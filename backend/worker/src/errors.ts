export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    /** User-facing message, in Georgian. */
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }

  static notFound(): ApiError {
    return new ApiError(404, "not_found", "ვერ მოიძებნა");
  }

  static methodNotAllowed(): ApiError {
    return new ApiError(405, "method_not_allowed", "მეთოდი არ არის დაშვებული");
  }

  static internal(): ApiError {
    return new ApiError(500, "internal", "სერვერის შეცდომა");
  }
}

export function json(body: unknown, status = 200, headers?: HeadersInit): Response {
  const h = new Headers(headers);
  h.set("content-type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { status, headers: h });
}

export function errorResponse(err: ApiError, headers?: HeadersInit): Response {
  return json({ error: { code: err.code, message: err.message } }, err.status, headers);
}
