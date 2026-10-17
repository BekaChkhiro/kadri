/**
 * AI providers for the two stages. `astra` is the default (Astra C:
 * gpt-6-astra for both stages). `hybrid` (Gemini stage 1) is an interface
 * placeholder only — its quality is not confirmed.
 */
import type { Env } from "../env";
import { ApiError } from "../errors";
import { aiErrors } from "./errors";
import { DEFAULT_EFFORT, DEFAULT_MODEL, outputText, postResponses, responsesPayload, type ResponseObject } from "./openai";
import { estimateCost, type Usage } from "./pricing";
import { promptParts, promptSteps, type Context, type Instructions } from "./prompts";
import { schemaParts, schemaSteps, softened, stepItemSchema, validateSchema } from "./schema";
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
  apiKey: string;
  model: string;
  effort: string;
  timeoutMs?: number;
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
  return {
    signal: controller.signal,
    timedOut: () => timedOut,
    abort: () => controller.abort(),
    clear: () => {
      clearTimeout(timer);
      outer?.removeEventListener("abort", onAbort);
    },
  };
}

export class AstraProvider implements PartsProvider, StepsProvider {
  readonly name = "astra";
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
      const res = await postResponses(apiKey, payload, limit.signal);
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
    const schema = schemaSteps(ids, input.count, { freeText: typeof input.instructions === "string", lastRound });
    // Length caps are guidance for the model; tidyStep clamps instead of a 502.
    const itemSchema = softened(stepItemSchema(ids));
    const promptParts = input.parts.map((p) => ({ id: p.id, label: p.name, box: p.box }));
    const payload = responsesPayload({
      model,
      effort,
      stage: "steps",
      prompt: promptSteps(input.object, promptParts, input.instructions, input.context, {
        maxRound: MAX_ROUNDS,
        count: input.count,
      }),
      schema,
      imageBase64: input.imageBase64,
    });
    const checkStep = (raw: unknown): Step => {
      const schemaErr = validateSchema(itemSchema, raw);
      const step = schemaErr ? null : tidyStep(raw as ModelStep, labels);
      const err = schemaErr ?? stepRuleError(step!, labels);
      if (err) {
        console.error("ai/steps invalid step", err);
        throw aiErrors.invalid();
      }
      return step!;
    };

    const limit = deadline(this.config.timeoutMs ?? AI_TIMEOUT_MS, signal);
    const start = Date.now();
    let firstStepMs: number | null = null;
    try {
      const res = await postResponses(apiKey, payload, limit.signal);
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
      const err = validateSchema(softened(schema), result);
      if (err) {
        console.error("ai/steps invalid result", err);
        throw aiErrors.invalid();
      }
      // Normally every step was already streamed; this covers a stream the
      // incremental parser could not follow.
      for (; emitted < result.steps.length; emitted++) {
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
        continuation: lastRound ? { kind: "complete" } : tidyContinuation(result.continuation),
      };
    } catch (err) {
      if (err instanceof ApiError) throw err;
      if (limit.timedOut()) throw aiErrors.timeout();
      console.error("ai/steps failed", err);
      throw aiErrors.upstream();
    } finally {
      limit.clear();
      // Also stops the upstream request when the consumer quits early.
      limit.abort();
    }
  }
}

function astraFor(env: Env): AstraProvider {
  switch (env.AI_PROVIDER ?? "astra") {
    case "astra":
      return new AstraProvider(astraConfig(env));
    case "hybrid":
      // TODO(hybrid): Gemini stage 1 (parts) behind GEMINI_API_KEY, Astra stage 2.
      // Experimental and not yet quality-confirmed (see experiments/som-test/HYBRID.md).
      throw aiErrors.providerUnavailable();
    default:
      throw aiErrors.notConfigured();
  }
}

export function partsProvider(env: Env): PartsProvider {
  return astraFor(env);
}

export function stepsProvider(env: Env): StepsProvider {
  return astraFor(env);
}

export function astraConfig(env: Env): AstraConfig {
  if (!env.OPENAI_API_KEY) throw aiErrors.notConfigured();
  return {
    apiKey: env.OPENAI_API_KEY,
    model: env.AI_MODEL || DEFAULT_MODEL,
    effort: env.AI_EFFORT || DEFAULT_EFFORT,
  };
}
