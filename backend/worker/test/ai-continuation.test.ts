import { afterEach, describe, expect, it, vi } from "vitest";
import { promptParts, promptSteps } from "../src/ai/prompts";
import { LIMITS, schemaSteps, softened, validateSchema } from "../src/ai/schema";
import { MAX_ROUNDS, parseContext, tidyContinuation } from "../src/ai/validate";
import { answerTurnLimit } from "../src/limits";
import { readStepsInput } from "../src/ai/steps";
import { readSse } from "../src/sse";
import { b64, call, diagnosticContinuation, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";

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

it("locks the legacy prompt and schema", async () => {
  const digest = async (value: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))), b => b.toString(16).padStart(2, "0")).join("");
  expect(await digest(promptSteps("x", [], "ზეთი", undefined, { count: 5 }))).toMatchInlineSnapshot(`"e1559541892bd01a6981fa9a97da361c0699a5353da2fa4750706b635cf09f3b"`);
  expect(await digest(JSON.stringify(schemaSteps(["p1"], 5, { freeText: true })))).toMatchInlineSnapshot(`"b8071c946144f73c67a33ff2b09856ca7146e17ef0f7a2c961dda0e48d2f44cd"`);
});

const capabilities = ["needs_answer", "needs_measurement", "summary"];
const answers = [{ question: "ჩართულია?", answer: "დიახ" }];
const diagnosticOptions = { capabilities };

describe("diagnostic request", () => {
  it("accepts answer follow-ups on the same first photo", async () => {
    const value = { round: 1, doneSteps: ["ჩართე"], answers };
    expect(parseContext(value)).toEqual({ ...value, photoPrompt: "" });
    const input = await readStepsInput(new Request("https://example.com/ai/steps", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ object: "x", parts, instructions: "x", capabilities: [...capabilities, "future", "summary"], context: value }),
    }));
    expect(input.capabilities).toEqual(capabilities);
    expect(input.context?.answers).toEqual(answers);
    expect(input.count).toBe(5);
  });

  it.each([null, "summary", [1], Array(9).fill("summary")])("rejects malformed capabilities %j", async caps => {
    expect((await postSteps({ object: "x", parts, instructions: "x", capabilities: caps })).status).toBe(400);
  });

  it.each([
    [], Array(9).fill(answers[0]), [{ question: "q", answer: "a".repeat(121) }],
    [{ question: "q".repeat(121), answer: "a" }], [{ question: "q", answer: "a", unit: "x".repeat(13) }],
    [{ question: "q", answer: " " }], [null], "bad",
  ])("rejects invalid round-one answers %j", bad => {
    expect(() => parseContext({ round: 1, doneSteps: [], answers: bad })).toThrow();
  });

  it("allows eight answers and validates later-photo context", () => {
    expect(parseContext({ ...context, answers: Array(8).fill({ question: "q", answer: "1", unit: "V" }) })?.answers).toHaveLength(8);
    expect(() => parseContext({ round: 2, doneSteps: [], answers })).toThrow();
  });
});

describe("diagnostic schema and tidying", () => {
  it("has one strict nullable object and gates each capability", () => {
    const c = (schemaSteps(["p1"], 5, diagnosticOptions).properties as any).continuation;
    expect(c.required).toEqual(["kind", "prompt", "reason", "question", "options", "allowOther", "unit", "min", "max", "how", "cause", "summary"]);
    expect(c.additionalProperties).toBe(false);
    expect(c.properties.kind.enum).toEqual(["complete", "needs_photo", "needs_answer", "needs_measurement"]);
    for (const name of ["prompt", "reason", "question", "unit", "how", "cause", "summary"]) expect(c.properties[name].type).toEqual(["string", "null"]);
    expect(validateSchema(c, diagnosticContinuation())).toBeNull();
    const limited = (schemaSteps([], 5, { ...diagnosticOptions, answerCount: 6 }).properties as any).continuation;
    expect(limited.properties.kind.enum).toEqual(["complete", "needs_photo"]);
    const last = (schemaSteps([], 5, { ...diagnosticOptions, lastRound: true }).properties as any).continuation;
    expect(last.properties.kind.enum).toEqual(["complete", "needs_answer", "needs_measurement"]);
    const single = (schemaSteps([], 5, { capabilities: ["needs_answer"] }).properties as any).continuation;
    expect(single.properties.kind.enum).toEqual(["complete", "needs_photo", "needs_answer"]);
    expect(single.properties.summary).toEqual({ type: "null" });
    expect(schemaSteps([], 5, { capabilities: ["future"] })).toEqual(schemaSteps([], 5));
  });

  it("clamps, deduplicates and defaults answer options", () => {
    const result = tidyContinuation(diagnosticContinuation({ question: "q".repeat(100), options: ["a", "a", "b".repeat(40), "c", "d", "e"], allowOther: null, reason: "r".repeat(120) }), diagnosticOptions) as any;
    expect(result.options).toHaveLength(4);
    expect(result.options[1]).toHaveLength(24);
    expect(result.question).toHaveLength(80);
    expect(result.reason).toHaveLength(100);
    expect(result.allowOther).toBe(true);
    expect(tidyContinuation(diagnosticContinuation({ options: ["a", "a", " "] }), diagnosticOptions).kind).toBe("complete");
    expect(tidyContinuation(diagnosticContinuation(), { ...diagnosticOptions, answerCount: 6 }).kind).toBe("complete");
    expect(tidyContinuation(diagnosticContinuation()).kind).toBe("complete");
  });

  it("validates measurements and completion summaries", () => {
    const measurement = { kind: "needs_measurement", question: "ძაბვა?", unit: " V ", min: 0, max: 12, how: "გაზომე", reason: null };
    expect(tidyContinuation(measurement, diagnosticOptions)).toEqual({ ...measurement, unit: "V" });
    expect(tidyContinuation({ ...measurement, unit: " " }, diagnosticOptions).kind).toBe("complete");
    expect(tidyContinuation({ ...measurement, min: NaN, max: Infinity }, diagnosticOptions)).toMatchObject({ min: null, max: null });
    expect(tidyContinuation(measurement, { ...diagnosticOptions, answerCount: 6 }).kind).toBe("complete");
    expect(tidyContinuation({ kind: "complete", cause: "c".repeat(100), summary: "s".repeat(150) }, diagnosticOptions)).toMatchObject({ cause: "c".repeat(79) + "…", summary: "s".repeat(119) + "…" });
    expect(tidyContinuation({ kind: "complete", cause: "c", summary: "s" })).toEqual({ kind: "complete" });
    expect(tidyContinuation({ kind: "unknown" }, diagnosticOptions)).toEqual({ kind: "complete", cause: null, summary: null });
  });

  it("reads the configurable answer limit with a safe default", () => {
    expect(answerTurnLimit({})).toBe(6);
    for (const raw of ["0", "-1", "bad", "Infinity"]) expect(answerTurnLimit({ ANSWER_TURN_LIMIT: raw })).toBe(6);
    expect(answerTurnLimit({ ANSWER_TURN_LIMIT: "2" })).toBe(2);
  });
});

describe("diagnostic SSE", () => {
  it.each([
    [{}, { kind: "needs_answer", question: "ჩართულია?", options: ["დიახ", "არა"], allowOther: true, reason: null }],
    [{ kind: "needs_measurement", question: "ძაბვა?", options: [], unit: "V", min: 0, max: 12, how: "გაზომე" }, { kind: "needs_measurement", question: "ძაბვა?", unit: "V", min: 0, max: 12, how: "გაზომე", reason: null }],
    [{ kind: "complete", cause: "დაცლილი ელემენტი", summary: "შეცვალე ელემენტი" }, { kind: "complete", cause: "დაცლილი ელემენტი", summary: "შეცვალე ელემენტი" }],
  ])("streams the negotiated continuation %j", async (fields, expected) => {
    upstreamSteps({ steps: [step], unknown_parts: [], continuation: diagnosticContinuation(fields) });
    const result = await doneOf(await postSteps({ object: "x", parts, instructions: "x", capabilities, context: { round: 1, doneSteps: [], answers } }));
    expect(result.steps).toHaveLength(1);
    expect(result.done.continuation).toEqual(expected);
  });

  it("allows answers on the last photo", async () => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: diagnosticContinuation() });
    const { done } = await doneOf(await postSteps({ object: "x", parts, instructions: "x", capabilities, context: { ...context, round: 5 } }));
    expect(done.continuation.kind).toBe("needs_answer");
    expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).not.toContain("needs_photo");
  });

  it.each(["needs_answer", "needs_measurement"])("suppresses %s at the answer limit even if the model disobeys", async kind => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: diagnosticContinuation({ kind, unit: "V" }) });
    const { done } = await doneOf(await postSteps({ object: "x", parts, instructions: "x", capabilities, context: { round: 1, doneSteps: [], answers: Array(6).fill(answers[0]) } }));
    expect(done.continuation).toEqual({ kind: "complete", cause: null, summary: null });
    expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).toEqual(["complete", "needs_photo"]);
  });

  it("uses ANSWER_TURN_LIMIT from Env", async () => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: diagnosticContinuation() });
    const { done } = await doneOf(await call("/ai/steps", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ object: "x", parts, instructions: "x", capabilities, context: { round: 1, doneSteps: [], answers } }),
    }, { ANSWER_TURN_LIMIT: "1" }));
    expect(done.continuation.kind).toBe("complete");
    expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).toEqual(["complete", "needs_photo"]);
  });

  it("preserves the exact legacy schema, prompt and done continuation", async () => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: { kind: "complete", prompt: null, reason: null } });
    for (const caps of [undefined, [], ["future"]]) {
      const { done } = await doneOf(await postSteps({ object: "x", parts, instructions: "x", capabilities: caps }));
      expect(done.continuation).toEqual({ kind: "complete" });
    }
    expect(sent[0]).toEqual(sent[1]);
    expect(sent[0]).toEqual(sent[2]);
  });
});
