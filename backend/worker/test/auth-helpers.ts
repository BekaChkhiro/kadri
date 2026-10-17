/// <reference types="vite/client" />
import { createExecutionContext } from "cloudflare:test";
import { env as workerEnv } from "cloudflare:workers";
import { vi } from "vitest";
import usersSql from "../migrations/0000_users.sql?raw";
import { GOOGLE_JWKS_URL } from "../src/auth";
import type { Env } from "../src/env";
import { router } from "../src/index";
import { base64UrlEncode, base64UrlEncodeJson } from "../src/session";

export const IOS_CLIENT_ID = "ios-client.apps.googleusercontent.com";
export const WEB_CLIENT_ID = "web-client.apps.googleusercontent.com";
export const KID = "test-kid-1";

// test/env.d.ts does not currently merge src/env.ts into Cloudflare.Env, so cast once here.
export const env = workerEnv as unknown as Env;

export const testEnv: Env = {
  ...env,
  SESSION_SECRET: "test-session-secret-not-for-production",
  GOOGLE_CLIENT_IDS: `${IOS_CLIENT_ID}, ${WEB_CLIENT_ID}`,
};

export async function migrate(): Promise<void> {
  const statements = usersSql
    .split(";")
    .map((s) => s.replace(/^\s*--.*$/gm, "").trim())
    .filter(Boolean);
  await env.DB.batch(statements.map((s) => env.DB.prepare(s)));
}

const RS256 = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } as const;

export function generateRsaKey(): Promise<CryptoKeyPair> {
  return crypto.subtle.generateKey({ ...RS256, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) }, true, [
    "sign",
    "verify",
  ]) as Promise<CryptoKeyPair>;
}

/** Stubs fetch so the Google JWKS URL serves `publicKey` under {@link KID}. Returns the spy. */
export async function stubJwks(publicKey: CryptoKey) {
  const jwk = (await crypto.subtle.exportKey("jwk", publicKey)) as JsonWebKey;
  const body = JSON.stringify({ keys: [{ ...jwk, kid: KID, alg: "RS256", use: "sig" }] });
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url !== GOOGLE_JWKS_URL) throw new Error(`unexpected fetch ${url}`);
    return new Response(body, {
      headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" },
    });
  });
}

export function now(): number {
  return Math.floor(Date.now() / 1000);
}

export function googleClaims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const t = now();
  return {
    iss: "https://accounts.google.com",
    aud: IOS_CLIENT_ID,
    sub: "1234567890",
    email: "nino@example.com",
    email_verified: true,
    name: "ნინო",
    picture: "https://example.com/nino.png",
    iat: t,
    exp: t + 3600,
    ...overrides,
  };
}

export async function signRs256(privateKey: CryptoKey, payload: unknown, kid = KID): Promise<string> {
  const input = `${base64UrlEncodeJson({ alg: "RS256", kid, typ: "JWT" })}.${base64UrlEncodeJson(payload)}`;
  const sig = await crypto.subtle.sign(RS256, privateKey, new TextEncoder().encode(input));
  return `${input}.${base64UrlEncode(sig)}`;
}

export function call(path: string, init?: RequestInit, e: Env = testEnv): Promise<Response> {
  return router.handle(new Request(`http://example.com${path}`, init), e, createExecutionContext());
}

export function postJson(path: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return call(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}
