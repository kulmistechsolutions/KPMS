-- New pharmacies start a real free trial (visible to super admin as "trial"),
-- and never-paid pharmacies stuck in pending get unblocked with a trial.

create or replace function public.register_pharmacy(
  p_name text,
  p_address text,
  p_phone text,
  p_license text,
  p_owner text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid;
  v_n int;
  v_plan_id uuid;
  v_trial_days int;
  v_ends timestamptz;
  v_sub_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select tenant_id into v_tenant
  from public.profiles
  where id = auth.uid();

  if v_tenant is not null then
    return v_tenant;
  end if;

  if nullif(trim(p_name), '') is null then
    raise exception 'Pharmacy name is required';
  end if;

  insert into public.tenants (name, address, phone, license_number, owner_name)
  values (
    nullif(trim(p_name), ''),
    nullif(trim(p_address), ''),
    nullif(trim(p_phone), ''),
    nullif(trim(p_license), ''),
    nullif(trim(p_owner), '')
  )
  returning id into v_tenant;

  if v_tenant is null then
    raise exception 'Failed to create tenant';
  end if;

  update public.profiles
  set
    tenant_id = v_tenant,
    full_name = coalesce(nullif(trim(p_owner), ''), full_name),
    updated_at = now()
  where id = auth.uid();

  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Profile row missing; sign up again or contact support';
  end if;

  select id into v_plan_id
  from public.subscription_plans
  where slug = 'free_trial'
  order by sort_order
  limit 1;

  select coalesce(nullif(pl.trial_days, 0), ps.default_trial_days, 14)
  into v_trial_days
  from public.platform_settings ps
  left join public.subscription_plans pl on pl.id = v_plan_id
  where ps.id = 1;

  v_trial_days := greatest(coalesce(v_trial_days, 14), 1);
  v_ends := now() + make_interval(days => v_trial_days);

  insert into public.subscriptions (
    tenant_id, plan, plan_id, status, lifecycle_status,
    payment_status, billing_interval, trial_ends_at, expires_at
  )
  values (
    v_tenant, 'free_trial', v_plan_id, 'active', 'trial',
    'trialing', 'trial', v_ends, v_ends
  )
  returning id into v_sub_id;

  begin
    insert into public.trial_history (tenant_id, subscription_id, action, days_added, reason, actor_id, ends_at)
    values (v_tenant, v_sub_id, 'started', v_trial_days, 'auto free trial on registration', auth.uid(), v_ends);
  exception when others then
    -- trial_history is best-effort; never fail registration on audit insert
    null;
  end;

  return v_tenant;
end;
$$;

-- ─── Backfill: unblock never-paid pharmacies stuck in pending / expired / no-end trial ───
do $$
declare
  v_trial_days int;
  v_plan_id uuid;
  v_ends timestamptz;
begin
  select coalesce(default_trial_days, 14) into v_trial_days
  from public.platform_settings where id = 1;
  v_trial_days := greatest(coalesce(v_trial_days, 14), 1);
  v_ends := now() + make_interval(days => v_trial_days);

  select id into v_plan_id
  from public.subscription_plans where slug = 'free_trial'
  order by sort_order limit 1;

  update public.subscriptions s
  set
    lifecycle_status = 'trial',
    status = 'active',
    payment_status = 'trialing',
    billing_interval = 'trial',
    plan = coalesce(nullif(s.plan, ''), 'free_trial'),
    plan_id = coalesce(s.plan_id, v_plan_id),
    trial_ends_at = v_ends,
    expires_at = v_ends,
    updated_at = now()
  where s.id in (
    select distinct on (sub.tenant_id) sub.id
    from public.subscriptions sub
    join public.tenants t on t.id = sub.tenant_id
    where t.suspended_at is null
      and t.deleted_at is null
      and sub.tenant_id not in (select tenant_id from public.payments where status = 'paid')
      and (
        coalesce(sub.lifecycle_status, 'trial') in ('pending', 'expired', 'cancelled')
        or (coalesce(sub.lifecycle_status, 'trial') = 'trial' and sub.trial_ends_at is null)
      )
    order by sub.tenant_id, sub.created_at desc
  );
end;
$$;
