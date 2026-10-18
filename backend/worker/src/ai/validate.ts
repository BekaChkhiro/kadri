/**
 * Validation of model output and request bodies. Model-output rules are
 * ported from experiments/som-test (variant_b.box_pixels, variant_c.assign_ids,
 * vision.validate_plan); failures are thrown as plain Errors with an English
 * reason for logs and mapped to a Georgian 502 by the caller.
 */
import { DEFAULT_ANSWER_TURN_LIMIT } from "../limits";
import { aiErrors } from "./errors";
import type { Context, Instructions } from "./prompts";
import { DIAGONAL_ARROW_DIRECTIONS, MOVE_ARROW_DIRECTIONS, CAPABILITIES, CHECK_PHOTO_LIMIT, FALLBACK_OPTIONS, HAND_GRIPS, HAND_SIDES, LIMITS, photoPromptLimit, schemaParts, softened, STEP_ICONS, TOOL_ICONS, validateSchema } from "./schema";
import { ACTION_AMOUNTS, ACTION_KINDS, AMOUNT_KINDS, genericFitCheck, TOOL_IDS, toolHasSize } from "./tools";

export type Box = [number, number, number, number];

export interface Part {
  id: string;
  name: string;
  box: Box;
}

export const MAX_PARTS = 12;
export const MAX_STEPS = 12;
/** Photos in one multi-photo session; the last round can only complete. */
export const MAX_ROUNDS = 5;

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
  const err = validateSchema(softened(schemaParts()), result);
  if (err) throw new Error(`parts schema: ${err}`);
  const r = result as { object: string; parts: Array<{ label: string; box: number[] }> };
  // Busy scenes (microscope, motherboard) return more than MAX_PARTS; keep the model's first ones instead of a 502.
  const kept = r.parts.slice(0, MAX_PARTS);
  const parts = assignIds(kept).map((p) => ({ ...p, name: clampText(p.name, LIMITS.label) }));
  return { object: clampText(r.object, LIMITS.object), parts };
}

/**
 * Collapses whitespace and cuts `text` to at most `max` characters, at a word
 * boundary when one is close, ending in "…". Over-long model text is clamped
 * rather than rejected: the call is already paid for. "soft" keeps the word
 * cut only past 60% of `max`; "always" (short prompts the user reads) past 40%.
 */
export function clampText(text: string, max: number, wordBoundary: "soft" | "always" = "soft"): string {
  const clean = text.replace(/\s+/g, " ").trim();
  const chars = [...clean];
  if (chars.length <= max) return clean;
  let cut = chars.slice(0, max - 1).join("");
  const space = cut.lastIndexOf(" ");
  if (space >= (max - 1) * (wordBoundary === "always" ? 0.4 : 0.6)) cut = cut.slice(0, space);
  return cut.replace(/[\s,;:.\-–—]+$/u, "") + "…";
}

export interface Step {
  title: string;
  text: string;
  focus: string[];
  avoid: string[];
  markers: Array<{ part: string; label: string; tone: string }>;
  arrows: Array<{ part: string; type: string; dir: string }>;
  /** Main action, one of STEP_ICONS. */
  icon: string | null;
  /** Tool names only, as before toolItems existed (older clients). */
  tools: string[];
  toolItems: Array<{ label: string; icon: string | null }>;
  tip: string | null;
  warn: string | null;
  /** tools_v2 only: catalog tools (TOOL_IDS) with size and reason. */
  toolCards?: ToolCard[];
  /** tools_v2 only: animated actions on the phone's parts. */
  actions?: StepAction[];
  /** hands_v1 only: where and with which hand to grip, turn, push, pull or support. */
  hands?: StepHand[];
}

export interface StepHand {
  part: string;
  grip: string;
  hand: string;
  /** The action needs no tool (its step then has no toolCards for it). */
  byHandOnly: boolean;
}

export type SizeSource = "seen" | "model" | "typical";

export interface ToolCard {
  id: string;
  size: string | null;
  /** seen: read on the photo/label; model: a known model's spec; typical: the usual size, unconfirmed. */
  sizeSource: SizeSource;
  /** How to check a typical size yourself and what to try next. */
  fitCheck: string | null;
  /** ≤2 other sizes to try. */
  alternatives: string[];
  why: string;
  notThis: { id: string; reason: string } | null;
}

export interface StepAction {
  part: string;
  kind: string;
  amount: string | null;
  order: string[] | null;
}

/** A step as the model writes it (schemaFor): tools are {name, icon} objects. */
export type ModelStep = Omit<Step, "tools" | "toolItems"> & {
  tools: Array<{ name: string; icon: string | null }>;
};

/**
 * What a card's size claim can be checked against: the part names,
 * instructions and answers as one string, and whether the device's model
 * is known (a Knowledge Hub hit or a model code in the text).
 */
export interface SizeEvidence {
  text: string;
  modelKnown: boolean;
}

/** "PH2", "M6", "10 მმ" → "PH2", "M6", "10"; letters and digits only (a decimal point stays). */
const sizeCore = (size: string) => size.toUpperCase().replace(/,/g, ".").replace(/[^A-Z0-9.]/g, "").replace(/^\.+|\.+$/g, "");

/** The evidence as standalone tokens: "ჭანჭიკი M6x20, PH 2" → M6, 20, PH, 2, PH2. */
function evidenceTokens(text: string): Set<string> {
  const upper = text.toUpperCase().replace(/,/g, ".");
  const split = (t: string) => t.split(/[^A-Z0-9.]+|(?<=\d)X(?=\d)/).map((w) => w.replace(/^\.+|\.+$/g, "")).filter(Boolean);
  return new Set([...split(upper), ...split(upper.replace(/\b([A-Z]+)[\s-]+(?=\d)/g, "$1"))]);
}

/**
 * tools_v2 cards: unknown or repeated ids dropped, unknown notThis as null,
 * texts clamped, ≤3. A size is never passed off as fact: "seen" needs the
 * size in the evidence text, "model" a known model, everything else is
 * "typical" with a fitCheck; tools without a size get none.
 */
function tidyToolCards(cards: ToolCard[], evidence?: SizeEvidence): ToolCard[] {
  const seen = new Set<string>();
  const out: ToolCard[] = [];
  let dropped = false;
  let downgraded = false;
  const tokens = evidence ? evidenceTokens(evidence.text) : new Set<string>();
  for (const card of cards) {
    if (!TOOL_IDS.includes(card.id) || seen.has(card.id)) {
      dropped = true;
      continue;
    }
    seen.add(card.id);
    const notThis = card.notThis && TOOL_IDS.includes(card.notThis.id) && card.notThis.id !== card.id
      ? { id: card.notThis.id, reason: clampText(card.notThis.reason ?? "", LIMITS.toolWhy) }
      : null;
    if (card.notThis && !notThis) console.warn("ai/steps tidy: unknown notThis tool set to null");
    const sized = toolHasSize(card.id);
    const size = sized && typeof card.size === "string" ? clampText(card.size, LIMITS.toolSize) || null : null;
    const claimed: SizeSource = card.sizeSource === "seen" || card.sizeSource === "model" ? card.sizeSource : "typical";
    let sizeSource: SizeSource = claimed;
    if (size === null) sizeSource = "typical";
    else if (claimed === "seen" && !tokens.has(sizeCore(size))) sizeSource = "typical";
    else if (claimed === "model" && !evidence?.modelKnown) sizeSource = "typical";
    if (sizeSource !== claimed && size !== null) downgraded = true;
    const given = typeof card.fitCheck === "string" ? clampText(card.fitCheck, LIMITS.fitCheck) || null : null;
    const fitCheck = !sized ? null : sizeSource === "typical" ? given ?? genericFitCheck(card.id) : given;
    const alternatives = sized && Array.isArray(card.alternatives)
      ? [...new Set(card.alternatives
          .filter((a): a is string => typeof a === "string")
          .map((a) => clampText(a, LIMITS.toolSize))
          .filter((a) => a && a !== size))].slice(0, LIMITS.toolAlternatives)
      : [];
    out.push({ id: card.id, size, sizeSource, fitCheck, alternatives, why: clampText(card.why ?? "", LIMITS.toolWhy), notThis });
  }
  if (dropped) console.warn("ai/steps tidy: unknown or duplicate tool card dropped");
  if (downgraded) console.warn("ai/steps tidy: unconfirmed tool size marked typical");
  return out.slice(0, LIMITS.toolCards);
}

/** tools_v2 actions: only on labelled parts and known kinds; amount/order only where they mean something. */
function tidyActions(actions: StepAction[], labels: Map<string, string>): StepAction[] {
  const isPart = (id: unknown): id is string => typeof id === "string" && !!(labels.get(id) ?? "").trim();
  const kept = actions.filter((a) => isPart(a.part) && (ACTION_KINDS as readonly string[]).includes(a.kind));
  if (kept.length !== actions.length) console.warn("ai/steps tidy: action with unknown part or kind dropped");
  const seen = new Set<string>();
  const out: StepAction[] = [];
  for (const a of kept) {
    const key = `${a.part}:${a.kind}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const amount = AMOUNT_KINDS.includes(a.kind) && (ACTION_AMOUNTS as readonly unknown[]).includes(a.amount) ? a.amount : null;
    let order: string[] | null = null;
    if (a.kind === "tighten_order" && Array.isArray(a.order)) {
      const ids = [...new Set(a.order.filter(isPart))];
      if (ids.length !== a.order.length) console.warn("ai/steps tidy: unknown or duplicate order part dropped");
      order = ids.length >= 2 ? ids : null;
    }
    out.push({ part: a.part, kind: a.kind, amount, order });
  }
  return out.slice(0, LIMITS.actions);
}

/** hands_v1: only on labelled parts with a known grip and hand; one per part+hand, ≤2. */
function tidyHands(hands: StepHand[], labels: Map<string, string>): StepHand[] {
  const isPart = (id: unknown): id is string => typeof id === "string" && !!(labels.get(id) ?? "").trim();
  const kept = hands.filter((h) => typeof h === "object" && h !== null && isPart(h.part) &&
    (HAND_GRIPS as readonly unknown[]).includes(h.grip) && (HAND_SIDES as readonly unknown[]).includes(h.hand));
  if (kept.length !== hands.length) console.warn("ai/steps tidy: hand hint with unknown part, grip or hand dropped");
  const seen = new Set<string>();
  const out: StepHand[] = [];
  for (const h of kept) {
    const key = `${h.part}:${h.hand}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ part: h.part, grip: h.grip, hand: h.hand, byHandOnly: h.byHandOnly === true });
  }
  return out.slice(0, LIMITS.hands);
}

const known = (set: readonly string[], icon: unknown): string | null =>
  typeof icon === "string" && set.includes(icon) ? icon : null;

/** "1. ", "2) ", "ნაბიჯი 3: " and the like in front of a title. */
const TITLE_NUMBER = /^\s*(?:ნაბიჯი\s*)?\d+\s*(?:[.):](?!\d)|\s[-–—])\s*/u;

/** The first 1–3 words of a part name that fit a marker, before any " — evidence" or ", detail". */
export function shortLabel(name: string): string {
  const head = name.split(/\s+[—–-]\s+|[,;(]/u)[0] ?? name;
  let label = "";
  for (const word of head.trim().split(/\s+/).slice(0, 3)) {
    const next = label ? `${label} ${word}` : word;
    if (label && [...next].length > LIMITS.markerLabel) break;
    label = next;
  }
  return clampText(label, LIMITS.markerLabel);
}

function validArrowDirection(arrow: { type: string; dir: string }): boolean {
  switch (arrow.type) {
    case "rotate": return arrow.dir === "cw" || arrow.dir === "ccw";
    case "move": return [...MOVE_ARROW_DIRECTIONS, ...DIAGONAL_ARROW_DIRECTIONS].some(dir => dir === arrow.dir);
    case "press": case "hold": case "align": return arrow.dir === "none";
    default: return false;
  }
}

/**
 * Brings a schema-valid step to the design's shape: no number before the
 * title, texts within LIMITS, ≤3 tools/markers, tools split into names and
 * toolItems, unknown icons as null, and a marker on the focus part
 * when the model sent none. Every synthesized reference is focus[0], which
 * stepRuleError checks anyway. Also repairs what is safe to repair (one
 * warning each): duplicate focus/avoid IDs, an ID in both (focus wins, its
 * danger marker turns brand), and arrows whose type/dir do not match.
 * Without `evidence` every tool size is "typical".
 */
export function tidyStep(step: ModelStep, labels: Map<string, string>, evidence?: SizeEvidence): Step {
  const optional = (value: string | null | undefined, max: number) => {
    const t = value == null ? "" : clampText(value, max);
    return t ? t : null;
  };
  const title = step.title.replace(TITLE_NUMBER, "").trim();
  const toolItems = step.tools
    .slice(0, LIMITS.tools)
    .map((t) => ({ label: clampText(t.name, LIMITS.tool), icon: known(TOOL_ICONS, t.icon) }));
  const focus = [...new Set(step.focus)];
  if (focus.length !== step.focus.length) console.warn("ai/steps tidy: duplicate focus ID dropped");
  const uniqueAvoid = [...new Set(step.avoid)];
  if (uniqueAvoid.length !== step.avoid.length) console.warn("ai/steps tidy: duplicate avoid ID dropped");
  // The step's target wins: an ID in both lists stays focus only.
  const avoid = uniqueAvoid.filter((id) => !focus.includes(id));
  const overlap = uniqueAvoid.filter((id) => focus.includes(id));
  if (overlap.length) console.warn("ai/steps tidy: ID in both focus and avoid kept as focus");
  const arrows = step.arrows.filter(validArrowDirection);
  if (arrows.length !== step.arrows.length) console.warn("ai/steps tidy: arrow with incompatible type/dir dropped");
  let markers = step.markers.slice(0, LIMITS.markers).map((m) => ({
    ...m,
    label: clampText(m.label, LIMITS.markerLabel),
    tone: overlap.includes(m.part) && m.tone === "danger" ? "brand" : m.tone,
  }));
  const target = focus[0];
  if (markers.length === 0 && target !== undefined) {
    markers = [
      {
        part: target,
        label: shortLabel(labels.get(target) ?? ""),
        tone: avoid.includes(target) ? "danger" : "brand",
      },
    ];
  }
  const hands = Array.isArray(step.hands) ? tidyHands(step.hands, labels) : undefined;
  // tools_v2+hands_v1: a step done entirely by hand needs no tool cards.
  const byHandOnly = hands !== undefined && hands.length > 0 && hands.every((h) => h.byHandOnly);
  let toolCards = Array.isArray(step.toolCards) ? tidyToolCards(step.toolCards, evidence) : undefined;
  if (byHandOnly && toolCards?.length) {
    console.warn("ai/steps tidy: tool cards dropped on a by-hand-only step");
    toolCards = [];
  }
  return {
    ...step,
    focus,
    avoid,
    arrows,
    title: clampText(title || step.title, LIMITS.title),
    text: clampText(step.text, LIMITS.text),
    markers,
    icon: known(STEP_ICONS, step.icon),
    tools: toolItems.map((t) => t.label),
    toolItems,
    tip: optional(step.tip, LIMITS.tip),
    warn: optional(step.warn, LIMITS.warn),
    ...(toolCards && { toolCards }),
    ...(Array.isArray(step.actions) && { actions: tidyActions(step.actions, labels) }),
    ...(hands && { hands }),
  };
}

/** vision.validate_plan's per-step rules (schema validation is done separately). */
export function stepRuleError(step: Step, labels: Map<string, string>): string | null {
  if (step.focus.some((id) => step.avoid.includes(id))) return "Same ID cannot be focus and avoid";
  for (const field of [step.focus, step.avoid]) {
    if (new Set(field).size !== field.length) return "Duplicate ID in step";
  }
  for (const arrow of step.arrows) {
    if (!validArrowDirection(arrow)) {
      return "Arrow direction incompatible with arrow type";
    }
  }
  const referenced = [...step.focus, ...step.avoid, ...step.markers.map((m) => m.part), ...step.arrows.map((a) => a.part),
    ...(step.actions ?? []).flatMap((a) => [a.part, ...(a.order ?? [])]), ...(step.hands ?? []).map((h) => h.part)];
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

/**
 * Optional request `context` of a later photo: an object, or (multipart) the
 * same object as a JSON string. Absent means round 1.
 */
export function parseContext(raw: unknown): Context | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  let value = raw;
  if (typeof raw === "string") {
    try {
      value = JSON.parse(raw);
    } catch {
      throw aiErrors.badRequest("context JSON ვერ წავიკითხე");
    }
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw aiErrors.badRequest("context ობიექტი უნდა იყოს");
  }
  const { round, photoPrompt, doneSteps, previousObject, answers, checkPhotos, checkPrompt } = value as Record<string, unknown>;
  if (typeof round !== "number" || !Number.isInteger(round) || round < 1 || round > MAX_ROUNDS) {
    throw aiErrors.badRequest(`context.round უნდა იყოს 1–${MAX_ROUNDS}`);
  }
  const validText = (v: unknown, max: number) => typeof v === "string" && v.trim().length > 0 && [...v].length <= max;
  if (answers !== undefined && (!Array.isArray(answers) || answers.length > 8 || answers.some(a =>
    typeof a !== "object" || a === null || Array.isArray(a) || !validText(a.question, 120) ||
    !validText(a.answer, 120) || (a.unit !== undefined && !validText(a.unit, 12))
  ))) throw aiErrors.badRequest("context.answers არასწორია");
  if (checkPhotos !== undefined && (typeof checkPhotos !== "number" || !Number.isInteger(checkPhotos) ||
      checkPhotos < 0 || checkPhotos > CHECK_PHOTO_LIMIT)) {
    throw aiErrors.badRequest(`context.checkPhotos უნდა იყოს 0–${CHECK_PHOTO_LIMIT}`);
  }
  if (checkPrompt !== undefined && !validText(checkPrompt, 120)) {
    throw aiErrors.badRequest("context.checkPrompt არასწორია");
  }
  // A verification photo of the first photo's steps is a round 1 follow-up too.
  if (round === 1 && (!Array.isArray(answers) || answers.length === 0) && checkPrompt === undefined) {
    throw aiErrors.badRequest("context.round 1-ს answers სჭირდება");
  }
  if ((round >= 2 || photoPrompt !== undefined) &&
      (typeof photoPrompt !== "string" || !photoPrompt.trim() || photoPrompt.length > 200)) {
    throw aiErrors.badRequest("context.photoPrompt არასწორია");
  }
  if (!Array.isArray(doneSteps) || doneSteps.length > 40) {
    throw aiErrors.badRequest("context.doneSteps უნდა იყოს ≤40 ნაბიჯის სია");
  }
  if (doneSteps.some((t) => typeof t !== "string" || t.length > 120)) {
    throw aiErrors.badRequest("context.doneSteps-ის ელემენტი არასწორია");
  }
  if (previousObject !== undefined && previousObject !== null && (typeof previousObject !== "string" || previousObject.length > 300)) {
    throw aiErrors.badRequest("context.previousObject არასწორია");
  }
  return {
    round,
    photoPrompt: typeof photoPrompt === "string" ? photoPrompt.trim() : "",
    ...(Array.isArray(answers) && { answers: answers.map(({ question, answer, unit }) => ({ question, answer, ...(unit !== undefined && { unit }) })) }),
    doneSteps: doneSteps as string[],
    ...(typeof previousObject === "string" && previousObject ? { previousObject } : {}),
    ...(checkPhotos !== undefined && { checkPhotos: checkPhotos as number }),
    ...(typeof checkPrompt === "string" && { checkPrompt: checkPrompt.trim() }),
  };
}

/** Recognized capabilities; unknown strings are ignored for forward compatibility. */
export function parseCapabilities(raw: unknown): string[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > 8 || raw.some(c => typeof c !== "string")) {
    throw aiErrors.badRequest("capabilities უნდა იყოს ≤8 სტრიქონის სია");
  }
  return [...new Set(raw.filter(c => (CAPABILITIES as readonly string[]).includes(c)))];
}

export type Continuation =
  | { kind: "complete"; cause?: string | null; summary?: string | null }
  | { kind: "needs_photo"; prompt: string; reason: string }
  | { kind: "needs_check_photo"; prompt: string; reason: string }
  | { kind: "needs_answer"; question: string; options: string[]; allowOther: boolean; reason: string | null }
  | { kind: "needs_measurement"; question: string; unit: string; min: number | null; max: number | null; how: string; reason: string | null };

export interface ContinuationOptions {
  capabilities?: readonly string[];
  answerCount?: number;
  answerTurnLimit?: number;
  lastRound?: boolean;
  /** check_photo: verification photos already sent (context.checkPhotos). */
  checkPhotos?: number;
  /** check_photo: questions already asked (context.answers), not to be asked again. */
  askedQuestions?: readonly string[];
}

/** For comparing questions: lower case, letters and digits only, single spaces. */
const normalizedQuestion = (text: string) =>
  text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

/**
 * needs_photo prompt/reason, cut at a word. Text exactly at the schema's
 * maxLength without closing punctuation was stopped by strict decoding
 * mid-word (Astra: „…წარწერების ახლ“, 2026-10-18): drop the broken word too.
 */
function photoText(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const clean = value.replace(/\s+/g, " ").trim();
  const stopped = [...clean].length === max && !/[.!?…»“”"')]$/u.test(clean);
  return clampText(clean, stopped ? max - 1 : max, "always") || null;
}

/** Invalid or unsupported continuations safely complete; legacy output stays unchanged. */
export function tidyContinuation(raw: unknown, opts: ContinuationOptions = {}): Continuation {
  const caps = opts.capabilities ?? [];
  const optional = (value: unknown, max: number) => typeof value === "string" ? clampText(value, max) || null : null;
  const complete = (value: Record<string, unknown> = {}): Continuation => caps.includes("summary")
    ? { kind: "complete", cause: optional(value.cause, 80), summary: optional(value.summary, 120) }
    : { kind: "complete" };
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return complete();
  const r = raw as Record<string, unknown>;
  if (r.kind === "complete") return complete(r);
  if (r.kind === "needs_photo") {
    const prompt = photoText(r.prompt, photoPromptLimit(caps));
    return !prompt || opts.lastRound ? complete() : { kind: "needs_photo", prompt, reason: photoText(r.reason, LIMITS.photoReason) ?? "" };
  }
  const checkPhoto = caps.includes("check_photo");
  const checkAllowed = checkPhoto && (opts.checkPhotos ?? 0) < CHECK_PHOTO_LIMIT;
  if (r.kind === "needs_check_photo" && checkPhoto) {
    const prompt = photoText(r.prompt, LIMITS.photoPromptV2);
    if (!prompt) return complete();
    const reason = photoText(r.reason, LIMITS.photoReason) ?? "";
    if (checkAllowed) return { kind: "needs_check_photo", prompt, reason };
    // Out of verification photos: a full new photo (a round) if one is left.
    console.warn("ai/steps tidy: check photo limit reached");
    return opts.lastRound ? complete() : { kind: "needs_photo", prompt, reason };
  }
  if ((opts.answerCount ?? 0) >= (opts.answerTurnLimit ?? DEFAULT_ANSWER_TURN_LIMIT)) return complete();
  const question = optional(r.question, 80);
  const reason = optional(r.reason, 100);
  if (!question) return complete();
  if (r.kind === "needs_answer" && caps.includes("needs_answer")) {
    const fallback = new Set(FALLBACK_OPTIONS.map(normalizedQuestion));
    const options = [...new Set((Array.isArray(r.options) ? r.options : []).map(o => optional(o, 24)).filter((o): o is string => o !== null))]
      .filter(o => !checkPhoto || !fallback.has(normalizedQuestion(o)))
      .slice(0, 4);
    if (options.length < 2) return complete();
    if (!checkPhoto) {
      return { kind: "needs_answer", question, options, allowOther: typeof r.allowOther === "boolean" ? r.allowOther : true, reason };
    }
    const asked = new Set((opts.askedQuestions ?? []).map(normalizedQuestion));
    if (asked.has(normalizedQuestion(question))) {
      console.warn("ai/steps tidy: repeated question replaced");
      return checkAllowed
        ? { kind: "needs_check_photo", prompt: clampText(`გადაიღე ახლოდან: ${question}`, LIMITS.photoPromptV2, "always"), reason: "ეს კითხვა უკვე იყო, ფოტოთი გადავამოწმებ" }
        : complete();
    }
    return { kind: "needs_answer", question, options: [...options, ...FALLBACK_OPTIONS], allowOther: true, reason };
  }
  if (r.kind === "needs_measurement" && caps.includes("needs_measurement")) {
    const unit = optional(r.unit, 12);
    if (!unit) return complete();
    const number = (v: unknown) => typeof v === "number" && Number.isFinite(v) ? v : null;
    return { kind: "needs_measurement", question, unit, min: number(r.min), max: number(r.max), how: optional(r.how, 100) ?? "", reason };
  }
  return complete();
}
