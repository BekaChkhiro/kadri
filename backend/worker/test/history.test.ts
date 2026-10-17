/// <reference types="vite/client" />
import { beforeAll, describe, expect, it } from "vitest";
import historySql from "../migrations/0001_init.sql?raw";
import { keyframeKey, MAX_KEYFRAME_BYTES } from "../src/history";
import { issueSession } from "../src/session";
import { call, env, migrate, testEnv } from "./auth-helpers";

interface ErrorBody {
  error: { code: string; message: string };
}

const OWNER = "history-owner";
const OTHER = "history-other";
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);

let ownerToken: string;
let otherToken: string;

async function migrateHistory(): Promise<void> {
  await migrate();
  const statements = historySql
    .split(";")
    .map((s) => s.replace(/^\s*--.*$/gm, "").trim())
    .filter(Boolean);
  await env.DB.batch(statements.map((s) => env.DB.prepare(s)));
}

async function addUser(sub: string): Promise<string> {
  const now = new Date().toISOString();
  await env.DB.prepare(
    "INSERT OR IGNORE INTO users (id, email, name, picture, created_at, last_login_at) VALUES (?, ?, NULL, NULL, ?, ?)",
  )
    .bind(sub, `${sub}@example.com`, now, now)
    .run();
  return (await issueSession(testEnv, { sub, email: `${sub}@example.com` })).sessionToken;
}

beforeAll(async () => {
  await migrateHistory();
  ownerToken = await addUser(OWNER);
  otherToken = await addUser(OTHER);
});

function req(token: string | null, method: string, body?: unknown, headers: Record<string, string> = {}): RequestInit {
  const h: Record<string, string> = { ...headers };
  if (token) h.authorization = `Bearer ${token}`;
  let payload: BodyInit | undefined;
  if (body instanceof Uint8Array) {
    payload = body;
  } else if (body !== undefined) {
    payload = JSON.stringify(body);
    h["content-type"] ??= "application/json";
  }
  return { method, headers: h, body: payload };
}

async function create(token = ownerToken, body: unknown = { instructions: "სიფონის გაწმენდა" }): Promise<string> {
  const res = await call("/sessions", req(token, "POST", body));
  expect(res.status).toBe(201);
  return (await res.json<{ id: string }>()).id;
}

async function expectError(res: Response, status: number, code?: string): Promise<ErrorBody> {
  expect(res.status).toBe(status);
  const body = await res.json<ErrorBody>();
  if (code) expect(body.error.code).toBe(code);
  expect(body.error.message.length).toBeGreaterThan(0);
  return body;
}

const PARTS = [
  { id: "p1", name: "სიფონის თხილი", box: [100, 200, 300, 400] },
  { id: "p2", name: "მილი", box: [400, 100, 900, 600] },
];
const STEPS = [
  { idx: 0, title: "ვედრო ჩადგი", text: "სიფონის ქვეშ ვედრო მოათავსე.", focus: ["p1"], avoid: [] },
  { idx: 1, title: "თხილი მოხსენი", text: "საათის ისრის საწინააღმდეგოდ მოატრიალე.", focus: ["p1"], avoid: ["p2"] },
];

describe("session history full cycle", () => {
  it("create → keyframe → patch → steps → feedback → get → list → delete", async () => {
    const created = await call("/sessions", req(ownerToken, "POST", { objectName: "ნიჟარა", instructions: "  სიფონი გაჭედილია  " }));
    expect(created.status).toBe(201);
    const { id, createdAt } = await created.json<{ id: string; createdAt: string }>();
    expect(id).toMatch(/^[0-9a-f-]{36}$/);
    expect(Date.parse(createdAt)).not.toBeNaN();

    const kf = await call(`/sessions/${id}/keyframe`, req(ownerToken, "PUT", JPEG, { "content-type": "image/jpeg" }));
    expect(kf.status).toBe(200);
    const key = keyframeKey(OWNER, id);
    expect(key).toBe(`users/${OWNER}/sessions/${id}/keyframe.jpg`);
    expect((await env.PHOTOS.head(key))?.size).toBe(JPEG.byteLength);

    const patched = await call(
      `/sessions/${id}`,
      req(ownerToken, "PATCH", { status: "steps", parts: PARTS, costUsd: 0.0123 }),
    );
    expect(patched.status).toBe(200);

    const steps = await call(`/sessions/${id}/steps`, req(ownerToken, "PUT", STEPS));
    expect(steps.status).toBe(200);
    expect(await steps.json()).toMatchObject({ stepCount: 2 });
    // Replace-all: a second PUT with one step leaves only that one.
    await call(`/sessions/${id}/steps`, req(ownerToken, "PUT", [STEPS[1]]));
    const one = await (await call(`/sessions/${id}`, req(ownerToken, "GET"))).json<{ steps: unknown[] }>();
    expect(one.steps).toEqual([STEPS[1]]);
    expect((await call(`/sessions/${id}/steps`, req(ownerToken, "PUT", STEPS))).status).toBe(200);

    const fb = await call(`/sessions/${id}/feedback`, req(ownerToken, "POST", { rating: 5, comment: "კარგი იყო" }));
    expect(fb.status).toBe(201);

    const got = await call(`/sessions/${id}`, req(ownerToken, "GET"));
    expect(got.status).toBe(200);
    expect(await got.json()).toMatchObject({
      id,
      objectName: "ნიჟარა",
      instructions: "სიფონი გაჭედილია",
      status: "steps",
      parts: PARTS,
      costUsd: 0.0123,
      keyframeUrl: `http://example.com/sessions/${id}/keyframe`,
      createdAt,
      steps: STEPS,
      feedback: [{ rating: 5, comment: "კარგი იყო" }],
    });

    const img = await call(`/sessions/${id}/keyframe`, req(ownerToken, "GET"));
    expect(img.status).toBe(200);
    expect(img.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await img.arrayBuffer())).toEqual(JPEG);

    const list = await call("/sessions", req(ownerToken, "GET"));
    expect(list.status).toBe(200);
    const { sessions } = await list.json<{ sessions: { id: string }[] }>();
    expect(sessions.find((s) => s.id === id)).toEqual({
      id,
      objectName: "ნიჟარა",
      status: "steps",
      createdAt,
      stepCount: 2,
      keyframeUrl: `http://example.com/sessions/${id}/keyframe`,
    });

    const del = await call(`/sessions/${id}`, req(ownerToken, "DELETE"));
    expect(del.status).toBe(204);
    expect(await env.PHOTOS.head(key)).toBeNull();
    await expectError(await call(`/sessions/${id}`, req(ownerToken, "GET")), 404, "not_found");
    const orphans = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM steps WHERE session_id = ?1) + (SELECT COUNT(*) FROM feedback WHERE session_id = ?1) AS n",
    )
      .bind(id)
      .first<{ n: number }>();
    expect(orphans?.n).toBe(0);
  });
});

describe("GET /sessions pagination", () => {
  it("pages newest first with a cursor and isolates users", async () => {
    const ids: string[] = [];
    for (let i = 0; i < 3; i++) ids.push(await create(otherToken));
    const first = await (await call("/sessions?limit=2", req(otherToken, "GET"))).json<{
      sessions: { id: string; keyframeUrl: string | null; stepCount: number }[];
      nextCursor: string | null;
    }>();
    expect(first.sessions).toHaveLength(2);
    expect(first.sessions[0]!.keyframeUrl).toBeNull();
    expect(first.sessions[0]!.stepCount).toBe(0);
    expect(first.nextCursor).toBeTruthy();
    const second = await (
      await call(`/sessions?limit=2&cursor=${first.nextCursor}`, req(otherToken, "GET"))
    ).json<{ sessions: { id: string }[]; nextCursor: string | null }>();
    const seen = [...first.sessions, ...second.sessions].map((s) => s.id);
    expect(new Set(seen).size).toBe(seen.length);
    expect(seen).toEqual(expect.arrayContaining(ids));
    expect(second.nextCursor).toBeNull();

    const own = await (await call("/sessions", req(ownerToken, "GET"))).json<{ sessions: { id: string }[] }>();
    expect(own.sessions.some((s) => ids.includes(s.id))).toBe(false);
  });

  it("rejects bad limit and cursor", async () => {
    await expectError(await call("/sessions?limit=0", req(ownerToken, "GET")), 400);
    await expectError(await call("/sessions?limit=51", req(ownerToken, "GET")), 400);
    await expectError(await call("/sessions?cursor=%%%", req(ownerToken, "GET")), 400);
  });
});

describe("authorization", () => {
  it("returns 401 without a session on every route", async () => {
    const id = await create();
    const routes: [string, string][] = [
      ["POST", "/sessions"],
      ["GET", "/sessions"],
      ["GET", `/sessions/${id}`],
      ["PATCH", `/sessions/${id}`],
      ["DELETE", `/sessions/${id}`],
      ["PUT", `/sessions/${id}/keyframe`],
      ["GET", `/sessions/${id}/keyframe`],
      ["PUT", `/sessions/${id}/steps`],
      ["POST", `/sessions/${id}/feedback`],
    ];
    for (const [method, path] of routes) {
      const body = await expectError(await call(path, req(null, method)), 401, "unauthorized");
      expect(body.error.message).toBe("ავტორიზაცია საჭიროა");
    }
  });

  it("returns 403 with a Georgian message for another user's session", async () => {
    const id = await create(ownerToken);
    await env.PHOTOS.put(keyframeKey(OWNER, id), JPEG);
    await env.DB.prepare("UPDATE sessions SET keyframe_key = ? WHERE id = ?").bind(keyframeKey(OWNER, id), id).run();
    const attempts: RequestInit[] = [
      req(otherToken, "GET"),
      req(otherToken, "PATCH", { status: "done" }),
      req(otherToken, "DELETE"),
    ];
    for (const init of attempts) {
      const body = await expectError(await call(`/sessions/${id}`, init), 403, "forbidden");
      expect(body.error.message).toBe("ამ სესიაზე წვდომა არ გაქვთ");
    }
    await expectError(await call(`/sessions/${id}/keyframe`, req(otherToken, "GET")), 403, "forbidden");
    await expectError(
      await call(`/sessions/${id}/keyframe`, req(otherToken, "PUT", JPEG, { "content-type": "image/jpeg" })),
      403,
      "forbidden",
    );
    await expectError(await call(`/sessions/${id}/steps`, req(otherToken, "PUT", STEPS)), 403, "forbidden");
    await expectError(await call(`/sessions/${id}/feedback`, req(otherToken, "POST", { rating: 1 })), 403, "forbidden");
    // Nothing changed for the owner.
    const got = await (await call(`/sessions/${id}`, req(ownerToken, "GET"))).json<{ status: string; steps: unknown[] }>();
    expect(got).toMatchObject({ status: "created", steps: [] });
    expect(await env.PHOTOS.head(keyframeKey(OWNER, id))).not.toBeNull();
  });

  it("returns 404 for unknown or malformed ids", async () => {
    await expectError(await call(`/sessions/${crypto.randomUUID()}`, req(ownerToken, "GET")), 404, "not_found");
    await expectError(await call("/sessions/not-a-uuid", req(ownerToken, "DELETE")), 404, "not_found");
  });

  it("returns 401 for a valid token whose user row is missing", async () => {
    const ghost = (await issueSession(testEnv, { sub: "ghost", email: "ghost@example.com" })).sessionToken;
    await expectError(await call("/sessions", req(ghost, "POST", { instructions: "x" })), 401, "unauthorized");
  });
});

describe("keyframe upload validation", () => {
  it("returns 415 for non-JPEG content types or bytes", async () => {
    const id = await create();
    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    await expectError(
      await call(`/sessions/${id}/keyframe`, req(ownerToken, "PUT", png, { "content-type": "image/png" })),
      415,
      "unsupported_media_type",
    );
    await expectError(await call(`/sessions/${id}/keyframe`, req(ownerToken, "PUT", JPEG)), 415);
    await expectError(
      await call(`/sessions/${id}/keyframe`, req(ownerToken, "PUT", png, { "content-type": "image/jpeg" })),
      415,
    );
    expect(await env.PHOTOS.head(keyframeKey(OWNER, id))).toBeNull();
  });

  it("returns 413 above 2 MB", async () => {
    const id = await create();
    const big = new Uint8Array(MAX_KEYFRAME_BYTES + 1);
    big.set(JPEG.subarray(0, 3));
    await expectError(
      await call(`/sessions/${id}/keyframe`, req(ownerToken, "PUT", big, { "content-type": "image/jpeg" })),
      413,
      "payload_too_large",
    );
  });

  it("returns 404 for GET keyframe before upload", async () => {
    const id = await create();
    await expectError(await call(`/sessions/${id}/keyframe`, req(ownerToken, "GET")), 404);
  });
});

describe("body validation", () => {
  it("rejects invalid parts with 400", async () => {
    const id = await create();
    const bad: unknown[] = [
      "nope",
      [{ id: "p1", name: "x", box: [0, 0, 10] }],
      [{ id: "p1", name: "x", box: [0, 0, 10, 1001] }],
      [{ id: "p1", name: "x", box: [500, 0, 100, 10] }],
      [{ id: "p1", name: "x", box: [0, 0, "10", 10] }],
      [{ id: "", name: "x", box: [0, 0, 10, 10] }],
      [{ name: "x", box: [0, 0, 10, 10] }],
      [
        { id: "p1", name: "x", box: [0, 0, 10, 10] },
        { id: "p1", name: "y", box: [0, 0, 10, 10] },
      ],
    ];
    for (const parts of bad) {
      await expectError(await call(`/sessions/${id}`, req(ownerToken, "PATCH", { parts })), 400, "invalid_request");
    }
    const got = await (await call(`/sessions/${id}`, req(ownerToken, "GET"))).json<{ parts: unknown[] }>();
    expect(got.parts).toEqual([]);
  });

  it("rejects other invalid PATCH, steps, feedback and create bodies", async () => {
    const id = await create();
    const cases: [string, string, unknown][] = [
      ["PATCH", `/sessions/${id}`, { status: "finished" }],
      ["PATCH", `/sessions/${id}`, { costUsd: -1 }],
      ["PATCH", `/sessions/${id}`, {}],
      ["PUT", `/sessions/${id}/steps`, { idx: 0 }],
      ["PUT", `/sessions/${id}/steps`, [{ idx: 0, title: "a", text: "b" }, { idx: 0, title: "c", text: "d" }]],
      ["PUT", `/sessions/${id}/steps`, [{ idx: 1.5, title: "a", text: "b" }]],
      ["PUT", `/sessions/${id}/steps`, [{ idx: 0, title: "a", text: "b", focus: [1] }]],
      ["POST", `/sessions/${id}/feedback`, { rating: 0 }],
      ["POST", `/sessions/${id}/feedback`, { rating: 6 }],
      ["POST", `/sessions/${id}/feedback`, { rating: 4.5 }],
      ["POST", "/sessions", {}],
      ["POST", "/sessions", { instructions: "   " }],
    ];
    for (const [method, path, body] of cases) {
      await expectError(await call(path, req(ownerToken, method, body)), 400, "invalid_request");
    }
    await expectError(
      await call(`/sessions/${id}`, { ...req(ownerToken, "PATCH"), body: "{not json", headers: { authorization: `Bearer ${ownerToken}` } }),
      400,
    );
  });
});
