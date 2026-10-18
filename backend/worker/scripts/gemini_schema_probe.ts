/** Live, opt-in schema acceptance probe. No image, maxOutputTokens=1.
 * Bundle with esbuild --bundle --platform=node --format=esm, then run with
 * GEMINI_API_KEY in the environment. Pass case names to select probes.
 * No keys or generated content are printed; error messages are redacted.
 * 2026-10-18, gemini-3.8-flash: tools/hands/full -> 400; isolated nullable
 * fragments -> 200. bounded_cards_id_notThis -> 400, either field alone -> 200.
 * Removing only outer minItems OR maxItems still fails; removing both works.
 * full_adapted and full_free_text_adapted use the production transformation.
 * Costs use provider usage and repository tariffs, not billing invoices.
 * Account for prior invocations separately when working under a total budget.
 */
import { schemaSteps, obj, type JsonSchema } from "../src/ai/schema";
import { GEMINI_MODEL, geminiUsage, geminiSchema } from "../src/ai/gemini";
import { estimateCost } from "../src/ai/pricing";

const base = ["needs_answer", "needs_measurement", "summary"];
const steps = (...caps: string[]) => schemaSteps(["p1", "p2"], 5, { capabilities: [...base, ...caps] });
const props = (schema: JsonSchema) => schema.properties as Record<string, JsonSchema>;
const step = (schema: JsonSchema) => props(props(schema).steps!.items as JsonSchema);
const tools = step(steps("tools_v2"));
const cards = props(tools.toolCards!.items as JsonSchema);
const actions = props(tools.actions!.items as JsonSchema);
const cases: Record<string, JsonSchema> = {
  legacy: schemaSteps(["p1", "p2"], 5),
  diagnostic: steps(),
  tools: steps("tools_v2"),
  hands: steps("hands_v1"),
  check_photo: steps("check_photo"),
  full: steps("tools_v2", "hands_v1", "check_photo"),
  notThis: obj({ value: cards.notThis! }),
  order: obj({ value: actions.order! }),
  amount: obj({ value: actions.amount! }),
  hands_fragment: obj({ value: step(steps("hands_v1")).hands! }),
  boolean: obj({ value: { type: "boolean" } }),
};

function rewrite(schema: JsonSchema, mode: string): JsonSchema {
  const out = structuredClone(schema);
  function visit(node: JsonSchema) {
    if (mode === "caps") { delete node.maxItems; delete node.minItems; }
    if (mode === "length") delete node.maxLength;
    if (mode === "enums" && node.enum) node.enum = (node.enum as unknown[]).slice(0, 1);
    if (mode === "nullable" && Array.isArray(node.type) && node.type.includes("null")) {
      node.type = node.type.filter(t => t !== "null")[0]; node.nullable = true;
    }
    for (const sub of Object.values((node.properties ?? {}) as Record<string, JsonSchema>)) visit(sub);
    if (node.items) visit(node.items as JsonSchema);
  }
  visit(out); return out;
}
for (const cap of ["tools", "hands"]) {
  for (const mode of ["caps", "length", "enums", "nullable"]) cases[`${cap}_${mode}`] = rewrite(cases[cap]!, mode);
  const single = structuredClone(cases[cap]!);
  props(single).steps!.maxItems = 1;
  props(single).steps!.minItems = 1;
  cases[`${cap}_one_step`] = single;
}

for (const cap of ["tools", "hands", "full"]) {
  for (const mode of ["outer_max", "outer_min", "outer_both", "inner_caps"]) {
    const schema = structuredClone(cases[cap]!);
    const list = props(schema).steps!;
    if (mode === "outer_max" || mode === "outer_both") delete list.maxItems;
    if (mode === "outer_min" || mode === "outer_both") delete list.minItems;
    if (mode === "inner_caps") list.items = rewrite(list.items as JsonSchema, "caps");
    cases[`${cap}_${mode}`] = schema;
  }
}

cases.hands_steps_only = obj({ steps: props(cases.hands!).steps! });
cases.tools_steps_only = obj({ steps: props(cases.tools!).steps! });
for (const field of Object.keys(step(cases.hands!))) {
  const schema = structuredClone(cases.hands!);
  delete step(schema)[field];
  const item = props(schema).steps!.items as JsonSchema;
  item.required = (item.required as string[]).filter(k => k !== field);
  cases[`hands_without_${field}`] = schema;
}

for (const cap of ["tools", "hands", "full"]) cases[`${cap}_adapted`] = geminiSchema(cases[cap]!);
cases.full_free_text_adapted = geminiSchema(schemaSteps(["p1", "p2"], 5, {
  capabilities: [...base, "tools_v2", "hands_v1", "check_photo"], freeText: true,
}));

for (const fields of [["toolCards"], ["actions"], ["toolCards", "actions"]]) {
  cases[`bounded_${fields.join("_")}`] = obj({ steps: {
    type: "array", minItems: 5, maxItems: 5,
    items: obj(Object.fromEntries(fields.map(name => [name, tools[name]!]))),
  } });
}

for (const fields of [["id"], ["notThis"], ["id", "notThis"]]) {
  cases[`bounded_cards_${fields.join("_")}`] = obj({ steps: {
    type: "array", minItems: 5, maxItems: 5,
    items: obj({ toolCards: { type: "array", maxItems: 3,
      items: obj(Object.fromEntries(fields.map(name => [name, cards[name]!]))),
    } }),
  } });
}

const key = process.env.GEMINI_API_KEY;
if (!key) throw new Error("Set GEMINI_API_KEY in the environment");
const selected = process.argv.slice(2);
if (!selected.length || selected.some(name => !cases[name])) throw new Error(`Select cases: ${Object.keys(cases).join(", ")}`);
let total = 0;
for (const name of selected) {
  const schema = cases[name]!;
  // Conservative per-call reservation; caller must account for earlier runs.
  const reserved = JSON.stringify(schema).length * 0.75 / 1_000_000 + 0.001;
  if (total + reserved > 0.05) throw new Error("Probe budget exhausted");
  const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:streamGenerateContent?alt=sse`, {
    method: "POST", headers: { "content-type": "application/json", "x-goog-api-key": key },
    body: JSON.stringify({ contents: [{ role: "user", parts: [{ text: "hi" }] }],
      generationConfig: { responseMimeType: "application/json", responseJsonSchema: schema, thinkingConfig: { thinkingLevel: "low" }, maxOutputTokens: 1 } }),
    signal: AbortSignal.timeout(30_000),
  });
  const body = await res.text();
  let cost: number | null = null;
  for (const line of body.split("\n")) {
    if (!line.startsWith("data: ")) continue;
    const event = JSON.parse(line.slice(6));
    if (event.usageMetadata) cost = estimateCost(geminiUsage(event.usageMetadata), GEMINI_MODEL);
  }
  total += cost ?? (res.ok ? reserved : 0);
  let error: unknown;
  if (!res.ok) {
    try { error = JSON.parse(body).error?.message; } catch { error = "Non-JSON error"; }
  }
  const safeError = typeof error === "string" ? error.replaceAll(key, "<redacted>").replace(/AIza[\w-]+/g, "<redacted>").slice(0, 1500) : undefined;
  console.log(JSON.stringify({ name, status: res.status, bytes: JSON.stringify(schema).length, costUsd: cost, accountedUsd: total, error: safeError }));
}
