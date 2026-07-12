-- KPMS DB-side benchmark — run AFTER seeding to measure the hot queries.
-- Run in Supabase SQL editor / psql. Compare BEFORE vs AFTER applying the RLS
-- InitPlan migration (20260712120000_rls_initplan_tenant_isolation_perf.sql).
--
-- What to look for
--   * Execution Time on each EXPLAIN — the headline number.
--   * "InitPlan" appearing for kpms_my_tenant_id() once the RLS opt is applied
--     (vs the bare function call being re-evaluated per row before it).
--   * Index scans (good) vs Seq Scans (bad) on tenant_id / updated_at.

-- Pick one real seeded tenant to profile as a tenant user would see it.
-- Replace with an actual id from: select id from public.tenants where name like 'LOADTEST — %' limit 1;
\set target_tenant '00000000-0000-0000-0000-000000000000'

-- 0) Make sure stats are current after a bulk seed.
analyze public.pharmacy_inventory;
analyze public.pharmacy_sales;

-- 1) Workspace pull — first page of inventory (mirrors KpmsSupabasePagedFetch, 800 rows).
explain (analyze, buffers, verbose)
select *
from public.pharmacy_inventory
where tenant_id = :'target_tenant'
order by id
limit 800;

-- 2) Incremental delta pull — sales changed in last 7 days (mirrors fetchForTenantSince).
explain (analyze, buffers)
select *
from public.pharmacy_sales
where tenant_id = :'target_tenant'
  and updated_at >= now() - interval '7 days'
order by updated_at
limit 800;

-- 3) Dashboard-style aggregate — total sales value for a tenant.
explain (analyze, buffers)
select count(*), coalesce(sum(total), 0)
from public.pharmacy_sales
where tenant_id = :'target_tenant';

-- 4) Cross-tenant leakage check (MUST return 0 rows under RLS as a tenant user;
--    run this connected as a seeded auth user, not as postgres/service_role).
--    select count(*) from public.pharmacy_sales where tenant_id <> auth_tenant;  -- expect 0

-- 5) Top time-consuming statements platform-wide (needs pg_stat_statements enabled).
select
  round(mean_exec_time::numeric, 2) as avg_ms,
  round(total_exec_time::numeric, 2) as total_ms,
  calls,
  left(query, 90) as query
from pg_stat_statements
order by total_exec_time desc
limit 20;
