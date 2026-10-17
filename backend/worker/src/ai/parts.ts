/**
 * POST /ai/parts — stage 1 of Astra C: photo + instructions → visible parts
 * with boxes (0–1000 XYXY) and server-assigned IDs p1..pN.
 *
 * Body: multipart/form-data (`image` JPEG file, `instructions` text or JSON
 * list, optional `sessionId`, optional `context` as a JSON string) or JSON
 * `{ image: base64 | data URL, instructions, sessionId?, context? }`.
 * `context` {round 2..5, photoPrompt, doneSteps, previousObject?} marks a later
 * photo of a multi-photo session (see docs/AI_LIVE_CHECK.md); absent = round 1.
 */
import { json } from "../errors";
import type { Handler } from "../router";
import { aiErrors } from "./errors";
import { checkedJpegBase64, fromBase64 } from "./image";
import { partsProvider, type PartsInput, type PartsResult } from "./provider";
import { parseContext, parseInstructions } from "./validate";

interface PartsBody {
  image: Uint8Array | null;
  instructions: unknown;
  sessionId: unknown;
  context: unknown;
}

async function readBody(request: Request): Promise<PartsBody> {
  const type = request.headers.get("content-type") ?? "";
  if (type.startsWith("multipart/form-data")) {
    let form: FormData;
    try {
      form = await request.formData();
    } catch {
      throw aiErrors.badRequest("multipart ვერ წავიკითხე");
    }
    const file = form.get("image");
    const image = typeof file === "object" && file !== null ? new Uint8Array(await (file as Blob).arrayBuffer()) : null;
    return {
      image,
      instructions: form.get("instructions"),
      sessionId: form.get("sessionId"),
      context: form.get("context"),
    };
  }
  if (type.startsWith("application/json")) {
    let body: Record<string, unknown>;
    try {
      body = await request.json<Record<string, unknown>>();
    } catch {
      throw aiErrors.badRequest("JSON ვერ წავიკითხე");
    }
    const image = typeof body?.image === "string" ? fromBase64(body.image) : null;
    return { image, instructions: body?.instructions, sessionId: body?.sessionId, context: body?.context };
  }
  throw aiErrors.badRequest("საჭიროა multipart/form-data ან application/json");
}

/** Optional client session ID (history), used only to tag the usage row. */
export function parseSessionId(raw: unknown): string | null {
  if (raw === undefined || raw === null || raw === "") return null;
  if (typeof raw !== "string" || raw.length > 128) throw aiErrors.badRequest("sessionId არასწორია");
  return raw;
}

export async function readPartsRequest(request: Request): Promise<{ input: PartsInput; sessionId: string | null }> {
  const body = await readBody(request);
  const imageBase64 = checkedJpegBase64(body.image);
  const instructions = parseInstructions(body.instructions);
  const context = parseContext(body.context);
  return {
    input: { imageBase64, instructions, ...(context && { context }) },
    sessionId: parseSessionId(body.sessionId),
  };
}

export async function readPartsInput(request: Request): Promise<PartsInput> {
  return (await readPartsRequest(request)).input;
}

export function partsResponse(result: PartsResult): Response {
  return json({
    object: result.object,
    parts: result.parts,
    model: result.model,
    usage: result.usage,
    costUsd: result.costUsd,
    latencyMs: result.latencyMs,
  });
}

/** Bare stage handler: no auth, limit or usage. The app mounts the guarded one (src/routes/ai.ts). */
export const partsHandler: Handler = async ({ request, env }) => {
  const provider = partsProvider(env);
  const input = await readPartsInput(request);
  return partsResponse(await provider.parts(input, request.signal));
};
