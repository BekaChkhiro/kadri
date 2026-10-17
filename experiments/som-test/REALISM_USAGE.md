# Realism runner

`run_realism.py` მხარს უჭერს B (`process_run`) და C (`process_c`) ვარიანტებს (`--variant b|c`). სინთეზური დეგრადაცია რეალური ფოტოთი ვალიდაცია არ არის; `proxy.json` მხოლოდ დიზაინის გეომეტრიას ზომავს.

```sh
cd experiments/som-test
uv run python run_realism.py --dry-run --scenes sink gym car
uv run python run_realism.py --dry-run --variant c --effort minimal --max-side 768 --scenes sink
uv run python run_realism.py --dry-run --real real --scenes sink
uv run python run_realism.py --offline-summary
uv run python -m unittest discover -s tests -v
```

სცენების სია მოდის `segmentation.SCENES`-დან: `sink`, `gym`, `car`, `chemistry`, `microscope`, `psychology`, `laundry`. საჭიროა თითო სცენის `out/<scene>/ground_truth.json`. რეალური ფოტოების ფორმატია `real/<scene>/*.jpg`; EXIF ორიენტაცია სწორდება. რეალური ფოტოსთვის გამოიყენება სცენის ნაბიჯების ტექსტი, მაგრამ დიზაინის სივრცული მონიშვნები არ ვრცელდება ფოტოზე. `proxy.json` ასეთ შემთხვევაში მიუწვდომელ შეფასებას აფიქსირებს. რეალურ ფოტოებს შორის ავტომატური matching არ კეთდება: ცნობილი transform მხოლოდ ერთი წყაროს სინთეზურ მეზობელ კადრებს აქვს.

`--dry-run` მხოლოდ PNG-ს, მასკებსა და მანიფესტებს ქმნის; OpenAI client-სა და SAM-ს არ იძახებს. `--kinds` არჩევს `original dark_noise motion_blur tilt_crop lowres jpeg occlusion shift_left shift_right` ვარიანტებს. `--seed` default არის 20261017. ბნელი კადრი შეიცავს Gaussian ხმაურს; blur არის მიმართულებითი kernel; tilt/crop არის 7° ბრუნვა და 1.15 zoom; lowres 8-ჯერ მცირდება; JPEG quality=12; occlusion — გაუმჭვირვალე სინთეზური ბოთლის სილუეტი. ეს არ არის რეალური საგნის ფოტოდან კომპოზიტი.

`--variant b|c` განსაზღვრავს მოდელის მილსადენს: B არის ერთიანი Responses მოთხოვნა, C არის ორეტაპიანი (`parts` და სტრიმინგ `steps`). `--effort minimal|low|high` განსაზღვრავს reasoning effort-ს (B იყენებს `REASONING_EFFORT`-ს, C პირდაპირ იღებს `effort`-ს). `--max-side` (default 768) ზღუდავს thumbnail ზომას C-ში.

ყოველი `out_realism/<scene>/<photo>/<kind>/` შეიცავს `image.png`, `transform.json`, `truth.json`, `truth_masks.npz`. `source_to_frame` არის 3×3 forward matrix პიქსელურ კოორდინატებში. მასკები გარდაიქმნება nearest-neighbor-ით; `full` ინარჩუნებს occluder-ის უკან არსებულ proxy-ს, `visible` მას გამორიცხავს. crop-ის გარეთ არსებული ნაწილი ორივე მასკიდან იკარგება. C-ის მიერ დაგენერირებული მასკების proxy შეფასებისას (`proxy_evaluation`), თუ thumbnail ზომა განსხვავდება ორიგინალისგან, მასკები nearest-neighbor-ით ემთხვევა ground truth ზომებს, რაც უზრუნველყოფს `full` და `visible` IoU-ების ზუსტ შეფასებას.

ფასიანი გაშვება ამ სამუშაოს ფარგლებში **არ ჩატარებულა**. შემდგომი გაშვებისას სავალდებულოა explicit `--input-rate RATE --output-rate RATE`; უცნობი/ნაგულისხმევი ფასი არ გამოიყენება. ტარიფებია დოლარი მილიონ ტოკენზე. მიუთითეთ დადასტურებული ზედა ტარიფები, რომლებიც ფარავს არჩეული მოდელის long-context და cache-write ფასსაც.

B-ის მოთხოვნისა და C-ის ორივე ეტაპისთვის გამოიყენება `client.responses.input_tokens.count` preflight-ით იგივე payload-ისთვის (`model`, `input`, `text`, `reasoning`, `truncation='disabled'`). დათვლამდე რეზერვდება conservative counting allowance: `100,000 * input_rate / 1,000,000`. დათვლის შემდეგ count allowance მცირდება (`counted_input * input_rate / 1,000,000`); ეს კონსერვატიული allowance-ია და არა დადასტურებული count billing, ხოლო გენერაციისთვის რეზერვდება `(100,000 * input_rate + max_output * output_rate) / 1,000,000`. შეყვანის ჭერია 100,000 ტოკენი: count-ის შეცდომაზე ან 100k-ის გადაჭარბებაზე სისტემა ჩერდება fail-closed პრინციპით (რეზერვაცია ინახება, fallback/resize არ ხდება). `preflight.json` ინახავს payload hash-ს, input token count-სა და preflight latency-ს.

C ვარიანტის გაშვება ხდება `run_c_adapter`-ით. წყარო უკვე დაზიანებულია `run_realism`-ის მიერ, ამიტომ C ეშვება `mode="clean"`-ით. C-ის შიდა `Budget` ინტერფეისი ადაპტირებულია საერთო realism ledger-ზე (`CBudgetAdapter`), რათა გამოირიცხოს ორმაგი რეზერვაცია და ხარჯი. Streaming steps-ის ვალიდური terminal usage ამცირებს generation რეზერვაციას, მათ შორის incomplete/failed პასუხზე; terminal usage-ის გარეშე შეცდომა/disconnect სრულ რეზერვაციას ინარჩუნებს. count-სა და generation-ს ledger-ში ცალკე ჩანაწერი აქვს. bool, უარყოფითი და არამთელი count უარყოფილია. count-ისთვის გადაცემული ობიექტი ასლია; create იყენებს იმავე უცვლელ input/text/reasoning/model/truncation payload-ს.

ბიუჯეტი default $13-ია და კამპანიაში მაქსიმუმია $13 (`--budget` მხოლოდ ამცირებს). საერთო კამპანიის ledger default არის `experiments/som-test/out_realism/budget.json` (სხვადასხვა `--out` დირექტორიებისთვისაც), ან გადაეცემა ხელით `--ledger`-ით. ledger ინახავს `limit`-სა და `requests` mapping-ს; თითო ჩანაწერი არის `{"state":"settled","usd":...}` ან `reserved`. ledger იყენებს `flock`-ს, atomic replace-ს და fsync-ს. crash/timeout/disconnect ინარჩუნებს რეზერვაციას.

`--resume` გამოტოვებს დასრულებულ trial-ს (`complete.json`). მთელი config შედარდება: `model`, `device`, `ledger`, `effort`, `max_side`, `variant`, `rates`, input image/truth hash და seed. adapter დამატებით ამოწმებს prompt/schema კოდის fingerprint-ს; C-ის cached stage მიმდინარე payload hash-საც უნდა ემთხვეოდეს. ძველი შედეგი შემოწმებადი config-ის გარეშე ავტომატურად არ გამოიყენება და API მოთხოვნა არ მეორდება. განსხვავების შემთხვევაში გაშვება უარყოფილია (`ValueError`). C-სთვის partial request-ის არსებობისას (მაგ. დასრულებული `parts_request` ან `steps_request`), resume იყენებს შენახულ შედეგებს ახალი API მოთხოვნის გამეორების გარეშე.

`latency.json` გამოყოფს:
- B: `first_box_full_response_seconds` (request_b-ის რეალური დრო, count-ის ჩათვლით), `first_box_model_only_seconds` (სრული დრო მინუს preflight), `preflight_seconds` (ტოკენების დათვლის დრო), `real_wall_time_to_first_box_seconds` (შეიცავს preflight-ს), `sam_seconds`, `adapter_wall_seconds`.
- C: `time_to_parts_response_seconds` (parts დაბრუნებამდე), `time_to_first_outline_seconds` (outline SAM-ის შემდეგ), `time_to_first_step_seconds` / `time_to_first_step_from_start_seconds` (პირველ streamed step-მდე), `sam_seconds`, `steps_seconds`, `total_seconds`.
`summary.json` შეიცავს ამ მაჩვენებლების p50/p90-ს და `n`-ს. `--offline-summary` API-ს გარეშე ხელახლა ითვლის summary-ს.

Partial replay ინარჩუნებს თავდაპირველ stage metrics-ს, მაშინაც თუ შემდეგი ეტაპი ჩავარდა. აღდგენილი latency მონიშნულია `is_replay`/`partial_recovery`-ით, საერთო დროები არის null და summary-ის p50/p90-ში არ შედის. დასრულებული run-ის resume საწყის metrics-ს უცვლელად ტოვებს. უცნობად ჩამოჭრილი მოთხოვნა ავტომატურად აღარ იგზავნება. B/C კამპანიებისთვის გამოიყენეთ სხვადასხვა `--out`, მაგრამ ერთი საერთო `--ledger`; იგივე run-ის variant-ის შეცვლა უარყოფილია.
