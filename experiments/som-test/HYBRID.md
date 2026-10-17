# Gemini → SAM2 → Astra: შუალედური pilot

22-კადრიანი შეფასება ჯერ დასრულებული არ არის. production-ის კანდიდატობაზე საბოლოო დასკვნა ჯერ არ კეთდება.

## მეთოდი

ახალი თანმიმდევრული გაშვება: Gemini 3.8 Flash (`thinking=low`, `maxOutputTokens=2048`) → არსებული `assign_ids` → SAM2 → `gpt-6-astra` (`effort=low`, streaming). ეტაპი 2 იყენებს არსებულ `prompt_steps`, ID enum schema-ს და ისტორიული truth-ის იმავე title/text ინსტრუქციებს. ისტორიული Astra C თავიდან არ გაშვებულა.

22 thumbnail აღდგენილია `prepare_gemini.prepare(out_hybrid)`-ით და ისტორიული მოთხოვნების hash-ებით გადამოწმებულია. შენახული Gemini პასუხები არ არის გამოყენებული latency-ის ახალ გაზომვებში. Gemini countTokens-ის დრო შედის first box-სა და მთელ timeline-ში; ცალკეც ინახება. OpenAI-ს ახალი count preflight არ აქვს: არსებული `request_stage` წინასწარ არეზერვებს input-ის კონსერვატიულ შეფასებასა და 2200 output ტოკენს. ისტორიულ C-ს count preflight აქვს; ეს შედარება pipeline-ებისაა, არა მხოლოდ მოდელების inference-ის.

`out_hybrid/budget.json` ერთობლივად აკონტროლებს Gemini ≤$0.50, OpenAI ≤$2 და ჯამში ≤$2.50. უცნობი ფასი იბლოკება; SDK retries=0; დაწყებული ან წარუმატებელი კადრი ავტომატურად აღარ მეორდება. Gemini settlement ითვლის thinking-საც. Gemini countTokens უფასოდ არის მიჩნეული მომხმარებლის მითითებით. ტარიფები აღებულია არსებული კოდიდან.

## Sink original, ერთი ცდა

| მეტრიკა, წმ | Hybrid | ისტორიული Astra C |
|---|---:|---:|
| პირველი box | 6.981 | 7.492 |
| პირველი კონტური | 17.978 | 13.578 |
| პირველი სრული streaming ნაბიჯი, თავიდან | 25.952 | 20.507 |
| სრული დრო, render-ის ჩათვლით | 41.063 | 38.972 |

Gemini countTokens: 1.684 წმ; SAM: 10.951 წმ (ისტორიული 5.901 წმ). ამ ერთ ცდაში SAM-ის დროის განსხვავება მოდელის სიჩქარის შესახებ დასკვნას ზღუდავს. თითო კადრი ერთჯერადი გაზომვაა; განმეორებითი ცდებისა და ერთდროული საკონტროლო გაშვების გარეშე მიზეზობრივი speedup ვერ დგინდება.

ვიზუალურად შემოწმდა [parts.png](out_hybrid/runs/c_astra_tracking/sink/original/parts.png) და [ნაბიჯი 3](out_hybrid/runs/c_astra_tracking/sink/original/step_3.png), ასევე [plan.json](out_hybrid/runs/c_astra_tracking/sink/original/plan.json):

- ნაბიჯი 3: focus=`p4`, მარჯვენა ქანჩის კონტური სწორია; uncertainty ახსნილია.
- ნაბიჯი 2: focus=[], ვედრო უხილავადაა აღწერილი; ფონზე ყალბი სამიზნე არ შექმნილა.
- ნაბიჯი 3: avoid=`p2,p3`, ორივე წყლის ჩამკეტი წითლადაა გამოყოფილი.
- `p1` მთელ სიფონს აერთიანებს: ეტაპი 1-ის დეტალიზაცია ისტორიულის იდენტური არ არის.

Empty focus: ორივეგან 1/5. დიზაინის ხილულ პოლიგონებთან საშუალო focus IoU: Hybrid 0.3802, Astra 0.3989; avoid IoU: 0.6000 და 0.8000. ეს არის გეომეტრიული proxy და არა სემანტიკური სისწორის ქულა. ცარიელი ორივე მხარის union=0 შემთხვევები IoU=1-ით ითვლება. სინთეზური სურათები და დეგრადაციები რეალური ფოტოების ვალიდაციას ვერ ცვლის.

Pilot ფასი: Gemini $0.00226275; OpenAI $0.10031750; ჯამი $0.10258025. ეს token usage-ით დათვლილი შეფასებაა, არა ინვოისი.

## გამეორება და შემოწმება

`run_hybrid.py prepare`, `run_hybrid.py pilot --run`, `run_hybrid.py matrix --run`; offline შეჯამება: `report_hybrid.py`. Matrix უკვე დასრულებულ pilot-ს ტოვებს, რათა 22 უნიკალური კადრი შეფასდეს. დაწყებულ, მაგრამ დაუმთავრებელ კადრზე runner ჩერდება.

108 offline unittest გაიარა, მათ შორის 5 ახალი ტესტი: provider caps, reservation retention, retry-ის აკრძალვა, count/generation payload-ის თანხვედრა, usage settlement, streaming ID enum/low effort და pipeline-ის მიმდევრობა. სურათები ადგილობრივად გენერირდება; input.png და step_*.png commit-ში არ შედის.
