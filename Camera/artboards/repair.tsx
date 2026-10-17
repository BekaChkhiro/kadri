// @device: mobile
import { useState } from "react";
import { motion } from "motion/react";
import { AnimatePresence } from "motion/react";
import { useReducedMotion } from "motion/react";
import { EdgeHint } from "./design-system";
import { Glass } from "./design-system";
import { Icon } from "./design-system";
import { IconButton } from "./design-system";
import { Target } from "./design-system";
import { TurnArrow } from "./design-system";
import { TrackedFeed } from "./design-system";
import { MeshWrap } from "./design-system";

// Coordinates are percentages of the photo (2:3), the same space the detector reports in.
type Step = {
  title: string;
  text: string;
  tools: string[];
  targets: { box: { left: number; top: number; width: number; height: number }; label: string; dashed?: boolean }[];
  turn?: { x: number; y: number; size: number; dir: "cw" | "ccw" };
  hint?: { side: "left" | "right" | "up" | "down"; text: string };
  note?: string;
  /** mesh parts lit in this step */
  focus: number[];
  /** camera tilt (px) so the focused parts sit above the card */
  pan: number;
};

// Under-sink parts in photo pixels (1024×1536) for the wrapping mesh.
const TAILPIPE = 0;
const TRAP = 1;
const NUT = 2;
const WALL = 3;
const VALVE_R = 4;
const VALVE_L = 5;
const parts = [
  "M278 140 L498 140 L498 246 L466 250 L466 380 L318 380 L318 250 L278 246 Z",
  "M318 380 L466 380 L466 560 Q500 628 537 560 L537 470 Q560 412 636 398 L640 578 L656 600 C656 765 318 765 318 600 Z",
  "M636 392 L762 392 L765 578 L640 578 Z",
  "M765 396 L880 396 L880 296 L1000 296 L1000 612 L880 612 L880 552 L765 552 Z",
  "M228 330 L322 330 L326 505 L230 505 Z",
  "M10 362 L150 362 L152 500 L12 500 Z",
];

const steps: Step[] = [
  {
    title: "დაკეტე წყალი",
    text: "მოატრიალე ონკანი საათის ისრის მიმართულებით ბოლომდე. შემდეგ მეორეც დაკეტე.",
    tools: [],
    targets: [{ box: { left: 21, top: 21, width: 11, height: 12.5 }, label: "ონკანი" }],
    turn: { x: 26.8, y: 27.2, size: 92, dir: "cw" },
    hint: { side: "left", text: "მეორე ონკანი მარცხნივაა" },
    focus: [VALVE_R, VALVE_L],
    pan: 0,
  },
  {
    title: "ჩადგი ვედრო სიფონის ქვეშ",
    text: "სიფონში წყალი დგას. გახსნისას ჩამოიღვრება, ამიტომ ვედრო ან ღრმა თასი პირდაპირ მის ქვეშ დადგი.",
    tools: ["ვედრო", "ტილო"],
    targets: [{ box: { left: 27, top: 50.5, width: 46, height: 9 }, label: "ვედრო აქ", dashed: true }],
    focus: [TRAP],
    pan: -70,
  },
  {
    title: "მოუშვი ქანჩი",
    text: "ეს ქანჩი ჟონავს. ხელით მოუშვი საათის ისრის საწინააღმდეგოდ. პლასტმასისაა, გასაღები არ დაგჭირდება.",
    tools: ["ხელთათმანი"],
    targets: [{ box: { left: 61.5, top: 24.5, width: 14, height: 13.5 }, label: "ქანჩი · ჟონავს" }],
    turn: { x: 68.5, y: 31, size: 118, dir: "ccw" },
    focus: [NUT],
    pan: 0,
  },
  {
    title: "შეამოწმე შუასადები",
    text: "მოხსენი სიფონი და ნახე ქანჩის შიგნით რეზინის რგოლი. თუ დაბზარულია ან გვერდზეა გადაწეული, შეცვალე. ზომა: 40 მმ.",
    tools: ["შუასადები 40 მმ"],
    targets: [{ box: { left: 30, top: 22.5, width: 37, height: 27 }, label: "სიფონი" }],
    note: "მაღაზიაში წაიღე ძველი შუასადები, ზომის შესადარებლად",
    focus: [TRAP, NUT],
    pan: 0,
  },
  {
    title: "მოუჭირე და შეამოწმე",
    text: "ხელით მოუჭირე ბოლომდე, შემდეგ კიდევ მეოთხედი ბრუნი. გახსენი წყალი და ერთი წუთი დააკვირდი.",
    tools: [],
    targets: [{ box: { left: 61.5, top: 24.5, width: 14, height: 13.5 }, label: "ქანჩი" }],
    turn: { x: 68.5, y: 31, size: 118, dir: "cw" },
    focus: [NUT, WALL],
    pan: 0,
  },
];

export default function Repair() {
  const reduce = useReducedMotion();
  const [index, setIndex] = useState(0);
  const [scanned, setScanned] = useState(Boolean(reduce));
  const step = steps[index];
  const last = index === steps.length - 1;
  const swap = {
    initial: reduce ? { opacity: 0 } : { opacity: 0, y: 8 },
    animate: { opacity: 1, y: 0 },
    exit: reduce ? { opacity: 0 } : { opacity: 0, y: -6 },
    transition: { duration: reduce ? 0.1 : 0.2, ease: "easeOut" as const },
  };

  return (
    <div className="relative flex min-h-screen flex-col overflow-hidden bg-ink-200 font-sans text-ink-900">
      {/* camera feed + AR layer share the photo's coordinate space */}
      <TrackedFeed src="/assets/sink-trap.png" aspect="2 / 3" pan={scanned ? step.pan : 0}>
        <MeshWrap
          width={1024}
          height={1536}
          parts={parts}
          focus={step.focus}
          scanFrom={120}
          scanTo={780}
          onScanned={() => setScanned(true)}
        />
        <AnimatePresence>
          {scanned &&
            step.targets.map((t) => (
              <Target
                key={`${index}-${t.label}`}
                box={t.box}
                label={t.label}
                dashed={t.dashed}
                bare={!t.dashed}
                labelBelow={Boolean(step.turn)}
              />
            ))}
        </AnimatePresence>
        {scanned && step.turn && <TurnArrow key={`turn-${index}`} {...step.turn} />}
      </TrackedFeed>
      <div className="pointer-events-none absolute inset-x-0 top-0 h-36 bg-gradient-to-b from-black/30 to-transparent" />

      <AnimatePresence>
        {scanned && step.hint && <EdgeHint key={`hint-${index}`} {...step.hint} />}
      </AnimatePresence>

      {/* top bar */}
      <header
        className="relative z-10 flex items-center gap-2 px-4"
        style={{ paddingTop: "calc(var(--safe-area-inset-top, 54px) + 8px)" }}
      >
        <IconButton label="დახურვა">
          <Icon name="close" />
        </IconButton>
        <Glass className="flex min-w-0 flex-1 items-center gap-2.5 rounded-pill py-1.5 pl-1.5 pr-4">
          <span className="grid h-8 w-8 shrink-0 place-items-center rounded-pill bg-brand-500 text-white">
            <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M14.5 6.5a4 4 0 0 0-5.3 5.3L4 17l3 3 5.2-5.2a4 4 0 0 0 5.3-5.3l-2.6 2.6-2.4-.6-.6-2.4 2.6-2.6Z" />
            </svg>
          </span>
          <span className="min-w-0 leading-tight">
            <span className="block truncate text-[14px] font-semibold">ნიჟარა ჟონავს</span>
            <span className="block truncate text-[12px] text-ink-500">სიფონის შეკეთება · ~15 წთ</span>
          </span>
        </Glass>
        <IconButton label="ფლეში">
          <Icon name="flash" />
        </IconButton>
      </header>

      <div className="flex-1" />

      {/* step card */}
      <div
        className="relative z-10 px-3"
        style={{ paddingBottom: "calc(var(--safe-area-inset-bottom, 34px) + 8px)" }}
      >
        <motion.div
          data-anim="sheet"
          initial={reduce ? { opacity: 0 } : { opacity: 0, y: 24 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: reduce ? 0.15 : 0.3, ease: "easeOut" }}
        >
          <Glass className="rounded-card p-4">
            <div className="flex items-center justify-between">
              <span className="text-[13px] font-semibold text-brand-600">
                ნაბიჯი {index + 1} / {steps.length}
              </span>
              <span className="flex items-center gap-1.5 text-[12px] font-medium text-ink-500">
                <span className="h-1.5 w-1.5 rounded-pill bg-brand-500" />
                კამერა ხედავს სიფონს
              </span>
            </div>
            <div className="mt-2.5 flex gap-1" aria-hidden="true">
              {steps.map((_, i) => (
                <span
                  key={i}
                  className={`h-1 flex-1 rounded-pill transition-colors duration-200 ${
                    i <= index ? "bg-brand-500" : "bg-ink-900/10"
                  }`}
                />
              ))}
            </div>

            <div aria-live="polite" className="min-h-[150px]">
              <AnimatePresence mode="wait" initial={false}>
                <motion.div key={index} data-anim="step" {...swap}>
                  <h2 className="mt-3.5 text-[21px] font-semibold leading-snug tracking-tight">{step.title}</h2>
                  <p className="mt-1.5 text-[14.5px] leading-relaxed text-ink-600">{step.text}</p>
                  {step.tools.length > 0 && (
                    <div className="mt-3 flex flex-wrap gap-1.5">
                      {step.tools.map((t) => (
                        <span
                          key={t}
                          className="rounded-pill border border-ink-200 bg-white px-2.5 py-1 text-[12.5px] font-medium text-ink-700"
                        >
                          {t}
                        </span>
                      ))}
                    </div>
                  )}
                  {step.note && (
                    <p className="mt-3 rounded-field bg-brand-50 px-3 py-2 text-[12.5px] leading-snug text-brand-800">
                      {step.note}
                    </p>
                  )}
                </motion.div>
              </AnimatePresence>
            </div>

            <div className="mt-4 flex items-center gap-2">
              <motion.button
                type="button"
                aria-label="ჰკითხე ხმით"
                data-anim="press"
                whileTap={{ scale: 0.94 }}
                transition={{ duration: 0.12 }}
                className="grid h-12 w-12 shrink-0 place-items-center rounded-btn bg-ink-900/5 text-ink-800"
              >
                <Icon name="mic" />
              </motion.button>
              <motion.button
                type="button"
                data-anim="press"
                whileTap={{ scale: 0.97 }}
                transition={{ duration: 0.12 }}
                disabled={index === 0}
                onClick={() => setIndex((i) => Math.max(0, i - 1))}
                className="h-12 rounded-btn bg-ink-900/5 px-4 text-[14.5px] font-semibold text-ink-800 disabled:opacity-40"
              >
                უკან
              </motion.button>
              <motion.button
                type="button"
                data-anim="press"
                whileTap={{ scale: 0.97 }}
                transition={{ duration: 0.12 }}
                onClick={() => setIndex((i) => (last ? 0 : i + 1))}
                className="flex h-12 flex-1 items-center justify-center gap-2 rounded-btn bg-brand-500 text-[14.5px] font-semibold text-white shadow-pop"
              >
                {last ? "დასრულდა" : "შესრულდა"}
                {!last && <Icon name="arrow" className="h-4 w-4" />}
              </motion.button>
            </div>
          </Glass>
        </motion.div>
      </div>
    </div>
  );
}
