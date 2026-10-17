# Realism runner

`run_realism.py` B-ის უცვლელ `process_run`-ს იყენებს. C ინტეგრაცია არ არის. სინთეზური დეგრადაცია რეალური ფოტოთი ვალიდაცია არ არის; `proxy.json` მხოლოდ დიზაინის გეომეტრიას ზომავს.

```sh
cd experiments/som-test
uv run python run_realism.py --dry-run --scenes sink gym car
uv run python run_realism.py --dry-run --real real --scenes sink
uv run python run_realism.py --offline-summary
uv run python -m unittest discover -s tests -v
```

სცენების სია მოდის `segmentation.SCENES`-დან: ახალი ოთხი სცენის ინტეგრაციის შემდეგ runner მათაც ავტომატურად დაინახავს. საჭიროა თითო სცენის `out/<scene>/ground_truth.json`. რეალური ფოტოების ფორმატია `real/<scene>/*.jpg`; EXIF ორიენტაცია სწორდება. რეალური ფოტოსთვის გამოიყენება სცენის ნაბიჯების ტექსტი, მაგრამ დიზაინის სივრცული მონიშვნები არ ვრცელდება ფოტოზე. `proxy.json` ასეთ შემთხვევაში მიუწვდომელ შეფასებას აფიქსირებს. რეალურ ფოტოებს შორის ავტომატური matching არ კეთდება: ცნობილი transform მხოლოდ ერთი წყაროს სინთეზურ მეზობელ კადრებს აქვს.

`--dry-run` მხოლოდ PNG-ს, მასკებსა და მანიფესტებს ქმნის; OpenAI client-სა და SAM-ს არ იძახებს. `--kinds` არჩევს `original dark_noise motion_blur tilt_crop lowres jpeg occlusion shift_left shift_right` ვარიანტებს. `--seed` default არის 20261017. ბნელი კადრი შეიცავს Gaussian ხმაურს; blur არის მიმართულებითი kernel; tilt/crop არის 7° ბრუნვა და 1.15 zoom; lowres 8-ჯერ მცირდება; JPEG quality=12; occlusion — გაუმჭვირვალე სინთეზური ბოთლის სილუეტი. ეს არ არის რეალური საგნის ფოტოდან კომპოზიტი.

ყოველი `out_realism/<scene>/<photo>/<kind>/` შეიცავს `image.png`, `transform.json`, `truth.json`, `truth_masks.npz`. `source_to_frame` არის 3×3 forward matrix პიქსელურ კოორდინატებში. მასკები გარდაიქმნება nearest-neighbor-ით; `full` ინარჩუნებს occluder-ის უკან არსებულ proxy-ს, `visible` მას გამორიცხავს. crop-ის გარეთ არსებული ნაწილი ორივე მასკიდან იკარგება. B-ის SVG adapter იგივე raster-ს აწვდის არსებულ evaluator-ს, ხოლო დამოუკიდებელი `proxy.json` პირდაპირ შენახულ მასკებს იყენებს.

ფასიანი გაშვება ამ სამუშაოს ფარგლებში **არ ჩატარებულა**. შემდგომი გაშვებისას სავალდებულოა `--ledger PATH --input-rate RATE --output-rate RATE`; უცნობი/ნაგულისხმევი ფასი არ გამოიყენება. ტარიფებია დოლარი მილიონ ტოკენზე. მიუთითეთ დადასტურებული ზედა ტარიფები, რომლებიც ფარავს არჩეული მოდელის long-context და cache-write ფასსაც. runner გათვლილია მაქსიმუმ 1,000,000 input-token კონტექსტიან მოდელებზე; უფრო დიდი კონტექსტის მოდელი ამ adapter-ით არ გაუშვათ. მოთხოვნამდე რეზერვდება სრული 1,000,000 input + B-ის 12,000 max-output ტოკენის ღირებულება. თუ ეს თანხა დარჩენილ ბიუჯეტს აღემატება, API არ გამოიძახება. კონსერვატიულმა რეზერვაციამ შესაძლოა იაფი ფაქტობრივი მოთხოვნაც დაბლოკოს.

ბიუჯეტი მაქსიმუმ $15-ია (`--budget` მხოლოდ ამცირებს). ერთი კამპანიის ყველა caller-მა **ერთი და იგივე ledger უნდა გამოიყენოს**. დამოუკიდებელი B/C სკრიპტების ან სხვა ledger-ის ხარჯები ავტომატურად არ ითვლება; მანამდე დახარჯული თანხა უნდა იყოს შეტანილი საერთო ledger-ში, ან `--budget` უნდა შემცირდეს დარჩენილ ლიმიტამდე. ledger ინახავს `limit`-სა და `requests` mapping-ს; თითო ჩანაწერი არის `{"state":"settled","usd":...}` ან `reserved`. ეს ლოკალური აღრიცხვაა და არა ანგარიშის პროვაიდერის spending cap.

ledger გამოიყენებს `flock`, atomic replace, file/directory fsync-ს. crash/timeout/უცნობი usage ინარჩუნებს რეზერვაციას. იგივე მოთხოვნის ავტომატური გამეორება აკრძალულია; ledger-ის წაშლა ან ახალი output directory-ის არჩევა retry-ის უსაფრთხო გზა არ არის. ანგარიშთან ხელით შეჯერებამდე გაურკვეველი ხარჯი არ გაათავისუფლოთ. SDK-ის `max_retries=0`.

`--resume` გამოტოვებს დასრულებულ trial-ს; თუ B-მ უკვე შეინახა ვალიდური `plan.json`, შესაძლებელია SAM-ის გაგრძელება ახალი API ხარჯის გარეშე. API-ზე წარუმატებელი trial-ისთვის ახალი მოთხოვნა არ გაიგზავნება. model/device/rates/ledger-ის ან წყაროს/seed/transform-ის ცვლილება იმავე output-ში უარყოფილია.

`latency.json` გამოყოფს `first_box_full_response_seconds`-ს (B-ის სრული პასუხი, streaming-ის გარეშე) და `sam_seconds`-ს. ეს პირველი გამოსახული UI box-ის დრო არ არის. `summary.json` შეიცავს p50/p90-ს და `n`-ს; დაბალი sample count სანდო tail-latency დასკვნისთვის საკმარისი არ არის.

Matching არის გეომეტრიული greedy one-to-one IoU, label/id-ის თანასწორობის მოთხოვნის გარეშე. შეწყვილებამდე boxes inverse transform-ით გადადის საწყის კოორდინატებში; ბრუნვისას axis-aligned envelope მიახლოებითია. ყოველი დეგრადირებული კადრი შედარდება იმავე trial-ის original-ს; `phone_ids` ინარჩუნებს original-ის ID-ს matched ნაწილებზე და ახალ ID-ს გასცემს unmatched ნაწილებზე. ეს offline pairwise tracker-ია და არა უწყვეტი phone runtime. ცალკე ინახება raw ID/label equality, unmatched და dropout. B confidence-ს არ აბრუნებს; offline sweep ამიტომ არის association-IoU ზღურბლების .25/.5/.75 sweep და არა მოგონილი confidence score-ები. `--offline-summary` API-ს გარეშე ხელახლა ითვლის ამ მონაცემებს.
