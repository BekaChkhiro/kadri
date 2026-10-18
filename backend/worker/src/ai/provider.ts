/** Two-stage providers with shared validation, incremental steps and continuation rules.
 * Astra is the deployment default; Gemini is selected only through the gated request field.
 */
import { GEMINI_MODEL, postGemini } from "./gemini";
import type { KnowledgeHit } from "./knowledge";
import { answerTurnLimit, DEFAULT_ANSWER_TURN_LIMIT } from "../limits";
import type { Env } from "../env";
import { ApiError } from "../errors";
import { aiErrors } from "./errors";
import { DEFAULT_EFFORT, DEFAULT_MODEL, LEGACY_STEPS_OUTPUT_LIMIT, outputText, postResponses, responsesPayload, type ResponseObject } from "./openai";
import { estimateCost, type Usage } from "./pricing";
import { promptParts, promptSteps, type Context, type Instructions } from "./prompts";
import { schemaParts, schemaSteps, softened, stepItemSchema, validateSchema, type JsonSchema } from "./schema";
import { StepsStreamParser } from "./stepsParser";
import {
  MAX_ROUNDS,
  partsFromModel,
  stepRuleError,
  tidyContinuation,
  tidyStep,
  type Continuation,
  type ModelStep,
  type Part,
  type SizeEvidence,
  type Step,
} from "./validate";
import { readSse } from "../sse";

export const AI_TIMEOUT_MS = 60_000;

export interface PartsInput {
  /** JPEG (longest side ≤768px) as base64. */
  imageBase64: string;
  instructions: Instructions;
  /** A later photo of a multi-photo session; absent on round 1. */
  context?: Context;
}

export interface PartsResult {
  object: string;
  parts: Part[];
  model: string;
  usage: Usage | null;
  costUsd: number | null;
  latencyMs: number;
}

export interface PartsProvider {
  readonly name: string;
  parts(input: PartsInput, signal?: AbortSignal): Promise<PartsResult>;
}

export interface StepsInput {
  knowledge?: KnowledgeHit[];
  capabilities?: readonly string[];
  object: string;
  /** The phone's parts; their IDs are the only ones the schema allows. */
  parts: Part[];
  instructions: Instructions;
  count: number;
  /** Optional JPEG as base64; the experiment attaches the photo to stage 2 too. */
  imageBase64?: string;
  /** A later photo of a multi-photo session; absent on round 1. */
  context?: Context;
}

/** A model code like "WAN28", "RTX-4070" or "F28-a" in the person's text or the part names. */
const MODEL_MARKER = /\b[A-Za-z]{1,6}-?\d{2,}[A-Za-z0-9-]*\b/;

/** What tidyStep may confirm a tool size against (tools_v2): parts, instructions, answers, knowledge. */
export function sizeEvidence(input: StepsInput): SizeEvidence {
  const instructions = typeof input.instructions === "string"
    ? input.instructions
    : input.instructions.map((s) => `${s.title} ${s.text}`).join(" ");
  const answers = (input.context?.answers ?? []).map((a) => `${a.question} ${a.answer} ${a.unit ?? ""}`);
  const text = [...input.parts.map((p) => p.name), instructions, ...answers].join(" ");
  return { text, modelKnown: (input.knowledge?.length ?? 0) > 0 || MODEL_MARKER.test(text) };
}

export type StepsEvent =
  | { type: "step"; index: number; step: Step }
  | {
      type: "done";
      unknownParts: string[];
      model: string;
      usage: Usage | null;
      costUsd: number | null;
      latencyMs: number;
      firstStepMs: number | null;
      continuation: Continuation;
    };

export interface StepsProvider {
  readonly name: string;
  /** Yields each step as soon as it is complete and valid, then `done`. Throws ApiError. */
  steps(input: StepsInput, signal?: AbortSignal): AsyncGenerator<StepsEvent>;
}

export interface AstraConfig {
  answerTurnLimit?: number;
  apiKey: string;
  model: string;
  effort: string;
  timeoutMs?: number;
  firstStepTimeoutMs?: number;
}

/** Aborts after `ms` or when `outer` aborts; `timedOut()` tells the two apart. */
export function deadline(ms: number, outer?: AbortSignal) {
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, ms);
  const onAbort = () => controller.abort();
  outer?.addEventListener("abort", onAbort);
  if (outer?.aborted) onAbort();
  return {
    signal: controller.signal,
    timedOut: () => timedOut,
    abort: () => controller.abort(),
    stopTimer: () => clearTimeout(timer),
    clear: () => {
      clearTimeout(timer);
      outer?.removeEventListener("abort", onAbort);
    },
  };
}

export class AstraProvider implements PartsProvider, StepsProvider {
  readonly name: string = "astra";
  protected post(apiKey: string, payload: Record<string, unknown>, signal: AbortSignal): Promise<Response> {
    return postResponses(apiKey, payload, signal);
  }
  constructor(readonly config: AstraConfig) {}

  async parts(input: PartsInput, signal?: AbortSignal): Promise<PartsResult> {
    const { model, effort, apiKey } = this.config;
    const payload = responsesPayload({
      model,
      effort,
      stage: "parts",
      prompt: promptParts(input.instructions, input.context),
      schema: schemaParts(),
      imageBase64: input.imageBase64,
    });
    const limit = deadline(this.config.timeoutMs ?? AI_TIMEOUT_MS, signal);
    const start = Date.now();
    let response: ResponseObject;
    try {
      const res = await this.post(apiKey, payload, limit.signal);
      if (!res.ok) {
        console.error("ai/parts upstream status", res.status, (await res.text()).slice(0, 500));
        throw aiErrors.upstream();
      }
      response = await res.json<ResponseObject>();
    } catch (err) {
      if (err instanceof ApiError) throw err;
      if (limit.timedOut()) throw aiErrors.timeout();
      console.error("ai/parts fetch failed", err);
      throw aiErrors.upstream();
    } finally {
      limit.clear();
    }
    const latencyMs = Date.now() - start;
    const usage = response.usage ?? null;
    const text = outputText(response);
    if (response.status !== "completed" || !text) {
      console.error("ai/parts incomplete", response.status);
      throw aiErrors.incomplete();
    }
    let result: { object: string; parts: Part[] };
    try {
      result = partsFromModel(JSON.parse(text));
    } catch (err) {
      console.error("ai/parts invalid output", String(err), text.slice(0, 1000));
      throw aiErrors.invalid();
    }
    return { ...result, model, usage, costUsd: estimateCost(usage, model), latencyMs };
  }

  async *steps(input: StepsInput, signal?: AbortSignal): AsyncGenerator<StepsEvent> {
    const { model, effort, apiKey } = this.config;
    const ids = input.parts.map((p) => p.id);
    const labels = new Map(input.parts.map((p) => [p.id, p.name]));
    const lastRound = (input.context?.round ?? 1) >= MAX_ROUNDS;
    const continuationOptions = {
      capabilities: input.capabilities,
      answerCount: input.context?.answers?.length ?? 0,
      answerTurnLimit: this.config.answerTurnLimit ?? DEFAULT_ANSWER_TURN_LIMIT,
      lastRound,
      ...(input.capabilities?.includes("check_photo") && {
        checkPhotos: input.context?.checkPhotos ?? 0,
        askedQuestions: (input.context?.answers ?? []).map((a) => a.question),
      }),
    };
    const schema = schemaSteps(ids, input.count, { freeText: typeof input.instructions === "string", ...continuationOptions });
    // Length caps are guidance for the model; tidyStep clamps instead of a 502.
    const itemSchema = softened(stepItemSchema(ids, input.capabilities));
    const promptParts = input.parts.map((p) => ({ id: p.id, label: p.name, box: p.box }));
    const payload = responsesPayload({
      model,
      effort,
      stage: "steps",
      prompt: promptSteps(input.object, promptParts, input.instructions, input.context, {
        ...continuationOptions,
        knowledge: input.knowledge,
        maxRound: MAX_ROUNDS,
        count: input.count,
      }),
      schema,
      imageBase64: input.imageBase64,
    });
    // tools_v2/hands_v1 add cards, actions and hands to every step: they do not fit the legacy budget.
    if (!input.capabilities?.some(c => ["needs_answer", "needs_measurement", "summary", "tools_v2", "check_photo", "hands_v1"].includes(c))) {
      payload.max_output_tokens = LEGACY_STEPS_OUTPUT_LIMIT;
    }
    const evidence = sizeEvidence(input);
    const checkStep = (raw: unknown): Step => {
      const schemaErr = validateSchema(itemSchema, raw);
      const step = schemaErr ? null : tidyStep(raw as ModelStep, labels, evidence);
      const err = schemaErr ?? stepRuleError(step!, labels);
      if (err) {
        console.error("ai/steps invalid step", err);
        throw aiErrors.invalid();
      }
      return step!;
    };

    const limit = deadline(this.config.timeoutMs ?? AI_TIMEOUT_MS, signal);
    const firstStepLimit = this.config.firstStepTimeoutMs === undefined
      ? undefined
      : deadline(this.config.firstStepTimeoutMs, limit.signal);
    const upstreamSignal = firstStepLimit?.signal ?? limit.signal;
    const start = Date.now();
    let firstStepMs: number | null = null;
    try {
      const res = await this.post(apiKey, payload, upstreamSignal);
      if (!res.ok || !res.body) {
        console.error("ai/steps upstream status", res.status, (await res.text()).slice(0, 500));
        throw aiErrors.upstream();
      }
      const parser = new StepsStreamParser();
      let text = "";
      let emitted = 0;
      let final: ResponseObject | null = null;
      for await (const msg of readSse(res.body)) {
        if (msg.data === "[DONE]") continue;
        let ev: { type?: string; delta?: string; response?: ResponseObject };
        try {
          ev = JSON.parse(msg.data);
        } catch {
          continue;
        }
        if (ev.type === "response.output_text.delta" && typeof ev.delta === "string") {
          text += ev.delta;
          for (const raw of parser.push(ev.delta)) {
            if (emitted >= input.count) throw aiErrors.invalid();
            const step = checkStep(raw);
            firstStepLimit?.stopTimer();
            firstStepMs ??= Date.now() - start;
            yield { type: "step", index: emitted++, step };
          }
        } else if (
          ev.type === "response.completed" ||
          ev.type === "response.incomplete" ||
          ev.type === "response.failed"
        ) {
          final = ev.response ?? null;
        } else if (ev.type === "error") {
          console.error("ai/steps stream error", msg.data.slice(0, 500));
          throw aiErrors.upstream();
        }
      }
      if (!final) throw aiErrors.upstream();
      const latencyMs = Date.now() - start;
      const usage = final.usage ?? null;
      const full = outputText(final) || text;
      if (final.status !== "completed" || !full) {
        console.error("ai/steps incomplete", final.status);
        throw aiErrors.incomplete();
      }
      let result: { steps: ModelStep[]; unknown_parts: string[]; continuation?: unknown };
      try {
        result = JSON.parse(full);
      } catch {
        throw aiErrors.invalid();
      }
      // Older fixtures (and a model that skips it) mean complete, not a 502.
      if (typeof result === "object" && result !== null) {
        result.continuation ??= { kind: "complete", prompt: null, reason: null };
      }
      // Validate steps strictly, but let tidyContinuation handle damaged/unsupported
      // continuation fields, including kinds excluded by the turn limit.
      const continuationSchema = (schema.properties as Record<string, JsonSchema>).continuation!;
      const validationResult = typeof result === "object" && result !== null ? {
        ...result,
        continuation: Object.fromEntries(Object.keys(continuationSchema.properties as Record<string, JsonSchema>).map(key =>
          [key, key === "kind" ? "complete" : key === "options" ? [] : null])),
      } : result;
      const err = validateSchema(softened(schema), validationResult);
      if (err) {
        console.error("ai/steps invalid result", err);
        throw aiErrors.invalid();
      }
      // Normally every step was already streamed; this covers a stream the
      // incremental parser could not follow.
      for (; emitted < result.steps.length; emitted++) {
        firstStepLimit?.stopTimer();
        firstStepMs ??= Date.now() - start;
        yield { type: "step", index: emitted, step: checkStep(result.steps[emitted]) };
      }
      yield {
        type: "done",
        unknownParts: result.unknown_parts,
        model,
        usage,
        costUsd: estimateCost(usage, model),
        latencyMs,
        firstStepMs,
        continuation: tidyContinuation(result.continuation, continuationOptions),
      };
    } catch (err) {
      if (err instanceof ApiError) throw err;
      if (limit.timedOut() || firstStepLimit?.timedOut()) throw aiErrors.timeout();
      console.error("ai/steps failed", err);
      throw aiErrors.upstream();
    } finally {
      firstStepLimit?.clear();
      firstStepLimit?.abort();
      limit.clear();
      // Also stops the upstream request when the consumer quits early.
      limit.abort();
    }
  }
}

export class GeminiProvider extends AstraProvider {
  override readonly name = "gemini";
  protected override async post(apiKey: string, payload: Record<string, unknown>, signal: AbortSignal): Promise<Response> {
    try { return await postGemini(apiKey, payload, signal); }
    catch (err) {
      if (err instanceof ApiError) throw err;
      if (signal.aborted) throw new Error("AI request aborted");
      throw aiErrors.upstream();
    }
  }
}

/** Selection is opt-in; requests without a provider retain the deployment default. */
export function selectedEnv(env: Env, requested: unknown): Env {
  if (requested === undefined || requested === null || requested === "") return env;
  if (requested !== "astra" && requested !== "gemini") throw aiErrors.badRequest("provider არასწორია");
  if (env.ALLOW_PROVIDER_SELECTION !== "true") throw aiErrors.badRequest("AI-ის არჩევა ამ გარემოში გამორთულია");
  return { ...env, AI_PROVIDER: requested };
}

function providerFor(env: Env, timing: Pick<AstraConfig, "timeoutMs" | "firstStepTimeoutMs"> = {}): AstraProvider {
  switch (env.AI_PROVIDER ?? "astra") {
    case "astra":
      return new AstraProvider({ ...astraConfig(env), ...timing });
    case "gemini":
      if (!env.GEMINI_API_KEY) throw aiErrors.notConfigured();
      return new GeminiProvider({ apiKey: env.GEMINI_API_KEY, model: GEMINI_MODEL, effort: "low", answerTurnLimit: answerTurnLimit(env), ...timing });
    case "hybrid":
      // TODO(hybrid): Gemini stage 1 (parts) behind GEMINI_API_KEY, Astra stage 2.
      // Experimental and not yet quality-confirmed (see experiments/som-test/HYBRID.md).
      throw aiErrors.providerUnavailable();
    default:
      throw aiErrors.notConfigured();
  }
}

export function partsProvider(env: Env, timeoutMs?: number): PartsProvider {
  return providerFor(env, { timeoutMs });
}

export function stepsProvider(env: Env, timeoutMs?: number, firstStepTimeoutMs?: number): StepsProvider {
  return providerFor(env, { timeoutMs, firstStepTimeoutMs });
}

export function astraConfig(env: Env): AstraConfig {
  if (!env.OPENAI_API_KEY) throw aiErrors.notConfigured();
  return {
    apiKey: env.OPENAI_API_KEY,
    model: env.AI_MODEL || DEFAULT_MODEL,
    effort: env.AI_EFFORT || DEFAULT_EFFORT,
    answerTurnLimit: answerTurnLimit(env),
  };
}
