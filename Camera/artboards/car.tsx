// @device: mobile
import { useState } from "react";
import { motion } from "motion/react";
import { AnimatePresence } from "motion/react";
import { useReducedMotion } from "motion/react";
import { Glass } from "./design-system";
import { Icon } from "./design-system";
import { IconButton } from "./design-system";
import { Marker } from "./design-system";
import { MeshWrap } from "./design-system";
import { MoveArrow } from "./design-system";
import { MoveArrowHead } from "./design-system";
import { TrackedFeed } from "./design-system";
import { TrackingChip } from "./design-system";
import { TurnArrow } from "./design-system";

// Engine bay parts in photo pixels (941×1672).
const COVER = 0;
const CAP = 1;
const DIP = 2;
const COOLANT = 3;
const WASHER = 4;
const BATTERY = 5;
const parts = [
  "M235 385 L655 385 L695 440 L695 600 L640 660 L560 680 L230 670 Q198 640 198 600 L200 450 Z",
  "M446 515 A54 54 0 1 0 554 515 A54 54 0 1 0 446 515 Z",
  "M550 616 Q552 606 575 606 Q598 606 598 625 L591 655 L583 664 L583 702 L563 702 L563 664 L555 655 Z",
  "M0 300 Q0 255 40 245 L65 228 L180 228 L185 290 Q215 295 215 330 L215 400 Q210 440 170 442 L30 442 Q0 440 0 410 Z",
  "M22 735 Q30 710 80 708 Q135 712 142 740 L135 770 L132 870 L45 870 L40 770 Z",
  "M830 245 L941 245 L941 505 L830 505 Z",
];

// Marker coordinates are % of the photo.
type Step = {
  title: string;
  text: string;
  focus: number[];
  avoid?: number[];
  pan: number;
  markers: { x: number; y: number; label: string; side?: "left" | "right"; danger?: boolean }[];
  pull?: boolean;
  turn?: { x: number; y: number; size: number; dir: "cw" | "ccw" };
  gauge?: boolean;
  chips?: string[];
  tip?: string;
  warn?: string;
};

const steps: Step[] = [
  {
    title: "იპოვე ზეთის საზომი",
    text: "ყვითელი რგოლი ძრავის საფარის ქვემოთ. ეს არის ზეთის საზომი ღერო.",
    focus: [DIP],
    pan: 0,
    markers: [{ x: 66.5, y: 37, label: "ზეთის საზომი" }],
    tip: "ძრავი გამორთული უნდა იყოს და 5 წუთი გაცივებული, მანქანა სწორ ზედაპირზე.",
  },
  {
    title: "ამოიღე და გაწმინდე",
    text: "ამოსწიე ღერო ბოლომდე, მშრალი ხელსახოცით გაწმინდე და ისევ ბოლომდე ჩადე.",
    focus: [DIP],
    pan: 0,
    markers: [],
    pull: true,
    chips: ["ქაღალდის ხელსახოცი"],
  },
  {
    title: "წაიკითხე დონე",
    text: "კიდევ ერთხელ ამოიღე. ზეთის კვალი ორ ნიშნულს შორის უნდა იყოს.",
    focus: [DIP],
    pan: 0,
    markers: [{ x: 66.5, y: 37, label: "ამოიღე" }],
    gauge: true,
  },
  {
    title: "დაამატე ზეთი",
    text: "თუ დონე MIN-თან ახლოსაა, მოხსენი ეს ხუფი საათის ისრის საწინააღმდეგოდ და ჩაასხი 200 მლ, შემდეგ გადაამოწმე.",
    focus: [CAP],
    avoid: [COOLANT, WASHER],
    pan: -60,
    markers: [
      { x: 2, y: 17, label: "ანტიფრიზი · არა", danger: true },
      { x: 2, y: 43, label: "მინის სითხე · არა", danger: true },
    ],
    turn: { x: 53.1, y: 30.8, size: 74, dir: "ccw" },
    tip: "ზეთის ტიპი მანქანის წიგნაკშია, მაგალითად 5W-30.",
  },
  {
    title: "დახურე და გადაამოწმე",
    text: "ხუფი მოუჭირე ბოლომდე, საზომი ღერო ჩადე თავის ადგილას. 2 წუთის შემდეგ კიდევ ერთხელ შეამოწმე დონე.",
    focus: [CAP, DIP],
    pan: 0,
    markers: [],
    turn: { x: 53.1, y: 30.8, size: 74, dir: "cw" },
    warn: "MAX-ს ნუ გადააცილებ: ზედმეტი ზეთი ძრავს ისევე ავნებს, როგორც ნაკლები.",
  },
];

// Dipstick read-out: the oily part ends between MIN and MAX.
function Gauge() {
  return (
    <svg viewBox="0 0 320 64" className="mt-3 w-full" role="img" aria-label="ზეთის კვალი MIN და MAX ნიშნულებს შორის">
      <rect x="8" y="26" width="304" height="10" rx="5" fill="var(--color-ink-200)" />
      <rect x="150" y="22" width="110" height="18" rx="4" fill="var(--color-success-500, #22c55e)" fillOpacity="0.18" />
      <rect x="8" y="26" width="214" height="10" rx="5" fill="var(--color-warning-700, #a16207)" fillOpacity="0.85" />
      <line x1="150" y1="16" x2="150" y2="46" stroke="var(--color-ink-700)" strokeWidth="2" />
      <line x1="260" y1="16" x2="260" y2="46" stroke="var(--color-ink-700)" strokeWidth="2" />
      <text x="150" y="60" textAnchor="middle" fontSize="12" fontWeight="600" fill="var(--color-ink-600)">MIN</text>
      <text x="260" y="60" textAnchor="middle" fontSize="12" fontWeight="600" fill="var(--color-ink-600)">MAX</text>
      <text x="222" y="12" textAnchor="middle" fontSize="11.5" fontWeight="600" fill="var(--color-brand-600)">ნორმა ✓</text>
    </svg>
  );
}

export default function Car() {
  const reduce = useReducedMotion();
  const [scanned, setScanned] = useState(Boolean(reduce));
  const [index, setIndex] = useState(0);
  const step = steps[index];
  const last = index === steps.length - 1;
  const swap = {
    initial: reduce ? { opacity: 0 } : { opacity: 0, y: 8 },
    animate: { opacity: 1, y: 0 },
    exit: reduce ? { opacity: 0 } : { opacity: 0, y: -6 },
    transition: { duration: reduce ? 0.1 : 0.2, ease: "easeOut" as const },
  };

  return (
    <div className="flex min-h-screen flex-col overflow-hidden bg-surface font-sans text-ink-900">
      <header
        className="flex items-center gap-2 px-4 pb-2.5"
        style={{ paddingTop: "calc(var(--safe-area-inset-top, 54px) + 8px)" }}
      >
        <IconButton label="დახურვა">
          <Icon name="close" />
        </IconButton>
        <div className="flex min-w-0 flex-1 items-center justify-center gap-2" aria-live="polite">
          <span className="relative flex h-2.5 w-2.5">
            {!reduce && (
              <span className="absolute inline-flex h-full w-full animate-ping rounded-pill bg-brand-400 opacity-60" />
            )}
            <span className="relative inline-flex h-2.5 w-2.5 rounded-pill bg-brand-500" />
          </span>
          <span className="truncate text-[14px] font-semibold">
            {scanned ? "ზეთის შემოწმება" : "სკანირება…"}
          </span>
        </div>
        <IconButton label="ფლეში">
          <Icon name="flash" />
        </IconButton>
      </header>

      <div className="relative flex-1 overflow-hidden rounded-t-card bg-ink-800">
        <TrackedFeed src="/assets/car-engine.png" aspect="941 / 1672" zoom={1.05} pan={scanned ? step.pan : 0}>
          <MeshWrap
            width={941}
            height={1672}
            parts={parts}
            focus={step.focus}
            avoid={step.avoid}
            scanTo={900}
            onScanned={() => setScanned(true)}
          />

          <AnimatePresence>
            {scanned &&
              step.markers.map((m, i) => (
                <Marker
                  key={`${index}-${i}`}
                  x={m.x}
                  y={m.y}
                  n={m.danger ? "✕" : i + 1}
                  label={m.label}
                  side={m.side}
                  tone={m.danger ? "danger" : "brand"}
                  index={i}
                />
              ))}
          </AnimatePresence>

          {scanned && step.pull && (
            <>
              <MoveArrow x={61} y1={35} y2={21} />
              <MoveArrowHead x={61} y={21} dir="up" />
            </>
          )}
          {scanned && step.turn && <TurnArrow key={`turn-${index}`} {...step.turn} />}
        </TrackedFeed>

        <div className="pointer-events-none absolute left-3 top-3">
          <TrackingChip text={scanned ? "მიყვება ძრავს" : "ვასკანერებ…"} />
        </div>

        <div
          className="absolute inset-x-0 bottom-0 px-3"
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
                <span className="text-[12px] font-medium text-ink-500">ძრავის განყოფილება · ~5 წთ</span>
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
                    {step.gauge && <Gauge />}
                    {step.chips && (
                      <div className="mt-3 flex flex-wrap gap-1.5">
                        {step.chips.map((c) => (
                          <span
                            key={c}
                            className="rounded-pill border border-ink-200 bg-white px-2.5 py-1 text-[12.5px] font-medium text-ink-700"
                          >
                            {c}
                          </span>
                        ))}
                      </div>
                    )}
                    {step.tip && (
                      <p className="mt-3 rounded-field bg-brand-50 px-3 py-2 text-[12.5px] leading-snug text-brand-800">
                        {step.tip}
                      </p>
                    )}
                    {step.warn && (
                      <p className="mt-3 rounded-field bg-danger-50 px-3 py-2 text-[12.5px] leading-snug text-danger-700">
                        {step.warn}
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
    </div>
  );
}
