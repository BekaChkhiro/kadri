/// <reference types="vite/client" />
import { beforeAll, describe, expect, it } from "vitest";
import usageSql from "../migrations/0002_usage.sql?raw";
import type { Env } from "../src/env";
import { ApiError } from "../src/errors";
import {
  assertDailyLimit,
  aiAttemptTimeoutMs,
  aiFirstStepTimeoutMs,
  aiTimeoutMs,
  LimitError,
  recordUsage,
  secondsUntilUtcMidnight,
  usageSummary,
  withTimeout,
  type UsageRow,
} from "../src/limits";
import { env } from "./auth-helpers";

const limitEnv: Env = { ...env, DAILY_SESSION_LIMIT: "3" };

function row(userId: string, overrides: Partial<UsageRow> = {}): UsageRow {
  return {
    userId,
    sessionId: "s1",
    stage: "parts",
    provider: "astra",
    model: "gpt-6-astra",
    inputTokens: 1000,
    outputTokens: 200,
    reasoningTokens: 50,
    costUsd: 0.01,
    latencyMs: 7000,
    status: "ok",
    ...overrides,
  };
}

beforeAll(async () => {
  const statements = usageSql
    .split(";")
    .map((s) => s.replace(/^\s*--.*$/gm, "").trim())
    .filter(Boolean);
  await env.DB.batch(statements.map((s) => env.DB.prepare(s)));
});

describe("assertDailyLimit", () => {
  it("passes below the limit and ignores steps rows and yesterday", async () => {
    const now = new Date("2026-10-17T12:00:00Z");
    await recordUsage(limitEnv, row("below", { createdAt: now }));
    await recordUsage(limitEnv, row("below", { createdAt: now, status: "error" }));
    await recordUsage(limitEnv, row("below", { createdAt: now, stage: "steps" }));
    await recordUsage(limitEnv, row("below", { createdAt: new Date("2026-10-16T23:59:59Z") }));
    await expect(assertDailyLimit(limitEnv, "below", now)).resolves.toBeUndefined();
  });

  it("throws 429 daily_limit with Retry-After at the limit", async () => {
    const now = new Date("2026-10-17T22:00:00Z");
    for (let i = 0; i < 3; i++) await recordUsage(limitEnv, row("at", { createdAt: now }));
    const err = await assertDailyLimit(limitEnv, "at", now).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(LimitError);
    expect(err).toBeInstanceOf(ApiError);
    const e = err as LimitError;
    expect(e.status).toBe(429);
    expect(e.code).toBe("daily_limit");
    expect(e.message).toBe("დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ");
    expect(e.headers["retry-after"]).toBe("7200");
  });

  it("defaults to 20 when DAILY_SESSION_LIMIT is unset", async () => {
    const now = new Date("2026-10-17T08:00:00Z");
    const plain: Env = { ...env, DAILY_SESSION_LIMIT: undefined };
    for (let i = 0; i < 19; i++) await recordUsage(plain, row("default", { createdAt: now }));
    await expect(assertDailyLimit(plain, "default", now)).resolves.toBeUndefined();
    await recordUsage(plain, row("default", { createdAt: now }));
    await expect(assertDailyLimit(plain, "default", now)).rejects.toMatchObject({ status: 429 });
  });

  it("computes seconds until UTC midnight", () => {
    expect(secondsUntilUtcMidnight(new Date("2026-10-17T23:59:59.500Z"))).toBe(1);
    expect(secondsUntilUtcMidnight(new Date("2026-10-17T00:00:00Z"))).toBe(86_400);
  });
});

describe("usageSummary", () => {
  it("sums cost and counts sessions within the window", async () => {
    const now = new Date("2026-10-17T12:00:00Z");
    await recordUsage(env, row("sum", { createdAt: now, costUsd: 0.012 }));
    await recordUsage(env, row("sum", { createdAt: now, stage: "steps", costUsd: 0.02, sessionId: null }));
    await recordUsage(env, row("sum", { createdAt: new Date("2026-10-10T00:00:00Z"), costUsd: 0.005 }));
    await recordUsage(env, row("sum", { createdAt: new Date("2026-08-01T00:00:00Z"), costUsd: 1 }));
    await recordUsage(env, row("other", { createdAt: now, costUsd: 5 }));

    const s = await usageSummary(env, "sum", 30, now);
    expect(s.days).toBe(30);
    expect(s.sessions).toBe(2);
    expect(s.costUsd).toBeCloseTo(0.037, 9);

    expect(await usageSummary(env, "nobody", 30, now)).toEqual({ days: 30, sessions: 0, costUsd: 0 });
  });
});

describe("withTimeout", () => {
  it("rejects slow work with 504 ai_timeout and aborts the signal", async () => {
    let seen: AbortSignal | undefined;
    const err = await withTimeout(20, (signal) => {
      seen = signal;
      return new Promise<string>((resolve) => setTimeout(() => resolve("late"), 500));
    }).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ApiError);
    expect((err as ApiError).status).toBe(504);
    expect((err as ApiError).code).toBe("ai_timeout");
    expect((err as ApiError).message).toBe("პასუხი დროში ვერ მოვიდა, სცადეთ თავიდან");
    expect(seen?.aborted).toBe(true);
  });

  it("returns the result of fast work without aborting", async () => {
    let seen: AbortSignal | undefined;
    const result = await withTimeout(1000, async (signal) => {
      seen = signal;
      return 42;
    });
    expect(result).toBe(42);
    expect(seen?.aborted).toBe(false);
  });

  it("passes through errors from the work itself", async () => {
    await expect(withTimeout(1000, async () => Promise.reject(new Error("boom")))).rejects.toThrow("boom");
  });
});

describe("AI deadline configuration", () => {
  it.each([undefined, "", "invalid", "0", "-1"])("uses defaults for %s", raw => {
    const config = { ...env, AI_ATTEMPT_TIMEOUT_MS: raw, AI_FIRST_STEP_TIMEOUT_MS: raw, AI_TIMEOUT_MS: raw };
    expect(aiAttemptTimeoutMs(config)).toBe(20_000);
    expect(aiFirstStepTimeoutMs(config)).toBe(25_000);
    expect(aiTimeoutMs(config)).toBe(60_000);
  });

  it("accepts independent overrides", () => {
    const config = { ...env, AI_ATTEMPT_TIMEOUT_MS: "12", AI_FIRST_STEP_TIMEOUT_MS: "34", AI_TIMEOUT_MS: "56" };
    expect(aiAttemptTimeoutMs(config)).toBe(12);
    expect(aiFirstStepTimeoutMs(config)).toBe(34);
    expect(aiTimeoutMs(config)).toBe(56);
  });
});
