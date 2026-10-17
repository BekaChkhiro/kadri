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

// Machine silhouette in photo pixels (941×1672), part by part.
const BAR = 0;
const UPRIGHTS = 1;
const CABLE = 2;
const STACK = 3;
const PADS = 4;
const SEAT = 5;
const BASE = 6;
const POST = 7;
const machine = [
  "M95 182 Q98 162 138 152 L432 118 L542 118 L800 150 Q842 160 842 186 L832 196 L792 176 L542 142 L432 142 L142 176 L104 196 Z",
  "M345 0 L392 0 L392 930 L345 930 Z M553 0 L600 0 L600 930 L553 930 Z",
  "M452 0 L492 0 L492 485 L452 485 Z",
  "M406 485 L540 485 L540 772 L406 772 Z",
  "M300 695 Q300 650 345 650 L598 650 Q640 650 640 695 Q640 740 598 740 L345 740 Q300 740 300 695 Z",
  "M352 822 Q352 790 392 790 L548 790 Q588 790 588 822 L588 856 Q588 886 548 886 L392 886 Q352 886 352 856 Z",
  "M256 975 L272 922 L668 922 L680 975 Z",
  "M440 886 L500 886 L502 1076 L434 1076 Z",
];

// Marker coordinates are % of the photo.
type Step = {
  title: string;
  text: string;
  focus: number[];
  /** camera tilt (px) so the focused parts sit above the card */
  pan: number;
  markers: { x: number; y: number; label: string; side?: "left" | "right" }[];
  move?: boolean;
  chips?: string[];
  tip?: string;
  warn?: string;
};

const steps: Step[] = [
  {
    title: "დაარეგულირე სიმაღლე",
    text: "გამოსწიე ყვითელი ღილაკი სავარძლის ქვეშ და ისე დააყენე, რომ ჯდომისას მუხლები ბალიშების ქვეშ მჭიდროდ მოექცეს.",
    focus: [PADS, SEAT, POST],
    pan: -190,
    markers: [
      { x: 49.5, y: 56.5, label: "ღილაკი" },
      { x: 62, y: 41.5, label: "ბალიშები" },
    ],
  },
  {
    title: "აირჩიე წონა",
    text: "ყვითელი ქინძისთავი გადაიტანე სასურველ ფილაში და ბოლომდე ჩაარჭე.",
    focus: [STACK],
    pan: -40,
    markers: [{ x: 55, y: 33.4, label: "ქინძისთავი" }],
    tip: "პირველად დაიწყე 20–25 კგ-ით. ბოლო 2 გამეორება რთული უნდა იყოს, მაგრამ შესრულებადი.",
  },
  {
    title: "მოკიდე სახელურს",
    text: "ფეხზე მდგომმა მოკიდე ხელი მოხრილ ბოლოებთან, მხრებზე ოდნავ ფართოდ, ხელისგულები წინ.",
    focus: [BAR],
    pan: 0,
    markers: [
      { x: 15, y: 9.5, label: "ხელი აქ", side: "right" },
      { x: 85, y: 9.5, label: "ხელი აქ", side: "left" },
    ],
  },
  {
    title: "დაჯექი და დაფიქსირდი",
    text: "სახელურით ხელში დაჯექი, ფეხები იატაკზე, მუხლები ბალიშების ქვეშ. მკერდი წინ, ზურგი სწორი.",
    focus: [SEAT, PADS],
    pan: -130,
    markers: [{ x: 62, y: 41.5, label: "მუხლები აქ" }],
  },
  {
    title: "ჩამოწიე მკერდამდე",
    text: "იდაყვები ქვემოთ და უკან, სახელური მკერდის ზედა ნაწილამდე. ზემოთ ნელა აუშვი, 2 წამში.",
    focus: [BAR, CABLE],
    pan: 0,
    markers: [],
    move: true,
    chips: ["3 სეტი", "10–12 გამეორება", "60–90 წმ დასვენება"],
    warn: "სახელური კისრის უკან არ ჩამოწიო და ზურგით უკან არ გადაიხარო.",
  },
];

export default function Gym() {
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
      {/* top strip, above the feed like a camera app */}
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
            {scanned ? "ზედა ბლოკის წევა" : "სკანირება…"}
          </span>
        </div>
        <IconButton label="ფლეში">
          <Icon name="flash" />
        </IconButton>
      </header>

      {/* camera feed + AR layer */}
      <div className="relative flex-1 overflow-hidden rounded-t-card bg-ink-300">
        <TrackedFeed src="/assets/gym-lat-pulldown.png" aspect="941 / 1672" zoom={1.2} pan={scanned ? step.pan : 0}>
          <MeshWrap
            width={941}
            height={1672}
            parts={machine}
            focus={step.focus}
            scanTo={1080}
            onScanned={() => setScanned(true)}
          />

          <AnimatePresence>
            {scanned &&
              step.markers.map((m, i) => (
                <Marker
                  key={`${index}-${i}`}
                  x={m.x}
                  y={m.y}
                  n={i + 1}
                  label={m.label}
                  side={m.side}
                  index={i}
                />
              ))}
          </AnimatePresence>

          {scanned && step.move && (
            <>
              <MoveArrow x={20} y1={14} y2={30} />
              <MoveArrow x={80} y1={14} y2={30} />
              <MoveArrowHead x={20} y={30} />
              <MoveArrowHead x={80} y={30} />
            </>
          )}
        </TrackedFeed>

        <div className="pointer-events-none absolute left-3 top-3">
          <TrackingChip text={scanned ? "მიყვება ტრენაჟორს" : "ვასკანერებ…"} />
        </div>

        {/* step card */}
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
                <span className="text-[12px] font-medium text-ink-500">Lat pulldown · ზურგი, ბიცეფსი</span>
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
                  {last ? "დაიწყე სეტი" : "შესრულდა"}
                  <Icon name="arrow" className="h-4 w-4" />
                </motion.button>
              </div>
            </Glass>
          </motion.div>
        </div>
      </div>
    </div>
  );
}
