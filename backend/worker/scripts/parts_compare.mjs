#!/usr/bin/env node
// Pre-deploy regression check of POST /ai/parts (PAID): the deployed staging
// Worker ("old") against this checkout run locally ("new"), both compared with
// the realism run's parts.json reference. Run it before every deploy.
//
//   set -a; source <main checkout>/experiments/som-test/.env; set +a     # OPENAI_API_KEY for the local Worker
//   node scripts/parts_compare.mjs --realism <main checkout>/experiments/som-test/out_realism/c_astra_tracking \
//     [--old https://kadri-worker-staging.bekachkhirodze1.workers.dev] [--staging-env ~/.config/kadri/staging.env] \
//     [--new http://127.0.0.1:8798] [--port 8798] [--cap 0.30] [--max-calls 6]
//
// Old side: a dev token signed with SESSION_SECRET read from --staging-env.
// New side: without --new it writes OPENAI_API_KEY (and a random SESSION_SECRET
// if missing) into .dev.vars (gitignored), applies the local D1 migrations and
// starts `wrangler dev --local` (src/index.ts, guarded routes) like
// live_check.mjs; its token is signed with .dev.vars' SESSION_SECRET.
// Each call is reserved in scripts/ledger.json (gitignored) before it is sent
// and settled with the returned costUsd; the cap is for this run only. A retry
// inside the new Worker is not visible in costUsd: when wall time exceeds the
// reported latency by RETRY_GAP_MS the run is charged twice and flagged.
// Results: scripts/out/parts_compare.json and parts_compare_<scene>.png.
// Secrets and tokens are never printed.
import { spawn, execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { devToken } from "./dev_token.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const worker = resolve(here, "..");
const out = join(here, "out");
const SCENES = [
  { scene: "sink", slug: "sink-trap" },
  { scene: "car", slug: "car-engine" },
  { scene: "gym", slug: "gym-lat-pulldown" },
];
// Per attempt: ≤4k input tokens at $10/1M + 1200 output tokens at $50/1M (a
// parts call measures ≈1k input / ≈230 output, ≈$0.024).
const RESERVE = (4000 * 10 + 1200 * 50) / 1e6;
const RETRY_GAP_MS = 2500;
// Regression thresholds (docs/PARTS_REGRESSION_CHECK.md).
const MAX_COUNT_DELTA = 3;
const MIN_MEAN_IOU = 0.6;
// Background / region "parts" the prompt forbids.
// Matched at word starts, so „სიფონი“ (siphon) is not „ფონი“ (background).
const BACKGROUND = /^(კედ[ე]?ლ|იატაკ|ფონ|ზონ|ზედაპირ|wall|floor|background|zone|area|surface)/i;

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
if (!args.realism) {
  console.error("--realism <dir> is required (…/out_realism/c_astra_tracking)");
  process.exit(2);
}
const realism = resolve(args.realism);
const oldBase = (args.old ?? "https://kadri-worker-staging.bekachkhirodze1.workers.dev").replace(/\/$/, "");
const stagingEnv = (args["staging-env"] ?? "~/.config/kadri/staging.env").replace(/^~/, homedir());
const port = Number(args.port ?? 8798);
const newBase = (args.new ?? `http://127.0.0.1:${port}`).replace(/\/$/, "");
const cap = Number(args.cap ?? 0.3);
const maxCalls = Number(args["max-calls"] ?? 6);

// ---------- ledger (text_check.mjs) ----------
const ledgerPath = join(here, "ledger.json");
const ledger = existsSync(ledgerPath) ? JSON.parse(readFileSync(ledgerPath, "utf8")) : { entries: [] };
const spent = () => ledger.entries.reduce((s, e) => s + e.charged_usd, 0);
const startSpent = spent();
const saveLedger = () => writeFileSync(ledgerPath, JSON.stringify({ ...ledger, spent_usd: spent() }, null, 2));
let calls = 0;
function reserve(label) {
  if (calls >= maxCalls) throw new Error(`max calls reached (${maxCalls})`);
  if (spent() - startSpent + RESERVE > cap + 1e-12) {
    throw new Error(`cap: this run $${(spent() - startSpent).toFixed(4)} + reserve $${RESERVE.toFixed(4)} > $${cap}`);
  }
  calls++;
  ledger.entries.push({ label, at: new Date().toISOString(), reserved_usd: RESERVE, charged_usd: RESERVE, status: "reserved_or_unknown" });
  saveLedger();
  return ledger.entries.length - 1;
}
function settle(ticket, cost, status = "usage_estimated") {
  if (typeof cost === "number" && Number.isFinite(cost) && cost >= 0) {
    Object.assign(ledger.entries[ticket], { charged_usd: cost, status });
  }
  saveLedger();
}

// ---------- secrets ----------
function fileVar(path, name) {
  if (!existsSync(path)) return null;
  const line = readFileSync(path, "utf8").split("\n").find((l) => l.replace(/^export\s+/, "").startsWith(`${name}=`));
  return line ? line.replace(/^export\s+/, "").slice(name.length + 1).trim().replace(/^["']|["']$/g, "") : null;
}
function ensureDevVars(key) {
  const path = join(worker, ".dev.vars");
  const lines = existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((l) => l && !l.startsWith("OPENAI_API_KEY=")) : [];
  lines.push(`OPENAI_API_KEY=${key}`);
  if (!lines.some((l) => l.startsWith("SESSION_SECRET="))) lines.push(`SESSION_SECRET=${randomBytes(32).toString("hex")}`);
  writeFileSync(path, lines.join("\n") + "\n", { mode: 0o600 });
}

// ---------- geometry ----------
function iou(a, b) {
  const ix = Math.max(0, Math.min(a[2], b[2]) - Math.max(a[0], b[0]));
  const iy = Math.max(0, Math.min(a[3], b[3]) - Math.max(a[1], b[1]));
  const inter = ix * iy;
  return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter);
}
/** Label head: lowercased text before " — ", ",", "(" with punctuation dropped. */
const norm = (label) =>
  label.toLowerCase().split(/\s[—–-]\s|[,(;:]/)[0].replace(/[^\p{L}\p{N}\s]/gu, "").replace(/\s+/g, " ").trim();
/** Pairs equal label heads first, then the remaining parts greedily by best IoU (> 0). */
function match(a, b) {
  const pairs = [], usedA = new Set(), usedB = new Set();
  a.forEach((p, i) => {
    const j = b.findIndex((q, k) => !usedB.has(k) && norm(q.name) === norm(p.name));
    if (j >= 0) { usedA.add(i); usedB.add(j); pairs.push({ i, j, by: "label" }); }
  });
  const cand = [];
  a.forEach((p, i) => b.forEach((q, j) => { if (!usedA.has(i) && !usedB.has(j)) cand.push([iou(p.box, q.box), i, j]); }));
  cand.sort((x, y) => y[0] - x[0]);
  for (const [v, i, j] of cand) {
    if (v <= 0 || usedA.has(i) || usedB.has(j)) continue;
    usedA.add(i); usedB.add(j); pairs.push({ i, j, by: "box" });
  }
  const matched = pairs.map(({ i, j, by }) => ({ a: a[i].id, b: b[j].id, by, iou: iou(a[i].box, b[j].box), aName: a[i].name, bName: b[j].name }));
  return {
    pairs: matched,
    meanIou: mean(matched.map((m) => m.iou)),
    unmatchedA: a.filter((_, i) => !usedA.has(i)).map((p) => `${p.id} ${p.name}`),
    unmatchedB: b.filter((_, j) => !usedB.has(j)).map((p) => `${p.id} ${p.name}`),
  };
}
const mean = (xs) => (xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : null);
const background = (parts) =>
  parts.filter((p) => p.name.split(/[^\p{L}]+/u).some((w) => BACKGROUND.test(w)) || (p.box[2] - p.box[0]) * (p.box[3] - p.box[1]) > 0.6 * 1e6).map((p) => `${p.id} ${p.name}`);

// ---------- inputs ----------
mkdirSync(out, { recursive: true });
function frame({ scene, slug }) {
  const dir = join(realism, scene, slug, "original/run_1");
  const png = join(dir, "input.png");
  if (!existsSync(png)) throw new Error(`missing ${png}`);
  const jpg = join(out, `${scene}.jpg`);
  execFileSync("sips", ["-Z", "768", "-s", "format", "jpeg", "-s", "formatOptions", "88", png, "--out", jpg], { stdio: "ignore" });
  // The realism run's own instructions: request.prompt's second line is the step list.
  const request = JSON.parse(readFileSync(join(dir, "parts_request/request.json"), "utf8"));
  const instructions = JSON.parse(request.prompt.slice(request.prompt.indexOf("\n") + 1));
  const ref = JSON.parse(readFileSync(join(dir, "parts.json"), "utf8"));
  return {
    scene, png, jpg, instructions, image: readFileSync(jpg).toString("base64"),
    reference: { object: ref.object, parts: ref.parts.map((p) => ({ id: p.id, name: p.label, box: p.box })) },
  };
}

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

async function partsCall(side, base, token, f) {
  const ticket = reserve(`parts_compare/${side}/${f.scene}`);
  const t0 = performance.now();
  let res, body;
  try {
    res = await fetch(`${base}/ai/parts`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ image: f.image, instructions: f.instructions }),
    });
    body = await res.json();
  } catch (err) {
    settle(ticket, null);
    throw err;
  }
  const wallMs = performance.now() - t0;
  const retried = res.ok && side === "new" && wallMs - (body.latencyMs ?? wallMs) > RETRY_GAP_MS;
  if (res.ok) settle(ticket, retried ? body.costUsd * 2 : body.costUsd, retried ? "usage_estimated_retry_x2" : "usage_estimated");
  else settle(ticket, null);
  if (!res.ok) return { error: { status: res.status, body }, wallMs };
  return { object: body.object, parts: body.parts, costUsd: body.costUsd, latencyMs: body.latencyMs, wallMs, retried };
}

function draw(f, old, neu) {
  const spec = {
    image: f.png, out: join(out, `parts_compare_${f.scene}.png`),
    panels: [
      { title: `reference (${f.reference.parts.length})`, color: [40, 170, 60], parts: f.reference.parts },
      { title: `old staging (${old.parts?.length ?? "error"})`, color: [220, 50, 40], parts: old.parts ?? [] },
      { title: `new local (${neu.parts?.length ?? "error"})`, color: [40, 90, 230], parts: neu.parts ?? [] },
    ],
  };
  const py = `
import json, sys
from PIL import Image, ImageDraw
s = json.loads(sys.argv[1])
src = Image.open(s["image"]).convert("RGB")
w, h = src.size
top = 24
canvas = Image.new("RGB", (w * 3 + 20, h + top), "white")
for k, p in enumerate(s["panels"]):
    im = src.copy()
    d = ImageDraw.Draw(im)
    c = tuple(p["color"])
    for part in p["parts"]:
        x0, y0, x1, y1 = [v / 1000 for v in part["box"]]
        b = [x0 * w, y0 * h, x1 * w, y1 * h]
        d.rectangle(b, outline=c, width=3)
        tw = d.textlength(part["id"])
        d.rectangle([b[0], b[1], b[0] + tw + 6, b[1] + 13], fill=c)
        d.text((b[0] + 3, b[1]), part["id"], fill="white")
    canvas.paste(im, (k * (w + 10), top))
    ImageDraw.Draw(canvas).text((k * (w + 10) + 4, 6), p["title"], fill=c)
canvas.save(s["out"])
`;
  try {
    execFileSync("python3", ["-I", "-c", py, JSON.stringify(spec)], { stdio: ["ignore", "ignore", "pipe"] });
    return spec.out;
  } catch (err) {
    console.error(`draw ${f.scene}: ${String(err.stderr ?? err).slice(0, 300)}`);
    return null;
  }
}

/** Absolute flags for one side against the reference. */
function flags(side, vsRef) {
  if (!side.parts) return ["error"];
  const f = [];
  if (Math.abs(side.parts.length - side.refCount) > MAX_COUNT_DELTA) f.push("count_vs_reference");
  if (background(side.parts).length) f.push("background");
  if (vsRef?.meanIou == null || vsRef.meanIou < MIN_MEAN_IOU) f.push("iou_vs_reference");
  return f;
}

// ---------- main ----------
const key = process.env.OPENAI_API_KEY;
let child;
if (!args.new) {
  if (!key) {
    console.error("OPENAI_API_KEY is not set (set -a; source …/experiments/som-test/.env; set +a)");
    process.exit(2);
  }
  ensureDevVars(key);
  execFileSync("npx", ["wrangler", "d1", "migrations", "apply", "DB", "--local"], { cwd: worker, stdio: "ignore", env: { ...process.env, CI: "1" } });
  child = spawn("npx", ["wrangler", "dev", "--local", "--ip", "127.0.0.1", "--port", String(port)], {
    cwd: worker,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, OPENAI_API_KEY: "", SESSION_SECRET: "" },
  });
  const log = [];
  child.stdout.on("data", (d) => log.push(String(d)));
  child.stderr.on("data", (d) => log.push(String(d)));
  child.on("exit", () => writeFileSync(join(out, "parts_compare_wrangler.log"), log.join("")));
}

const stamp = Date.now();
const oldSecret = fileVar(stagingEnv, "SESSION_SECRET");
const newSecret = fileVar(join(worker, ".dev.vars"), "SESSION_SECRET");
if (!oldSecret) { console.error(`SESSION_SECRET not found in ${stagingEnv}`); process.exit(2); }
if (!newSecret) { console.error("SESSION_SECRET not found in .dev.vars"); process.exit(2); }
const oldToken = devToken({ secret: oldSecret, sub: `parts-compare-${stamp}`, email: "parts-compare@example.com" });
const newToken = devToken({ secret: newSecret, sub: `parts-compare-${stamp}`, email: "parts-compare@example.com" });

const report = { at: new Date().toISOString(), old: oldBase, new: newBase, cap, maxCalls, thresholds: { MAX_COUNT_DELTA, MIN_MEAN_IOU }, scenes: [] };
try {
  const oldHealth = await (await fetch(`${oldBase}/health`)).json().catch(() => null);
  report.oldHealth = oldHealth;
  await waitHealth(newBase, 90_000);
  for (const s of SCENES) {
    const f = frame(s);
    const ref = f.reference;
    const [old, neu] = [await partsCall("old", oldBase, oldToken, f), await partsCall("new", newBase, newToken, f)];
    const cmp = (side) => (side.parts ? match(ref.parts, side.parts) : null);
    const oldVsRef = cmp(old), newVsRef = cmp(neu);
    const newVsOld = old.parts && neu.parts ? match(old.parts, neu.parts) : null;
    const oldFlags = flags({ ...old, refCount: ref.parts.length }, oldVsRef);
    const newFlags = flags({ ...neu, refCount: ref.parts.length }, newVsRef);
    // A regression is what the new side breaks and the old one does not, or a gap between the two.
    const regression = newFlags.filter((x) => !oldFlags.includes(x));
    if (old.parts && neu.parts && Math.abs(neu.parts.length - old.parts.length) > MAX_COUNT_DELTA) regression.push("count_vs_old");
    if (newVsOld && (newVsOld.meanIou === null || newVsOld.meanIou < MIN_MEAN_IOU)) regression.push("iou_vs_old");
    if (neu.error) regression.push("new_error");
    const picture = draw(f, old, neu);
    const row = {
      scene: f.scene, instructions: f.instructions.map((i) => i.title), reference: ref,
      old: { ...old, background: old.parts ? background(old.parts) : null, vsReference: oldVsRef, flags: oldFlags },
      new: { ...neu, background: neu.parts ? background(neu.parts) : null, vsReference: newVsRef, flags: newFlags },
      newVsOld, regression, picture,
    };
    report.scenes.push(row);
    const fmt = (v) => (v === null || v === undefined ? "—" : v.toFixed(3));
    console.log(`${f.scene}: ref ${ref.parts.length} | old ${old.parts?.length ?? "ERR"} IoU ${fmt(oldVsRef?.meanIou)} ${old.wallMs.toFixed(0)}ms` +
      ` | new ${neu.parts?.length ?? "ERR"} IoU ${fmt(newVsRef?.meanIou)} ${neu.wallMs.toFixed(0)}ms${neu.retried ? " RETRY" : ""}` +
      ` | new↔old IoU ${fmt(newVsOld?.meanIou)} | regression: ${regression.join(",") || "none"}`);
  }
} catch (err) {
  report.error = String(err?.message ?? err);
  console.error(report.error);
  process.exitCode = 1;
} finally {
  report.calls = calls;
  report.runSpentUsd = spent() - startSpent;
  report.regression = report.error ? null : report.scenes.some((s) => s.regression.length > 0);
  writeFileSync(join(out, "parts_compare.json"), JSON.stringify(report, null, 2));
  console.log(`calls=${calls} run=$${report.runSpentUsd.toFixed(4)} regression=${report.regression}`);
  child?.kill("SIGINT");
}
