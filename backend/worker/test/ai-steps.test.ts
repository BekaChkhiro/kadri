import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../src/errors";
import { promptSteps } from "../src/ai/prompts";
import { AstraProvider } from "../src/ai/provider";
import { schemaSteps, stepItemSchema } from "../src/ai/schema";
import { StepsStreamParser } from "../src/ai/stepsParser";
import { readSse, sseEvent, SSE_HEADERS } from "../src/sse";
import { call, mockFetch, responseBody } from "./ai-helpers";

const parts = [
  { id: "p1", name: "მარცხენა ონკანი", box: [12, 255, 98, 320] },
  { id: "p2", name: "სიფონის ქანჩი", box: [619, 250, 748, 385] },
];
const instructions = [
  { title: "დაკეტე წყალი", text: "მოატრიალე ონკანი." },
  { title: "მოუშვი ქანჩი", text: "ხელით მოუშვი." },
];
const step1 = {
  title: "დაკეტე წყალი",
  text: "მოატრიალე ონკანი საათის ისრის მიმართულებით.",
  focus: ["p1"],
  avoid: [],
  markers: [{ part: "p1", label: "ონკანი {ჯერ}", tone: "brand" }],
  arrows: [{ part: "p1", type: "rotate", dir: "cw" }],
  tools: [],
  warn: null,
};
const step2 = { ...step1, title: "მოუშვი ქანჩი", text: "ხელით, \"საწინააღმდეგოდ\".", focus: ["p2"], markers: [], arrows: [{ part: "p2", type: "rotate", dir: "ccw" }] };
const result = { steps: [step1, step2], unknown_parts: ["ვედრო"] };

const enc = new TextEncoder();
const frame = (data: unknown) => enc.encode(`event: ${(data as any).type}\ndata: ${JSON.stringify(data)}\n\n`);
const delta = (d: string) => frame({ type: "response.output_text.delta", delta: d });
const completed = (status = "completed") => {
  const r = responseBody(result, status);
  return frame({ type: `response.${status}`, response: r });
};

/** An upstream body the test feeds by hand. */
function controlledUpstream() {
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  const body = new ReadableStream<Uint8Array>({ start: (c) => void (controller = c) });
  return { body, push: (b: Uint8Array) => controller.enqueue(b), close: () => controller.close() };
}

function postSteps(body: unknown) {
  return call("/ai/steps", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
}

async function collect(res: Response) {
  const events: Array<{ event: string | null; data: any }> = [];
  for await (const m of readSse(res.body!)) events.push({ event: m.event, data: JSON.parse(m.data) });
  return events;
}

afterEach(() => vi.restoreAllMocks());

describe("StepsStreamParser", () => {
  it("returns each step only once its object is complete, across arbitrary chunks", () => {
    const text = JSON.stringify(result, null, 1);
    const parser = new StepsStreamParser();
    const seen: Array<{ at: number; step: unknown }> = [];
    for (let i = 0; i < text.length; i += 7) {
      for (const s of parser.push(text.slice(i, i + 7))) seen.push({ at: i + 7, step: s });
    }
    expect(seen.map((s) => s.step)).toEqual([step1, step2]);
    // The first step is emitted before the second step's text has fully arrived.
    const secondEnd = text.lastIndexOf("}", text.indexOf('"unknown_parts"')) + 1;
    expect(seen[0]!.at).toBeLessThan(secondEnd);
    expect(seen[1]!.at).toBeGreaterThanOrEqual(secondEnd);
    expect(parser.fallback).toBe(false);
  });

  it("handles braces and escaped quotes inside strings, one character at a time", () => {
    const parser = new StepsStreamParser();
    const out: unknown[] = [];
    for (const ch of JSON.stringify(result)) out.push(...parser.push(ch));
    expect(out).toEqual([step1, step2]);
  });

  it("switches to fallback when steps is not the first key", () => {
    const parser = new StepsStreamParser();
    expect(parser.push('{"unknown_parts": [], "steps": [')).toEqual([]);
    expect(parser.fallback).toBe(true);
  });
});

describe("schemaSteps", () => {
  it("limits every ID reference to the given parts and fixes the step count", () => {
    const schema = schemaSteps(["p1", "p2"], 3) as any;
    expect(Object.keys(schema.properties)).toEqual(["steps", "unknown_parts"]);
    expect(schema.properties.steps.minItems).toBe(3);
    expect(schema.properties.steps.maxItems).toBe(3);
    const step = schema.properties.steps.items.properties;
    expect(step.focus.items.enum).toEqual(["p1", "p2"]);
    expect(step.avoid.items.enum).toEqual(["p1", "p2"]);
    expect(step.markers.items.properties.part.enum).toEqual(["p1", "p2"]);
    expect(step.arrows.items.properties.part.enum).toEqual(["p1", "p2"]);
    expect(step.focus.description).toMatch(/^მოქმედების სამიზნე/);
    expect(step.warn.type).toEqual(["string", "null"]);
    expect(schema.additionalProperties).toBe(false);
  });

  it("replaces enums with empty arrays when there are no parts", () => {
    const step = (stepItemSchema([]) as any).properties;
    for (const f of ["focus", "avoid", "markers", "arrows"]) {
      expect(step[f]).toEqual({ type: "array", items: { type: "string" }, maxItems: 0 });
    }
  });
});

describe("SSE", () => {
  it("formats one event per frame", () => {
    expect(sseEvent("step", { index: 0, title: "ა" })).toBe('event: step\ndata: {"index":0,"title":"ა"}\n\n');
  });

  it("parses CRLF, comments, multi-line data and frames split across chunks", async () => {
    const chunks = [": ping\r\nevent: a\r\ndata: {\"x\"", ":1}\r", "\n\r\ndata: one\ndata: two\n\n"];
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        for (const ch of chunks) c.enqueue(enc.encode(ch));
        c.close();
      },
    });
    const out = [];
    for await (const m of readSse(body)) out.push(m);
    expect(out).toEqual([
      { event: "a", data: '{"x":1}' },
      { event: null, data: "one\ntwo" },
    ]);
  });
});

describe("POST /ai/steps", () => {
  it("streams the first step before the second step arrives (acceptance)", async () => {
    const upstream = controlledUpstream();
    let sent: any;
    mockFetch((_url, init) => {
      sent = JSON.parse(String(init.body));
      return new Response(upstream.body, { headers: { "content-type": "text/event-stream" } });
    });
    const res = await postSteps({ object: "სიფონი", parts, instructions });
    expect(res.status).toBe(200);
    for (const [k, v] of Object.entries(SSE_HEADERS)) expect(res.headers.get(k)).toBe(v);

    const text = JSON.stringify(result);
    const cut = text.indexOf('"მოუშვი ქანჩი"');
    upstream.push(frame({ type: "response.created", response: { status: "in_progress" } }));
    upstream.push(delta(text.slice(0, 20)));
    upstream.push(delta(text.slice(20, cut)));

    const events = readSse(res.body!);
    const first = await events.next();
    expect(first.value!.event).toBe("step");
    expect(JSON.parse(first.value!.data)).toEqual({ index: 0, ...step1 });

    upstream.push(delta(text.slice(cut)));
    upstream.push(completed());
    upstream.close();
    const rest = [];
    for await (const m of events) rest.push({ event: m.event, data: JSON.parse(m.data) });
    expect(rest.map((e) => e.event)).toEqual(["step", "done"]);
    expect(rest[0]!.data).toEqual({ index: 1, ...step2 });
    expect(rest[1]!.data.unknownParts).toEqual(["ვედრო"]);
    expect(rest[1]!.data.costUsd).toBeGreaterThan(0);
    expect(typeof rest[1]!.data.firstStepMs).toBe("number");

    expect(sent.stream).toBe(true);
    expect(sent.max_output_tokens).toBe(2200);
    expect(sent.reasoning).toEqual({ effort: "low" });
    expect(sent.text.format.name).toBe("variant_c_steps");
    expect(sent.text.format.schema).toEqual(schemaSteps(["p1", "p2"], 2));
    expect(sent.input[0].content).toEqual([
      {
        type: "input_text",
        text: promptSteps("სიფონი", parts.map((p) => ({ id: p.id, label: p.name, box: p.box })), instructions),
      },
    ]);
  });

  it("falls back to the final JSON when the stream does not start with steps", async () => {
    const reordered = JSON.stringify({ unknown_parts: ["ვედრო"], steps: [step1, step2] });
    mockFetch(() => {
      const body = new ReadableStream<Uint8Array>({
        start(c) {
          c.enqueue(delta(reordered));
          c.enqueue(completed());
          c.close();
        },
      });
      return new Response(body);
    });
    const events = await collect(await postSteps({ object: "სიფონი", parts, instructions }));
    expect(events.map((e) => e.event)).toEqual(["step", "step", "done"]);
  });

  it("sends a Georgian error event for an invalid streamed step", async () => {
    const bad = { steps: [{ ...step1, avoid: ["p1"] }, step2], unknown_parts: [] };
    mockFetch(() => new Response(new ReadableStream({ start: (c) => { c.enqueue(delta(JSON.stringify(bad))); c.close(); } })));
    const events = await collect(await postSteps({ object: "სიფონი", parts, instructions }));
    expect(events.map((e) => e.event)).toEqual(["error"]);
    expect(events[0]!.data.code).toBe("ai_invalid_response");
    expect(events[0]!.data.message).toMatch(/[ა-ჰ]/);
  });

  it("sends an error event when the response is incomplete or upstream fails", async () => {
    mockFetch(() => new Response(new ReadableStream({ start: (c) => { c.enqueue(completed("incomplete")); c.close(); } })));
    let events = await collect(await postSteps({ object: "სიფონი", parts, instructions }));
    expect(events.at(-1)!.data.code).toBe("ai_incomplete");
    vi.restoreAllMocks();
    mockFetch(() => new Response("nope", { status: 500 }));
    events = await collect(await postSteps({ object: "სიფონი", parts, instructions }));
    expect(events).toEqual([{ event: "error", data: { code: "ai_upstream", message: expect.stringMatching(/[ა-ჰ]/) } }]);
  });

  it("rejects bad bodies with 400 before calling the model", async () => {
    const spy = mockFetch(() => new Response(""));
    expect((await postSteps({ object: "x", parts: [{ id: "p1", name: "a", box: [5, 5, 1, 1] }], instructions })).status).toBe(400);
    expect((await postSteps({ object: "x", parts: [{ id: "x1", name: "a", box: [1, 1, 5, 5] }], instructions })).status).toBe(400);
    expect((await postSteps({ object: "x", parts, instructions, count: 0 })).status).toBe(400);
    expect((await postSteps({ object: "x", parts, instructions, image: "AAAA" })).status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("AstraProvider.steps", () => {
  it("times out with a Georgian 504", async () => {
    mockFetch((_url, init) =>
      new Promise<Response>((_resolve, reject) =>
        init.signal!.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError"))),
      ),
    );
    const provider = new AstraProvider({ apiKey: "k", model: "gpt-6-astra", effort: "low", timeoutMs: 20 });
    const gen = provider.steps({ object: "x", parts: [], instructions, count: 2 });
    const err = await gen.next().then(() => null, (e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err.code).toBe("ai_timeout");
    expect(err.status).toBe(504);
  });
});
