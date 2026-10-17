/**
 * POST /ai/parts — stage 1 of Astra C: photo + instructions → visible parts
 * with boxes (0–1000 XYXY) and server-assigned IDs p1..pN.
 *
 * Body: multipart/form-data (`image` JPEG file, `instructions` text or JSON
 * list) or JSON `{ image: base64 | data URL, instructions }`.
 */
import { json } from "../errors";
import type { Handler } from "../router";
import { aiErrors } from "./errors";
import { checkedJpegBase64, fromBase64 } from "./image";
import { partsProvider, type PartsInput } from "./provider";
import { parseInstructions } from "./validate";

async function readBody(request: Request): Promise<{ image: Uint8Array | null; instructions: unknown }> {
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
    return { image, instructions: form.get("instructions") };
  }
  if (type.startsWith("application/json")) {
    let body: Record<string, unknown>;
    try {
      body = await request.json<Record<string, unknown>>();
    } catch {
      throw aiErrors.badRequest("JSON ვერ წავიკითხე");
    }
    const image = typeof body?.image === "string" ? fromBase64(body.image) : null;
    return { image, instructions: body?.instructions };
  }
  throw aiErrors.badRequest("საჭიროა multipart/form-data ან application/json");
}

export async function readPartsInput(request: Request): Promise<PartsInput> {
  const { image, instructions } = await readBody(request);
  return { imageBase64: checkedJpegBase64(image), instructions: parseInstructions(instructions) };
}

export const partsHandler: Handler = async ({ request, env }) => {
  const provider = partsProvider(env);
  const input = await readPartsInput(request);
  const result = await provider.parts(input, request.signal);
  return json({
    object: result.object,
    parts: result.parts,
    model: result.model,
    usage: result.usage,
    costUsd: result.costUsd,
    latencyMs: result.latencyMs,
  });
};
