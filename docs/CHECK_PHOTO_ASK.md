# შემოწმების ფოტოები და „შეეხე და იკითხე" — 2026-10-18

ორი ფუნქცია, ორივეს ერთი მიზანი: AI-მ არ გამოიცნოს.
- T5.15 `check_photo`: შეუქცევადი ან ხშირად შეცდომიანი ოპერაციის შემდეგ AI ითხოვს ახლო ფოტოს და შედეგს ფოტოზე ამოწმებს. მომხმარებლის პასუხს ბრმად არ ენდობა.
- T5.16 `POST /ai/ask`: მომხმარებელი ფოტოზე ნაწილს ეხება და მასზე სვამს კითხვას.

## check_photo (worker)

კოდი: `schema.ts` (`CHECK_PHOTO_LIMIT=20`, `FALLBACK_OPTIONS`), `validate.ts` (`parseContext`, `tidyContinuation`), `prompts.ts` `checkPhotoRule`, `steps.ts`. ტესტები: `test/ai-check-photo.test.ts`.

- **Capability** `"check_photo"` `POST /ai/steps`-ის `capabilities`-ში. მის გარეშე `context.checkPhotos`/`checkPrompt` იგნორირდება და მოთხოვნა legacy-ა. `locks the legacy prompt and schema` ამოწმებს, რომ check_photo-ს გარეშე diagnostic prompt/schema უცვლელია.
- **Continuation** `{ kind: "needs_check_photo", prompt ≤90, reason ≤100 }`. prompt/reason სიტყვაზე იჭრება. აპი იმავე round-ს თავიდან აგზავნის: `image` = ახლო ფოტო, `context.checkPhotos` +1, `context.checkPrompt` = რა ითხოვა (≤120). round 1 answers-ის გარეშეც დასაშვებია, თუ `checkPrompt` არის.
- **ლიმიტი 20** შემოწმების ფოტოზე სესიაში. ეს round-ად არ ითვლება და კითხვების ლიმიტს არ ეხება: ნებადართულია ბოლო round-ზეც და answer-ლიმიტის შემდეგაც. `checkPhotos ≥ 20`-ზე `needs_check_photo` schema-დან ქრება. თუ მოდელმა მაინც მოითხოვა, ხდება `needs_photo` (ბოლო round-ზე `complete`). `context.checkPhotos` > 20 → 400.
- **შემოწმების ფოტოს prompt**: „მიმაგრებული ფოტო შემოწმების ფოტოა, გადაღებული თხოვნით „…"". AI ჯერ აფასებს, სწორად შესრულდა თუ არა ბოლო ნაბიჯი, და ხილულ ფაქტს პირველი ნაბიჯის text-ში ასახელებს. არასწორზე პირველი ნაბიჯით გაასწორებინებს; თუ არ ჩანს, თავიდან ითხოვს.
- **როდის**: CPU-ს ორიენტაცია/ბერკეტი, ქულერის სამაგრი, RAM-ის წკაპი, 24-pin/8-pin/12VHPWR, front panel, ჰერმეტული შეერთება. ასეთ დროს `needs_check_photo`, არა `needs_answer`. ნაბიჯები მთავრდება შესამოწმებელი ოპერაციით.
- **აწყობის რეჟიმი** (მრავალნაწილიანი ობიექტი ან „ნაბიჯ-ნაბიჯ"/„პირველად"/„ავაწყო"): ერთი ფიზიკური მოქმედება ნაბიჯზე, 2–4 ნაბიჯი შემოწმებამდე. text-ში „სად არის": დაფის წარწერა (CPU_FAN1, JFP1) და ადგილი. საერთო ფოტოზე focus მთელ დაფაზე არ ეძლევა — ითხოვს ახლო ფოტოს. checklist: ბერკეტი, ქულერი ჯვარედინად, დამცავი ფირები, ESD. დეტალები: `docs/E2E_PC_ASSEMBLY.md`.
- **answer options**: `needs_answer`-ზე მოდელის ≤4 ვარიანტს validator ყოველთვის უმატებს „არ ვიცი" და „ფოტოს გაჩვენებ"-ს (სულ ≤6). მოდელის საკუთარ ასლებს შლის. `allowOther=true` ყოველთვის.
- **გამეორებული კითხვა**: თუ კითხვა (lower case, მხოლოდ ასოები/ციფრები) უკვე არის `context.answers`-ში, `needs_answer` იცვლება `needs_check_photo`-ით: „გადაიღე ახლოდან: <კითხვა>", reason „ეს კითხვა უკვე იყო, ფოტოთი გადავამოწმებ". ლიმიტზე → `complete`.

## check_photo (iOS)

**ინტეგრაციის პროცესშია.** ამ commit-ის მდგომარეობით iOS-ში `check_photo` არ ჩანს. `KadriAPI.swift` აგზავნის `["needs_answer", "needs_measurement", "summary", "tools_v2", "hands_v1"]`-ს, ხოლო `PhotoSession.swift`/`SessionModel`-ში `needs_check_photo`, `checkPhotos` და `checkPrompt` არ არის. ამ ნაწილზე მუშაობს thread „check photo ios". მოსალოდნელი ნაკადი worker-ის კონტრაქტიდან: continuation-ზე ჩანს prompt-ის ბარათი → ახლო ფოტო → იგივე round `image`-ით, `checkPhotos+1` და `checkPrompt`-ით; „ფოტოს გაჩვენებ" ვარიანტი ამავე გზაზე მიდის.

## `POST /ai/ask` (worker)

კოდი: `backend/worker/src/ai/ask.ts`, route `guardedAskHandler`. ტესტები: `test/ai-ask.test.ts`.

- Body: multipart (`image`; `question`, `partId`, `sessionId`, `provider` ტექსტად; `box`, `parts`, `context` JSON სტრიქონად) ან JSON `{ image, question, box?, partId?, parts?, context?, sessionId?, provider? }`.
  - `question` 1–200.
  - `box` ან `partId` სავალდებულოა. `partId` `parts`-ში იძებნება (არ არის → 400). explicit `box` ჯობნის ნაწილის box-ს.
  - `context` — `{ object? ≤300, doneSteps? ≤40×120, answers? ≤8 }`.
- Guard-ი იგივეა, რაც explain-ზე: `requireSession`, `assertDailyLimit`, ერთი retry (`ai_invalid_response`/`ai_timeout`), usage `stage="ask"` თითო ცდაზე (migration 0003). provider default Gemini, explicit — `selectedEnv` gate-ით. Knowledge Hub ტექსტით: object/partName + question + answers.
- Prompt: სამიზნე ზონა `box=[x0,y0,x1,y1]`. Gemini-სთვის რიცხვები YXYX რიგშია, რადგან `postGemini` literal-ს `box_2d`-ად წერს. „მოვხსნა?"-ზე პასუხი ჯერ უსაფრთხოებით იწყება (დენი, გაზი/წყალი, წნევა, გაცივება).

```jsonc
{
  "partLabel": "სიფონის ქანჩი",   // ≤40
  "answer": "…",                  // 1–200
  "size": "10 მმ",                // ≤12 | null — მხოლოდ ზომის კითხვაზე
  "sizeSource": "typical",        // seen | model | typical | null
  "fitCheck": "…",                // ≤100 | null; typical-ზე ყოველთვის არის
  "urgency": null,                // stop | soon | ok | null
  "suggestStep": null,            // ≤80 | null
  "confidence": "medium",         // high | medium | low
  "model": "…", "usage": {…}, "costUsd": 0.0, "latencyMs": 0
}
```

- **Validator** (`tidyAsk`):
  - ცარიელი `answer` → invalid (retry).
  - enum-ის გარეთ: urgency/sizeSource → `null`, confidence → `low`. 502 არ ბრუნდება.
  - ზომა: `seen` რჩება მხოლოდ მაშინ, თუ ზომის ბირთვი evidence-შია (ნაწილების სახელები, კითხვა, object, answers). `model` — მხოლოდ ცნობილ მოდელზე (Knowledge Hub ან მოდელის კოდი). სხვა შემთხვევაში `typical`.
  - `typical`-ზე fitCheck-ის გარეშე → „შეადარე ხელსაწყო ადგილზე: უნდა ჩაჯდეს თამაშის გარეშე". ზომის გარეშე sizeSource `null`-ია; `typical` რჩება, თუ მოდელმა ის თავად აირჩია.
- urgency `stop` — გაზი, ელექტრობა ძაბვის ქვეშ, წნევის ქვეშ მყოფი ან ცხელი ნაწილი.

## შეეხე და იკითხე (iOS)

- **შეხება** (`PhotoResultView` `onTapGesture`): მუშაობს, როცა მოთხოვნა არ მიმდინარეობს და ნაბიჯი ჩანს ან სესია დასრულებულია. round-ის ან ნაბიჯის შეცვლა sheet-ს ხურავს.
- **არჩევა** (`PhotoAskSession.select`, `PhotoAskGeometry`):
  1. თითის ქვეშ ცნობილი ნაწილის box თუ არის, ირჩევა ყველაზე პატარა (ჩადგმულებიდან). იგზავნება `partId`, sheet მაშინვე იხსნება.
  2. სხვა შემთხვევაში — **SAM point mask**: `Segmenter.shared()` (CPU), `embed` + `maskFromPoint`. mask-ის საზღვრებიდან გამოდის `box`, `MaskContours`-დან — კონტური ფოტოზე.
  3. SAM-ის deadline 1 წმ-ია. დაგვიანებისას იგზავნება 200×200 (0–1000 შკალაზე) კვადრატი თითის გარშემო, გვიანი შედეგი უარყოფილია.
- **`PhotoAskSheet`** („შეეხე და იკითხე", medium/large): სწრაფი კითხვები „ეს რა არის?" / „მოვხსნა?" / „რა ზომაა?", თავისუფალი ტექსტი ≤200, გაუქმება, „სცადე თავიდან".
- **მოთხოვნა**: მთელი ნაჩვენები ფოტო ≤768, ასპექტით, JPEG 0.85. `context` = `AskContext(object:)`. provider — `photoAIProvider`, default Gemini.
- **`PhotoAskAnswer`**: `stop` → წითელი „გაჩერდი"; confidence ≠ high → „სავარაუდო". ზომაზე: „დადასტურებული" (seen/model) ან „სავარაუდო — შეამოწმე" + fitCheck. `suggestStep` → ღილაკი „ნაბიჯების გაგრძელება: …".

## შეზღუდვები

- iOS check_photo ჯერ არ არის. worker-ის კონტრაქტი მხოლოდ mock ტესტებითაა დაფარული.
- iOS ask-ში `context` მხოლოდ `object`-ს აგზავნის. `doneSteps` და `answers` worker-ს ესმის, მაგრამ აპი მათ ჯერ არ აწვდის.
- `PhotoResultView.askContinue` `PhotoFlowView`-ში არ არის მიერთებული (default `{ _ in }`). „ნაბიჯების გაგრძელება" ახლა მხოლოდ sheet-ს ხურავს.
- ask-ის ზომის „დადასტურება" ტექსტურ მტკიცებულებაზეა დაფუძნებული, ფოტოს პიქსელებს სერვერი არ ამოწმებს. Gemini-ზე YXYX თანმიმდევრობა mock-ითაა შემოწმებული.
- SAM CPU-ზე ზოგჯერ 1 წმ-ზე მეტს საჭიროებს. მაშინ ზონა უხეში კვადრატია, ნაწილის კონტური არ ჩანს.
- Smoke არტეფაქტები: `/Users/beqolozi/Developer/kadri-e2e-artifacts/ask-2026-10-18/smoke/`.

## შედეგები (E2E)

### check_photo — მომზადება 2026-10-18

Autopilot-ის `check-N.request.json` შეიცავს `needs_check_photo` prompt/reason-ს;
სკრიპტი `check-N.png`-ს აწვდის `PhotoSession.continueWithCheckPhoto`-ს. round არ იზრდება,
ფოტო პირდაპირ steps-ში მიდის. ცალკე ლიმიტია 20; `summary.json` შეიცავს `checkPhotos`-ს.
`--prefer-photo-answers` ირჩევს „ფოტოს გაჩვენებ“-ს, თუ ვარიანტებში არის;
მის გარეშე პასუხს ისევ Codex ირჩევს.

უფასო Python საცდელი ნაკადი (check → photo answer → check → complete) და ხარჯის
დათვლის შემოწმება გაიარა. `PhotoAutopilotTests`-ში დამატებულია MockCheckPhotoAPI სცენარი:
ერთი parts მოთხოვნა, steps image/context, უცვლელი round და ორი შემოწმების ფოტო.
`build-for-testing` წარმატებულია (`/tmp/kadri-dd-e2e-check`);
ტესტის შესრულება და staging Gemini E2E ელოდება სიმულატორის გადმოცემას.
ფასიანი მოთხოვნები ამ ეტაპზე: 0; ხარჯი: $0.00. ეს ჯერ არ არის მოდელის ხარისხის შეფასება.
