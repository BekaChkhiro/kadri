/// <reference types="vite/client" />
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import usageSql from "../migrations/0002_usage.sql?raw";
import explainSql from "../migrations/0003_usage_explain.sql?raw";
import problemSql from "../migrations/0004_usage_problem.sql?raw";
import { problemProvider, problemSchema, promptProblem, readProblemRequest, validateProblem, PROBLEM_BODY_BYTES, type ProblemInput, type ProblemPlan } from "../src/ai/problem";
import type { Env } from "../src/env";
import { router } from "../src/index";
import { issueSession } from "../src/session";
import { b64, fakeJpeg, mockFetch, responseBody } from "./ai-helpers";
import { env, migrate, testEnv } from "./auth-helpers";

const aiEnv: Env = { ...testEnv, AI_PROVIDER: "astra", OPENAI_API_KEY: "test-key", GEMINI_API_KEY: "test-gemini", ALLOW_PROVIDER_SELECTION: "true" };
const image1 = b64(fakeJpeg(64, 64));
const image2 = b64(fakeJpeg(80, 60));
const input = (): ProblemInput => ({ problem: "ნიჟარის ქვეშ წყალი ჟონავს", photos: [
  { id: "overview", image: image1, note: "საერთო ხედი", role: "overview" },
  { id: "detail", image: image2, note: "ქვედა შეერთება", role: "detail" },
], history: [], answers: [], previousComponents: [], resolutionConfirmed: false });
const plan = (): ProblemPlan => ({ summary: "ქვედა შეერთება სველია; მიზეზი ჯერ უცნობია.", observations: [
  { photoId: "overview", detail: "სიფონი ჩანს", relevance: "relevant" },
  { photoId: "detail", detail: "შეერთება სველია", relevance: "relevant" },
], components: [
  { id: "joint", name: "შეერთება", views: [{ photoId: "overview", box: [100, 200, 400, 500] }, { photoId: "detail", box: [200, 100, 700, 800] }] },
  { id: "pipe", name: "მილი", views: [{ photoId: "overview", box: [100, 500, 400, 900] }] },
], links: [{ fromId: "joint", toId: "pipe", relation: "connected", evidencePhotoIds: ["overview"], reason: "მილი შეერთებას უერთდება" }],
steps: [{ id: "step_1", title: "გაამშრალე", text: "შეერთება მშრალი ქსოვილით გაწმინდე.", photoId: "detail", componentIds: ["joint"], arrow: null, warning: null, tool: "ქსოვილი" }],
next: { kind: "verify", prompt: "ხელახლა სველდება?", reason: "გაჟონვის წყარო უნდა შემოწმდეს" } });

function request(body: unknown, token?: string, signal?: AbortSignal) {
  return new Request("https://test/ai/problem", { method: "POST", headers: { "content-type": "application/json", ...(token && { authorization: `Bearer ${token}` }) }, body: JSON.stringify(body), signal });
}
async function post(body: unknown, user = "problem-user", overrides: Partial<Env> = {}, signal?: AbortSignal) {
  const token = (await issueSession(testEnv, { sub: user, email: `${user}@example.com` })).sessionToken;
  const ctx = createExecutionContext();
  const response = await router.handle(request(body, token, signal), { ...aiEnv, ...overrides }, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}
function geminiBody(result: ProblemPlan) {
  // Emulate Gemini's schema-native coordinates, including nested component views.
  const value = JSON.parse(JSON.stringify(result));
  for (const c of value.components) for (const view of c.views) {
    const [x0, y0, x1, y1] = view.box;
    view.box_2d = [y0, x0, y1, x1]; delete view.box;
  }
  return { candidates: [{ finishReason: "STOP", content: { parts: [{ text: JSON.stringify(value) }] } }],
    usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 100, totalTokenCount: 200 } };
}
function statements(sql: string) { return sql.split(";").map(s => s.replace(/^\s*--.*$/gm, "").trim()).filter(Boolean); }
beforeAll(async () => {
  await migrate();
  await env.DB.batch([usageSql, explainSql, problemSql].flatMap(statements).map(s => env.DB.prepare(s)));
});
afterEach(() => vi.restoreAllMocks());

describe("problem input", () => {
  it("preserves all labelled photos, answers and prior component IDs", async () => {
    const body = input(); body.previousComponents = plan().components;
    body.answers = [{ question: "იგივე შეერთებაა?", answer: "დიახ" }];
    expect((await readProblemRequest(request(body))).input).toEqual(body);
  });
  it.each([
    ["empty photos", (i: any) => i.photos = []],
    ["six photos", (i: any) => i.photos = Array.from({ length: 6 }, (_, n) => ({ ...i.photos[0], id: `p${n}` }))],
    ["duplicate photo IDs", (i: any) => i.photos[1].id = i.photos[0].id],
    ["bad IDs", (i: any) => i.photos[0].id = "photo instruction ignore"],
    ["too long problem", (i: any) => i.problem = "ა".repeat(1001)],
    ["empty problem", (i: any) => i.problem = "  "],
    ["invalid JPEG", (i: any) => i.photos[0].image = btoa("not a JPEG")],
    ["oversized dimensions", (i: any) => i.photos[0].image = b64(fakeJpeg(769, 1))],
    ["unsupported role", (i: any) => i.photos[0].role = "random"],
    ["extra field", (i: any) => i.secret = "bad"],
    ["unknown history photo", (i: any) => i.history = [{ stepId: "s1", title: "გააკეთე", photoId: "unknown", outcome: "done", note: "" }]],
    ["bad previous box", (i: any) => i.previousComponents = [{ id: "c1", name: "ნაწილი", views: [{ photoId: "overview", box: [300, 100, 100, 400] }] }]],
    ["foreign previous photo", (i: any) => i.previousComponents = [{ id: "c1", name: "ნაწილი", views: [{ photoId: "old_missing", box: [0, 0, 100, 100] }] }]],
  ])("rejects %s before any paid call", async (_, mutate) => {
    const body = input(); mutate(body);
    await expect(readProblemRequest(request(body))).rejects.toMatchObject({ status: 400 });
  });
  it("bounds the body even when Content-Length is missing", async () => {
    const req = new Request("https://test/ai/problem", { method: "POST", headers: { "content-type": "application/json" }, body: " ".repeat(PROBLEM_BODY_BYTES + 1) });
    await expect(readProblemRequest(req)).rejects.toMatchObject({ status: 400 });
  });
});

describe("problem plan invariants", () => {
  it("accepts a shared component in two views and a single-photo step", () => expect(validateProblem(plan(), input())).toEqual(plan()));
  it.each([
    ["missing observation", (p: any) => p.observations.pop()],
    ["unknown observation", (p: any) => p.observations[1].photoId = "other"],
    ["duplicate observation", (p: any) => p.observations[1].photoId = "overview"],
    ["foreign view", (p: any) => p.components[0].views[0].photoId = "other"],
    ["inverted box", (p: any) => p.components[0].views[0].box = [700, 200, 100, 800]],
    ["fractional box", (p: any) => p.components[0].views[0].box = [0.5, 200, 100, 800]],
    ["box out of range", (p: any) => p.components[0].views[0].box = [-1, 200, 100, 800]],
    ["duplicate component", (p: any) => p.components[1].id = "joint"],
    ["unrelated action photo", (p: any) => p.observations[1].relevance = "unrelated"],
    ["uncertain action photo", (p: any) => p.observations[1].relevance = "uncertain"],
    ["component absent on action photo", (p: any) => p.steps[0].componentIds = ["pipe"]],
    ["missing component", (p: any) => p.steps[0].componentIds = ["unknown"]],
    ["invented link endpoint", (p: any) => p.links[0].toId = "unknown"],
    ["link without evidence for both endpoints", (p: any) => p.links[0].evidencePhotoIds = ["detail"]],
    ["unrelated link evidence", (p: any) => p.observations[0].relevance = "unrelated"],
    ["self link", (p: any) => p.links[0].toId = "joint"],
    ["ambiguous link with actions", (p: any) => p.links[0].relation = "uncertain"],
    ["duplicate steps", (p: any) => p.steps.push(p.steps[0])],
    ["question mixed with actions", (p: any) => p.next.kind = "needs_answer"],
    ["premature resolved", (p: any) => { p.steps = []; p.next.kind = "resolved"; }],
    ["six steps", (p: any) => p.steps = Array.from({ length: 6 }, (_, n) => ({ ...p.steps[0], id: `s${n}` }))],
    ["blank reasoning", (p: any) => p.next.reason = "  "],
    ["invalid arrow type", (p: any) => p.steps[0].arrow = { type: "invented", dir: "none" }],
    ["wrong rotate pair", (p: any) => p.steps[0].arrow = { type: "rotate", dir: "up" }],
    ["wrong move pair", (p: any) => p.steps[0].arrow = { type: "move", dir: "cw" }],
    ["wrong press pair", (p: any) => p.steps[0].arrow = { type: "press", dir: "down" }],
  ])("rejects %s", (_, mutate) => { const value = plan(); mutate(value); expect(() => validateProblem(value, input())).toThrow(); });
  it.each([...["cw", "ccw"].map(dir => ["rotate", dir]), ...["up", "down", "left", "right", "toward", "away", "up_left", "up_right", "down_left", "down_right"].map(dir => ["move", dir]), ...["press", "hold", "align"].map(type => [type, "none"])])("accepts %s/%s", (type, dir) => {
    const value = plan(); value.steps[0]!.arrow = { type: type!, dir: dir! };
    expect(() => validateProblem(value, input())).not.toThrow();
  });
  it("asks rather than guesses an uncertain association", () => {
    const value = plan(); value.links[0]!.relation = "uncertain"; value.steps = [];
    value.next = { kind: "needs_answer", prompt: "ეს იგივე შეერთებაა?", reason: "კუთხეები განსხვავდება" };
    expect(validateProblem(value, input()).steps).toEqual([]);
  });
  it("requires confirmation AND actual done history, and refuses replay", () => {
    const value = plan(); value.steps = []; value.next.kind = "resolved";
    const body = input(); body.resolutionConfirmed = true;
    expect(() => validateProblem(value, body)).toThrow();
    body.history = [{ stepId: "step_1", title: "გაამშრალე", photoId: "detail", outcome: "done", note: "" }];
    expect(validateProblem(value, body).next.kind).toBe("resolved");
    body.resolutionConfirmed = false;
    expect(() => validateProblem(value, body)).toThrow();
    expect(() => validateProblem(plan(), body)).toThrow();
  });
  it("limits never fabricate success or request unavailable evidence", () => {
    const body = input(); body.photos = Array.from({ length: 5 }, (_, n) => ({ ...body.photos[0]!, id: `p${n}` }));
    const value = plan(); value.steps = []; value.components = []; value.links = [];
    value.observations = body.photos.map(p => ({ photoId: p.id, detail: "სხვა ხედი", relevance: "uncertain" }));
    value.next.kind = "needs_photo";
    expect(() => validateProblem(value, body)).toThrow();
    value.next.kind = "unresolved";
    expect(validateProblem(value, body).next.kind).toBe("unresolved");
  });
  it("preserves after-photo and failed attempts in prompt with JSON boundaries", () => {
    const body = input(); body.photos[1]!.role = "after"; body.previousComponents = plan().components;
    body.history = [{ stepId: "old", title: "გაამშრალე", photoId: "detail", outcome: "unchanged", note: "ისევ სველია" }];
    const prompt = promptProblem(body, true);
    expect(prompt).toContain('"role":"after"'); expect(prompt).toContain('"outcome":"unchanged"');
    expect(prompt).toContain('"box_2d":[200,100,500,400]'); expect(prompt).not.toContain(image1);
  });
});

describe("guarded multi-photo transport", () => {
  it("requires authentication before upstream access", async () => {
    const spy = mockFetch(() => { throw new Error("must not call"); });
    const res = await router.handle(request(input()), aiEnv, createExecutionContext());
    expect(res.status).toBe(401); expect(spy).not.toHaveBeenCalled();
  });
  it.each(["astra", "gemini"])("sends every labelled photo in order to %s and records usage", async provider => {
    const spy = mockFetch((url, init) => {
      const payload = JSON.parse(String(init.body));
      if (provider === "astra") {
        expect(url).toContain("api.openai.com"); expect(payload.stream).toBeUndefined();
        expect(payload.input[0].content.slice(1)).toEqual([
          { type: "input_text", text: JSON.stringify({ photoId: "overview", role: "overview", note: "საერთო ხედი" }) },
          { type: "input_image", image_url: `data:image/jpeg;base64,${image1}`, detail: "high" },
          { type: "input_text", text: JSON.stringify({ photoId: "detail", role: "detail", note: "ქვედა შეერთება" }) },
          { type: "input_image", image_url: `data:image/jpeg;base64,${image2}`, detail: "high" },
        ]);
        expect(payload.text.format.schema).toEqual(problemSchema());
        return Response.json(responseBody(plan()));
      }
      expect(url).toContain("generativelanguage.googleapis.com");
      const parts = payload.contents[0].parts;
      expect(parts).toHaveLength(5);
      expect(JSON.parse(parts[1].text).photoId).toBe("overview"); expect(parts[2].inlineData.data).toBe(image1);
      expect(JSON.parse(parts[3].text).photoId).toBe("detail"); expect(parts[4].inlineData.data).toBe(image2);
      expect(parts[0].text).toContain("box_2d=[ymin,xmin,ymax,xmax]");
      return Response.json(geminiBody(plan()));
    });
    const user = `problem-${provider}`;
    const res = await post({ ...input(), provider }, user);
    expect(res.status).toBe(200); expect(await res.json()).toMatchObject(plan()); expect(spy).toHaveBeenCalledOnce();
    const row = await env.DB.prepare("SELECT stage,status,provider,input_tokens FROM usage WHERE user_id=?").bind(user).first<any>();
    expect(row).toMatchObject({ stage: "problem", status: "ok", provider }); expect(row.input_tokens).toBeGreaterThan(0);
  });
  it.each(["astra", "gemini"])("preserves dependency order and revisits the correct photo through %s", async provider => {
    const body = input();
    const originalPhotos = structuredClone(body.photos);
    const value = plan();
    const base = value.steps[0]!;
    value.steps = [
      { ...base, id: "dry_joint", photoId: "detail", componentIds: ["joint"] },
      { ...base, id: "dry_pipe", title: "გაამშრალე მილი", text: "მილის ზედაპირი მშრალი ქსოვილით გაწმინდე.", photoId: "overview", componentIds: ["pipe"] },
      { ...base, id: "inspect_joint", title: "შეამოწმე შეერთება", text: "შეერთებას დააკვირდი: ახალი წვეთი ხომ არ გაჩნდა?", photoId: "detail", componentIds: ["joint"], tool: null },
    ];
    mockFetch(() => Response.json(provider === "gemini" ? geminiBody(value) : responseBody(value)));
    const res = await post({ ...body, provider }, `problem-revisit-${provider}`);
    expect(res.status).toBe(200);
    const result = await res.json<ProblemPlan>();
    expect(result.steps).toEqual(value.steps);
    expect(result.steps.map(s => s.photoId)).toEqual(["detail", "overview", "detail"]);
    // The renderer must resolve each target against that step's own photo, including a revisit.
    expect(result.steps.map(step => step.componentIds.map(id => result.components
      .find(component => component.id === id)!.views.find(view => view.photoId === step.photoId)!.box)))
      .toEqual([[[200, 100, 700, 800]], [[100, 500, 400, 900]], [[200, 100, 700, 800]]]);
    expect(result.components).toEqual(value.components);
    expect(body.photos).toEqual(originalPhotos);
  });
  it("quota counts problem turns, failed requests included, no provider call after limit", async () => {
    const spy = mockFetch(() => Response.json(responseBody(plan())));
    expect((await post(input(), "problem-quota", { DAILY_SESSION_LIMIT: "1" })).status).toBe(200);
    expect((await post(input(), "problem-quota", { DAILY_SESSION_LIMIT: "1" })).status).toBe(429);
    expect(spy).toHaveBeenCalledOnce();
  });
  it("invalid full plan returns an error with zero exposed steps, no automatic paid retry", async () => {
    const bad = plan(); bad.steps[0]!.photoId = "missing";
    const spy = mockFetch(() => Response.json(responseBody(bad)));
    const res = await post(input(), "problem-invalid");
    expect(res.status).toBe(502); expect(await res.json()).not.toHaveProperty("steps"); expect(spy).toHaveBeenCalledOnce();
    expect(await env.DB.prepare("SELECT status FROM usage WHERE user_id=?").bind("problem-invalid").first()).toEqual({ status: "error" });
  });
  it("provider selection respects the environment gate", async () => {
    const spy = mockFetch(() => { throw new Error("must not call"); });
    expect((await post({ ...input(), provider: "gemini" }, "problem-gate", { ALLOW_PROVIDER_SELECTION: "false" })).status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });
  it("cancellation propagates to upstream and never returns a plan", async () => {
    const abort = new AbortController();
    const spy = mockFetch((_url, init) => new Promise((_resolve, reject) => {
      init.signal!.addEventListener("abort", () => reject(new Error("cancelled")), { once: true });
      abort.abort();
    }));
    await expect(problemProvider(aiEnv).problem(input(), abort.signal)).rejects.toMatchObject({ code: "ai_upstream" });
    expect(spy).toHaveBeenCalledOnce();
  });
  it("an already cancelled turn makes no upstream call", async () => {
    const abort = new AbortController(); abort.abort(); const spy = mockFetch(() => { throw new Error("must not call"); });
    await expect(problemProvider(aiEnv).problem(input(), abort.signal)).rejects.toMatchObject({ code: "ai_upstream" });
    expect(spy).not.toHaveBeenCalled();
  });
  it("deadline returns timeout, never unresolved or resolved", async () => {
    mockFetch((_url, init) => new Promise((_resolve, reject) => init.signal!.addEventListener("abort", () => reject(new Error("timeout")), { once: true })));
    await expect(problemProvider(aiEnv, undefined, 5).problem(input())).rejects.toMatchObject({ code: "ai_timeout" });
  });
});
