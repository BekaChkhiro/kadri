/**
 * OpenAI Responses API payloads, as variant_c.request_stage builds them.
 * Single upstream call: guarded AI routes own the eligible retry and log each paid attempt.
 */
import type { JsonSchema } from "./schema";
import type { Usage } from "./pricing";

export const RESPONSES_URL = "https://api.openai.com/v1/responses";
export const DEFAULT_MODEL = "gpt-6-astra";
/** `minimal` is not supported by gpt-6-astra; `low` is the measured setting. */
export const DEFAULT_EFFORT = "low";
/** Reasoning and visible output share this budget. Legacy steps retain their cap. */
export const LEGACY_STEPS_OUTPUT_LIMIT = 2200;
export const OUTPUT_LIMITS = { parts: 1200, steps: 4000 } as const;

export type Stage = keyof typeof OUTPUT_LIMITS;

export interface StageRequest {
  model: string;
  effort: string;
  stage: Stage;
  prompt: string;
  schema: JsonSchema;
  /** JPEG bytes as base64, sent with detail "high". */
  imageBase64?: string;
}

export function responsesPayload(r: StageRequest): Record<string, unknown> {
  const content: Array<Record<string, unknown>> = [{ type: "input_text", text: r.prompt }];
  if (r.imageBase64) {
    content.push({ type: "input_image", image_url: `data:image/jpeg;base64,${r.imageBase64}`, detail: "high" });
  }
  const payload: Record<string, unknown> = {
    model: r.model,
    store: false,
    max_output_tokens: OUTPUT_LIMITS[r.stage],
    input: [{ role: "user", content }],
    text: { format: { type: "json_schema", name: `variant_c_${r.stage}`, strict: true, schema: r.schema } },
  };
  if (r.model.startsWith("gpt-5") || r.model.startsWith("gpt-6")) {
    payload.reasoning = { effort: r.effort };
  }
  if (r.stage === "steps") payload.stream = true;
  return payload;
}

export interface ResponseObject {
  status?: string;
  model?: string;
  usage?: Usage | null;
  output?: Array<{ type?: string; content?: Array<{ type?: string; text?: string }> }>;
}

/** Equivalent of the SDK's `response.output_text`. */
export function outputText(response: ResponseObject): string {
  let text = "";
  for (const item of response.output ?? []) {
    if (item.type !== "message") continue;
    for (const c of item.content ?? []) {
      if (c.type === "output_text" && typeof c.text === "string") text += c.text;
    }
  }
  return text;
}

export function postResponses(
  apiKey: string,
  payload: Record<string, unknown>,
  signal: AbortSignal,
): Promise<Response> {
  return fetch(RESPONSES_URL, {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify(payload),
    signal,
  });
}
