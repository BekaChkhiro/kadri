import { afterEach, describe, expect, it, vi } from "vitest";
import { promptSteps } from "../src/ai/prompts";
import { schemaSteps, softened, stepItemSchema, validateSchema } from "../src/ai/schema";
import { ACTION_KINDS, genericFitCheck, TOOL_CATALOG, TOOL_IDS } from "../src/ai/tools";
import { parseCapabilities, stepRuleError, tidyStep, type ModelStep, type ToolCard } from "../src/ai/validate";
import { readSse } from "../src/sse";
import { call, mockFetch, responseBody } from "./ai-helpers";

const ids = ["p1", "p2", "p3"];
const labels = new Map([["p1", "ქანჩი"], ["p2", "ხრახნი"], ["p3", ""]]);
const caps = { capabilities: ["tools_v2"] };
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
const card: ToolCard = {
  id: "adjustable_wrench",
  size: "17 მმ",
  sizeSource: "typical",
  fitCheck: "დაიწყე 17 მმ-ით; თუ თავისუფლად ბრუნავს, სცადე 19",
  alternatives: ["19 მმ"],
  why: "ქანჩი დიდია",
  notThis: { id: "pliers", reason: "წახნაგები დაზიანდება" },
};
/** A card the model sent with only the older fields. */
const bare = (c: Pick<ToolCard, "id" | "size" | "why" | "notThis">): ToolCard =>
  ({ sizeSource: "typical", fitCheck: null, alternatives: [], ...c });
const action = { part: "p1", kind: "rotate_ccw", amount: "½", order: null };

afterEach(() => vi.restoreAllMocks());

describe("tools_v2 schema", () => {
  it("adds required toolCards and actions only with the capability", () => {
    const step = (schemaSteps(ids, 5, caps).properties as any).steps.items;
    expect(step.required).toEqual(expect.arrayContaining(["toolCards", "actions"]));
    expect(step.properties.toolCards.maxItems).toBe(3);
    expect(step.properties.toolCards.items.properties.id.enum).toEqual(TOOL_IDS);
    expect(step.properties.actions.items.properties.kind.enum).toEqual([...ACTION_KINDS]);
    expect(schemaSteps(ids, 5, { capabilities: [] })).toEqual(schemaSteps(ids, 5));
    expect(schemaSteps(ids, 5, { capabilities: ["future"] })).toEqual(schemaSteps(ids, 5));
    expect((schemaSteps(ids, 5).properties as any).steps.items.properties).not.toHaveProperty("toolCards");
  });

  it("requires sizeSource, fitCheck and alternatives on every card", () => {
    const item = (schemaSteps(ids, 5, caps).properties as any).steps.items.properties.toolCards.items;
    expect(item.required).toEqual(expect.arrayContaining(["sizeSource", "fitCheck", "alternatives"]));
    expect(item.properties.sizeSource).toEqual({ type: "string", enum: ["seen", "model", "typical"] });
    expect(item.properties.fitCheck).toEqual({ type: ["string", "null"], maxLength: 100 });
    expect(item.properties.alternatives).toEqual({ type: "array", items: { type: "string", maxLength: 12 }, maxItems: 2 });
    expect(JSON.stringify(schemaSteps(ids, 5))).not.toMatch(/sizeSource|fitCheck|alternatives/);
    const soft = softened(stepItemSchema(ids, ["tools_v2"]));
    expect(validateSchema(soft, { ...base, toolCards: [{ ...card, sizeSource: "guess" }], actions: [] })).toMatch(/not in enum/);
    expect(validateSchema(soft, { ...base, toolCards: [{ ...card, alternatives: ["1", "2", "3"] }], actions: [] })).toMatch(/too many/);
    const { fitCheck: _, ...noFit } = card;
    expect(validateSchema(soft, { ...base, toolCards: [noFit], actions: [] })).toMatch(/required/);
  });

  it("forbids actions without parts and keeps item caps when softened", () => {
    const empty = (schemaSteps([], 5, caps).properties as any).steps.items.properties;
    expect(empty.actions).toEqual({ type: "array", items: { type: "string" }, maxItems: 0 });
    const soft = softened(stepItemSchema(ids, ["tools_v2"])) as any;
    expect(soft.properties.toolCards.maxItems).toBe(3);
    expect(soft.properties.actions.maxItems).toBe(3);
    expect(soft.properties.toolCards.items.properties.why.maxLength).toBeUndefined();
  });

  it("validates cards with notThis object or null and rejects unknown enums", () => {
    const item = softened(stepItemSchema(ids, ["tools_v2"]));
    const ok = { ...base, toolCards: [card, { ...card, id: "ph2", size: null, fitCheck: null, alternatives: [], notThis: null }], actions: [action] };
    expect(validateSchema(item, ok)).toBeNull();
    expect(validateSchema(item, { ...ok, toolCards: [{ ...card, id: "spoon" }] })).toMatch(/not in enum/);
    expect(validateSchema(item, { ...ok, toolCards: [{ ...card, notThis: { id: "spoon", reason: "x" } }] })).toMatch(/not in enum/);
    expect(validateSchema(item, { ...ok, toolCards: [{ ...card, notThis: { id: "pliers" } }] })).toMatch(/required/);
    expect(validateSchema(item, { ...ok, actions: [{ ...action, kind: "spin" }] })).toMatch(/not in enum/);
    expect(validateSchema(item, { ...ok, actions: [{ ...action, part: "p9" }] })).toMatch(/not in enum/);
    expect(validateSchema(item, { ...ok, actions: [{ ...action, amount: "2" }] })).toMatch(/not in enum/);
    expect(validateSchema(item, { ...ok, toolCards: Array(4).fill(card) })).toMatch(/too many/);
    // Without the capability the streamed step may not carry them.
    expect(validateSchema(softened(stepItemSchema(ids)), ok)).toMatch(/not allowed/);
  });
});

describe("tools_v2 tidyStep", () => {
  it("leaves legacy steps without the new keys", () => {
    const out = tidyStep(base, labels);
    expect("toolCards" in out).toBe(false);
    expect("actions" in out).toBe(false);
    expect(JSON.stringify(out)).not.toContain("toolCards");
  });

  it("filters unknown and duplicate cards, notThis, texts and count", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const out = tidyStep({
      ...base,
      toolCards: [
        bare({ id: "spoon", size: null, why: "x", notThis: null }),
        { ...card, size: "ძალიან გრძელი ზომა 17 მმ", why: "ა".repeat(80), notThis: { id: "spoon", reason: "x" } },
        card,
        bare({ id: "ph2", size: "  ", why: "ხრახნი", notThis: null }),
        bare({ id: "gloves", size: null, why: "x", notThis: null }),
        bare({ id: "towel", size: null, why: "x", notThis: null }),
      ],
    }, labels);
    expect(out.toolCards!.map((c) => c.id)).toEqual(["adjustable_wrench", "ph2", "gloves"]);
    expect(out.toolCards![0]!.notThis).toBeNull();
    expect([...out.toolCards![0]!.size!].length).toBeLessThanOrEqual(12);
    expect([...out.toolCards![0]!.why].length).toBeLessThanOrEqual(60);
    expect(out.toolCards![1]!.size).toBeNull();
    expect(out.actions).toBeUndefined();
  });

  it("keeps seen only when the size is in the evidence text", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const m6 = { ...card, id: "socket_wrench", size: "M6", sizeSource: "seen" as const, fitCheck: null, alternatives: [] };
    const tidy = (c: ToolCard, evidence?: { text: string; modelKnown: boolean }) =>
      tidyStep({ ...base, toolCards: [c] }, labels, evidence).toolCards![0]!;
    expect(tidy(m6, { text: "ჭანჭიკი M6 მოუშვი", modelKnown: false })).toMatchObject({ size: "M6", sizeSource: "seen", fitCheck: null });
    expect(tidy({ ...m6, size: "PH2", id: "ph2" }, { text: "ხრახნი ph 2", modelKnown: false }).sizeSource).toBe("seen");
    expect(tidy({ ...m6, size: "10 მმ" }, { text: "ქანჩი 10მმ", modelKnown: false }).sizeSource).toBe("seen");
    // Not a standalone token: M60 and M6x20 do not confirm M6 / 6.
    expect(tidy(m6, { text: "ჭანჭიკი M60", modelKnown: true }).sizeSource).toBe("typical");
    expect(tidy({ ...m6, size: "6" }, { text: "ჭანჭიკი M6", modelKnown: false }).sizeSource).toBe("typical");
    const unconfirmed = tidy(m6);
    expect(unconfirmed).toMatchObject({ size: "M6", sizeSource: "typical", fitCheck: genericFitCheck("socket_wrench") });
    expect(warn).toHaveBeenCalledWith("ai/steps tidy: unconfirmed tool size marked typical");
  });

  it("keeps model only when the model is known", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const t20 = { ...card, id: "torx_t20", size: "T20", sizeSource: "model" as const, fitCheck: null, alternatives: [] };
    const tidy = (modelKnown: boolean) =>
      tidyStep({ ...base, toolCards: [t20] }, labels, { text: "კორპუსი", modelKnown }).toolCards![0]!;
    expect(tidy(true)).toMatchObject({ sizeSource: "model", fitCheck: null });
    expect(tidy(false)).toMatchObject({ sizeSource: "typical", fitCheck: genericFitCheck("torx_t20") });
  });

  it("keeps a typical card with its own fitCheck, and a null size as typical", () => {
    expect(tidyStep({ ...base, toolCards: [card] }, labels).toolCards).toEqual([card]);
    const out = tidyStep({ ...base, toolCards: [{ ...card, id: "hex_key", size: null, sizeSource: "seen", fitCheck: "" }] }, labels);
    expect(out.toolCards![0]).toMatchObject({ size: null, sizeSource: "typical", fitCheck: genericFitCheck("hex_key") });
  });

  it("dedupes alternatives, drops the size itself and keeps ≤2", () => {
    const out = tidyStep({
      ...base,
      toolCards: [{ ...card, alternatives: ["17 მმ", "19 მმ", "19 მმ", "", "21 მმ", "13 მმ"] }],
    }, labels);
    expect(out.toolCards![0]!.alternatives).toEqual(["19 მმ", "21 მმ"]);
  });

  it("gives tools without a size no size, fitCheck or alternatives", () => {
    const out = tidyStep({
      ...base,
      toolCards: [{ ...card, id: "gloves", size: "L", sizeSource: "seen", fitCheck: "x", alternatives: ["M"] }],
    }, labels, { text: "L", modelKnown: true });
    expect(out.toolCards![0]).toMatchObject({ size: null, sizeSource: "typical", fitCheck: null, alternatives: [] });
    for (const id of ["gloves", "bucket", "towel", "flashlight", "multimeter"]) expect(genericFitCheck(id)).toBeNull();
    for (const id of TOOL_IDS) expect([...(genericFitCheck(id) ?? "")].length).toBeLessThanOrEqual(100);
    expect(genericFitCheck("ph1")).toContain("მეზობელი ზომა");
    expect(genericFitCheck("open_wrench")).toContain("რეგულირებადი");
  });

  it("filters actions by part and kind, and amount/order by kind", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const out = tidyStep({
      ...base,
      actions: [
        { part: "p9", kind: "press", amount: null, order: null },
        { part: "p3", kind: "press", amount: null, order: null },
        { part: "p1", kind: "spin", amount: null, order: null },
        { part: "p1", kind: "press", amount: "½", order: ["p1", "p2"] },
        { part: "p2", kind: "tighten_order", amount: "hand_tight_plus_quarter", order: ["p2", "p9", "p2", "p3"] },
        { part: "p1", kind: "tighten_order", amount: "7", order: ["p1", "p2", "p1"] },
        { part: "p2", kind: "rotate_cw", amount: "¼", order: ["p1", "p2"] },
        { part: "p1", kind: "lift", amount: null, order: null },
      ],
    }, labels);
    expect(out.actions).toEqual([
      { part: "p1", kind: "press", amount: null, order: null },
      { part: "p2", kind: "tighten_order", amount: "hand_tight_plus_quarter", order: null },
      { part: "p1", kind: "tighten_order", amount: null, order: ["p1", "p2"] },
    ]);
    expect(stepRuleError(out, labels)).toBeNull();
    expect(stepRuleError({ ...out, actions: [{ part: "p3", kind: "press", amount: null, order: null }] }, labels)).toMatch(/recognized label/);
  });
});

describe("tools_v2 prompt and capabilities", () => {
  it("adds the catalog rule only with the capability", () => {
    const legacy = promptSteps("x", [], "x");
    const prompt = promptSteps("x", [], "x", undefined, caps);
    expect(legacy).not.toContain("toolCards");
    expect(prompt).toContain("toolCards");
    expect(prompt).toContain("ph2 — ჯვარედინი სახრახნისი PH2");
    expect(prompt).toContain("ზომა არასოდეს გამოიგონო");
    expect(prompt).toContain("ეჭვისას ყოველთვის typical");
    expect(prompt).toContain("fitCheck ≤100");
    expect(legacy).not.toContain("sizeSource");
    expect(prompt).toContain("typical-ზე why-ში ზომის დარწმუნებული ფრაზები („ზუსტად ერგება“) არ დაწერო");
    expect(legacy).not.toContain("ზუსტად ერგება");
    for (const t of TOOL_CATALOG) expect(prompt).toContain(`${t.id} — ${t.name}`);
    expect(promptSteps("x", [], "x", undefined, { capabilities: ["future"] })).toBe(legacy);
  });

  it("accepts tools_v2", () => {
    expect(parseCapabilities(["tools_v2", "future", "summary", "tools_v2"])).toEqual(["tools_v2", "summary"]);
  });

  it("catalog has 32 unique ids", () => {
    expect(TOOL_CATALOG).toHaveLength(32);
    expect(new Set(TOOL_IDS).size).toBe(32);
  });
});

describe("tools_v2 steps endpoint", () => {
  const parts = [
    { id: "p1", name: "სიფონის ქანჩი", box: [100, 100, 300, 400] },
    { id: "p2", name: "ხრახნი", box: [400, 500, 700, 900] },
  ];
  const enc = new TextEncoder();
  const frame = (data: any) => enc.encode(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);

  async function run(capabilities: string[], step: unknown, extra: Record<string, unknown> = {}) {
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
      body: JSON.stringify({ object: "x", parts, instructions: "x", capabilities, ...extra }),
    });
    const events: Array<{ event: string | null; data: any }> = [];
    for await (const m of readSse(res.body!)) events.push({ event: m.event, data: JSON.parse(m.data) });
    return { sent, events };
  }

  it("streams toolCards and actions with tools_v2", async () => {
    const { sent, events } = await run(["tools_v2"], { ...base, toolCards: [card], actions: [action] });
    const schemaStep = sent[0].text.format.schema.properties.steps.items;
    expect(schemaStep.required).toContain("toolCards");
    expect(sent[0].input[0].content.some((c: any) => typeof c.text === "string" && c.text.includes("ph2 — "))).toBe(true);
    const step = events.find((e) => e.event === "step")!.data;
    expect(step.toolCards).toEqual([card]);
    expect(step.actions).toEqual([action]);
    expect(events.at(-1)!.event).toBe("done");
  });

  it("marks unconfirmed seen/model sizes typical and keeps a size the parts confirm", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const model = { ...card, id: "torx_t20", size: "T20", sizeSource: "model", fitCheck: null, alternatives: [] };
    const seenOk = { ...card, id: "socket_wrench", size: "M6", sizeSource: "seen", fitCheck: null, alternatives: [] };
    const seenBad = { ...card, id: "open_wrench", size: "13 მმ", sizeSource: "seen", fitCheck: null, alternatives: [] };
    parts[1]!.name = "ხრახნი M6";
    try {
      const { sent, events } = await run(["tools_v2"], { ...base, toolCards: [model, seenOk, seenBad], actions: [] });
      const cardSchema = sent[0].text.format.schema.properties.steps.items.properties.toolCards.items;
      expect(cardSchema.required).toContain("sizeSource");
      const [m, ok, bad] = events.find((e) => e.event === "step")!.data.toolCards;
      // No Knowledge Hub hit and no model code in the text: model is not confirmed.
      expect(m).toMatchObject({ sizeSource: "typical", fitCheck: genericFitCheck("torx_t20") });
      expect(ok).toMatchObject({ size: "M6", sizeSource: "seen", fitCheck: null });
      expect(bad).toMatchObject({ size: "13 მმ", sizeSource: "typical", fitCheck: genericFitCheck("open_wrench") });
    } finally {
      parts[1]!.name = "ხრახნი";
    }
  });

  it("keeps model when the text names a model code", async () => {
    const model = { ...card, id: "torx_t20", size: "T20", sizeSource: "model", fitCheck: null, alternatives: [] };
    const { events } = await run(["tools_v2"], { ...base, toolCards: [model], actions: [] }, { instructions: "Bosch WAN28 ფილტრი" });
    expect(events.find((e) => e.event === "step")!.data.toolCards[0]).toMatchObject({ sizeSource: "model", fitCheck: null });
  });

  it("legacy request sends no new keys", async () => {
    const { sent, events } = await run([], base);
    expect(sent[0].text.format.schema.properties.steps.items.properties).not.toHaveProperty("toolCards");
    const step = events.find((e) => e.event === "step")!.data;
    expect(step).not.toHaveProperty("toolCards");
    expect(step).not.toHaveProperty("actions");
  });
});
