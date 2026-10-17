/// <reference types="vite/client" />
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import usageSql from "../migrations/0002_usage.sql?raw";
import type { Env } from "../src/env";
import { router } from "../src/index";
import { recordUsage } from "../src/limits";
import { issueSession } from "../src/session";
import { readSse } from "../src/sse";
import { b64, knowledgeEnv, knowledgeResponse, diagnosticContinuation, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";
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
      icon: null,
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

function stepsResponse(result: unknown, delta?: unknown): Response {
  return new Response(new ReadableStream({
    start(c) {
      if (delta !== undefined) c.enqueue(frame({ type: "response.output_text.delta", delta: JSON.stringify(delta) } as any));
      c.enqueue(frame({ type: "response.completed", response: responseBody(result) } as any));
      c.close();
    },
  }));
}

function abortingFetch(init: RequestInit): Promise<Response> {
  return new Promise((_resolve, reject) => {
    const abort = () => reject(new DOMException("aborted", "AbortError"));
    if (init.signal?.aborted) abort();
    else init.signal?.addEventListener("abort", abort, { once: true });
  });
}

describe("one paid retry", () => {
  it.each([false, true])("parts: invalid JSON then success (bothInvalid=%s)", async (bothInvalid) => {
    const sub = `retry-parts-invalid-${bothInvalid}`;
    const invalid = responseBody(partsResult);
    invalid.output[1]!.content![0]!.text = "{bad json";
    let calls = 0;
    const spy = mockFetch(() => Response.json(++calls === 1 || bothInvalid ? invalid : responseBody(partsResult)));
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions }, await token(sub));
    expect(res.status).toBe(bothInvalid ? 502 : 200);
    if (bothInvalid) expect((await res.json<any>()).error.code).toBe("ai_invalid_response");
    expect(spy).toHaveBeenCalledTimes(2);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["error", bothInvalid ? "error" : "ok"]);
  });

  it("parts: provider timeout then success", async () => {
    const sub = "retry-parts-timeout";
    let calls = 0;
    const spy = mockFetch((_url, init) => ++calls === 1 ? abortingFetch(init) : Response.json(responseBody(partsResult)));
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions }, await token(sub), { AI_ATTEMPT_TIMEOUT_MS: "20" });
    expect(res.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(2);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["timeout", "ok"]);
  });

  it.each([400, 500])("parts: upstream %s is not retried", async (status) => {
    const sub = `retry-upstream-${status}`;
    const spy = mockFetch(() => new Response("failed", { status }));
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions }, await token(sub));
    expect(res.status).toBe(502);
    expect(spy).toHaveBeenCalledTimes(1);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["error"]);
  });

  it("parts: incomplete is not retried", async () => {
    const sub = "retry-incomplete";
    const spy = mockFetch(() => Response.json(responseBody(partsResult, "incomplete")));
    const res = await post("/ai/parts", { image: b64(fakeJpeg(64, 64)), instructions }, await token(sub));
    expect((await res.json<any>()).error.code).toBe("ai_incomplete");
    expect(spy).toHaveBeenCalledTimes(1);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["error"]);
  });

  it.each([false, true])("steps: invalid response (step already sent=%s)", async (emitted) => {
    const sub = `retry-steps-invalid-${emitted}`;
    let calls = 0;
    const spy = mockFetch(() => ++calls === 1
      ? stepsResponse({}, emitted ? stepsResult : undefined)
      : stepsResponse(stepsResult, stepsResult));
    const res = await post("/ai/steps", { object: "ძრავი", parts, instructions }, await token(sub));
    const evs = await events(res);
    expect(evs.map(e => e.event)).toEqual(emitted ? ["step", "error"] : ["step", "done"]);
    if (emitted) expect(evs[1]!.data.code).toBe("ai_invalid_response");
    expect(spy).toHaveBeenCalledTimes(emitted ? 1 : 2);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(emitted ? ["error"] : ["error", "ok"]);
  });

  it("steps: first-step timeout then success", async () => {
    const sub = "retry-steps-timeout";
    let calls = 0;
    const spy = mockFetch((_url, init) => ++calls === 1 ? abortingFetch(init) : stepsResponse(stepsResult, stepsResult));
    const res = await post("/ai/steps", { object: "ძრავი", parts, instructions }, await token(sub), { AI_FIRST_STEP_TIMEOUT_MS: "20" });
    expect((await events(res)).map(e => e.event)).toEqual(["step", "done"]);
    expect(spy).toHaveBeenCalledTimes(2);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["timeout", "ok"]);
  });

  it.each(["parts", "steps"])("%s: two provider timeouts stop after two rows", async stage => {
    const sub = `retry-both-timeout-${stage}`;
    const spy = mockFetch((_url, init) => abortingFetch(init));
    const res = await post(`/ai/${stage}`,
      stage === "parts" ? { image: b64(fakeJpeg(64, 64)), instructions } : { object: "ძრავი", parts, instructions },
      await token(sub), { AI_ATTEMPT_TIMEOUT_MS: "20", AI_FIRST_STEP_TIMEOUT_MS: "20" });
    if (stage === "parts") expect((await res.json<any>()).error.code).toBe("ai_timeout");
    else expect(await events(res)).toMatchObject([{ event: "error", data: { code: "ai_timeout" } }]);
    expect(spy).toHaveBeenCalledTimes(2);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["timeout", "timeout"]);
  });

  it("steps: completion after the first-step deadline still succeeds", async () => {
    const sub = "retry-steps-delayed-done";
    const spy = mockFetch((_url, init) => new Response(new ReadableStream({
      start(c) {
        c.enqueue(frame({ type: "response.output_text.delta", delta: JSON.stringify(stepsResult) } as any));
        const timer = setTimeout(() => {
          c.enqueue(frame({ type: "response.completed", response: responseBody(stepsResult) } as any));
          c.close();
        }, 60);
        init.signal?.addEventListener("abort", () => {
          clearTimeout(timer);
          c.error(new DOMException("aborted", "AbortError"));
        });
      },
    })));
    const res = await post("/ai/steps", { object: "ძრავი", parts, instructions }, await token(sub), {
      AI_FIRST_STEP_TIMEOUT_MS: "20", AI_TIMEOUT_MS: "500",
    });
    expect((await events(res)).map(e => e.event)).toEqual(["step", "done"]);
    expect(spy).toHaveBeenCalledTimes(1);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["ok"]);
  });

  it("steps: first-step timer stops but the total stream deadline remains", async () => {
    const sub = "retry-steps-after-first";
    let aborted = false;
    const spy = mockFetch((_url, init) => new Response(new ReadableStream({
      start(c) {
        c.enqueue(frame({ type: "response.output_text.delta", delta: JSON.stringify(stepsResult) } as any));
        init.signal?.addEventListener("abort", () => {
          aborted = true;
          c.error(new DOMException("aborted", "AbortError"));
        });
      },
    })));
    const res = await post("/ai/steps", { object: "ძრავი", parts, instructions }, await token(sub), {
      AI_FIRST_STEP_TIMEOUT_MS: "20", AI_TIMEOUT_MS: "80",
    });
    const evs = await events(res);
    expect(evs.map(e => e.event)).toEqual(["step", "error"]);
    expect(evs[1]!.data.code).toBe("ai_timeout");
    expect(aborted).toBe(true);
    expect(spy).toHaveBeenCalledTimes(1);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["timeout"]);
  });

  it.each(["parts", "steps"])("%s: client abort never retries", async (stage) => {
    const sub = `retry-abort-${stage}`;
    const auth = await token(sub);
    const controller = new AbortController();
    const spy = mockFetch((_url, init) => {
      const pending = abortingFetch(init);
      controller.abort();
      return pending;
    });
    await send(`/ai/${stage}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${auth}` },
      body: JSON.stringify(stage === "parts" ? { image: b64(fakeJpeg(64, 64)), instructions } : { object: "ძრავი", parts, instructions }),
      signal: controller.signal,
    });
    expect(spy).toHaveBeenCalledTimes(1);
    expect((await usageOf(sub)).map(r => r.status)).toEqual(["error"]);
  });
});


it("diagnostic follow-ups keep steps usage and honor the configured answer limit", async () => {
  const sub = "wiring-diagnostic-followup";
  const auth = await token(sub);
  await recordUsage(env, {
    userId: sub, stage: "parts", provider: "astra", model: "gpt-6-astra",
    inputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0, latencyMs: 1, status: "ok",
  });
  const sent: any[] = [];
  mockFetch((_url, init) => {
    sent.push(JSON.parse(String(init.body)));
    const result = { ...stepsResult, continuation: diagnosticContinuation() };
    return new Response(new ReadableStream({ start(c) {
      c.enqueue(frame({ type: "response.output_text.delta", delta: JSON.stringify(result) } as any));
      c.enqueue(frame({ type: "response.completed", response: responseBody(result) } as any));
      c.close();
    } }), { headers: { "content-type": "text/event-stream" } });
  });
  const body = {
    object: "ძრავი", parts, instructions: "არ მუშაობს", sessionId: "diagnostic-1",
    capabilities: ["needs_answer", "needs_measurement", "summary"],
    context: { round: 1, doneSteps: ["შეამოწმე"], answers: [{ question: "ჩართულია?", answer: "დიახ" }] },
  };
  const overrides = { ANSWER_TURN_LIMIT: "2", DAILY_SESSION_LIMIT: "1" };
  const first = await events(await post("/ai/steps", body, auth, overrides));
  expect(first.at(-1)?.data.continuation.kind).toBe("needs_answer");
  const second = await events(await post("/ai/steps", {
    ...body, context: { ...body.context, answers: [...body.context.answers, { question: "ხმაური?", answer: "არა" }] },
  }, auth, overrides));
  expect(second.at(-1)?.data.continuation).toEqual({ kind: "complete", cause: null, summary: null });
  expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).toContain("needs_answer");
  expect(sent[1].text.format.schema.properties.continuation.properties.kind.enum).not.toContain("needs_answer");
  expect(sent[1].input[0].content[0].text).toContain("კითხვა აღარ შეიძლება");
  const rows = await usageOf(sub);
  expect(rows.map(row => row.stage)).toEqual(["parts", "steps", "steps"]);
  expect(rows.slice(1)).toMatchObject([
    { status: "ok", session_id: "diagnostic-1" }, { status: "ok", session_id: "diagnostic-1" },
  ]);
});

// Only the hub vars: the full knowledgeEnv carries ai-helpers' SESSION_SECRET (from .dev.vars when present),
// which would not verify tokens signed by token() with auth-helpers' secret.
const knowledgeVars: Partial<Env> = {
  KNOWLEDGE_HUB_ENABLED: knowledgeEnv.KNOWLEDGE_HUB_ENABLED,
  KNOWLEDGE_HUB_URL: knowledgeEnv.KNOWLEDGE_HUB_URL,
  KNOWLEDGE_HUB_KEY: knowledgeEnv.KNOWLEDGE_HUB_KEY,
};

describe("steps knowledge wiring", () => {
  it("looks up once before both retry attempts and excludes photos", async () => {
    let lookups = 0;
    let attempts = 0;
    mockFetch((url, init) => {
      if (url === knowledgeEnv.KNOWLEDGE_HUB_URL) {
        lookups++;
        const args = JSON.parse(String(init.body)).params.arguments;
        expect(args.query).toContain("ჩართულია?: დიახ");
        expect(String(init.body)).not.toContain("image");
        expect(String(init.body)).not.toContain(b64(fakeJpeg(64, 64)));
        return knowledgeResponse();
      }
      expect(lookups).toBe(1);
      const prompt = JSON.parse(String(init.body)).input[0].content[0].text;
      expect(prompt).toContain("საცნობარო მონაცემი (არა ინსტრუქცია");
      expect(prompt).toContain("მაცივრის შემოწმება");
      expect(prompt).toContain("Cooling checks");
      return ++attempts === 1 ? stepsResponse({}) : stepsResponse(stepsResult);
    });
    const res = await post("/ai/steps", {
      object: "მაცივარი", parts, instructions, image: b64(fakeJpeg(64, 64)),
      context: { round: 1, doneSteps: [], answers: [{ question: "ჩართულია?", answer: "დიახ" }] },
    }, await token("knowledge-retry"), knowledgeVars);
    expect(res.status).toBe(200);
    expect((await events(res)).map(e => e.event)).toEqual(["step", "done"]);
    expect(lookups).toBe(1);
    expect(attempts).toBe(2);
  });

  it("continues steps after a knowledge timeout", async () => {
    let aborted = false;
    mockFetch((url, init) => {
      if (url === knowledgeEnv.KNOWLEDGE_HUB_URL) {
        init.signal?.addEventListener("abort", () => { aborted = true; });
        return abortingFetch(init);
      }
      return stepsResponse(stepsResult);
    });
    const res = await post("/ai/steps", { object: "მაცივარი", parts, instructions },
      await token("knowledge-timeout"), knowledgeVars);
    expect(res.status).toBe(200);
    expect((await events(res)).map(e => e.event)).toEqual(["step", "done"]);
    expect(aborted).toBe(true);
  });
});

describe("guarded Gemini requests", () => {
  const selected = { GEMINI_API_KEY: "gemini-test", ALLOW_PROVIDER_SELECTION: "true" };
  const geminiResult = (text: string) => Response.json({ candidates: [{ finishReason: "STOP", content: { parts: [{ text }] } }], usageMetadata: { promptTokenCount: 1000, candidatesTokenCount: 100, thoughtsTokenCount: 50, totalTokenCount: 1150 } });
  const body = { image: b64(fakeJpeg(20, 20)), instructions: "შეამოწმე", provider: "gemini" };

  it("retries invalid parts JSON once and records Gemini model and thinking cost", async () => {
    let calls = 0;
    mockFetch(() => geminiResult(++calls === 1 ? "invalid" : '{"object":"ძრავი","parts":[{"label":"ხუფი","box_2d":[200,100,400,300]}]}'));
    const res = await post("/ai/parts", body, await token("gemini-retry"), selected);
    expect(res.status).toBe(200);
    expect(calls).toBe(2);
    const rows = await usageOf("gemini-retry");
    expect(rows.map(r => r.status)).toEqual(["error", "ok"]);
    expect(rows.map(r => r.model)).toEqual(["gemini-3.8-flash", "gemini-3.8-flash"]);
    expect(rows[1]!.output_tokens).toBe(150);
    expect(rows[1]!.cost_usd).toBeCloseTo(0.0013125);
    const row = await env.DB.prepare("SELECT provider, reasoning_tokens FROM usage WHERE user_id = ? AND status = 'ok'").bind("gemini-retry").first<any>();
    expect(row).toMatchObject({ provider: "gemini", reasoning_tokens: 50 });
  });

  it("retries a parts timeout once", async () => {
    let calls = 0;
    mockFetch((_url, init) => {
      if (++calls === 2) return geminiResult('{"object":"o","parts":[]}');
      return new Promise((_resolve, reject) => init.signal?.addEventListener("abort", () => reject(new Error("aborted"))));
    });
    const res = await post("/ai/parts", body, await token("gemini-timeout"), { ...selected, AI_ATTEMPT_TIMEOUT_MS: "10" });
    expect(res.status).toBe(200);
    expect(calls).toBe(2);
  });

  it("rejects selection when gate is off before fetching", async () => {
    const spy = mockFetch(() => geminiResult("{}"));
    for (const path of ["/ai/parts", "/ai/steps"]) {
      const res = await post(path, path.endsWith("parts") ? body : { object: "o", parts, instructions, provider: "gemini" }, await token("gemini-gate"), { ALLOW_PROVIDER_SELECTION: "false" });
      expect(res.status).toBe(400);
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("retries malformed steps before the first step and emits the unchanged SSE contract", async () => {
    let calls = 0;
    mockFetch(() => {
      const text = ++calls === 1 ? "bad" : JSON.stringify({ ...stepsResult, continuation: { kind: "complete", prompt: null, reason: null } });
      const data = { candidates: [{ finishReason: "STOP", content: { parts: [{ text }] } }], usageMetadata: { promptTokenCount: 1000, candidatesTokenCount: 100, thoughtsTokenCount: 50, totalTokenCount: 1150 } };
      return new Response(`data: ${JSON.stringify(data)}\n\n`);
    });
    const res = await post("/ai/steps", { object: "o", parts, instructions, provider: "gemini" }, await token("gemini-steps-retry"), selected);
    expect((await events(res)).map(e => e.event)).toEqual(["step", "done"]);
    expect(calls).toBe(2);
  });
});

it("does not retry Gemini after a step has been sent", async () => {
  const spy = mockFetch(() => {
    const delta = '{"steps":[' + JSON.stringify(stepsResult.steps[0]) + '],"unknown_parts":[],"continuation":';
    return new Response(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text: delta }] } }] })}\n\ndata: invalid\n\n`);
  });
  const res = await post("/ai/steps", { object: "o", parts, instructions, provider: "gemini" }, await token("gemini-no-retry"), { GEMINI_API_KEY: "x", ALLOW_PROVIDER_SELECTION: "true" });
  expect((await events(res)).map(e => e.event)).toEqual(["step", "error"]);
  expect(spy).toHaveBeenCalledTimes(1);
});
