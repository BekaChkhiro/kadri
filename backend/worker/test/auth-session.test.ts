import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { resetJwksCache } from "../src/auth";
import { issueSession, requireSession, SESSION_TTL_SECONDS } from "../src/session";
import {
  call,
  generateRsaKey,
  googleClaims,
  migrate,
  now,
  postJson,
  signRs256,
  stubJwks,
  testEnv,
} from "./auth-helpers";

interface ErrorBody {
  error: { code: string; message: string };
}

let sessionToken: string;

beforeAll(async () => {
  await migrate();
  const google = await generateRsaKey();
  resetJwksCache();
  await stubJwks(google.publicKey);
  const res = await postJson("/auth/google", {
    idToken: await signRs256(google.privateKey, googleClaims({ sub: "session-user" })),
  });
  expect(res.status).toBe(200);
  sessionToken = (await res.json<{ sessionToken: string }>()).sessionToken;
  vi.restoreAllMocks();
});

afterEach(() => {
  vi.restoreAllMocks();
});

function bearer(token: string): RequestInit {
  return { headers: { authorization: `Bearer ${token}` } };
}

async function expect401(res: Response): Promise<void> {
  expect(res.status).toBe(401);
  expect((await res.json<ErrorBody>()).error.message).toBe("ავტორიზაცია საჭიროა");
}

describe("GET /me", () => {
  it("returns the user for a valid session", async () => {
    const res = await call("/me", bearer(sessionToken));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      user: {
        id: "session-user",
        email: "nino@example.com",
        name: "ნინო",
        picture: "https://example.com/nino.png",
      },
    });
  });

  it("rejects a missing Authorization header", async () => {
    await expect401(await call("/me"));
  });

  it("rejects an expired session", async () => {
    const old = await issueSession(
      testEnv,
      { sub: "session-user", email: "nino@example.com" },
      now() - SESSION_TTL_SECONDS - 1,
    );
    await expect401(await call("/me", bearer(old.sessionToken)));
  });

  it("rejects a session signed with another secret", async () => {
    const other = await issueSession(
      { ...testEnv, SESSION_SECRET: "a-different-secret" },
      { sub: "session-user", email: "nino@example.com" },
    );
    await expect401(await call("/me", bearer(other.sessionToken)));
  });

  it("rejects a tampered session payload", async () => {
    const [h, , s] = sessionToken.split(".");
    const forged = btoa(JSON.stringify({ sub: "x", email: "x", iat: now(), exp: now() + 9999 })).replace(/=+$/, "");
    await expect401(await call("/me", bearer(`${h}.${forged}.${s}`)));
  });

  it("rejects alg=none tokens", async () => {
    const enc = (v: unknown) => btoa(JSON.stringify(v)).replace(/=+$/, "");
    const token = `${enc({ alg: "none" })}.${enc({ sub: "session-user", email: "x", iat: now(), exp: now() + 60 })}.`;
    await expect401(await call("/me", bearer(token)));
  });
});

describe("POST /auth/refresh", () => {
  it("issues a new session for a valid one", async () => {
    const res = await call("/auth/refresh", { method: "POST", ...bearer(sessionToken) });
    expect(res.status).toBe(200);
    const body = await res.json<{ sessionToken: string; expiresAt: string }>();
    expect(Date.parse(body.expiresAt)).toBeGreaterThan(Date.now());
    const claims = await requireSession(new Request("http://example.com", bearer(body.sessionToken)), testEnv);
    expect(claims).toEqual({ sub: "session-user", email: "nino@example.com" });
  });

  it("rejects an expired session", async () => {
    const old = await issueSession(testEnv, { sub: "session-user", email: "nino@example.com" }, now() - 7200);
    await expect401(await call("/auth/refresh", { method: "POST", ...bearer(old.sessionToken) }));
  });
});
