-- KPMS load-test seeding — synthetic tenants + proportional high-volume rows.
--
-- PURPOSE
--   Populate the two tables that dominate at scale (pharmacy_inventory, pharmacy_sales)
--   so you can measure query/RLS behaviour at 1k → 5k → 10k tenants with realistic row
--   counts, instead of estimating.
--
-- HOW TO RUN
--   Run in the Supabase SQL editor or psql as a role that BYPASSES RLS (postgres /
--   service_role) — RLS would otherwise block cross-tenant inserts.
--   ALWAYS run against a BRANCH / staging project, never production.
--
-- TUNE THESE
--   :n_tenants           how many synthetic tenants to create this run
--   :products_per_tenant rows in pharmacy_inventory per tenant
--   :sales_per_tenant    rows in pharmacy_sales per tenant
--   Example totals: 10000 tenants × 1000 products = 10M inventory rows;
--                   10000 tenants × 1000 sales    = 10M sales rows.
--
-- All synthetic tenants are named 'LOADTEST — …' so cleanup (03_cleanup.sql) is exact.

\set n_tenants 1000
\set products_per_tenant 1000
\set sales_per_tenant 1000

begin;

-- 1) Tenants ------------------------------------------------------------------
with new_tenants as (
  insert into public.tenants (name, owner_name, phone)
  select
    'LOADTEST — pharmacy ' || g,
    'Owner ' || g,
    '+2526' || lpad(g::text, 8, '0')
  from generate_series(1, :n_tenants) as g
  returning id
)
-- 2) Inventory (proportional) -------------------------------------------------
insert into public.pharmacy_inventory
  (tenant_id, client_id, name, form_type, quantity, buying_price, selling_price, minimum_stock_alert, updated_at)
select
  t.id,
  'lt-med-' || p,
  'Med ' || p,
  (array['tablet','syrup','capsule','injection'])[1 + (p % 4)],
  (10 + (p % 500)),
  round((0.5 + (p % 50))::numeric, 2),
  round((1.0 + (p % 80))::numeric, 2),
  5,
  now() - ((p % 90) || ' days')::interval
from new_tenants t
cross join generate_series(1, :products_per_tenant) as p;

-- 3) Sales (proportional) -----------------------------------------------------
-- Re-select the tenants we just created (name prefix is the stable key).
insert into public.pharmacy_sales
  (tenant_id, client_id, invoice_number, issued_at, customer_name, payment_method, subtotal, total, updated_at)
select
  t.id,
  'lt-sale-' || s,
  'LT-' || substr(t.id::text, 1, 8) || '-' || s,
  now() - ((s % 365) || ' days')::interval,
  'Walk-in',
  (array['cash','evc','zaad','card'])[1 + (s % 4)],
  round((1 + (s % 200))::numeric, 2),
  round((1 + (s % 200))::numeric, 2),
  now() - ((s % 365) || ' days')::interval
from public.tenants t
cross join generate_series(1, :sales_per_tenant) as s
where t.name like 'LOADTEST — %';

commit;

-- Quick sanity counts
select
  (select count(*) from public.tenants          where name like 'LOADTEST — %') as loadtest_tenants,
  (select count(*) from public.pharmacy_inventory) as inventory_rows,
  (select count(*) from public.pharmacy_sales)     as sales_rows;
