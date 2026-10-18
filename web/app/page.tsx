"use client";

import Image from "next/image";
import { VideoPreview } from "./video-preview";
import { useReducedMotion } from "./use-reduced-motion";
import { useState } from "react";
import type { ReactNode } from "react";
import { motion, AnimatePresence } from "motion/react";

// Real iOS simulator captures from output/, copied into assets/ as demo-*.png .
const shot = {
  describe: "/assets/demo-capture-add-prominent.png",
  clarify: "/assets/demo-00-submit.png",
  stepBox: "/assets/demo-04-done.png",
  multi: "/assets/demo-01-answer.png",
  turn: "/assets/demo-clockwise.png",
  check: "/assets/demo-photo-check-preview.png",
  ask: "/assets/demo-ask-preview.png",
  tools: "/assets/demo-tool-cards.png",
};

const ease = [0.22, 1, 0.36, 1] as const;

/* ---------- primitives ---------- */

function Phone({ src, alt, className = "", dark = false, children, priority = false }: { src: string; alt: string; className?: string; dark?: boolean; children?: ReactNode; priority?: boolean }) {
  return (
    <div className={`rounded-[48px] p-[9px] ${dark ? "bg-ink-800 ring-1 ring-ink-700" : "bg-ink-900"} shadow-pop ${className}`}>
      <div className="relative aspect-[1170/2532] overflow-hidden rounded-[40px] bg-ink-100">
        <Image src={src} alt={alt} fill sizes="(min-width: 768px) 380px, 290px" priority={priority} className="object-cover object-top" />
        {children}
      </div>
    </div>
  );
}

function Corners({ className = "", color = "border-ink-50/40" }: { className?: string; color?: string }) {
  const c = `absolute h-7 w-7 ${color}`;
  return (
    <div aria-hidden="true" className={`pointer-events-none absolute ${className}`}>
      <span className={`${c} left-0 top-0 rounded-tl-xl border-l-2 border-t-2`} />
      <span className={`${c} right-0 top-0 rounded-tr-xl border-r-2 border-t-2`} />
      <span className={`${c} bottom-0 left-0 rounded-bl-xl border-b-2 border-l-2`} />
      <span className={`${c} bottom-0 right-0 rounded-br-xl border-b-2 border-r-2`} />
    </div>
  );
}

function Logo() {
  return (
    <Image
      src="/brand/neta-logo-light.svg"
      alt="NETA"
      width={1636}
      height={407}
      className="h-auto w-36 shrink-0 md:w-40"
      unoptimized
    />
  );
}

function Rise({ children, id, delay = 0, className = "" }: { children: ReactNode; id: string; delay?: number; className?: string }) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      data-anim={id}
      className={`min-w-0 ${className}`}
      initial={reduce ? { opacity: 0 } : { opacity: 0, y: 28 }}
      whileInView={reduce ? { opacity: 1 } : { opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.25 }}
      transition={{ duration: reduce ? 0.15 : 0.6, delay: reduce ? 0 : delay, ease }}
    >
      {children}
    </motion.div>
  );
}

/* AR-style callout: a dot on the phone, a hairline, and a glass label. */
function Callout({ side, top, kicker, text, delay, id }: { side: "left" | "right"; top: string; kicker: string; text: string; delay: number; id: string }) {
  const reduce = useReducedMotion();
  const left = side === "left";
  return (
    <motion.div
      data-anim={id}
      className={`absolute z-10 hidden items-center lg:flex ${left ? "right-[calc(100%-70px)] flex-row" : "left-[calc(100%-70px)] flex-row-reverse"}`}
      style={{ top }}
      initial={reduce ? { opacity: 0 } : { opacity: 0, x: left ? -16 : 16 }}
      animate={reduce ? { opacity: 1 } : { opacity: 1, x: 0 }}
      transition={{ duration: reduce ? 0.15 : 0.5, delay: reduce ? 0 : delay, ease }}
    >
      <div className="w-[210px] rounded-2xl border border-ink-50/15 bg-ink-900/75 px-4 py-3 shadow-pop backdrop-blur-md">
        <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-brand-300">{kicker}</p>
        <p className="mt-1 text-sm font-medium leading-5 text-ink-50">{text}</p>
      </div>
      <span className="h-px w-16 bg-gradient-to-r from-ink-50/10 via-ink-50/60 to-ink-50/10" />
      <span className="relative grid h-4 w-4 place-items-center">
        <span className="absolute h-4 w-4 rounded-full bg-brand-400/40" />
        <span className="h-2 w-2 rounded-full bg-brand-300" />
      </span>
    </motion.div>
  );
}

/* ---------- content ---------- */

const story = [
  { k: "გადაიღე", t: "1–5 ფოტო. ერთი პრობლემა.", d: "საერთო ხედი, დეტალი, ეტიკეტი. მერე ერთი წინადადებით ან ხმით: „ნიჟარის ქვეშ წყალი წვეთავს“.", src: shot.describe, alt: "ფოტოს დამატება და პრობლემის აღწერა" },
  { k: "დაზუსტება", t: "ჯერ კითხავს. მერე ასწავლის.", d: "როცა ფოტოებიდან ბოლომდე არ ჩანს, რა ხდება, კადრი ჯერ გეკითხება — დამტენი გამორთულია? ბატარეა ამოღებულია? — და მხოლოდ მერე გეგმავს.", src: shot.clarify, alt: "ასისტენტის დამაზუსტებელი კითხვა" },
  { k: "ნაბიჯი", t: "სწორედ ის ნაწილი, სწორ ფოტოზე.", d: "ყოველ ნაბიჯს თავისი ფოტო აქვს: ნაწილი ჩარჩოშია, გვერდით ხელსაწყო და გაფრთხილება. სულ ხუთი ნაბიჯი, არა ოცი.", src: shot.stepBox, alt: "ნაბიჯი 4/5: ქვედა მომსახურების საფარი ჩარჩოში" },
  { k: "მოძრაობა", t: "ისარი გეუბნება, საით.", d: "საათის ისრით, შენსკენ, ზემოთ, დაჭერა — 15 ტიპის მოძრაობა პირდაპირ დეტალზე. ინტერნეტის გარეშეც და Reduce Motion-ის პატივისცემით.", src: shot.turn, alt: "ბრუნვის ისარი სიფონის ქანჩზე" },
  { k: "შემოწმება", t: "„მზადაა“ ფოტოთი მტკიცდება.", d: "ბოლოს კადრი ახალ ფოტოს გთხოვს და ამოწმებს — ბერკეტი დაკეტილია? შეერთება მშრალია? მინიშნებებით: ცენტრში, 20–30 სმ, კარგი შუქი.", src: shot.check, alt: "ფოტოთი შემოწმება" },
];

const reel: [string, string][] = [
  [shot.describe, "აღწერა"],
  [shot.clarify, "დაზუსტება"],
  [shot.multi, "ერთი პრობლემა, 4 ფოტო"],
  [shot.stepBox, "ნაბიჯი ჩარჩოთი"],
  [shot.turn, "მოძრაობის ისარი"],
  [shot.ask, "შეეხე და იკითხე"],
  [shot.check, "ფოტოთი შემოწმება"],
];

const scenes: [string, string, string][] = [
  ["/assets/sink-trap.png", "სანტექნიკა", "ჟონავს სიფონი"],
  ["/assets/ethernet-crimp.png", "ქსელი", "RJ45 · T568B"],
  ["/assets/car-engine.png", "მანქანა", "ზეთის დონე"],
  ["/assets/washing-machine.png", "ტექნიკა", "სარეცხის პროგრამა"],
  ["/assets/microscope.png", "ლაბი", "მიკროსკოპი 4× → 40×"],
];

/* ---------- page ---------- */

export default function LandingV2() {
  const reduce = useReducedMotion();
  const [active, setActive] = useState(0);

  return (
    <main id="main-content" className="bg-surface font-sans text-ink-900">
      {/* ============ HERO — viewfinder ============ */}
      <section className="relative overflow-hidden bg-ink-950 text-ink-50">
        <div aria-hidden="true" className="pointer-events-none absolute left-1/2 top-[340px] h-[720px] w-[720px] -translate-x-1/2 rounded-full bg-brand-600 opacity-25 blur-[140px]" />
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 opacity-[0.07]"
          style={{ backgroundImage: "linear-gradient(var(--color-ink-50) 1px, transparent 1px), linear-gradient(90deg, var(--color-ink-50) 1px, transparent 1px)", backgroundSize: "64px 64px" }}
        />

        <header className="relative z-20 mx-auto flex max-w-6xl items-center justify-between px-6 pt-6 md:px-10">
          <Logo />
          <nav aria-label="მთავარი" className="hidden items-center gap-8 text-sm text-ink-300 md:flex">
            <a href="#story" className="hover:text-ink-50">როგორ მუშაობს</a>
            <a href="#honest" className="hover:text-ink-50">სანდოობა</a>
            <a href="#reel" className="hover:text-ink-50">ეკრანები</a>
          </nav>
          <a href="https://github.com/BekaChkhiro/kadri" className="whitespace-nowrap rounded-pill bg-ink-50 px-5 py-2.5 text-sm font-semibold text-ink-950 hover:bg-ink-200">GitHub ↗</a>
        </header>

        <div className="relative mx-auto max-w-6xl px-6 pb-0 pt-16 md:px-10">
          <Corners className="inset-x-6 bottom-10 top-6 md:inset-x-10" />

          <div className="relative text-center">
            <motion.p
              data-anim="hero-live"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ duration: 0.3 }}
              className="inline-flex max-w-full items-center gap-2 rounded-pill border border-ink-50/15 px-3.5 py-1.5 font-mono text-xs tracking-[0.18em] text-ink-300"
            >
              <span className="h-2 w-2 shrink-0 rounded-full bg-danger-500" />
              LIVE · AI ასისტენტი შეკეთებისთვის
            </motion.p>
            <h1 className="mx-auto mt-8 max-w-4xl font-bold tracking-tight" style={{ fontSize: "clamp(40px, 6.4vw, 84px)", lineHeight: 1.05 }}>
              {["ნახე.", "შეეხე.", "შეაკეთე."].map((w, i) => (
                <motion.span
                  key={w}
                  data-anim={`hero-word-${i}`}
                  className={`inline-block px-[0.12em] ${i === 2 ? "text-brand-400" : "text-ink-50"}`}
                  initial={reduce ? { opacity: 0 } : { opacity: 0, y: 28, filter: "blur(6px)" }}
                  animate={reduce ? { opacity: 1 } : { opacity: 1, y: 0, filter: "blur(0px)" }}
                  transition={{ duration: reduce ? 0.15 : 0.6, delay: reduce ? 0 : 0.1 + i * 0.08, ease }}
                >
                  {w}
                </motion.span>
              ))}
            </h1>
            <motion.p
              data-anim="hero-sub"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ duration: 0.4, delay: reduce ? 0 : 0.4 }}
              className="mx-auto mt-6 max-w-xl text-lg leading-8 text-ink-300"
            >
              გადაუღე ფოტო იმას, რაც გაფუჭდა. კადრი ნაწილს პირდაპირ შენს ფოტოზე მონიშნავს და ნაბიჯ-ნაბიჯ გაგიძღვება — ქართულად.
            </motion.p>
            <motion.div
              data-anim="hero-cta"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ duration: 0.4, delay: reduce ? 0 : 0.5 }}
              className="mt-9 flex flex-wrap justify-center gap-3"
            >
              <a href="https://github.com/BekaChkhiro/kadri" className="rounded-pill bg-brand-600 px-7 py-3.5 font-semibold text-white hover:bg-brand-700">GitHub ↗</a>
              <a href="#demo" className="rounded-pill border border-ink-50/20 px-7 py-3.5 font-semibold text-ink-100 hover:border-ink-50/40">ნახე როგორ მუშაობს ↓</a>
            </motion.div>
          </div>

          {/* phone stage */}
          <div className="relative mx-auto mt-16 h-[560px] w-full max-w-[1040px] overflow-hidden md:h-[600px]">
            <motion.div
              data-anim="hero-side-left"
              className="absolute left-[2%] top-[110px] hidden w-[230px] md:block"
              initial={reduce ? { opacity: 0 } : { opacity: 0, y: 80, rotate: -10 }}
              animate={reduce ? { opacity: 0.4 } : { opacity: 0.4, y: 0, rotate: -8 }}
              transition={{ duration: reduce ? 0.15 : 0.9, delay: reduce ? 0 : 0.45, ease }}
            >
              <Phone dark src={shot.describe} alt="აღწერის ეკრანი" />
            </motion.div>
            <motion.div
              data-anim="hero-side-right"
              className="absolute right-[2%] top-[110px] hidden w-[230px] md:block"
              initial={reduce ? { opacity: 0 } : { opacity: 0, y: 80, rotate: 10 }}
              animate={reduce ? { opacity: 0.4 } : { opacity: 0.4, y: 0, rotate: 8 }}
              transition={{ duration: reduce ? 0.15 : 0.9, delay: reduce ? 0 : 0.5, ease }}
            >
              <Phone dark src={shot.turn} alt="მოძრაობის მინიშნება" />
            </motion.div>

            <motion.div
              data-anim="hero-phone"
              className="absolute left-1/2 top-0 w-[290px] -ml-[145px]"
              initial={reduce ? { opacity: 0 } : { opacity: 0, y: 120 }}
              animate={reduce ? { opacity: 1 } : { opacity: 1, y: 0 }}
              transition={{ duration: reduce ? 0.15 : 1, delay: reduce ? 0 : 0.3, ease }}
            >
              <Phone priority dark src={shot.stepBox} alt="კადრი: ნაბიჯი 4/5, ქვედა საფარი ჩარჩოში">
                {!reduce && (
                  <motion.div
                    data-anim="hero-scan"
                    aria-hidden="true"
                    className="absolute inset-x-0 h-24 bg-gradient-to-b from-transparent via-brand-400/30 to-transparent"
                    initial={{ top: "-15%" }}
                    animate={{ top: "105%" }}
                    transition={{ duration: 2.4, delay: 1.2, repeat: 1, repeatDelay: 0.8, ease: "easeInOut" }}
                  >
                    <div className="absolute inset-x-0 top-1/2 h-px bg-brand-300 shadow-[0_0_12px_2px_var(--color-brand-400)]" />
                  </motion.div>
                )}
              </Phone>
            </motion.div>

            <div className="pointer-events-none absolute left-1/2 top-0 h-full w-[290px] -ml-[145px]">
              <Callout id="call-part" side="left" top="150px" kicker="ნაწილი ამოიცნო" text="ქვედა მომსახურების საფარი" delay={1.1} />
              <Callout id="call-tool" side="right" top="300px" kicker="ხელსაწყო" text="სახრახნისი · ზომა დადასტურდება ფოტოთი" delay={1.25} />
            </div>

            <div aria-hidden="true" className="absolute inset-x-0 bottom-0 h-40 bg-gradient-to-t from-ink-950 to-transparent" />
          </div>
        </div>
      </section>

      <VideoPreview />

      {/* ============ STRIP ============ */}
      <section className="border-b border-ink-200 bg-ink-50">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-6 px-6 py-7 md:px-10">
          {[
            ["1–5", "ფოტო ერთ პრობლემაზე"],
            ["≤5", "ნაბიჯი გეგმაში"],
            ["15", "მოძრაობის ისარი"],
            ["25", "ხელსაწყოს აიქონი"],
          ].map(([n, l]) => (
            <div key={l} className="flex items-baseline gap-3">
              <span className="whitespace-nowrap text-2xl font-bold tracking-tight">{n}</span>
              <span className="text-sm text-ink-600">{l}</span>
            </div>
          ))}
        </div>
      </section>

      {/* ============ STORY — sticky phone ============ */}
      <section id="story" className="mx-auto max-w-6xl scroll-mt-6 px-6 py-28 md:px-10">
        <Rise id="story-head" className="max-w-2xl">
          <p className="font-mono text-xs tracking-[0.2em] text-brand-600">როგორ მუშაობს</p>
          <h2 className="mt-4 font-bold tracking-tight" style={{ fontSize: "clamp(32px, 4vw, 52px)", lineHeight: 1.1 }}>
            ფოტოდან შეკეთებამდე — ხუთი კადრი.
          </h2>
        </Rise>

        <div className="mt-16 grid gap-16 md:grid-cols-[1fr_340px] lg:grid-cols-[1fr_380px]">
          <ol>
            {story.map((s, i) => (
              <motion.li
                key={s.k}
                data-anim={`story-${i}`}
                onViewportEnter={() => setActive(i)}
                viewport={{ amount: 0.6 }}
                className="flex min-h-[460px] flex-col justify-center border-l-2 py-10 pl-8 transition-colors duration-300 motion-reduce:transition-none"
                style={{ borderColor: active === i ? "var(--color-brand-500)" : "var(--color-ink-200)" }}
              >
                <p className={`font-mono text-sm ${active === i ? "text-brand-600" : "text-ink-600"}`}>
                  0{i + 1} — {s.k}
                </p>
                <h3 className={`mt-3 text-3xl font-bold leading-tight tracking-tight transition-colors duration-300 ${active === i ? "text-ink-900" : "text-ink-600"}`}>{s.t}</h3>
                <p className="mt-4 max-w-lg text-lg leading-8 text-ink-600">{s.d}</p>
                <div className="mt-8 w-[220px] md:hidden">
                  <Phone src={s.src} alt={s.alt} />
                </div>
              </motion.li>
            ))}
          </ol>

          <div className="hidden md:block">
            <div className="sticky top-16">
              <div className="relative">
                <Corners className="-inset-5" color="border-ink-300" />
                <div className="relative aspect-[1170/2532] w-full">
                  <AnimatePresence mode="popLayout" initial={false}>
                    <motion.div
                      key={active}
                      data-anim="story-phone"
                      className="absolute inset-0"
                      initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.97 }}
                      animate={reduce ? { opacity: 1 } : { opacity: 1, scale: 1 }}
                      exit={{ opacity: 0 }}
                      transition={{ duration: reduce ? 0.15 : 0.35, ease }}
                    >
                      <Phone src={story[active].src} alt={story[active].alt} />
                    </motion.div>
                  </AnimatePresence>
                </div>
              </div>
              <div className="mt-8 flex justify-center gap-2" aria-hidden="true">
                {story.map((s, i) => (
                  <span key={s.k} className={`h-1.5 rounded-full transition-all duration-300 ${active === i ? "w-8 bg-brand-500" : "w-1.5 bg-ink-300"}`} />
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ============ HONEST AI ============ */}
      <section id="honest" className="scroll-mt-6 bg-ink-50 py-28">
        <div className="mx-auto max-w-6xl px-6 md:px-10">
          <div className="grid items-end gap-10 md:grid-cols-2">
            <Rise id="honest-head">
              <p className="font-mono text-xs tracking-[0.2em] text-brand-600">სანდოობა</p>
              <h2 className="mt-4 font-bold tracking-tight" style={{ fontSize: "clamp(32px, 4vw, 52px)", lineHeight: 1.1 }}>
                AI, რომელიც იცის, რა არ იცის.
              </h2>
            </Rise>
            <Rise id="honest-lede" delay={0.08}>
              <p className="text-lg leading-8 text-ink-600">ხელით სამუშაოში ზედმეტი თავდაჯერება ძვირი ჯდება. ამიტომ კადრი ყოველთვის ამბობს, რამდენად დარწმუნებულია, და გაჩვენებს, როგორ შეამოწმო თავად.</p>
            </Rise>
          </div>

          <div className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-3">
            <Rise id="honest-1" className="h-full">
              <article className="flex h-full flex-col rounded-card border border-ink-200 bg-surface p-7">
                <div className="flex flex-wrap gap-2">
                  <span className="inline-flex items-center gap-1.5 rounded-pill bg-brand-50 px-3 py-1.5 text-sm font-semibold text-brand-700">✓ დადასტურებული · T10</span>
                  <span className="inline-flex items-center gap-1.5 rounded-pill bg-warning-100 px-3 py-1.5 text-sm font-semibold text-warning-800">≈ PH2 · შეამოწმე</span>
                </div>
                <h3 className="mt-8 text-xl font-semibold">ზომაზე არ ცრუობს</h3>
                <p className="mt-2 leading-7 text-ink-600">ფოტოზე ნანახი ზომა — „დადასტურებულია“. დანარჩენი — „სავარაუდო“, ალტერნატივით და შემოწმების ხერხით.</p>
              </article>
            </Rise>
            <Rise id="honest-2" delay={0.06} className="h-full">
              <article className="flex h-full flex-col rounded-card border border-ink-200 bg-surface p-7">
                <div className="rounded-2xl bg-ink-50 p-4 shadow-card">
                  <p className="text-sm font-semibold leading-6">ბატარეა ამოღებულია და დამტენი გამორთულია?</p>
                  <div className="mt-3 h-9 rounded-field border border-ink-200 bg-surface px-3 text-sm leading-9 text-ink-600">შენი პასუხი</div>
                </div>
                <h3 className="mt-8 text-xl font-semibold">ჯერ კითხვა, მერე ინსტრუქცია</h3>
                <p className="mt-2 leading-7 text-ink-600">ბუნდოვან სიტუაციაში არ გამოიცნობს — დაგისვამს კითხვას და მხოლოდ პასუხის შემდეგ ააწყობს გეგმას.</p>
              </article>
            </Rise>
            <Rise id="honest-3" delay={0.12} className="h-full">
              <article className="flex h-full flex-col rounded-card border border-ink-200 bg-surface p-7">
                <div className="flex items-center gap-3 rounded-2xl border border-dashed border-ink-300 px-4 py-3.5 text-sm text-ink-600">
                  <span className="grid h-7 w-7 place-items-center rounded-lg border border-ink-300 text-ink-400">⌗</span>
                  მოქმედების ადგილი ფოტოზე არ ჩანს
                </div>
                <h3 className="mt-8 text-xl font-semibold">არ ხატავს, რაც არ ხედავს</h3>
                <p className="mt-2 leading-7 text-ink-600">ჩარჩო ჩნდება მხოლოდ იქ, სადაც ნაწილი მართლა ჩანს. თუ არ ჩანს, ამას პირდაპირ გეტყვის.</p>
              </article>
            </Rise>
          </div>

          <Rise id="honest-tools" className="mt-5">
            <div className="grid items-center gap-10 overflow-hidden rounded-card bg-ink-950 px-8 pt-10 text-ink-50 md:grid-cols-2 md:px-14 md:pt-0">
              <div className="md:py-14">
                <p className="font-mono text-xs tracking-[0.2em] text-brand-300">ხელსაწყოს ბარათები</p>
                <h3 className="mt-4 text-3xl font-bold leading-tight tracking-tight text-ink-50">Torx-ს Phillips-ისგან არჩევს.</h3>
                <p className="mt-4 max-w-md leading-7 text-ink-300">25 ხელსაწყოს ამოცნობადი აიქონი, ზომა, დადასტურების სტატუსი და მოკლე რჩევა, როგორ მოარგო — ყოველ ნაბიჯზე.</p>
              </div>
              <div className="relative mx-auto h-[340px] w-[280px] max-w-full md:mt-12">
                <Phone dark src={shot.tools} alt="ხელსაწყოს ბარათები: T10, PH2, ექვსკუთხა, 10 მმ" />
              </div>
            </div>
          </Rise>
        </div>
      </section>

      {/* ============ REEL — all real screens ============ */}
      <section id="reel" className="scroll-mt-6 py-28">
        <div className="mx-auto flex max-w-6xl flex-wrap items-end justify-between gap-6 px-6 md:px-10">
          <Rise id="reel-head">
            <p className="font-mono text-xs tracking-[0.2em] text-brand-600">რეალური ეკრანები</p>
            <h2 className="mt-4 font-bold tracking-tight" style={{ fontSize: "clamp(32px, 4vw, 52px)", lineHeight: 1.1 }}>
              აპი, როგორიც არის.
            </h2>
          </Rise>
          <p className="max-w-sm text-ink-600">ყველა ეკრანი iPhone-ის სიმულატორიდანაა, ტესტირების ვერსიიდან. გადაფურცლე →</p>
        </div>
        <div role="region" aria-label="აპის ეკრანები" tabIndex={0} className="screen-reel mt-12 flex snap-x snap-proximity gap-6 overflow-x-auto pb-6" style={{ paddingInline: "max(24px, calc(50% - 536px))", scrollPaddingInline: "max(24px, calc(50% - 536px))" }}>
          {reel.map(([src, label], i) => (
            <figure key={label} className="w-[230px] flex-none snap-start">
              <Phone src={src} alt={label} />
              <figcaption className="mt-4 flex items-center gap-2 text-sm">
                <span className="font-mono text-ink-600">0{i + 1}</span>
                <span className="font-medium text-ink-700">{label}</span>
              </figcaption>
            </figure>
          ))}
        </div>
      </section>

      {/* ============ SCENES — bento ============ */}
      <section className="mx-auto max-w-6xl px-6 pb-28 md:px-10">
        <Rise id="scenes-head" className="mb-10 max-w-xl">
          <h2 className="font-bold tracking-tight" style={{ fontSize: "clamp(28px, 3.2vw, 40px)", lineHeight: 1.15 }}>
            ნიჟარის ქვეშ, კაპოტის ქვეშ, მიკროსკოპის ქვეშ.
          </h2>
        </Rise>
        <div className="grid auto-rows-[200px] gap-4 md:grid-cols-4">
          {scenes.map(([src, tag, title], i) => (
            <Rise key={title} id={`scene-${i}`} delay={i * 0.05} className={i === 0 ? "md:col-span-2 md:row-span-2" : ""}>
              <figure className="group relative h-full overflow-hidden rounded-card bg-ink-200">
                <Image src={src} alt="" fill sizes={i === 0 ? "(min-width: 768px) 540px, 100vw" : "(min-width: 768px) 270px, 100vw"} className="object-cover transition-transform duration-700 group-hover:scale-105 motion-reduce:transition-none motion-reduce:group-hover:scale-100" />
                <div className="absolute inset-0 bg-gradient-to-t from-ink-950/70 via-transparent to-transparent" />
                <Corners className="inset-4 opacity-0 transition-opacity duration-300 group-hover:opacity-100" color="border-ink-50/80" />
                <figcaption className="absolute bottom-4 left-5 text-ink-50">
                  <p className="font-mono text-[11px] tracking-[0.16em] text-ink-200">{tag}</p>
                  <p className={`mt-1 font-semibold ${i === 0 ? "text-2xl" : "text-base"}`}>{title}</p>
                </figcaption>
              </figure>
            </Rise>
          ))}
        </div>
      </section>

      {/* ============ JOIN ============ */}
      <section id="join" className="relative scroll-mt-6 overflow-hidden bg-ink-950 py-28 text-ink-50">
        <div aria-hidden="true" className="pointer-events-none absolute left-1/2 top-1/2 h-[520px] w-[520px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-brand-600 opacity-30 blur-[120px]" />
        <div className="relative mx-auto max-w-3xl px-6 text-center">
          <div className="relative px-6 py-14 md:px-16">
            <Corners className="inset-0" color="border-brand-400/70" />
            <h2 className="font-bold tracking-tight text-ink-50" style={{ fontSize: "clamp(32px, 4.4vw, 56px)", lineHeight: 1.08 }}>
              შემდეგ ჯერზე, როცა რამე გაფუჭდება —
              <span className="block text-brand-400">ჯერ კადრი.</span>
            </h2>
            <div className="mt-9 flex flex-wrap justify-center gap-3">
              <a href="https://github.com/BekaChkhiro/kadri" className="rounded-pill bg-brand-600 px-7 py-3.5 font-semibold text-white hover:bg-brand-700">GitHub ↗</a>
              <a href="#demo" className="rounded-pill border border-ink-50/20 px-7 py-3.5 font-semibold text-ink-50 hover:border-ink-50/60">ნახე დემო</a>
            </div>
          </div>
        </div>
        <footer className="relative mx-auto mt-16 flex max-w-6xl flex-wrap items-center justify-between gap-4 border-t border-ink-800 px-6 pt-8 text-sm text-ink-400 md:px-10">
          <Logo />
          <p>კადრი · 2026 · ნაბიჯ-ნაბიჯ, შენს ფოტოზე</p>
        </footer>
      </section>
    </main>
  );
}
