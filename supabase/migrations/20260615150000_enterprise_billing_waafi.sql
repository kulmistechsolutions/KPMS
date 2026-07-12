-- KPMS V3 enterprise billing: payments, invoices, trials, coupons, tenant limits, WAAFI activation.
-- Subscription becomes ACTIVE only after server-verified payment (see kpms_billing_complete_payment).

-- ─── Platform billing settings ─────────────────────────────────────────────
alter table public.platform_settings
  add column if not exists trial_enabled boolean not null default true,
  add column if not exists grace_period_days integer not null default 7,
  add column if not exists grace_pos_enabled boolean not null default false,
  add column if not exists grace_inventory_enabled boolean not null default true,
  add column if not exists billing_currency text not null default 'USD',
  add column if not exists waafi_enabled boolean not null default true;

alter table public.subscription_plans
  add column if not exists archived_at timestamptz,
  add column if not exists trial_days integer,
  add column if not exists is_public boolean not null default true;

alter table public.subscriptions
  add column if not exists lifecycle_status text not null default 'trial',
  add column if not exists trial_ends_at timestamptz,
  add column if not exists pending_plan_id uuid references public.subscription_plans (id) on delete set null,
  add column if not exists cancelled_at timestamptz,
  add column if not exists blocked_at timestamptz;

comment on column public.subscriptions.lifecycle_status is
  'trial|pending|active|expired|suspended|cancelled|grace_period|blocked';

-- ─── subscription_features (normalized plan entitlements) ────────────────────
create table if not exists public.subscription_features (
  plan_id uuid not null references public.subscription_plans (id) on delete cascade,
  feature_key text not null,
  enabled boolean not null default true,
  limit_value integer,
  updated_at timestamptz not null default now(),
  primary key (plan_id, feature_key)
);

alter table public.subscription_features enable row level security;

drop policy if exists subscription_features_select on public.subscription_features;
create policy subscription_features_select on public.subscription_features
  for select to authenticated using (true);

drop policy if exists subscription_features_write_sa on public.subscription_features;
create policy subscription_features_write_sa on public.subscription_features
  for all to authenticated
  using (public.kpms_is_platform_super_admin())
  with check (public.kpms_is_platform_super_admin());

grant select on public.subscription_features to authenticated;
grant insert, update, delete on public.subscription_features to authenticated;

-- ─── tenant_limits (materialized per tenant) ─────────────────────────────────
create table if not exists public.tenant_limits (
  tenant_id uuid primary key references public.tenants (id) on delete cascade,
  max_users integer,
  max_branches integer,
  max_products integer,
  max_storage_mb integer,
  pos_enabled boolean not null default true,
  ai_enabled boolean not null default false,
  reports_enabled boolean not null default true,
  inventory_enabled boolean not null default true,
  crm_enabled boolean not null default true,
  accounting_enabled boolean not null default false,
  multi_branch_enabled boolean not null default false,
  api_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.tenant_limits enable row level security;

drop policy if exists tenant_limits_select on public.tenant_limits;
create policy tenant_limits_select on public.tenant_limits
  for select to authenticated
  using (tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin());

drop policy if exists tenant_limits_write_sa on public.tenant_limits;
create policy tenant_limits_write_sa on public.tenant_limits
  for all to authenticated
  using (public.kpms_is_platform_super_admin())
  with check (public.kpms_is_platform_super_admin());

grant select on public.tenant_limits to authenticated;

-- ─── subscription_usage ──────────────────────────────────────────────────────
create table if not exists public.subscription_usage (
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  metric_key text not null,
  period_start date not null default (date_trunc('month', now())::date),
  current_value integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, metric_key, period_start)
);

alter table public.subscription_usage enable row level security;

drop policy if exists subscription_usage_tenant on public.subscription_usage;
create policy subscription_usage_tenant on public.subscription_usage
  for select to authenticated
  using (tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin());

grant select on public.subscription_usage to authenticated;

-- ─── coupons & discounts ─────────────────────────────────────────────────────
create table if not exists public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  description text,
  discount_type text not null check (discount_type in ('percent', 'fixed')),
  discount_value numeric(12, 2) not null,
  max_redemptions integer,
  redemption_count integer not null default 0,
  valid_from timestamptz,
  valid_until timestamptz,
  applicable_plan_ids uuid[],
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coupons_code_unique unique (code)
);

create table if not exists public.discounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants (id) on delete set null,
  payment_id uuid,
  coupon_id uuid references public.coupons (id) on delete set null,
  discount_cents integer not null default 0,
  description text,
  created_at timestamptz not null default now()
);

alter table public.coupons enable row level security;
alter table public.discounts enable row level security;

drop policy if exists coupons_select on public.coupons;
create policy coupons_select on public.coupons
  for select to authenticated using (is_active or public.kpms_is_platform_super_admin());

drop policy if exists coupons_write_sa on public.coupons;
create policy coupons_write_sa on public.coupons
  for all to authenticated
  using (public.kpms_is_platform_super_admin())
  with check (public.kpms_is_platform_super_admin());

drop policy if exists discounts_select on public.discounts;
create policy discounts_select on public.discounts
  for select to authenticated
  using (tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin());

grant select on public.coupons to authenticated;
grant select on public.discounts to authenticated;

-- ─── billing_invoices ────────────────────────────────────────────────────────
create table if not exists public.billing_invoices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  subscription_id uuid references public.subscriptions (id) on delete set null,
  plan_id uuid references public.subscription_plans (id) on delete set null,
  invoice_number text not null,
  amount_cents integer not null,
  discount_cents integer not null default 0,
  currency text not null default 'USD',
  status text not null default 'open'
    check (status in ('draft', 'open', 'paid', 'void', 'overdue', 'cancelled')),
  billing_interval text check (billing_interval in ('monthly', 'yearly', 'trial', 'manual')),
  due_at timestamptz,
  paid_at timestamptz,
  line_items jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint billing_invoices_number_unique unique (invoice_number)
);

create index if not exists billing_invoices_tenant_idx on public.billing_invoices (tenant_id, created_at desc);
create index if not exists billing_invoices_status_idx on public.billing_invoices (status, due_at);

-- ─── payments ────────────────────────────────────────────────────────────────
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  subscription_id uuid references public.subscriptions (id) on delete set null,
  invoice_id uuid references public.billing_invoices (id) on delete set null,
  plan_id uuid references public.subscription_plans (id) on delete set null,
  coupon_id uuid references public.coupons (id) on delete set null,
  amount_cents integer not null,
  discount_cents integer not null default 0,
  currency text not null default 'USD',
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'failed', 'cancelled', 'refunded')),
  method text not null default 'waafi',
  payment_type text not null default 'subscription_new'
    check (payment_type in ('subscription_new', 'renewal', 'upgrade', 'downgrade', 'manual', 'trial_conversion')),
  billing_interval text check (billing_interval in ('monthly', 'yearly')),
  waafi_reference_id text,
  waafi_order_id text,
  waafi_transaction_id text,
  waafi_transfer_code text,
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb,
  paid_at timestamptz,
  failed_at timestamptz,
  cancelled_at timestamptz,
  refunded_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  verified_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payments_idempotency_unique unique (idempotency_key),
  constraint payments_waafi_reference_unique unique (waafi_reference_id)
);

create index if not exists payments_tenant_idx on public.payments (tenant_id, created_at desc);
create index if not exists payments_status_idx on public.payments (status, created_at desc);
create index if not exists payments_pending_idx on public.payments (status) where status = 'pending';

-- FK discounts.payment_id after payments exists
alter table public.discounts
  drop constraint if exists discounts_payment_id_fkey;
alter table public.discounts
  add constraint discounts_payment_id_fkey
  foreign key (payment_id) references public.payments (id) on delete set null;

-- ─── payment_transactions (audit trail per payment) ──────────────────────────
create table if not exists public.payment_transactions (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id) on delete cascade,
  event_type text not null,
  status text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists payment_transactions_payment_idx on public.payment_transactions (payment_id, created_at desc);

-- ─── payment_methods (platform-level) ────────────────────────────────────────
create table if not exists public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  provider text not null default 'waafi',
  is_active boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

insert into public.payment_methods (code, name, provider, is_active)
values ('waafi_mwallet', 'WAAFI / Mobile Wallet', 'waafi', true)
on conflict (code) do nothing;

-- ─── billing_receipts ────────────────────────────────────────────────────────
create table if not exists public.billing_receipts (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id) on delete cascade,
  invoice_id uuid references public.billing_invoices (id) on delete set null,
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  receipt_number text not null,
  receipt_url text,
  amount_cents integer not null,
  currency text not null default 'USD',
  created_at timestamptz not null default now(),
  constraint billing_receipts_number_unique unique (receipt_number)
);

-- ─── trial_history ───────────────────────────────────────────────────────────
create table if not exists public.trial_history (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  subscription_id uuid references public.subscriptions (id) on delete set null,
  action text not null check (action in ('started', 'extended', 'cancelled', 'converted', 'expired')),
  days_added integer not null default 0,
  reason text,
  actor_id uuid references public.profiles (id) on delete set null,
  ends_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists trial_history_tenant_idx on public.trial_history (tenant_id, created_at desc);

-- ─── webhook replay protection ───────────────────────────────────────────────
create table if not exists public.billing_webhook_events (
  event_id text primary key,
  provider text not null default 'waafi',
  payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now()
);

-- ─── RLS: tenant-scoped billing reads ────────────────────────────────────────
alter table public.billing_invoices enable row level security;
alter table public.payments enable row level security;
alter table public.payment_transactions enable row level security;
alter table public.billing_receipts enable row level security;
alter table public.trial_history enable row level security;
alter table public.payment_methods enable row level security;
alter table public.billing_webhook_events enable row level security;

drop policy if exists billing_invoices_tenant on public.billing_invoices;
create policy billing_invoices_tenant on public.billing_invoices
  for select to authenticated
  using (tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin());

drop policy if exists payments_tenant on public.payments;
create policy payments_tenant on public.payments
  for select to authenticated
  using (tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin());

drop policy if exists payment_transactions_tenant on public.payment_transactions;
create policy payment_transactions_tenant on public.payment_transactions
  for select to authenticated
  using (
    exists (
      select 1 from public.payments p
      where p.id = payment_id
        and (p.tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin())
    )
  );

drop policy if exists billing_receipts_tenant on public.billing_receipts;
create policy billing_receipts_tenant on public.billing_receipts
  for select to authenticated
  using (tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin());

drop policy if exists trial_history_tenant on public.trial_history;
create policy trial_history_tenant on public.trial_history
  for select to authenticated
  using (tenant_id = public.kpms_my_tenant_id() or public.kpms_is_platform_super_admin());

drop policy if exists payment_methods_select on public.payment_methods;
create policy payment_methods_select on public.payment_methods
  for select to authenticated using (is_active);

drop policy if exists billing_webhook_events_sa on public.billing_webhook_events;
create policy billing_webhook_events_sa on public.billing_webhook_events
  for select to authenticated using (public.kpms_is_platform_super_admin());

grant select on public.billing_invoices to authenticated;
grant select on public.payments to authenticated;
grant select on public.payment_transactions to authenticated;
grant select on public.billing_receipts to authenticated;
grant select on public.trial_history to authenticated;
grant select on public.payment_methods to authenticated;

-- ─── Helpers ─────────────────────────────────────────────────────────────────
create or replace function public._kpms_next_invoice_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seq bigint;
begin
  select count(*) + 1 into v_seq from public.billing_invoices;
  return 'INV-' || to_char(now(), 'YYYYMM') || '-' || lpad(v_seq::text, 6, '0');
end;
$$;

create or replace function public._kpms_next_receipt_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seq bigint;
begin
  select count(*) + 1 into v_seq from public.billing_receipts;
  return 'RCP-' || to_char(now(), 'YYYYMM') || '-' || lpad(v_seq::text, 6, '0');
end;
$$;

create or replace function public._kpms_sync_tenant_limits(p_tenant_id uuid, p_plan_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pl public.subscription_plans%rowtype;
  v_feat jsonb;
begin
  select * into v_pl from public.subscription_plans where id = p_plan_id;
  if not found then return; end if;

  v_feat := coalesce(v_pl.features, '{}'::jsonb);

  insert into public.tenant_limits (
    tenant_id, max_users, max_branches, max_products, max_storage_mb,
    pos_enabled, ai_enabled, reports_enabled, inventory_enabled,
    crm_enabled, accounting_enabled, multi_branch_enabled, api_enabled, updated_at
  )
  values (
    p_tenant_id,
    v_pl.max_staff,
    v_pl.max_branches,
    v_pl.max_medicines,
    v_pl.max_storage_mb,
    coalesce((v_feat->>'pos')::boolean, true),
    coalesce((v_feat->>'ai')::boolean, false),
    coalesce((v_feat->>'reports')::boolean, true),
    coalesce((v_feat->>'inventory')::boolean, true),
    coalesce((v_feat->>'crm')::boolean, true),
    coalesce((v_feat->>'accounting')::boolean, false),
    coalesce((v_feat->>'multi_branch')::boolean, (v_pl.max_branches is not null and v_pl.max_branches > 1)),
    coalesce((v_feat->>'api')::boolean, false),
    now()
  )
  on conflict (tenant_id) do update set
    max_users = excluded.max_users,
    max_branches = excluded.max_branches,
    max_products = excluded.max_products,
    max_storage_mb = excluded.max_storage_mb,
    pos_enabled = excluded.pos_enabled,
    ai_enabled = excluded.ai_enabled,
    reports_enabled = excluded.reports_enabled,
    inventory_enabled = excluded.inventory_enabled,
    crm_enabled = excluded.crm_enabled,
    accounting_enabled = excluded.accounting_enabled,
    multi_branch_enabled = excluded.multi_branch_enabled,
    api_enabled = excluded.api_enabled,
    updated_at = now();
end;
$$;

-- ─── Create checkout (tenant owner) — payment stays pending until verified ───
create or replace function public.kpms_billing_create_checkout(
  p_plan_id uuid,
  p_billing_interval text default 'monthly',
  p_coupon_code text default null,
  p_payment_type text default 'subscription_new'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_tenant uuid;
  v_role text;
  v_pl public.subscription_plans%rowtype;
  v_sub public.subscriptions%rowtype;
  v_amount integer;
  v_discount integer := 0;
  v_coupon public.coupons%rowtype;
  v_coupon_id uuid;
  v_invoice_id uuid;
  v_payment_id uuid;
  v_ref text;
  v_interval text := lower(trim(coalesce(p_billing_interval, 'monthly')));
  v_currency text;
begin
  if v_uid is null then raise exception 'Unauthorized'; end if;

  select p.tenant_id, p.role into v_tenant, v_role
  from public.profiles p where p.id = v_uid;

  if v_tenant is null then raise exception 'No tenant linked'; end if;
  if v_role not in ('pharmacy_owner', 'pharmacy_admin', 'pharmacist') then
    raise exception 'Forbidden';
  end if;

  select * into v_pl from public.subscription_plans
  where id = p_plan_id and is_active = true and archived_at is null;
  if not found then raise exception 'Plan not found'; end if;

  if v_interval = 'yearly' then
    v_amount := coalesce(v_pl.yearly_price_cents, 0);
  else
    v_amount := coalesce(v_pl.monthly_price_cents, 0);
    v_interval := 'monthly';
  end if;

  if v_amount <= 0 then raise exception 'Plan has no price for interval %', v_interval; end if;

  if p_coupon_code is not null and trim(p_coupon_code) <> '' then
    select * into v_coupon from public.coupons c
    where upper(c.code) = upper(trim(p_coupon_code))
      and c.is_active = true
      and (c.valid_from is null or c.valid_from <= now())
      and (c.valid_until is null or c.valid_until >= now())
      and (c.max_redemptions is null or c.redemption_count < c.max_redemptions);
    if found then
      if v_coupon.discount_type = 'percent' then
        v_discount := floor(v_amount * (v_coupon.discount_value / 100.0))::integer;
      else
        v_discount := least(v_amount, (v_coupon.discount_value * 100)::integer);
      end if;
      v_coupon_id := v_coupon.id;
    end if;
  end if;

  select coalesce(ps.billing_currency, 'USD') into v_currency
  from public.platform_settings ps where ps.id = 1;

  select * into v_sub from public.subscriptions s
  where s.tenant_id = v_tenant order by s.created_at desc limit 1;

  v_ref := replace(gen_random_uuid()::text, '-', '');

  insert into public.billing_invoices (
    tenant_id, subscription_id, plan_id, invoice_number,
    amount_cents, discount_cents, currency, status, billing_interval, due_at, line_items
  )
  values (
    v_tenant, v_sub.id, p_plan_id, public._kpms_next_invoice_number(),
    v_amount, v_discount, v_currency, 'open', v_interval, now() + interval '24 hours',
    jsonb_build_array(jsonb_build_object(
      'description', v_pl.name || ' (' || v_interval || ')',
      'amount_cents', v_amount - v_discount
    ))
  )
  returning id into v_invoice_id;

  insert into public.payments (
    tenant_id, subscription_id, invoice_id, plan_id, coupon_id,
    amount_cents, discount_cents, currency, status, method, payment_type,
    billing_interval, waafi_reference_id, idempotency_key, created_by
  )
  values (
    v_tenant, v_sub.id, v_invoice_id, p_plan_id, v_coupon_id,
    v_amount - v_discount, v_discount, v_currency, 'pending', 'waafi',
    coalesce(p_payment_type, 'subscription_new'), v_interval,
    v_ref, v_ref, v_uid
  )
  returning id into v_payment_id;

  if v_coupon_id is not null then
    insert into public.discounts (tenant_id, payment_id, coupon_id, discount_cents, description)
    select v_tenant, v_payment_id, v_coupon_id, v_discount, 'Coupon ' || c.code
    from public.coupons c where c.id = v_coupon_id;
  end if;

  insert into public.payment_transactions (payment_id, event_type, status, payload)
  values (v_payment_id, 'checkout_created', 'pending', jsonb_build_object('plan_id', p_plan_id, 'interval', v_interval));

  update public.subscriptions
  set
    lifecycle_status = 'pending',
    pending_plan_id = p_plan_id,
    payment_status = 'unknown',
    updated_at = now()
  where tenant_id = v_tenant;

  perform public._platform_audit_log(
    'billing_checkout_created', 'payments', v_payment_id,
    jsonb_build_object('tenant_id', v_tenant, 'amount_cents', v_amount - v_discount)
  );

  return jsonb_build_object(
    'payment_id', v_payment_id,
    'invoice_id', v_invoice_id,
    'reference_id', v_ref,
    'amount_cents', v_amount - v_discount,
    'currency', v_currency,
    'plan_name', v_pl.name,
    'billing_interval', v_interval
  );
end;
$$;

-- ─── Complete payment (service role / edge function ONLY) ─────────────────────
create or replace function public.kpms_billing_complete_payment(
  p_payment_id uuid,
  p_waafi_transaction_id text,
  p_waafi_order_id text default null,
  p_waafi_transfer_code text default null,
  p_verified_amount numeric default null,
  p_verified_currency text default null,
  p_status text default 'paid',
  p_webhook_event_id text default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments%rowtype;
  v_pl public.subscription_plans%rowtype;
  v_expires timestamptz;
  v_receipt_id uuid;
  v_receipt_no text;
  v_grace_days integer;
begin
  if p_webhook_event_id is not null and trim(p_webhook_event_id) <> '' then
    if exists (select 1 from public.billing_webhook_events e where e.event_id = p_webhook_event_id) then
      return jsonb_build_object('ok', true, 'duplicate', true);
    end if;
    insert into public.billing_webhook_events (event_id, payload) values (p_webhook_event_id, p_payload);
  end if;

  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;

  if v_pay.status = 'paid' then
    return jsonb_build_object('ok', true, 'already_paid', true, 'payment_id', v_pay.id);
  end if;

  if lower(coalesce(p_status, 'paid')) not in ('paid', 'failed', 'cancelled', 'refunded') then
    raise exception 'Invalid status';
  end if;

  if p_status = 'paid' then
    if p_verified_amount is not null then
      if abs(p_verified_amount - (v_pay.amount_cents / 100.0)) > 0.02 then
        raise exception 'Amount mismatch';
      end if;
    end if;
    if p_verified_currency is not null and upper(p_verified_currency) <> upper(v_pay.currency) then
      raise exception 'Currency mismatch';
    end if;
  end if;

  update public.payments set
    status = p_status,
    waafi_transaction_id = coalesce(p_waafi_transaction_id, waafi_transaction_id),
    waafi_order_id = coalesce(p_waafi_order_id, waafi_order_id),
    waafi_transfer_code = coalesce(p_waafi_transfer_code, waafi_transfer_code),
    paid_at = case when p_status = 'paid' then now() else paid_at end,
    failed_at = case when p_status = 'failed' then now() else failed_at end,
    cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
    refunded_at = case when p_status = 'refunded' then now() else refunded_at end,
    updated_at = now()
  where id = p_payment_id;

  insert into public.payment_transactions (payment_id, event_type, status, payload)
  values (p_payment_id, 'payment_' || p_status, p_status, p_payload);

  if p_status <> 'paid' then
    return jsonb_build_object('ok', true, 'payment_id', p_payment_id, 'status', p_status);
  end if;

  select * into v_pl from public.subscription_plans where id = v_pay.plan_id;
  if not found then raise exception 'Plan missing'; end if;

  select coalesce(ps.grace_period_days, 7) into v_grace_days from public.platform_settings ps where ps.id = 1;

  if v_pay.billing_interval = 'yearly' then
    v_expires := now() + interval '1 year';
  else
    v_expires := now() + interval '1 month';
  end if;

  update public.subscriptions set
    plan_id = v_pay.plan_id,
    plan = v_pl.slug,
    status = 'active',
    lifecycle_status = 'active',
    payment_status = 'current',
    billing_interval = v_pay.billing_interval,
    expires_at = v_expires,
    grace_ends_at = v_expires + make_interval(days => v_grace_days),
    pending_plan_id = null,
    trial_ends_at = null,
    updated_at = now()
  where tenant_id = v_pay.tenant_id;

  update public.billing_invoices set
    status = 'paid', paid_at = now(), updated_at = now()
  where id = v_pay.invoice_id;

  v_receipt_no := public._kpms_next_receipt_number();
  insert into public.billing_receipts (
    payment_id, invoice_id, tenant_id, receipt_number, amount_cents, currency
  )
  values (
    v_pay.id, v_pay.invoice_id, v_pay.tenant_id, v_receipt_no, v_pay.amount_cents, v_pay.currency
  )
  returning id into v_receipt_id;

  if v_pay.coupon_id is not null then
    update public.coupons set redemption_count = redemption_count + 1, updated_at = now()
    where id = v_pay.coupon_id;
  end if;

  perform public._kpms_sync_tenant_limits(v_pay.tenant_id, v_pay.plan_id);

  insert into public.platform_billing_events (tenant_id, event_type, amount_cents, currency, metadata, actor_id)
  values (
    v_pay.tenant_id, 'payment_success', v_pay.amount_cents, v_pay.currency,
    jsonb_build_object('payment_id', v_pay.id, 'waafi_transaction_id', p_waafi_transaction_id),
    v_pay.created_by
  );

  perform public._platform_audit_log(
    'subscription_activated', 'subscriptions', v_pay.subscription_id,
    jsonb_build_object('payment_id', v_pay.id, 'plan_id', v_pay.plan_id)
  );

  return jsonb_build_object(
    'ok', true,
    'payment_id', v_pay.id,
    'receipt_id', v_receipt_id,
    'receipt_number', v_receipt_no,
    'expires_at', v_expires
  );
end;
$$;

revoke all on function public.kpms_billing_complete_payment(uuid, text, text, text, numeric, text, text, text, jsonb) from public;
revoke all on function public.kpms_billing_complete_payment(uuid, text, text, text, numeric, text, text, text, jsonb) from authenticated;
grant execute on function public.kpms_billing_complete_payment(uuid, text, text, text, numeric, text, text, text, jsonb) to service_role;

-- ─── Manual payment (super admin) ────────────────────────────────────────────
create or replace function public.super_admin_record_manual_payment(
  p_tenant_id uuid,
  p_plan_id uuid,
  p_amount_cents integer,
  p_billing_interval text default 'monthly',
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref text := replace(gen_random_uuid()::text, '-', '');
  v_invoice_id uuid;
  v_payment_id uuid;
  v_pl public.subscription_plans%rowtype;
  v_sub uuid;
  v_currency text;
  v_result jsonb;
begin
  if not public.kpms_is_platform_super_admin() then raise exception 'Forbidden'; end if;

  select * into v_pl from public.subscription_plans where id = p_plan_id;
  if not found then raise exception 'Plan not found'; end if;

  select s.id into v_sub from public.subscriptions s where s.tenant_id = p_tenant_id order by created_at desc limit 1;
  select coalesce(billing_currency, 'USD') into v_currency from public.platform_settings where id = 1;

  insert into public.billing_invoices (
    tenant_id, subscription_id, plan_id, invoice_number, amount_cents, currency, status, billing_interval, due_at
  )
  values (
    p_tenant_id, v_sub, p_plan_id, public._kpms_next_invoice_number(),
    p_amount_cents, v_currency, 'open', p_billing_interval, now() + interval '24 hours'
  )
  returning id into v_invoice_id;

  insert into public.payments (
    tenant_id, subscription_id, invoice_id, plan_id, amount_cents, currency,
    status, method, payment_type, billing_interval, waafi_reference_id, idempotency_key, metadata, created_by
  )
  values (
    p_tenant_id, v_sub, v_invoice_id, p_plan_id, p_amount_cents, v_currency,
    'pending', 'manual', 'manual', p_billing_interval, v_ref, v_ref,
    jsonb_build_object('note', coalesce(p_note, '')), auth.uid()
  )
  returning id into v_payment_id;

  select public.kpms_billing_complete_payment(
    v_payment_id, 'MANUAL-' || v_payment_id::text, null, null,
    p_amount_cents / 100.0, v_currency, 'paid', null, jsonb_build_object('manual', true)
  ) into v_result;

  perform public._platform_audit_log('manual_payment_recorded', 'payments', v_payment_id,
    jsonb_build_object('tenant_id', p_tenant_id, 'note', p_note));

  return v_result;
end;
$$;

-- ─── Trial management ────────────────────────────────────────────────────────
create or replace function public.super_admin_grant_trial(
  p_tenant_id uuid,
  p_days integer,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub_id uuid;
  v_ends timestamptz;
begin
  if not public.kpms_is_platform_super_admin() then raise exception 'Forbidden'; end if;
  if p_days < 1 then raise exception 'Days must be positive'; end if;

  v_ends := now() + make_interval(days => p_days);

  update public.subscriptions set
    lifecycle_status = 'trial',
    status = 'active',
    payment_status = 'trialing',
    billing_interval = 'trial',
    trial_ends_at = v_ends,
    expires_at = v_ends,
    updated_at = now()
  where tenant_id = p_tenant_id
  returning id into v_sub_id;

  insert into public.trial_history (tenant_id, subscription_id, action, days_added, reason, actor_id, ends_at)
  values (p_tenant_id, v_sub_id, 'started', p_days, p_reason, auth.uid(), v_ends);

  perform public._platform_audit_log('trial_granted', 'subscriptions', v_sub_id,
    jsonb_build_object('days', p_days, 'ends_at', v_ends));
end;
$$;

create or replace function public.super_admin_extend_trial(
  p_tenant_id uuid,
  p_extra_days integer,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub public.subscriptions%rowtype;
  v_ends timestamptz;
begin
  if not public.kpms_is_platform_super_admin() then raise exception 'Forbidden'; end if;

  select * into v_sub from public.subscriptions where tenant_id = p_tenant_id order by created_at desc limit 1;
  if not found then raise exception 'Subscription not found'; end if;

  v_ends := coalesce(v_sub.trial_ends_at, v_sub.expires_at, now()) + make_interval(days => p_extra_days);

  update public.subscriptions set
    lifecycle_status = 'trial',
    payment_status = 'trialing',
    trial_ends_at = v_ends,
    expires_at = v_ends,
    updated_at = now()
  where id = v_sub.id;

  insert into public.trial_history (tenant_id, subscription_id, action, days_added, reason, actor_id, ends_at)
  values (p_tenant_id, v_sub.id, 'extended', p_extra_days, p_reason, auth.uid(), v_ends);

  perform public._platform_audit_log('trial_extended', 'subscriptions', v_sub.id,
    jsonb_build_object('extra_days', p_extra_days));
end;
$$;

-- ─── Billing analytics (super admin dashboard) ───────────────────────────────
create or replace function public.super_admin_billing_analytics()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mrr numeric := 0;
  v_arr numeric := 0;
  v_active int;
  v_trials int;
  v_expired int;
  v_pending int;
  v_failed int;
  v_suspended int;
  v_revenue_month numeric;
  v_revenue_year numeric;
  v_churn numeric := 0;
  v_success_rate numeric := 100;
  v_total_payments int;
  v_paid_payments int;
begin
  if not public.kpms_is_platform_super_admin() then raise exception 'Forbidden'; end if;

  select count(*) into v_active from public.subscriptions where lifecycle_status = 'active';
  select count(*) into v_trials from public.subscriptions where lifecycle_status = 'trial';
  select count(*) into v_expired from public.subscriptions where lifecycle_status in ('expired', 'cancelled');
  select count(*) into v_pending from public.payments where status = 'pending';
  select count(*) into v_failed from public.payments where status = 'failed' and created_at >= now() - interval '30 days';
  select count(*) into v_suspended from public.subscriptions where lifecycle_status = 'suspended';

  select coalesce(sum(
    case when s.billing_interval = 'yearly' then pl.yearly_price_cents / 12.0 else pl.monthly_price_cents end
  ), 0) / 100.0
  into v_mrr
  from public.subscriptions s
  join public.subscription_plans pl on pl.id = s.plan_id
  where s.lifecycle_status = 'active';

  v_arr := v_mrr * 12;

  select coalesce(sum(amount_cents), 0) / 100.0 into v_revenue_month
  from public.payments where status = 'paid' and paid_at >= date_trunc('month', now());

  select coalesce(sum(amount_cents), 0) / 100.0 into v_revenue_year
  from public.payments where status = 'paid' and paid_at >= date_trunc('year', now());

  select count(*) into v_total_payments from public.payments where created_at >= now() - interval '30 days';
  select count(*) into v_paid_payments from public.payments where status = 'paid' and created_at >= now() - interval '30 days';
  if v_total_payments > 0 then
    v_success_rate := round(100.0 * v_paid_payments / v_total_payments, 2);
  end if;

  return jsonb_build_object(
    'mrr', v_mrr,
    'arr', v_arr,
    'active_subscriptions', v_active,
    'trial_accounts', v_trials,
    'expired_accounts', v_expired,
    'pending_payments', v_pending,
    'failed_payments', v_failed,
    'suspended_pharmacies', v_suspended,
    'monthly_revenue', v_revenue_month,
    'annual_revenue', v_revenue_year,
    'payment_success_rate', v_success_rate,
    'churn_rate', v_churn
  );
end;
$$;

-- ─── List payments (paginated, super admin) ──────────────────────────────────
create or replace function public.super_admin_list_payments(
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.kpms_is_platform_super_admin() then raise exception 'Forbidden'; end if;

  return jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select p.*, t.name as tenant_name, pl.name as plan_name
        from public.payments p
        left join public.tenants t on t.id = p.tenant_id
        left join public.subscription_plans pl on pl.id = p.plan_id
        where p_status is null or p.status = p_status
        order by p.created_at desc
        limit greatest(p_limit, 1)
        offset greatest(p_offset, 0)
      ) x
    ), '[]'::jsonb),
    'total', (select count(*) from public.payments p where p_status is null or p.status = p_status),
    'limit', p_limit,
    'offset', p_offset
  );
end;
$$;

-- ─── Tenant payment history ────────────────────────────────────────────────────
create or replace function public.kpms_my_billing_history(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid;
begin
  select p.tenant_id into v_tenant from public.profiles p where p.id = auth.uid();
  if v_tenant is null then return '[]'::jsonb; end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
    from (
      select p.id, p.amount_cents, p.currency, p.status, p.method,
             p.waafi_reference_id, p.waafi_transaction_id, p.paid_at, p.created_at,
             bi.invoice_number, br.receipt_number, br.receipt_url
      from public.payments p
      left join public.billing_invoices bi on bi.id = p.invoice_id
      left join public.billing_receipts br on br.payment_id = p.id
      where p.tenant_id = v_tenant
      order by p.created_at desc
      limit greatest(p_limit, 1)
    ) x
  ), '[]'::jsonb);
end;
$$;

-- ─── Daily billing jobs ────────────────────────────────────────────────────────
create or replace function public.kpms_billing_run_daily_jobs()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired_trials int := 0;
  v_expired_subs int := 0;
  v_reminders int := 0;
  v_grace int := 0;
begin
  -- Expire trials
  update public.subscriptions set
    lifecycle_status = 'expired',
    status = 'inactive',
    payment_status = 'overdue',
    updated_at = now()
  where lifecycle_status = 'trial'
    and trial_ends_at is not null
    and trial_ends_at < now();
  get diagnostics v_expired_trials = row_count;

  -- Move active → grace_period when expired but grace valid
  update public.subscriptions set lifecycle_status = 'grace_period', updated_at = now()
  where lifecycle_status = 'active'
    and expires_at is not null
    and expires_at < now()
    and grace_ends_at is not null
    and grace_ends_at >= now();
  get diagnostics v_grace = row_count;

  -- Expire subscriptions past grace
  update public.subscriptions set
    lifecycle_status = 'expired',
    status = 'inactive',
    payment_status = 'overdue',
    updated_at = now()
  where lifecycle_status in ('active', 'grace_period')
    and expires_at is not null
    and expires_at < now()
    and (grace_ends_at is null or grace_ends_at < now());
  get diagnostics v_expired_subs = row_count;

  -- Cancel stale pending payments (>48h)
  update public.payments set status = 'cancelled', cancelled_at = now(), updated_at = now()
  where status = 'pending' and created_at < now() - interval '48 hours';

  return jsonb_build_object(
    'expired_trials', v_expired_trials,
    'expired_subscriptions', v_expired_subs,
    'grace_period_started', v_grace,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.kpms_billing_run_daily_jobs() from public;
revoke all on function public.kpms_billing_run_daily_jobs() from authenticated;
grant execute on function public.kpms_billing_run_daily_jobs() to service_role;

-- ─── Enhanced operational status (pending/blocked) ───────────────────────────
create or replace function public.get_my_pharmacy_operational_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_tenant uuid;
  v_suspended timestamptz;
  v_deleted timestamptz;
  v_maint boolean;
  v_maint_msg text;
  v_expires timestamptz;
  v_grace timestamptz;
  v_sub_status text;
  v_lifecycle text;
  v_pay text;
  v_force_epoch bigint;
  v_features jsonb := '{}'::jsonb;
  v_ent jsonb;
  v_limits jsonb;
  v_warn boolean := false;
  v_warn_msg text;
  v_pl_id uuid;
  v_grace_pos boolean;
  v_grace_inv boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('blocked', true, 'reason', 'unauthenticated', 'message', 'Sign in required.');
  end if;

  select p.role, p.tenant_id into v_role, v_tenant from public.profiles p where p.id = auth.uid();

  if v_role in ('platform_super_admin', 'super_admin') then
    return jsonb_build_object('blocked', false, 'reason', null, 'message', null,
      'subscription_warning', false, 'feature_flags', '{}'::jsonb, 'entitlements', '{}'::jsonb, 'force_logout_epoch', 0);
  end if;

  select ps.maintenance_mode, coalesce(nullif(trim(ps.maintenance_message), ''), 'The platform is under maintenance.'),
         coalesce(ps.grace_pos_enabled, false), coalesce(ps.grace_inventory_enabled, true)
  into v_maint, v_maint_msg, v_grace_pos, v_grace_inv
  from public.platform_settings ps where ps.id = 1;

  if coalesce(v_maint, false) then
    return jsonb_build_object('blocked', true, 'reason', 'maintenance', 'message', v_maint_msg);
  end if;

  if v_tenant is null then
    return jsonb_build_object('blocked', false, 'reason', null, 'message', null,
      'subscription_warning', false, 'feature_flags', '{}'::jsonb, 'entitlements', '{}'::jsonb, 'force_logout_epoch', 0);
  end if;

  select t.suspended_at, t.deleted_at, coalesce(t.force_logout_epoch, 0)
  into v_suspended, v_deleted, v_force_epoch from public.tenants t where t.id = v_tenant;

  if v_deleted is not null then
    return jsonb_build_object('blocked', true, 'reason', 'archived',
      'message', 'This pharmacy account is no longer available.');
  end if;

  if v_suspended is not null then
    return jsonb_build_object('blocked', true, 'reason', 'suspended',
      'message', 'Account suspended. Contact platform support.');
  end if;

  select s.expires_at, s.grace_ends_at, s.status, s.payment_status, s.plan_id, s.lifecycle_status
  into v_expires, v_grace, v_sub_status, v_pay, v_pl_id, v_lifecycle
  from public.subscriptions s where s.tenant_id = v_tenant order by s.created_at desc limit 1;

  if v_lifecycle = 'pending' then
    return jsonb_build_object('blocked', true, 'reason', 'subscription_pending',
      'message', 'Complete payment to activate your subscription.', 'redirect', '/app/subscriptions');
  end if;

  if v_lifecycle = 'blocked' then
    return jsonb_build_object('blocked', true, 'reason', 'subscription_blocked',
      'message', 'Your account is blocked. Contact support.', 'redirect', '/app/subscriptions');
  end if;

  select coalesce(jsonb_object_agg(o.flag_key, o.value), '{}'::jsonb) into v_features
  from public.platform_tenant_feature_overrides o where o.tenant_id = v_tenant;

  if v_pl_id is not null then
    select coalesce(pl.features, '{}'::jsonb) || v_features into v_features
    from public.subscription_plans pl where pl.id = v_pl_id;
  end if;

  select to_jsonb(tl.*) into v_limits from public.tenant_limits tl where tl.tenant_id = v_tenant;

  v_ent := coalesce(v_limits, jsonb_build_object(
    'max_medicines', (select pl.max_medicines from public.subscription_plans pl where pl.id = v_pl_id),
    'max_staff', (select pl.max_staff from public.subscription_plans pl where pl.id = v_pl_id),
    'max_branches', (select pl.max_branches from public.subscription_plans pl where pl.id = v_pl_id),
    'max_storage_mb', (select pl.max_storage_mb from public.subscription_plans pl where pl.id = v_pl_id)
  ));

  if v_lifecycle = 'grace_period' or (v_expires is not null and v_expires < now() and v_grace is not null and v_grace >= now()) then
    if not v_grace_pos then v_features := v_features || jsonb_build_object('pos', false); end if;
    if not v_grace_inv then v_features := v_features || jsonb_build_object('inventory', false); end if;
    return jsonb_build_object(
      'blocked', false, 'reason', 'subscription_grace', 'message', null,
      'subscription_warning', true,
      'subscription_warning_message', format('Grace period until %s. Renew to restore full access.', to_char(v_grace at time zone 'UTC', 'YYYY-MM-DD')),
      'grace_ends_at', v_grace, 'feature_flags', v_features, 'entitlements', v_ent, 'force_logout_epoch', v_force_epoch
    );
  end if;

  if v_expires is not null and v_expires < now() then
    return jsonb_build_object('blocked', true, 'reason', 'subscription_expired',
      'message', 'Your subscription has expired. Renew to continue.', 'redirect', '/app/subscriptions');
  end if;

  if coalesce(v_lifecycle, v_sub_status) in ('expired', 'cancelled', 'suspended') then
    return jsonb_build_object('blocked', true, 'reason', 'subscription_inactive',
      'message', 'Your subscription is not active.', 'redirect', '/app/subscriptions');
  end if;

  if v_expires is not null and v_expires <= now() + interval '7 days' then
    v_warn := true;
    v_warn_msg := format('Subscription renews or expires on %s.', to_char(v_expires at time zone 'UTC', 'YYYY-MM-DD'));
  end if;

  return jsonb_build_object(
    'blocked', false, 'reason', null, 'message', null,
    'subscription_warning', v_warn,
    'subscription_warning_message', case when v_warn then v_warn_msg else null end,
    'feature_flags', coalesce(v_features, '{}'::jsonb),
    'entitlements', coalesce(v_ent, '{}'::jsonb),
    'force_logout_epoch', coalesce(v_force_epoch, 0),
    'lifecycle_status', v_lifecycle
  );
end;
$$;

-- Grants
grant execute on function public.kpms_billing_create_checkout(uuid, text, text, text) to authenticated;
grant execute on function public.kpms_my_billing_history(integer) to authenticated;
grant execute on function public.super_admin_billing_analytics() to authenticated;
grant execute on function public.super_admin_list_payments(text, integer, integer) to authenticated;
grant execute on function public.super_admin_record_manual_payment(uuid, uuid, integer, text, text) to authenticated;
grant execute on function public.super_admin_grant_trial(uuid, integer, text) to authenticated;
grant execute on function public.super_admin_extend_trial(uuid, integer, text) to authenticated;
