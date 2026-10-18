/// <reference types="vite/client" />
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import usageSql from "../migrations/0002_usage.sql?raw";
import explainSql from "../migrations/0003_usage_explain.sql?raw";
import { ASK_FIT_CHECK, askSchema, promptAsk, tidyAsk } from "../src/ai/ask";
import { GEMINI_MODEL } from "../src/ai/gemini";
import type { JsonSchema } from "../src/ai/schema";
import type { Part } from "../src/ai/validate";
import type { Env } from "../src/env";
import { router } from "../src/index";
import { issueSession } from "../src/session";
import { b64, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";
import { env, migrate, testEnv } from "./auth-helpers";

const aiEnv: Env = { ...testEnv, AI_PROVIDER: "astra", OPENAI_API_KEY: "test-key", GEMINI_API_KEY: "test-gemini" };
const image = b64(fakeJpeg(64, 64));
const parts: Part[] = [
  { id: "p1", name: "სიფონი", box: [100, 200, 300, 400] },
  { id: "p2", name: "ჭანჭიკი M6", box: [500, 500, 600, 650] },
];

function answer(fields: Record<string, unknown> = {}) {
  return {
    partLabel: "სიფონი", answer: "ეს სიფონია: წყალს უკან არ უშვებს სუნს.", size: null, sizeSource: null,
    fitCheck: null, urgency: "ok", suggestStep: null, confidence: "high", ...fields,
  };
}

function geminiBody(fields: Record<string, unknown> = {}) {
  return {
    candidates: [{ finishReason: "STOP", content: { parts: [{ text: JSON.stringify(answer(fields)) }] } }],
    usageMetadata: { promptTokenCount: 1000, candidatesTokenCount: 100, thoughtsTokenCount: 50, totalTokenCount: 1150 },
  };
}

async function token(sub: string): Promise<string> {
  return (await issueSession(testEnv, { sub, email: `${sub}@example.com` })).sessionToken;
}

function post(body: unknown, auth?: string, overrides: Partial<Env> = {}): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (auth) headers.authorization = `Bearer ${auth}`;
  const request = new Request("http://example.com/ai/ask", { method: "POST", headers, body: JSON.stringify(body) });
  return router.handle(request, { ...aiEnv, ...overrides }, createExecutionContext());
}

async function usageOf(userId: string) {
  const { results } = await env.DB.prepare("SELECT stage, status, provider, model FROM usage WHERE user_id = ? ORDER BY id")
    .bind(userId).all<{ stage: string; status: string; provider: string; model: string }>();
  return results;
}

function statements(sql: string): string[] {
  return sql.split(";").map((s) => s.replace(/^\s*--.*$/gm, "").trim()).filter(Boolean);
}

beforeAll(async () => {
  await migrate();
  await env.DB.batch([...statements(usageSql), ...statements(explainSql)].map((s) => env.DB.prepare(s)));
});

afterEach(() => vi.restoreAllMocks());

const evidence = { question: "რა ზომაა?", parts: [] as never[] };

describe("ask schema and prompt", () => {
  it("is strict: every key required, no others", () => {
    const schema = askSchema();
    expect(schema.additionalProperties).toBe(false);
    expect(schema.required).toEqual(Object.keys(schema.properties as object));
    expect(schema.required).toEqual([
      "partLabel", "answer", "size", "sizeSource", "fitCheck", "urgency", "suggestStep", "confidence",
    ]);
    const props = schema.properties as Record<string, JsonSchema>;
    expect(props.sizeSource!.enum).toEqual(["seen", "model", "typical", null]);
    expect(props.urgency!.enum).toEqual(["stop", "soon", "ok", null]);
    expect(props.confidence!.enum).toEqual(["high", "medium", "low"]);
  });

  it("names the box literal once, XYXY for astra and YXYX for Gemini, with the context", () => {
    const input = {
      imageBase64: image, question: "მოვხსნა?", box: [10, 20, 30, 40] as [number, number, number, number], parts: [],
      context: { object: "ნიჟარა", doneSteps: ["წყალი დავკეტე"], answers: [{ question: "რა მასალაა?", answer: "პლასტმასი" }] },
    };
    const astra = promptAsk(input);
    expect(astra.split("box=[x0,y0,x1,y1]")).toHaveLength(2);
    expect(astra).toContain("box=[x0,y0,x1,y1] = [10,20,30,40]");
    expect(astra).toContain("„ნიჟარა“");
    expect(astra).toContain("„წყალი დავკეტე“");
    expect(astra).toContain("რა მასალაა?: პლასტმასი");
    expect(astra).toContain('"მოვხსნა?"');
    expect(promptAsk(input, { yx: true })).toContain("box=[x0,y0,x1,y1] = [20,10,40,30]");
  });
});

describe("tidyAsk", () => {
  it("seen without the size in parts/question/answers → typical with a generic fitCheck", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const out = tidyAsk(answer({ size: "M8", sizeSource: "seen" }), { ...evidence, parts });
    expect(out).toMatchObject({ size: "M8", sizeSource: "typical", fitCheck: ASK_FIT_CHECK });
  });

  it("keeps seen when the size core is in the evidence, and the model's fitCheck on typical", () => {
    expect(tidyAsk(answer({ size: "M6", sizeSource: "seen" }), { ...evidence, parts })).toMatchObject({ sizeSource: "seen", fitCheck: null });
    expect(tidyAsk(answer({ size: "10 მმ", sizeSource: "typical", fitCheck: "დაიწყე 10-ით" }), evidence))
      .toMatchObject({ sizeSource: "typical", fitCheck: "დაიწყე 10-ით" });
  });

  it("model needs a known model; no size → sizeSource null unless typical", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(tidyAsk(answer({ size: "T20", sizeSource: "model" }), evidence).sizeSource).toBe("typical");
    expect(tidyAsk(answer({ size: "T20", sizeSource: "model" }), { ...evidence, question: "Bosch WAT28-ზე რა ზომაა?" }).sizeSource).toBe("model");
    expect(tidyAsk(answer({ size: "T20", sizeSource: null }), evidence).sizeSource).toBe("typical");
    expect(tidyAsk(answer(), evidence)).toMatchObject({ size: null, sizeSource: null, fitCheck: null });
    expect(tidyAsk(answer({ sizeSource: "seen" }), evidence)).toMatchObject({ sizeSource: "typical", fitCheck: ASK_FIT_CHECK });
  });

  it("values outside the enums → null / low; long texts clamped", () => {
    const out = tidyAsk(answer({ urgency: "panic", sizeSource: "guess", confidence: "sure", answer: "ა ".repeat(300) }), evidence);
    expect(out).toMatchObject({ urgency: null, sizeSource: null, confidence: "low" });
    expect([...out.answer].length).toBeLessThanOrEqual(200);
  });

  it("an empty answer is invalid (retried by the route)", () => {
    expect(() => tidyAsk(answer({ answer: " " }), evidence)).toThrow();
  });
});

describe("POST /ai/ask", () => {
  it("401 without a session and never calls the AI", async () => {
    const spy = mockFetch(() => Response.json({}));
    expect((await post({ image, question: "ეს რა არის?", box: [1, 2, 3, 4] })).status).toBe(401);
    expect(spy).not.toHaveBeenCalled();
  });

  it("defaults to Gemini, partId → box (YXYX after box_2d), postGemini accepts the schema, logs an ask row", async () => {
    const sub = "ask-gemini";
    const spy = mockFetch((url, init) => {
      expect(url).toContain(`generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`);
      const body = JSON.parse(init.body as string);
      const text = body.contents[0].parts[0].text as string;
      expect(text).toContain("box_2d=[ymin,xmin,ymax,xmax] = [200,100,400,300]");
      expect(text).not.toContain("box=[x0,y0,x1,y1]");
      expect(text).toContain("„სიფონი“");
      expect(body.generationConfig.responseJsonSchema.required).toContain("sizeSource");
      return Response.json(geminiBody({ urgency: "stop", confidence: "medium" }));
    });
    const res = await post({ image, question: "მოვხსნა?", partId: "p1", parts, sessionId: "s-1" }, await token(sub));
    expect(res.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(1);
    const body = await res.json<any>();
    expect(body).toMatchObject({
      partLabel: "სიფონი", size: null, sizeSource: null, fitCheck: null, urgency: "stop",
      suggestStep: null, confidence: "medium", model: GEMINI_MODEL,
    });
    expect(body.costUsd).toBeGreaterThan(0);
    expect(await usageOf(sub)).toEqual([{ stage: "ask", status: "ok", provider: "gemini", model: GEMINI_MODEL }]);
  });

  it("route: an unconfirmed seen size comes back typical with a fitCheck", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    mockFetch(() => Response.json(geminiBody({ size: "PH2", sizeSource: "seen", fitCheck: null })));
    const res = await post({ image, question: "რა ზომაა?", box: [100, 100, 200, 200] }, await token("ask-size"));
    expect(await res.json<any>()).toMatchObject({ size: "PH2", sizeSource: "typical", fitCheck: ASK_FIT_CHECK });
  });

  it("astra: urgency outside the enum → null, not a 502", async () => {
    mockFetch((url) => {
      expect(url).toBe("https://api.openai.com/v1/responses");
      return Response.json(responseBody(answer({ urgency: "danger" })));
    });
    const res = await post({ image, question: "ეს რა არის?", box: [1, 2, 3, 4], provider: "astra" }, await token("ask-astra"),
      { ALLOW_PROVIDER_SELECTION: "true" });
    expect(res.status).toBe(200);
    expect((await res.json<any>()).urgency).toBeNull();
    expect(await usageOf("ask-astra")).toMatchObject([{ stage: "ask", provider: "astra" }]);
  });

  it.each([
    ["neither box nor partId", { question: "ეს რა არის?" }],
    ["unknown partId", { question: "ეს რა არის?", partId: "p9", parts }],
    ["empty question", { question: "  ", box: [1, 2, 3, 4] }],
    ["201-character question", { question: "ა".repeat(201), box: [1, 2, 3, 4] }],
    ["bad box", { question: "ეს რა არის?", box: [5, 5, 1, 1] }],
    ["bad context", { question: "ეს რა არის?", box: [1, 2, 3, 4], context: { doneSteps: "x" } }],
  ])("400 for %s, before any AI call", async (_name, fields) => {
    const spy = mockFetch(() => Response.json({}));
    const res = await post({ image, ...fields }, await token("ask-bad"));
    expect(res.status).toBe(400);
    expect((await res.json<any>()).error.code).toBe("bad_request");
    expect(spy).not.toHaveBeenCalled();
  });

  it("accepts a 200-character question", async () => {
    mockFetch(() => Response.json(geminiBody()));
    expect((await post({ image, question: "ა".repeat(200), box: [1, 2, 3, 4] }, await token("ask-200"))).status).toBe(200);
  });

  it("multipart: box, parts and context as JSON strings", async () => {
    mockFetch((_url, init) => {
      const text = JSON.parse(init.body as string).contents[0].parts[0].text as string;
      expect(text).toContain("= [500,500,650,600]");
      expect(text).toContain("„ნიჟარა“");
      return Response.json(geminiBody());
    });
    const form = new FormData();
    form.set("image", new Blob([fakeJpeg(64, 64)], { type: "image/jpeg" }), "photo.jpg");
    form.set("question", "რა ზომაა?");
    form.set("partId", "p2");
    form.set("parts", JSON.stringify(parts));
    form.set("context", JSON.stringify({ object: "ნიჟარა" }));
    const request = new Request("http://example.com/ai/ask", {
      method: "POST", headers: { authorization: `Bearer ${await token("ask-multipart")}` }, body: form,
    });
    expect((await router.handle(request, aiEnv, createExecutionContext())).status).toBe(200);
  });

  it("400 for a provider when selection is disabled, before any AI call", async () => {
    const spy = mockFetch(() => Response.json({}));
    const res = await post({ image, question: "ეს რა არის?", box: [1, 2, 3, 4], provider: "astra" }, await token("ask-gate"),
      { ALLOW_PROVIDER_SELECTION: "false" });
    expect(res.status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });

  it("retries once after ai_invalid_response, with a usage row per attempt", async () => {
    const sub = "ask-retry";
    let calls = 0;
    mockFetch(() => {
      calls++;
      return calls === 1
        ? Response.json({ candidates: [{ finishReason: "STOP", content: { parts: [{ text: "{bad" }] } }] })
        : Response.json(geminiBody());
    });
    const res = await post({ image, question: "ეს რა არის?", box: [1, 2, 3, 4] }, await token(sub));
    expect(res.status).toBe(200);
    expect(calls).toBe(2);
    expect(await usageOf(sub)).toMatchObject([
      { stage: "ask", status: "error" },
      { stage: "ask", status: "ok" },
    ]);
  });

  it("does not retry a second time", async () => {
    const sub = "ask-retry-twice";
    let calls = 0;
    mockFetch(() => {
      calls++;
      return Response.json({ candidates: [{ finishReason: "STOP", content: { parts: [{ text: "{bad" }] } }] });
    });
    const res = await post({ image, question: "ეს რა არის?", box: [1, 2, 3, 4] }, await token(sub));
    expect(res.status).toBe(502);
    expect(calls).toBe(2);
    expect(await usageOf(sub)).toMatchObject([{ stage: "ask", status: "error" }, { stage: "ask", status: "error" }]);
  });

  it("a call the client cancels still records one error row via waitUntil", async () => {
    const sub = "ask-cancelled";
    const client = new AbortController();
    const ai = mockFetch((_url, init) => new Promise<Response>((_resolve, reject) => {
      init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
      client.abort();
    }));
    const request = new Request("http://example.com/ai/ask", {
      method: "POST", signal: client.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${await token(sub)}` },
      body: JSON.stringify({ image, question: "ეს რა არის?", box: [1, 2, 3, 4] }),
    });
    const ctx = createExecutionContext();
    const waitUntil = vi.spyOn(ctx, "waitUntil");
    await router.handle(request, aiEnv, ctx).catch(() => undefined);
    await waitOnExecutionContext(ctx);
    expect(ai).toHaveBeenCalledTimes(1);
    expect(waitUntil).toHaveBeenCalledTimes(1);
    expect(await usageOf(sub)).toEqual([{ stage: "ask", status: "error", provider: "gemini", model: GEMINI_MODEL }]);
  });
});
