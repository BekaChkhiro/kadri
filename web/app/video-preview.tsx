"use client";

import Image from "next/image";
import { useState } from "react";

const videoUrl = "https://www.youtube.com/watch?v=1h_iX-sqAmE";

export function VideoPreview() {
  const [playing, setPlaying] = useState(false);

  return (
    <section id="demo" aria-labelledby="demo-title" className="scroll-mt-6 bg-ink-950 px-6 pb-20 pt-8 text-ink-50 md:px-10">
      <div className="mx-auto max-w-5xl">
        <div className="mb-8 flex flex-wrap items-end justify-between gap-4">
          <h2 id="demo-title" className="text-2xl font-semibold tracking-tight md:text-3xl">ნახე, როგორ მუშაობს</h2>
          <a href={videoUrl} className="text-sm text-ink-300 underline decoration-ink-600 underline-offset-4 hover:text-ink-50">ნახე დემო ↗</a>
        </div>
        <div className="relative p-3 md:p-5">
          <span aria-hidden="true" className="pointer-events-none absolute inset-0 rounded-2xl border border-brand-400/40" />
          <span aria-hidden="true" className="pointer-events-none absolute left-0 top-0 h-8 w-8 rounded-tl-2xl border-l-2 border-t-2 border-brand-400" />
          <span aria-hidden="true" className="pointer-events-none absolute bottom-0 right-0 h-8 w-8 rounded-br-2xl border-b-2 border-r-2 border-brand-400" />
          <div className="relative aspect-video overflow-hidden rounded-xl bg-ink-900">
            {playing ? (
              <iframe
                ref={(node) => { node?.focus(); }}
                src="https://www.youtube-nocookie.com/embed/1h_iX-sqAmE?autoplay=1&rel=0"
                title="NETA — ნახე, როგორ მუშაობს"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                referrerPolicy="strict-origin-when-cross-origin"
                allowFullScreen
                className="absolute inset-0 h-full w-full border-0"
              />
            ) : (
              <button
                type="button"
                onClick={() => setPlaying(true)}
                aria-label="ვიდეოს ჩართვა — ნახე, როგორ მუშაობს"
                className="group absolute inset-0 block h-full w-full focus-visible:outline-offset-[-4px]"
              >
                <Image
                  src="https://img.youtube.com/vi/1h_iX-sqAmE/maxresdefault.jpg"
                  alt=""
                  fill
                  sizes="(min-width: 1100px) 984px, 100vw"
                  className="object-cover"
                />
                <span aria-hidden="true" className="absolute inset-0 bg-ink-950/20 transition-opacity group-hover:opacity-0" />
                <span aria-hidden="true" className="absolute left-1/2 top-1/2 grid h-16 w-16 -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full border border-ink-50/30 bg-brand-500 shadow-pop transition-colors group-hover:bg-brand-600 md:h-20 md:w-20">
                  <svg viewBox="0 0 24 24" className="ml-1 h-7 w-7 fill-white"><path d="M8 4.8v14.4L20 12Z" /></svg>
                </span>
              </button>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}
