import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

describe("GET /health", () => {
  it("returns 200 with env, provider and version", async () => {
    const res = await exports.default.fetch("http://example.com/health");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(await res.json()).toEqual({ ok: true, env: "dev", provider: "astra", version: "dev" });
  });
});
