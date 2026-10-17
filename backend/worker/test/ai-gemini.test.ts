import { afterEach, describe, expect, it, vi } from "vitest";
import { GeminiProvider, selectedEnv } from "../src/ai/provider";
import { geminiUsage, GEMINI_MODEL } from "../src/ai/gemini";
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
