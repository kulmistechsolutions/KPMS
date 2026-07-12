-- Trial pharmacies must stay usable while checkout is in progress or after a failed payment.

create or replace function public.kpms_billing_restore_after_failed_checkout(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub public.subscriptions%rowtype;
  v_trial_days int;
  v_ends timestamptz;
begin
  select * into v_sub
  from public.subscriptions
  where tenant_id = p_tenant_id
  order by created_at desc
  limit 1;

  if not found then return; end if;

  if exists (
    select 1 from public.payments p
    where p.tenant_id = p_tenant_id and p.status = 'paid'
  ) then
    return;
  end if;

  v_ends := coalesce(v_sub.trial_ends_at, v_sub.expires_at);

  if v_ends is null or v_ends <= now() then
    select coalesce(ps.default_trial_days, 14) into v_trial_days
    from public.platform_settings ps where ps.id = 1;
    v_trial_days := greatest(coalesce(v_trial_days, 14), 1);
    v_ends := now() + make_interval(days => v_trial_days);
  end if;

  update public.subscriptions set
    lifecycle_status = 'trial',
    status = 'active',
    payment_status = 'trialing',
    billing_interval = coalesce(nullif(billing_interval, ''), 'trial'),
    trial_ends_at = v_ends,
    expires_at = v_ends,
    pending_plan_id = null,
    updated_at = now()
  where id = v_sub.id;
end;
$$;

revoke all on function public.kpms_billing_restore_after_failed_checkout(uuid) from public;
grant execute on function public.kpms_billing_restore_after_failed_checkout(uuid) to service_role;

-- Checkout: keep trial/active access while payment is pending.
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
  v_next_lifecycle text;
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

  v_next_lifecycle := coalesce(v_sub.lifecycle_status, 'trial');
  if v_sub.lifecycle_status = 'trial'
     and coalesce(v_sub.trial_ends_at, v_sub.expires_at, now() + interval '1 day') > now() then
    v_next_lifecycle := 'trial';
  elsif v_sub.lifecycle_status in ('active', 'grace_period')
     and coalesce(v_sub.expires_at, now()) > now() then
    v_next_lifecycle := v_sub.lifecycle_status;
  else
    v_next_lifecycle := 'pending';
  end if;

  update public.subscriptions
  set
    lifecycle_status = v_next_lifecycle,
    pending_plan_id = p_plan_id,
    payment_status = 'checkout_pending',
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

-- Failed payment: restore trial when tenant has never paid.
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
    perform public.kpms_billing_restore_after_failed_checkout(v_pay.tenant_id);
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

-- Pending checkout must not lock out an active trial.
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
  v_trial_ends timestamptz;
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

  select s.expires_at, s.trial_ends_at, s.grace_ends_at, s.status, s.payment_status, s.plan_id, s.lifecycle_status
  into v_expires, v_trial_ends, v_grace, v_sub_status, v_pay, v_pl_id, v_lifecycle
  from public.subscriptions s where s.tenant_id = v_tenant order by s.created_at desc limit 1;

  if v_lifecycle = 'pending' then
    if coalesce(v_trial_ends, v_expires) is not null and coalesce(v_trial_ends, v_expires) >= now() then
      v_lifecycle := 'trial';
      v_warn := true;
      v_warn_msg := 'Payment checkout in progress — your free trial access continues.';
    else
      return jsonb_build_object('blocked', true, 'reason', 'subscription_pending',
        'message', 'Complete payment to activate your subscription.', 'redirect', '/app/subscriptions');
    end if;
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

  if v_expires is not null and v_expires < now() and coalesce(v_lifecycle, '') <> 'trial' then
    return jsonb_build_object('blocked', true, 'reason', 'subscription_expired',
      'message', 'Your subscription has expired. Renew to continue.', 'redirect', '/app/subscriptions');
  end if;

  if coalesce(v_lifecycle, v_sub_status) in ('expired', 'cancelled', 'suspended') then
    return jsonb_build_object('blocked', true, 'reason', 'subscription_inactive',
      'message', 'Your subscription is not active.', 'redirect', '/app/subscriptions');
  end if;

  if v_lifecycle = 'trial' and v_trial_ends is not null and v_trial_ends <= now() + interval '7 days' then
    v_warn := true;
    v_warn_msg := format('Free trial ends on %s.', to_char(v_trial_ends at time zone 'UTC', 'YYYY-MM-DD'));
  elsif v_expires is not null and v_expires <= now() + interval '7 days' then
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

-- Unblock pharmacies stuck in pending after failed checkout.
do $$
declare
  r record;
begin
  for r in
    select distinct s.tenant_id
    from public.subscriptions s
    join public.tenants t on t.id = s.tenant_id
    where t.suspended_at is null
      and t.deleted_at is null
      and s.lifecycle_status = 'pending'
      and not exists (
        select 1 from public.payments p
        where p.tenant_id = s.tenant_id and p.status = 'paid'
      )
  loop
    perform public.kpms_billing_restore_after_failed_checkout(r.tenant_id);
  end loop;
end;
$$;

grant execute on function public.kpms_billing_create_checkout(uuid, text, text, text) to authenticated;
