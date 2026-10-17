import { createExecutionContext, env } from "cloudflare:test";
import { vi } from "vitest";
import { Router } from "../src/router";
import { mountAiRoutes } from "../src/routes/ai";
import type { Env } from "../src/env";

/** Minimal JPEG: SOI + SOF0 header with the given size + EOI. Enough for size checks. */
export function fakeJpeg(width: number, height: number): Uint8Array {
  return new Uint8Array([
    0xff, 0xd8,
    0xff, 0xe0, 0x00, 0x04, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 0x03,
    1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
    0xff, 0xd9,
  ]);
}

export function b64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

export const testEnv: Env = { ...(env as Env), AI_PROVIDER: "astra", OPENAI_API_KEY: "test-key" };

export function call(path: string, init: RequestInit, overrides: Partial<Env> = {}): Promise<Response> {
  const router = mountAiRoutes(new Router());
  return router.handle(new Request(`http://example.com${path}`, init), { ...testEnv, ...overrides }, createExecutionContext());
}

/** Responses API (non-stream) body whose output_text is `result` JSON. */
export function responseBody(result: unknown, status = "completed") {
  return {
    status,
    model: "gpt-6-astra",
    usage: {
      input_tokens: 1027,
      input_tokens_details: { cache_write_tokens: 0, cached_tokens: 1024 },
      output_tokens: 227,
      output_tokens_details: { reasoning_tokens: 0 },
      total_tokens: 1254,
    },
    output: [
      { type: "reasoning", summary: [] },
      { type: "message", content: [{ type: "output_text", text: JSON.stringify(result) }] },
    ],
  };
}

export function mockFetch(impl: (url: string, init: RequestInit) => Response | Promise<Response>) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => impl(String(input), init ?? {}));
}
