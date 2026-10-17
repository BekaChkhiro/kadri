/// <reference types="vite/client" />
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import usageSql from "../migrations/0002_usage.sql?raw";
import type { Env } from "../src/env";
import { router } from "../src/index";
import { recordUsage } from "../src/limits";
import { issueSession } from "../src/session";
import { readSse } from "../src/sse";
import { b64, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";
import { env, migrate, testEnv } from "./auth-helpers";

const aiEnv: Env = { ...testEnv, AI_PROVIDER: "astra", OPENAI_API_KEY: "test-key" };
const instructions = [{ title: "შეამოწმე ზეთი", text: "ამოიღე საზომი." }];
const partsResult = { object: "ძრავი", parts: [{ label: "ზეთის საზომი", box: [100, 100, 300, 400] }] };
const parts = [{ id: "p1", name: "ზეთის საზომი", box: [100, 100, 300, 400] }];
const stepsResult = {
  steps: [
    {
      title: "შეამოწმე ზეთი",
      text: "ამოიღე საზომი და შეხედე დონეს.",
      focus: ["p1"],
      avoid: [],
      markers: [],
      arrows: [{ part: "p1", type: "rotate", dir: "cw" }],
      tools: [],
      tip: null,
      warn: null,
    },
  ],
  unknown_parts: [],
};
// responseBody usage: 3 normal + 1024 cached input, 227 output at gpt-6-astra prices.
const COST = (3 * 10 + 1024 * 1 + 227 * 50) / 1e6;

interface UsageDbRow {
  stage: string;
  status: string;
  session_id: string | null;
  model: string;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
}

async function token(sub: string): Promise<string> {
  return (await issueSession(testEnv, { sub, email: `${sub}@example.com` })).sessionToken;
}

async function send(path: string, init: RequestInit, overrides: Partial<Env> = {}): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await router.handle(new Request(`http://example.com${path}`, init), { ...aiEnv, ...overrides }, ctx);
  // Drain SSE bodies first: steps usage is recorded via waitUntil once the stream ends.
  const isSse = (res.headers.get("content-type") ?? "").startsWith("text/event-stream");
  const body = isSse ? await res.text() : null;
  await waitOnExecutionContext(ctx);
  return body === null ? res : new Response(body, { status: res.status, headers: res.headers });
}

function post(path: string, body: unknown, auth?: string, overrides: Partial<Env> = {}): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (auth) headers.authorization = `Bearer ${auth}`;
  return send(path, { method: "POST", headers, body: JSON.stringify(body) }, overrides);
}

async function usageOf(userId: string): Promise<UsageDbRow[]> {
  const { results } = await env.DB.prepare(
    "SELECT stage, status, session_id, model, input_tokens, output_tokens, cost_usd FROM usage WHERE user_id = ? ORDER BY id",
  )
    .bind(userId)
    .all<UsageDbRow>();
  return results;
}

async function events(res: Response) {
  const out: Array<{ event: string | null; data: any }> = [];
  for await (const m of readSse(res.body!)) out.push({ event: m.event, data: JSON.parse(m.data) });
  return out;
}

const enc = new TextEncoder();
const frame = (data: { type: string }) => enc.encode(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);

beforeAll(async () => {
  await migrate();
  const statements = usageSql
    .split(";")
    .map((s) => s.replace(/^\s*--.*$/gm, "").trim())
    .filter(Boolean);
  await env.DB.batch(statements.map((s) => env.DB.prepare(s)));
});

afterEach(() => vi.restoreAllMocks());

describe("AI routes in the app router", () => {
  it("/health still works without auth", async () => {
    const res = await send("/health", {});
    expect(res.status).toBe(200);
    expect((await res.json<any>()).ok).toBe(true);
  });

  it("rejects parts and steps without a session (401) and never calls the AI", async () => {
    const spy = mockFetch(() => Response.json({}));
    for (const path of ["/ai/parts", "/ai/steps"]) {
      const res = await post(path, { image: b64(fakeJpeg(64, 64)), instructions });
      expect(res.status).toBe(401);
      expect((await res.json<any>()).error).toEqual({ code: "unauthorized", message: "ავტორიზაცია საჭიროა" });
    }
    expect((await post("/ai/parts", {}, "not.a.token")).status).toBe(401);
    expect(spy).not.toHaveBeenCalled();
  });

  it("parts: 200 and an ok usage row with the cost and sessionId", async () => {
    const sub = "wiring-parts-ok";
    mockFetch(() => Response.json(responseBody(partsResult)));
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions, sessionId: "s-42" }, await token(sub));
    expect(res.status).toBe(200);
    const body = await res.json<any>();
    expect(body.parts.map((p: any) => p.id)).toEqual(["p1"]);
    const rows = await usageOf(sub);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ stage: "parts", status: "ok", session_id: "s-42", model: "gpt-6-astra", input_tokens: 1027, output_tokens: 227 });
    expect(rows[0]!.cost_usd).toBeCloseTo(COST, 9);
    expect(body.costUsd).toBeCloseTo(COST, 9);
  });

  it("parts: 429 daily_limit with Retry-After once the day's sessions are used, without an AI call", async () => {
    const sub = "wiring-limit";
    await recordUsage(env, {
      userId: sub,
      stage: "parts",
      provider: "astra",
      model: "gpt-6-astra",
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      costUsd: 0.01,
      latencyMs: 1,
      status: "ok",
    });
    const spy = mockFetch(() => Response.json(responseBody(partsResult)));
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions }, await token(sub), {
      DAILY_SESSION_LIMIT: "1",
    });
    expect(res.status).toBe(429);
    const retryAfter = Number(res.headers.get("retry-after"));
    expect(retryAfter).toBeGreaterThan(0);
    expect(retryAfter).toBeLessThanOrEqual(86_400);
    expect((await res.json<any>()).error).toEqual({ code: "daily_limit", message: "დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ" });
    expect(spy).not.toHaveBeenCalled();
    expect(await usageOf(sub)).toHaveLength(1);
  });

  it("parts: 504 ai_timeout on a slow AI, aborts the upstream call and logs a timeout row", async () => {
    const sub = "wiring-timeout";
    let aborted = false;
    mockFetch(
      (_url, init) =>
        new Promise<Response>((resolve, reject) => {
          const timer = setTimeout(() => resolve(Response.json(responseBody(partsResult))), 2000);
          init.signal?.addEventListener("abort", () => {
            aborted = true;
            clearTimeout(timer);
            reject(new DOMException("aborted", "AbortError"));
          });
        }),
    );
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions }, await token(sub), { AI_TIMEOUT_MS: "50" });
    expect(res.status).toBe(504);
    expect((await res.json<any>()).error.code).toBe("ai_timeout");
    expect(aborted).toBe(true);
    expect(await usageOf(sub)).toMatchObject([{ stage: "parts", status: "timeout", cost_usd: 0 }]);
  });

  it("parts: an upstream failure logs an error row (and is not retried)", async () => {
    const sub = "wiring-parts-error";
    const spy = mockFetch(() => new Response("rate limited", { status: 429 }));
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions }, await token(sub));
    expect(res.status).toBe(502);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(await usageOf(sub)).toMatchObject([{ stage: "parts", status: "error", cost_usd: 0 }]);
  });

  it("steps: streams, then logs a steps usage row after done", async () => {
    const sub = "wiring-steps-ok";
    mockFetch(
      () =>
        new Response(
          new ReadableStream({
            start(c) {
              c.enqueue(frame({ type: "response.output_text.delta", delta: JSON.stringify(stepsResult) } as any));
              c.enqueue(frame({ type: "response.completed", response: responseBody(stepsResult) } as any));
              c.close();
            },
          }),
        ),
    );
    const res = await post("/ai/steps", { object: "ძრავი", parts, instructions, sessionId: "s-42" }, await token(sub));
    expect(res.status).toBe(200);
    const evs = await events(res);
    expect(evs.map((e) => e.event)).toEqual(["step", "done"]);
    const rows = await usageOf(sub);
    expect(rows).toMatchObject([{ stage: "steps", status: "ok", session_id: "s-42", input_tokens: 1027 }]);
    expect(rows[0]!.cost_usd).toBeCloseTo(COST, 9);
  });

  it("steps: a slow stream ends with an ai_timeout error event and a timeout row", async () => {
    const sub = "wiring-steps-timeout";
    mockFetch(
      (_url, init) =>
        new Response(
          new ReadableStream({
            start(c) {
              init.signal?.addEventListener("abort", () => c.error(new DOMException("aborted", "AbortError")));
            },
          }),
        ),
    );
    const res = await post("/ai/steps", { object: "ძრავი", parts, instructions }, await token(sub), { AI_TIMEOUT_MS: "50" });
    expect(res.status).toBe(200);
    const evs = await events(res);
    expect(evs).toHaveLength(1);
    expect(evs[0]).toMatchObject({ event: "error", data: { code: "ai_timeout" } });
    expect(await usageOf(sub)).toMatchObject([{ stage: "steps", status: "timeout", cost_usd: 0 }]);
  });

  it("steps: a mid-stream failure sends an error event and logs an error row", async () => {
    const sub = "wiring-steps-error";
    mockFetch(
      () =>
        new Response(
          new ReadableStream({
            start(c) {
              c.enqueue(frame({ type: "error" }));
              c.close();
            },
          }),
        ),
    );
    const res = await post("/ai/steps", { object: "ძრავი", parts, instructions }, await token(sub));
    const evs = await events(res);
    expect(evs).toMatchObject([{ event: "error", data: { code: "ai_upstream" } }]);
    expect(await usageOf(sub)).toMatchObject([{ stage: "steps", status: "error" }]);
  });
});
