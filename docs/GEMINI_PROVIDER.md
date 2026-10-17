# Gemini provider — 2026-10-18

NETA-ს Photo აღწერის ეკრანზე გაგზავნამდე არის `Astra / Gemini` segmented control, Debug-სა და Release-ში. არჩევანი ინახება UserDefaults-ის `photoAIProvider` გასაღებით. `SessionModel.submit(provider:)` აფიქსირებს არჩევანს მთელი სესიისთვის: parts, steps, retry, ახალი ფოტო და პასუხი/გაზომვა. default Astra მოთხოვნაში provider-ს არ აგზავნის.

## ჩართვა და კონტრაქტი

- `POST /ai/parts`: JSON ან multipart ველი `provider=gemini`.
- `POST /ai/steps`: JSON ველი `"provider":"gemini"`.
- ველი მიიღება მხოლოდ `ALLOW_PROVIDER_SELECTION="true"`-ზე: dev და staging ჩართულია, production გამორთულია. გამორთულ გარემოში explicit provider აბრუნებს HTTP 400-ს; უცნობი სახელი ასევე 400-ია. ველის გარეშე ინარჩუნებს deployment-ის Astra default-ს.
- `GEMINI_API_KEY` საჭიროა მხოლოდ Gemini-სთვის. საიდუმლო გადაეცემა `x-goog-api-key` header-ით. staging-ზე დაყენებულია stdin-ით; ლოკალური `.dev.vars` gitignored-ია და აქვს mode 600. საიდუმლო არც ანგარიშშია და არც git-ში.
- მოდელი `gemini-3.8-flash`, `thinkingLevel=low`, `maxOutputTokens=8192`, `responseJsonSchema`. [Google REST კონტრაქტი](https://ai.google.dev/api/generate-content).
- Gemini-ის `box_2d=[ymin,xmin,ymax,xmax]` გარდაიქმნება აპის `box=[x0,y0,x1,y1]`-ში, ყველა კოორდინატი 0–1000. არავალიდური/ნულოვანი ფართობის box უარყოფილია; p1…pN-ს სერვერი ანიჭებს.
- ტრანსპორტის პასუხები გადადის არსებულ ვალიდატორში: `StepsStreamParser`, `tidyStep`, `tidyContinuation`, capabilities, answers, Knowledge Hub და round/answer ლიმიტები ორივე provider-ს საერთო აქვს. `streamGenerateContent?alt=sse` ინკრემენტულად იძლევა `event: step`-ს; ბოლოს მოდის იგივე `done` continuation-ით. iOS-ის Gemini-სთვის განსხვავებული decoder არ დამატებულა.
- guarded route აკეთებს ერთ retry-ს მხოლოდ `ai_invalid_response`/timeout-ზე. უკვე გაგზავნილი ნაბიჯის შემდეგ retry არ ხდება.
- ტარიფი: input $0.75/M, output $3.75/M. Output არის `max(candidatesTokenCount + thoughtsTokenCount, totalTokenCount - promptTokenCount)`; thinking ჩაიწერება reasoningTokens-შიც. ტარიფის წყარო: `experiments/som-test/gemini_stage1.py` და [Google pricing](https://ai.google.dev/gemini-api/docs/pricing). ეს usage-ით შეფასებაა, არა ინვოისი.

## შემოწმება და staging

- Worker: `npm run typecheck`; `npx vitest run` — **203/203**.
- KadriCore: `swift test` — **117 ტესტი, 0 შეცდომა, 1 live ტესტი გამოტოვებული**. პირველ პარალელურ build-ზე არსებული grid performance ტესტი იყო 5.034 ms (>5 ms); build-ის დასრულების შემდეგ სრული განმეორებითი გაშვება წარმატებულია.
- `xcodebuild build -project ios/Kadri.xcodeproj -scheme Kadri -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/kadri-dd-gemini` — **BUILD SUCCEEDED**.
- ტელეფონი/სიმულატორი არ გაშვებულა; UI/snapshot ტესტები და ეკრანის ვიზუალური შემოწმება არ შესრულებულა ამ აკრძალვის გამო. რეალურ მოწყობილობაზე UI შემოწმება მთავარ სესიას რჩება.
- Mock ტესტები ამოწმებს YXYX→XYXY-ს, ნაწილებს, ნაბიჯის გამოჩენას upstream-ის დასრულებამდე, ოთხივე continuation kind-ს, invalid JSON/timeout retry-ს, პირველი ნაბიჯის შემდეგ retry-ის აკრძალვას, gate-ს და D1 usage/pricing-ს. Swift ტესტი გადის answer→photo→retry-ზე და ამოწმებს ორივე wire მოთხოვნის provider-ს.
- Deploy-მდე `PARTS_REGRESSION_CHECK`: 6 Astra მოთხოვნა, **$0.088937**, რეგრესია არ არის; რაოდენობები 5/2/7. ახალი↔ძველი საშუალო IoU: 0.884 / 0.916 / 0.868. სამივე box-ების სურათი შემოწმებულია.
- staging Worker version: **7480a208-80f8-4dcd-a754-fd9be6895c30**, `/health.version=6937e8e`; `deploy_check` სამივე შემოწმება გავიდა. Production არ შეცვლილა.

## Parts შედარება

Astra არის ამ ცვლილების local regression გაშვება; Gemini — ახალი staging გაშვება. იგივე realism ფოტოებია; JPEG ხარისხი სკრიპტებში შესაბამისად 88/90-ია. თითო ფოტოზე ერთი ცდაა. IoU ქვემოთ ორივესთვის ერთნაირად ითვლება: greedy ერთ-ერთზე geometry matching; დაუწყვილებელი reference=0. ეს გეომეტრიული მეტრიკაა და არა სემანტიკური ხარისხის შეფასება.

| ფოტო | ნაწილები Astra / Gemini | IoU reference-თან Astra / Gemini | Gemini↔Astra IoU | პირველი box, სერვერი, წმ Astra / Gemini | ფასი Astra / Gemini |
|---|---|---|---|---|---|
| sink | 5 / 5 | 0.714 / 0.756 | 0.834 | 4.952 / 3.608 | $0.008271 / $0.002272 |
| car | 2 / 2 | 0.866 / 0.803 | 0.883 | 3.182 / 3.067 | $0.013710 / $0.001656 |
| gym | 7 / 7 | 0.868 / 0.844 | 0.873 | 7.432 / 4.132 | $0.010261 / $0.002727 |

პირველი box აქ ნიშნავს სრულ, ვალიდურ parts პასუხს (ეს ეტაპი stream არ არის). Gemini-ის კლიენტის wall time: sink 4.111 წმ, car 3.579 წმ, gym 4.329 წმ. ფოტოებზე შემოწმებულია: sink-ის მარჯვენა ქანჩი და ორი ჩამკეტი სწორია; Gemini სიფონს უფრო მჭიდროდ მოიცავს. Car-ზე სწორია შავი ხუფი და ყვითელი საზომი. Gym-ზე ორივე არჩევს შვიდივე დეტალს, მათ შორის პატარა წონის ქინძისთავს და სავარძლის რეგულატორს. წონის დასტის box ორივეგან ქვედა კონსტრუქციასაც ნაწილობრივ მოიცავს.

## ნაბიჯები: sink

| მეტრიკა | Astra — ისტორიული reference | Gemini — ახალი staging |
|---|---|---|
| ნაბიჯები | 5 | 5 |
| პირველი ნაბიჯი, stage დრო | 6.923 წმ | 3.109 წმ server / 3.374 წმ wall |
| სრული steps დრო | 25.241 წმ | 6.940 წმ server / 7.189 წმ wall |
| steps ფასი | $0.104125 | $0.006385 |
| SSE თანდათან მოდის | ისტორიული streaming | პირველი 3.374, მეორე 4.023, მეხუთე 6.946 წმ; done 7.165 წმ |
| continuation | ძველი reference | complete |

ეს არ არის ერთდროული steps A/B ტესტი: Astra მონაცემები აღებულია `out_realism/c_astra_tracking/sink/sink-trap/original/run_1/{metrics.json,steps_request/metrics.json,plan.json}`-დან. ახალი Astra steps ფასიანი მოთხოვნა არ გაშვებულა. პრომპტის მიმდინარე შეზღუდვები და Knowledge Hub ისტორიულ გარემოსაც განსხვავდება; სიჩქარის/ხარისხის ზოგადი უპირატესობა ამ ერთი მაგალითით არ დასტურდება.

Gemini-ის ხუთივე ნაბიჯი ქართულადაა. ჩამკეტებზე focus=[p2,p3], უხილავ ვედროზე focus=[], სველ მარჯვენა ქანჩზე focus=[p4], შუასადების შემოწმებისას ხილულ სიფონზე focus=[p5]. `unknownParts` სწორად შეიცავს ვედროსა და შიდა რეზინის შუასადებს. თუმცა შუასადების ნაბიჯზე არ ხსნის, რომ p5 მხოლოდ მის გარე კორპუსს აღნიშნავს.

უსაფრთხოების განსხვავება: Gemini აფრთხილებს პლასტმასის კუთხვილის დაზიანებაზე და ინსტრუმენტის არგამოყენებას ითხოვს; ყველა `avoid` ცარიელია. ისტორიულ Astra-ს ქანჩის ეტაპზე avoid=[p1] ჰქონდა, გაჭედილ ონკანზე ძალის არდატანას და სიფონის მოხსნამდე დამჭერი შეერთებების გათავისუფლებასაც განმარტავდა. Gemini-ის „მოხსენი მუხლი“ ამ განმარტებას ტოვებს. ამიტომ თანაბარი უსაფრთხოების დეტალიზაცია არ დადასტურდა.

## ხარჯი და გამეორება

ფაქტობრივი usage-ით შეფასება: Astra regression **$0.088937**, Gemini სამი parts **$0.00665475** + ერთი steps **$0.00638475** = სულ **$0.1019765**, ავტორიზებული $0.50-დან. D1-ში Gemini არის ზუსტად 3 parts + 1 steps, ყველა `ok`, retry არ ყოფილა; provider/model სწორად ჩაიწერა, ამ კონკრეტულ პასუხებში thinking=0. Thinking-ის დათვლა ცალკე mock-ითაა შემოწმებული.

`live_check.mjs`-ს დაემატა `--provider gemini` და `--realism <path>`. Ledger ყოველი Gemini მოთხოვნისთვის ორ ცდას წინასწარ ჯავშნის; წარმატების შემდეგ დამატებითი ცდის რეზერვს კონსერვატიულად ინარჩუნებს. ამიტომ ledger ceiling **$0.2728565**-ია, ფაქტობრივ შეფასებაზე მაღალი და მაინც $0.50-ზე ნაკლები. გაშვება:

```sh
cd backend/worker
PATH=/opt/homebrew/opt/node@22/bin:$PATH node --env-file=/path/to/staging.env scripts/live_check.mjs \
  --provider gemini --realism /path/to/out_realism/c_astra_tracking \
  --runs 1 --cap 0.50 --url https://kadri-worker-staging.bekachkhirodze1.workers.dev
```

მეორედ გაშვება ახალი ფასიანი სამუშაოა: მიმდინარე ledger უნდა შენარჩუნდეს და ახალი ავტორიზებული ბიუჯეტი ჰქონდეს. არტეფაქტები worktree-ში: `backend/worker/scripts/out/live_check_gemini.json`, `parts_compare.json`, `gemini_compare_{sink,car,gym}.jpg`, `scripts/ledger.json` (gitignored). შემოწმების ლოგები `/tmp/kadri-gemini-checks/`-შია.

ცოცხალი steps შემოწმება ძველი ინსტრუქციების სიითა და ფოტოთი შესრულდა; needs_answer/needs_measurement/summary ცოცხლად არ გამოგვიცდია, მათი კონტრაქტი mock ტესტებითაა დაფარული. აპი steps-ზე ჯერ ისევ `image:nil`-ს აგზავნის — ეს დავალება იმ ქცევას არ ცვლის. სურვილისამებრ შედეგის provider badge არ დამატებულა.
