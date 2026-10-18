/** Gemini REST transport, normalized to the response events consumed by the shared
 * validator. It never calls OpenAI; both providers use the same steps parser/tidying. */
import { aiErrors } from "./errors";
import type { Usage } from "./pricing";
import type { JsonSchema } from "./schema";
import { softened, validateSchema } from "./schema";
import { readSse } from "../sse";

export const GEMINI_MODEL = "gemini-3.8-flash";
interface GeminiResponse {
  candidates?: Array<{ finishReason?: string; content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>;
  usageMetadata?: Record<string, number>;
  error?: unknown;
}

export function geminiUsage(raw?: Record<string, number>): Usage | null {
  if (!raw || raw.promptTokenCount === undefined || raw.totalTokenCount === undefined) return null;
  const counts = [raw.promptTokenCount, raw.totalTokenCount, raw.candidatesTokenCount ?? 0, raw.thoughtsTokenCount ?? 0];
  if (counts.some(n => !Number.isInteger(n) || n < 0)) return null;
  return {
    input_tokens: raw.promptTokenCount,
    output_tokens: Math.max((raw.candidatesTokenCount ?? 0) + (raw.thoughtsTokenCount ?? 0), raw.totalTokenCount - raw.promptTokenCount),
    output_tokens_details: { reasoning_tokens: raw.thoughtsTokenCount ?? 0 },
  };
}

function content(raw: GeminiResponse): string {
  return (raw.candidates?.[0]?.content?.parts ?? []).filter(p => !p.thought).map(p => p.text ?? "").join("");
}

type Props = Record<string, JsonSchema>;

/** Gemini rejects bounded steps arrays once tools/hands increase grammar complexity.
 * Keep their count as guidance on the wire; the shared validator still enforces
 * the original bounds. Nullable types and all per-step constraints stay intact.
 */
export function geminiSchema(schema: JsonSchema): JsonSchema {
  const result = structuredClone(schema);
  const steps = (result.properties as Props | undefined)?.steps;
  const fields = (steps?.items as JsonSchema | undefined)?.properties as Props | undefined;
  if (steps && (fields?.toolCards || fields?.hands)) {
    const { minItems, maxItems } = steps;
    if (typeof minItems === "number" && typeof maxItems === "number") {
      const count = minItems === maxItems ? `exactly ${minItems}` : `between ${minItems} and ${maxItems}`;
      steps.description = [steps.description, `Return ${count} steps.`].filter(Boolean).join(" ");
      delete steps.minItems;
      delete steps.maxItems;
    }
  }
  return result;
}

/** Every object schema reachable through properties/items that has a `box` property. */
function boxObjects(schema: JsonSchema, visit: (item: JsonSchema) => void): void {
  const props = schema.properties as Props | undefined;
  if (props?.box) visit(schema);
  for (const sub of Object.values(props ?? {})) boxObjects(sub, visit);
  if (schema.items && typeof schema.items === "object") boxObjects(schema.items as JsonSchema, visit);
}

/** Gemini's native boxes: `box` [x0,y0,x1,y1] → `box_2d` [ymin,xmin,ymax,xmax], in place. */
function renameBoxes(schema: JsonSchema): void {
  boxObjects(schema, item => {
    const props = item.properties as Props;
    const renamed: Props = {};
    for (const [key, value] of Object.entries(props)) renamed[key === "box" ? "box_2d" : key] = value;
    item.properties = renamed;
    item.required = (item.required as string[] | undefined)?.map(key => key === "box" ? "box_2d" : key);
  });
}

/** Walks `value` along the renamed schema and turns every `box_2d` back into an XYXY `box`. */
function unrenameBoxes(schema: JsonSchema, value: unknown): unknown {
  if (Array.isArray(value)) {
    return schema.items && typeof schema.items === "object" ? value.map(v => unrenameBoxes(schema.items as JsonSchema, v)) : value;
  }
  if (!value || typeof value !== "object") return value;
  const props = (schema.properties ?? {}) as Props;
  const out: Record<string, unknown> = {};
  for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
    if (key === "box_2d" && props.box_2d) {
      const [y0, x0, y1, x1] = v as [number, number, number, number];
      out.box = [x0, y0, x1, y1];
    } else {
      out[key] = props[key] ? unrenameBoxes(props[key]!, v) : v;
    }
  }
  return out;
}

export async function postGemini(apiKey: string, payload: Record<string, unknown>, signal: AbortSignal): Promise<Response> {
  const stream = payload.stream === true;
  const schema = structuredClone((payload.text as { format: { schema: JsonSchema } }).format.schema);
  const input = (payload.input as Array<{ content: Array<{ type: string; text?: string; image_url?: string }> }>)[0]!;
  const parts = input.content.map(item => item.type === "input_text"
    ? { text: stream ? item.text : item.text!.replaceAll("box=[x0,y0,x1,y1]", "box_2d=[ymin,xmin,ymax,xmax]") }
    : { inlineData: { mimeType: "image/jpeg", data: item.image_url!.split(",")[1] } });
  if (!stream) renameBoxes(schema);
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:${stream ? "streamGenerateContent?alt=sse" : "generateContent"}`, {
    method: "POST", signal,
    headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
    body: JSON.stringify({ contents: [{ role: "user", parts }], generationConfig: {
      responseMimeType: "application/json", responseJsonSchema: geminiSchema(schema),
      thinkingConfig: { thinkingLevel: "low" }, maxOutputTokens: 8192, candidateCount: 1,
    } }),
  });
  // Never log provider bodies or exception text (may contain credentials).
  if (!response.ok || !response.body) throw aiErrors.upstream();
  if (!stream) {
    let raw: GeminiResponse;
    try { raw = await response.json<GeminiResponse>(); } catch {
      if (signal.aborted) throw new Error("AI request aborted");
      throw aiErrors.invalid();
    }
    if (raw.candidates?.length !== 1 || raw.candidates[0]?.finishReason !== "STOP") throw aiErrors.incomplete();
    let parsed: unknown;
    try { parsed = JSON.parse(content(raw)); } catch { throw aiErrors.invalid(); }
    // Length caps are guidance; callers clamp (as with the Responses API).
    if (validateSchema(softened(schema), parsed)) throw aiErrors.invalid();
    const result = unrenameBoxes(schema, parsed);
    // Parts keep their strict box check; other stages drop bad items themselves.
    const found = (result as { parts?: Array<{ label: string; box: number[] }> }).parts;
    if ((schema.properties as Record<string, JsonSchema>).parts && found?.some(p => {
      const [x0, y0, x1, y1] = p.box as [number, number, number, number];
      return y1 <= y0 || x1 <= x0 || !p.label.trim();
    })) throw aiErrors.invalid();
    return Response.json({ status: "completed", usage: geminiUsage(raw.usageMetadata),
      output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(result) }] }] });
  }
  const messages = readSse(response.body);
  let usage: Usage | null = null;
  let finished = false;
  const encoder = new TextEncoder();
  const frame = (data: unknown) => encoder.encode(`data: ${JSON.stringify(data)}\n\n`);
  return new Response(new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        while (true) {
          const next = await messages.next();
          if (next.done) {
            if (!finished) throw aiErrors.incomplete();
            controller.enqueue(frame({ type: "response.completed", response: { status: "completed", usage } }));
            controller.close();
            return;
          }
          let raw: GeminiResponse;
          try { raw = JSON.parse(next.value.data); } catch { throw aiErrors.invalid(); }
          if (raw.error) throw aiErrors.upstream();
          if (raw.usageMetadata) usage = geminiUsage(raw.usageMetadata);
          const candidate = raw.candidates?.[0];
          if (candidate?.finishReason) {
            if (candidate.finishReason !== "STOP") throw aiErrors.incomplete();
            finished = true;
          }
          if ((raw.candidates?.length ?? 0) > 1) throw aiErrors.invalid();
          const delta = content(raw);
          if (delta) {
            controller.enqueue(frame({ type: "response.output_text.delta", delta }));
            return;
          }
        }
      } catch (err) { controller.error(err); }
    },
    async cancel() { await messages.return(undefined); },
  }));
}
