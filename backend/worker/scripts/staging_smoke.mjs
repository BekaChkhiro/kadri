#!/usr/bin/env node
// Short live smoke of /ai/ask and /ai/steps on staging (PAID, a few cents).
//
//   node scripts/staging_smoke.mjs ask     --image <photo> --out <dir> --box x0,y0,x1,y1 [--question "ეს რა არის?"]
//   node scripts/staging_smoke.mjs steps   --image <photo> --out <dir> --parts <parts.json> --instructions <request.json>
//                                          [--max-steps 2] [--provider gemini]
//   common: [--url <staging url>] [--staging-env ~/.config/kadri/staging.env] [--cap 0.05]
//
// The token is signed with SESSION_SECRET from --staging-env (never printed). The photo is
// resized to ≤768 px JPEG q88 with sips. `steps` stops reading after --max-steps step events
// to bound the cost. Writes <out>/<mode>.json with the response, wall time and cost.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { devToken } from "./dev_token.mjs";

const [mode, ...rest] = process.argv.slice(2);
const args = Object.fromEntries(rest.reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
if (!["ask", "steps"].includes(mode) || !args.image || !args.out) {
  console.error("usage: staging_smoke.mjs ask|steps --image <photo> --out <dir> …");
  process.exit(2);
}
const base = (args.url ?? "https://kadri-worker-staging.bekachkhirodze1.workers.dev").replace(/\/$/, "");
const cap = Number(args.cap ?? 0.05);
const out = resolve(args.out);
mkdirSync(out, { recursive: true });

function fileVar(path, name) {
  if (!existsSync(path)) return null;
  const line = readFileSync(path, "utf8").split("\n").find((l) => l.replace(/^export\s+/, "").startsWith(`${name}=`));
  return line ? line.replace(/^export\s+/, "").slice(name.length + 1).trim().replace(/^["']|["']$/g, "") : null;
}
const secret = fileVar((args["staging-env"] ?? "~/.config/kadri/staging.env").replace(/^~/, homedir()), "SESSION_SECRET");
if (!secret) { console.error("SESSION_SECRET not found in --staging-env"); process.exit(2); }
const token = devToken({ secret, sub: "smoke-2026-10-18", email: "smoke@example.com", ttl: 900 });

const jpg = join(out, "input.jpg");
execFileSync("sips", ["-Z", "768", "-s", "format", "jpeg", "-s", "formatOptions", "88", resolve(args.image), "--out", jpg], { stdio: "ignore" });
const image = readFileSync(jpg).toString("base64");
const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };

const started = performance.now();
let report;
if (mode === "ask") {
  const body = { image, question: args.question ?? "ეს რა არის?", box: args.box.split(",").map(Number), ...(args.provider && { provider: args.provider }) };
  const res = await fetch(`${base}/ai/${mode}`, { method: "POST", headers, body: JSON.stringify(body) });
  const json = await res.json().catch(() => null);
  report = { mode, status: res.status, wallMs: Math.round(performance.now() - started), request: { ...body, image: `<${jpg}>` }, response: json };
} else {
  const parts = JSON.parse(readFileSync(resolve(args.parts), "utf8"));
  const request = JSON.parse(readFileSync(resolve(args.instructions), "utf8"));
  const instructions = JSON.parse(request.prompt.slice(request.prompt.indexOf("\n") + 1));
  const capabilities = ["needs_answer", "needs_measurement", "summary", "tools_v2", "hands_v1", "check_photo"];
  const body = { object: parts.object, parts: parts.parts, instructions, image, capabilities, ...(args.provider && { provider: args.provider }) };
  const ctl = new AbortController();
  const res = await fetch(`${base}/ai/steps`, { method: "POST", headers: { ...headers, accept: "text/event-stream" }, body: JSON.stringify(body), signal: ctl.signal });
  const events = [];
  let stopped = false;
  if (res.ok && res.body) {
    const maxSteps = Number(args["max-steps"] ?? 2);
    const decoder = new TextDecoder();
    let buf = "";
    try {
      for await (const chunk of res.body) {
        buf += decoder.decode(chunk, { stream: true });
        let cut;
        while ((cut = buf.indexOf("\n\n")) >= 0) {
          const raw = buf.slice(0, cut);
          buf = buf.slice(cut + 2);
          const event = /^event: (.*)$/m.exec(raw)?.[1];
          const data = /^data: (.*)$/m.exec(raw)?.[1];
          if (!event) continue;
          events.push({ event, atMs: Math.round(performance.now() - started), data: data ? JSON.parse(data) : null });
        }
        if (events.filter((e) => e.event === "step").length >= maxSteps && !events.some((e) => e.event === "done")) {
          stopped = true;
          ctl.abort();
          break;
        }
        if (events.some((e) => e.event === "done" || e.event === "error")) break;
      }
    } catch (err) {
      if (!stopped) throw err;
    }
  }
  report = {
    mode, status: res.status, wallMs: Math.round(performance.now() - started), stoppedAfterSteps: stopped,
    request: { ...body, image: `<${jpg}>` }, events, ...(res.ok ? {} : { error: await res.text() }),
  };
}

writeFileSync(join(out, `${mode}.json`), JSON.stringify(report, null, 2));
const cost = report.response?.costUsd ?? report.events?.find((e) => e.event === "done")?.data?.costUsd ?? null;
console.log(`${mode}: HTTP ${report.status} wall ${report.wallMs} ms latencyMs ${report.response?.latencyMs ?? "-"} cost ${cost ?? "n/a (see D1 usage)"}`);
if (cost !== null && cost > cap) console.error(`cost ${cost} > cap ${cap}`);
