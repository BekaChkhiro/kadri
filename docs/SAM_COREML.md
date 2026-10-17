# SAM Core ML — T3.1 Python შეფასება

გაზომვა: 2026-10-17, Apple M5, 16 GiB RAM, macOS 26.3, Python 3.11,
PyTorch 2.7.0, coremltools 8.3.0. ფასიანი API გამოძახება: **0**.

## გადაწყვეტილება და acceptance

საბაზისო საექსპერიმენტო ექსპორტად არჩეულია **EfficientSAM-Ti (Apache-2.0)**.
მას აქვს საუკეთესო საშუალო შეთანხმება SAM2-თან და ყველაზე თანაბარი ხარისხი
ამ 14 ნაწილზე. `convert_sam.py` default-ად მის ორ მოდელს ქმნის.
ეს **არ არის საწარმოო ან iPhone 12-ის შესრულების დამტკიცებული არჩევანი**.

FP16 Core ML-ზე სამივე სცენის საშუალო IoU ≥0.8-ია. თუმცა **არცერთ კანდიდატს
არ გაუვლია ყველა ნაწილის ≥0.8 ზღვარი**: EfficientSAM-ის gym/p2 = 0.7978.
ამ შედეგს „თითქმის გაიარა“-დ არ ვთვლით. iPhone 12-ზე encoder ≤150 მს და
ერთ box-ზე decoder ≤30 მს ჯერ გაზომილი არ არის; T3.1 მთლიანად დასრულებული არაა.
M5-ზე EfficientSAM encoder-ის დაახლოებით 148 მს უკვე მნიშვნელოვანი რისკია
უფრო ძველი ტელეფონის სამიზნე დროისთვის, თუმცა ეს iPhone-ის გაზომვას ვერ ცვლის.

კანდიდატები:

- **EdgeSAM-3x:** ყველაზე სწრაფია, მაგრამ ოფიციალური
  [S-Lab License 1.0](https://github.com/chongzhou96/EdgeSAM/blob/03465ff934a01e850639f47e3cd02304d1840f58/LICENSE)
  მხოლოდ არაკომერციულ გამოყენებას უშვებს მოცემული პირობებით და მოთხოვნილ
  Apache/MIT ფილტრს ვერ გადის. ანგარიშის ექსპორტი მხოლოდ შეფასებისთვისაა;
  აპში არ ირჩევა. გამოყენებულია inference-only commit, training code-ის
  `mmdet/mmcv` დამოკიდებულებების შემოტანამდე. Bilinear upsample შეესაბამება
  [ოფიციალურ Core ML exporter-ს](https://github.com/chongzhou96/EdgeSAM/blob/03465ff934a01e850639f47e3cd02304d1840f58/scripts/export_coreml_model.py).
- **MobileSAM / TinyViT:** [Apache-2.0](https://github.com/ChaoningZhang/MobileSAM/blob/f706ad9c4eb7f219c00d9050e46328518ffb65d2/LICENSE),
  სწრაფი, სუფთა ექსპორტი, მაგრამ სამი ნაწილი <0.8 და sink/p3 მხოლოდ 0.5277.
  კარგი კანდიდატია დამოუკიდებელი მრავალმასკიანი არჩევის გაუმჯობესებისათვის.
- **EfficientSAM-Ti:** [Apache-2.0](https://github.com/yformer/EfficientSAM/blob/d525f622e6f640acf5a0fc37c7ca1f243da5bde0/LICENSE),
  საუკეთესო საშუალო ხარისხი. ფიქსირებულ 64×64 grid-ზე პოზიციური embedding-ის
  bicubic ინტერპოლაცია წინასწარ ითვლება upstream `get_abs_pos`-ით, რადგან
  coremltools-ის Torch converter `upsample_bicubic2d`-ს ვერ გარდაქმნის.
  გამოსახულებაზე დამოკიდებული გამოთვლა არ ჩანაცვლებულა. FP32-ში წინასწარ
  გამოთვლილი positional embedding-ის ეკვივალენტობა sink/car/gym-ზე ცალკე
  შემოწმდა: embedding-ის მაქსიმალური სხვაობა სამივეზე ზუსტად 0. Decoder პირდაპირ
  გარდაიქმნა. არქიტექტურის 1024-ზომიანი გლობალური attention encoder-ს ძვირს ხდის.

## მეთოდი და რეფერენსი

სამივე კანდიდატი შეფასდა არჩევამდე, CPU PyTorch-სა და FP16 Core ML-ზე.
წყარო: `experiments/som-test/out_realism/c_astra_tracking/{sink,car,gym}/*/original/run_1/`.
გამოყენებულია `input.png`, `plan.json`, `segmentation.json`, **`masks.npz`**.
`truth_masks.npz` სხვა ნაწილების ნაკრებს შეიცავს და ამ შედარებისთვის არ გამოიყენება.
`variant_b.py::make_sam/segment_boxes` აღწერს რეფერენსს: Ultralytics
`sam2.1_b.pt`, box prompt, ერთი მასკა თითო ნაწილზე; საჭიროებისას რეფერენსის
ბინარული მასკა საწყის ზომაზე nearest-neighbor-ით იყო დაყვანილი.
ყველა საჭირო რეფერენსი შენახული იყო, ამიტომ SAM2 თავიდან არ გაშვებულა.

5 sink + 2 car + 7 gym ნაწილი. მოწმდება ID-ების რიგი, box-ის პიქსელები და
მასკების ზომა. JSON ინახავს input/plan/masks SHA-256-ს. IoU ითვლება სრულ
საწყის გამოსახულებაზე, box-ით დამატებითი clipping-ის გარეშე; ცარიელი union-ის
IoU = 1. რეფერენსიც მოდელის შედეგია: ეს **SAM2-თან შეთანხმებაა**, არა ადამიანით
დამოწმებული სეგმენტაციის სიზუსტე ან ახალი კადრებზე განზოგადების გარანტია.

მოდელი ირჩევს მაქსიმალური predicted IoU score-ის მქონე მასკას. Edge/Mobile
აბრუნებს ოთხ token-ს (single + სამი multimask), EfficientSAM — upstream-ის სამ
multimask შედეგს. `oracle` ნიშნავს SAM2-ით საუკეთესო მასკის არჩევას და მხოლოდ
დიაგნოსტიკაა; ასეთი არჩევანი რეალურ აპში მიუწვდომელია.

დრო: ორი warmup და ათი გაზომილი synchronous `MLModel.predict` გამოძახება
თითო სურათზე/box-ზე. საერთო encoder მედიანა 30 sample-იდან, decoder — 140-იდან.
გამორიცხულია compile/load, preprocessing, postprocessing და reference IoU;
შედის Python/Core ML I/O ხარჯი. ინახება თითო sample და თითო box-ის მედიანაც.
Benchmark-ები გაშვებულია თანმიმდევრულად; ცივი start და sustained thermal ქცევა
ამ ცხრილით არ იზომება.

## გაზომილი შედეგები

| კანდიდატი | PyTorch mean IoU | Core ML mean IoU (ALL) | მინ. ნაწილი | encoder პარამ. | decoder პარამ. | encoder G-FMA | decoder G-FMA |
|---|---:|---:|---:|---:|---:|---:|---:|
| edgesam | 0.8972 | 0.8991 | 0.7882 | 5,517,552 | 4,064,560 | 20.361 | 1.823 |
| mobilesam | 0.9008 | 0.8988 | 0.5277 | 6,065,532 | 4,064,560 | 39.122 | 1.823 |
| efficientsam | 0.9131 | 0.9124 | 0.7978 | 6,163,840 | 4,059,364 | 102.368 | 1.861 |

G-FMA: fvcore-ის დათვლა (ერთი fused multiply-add = ერთი FLOP). ორი FLOP/FMA
კონვენციით ძირითადი MAC-ების წვლილი დაახლოებით ორმაგია. ეს სრული ზუსტი FLOP
დათვლა არ არის: unsupported elementwise/softmax/GELU და ზოგი resize ოპერაცია
გამორიცხულია; სრული სია `*_pytorch.json`-ში ინახება. პარამეტრები არის upstream
FP32 მოდელის, conversion-time constant folding-მდე.

### Core ML — თითოეული ნაწილი (ALL)

| სცენა | ნაწილი | EdgeSAM-3x | MobileSAM | EfficientSAM-Ti | Efficient oracle |
|---|---|---:|---:|---:|---:|
| sink | p1 — სიფონის ზედა პლასტმასის ქანჩი — მეტალის ვერტიკალურ მილთან შეერთება | 0.9669 | 0.9661 | 0.9689 | 0.9702 |
| sink | p2 — მარცხენა ჩამკეტი ონკანი — მრგვალი მეტალის სახელური | 0.8284 | 0.8927 | 0.8125 | 0.8863 |
| sink | p3 — მარჯვენა ჩამკეტი ონკანი — მრგვალი მეტალის სახელური, ვერტიკალური მილის მარცხნივ | 0.8050 | 0.5277 | 0.8351 | 0.8351 |
| sink | p4 — სიფონის მარჯვენა პლასტმასის ქანჩი — ჰორიზონტალურ მილთან შეერთებაზე ჩანს წვეთები | 0.9678 | 0.9698 | 0.9689 | 0.9689 |
| sink | p5 — თეთრი U-ს ფორმის სიფონი — ქვედა მოხრილი მილი | 0.7882 | 0.7927 | 0.9275 | 0.9628 |
| car | p1 — ზეთის ჩასასხმელი ხუფი — ძრავის საფარზე, შავი მრგვალი თავსახურითა და განივი სახელურით | 0.9339 | 0.7794 | 0.9269 | 0.9269 |
| car | p2 — ზეთის საზომი ღეროს ყვითელი რგოლი — ძრავის საფარის ქვედა მარჯვენა კიდესთან | 0.9079 | 0.9504 | 0.9147 | 0.9377 |
| gym | p1 — ზედა სახელური, მარცხნივ და მარჯვნივ ქვემოთ მოხრილი ბოლოებით | 0.9172 | 0.9161 | 0.9505 | 0.9649 |
| gym | p2 — წონის ასარჩევი ყვითელი ქინძისთავი, ფილების მარჯვენა მხარეს | 0.8627 | 0.9560 | 0.7978 | 0.9239 |
| gym | p3 — წონის ფილების დასტა, ტრენაჟორის შუაში | 0.9654 | 0.9868 | 0.9659 | 0.9659 |
| gym | p4 — მუხლების მარცხენა შავი ბალიში | 0.9321 | 0.9725 | 0.9514 | 0.9611 |
| gym | p5 — მუხლების მარჯვენა შავი ბალიში | 0.9138 | 0.9719 | 0.9654 | 0.9654 |
| gym | p6 — ქვედა შავი სავარძელი | 0.9700 | 0.9752 | 0.9632 | 0.9756 |
| gym | p7 — სავარძლის სიმაღლის მარეგულირებელი ყვითელი ღილაკი, სავარძლის ქვემოთ | 0.8276 | 0.9256 | 0.8250 | 0.8250 |

| სცენის საშუალო | EdgeSAM-3x | MobileSAM | EfficientSAM-Ti |
|---|---:|---:|---:|
| sink | 0.8713 | 0.8298 | 0.9026 |
| car | 0.9209 | 0.8649 | 0.9208 |
| gym | 0.9127 | 0.9577 | 0.9170 |

### Mac warm latency და პაკეტების ზომა

| კანდიდატი | რეჟიმი | encoder მედიანა, მს | decoder მედიანა/box, მს | encoder MiB | decoder MiB |
|---|---|---:|---:|---:|---:|
| edgesam | ALL | 11.29 | 2.53 | 10.69 | 11.85 |
| edgesam | CPU_AND_NE | 9.90 | 2.53 | 10.69 | 11.85 |
| mobilesam | ALL | 35.41 | 2.58 | 13.45 | 11.85 |
| mobilesam | CPU_AND_NE | 35.36 | 2.59 | 13.45 | 11.85 |
| efficientsam | ALL | 148.33 | 2.49 | 13.31 | 9.86 |
| efficientsam | CPU_AND_NE | 148.52 | 2.49 | 13.31 | 9.86 |

საბოლოო default პაკეტის განმეორებითი შემოწმება (`out/bench.json`):
- ALL: encoder 145.63 მს, decoder 2.53 მს, mean IoU 0.9124; სცენის საშუალო gate passed, ყველა ნაწილის gate failed (gym/p2).
- CPU_AND_NE: encoder 145.06 მს, decoder 2.49 მს, mean IoU 0.9124; სცენის საშუალო gate passed, ყველა ნაწილის gate failed (gym/p2).

### პინები და არტეფაქტების იდენტიფიკაცია

| კანდიდატი | upstream commit | weights SHA-256 |
|---|---|---|
| edgesam | `03465ff934a01e850639f47e3cd02304d1840f58` | `5a3e3261da9e2f4c8154410885689ae57d09cbf4cf5d0c848b9d80b6df336ece` |
| mobilesam | `f706ad9c4eb7f219c00d9050e46328518ffb65d2` | `6dbb90523a35330fedd7f1d3dfc66f995213d81b29a5ca8108dbcdd4e37d6c2f` |
| efficientsam | `d525f622e6f640acf5a0fc37c7ca1f243da5bde0` | `dff858b19600a46461cbb7de98f796b23a7a888d9f5e34c0b033f7d6eb9e4e6a` |

ჩამოტვირთვის ზუსტი URL-ები `ios/Tools/candidates.py`-შია; hash მოწმდება
ყოველ ჩატვირთვაზე. Pinned upstream source და LICENSE ინახება `.cache/sources/`-ში.


## ANE და კონვერტაციის დაკვირვებები

`bench_sam.py` იყენებს `MLComputePlan.load_from_path`-ს თითო compute-unit რეჟიმისთვის,
ინახავს თითო ოპერაციის preferred/supported devices-სა და estimated cost-ს.
`conversion.json` დამატებით შეიცავს ML Program ოპერაციების ინვენტარს.
Compute plan დაგეგმილი განაწილებაა და არა profiler-ით გაზომილი შესრულების კვალი.
`CPU_AND_NE` არჩევა თავისთავად არ ამტკიცებს, რომ მთელი მოდელი ANE-ზე მუშაობს.

EfficientSAM: encoder-ის 268 ოპერაციის preferred device ANE-ია; decoder-ის
216 ოპერაცია ANE-ზეა, 15 CPU-ზე. CPU-ს რჩება cast/reshape/pad, box-ის
საწყისი add/slice/mul/scatter. MobileSAM: encoder 436 ANE; decoder 200 ANE +
34 CPU, მათ შორის prompt-ის sin/cos/linear. EdgeSAM: ALL encoder 272 ANE +
19 GPU; CPU_AND_NE encoder 291 ANE. Edge decoder 200 ANE + 34 CPU.
არცერთი encoder მთლიანად CPU-ზე არ ჩამოვარდნილა ამ Mac-ზე.

Constant/არამინიჭებული ოპერაციები ცალკეა (Efficient encoder 482, decoder 344;
Mobile encoder 752, decoder 344; Edge encoder 980, decoder 344).
ისინი CPU fallback-ად არ ითვლება. ეს რიცხვები iPhone-ზე შეიძლება განსხვავდებოდეს.

coremltools 8.3 აფრთხილებს, რომ Torch 2.7 მის ოფიციალურად დატესტილ 2.5-ზე ახალია.
პინები შენარჩუნებულია გამეორებადობისთვის; ექვსივე მოდელის კონვერტაცია, ჩატვირთვა,
რეალური prediction და compute plan შემოწმდა. TracerWarning ეხება ფიქსირებული
ფორმების Python განშტოებებს; ექსპორტი მხოლოდ მითითებულ სტატიკურ ფორმებს იღებს.
FP16 არჩევამ quality შეცვალა: EfficientSAM gym/p2 PyTorch-ში 0.8202 იყო,
Core ML-ში 0.7978. Core ML/PyTorch არჩეული მასკების მინიმალური ურთიერთ-IoU
EfficientSAM-ზე 0.9467-ია; ახლო score-ებისას არჩეული token-იც იცვლება.

## Swift-ის ზუსტი I/O კონტრაქტი — არჩეული EfficientSAM-Ti

ორი დამოუკიდებელი `mlprogram`, iOS 17 deployment target, FP16 შიდა გამოთვლა
და weights; გარე ტენზორები Float32 `MLMultiArray`-ია. მოქნილი ზომები არ არის.

| მოდელი | მიმართულება | სახელი | ფორმა | dtype / მნიშვნელობა |
|---|---|---|---|---|
| SAMEncoder | input | `image` | `[1,3,1024,1024]` | Float32, RGB NCHW, 0…255 |
| SAMEncoder | output | `embedding` | `[1,256,64,64]` | Float32 |
| SAMDecoder | input | `embedding` | `[1,256,64,64]` | Float32, იგივე encoder-ის შედეგი |
| SAMDecoder | input | `box` | `[4]` | Float32 `[x0,y0,x1,y1]`, 1024×1024 კოორდინატებში |
| SAMDecoder | output | `mask_logits` | `[1,3,256,256]` | Float32, სამი შეუკვეცავი low-res logit მასკა |
| SAMDecoder | output | `iou_scores` | `[1,3]` | Float32, შესაბამისი ხარისხის პროგნოზი |

Preprocessing:

1. თავდაპირველად ორიენტაცია და RGB არხების რიგი გაასწორეთ. `W,H` არის ამავე
   ორიენტირებული კადრის ზომები; box-ებიც ამ კადრს უნდა ეკუთვნოდეს.
2. EfficientSAM-ისთვის გამოსახულება **პირდაპირ 1024×1024-ზე resize**: bilinear,
   `align_corners=False`, antialias=False; aspect ratio არ ინახება, padding არ არის.
   ყოველი output center-ის წყაროს კოორდინატია `(dst+0.5)*srcSize/1024-0.5`,
   საზღვრები clamp-დება. შეინარჩუნეთ Float32, ხელახლა uint8-ზე არ დაამრგვალოთ.
3. RGB 0…255 მიეცით encoder-ს. Normalization მოდელშია:
   `(RGB - [123.675,116.28,103.53]) / [58.395,57.12,57.375]`.
   Swift-ში normalization მეორედ არ გააკეთოთ.
4. რეფერენსის შესატყვისად 0…1000 XYXY box-ის პირველი ორი კოორდინატი
   `floor(x0*W/1000), floor(y0*H/1000)`, ბოლო ორი
   `ceil(x1*W/1000), ceil(y1*H/1000)`-ით გადადის საწყის პიქსელებში.
   შემდეგ X-ები გამრავლდეს `1024/W`-ზე, Y-ები `1024/H`-ზე.
   დაუშვებელია არაკორექტული/შებრუნებული/არასრულყოფილი box; დასაშვები საზღვარია 1024.
   გარედან 0.5 **არ დაამატოთ**: decoder-ში ორი კუთხის labels 2 და 3,
   ოთხი padding prompt (-1) და pixel-center shift უკვე ჩაშენებულია.
5. Embedding ერთ კადრზე ერთხელ მიიღეთ და ყველა ნაწილის decoder-ს გაუზიარეთ.
   Box-ის შეცვლა ხელახალ encoder-ს არ მოითხოვს; სხვა კადრი კი მოითხოვს.

Postprocessing:

- `argmax(iou_scores[0])` ირჩევს ერთ-ერთ სამ მასკას; score-ის threshold-ით
  კლასიფიკაცია არ გამოიყენება. Score არის პროგნოზი და შეიძლება შეცდეს.
- შერჩეული 256×256 logits **პირდაპირ საწყის H×W-ზე bicubic** interpolate,
  `align_corners=False` (PyTorch cubic coefficient `a=-0.75`, boundary clamp).
  EfficientSAM-ისთვის არც 1024 intermediate upsample და არც padding crop არ არის.
- საბოლოო მასკა `upsampled_logit > 0`. Threshold კეთდება resize-ის **შემდეგ**.
  Sigmoid საჭირო არაა; ბინარული მასკის resize ეკვივალენტური არ არის.
- Python `restore_masks` არის შესატყვისი რეფერენსი; Swift/Metal ან vImage
  იმპლემენტაცია ამ fixture-ებზე ცალკე უნდა შემოწმდეს, განსაკუთრებით პატარა ნაწილებზე.

ალტერნატიული Edge/Mobile პაკეტები სხვა preprocessing-ს მოითხოვს: longest side 1024,
მეორე ზომა `int(oldSize*1024/max(W,H)+0.5)`; PIL bilinear RGB uint8 resize,
მარჯვენა/ქვედა padding mean RGB-ით (normalization-ის შემდეგ ნულია).
Box მასშტაბირდება **დამრგვალებული resized ზომებით**. Postprocessing არის
256→1024 bilinear (`align_corners=False`), padding crop, შემდეგ საწყის ზომაზე
bilinear და threshold >0. მათი outputs არის `[1,4,256,256]` და `[1,4]`.
EfficientSAM-ის კონტრაქტს ნუ აურევთ ამ ვარიანტებში.

## დარჩენილი სამუშაო და ალტერნატივები

- iPhone 12 და 15 Pro: cold/warm encoder/decoder, sustained ტემპერატურა,
  memory peak, ALL/CPU_AND_NE, camera→mask სრული დრო; სამიზნეები 150/30 მს.
- Swift preprocessing/postprocessing-ის parity, რეალური კამერის ორიენტაცია და
  ნაწილის box კოორდინატები. Python benchmark-ის სისწრაფე ამ სამუშაოს არ მოიცავს.
- ყველა ნაწილის ≥0.8 gate ამ ექსპორტზე **ვერ გაიარა**. შემდეგი შესაძლო გზები:
  1. დამოუკიდებელ validation set-ზე მრავალმასკიანი არჩევის გაუმჯობესება.
     Efficient gym/p2-ს უკვე აქვს oracle IoU 0.9239-ის მასკა, მაგრამ score მას არ ირჩევს.
     Mobile-ის ჩავარდნილ სამ ნაწილზეც oracle >0.8-ია. ეს შესაძლებლობაა და არა
     განხორციელებული გამოსავალი; benchmark-ზე რეფერენსით შერჩევა მიუღებელია.
  2. SAM2 small-ის Core ML/ANE ექსპორტის ცალკე feasibility ტესტი, ლიცენზიის,
     ზომის, encoder/decoder I/O-სა და iPhone დროის თავიდან გაზომვით.
  3. სერვერული SAM2 იმ სცენებისთვის, სადაც ხარისხი გადამწყვეტია; ამას სჭირდება
     ქსელის დროის/ფოტოს დამუშავების პოლიტიკის შეთანხმება და ცალკე არქიტექტურული task.

არცერთი ალტერნატივა აქ არ განხორციელებულა. Swift, experiments/, Camera/ და
root `.gitignore` არ შეცვლილა. ადგილობრივი `.gitignore` ფაილები იცავს weights-ს,
`.mlpackage`-ებს, გარემოს და benchmark output-ს commit-ში მოხვედრისგან.

## გამეორება და შემოწმებები

სრული ბრძანებები: [ios/Tools/README.md](../ios/Tools/README.md).
`uv sync --project ios/Tools --python 3.11 --locked`; Python unit tests: 11 passed.
სამივე კანდიდატის `evaluate_candidates.py`, `convert_sam.py` და `bench_sam.py`
რეალურად გაშვებულია. Default პაკეტის benchmark დამატებით გაშვებულია საბოლოო
`ios/Models/` მისამართიდან. `out/bench.json` შეიცავს ნედლ sample-ებს, ხარისხის
gate-ებს, provenance-სა და compute plans-ს; `out/review/` — გადაფარულ მასკებს.
ვიზუალურად შემოწმდა sink/p3, car/p1 და gym/p2 overlay-ები.

Default `SAMEncoder.mlpackage`, `SAMDecoder.mlpackage` და `conversion.json`
git-შია (`ios/Models/`, root `.gitignore`-ის გამო `git add -f`-ით), რომ app build
და CI რეპროდუცირებადი იყოს. კანდიდატების ექსპორტები და upstream weights git-ში
არ შედის; მათ ზემოთ მითითებული export ბრძანება აღადგენს.

## Swift parity

`ios/Kadri/Segmentation/Segmenter.swift` (actor): `embed(CGImage)` → `Embedding`,
`mask(embedding:box:imageSize:)` → `Mask` (W×H, 0/255 bitmap, score, დროები).
Preprocessing: 8-bit RGBX გამოსახულების საკუთარ ფერთა სივრცეში (ფერის გარდაქმნის
გარეშე, PIL-ის მსგავსად), `vDSP_vfltu8` → planar Float32, separable bilinear
1024×1024-ზე პირდაპირ `MLMultiArray`-ში. Postprocessing: `iou_scores`-ის argmax
(თანაბრისას პირველი), შერჩეული 256×256 logits → separable bicubic H×W-ზე (`a=-0.75`,
`floor`, tap-ები საზღვარზე clamp-დება; index/lambda **არ** clamp-დება — PyTorch-თან
ასე ემთხვევა), შემდეგ `>0`. მხოლოდ Accelerate/vDSP, Metal არა. ორივე kernel PyTorch-ს
<1e-5-ით ემთხვევა (`interp.json`). მოდელები `MLModel(contentsOf:)`-ით იტვირთება
(`COREML_CODEGEN_LANGUAGE=None`, Swift 6).

Fixtures: `ios/KadriTests/Fixtures/make_fixtures.py` (1.5 MB) — `input.png`,
`boxes.json`, Python Core ML **CPU_ONLY** მასკები (`coreml_pN.png`; სიმულატორში Core ML
CPU-ზე მუშაობს) და SAM2 რეფერენსი (`sam2_pN.png`). Mac-ზე ALL და CPU_ONLY მასკები
ერთმანეთს მინ. IoU 0.9467-ით ემთხვევა (gym/p1), ამიტომ რეფერენსად CPU არჩეულია.

სიმულატორი (iPhone 17, Debug, `.cpuOnly`), 2026-10-17:

| სცენა/ნაწილი | IoU Python Core ML-თან | IoU SAM2-თან | არჩეული (Swift/Py) |
|---|---:|---:|---|
| sink p1 | 0.9982 | 0.9653 | 0/0 |
| sink p2 | 0.9840 | 0.8266 | 2/2 |
| sink p3 | 0.9925 | 0.8311 | 1/1 |
| sink p4 | 0.9979 | 0.9653 | 0/0 |
| sink p5 | 0.9932 | 0.9361 | 2/2 |
| car p1 | 0.9972 | 0.9320 | 2/2 |
| car p2 | 0.9547 | 0.9202 | **2/1** |
| gym p1 | 0.9984 | 0.9081 | 1/1 |
| gym p2 | 1.0000 | 0.8090 | 2/2 |
| gym p3 | 0.9991 | 0.9650 | 2/2 |
| gym p4 | 0.9985 | 0.9489 | 2/2 |
| gym p5 | 1.0000 | 0.9644 | 0/0 |
| gym p6 | 0.9993 | 0.9639 | 0/0 |
| gym p7 | 1.0000 | 0.8250 | 2/2 |

სცენის საშუალო SAM2-თან: sink 0.9049, car 0.9261, gym 0.9120 (≥0.8 gate გაიარა).
ყველა ნაწილი ≥0.95 Python Core ML-თან. ერთადერთი token-ის გადართვა car/p2-ზეა: score-ები
სიმულატორსა და Mac Core ML-ს შორის ~0.003-ით განსხვავდება, ამ ნაწილის ორი საუკეთესო კი
თითქმის თანაბარია (Swift 0.8926/0.8901, Python 0.8887/0.8896); ორივე მასკა ახლოსაა
(0.9547). ზღვარი არ შესუსტებულა. სიმულატორის დროები (Debug, მხოლოდ CPU, მხოლოდ
ორიენტაციისთვის — ტელეფონის ციფრები არაა): pre ≈130 მს, encoder ≈1.05 წმ,
decoder ≈25 მს/box, post ≈22–28 მს/box.

## ტელეფონის bench — ინსტრუქცია ადამიანისთვის

1. Xcode-ში `ios/Kadri.xcodeproj`, target Kadri → Signing & Capabilities → შენი Team.
   სქემა Kadri → Edit Scheme → Run → Build Configuration **Release** (Debug-ში
   pre/post ბევრად ნელია). აირჩიე ტელეფონი (iPhone 12 და iPhone 15 Pro) და Run.
2. აპში ზედა მარჯვენა „SAM bench“. ჩაიტვირთება ჩაშენებული sink კადრი (5 ნაწილი).
3. აირჩიე `ALL`, დააჭირე „გაშვება (10×)“. დაელოდე ცხრილს, შეამოწმე, რომ ფერადი
   მასკები ნაწილებს ფარავს. დააჭირე „კოპირება (JSON)“ და ჩასვი ჩატში.
4. იგივე გაიმეორე `CPU_AND_NE`-ით. შემდეგ ერთხელ ისევ `ALL` (მეორე გაშვება აჩვენებს
   ANE-ის cache-ის შემდეგ load/cold დროს). სურვილისამებრ „ფოტოს არჩევა“ — ცენტრალური
   box, გრძელი მხარე ≤1440 px.
5. JSON-ში: `loadMs` — ორივე მოდელის ჩატვირთვა; `encoderColdMs`/`decoderColdMs` —
   პირველი გაშვება ჩატვირთვის შემდეგ; `*WarmMs.median` — შემდეგი 10-ის მედიანა.
   სამიზნეები: encoder ≤150 მს, decoder ≤30 მს/box. პირველი გაშვება აპის დაყენების
   შემდეგ ყველაზე ცივია (ANE compile) — ჩაინიშნე ცალკე.
6. სურვილისამებრ: 5 წუთი ზედიზედ გაშვება და ტელეფონის გაცხელება (sustained ქცევა).
