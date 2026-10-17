import type { Env } from "./env";
import { ApiError, json } from "./errors";
import type { RouteContext } from "./router";
import {
  base64UrlDecode,
  decodeJsonSegment,
  isObject,
  issueSession,
  nowSeconds,
  requireSession,
  unauthorized,
} from "./session";

export const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_ISSUERS = new Set(["accounts.google.com", "https://accounts.google.com"]);
/** Allowed clock skew for exp/iat, seconds. */
const CLOCK_SKEW_SECONDS = 60;
/** Used when Google's response carries no max-age. */
const DEFAULT_JWKS_TTL_SECONDS = 60 * 60;
/** An unknown kid forces a refetch at most this often (key rotation without hammering Google). */
const MIN_REFETCH_INTERVAL_SECONDS = 60;

const RS256 = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } as const;

export interface GoogleClaims {
  sub: string;
  email: string;
  name: string | null;
  picture: string | null;
}

export interface User {
  id: string;
  email: string;
  name: string | null;
  picture: string | null;
}

interface JwksCache {
  keys: Map<string, CryptoKey>;
  expiresAt: number;
  fetchedAt: number;
}

let jwks: JwksCache | null = null;

/** Test hook: forget cached Google keys. */
export function resetJwksCache(): void {
  jwks = null;
}

function maxAge(cacheControl: string | null): number {
  const m = /max-age=(\d+)/i.exec(cacheControl ?? "");
  return m ? Number(m[1]) : DEFAULT_JWKS_TTL_SECONDS;
}

async function fetchJwks(now: number): Promise<JwksCache> {
  const res = await fetch(GOOGLE_JWKS_URL);
  if (!res.ok) {
    console.error("google jwks fetch failed", res.status);
    throw new ApiError(502, "auth_upstream", "Google-თან კავშირი ვერ მოხერხდა");
  }
  const body = await res.json<{ keys?: (JsonWebKey & { kid?: string })[] }>();
  const keys = new Map<string, CryptoKey>();
  for (const jwk of body.keys ?? []) {
    if (!jwk.kid || jwk.kty !== "RSA") continue;
    try {
      keys.set(jwk.kid, await crypto.subtle.importKey("jwk", jwk, RS256, false, ["verify"]));
    } catch (err) {
      console.error("skipping unusable google jwk", jwk.kid, err);
    }
  }
  return { keys, fetchedAt: now, expiresAt: now + maxAge(res.headers.get("cache-control")) };
}

async function googleKey(kid: string, now: number): Promise<CryptoKey | undefined> {
  if (!jwks || jwks.expiresAt <= now) {
    jwks = await fetchJwks(now);
  } else if (!jwks.keys.has(kid) && now - jwks.fetchedAt >= MIN_REFETCH_INTERVAL_SECONDS) {
    jwks = await fetchJwks(now);
  }
  return jwks.keys.get(kid);
}

function allowedAudiences(env: Env): Set<string> {
  return new Set(
    (env.GOOGLE_CLIENT_IDS ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
}

/** Validates a Google ID token (RS256, iss, aud, exp/iat, email_verified). Throws 401 on any failure. */
export async function verifyGoogleIdToken(env: Env, idToken: string, now = nowSeconds()): Promise<GoogleClaims> {
  const audiences = allowedAudiences(env);
  if (audiences.size === 0) {
    console.error("GOOGLE_CLIENT_IDS is not configured");
    throw ApiError.internal();
  }
  const parts = idToken.split(".");
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
  if (!isObject(header) || header.alg !== "RS256" || typeof header.kid !== "string") throw unauthorized();
  const key = await googleKey(header.kid, now);
  if (!key) throw unauthorized();
  const ok = await crypto.subtle.verify(RS256, key, sig, new TextEncoder().encode(`${h}.${p}`));
  if (!ok || !isObject(payload)) throw unauthorized();

  const { iss, aud, exp, iat, sub, email, email_verified, name, picture } = payload;
  if (typeof iss !== "string" || !GOOGLE_ISSUERS.has(iss)) throw unauthorized();
  if (typeof aud !== "string" || !audiences.has(aud)) throw unauthorized();
  if (typeof exp !== "number" || exp + CLOCK_SKEW_SECONDS <= now) throw unauthorized();
  if (typeof iat !== "number" || iat - CLOCK_SKEW_SECONDS > now) throw unauthorized();
  if (typeof sub !== "string" || !sub || typeof email !== "string" || !email) throw unauthorized();
  // Google sends email_verified as a boolean; older tokens used the string "true".
  if (email_verified !== true && email_verified !== "true") throw unauthorized();

  return {
    sub,
    email,
    name: typeof name === "string" ? name : null,
    picture: typeof picture === "string" ? picture : null,
  };
}

async function upsertUser(env: Env, claims: GoogleClaims): Promise<User> {
  const now = new Date().toISOString();
  const row = await env.DB.prepare(
    `INSERT INTO users (id, email, name, picture, created_at, last_login_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5)
     ON CONFLICT (id) DO UPDATE SET
       email = excluded.email,
       name = excluded.name,
       picture = excluded.picture,
       last_login_at = excluded.last_login_at
     RETURNING id, email, name, picture`,
  )
    .bind(claims.sub, claims.email, claims.name, claims.picture, now)
    .first<User>();
  if (!row) throw ApiError.internal();
  return row;
}

/** POST /auth/google {idToken} → {sessionToken, expiresAt, user}. */
export async function googleSignIn({ request, env }: RouteContext): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    body = null;
  }
  if (!isObject(body) || typeof body.idToken !== "string" || !body.idToken) {
    throw new ApiError(400, "bad_request", "idToken აკლია");
  }
  const claims = await verifyGoogleIdToken(env, body.idToken);
  const user = await upsertUser(env, claims);
  const session = await issueSession(env, { sub: user.id, email: user.email });
  return json({ ...session, user });
}

/** POST /auth/refresh with a valid Bearer session → a fresh session. */
export async function refreshSession({ request, env }: RouteContext): Promise<Response> {
  const claims = await requireSession(request, env);
  return json(await issueSession(env, claims));
}

/** GET /me — sample protected endpoint. */
export async function me({ request, env }: RouteContext): Promise<Response> {
  const { sub } = await requireSession(request, env);
  const user = await env.DB.prepare("SELECT id, email, name, picture FROM users WHERE id = ?1").bind(sub).first<User>();
  if (!user) throw unauthorized();
  return json({ user });
}
