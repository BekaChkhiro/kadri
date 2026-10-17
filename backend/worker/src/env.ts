export type AiProvider = "astra" | "hybrid";

export interface Env {
  DB: D1Database;
  PHOTOS: R2Bucket;
  AI_PROVIDER: AiProvider;
  ENVIRONMENT: string;
  /** Build/release identifier; falls back to "dev" when unset. */
  VERSION?: string;
  OPENAI_API_KEY?: string;
  GEMINI_API_KEY?: string;
  SESSION_SECRET?: string;
  GOOGLE_CLIENT_IDS?: string;
  /** Started sessions per user per UTC day; default 20 (src/limits.ts). */
  DAILY_SESSION_LIMIT?: string;
  /** Per AI request timeout in ms; default 60000 (src/limits.ts). */
  AI_TIMEOUT_MS?: string;
}
