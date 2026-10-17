import { motion } from "motion/react";
import { useReducedMotion } from "motion/react";
import type { ReactNode } from "react";
import { useState } from "react";
import { useId } from "react";

// Wireframe mesh wrapped around an object's silhouette. Paths are in photo pixels
// (viewBox = photo size) so the mesh cells stay square.
// 1. Scan: a line sweeps down and lays the mesh over every part, outlines draw.
// 2. Focus: once scanned, only the parts in `focus` stay lit (stronger fill, glow);
//    the rest fade to a faint outline and the frame dims around the focused parts.
// It rides with the feed. Reduced motion: complete at once, focus changes are instant.
export function MeshWrap({
  width,
  height,
  parts,
  focus = [],
  avoid = [],
  scanFrom = 0,
  scanTo,
  cell = 26,
  onScanned,
}: {
  width: number;
  height: number;
  parts: string[];
  focus?: number[];
  /** parts lit in red: "not this one" */
  avoid?: number[];
  scanFrom?: number;
  scanTo?: number;
  cell?: number;
  onScanned?: () => void;
}) {
  const reduce = useReducedMotion();
  const id = useId().replace(/:/g, "");
  const end = scanTo ?? height;
  const [scanned, setScanned] = useState(Boolean(reduce));
  const focusing = scanned && focus.length + avoid.length > 0;
  const spot = [...focus, ...avoid];
  const sweep = { duration: 1.3, ease: "easeInOut" as const };
  const fade = { duration: reduce ? 0 : 0.35, ease: "easeOut" as const };
  return (
    <svg
      aria-hidden="true"
      viewBox={`0 0 ${width} ${height}`}
      className="pointer-events-none absolute inset-0 h-full w-full overflow-visible"
      preserveAspectRatio="none"
    >
      <defs>
        <pattern id={`grid-${id}`} width={cell} height={cell} patternUnits="userSpaceOnUse">
          <path
            d={`M0 0H${cell}M0 0V${cell}M0 ${cell}L${cell} 0`}
            fill="none"
            stroke="white"
            strokeWidth={1.4}
            strokeOpacity={0.75}
          />
        </pattern>
        {parts.map((d, i) => (
          <clipPath key={i} id={`part-${id}-${i}`}>
            <path d={d} />
          </clipPath>
        ))}
        <filter
          id={`soft-${id}`}
          filterUnits="userSpaceOnUse"
          x={-width}
          y={-height}
          width={width * 3}
          height={height * 3}
        >
          <feGaussianBlur stdDeviation={18} />
        </filter>
        <mask id={`spot-${id}`} maskUnits="userSpaceOnUse" x={-width} y={-height} width={width * 3} height={height * 3}>
          <rect x={-width} y={-height} width={width * 3} height={height * 3} fill="white" />
          <g filter={`url(#soft-${id})`}>
            {spot.map((i) => (
              <path key={i} d={parts[i]} fill="black" stroke="black" strokeWidth={60} strokeLinejoin="round" />
            ))}
          </g>
        </mask>
        <mask id={`reveal-${id}`} maskUnits="userSpaceOnUse" x={0} y={0} width={width} height={height}>
          <motion.rect
            data-anim="mesh"
            width={width}
            height={end}
            fill="white"
            style={{ transformOrigin: "50% 0%" }}
            initial={reduce ? false : { scaleY: 0 }}
            animate={{ scaleY: 1 }}
            transition={reduce ? { duration: 0 } : sweep}
            onAnimationComplete={() => {
              setScanned(true);
              onScanned?.();
            }}
          />
        </mask>
      </defs>

      {/* spotlight: dim the frame around the focused parts */}
      <motion.rect
        data-anim="mesh"
        x={-width}
        y={-height}
        width={width * 3}
        height={height * 3}
        fill="rgb(2 6 23)"
        mask={`url(#spot-${id})`}
        initial={false}
        animate={{ opacity: focusing ? 0.45 : 0 }}
        transition={fade}
      />

      <g mask={`url(#reveal-${id})`}>
        {parts.map((_, i) => {
          const lit = spot.includes(i);
          const bad = focusing && avoid.includes(i);
          return (
            <motion.g
              key={i}
              data-anim="mesh"
              clipPath={`url(#part-${id}-${i})`}
              initial={false}
              animate={{ opacity: !focusing || lit ? 1 : 0.15 }}
              transition={fade}
            >
              <rect
                width={width}
                height={height}
                fill={bad ? "rgb(239 68 68 / 0.42)" : focusing && lit ? "rgb(47 107 255 / 0.38)" : "rgb(47 107 255 / 0.22)"}
              />
              <rect width={width} height={height} fill={`url(#grid-${id})`} />
            </motion.g>
          );
        })}
      </g>

      {parts.map((d, i) => {
        const lit = focusing && spot.includes(i);
        const glow = focusing && avoid.includes(i) ? "239 68 68" : "47 107 255";
        return (
          <motion.path
            key={i}
            data-anim="mesh"
            d={d}
            fill="none"
            stroke="white"
            strokeLinejoin="round"
            style={{
              filter: lit
                ? `drop-shadow(0 0 10px rgb(${glow})) drop-shadow(0 0 3px rgb(${glow}))`
                : "drop-shadow(0 0 6px rgb(47 107 255 / 0.9))",
            }}
            initial={reduce ? false : { pathLength: 0, opacity: 0 }}
            animate={{
              pathLength: 1,
              opacity: focusing && !lit ? 0.3 : 1,
              strokeWidth: lit ? 5 : 3,
            }}
            transition={
              reduce
                ? { duration: 0 }
                : scanned
                  ? fade
                  : { duration: 0.9, ease: "easeInOut", delay: 0.2 + i * 0.08 }
            }
          />
        );
      })}

      {!reduce && (
        <motion.rect
          data-anim="mesh"
          width={width}
          height={5}
          rx={2.5}
          fill="white"
          style={{ filter: "drop-shadow(0 0 10px rgb(47 107 255))" }}
          initial={{ y: scanFrom, opacity: 1 }}
          animate={{ y: end, opacity: [1, 1, 0] }}
          transition={{ ...sweep, opacity: { ...sweep, times: [0, 0.85, 1] } }}
        />
      )}
    </svg>
  );
}

// Live camera feed. The photo and every AR mark live in one "world" layer, so whatever
// moves the camera (handheld sway, the person's drag) moves the marks with their objects.
// Children position themselves in % of the photo. Reduced motion: no sway, drag stays.
export function TrackedFeed({
  src,
  aspect,
  zoom = 1.12,
  pan = 0,
  children,
}: {
  src: string;
  aspect: string;
  zoom?: number;
  /** vertical camera tilt in px, so the focused part sits in the clear area above the card */
  pan?: number;
  children?: ReactNode;
}) {
  const reduce = useReducedMotion();
  const [dragging, setDragging] = useState(false);
  const sway = {
    x: [0, -14, 9, -7, 4, 0],
    y: [0, 7, -6, 9, -4, 0],
    rotate: [0, -0.7, 0.4, 0.6, -0.3, 0],
  };
  return (
    <div className="absolute inset-0 overflow-hidden" style={{ touchAction: "none" }}>
      <motion.div
        data-anim="camera-drag"
        drag
        dragConstraints={{ left: -36, right: 36, top: -70, bottom: 12 }}
        dragElastic={reduce ? 0 : 0.15}
        dragMomentum={!reduce}
        onDragStart={() => setDragging(true)}
        onDragEnd={() => setDragging(false)}
        className="absolute left-1/2 top-0 cursor-grab active:cursor-grabbing"
        style={{ height: `${zoom * 100}%`, aspectRatio: aspect, translate: "-50% 0" }}
      >
        <motion.div
          data-anim="camera-pan"
          className="absolute inset-0"
          initial={false}
          animate={{ y: pan }}
          transition={{ duration: reduce ? 0 : 0.6, ease: "easeInOut" }}
        >
          <motion.div
            data-anim="camera-sway"
            className="absolute inset-0"
            animate={reduce || dragging ? { x: 0, y: 0, rotate: 0 } : sway}
            transition={
              reduce || dragging
                ? { duration: reduce ? 0 : 0.4, ease: "easeOut" }
                : { duration: 10, ease: "easeInOut", repeat: Infinity }
            }
          >
            <img src={src} alt="" draggable={false} className="h-full w-full select-none object-cover" />
            {children}
          </motion.div>
        </motion.div>
      </motion.div>
    </div>
  );
}

// Small status chip: the marks are locked to their objects.
export function TrackingChip({ text }: { text: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-pill bg-ink-900/55 px-2.5 py-1 text-[12px] font-semibold text-white backdrop-blur-xl">
      <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" {...stroke} strokeWidth={2.2} aria-hidden="true">
        <path d="M4 8V5.5A1.5 1.5 0 0 1 5.5 4H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16" />
        <circle cx="12" cy="12" r="2.5" />
      </svg>
      {text}
    </span>
  );
}

// Frosted light glass used for every panel that sits on top of the camera feed.
export function Glass({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={`border border-white/60 bg-white/75 shadow-card backdrop-blur-xl ${className}`}
    >
      {children}
    </div>
  );
}

export function IconButton({ label, children }: { label: string; children: ReactNode }) {
  return (
    <motion.button
      type="button"
      aria-label={label}
      data-anim="press"
      whileTap={{ scale: 0.94 }}
      transition={{ duration: 0.12 }}
      className="grid h-11 w-11 place-items-center rounded-pill border border-white/60 bg-white/75 text-ink-800 shadow-card backdrop-blur-xl"
    >
      {children}
    </motion.button>
  );
}

type Box = { left: number; top: number; width: number; height: number };

// Bounding box: thin white corner brackets, label chip on top.
// Selected box gets the brand outline and a soft tint.
export function DetectionBox({
  box,
  label,
  confidence,
  selected,
  index,
  onSelect,
}: {
  box: Box;
  label: string;
  confidence: number;
  selected: boolean;
  index: number;
  onSelect: () => void;
}) {
  const reduce = useReducedMotion();
  const corner = selected ? "border-brand-500" : "border-white";
  const size = "h-5 w-5";
  return (
    <motion.button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      aria-label={`${label}, ${confidence}%`}
      data-anim="detect"
      initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.92 }}
      animate={{ opacity: 1, scale: 1 }}
      transition={
        reduce
          ? { duration: 0.15 }
          : { type: "spring", stiffness: 400, damping: 30, delay: 0.15 + index * 0.06 }
      }
      className="absolute"
      style={{
        left: `${box.left}%`,
        top: `${box.top}%`,
        width: `${box.width}%`,
        height: `${box.height}%`,
      }}
    >
      <span
        className={`absolute inset-0 rounded-[18px] transition-colors duration-200 ${
          selected ? "bg-brand-500/10 ring-2 ring-brand-500" : "ring-1 ring-white/35"
        }`}
      />
      <span className={`absolute left-0 top-0 ${size} rounded-tl-[18px] border-l-[3px] border-t-[3px] ${corner}`} />
      <span className={`absolute right-0 top-0 ${size} rounded-tr-[18px] border-r-[3px] border-t-[3px] ${corner}`} />
      <span className={`absolute bottom-0 left-0 ${size} rounded-bl-[18px] border-b-[3px] border-l-[3px] ${corner}`} />
      <span className={`absolute bottom-0 right-0 ${size} rounded-br-[18px] border-b-[3px] border-r-[3px] ${corner}`} />
      <span
        className={`absolute -top-3 left-3 flex items-center gap-1.5 whitespace-nowrap rounded-pill px-2.5 py-1 text-[12px] font-semibold shadow-card transition-colors duration-200 ${
          selected ? "bg-brand-500 text-white" : "bg-white/90 text-ink-800 backdrop-blur-xl"
        }`}
      >
        {label}
        <span className={selected ? "text-brand-100" : "text-ink-400"}>{confidence}%</span>
      </span>
    </motion.button>
  );
}

// AR target for a repair step: brand outline (solid = part to touch, dashed = place something here).
export function Target({
  box,
  label,
  dashed = false,
  labelBelow = false,
  bare = false,
}: {
  box: Box;
  label: string;
  dashed?: boolean;
  labelBelow?: boolean;
  /** label only: the mesh already outlines the part */
  bare?: boolean;
}) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      data-anim="target"
      initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.94 }}
      animate={{ opacity: 1, scale: 1 }}
      exit={{ opacity: 0 }}
      transition={reduce ? { duration: 0.15 } : { type: "spring", stiffness: 380, damping: 30 }}
      className="pointer-events-none absolute"
      style={{ left: `${box.left}%`, top: `${box.top}%`, width: `${box.width}%`, height: `${box.height}%` }}
    >
      <span
        className={`absolute inset-0 rounded-[20px] ${
          bare
            ? "hidden"
            : dashed
            ? "border-2 border-dashed border-white bg-white/15"
            : "bg-brand-500/10 ring-[2.5px] ring-brand-500 shadow-[0_0_0_6px_rgb(47_107_255_/_0.18)]"
        }`}
      />
      <span
        className={`absolute ${labelBelow ? "-bottom-12" : "-top-3.5"} left-1/2 -translate-x-1/2 whitespace-nowrap rounded-pill px-3 py-1 text-[12.5px] font-semibold shadow-card ${
          dashed ? "bg-white text-ink-800" : "bg-brand-500 text-white"
        }`}
      >
        {label}
      </span>
    </motion.div>
  );
}

// Rotation hint drawn around a part. Arc draws, arrowhead lands, short pause, repeats.
// Reduced motion: complete static arrow.
export function TurnArrow({
  x,
  y,
  size,
  dir,
}: {
  x: number;
  y: number;
  size: number;
  dir: "cw" | "ccw";
}) {
  const reduce = useReducedMotion();
  const loop = { duration: 1.1, ease: "easeInOut" as const, repeat: Infinity, repeatDelay: 0.7 };
  return (
    <div
      aria-hidden="true"
      className="pointer-events-none absolute -translate-x-1/2 -translate-y-1/2"
      style={{ left: `${x}%`, top: `${y}%`, width: size, height: size }}
    >
      <svg
        viewBox="0 0 100 100"
        className="h-full w-full overflow-visible drop-shadow-[0_2px_6px_rgb(15_23_42_/_0.35)]"
        style={{ transform: dir === "ccw" ? "scaleX(-1)" : undefined }}
        fill="none"
        stroke="white"
        strokeWidth={6}
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <motion.path
          data-anim="turn"
          d="M10.5 64.4 A42 42 0 1 1 89.5 64.4"
          initial={reduce ? false : { pathLength: 0 }}
          animate={{ pathLength: 1 }}
          transition={reduce ? { duration: 0 } : loop}
        />
        <motion.path
          data-anim="turn"
          d="M97.1 58 L89.5 64.4 L87.7 54.6"
          initial={reduce ? false : { opacity: 0 }}
          animate={reduce ? { opacity: 1 } : { opacity: [0, 0, 1] }}
          transition={reduce ? { duration: 0 } : { ...loop, ease: "linear", times: [0, 0.8, 1] }}
        />
      </svg>
    </div>
  );
}

// Numbered pin on a part; the number matches a line in the card.
export function Marker({
  x,
  y,
  n,
  label,
  tone = "brand",
  index = 0,
  side = "right",
}: {
  x: number;
  y: number;
  n: number | string;
  label: string;
  tone?: "brand" | "danger";
  index?: number;
  side?: "left" | "right";
}) {
  const reduce = useReducedMotion();
  const dot = tone === "danger" ? "bg-danger-500" : "bg-brand-500";
  const halo = tone === "danger" ? "bg-danger-500/25" : "bg-brand-500/25";
  return (
    <motion.div
      data-anim="marker"
      initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.8 }}
      animate={{ opacity: 1, scale: 1 }}
      exit={{ opacity: 0 }}
      transition={
        reduce ? { duration: 0.15 } : { type: "spring", stiffness: 420, damping: 30, delay: index * 0.07 }
      }
      className={`pointer-events-none absolute flex items-center gap-1.5 ${side === "left" ? "flex-row-reverse" : ""}`}
      style={{ left: `${x}%`, top: `${y}%`, translate: side === "left" ? "calc(-100% + 14px) -50%" : "-14px -50%" }}
    >
      <span className="relative grid h-7 w-7 place-items-center">
        <span className={`absolute inset-0 rounded-pill ${halo}`} />
        <span className={`relative grid h-6 w-6 place-items-center rounded-pill border-2 border-white text-[12px] font-bold text-white shadow-card ${dot}`}>
          {n}
        </span>
      </span>
      <span className="whitespace-nowrap rounded-pill bg-white/90 px-2.5 py-1 text-[12.5px] font-semibold text-ink-800 shadow-card backdrop-blur-xl">
        {label}
      </span>
    </motion.div>
  );
}

// Straight movement path (pull / push): line draws, arrowhead lands, pause, repeat.
// Reduced motion: complete static arrow.
export function MoveArrow({
  x,
  y1,
  y2,
}: {
  x: number;
  y1: number;
  y2: number;
}) {
  const reduce = useReducedMotion();
  const loop = { duration: 1.2, ease: "easeInOut" as const, repeat: Infinity, repeatDelay: 0.6 };
  return (
    <svg
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 h-full w-full overflow-visible drop-shadow-[0_2px_6px_rgb(15_23_42_/_0.35)]"
      viewBox="0 0 100 100"
      preserveAspectRatio="none"
    >
      <line x1={x} y1={y1} x2={x} y2={y2} stroke="white" strokeOpacity={0.35} strokeWidth={6} strokeLinecap="round" vectorEffect="non-scaling-stroke" strokeDasharray="2 10" />
      <motion.line
        data-anim="move"
        x1={x}
        y1={y1}
        x2={x}
        y2={y2}
        stroke="white"
        strokeWidth={6}
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
        initial={reduce ? false : { pathLength: 0 }}
        animate={{ pathLength: 1 }}
        transition={reduce ? { duration: 0 } : loop}
      />
    </svg>
  );
}

// Arrowhead for MoveArrow, kept outside the stretched SVG so it stays undistorted.
export function MoveArrowHead({ x, y, dir = "down" }: { x: number; y: number; dir?: "down" | "up" }) {
  const reduce = useReducedMotion();
  const loop = { duration: 1.2, ease: "linear" as const, repeat: Infinity, repeatDelay: 0.6, times: [0, 0.8, 1] };
  return (
    <motion.svg
      aria-hidden="true"
      data-anim="move"
      viewBox="0 0 24 24"
      className="pointer-events-none absolute h-8 w-8 drop-shadow-[0_2px_6px_rgb(15_23_42_/_0.35)]"
      style={{ left: `${x}%`, top: `${y}%`, translate: "-50% -50%", rotate: dir === "up" ? "180deg" : "0deg" }}
      fill="none"
      stroke="white"
      strokeWidth={3}
      strokeLinecap="round"
      strokeLinejoin="round"
      initial={reduce ? false : { opacity: 0 }}
      animate={reduce ? { opacity: 1 } : { opacity: [0, 0, 1] }}
      transition={reduce ? { duration: 0 } : loop}
    >
      <path d="M5 11l7 7 7-7" />
    </motion.svg>
  );
}

// Points the person towards a part that is outside the frame.
export function EdgeHint({ side, text }: { side: "left" | "right" | "up" | "down"; text: string }) {
  const reduce = useReducedMotion();
  const pos = {
    left: "left-3 top-[44%]",
    right: "right-3 top-[44%]",
    up: "left-1/2 top-[18%] -translate-x-1/2",
    down: "bottom-[46%] left-1/2 -translate-x-1/2",
  }[side];
  const rotate = { left: 180, right: 0, up: -90, down: 90 }[side];
  const nudge = side === "left" ? { x: [0, -4, 0] } : side === "right" ? { x: [0, 4, 0] } : side === "up" ? { y: [0, -4, 0] } : { y: [0, 4, 0] };
  return (
    <motion.div
      data-anim="hint"
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.2 }}
      className={`pointer-events-none absolute ${pos} flex items-center gap-2 rounded-pill bg-ink-900/70 py-2 pl-2.5 pr-3.5 text-[13px] font-semibold text-white backdrop-blur-xl ${
        side === "right" ? "flex-row-reverse pl-3.5 pr-2.5" : ""
      }`}
    >
      <motion.span
        data-anim="hint"
        className="grid h-6 w-6 place-items-center rounded-pill bg-white text-ink-900"
        animate={reduce ? undefined : nudge}
        transition={{ duration: 1.2, ease: "easeInOut", repeat: Infinity }}
      >
        <svg viewBox="0 0 24 24" className="h-4 w-4" style={{ transform: `rotate(${rotate}deg)` }} {...stroke} strokeWidth={2.4} aria-hidden="true">
          <path d="M5 12h14M13 6l6 6-6 6" />
        </svg>
      </motion.span>
      {text}
    </motion.div>
  );
}

export function Sparkle({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="currentColor" aria-hidden="true">
      <path d="M12 2.5c.4 3.9 1.6 6.1 3.4 7.6 1.5 1.2 3.4 1.7 6.1 1.9-2.7.2-4.6.7-6.1 1.9-1.8 1.5-3 3.7-3.4 7.6-.4-3.9-1.6-6.1-3.4-7.6C7.1 12.7 5.2 12.2 2.5 12c2.7-.2 4.6-.7 6.1-1.9C10.4 8.6 11.6 6.4 12 2.5Z" />
    </svg>
  );
}

const stroke = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.8,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

export function Icon({ name, className = "h-5 w-5" }: { name: "flash" | "settings" | "gallery" | "history" | "mic" | "close" | "arrow"; className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...stroke}>
      {name === "flash" && <path d="M13 2 4.5 13.5H11L10 22l8.5-11.5H12L13 2Z" />}
      {name === "settings" && (
        <>
          <path d="M4 7h10M18 7h2M4 17h4M12 17h8" />
          <circle cx="16" cy="7" r="2" />
          <circle cx="10" cy="17" r="2" />
        </>
      )}
      {name === "gallery" && (
        <>
          <rect x="3.5" y="4.5" width="17" height="15" rx="3.5" />
          <path d="m4 16 4.5-4.5 4 4 2.5-2.5 5 5" />
          <circle cx="15.5" cy="9" r="1.5" />
        </>
      )}
      {name === "history" && (
        <>
          <path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1L3.5 8.5" />
          <path d="M3.5 4v4.5H8M12 7.5V12l3 2" />
        </>
      )}
      {name === "mic" && (
        <>
          <rect x="9" y="3" width="6" height="11" rx="3" />
          <path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21" />
        </>
      )}
      {name === "close" && <path d="M6 6l12 12M18 6 6 18" />}
      {name === "arrow" && <path d="M5 12h14M13 6l6 6-6 6" />}
    </svg>
  );
}
