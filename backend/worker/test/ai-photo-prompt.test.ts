import { describe, expect, it } from "vitest";
import { promptSteps } from "../src/ai/prompts";
import { LIMITS, schemaSteps } from "../src/ai/schema";
import { clampText, tidyContinuation } from "../src/ai/validate";

const len = (s: string) => [...s].length;
// 95 characters, words of 9–10 letters.
const long = "გადაიღე დედაპლატის, ოპერატიულისა და პროცესორის წარწერები ახლოდან, ისე რომ ყველა ასო იკითხებოდეს";

describe("needs_photo prompt length (T7.9)", () => {
  it("allows 90 characters only with capabilities", () => {
    const prompt = (caps?: string[]) =>
      (schemaSteps(["p1"], 5, { capabilities: caps }) as any).properties.continuation.properties.prompt;
    expect(prompt().maxLength).toBe(LIMITS.photoPrompt);
    expect(prompt(["tools_v2"]).maxLength).toBe(LIMITS.photoPromptV2);
    expect(prompt(["needs_answer"]).maxLength).toBe(90);
    expect(prompt(["future"]).maxLength).toBe(LIMITS.photoPrompt);
  });

  it("tells the model ≤90 only with capabilities", () => {
    expect(promptSteps("x", [], "ზეთი", undefined, { count: 5 })).toContain("≤60 სიმბ.");
    expect(promptSteps("x", [], "ზეთი", undefined, { count: 5, capabilities: ["tools_v2"] })).toContain("≤90 სიმბ.");
    const diagnostic = promptSteps("x", [], "ზეთი", undefined, { count: 5, capabilities: ["needs_answer"] });
    expect(diagnostic).toContain("prompt ≤90");
    expect(diagnostic).not.toContain("≤60");
  });

  it("cuts a 95-character prompt at a word under 90", () => {
    expect(len(long)).toBe(95);
    const c = tidyContinuation({ kind: "needs_photo", prompt: long, reason: "მიზეზი" }, { capabilities: ["tools_v2"] }) as any;
    expect(len(c.prompt)).toBeLessThanOrEqual(90);
    expect(c.prompt.endsWith("…")).toBe(true);
    expect(long.startsWith(c.prompt.slice(0, -1) + " ")).toBe(true);
  });

  it("keeps legacy prompts at 60, at a word", () => {
    const c = tidyContinuation({ kind: "needs_photo", prompt: long, reason: "მიზეზი" }) as any;
    expect(len(c.prompt)).toBeLessThanOrEqual(LIMITS.photoPrompt);
    expect(long.startsWith(c.prompt.slice(0, -1) + " ")).toBe(true);
  });

  it("drops the broken word when strict decoding stopped at maxLength", () => {
    const stopped = "ატვირთე დედაპლატის, RAM-ებისა და პროცესორების წარწერების ახლ";
    expect(len(stopped)).toBe(60);
    const c = tidyContinuation({ kind: "needs_photo", prompt: stopped, reason: "r" }) as any;
    expect(c.prompt).toBe("ატვირთე დედაპლატის, RAM-ებისა და პროცესორების წარწერების…");
    // A full sentence of exactly 60 stays as it is.
    const full = "ა".repeat(58) + "ბ.";
    expect((tidyContinuation({ kind: "needs_photo", prompt: full, reason: "r" }) as any).prompt).toBe(full);
    // Shorter than the cap: untouched.
    const short = "გადაიღე ჩაკეტილი სოკეტი";
    expect((tidyContinuation({ kind: "needs_photo", prompt: short, reason: "r" }, { capabilities: ["tools_v2"] }) as any).prompt).toBe(short);
  });
});

describe("clampText wordBoundary", () => {
  // The last space is at 45% of max: "soft" cuts mid-word, "always" at the word.
  const text = "ა".repeat(9) + " " + "ბ".repeat(30);
  it("soft is unchanged, always cuts past 40%", () => {
    expect(clampText(text, 20)).toBe("ა".repeat(9) + " " + "ბ".repeat(9) + "…");
    expect(clampText(text, 20, "soft")).toBe(clampText(text, 20));
    expect(clampText(text, 20, "always")).toBe("ა".repeat(9) + "…");
    // Below 40% even "always" falls back to characters.
    expect(clampText("ა ბბბბბბბბბბბბბბბბბბბბ", 10, "always")).toBe("ა ბბბბბბბ…");
  });
});
