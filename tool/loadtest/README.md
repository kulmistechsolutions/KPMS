# KPMS Load & Performance Testing Kit

A runnable harness to **measure** whether KPMS holds up at 10,000 pharmacies / millions of
rows — instead of estimating. Nobody can prove the 10k target from code inspection; you
prove it by seeding a realistic dataset, driving load, and reading the numbers.

> **Run everything against a Supabase branch or staging project — never production.**
> Seeding writes millions of rows; load tests hammer the API; both distort a live DB.

## Files

| File | What it does |
|------|--------------|
| `01_seed_tenants.sql` | Creates N synthetic `LOADTEST — …` tenants with proportional inventory + sales rows. |
| `02_benchmark_queries.sql` | `EXPLAIN (ANALYZE)` on the hot queries + `pg_stat_statements` top-20. |
| `k6_api_load.js` | Ramps virtual users (1k → 5k → 10k) against the real auth-gate + workspace-pull endpoints. |
| `03_cleanup.sql` | Deletes all synthetic tenants (child rows cascade). |

## Procedure

### 1. Seed in stages
Run `01_seed_tenants.sql` three times, raising `:n_tenants` each pass: **1000 → 5000 → 10000**.
At the largest stage with `products_per_tenant = 1000` and `sales_per_tenant = 1000` you land
at ~10M inventory rows and ~10M sales rows — the target scale.

### 2. Measure the database (the real bottleneck at scale)
Before **and** after applying the RLS InitPlan migration
(`supabase/migrations/20260712120000_rls_initplan_tenant_isolation_perf.sql`), run
`02_benchmark_queries.sql`. Record for each query:

- **Execution Time** (the headline).
- **Plan shape** — index scan on `(tenant_id, updated_at)` = good; `Seq Scan` = missing/unused index.
- **InitPlan** — after the RLS opt, `kpms_my_tenant_id()` should appear as a once-per-statement
  InitPlan rather than a per-row call. This is where the ~100× on large tables comes from.

Enable `pg_stat_statements` (Supabase: Database → Extensions) so query #5 can rank the
platform's most expensive statements.

### 3. Drive API load
Install [k6](https://k6.io), pre-create test auth users on seeded tenants, then:

```bash
k6 run -e SUPABASE_URL=https://<ref>.supabase.co \
       -e ANON_KEY=<anon_key> \
       -e TEST_EMAIL=<seeded_user_email> \
       -e TEST_PASSWORD=<password> \
       tool/loadtest/k6_api_load.js
```

The script exercises the three calls that gate every session start and navigation:
`kpms_my_permission_profile`, `get_my_pharmacy_operational_status`, and the first
inventory page. 10k VUs needs a strong k6 host or distributed/k6-cloud execution —
validate at 1k first.

### 4. Watch the resource ceiling while load runs
On the Supabase dashboard (Reports → Database / API) capture during each ramp stage:

| Metric | Where | Watch for |
|--------|-------|-----------|
| CPU % | Database report | sustained >80% = compute-bound |
| RAM / cache hit | Database report | cache hit ratio dropping <95% |
| Connections | Database report | approaching pooler limit = need Supavisor tuning |
| API latency p95/p99 | k6 output + API report | vs the thresholds in `k6_api_load.js` |
| Error rate | k6 `http_req_failed` | must stay <1% |

### 5. Client-side profiling (Flutter)
Separate from server load — profile the app itself:

```bash
flutter run --profile        # then open DevTools
```

- **Performance / frame chart** — drive POS, inventory list, dashboard; look for frames
  over 16ms (jank) and rebuild storms.
- **CPU profiler** — record during a workspace bootstrap and a large list scroll.
- **Memory** — watch for growth across navigation cycles (leaked controllers/streams).

## Pass/fail budget (starting SLOs — tighten to your needs)

| Signal | Target |
|--------|--------|
| Auth-gate RPC p95 | < 400 ms |
| Workspace first-page pull p95 | < 1.5 s |
| API error rate under peak | < 1% |
| DB CPU at 10k-tenant steady load | < 80% sustained |
| Client frame time (POS, list scroll) | < 16 ms (60 FPS) |

## Interpreting results → action

- **Seq Scan on a hot query** → add/adjust a composite index; re-`ANALYZE`.
- **Function re-eval per row in EXPLAIN** → apply the RLS InitPlan migration.
- **CPU-bound at 5k** before 10k → scale compute tier and/or add read replicas for reports.
- **Connection exhaustion** → tune Supavisor pool size; ensure the app isn't over-opening.
- **Client jank without server load** → `RepaintBoundary`, `const`, list virtualization on the
  offending screen (profile first, optimize the proven hot widget).
