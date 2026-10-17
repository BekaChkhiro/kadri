#!/usr/bin/env node
// Dev-only session token, signed like src/session.ts issueSession (HS256 JWT).
//
//   node scripts/dev_token.mjs [--sub dev-user] [--email dev@example.com] [--ttl 3600]
//
// SESSION_SECRET comes from the environment or backend/worker/.dev.vars. Use it
// against `wrangler dev` only — never mint tokens with a staging/prod secret.
import { createHmac } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const worker = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const b64url = (buf) => Buffer.from(buf).toString("base64url");

export function devVarsSecret() {
  if (process.env.SESSION_SECRET) return process.env.SESSION_SECRET;
  const path = join(worker, ".dev.vars");
  if (!existsSync(path)) return null;
  const line = readFileSync(path, "utf8").split("\n").find((l) => l.startsWith("SESSION_SECRET="));
  return line ? line.slice("SESSION_SECRET=".length).trim() : null;
}

export function devToken({ secret, sub = "dev-user", email = "dev@example.com", ttl = 3600 }) {
  if (!secret) throw new Error("SESSION_SECRET is not set (env or .dev.vars)");
  const iat = Math.floor(Date.now() / 1000);
  const input = `${b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }))}.${b64url(JSON.stringify({ sub, email, iat, exp: iat + ttl }))}`;
  return `${input}.${b64url(createHmac("sha256", secret).update(input).digest())}`;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = Object.fromEntries(
    process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
  );
  try {
    console.log(devToken({ secret: devVarsSecret(), sub: args.sub, email: args.email, ttl: Number(args.ttl ?? 3600) }));
  } catch (err) {
    console.error(err.message);
    process.exit(2);
  }
}
