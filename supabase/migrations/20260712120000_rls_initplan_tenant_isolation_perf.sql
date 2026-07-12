-- RLS performance: wrap kpms_my_tenant_id() in a scalar subquery so PostgreSQL
-- evaluates it ONCE per statement (an InitPlan) instead of once per row.
--
-- Why this matters at scale
--   The tenant-isolation policies created in 20260523120000_pharmacy_operational_cloud.sql
--   use the predicate `tenant_id = public.kpms_my_tenant_id()`. Even though the helper is
--   marked STABLE, the planner re-invokes a bare function reference for every candidate row
--   during a sequential/large index scan. On the high-volume tables (sales, sale_items,
--   purchases, inventory) at millions of rows this dominates query time.
--
--   Rewriting the predicate as `tenant_id = (select public.kpms_my_tenant_id())` lets the
--   planner hoist the call into an InitPlan computed a single time and reused for all rows.
--   This is the pattern documented in Supabase's own RLS performance guide (measured up to
--   ~100x on large tables). Semantics are identical — same value, same isolation.
--
-- Scope
--   Only the 11 uniform tenant tables from the original generator (predicate is exactly
--   `tenant_id = kpms_my_tenant_id()`, no other clauses). Heterogeneous policies that also
--   filter on user_id / role are intentionally left for a separately reviewed pass.
--
-- Safety
--   * New migration — does not edit already-applied history.
--   * Idempotent: drops then recreates each policy.
--   * Tenant-isolation-critical. Apply on a Supabase branch first and verify with:
--       explain (analyze, buffers)
--       select count(*) from public.pharmacy_sales;   -- as an authenticated tenant user
--     Confirm the plan shows an InitPlan for kpms_my_tenant_id() and that cross-tenant
--     reads still return zero rows before promoting to production.

do $$
declare
  tbl text;
begin
  foreach tbl in array array[
    'pharmacy_inventory',
    'pharmacy_customers',
    'pharmacy_suppliers',
    'pharmacy_sales',
    'pharmacy_sale_items',
    'pharmacy_sale_returns',
    'pharmacy_purchases',
    'pharmacy_purchase_items',
    'pharmacy_purchase_returns',
    'pharmacy_transactions',
    'pharmacy_notifications'
  ]
  loop
    execute format('drop policy if exists %I_select on public.%I', tbl, tbl);
    execute format('drop policy if exists %I_insert on public.%I', tbl, tbl);
    execute format('drop policy if exists %I_update on public.%I', tbl, tbl);
    execute format('drop policy if exists %I_delete on public.%I', tbl, tbl);

    execute format(
      'create policy %I_select on public.%I for select to authenticated '
      'using (tenant_id = (select public.kpms_my_tenant_id()))',
      tbl, tbl
    );
    execute format(
      'create policy %I_insert on public.%I for insert to authenticated '
      'with check (tenant_id = (select public.kpms_my_tenant_id()))',
      tbl, tbl
    );
    execute format(
      'create policy %I_update on public.%I for update to authenticated '
      'using (tenant_id = (select public.kpms_my_tenant_id())) '
      'with check (tenant_id = (select public.kpms_my_tenant_id()))',
      tbl, tbl
    );
    execute format(
      'create policy %I_delete on public.%I for delete to authenticated '
      'using (tenant_id = (select public.kpms_my_tenant_id()))',
      tbl, tbl
    );
  end loop;
end;
$$;
