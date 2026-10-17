import { afterEach, describe, expect, it, vi } from "vitest";
import { lookupKnowledge } from "../src/ai/knowledge";
import { knowledgeEnv, knowledgeResponse, mockFetch } from "./ai-helpers";

afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

describe("Knowledge Hub", () => {
  it("normalizes Georgian and English records and sends only bounded text", async () => {
    const spy = mockFetch((_url, init) => {
      expect(init.headers).toMatchObject({
        Authorization: "Bearer knowledge-test-key", Accept: "application/json, text/event-stream",
      });
      const body = JSON.parse(String(init.body));
      expect(body).toMatchObject({ jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "knowledge_search", arguments: { limit: 3, domain: "appliances" } } });
      expect(body.params.arguments.query).toContain("ჩართულია?: დიახ");
      expect(String(init.body)).not.toMatch(/image|base64|PHOTO_SECRET/);
      return knowledgeResponse();
    });
    const input = { object: "მაცივარი", instructions: [{ title: "არ აცივებს", text: "ignored body" }],
      answers: [{ question: "ჩართულია?", answer: "დიახ" }], image: "PHOTO_SECRET" };
    const hits = await lookupKnowledge(knowledgeEnv, input);
    expect(hits).toEqual([
      { id: "ka-1", title: "მაცივრის შემოწმება", summary: "შეამოწმეთ კვება.", note: "მხოლოდ გარედან." },
      { id: "en-1", title: "Cooling checks", summary: "Check ventilation.", note: "External checks only." },
    ]);
    expect(spy).toHaveBeenCalledOnce();
  });

  it.each([
    { KNOWLEDGE_HUB_ENABLED: "false" }, { KNOWLEDGE_HUB_ENABLED: undefined },
    { KNOWLEDGE_HUB_KEY: undefined }, { KNOWLEDGE_HUB_URL: undefined },
  ])("does not fetch when disabled or unconfigured: %j", async overrides => {
    const spy = mockFetch(() => knowledgeResponse());
    expect(await lookupKnowledge({ ...knowledgeEnv, ...overrides }, { object: "x", instructions: "y" })).toEqual([]);
    expect(spy).not.toHaveBeenCalled();
  });

  it.each([
    ["როზეტი", "electrical"], ["Wi-Fi", "networking"], ["ველოსიპედი", "bicycles"],
    ["ქვაბი", undefined], ["უცნობი", undefined],
  ])("chooses an optional domain for %s", async (name, domain) => {
    mockFetch((_url, init) => {
      const args = JSON.parse(String(init.body)).params.arguments;
      expect(args.domain).toBe(domain);
      if (domain === undefined) expect(args).not.toHaveProperty("domain");
      return knowledgeResponse();
    });
    await lookupKnowledge(knowledgeEnv, { object: name!, instructions: "შემოწმება" });
  });

  it("clamps query and fields and supports text content fallback", async () => {
    mockFetch((_url, init) => {
      expect([...JSON.parse(String(init.body)).params.arguments.query].length).toBeLessThanOrEqual(500);
      return Response.json({ result: { content: [{ type: "text", text: JSON.stringify({ results: [
        { record: { id: "1", title: "a".repeat(100), summary: "b".repeat(300), limitations: "c".repeat(200) } },
      ] }) }] } });
    });
    const [hit] = await lookupKnowledge(knowledgeEnv, { object: "x", instructions: "y".repeat(700) });
    expect(hit!.title.length).toBe(80);
    expect(hit!.summary.length).toBe(240);
    expect(hit!.note.length).toBe(160);
  });

  it.each([
    () => new Response("unauthorized", { status: 401 }),
    () => Response.json({ result: { isError: true } }),
    () => Response.json({ error: { code: -32602 } }),
    () => new Response("not json"),
    () => Response.json({ result: { structuredContent: { results: [{}] } } }),
  ])("fails open with one sanitized warning", async response => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    mockFetch(response);
    expect(await lookupKnowledge(knowledgeEnv, { object: "x", instructions: "y" })).toEqual([]);
    expect(warn).toHaveBeenCalledExactlyOnceWith("knowledge: lookup skipped");
  });

  it.each([false, true])("aborts a hanging fetch (outer cancellation=%s)", async outerAbort => {
    vi.useFakeTimers();
    const controller = new AbortController();
    let signal: AbortSignal | undefined | null;
    mockFetch((_url, init) => new Promise((_resolve, reject) => {
      signal = init.signal;
      signal?.addEventListener("abort", () => reject(new Error("secret upstream error")));
    }));
    const pending = lookupKnowledge(knowledgeEnv, { object: "x", instructions: "y" }, controller.signal);
    if (outerAbort) controller.abort();
    else await vi.advanceTimersByTimeAsync(2500);
    expect(await pending).toEqual([]);
    expect(signal?.aborted).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });
});
