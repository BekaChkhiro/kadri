#!/usr/bin/env node
// Live check of /ai/parts and /ai/steps against the real OpenAI API (PAID).
//
//   set -a; source <path>/experiments/som-test/.env; set +a
//   node scripts/live_check.mjs [--runs 1] [--cap 3] [--port 8797] [--url http://127.0.0.1:8797] [--token <session>]
//
// The AI routes need a session: without --url it writes OPENAI_API_KEY (and a
// random SESSION_SECRET if missing) into .dev.vars (gitignored), applies the D1
// migrations locally, starts `wrangler dev --local` (src/index.ts) and signs a
// dev token with scripts/dev_token.mjs. With --url pass --token (or
// KADRI_SESSION_TOKEN); otherwise .dev.vars' SESSION_SECRET is used. Every call is reserved in
// scripts/ledger.json (gitignored) before it is sent and settled with the
// returned costUsd; nothing is sent once the cap would be exceeded.
// Results: scripts/out/live_check.json. The key is never printed.
import { spawn, execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { devToken, devVarsSecret } from "./dev_token.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const worker = resolve(here, "..");
const repo = resolve(worker, "../..");
let realism = join(repo, "experiments/som-test/out_realism/c_astra_tracking");
const SCENES = [
  { scene: "sink", slug: "sink-trap" },
  { scene: "car", slug: "car-engine" },
  { scene: "gym", slug: "gym-lat-pulldown" },
];
// Upper bounds per call: 16k input at $10/1M + max output at $50/1M (vision.py PRICES).
let RESERVE = { parts: (16000 * 10 + 1200 * 50) / 1e6, steps: (20000 * 10 + 2200 * 50) / 1e6 };

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
if (args.realism) realism = resolve(args.realism);
const provider = args.provider;
if (provider !== undefined && !["astra", "gemini"].includes(provider)) throw new Error("invalid --provider");
// Gemini: reserve two attempts (guarded retry), including all thinking/output tokens.
const geminiAttemptReserve = (16000 * 0.75 + 8192 * 3.75) / 1e6;
if (provider === "gemini") RESERVE = { parts: 2 * geminiAttemptReserve, steps: 2 * geminiAttemptReserve };
const runs = Number(args.runs ?? 1);
const cap = Number(args.cap ?? 3);
const port = Number(args.port ?? 8797);
let base = args.url ?? `http://127.0.0.1:${port}`;

// ---------- ledger ----------
const ledgerPath = join(here, "ledger.json");
const ledger = existsSync(ledgerPath) ? JSON.parse(readFileSync(ledgerPath, "utf8")) : { entries: [] };
const spent = () => ledger.entries.reduce((s, e) => s + e.charged_usd, 0);
const saveLedger = () => writeFileSync(ledgerPath, JSON.stringify({ spent_usd: spent(), cap_usd: cap, ...ledger }, null, 2));
function reserve(label, amount) {
  if (spent() + amount > cap + 1e-12) {
    throw new Error(`ledger cap: spent $${spent().toFixed(4)} + reserve $${amount.toFixed(4)} > $${cap}`);
  }
  ledger.entries.push({ label, at: new Date().toISOString(), reserved_usd: amount, charged_usd: amount, status: "reserved_or_unknown" });
  saveLedger();
  return ledger.entries.length - 1;
}
function settle(ticket, cost) {
  if (typeof cost === "number" && Number.isFinite(cost) && cost >= 0) {
    Object.assign(ledger.entries[ticket], { charged_usd: cost + (provider === "gemini" ? geminiAttemptReserve : 0), reported_usd: cost, status: provider === "gemini" ? "usage_plus_retry_reserve" : "usage_estimated" });
  }
  saveLedger();
}

// ---------- geometry ----------
function iou(a, b) {
  const ix = Math.max(0, Math.min(a[2], b[2]) - Math.max(a[0], b[0]));
  const iy = Math.max(0, Math.min(a[3], b[3]) - Math.max(a[1], b[1]));
  const inter = ix * iy;
  return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter);
}
/** Greedy one-to-one best-IoU pairs (variant_c.match_parts without the 0.5 threshold). */
function match(reference, observed) {
  const cand = [];
  reference.forEach((r, i) => observed.forEach((o, j) => cand.push([iou(r.box, o.box), i, j])));
  cand.sort((x, y) => y[0] - x[0]);
  const usedR = new Set(), usedO = new Set(), pairs = new Map();
  for (const [v, i, j] of cand) {
    if (v <= 0 || usedR.has(i) || usedO.has(j)) continue;
    usedR.add(i); usedO.add(j); pairs.set(i, { j, iou: v });
  }
  return reference.map((r, i) => {
    const p = pairs.get(i);
    return { ref: r.id, refLabel: r.label, got: p ? observed[p.j].id : null, gotName: p ? observed[p.j].name : null, iou: p ? p.iou : 0 };
  });
}
const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b), m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

// ---------- worker ----------
async function waitHealth(url, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      if ((await fetch(`${url}/health`)).ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`worker did not come up at ${url}`);
}
function ensureDevVars(key) {
  const path = join(worker, ".dev.vars");
  const lines = existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((l) => l && !l.startsWith("OPENAI_API_KEY=")) : [];
  lines.push(`OPENAI_API_KEY=${key}`);
  if (!lines.some((l) => l.startsWith("SESSION_SECRET="))) lines.push(`SESSION_SECRET=${randomBytes(32).toString("hex")}`);
  writeFileSync(path, lines.join("\n") + "\n", { mode: 0o600 });
}

// ---------- inputs ----------
const tmp = join(here, "out");
mkdirSync(tmp, { recursive: true });
function frame({ scene, slug }) {
  const dir = join(realism, scene, slug, "original/run_1");
  const png = join(dir, "input.png");
  if (!existsSync(png)) throw new Error(`missing ${png} — rsync it from the main checkout`);
  const jpg = join(tmp, `${scene}.jpg`);
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "90", png, "--out", jpg], { stdio: "ignore" });
  const request = JSON.parse(readFileSync(join(dir, "parts_request/request.json"), "utf8"));
  const instructions = JSON.parse(request.prompt.slice(request.prompt.indexOf("\n") + 1));
  const plan = JSON.parse(readFileSync(join(dir, "plan.json"), "utf8"));
  const pyMetrics = JSON.parse(readFileSync(join(dir, "parts_request/metrics.json"), "utf8"));
  return { scene, image: readFileSync(jpg).toString("base64"), instructions, plan, pySeconds: pyMetrics.seconds };
}

async function partsCall(f, run) {
  const ticket = reserve(`parts/${f.scene}/run_${run}`, RESERVE.parts);
  const t0 = performance.now();
  const res = await fetch(`${base}/ai/parts`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ image: f.image, instructions: f.instructions, ...(provider && { provider }) }),
  });
  const wallMs = performance.now() - t0;
  const body = await res.json();
  settle(ticket, res.ok ? body.costUsd : null);
  if (!res.ok) throw new Error(`/ai/parts ${f.scene}: ${res.status} ${JSON.stringify(body)}`);
  return { ...body, wallMs };
}

async function stepsCall(f, parts) {
  const ticket = reserve(`steps/${f.scene}`, RESERVE.steps);
  const t0 = performance.now();
  const res = await fetch(`${base}/ai/steps`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ object: parts.object, parts: parts.parts, instructions: f.instructions, image: f.image, ...(provider && { provider }) }),
  });
  if (!res.ok) {
    settle(ticket, null);
    throw new Error(`/ai/steps: ${res.status} ${await res.text()}`);
  }
  const events = [];
  const decoder = new TextDecoder();
  let buf = "";
  for await (const chunk of res.body) {
    buf += decoder.decode(chunk, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const raw = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const event = /^event: (.*)$/m.exec(raw)?.[1];
      const data = JSON.parse(/^data: (.*)$/m.exec(raw)?.[1] ?? "null");
      events.push({ event, data, atMs: performance.now() - t0 });
    }
  }
  const done = events.find((e) => e.event === "done");
  settle(ticket, done?.data.costUsd ?? null);
  return { events, totalMs: performance.now() - t0 };
}

// ---------- main ----------
const key = process.env.OPENAI_API_KEY;
let child;
if (!args.url) {
  if (!key) {
    console.error("OPENAI_API_KEY is not set (set -a; source …/experiments/som-test/.env; set +a)");
    process.exit(2);
  }
  ensureDevVars(key);
  execFileSync("npx", ["wrangler", "d1", "migrations", "apply", "DB", "--local"], { cwd: worker, stdio: "ignore", env: { ...process.env, CI: "1" } });
  child = spawn("npx", ["wrangler", "dev", "--local", "--ip", "127.0.0.1", "--port", String(port)], {
    cwd: worker,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, OPENAI_API_KEY: "" },
  });
  const log = [];
  child.stdout.on("data", (d) => log.push(String(d)));
  child.stderr.on("data", (d) => log.push(String(d)));
  child.on("exit", () => writeFileSync(join(tmp, "wrangler.log"), log.join("")));
}

// A fresh user per run, so earlier runs do not count towards DAILY_SESSION_LIMIT.
const token = args.token ?? process.env.KADRI_SESSION_TOKEN ?? devToken({ secret: devVarsSecret(), sub: `live-check-${Date.now()}`, email: "live-check@example.com" });

const report = { provider: provider ?? "astra", at: new Date().toISOString(), base, runs, cap, scenes: [], steps: null };
try {
  await waitHealth(base, 90_000);
  const frames = SCENES.map(frame);
  for (const f of frames) {
    const reference = f.plan.parts;
    const sceneRuns = [];
    for (let run = 1; run <= runs; run++) {
      const out = await partsCall(f, run);
      const matches = match(reference, out.parts);
      const matched = matches.filter((m) => m.got);
      sceneRuns.push({
        run, object: out.object, parts: out.parts, usage: out.usage, costUsd: out.costUsd,
        latencyMs: out.latencyMs, wallMs: out.wallMs, matches,
        meanIouAllReference: mean(matches.map((m) => m.iou)),
        meanIouMatched: mean(matched.map((m) => m.iou)),
        referenceCount: reference.length, observedCount: out.parts.length,
      });
      console.log(`parts ${f.scene} run ${run}: ${out.parts.length} parts (python ${reference.length}), ` +
        `meanIoU(all ref)=${sceneRuns.at(-1).meanIouAllReference.toFixed(3)}, ` +
        `latency=${out.latencyMs}ms wall=${out.wallMs.toFixed(0)}ms cost=$${out.costUsd?.toFixed(4)}`);
      for (const m of matches) console.log(`   ${m.ref} → ${m.got ?? "—"}  IoU ${m.iou.toFixed(3)}  ${m.refLabel.slice(0, 50)} ↔ ${(m.gotName ?? "").slice(0, 50)}`);
    }
    report.scenes.push({ scene: f.scene, pythonPartsSeconds: f.pySeconds, runs: sceneRuns, firstRunParts: sceneRuns[0] });
  }

  const sink = frames[0];
  const sinkParts = report.scenes[0].runs[0];
  const st = await stepsCall(sink, sinkParts);
  const stepEvents = st.events.filter((e) => e.event === "step");
  const done = st.events.find((e) => e.event === "done");
  const error = st.events.find((e) => e.event === "error");
  report.steps = {
    scene: "sink",
    events: st.events.map((e) => ({ event: e.event, atMs: e.atMs, index: e.data?.index, title: e.data?.title, focus: e.data?.focus })),
    firstStepMs: stepEvents[0]?.atMs ?? null,
    secondStepMs: stepEvents[1]?.atMs ?? null,
    firstBeforeSecond: stepEvents.length > 1 && stepEvents[0].atMs < stepEvents[1].atMs,
    serverFirstStepMs: done?.data.firstStepMs ?? null,
    totalMs: st.totalMs,
    done: done?.data ?? null,
    error: error?.data ?? null,
    steps: stepEvents.map((e) => e.data),
  };
  console.log(`steps sink: ${stepEvents.length} step events, first at ${report.steps.firstStepMs?.toFixed(0)}ms, ` +
    `second at ${report.steps.secondStepMs?.toFixed(0)}ms, done at ${st.totalMs.toFixed(0)}ms, cost=$${done?.data.costUsd?.toFixed(4)}` +
    (error ? ` ERROR ${JSON.stringify(error.data)}` : ""));
} catch (err) {
  report.error = String(err?.message ?? err);
  console.error(report.error);
  process.exitCode = 1;
} finally {
  const all = report.scenes.flatMap((s) => s.runs);
  report.summary = {
    meanIouAllReference: mean(all.map((r) => r.meanIouAllReference)),
    meanIouMatched: mean(all.map((r) => r.meanIouMatched)),
    p50PartsLatencyMs: median(all.map((r) => r.latencyMs)),
    p50PartsWallMs: median(all.map((r) => r.wallMs)),
    ledgerSpentUsd: spent(),
  };
  writeFileSync(join(tmp, provider ? `live_check_${provider}.json` : "live_check.json"), JSON.stringify(report, null, 2));
  console.log("summary", JSON.stringify(report.summary));
  child?.kill("SIGINT");
}
