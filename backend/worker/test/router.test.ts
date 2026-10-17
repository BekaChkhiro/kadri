import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

describe("router", () => {
  it("returns a Georgian JSON 404 for unknown paths", async () => {
    const res = await exports.default.fetch("http://example.com/nope");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: { code: "not_found", message: "ვერ მოიძებნა" } });
  });

  it("returns 405 with Allow header on method mismatch", async () => {
    const res = await exports.default.fetch("http://example.com/health", { method: "POST" });
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("GET");
    const body = await res.json<{ error: { code: string; message: string } }>();
    expect(body.error.code).toBe("method_not_allowed");
    expect(body.error.message).toBeTruthy();
  });
});
