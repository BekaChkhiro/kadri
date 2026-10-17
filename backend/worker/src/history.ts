import type { Env } from "./env";
import { ApiError, json } from "./errors";
import type { Handler, RouteContext, Router } from "./router";
import { base64UrlDecode, base64UrlEncode, isObject, requireSession, unauthorized } from "./session";

export const SESSION_STATUSES = ["created", "parts", "steps", "done", "failed"] as const;
export type SessionStatus = (typeof SESSION_STATUSES)[number];

export const MAX_KEYFRAME_BYTES = 2 * 1024 * 1024;
export const DEFAULT_LIST_LIMIT = 20;
export const MAX_LIST_LIMIT = 50;

const MAX_TEXT = 2000;
const MAX_NAME = 200;
const MAX_ITEMS = 50;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface Part {
  id: string;
  name: string;
  /** XYXY in 0–1000 image-normalised coordinates. */
  box: [number, number, number, number];
}

export interface StepInput {
  idx: number;
  title: string;
  text: string;
  focus: string[];
  avoid: string[];
}

interface SessionRow {
  id: string;
  user_id: string;
  object_name: string | null;
  instructions: string;
  status: SessionStatus;
  keyframe_key: string | null;
  parts_json: string | null;
  cost_usd: number | null;
  created_at: string;
  updated_at: string;
}

function badRequest(message: string): ApiError {
  return new ApiError(400, "invalid_request", message);
}

function forbidden(): ApiError {
  return new ApiError(403, "forbidden", "ამ სესიაზე წვდომა არ გაქვთ");
}

export function keyframeKey(sub: string, sessionId: string): string {
  return `users/${sub}/sessions/${sessionId}/keyframe.jpg`;
}

function keyframeUrl(url: URL, row: Pick<SessionRow, "id" | "keyframe_key">): string | null {
  return row.keyframe_key ? `${url.origin}/sessions/${row.id}/keyframe` : null;
}

async function readJson(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw badRequest("არასწორი JSON");
  }
}

function optionalString(value: unknown, field: string, max: number): string | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== "string" || value.length > max) throw badRequest(`ველი ${field} არასწორია`);
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function requiredString(value: unknown, field: string, max: number): string {
  const s = optionalString(value, field, max);
  if (!s) throw badRequest(`ველი ${field} სავალდებულოა`);
  return s;
}

function isCoord(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1000;
}

export function parseParts(value: unknown): Part[] {
  if (!Array.isArray(value) || value.length > MAX_ITEMS) throw badRequest("ველი parts არასწორია");
  const seen = new Set<string>();
  return value.map((p, i) => {
    const err = () => badRequest(`parts[${i}] არასწორია`);
    if (!isObject(p)) throw err();
    const { id, name, box } = p;
    if (typeof id !== "string" || id.trim() === "" || id.length > 32 || seen.has(id)) throw err();
    if (typeof name !== "string" || name.trim() === "" || name.length > MAX_NAME) throw err();
    if (!Array.isArray(box) || box.length !== 4 || !box.every(isCoord)) throw err();
    const [x1, y1, x2, y2] = box as [number, number, number, number];
    if (x1 > x2 || y1 > y2) throw err();
    seen.add(id);
    return { id, name: name.trim(), box: [x1, y1, x2, y2] };
  });
}

function stringList(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length > MAX_ITEMS) return null;
  return value.every((s) => typeof s === "string" && s.length > 0 && s.length <= 32) ? (value as string[]) : null;
}

export function parseSteps(value: unknown): StepInput[] {
  if (!Array.isArray(value) || value.length > MAX_ITEMS) throw badRequest("ნაბიჯების სია არასწორია");
  const seen = new Set<number>();
  return value.map((s, i) => {
    const err = () => badRequest(`steps[${i}] არასწორია`);
    if (!isObject(s)) throw err();
    const { idx, title, text } = s;
    if (typeof idx !== "number" || !Number.isInteger(idx) || idx < 0 || idx > 999 || seen.has(idx)) throw err();
    if (typeof title !== "string" || title.trim() === "" || title.length > MAX_NAME) throw err();
    if (typeof text !== "string" || text.length > MAX_TEXT) throw err();
    const focus = s.focus === undefined ? [] : stringList(s.focus);
    const avoid = s.avoid === undefined ? [] : stringList(s.avoid);
    if (!focus || !avoid) throw err();
    seen.add(idx);
    return { idx, title: title.trim(), text: text.trim(), focus, avoid };
  });
}

/** Loads a session the caller owns: 404 when missing, 403 when it belongs to someone else. */
async function ownedSession(c: RouteContext): Promise<{ sub: string; row: SessionRow }> {
  const { sub } = await requireSession(c.request, c.env);
  const id = c.params.id ?? "";
  if (!UUID_RE.test(id)) throw ApiError.notFound();
  const row = await c.env.DB.prepare("SELECT * FROM sessions WHERE id = ?").bind(id).first<SessionRow>();
  if (!row) throw ApiError.notFound();
  if (row.user_id !== sub) throw forbidden();
  return { sub, row };
}

function touch(env: Env, id: string, now: string): D1PreparedStatement {
  return env.DB.prepare("UPDATE sessions SET updated_at = ? WHERE id = ?").bind(now, id);
}

const createSession: Handler = async ({ request, env }) => {
  const { sub } = await requireSession(request, env);
  const body = await readJson(request);
  if (!isObject(body)) throw badRequest("არასწორი მოთხოვნა");
  const instructions = requiredString(body.instructions, "instructions", MAX_TEXT);
  const objectName = optionalString(body.objectName, "objectName", MAX_NAME) ?? null;
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const res = await env.DB.prepare(
    `INSERT INTO sessions (id, user_id, object_name, instructions, status, created_at, updated_at)
     SELECT ?1, ?2, ?3, ?4, 'created', ?5, ?5 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?2)`,
  )
    .bind(id, sub, objectName, instructions, now)
    .run();
  // A valid token for a user row that no longer exists.
  if (res.meta.changes !== 1) throw unauthorized();
  return json({ id, createdAt: now }, 201);
};

const putKeyframe: Handler = async (c) => {
  const { sub, row } = await ownedSession(c);
  const type = (c.request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (type !== "image/jpeg") {
    throw new ApiError(415, "unsupported_media_type", "მხოლოდ image/jpeg ფორმატია მხარდაჭერილი");
  }
  const tooLarge = () => new ApiError(413, "payload_too_large", "ფოტო 2 MB-ზე დიდია");
  const declared = Number(c.request.headers.get("content-length") ?? "0");
  if (declared > MAX_KEYFRAME_BYTES) throw tooLarge();
  const bytes = new Uint8Array(await c.request.arrayBuffer());
  if (bytes.byteLength > MAX_KEYFRAME_BYTES) throw tooLarge();
  if (bytes.byteLength < 3 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
    throw new ApiError(415, "unsupported_media_type", "ფაილი JPEG არ არის");
  }
  const key = keyframeKey(sub, row.id);
  await c.env.PHOTOS.put(key, bytes, { httpMetadata: { contentType: "image/jpeg" } });
  const now = new Date().toISOString();
  await c.env.DB.prepare("UPDATE sessions SET keyframe_key = ?, updated_at = ? WHERE id = ?")
    .bind(key, now, row.id)
    .run();
  return json({ keyframeUrl: keyframeUrl(c.url, { id: row.id, keyframe_key: key }) });
};

const getKeyframe: Handler = async (c) => {
  const { row } = await ownedSession(c);
  if (!row.keyframe_key) throw ApiError.notFound();
  const obj = await c.env.PHOTOS.get(row.keyframe_key);
  if (!obj) throw ApiError.notFound();
  return new Response(c.request.method === "HEAD" ? null : obj.body, {
    headers: {
      "content-type": "image/jpeg",
      "content-length": String(obj.size),
      "cache-control": "private, max-age=3600",
      etag: obj.httpEtag,
    },
  });
};

const patchSession: Handler = async (c) => {
  const { row } = await ownedSession(c);
  const body = await readJson(c.request);
  if (!isObject(body)) throw badRequest("არასწორი მოთხოვნა");
  const sets: string[] = [];
  const values: unknown[] = [];
  if (body.status !== undefined) {
    if (!SESSION_STATUSES.includes(body.status as SessionStatus)) throw badRequest("ველი status არასწორია");
    sets.push("status = ?");
    values.push(body.status);
  }
  const objectName = optionalString(body.objectName, "objectName", MAX_NAME);
  if (objectName !== undefined) {
    sets.push("object_name = ?");
    values.push(objectName);
  }
  if (body.parts !== undefined) {
    sets.push("parts_json = ?");
    values.push(JSON.stringify(parseParts(body.parts)));
  }
  if (body.costUsd !== undefined) {
    const cost = body.costUsd;
    if (typeof cost !== "number" || !Number.isFinite(cost) || cost < 0) throw badRequest("ველი costUsd არასწორია");
    sets.push("cost_usd = ?");
    values.push(cost);
  }
  if (sets.length === 0) throw badRequest("შესაცვლელი ველი არ არის მითითებული");
  const now = new Date().toISOString();
  await c.env.DB.prepare(`UPDATE sessions SET ${sets.join(", ")}, updated_at = ? WHERE id = ?`)
    .bind(...values, now, row.id)
    .run();
  return json({ id: row.id, updatedAt: now });
};

const putSteps: Handler = async (c) => {
  const { row } = await ownedSession(c);
  const steps = parseSteps(await readJson(c.request));
  const now = new Date().toISOString();
  const db = c.env.DB;
  await db.batch([
    db.prepare("DELETE FROM steps WHERE session_id = ?").bind(row.id),
    ...steps.map((s) =>
      db
        .prepare(
          "INSERT INTO steps (session_id, idx, title, text, focus_json, avoid_json) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(row.id, s.idx, s.title, s.text, JSON.stringify(s.focus), JSON.stringify(s.avoid)),
    ),
    touch(c.env, row.id, now),
  ]);
  return json({ id: row.id, stepCount: steps.length, updatedAt: now });
};

const postFeedback: Handler = async (c) => {
  const { row } = await ownedSession(c);
  const body = await readJson(c.request);
  if (!isObject(body)) throw badRequest("არასწორი მოთხოვნა");
  const { rating } = body;
  if (typeof rating !== "number" || !Number.isInteger(rating) || rating < 1 || rating > 5) {
    throw badRequest("შეფასება 1-დან 5-მდე მთელი რიცხვი უნდა იყოს");
  }
  const comment = optionalString(body.comment, "comment", MAX_TEXT) ?? null;
  const now = new Date().toISOString();
  const res = await c.env.DB.prepare(
    "INSERT INTO feedback (session_id, rating, comment, created_at) VALUES (?, ?, ?, ?) RETURNING id",
  )
    .bind(row.id, rating, comment, now)
    .first<{ id: number }>();
  return json({ id: res!.id, createdAt: now }, 201);
};

interface Cursor {
  createdAt: string;
  id: string;
}

function encodeCursor(c: Cursor): string {
  return base64UrlEncode(new TextEncoder().encode(`${c.createdAt}|${c.id}`));
}

function decodeCursor(s: string): Cursor {
  try {
    const [createdAt, id] = new TextDecoder().decode(base64UrlDecode(s)).split("|");
    if (createdAt && id && UUID_RE.test(id)) return { createdAt, id };
  } catch {
    // fall through
  }
  throw badRequest("ველი cursor არასწორია");
}

const listSessions: Handler = async ({ request, env, url }) => {
  const { sub } = await requireSession(request, env);
  const limitParam = url.searchParams.get("limit");
  const limit = limitParam === null ? DEFAULT_LIST_LIMIT : Number(limitParam);
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIST_LIMIT) {
    throw badRequest(`limit უნდა იყოს 1-დან ${MAX_LIST_LIMIT}-მდე`);
  }
  const cursorParam = url.searchParams.get("cursor");
  const cursor = cursorParam ? decodeCursor(cursorParam) : null;
  const { results } = await env.DB.prepare(
    `SELECT s.id, s.object_name, s.status, s.created_at, s.keyframe_key,
            (SELECT COUNT(*) FROM steps WHERE session_id = s.id) AS step_count
     FROM sessions s
     WHERE s.user_id = ?1 AND (?2 IS NULL OR s.created_at < ?2 OR (s.created_at = ?2 AND s.id < ?3))
     ORDER BY s.created_at DESC, s.id DESC
     LIMIT ?4`,
  )
    .bind(sub, cursor?.createdAt ?? null, cursor?.id ?? null, limit + 1)
    .all<Pick<SessionRow, "id" | "object_name" | "status" | "created_at" | "keyframe_key"> & { step_count: number }>();
  const page = results.slice(0, limit);
  const last = page.at(-1);
  return json({
    sessions: page.map((r) => ({
      id: r.id,
      objectName: r.object_name,
      status: r.status,
      createdAt: r.created_at,
      stepCount: r.step_count,
      keyframeUrl: keyframeUrl(url, r),
    })),
    nextCursor: results.length > limit && last ? encodeCursor({ createdAt: last.created_at, id: last.id }) : null,
  });
};

const getSession: Handler = async (c) => {
  const { row } = await ownedSession(c);
  const db = c.env.DB;
  const [steps, feedback] = await db.batch([
    db
      .prepare("SELECT idx, title, text, focus_json, avoid_json FROM steps WHERE session_id = ? ORDER BY idx")
      .bind(row.id),
    db
      .prepare("SELECT id, rating, comment, created_at FROM feedback WHERE session_id = ? ORDER BY created_at, id")
      .bind(row.id),
  ]);
  type StepRow = { idx: number; title: string; text: string; focus_json: string; avoid_json: string };
  type FeedbackRow = { id: number; rating: number; comment: string | null; created_at: string };
  return json({
    id: row.id,
    objectName: row.object_name,
    instructions: row.instructions,
    status: row.status,
    parts: row.parts_json ? (JSON.parse(row.parts_json) as Part[]) : [],
    costUsd: row.cost_usd,
    keyframeUrl: keyframeUrl(c.url, row),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    steps: (steps!.results as StepRow[]).map((s) => ({
      idx: s.idx,
      title: s.title,
      text: s.text,
      focus: JSON.parse(s.focus_json) as string[],
      avoid: JSON.parse(s.avoid_json) as string[],
    })),
    feedback: (feedback!.results as FeedbackRow[]).map((f) => ({
      id: f.id,
      rating: f.rating,
      comment: f.comment,
      createdAt: f.created_at,
    })),
  });
};

const deleteSession: Handler = async (c) => {
  const { row } = await ownedSession(c);
  if (row.keyframe_key) await c.env.PHOTOS.delete(row.keyframe_key);
  const db = c.env.DB;
  // Children explicitly too, so deletion does not depend on PRAGMA foreign_keys.
  await db.batch([
    db.prepare("DELETE FROM feedback WHERE session_id = ?").bind(row.id),
    db.prepare("DELETE FROM steps WHERE session_id = ?").bind(row.id),
    db.prepare("DELETE FROM sessions WHERE id = ?").bind(row.id),
  ]);
  return new Response(null, { status: 204 });
};

/** Registers the session-history routes. All require `Authorization: Bearer <session>`. */
export function registerHistoryRoutes(router: Router): Router {
  return router
    .post("/sessions", createSession)
    .get("/sessions", listSessions)
    .get("/sessions/:id", getSession)
    .on("PATCH", "/sessions/:id", patchSession)
    .on("DELETE", "/sessions/:id", deleteSession)
    .on("PUT", "/sessions/:id/keyframe", putKeyframe)
    .get("/sessions/:id/keyframe", getKeyframe)
    .on("PUT", "/sessions/:id/steps", putSteps)
    .post("/sessions/:id/feedback", postFeedback);
}
