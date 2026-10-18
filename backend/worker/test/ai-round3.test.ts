/// <reference types="vite/client" />
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, expect, it, vi } from "vitest";
import usageSql from "../migrations/0002_usage.sql?raw";
import { router } from "../src/index";
import { issueSession } from "../src/session";
import { fakeJpeg, mockFetch, responseBody } from "./ai-helpers";
import { env, migrate, testEnv } from "./auth-helpers";

beforeAll(async () => {
  await migrate();
  const statements = usageSql.split(";").map(s => s.replace(/^\s*--.*$/gm, "").trim()).filter(Boolean);
  await env.DB.batch(statements.map(s => env.DB.prepare(s)));
});
afterEach(() => vi.restoreAllMocks());

it.each([6, 40, 41])("round 3 multipart with %i completed steps responds without hanging", async count => {
  const sub = `third-photo-${count}`;
  const { sessionToken } = await issueSession(testEnv, { sub, email: `${sub}@example.com` });
  const ai = mockFetch(() => Response.json(responseBody({ object: "CPU", parts: [{ label: "socket", box: [0, 0, 500, 500] }] })));
  const form = new FormData();
  form.append("image", new Blob([fakeJpeg(768, 768)], { type: "image/jpeg" }), "keyframe.jpg");
  form.append("instructions", "შეამოწმე პროცესორი");
  form.append("context", JSON.stringify({ round: 3, photoPrompt: "გადაუღე ჩაკეტილ სოკეტს", doneSteps: Array.from({ length: count }, (_, i) => `ნაბიჯი ${i}`), previousObject: "სოკეტი" }));
  const ctx = createExecutionContext();
  const response = await router.handle(new Request("https://example.com/ai/parts", {
    method: "POST", headers: { authorization: `Bearer ${sessionToken}` }, body: form,
  }), { ...testEnv, AI_PROVIDER: "astra", OPENAI_API_KEY: "test-key" }, ctx);
  await waitOnExecutionContext(ctx);
  expect(response.status).toBe(count > 40 ? 400 : 200);
  expect(ai).toHaveBeenCalledTimes(count > 40 ? 0 : 1);
  const usage = await env.DB.prepare("SELECT COUNT(*) AS n FROM usage WHERE user_id = ?").bind(sub).first<{ n: number }>();
  expect(usage?.n).toBe(count > 40 ? 0 : 1);
}, 2000);

it("a parts call the client cancels still records an error row via waitUntil", async () => {
  const sub = "third-photo-cancelled";
  const { sessionToken } = await issueSession(testEnv, { sub, email: `${sub}@example.com` });
  const client = new AbortController();
  const ai = mockFetch((_url, init) => new Promise<Response>((_resolve, reject) => {
    init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    // The app gives up mid-request, as its old 45 s scan timer did.
    client.abort();
  }));
  const form = new FormData();
  form.append("image", new Blob([fakeJpeg(768, 768)], { type: "image/jpeg" }), "keyframe.jpg");
  form.append("instructions", "შეამოწმე პროცესორი");
  form.append("context", JSON.stringify({ round: 3, photoPrompt: "გადაუღე ჩაკეტილ სოკეტს", doneSteps: ["ნაბიჯი 1"], previousObject: "სოკეტი" }));
  const ctx = createExecutionContext();
  const waitUntil = vi.spyOn(ctx, "waitUntil");
  await router.handle(new Request("https://example.com/ai/parts", {
    method: "POST", headers: { authorization: `Bearer ${sessionToken}` }, body: form, signal: client.signal,
  }), { ...testEnv, AI_PROVIDER: "astra", OPENAI_API_KEY: "test-key" }, ctx).catch(() => undefined);
  await waitOnExecutionContext(ctx);
  expect(ai).toHaveBeenCalledTimes(1);
  expect(waitUntil).toHaveBeenCalledTimes(1);
  const rows = await env.DB.prepare("SELECT stage, status, cost_usd FROM usage WHERE user_id = ?").bind(sub).all();
  expect(rows.results).toEqual([{ stage: "parts", status: "error", cost_usd: 0 }]);
}, 2000);
