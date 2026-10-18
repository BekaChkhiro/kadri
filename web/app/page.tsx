"use client";

import Image from "next/image";
import { motion } from "motion/react";
import type { ReactNode } from "react";
import { VideoPreview } from "./video-preview";
import { useReducedMotion } from "./use-reduced-motion";

const github = "https://github.com/BekaChkhiro/kadri";
const features = [
  { image: "parts", title: "ნაწილს ფოტოზე მონიშნავს", text: "ზუსტად დაინახავ, რომელ დეტალზეა საუბარი.", alt: "ლეპტოპის ქვედა საფარი ლურჯი ჩარჩოთი მონიშნული", position: "center 37%" },
  { image: "arrows", title: "ისრები და ნაბიჯები", text: "მოძრაობის მიმართულება პირდაპირ შენს ფოტოზე.", alt: "სიფონის ქანჩზე ბრუნვის მიმართულების ისარი", position: "center 52%" },
  { image: "tools", title: "ხელსაწყოები, მინიშნებით", text: "დადასტურებული თუ სავარაუდო — განსხვავება ყოველთვის ჩანს.", alt: "ხელსაწყოების ბარათები დადასტურებული და სავარაუდო ზომებით", position: "center 28%" },
  { image: "check", title: "ფოტოთი შემოწმება", text: "ახალი ფოტო დაგეხმარება შედეგის გადამოწმებაში.", alt: "ახალი ფოტოთი შედეგის შემოწმების ეკრანი", position: "center 20%" },
];

function Fade({ children, className = "" }: { children: ReactNode; className?: string }) {
  const reduce = useReducedMotion();
  return (
    <motion.div data-fade className={className} initial={{ opacity: 0 }} whileInView={{ opacity: 1 }}
      viewport={{ once: true, amount: 0.15 }} transition={{ duration: reduce ? 0 : 0.45 }}>
      {children}
    </motion.div>
  );
}

function Corners() {
  return <div aria-hidden="true" className="pointer-events-none absolute inset-0">
    <span className="absolute left-0 top-0 h-6 w-6 rounded-tl-xl border-l-2 border-t-2 border-brand-500" />
    <span className="absolute right-0 top-0 h-6 w-6 rounded-tr-xl border-r-2 border-t-2 border-brand-500" />
    <span className="absolute bottom-0 left-0 h-6 w-6 rounded-bl-xl border-b-2 border-l-2 border-brand-500" />
    <span className="absolute bottom-0 right-0 h-6 w-6 rounded-br-xl border-b-2 border-r-2 border-brand-500" />
  </div>;
}

export default function Home() {
  return (
    <div className="relative isolate min-h-screen overflow-x-clip bg-ink-950 text-ink-50">
      <div aria-hidden="true" className="visor-grid pointer-events-none absolute inset-x-0 top-0 -z-10 h-[780px]" />
      <header className="mx-auto flex max-w-[1088px] items-center justify-between px-5 py-5 md:px-8 md:py-6">
        <a href="#main-content" aria-label="NETA — მთავარი" className="rounded-sm">
          <Image src="/brand/neta-logo-light.svg" alt="NETA" width={1636} height={407} priority unoptimized className="h-auto w-28 md:w-32" />
        </a>
        <a href={github} className="inline-flex min-h-11 items-center gap-2 text-sm font-medium text-ink-200 hover:text-white">GitHub <span aria-hidden="true">↗</span></a>
      </header>

      <main id="main-content">
        <section aria-labelledby="hero-title" className="mx-auto grid max-w-[1040px] items-center gap-7 px-5 pb-10 pt-7 md:grid-cols-[1.3fr_1fr] md:gap-16 md:px-8 md:pb-12 md:pt-4">
          <Fade className="text-center md:text-left">
            <h1 id="hero-title" className="text-[clamp(2.4rem,5.3vw,4.25rem)] font-semibold leading-[1.16] tracking-[-0.055em]">ნახე. შეეხე.<br /><span className="text-brand-400">შეაკეთე.</span></h1>
            <p className="mx-auto mt-5 max-w-md text-sm leading-7 text-ink-300 md:mx-0 md:text-base">გადაუღე ფოტო — NETA ნაწილს მონიშნავს და შეკეთებაში ნაბიჯ-ნაბიჯ გაგიძღვება.</p>
            <div className="mt-6 flex flex-wrap justify-center gap-3 md:justify-start">
              <a href="#demo" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-btn bg-brand-600 px-5 text-sm font-semibold text-white hover:bg-brand-700"><span aria-hidden="true">▷</span> ნახე დემო</a>
              <a href={github} className="inline-flex min-h-12 items-center justify-center gap-2 rounded-btn border border-ink-700 bg-ink-900/60 px-5 text-sm font-medium hover:bg-ink-800">GitHub <span aria-hidden="true">↗</span></a>
            </div>
          </Fade>
          <Fade className="relative mx-auto w-[182px] p-3 md:w-[220px] md:p-4">
            <Corners />
            <div className="rounded-[27px] border border-ink-600 bg-ink-900 p-[5px] shadow-[0_16px_80px_-24px_#2f6bff55]">
              <Image src="/shots/parts.png" alt="NETA აპი — ფოტოზე მონიშნული ნაწილი და შეკეთების ნაბიჯი" width={1170} height={2532} priority sizes="(min-width: 768px) 176px, 146px" className="h-auto w-full rounded-[21px]" />
            </div>
          </Fade>
        </section>

        <VideoPreview />

        <section aria-label="NETA-ს შესაძლებლობები" className="mx-auto max-w-[1088px] px-5 pb-10 pt-7 md:px-8 md:pb-12 md:pt-10">
          <div className="grid grid-cols-2 gap-x-4 gap-y-6 md:grid-cols-4 md:gap-5">
            {features.map((feature) => (
              <Fade key={feature.image}>
                <article>
                  <div className="relative aspect-[1/1] overflow-hidden rounded-2xl border border-ink-700 bg-ink-900 md:aspect-[6/5]">
                    <Image src={`/shots/${feature.image}.png`} alt={feature.alt} fill sizes="(min-width: 1088px) 240px, (min-width: 768px) 22vw, 44vw" className="object-cover" style={{ objectPosition: feature.position }} />
                  </div>
                  <h2 className="mt-4 text-sm font-semibold leading-6 md:text-base">{feature.title}</h2>
                  <p className="mt-1.5 text-xs leading-5 text-ink-400 md:text-sm md:leading-6">{feature.text}</p>
                </article>
              </Fade>
            ))}
          </div>
        </section>
      </main>

      <footer className="mx-auto flex max-w-[1024px] flex-wrap items-center justify-between gap-2 border-t border-ink-800 px-5 py-5 text-xs text-ink-400 md:px-0">
        <p>Hacktoberfest 2026 · Hamburger</p>
        <a href={github} className="inline-flex min-h-11 items-center text-ink-200 hover:text-white">GitHub ↗</a>
      </footer>
    </div>
  );
}
