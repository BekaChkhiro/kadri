import { afterEach, describe, expect, it, vi } from "vitest";
import { estimateCost } from "../src/ai/pricing";
import { promptParts } from "../src/ai/prompts";
import { pyDumps, schemaParts } from "../src/ai/schema";
import { assignIds } from "../src/ai/validate";
import { b64, call, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";

const instructions = [
  { title: "დაკეტე წყალი", text: "მოატრიალე ონკანი." },
  { title: "მოუშვი ქანჩი", text: "ხელით მოუშვი." },
];

function postParts(body: unknown, overrides = {}) {
  return call(
    "/ai/parts",
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) },
    overrides,
  );
}

afterEach(() => vi.restoreAllMocks());

describe("POST /ai/parts", () => {
  it("sends the Astra C payload and renumbers IDs by center y, then x", async () => {
    let sent: Record<string, any> = {};
    mockFetch((url, init) => {
      expect(url).toBe("https://api.openai.com/v1/responses");
      expect(new Headers(init.headers).get("authorization")).toBe("Bearer test-key");
      sent = JSON.parse(String(init.body));
      return Response.json(
        responseBody({
          object: "სიფონი",
          parts: [
            { label: "ქვედა მილი", box: [100, 600, 300, 800] },
            { label: "ზედა მარჯვენა ქანჩი", box: [600, 100, 700, 200] },
            { label: "ზედა მარცხენა ქანჩი", box: [100, 100, 200, 200] },
          ],
        }),
      );
    });

    const res = await postParts({ image: b64(fakeJpeg(512, 768)), instructions });
    expect(res.status).toBe(200);
    const body = await res.json<any>();
    expect(body.object).toBe("სიფონი");
    expect(body.parts).toEqual([
      { id: "p1", name: "ზედა მარცხენა ქანჩი", box: [100, 100, 200, 200] },
      { id: "p2", name: "ზედა მარჯვენა ქანჩი", box: [600, 100, 700, 200] },
      { id: "p3", name: "ქვედა მილი", box: [100, 600, 300, 800] },
    ]);
    // 3 normal + 1024 cached input at $10/$1, 227 output at $50 per 1M.
    expect(body.costUsd).toBeCloseTo((3 * 10 + 1024 * 1 + 227 * 50) / 1e6, 10);
    expect(body.usage.output_tokens).toBe(227);
    expect(typeof body.latencyMs).toBe("number");

    expect(sent.model).toBe("gpt-6-astra");
    expect(sent.store).toBe(false);
    expect(sent.stream).toBeUndefined();
    expect(sent.reasoning).toEqual({ effort: "low" });
    expect(sent.max_output_tokens).toBe(1200);
    expect(sent.text.format).toEqual({ type: "json_schema", name: "variant_c_parts", strict: true, schema: schemaParts() });
    const [text, image] = sent.input[0].content;
    expect(text).toEqual({ type: "input_text", text: promptParts(instructions) });
    expect(image.type).toBe("input_image");
    expect(image.detail).toBe("high");
    expect(image.image_url.startsWith("data:image/jpeg;base64,")).toBe(true);
  });

  it("accepts multipart with free-text instructions", async () => {
    let prompt = "";
    mockFetch((_url, init) => {
      prompt = JSON.parse(String(init.body)).input[0].content[0].text;
      return Response.json(responseBody({ object: "ძრავა", parts: [{ label: "ზეთის საცობი", box: [1, 2, 3, 4] }] }));
    });
    const form = new FormData();
    form.set("image", new Blob([fakeJpeg(768, 576)], { type: "image/jpeg" }), "frame.jpg");
    form.set("instructions", "ზეთი შეამოწმე");
    const res = await call("/ai/parts", { method: "POST", body: form });
    expect(res.status).toBe(200);
    expect(prompt.endsWith('\n"ზეთი შეამოწმე"')).toBe(true);
    expect((await res.json<any>()).parts[0].id).toBe("p1");
  });

  it.each([
    ["x1 >= x2", [500, 100, 400, 200]],
    ["y1 >= y2", [100, 300, 200, 300]],
    ["out of range", [0, 0, 1001, 10]],
    ["three numbers", [0, 0, 10]],
  ])("rejects a bad model box (%s) with a Georgian 502", async (_name, box) => {
    mockFetch(() => Response.json(responseBody({ object: "x", parts: [{ label: "ნაწილი", box }] })));
    const res = await postParts({ image: b64(fakeJpeg(512, 512)), instructions });
    expect(res.status).toBe(502);
    const body = await res.json<any>();
    expect(body.error.code).toBe("ai_invalid_response");
    expect(body.error.message).toMatch(/[ა-ჰ]/);
  });

  it("rejects more than 12 parts", async () => {
    const parts = Array.from({ length: 13 }, (_, i) => ({ label: `ნაწილი ${i}`, box: [i, i, i + 10, i + 10] }));
    mockFetch(() => Response.json(responseBody({ object: "x", parts })));
    const res = await postParts({ image: b64(fakeJpeg(512, 512)), instructions });
    expect(res.status).toBe(502);
  });

  it("maps incomplete responses and upstream errors to 502", async () => {
    mockFetch(() => Response.json(responseBody({ object: "x", parts: [] }, "incomplete")));
    expect((await postParts({ image: b64(fakeJpeg(64, 64)), instructions })).status).toBe(502);
    vi.restoreAllMocks();
    mockFetch(() => new Response("rate limited", { status: 429 }));
    const res = await postParts({ image: b64(fakeJpeg(64, 64)), instructions });
    expect(res.status).toBe(502);
    expect((await res.json<any>()).error.code).toBe("ai_upstream");
  });

  it("validates the request before paying for a call", async () => {
    const spy = mockFetch(() => Response.json({}));
    expect((await postParts({ image: b64(fakeJpeg(1024, 768)), instructions })).status).toBe(400);
    expect((await postParts({ image: b64(new Uint8Array([0x89, 0x50, 0x4e, 0x47])), instructions })).status).toBe(400);
    expect((await postParts({ image: b64(fakeJpeg(512, 512)) })).status).toBe(400);
    expect((await postParts({ image: b64(fakeJpeg(512, 512)), instructions }, { OPENAI_API_KEY: "" })).status).toBe(500);
    expect((await postParts({ image: b64(fakeJpeg(512, 512)), instructions }, { AI_PROVIDER: "hybrid" })).status).toBe(501);
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("Astra C port", () => {
  it("assignIds breaks center ties by box then label, never by model order", () => {
    const a = { label: "ბ", box: [0, 0, 10, 10] };
    const b = { label: "ა", box: [0, 0, 10, 10] };
    const c = { label: "გ", box: [2, 2, 8, 8] };
    expect(assignIds([a, c, b]).map((p) => p.name)).toEqual(["ა", "ბ", "გ"]);
  });

  it("pyDumps matches Python json.dumps(ensure_ascii=False)", () => {
    expect(pyDumps([{ title: "ა\"ბ", text: "x\ny" }, { n: 1.5, z: null }])).toBe(
      '[{"title": "ა\\"ბ", "text": "x\\ny"}, {"n": 1.5, "z": null}]',
    );
  });

  it("estimateCost follows vision.py", () => {
    const usage = { input_tokens: 3118, input_tokens_details: { cache_write_tokens: 3115, cached_tokens: 0 }, output_tokens: 1303 };
    expect(estimateCost(usage, "gpt-6-astra")).toBeCloseTo((3 * 10 + 3115 * 12.5 + 1303 * 50) / 1e6, 10);
    expect(estimateCost(usage, "unknown-model")).toBeNull();
    expect(estimateCost({ ...usage, input_tokens: 200_001 }, "gpt-6-astra")).toBeNull();
    expect(estimateCost({ ...usage, input_tokens_details: { audio_tokens: 5 } }, "gpt-6-astra")).toBeNull();
  });
});
