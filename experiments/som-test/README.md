# SoM ტესტი

სამი უცვლელი ფოტო → SAM2.1 automatic masks → დანომრილი ფოტო → OpenAI Responses strict JSON → ნაბიჯების ვიზუალური შემოწმება.

## გაშვება

```sh
cd experiments/som-test
uv venv --python 3.11
uv sync --locked
uv run python run.py --segment-only
uv run python -m unittest discover -s tests -v
```

SAM2.1_b-ის ოფიციალური წონები პირველ გაშვებაზე ჩამოიტვირთება `models/`-ში. Mac-ზე ავტომატურად MPS ირჩევა; სხვა გარემოში CPU. MPS პრობლემისას გამოიყენეთ `--device cpu --resegment`. `--resegment` შლის ამ სცენის ძველ API ცდებს/ნაბიჯების სურათებს, რადგან ID-ები შესაძლოა შეიცვალოს. შეინახეთ ისინი ცალკე, თუ შედარება გჭირდებათ.

API ეტაპისთვის `.env.example` დააკოპირეთ `.env`-ად და გასაღები ადგილობრივად ჩაწერეთ. შემდეგ:

```sh
uv run python run.py
```

key-ის გარეშე სეგმენტაცია სრულდება და პროგრამა სრულდება კოდით 2, რაც API ეტაპის გამოტოვებას ნიშნავს. `--segment-only` ყოველთვის კრძალავს API გამოძახებას, key-ის არსებობის მიუხედავად, და წარმატებისას აბრუნებს 0-ს. სამივე სცენაზე სრულდება 3 დამოუკიდებელი API ცდა. გამართული ცდები ქეშიდან იკითხება; წარუმატებელი ცდა მომდევნო გაშვებაზე მეორდება (შეიძლება კვლავ ფასიანი იყოს). SDK ავტომატური retry გამორთულია. API key არასოდეს ინახება შედეგებში.

`--scene sink`, `--scene gym`, `--scene car` ზღუდავს სცენებს. `--sam-model sam2.1_s.pt` იძლევა დაზუსტებულ ალტერნატივას. ნაგულისხმევი მოდელია base, 32×32 grid, 16 prompts/batch, ერთი დამატებითი crop-ფენა (downscale=2); `--crop-layers 0` თიშავს მას. FastSAM ავტომატურად არ ინაცვლებს SAM2-ს; შემოწმებულ Mac-ზე SAM2 საკმარისად სწრაფია ამ offline ექსპერიმენტისთვის.

## შედეგები

- `out/<scene>/marked.png`, `parts.png`: საერთო კონტურები და თითო მასკა ცალკე.
- `masks.npz`, `segments.json`: სრული boolean მასკები, ID, confidence, SHA256, პარამეტრები და დრო.
- `ground_truth.json`, `ground_truth.png`, `coverage.json`: artboard-ის ნაბიჯები და დიზაინის კონტურების მიახლოებითი დამთხვევა.
- `run_1/` … `run_3/`: მოთხოვნა, ნედლი პასუხი, ვალიდირებული `plan.json`, latency/usage/ფასი, შეფასება და `step_*.png`.
- `out/<scene>/step_<n>.png`: პირველი წარმატებული ცდის ნომერი 1-ის გამოსახულებები; ყველა ცდა ცალკეც ინახება.
- `REPORT.md`: ავტომატურად განახლებადი ქართული ანგარიში; `VISUAL_REVIEW.md`-დან ერთვის ხელით შემოწმების ჩანაწერები.

## რას ზომავს

მოდელი იღებს artboard-ის ნაბიჯების მხოლოდ სათაურს/ტექსტს და მონიშნულ ფოტოს. ეს იზოლირებულად ამოწმებს grounding-ს: სწორი ID-ების შერჩევას ცნობილი ამოცანებისთვის. ინსტრუქციების დამოუკიდებლად დაგეგმვას არ ამოწმებს. დიზაინის რიცხვითი ID-ები და SVG კოორდინატები არ იგზავნება. ყველა ნაბიჯი ქართულად უნდა დაბრუნდეს; ID-ები schema enum-ით იზღუდება. `parts` ყველა დაშვებულ ID-ს შეიცავს; უცნობი/ფონის მნიშვნელობა ცარიელი სტრიქონია, რადგან strict schema დინამიკურ თვითნებურ გასაღებებს არ იყენებს.

ქანჩის მსგავს ჩადგმულ სეგმენტებს ფილტრი ინარჩუნებს. ID-ების სტაბილურობა გარანტირებულია მხოლოდ შენახული მასკებისთვის. AR, კამერის მოძრაობა და on-device წარმადობა ამ ექსპერიმენტში არ იზომება.

დიზაინის კონტურები რეალური pixel-perfect ground truth არაა. `evaluation.json`-ის IoU არ არის სემანტიკური სიზუსტე. API ცდების შემდეგ საჭიროა `review_template.json`-ის შევსება სურათების მიხედვით; ჯერ ყველა შეფასება `null`-ია. უცნობი ნაწილების აღნიშვნა სჯობს არასწორ კონტურზე მითითებას.

## მოდელი და ფასი

`models.list()` ადგენს ანგარიშისთვის ხილულ ID-ებს; ხარისხის რეიტინგს/vision შესაძლებლობას ეს endpoint არ იძლევა. `vision.py`-ში მითითებულია ოფიციალური დოკუმენტაციით შერჩეული პრიორიტეტები (2026-10-17), პირველია `gpt-6-astra`. `OPENAI_MODEL` ცვლის არჩევანს და ასევე მოწმდება ანგარიშის სიაში. ახალი მოდელის დამატებისას განაახლეთ პრიორიტეტი და ფასიც. მიღებული მოდელის ზუსტი სახელი ინახება metrics-ში.

ფასი არის standard short-context შეფასება, cached input-ის გამოყოფით. უცნობი ტარიფი/ბილინგის კატეგორია რჩება `null`, არა ნულოვანი ფასი. source/date ინახება metrics-ში; reasoning ტოკენები output usage-ში შედის. ინვოისისთვის შეამოწმეთ Platform usage. წყაროები `REPORT.md`-შია.

## ვარიანტი B — AI-first

ორიგინალი ფოტო + იგივე ნაბიჯების title/text → OpenAI strict JSON (`object`, დინამიკური `parts[{id,label,box}]`, A-ს ფორმატის `steps`, `unknown_parts`) → თითო box-ზე SAM2.1_b. ID არის ინგლისური snake_case, ტექსტი — ქართული; XYXY box ნორმალიზებულია 0..1000-ზე. უცნობი ID ყველა reference-ში შეცდომაა და ინახება `error.json`-ში. [Structured Outputs-ის კონტრაქტი](https://developers.openai.com/api/docs/guides/structured-outputs) დამატებით ადგილობრივად მოწმდება.

```sh
cd experiments/som-test
uv run python run_b.py --help
uv run python run_b.py --scenes sink gym car --runs 3
# სურვილისამებრ: --model MODEL_ID --device mps
uv run python -m unittest discover -s tests -v
```

`.env`, მოდელის default/ანგარიშზე ხელმისაწვდომობის შემოწმება, `OPENAI_MODEL`, ტოკენებისა და ფასის ლოგიკა A-ს ემთხვევა. key-ის გარეშე აბრუნებს 2-ს და API არ იძახება. SDK retry გამორთულია. B კითხულობს უკვე არსებულ `out/<scene>/ground_truth.json`-ს; A-ს შედეგები და `REPORT.md` არ იცვლება.

`out_b/<scene>/run_<n>/` შეიცავს `request.json`, `response.json`, `plan.json`, `metrics.json` (API latency/usage/შეფასებული ფასი), `segmentation.json` (SAM latency და ხარისხი), `masks.npz` (მასკები და შესაბამისი ID-ები), `parts.png`, `step_<k>.png`, `evaluation.json`. სურათების `pN` ნომრები ლეგენდით უკავშირდება B-ს ID/ქართულ label-ს; რენდერი და ნაბიჯების IoU A-დანაა იმპორტირებული. ისევე როგორც A-ში, arrows JSON-ში რჩება, რენდერი მათ ცალკე არ ხატავს. `evaluation.json` არის დიზაინის კონტურებთან გეომეტრიული proxy და არა სემანტიკური სიზუსტის დადასტურება.

ხარისხი: `mask_fraction_inside_box` = box-ში მოხვედრილი მასკის პიქსელები / მთელი მასკა; `box_occupancy` = იგივე პიქსელები / box-ის ფართობი. ცარიელი მასკა ინახება და აღინიშნება; `too_large` ნიშნავს ფოტოს >85%-ს ან box-ის ფართობის >2-გზის მასკას (ეს დიაგნოსტიკური ზღვრებია, მასკები არ იფილტრება). `consistency.json` ადარებს ყველა წარმატებული ცდის წყვილს: NFKC/casefold/whitespace-normalized თანაბარი label + box IoU≥0.5, greedy ერთი-ერთთან მატჩინგი; შემდეგ parts და ნაბიჯების focus/avoid Jaccard. სინონიმები არ ემთხვევა; თანხმობა სისწორეს არ ამტკიცებს.

განმეორებით გაშვებისას ვალიდური `plan.json` თავიდან არ ითხოვება, SAM/რენდერი ახლდება. წარუმატებელი API ცდა ხელახლა იგზავნება და შეიძლება ფასიანი იყოს. მოდელის, ფოტოს, ground truth-ის ან device-ის შეცვლისას ძველი run ფოლდერი ჯერ ცალკე გადაიტანეთ — შეუთავსებელი ქეში არ გადაიწერება. `out_b/manual_sink/` არის ხელით არჩეული box-ის MPS შემოწმება, არა AI ცდა.

## ვარიანტი C — parts → კონტურები → streaming steps

`run_c.py` იყენებს `gpt-6-astra`-ს default-ად, `--max-side 768`, `--effort minimal`, 3 ცდას. პირველი strict პასუხი შეიცავს მხოლოდ `object`/`parts[{label,box}]`; კოდი ცენტრის Y/X რიგით ანიჭებს `p1..pN`-ს და B-დან იმპორტირებული SAM box prompt-ით წერს კონტურებს. მეორე მოთხოვნა იღებს მხოლოდ object/ნაწილებს/ინსტრუქციებს, ფოტოს ხელახლა არ აგზავნის; ყველა reference ტელეფონის ID-ების enum-ით იზღუდება. [Responses streaming](https://developers.openai.com/api/docs/guides/streaming-responses)-ში პირველი **სრული, ვალიდირებული ნაბიჯის** მიღების დრო იზომება, არა პირველი ტოკენის. ეს ნაბიჯი დასრულებამდე წინასწარია: სრული პასუხი შესაძლოა incomplete/refused აღმოჩნდეს.

```sh
cd experiments/som-test
uv sync --locked
uv run python run_c.py --dry-run
uv run python -m unittest discover -s tests -v
```

რეკომენდებული მცირე სერია (მთლიანი შეფასება **$1.266**, ქვემოთ მოცემული ტარიფებით; სამივე ბრძანებამდე დაამატეთ `--dry-run` გეგმების სანახავად):

```sh
# (ა) speed sweep: ერთი სცენა, თითო მოდელზე ერთი ცდა (~$0.558)
uv run python run_c.py --scenes sink --runs 1 --effort low \
  --models gpt-6-astra gpt-5.4-mini gpt-5.4-nano gpt-4.1-mini \
  --price gpt-5.4-mini=0.75,4.5 --price gpt-5.4-nano=0.2,1.25 \
  --price gpt-4.1-mini=0.4,1.6 --budget-usd 2

# (ბ) ID სტაბილურობა: ერთი სცენა, სამი ცდა (~$0.118)
uv run python run_c.py --scenes sink --runs 3 --effort low \
  --models gpt-5.4-mini --price gpt-5.4-mini=0.75,4.5 --budget-usd 2

# (გ) clean + ოთხივე დაზიანება, სამივე სცენა (~$0.590)
uv run python run_c.py --scenes sink gym car --runs 1 --effort low \
  --models gpt-5.4-mini --price gpt-5.4-mini=0.75,4.5 \
  --degrade --seed 42 --budget-usd 2
```

ტარიფები $/1M input/output: [5.4-mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini), [5.4-nano](https://developers.openai.com/api/docs/models/gpt-5.4-nano), [4.1-mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini), შემოწმებული 2026-10-17. `low` არჩეულია sweep-ისთვის, რადგან 5.4 mini/nano `minimal`-ს არ ასახელებს მხარდაჭერილ effort-ებში; ავტომატური შეცვლა/retry არ ხდება. Reasoning მხოლოდ `gpt-5*`/`gpt-6*` მოდელებს ეგზავნება. უცნობი ტარიფი მოთხოვნას ბლოკავს `--price MODEL=IN_PER_1M,OUT_PER_1M`-მდე. ცნობილი ფასები/usage-ის cached input ლოგიკა უცვლელი `vision.py`-დანაა; ხელით მოცემული ორი ტარიფი cached input-საც სრული ფასით ითვლის.

ბიუჯეტი **C-ს ყველა გაშვებაზე გროვდება** `out_c/budget.json`-ში. ყოველი მოთხოვნის წინ ჯავშნდება შეფასებული input + მაქსიმალური output-ის ფასი; usage-ის შემდეგ ზუსტდება. განუსაზღვრელი/გაწყვეტილი მოთხოვნის ჯავშანი რჩება. შემდეგი მოთხოვნა აღარ იგზავნება, თუ ჯამი ლიმიტს გადააჭარბებს; SDK retry გამორთულია. `--dry-run` API-ს, SAM-სა და ledger-ის ჩაწერას არ აკეთებს; default 9 ცდის გეგმა ~$4.41-ია და $2-ში არ ეტევა — runner ლიმიტზე გაჩერდება. შეფასება ეფუძნება 16k input/stage-სა და 1200/2200 output-ის ლიმიტს; დიდი prompt-ისთვის ჯავშანი იზრდება. ეს ბილინგის გარანტია ან ანგარიშის დარჩენილი ბალანსის შემოწმება არაა. ხელახალი გაშვება ახალ batch-ს ქმნის და ფასიანია; ledger არ წაშალოთ ამ $2 სერიის შუაში.

შედეგები ინახება `out_c/<UTC_batch>/<model>/<scene>/run_<n>/<mode>/`-ში: შემცირებული `input.png`, `degradation.json`, `parts.json`, მოთხოვნები/ნედლი პასუხები/usage, `parts.png`, მასკები, ნაბიჯები და metrics. `time_to_first_outline_seconds` მოიცავს ფოტოს მომზადებას, parts API-ს, SAM-ის ჩატვირთვას/ყველა box-სა და კონტურების რენდერს; თუ ყველა მასკა ცარიელია, არის `null`. `time_to_first_step_seconds` ითვლება მეორე API მოთხოვნიდან, ხოლო `time_to_first_step_from_start_seconds` — სრული ცდის დასაწყისიდან. `summary.json` შეიცავს ყველა წყვილის ID თანხვედრას, IoU მატჩებს, ნაწილების რაოდენობის ცვლილებასა და clean/degrade შედარებას; წარუმატებელი ცდები ცალკე აღინიშნება.

`--degrade` ნიშნავს clean + dark/blur/tilt/jpeg; `--degrade dark blur` ზღუდავს რეჟიმებს. Dark: linear-light −1.5EV, gamma 2.2, noise σ=5; blur: 15px ჰორიზონტალური motion kernel; tilt: seed-ით ±12°, ცენტრალური crop; jpeg: q=35. იგივე seed ცდებს შორის იმავე დაზიანებას იძლევა. Tilt-ისთვის clean box-ებიც გარდაიქმნება და მოიჭრება; სრულად მოჭრილი ნაწილები matching-ის denominator-იდან გამოირიცხება. IoU≥0.5 greedy one-to-one მატჩინგი label-ს არ იყენებს. ეს გეომეტრიული proxy-ა: სემანტიკურ სისწორეს ან AR tracking-ს არ ადასტურებს. ცენტრით მინიჭებული ნომრები დეტერმინისტულია, მაგრამ ნაწილის გამოტოვებისას შეიძლება გადაიწიოს — სწორედ ამას ზომავს ID თანხვედრა.

Offline შემოწმება (2026-10-17): 37 A+B+C ტესტი გაიარა; სამივე რეკომენდებული dry-run-ის ჯამია $1.26559. რეალური SAM2.1_b/MPS გაეშვა sink-ის ხელით მოცემულ box-ზე `[620,247,750,387]`, 512×768 ფოტოზე: clean/dark/blur/tilt/jpeg მასკები — 4470/4429/5159/9147/4618 px, ყველა არაცარიელი. ოთხივე დაზიანება და ხუთივე კონტური ვიზუალურად შემოწმებულია; blur-ის კონტური შედარებით გაფართოებულია. ეს არის SAM/degrade შემოწმება, არა AI ხარისხის შედეგი. API არ გაშვებულა. ადგილობრივი მტკიცებულებები `out_c/local_check/`-შია და git-ში არ შედის.
