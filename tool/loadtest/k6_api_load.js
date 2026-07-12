// KPMS API load test — drives the real Supabase endpoints the app hits on every
// session start and navigation, under a ramping virtual-user load.
//
// Run:
//   k6 run -e SUPABASE_URL=https://xxxx.supabase.co \
//          -e ANON_KEY=<anon_key> \
//          -e TEST_EMAIL=loadtest1@example.com \
//          -e TEST_PASSWORD=... \
//          tool/loadtest/k6_api_load.js
//
// Provisioning the tenant JWT
//   RLS scopes every request to the caller's tenant, so you need a REAL signed-in
//   user that belongs to a seeded tenant. setup() below signs in one test user via
//   GoTrue and reuses its access token. To exercise many tenants concurrently,
//   pre-create N test auth users (one per seeded tenant) and load their tokens from
//   a file / array instead of the single sign-in here.
//
// Point this at a BRANCH / staging project. Never load-test production.

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const SUPABASE_URL = __ENV.SUPABASE_URL;
const ANON_KEY = __ENV.ANON_KEY;

const permGate = new Trend('gate_permission_ms', true);
const opGate = new Trend('gate_operational_ms', true);
const pull = new Trend('workspace_pull_ms', true);

// Ramp the requested 1k → 5k → 10k concurrency stages.
// Note: 10k VUs needs a beefy k6 host (or distributed k6). Start smaller to validate.
export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 1000 },
        { duration: '3m', target: 1000 },
        { duration: '2m', target: 5000 },
        { duration: '3m', target: 5000 },
        { duration: '2m', target: 10000 },
        { duration: '3m', target: 10000 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    // Pass/fail budget — tighten to your SLOs.
    http_req_failed: ['rate<0.01'],           // <1% errors
    gate_permission_ms: ['p(95)<400'],        // auth gate p95 < 400ms
    gate_operational_ms: ['p(95)<400'],
    workspace_pull_ms: ['p(95)<1500'],        // first inventory page p95 < 1.5s
  },
};

export function setup() {
  const res = http.post(
    `${SUPABASE_URL}/auth/v1/token?grant_type=password`,
    JSON.stringify({ email: __ENV.TEST_EMAIL, password: __ENV.TEST_PASSWORD }),
    { headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' } }
  );
  check(res, { 'signed in': (r) => r.status === 200 });
  const body = res.json();
  return { token: body.access_token };
}

export default function (data) {
  const headers = {
    apikey: ANON_KEY,
    Authorization: `Bearer ${data.token}`,
    'Content-Type': 'application/json',
  };

  // 1) Permission gate RPC (runs inside the router redirect on every navigation).
  let r = http.post(`${SUPABASE_URL}/rest/v1/rpc/kpms_my_permission_profile`, '{}', { headers });
  permGate.add(r.timings.duration);
  check(r, { 'perm gate ok': (x) => x.status === 200 });

  // 2) Operational-status gate RPC.
  r = http.post(`${SUPABASE_URL}/rest/v1/rpc/get_my_pharmacy_operational_status`, '{}', { headers });
  opGate.add(r.timings.duration);
  check(r, { 'op gate ok': (x) => x.status === 200 });

  // 3) Workspace pull — first inventory page (RLS scopes to caller's tenant).
  r = http.get(
    `${SUPABASE_URL}/rest/v1/pharmacy_inventory?select=*&order=id&limit=800`,
    { headers }
  );
  pull.add(r.timings.duration);
  check(r, { 'pull ok': (x) => x.status === 200 });

  sleep(1);
}
