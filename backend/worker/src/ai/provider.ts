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
import { promptParts, type Instructions } from "./prompts";
import { schemaParts } from "./schema";
import { partsFromModel, type Part } from "./validate";

export const AI_TIMEOUT_MS = 60_000;

export interface PartsInput {
  /** JPEG (longest side ≤768px) as base64. */
  imageBase64: string;
  instructions: Instructions;
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
    clear: () => {
      clearTimeout(timer);
      outer?.removeEventListener("abort", onAbort);
    },
  };
}

export class AstraProvider implements PartsProvider {
  readonly name = "astra";
  constructor(readonly config: AstraConfig) {}

  async parts(input: PartsInput, signal?: AbortSignal): Promise<PartsResult> {
    const { model, effort, apiKey } = this.config;
    const payload = responsesPayload({
      model,
      effort,
      stage: "parts",
      prompt: promptParts(input.instructions),
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
}

export function astraConfig(env: Env): AstraConfig {
  if (!env.OPENAI_API_KEY) throw aiErrors.notConfigured();
  return {
    apiKey: env.OPENAI_API_KEY,
    model: env.AI_MODEL || DEFAULT_MODEL,
    effort: env.AI_EFFORT || DEFAULT_EFFORT,
  };
}

export function partsProvider(env: Env): PartsProvider {
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
