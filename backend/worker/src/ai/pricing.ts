/**
 * Cost estimate, ported from experiments/som-test/vision.py (PRICES,
 * estimate_cost). USD per 1M tokens: normal input, cached input, cache write,
 * output. Checked 2026-10-17; an estimate, not an invoice.
 */
export const PRICES: Record<string, readonly [number, number, number, number]> = {
  "gemini-3.8-flash": [0.75, 0.75, 0.75, 3.75],
  "gpt-6-astra": [10, 1, 12.5, 50],
  "gpt-6.1-sol": [2, 0.1, 2.5, 10],
};

export const PRICE_SOURCE = "https://developers.openai.com/api/docs/pricing";

export interface Usage {
  input_tokens: number;
  output_tokens: number;
  input_tokens_details?: Record<string, number> | null;
  [key: string]: unknown;
}

/** USD estimate, or null when the tariff or a billing category is unknown. */
export function estimateCost(usage: Usage | null | undefined, model: string): number | null {
  const prices = PRICES[model];
  if (!usage || !prices || usage.input_tokens > 200_000) return null;
  const details = usage.input_tokens_details ?? {};
  // Do not invent cache-write charges if the response reports a new billing category.
  if (Object.entries(details).some(([k, v]) => v && k !== "cached_tokens" && k !== "cache_write_tokens")) {
    return null;
  }
  const [normal, cached, cacheWrite, output] = prices;
  const cachedCount = details.cached_tokens ?? 0;
  const writeCount = details.cache_write_tokens ?? 0;
  return (
    ((usage.input_tokens - cachedCount - writeCount) * normal +
      cachedCount * cached +
      writeCount * cacheWrite +
      usage.output_tokens * output) /
    1_000_000
  );
}
