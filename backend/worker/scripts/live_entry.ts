// Worker entry for scripts/live_check.mjs: the real app router plus the AI
// routes, until src/index.ts mounts aiRoutes() itself (a duplicate mount is
// harmless — the first matching route wins).
import type { Env } from "../src/env";
import { router } from "../src/index";
import { mountAiRoutes } from "../src/routes/ai";

mountAiRoutes(router);

export default {
  fetch(request, env, ctx) {
    return router.handle(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
