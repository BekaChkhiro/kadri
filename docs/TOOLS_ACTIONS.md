# ხელსაწყოს ბარათები, მოქმედებები და ხელის მინიშნებები — 2026-10-18

T5.14 (`tools_v2`) და `hands_v1`. ნაბიჯს ემატება სამი სია: `toolCards` — რომელი ხელსაწყო, რა ზომის და რამდენად დადასტურებულია ზომა; `actions` — ანიმირებული მოქმედება ფოტოს ნაწილზე; `hands` — სად და რომელი ხელით მოკიდოს. მთავარი პრინციპი: AI ზომაზე არასდროს ცრუობს. დაუდასტურებელი ზომა ყოველთვის „სავარაუდოა" და თან ახლავს, როგორ შეამოწმოს თავად.

## Capabilities და თავსებადობა

- `POST /ai/steps`-ის `capabilities`-ში `"tools_v2"` და/ან `"hands_v1"` (`backend/worker/src/ai/validate.ts` `parseCapabilities`; ცნობილი სია `schema.ts` `CAPABILITIES`). უცნობი სტრიქონი იგნორირდება.
- iOS ორივეს აგზავნის: `KadriAPI.swift` — `["needs_answer", "needs_measurement", "summary", "tools_v2", "hands_v1"]`.
- capability-ის გარეშე prompt და schema ბაიტამდე უცვლელია, step event-ში ახალი გასაღებები არ ჩნდება. ამას იცავს `test/ai-continuation.test.ts`-ის `locks the legacy prompt and schema` (SHA-256 inline snapshot-ები) და `legacy request sends no new keys` / `legacy request sends no hands` (`ai-tools`, `ai-hands`).
- schema-ში capability-სთან ერთად სამივე ველი სავალდებულოა (strict). ნაწილების გარეშე (`ids=[]`) `actions` და `hands` `maxItems: 0`-ია.
- რომელიმე ცნობილი capability-ის დროს legacy output-ბიუჯეტი არ გამოიყენება (`provider.ts`).

## Wire ფორმატი (`event: step`)

```jsonc
"toolCards": [{                       // ≤3
  "id": "ph2",                        // TOOL_CATALOG-დან
  "size": "PH2",                      // string ≤12 | null
  "sizeSource": "seen",               // seen | model | typical
  "fitCheck": null,                   // ≤100; typical-ზე ყოველთვის არის (ზომიან ხელსაწყოზე)
  "alternatives": [],                 // ≤2 სხვა ზომა
  "why": "ჭანჭიკის თავი ჯვარედინია", // ≤60
  "notThis": { "id": "pliers", "reason": "წახნაგები დაზიანდება" } // ≤60 | null
}],
"actions": [{                         // ≤3
  "part": "p2",
  "kind": "rotate_ccw",               // rotate_cw|rotate_ccw|press|pull|lift|slide|lever_up|lever_down|align|tighten_order
  "amount": "¼",                      // ¼ | ½ | 1 | hand_tight_plus_quarter | null
  "order": null                       // [pN] მხოლოდ tighten_order-ზე
}],
"hands": [{                           // ≤2
  "part": "p3",
  "grip": "support",                  // hold | turn | push | pull | support
  "hand": "left",                     // left | right | both
  "byHandOnly": false
}]
```

- `sizeSource`: `seen` — ზომა ფოტოზე/ეტიკეტზე იკითხება; `model` — ცნობილი მოდელის სპეციფიკაციიდან (მომხმარებლის ტექსტი ან Knowledge Hub); `typical` — ყველაზე გავრცელებული, დაუდასტურებელი.
- KadriCore: `Step.toolCards: [StepToolCard]?`, `Step.actions: [StepAction]?`, `Step.hands: [StepHand]?`. decoder `StepHand.isSupported`-ის გარეშე ჩანაწერებს ფილტრავს (`Models.swift`).

## კატალოგი (32)

`backend/worker/src/ai/tools.ts` `TOOL_CATALOG`; იგივე რიგით `KadriCore/ToolCatalog.swift` და `gen_tool_illustrations.py`. asset: `ToolCatalog.assetName(id)` = `tool-<id>` (`ios/Kadri/Assets.xcassets/Tools/`).

| id | სახელი | asset |
|---|---|---|
| ph1 | ჯვარედინი სახრახნისი PH1 | tool-ph1 |
| ph2 | ჯვარედინი სახრახნისი PH2 | tool-ph2 |
| flat_small | ბრტყელი სახრახნისი (პატარა) | tool-flat_small |
| flat_large | ბრტყელი სახრახნისი (დიდი) | tool-flat_large |
| torx_t10 | Torx სახრახნისი T10 | tool-torx_t10 |
| torx_t20 | Torx სახრახნისი T20 | tool-torx_t20 |
| hex_key | ექვსკუთხა გასაღები | tool-hex_key |
| adjustable_wrench | რეგულირებადი გასაღები | tool-adjustable_wrench |
| open_wrench | ქანჩის გასაღები | tool-open_wrench |
| socket_wrench | თავაკიანი გასაღები | tool-socket_wrench |
| pipe_wrench | მილის გასაღები | tool-pipe_wrench |
| pliers | ბრტყელტუჩა | tool-pliers |
| needle_pliers | წვრილტუჩა | tool-needle_pliers |
| wire_cutter | მავთულის საჭრელი | tool-wire_cutter |
| wire_stripper | კაბელის გამწმენდი | tool-wire_stripper |
| crimper_rj45 | RJ45 კრიმპერი | tool-crimper_rj45 |
| multimeter | მულტიმეტრი | tool-multimeter |
| voltage_tester | ძაბვის ინდიკატორი | tool-voltage_tester |
| flashlight | ფანარი | tool-flashlight |
| bucket | ვედრო | tool-bucket |
| towel | ტილო | tool-towel |
| gloves | ხელთათმანები | tool-gloves |
| antistatic_strap | ანტისტატიკური სამაჯური | tool-antistatic_strap |
| thermal_paste | თერმოპასტა | tool-thermal_paste |
| cable_ties | კაბელის სამაგრები | tool-cable_ties |
| tape_measure | რულეტკა | tool-tape_measure |
| level | თარაზო | tool-level |
| drill | დრელი | tool-drill |
| hammer | ჩაქუჩი | tool-hammer |
| utility_knife | საკანცელარიო დანა | tool-utility_knife |
| plumber_tape | ფუმლენტა | tool-plumber_tape |
| spudger | პლასტმასის სპუჯერი | tool-spudger |

ზომა აზრიანია მხოლოდ სახრახნისებზე (ph*, flat_*, torx_*), `hex_key`/`open_wrench`/`socket_wrench`-ზე, `adjustable_wrench`/`pipe_wrench`-ზე და `drill`-ზე (`toolHasSize`). დანარჩენზე size, fitCheck და alternatives ყოველთვის ცარიელია.

## Validator (`validate.ts` `tidyStep`)

- **ბარათები** (`tidyToolCards`): უცნობი ან განმეორებული `id` — ბარათი იშლება; `notThis` უცნობი id-ით ან იგივე id-ით → `null`; ტექსტები `clampText`-ით; ≤3.
- **sizeSource ჩამოყვანა evidence-ით** (`provider.ts` `sizeEvidence`: ნაწილების სახელები + instructions + answers + Knowledge Hub):
  - `seen` → `typical`, თუ ზომის ბირთვი (`PH2`, `M6`, `10`, `T20`; ასოები/ციფრები, `,`→`.`) evidence-ის token-ებში არ არის. token-ები იყოფა `M6x20`→`M6`,`20` და `PH 2`→`PH2`-ადაც.
  - `model` → `typical`, თუ მოდელი უცნობია (Knowledge Hub ცარიელია და ტექსტში მოდელის კოდი არ არის, მაგ. `WAN28`, `RTX-4070`).
  - `size=null` → ყოველთვის `typical`.
- **fitCheck**: `typical`-ზე მოდელის fitCheck-ი რჩება; ცარიელზე სვამს `genericFitCheck(id)`-ს (სახრახნისი — „მჭიდროდ უნდა ჩაჯდეს და არ ამოხტეს…", ფიქსირებული გასაღები — „…სცადე 1 მმ-ით პატარა/დიდი…", რეგულირებადი — „ყბები მჭიდროდ მოარგე…", დრელი — „ბურღის დიამეტრი დიუბელს უნდა ემთხვეოდეს…").
- **alternatives**: უნიკალური, ზომის გარდა, ≤2.
- **actions** (`tidyActions`): უცნობი/უსახელო part ან უცნობი kind → იშლება; დუბლიკატი `part:kind` → ერთი; `amount` მხოლოდ `rotate_cw`/`rotate_ccw`/`tighten_order`-ზე; `order` მხოლოდ `tighten_order`-ზე, ≥2 ცნობილი ნაწილით, სხვაგვარად `null`; ≤3.
- **hands** (`tidyHands`): უცნობი part/grip/hand → იშლება; ერთი ჩანაწერი თითო `part:hand`-ზე; ≤2.
- **byHandOnly**: თუ `hands` არაცარიელია და ყველა `byHandOnly=true`, `toolCards` ცარიელდება (გაფრთხილება ლოგში). ერთი `false` საკმარისია, რომ ბარათები დარჩეს.
- `stepRuleError` ამოწმებს `actions[].part`, `order` და `hands[].part`-საც — ყველა უნდა იყოს ცნობილი label-ით.

## Prompt-ის წესები (`prompts.ts`)

- `toolsRule()`: ≤3 ხელსაწყო მხოლოდ კატალოგიდან (სია prompt-შია); „ზომა არასოდეს გამოიგონო"; ეჭვისას `typical`; typical-ზე fitCheck სავალდებულოა („დაიწყე 10 მმ-ით; თუ თავისუფლად ბრუნავს, სცადე 11; ზუსტი არ გაქვს — რეგულირებადი გასაღები"); seen/model-ზე fitCheck null და alternatives ცარიელი; `notThis` — როცა ტიპური არასწორი ხელსაწყო აზიანებს; `amount` მხოლოდ თუ ნამდვილად იცის; `tighten_order` — ჯვარედინი თანმიმდევრობა.
- `handsRule()`: ≤2; ორი ხელი = ორი ჩანაწერი (მაგ. `support left` + `turn right`); `byHandOnly=true` მხოლოდ მაშინ, როცა ხელსაწყო ნამდვილად არ სჭირდება; ეჭვისას `false`; ცხელ, მბრუნავ ან ძაბვის ქვეშ მყოფ ნაწილზე `hold` არ მისცეს და `warn`-ში დაწეროს.

## iOS

- **`ToolCatalog`** (KadriCore): `ids`, `names`, `name(_:)`, `assetName(_:)`. უცნობი id-ის ბარათი არ ჩანს.
- **`PhotoToolCard`** (`PhotoStepCard`-ში ≤3 ბარათი):
  - ილუსტრაცია 64 pt; asset-ის გარეშე SF Symbol fallback.
  - წვერის ხატულა ქვედა კუთხეში: ჯვარი (ph*), ვარსკვლავი (torx_*), ხაზი (flat_*). ასე clay ილუსტრაციები ერთმანეთისგან ირჩევა.
  - ზომის badge: დადასტურებული (`seen`/`model` და ზომა არის) — ლურჯი, „დადასტურებული" ✓. სხვა შემთხვევაში — ყავისფერი `≈ PH2`, „სავარაუდო — შეამოწმე", fitCheck-ის ტექსტი და „ან PH1" ჩიპები.
  - `notThis` — წითელი ზოლი „არა: <სახელი> — <მიზეზი>".
  - ზომის გარეშე სახრახნისზე badge-ის ნაცვლად ტიპი ჩანს („ჯვარედინი" / „Torx" / „ბრტყელი").
- **`PhotoByHandCard`**: „ხელით შეგიძლია — ხელსაწყო არ სჭირდება", როცა ბარათები ცარიელია და ერთი hand მაინც `byHandOnly`-ია.
- **`PhotoActionOverlays`** (`PhotoOverlays.swift`-დან, ფოტოზე): `rotate_*` amount-ის გარეშე — არსებული `TurnArrowView`; amount-ით — 90°/180°/360° რკალი და „¼"/„½"/„1"/„ხელით + ¼" ნიშანი; `press` — მზარდი წრე და ისარი; `pull` / `lift` (წყვეტილი ჩარჩო მაღლა მიიწევს) / `slide` (წყვეტილი); `lever_up`/`lever_down` — 45° ბერკეტი; `align` — ორი ერთმანეთისკენ მიმავალი სამკუთხედი; `tighten_order` — ნომრიანი წრეები, აქტიური ლურჯად მოძრაობს 3 წმ ციკლით. ≤3 action; part-ის box-ის გარეშე არაფერი იხატება. Reduce Motion (სისტემური ან `photoOverlayReduceMotion`): `PhotoActionFrame` `progress=1`-ით — სტატიკური საბოლოო კადრი. snapshot-ებიც იგივე კადრს იყენებს.
- **`PhotoHandOverlays`**: ხელის კონტური (`both` → ორი სარკისებური ხელი), `turn`/`push`/`pull` მოძრაობის ისრით, `support` 65% გამჭვირვალობით. თუ იმავე ნაწილზე action არის, ხელი `hold`-ად იხატება და ქვემოთ იწევს, რომ ისრებს არ ეჯახებოდეს. pin-ებს ქვემოთ გადაუვლის. Reduce Motion-ზე პულსაცია არ არის.

## ილუსტრაციები

- `ios/Tools/gen_tool_illustrations.py` იძახებს ადამიანის ლოკალურ `codex exec`-ს (API key-ებს არ კითხულობს) და წერს `Assets.xcassets/Tools/tool-<id>.imageset/<id>.png`-ს (512 px). ყველა: `python3 ios/Tools/gen_tool_illustrations.py`; გასწორება: `--ids ph2,level --fix "…"`.
- სტილი: მქრქალი 3D clay; 3/4 კუთხე, დიაგონალზე ქვედა-მარცხნიდან ზედა-მარჯვნივ; ~80% ტილო; რბილი ჩრდილი; სუფთა თეთრი ფონი. ფერები: თეთრი, ღია ნაცრისფერი, brand `#2F6BFF` სახელურზე, თბილი ნეიტრალური მხოლოდ ბუნებრივ ადგილას. შავი არ არის, ლითონი ღია ვერცხლისფერია. ტექსტი, ციფრი, ლოგო, ხელი ან სხვა ობიექტი არ არის.

## სქრინშოტები

`/Users/beqolozi/Developer/kadri-e2e-artifacts/tools-anim-2026-10-18/`. იქ არის: `tools-seen-typical.png`, `tools-tip-types.png`, `tools-accessibility.png`, `tools-long-step-{top,bottom}.png`, `actions-frame-{0,1,2}.png`, `rotate-quarter-reduce-motion.png`, `tighten-order-{on-photo,reduce-motion}.png`, `hands-*.png` (hold-turn, both-hold/push/pull/support, by-hand-card, live-step), `smoke-*.png` და build/UI ლოგები.

## შეზღუდვები

- „დადასტურებული" ნიშნავს, რომ ზომა ტექსტურ მტკიცებულებაში ჩანს (ნაწილის სახელი, ინსტრუქცია, პასუხი) ან მოდელი ცნობილია. ფოტოს პიქსელებს სერვერი დამოუკიდებლად არ ამოწმებს. თუ მოდელმა ნაწილის label-ში ზომა თავად ჩაწერა, `seen` შენარჩუნდება.
- `model`-ის შემოწმება მხოლოდ იმას ადგენს, ცნობილია თუ არა მოდელი (Knowledge Hub ან მოდელის კოდი ტექსტში). ზომა კონკრეტულ სპეციფიკაციას არ ედარება.
- action/hand იხატება მხოლოდ ფოტოზე ამოცნობილ ნაწილზე (box). უხილავ ნაწილზე მინიშნება არ ჩანს.
- `amount`-ის მოცემა მოდელზეა დამოკიდებული. როცა არ იცის, null-ია და ანიმაცია რაოდენობის გარეშე ჩანს.

## შედეგები (E2E)

2026-10-18: staging `4d192c11-3c7c-4d0a-ae2d-50c13e0d1195`, checkout snapshot `cbc5fdc`.
Gemini (`gemini-3.8-flash`), მიმდინარე HEAD-ის Debug build, iPhone 17 `6C9A34B2…`.
`e2e_codex_loop.py --reuse --max-rounds 1`, `photoAIProvider=gemini`; PC seed `pcg-s1`,
სიფონი `run-20261017-222846`. ფოტოები თავიდან არ გენერირებულა.

| სცენარი | შედეგი | scan / პირველი ნაბიჯი (აპი) | ხარჯი (D1, parts + steps) |
|---|---|---|---|
| PC | 18 ნაბიჯი, 5 პასუხი, complete; ბარათები, actions და hands ჩანს | 5.77 / 10.41 წმ | $0.049911 |
| სიფონი | 4 ნაბიჯი, შემდეგ needs_photo; ქანჩზე ბრუნვა და დამჭერი ხელი ჩანს | 4.73 / 7.91 წმ | $0.009071 |
| PC wire: სოკეტის გახსნა | lever_up + right/hold; byHandOnly=true → toolCards=[] | პირველი event 4.94 წმ; done 5.45 წმ | $0.004969 |
| PC wire: M.2 რადიატორის ხრახნი | PH1 typical, fitCheck, PH0/PH2 alternatives, notThis=flat_large; rotate_ccw + turn/support | პირველი event 6.02 წმ; done 6.87 წმ | $0.006635 |
| სიფონი wire | rotate_ccw; მარცხენა support / მარჯვენა turn; byHandOnly=true → toolCards=[] | პირველი event 5.30 წმ; done 6.08 წმ | $0.005912 |

T5.14 ჯამი **$0.076497** (ზღვარი $0.40). ყველა ფასიანი მოთხოვნა D1-ში `ok`, Gemini schema error აღარ განმეორდა.
Wire შემოწმებები ცალკე მოთხოვნებია და UI-ს იდენტური პასუხები არ არის: `PhotoAutopilot.resultJSON`
არ წერს toolCards/actions/hands-ს. ამიტომ ინახება აპის `round-1.result.json` და ცალკე `steps.json` SSE event-ები.
პირველი დამატებითი PC wire მოთხოვნა არასწორი სატესტო input-ის გამო HTTP 400 იყო (text აკლდა), ფასიანი AI არ გამოუძახებია.

**შეფასება და ხარვეზები:**

- PH1 ზომა დაუდასტურებელია და სწორად არის `typical`; მორგების ტექსტი ამოწმებს მჭიდრო ჩაჯდომას/სრიალს და PH0-ს სთავაზობს. `notThis=flat_large` აზრიანია. თუმცა `why` ამბობს „ზუსტად ერგება“ — ეს ზედმეტად კატეგორიულია typical ზომისთვის. seen/model ზომის ცოცხალი შემთხვევა არ მიგვიღია.
- სიფონის ქანჩის ბრუნვა სწორ რეგიონზეა. მეორე, დამჭერი ხელი ზუმისას ფოტოს ქვედა საზღვართან ნაწილობრივ იჭრება (`sink/shots/card-scrolled.png`).
- PC-ზე მინიშნებები ამოცნობილ ობიექტს მიჰყვება, მაგრამ აწყობის ზუსტ წერტილს ვერ აჩვენებს: SSD-ის ჩასმა — მაგიდაზე დადებულ SSD-ზე; დედაპლატის დამაგრება — ხრახნების პაკეტზე; JFP1 — მთელ დედაპლატაზე. სლოტის/ხრახნის ახლო ფოტო არ მოითხოვა. ხელები/ანიმაციები ამ შემთხვევებში ზუსტ ინსტრუქციად ვერ ჩაითვლება.
- PC ერთ ფოტოზე სრულ აწყობას სიტყვიერი პასუხებით ასრულებს; რეალური ჩასმა/დამაგრება არ გადამოწმებულა.
- ხელსაწყოს ბარათის სათაური/სურათი ჩანს, მაგრამ პირველ ხედში მისი ზომა/fitCheck ქვემოთ, ღილაკების მიღმა რჩება (`pc/shots/r1-steps-s3.png`, sink-ის პირველი ნაბიჯი). სრული ბარათის წაკითხვის ვიზუალური შემოწმება ამ გაშვებაში ვერ დადასტურდა; ხელის მინიშნების ქვედა ტექსტი scroll-ის შემდეგ იკითხება.
- `byHandOnly` ყველა toolCard-ს შლის, მათ შორის ვედროს/ტილოს, თუმცა legacy tools-ში ორივე რჩება (sink wire). ეს მიმდინარე კონტრაქტს ემთხვევა, მაგრამ დამხმარე ნივთების ბარათებსაც კარგავს.

Artifacts: `/Users/beqolozi/Developer/kadri-e2e-artifacts/tools-anim-2026-10-18/e2e/`:
`pc/`, `sink/` (report, JSON, shots), `pc-wire/`, `pc-tool-wire/`, `sink-wire/` (სრული SSE JSON),
`regression/` (შედარება და box-ების სურათები). ანიმაციის სხვადასხვა მდგომარეობა ჩანს ეტაპების screenshots-ში;
ყველა დამატებითი `animation-a/b` ფაილი ერთსა და იმავე ნაბიჯს არ ასახავს. კოდი არ შეცვლილა.
