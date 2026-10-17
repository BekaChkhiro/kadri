#!/usr/bin/env node
// Paid check of the short step texts (2026-10-17) on a deployed Worker.
//
//   set -a; source ~/.config/kadri/staging.env; set +a      # SESSION_SECRET → dev token
//   node scripts/text_check.mjs --url https://kadri-worker-staging.bekachkhirodze1.workers.dev [--cap 0.5] [--max-calls 3] [--token <session>]
//
// Exactly three calls, each reserved in scripts/ledger.json (gitignored) before
// it is sent and settled with the returned costUsd, like live_check.mjs:
//   1. POST /ai/parts  car-engine  „ზეთის შეცვლა მინდა“
//   2. POST /ai/steps  car-engine  same instructions, (1)'s parts, image
//   3. POST /ai/steps  sink-trap   „ნიჟარა ჟონავს“, the realism run's fixed parts
// Frames: Camera/assets/*.png → ≤768 px JPEG q88 (sips) in a temp directory.
// Results and a contract check: scripts/out/text_check.json. Secrets are never printed.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { devToken, devVarsSecret } from "./dev_token.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../../..");
const SINK_PARTS = join(repo, "experiments/som-test/out_realism/c_astra_tracking/sink/sink-trap/original/run_1/parts.json");
// Upper bounds per call, as in live_check.mjs.
const RESERVE = { parts: (16000 * 10 + 1200 * 50) / 1e6, steps: (20000 * 10 + 2200 * 50) / 1e6 };
const LIMITS = { object: 40, title: 40, text: 120, tip: 100, warn: 100, tools: 3, tool: 24, markerLabel: 24 };

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
if (!args.url) {
  console.error("--url is required");
  process.exit(2);
}
const base = args.url.replace(/\/$/, "");
const cap = Number(args.cap ?? 0.5);
const maxCalls = Number(args["max-calls"] ?? 3);

// ---------- ledger (live_check.mjs) ----------
const ledgerPath = join(here, "ledger.json");
const ledger = existsSync(ledgerPath) ? JSON.parse(readFileSync(ledgerPath, "utf8")) : { entries: [] };
const spent = () => ledger.entries.reduce((s, e) => s + e.charged_usd, 0);
const startSpent = spent();
const saveLedger = () => writeFileSync(ledgerPath, JSON.stringify({ ...ledger, spent_usd: spent() }, null, 2));
let calls = 0;
// The cap is for this run; earlier entries stay in the ledger as history.
function reserve(label, amount) {
  if (calls >= maxCalls) throw new Error(`max calls reached (${maxCalls})`);
  if (spent() - startSpent + amount > cap + 1e-12) {
    throw new Error(`cap: this run $${(spent() - startSpent).toFixed(4)} + reserve $${amount.toFixed(4)} > $${cap}`);
  }
  calls++;
  ledger.entries.push({ label, at: new Date().toISOString(), reserved_usd: amount, charged_usd: amount, status: "reserved_or_unknown" });
  saveLedger();
  return ledger.entries.length - 1;
}
function settle(ticket, cost) {
  if (typeof cost === "number" && Number.isFinite(cost) && cost >= 0) {
    Object.assign(ledger.entries[ticket], { charged_usd: cost, status: "usage_estimated" });
  }
  saveLedger();
}

// ---------- inputs ----------
const tmp = mkdtempSync(join(tmpdir(), "kadri-text-check-"));
function jpeg(slug) {
  const png = join(repo, "Camera/assets", `${slug}.png`);
  const jpg = join(tmp, `${slug}.jpg`);
  execFileSync("sips", ["-Z", "768", "-s", "format", "jpeg", "-s", "formatOptions", "88", png, "--out", jpg], { stdio: "ignore" });
  return readFileSync(jpg).toString("base64");
}

const token =
  args.token ??
  process.env.KADRI_SESSION_TOKEN ??
  devToken({ secret: devVarsSecret(), sub: `text-check-${Date.now()}`, email: "text-check@example.com" });
const headers = { "content-type": "application/json", authorization: `Bearer ${token}` };

async function partsCall(label, image, instructions) {
  const ticket = reserve(label, RESERVE.parts);
  const res = await fetch(`${base}/ai/parts`, { method: "POST", headers, body: JSON.stringify({ image, instructions }) });
  const body = await res.json();
  settle(ticket, res.ok ? body.costUsd : null);
  if (!res.ok) throw new Error(`${label}: ${res.status} ${JSON.stringify(body)}`);
  return body;
}

async function stepsCall(label, body) {
  const ticket = reserve(label, RESERVE.steps);
  const res = await fetch(`${base}/ai/steps`, { method: "POST", headers, body: JSON.stringify(body) });
  if (!res.ok) {
    settle(ticket, null);
    throw new Error(`${label}: ${res.status} ${await res.text()}`);
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
      events.push({ event: /^event: (.*)$/m.exec(raw)?.[1], data: JSON.parse(/^data: (.*)$/m.exec(raw)?.[1] ?? "null") });
    }
  }
  const done = events.find((e) => e.event === "done")?.data ?? null;
  settle(ticket, done?.costUsd ?? null);
  return {
    steps: events.filter((e) => e.event === "step").map((e) => e.data),
    done,
    error: events.find((e) => e.event === "error")?.data ?? null,
  };
}

// ---------- contract ----------
const len = (s) => [...(s ?? "")].length;
function stepIssues(s) {
  const issues = [];
  if (/^\s*\d/.test(s.title)) issues.push("title starts with a number");
  if (len(s.title) > LIMITS.title) issues.push(`title ${len(s.title)} > ${LIMITS.title}`);
  if (s.title.trim().split(/\s+/).length > 4) issues.push("title > 4 words");
  if (len(s.text) > LIMITS.text) issues.push(`text ${len(s.text)} > ${LIMITS.text}`);
  if (len(s.tip) > LIMITS.tip) issues.push(`tip ${len(s.tip)} > ${LIMITS.tip}`);
  if (len(s.warn) > LIMITS.warn) issues.push(`warn ${len(s.warn)} > ${LIMITS.warn}`);
  if (s.tools.length > LIMITS.tools) issues.push("tools > 3");
  if (s.tools.some((t) => len(t) > LIMITS.tool)) issues.push("tool > 24");
  if (s.focus.length && !s.markers.some((m) => s.focus.includes(m.part))) issues.push("no marker on focus");
  if (s.markers.some((m) => len(m.label) > LIMITS.markerLabel)) issues.push("marker label > 24");
  if (s.text.endsWith("…") || (s.warn ?? "").endsWith("…") || (s.tip ?? "").endsWith("…")) issues.push("clamped by the Worker");
  return issues;
}
const brief = (s) => ({ title: s.title, text: s.text, tip: s.tip, warn: s.warn, icon: s.icon ?? null, tools: s.tools, toolItems: s.toolItems ?? null, focus: s.focus, markers: s.markers, issues: stepIssues(s) });

// ---------- main ----------
const report = { at: new Date().toISOString(), base, cap, maxCalls };
try {
  const car = jpeg("car-engine");
  const sink = jpeg("sink-trap");
  const carInstructions = "ზეთის შეცვლა მინდა";

  const carParts = await partsCall("text_check/parts/car", car, carInstructions);
  report.carParts = { object: carParts.object, objectOk: len(carParts.object) <= LIMITS.object, parts: carParts.parts, costUsd: carParts.costUsd };
  console.log(`parts car: object=${carParts.object}, ${carParts.parts.length} parts, $${carParts.costUsd?.toFixed(4)}`);

  const carSteps = await stepsCall("text_check/steps/car", { object: carParts.object, parts: carParts.parts, instructions: carInstructions, image: car });
  report.carSteps = { steps: carSteps.steps.map(brief), unknownParts: carSteps.done?.unknownParts, costUsd: carSteps.done?.costUsd, error: carSteps.error };
  console.log(`steps car: ${carSteps.steps.length} steps, $${carSteps.done?.costUsd?.toFixed(4)}${carSteps.error ? ` ERROR ${carSteps.error.code}` : ""}`);

  const fixed = JSON.parse(readFileSync(SINK_PARTS, "utf8"));
  const sinkSteps = await stepsCall("text_check/steps/sink", {
    object: fixed.object,
    parts: fixed.parts.map((p) => ({ id: p.id, name: p.label, box: p.box })),
    instructions: "ნიჟარა ჟონავს",
    image: sink,
  });
  report.sinkSteps = { steps: sinkSteps.steps.map(brief), unknownParts: sinkSteps.done?.unknownParts, costUsd: sinkSteps.done?.costUsd, error: sinkSteps.error };
  console.log(`steps sink: ${sinkSteps.steps.length} steps, $${sinkSteps.done?.costUsd?.toFixed(4)}${sinkSteps.error ? ` ERROR ${sinkSteps.error.code}` : ""}`);
} catch (err) {
  report.error = String(err?.message ?? err);
  console.error(report.error);
  process.exitCode = 1;
} finally {
  rmSync(tmp, { recursive: true, force: true });
  report.calls = calls;
  report.runSpentUsd = spent() - startSpent;
  report.ledgerSpentUsd = spent();
  mkdirSync(join(here, "out"), { recursive: true });
  writeFileSync(join(here, "out/text_check.json"), JSON.stringify(report, null, 2));
  console.log(`calls=${calls} run=$${report.runSpentUsd.toFixed(4)} ledger=$${report.ledgerSpentUsd.toFixed(4)}`);
}
