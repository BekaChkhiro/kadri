import { afterEach, describe, expect, it, vi } from "vitest";
import { promptSteps } from "../src/ai/prompts";
import { CHECK_PHOTO_LIMIT, LIMITS, schemaSteps, softened, validateSchema } from "../src/ai/schema";
import { readStepsInput } from "../src/ai/steps";
import { parseCapabilities, parseContext, tidyContinuation } from "../src/ai/validate";
import { readSse } from "../src/sse";
import { b64, call, diagnosticContinuation, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";

const parts = [{ id: "p1", name: "CPU სოკეტის ბერკეტი", box: [100, 100, 300, 400] }];
const step = {
  title: "დაკეტე ბერკეტი", text: "ჩამოწიე ბერკეტი სამაგრამდე.", focus: ["p1"], avoid: [], markers: [],
  arrows: [], icon: "press", tools: [], tip: null, warn: null,
};
const diagnostic = ["needs_answer", "needs_measurement", "summary"];
const capabilities = [...diagnostic, "check_photo"];
const answers = [{ question: "ბერკეტი დაკეტილია?", answer: "დიახ" }];
const checkContext = { round: 1, doneSteps: ["დადე CPU"], checkPhotos: 1, checkPrompt: "გადაიღე ბერკეტი ახლოდან" };
const parsedCheckContext = { ...checkContext, photoPrompt: "" };
const checkPhoto = (fields: Record<string, unknown> = {}) =>
  diagnosticContinuation({ kind: "needs_check_photo", prompt: "გადაიღე CPU-ს ბერკეტი ახლოდან", reason: "დაკეტვას შევამოწმებ", question: null, options: [], ...fields });

const enc = new TextEncoder();
const frame = (data: any) => enc.encode(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);

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

const postSteps = (body: unknown) =>
  call("/ai/steps", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

async function doneOf(res: Response) {
  expect(res.status).toBe(200);
  const events: Array<{ event: string | null; data: any }> = [];
  for await (const m of readSse(res.body!)) events.push({ event: m.event, data: JSON.parse(m.data) });
  expect(events.at(-1)!.event).toBe("done");
  return events.at(-1)!.data;
}

afterEach(() => vi.restoreAllMocks());

describe("check_photo request", () => {
  it("is a known capability", () => {
    expect(parseCapabilities(["check_photo", "future"])).toEqual(["check_photo"]);
  });

  it("parses checkPhotos and checkPrompt, also on round 1 without answers", () => {
    expect(parseContext(checkContext)).toEqual(parsedCheckContext);
    expect(parseContext({ ...checkContext, checkPhotos: 0, checkPrompt: "  გადაიღე  " })).toMatchObject({ checkPhotos: 0, checkPrompt: "გადაიღე" });
    expect(parseContext({ ...checkContext, checkPhotos: CHECK_PHOTO_LIMIT })?.checkPhotos).toBe(20);
    // Absent fields stay absent: the legacy context is unchanged.
    expect(parseContext({ round: 1, doneSteps: [], answers })).toEqual({ round: 1, photoPrompt: "", doneSteps: [], answers });
  });

  it.each([
    ["21 photos", { checkPhotos: 21 }], ["negative", { checkPhotos: -1 }], ["fraction", { checkPhotos: 1.5 }],
    ["string count", { checkPhotos: "1" }], ["empty prompt", { checkPrompt: " " }], ["long prompt", { checkPrompt: "ა".repeat(121) }],
    ["round 1 without answers or checkPrompt", { checkPrompt: undefined }],
  ])("rejects %s with a Georgian 400", (_name, fields) => {
    let err: any;
    try {
      parseContext({ ...checkContext, ...fields });
    } catch (e) {
      err = e;
    }
    expect(err?.status).toBe(400);
    expect(err.message).toMatch(/[ა-ჰ]/);
  });

  it("drops check fields without the capability", async () => {
    const read = (caps: string[], context: unknown) => readStepsInput(new Request("https://example.com/ai/steps", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ object: "x", parts, instructions: "x", capabilities: caps, context }),
    }));
    expect((await read(capabilities, checkContext)).context).toEqual(parsedCheckContext);
    expect((await read(diagnostic, { ...checkContext, answers })).context).toEqual({ round: 1, photoPrompt: "", doneSteps: ["დადე CPU"], answers });
    await expect(read(diagnostic, checkContext)).rejects.toMatchObject({ status: 400 });
  });
});

describe("check_photo schema", () => {
  it("adds needs_check_photo and six options; the rest is the old schema", () => {
    const schema = schemaSteps(["p1"], 5, { freeText: true, capabilities }) as any;
    const c = schema.properties.continuation;
    expect(c.properties.kind.enum).toEqual(["complete", "needs_photo", "needs_answer", "needs_measurement", "needs_check_photo"]);
    expect(c.properties.options.maxItems).toBe(6);
    expect(c.properties.prompt.maxLength).toBe(LIMITS.photoPromptV2);
    expect(validateSchema(softened(schema), { steps: [step], unknown_parts: [], continuation: checkPhoto() })).toBeNull();
    const old = schemaSteps(["p1"], 5, { freeText: true, capabilities: diagnostic }) as any;
    c.properties.kind.enum = old.properties.continuation.properties.kind.enum;
    c.properties.options.maxItems = 4;
    expect(schema).toEqual(old);
    expect(schemaSteps(["p1"], 5, { capabilities: diagnostic, checkPhotos: 3 })).toEqual(schemaSteps(["p1"], 5, { capabilities: diagnostic }));
  });

  it("keeps needs_check_photo on the last round and past the answer limit, drops it at 20 photos", () => {
    const kinds = (opts: object) => (schemaSteps([], 5, { capabilities, ...opts }) as any).properties.continuation.properties.kind.enum;
    expect(kinds({ lastRound: true, answerCount: 6 })).toEqual(["complete", "needs_check_photo"]);
    expect(kinds({ checkPhotos: CHECK_PHOTO_LIMIT - 1 })).toContain("needs_check_photo");
    expect(kinds({ checkPhotos: CHECK_PHOTO_LIMIT })).not.toContain("needs_check_photo");
  });
});

describe("check_photo tidyContinuation", () => {
  const opts = { capabilities, checkPhotos: 0 };

  it("passes needs_check_photo with prompt/reason cut at a word", () => {
    expect(tidyContinuation(checkPhoto(), opts)).toEqual({ kind: "needs_check_photo", prompt: "გადაიღე CPU-ს ბერკეტი ახლოდან", reason: "დაკეტვას შევამოწმებ" });
    const long = tidyContinuation(checkPhoto({ prompt: "გადაიღე ".repeat(20), reason: null }), opts) as any;
    expect([...long.prompt].length).toBeLessThanOrEqual(LIMITS.photoPromptV2);
    expect(long.prompt).toMatch(/გადაიღე…$/);
    expect(long.reason).toBe("");
    expect(tidyContinuation(checkPhoto({ prompt: " " }), opts)).toEqual({ kind: "complete", cause: null, summary: null });
    // Not limited by the answer turns.
    expect(tidyContinuation(checkPhoto(), { ...opts, answerCount: 6, lastRound: true }).kind).toBe("needs_check_photo");
  });

  it("at the limit becomes needs_photo, or complete on the last round; unknown without the capability", () => {
    expect(tidyContinuation(checkPhoto(), { ...opts, checkPhotos: 20 })).toEqual({ kind: "needs_photo", prompt: "გადაიღე CPU-ს ბერკეტი ახლოდან", reason: "დაკეტვას შევამოწმებ" });
    expect(tidyContinuation(checkPhoto(), { ...opts, checkPhotos: 20, lastRound: true }).kind).toBe("complete");
    expect(tidyContinuation(checkPhoto(), { capabilities: diagnostic })).toEqual({ kind: "complete", cause: null, summary: null });
  });

  it("ends answer options with „არ ვიცი“ and „ფოტოს გაჩვენებ“, allowOther always", () => {
    const answer = tidyContinuation(diagnosticContinuation({ options: ["დიახ", "არა", "ნაწილობრივ", "ფოტოს გაჩვენებ", "კი", "მეხუთე"], allowOther: false }), opts) as any;
    expect(answer.options).toEqual(["დიახ", "არა", "ნაწილობრივ", "კი", "არ ვიცი", "ფოტოს გაჩვენებ"]);
    expect(answer.allowOther).toBe(true);
    expect(tidyContinuation(diagnosticContinuation({ options: ["დიახ", "არ ვიცი"] }), opts).kind).toBe("complete");
    // Without check_photo the options stay the model's.
    expect((tidyContinuation(diagnosticContinuation({ allowOther: false }), { capabilities: diagnostic }) as any)).toMatchObject({ options: ["დიახ", "არა"], allowOther: false });
  });

  it("turns a repeated question into a check photo, or complete at the limit", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const repeated = diagnosticContinuation({ question: "  ბერკეტი დაკეტილია ?" });
    const asked = { ...opts, askedQuestions: answers.map((a) => a.question) };
    expect(tidyContinuation(repeated, asked)).toEqual({
      kind: "needs_check_photo", prompt: "გადაიღე ახლოდან: ბერკეტი დაკეტილია ?", reason: "ეს კითხვა უკვე იყო, ფოტოთი გადავამოწმებ",
    });
    expect(warn).toHaveBeenCalledTimes(1);
    expect(tidyContinuation(repeated, { ...asked, checkPhotos: 20 })).toEqual({ kind: "complete", cause: null, summary: null });
    const long = tidyContinuation(diagnosticContinuation({ question: "ა ".repeat(40) }), { ...opts, askedQuestions: ["ა ".repeat(40)] }) as any;
    expect([...long.prompt].length).toBeLessThanOrEqual(LIMITS.photoPromptV2);
    expect(tidyContinuation(diagnosticContinuation(), asked).kind).toBe("needs_answer");
  });
});

describe("check_photo prompt", () => {
  it("explains check photos, assembly mode and answer options only with the capability", () => {
    const prompt = promptSteps("x", [], "ავაწყო კომპიუტერი", { ...parsedCheckContext, answers }, { capabilities, count: 5 });
    for (const text of ["needs_check_photo:", "და არა needs_answer", "CPU ორიენტაცია/ბერკეტი", "12VHPWR", "ჰერმეტული შეერთება",
      "შემოწმების ფოტოა, გადაღებული თხოვნით „გადაიღე ბერკეტი ახლოდან“", "სწორად შესრულდა თუ არა", "აწყობის რეჟიმი",
      "ერთი ფიზიკური მოქმედება ნაბიჯზე", "CPU_FAN1, JFP1", "ESD", "„არ ვიცი“ და „ფოტოს გაჩვენებ“", "allowOther=true",
      "არ გაიმეორო", "„ბერკეტი დაკეტილია?“ → „დიახ“"]) expect(prompt).toContain(text);
    expect(prompt).toContain("პირველი JSON გასაღები იყოს steps.");
    const plain = promptSteps("x", [], "ავაწყო", undefined, { capabilities, count: 5 });
    expect(plain).toContain("needs_check_photo:");
    expect(plain).not.toContain("შემოწმების ფოტოა");
    const limited = promptSteps("x", [], "x", { ...parsedCheckContext, checkPhotos: 20 }, { capabilities });
    expect(limited).toContain("needs_check_photo აღარ შეიძლება");
    expect(limited).not.toContain("needs_check_photo:");
    for (const p of [promptSteps("x", [], "x", undefined, { capabilities: diagnostic }), promptSteps("x", [], "x", undefined, { count: 5 })]) {
      expect(p).not.toContain("needs_check_photo");
      expect(p).not.toContain("არ ვიცი");
    }
  });
});

describe("POST /ai/steps check_photo", () => {
  it("sends the verification photo and context.checkPrompt to the model", async () => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: checkPhoto() });
    const image = b64(fakeJpeg(512, 384));
    const done = await doneOf(await postSteps({ object: "x", parts, instructions: "ავაწყო", image, capabilities, context: checkContext }));
    expect(done.continuation).toEqual({ kind: "needs_check_photo", prompt: "გადაიღე CPU-ს ბერკეტი ახლოდან", reason: "დაკეტვას შევამოწმებ" });
    const content = sent[0].input[0].content;
    expect(content.find((c: any) => c.type === "input_image").image_url).toBe(`data:image/jpeg;base64,${image}`);
    expect(content[0].text).toContain("„გადაიღე ბერკეტი ახლოდან“");
    expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).toContain("needs_check_photo");
  });

  it("sends the photo on an answer turn too, and offers the fallback options", async () => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: diagnosticContinuation({ question: "RAM ჩაჯდა?" }) });
    const image = b64(fakeJpeg(256, 256));
    const done = await doneOf(await postSteps({ object: "x", parts, instructions: "x", image, capabilities, context: { round: 1, doneSteps: [], answers } }));
    expect(done.continuation).toEqual({ kind: "needs_answer", question: "RAM ჩაჯდა?", options: ["დიახ", "არა", "არ ვიცი", "ფოტოს გაჩვენებ"], allowOther: true, reason: null });
    expect(sent[0].input[0].content.some((c: any) => c.type === "input_image")).toBe(true);
  });

  it("stops offering check photos at the limit", async () => {
    const sent = upstreamSteps({ steps: [step], unknown_parts: [], continuation: checkPhoto() });
    const done = await doneOf(await postSteps({ object: "x", parts, instructions: "x", capabilities, context: { ...checkContext, checkPhotos: 20 } }));
    expect(done.continuation.kind).toBe("needs_photo");
    expect(sent[0].text.format.schema.properties.continuation.properties.kind.enum).not.toContain("needs_check_photo");
    expect((await postSteps({ object: "x", parts, instructions: "x", capabilities, context: { ...checkContext, checkPhotos: 21 } })).status).toBe(400);
  });
});
