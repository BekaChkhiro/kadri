import { partsHandler } from "../ai/parts";
import { stepsHandler } from "../ai/steps";
import type { Handler, Router } from "../router";

export interface AiRoute {
  method: "POST";
  pattern: string;
  handler: Handler;
}

/** AI stage routes; mount with `for (const r of aiRoutes()) router.on(r.method, r.pattern, r.handler)`. */
export function aiRoutes(): AiRoute[] {
  return [
    { method: "POST", pattern: "/ai/parts", handler: partsHandler },
    { method: "POST", pattern: "/ai/steps", handler: stepsHandler },
  ];
}

export function mountAiRoutes(router: Router): Router {
  for (const r of aiRoutes()) router.on(r.method, r.pattern, r.handler);
  return router;
}
