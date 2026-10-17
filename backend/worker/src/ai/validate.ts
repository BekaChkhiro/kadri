/**
 * Validation of model output and request bodies. Model-output rules are
 * ported from experiments/som-test (variant_b.box_pixels, variant_c.assign_ids,
 * vision.validate_plan); failures are thrown as plain Errors with an English
 * reason for logs and mapped to a Georgian 502 by the caller.
 */
import { aiErrors } from "./errors";
import type { Instructions } from "./prompts";
import { schemaParts, validateSchema } from "./schema";

export type Box = [number, number, number, number];

export interface Part {
  id: string;
  name: string;
  box: Box;
}

export const MAX_PARTS = 12;
export const MAX_STEPS = 12;

/** variant_b.box_pixels' checks: finite numbers in 0..1000, positive width/height. */
export function boxError(box: unknown): string | null {
  if (!Array.isArray(box) || box.length !== 4) return "box must have 4 numbers";
  if (box.some((v) => typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 1000)) {
    return "box coordinates must be finite numbers in 0..1000";
  }
  const [x0, y0, x1, y1] = box as Box;
  if (x0 >= x1 || y0 >= y1) return "box must have positive width and height";
  return null;
}

function compareTuple(a: Array<number | string>, b: Array<number | string>): number {
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (x < y) return -1;
    if (x > y) return 1;
  }
  return 0;
}

/**
 * variant_c.assign_ids: sort centers by y, then x; box/label break exact
 * ties, never model order. Returns p1..pN in that order.
 */
export function assignIds(parts: Array<{ label: string; box: number[] }>): Part[] {
  for (const p of parts) {
    const err = boxError(p.box);
    if (err) throw new Error(err);
    if (!p.label.trim()) throw new Error("Empty label");
  }
  const key = (p: { label: string; box: number[] }): Array<number | string> => {
    const [x0, y0, x1, y1] = p.box as Box;
    return [(y0 + y1) / 2, (x0 + x1) / 2, x0, y0, x1, y1, p.label];
  };
  const ordered = [...parts].sort((a, b) => compareTuple(key(a), key(b)));
  return ordered.map((p, i) => ({ id: `p${i + 1}`, name: p.label, box: [...p.box] as Box }));
}

/** Validates the parts-stage model JSON and renumbers IDs. Throws Error on any violation. */
export function partsFromModel(result: unknown): { object: string; parts: Part[] } {
  const err = validateSchema(schemaParts(), result);
  if (err) throw new Error(`parts schema: ${err}`);
  const r = result as { object: string; parts: Array<{ label: string; box: number[] }> };
  const parts = assignIds(r.parts);
  if (parts.length > MAX_PARTS) throw new Error(`too many parts: ${parts.length} > ${MAX_PARTS}`);
  return { object: r.object, parts };
}

export interface Step {
  title: string;
  text: string;
  focus: string[];
  avoid: string[];
  markers: Array<{ part: string; label: string; tone: string }>;
  arrows: Array<{ part: string; type: string; dir: string }>;
  tools: string[];
  warn: string | null;
}

/** vision.validate_plan's per-step rules (schema validation is done separately). */
export function stepRuleError(step: Step, labels: Map<string, string>): string | null {
  if (step.focus.some((id) => step.avoid.includes(id))) return "Same ID cannot be focus and avoid";
  for (const field of [step.focus, step.avoid]) {
    if (new Set(field).size !== field.length) return "Duplicate ID in step";
  }
  for (const arrow of step.arrows) {
    if ((arrow.type === "rotate") !== (arrow.dir === "cw" || arrow.dir === "ccw")) {
      return "Arrow direction incompatible with arrow type";
    }
  }
  const referenced = [...step.focus, ...step.avoid, ...step.markers.map((m) => m.part), ...step.arrows.map((a) => a.part)];
  if (referenced.some((id) => !(labels.get(id) ?? "").trim())) return "Referenced ID must have a recognized label";
  return null;
}

/** Request `instructions`: free text, or the experiment's [{title, text}] list. */
export function parseInstructions(value: unknown): Instructions {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed.startsWith("[")) {
      try {
        return parseInstructions(JSON.parse(trimmed));
      } catch {
        // Not JSON after all; treat as free text below.
      }
    }
    if (!trimmed) throw aiErrors.badRequest("instructions ცარიელია");
    if (trimmed.length > 4000) throw aiErrors.badRequest("instructions ძალიან გრძელია");
    return value;
  }
  if (Array.isArray(value)) {
    if (value.length < 1 || value.length > MAX_STEPS) {
      throw aiErrors.badRequest(`instructions-ში 1–${MAX_STEPS} ნაბიჯი უნდა იყოს`);
    }
    return value.map((s) => {
      if (typeof s !== "object" || s === null || typeof s.title !== "string" || typeof s.text !== "string") {
        throw aiErrors.badRequest("ყოველ ნაბიჯს title და text სჭირდება");
      }
      return { title: s.title, text: s.text };
    });
  }
  throw aiErrors.badRequest("instructions აკლია");
}

/** Request `parts` for the steps stage: the phone's p1..pN with names and boxes. */
export function parseParts(value: unknown): Part[] {
  if (!Array.isArray(value) || value.length > 24) throw aiErrors.badRequest("parts უნდა იყოს ≤24 ნაწილის სია");
  const seen = new Set<string>();
  return value.map((p) => {
    if (typeof p !== "object" || p === null) throw aiErrors.badRequest("parts-ის ელემენტი არასწორია");
    const { id, name, box } = p as Record<string, unknown>;
    if (typeof id !== "string" || !/^p[1-9]\d{0,2}$/.test(id) || seen.has(id)) {
      throw aiErrors.badRequest("ნაწილის id უნდა იყოს უნიკალური pN");
    }
    if (typeof name !== "string" || !name.trim() || name.length > 120) {
      throw aiErrors.badRequest("ნაწილის name არასწორია");
    }
    if (boxError(box)) throw aiErrors.badRequest("ნაწილის box არასწორია");
    seen.add(id);
    return { id, name, box: [...(box as number[])] as Box };
  });
}
