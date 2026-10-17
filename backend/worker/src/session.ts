import type { Env } from "./env";
import { ApiError } from "./errors";

/** Session lifetime in seconds. */
export const SESSION_TTL_SECONDS = 60 * 60;

export interface SessionClaims {
  sub: string;
  email: string;
}

interface SessionPayload extends SessionClaims {
  iat: number;
  exp: number;
}

export interface IssuedSession {
  sessionToken: string;
  /** ISO 8601 UTC. */
  expiresAt: string;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64UrlEncode(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = "";
  for (const b of arr) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Throws on malformed input. */
export function base64UrlDecode(s: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new Error("invalid base64url");
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function base64UrlEncodeJson(value: unknown): string {
  return base64UrlEncode(encoder.encode(JSON.stringify(value)));
}

export function decodeJsonSegment(segment: string): unknown {
  return JSON.parse(decoder.decode(base64UrlDecode(segment)));
}

export function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

export function unauthorized(): ApiError {
  return new ApiError(401, "unauthorized", "ავტორიზაცია საჭიროა");
}

const keyCache = new Map<string, Promise<CryptoKey>>();

function hmacKey(env: Env): Promise<CryptoKey> {
  const secret = env.SESSION_SECRET;
  if (!secret) {
    console.error("SESSION_SECRET is not configured");
    throw ApiError.internal();
  }
  let key = keyCache.get(secret);
  if (!key) {
    key = crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
      "sign",
      "verify",
    ]);
    keyCache.set(secret, key);
  }
  return key;
}

/** Signs a HS256 session JWT valid for {@link SESSION_TTL_SECONDS}. */
export async function issueSession(env: Env, claims: SessionClaims, now = nowSeconds()): Promise<IssuedSession> {
  const exp = now + SESSION_TTL_SECONDS;
  const payload: SessionPayload = { sub: claims.sub, email: claims.email, iat: now, exp };
  const signingInput = `${base64UrlEncodeJson({ alg: "HS256", typ: "JWT" })}.${base64UrlEncodeJson(payload)}`;
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(env), encoder.encode(signingInput));
  return {
    sessionToken: `${signingInput}.${base64UrlEncode(sig)}`,
    expiresAt: new Date(exp * 1000).toISOString(),
  };
}

/** Verifies a session JWT; throws 401 ApiError when invalid or expired. */
export async function verifySession(env: Env, token: string, now = nowSeconds()): Promise<SessionClaims> {
  const key = await hmacKey(env);
  const parts = token.split(".");
  if (parts.length !== 3) throw unauthorized();
  const [h, p, s] = parts as [string, string, string];
  let header: unknown;
  let payload: unknown;
  let sig: Uint8Array<ArrayBuffer>;
  try {
    header = decodeJsonSegment(h);
    payload = decodeJsonSegment(p);
    sig = base64UrlDecode(s);
  } catch {
    throw unauthorized();
  }
  if (!isObject(header) || header.alg !== "HS256") throw unauthorized();
  const ok = await crypto.subtle.verify("HMAC", key, sig, encoder.encode(`${h}.${p}`));
  if (!ok || !isObject(payload)) throw unauthorized();
  const { sub, email, exp } = payload;
  if (typeof sub !== "string" || typeof email !== "string" || typeof exp !== "number") throw unauthorized();
  if (exp <= now) throw unauthorized();
  return { sub, email };
}

/** Reads `Authorization: Bearer <session>` and returns its claims, or throws 401. */
export async function requireSession(request: Request, env: Env): Promise<SessionClaims> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  if (!match) throw unauthorized();
  return verifySession(env, match[1]!);
}

export function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
