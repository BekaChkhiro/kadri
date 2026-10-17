import type { Env } from "./env";
import { json } from "./errors";
import { Router } from "./router";

export const router = new Router().get("/health", ({ env }) =>
  json({
    ok: true,
    env: env.ENVIRONMENT,
    provider: env.AI_PROVIDER,
    version: env.VERSION ?? "dev",
  }),
);

export default {
  fetch(request, env, ctx) {
    return router.handle(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
