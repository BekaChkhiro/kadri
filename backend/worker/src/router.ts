import type { Env } from "./env";
import { ApiError, errorResponse } from "./errors";
import { LimitError } from "./limits";

export type Params = Record<string, string>;

export interface RouteContext {
  request: Request;
  env: Env;
  ctx: ExecutionContext;
  params: Params;
  url: URL;
}

export type Handler = (c: RouteContext) => Response | Promise<Response>;

interface Route {
  method: string;
  segments: string[];
  handler: Handler;
}

function split(path: string): string[] {
  return path.split("/").filter(Boolean);
}

function match(segments: string[], path: string[]): Params | null {
  if (segments.length !== path.length) return null;
  const params: Params = {};
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i]!;
    const part = path[i]!;
    if (seg.startsWith(":")) {
      params[seg.slice(1)] = decodeURIComponent(part);
    } else if (seg !== part) {
      return null;
    }
  }
  return params;
}

/** Minimal path+method router. Patterns use `:name` segments, e.g. `/sessions/:id`. */
export class Router {
  private routes: Route[] = [];

  on(method: string, pattern: string, handler: Handler): this {
    this.routes.push({ method: method.toUpperCase(), segments: split(pattern), handler });
    return this;
  }

  get(pattern: string, handler: Handler): this {
    return this.on("GET", pattern, handler);
  }

  post(pattern: string, handler: Handler): this {
    return this.on("POST", pattern, handler);
  }

  async handle(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = split(url.pathname);
    const method = request.method.toUpperCase();
    const allowed = new Set<string>();

    try {
      for (const route of this.routes) {
        const params = match(route.segments, path);
        if (!params) continue;
        if (route.method === method || (method === "HEAD" && route.method === "GET")) {
          return await route.handler({ request, env, ctx, params, url });
        }
        allowed.add(route.method);
      }
      if (allowed.size > 0) {
        return errorResponse(ApiError.methodNotAllowed(), { allow: [...allowed].join(", ") });
      }
      throw ApiError.notFound();
    } catch (err) {
      if (err instanceof ApiError) return errorResponse(err, err instanceof LimitError ? err.headers : undefined);
      console.error("unhandled error", err);
      return errorResponse(ApiError.internal());
    }
  }
}
