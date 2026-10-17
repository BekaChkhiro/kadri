import type { Env } from "./env";
import { ApiError } from "./errors";

export const DEFAULT_ANSWER_TURN_LIMIT = 6;

export function answerTurnLimit(env: Pick<Env, "ANSWER_TURN_LIMIT">): number {
  return Math.max(1, positiveInt(env.ANSWER_TURN_LIMIT, DEFAULT_ANSWER_TURN_LIMIT));
}

export const DEFAULT_DAILY_SESSION_LIMIT = 20;
export const DEFAULT_AI_TIMEOUT_MS = 60_000;
export const DEFAULT_AI_ATTEMPT_TIMEOUT_MS = 20_000;
export const DEFAULT_AI_FIRST_STEP_TIMEOUT_MS = 25_000;

export type UsageStage = "parts" | "steps";
export type UsageStatus = "ok" | "error" | "timeout";

export interface UsageRow {
  userId: string;
  sessionId?: string | null;
  stage: UsageStage;
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  /** Computed by the caller (pricing lives with the AI providers). */
  costUsd: number;
  latencyMs: number;
  status: UsageStatus;
  /** Defaults to now. */
  createdAt?: Date;
}

export interface UsageSummary {
  days: number;
  sessions: number;
  costUsd: number;
}

/** ApiError that also carries response headers (e.g. Retry-After). */
export class LimitError extends ApiError {
  constructor(
    status: number,
    code: string,
    message: string,
    readonly headers: Record<string, string>,
  ) {
    super(status, code, message);
    this.name = "LimitError";
  }
}

function positiveInt(raw: string | undefined, fallback: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

export function dailySessionLimit(env: Env): number {
  return positiveInt(env.DAILY_SESSION_LIMIT, DEFAULT_DAILY_SESSION_LIMIT);
}

export function aiTimeoutMs(env: Env): number {
  return positiveInt(env.AI_TIMEOUT_MS, DEFAULT_AI_TIMEOUT_MS);
}

export function aiAttemptTimeoutMs(env: Env): number {
  return positiveInt(env.AI_ATTEMPT_TIMEOUT_MS, DEFAULT_AI_ATTEMPT_TIMEOUT_MS);
}

export function aiFirstStepTimeoutMs(env: Env): number {
  return positiveInt(env.AI_FIRST_STEP_TIMEOUT_MS, DEFAULT_AI_FIRST_STEP_TIMEOUT_MS);
}

function utcMidnight(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
}

/** Seconds until the next UTC midnight (at least 1). */
export function secondsUntilUtcMidnight(now = new Date()): number {
  const next = utcMidnight(now).getTime() + 86_400_000;
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000));
}

/**
 * Throws 429 `daily_limit` when the user has already started DAILY_SESSION_LIMIT sessions today (UTC).
 * A started session = one `usage` row with stage='parts', whatever its status (failed calls are still paid).
 */
export async function assertDailyLimit(env: Env, userId: string, now = new Date()): Promise<void> {
  const limit = dailySessionLimit(env);
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM usage WHERE user_id = ?1 AND stage = 'parts' AND created_at >= ?2",
  )
    .bind(userId, utcMidnight(now).toISOString())
    .first<{ n: number }>();
  if ((row?.n ?? 0) >= limit) {
    throw new LimitError(429, "daily_limit", "დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ", {
      "retry-after": String(secondsUntilUtcMidnight(now)),
    });
  }
}

export async function recordUsage(env: Env, row: UsageRow): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO usage (user_id, session_id, stage, provider, model, input_tokens, output_tokens,
       reasoning_tokens, cost_usd, latency_ms, status, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
  )
    .bind(
      row.userId,
      row.sessionId ?? null,
      row.stage,
      row.provider,
      row.model,
      row.inputTokens,
      row.outputTokens,
      row.reasoningTokens,
      row.costUsd,
      Math.round(row.latencyMs),
      row.status,
      (row.createdAt ?? new Date()).toISOString(),
    )
    .run();
}

/** Total cost and started sessions over the last `days` days (settings screen). */
export async function usageSummary(env: Env, userId: string, days = 30, now = new Date()): Promise<UsageSummary> {
  const since = new Date(now.getTime() - days * 86_400_000).toISOString();
  const row = await env.DB.prepare(
    `SELECT COALESCE(SUM(cost_usd), 0) AS cost, COALESCE(SUM(stage = 'parts'), 0) AS sessions
     FROM usage WHERE user_id = ?1 AND created_at >= ?2`,
  )
    .bind(userId, since)
    .first<{ cost: number; sessions: number }>();
  return { days, sessions: row?.sessions ?? 0, costUsd: row?.cost ?? 0 };
}

/**
 * Runs `run` with an AbortSignal that fires after `ms`; on timeout rejects with 504 `ai_timeout`.
 * This helper does not retry; guarded AI routes own the single eligible retry and per-attempt usage.
 */
export async function withTimeout<T>(ms: number, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const controller = new AbortController();
  let fail!: (err: ApiError) => void;
  const timeout = new Promise<never>((_, reject) => (fail = reject));
  const timer = setTimeout(() => {
    controller.abort();
    fail(new ApiError(504, "ai_timeout", "პასუხი დროში ვერ მოვიდა, სცადეთ თავიდან"));
  }, ms);
  try {
    return await Promise.race([run(controller.signal), timeout]);
  } finally {
    clearTimeout(timer);
  }
}
