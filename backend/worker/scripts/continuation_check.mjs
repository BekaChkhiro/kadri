#!/usr/bin/env node
// Paid check of the multi-photo continuation (2026-10-17) on a deployed Worker.
//
//   set -a; source ~/.config/kadri/staging.env; set +a      # SESSION_SECRET → dev token
//   node scripts/continuation_check.mjs --url https://kadri-worker-staging.bekachkhirodze1.workers.dev [--cap 0.60] [--max-calls 6] [--token <session>]
//
// At most six calls, each reserved in scripts/ledger.json (gitignored) before
// it is sent and settled with the returned costUsd, like text_check.mjs:
//   a. POST /ai/parts  car-engine  „ზეთი შევამოწმო“
//   b. POST /ai/steps  car-engine  same photo                → expected complete
//   c. POST /ai/parts  sink-trap   „ნიჟარა ჟონავს“
//   d. POST /ai/steps  sink-trap                             → expected needs_photo (gasket)
//   e. POST /ai/parts  sink-trap   context round 2 from (d)  — only if (d) is needs_photo and the cap allows
//   f. POST /ai/steps  round 2                               → expected complete
// (e)/(f) reuse sink-trap.png: there is no photo of the removed trap.
//
// --phase 2 (two steps calls, no parts call; `--cap` is this run's share):
//   5. POST /ai/steps  sink-trap  „სიფონის შუასადები შევცვალო“, the realism run's fixed parts → expected needs_photo
//   6. POST /ai/steps  same, context round 2 from (5)       — only if (5) is needs_photo → expected complete
// Results of phase 2: scripts/out/continuation_check_phase2.json.
// Frames: Camera/assets/*.png → ≤768 px JPEG q88 (sips) in a temp directory.
// Results: scripts/out/continuation_check.json. Secrets are never printed.
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

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
if (!args.url) {
  console.error("--url is required");
  process.exit(2);
}
const base = args.url.replace(/\/$/, "");
const cap = Number(args.cap ?? 0.6);
const phase = Number(args.phase ?? 1);
const maxCalls = Math.min(phase === 2 ? 2 : 6, Number(args["max-calls"] ?? 6));

// ---------- ledger (live_check.mjs) ----------
const ledgerPath = join(here, "ledger.json");
const ledger = existsSync(ledgerPath) ? JSON.parse(readFileSync(ledgerPath, "utf8")) : { entries: [] };
const spent = () => ledger.entries.reduce((s, e) => s + e.charged_usd, 0);
const startSpent = spent();
const saveLedger = () => writeFileSync(ledgerPath, JSON.stringify({ ...ledger, spent_usd: spent() }, null, 2));
let calls = 0;
const canReserve = (amount) => calls < maxCalls && spent() - startSpent + amount <= cap + 1e-12;
// The cap is for this run; earlier entries stay in the ledger as history.
function reserve(label, amount) {
  if (calls >= maxCalls) throw new Error(`max calls reached (${maxCalls})`);
  if (!canReserve(amount)) {
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
const tmp = mkdtempSync(join(tmpdir(), "kadri-continuation-check-"));
function jpeg(slug) {
  const png = join(repo, "Camera/assets", `${slug}.png`);
  const jpg = join(tmp, `${slug}.jpg`);
  execFileSync("sips", ["-Z", "768", "-s", "format", "jpeg", "-s", "formatOptions", "88", png, "--out", jpg], { stdio: "ignore" });
  return readFileSync(jpg).toString("base64");
}

const token =
  args.token ??
  process.env.KADRI_SESSION_TOKEN ??
  devToken({ secret: devVarsSecret(), sub: `continuation-check-${Date.now()}`, email: "continuation-check@example.com" });
const headers = { "content-type": "application/json", authorization: `Bearer ${token}` };

async function partsCall(label, body) {
  const ticket = reserve(label, RESERVE.parts);
  const res = await fetch(`${base}/ai/parts`, { method: "POST", headers, body: JSON.stringify(body) });
  const out = await res.json();
  settle(ticket, res.ok ? out.costUsd : null);
  if (!res.ok) throw new Error(`${label}: ${res.status} ${JSON.stringify(out)}`);
  return out;
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

// Full parts (with boxes), so a later --phase 2 run can reuse them.
const partsBrief = (p) => ({ object: p.object, parts: p.parts, costUsd: p.costUsd, latencyMs: p.latencyMs });
const stepsBrief = (s, expected) => ({
  expected,
  continuation: s.done?.continuation ?? null,
  ok: s.done?.continuation?.kind === expected,
  steps: s.steps.map((x) => ({ title: x.title, text: x.text, focus: x.focus })),
  unknownParts: s.done?.unknownParts,
  costUsd: s.done?.costUsd,
  latencyMs: s.done?.latencyMs,
  error: s.error,
});
const show = (key, r) =>
  console.log(
    `${key}: ${r.steps.length} steps [${r.steps.map((s) => s.title).join(" | ")}] → ${JSON.stringify(r.continuation)} (expected ${r.expected}) $${r.costUsd?.toFixed(4)}${r.error ? ` ERROR ${r.error.code}` : ""}`,
  );

// ---------- main ----------
const report = { at: new Date().toISOString(), base, cap, maxCalls, phase };
async function phase2() {
  const sink = jpeg("sink-trap");
  const instructions = "სიფონის შუასადები შევცვალო";
  const fixed = JSON.parse(readFileSync(SINK_PARTS, "utf8"));
  const parts = fixed.parts.map((p) => ({ id: p.id, name: p.label, box: p.box }));
  report.parts = { source: "out_realism sink-trap run_1 (fixed)", object: fixed.object, parts: parts.map((p) => `${p.id} ${p.name}`) };

  const five = await stepsCall("continuation_check/5/steps/sink-gasket", { object: fixed.object, parts, instructions, image: sink });
  report.five = stepsBrief(five, "needs_photo");
  show("5", report.five);
  const need = five.done?.continuation;
  if (need?.kind !== "needs_photo") {
    report.skipped = "6: (5) was not needs_photo";
    return;
  }
  // Same photo and parts: no photo of the removed trap, and no round-2 parts call (budget).
  const context = { round: 2, photoPrompt: need.prompt, doneSteps: five.steps.map((s) => s.title), previousObject: fixed.object };
  report.context = context;
  const six = await stepsCall("continuation_check/6/steps/sink-gasket-r2", { object: fixed.object, parts, instructions, image: sink, context });
  report.six = stepsBrief(six, "complete");
  report.six.repeats = six.steps.map((s) => s.title).filter((t) => context.doneSteps.includes(t));
  show("6", report.six);
}

try {
  if (phase === 2) {
    await phase2();
  } else {
    const car = jpeg("car-engine");
    const sink = jpeg("sink-trap");
    const carInstructions = "ზეთი შევამოწმო";
    const sinkInstructions = "ნიჟარა ჟონავს";

    const a = await partsCall("continuation_check/a/parts/car", { image: car, instructions: carInstructions });
    report.a = partsBrief(a);
    console.log(`a: object=${a.object}, ${a.parts.length} parts, $${a.costUsd?.toFixed(4)}`);

    const b = await stepsCall("continuation_check/b/steps/car", { object: a.object, parts: a.parts, instructions: carInstructions, image: car });
    report.b = stepsBrief(b, "complete");
    show("b", report.b);

    const c = await partsCall("continuation_check/c/parts/sink", { image: sink, instructions: sinkInstructions });
    report.c = partsBrief(c);
    console.log(`c: object=${c.object}, ${c.parts.length} parts, $${c.costUsd?.toFixed(4)}`);

    const d = await stepsCall("continuation_check/d/steps/sink", { object: c.object, parts: c.parts, instructions: sinkInstructions, image: sink });
    report.d = stepsBrief(d, "needs_photo");
    show("d", report.d);

    const need = d.done?.continuation;
    if (need?.kind !== "needs_photo") {
      report.skipped = "e/f: (d) was not needs_photo";
    } else if (!canReserve(RESERVE.parts)) {
      report.skipped = "e/f: cap";
    } else {
      // Same sink-trap.png: there is no photo of the removed trap.
      const context = { round: 2, photoPrompt: need.prompt, doneSteps: d.steps.map((s) => s.title), previousObject: c.object };
      report.context = context;
      const e = await partsCall("continuation_check/e/parts/sink-r2", { image: sink, instructions: sinkInstructions, context });
      report.e = partsBrief(e);
      console.log(`e: object=${e.object}, ${e.parts.length} parts, $${e.costUsd?.toFixed(4)}`);
      if (!canReserve(RESERVE.steps)) {
        report.skipped = "f: cap";
      } else {
        const f = await stepsCall("continuation_check/f/steps/sink-r2", {
          object: e.object,
          parts: e.parts,
          instructions: sinkInstructions,
          image: sink,
          context,
        });
        report.f = stepsBrief(f, "complete");
        show("f", report.f);
      }
    }
  }
  if (report.skipped) console.log(`skipped ${report.skipped}`);
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
  writeFileSync(join(here, phase === 2 ? "out/continuation_check_phase2.json" : "out/continuation_check.json"), JSON.stringify(report, null, 2));
  console.log(`calls=${calls} run=$${report.runSpentUsd.toFixed(4)} ledger=$${report.ledgerSpentUsd.toFixed(4)}`);
}
