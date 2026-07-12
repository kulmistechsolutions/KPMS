-- KPMS load-test cleanup — removes every synthetic tenant and its cascaded rows.
-- Safe because seeding names all tenants 'LOADTEST — …' and child rows cascade on
-- delete (tenant_id ... references public.tenants (id) on delete cascade).
-- Run as postgres / service_role.

begin;

delete from public.tenants where name like 'LOADTEST — %';

commit;

select
  (select count(*) from public.tenants where name like 'LOADTEST — %') as remaining_loadtest_tenants,
  (select count(*) from public.pharmacy_inventory) as inventory_rows_left,
  (select count(*) from public.pharmacy_sales)     as sales_rows_left;
