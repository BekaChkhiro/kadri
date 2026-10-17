"""Render the saved paired summary and human visual notes as Georgian Markdown."""
from pathlib import Path
from prepare_gemini import load
from segmentation import HERE
from realism import percentiles


def main():
    root = HERE/'out_hybrid'
    data = load(root/'summary.json')
    h,a = data['hybrid'],data['astra']
    n=data['n']
    lines = ['# Gemini → SAM2 → Astra ჰიბრიდი', '',
        f'შეფასებულია **{n}/22 კადრი**, {h["steps"]} ნაბიჯი. '+
        ('კამპანია დასრულებულია.' if n==22 else '**შეფასება ნაწილობრივია; 22-კადრიანი საბოლოო დასკვნა არ კეთდება.**'), '',
        '## რეკომენდაცია', '',
        'ჰიბრიდი შემდგომი ექსპერიმენტის კანდიდატია, მაგრამ production pipeline-ად მიღებისთვის საკმარისი მტკიცებულება არ გვაქვს. '+
        'მონიშნული სამიზნეები ძირითად სცენებში გამოსადეგია, თუმცა ნაწილების გაერთიანება და დაკარგული პატარა კომპონენტები `avoid`-ის დეტალიზაციას ცვლის. '+
        'დიზაინის proxy არ ამტკიცებს ნაბიჯების ხარისხის ეკვივალენტობას. რეალური მომხმარებლის ფოტოები ჯერ არ შეფასებულა.', '',
        '## დაწყვილებული დროები', '',
        'წამები; ერთი ახალი ცდა თითო კადრზე. Astra C ისტორიულია და თავიდან არ გაშვებულა. p50/p90 ითვლება დასრულებული, იდენტური კადრების წყვილებზე.', '',
        '| მეტრიკა | Hybrid p50 | Hybrid p90 | Astra C p50 | Astra C p90 | Hybrid უფრო სწრაფია |',
        '|---|---:|---:|---:|---:|---:|']
    for key,title in [('first_box','პირველი box'),('outline','პირველი კონტური'),('first_step','პირველი სრული streaming ნაბიჯი'),('total','სრული დრო')]:
        lines.append(f'| {title} | {h[key]["p50"]:.3f} | {h[key]["p90"]:.3f} | {a[key]["p50"]:.3f} | {a[key]["p90"]:.3f} | {data["faster_frames"][key]}/{n} |')
    lines += ['', '### სცენების განაწილება', '',
        '| სცენა | კადრები | Hybrid outline p50 | Astra outline p50 | Hybrid first step p50 | Astra first step p50 |',
        '|---|---:|---:|---:|---:|---:|']
    for scene in sorted({r['scene'] for r in data['rows']}):
        rows=[r for r in data['rows'] if r['scene']==scene]
        values=[percentiles([r[name][field] for r in rows])['p50'] for field in
            ('time_to_first_outline_seconds','time_to_first_step_from_start_seconds') for name in ('hybrid','astra')]
        lines.append(f'| {scene} | {len(rows)} | '+ ' | '.join(f'{v:.3f}' for v in values)+' |')
    lines += ['', '„უფრო სწრაფია“ ითვლის იმავე კადრზე ნაკლებ დროს; ეს არ არის განმეორებითი ცდებით დადასტურებული სტაბილური უპირატესობა.', '',
        '## ხარისხი', '',
        '| მეტრიკა | Hybrid | Astra C |', '|---|---:|---:|',
        f'| Empty focus ნაბიჯები | {h["empty_focus"]}/{h["steps"]} | {a["empty_focus"]}/{a["steps"]} |',
        f'| საშუალო visible focus IoU, დიზაინის proxy | {h["focus_iou"]:.4f} | {a["focus_iou"]:.4f} |',
        f'| საშუალო visible avoid IoU, დიზაინის proxy | {h["avoid_iou"]:.4f} | {a["avoid_iou"]:.4f} |', '',
        'IoU ითვლება ნაწილების mask-ების union-სა და გარდაქმნილ ხილულ დიზაინის პოლიგონებს შორის. ორივე ცარიელი union → IoU=1. '+
        'დიზაინს sink-ის ვედროს ნაბიჯზე სიფონის პოლიგონი აქვს, მაშინ როცა უხილავი ვედროს სწორი პასუხი empty focus-ია. '+
        'avoid ხშირად დიზაინში საერთოდ არ არის მოცემული, ამიტომ დამატებითი გამაფრთხილებელი მონიშვნა proxy-ს ამცირებს. '+
        'ამრიგად ეს ქულები არც სემანტიკური სისწორისა და არც უსაფრთხოების ხარისხის საზომი არ არის. '+
        '`match_frames` შედეგები `summary.json`-ში ადარებს ნაწილებს geometry IoU≥0.5-ით; თანაბარი pN სხვადასხვა კადრში ავტომატურად ერთსა და იმავე ობიექტს არ ნიშნავს.', '',
        '## ვიზუალური შემოწმება', '']
    notes=load(root/'review/visual_notes.json')
    links={'sink/original':'sink-original-target.jpg', 'car/original':'car-original-avoid.jpg',
           'chemistry/original':'chemistry-original-step2.jpg', 'gym/original':'gym-original-weight.jpg'}
    for scene,note in notes.items():
        link=links.get(scene)
        lines.append(f'- **{scene}**: {note["finding"]}'+(f' [სურათი](out_hybrid/review/{link}).' if link else ''))
    lines += ['', '## ფასი და ბიუჯეტი', '',
        f'ახალი ledger: Gemini **${data["cost"]["gemini"]:.6f}**, OpenAI **${data["cost"]["openai"]:.6f}**, ჯამში **${sum(data["cost"].values()):.6f}**. '+
        f'დაუხურავი რეზერვაციები: {data["unsettled"]}. Ledger-ის თანხა მთელ კამპანიას მოიცავს, მათ შორის დაწყებულ კადრებს; ეს usage-ით დათვლილი შეფასებაა, არა ინვოისი.',
        f'დასრულებული {n} კადრის generation ჯამი: Hybrid ${data["paired_cost"]["hybrid"]:.6f}; ისტორიული Astra C ${data["paired_cost"]["astra"]:.6f}. '+
        'ისტორიული ფასები არსებული metrics-იდანაა, დათვლის preflight-ის სავარაუდო ხარჯის გარეშე.', '',
        'ერთ ledger-ში დაცულია Gemini ≤$0.50, OpenAI ≤$2 და ჯამი ≤$2.50. ფასები არსებული `gemini_stage1.py`/`vision.py`-დანაა; უცნობი ფასი იბლოკება. '+
        'Gemini რეზერვირდება ზუსტად იმავე request-ის countTokens input-ით და 2048 output ტოკენით, settlement მოიცავს thinking-საც. '+
        'countTokens უფასოდაა მიჩნეული მომხმარებლის მითითებით. OpenAI იყენებს არსებული `request_stage`-ის კონსერვატიულ input შეფასებას და 2200 output ტოკენს. '+
        'წარუმატებელი ფასიანი მოთხოვნის რეზერვაცია რჩება; SDK retries=0.', '',
        '## მეთოდი და შეზღუდვები', '',
        '- ახალი თანმიმდევრული timeline: Gemini 3.8 Flash (`thinking=low`) → `assign_ids` → SAM2 → `gpt-6-astra` (`effort=low`, streaming). Cache-იდან პასუხი latency-ის გასაზომად არ გამოყენებულა.',
        '- 22 thumbnail აღდგა `prepare_gemini.prepare(out_hybrid)`-ით და ისტორიული request hash-ებით გადამოწმდა. `prompt_audit.json` ადასტურებს 22-ვე baseline-ზე იმავე parts/steps prompt-ს, title/text ინსტრუქციებს და Astra effort=low-ს.',
        '- First box არის ვალიდური სრული Gemini parts პასუხი; Gemini countTokens-ის დრო შედის ყველა end-to-end მეტრიკაში და ცალკეც ინახება. First outline იზომება SAM-ისა და parts.png-ის render-ის შემდეგ. First step არის დასრულებული, schema-ით ვალიდური პირველი streaming ნაბიჯი. Total შეიცავს step render-საც.',
        '- ახალი OpenAI count preflight არ სრულდება, ისტორიულ C-ში კი სრულდებოდა. შესაბამისად ცხრილი ადარებს pipeline-ებს; მოდელების სუფთა inference speedup-ს არ იზოლირებს. Thumbnail-ის offline აღდგენა timeline-ს გარეთაა.',
        '- SAM-ის გაშვების დრო და მოდელის ჩატვირთვა შეიძლება განსხვავდებოდეს. Sink pilot-ის SAM იყო 10.951 წმ, ისტორიული 5.901 წმ; pilot-ის კონტური 17.978 vs 13.578 წმ, პირველი ნაბიჯი 25.952 vs 20.507 წმ. ეს ერთი ცდა თავისთავად აჩქარებას არ აჩვენებს.',
        '- სხვადასხვა დროს ჩატარებული თითო ცდა, მცირე შერჩევა და სინთეზური დეგრადაციები ვერ ამტკიცებს ეკვივალენტურ ხარისხს ან production latency-ს რეალურ ფოტოებზე.',
        '- პირველი matrix პროცესი 2 დასრულებული კადრის შემდეგ შეწყდა. car/shift_left-ზე paid generation არ დაწყებულა (reservation არ იყო). მომხმარებლის პირდაპირი თანხმობით attempt შენახულია `interrupted/`-ში და ახალი მცდელობა შესრულდა; ავტომატური retry არ გამოყენებულა.', '',
        '## არტეფაქტები და შემოწმება', '',
        '[რიცხვითი შედეგები და თითო კადრის დეტალები](out_hybrid/summary.json), [ბიუჯეტი](out_hybrid/budget.json), '+
        '[ისტორიული prompt-ების აუდიტი](out_hybrid/prompt_audit.json), [ვიზუალური ჩანაწერები](out_hybrid/review/visual_notes.json).', '',
        '`run_hybrid.py prepare`; `run_hybrid.py pilot --run`; `run_hybrid.py matrix --run`. '+
        'დასრულებული კადრები გამოტოვებულია, დაწყებული დაუმთავრებელი კადრი ჩერდება. '+
        'Offline ანგარიში: `report_hybrid.py`, შემდეგ `write_hybrid_report.py`. '+
        'სურათები input.png და step_*.png commit-ში არ შედის; შერჩეული review JPG-ები ინახება.', '',
        'Offline: 110 ტესტი გაიარა, მათ შორის 5 ახალი hybrid ტესტი და report-ის 2 ტესტი. ეს უკანასკნელი ამოწმებს mask resize-ს, ცარიელ union-ს და ნაბიჯების რაოდენობის აცდენის უარყოფას.']
    (HERE/'HYBRID.md').write_text('\n'.join(lines)+'\n')

if __name__=='__main__': main()
