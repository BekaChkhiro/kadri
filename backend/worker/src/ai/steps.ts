/**
 * POST /ai/steps — stage 2 of Astra C: object + the phone's parts (p1..pN)
 * + instructions → steps, streamed as SSE while the model is still writing.
 *
 * Body (JSON): { object, parts: [{id, name, box}], instructions, count?, image?, sessionId? }
 * `image` (JPEG base64, optional) is attached like the experiment does.
 *
 * Events: `step` {index, title, text, focus, avoid, markers, arrows, tools, tip, warn}
 * per completed step, then `done` {unknownParts, usage, costUsd, latencyMs,
 * firstStepMs, model}, or `error` {code, message} in Georgian.
 */
import { ApiError } from "../errors";
import type { Handler } from "../router";
import { sseResponse } from "../sse";
import { aiErrors } from "./errors";
import { checkedJpegBase64, fromBase64 } from "./image";
import { parseSessionId } from "./parts";
import { stepsProvider, type StepsEvent, type StepsInput, type StepsProvider } from "./provider";
import { MAX_STEPS, parseInstructions, parseParts } from "./validate";

export async function readStepsRequest(request: Request): Promise<{ input: StepsInput; sessionId: string | null }> {
  if (!(request.headers.get("content-type") ?? "").startsWith("application/json")) {
    throw aiErrors.badRequest("საჭიროა application/json");
  }
  let body: Record<string, unknown>;
  try {
    body = await request.json<Record<string, unknown>>();
  } catch {
    throw aiErrors.badRequest("JSON ვერ წავიკითხე");
  }
  if (typeof body !== "object" || body === null) throw aiErrors.badRequest("JSON ობიექტი უნდა იყოს");
  if (typeof body.object !== "string" || body.object.length > 300) throw aiErrors.badRequest("object არასწორია");
  const parts = parseParts(body.parts);
  const instructions = parseInstructions(body.instructions);
  // Free text: 5 steps, as in the design's flows (Camera/artboards/car.tsx).
  let count = Array.isArray(instructions) ? instructions.length : 5;
  if (body.count !== undefined) {
    if (typeof body.count !== "number" || !Number.isInteger(body.count) || body.count < 1 || body.count > MAX_STEPS) {
      throw aiErrors.badRequest(`count უნდა იყოს 1–${MAX_STEPS}`);
    }
    count = body.count;
  }
  let imageBase64: string | undefined;
  if (body.image !== undefined && body.image !== null) {
    imageBase64 = checkedJpegBase64(typeof body.image === "string" ? fromBase64(body.image) : null);
  }
  return {
    input: { object: body.object, parts, instructions, count, imageBase64 },
    sessionId: parseSessionId(body.sessionId),
  };
}

export async function readStepsInput(request: Request): Promise<StepsInput> {
  return (await readStepsRequest(request)).input;
}

export type StepsDone = Extract<StepsEvent, { type: "done" }>;

/** How a steps stream ended: `done` (sent), an `error` event, or the client went away. */
export type StepsOutcome = { kind: "done"; done: StepsDone } | { kind: "error"; error: ApiError } | { kind: "gone" };

export interface StepsStreamOptions {
  signal?: AbortSignal;
  /** True when `signal` fired because of our own deadline; the error event becomes ai_timeout. */
  timedOut?: () => boolean;
  /** Called once, after the last event was written. */
  onEnd?: (outcome: StepsOutcome) => void;
}

export function stepsStream(provider: StepsProvider, input: StepsInput, opts: StepsStreamOptions = {}): Response {
  return sseResponse(async (send) => {
    let outcome: StepsOutcome = { kind: "gone" };
    try {
      for await (const ev of provider.steps(input, opts.signal)) {
        if (ev.type === "done") outcome = { kind: "done", done: ev };
        const ok =
          ev.type === "step"
            ? await send("step", { index: ev.index, ...ev.step })
            : await send("done", {
                unknownParts: ev.unknownParts,
                usage: ev.usage,
                costUsd: ev.costUsd,
                latencyMs: ev.latencyMs,
                firstStepMs: ev.firstStepMs,
                model: ev.model,
              });
        // Client went away: stop reading (the generator aborts the upstream call).
        if (!ok) return;
      }
    } catch (err) {
      const e = opts.timedOut?.() ? aiErrors.timeout() : err instanceof ApiError ? err : aiErrors.upstream();
      if (!(err instanceof ApiError)) console.error("ai/steps failed", err);
      outcome = { kind: "error", error: e };
      await send("error", { code: e.code, message: e.message });
    } finally {
      opts.onEnd?.(outcome);
    }
  });
}

/** Bare stage handler: no auth or usage. The app mounts the guarded one (src/routes/ai.ts). */
export const stepsHandler: Handler = async ({ request, env }) => {
  const provider = stepsProvider(env);
  const input = await readStepsInput(request);
  return stepsStream(provider, input, { signal: request.signal });
};
