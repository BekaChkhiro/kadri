import { afterEach, describe, expect, it, vi } from "vitest";
import { promptSteps } from "../src/ai/prompts";
import { HAND_GRIPS, HAND_SIDES, schemaSteps, softened, stepItemSchema, validateSchema } from "../src/ai/schema";
import { parseCapabilities, stepRuleError, tidyStep, type ModelStep, type StepHand } from "../src/ai/validate";
import { readSse } from "../src/sse";
import { call, mockFetch, responseBody } from "./ai-helpers";

const ids = ["p1", "p2", "p3"];
const labels = new Map([["p1", "ქანჩი"], ["p2", "მილი"], ["p3", ""]]);
const caps = { capabilities: ["hands_v1"] };
const base: ModelStep = {
  title: "მოუშვი ქანჩი",
  text: "საათის ისრის საწინააღმდეგოდ.",
  focus: ["p1"],
  avoid: [],
  markers: [],
  arrows: [],
  icon: "unscrew",
  tools: [],
  tip: null,
  warn: null,
};
const support: StepHand = { part: "p2", grip: "support", hand: "left", byHandOnly: true };
const turn: StepHand = { part: "p1", grip: "turn", hand: "right", byHandOnly: true };

afterEach(() => vi.restoreAllMocks());

describe("hands_v1 schema", () => {
  it("adds required hands only with the capability", () => {
    const step = (schemaSteps(ids, 5, caps).properties as any).steps.items;
    expect(step.required).toContain("hands");
    expect(step.properties.hands.maxItems).toBe(2);
    const item = step.properties.hands.items;
    expect(item.required).toEqual(["part", "grip", "hand", "byHandOnly"]);
    expect(item.properties.part.enum).toEqual(ids);
    expect(item.properties.grip.enum).toEqual([...HAND_GRIPS]);
    expect(item.properties.hand.enum).toEqual([...HAND_SIDES]);
    expect(item.properties.byHandOnly).toEqual({ type: "boolean" });
    expect(JSON.stringify(schemaSteps(ids, 5))).not.toMatch(/hands|byHandOnly/);
    expect(JSON.stringify(schemaSteps(ids, 5, { capabilities: ["tools_v2"] }))).not.toMatch(/hands|byHandOnly/);
  });

  it("forbids hands without parts and validates items", () => {
    const empty = (schemaSteps([], 5, caps).properties as any).steps.items.properties;
    expect(empty.hands).toEqual({ type: "array", items: { type: "string" }, maxItems: 0 });
    const soft = softened(stepItemSchema(ids, ["hands_v1"]));
    expect(validateSchema(soft, { ...base, hands: [support, turn] })).toBeNull();
    expect(validateSchema(soft, { ...base, hands: [{ ...turn, grip: "squeeze" }] })).toMatch(/not in enum/);
    expect(validateSchema(soft, { ...base, hands: [{ ...turn, hand: "foot" }] })).toMatch(/not in enum/);
    expect(validateSchema(soft, { ...base, hands: [{ ...turn, part: "p9" }] })).toMatch(/not in enum/);
    expect(validateSchema(soft, { ...base, hands: [support, turn, turn] })).toMatch(/too many/);
    expect(validateSchema(softened(stepItemSchema(ids)), { ...base, hands: [turn] })).toMatch(/not allowed/);
  });

  it("combines with tools_v2", () => {
    const step = (schemaSteps(ids, 5, { capabilities: ["tools_v2", "hands_v1"] }).properties as any).steps.items;
    expect(step.required).toEqual(expect.arrayContaining(["toolCards", "actions", "hands"]));
  });
});

describe("hands_v1 tidyStep", () => {
  it("leaves legacy steps without the hands key", () => {
    const out = tidyStep(base, labels);
    expect("hands" in out).toBe(false);
    expect(JSON.stringify(out)).not.toContain("hands");
  });

  it("drops unknown parts, grips and hands, dedupes part+hand and keeps ≤2", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const out = tidyStep({
      ...base,
      hands: [
        { part: "p9", grip: "hold", hand: "left", byHandOnly: false },
        { part: "p3", grip: "hold", hand: "left", byHandOnly: false },
        { part: "p1", grip: "squeeze", hand: "left", byHandOnly: false },
        { part: "p1", grip: "hold", hand: "foot", byHandOnly: false },
        support,
        { ...support, grip: "hold" },
        { ...turn, byHandOnly: "yes" as unknown as boolean },
        { part: "p1", grip: "push", hand: "left", byHandOnly: true },
      ],
    }, labels);
    expect(out.hands).toEqual([support, { ...turn, byHandOnly: false }]);
    expect(warn).toHaveBeenCalledWith("ai/steps tidy: hand hint with unknown part, grip or hand dropped");
    expect(stepRuleError(out, labels)).toBeNull();
  });

  it("keeps an empty list and counts hand parts as references", () => {
    expect(tidyStep({ ...base, hands: [] }, labels).hands).toEqual([]);
    const out = tidyStep({ ...base, hands: [turn] }, labels);
    expect(stepRuleError({ ...out, hands: [{ ...turn, part: "p3" }] }, labels)).toMatch(/recognized label/);
  });
});

describe("hands_v1 by-hand-only tool cards", () => {
  const ph2 = {
    id: "ph2",
    size: "PH2",
    sizeSource: "typical" as const,
    fitCheck: "PH2 მჭიდროდ უნდა ჩაჯდეს; თუ ხტება, PH1",
    alternatives: ["PH1"],
    why: "ხრახნი",
    notThis: null,
  };

  it("drops tool cards when every hand is by hand only", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const out = tidyStep({ ...base, toolCards: [ph2], actions: [], hands: [turn] }, labels);
    expect(out.toolCards).toEqual([]);
    expect(out.hands).toEqual([turn]);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith("ai/steps tidy: tool cards dropped on a by-hand-only step");
  });

  it("keeps tool cards when any hand needs a tool", () => {
    const hold: StepHand = { part: "p1", grip: "hold", hand: "left", byHandOnly: false };
    const out = tidyStep({ ...base, toolCards: [ph2], actions: [], hands: [hold, { ...turn, part: "p2" }] }, labels);
    expect(out.toolCards!.map((c) => c.id)).toEqual(["ph2"]);
  });

  it("keeps tool cards with empty or missing hands", () => {
    expect(tidyStep({ ...base, toolCards: [ph2], actions: [], hands: [] }, labels).toolCards!.map((c) => c.id)).toEqual(["ph2"]);
    expect(tidyStep({ ...base, toolCards: [ph2], actions: [] }, labels).toolCards!.map((c) => c.id)).toEqual(["ph2"]);
  });

  it("adds no toolCards or hands key to a legacy step", () => {
    const out = tidyStep(base, labels);
    expect(out).not.toHaveProperty("toolCards");
    expect(out).not.toHaveProperty("hands");
  });
});

describe("hands_v1 prompt and capabilities", () => {
  it("adds the hands rule only with the capability", () => {
    const legacy = promptSteps("x", [], "x");
    const prompt = promptSteps("x", [], "x", undefined, caps);
    expect(prompt).toContain("byHandOnly");
    expect(prompt).toContain("hold არ მისცე");
    expect(prompt).toContain("თუ ხელსაწყო მართლა სჭირდება, byHandOnly=false დატოვე (უსაფრთხო მხარე)");
    expect(legacy).not.toContain("byHandOnly");
    expect(legacy).not.toContain("hands:");
    expect(promptSteps("x", [], "x", undefined, { capabilities: ["tools_v2"] })).not.toContain("byHandOnly");
  });

  it("accepts hands_v1", () => {
    expect(parseCapabilities(["hands_v1", "future", "hands_v1"])).toEqual(["hands_v1"]);
  });
});

describe("hands_v1 steps endpoint", () => {
  const parts = [
    { id: "p1", name: "სიფონის ქანჩი", box: [100, 100, 300, 400] },
    { id: "p2", name: "მილი", box: [400, 500, 700, 900] },
  ];
  const enc = new TextEncoder();
  const frame = (data: any) => enc.encode(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);

  async function run(capabilities: string[], step: unknown) {
    const result = { steps: [step], unknown_parts: [], continuation: { kind: "complete", prompt: null, reason: null } };
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
    const res = await call("/ai/steps", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ object: "x", parts, instructions: "x", capabilities }),
    });
    const events: Array<{ event: string | null; data: any }> = [];
    for await (const m of readSse(res.body!)) events.push({ event: m.event, data: JSON.parse(m.data) });
    return { sent, events };
  }

  it("streams hands with hands_v1", async () => {
    const { sent, events } = await run(["hands_v1"], { ...base, hands: [support, turn] });
    expect(sent[0].text.format.schema.properties.steps.items.required).toContain("hands");
    expect(sent[0].input[0].content.some((c: any) => typeof c.text === "string" && c.text.includes("byHandOnly"))).toBe(true);
    expect(sent[0].max_output_tokens).not.toBe(2200);
    const step = events.find((e) => e.event === "step")!.data;
    expect(step.hands).toEqual([support, turn]);
    expect(step).not.toHaveProperty("toolCards");
    expect(events.at(-1)!.event).toBe("done");
  });

  it("legacy request sends no hands", async () => {
    const { sent, events } = await run([], base);
    expect(JSON.stringify(sent[0])).not.toContain("byHandOnly");
    expect(events.find((e) => e.event === "step")!.data).not.toHaveProperty("hands");
  });
});
