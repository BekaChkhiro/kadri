// @device: mobile
import { useState } from "react";
import { motion } from "motion/react";
import { AnimatePresence } from "motion/react";
import { useReducedMotion } from "motion/react";
import { DetectionBox } from "./design-system";
import { Glass } from "./design-system";
import { Icon } from "./design-system";
import { IconButton } from "./design-system";
import { Sparkle } from "./design-system";

const objects = [
  {
    id: "plant",
    label: "მონსტერა",
    confidence: 96,
    box: { left: 2, top: 15, width: 50, height: 26 },
    title: "Monstera deliciosa",
    answer:
      "ოთახის მცენარეა. რწყე კვირაში ერთხელ, როცა ზედა 2–3 სმ მიწა გაშრება. უყვარს ნათელი, მაგრამ არა პირდაპირი მზე.",
    prompts: ["რატომ უყვითლდება ფოთლები?", "როგორ გავამრავლო?", "ცხოველებს ავნებს?"],
  },
  {
    id: "espresso",
    label: "ესპრესო",
    confidence: 91,
    box: { left: 68, top: 16, width: 30, height: 24 },
    title: "ესპრესოს აპარატი",
    answer:
      "ბერკეტიანი აპარატია. ერთი ესპრესოსთვის 18 გ ფქვილი და დაახლოებით 25 წამი ექსტრაქცია. ნადებს თვეში ერთხელ ასუფთავებ.",
    prompts: ["ლატეს მომზადება", "როგორ გავწმინდო ნადები?", "რომელი ყავა ჯობია?"],
  },
  {
    id: "mug",
    label: "ფინჯანი",
    confidence: 88,
    box: { left: 26, top: 31, width: 34, height: 15 },
    title: "კერამიკული ფინჯანი",
    answer:
      "მატი კერამიკაა, დაახლოებით 300 მლ. მიკროტალღურსა და ჭურჭლის სარეცხ მანქანაში უსაფრთხოა, თუ ძირზე სხვა რამ არ წერია.",
    prompts: ["რამდენი ფინჯანი ყავა დღეში?", "ლაქის მოშორება", "მსგავსი ვიყიდო"],
  },
  {
    id: "headphones",
    label: "ყურსასმენი",
    confidence: 84,
    box: { left: 61, top: 39.5, width: 36, height: 15.5 },
    title: "უსადენო ყურსასმენი",
    answer:
      "ბლუთუზ ყურსასმენია. დასაკავშირებლად 5 წამი გეჭიროს ჩართვის ღილაკი, სანამ ინდიკატორი ციმციმს არ დაიწყებს.",
    prompts: ["ტელეფონთან დაკავშირება", "ხმაურის ჩახშობა", "ბატარეის მოვლა"],
  },
];

const modes = ["ამოცნობა", "კითხვა", "თარგმნა", "ინსტრუქცია"];

export default function Camera() {
  const reduce = useReducedMotion();
  const [selectedId, setSelectedId] = useState("plant");
  const [mode, setMode] = useState(0);
  const selected = objects.find((o) => o.id === selectedId) ?? objects[0];

  return (
    <div className="relative flex min-h-screen flex-col overflow-hidden bg-ink-200 font-sans text-ink-900">
      {/* camera feed */}
      <div className="absolute inset-0 bg-gradient-to-b from-ink-100 via-ink-200 to-ink-300">
        <img
          src="/assets/camera-scene.png"
          alt=""
          className="absolute inset-x-0 w-full object-cover"
          style={{ top: "-8%", height: "108%" }}
        />
        <div className="absolute inset-x-0 top-0 h-40 bg-gradient-to-b from-black/25 to-transparent" />
      </div>

      {/* detections */}
      <div className="absolute inset-0">
        {objects.map((o, i) => (
          <DetectionBox
            key={o.id}
            index={i}
            box={o.box}
            label={o.label}
            confidence={o.confidence}
            selected={o.id === selectedId}
            onSelect={() => setSelectedId(o.id)}
          />
        ))}
      </div>

      {/* top bar */}
      <header
        className="relative z-10 flex items-center justify-between px-4"
        style={{ paddingTop: "calc(var(--safe-area-inset-top, 54px) + 8px)" }}
      >
        <Glass className="flex items-center gap-2 rounded-pill py-2 pl-3 pr-4">
          <span className="relative flex h-2.5 w-2.5">
            {!reduce && (
              <span className="absolute inline-flex h-full w-full animate-ping rounded-pill bg-brand-400 opacity-60" />
            )}
            <span className="relative inline-flex h-2.5 w-2.5 rounded-pill bg-brand-500" />
          </span>
          <span className="text-[14px] font-semibold">კადრი</span>
          <span className="text-[13px] text-ink-500">· {objects.length} ობიექტი</span>
        </Glass>
        <div className="flex gap-2">
          <IconButton label="ფლეში">
            <Icon name="flash" />
          </IconButton>
          <IconButton label="პარამეტრები">
            <Icon name="settings" />
          </IconButton>
        </div>
      </header>

      <div className="flex-1" />

      {/* assistant + controls */}
      <div
        className="relative z-10 px-3"
        style={{ paddingBottom: "calc(var(--safe-area-inset-bottom, 34px) + 4px)" }}
      >
        <motion.div
          data-anim="sheet"
          initial={reduce ? { opacity: 0 } : { opacity: 0, y: 24 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: reduce ? 0.15 : 0.3, ease: "easeOut" }}
        >
          <Glass className="rounded-card p-4">
            <div className="flex items-center gap-2">
              <span className="grid h-7 w-7 place-items-center rounded-pill bg-brand-500 text-white">
                <Sparkle className="h-4 w-4" />
              </span>
              <span className="text-[13px] font-medium text-ink-500">ასისტენტი</span>
              <span className="ml-auto rounded-pill bg-ink-900/5 px-2.5 py-1 text-[12px] font-medium text-ink-600">
                შეეხე ობიექტს
              </span>
            </div>

            <div aria-live="polite" className="min-h-[124px]">
              <AnimatePresence mode="wait" initial={false}>
                <motion.div
                  key={selected.id}
                  data-anim="answer"
                  initial={reduce ? { opacity: 0 } : { opacity: 0, y: 8 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={reduce ? { opacity: 0 } : { opacity: 0, y: -6 }}
                  transition={{ duration: reduce ? 0.1 : 0.2, ease: "easeOut" }}
                >
                  <h2 className="mt-3 text-[19px] font-semibold leading-snug tracking-tight">
                    {selected.title}
                  </h2>
                  <p className="mt-1.5 text-[14.5px] leading-relaxed text-ink-600">{selected.answer}</p>
                  <div className="-mx-4 mt-3 flex gap-2 overflow-x-auto px-4 pb-0.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
                    {selected.prompts.map((p) => (
                      <motion.button
                        key={p}
                        type="button"
                        data-anim="press"
                        whileTap={{ scale: 0.96 }}
                        transition={{ duration: 0.12 }}
                        className="shrink-0 whitespace-nowrap rounded-pill border border-ink-200 bg-white px-3.5 py-2 text-[13px] font-medium text-ink-800"
                      >
                        {p}
                      </motion.button>
                    ))}
                  </div>
                </motion.div>
              </AnimatePresence>
            </div>
          </Glass>
        </motion.div>

        {/* modes */}
        <div
          className="mx-auto mt-4 flex w-fit gap-0.5 rounded-pill bg-ink-900/25 p-1 backdrop-blur-xl"
          role="tablist"
          aria-label="რეჟიმი"
        >
          {modes.map((m, i) => (
            <button
              key={m}
              type="button"
              role="tab"
              aria-selected={mode === i}
              onClick={() => setMode(i)}
              className={`rounded-pill px-2.5 py-1.5 text-[12.5px] font-semibold transition-colors duration-150 ${
                mode === i ? "bg-white text-ink-900 shadow-card" : "text-white"
              }`}
            >
              {m}
            </button>
          ))}
        </div>

        {/* controls */}
        <div className="mt-4 flex items-center justify-between px-6">
          <IconButton label="გალერეა">
            <Icon name="gallery" />
          </IconButton>
          <motion.button
            type="button"
            aria-label="ჰკითხე ხმით"
            data-anim="press"
            whileTap={{ scale: 0.94 }}
            transition={{ duration: 0.12 }}
            className="grid h-[72px] w-[72px] place-items-center rounded-pill bg-white/90 p-1.5 shadow-pop backdrop-blur-xl"
          >
            <span className="grid h-full w-full place-items-center rounded-pill bg-brand-500 text-white">
              <Icon name="mic" className="h-7 w-7" />
            </span>
          </motion.button>
          <IconButton label="ისტორია">
            <Icon name="history" />
          </IconButton>
        </div>
      </div>
    </div>
  );
}
