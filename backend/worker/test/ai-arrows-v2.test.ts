import { afterEach, describe, expect, it, vi } from "vitest";
import { promptSteps } from "../src/ai/prompts";
import { schemaSteps, stepItemSchema, validateSchema } from "../src/ai/schema";
import { parseCapabilities, stepRuleError, tidyStep } from "../src/ai/validate";
import { call, mockFetch, responseBody } from "./ai-helpers";
import { readSse } from "../src/sse";

const labels = new Map([["p1", "საკეტი"]]);
const step = {
  title: "ასწიე საკეტი", text: "ასწიე საკეტი ზემოთ.", focus: ["p1"], avoid: [],
  markers: [], arrows: [{ part: "p1", type: "move", dir: "up" }],
  icon: "pull", tools: [], tip: null, warn: null,
};
const parts = [{ id: "p1", name: "საკეტი", box: [100, 100, 300, 400] }];
const capabilities = ["arrows_v2"];
const validPairs = [
  ["rotate", "cw"], ["rotate", "ccw"],
  ...["up", "down", "left", "right", "toward", "away", "up_left", "up_right", "down_left", "down_right"].map(dir => ["move", dir]),
  ["press", "none"], ["hold", "none"], ["align", "none"],
];

afterEach(() => vi.restoreAllMocks());

describe("arrows_v2 capability", () => {
  it("accepts the capability while deduplicating and ignoring unknown flags", () => {
    expect(parseCapabilities(["summary", "arrows_v2", "unknown", "arrows_v2"])).toEqual(["summary", "arrows_v2"]);
  });

  it("preserves tools, actions and photo verification when enabling arrows", () => {
    const combined = ["tools_v2", "check_photo", "arrows_v2"];
    const schema = schemaSteps(["p1"], 1, { capabilities: combined }) as any;
    expect(schema.properties.steps.items.required).toEqual(expect.arrayContaining(["toolCards", "actions"]));
    expect(schema.properties.steps.items.required).not.toContain("hands");
    expect(schema.properties.continuation.properties.kind.enum).toContain("needs_check_photo");
    const candidate = {
      ...step, arrows: [{ part: "p1", type: "move", dir: "down_right" }], toolCards: [],
      actions: [{ part: "p1", kind: "rotate_cw", amount: "¼", order: null }],
    };
    expect(validateSchema(stepItemSchema(["p1"], combined), candidate)).toBeNull();
    const cleaned = tidyStep(candidate, labels);
    expect(cleaned.actions).toEqual(candidate.actions);
    expect(cleaned.arrows).toEqual(candidate.arrows);
    expect(cleaned.toolCards).toEqual([]);
  });

  it.each(validPairs)("accepts %s/%s in both whole and streamed step schemas", (type, dir) => {
    const candidate = { ...step, arrows: [{ part: "p1", type, dir }] };
    expect(validateSchema(stepItemSchema(["p1"], capabilities), candidate)).toBeNull();
    expect(validateSchema(schemaSteps(["p1"], 1, { capabilities }), {
      steps: [candidate], unknown_parts: [], continuation: { kind: "complete", prompt: null, reason: null },
    })).toBeNull();
    const cleaned = tidyStep(candidate, labels);
    expect(cleaned.arrows).toEqual(candidate.arrows);
    expect(stepRuleError(cleaned, labels)).toBeNull();
  });

  it.each([["move", "up_left"], ["press", "none"], ["hold", "none"], ["align", "none"]])(
    "does not expose %s/%s to a legacy client", (type, dir) => {
      expect(validateSchema(stepItemSchema(["p1"]), { ...step, arrows: [{ part: "p1", type, dir }] })).not.toBeNull();
    },
  );

  it.each([["rotate", "up"], ["move", "none"], ["press", "down"], ["hold", "cw"], ["align", "toward"], ["invented", "none"]])(
    "drops incompatible %s/%s and rejects it in strict rule checks", (type, dir) => {
      const candidate = { ...step, arrows: [{ part: "p1", type, dir }] };
      const cleaned = tidyStep(candidate, labels);
      expect(cleaned.arrows).toEqual([]);
      expect(stepRuleError({ ...cleaned, arrows: candidate.arrows }, labels)).toMatch(/incompatible/);
    },
  );

  it("still forbids unknown part IDs and arrows when no parts are visible", () => {
    expect(validateSchema(stepItemSchema(["p1"], capabilities), {
      ...step, arrows: [{ part: "unknown", type: "press", dir: "none" }],
    })).not.toBeNull();
    expect(validateSchema(stepItemSchema([], capabilities), {
      ...step, focus: [], arrows: [{ part: "p1", type: "press", dir: "none" }],
    })).not.toBeNull();
  });

  it("only teaches new directions to capable clients and defines depth relative to the viewer", () => {
    const legacy = promptSteps("საკეტი", [], "აწიე");
    const expanded = promptSteps("საკეტი", [], "აწიე", undefined, { capabilities });
    expect(legacy).not.toContain("up_left");
    expect(expanded).toContain("up_left");
    expect(expanded).toContain("press/hold/align: dir=none");
    expect(expanded).toContain("toward — მომხმარებლისკენ");
    expect(expanded).toContain("avoid ნაწილზე ისარი არ დასვა");
  });

  it("streams an expanded arrow through request parsing and provider validation", async () => {
    const candidate = { ...step, arrows: [{ part: "p1", type: "move", dir: "up_left" }] };
    const result = { steps: [candidate], unknown_parts: [], continuation: { kind: "complete", prompt: null, reason: null } };
    let requestedTypes: string[] = [];
    mockFetch((_url, init) => {
      const request = JSON.parse(String(init.body));
      requestedTypes = request.text.format.schema.properties.steps.items.properties.arrows.items.properties.type.enum;
      const frames = [
        { type: "response.output_text.delta", delta: JSON.stringify(result) },
        { type: "response.completed", response: responseBody(result) },
      ].map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");
      return new Response(frames, { headers: { "content-type": "text/event-stream" } });
    });
    const response = await call("/ai/steps", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ object: "საკეტი", parts, instructions: [{ title: step.title, text: step.text }], capabilities }),
    });
    const events = [];
    for await (const event of readSse(response.body!)) events.push({ event: event.event, data: JSON.parse(event.data) });
    expect(requestedTypes).toContain("press");
    expect(events.find(event => event.event === "step")?.data.arrows).toEqual(candidate.arrows);
    expect(events.some(event => event.event === "done")).toBe(true);
    expect(events.some(event => event.event === "error")).toBe(false);
  });
});
