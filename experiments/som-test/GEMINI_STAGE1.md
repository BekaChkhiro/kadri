# Gemini — ვარიანტი C-ის ეტაპი 1

თარიღი: 2026-10-17. მიზანი: ქართული სახელებით ხილული სამოქმედო ნაწილების პოვნა და მჭიდრო box-ების დაბრუნება ≤5 წამში. მხოლოდ ეტაპი 1 და არსებული SAM2; ეტაპი 2 და OpenAI API არ გაშვებულა. Astra-ს შედარება **ისტორიულია**, იმავე დროს თავიდან არ გაზომილა.

## შედეგი — Astra-ს პირდაპირი ჩანაცვლება ჯერ არ დასტურდება

Flash-Lite 3.5 აკმაყოფილებს სიჩქარის მიზანს ამ 22 კადრში, მაგრამ ხარისხის აშკარა რეგრესიები აქვს. Flash 3.8 ხარისხით უფრო ახლოსაა Astra-სთან და სწრაფიცაა, თუმცა ≤5 წმ მიზანს 19/22 შემთხვევაში სცდება. **ერთდროულად „≤5 წმ და იგივე/უკეთესი ხარისხი“ არც ერთმა კანდიდატმა არ დაადასტურა.**

| მოდელი / ეტაპი 1 | n | პირველი box p50 / p90, წმ | ≤5 წმ | labels სულ / საშუალო | Astra-სთან IoU≥0.5 წყვილები | დიზაინის proxy IoU | generation ფასი |
|---|---:|---:|---:|---:|---:|---:|---:|
| Astra low — **ისტორიული** | 22 | 7.475 / 11.028 | 3/22 | 118 / 5.36 | — | 0.4055 | $0.53046¹ |
| Gemini 3.8 Flash low | 22 | 6.044 / 7.376 | 3/22 | 106 / 4.82 | 89/118 (75.4%) | 0.3979 | $0.054063 |
| Gemini 3.5 Flash-Lite minimal | 22 | 3.168 / 3.801 | 22/22 | 88 / 4.00 | 67/118 (56.8%) | 0.3269 | $0.025027 |

¹ Astra-ს ფასი ისტორიულ `parts_request/metrics.json`-ში შენახული ხელით მითითებული ტარიფითაა; ახალი ფასის გადამოწმება ან API მოთხოვნა არ გაკეთებულა. ცალკე count-preflight რეზერვები აქ გამორიცხულია. Gemini-ის $0.079090 matrix + $0.005756 pilot = **$0.084847**, $5 ლიმიტის 1.70%; სულ **47/47 წარმატებული მოთხოვნა**, შეცდომა/დარჩენილი რეზერვი 0.

Flash-ის median wall-time დაახლოებით 19.1%-ით ნაკლებია, Lite-ის — 57.6%-ით. Astra-ს count-preflight-ის გამოკლებით historical p50/p90 არის **6.849/10.587 წმ**; Gemini-ს უპირატესობის ნაწილი სწორედ preflight-ის არქონიდან მოდის. ეს სხვადასხვა დროს გაზომილი მონაცემებია; ქსელის/დატვირთვის ეფექტი და ერთი ცდა თითო კადრზე არ იძლევა სანდოობის გარანტიას. არც p90 არის hard SLA.

Gemini-ს box-ების საკუთარი რაოდენობის მიმართ Astra-სთან შეწყვილდა Flash-ის 89/106 (84.0%) და Lite-ის 67/88 (76.1%). Matrix usage: Flash input **36,799**, output **6,738**, thinking **319**; Lite input **36,799**, output **5,595**, thinking **0**. Astra ისტორიული input/output **21,505/5,233**; სხვადასხვა პროვაიდერის token-ები ერთმანეთის ეკვივალენტი არ არის. სრული ციფრები: [measurements.json](out_gemini/measurements.json), [matrix_summary.json](out_gemini/matrix_summary.json), [pilot_summary.json](out_gemini/pilot_summary.json).

## მეთოდი და გამეორება

22 დასრულებული ისტორიული კადრი: tracking 13 + stress 9; car 6, chemistry 3, gym 6, microscope 1, sink 6. ზუსტი სიაა [frames.json](out_gemini/frames.json). ყველა სცენა სინთეზურია. ეს არ არის რეალურ კამერაზე ანოტირებული semantic accuracy. psychology/laundry ამ დასრულებულ baseline-ში არ არის.

20 `input.png` აკლდა იზოლირებულ checkout-ს. მომხმარებლის თანხმობით აღდგა Camera/assets-ის მხოლოდ წაკითხვით, იმავე `realism.degrade`, seed და Lanczos thumbnail-ით. შემოწმდა საწყისი ფოტო/ground_truth/სრული გარდაქმნილი კადრის SHA256, transform metadata და **22/22 სრული ისტორიული parts-request hash** (მოიცავს PNG base64-ს). 2 შემორჩენილ thumbnail-ს აღდგენილი bytes ზუსტად ემთხვევა. baseline არ შეცვლილა; ახალი input-ები მხოლოდ `out_gemini/inputs/`-შია და commit-ში არ შედის. აღდგენა: `uv run python prepare_gemini.py`.

`gemini_stage1.py` იყენებს `variant_c.prompt_parts`-ის ზუსტად იმავე სემანტიკას; იცვლება მხოლოდ კოორდინატების დასახელება/რიგი. [ოფიციალური ფორმატი](https://ai.google.dev/gemini-api/docs/image-understanding): `box_2d=[ymin,xmin,ymax,xmax]`, 0–1000; ლოკალური ფორმაა `[xmin,ymin,xmax,ymax]`. არასწორი/შებრუნებული/არასასრული box იბლოკება, ავტომატურად არ სწორდება. IDs ენიჭება არსებული `assign_ids`-ით, კონტურები — `variant_b.segment_boxes/render_parts`-ით, SAM2.1 base, MPS.

[Thinking დოკუმენტაციით](https://ai.google.dev/gemini-api/docs/generate-content/thinking) Flash 3.8-ზე გამოყენებულია `thinkingLevel=low`, Robotics ER 2-სა და Flash-Lite-ზე `minimal`; 3.8-ის `minimal` არ არის მხარდაჭერილი. `thinkingBudget` არ იგზავნება. REST `generateContent`, structured JSON schema, ერთი candidate, `maxOutputTokens=8192` (thinking-ის ჩათვლით), retries=0. დამატებითი SDK არ დაგვჭირდა.

„პირველი box“ ნიშნავს სრული ვალიდური parts-პასუხის მიღებას, ქსელის ჩათვლით, SAM2-მდე — იგივე სრული პასუხის საზომი, რაც ისტორიულ C-ში. პირველი streamed token/ნაწილობრივი box არ გაზომილა. Gemini-ს დამატებითი count-preflight არ აქვს; Astra-ს ისტორიულ wall-time-ში preflight შედის. parsing-ის დრო ცალკე ინახება; SAM2-ის დრო `segmentation.json`-შია. ეს არ არის პირველი კონტურის ≤5 წამის გარანტია.

`match_frames(..., threshold=.5)` ერთსა და იმავე კადრზე ზომავს მხოლოდ ერთ-ერთზე box-შესაბამისობას Astra-სთან. არც Astra არის ground truth და არც ID-ის თანხვედრა ადასტურებს მნიშვნელობის თანხვედრას. დიზაინის proxy: თითო ხილულ truth-mask-ზე საუკეთესო SAM mask-ის IoU (`evaluation.iou`), საშუალო ყველა ხილულ დიზაინის ნაწილზე; არნაპოვნი mask = 0, სრულად დაფარული truth = გამორიცხული. გამოიყენება baseline-ის იგივე `truth_masks.npz`, რომელიც `mask_truth`-ის წყაროცაა. pin/button/tip-ს ცალკე ზუსტი truth ყოველთვის არ აქვს, ამიტომ ვიზუალური შეფასება აუცილებელია.

## Pilot — sink original, თითო ცდა

| მოდელი | პირველი box, წმ | ნაწილები | Astra box-ებთან თანხვედრა | დიზაინის proxy IoU | ფასი |
|---|---:|---:|---:|---:|---:|
| Flash 3.8 low | 5.429 | 4 | 3/5 | 0.450 | $0.002278 |
| Robotics ER 2 minimal | 6.089 | 4 | 2/5 | 0.456 | $0.002462 |
| Flash-Lite 3.5 minimal | 3.486 | 3 | 1/5 | 0.346 | $0.001017 |
| Astra low — ისტორიული | 7.492 | 5 | — | 0.414 | ცალკე ისტორიული ledger |

სამივე `parts.png` გაიხსნა და შეფასდა. [Flash 3.8](out_gemini/pilot/gemini-3.8-flash/c_astra_tracking/sink/original/parts.png) გამოყოფს ორივე სარქველს, სველ ქანჩსა და სიფონის ქვედა მრუდს. [Robotics](out_gemini/pilot/gemini-robotics-er-2-preview/c_astra_tracking/sink/original/parts.png) „სიფონის“ mask-ში ზედა მილსაც აერთიანებს, ცალკე ქანჩი სწორ მხარეს აქვს. [Lite](out_gemini/pilot/gemini-3.5-flash-lite/c_astra_tracking/sink/original/parts.png) სწრაფია, მაგრამ სიფონს საერთოდ არ აბრუნებს. სამივე ტოვებს უხილავ ვედროს/შუასადებს გამოუგონებლად.

მატრიცისთვის წინასწარ შეირჩა Flash 3.8 (უფრო ზუსტი დაყოფა და Robotics-ზე ნაკლები latency) და Lite (ერთადერთი ≤5 წმ კანდიდატი). Pilot-ში გამარჯვება ზოგად უპირატესობას არ ამტკიცებს. Pilot-ის შედეგები 22-კადრიანი საზომის ნაწილად არ ითვლება; matrix-ში sink original ხელახლა იზომება.

## ფასი და საზღვრები

[Google-ის ოფიციალური Standard paid pricing](https://ai.google.dev/gemini-api/docs/pricing), შემოწმებულია 2026-10-17: თითო 1M input/output token-ზე Flash 3.8 $0.75/$3.75; Robotics ER 2 $1/$5; Flash-Lite 3.5 $0.30/$2.50. პირველი ორი ტარიფი მოქმედებს 2026-12-31-მდე. უცნობი მოდელის ან ვადაგასული ფასის შემთხვევაში ადაპტერი API-ს ბლოკავს. Free-tier შეღავათი არ გვივარაუდია.

ცალკე [budget.json](out_gemini/budget.json), მაქსიმუმ $5. თითო მოთხოვნამდე რეზერვდება სრული 1,048,576 input-token ceiling + 8192 output-token; შემდეგ ანგარიშდება usage-ით, thinking-ის ჩათვლით. გაურკვეველი წარუმატებლობა ინარჩუნებს რეზერვს და ავტომატურად არ მეორდება. ეს არის usage-ით გამოთვლილი ფასი, არა ინვოისის დადასტურება. გასაღები არ ინახება არც request JSON-ში, არც ledger-ში.

## ვიზუალური შეფასება

AI ასისტენტის ვიზუალური განხილვაა, არა დამოუკიდებელი ადამიანის ანოტაცია. ვიზუალურად განხილულია 44/44 matrix parts.png საკონტაქტო ფურცლებზე და 3/3 pilot parts.png უშუალოდ; დამატებით ორი box-დეტალის crop და ისტორიული Astra gym original. Matrix-ის სურათები წარმოდგენილია [review/index.json](out_gemini/review/index.json)-ის საკონტაქტო ფურცლებზე; თითოეულს აქვს სცენა/გარდაქმნა და სრული labels. შესაბამისი `parts.json`, `segmentation.json` და `comparison.json` იმავე run-ის საქაღალდეშია.

- **car:** Flash 3.8 ხუთ დაუფარავ კადრში აბრუნებს ზეთის ხუფსა და საზომს; occlusion-ზე მხოლოდ საზომს. Lite ექვსივე კადრში მხოლოდ საზომს აბრუნებს — ხუთ დაუფარავ კადრში ხუფი გამოტოვებულია. Lite-ის original/shift კადრებში საზომის box/mask ღეროს მეტ ნაწილს მოიცავს და Astra-ს პატარა რგოლის box-ს IoU≥0.5-ით ვერ ემთხვევა. [Flash car](out_gemini/review/gemini-3.8-flash-01.jpg), [Lite car](out_gemini/review/gemini-3.5-flash-lite-01.jpg), [stress](out_gemini/review/gemini-3.5-flash-lite-04.jpg).
- **„არ შეეხო“:** ანტიფრიზი/მინის სითხე ცალკე ნაწილებად car-ის 6/6 კადრში არც ერთ Gemini-ს არ აქვს. ეს Astra-ს historical parts-საც აკლია; მხოლოდ ამ ტესტით Gemini-ს სპეციფიკურ რეგრესიად ვერ ჩაითვლება. `prompt_parts` იღებს მხოლოდ title/text-ს, არა truth-ის avoid-ს. დაკარგულ ნაწილს შემდგომი Astra ეტაპი 2 ID-ით ვეღარ მიუთითებს. არსებული prompt-ის სემანტიკა ექსპერიმენტში განზრახ უცვლელი დარჩა.
- **gym:** Flash-ის original/ორივე shift/dark კადრებში ქინძისთავის პატარა box მიზანს ზუსტად ერგება; blur-ზე „წონის ფილები ყვითელი ქინძისთავით“ ერთი ფართო box-ია. ქინძისთავის label არსებობა ცალკე სამიზნის არსებობას არ უდრის. [box-ის გადიდება](out_gemini/review/gym-gemini-3.8-flash-box-detail.png) აჩვენებს სწორ ადგილას პატარა rectangle-ს, მაშინ როცა [parts ფურცელზე](out_gemini/review/gemini-3.8-flash-02.jpg) SAM მთელ წონების ბლოკს იღებს. მსგავსი SAM შეცდომა [ისტორიულ Astra original-შიც](out_realism/c_astra_tracking/gym/gym-lat-pulldown/original/run_1/parts.png) ჩანს. ამიტომ ყველა კონტურის შეცდომა დეტექტორს არ მიეწერება. Lite-იც 4/5 დაუფარავ კადრში ცალკე pin box-ს აბრუნებს, მაგრამ shift_right-ში წონების დასტასთან აერთიანებს; blur-ზე ცალკე pin box აქვს, თუმცა SAM mask სცდება მცირე სამიზნეს. სავარძლის ღილაკს ორივე მოდელი ხუთივე დაუფარავ კადრში ცალკე აღნიშნავს; occlusion-ში დაფარულ დეტალებს არ იგონებს.
- **chemistry:** Flash სამივე კადრში აბრუნებს ბიურეტს და ონკანს, მაგრამ **წვერი ცალკე ID-ით 0/3**; Astra-ს სამიზნე უფრო წვრილადაა დაყოფილი. ბიურეტის საერთო box წვერის ნაწილს შეიძლება ფარავდეს — ეს ხილული პიქსელის სრული დაკარგვის ტოლფასი არ არის, მაგრამ ცალკე focus-ს ვერ უზრუნველყოფს. Lite original/shift_right-ში ბიურეტს მთლიანად ტოვებს და shift_left-ში აბრუნებს; წვერის ცალკე ID მასაც 0/3 აქვს. [Flash](out_gemini/review/gemini-3.8-flash-02.jpg), [Lite](out_gemini/review/gemini-3.5-flash-lite-02.jpg), [წვერის გადიდება](out_gemini/review/chemistry-gemini-3.8-flash-box-detail.png).
- **microscope:** Flash 13 ნაწილს გამოყოფს, მათ შორის ინდივიდუალურ ობიექტივებს, სამაგრებს, მცირე/დიდ ხრახნებს; Lite 8 ნაწილამდე აერთიანებს, რევოლვერს ობიექტივებიანად ერთ ნაწილად ტოვებს. 4×/40×-ზე შემდგომი მითითების თანაბარი სიზუსტე ამით არ დასტურდება. ორივეს აქვს ღილაკის label, მაგრამ მცირე ჩამრთველის ზუსტი mask ცალკე დასადასტურებელია. [Flash](out_gemini/review/gemini-3.8-flash-03.jpg), [Lite](out_gemini/review/gemini-3.5-flash-lite-03.jpg).
- **sink:** Flash პოულობს ორივე სარქველს და წვეთებიან მარჯვენა ქანჩს; სიფონის გაყოფა მეზობელ კადრებს შორის იცვლება. Lite original/shift კადრებში სიფონის U-ნაწილს ტოვებს, მიუხედავად იმისა, რომ ინსტრუქცია მის მოხსნას ითხოვს. Blur-ზე ზოგი სარქვლის mask შლანგზეც ვრცელდება. ეს პირდაპირი მიზეზია, რატომ არ კმარა მხოლოდ სწრაფი პასუხი. [Flash](out_gemini/review/gemini-3.8-flash-06.jpg), [Lite](out_gemini/review/gemini-3.5-flash-lite-03.jpg).

## რეკომენდაცია და ჰიბრიდი

შემდგომი ხარისხის კვლევის კანდიდატად ავირჩევდი **Gemini 3.8 Flash low**-ს. მისი parts-ის ფორმა თავსებადია C-ის IDs/SAM2-თან და ტექნიკურად შეიძლება Gemini ეტაპი 1 + Astra ეტაპი 2. ეს ჰიბრიდი **ამ ექსპერიმენტში არ გაშვებულა** და მისი end-to-end latency, ინსტრუქციების სისწორე ან უსაფრთხოება არ გაზომილა. ეტაპი 2 ვერ აღადგენს parts-ში გამოტოვებულ ID-ს; ამიტომ ჯერ საჭიროა დეტალებისა და avoid-ნაწილების completeness-ის გაუმჯობესება და რეალურ ფოტოებზე ცალკე ანოტირებული შეფასება.

**Lite-ს უცვლელი ჩანაცვლებისთვის არ ვურჩევ:** სიჩქარის მოგება მოდის, სხვა საკითხებთან ერთად, ნაკლები ნაწილების დაბრუნების ფონზე. უფრო სწრაფი წინასწარი მონიშვნის ექსპერიმენტი შესაძლებელი მიმართულებაა, მაგრამ საჭირო ნაწილების completeness-check/fallback ჯერ არ არსებობს და მისი ეფექტი არ გაზომილა. Flash-ის streaming-ით პირველი ვალიდური box-ის უფრო ადრე გამოჩენაც მხოლოდ შემდგომი შესამოწმებელი ვარიანტია, არა ამ შედეგის ნაწილი.

ამ 22 კადრში არ არის ახალი რეალური ფოტოები, chemistry stress-ის დასრულებული კადრები, laundry/psychology, tilt-crop/lowres/jpeg-ის სრული მატრიცა. მონაცემები ამ არყოფნილ შემთხვევებზე არ განზოგადდება. ქინძისთავისა და ღილაკის ცალკე box-ების 4/5 და 5/5 დაფარვა აღწერითი ვიზუალური დაკვირვებაა; calibrated recall/precision არ გამოთვლილა.

## შემოწმება და ბრძანებები

`uv run python -m unittest discover -s tests` — **103 ტესტი წარმატებით**, მათ შორის 9 ახალი API-ის გარეშე: კოორდინატების ასიმეტრიული კონვერტაცია, malformed/empty/truncated პასუხები, NaN/Inf/არასწორი box-ები, უცნობი ფასი, thinking-token billing, რეზერვი/settlement, retry-ის აკრძალვა, error-redaction და ცარიელი prediction-ის proxy. ტესტებში არსებული Astra-სტრიქონები mock-შედეგებია; OpenAI ქსელური მოთხოვნა არ გაკეთებულა.

Offline შედეგების განახლება: `uv run python report_gemini_stage1.py`. განზრახ ახალი ექსპერიმენტისთვის runner-ს სჭირდება `--run`; იმავე ledger-ის უკვე დარეზერვებული/გადახდილი მოთხოვნა ხელახლა არ იგზავნება. Saved შედეგის აღდგენა ახალ latency დაკვირვებად არ ითვლება.

გამოყენებული paid ბრძანებები:

```sh
uv run python run_gemini_stage1.py pilot --models gemini-3.8-flash gemini-robotics-er-2-preview gemini-3.5-flash-lite --run
uv run python run_gemini_stage1.py matrix --models gemini-3.8-flash gemini-3.5-flash-lite --run
```

ზემოთ მოცემული გაშვებებისას გამოყენებულია არსებული `.venv/bin/python` (`uv` dependency graph არ შეცვლილა). შენახულია ყველა response/usage, box, SAM mask, ვიზუალური overlay, შედარება და ledger; `.env`, `input.png`, `step_*.png` commit-ში არ შედის. Camera/ და .threadrig/ არ შეცვლილა.
