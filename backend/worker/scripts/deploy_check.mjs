#!/usr/bin/env node
// Free smoke check of a deployed Worker (no AI calls, no auth).
//
//   node scripts/deploy_check.mjs https://kadri-worker-staging.bekachkhirodze1.workers.dev [--env staging]
//
// Checks: GET /health → 200 {ok:true, env}; POST /ai/parts without a session →
// 401 JSON; GET /sessions without a session → 401 JSON. Exits 1 on any failure.
const args = process.argv.slice(2);
const url = args.find((a) => !a.startsWith("--"))?.replace(/\/+$/, "");
const envIdx = args.indexOf("--env");
const expectEnv = envIdx >= 0 ? args[envIdx + 1] : null;
if (!url) {
  console.error("usage: node scripts/deploy_check.mjs <worker-url> [--env staging]");
  process.exit(2);
}

async function call(method, path, body) {
  const t0 = performance.now();
  const res = await fetch(`${url}${path}`, {
    method,
    headers: body ? { "content-type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {}
  return { status: res.status, type: res.headers.get("content-type") ?? "", json, text, ms: Math.round(performance.now() - t0) };
}

const checks = [
  {
    name: "GET /health",
    run: () => call("GET", "/health"),
    ok: (r) => r.status === 200 && r.json?.ok === true && (!expectEnv || r.json?.env === expectEnv),
  },
  {
    name: "POST /ai/parts (no auth)",
    run: () => call("POST", "/ai/parts", { image: "", instructions: "" }),
    ok: (r) => r.status === 401 && r.json !== null && r.type.includes("application/json"),
  },
  {
    name: "GET /sessions (no auth)",
    run: () => call("GET", "/sessions"),
    ok: (r) => r.status === 401 && r.json !== null && r.type.includes("application/json"),
  },
];

let failed = 0;
for (const c of checks) {
  try {
    const r = await c.run();
    const pass = c.ok(r);
    if (!pass) failed++;
    console.log(`${pass ? "PASS" : "FAIL"}  ${c.name}  ${r.status} ${r.ms}ms  ${r.text.slice(0, 120)}`);
  } catch (err) {
    failed++;
    console.log(`FAIL  ${c.name}  ${err.message}`);
  }
}
console.log(failed ? `${failed} check(s) failed` : "all checks passed");
process.exit(failed ? 1 : 0);
