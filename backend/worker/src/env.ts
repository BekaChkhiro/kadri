export type AiProvider = "astra" | "hybrid";

export interface Env {
  DB: D1Database;
  PHOTOS: R2Bucket;
  AI_PROVIDER: AiProvider;
  ENVIRONMENT: string;
  /** Build/release identifier; falls back to "dev" when unset. */
  VERSION?: string;
  OPENAI_API_KEY?: string;
  /** Responses API model for the Astra stages; defaults to gpt-6-astra. */
  AI_MODEL?: string;
  /** Reasoning effort; defaults to "low" (gpt-6-astra rejects "minimal"). */
  AI_EFFORT?: string;
  GEMINI_API_KEY?: string;
  SESSION_SECRET?: string;
  GOOGLE_CLIENT_IDS?: string;
  /** Started sessions per user per UTC day; default 20 (src/limits.ts). */
  DAILY_SESSION_LIMIT?: string;
  /** Total guarded AI request/stream timeout in ms; default 60000 (src/limits.ts). */
  AI_TIMEOUT_MS?: string;
  /** Parts deadline per attempt; default 20000. */
  AI_ATTEMPT_TIMEOUT_MS?: string;
  /** Steps deadline per attempt until its first step; default 25000. */
  AI_FIRST_STEP_TIMEOUT_MS?: string;
}
