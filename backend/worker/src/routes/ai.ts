import { lookupKnowledge } from "../ai/knowledge";
import { partsHandler, partsResponse, readPartsRequest } from "../ai/parts";
import { aiErrors } from "../ai/errors";
import { DEFAULT_MODEL } from "../ai/openai";
import type { Usage } from "../ai/pricing";
import { deadline, partsProvider, stepsProvider, type StepsProvider } from "../ai/provider";
import { readStepsRequest, stepsHandler, stepsStream } from "../ai/steps";
import type { Env } from "../env";
import { ApiError } from "../errors";
import { aiAttemptTimeoutMs, aiFirstStepTimeoutMs, aiTimeoutMs, assertDailyLimit, recordUsage, type UsageRow, type UsageStatus } from "../limits";
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

/** Only model validation and provider deadlines qualify; cancellation never does. */
function retryable(err: unknown, signal: AbortSignal): err is ApiError {
  return !signal.aborted && err instanceof ApiError &&
    (err.code === "ai_invalid_response" || err.code === "ai_timeout");
}

/** Authenticated parts: one retry, with a separate usage row for each paid attempt. */
export const guardedPartsHandler: Handler = async ({ request, env }) => {
  const { sub } = await requireSession(request, env);
  await assertDailyLimit(env, sub);
  const provider = partsProvider(env, aiAttemptTimeoutMs(env));
  const { input, sessionId } = await readPartsRequest(request);
  const base = { userId: sub, sessionId, stage: "parts", provider: provider.name, model: env.AI_MODEL || DEFAULT_MODEL } as const;
  const limit = deadline(aiTimeoutMs(env), request.signal);
  try {
    for (let attempt = 0; ; attempt++) {
      limit.signal.throwIfAborted();
      const start = Date.now();
      try {
        const result = await provider.parts(input, limit.signal);
        await record(env, {
          ...base, model: result.model, ...tokens(result.usage),
          costUsd: result.costUsd ?? 0, latencyMs: result.latencyMs, status: "ok",
        });
        return partsResponse(result);
      } catch (err) {
        const error = limit.timedOut() ? aiErrors.timeout() : err;
        await record(env, { ...base, ...tokens(null), costUsd: 0, latencyMs: Date.now() - start, status: statusOf(error) });
        if (attempt !== 0 || !retryable(error, limit.signal)) throw error;
        console.log(`ai/parts retry after ${error.code}`);
      }
    }
  } finally {
    limit.clear();
  }
};

/** Authenticated steps: retry before the first step only, within one total stream deadline. */
export const guardedStepsHandler: Handler = async ({ request, env, ctx }) => {
  const { sub } = await requireSession(request, env);
  const provider = stepsProvider(env, aiTimeoutMs(env), aiFirstStepTimeoutMs(env));
  const { input, sessionId } = await readStepsRequest(request);
  input.knowledge = await lookupKnowledge(env, {
    object: input.object, instructions: input.instructions, answers: input.context?.answers,
  }, request.signal);
  const base = { userId: sub, sessionId, stage: "steps", provider: provider.name, model: env.AI_MODEL || DEFAULT_MODEL } as const;
  const limit = deadline(aiTimeoutMs(env), request.signal);
  const retried: StepsProvider = {
    name: provider.name,
    async *steps(input, signal) {
      for (let attempt = 0; ; attempt++) {
        limit.signal.throwIfAborted();
        const start = Date.now();
        let emitted = false;
        let row: UsageRow = { ...base, ...tokens(null), costUsd: 0, latencyMs: 0, status: "error" };
        try {
          for await (const event of provider.steps(input, signal)) {
            if (event.type === "step") emitted = true;
            else row = {
              ...base, model: event.model, ...tokens(event.usage),
              costUsd: event.costUsd ?? 0, latencyMs: event.latencyMs, status: "ok",
            };
            yield event;
          }
          return;
        } catch (err) {
          const error = limit.timedOut() ? aiErrors.timeout() : err;
          row.status = statusOf(error);
          if (attempt !== 0 || emitted || !retryable(error, limit.signal)) throw error;
          console.log(`ai/steps retry after ${error.code}`);
        } finally {
          if (row.status !== "ok") row.latencyMs = Date.now() - start;
          // Await insertion to keep attempts ordered; the stream's lifetime is
          // retained by waitUntil, including client disconnects.
          const recording = record(env, row);
          ctx.waitUntil(recording);
          await recording;
        }
      }
    },
  };
  return stepsStream(retried, input, {
    signal: limit.signal,
    timedOut: limit.timedOut,
    onEnd: () => limit.clear(),
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
