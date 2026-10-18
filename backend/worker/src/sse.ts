/** Server-Sent Events: writing our own streams and reading upstream ones. */

export const SSE_HEADERS: Record<string, string> = {
  "content-type": "text/event-stream; charset=utf-8",
  "cache-control": "no-cache",
  connection: "keep-alive",
  "x-accel-buffering": "no",
};

/** One SSE frame. `data` is JSON-encoded on a single line. */
export function sseEvent(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

/** Returns false once the client has gone away. */
export type SseSend = (event: string, data: unknown) => Promise<boolean>;

/**
 * Starts `run` and returns its events as a streaming response right away.
 * The stream closes when `run` settles.
 */
export function sseResponse(run: (send: SseSend) => Promise<void>, init: { status?: number; onCancel?: () => void } = {}): Response {
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const encoder = new TextEncoder();
  let open = true;
  // Cancellation rejects closed even while run is waiting for upstream data,
  // with no pending write to notice that the reader has disconnected.
  void writer.closed.catch(() => {
    open = false;
    init.onCancel?.();
  });
  const send: SseSend = async (event, data) => {
    if (!open) return false;
    try {
      await writer.write(encoder.encode(sseEvent(event, data)));
      return true;
    } catch {
      open = false;
      return false;
    }
  };
  void run(send)
    .catch((err) => console.error("sse run failed", err))
    .finally(() => {
      if (open) writer.close().catch(() => {});
    });
  return new Response(readable, { status: init.status ?? 200, headers: SSE_HEADERS });
}

export interface SseMessage {
  event: string | null;
  data: string;
}

/** Parses an SSE byte stream into messages (handles CRLF, comments, multi-line data). */
export async function* readSse(body: ReadableStream<Uint8Array>): AsyncGenerator<SseMessage> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let event: string | null = null;
  let data: string[] = [];
  const flushLine = (line: string): SseMessage | null => {
    if (line === "") {
      const msg = data.length ? { event, data: data.join("\n") } : null;
      event = null;
      data = [];
      return msg;
    }
    if (line.startsWith(":")) return null;
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    else if (field === "data") data.push(value);
    return null;
  };
  try {
    while (true) {
      const { done, value } = await reader.read();
      buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buffer.search(/\r\n|\r|\n/)) >= 0) {
        // A trailing CR may be the first half of a CRLF split across chunks.
        if (!done && nl === buffer.length - 1 && buffer[nl] === "\r") break;
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + (buffer.startsWith("\r\n", nl) ? 2 : 1));
        const msg = flushLine(line);
        if (msg) yield msg;
      }
      if (done) {
        if (buffer) flushLine(buffer);
        const msg = flushLine("");
        if (msg) yield msg;
        return;
      }
    }
  } finally {
    reader.releaseLock();
  }
}
