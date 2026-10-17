import { partsHandler, partsResponse, readPartsRequest } from "../ai/parts";
import { DEFAULT_MODEL } from "../ai/openai";
import type { Usage } from "../ai/pricing";
import { deadline, partsProvider, stepsProvider } from "../ai/provider";
import { readStepsRequest, stepsHandler, stepsStream } from "../ai/steps";
import type { Env } from "../env";
import { ApiError } from "../errors";
import { aiTimeoutMs, assertDailyLimit, recordUsage, withTimeout, type UsageRow, type UsageStatus } from "../limits";
import type { Handler, Router } from "../router";
import { requireSession } from "../session";

export interface AiRoute {
  method: "POST";
  pattern: string;
  handler: Handler;
}

function tokens(usage: Usage | null | undefined) {
  const details = usage?.output_tokens_details as { reasoning_tokens?: number } | null | undefined;
  return {
    inputTokens: usage?.input_tokens ?? 0,
    outputTokens: usage?.output_tokens ?? 0,
    reasoningTokens: details?.reasoning_tokens ?? 0,
  };
}

function statusOf(err: unknown): UsageStatus {
  return err instanceof ApiError && err.code === "ai_timeout" ? "timeout" : "error";
}

/** A failed usage insert must not fail a paid request that already succeeded. */
async function record(env: Env, row: UsageRow): Promise<void> {
  try {
    await recordUsage(env, row);
  } catch (err) {
    console.error("usage insert failed", row.stage, err);
  }
}

/**
 * POST /ai/parts for the app: session → daily limit → AI call under AI_TIMEOUT_MS → usage row
 * (ok, error or timeout; failed calls count towards the limit too). Never retried.
 */
export const guardedPartsHandler: Handler = async ({ request, env }) => {
  const { sub } = await requireSession(request, env);
  await assertDailyLimit(env, sub);
  const provider = partsProvider(env);
  const { input, sessionId } = await readPartsRequest(request);
  const base = { userId: sub, sessionId, stage: "parts", provider: provider.name, model: env.AI_MODEL || DEFAULT_MODEL } as const;
  const start = Date.now();
  try {
    const result = await withTimeout(aiTimeoutMs(env), (signal) =>
      provider.parts(input, AbortSignal.any([signal, request.signal])),
    );
    await record(env, {
      ...base,
      model: result.model,
      ...tokens(result.usage),
      costUsd: result.costUsd ?? 0,
      latencyMs: result.latencyMs,
      status: "ok",
    });
    return partsResponse(result);
  } catch (err) {
    await record(env, { ...base, ...tokens(null), costUsd: 0, latencyMs: Date.now() - start, status: statusOf(err) });
    throw err;
  }
};

/**
 * POST /ai/steps for the app: session (no limit — the session was counted at /ai/parts) →
 * SSE under AI_TIMEOUT_MS for the whole stream → usage row via waitUntil once it ends.
 */
export const guardedStepsHandler: Handler = async ({ request, env, ctx }) => {
  const { sub } = await requireSession(request, env);
  const provider = stepsProvider(env);
  const { input, sessionId } = await readStepsRequest(request);
  const base = { userId: sub, sessionId, stage: "steps", provider: provider.name, model: env.AI_MODEL || DEFAULT_MODEL } as const;
  const limit = deadline(aiTimeoutMs(env), request.signal);
  const start = Date.now();
  return stepsStream(provider, input, {
    signal: limit.signal,
    timedOut: limit.timedOut,
    onEnd: (outcome) => {
      limit.clear();
      const row: UsageRow =
        outcome.kind === "done"
          ? {
              ...base,
              model: outcome.done.model,
              ...tokens(outcome.done.usage),
              costUsd: outcome.done.costUsd ?? 0,
              latencyMs: outcome.done.latencyMs,
              status: "ok",
            }
          : {
              ...base,
              ...tokens(null),
              costUsd: 0,
              latencyMs: Date.now() - start,
              status: outcome.kind === "error" ? statusOf(outcome.error) : "error",
            };
      ctx.waitUntil(record(env, row));
    },
  });
};

/** Bare stage routes (no auth, limit or usage) — for stage tests and scripts only. */
export function aiRoutes(): AiRoute[] {
  return [
    { method: "POST", pattern: "/ai/parts", handler: partsHandler },
    { method: "POST", pattern: "/ai/steps", handler: stepsHandler },
  ];
}

/** Mounts the bare stage routes; never use this in src/index.ts (see {@link mountGuardedAiRoutes}). */
export function mountAiRoutes(router: Router): Router {
  for (const r of aiRoutes()) router.on(r.method, r.pattern, r.handler);
  return router;
}

/** The app's AI routes: auth, daily limit, timeout and usage log around each stage. */
export function guardedAiRoutes(): AiRoute[] {
  return [
    { method: "POST", pattern: "/ai/parts", handler: guardedPartsHandler },
    { method: "POST", pattern: "/ai/steps", handler: guardedStepsHandler },
  ];
}

export function mountGuardedAiRoutes(router: Router): Router {
  for (const r of guardedAiRoutes()) router.on(r.method, r.pattern, r.handler);
  return router;
}
