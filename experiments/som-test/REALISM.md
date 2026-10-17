# B/C რეალისტურობის საბოლოო ანგარიში — 2026-10-17

**C Astra გაუმჯობესებულ sink მიბმას აჩვენებს, თუმცა ≤5 წამში პირველი box-ის სამიზნე არ დასტურდება: first box p50/p90 stress-ში 6.78/8.41 წამია (n=9), tracking-ში — 7.49/12.77 წამი (n=13). Mini უფრო სწრაფია, მაგრამ წვრილ ნაწილებს ტოვებს და ზოგჯერ label-ს მცდარ რეგიონს აბამს. საერთო B/C გამარჯვებულის დასადგენი თანაბარი შედარება არ გვაქვს.**

ეს არის სინთეზური სურათებისა და მათი ხელოვნური დეგრადაციების ექსპერიმენტი, desktop MPS-ზე. რეალური mobile კამერა, მოწყობილობაზე წარმადობა, ვიდეოტრეკინგი და დამოუკიდებლად ანოტირებული რეალური ფოტოები არ შემოწმებულა. დიზაინის IoU არის მხოლოდ გეომეტრიული proxy; ასისტენტის ვიზუალური განხილვა ადამიანის შეფასებად ან semantic accuracy-ად არ ითვლება.

წყაროებია [მეტრიკების JSON](out_realism/report-metrics.json), [კამპანიის ფარგლები](out_realism/campaign-plan.json), [ledger](out_realism/budget.json), [პირველი ვიზუალური განხილვა](VISUAL_REALISM.md) და [Astra stress/tracking განხილვა](ASTRA_STRESS_VISUAL.md). ბოლო ორი დოკუმენტის coverage ძველ snapshot-ს ეკუთვნის; ქვემოთ მოცემული დასრულების რიცხვები საბოლოო ფაილებიდანაა. ახალი API გამოძახებები ანგარიშის მომზადებისას: **0**.

## რა შესრულდა

`complete.json` განსაზღვრავს დასრულებას. F ნიშნავს error არტეფაქტით დადასტურებულ ჩავარდნას (მათ შორის მოთხოვნამდე budget block-ს), I — დაუმთავრებელ ცდას, M — საერთოდ არშექმნილ ცდას. F არ ნიშნავს აუცილებლად ფასიან API გამოძახებას. თითო სცენა/რეჟიმზე დაგეგმილია ერთი run; განმეორებითი გაზომვები არ გვაქვს.

| კამპანია | მოდელი / effort | დასრულებული / გეგმა | F | I | M |
|---|---|---:|---:|---:|---:|
| `b_astra_low` | gpt-6-astra / low | 0/4 | 4 | 0 | 0 |
| `b_astra_valid` | gpt-6-astra / high | 4/4 | 0 | 0 | 0 |
| `c_astra_stress` | gpt-6-astra / low | 9/21 | 12 | 0 | 0 |
| `c_astra_tracking` | gpt-6-astra / low | 13/21 | 8 | 0 | 0 |
| `c_mini_matrix` | gpt-5.4-mini / low | 20/63 | 0 | 1 | 42 |

ჯამი: **46/113 დასრულებული**, 24 F, 1 I და 42 M. მხოლოდ 71 დაგეგმილი კადრი მომზადდა. ექვსი ისტორიული/pilot run ამ 113-ის გარეთაა და ამ კამპანიების ნაკლულ უჯრებს არ ავსებს. JSON-ის გლობალური latency/proxy ყველა აღმოჩენილ შედეგს მოიცავს; კამპანიის ცხრილები ცალკე გამოიყენეთ.

B high-ის ოთხი ახალი original დასრულებულია. B low-ის ოთხივე original ბიუჯეტით დაიბლოკა; შესაბამის low-vs-low კონტროლი არ მიღებულა. C Astra tracking-ში microscope shift_left და stress-ში chemistry dark_noise `ReadTimeout`-ით დასრულდა; ორივეგან ნაწილობრივი steps დასრულებულ გეგმას არ უდრის. დარჩენილი 18 Astra ცდა და B low-ის 4 ცდა budget-blocked არის; error ფაილები ძირითადად მხოლოდ `RuntimeError`-ს ინახავს, მიზეზის ინტერპრეტაცია ledger-სა და კამპანიის დასრულების ჩანაწერს ეყრდნობა.

Mini ხარისხის გამო შეჩერდა: car motion_blur დაუმთავრებელია და error არტეფაქტი არ აქვს; car-ის დარჩენილი 6 რეჟიმი და ოთხი ახალი სცენის 36 რეჟიმი საერთოდ არ შექმნილა. Mini-ს შეჩერება ავტომატურად 43 API failure-ად არ ითვლება.

ისტორიული ფარგლებსგარეშე ცდები: `c_astra`, `c_visual`, `c_mini_pilot` — თითო დასრულებული sink original; `c_pilot` და `c_diagnostic` — count-ის HTTP 400; `b_astra/chemistry` — შეწყვეტილი/დაუმთავრებელი original. diagnostic-ის სანიტიზებული პასუხი Astra-ზე `minimal` effort-ის მიუღებლობას ადასტურებს; ადრინდელი failure-ის დეტალები სრულად არ არის შემონახული. `baseline` არის მხოლოდ მომზადებული მასალა.

## სცენა × დაზიანების დაფარვა

უჯრებში C = complete, F = confirmed failure, I = incomplete, M = missing. რეჟიმები: original — საწყისი; dark_noise — დაბნელება/ხმაური; motion_blur — მოძრაობის დაბინდვა; tilt_crop — ბრუნვა/ჭრა; lowres — დაბალი გარჩევადობა; jpeg — შეკუმშვა; occlusion — ხელოვნური საფარი; shift_left/right — სინთეზური მეზობელი კადრები.

### `b_astra_valid`

| სცენა | original |
|---|---|
| chemistry | C |
| microscope | C |
| psychology | C |
| laundry | C |

### `b_astra_low`

| სცენა | original |
|---|---|
| chemistry | F |
| microscope | F |
| psychology | F |
| laundry | F |

### `c_astra_tracking`

| სცენა | original | shift_left | shift_right |
|---|---|---|---|
| sink | C | C | C |
| gym | C | C | C |
| car | C | C | C |
| chemistry | C | C | C |
| microscope | C | F | F |
| psychology | F | F | F |
| laundry | F | F | F |

### `c_astra_stress`

| სცენა | dark_noise | motion_blur | occlusion |
|---|---|---|---|
| sink | C | C | C |
| gym | C | C | C |
| car | C | C | C |
| chemistry | F | F | F |
| microscope | F | F | F |
| psychology | F | F | F |
| laundry | F | F | F |

### `c_mini_matrix`

| სცენა | original | dark_noise | motion_blur | tilt_crop | lowres | jpeg | occlusion | shift_left | shift_right |
|---|---|---|---|---|---|---|---|---|---|
| sink | C | C | C | C | C | C | C | C | C |
| gym | C | C | C | C | C | C | C | C | C |
| car | C | C | I | M | M | M | M | M | M |
| chemistry | M | M | M | M | M | M | M | M | M |
| microscope | M | M | M | M | M | M | M | M | M |
| psychology | M | M | M | M | M | M | M | M | M |
| laundry | M | M | M | M | M | M | M | M | M |

Astra-ს tilt_crop/lowres/jpeg ამ tracking+stress გეგმის ნაწილი არ ყოფილა და არც შესრულებულად ითვლება. სრული 7×9 Astra მატრიცა არ გვაქვს. Psychology/laundry-ზე C დასრულებული მაგალითი საერთოდ არ არის; microscope-ზე მხოლოდ original გვაქვს.

## დრო: p50 / p90 / n

წამები ახალი, არაქეშირებული გაშვებებიდან. B first box ელოდება მთელ პასუხს/გეგმას; C first box მხოლოდ parts პასუხია, outline — SAM-ის შემდეგ პირველი კონტური. ამიტომ B high-სა და C low-ს დროები არც თანაბარი effort-ის, არც თანაბარი სამუშაოს სუფთა benchmark-ია. C-ის thumbnail max_side=768; B-ის runner config-ში იგივე რიცხვის არსებობა იდენტურ შემავალ resolution-ს არ ამტკიცებს. პარალელური კამპანიები ერთ desktop MPS რესურსს იყენებდნენ: SAM/wall დრო კონკურენტული დატვირთვითაა დაბინძურებული.

| კამპანია | first box p50 / p90 / n | outline p50 / p90 / n | პირველი step დასაწყისიდან p50 / p90 / n | total p50 / p90 / n |
|---|---|---|---|---|
| `b_astra_low` | N/A / N/A / 0 | N/A / N/A / 0 | N/A / N/A / 0 | N/A / N/A / 0 |
| `b_astra_valid` | 77.24 / 88.46 / 4 | N/A / N/A / 0 | N/A / N/A / 0 | 85.10 / 94.56 / 4 |
| `c_astra_stress` | 6.78 / 8.41 / 9 | 9.68 / 12.39 / 9 | 14.50 / 18.11 / 9 | 27.48 / 32.91 / 9 |
| `c_astra_tracking` | 7.49 / 12.77 / 13 | 11.78 / 18.19 / 13 | 17.14 / 23.88 / 13 | 30.59 / 38.49 / 13 |
| `c_mini_matrix` | 3.43 / 4.06 / 20 | 6.32 / 7.46 / 19 | 9.29 / 10.76 / 20 | 10.70 / 12.29 / 20 |

B outline/first step ცალკე არ გაზომილა: N/A ნულია არა. Mini car dark_noise-ში outline null-ია, ამიტომ first box n=20, outline n=19. ქეშირებული/replay latency ნიმუშები ამ snapshot-ში 0-ია. Timeout-ები და budget block-ები დასრულებული ცდების latency განაწილებაში ვერ აისახება; წარმატებული ცდების p90 საიმედოობის გარანტია არ არის.

თავდაპირველი სამიზნე **≤5s first box** იყო. C Astra stress-ის first box p50/p90 არის **6.78/8.41 წამი (n=9)**, tracking-ის — **7.49/12.77 წამი (n=13)**; ორივე p50 5 წამზე მეტია. ზოგი tracking parts პასუხი 5 წამზე ადრე მოვიდა, მაგრამ ეს საერთო სამიზნის შესრულებას ვერ ადასტურებს. Outline დამატებითი მეტრიკაა: tracking-ის მინიმუმი 5.82 წამია, stress-ის — 7.16 წამი; ის თავდაპირველ first box კრიტერიუმს არ ცვლის. ყველა რეჟიმში მხოლოდ თითო ცდა და სცენების შერევა გვაქვს; p90 აღწერითი სტატისტიკაა, არა სტაბილური SLA.

## გეომეტრიული proxy და empty focus

ცხრილში მხოლოდ დასრულებული ცდებია; საშუალო IoU-ები ნაბიჯების მიხედვით ითვლება. Full/visible ნიშნავს მთელ/დაუფარავ დიზაინის მასკასთან გადაფარვას. ეს მასკები დამოუკიდებელი ადამიანური ground truth არ არის. Avoid მხოლოდ არაცარიელი სამიზნე avoid-ისთვის ითვლება; ცარიელი avoid focus-ის საშუალოს არ აზავებს.

| კამპანია | Focus full / visible mean (n) | Avoid full / visible mean (n) | empty focus / ნაბიჯები |
|---|---|---|---|
| `b_astra_low` | N/A (0) | N/A (0) | 0/0 |
| `b_astra_valid` | 0.380 / 0.380 (20) | 0.246 / 0.246 (3) | 8/20 |
| `c_astra_stress` | 0.463 / 0.489 (45) | 0.000 / 0.000 (3) | 5/45 |
| `c_astra_tracking` | 0.516 / 0.516 (65) | 0.105 / 0.105 (7) | 3/65 |
| `c_mini_matrix` | 0.143 / 0.144 (100) | 0.000 / 0.000 (2) | 17/100 |

სრული scene/kind proxy, latency, step-count და original-ების სია შენახულია JSON-ში. გლობალური 245 ნაბიჯი მოიცავს ისტორიულ/pilot დასრულებულ ცდებსაც. Empty focus არც ავტომატური შეცდომაა და არც ავტომატური სიზუსტე: უხილავი ვედროსთვის სწორია; ხილული მცირე ხრახნის ან მანქანის კარის ქვემოქმედების გამოტოვება შეიძლება ზედმეტი თავშეკავება იყოს.

### დასრულებული B/Astra — სცენისა და დაზიანების მიხედვით

ქვემოთ არის B high-ის ოთხივე და C Astra low-ის 22 დასრულებული ცდა, თითო სცენა/რეჟიმზე ერთი run. Focus full/visible არის ნაბიჯების საშუალო დიზაინის მასკის IoU, **არა სემანტიკური სიზუსტე ან ადამიანის შეფასება**. `n` შეფასებული ნაბიჯების რაოდენობაა; empty focus ცალკეა და მისი გამართლება ვიზუალურ კონტექსტზეა დამოკიდებული. ჩავარდნილი/ნაკლული უჯრები ზემოთ coverage ცხრილებშია და აქ ნულოვან სიზუსტედ არ ჩაითვლება.

| კამპანია | სცენა | რეჟიმი | Focus full mean | Focus visible mean | n | empty focus / ნაბიჯები |
|---|---|---|---:|---:|---:|---:|
| `b_astra_valid` | chemistry | original | 0.420 | 0.420 | 5 | 1/5 |
| `b_astra_valid` | laundry | original | 0.102 | 0.102 | 5 | 4/5 |
| `b_astra_valid` | microscope | original | 0.434 | 0.434 | 5 | 2/5 |
| `b_astra_valid` | psychology | original | 0.562 | 0.562 | 5 | 1/5 |
| `c_astra_stress` | car | dark_noise | 0.768 | 0.768 | 5 | 0/5 |
| `c_astra_stress` | car | motion_blur | 0.702 | 0.702 | 5 | 0/5 |
| `c_astra_stress` | car | occlusion | 0.587 | 0.729 | 5 | 0/5 |
| `c_astra_stress` | gym | dark_noise | 0.365 | 0.365 | 5 | 0/5 |
| `c_astra_stress` | gym | motion_blur | 0.290 | 0.290 | 5 | 0/5 |
| `c_astra_stress` | gym | occlusion | 0.202 | 0.241 | 5 | 2/5 |
| `c_astra_stress` | sink | dark_noise | 0.439 | 0.439 | 5 | 1/5 |
| `c_astra_stress` | sink | motion_blur | 0.467 | 0.467 | 5 | 1/5 |
| `c_astra_stress` | sink | occlusion | 0.345 | 0.397 | 5 | 1/5 |
| `c_astra_tracking` | car | original | 0.662 | 0.662 | 5 | 0/5 |
| `c_astra_tracking` | car | shift_left | 0.673 | 0.673 | 5 | 0/5 |
| `c_astra_tracking` | car | shift_right | 0.671 | 0.671 | 5 | 0/5 |
| `c_astra_tracking` | chemistry | original | 0.625 | 0.625 | 5 | 0/5 |
| `c_astra_tracking` | chemistry | shift_left | 0.618 | 0.618 | 5 | 0/5 |
| `c_astra_tracking` | chemistry | shift_right | 0.627 | 0.627 | 5 | 0/5 |
| `c_astra_tracking` | gym | original | 0.363 | 0.363 | 5 | 0/5 |
| `c_astra_tracking` | gym | shift_left | 0.317 | 0.317 | 5 | 0/5 |
| `c_astra_tracking` | gym | shift_right | 0.488 | 0.488 | 5 | 0/5 |
| `c_astra_tracking` | microscope | original | 0.347 | 0.347 | 5 | 0/5 |
| `c_astra_tracking` | sink | original | 0.399 | 0.399 | 5 | 1/5 |
| `c_astra_tracking` | sink | shift_left | 0.463 | 0.463 | 5 | 1/5 |
| `c_astra_tracking` | sink | shift_right | 0.460 | 0.460 | 5 | 1/5 |

## ვიზუალური შედეგი და შეზღუდვები

არსებული ორი ვიზუალური ანგარიშის გარდა, ამ ანგარიშისთვის რეალურად გაიხსნა B-ის ოთხივე original `parts.png` და ექვსი მოგვიანებით დასრულებული Astra `parts.png`; მათი გეგმებიც წაკითხულია. ქვემოთ ჩამოთვლილი განხილვა AI ასისტენტისაა. ადრე განხილულ 16 Astra შედეგთან ერთად დაფარულია ყველა 22 დასრულებული Astra tracking/stress overlay, მაგრამ არა ადამიანის ანოტაციით. Mini-ს ყველა 20 შედეგის ვიზუალური განხილვა არ მომხდარა.

| სცენა | დაკვირვება | დარჩენილი ნაკლი |
|---|---|---|
| sink | C visual ფონურ p6-ს აღარ ასაღებს ნაწილად; მარჯვენა ქანჩს უკეთ ირჩევს; ვედრო/შუასადების უხილავობას აღნიშნავს | blur-ზე ქანჩის არჩევანი მაინც დაშვებაა; სტატიკური სურათი გაჟონვას ვერ ადასტურებს |
| gym | Astra noise/blur-ში დიდი ნაწილები ცნობადია; occlusion-ში მხოლოდ სახელური და ბალიშები დარჩა, ორი დაფარული რეგულატორის focus ცარიელია | blur-ში წონის დასტის კონტური იშლება; shift_left-ში სახელური ორ ნაწილად იყოფა და IDs იცვლება |
| car | სამი stress overlay ინარჩუნებს ხუფის/ყვითელი რგოლის რეგიონებს; occlusion-ში მხოლოდ ხუფის ხილულ კიდეს მიჰყვება და დაფარვას აღნიშნავს | blur/noise-ში წარწერა მცირე დეტალს ფარავს; ზეთის დონე და ღეროს ნიშნულები არ ჩანს |
| chemistry | B-ის ძაბრი/ონკანი/კოლბა გამოსადეგად გამოიყო; Astra shift_right-ში ცხრა ნაწილი კვლავ შესაბამის უბნებზეა | shift_left-ში შვიდი ნაწილი იყო: IDs/ნაწილების სია არასტაბილურია; მოცულობა/ბოთლის შიგთავსი ვერ დასტურდება |
| microscope | B და C გამოყოფს ძირითად მართვის ნაწილებს; C ხილულ რევოლვერსა და პატარა ხრახნს focus-ში იყენებს | C 4×/40× ობიექტივს სავარაუდოდ არჩევს, წარწერა არ იკითხება; B-ის ორი empty focus ზედმეტად კონსერვატიული იყო |
| psychology | B-ის საყრდენები, სენსორი და პულტი შესაბამის რეგიონებშია | ეკრანის კიდე დაკბილულია; calibration/მონაწილის პოზა ვერ მოწმდება; C შედეგი არ გვაქვს |
| laundry | B-ში კარი, უჯრა, სახელური და განყოფილებები გამოიყო | empty focus 4/5; ფუნქციური ეტიკეტების გაურკვევლობა ზოგ ხილულ ქვემოქმედებასაც ტოვებს; C შედეგი არ გვაქვს |

B empty focus: chemistry 1/5, microscope 2/5, psychology 1/5, laundry 4/5. Mini sink-ში მთელი მილის ერთ ნაწილად გაერთიანება კონკრეტულ ქანჩზე მითითებას აკარგვინებს; დეგრადაციებზე ზოგი ონკანის label ფონზე/შლანგზე გადადის. სწრაფი parts პასუხი ამ ხარისხობრივ ნაკლს ვერ ანაზღაურებს.

ახლად გახსნილი Astra მტკიცებულებები:

- chemistry/shift_right: [parts](out_realism/c_astra_tracking/chemistry/chem-titration/shift_right/run_1/parts.png), [გეგმა](out_realism/c_astra_tracking/chemistry/chem-titration/shift_right/run_1/plan.json).

- microscope/original: [parts](out_realism/c_astra_tracking/microscope/microscope/original/run_1/parts.png), [გეგმა](out_realism/c_astra_tracking/microscope/microscope/original/run_1/plan.json).

- car/dark_noise: [parts](out_realism/c_astra_stress/car/car-engine/dark_noise/run_1/parts.png), [გეგმა](out_realism/c_astra_stress/car/car-engine/dark_noise/run_1/plan.json).

- car/motion_blur: [parts](out_realism/c_astra_stress/car/car-engine/motion_blur/run_1/parts.png), [გეგმა](out_realism/c_astra_stress/car/car-engine/motion_blur/run_1/plan.json).

- car/occlusion: [parts](out_realism/c_astra_stress/car/car-engine/occlusion/run_1/parts.png), [გეგმა](out_realism/c_astra_stress/car/car-engine/occlusion/run_1/plan.json).

- gym/occlusion: [parts](out_realism/c_astra_stress/gym/gym-lat-pulldown/occlusion/run_1/parts.png), [გეგმა](out_realism/c_astra_stress/gym/gym-lat-pulldown/occlusion/run_1/plan.json).

B original-ების ოთხივე ბმული და დეტალური ნაბიჯობრივი განხილვა მოცემულია [VISUAL_REALISM.md](VISUAL_REALISM.md)-ში.

## ID matching — IoU threshold sweep

ეს არის ცნობილი გარდაქმნით გასწორებული bounding box-ების IoU-ზე დაფუძნებული greedy გეომეტრიული association (`realism.match_frames` იყენებს `variant_b.box_iou`-ს); confidence threshold ან semantic accuracy არ არის. რვა შედარება მოდის მხოლოდ `c_astra_tracking/summary.json`-იდან: sink/gym/car/chemistry original თითოეულ shift-ს ედრება. Microscope-ზე დასრულებული წყვილი არ არის. Mini/stress-ისთვის ამ JSON-ში matching შედეგი არ გვაქვს.

| IoU ზღვარი | retention | dropout | raw ID თანხვედრა (n) | raw label თანხვედრა (n) | შედარებები n |
|---|---:|---:|---:|---:|---:|
| 0.25 | 91.9% | 8.1% | 76.8% (8) | 17.5% (8) | 8 |
| 0.5 | 77.8% | 22.2% | 77.5% (8) | 12.7% (8) | 8 |
| 0.75 | 54.6% | 45.4% | 75.0% (7) | 13.2% (7) | 8 |

მაჩვენებლები შედარებების საშუალოებია. Raw ID/label ითვლება მხოლოდ დამთხვეულ წყვილებზე; 0.75-ზე ერთ შედარებაში წყვილი არ დარჩა, ამიტომ raw n=7. Label-ის სიტყვიერი ცვლილება თავისთავად არ არის მცდარი ობიექტი, ხოლო ერთნაირი ID თავისთავად სწორ ობიექტს არ ნიშნავს. მიმდინარე კადრში სწორი ID-ის გამოყენება კადრებს შორის იმავე ID-ის გადატანის გარანტიას არ იძლევა.

## ხარჯი და გაჩერების მიზეზი

Ledger-ის ჭერია **$13**. ქვემოთ მოცემულია token/rate-ზე შეფასება და allowance, არა პროვაიდერის ფაქტობრივი ინვოისი. რეზერვაცია აქტიურ პროცესს არ ნიშნავს: ყველა ფასიანი პროცესი დასრულებულია, მაგრამ უცნობი terminal usage-ის თანხა ledger-ში დაკავებული დარჩა.

| კატეგორია | settled | held reservation |
|---|---:|---:|
| Generation estimated | $3.9461870 | $4.6504000 |
| Count allowance | $1.5444425 | $2.5000000 |
| ჯამი | **$5.4906295** | **$7.1504000** |

გამოყენებული + დაკავებული = **$12.6410295**; თავისუფალი = **$0.3589705**. ეს ვერ იტევს Astra-ს შემდეგ count allowance-ს ($1.25), რომ აღარაფერი ვთქვათ generation reservation-ზე. ამიტომ სრული coverage ვერ შესრულდა. Generation settled მოთხოვნები 96-ია, count settled 100; ეს მოთხოვნების რაოდენობაა და არა დასრულებული trial-ების.

| დაკავებული მოთხოვნა | თანხა |
|---|---:|
| ადრინდელი failed minimal count ×2 | $2.5000 |
| შეწყვეტილი B generation | $1.8500 |
| გაჩერებული mini generation | $0.0804 |
| Astra steps timeout ×2 | $2.7200 |

ანგარიშის CLI-მ runner_config-ის აბსოლუტური ledger path-ით owner checkout-ის იდენტური ასლიც აღმოაჩინა და თავდაპირველად ორჯერ დათვალა. საბოლოო `report-metrics.json.costs` offline ხელახლა დაითვალა **მხოლოდ ამ checkout-ის `out_realism/budget.json`-ით**, იმავე `analyze_realism_metrics` ფუნქციით. კორექცია JSON metadata-შია; ledger, runner config და კოდი არ შეცვლილა. `costs.total_settled_usd` მხოლოდ generation-ს ნიშნავს; სრული $5.4906295 მის და `count_allowance.settled_usd`-ის ჯამია.

## გამეორება და შემდეგი ნაბიჯი

მეტრიკების გენერაცია, `experiments/som-test`-იდან (გენერატორის Markdown ნედლი ანგარიშია; აქ საბოლოო ტექსტი რედაქტირებულია):

```sh
python3 realism_report.py --root out_realism --campaign-plan out_realism/campaign-plan.json --out RAW_REALISM.md --json out_realism/report-metrics.json
```

იზოლირებულ checkout-ში ხელახალი გენერაციისას გადაამოწმეთ ledger-ების იდენტური ასლების აღმოჩენა ზემოთ აღწერილი წესით; CLI-ის დაუმუშავებელი ხარჯის ჯამი შეიძლება გაორმაგდეს. JSON-ის არტეფაქტების path-ები პროექტის root-თან ფარდობითადაა შენახული.

რეალური JPG-ები მოათავსეთ `real/<scene>/*.jpg`-ში. ერთი უსაფრთხო ბრძანება, იმავე დირექტორიიდან, ამზადებს შვიდივე სცენის რეალურ ფოტოებს API ხარჯის გარეშე:

```sh
uv run python run_realism.py --dry-run --real real --variant c --effort low --scenes sink gym car chemistry microscope psychology laundry --kinds original --out out_realism/real_photos
```

ეს მხოლოდ მომზადებაა, არა მოდელის შეფასება. რეალურ ფოტოებზე დიზაინის proxy არ ვრცელდება. შემდეგ საჭიროა რეალური მასალის ადამიანის მიერ დამოუკიდებელი მონიშვნა, თანაბარი B/C effort/input პირობები, სერიული და განმეორებითი latency გაზომვები, შემდეგ უშუალოდ სამიზნე mobile მოწყობილობაზე ტესტი. ჯერ უნდა გაირკვეს held reservation-ის ფაქტობრივი სტატუსი; ავტომატური release/retry ამ ანგარიშში არ შესრულებულა. ახალი თანხის მოთხოვნა არ კეთდება.

ანგარიშის ცვლილება შემოიფარგლება `REALISM.md`, `out_realism/campaign-plan.json` და `out_realism/report-metrics.json` ფაილებით. შემოწმება: report-ის პროექტის unittest-ები, JSON/coverage/ledger თანხვედრა, ფარდობითი ბმულები და `git diff --check`. აპლიკაციის build და ახალი ფასიანი გაშვება ამ დოკუმენტური ცვლილებისთვის არ ჩატარებულა.
