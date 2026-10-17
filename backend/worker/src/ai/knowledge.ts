import type { Env } from "../env";
import type { Context, Instructions } from "./prompts";
import { deadline } from "./provider";
import { clampText } from "./validate";

export interface KnowledgeHit {
  id: string;
  title: string;
  summary: string;
  note: string;
}

interface KnowledgeInput {
  object: string;
  instructions: Instructions;
  answers?: Context["answers"];
}

function domainFor(text: string): string | undefined {
  const rules: Array<[RegExp, string]> = [
    [/მაცივარ|სარეცხ|ჭურჭლის/i, "appliances"],
    [/ავტომატ|ფარ|როზეტ|ჩამრთველ|ნათურ/i, "electrical"],
    [/მანქან|აკუმულატორ|ძრავ/i, "automotive"],
    [/wi-fi|როუტერ/i, "networking"],
    [/ონკან|სიფონ|მილ/i, "plumbing"],
    [/ველოსიპედ/i, "bicycles"],
  ];
  return rules.find(([pattern]) => pattern.test(text))?.[1];
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid knowledge response");
  return value as Record<string, unknown>;
}

function field(record: Record<string, unknown>, primary: string, fallback: string, max: number): string {
  const preferred = record[primary];
  const value = typeof preferred === "string" && preferred.trim() ? preferred : record[fallback];
  return typeof value === "string" ? clampText(value, max) : "";
}

/** Text-only, best-effort reference lookup; never accepts or forwards a photo. */
export async function lookupKnowledge(env: Env, input: KnowledgeInput, signal?: AbortSignal): Promise<KnowledgeHit[]> {
  if (env.KNOWLEDGE_HUB_ENABLED !== "true" || !env.KNOWLEDGE_HUB_URL || !env.KNOWLEDGE_HUB_KEY) return [];
  const instructions = typeof input.instructions === "string"
    ? input.instructions : input.instructions.map(item => item.title).join(". ");
  const text = input.object + ". " + instructions;
  const query = clampText([text, ...(input.answers ?? []).map(item =>
    `${item.question}: ${item.answer}${item.unit ? " " + item.unit : ""}`)].join(". "), 500);
  const domain = domainFor(text);
  const limit = deadline(2500, signal);
  const start = Date.now();
  try {
    limit.signal.throwIfAborted();
    const res = await fetch(env.KNOWLEDGE_HUB_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.KNOWLEDGE_HUB_KEY}`,
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
      },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "knowledge_search", arguments: { query, limit: 3, ...(domain && { domain }) } },
      }),
      signal: limit.signal,
    });
    if (!res.ok) throw new Error("Knowledge HTTP failure");
    const rpc = object(await res.json());
    if (rpc.error) throw new Error("Knowledge RPC failure");
    const result = object(rpc.result);
    if (result.isError) throw new Error("Knowledge tool failure");
    let data = result.structuredContent;
    if (data === undefined) {
      const content = result.content;
      if (!Array.isArray(content) || typeof object(content[0]).text !== "string") throw new Error("Missing knowledge content");
      data = JSON.parse(object(content[0]).text as string);
    }
    const results = object(data).results;
    if (!Array.isArray(results)) throw new Error("Invalid knowledge results");
    const hits = results.slice(0, 3).map(item => {
      const record = object(object(item).record);
      if (typeof record.id !== "string" || !record.id.trim()) throw new Error("Invalid knowledge ID");
      const title = field(record, "title_ka", "title", 80);
      const summary = field(record, "summary_ka", "summary", 240);
      if (!title || !summary) throw new Error("Missing knowledge text");
      return { id: clampText(record.id, 120), title, summary, note: field(record, "scope_note", "limitations", 160) };
    });
    console.log(`knowledge: ${hits.length} records in ${Date.now() - start} ms`);
    return hits;
  } catch {
    // Never log upstream bodies/errors: they may contain credentials or user text.
    console.warn("knowledge: lookup skipped");
    return [];
  } finally {
    limit.clear();
  }
}
