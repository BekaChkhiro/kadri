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

/**
 * Length caps of the design's short texts (2026-10-17). They are sent in the
 * strict schemas, but only as guidance: whether the Responses API enforces
 * maxLength is not something we rely on, so `softened` drops them for our own
 * validation and validate.ts clamps what still overflows instead of a 502.
 */
export const LIMITS = {
  object: 40,
  label: 60,
  title: 40,
  text: 120,
  tip: 100,
  warn: 100,
  tools: 3,
  tool: 24,
  markers: 3,
  markerLabel: 24,
} as const;

/** The phone's icon set for a step's main action (2026-10-17). */
export const STEP_ICONS = [
  "rotate_cw", "rotate_ccw", "unscrew", "tighten", "pull", "push", "press", "open",
  "close", "pour", "check", "clean", "place", "remove", "wait", "warning",
] as const;

/** The phone's icon set for tools. */
export const TOOL_ICONS = [
  "wrench", "screwdriver", "pliers", "hex_key", "hammer", "bucket", "gloves", "towel", "cloth", "brush",
  "flashlight", "tape", "knife", "funnel", "container", "oil", "water", "cable", "phone", "paper",
] as const;

/** variant_c.schema_parts */
export function schemaParts(): JsonSchema {
  return obj({
    object: { type: "string", maxLength: LIMITS.object },
    parts: {
      ...array(
        obj({
          label: { type: "string", minLength: 1, maxLength: LIMITS.label },
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
  const capped = (max: number): JsonSchema => ({ type: "string", maxLength: max });
  const step = obj({
    title: { type: "string", minLength: 1, maxLength: LIMITS.title },
    text: capped(LIMITS.text),
    focus: array(part()),
    avoid: array(part()),
    markers: {
      ...array(
        obj({
          part: part(),
          label: capped(LIMITS.markerLabel),
          tone: { type: "string", enum: ["brand", "danger", "neutral"] },
        }),
      ),
      maxItems: LIMITS.markers,
    },
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
    icon: {
      type: ["string", "null"],
      enum: [...STEP_ICONS, null],
      description: "ნაბიჯის მთავარი მოქმედება; თუ არცერთი არ ერგება — null",
    },
    tools: {
      ...array(
        obj({
          name: capped(LIMITS.tool),
          icon: { type: ["string", "null"], enum: [...TOOL_ICONS, null] },
        }),
      ),
      maxItems: LIMITS.tools,
    },
    tip: { type: ["string", "null"], maxLength: LIMITS.tip },
    warn: { type: ["string", "null"], maxLength: LIMITS.warn },
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
      "მოქმედების სამიზნე ხილული ნაწილების ID-ები. რამდენიმე კანდიდატიდან აირჩიე ყველაზე " +
      "სავარაუდო. ცარიელი მხოლოდ მაშინ, როცა სამიზნე საერთოდ არ ჩანს. არ გამოიგონო ID.";
    step.warn!.description =
      "ერთი წინადადება მხოლოდ რეალურ საფრთხეზე ან დაზიანების რისკზე, სხვა შემთხვევაში null.";
  }
  return result;
}

/**
 * `schema` without the soft caps of LIMITS: every maxLength, and maxItems of
 * `tools`/`markers` (but not the `maxItems: 0` that forbids references when
 * there are no parts). Hard rules — enums, required keys, step count — stay.
 */
export function softened(schema: JsonSchema): JsonSchema {
  const out: JsonSchema = {};
  for (const [key, value] of Object.entries(schema)) {
    if (key === "maxLength") continue;
    if (key === "properties") {
      const props: Props = {};
      for (const [name, sub] of Object.entries(value as Props)) {
        const soft = softened(sub);
        if ((name === "tools" || name === "markers") && typeof soft.maxItems === "number" && soft.maxItems > 0) {
          delete soft.maxItems;
        }
        props[name] = soft;
      }
      out[key] = props;
    } else if (key === "items" && typeof value === "object" && value !== null) {
      out[key] = softened(value as JsonSchema);
    } else {
      out[key] = value;
    }
  }
  return out;
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
