import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { resetJwksCache } from "../src/auth";
import { base64UrlEncodeJson } from "../src/session";
import {
  WEB_CLIENT_ID,
  env,
  generateRsaKey,
  googleClaims,
  migrate,
  now,
  postJson,
  signRs256,
  stubJwks,
} from "./auth-helpers";

interface SignInBody {
  sessionToken: string;
  expiresAt: string;
  user: { id: string; email: string; name: string | null; picture: string | null };
}
interface ErrorBody {
  error: { code: string; message: string };
}

let google: CryptoKeyPair;
let fetchSpy: Awaited<ReturnType<typeof stubJwks>>;

beforeAll(async () => {
  await migrate();
  google = await generateRsaKey();
});

beforeEach(async () => {
  resetJwksCache();
  fetchSpy = await stubJwks(google.publicKey);
});

afterEach(() => {
  vi.restoreAllMocks();
});

async function signIn(claims: Record<string, unknown>, key = google.privateKey): Promise<Response> {
  return postJson("/auth/google", { idToken: await signRs256(key, claims) });
}

async function expect401(res: Response): Promise<void> {
  expect(res.status).toBe(401);
  const body = await res.json<ErrorBody>();
  expect(body.error).toEqual({ code: "unauthorized", message: "ავტორიზაცია საჭიროა" });
}

describe("POST /auth/google", () => {
  it("accepts a valid ID token, upserts the user and returns a session", async () => {
    const before = now();
    const res = await signIn(googleClaims());
    expect(res.status).toBe(200);
    const body = await res.json<SignInBody>();
    expect(body.user).toEqual({
      id: "1234567890",
      email: "nino@example.com",
      name: "ნინო",
      picture: "https://example.com/nino.png",
    });
    expect(body.sessionToken.split(".")).toHaveLength(3);
    const exp = Date.parse(body.expiresAt) / 1000;
    expect(exp).toBeGreaterThanOrEqual(before + 3600);
    expect(exp).toBeLessThanOrEqual(now() + 3600);

    const row = await env.DB.prepare("SELECT * FROM users WHERE id = ?1").bind("1234567890").first<{
      email: string;
      created_at: string;
      last_login_at: string;
    }>();
    expect(row?.email).toBe("nino@example.com");
    expect(row?.created_at).toBe(row?.last_login_at);
  });

  it("updates an existing user on repeat sign-in and keeps created_at", async () => {
    await signIn(googleClaims({ sub: "repeat-user" }));
    const first = await env.DB.prepare("SELECT created_at FROM users WHERE id = 'repeat-user'").first<{
      created_at: string;
    }>();
    const res = await signIn(googleClaims({ sub: "repeat-user", name: "ახალი სახელი", aud: WEB_CLIENT_ID }));
    expect(res.status).toBe(200);
    const row = await env.DB.prepare("SELECT name, created_at FROM users WHERE id = 'repeat-user'").first<{
      name: string;
      created_at: string;
    }>();
    expect(row).toEqual({ name: "ახალი სახელი", created_at: first?.created_at });
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE id = 'repeat-user'").first<{
      n: number;
    }>();
    expect(count?.n).toBe(1);
  });

  it("accepts the bare accounts.google.com issuer", async () => {
    expect((await signIn(googleClaims({ iss: "accounts.google.com" }))).status).toBe(200);
  });

  it("caches JWKS between requests", async () => {
    await signIn(googleClaims());
    await signIn(googleClaims());
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("rejects an expired token", async () => {
    const t = now();
    await expect401(await signIn(googleClaims({ iat: t - 7200, exp: t - 3600 })));
  });

  it("rejects a token issued in the future", async () => {
    await expect401(await signIn(googleClaims({ iat: now() + 600 })));
  });

  it("rejects a wrong audience", async () => {
    await expect401(await signIn(googleClaims({ aud: "someone-else.apps.googleusercontent.com" })));
  });

  it("rejects a wrong issuer", async () => {
    await expect401(await signIn(googleClaims({ iss: "https://evil.example.com" })));
  });

  it("rejects an unverified email", async () => {
    await expect401(await signIn(googleClaims({ email_verified: false })));
  });

  it("rejects a bad signature", async () => {
    const attacker = await generateRsaKey();
    await expect401(await signIn(googleClaims(), attacker.privateKey));
  });

  it("rejects a tampered payload", async () => {
    const token = await signRs256(google.privateKey, googleClaims());
    const [h, , s] = token.split(".");
    const forged = base64UrlEncodeJson(googleClaims({ sub: "admin" }));
    await expect401(await postJson("/auth/google", { idToken: `${h}.${forged}.${s}` }));
  });

  it("rejects an unknown kid", async () => {
    const token = await signRs256(google.privateKey, googleClaims(), "other-kid");
    await expect401(await postJson("/auth/google", { idToken: token }));
  });

  it("rejects garbage tokens", async () => {
    await expect401(await postJson("/auth/google", { idToken: "not-a-jwt" }));
  });

  it("returns 400 when idToken is missing", async () => {
    const res = await postJson("/auth/google", {});
    expect(res.status).toBe(400);
  });
});
