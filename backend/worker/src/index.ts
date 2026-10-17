import { googleSignIn, me, refreshSession } from "./auth";
import type { Env } from "./env";
import { json } from "./errors";
import { registerHistoryRoutes } from "./history";
import { Router } from "./router";
import { mountGuardedAiRoutes } from "./routes/ai";

export { requireSession } from "./session";

export const router = mountGuardedAiRoutes(registerHistoryRoutes(new Router()))
  .get("/health", ({ env }) =>
    json({
      ok: true,
      env: env.ENVIRONMENT,
      provider: env.AI_PROVIDER,
      version: env.VERSION ?? "dev",
    }),
  )
  .post("/auth/google", googleSignIn)
  .post("/auth/refresh", refreshSession)
  .get("/me", me);

export default {
  fetch(request, env, ctx) {
    return router.handle(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
