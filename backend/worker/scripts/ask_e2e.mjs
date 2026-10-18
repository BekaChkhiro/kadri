#!/usr/bin/env node
// Touch-and-ask E2E on staging: several POST /ai/ask calls from a cases file (PAID, ≈$0.002 each).
//
//   node scripts/ask_e2e.mjs --cases <cases.json> --paid yes [--url <staging url>]
//        [--staging-env ~/.config/kadri/staging.env] [--cap 0.30] [--reserve 0.01] [--provider gemini]
//
// cases.json: [{ name, image, out, box: [x0,y0,x1,y1], question, context?: { object, doneSteps, answers } }]
// (image/out relative to the cases file). The photo is resized to ≤1024 px JPEG q88 with sips. Calls run
// one by one; before each one the run stops if spent + --reserve would pass --cap (a call without costUsd
// counts as --reserve). Without `--paid yes` it only prints the plan and sends nothing. Writes <out>/ask-<slug of question>.json and prints one line per call.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { devToken } from "./dev_token.mjs";

const rest = process.argv.slice(2);
const args = Object.fromEntries(rest.reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
if (!args.cases) {
  console.error("usage: ask_e2e.mjs --cases <cases.json> [--paid yes] [--cap 0.30]");
  process.exit(2);
}
if (args.paid !== "yes") {
  const n = JSON.parse(readFileSync(resolve(args.cases), "utf8")).length;
  console.log(`dry run: ${n} /ai/ask calls planned, nothing sent (add --paid yes to spend, cap $${args.cap ?? 0.3})`);
  process.exit(0);
}
const base = (args.url ?? "https://kadri-worker-staging.bekachkhirodze1.workers.dev").replace(/\/$/, "");
const cap = Number(args.cap ?? 0.3);
const reserve = Number(args.reserve ?? 0.01);
const casesPath = resolve(args.cases);
const root = dirname(casesPath);
const cases = JSON.parse(readFileSync(casesPath, "utf8"));

function fileVar(path, name) {
  if (!existsSync(path)) return null;
  const line = readFileSync(path, "utf8").split("\n").find((l) => l.replace(/^export\s+/, "").startsWith(`${name}=`));
  return line ? line.replace(/^export\s+/, "").slice(name.length + 1).trim().replace(/^["']|["']$/g, "") : null;
}
const secret = fileVar((args["staging-env"] ?? "~/.config/kadri/staging.env").replace(/^~/, homedir()), "SESSION_SECRET");
if (!secret) { console.error("SESSION_SECRET not found in --staging-env"); process.exit(2); }
const token = devToken({ secret, sub: "ask-e2e-2026-10-18", email: "smoke@example.com", ttl: 1800 });
const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };

const slug = (q) => ({ "ეს რა არის?": "what", "რა ზომაა?": "size", "მოვხსნა?": "remove" })[q] ?? `q${Buffer.from(q).toString("hex").slice(0, 8)}`;
let spent = 0;
const summary = [];
for (const c of cases) {
  if (spent + reserve > cap) {
    console.error(`stop: spent $${spent.toFixed(4)} + reserve $${reserve} > cap $${cap}`);
    break;
  }
  const out = resolve(root, c.out);
  mkdirSync(out, { recursive: true });
  const jpg = join(out, "input.jpg");
  if (!existsSync(jpg)) {
    execFileSync("sips", ["-Z", "1024", "-s", "format", "jpeg", "-s", "formatOptions", "88", resolve(root, c.image), "--out", jpg], { stdio: "ignore" });
  }
  const body = {
    image: readFileSync(jpg).toString("base64"), question: c.question, box: c.box,
    ...(c.context && { context: c.context }), ...(args.provider && { provider: args.provider }),
  };
  const started = performance.now();
  const res = await fetch(`${base}/ai/ask`, { method: "POST", headers, body: JSON.stringify(body) });
  const json = await res.json().catch(() => null);
  const wallMs = Math.round(performance.now() - started);
  const cost = typeof json?.costUsd === "number" ? json.costUsd : reserve;
  spent += cost;
  const report = { name: c.name, status: res.status, wallMs, at: new Date().toISOString(), request: { ...body, image: `<${jpg}>` }, response: json };
  writeFileSync(join(out, `ask-${slug(c.question)}.json`), JSON.stringify(report, null, 2));
  summary.push({ name: c.name, question: c.question, status: res.status, wallMs, latencyMs: json?.latencyMs ?? null, costUsd: json?.costUsd ?? null });
  console.log(`${c.name} ${c.question}: HTTP ${res.status} wall ${wallMs} ms latencyMs ${json?.latencyMs ?? "-"} cost ${json?.costUsd ?? "n/a"} (total $${spent.toFixed(4)})`);
}
writeFileSync(join(root, "summary.json"), JSON.stringify({ base, spentUsd: spent, calls: summary }, null, 2));
