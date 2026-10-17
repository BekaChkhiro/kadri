import { afterEach, describe, expect, it, vi } from "vitest";
import { promptParts, promptSteps } from "../src/ai/prompts";
import { LIMITS, schemaSteps, softened, validateSchema } from "../src/ai/schema";
import { MAX_ROUNDS, parseContext, tidyContinuation } from "../src/ai/validate";
import { readSse } from "../src/sse";
import { b64, call, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";

const parts = [
  { id: "p1", name: "სიფონის ქანჩი", box: [100, 100, 300, 400] },
  { id: "p2", name: "ვედრო", box: [400, 500, 700, 900] },
];
const step = {
  title: "მოუშვი ქანჩი",
  text: "ხელით, საათის ისრის საწინააღმდეგოდ.",
  focus: ["p1"],
  avoid: [],
  markers: [],
  arrows: [{ part: "p1", type: "rotate", dir: "ccw" }],
  icon: "unscrew",
  tools: [],
  tip: null,
  warn: null,
};
const context = {
  round: 2,
  photoPrompt: "გადაიღე მოხსნილი სიფონის შიგნითა მხარე ახლოდან",
  doneSteps: ["დაკეტე წყალი", "ჩადგი ვედრო", "მოუშვი ქანჩი"],
  previousObject: "ნიჟარის სიფონი",
};

const enc = new TextEncoder();
const frame = (data: any) => enc.encode(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);

/** Mocks a streamed steps call whose output is `result`; returns the sent payloads. */
function upstreamSteps(result: unknown) {
  const sent: any[] = [];
  mockFetch((_url, init) => {
    sent.push(JSON.parse(String(init.body)));
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(frame({ type: "response.output_text.delta", delta: JSON.stringify(result) }));
        c.enqueue(frame({ type: "response.completed", response: responseBody(result) }));
        c.close();
      },
    });
    return new Response(body, { headers: { "content-type": "text/event-stream" } });
  });
  return sent;
}

function postSteps(body: unknown) {
  return call("/ai/steps", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
}

function postParts(body: unknown) {
  return call("/ai/parts", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
}

async function doneOf(res: Response) {
  const events: Array<{ event: string | null; data: any }> = [];
  for await (const m of readSse(res.body!)) events.push({ event: m.event, data: JSON.parse(m.data) });
  expect(events.at(-1)!.event).toBe("done");
  return { steps: events.filter((e) => e.event === "step"), done: events.at(-1)!.data };
}

afterEach(() => vi.restoreAllMocks());

describe("parseContext", () => {
  it("accepts an object or a JSON string, and absent means round 1", () => {
    expect(parseContext(undefined)).toBeUndefined();
    expect(parseContext(null)).toBeUndefined();
    expect(parseContext("")).toBeUndefined();
    expect(parseContext(context)).toEqual(context);
    expect(parseContext(JSON.stringify(context))).toEqual(context);
    const { previousObject: _, ...bare } = context;
    expect(parseContext({ ...bare, doneSteps: [] })).toEqual({ ...bare, doneSteps: [] });
  });

  it.each([
    ["round 1", { ...context, round: 1 }],
    ["round 6", { ...context, round: MAX_ROUNDS + 1 }],
    ["round not an integer", { ...context, round: 2.5 }],
    ["round as a string", { ...context, round: "2" }],
    ["empty photoPrompt", { ...context, photoPrompt: "  " }],
    ["long photoPrompt", { ...context, photoPrompt: "ა".repeat(201) }],
    ["more than 40 doneSteps", { ...context, doneSteps: Array.from({ length: 41 }, () => "ნაბიჯი") }],
    ["long doneStep", { ...context, doneSteps: ["ა".repeat(121)] }],
    ["doneSteps missing", { round: 2, photoPrompt: "გადაიღე" }],
    ["long previousObject", { ...context, previousObject: "ა".repeat(301) }],
    ["not an object", [context]],
    ["broken JSON", "{round: 2"],
  ])("rejects %s with a Georgian 400", (_name, raw) => {
    let err: any;
    try {
      parseContext(raw);
    } catch (e) {
      err = e;
    }
    expect(err?.status).toBe(400);
    expect(err.message).toMatch(/[ა-ჰ]/);
  });
});

describe("tidyContinuation", () => {
  it("falls back to complete and clamps texts", () => {
    expect(tidyContinuation(undefined)).toEqual({ kind: "complete" });
    expect(tidyContinuation({ kind: "complete", prompt: null, reason: null })).toEqual({ kind: "complete" });
    expect(tidyContinuation({ kind: "needs_photo", prompt: null, reason: "რატომ" })).toEqual({ kind: "complete" });
    expect(tidyContinuation({ kind: "needs_photo", prompt: "   ", reason: "რატომ" })).toEqual({ kind: "complete" });
    expect(tidyContinuation({ kind: "maybe", prompt: "გადაიღე" })).toEqual({ kind: "complete" });
    expect(tidyContinuation({ kind: "needs_photo", prompt: "გადაიღე", reason: null })).toEqual({
      kind: "needs_photo",
      prompt: "გადაიღე",
      reason: "",
    });
  });
});

describe("schemaSteps continuation", () => {
  it("adds continuation after steps; only complete on the last round", () => {
    const schema = schemaSteps(["p1"], 5) as any;
    expect(Object.keys(schema.properties)).toEqual(["steps", "unknown_parts", "continuation"]);
    expect(schema.required).toContain("continuation");
    const c = schema.properties.continuation;
    expect(c.required).toEqual(["kind", "prompt", "reason"]);
    expect(c.additionalProperties).toBe(false);
    expect(c.properties.kind.enum).toEqual(["complete", "needs_photo"]);
    expect(c.properties.prompt).toEqual({ type: ["string", "null"], maxLength: LIMITS.photoPrompt });
    expect(c.properties.reason).toEqual({ type: ["string", "null"], maxLength: LIMITS.photoReason });
    expect((schemaSteps(["p1"], 5, { lastRound: true }) as any).properties.continuation.properties.kind.enum).toEqual(["complete"]);
    expect((softened(schema) as any).properties.continuation.properties.prompt.maxLength).toBeUndefined();
  });

  it("free text allows 1..count steps, a list exactly count", () => {
    const free = (schemaSteps(["p1"], 5, { freeText: true }) as any).properties.steps;
    expect([free.minItems, free.maxItems]).toEqual([1, 5]);
    const list = (schemaSteps(["p1"], 5) as any).properties.steps;
    expect([list.minItems, list.maxItems]).toEqual([5, 5]);
    const c = { kind: "complete", prompt: null, reason: null };
    expect(validateSchema(softened(schemaSteps(["p1"], 5, { freeText: true })), { steps: [step], unknown_parts: [], continuation: c })).toBeNull();
  });
});

describe("prompts with context", () => {
  it("parts and steps prompts carry the done steps and the photo request", () => {
    for (const prompt of [
      promptParts("ნიჟარა ჟონავს", context),
      promptSteps("მოხსნილი სიფონი", [], "ნიჟარა ჟონავს", context, { count: 5 }),
    ]) {
      for (const done of context.doneSteps) expect(prompt).toContain(done);
      expect(prompt).toContain(context.photoPrompt);
      expect(prompt).toContain("მე-2");
    }
    expect(promptParts("ნიჟარა ჟონავს", context)).toContain('"previousObject": "ნიჟარის სიფონი"');
    // Round 1 keeps the old payload.
    expect(promptParts("ზეთი").endsWith('\n"ზეთი"')).toBe(true);
  });

  it("steps prompt asks for a decision, except on the last round; steps stay the first key", () => {
    const first = promptSteps("x", [], "ზეთი", undefined, { count: 5 });
    expect(first).toContain("needs_photo მხოლოდ მაშინ");
    expect(first).toContain("ჩვეულებრივ 5 ნაბიჯი");
    const last = promptSteps("x", [], "ზეთი", { ...context, round: MAX_ROUNDS });
    expect(last).not.toContain("needs_photo მხოლოდ მაშინ");
    expect(last).toContain("ახალი ფოტო აღარ შეიძლება");
    for (const p of [first, last]) expect(p).toContain("პირველი JSON გასაღები იყოს steps.");
  });
});

describe("POST /ai/steps continuation", () => {
  it("sends needs_photo in done with clamped texts", async () => {
    const sent = upstreamSteps({
      steps: [step],
      unknown_parts: ["შუასადები"],
      continuation: { kind: "needs_photo", prompt: "გადაიღე ".repeat(20), reason: "მიზეზი ".repeat(30) },
    });
    const { steps, done } = await doneOf(await postSteps({ object: "სიფონი", parts, instructions: "ნიჟარა ჟონავს" }));
    expect(steps).toHaveLength(1);
    expect(done.continuation.kind).toBe("needs_photo");
    expect([...done.continuation.prompt].length).toBeLessThanOrEqual(LIMITS.photoPrompt);
    expect([...done.continuation.reason].length).toBeLessThanOrEqual(LIMITS.photoReason);
    expect(done.unknownParts).toEqual(["შუასადები"]);
    // Free text: up to 5 steps, the round may stop early.
    expect(sent[0].text.format.schema.properties.steps.minItems).toBe(1);
    expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).toEqual(["complete", "needs_photo"]);
  });

  it("needs_photo without a prompt, or a missing continuation, is complete", async () => {
    upstreamSteps({ steps: [step], unknown_parts: [], continuation: { kind: "needs_photo", prompt: null, reason: "x" } });
    expect((await doneOf(await postSteps({ object: "სიფონი", parts, instructions: "ჟონავს" }))).done.continuation).toEqual({ kind: "complete" });
    vi.restoreAllMocks();
    upstreamSteps({ steps: [step], unknown_parts: [] });
    expect((await doneOf(await postSteps({ object: "სიფონი", parts, instructions: "ჟონავს" }))).done.continuation).toEqual({ kind: "complete" });
  });

  it("passes context to the prompt and only allows complete on round 5", async () => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: { kind: "complete", prompt: null, reason: null } });
    await doneOf(await postSteps({ object: "სიფონი", parts, instructions: "ჟონავს", context }));
    await doneOf(await postSteps({ object: "სიფონი", parts, instructions: "ჟონავს", context: { ...context, round: 5 } }));
    const prompt = sent[0].input[0].content[0].text as string;
    expect(prompt).toContain(context.photoPrompt);
    expect(prompt).toContain("„მოუშვი ქანჩი“");
    expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).toEqual(["complete", "needs_photo"]);
    expect(sent[1].text.format.schema.properties.continuation.properties.kind.enum).toEqual(["complete"]);
  });

  it("rejects a bad context with 400 before calling the model", async () => {
    const spy = mockFetch(() => new Response(""));
    for (const bad of [{ ...context, round: 1 }, { ...context, round: 6 }, { ...context, photoPrompt: "" }]) {
      const res = await postSteps({ object: "სიფონი", parts, instructions: "ჟონავს", context: bad });
      expect(res.status).toBe(400);
    }
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("POST /ai/parts context", () => {
  const model = { object: "მოხსნილი სიფონი", parts: [{ label: "შუასადები", box: [1, 2, 3, 4] }] };

  it("reads context from a multipart JSON string", async () => {
    let prompt = "";
    mockFetch((_url, init) => {
      prompt = JSON.parse(String(init.body)).input[0].content[0].text;
      return Response.json(responseBody(model));
    });
    const form = new FormData();
    form.set("image", new Blob([fakeJpeg(768, 576)], { type: "image/jpeg" }), "frame.jpg");
    form.set("instructions", "ნიჟარა ჟონავს");
    form.set("context", JSON.stringify(context));
    const res = await call("/ai/parts", { method: "POST", body: form });
    expect(res.status).toBe(200);
    expect((await res.json<any>()).object).toBe("მოხსნილი სიფონი");
    expect(prompt.startsWith("ეს არის იმავე დავალების მე-2 ფოტო.")).toBe(true);
    for (const done of context.doneSteps) expect(prompt).toContain(done);
    expect(prompt).toContain(context.photoPrompt);
  });

  it("reads context from JSON and rejects a bad one with 400", async () => {
    let prompt = "";
    const spy = mockFetch((_url, init) => {
      prompt = JSON.parse(String(init.body)).input[0].content[0].text;
      return Response.json(responseBody(model));
    });
    const image = b64(fakeJpeg(512, 512));
    expect((await postParts({ image, instructions: "ჟონავს", context })).status).toBe(200);
    expect(prompt).toContain(context.photoPrompt);
    expect(spy).toHaveBeenCalledTimes(1);
    const form = new FormData();
    form.set("image", new Blob([fakeJpeg(64, 64)], { type: "image/jpeg" }), "frame.jpg");
    form.set("instructions", "ჟონავს");
    form.set("context", "{not json");
    expect((await call("/ai/parts", { method: "POST", body: form })).status).toBe(400);
    expect((await postParts({ image, instructions: "ჟონავს", context: { ...context, doneSteps: "x" } })).status).toBe(400);
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("an old body without context is unchanged", async () => {
    let prompt = "";
    mockFetch((_url, init) => {
      prompt = JSON.parse(String(init.body)).input[0].content[0].text;
      return Response.json(responseBody(model));
    });
    expect((await postParts({ image: b64(fakeJpeg(512, 512)), instructions: "ჟონავს" })).status).toBe(200);
    expect(prompt).toBe(promptParts("ჟონავს"));
  });
});
