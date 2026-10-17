/**
 * Strict JSON schemas for the two Astra C stages, ported 1:1 from
 * experiments/som-test (vision.py: obj/array/schema_for, variant_c.py:
 * schema_parts/schema_steps), plus a small validator for the subset of
 * JSON Schema those schemas use.
 */

export type JsonSchema = { [key: string]: unknown };

export function obj(properties: Record<string, JsonSchema>): JsonSchema {
  return {
    type: "object",
    properties,
    required: Object.keys(properties),
    additionalProperties: false,
  };
}

export function array(items: JsonSchema): JsonSchema {
  return { type: "array", items };
}

/** variant_c.schema_parts */
export function schemaParts(): JsonSchema {
  return obj({
    object: { type: "string" },
    parts: {
      ...array(
        obj({
          label: { type: "string", minLength: 1, maxLength: 120 },
          box: {
            ...array({ type: "number", minimum: 0, maximum: 1000 }),
            minItems: 4,
            maxItems: 4,
          },
        }),
      ),
      maxItems: 24,
    },
  });
}

/** vision.schema_for */
export function schemaFor(ids: string[], count = 5): JsonSchema {
  const string = (): JsonSchema => ({ type: "string" });
  const part = (): JsonSchema => ({ type: "string", enum: [...ids] });
  const step = obj({
    title: string(),
    text: string(),
    focus: array(part()),
    avoid: array(part()),
    markers: array(
      obj({
        part: part(),
        label: string(),
        tone: { type: "string", enum: ["brand", "danger", "neutral"] },
      }),
    ),
    arrows: array(
      obj({
        part: part(),
        type: { type: "string", enum: ["rotate", "move"] },
        dir: {
          type: "string",
          enum: ["cw", "ccw", "up", "down", "left", "right", "toward", "away"],
        },
      }),
    ),
    tools: array(string()),
    warn: { type: ["string", "null"] },
  });
  // Strict schemas require all object properties. Empty label means unknown/background.
  return obj({
    object: string(),
    parts: obj(Object.fromEntries(ids.map((id) => [id, string()]))),
    steps: { ...array(step), minItems: count, maxItems: count },
    unknown_parts: array(string()),
  });
}

type Props = Record<string, JsonSchema>;

/** variant_c.schema_steps */
export function schemaSteps(ids: string[], count: number): JsonSchema {
  const base = schemaFor(ids, count).properties as Props;
  const result = obj({ steps: base.steps!, unknown_parts: base.unknown_parts! });
  const stepsSchema = (result.properties as Props).steps!;
  const step = ((stepsSchema.items as JsonSchema).properties as Props);
  if (ids.length === 0) {
    // Empty enum is invalid JSON Schema; no references are possible instead.
    for (const field of ["focus", "avoid", "markers", "arrows"]) {
      step[field] = { type: "array", items: { type: "string" }, maxItems: 0 };
    }
  } else {
    step.focus!.description =
      "მოქმედების სამიზნე ხილული ნაწილების ID-ები (p1..pN). როდესაც მოქმედების სამიზნის " +
      "რამდენიმე plausible კანდიდატია, აირჩიე ყველაზე სავარაუდო ID მდებარეობის/ინსტრუქციის " +
      "მიხედვით და warn-ში ჩაწერე გაურკვევლობა. empty focus დასაშვებია მხოლოდ მაშინ, როცა " +
      "სამიზნე ნაწილი სიაში/ფოტოზე საერთოდ არ ჩანს (უხილავია). არ გამოიგონო ID.";
    step.warn!.description =
      "გაფრთხილება, უსაფრთხოების რჩევა ან გაურკვევლობის (uncertainty) ახსნა, მათ შორის თუ " +
      "სამიზნე უხილავია ან რამდენიმე კანდიდატს შორის შეირჩა ყველაზე სავარაუდო.";
  }
  return result;
}

/** The schema of one element of `steps` (used to validate streamed steps). */
export function stepItemSchema(ids: string[]): JsonSchema {
  const steps = (schemaSteps(ids, 1).properties as Props).steps!;
  return steps.items as JsonSchema;
}

function typeOk(type: string, value: unknown): boolean {
  switch (type) {
    case "string":
      return typeof value === "string";
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "boolean":
      return typeof value === "boolean";
    case "null":
      return value === null;
    case "array":
      return Array.isArray(value);
    case "object":
      return typeof value === "object" && value !== null && !Array.isArray(value);
    default:
      return false;
  }
}

/**
 * Validates `value` against the JSON Schema subset used above. Returns the
 * first error as a path-prefixed string, or null when valid.
 */
export function validateSchema(schema: JsonSchema, value: unknown, path = "$"): string | null {
  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? (schema.type as string[]) : [schema.type as string];
    if (!types.some((t) => typeOk(t, value))) return `${path}: expected ${types.join("|")}`;
  }
  if (Array.isArray(schema.enum) && !schema.enum.includes(value)) {
    return `${path}: not in enum`;
  }
  if (typeof value === "string") {
    const len = [...value].length;
    if (typeof schema.minLength === "number" && len < schema.minLength) return `${path}: too short`;
    if (typeof schema.maxLength === "number" && len > schema.maxLength) return `${path}: too long`;
  }
  if (typeof value === "number") {
    if (typeof schema.minimum === "number" && value < schema.minimum) return `${path}: below minimum`;
    if (typeof schema.maximum === "number" && value > schema.maximum) return `${path}: above maximum`;
  }
  if (Array.isArray(value)) {
    if (typeof schema.minItems === "number" && value.length < schema.minItems) return `${path}: too few items`;
    if (typeof schema.maxItems === "number" && value.length > schema.maxItems) return `${path}: too many items`;
    if (schema.items) {
      for (let i = 0; i < value.length; i++) {
        const err = validateSchema(schema.items as JsonSchema, value[i], `${path}[${i}]`);
        if (err) return err;
      }
    }
  }
  if (typeOk("object", value)) {
    const record = value as Record<string, unknown>;
    const props = (schema.properties ?? {}) as Props;
    for (const key of (schema.required ?? []) as string[]) {
      if (!(key in record)) return `${path}.${key}: required`;
    }
    for (const [key, v] of Object.entries(record)) {
      const sub = props[key];
      if (!sub) {
        if (schema.additionalProperties === false) return `${path}.${key}: not allowed`;
        continue;
      }
      const err = validateSchema(sub, v, `${path}.${key}`);
      if (err) return err;
    }
  }
  return null;
}

/**
 * Python `json.dumps(value, ensure_ascii=False)` — default ", " / ": "
 * separators — so prompts are byte-identical to the experiment's.
 */
export function pyDumps(value: unknown): string {
  if (value === null || value === undefined) return "null";
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(pyDumps).join(", ")}]`;
  const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== undefined);
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}: ${pyDumps(v)}`).join(", ")}}`;
}
