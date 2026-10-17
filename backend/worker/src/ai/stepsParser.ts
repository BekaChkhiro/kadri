/**
 * Incremental parser for `{"steps": [ {...}, {...} ], ...}` arriving in
 * arbitrary chunks. `push` returns each step object as soon as its closing
 * brace arrives — never a partial object. If the text does not start with the
 * `steps` key it switches off (`fallback`), and the caller uses the final JSON.
 */
export class StepsStreamParser {
  private buf = "";
  private pos = 0;
  private state: "seek" | "items" | "done" | "off" = "seek";

  get fallback(): boolean {
    return this.state === "off";
  }

  push(delta: string): unknown[] {
    this.buf += delta;
    const out: unknown[] = [];
    if (this.state === "seek") {
      const head = '{"steps":[';
      const compact = this.buf.replace(/\s+/g, "");
      if (compact.startsWith(head)) {
        this.pos = /^\s*\{\s*"steps"\s*:\s*\[/.exec(this.buf)?.[0].length ?? -1;
        this.state = this.pos < 0 ? "off" : "items";
      } else if (!head.startsWith(compact)) {
        this.state = "off";
      }
    }
    while (this.state === "items") {
      let i = this.pos;
      while (i < this.buf.length && (this.buf[i] === "," || /\s/.test(this.buf[i]!))) i++;
      this.pos = i;
      if (i >= this.buf.length) break;
      if (this.buf[i] === "]") {
        this.state = "done";
        break;
      }
      if (this.buf[i] !== "{") {
        this.state = "off";
        break;
      }
      const end = objectEnd(this.buf, i);
      if (end < 0) break;
      try {
        out.push(JSON.parse(this.buf.slice(i, end)));
      } catch {
        this.state = "off";
        break;
      }
      this.pos = end;
    }
    return out;
  }
}

/** Index just past the `}` that closes the object starting at `start`, or -1 if not yet complete. */
function objectEnd(s: string, start: number): number {
  let depth = 0;
  let inString = false;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
    } else if (c === '"') {
      inString = true;
    } else if (c === "{" || c === "[") {
      depth++;
    } else if (c === "}" || c === "]") {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}
