import { afterEach, describe, expect, it, vi } from "vitest";
import { GeminiProvider, selectedEnv } from "../src/ai/provider";
import { geminiUsage, geminiSchema, GEMINI_MODEL, postGemini } from "../src/ai/gemini";
import { schemaSteps, validateSchema } from "../src/ai/schema";
import { estimateCost } from "../src/ai/pricing";
import { b64, call, diagnosticContinuation, fakeJpeg, mockFetch, testEnv } from "./ai-helpers";

const usage = { promptTokenCount: 1000, candidatesTokenCount: 100, thoughtsTokenCount: 50, totalTokenCount: 1150 };
const provider = () => new GeminiProvider({ apiKey: "test-gemini", model: GEMINI_MODEL, effort: "low" });
const step = { title: "შეამოწმე", text: "შეამოწმე კვება", focus: ["p1"], avoid: [], markers: [], arrows: [], icon: null, tools: [], tip: null, warn: null };
const input = { object: "მოწყობილობა", parts: [{ id: "p1", name: "ღილაკი", box: [100, 200, 300, 400] as [number, number, number, number] }], instructions: "არ მუშაობს", count: 5, capabilities: ["needs_answer", "needs_measurement", "summary"] };
const chunk = (text: string, finish = false) => ({ candidates: [{ content: { parts: [{ text }] }, ...(finish ? { finishReason: "STOP" } : {}) }], ...(finish ? { usageMetadata: usage } : {}) });
const frame = (data: unknown) => new TextEncoder().encode(`data: ${JSON.stringify(data)}\n\n`);
afterEach(() => vi.restoreAllMocks());

describe("Gemini provider", () => {
  it.each([
    { status: 400, message: "Schema exceeds maximum allowed states: SECRET_KEY private photo text", reason: "schema_complexity" },
    { status: 400, message: "Schema exceeds maximum nesting depth SECRET_KEY", reason: "schema_complexity" },
    { status: 400, message: "Constraint has too many states SECRET_KEY", reason: "schema_complexity" },
    { status: 400, message: "Grammar is too complex SECRET_KEY", reason: "schema_complexity" },
    { status: 400, message: "Too many states SECRET_KEY", reason: "schema_complexity" },
    { status: 400, message: "API key not valid. Please pass a valid API key. SECRET_KEY", reason: "auth" },
    { status: 400, message: "API key expired. Please renew the API key. SECRET_KEY", reason: "auth" },
    { status: 400, message: "Invalid API key SECRET_KEY", reason: "auth" },
    { status: 429, message: "Quota for SECRET_KEY exceeded", reason: "quota" },
    { status: 403, message: "SECRET_KEY unauthorized", reason: "auth" },
    { status: 404, message: "Private model SECRET_KEY not found", reason: "not_found" },
    { status: 500, message: "Unexpected SECRET_KEY private prompt", reason: "other" },
  ])("logs only safe diagnostics for upstream $status/$reason", async ({ status, message, reason }) => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    mockFetch(() => Response.json({ error: { message } }, { status }));
    const payload = { text: { format: { schema: { type: "object", properties: {} } } }, input: [{ content: [{ type: "input_text", text: "private photo text" }] }] };
    await expect(postGemini("SECRET_KEY", payload, new AbortController().signal)).rejects.toMatchObject({ code: "ai_upstream" });
    expect(warn.mock.calls).toEqual([["ai/gemini upstream rejected", { status, reason }]]);
    expect(JSON.stringify(warn.mock.calls)).not.toContain("SECRET_KEY");
    expect(JSON.stringify(warn.mock.calls)).not.toContain("private");
  });

  it("reports only allowlisted field names from a rejected configuration", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    mockFetch(() => Response.json({ error: { message: "Unknown thinkingLevel / responseJsonSchema maxItems, private_SECRET_FIELD; SECRET_KEY" } }, { status: 400 }));
    const payload = { text: { format: { schema: { type: "object", properties: {} } } }, input: [{ content: [] }] };
    await expect(postGemini("SECRET_KEY", payload, new AbortController().signal)).rejects.toMatchObject({ code: "ai_upstream" });
    expect(warn.mock.calls).toEqual([["ai/gemini upstream rejected", {
      status: 400, reason: "other", fields: ["maxItems", "thinkingLevel", "responseJsonSchema"],
    }]]);
  });

  it.each(["not JSON SECRET_KEY", "x".repeat(16_385)])("does not leak malformed or oversized error bodies", async body => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    mockFetch(() => new Response(body, { status: 400 }));
    const payload = { text: { format: { schema: { type: "object", properties: {} } } }, input: [{ content: [] }] };
    await expect(postGemini("SECRET_KEY", payload, new AbortController().signal)).rejects.toMatchObject({ code: "ai_upstream" });
    expect(warn.mock.calls).toEqual([["ai/gemini upstream rejected", { status: 400, reason: "other" }]]);
  });

  it.each([[], ["needs_answer", "needs_measurement", "summary"], ["check_photo"]].map(capabilities => ({ capabilities })))(
    "preserves schemas without tools/hands byte-for-byte: $capabilities", ({ capabilities }) => {
      const schema = schemaSteps(["p1", "p2"], 5, { capabilities });
      expect(JSON.stringify(geminiSchema(schema))).toBe(JSON.stringify(schema));
    },
  );

  it.each([false, true])("only relaxes the outer steps count in Gemini payloads (freeText=%s)", freeText => {
    const schema = schemaSteps(["p1", "p2"], 5, { freeText, capabilities: ["tools_v2", "hands_v1", "check_photo"] });
    const before = JSON.stringify(schema);
    const adapted = geminiSchema(schema) as any;
    const list = adapted.properties.steps;
    expect(list.minItems).toBeUndefined();
    expect(list.maxItems).toBeUndefined();
    expect(list.description).toBe(freeText ? "Return between 1 and 5 steps." : "Return exactly 5 steps.");
    const original = (schema.properties as any).steps;
    expect(list.items).toEqual(original.items);
    expect(validateSchema(original, [])).toContain("too few items");
    expect(validateSchema(original, Array(6).fill({}))).toContain("too many items");
    expect(JSON.stringify(schema)).toBe(before);
    const fields = list.items.properties;
    expect(fields.toolCards.items.properties.notThis.type).toEqual(["object", "null"]);
    expect(fields.actions.items.properties.order.type).toEqual(["array", "null"]);
    expect(fields.hands.maxItems).toBe(2);
    expect(fields.actions.maxItems).toBe(3);
    expect(fields.toolCards.maxItems).toBe(3);
  });

  it.each([["tools_v2"], ["hands_v1"], ["tools_v2", "hands_v1", "check_photo"]].map(extra => ({ extra })))(
    "sends adapted steps and preserves nullable output with $extra", async ({ extra }) => {
      const capabilities = [...input.capabilities, ...extra];
      const extended = { ...step,
        ...(extra.includes("tools_v2") ? { toolCards: [{ id: "ph2", size: null, sizeSource: "typical", fitCheck: "შეამოწმე", alternatives: [], why: "მოხსენი", notThis: null }],
          actions: [{ part: "p1", kind: "press", amount: null, order: null }] } : {}),
        ...(extra.includes("hands_v1") ? { hands: [{ part: "p1", grip: "support", hand: "right", byHandOnly: false }] } : {}),
      };
      mockFetch((_url, init) => {
        const sent = JSON.parse(init.body as string).generationConfig.responseJsonSchema;
        expect(sent).toEqual(geminiSchema(schemaSteps(["p1"], 5, { freeText: true, capabilities })));
        const text = JSON.stringify({ steps: [extended], unknown_parts: [], continuation: diagnosticContinuation({ kind: "complete" }) });
        return new Response(new ReadableStream({ start(c) { c.enqueue(frame(chunk(text, true))); c.close(); } }));
      });
      const events = [];
      for await (const event of provider().steps({ ...input, capabilities })) events.push(event);
      expect(events[0]).toMatchObject({ type: "step", step: {
        ...(extra.includes("tools_v2") ? { toolCards: [{ notThis: null }], actions: [{ order: null, amount: null }] } : {}),
        ...(extra.includes("hands_v1") ? { hands: extended.hands } : {}),
      } });
      expect(events.at(-1)).toMatchObject({ type: "done" });
    },
  );

  it("converts YXYX boxes and sends JSON schema, low thinking and JPEG", async () => {
    mockFetch((url, init) => {
      expect(url).toContain(`${GEMINI_MODEL}:generateContent`);
      expect(init.headers).toMatchObject({ "x-goog-api-key": "test-gemini" });
      const body = JSON.parse(init.body as string);
      expect(body.generationConfig.thinkingConfig).toEqual({ thinkingLevel: "low" });
      expect(body.generationConfig.responseJsonSchema.properties.parts.items.required).toEqual(["label", "box_2d"]);
      expect(body.contents[0].parts[0].text).toContain("box_2d=[ymin,xmin,ymax,xmax]");
      expect(body.contents[0].parts[1].inlineData).toEqual({ mimeType: "image/jpeg", data: "jpeg" });
      return Response.json(chunk(JSON.stringify({ object: "ძრავი", parts: [{ label: "ხუფი", box_2d: [200, 100, 400, 300] }] }), true));
    });
    const result = await provider().parts({ imageBase64: "jpeg", instructions: "შეამოწმე" });
    expect(result.parts).toEqual([{ id: "p1", name: "ხუფი", box: [100, 200, 300, 400] }]);
    expect(result.usage?.output_tokens).toBe(150);
    expect(result.costUsd).toBeCloseTo(0.0013125);
  });

  it.each(["complete", "needs_photo", "needs_answer", "needs_measurement"])("streams steps before upstream completion and tidies %s", async kind => {
    let upstream!: ReadableStreamDefaultController<Uint8Array>;
    mockFetch((url, init) => {
      expect(url).toContain("streamGenerateContent?alt=sse");
      const body = JSON.parse(init.body as string);
      expect(body.generationConfig.responseJsonSchema.properties.continuation.properties.kind.enum).toContain(kind);
      return new Response(new ReadableStream({ start(c) { upstream = c; } }));
    });
    const continuation = diagnosticContinuation({ kind, prompt: "ფოტო", reason: "მიზეზი", unit: "V", min: 0, max: 10, how: "გაზომე", cause: "კვება", summary: "შეჯამება" });
    const iter = provider().steps(input);
    const first = iter.next();
    await vi.waitFor(() => expect(upstream).toBeDefined());
    upstream.enqueue(frame({ candidates: [{ content: { parts: [{ text: "hidden", thought: true }] } }] }));
    upstream.enqueue(frame(chunk('{"steps":[' + JSON.stringify(step) + ']')));
    expect((await first).value).toMatchObject({ type: "step", index: 0, step: { focus: ["p1"] } });
    upstream.enqueue(frame(chunk(',"unknown_parts":[],"continuation":' + JSON.stringify(continuation) + '}', true)));
    upstream.close();
    expect((await iter.next()).value).toMatchObject({ type: "done", model: GEMINI_MODEL, continuation: { kind }, usage: { output_tokens: 150 } });
    await iter.return(undefined);
  });

  it("rejects invalid JSON and invalid boxes", async () => {
    for (const text of ["{bad", JSON.stringify({ object: "o", parts: [{ label: "x", box_2d: [200, 100, 100, 300] }] })]) {
      mockFetch(() => Response.json(chunk(text, true)));
      await expect(provider().parts({ imageBase64: "x", instructions: "x" })).rejects.toMatchObject({ code: "ai_invalid_response" });
      vi.restoreAllMocks();
    }
  });

  it("counts thinking and unknown generated tokens conservatively", () => {
    expect(geminiUsage({ ...usage, totalTokenCount: 1200 })?.output_tokens).toBe(200);
    expect(geminiUsage({ promptTokenCount: -1, totalTokenCount: 1 })).toBeNull();
    expect(estimateCost(geminiUsage(usage), GEMINI_MODEL)).toBeCloseTo(0.0013125);
  });

  it("gates explicit provider selection and preserves absent-provider default", async () => {
    expect(selectedEnv(testEnv, undefined)).toBe(testEnv);
    expect(() => selectedEnv({ ...testEnv, ALLOW_PROVIDER_SELECTION: "false" }, "gemini")).toThrow();
    expect(() => selectedEnv({ ...testEnv, ALLOW_PROVIDER_SELECTION: "true" }, "other")).toThrow();
    mockFetch(() => Response.json(chunk('{"object":"o","parts":[]}', true)));
    const body = JSON.stringify({ image: b64(fakeJpeg(20, 20)), instructions: "x", provider: "gemini" });
    const res = await call("/ai/parts", { method: "POST", headers: { "content-type": "application/json" }, body }, { GEMINI_API_KEY: "x", ALLOW_PROVIDER_SELECTION: "true" });
    expect(res.status).toBe(200);
    expect((await res.json<any>()).model).toBe(GEMINI_MODEL);
  });
});
