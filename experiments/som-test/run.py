"""uv run python run.py [--segment-only]; all writes stay in this experiment."""
import argparse
import json
import os
import shutil
from pathlib import Path

import numpy as np
from dotenv import load_dotenv
from PIL import Image, ImageDraw

from evaluation import consistency, coverage, evaluate, ground_truth, truth_masks
from segmentation import HERE, SCENES, font, paint, save_json, segment, digest
from vision import request_plan, schema_for, select_model, validate_plan


def contact_sheet(image, masks, destination):
    tile_w, tile_h, cols = 240, 280, 4
    sheet = Image.new("RGB", (tile_w * cols, tile_h * ((len(masks) + cols - 1) // cols)), "#f1f5f9")
    draw = ImageDraw.Draw(sheet)
    for i, mask in enumerate(masks):
        pixels = np.array(image)
        pixels[~mask] = (pixels[~mask] * 0.18).astype(np.uint8)
        ys, xs = np.where(mask)
        crop = Image.fromarray(pixels).crop((max(0, xs.min() - 15), max(0, ys.min() - 15),
                                             min(image.width, xs.max() + 16), min(image.height, ys.max() + 16)))
        crop.thumbnail((tile_w - 12, tile_h - 40))
        x, y = (i % cols) * tile_w, (i // cols) * tile_h
        sheet.paste(crop, (x + (tile_w - crop.width) // 2, y + 35))
        draw.text((x + 8, y + 4), f"p{i + 1}", font=font(22), fill="#0f172a")
    sheet.save(destination)


def render_steps(image, masks, plan, directory):
    for number, step in enumerate(plan["steps"], 1):
        ids = list(dict.fromkeys(step["focus"] + step["avoid"] + [m["part"] for m in step["markers"]]))
        colors = [(239, 68, 68) if pid in step["avoid"] else (47, 107, 255) for pid in ids]
        selected = [masks[int(pid[1:]) - 1] for pid in ids]
        result = paint(image, selected, colors, ids)
        # Georgian marker legend preserves the photo; IDs link labels to the masks.
        face = font(24, True)
        legend = [f"{number}. {step['title']}"] + [f"{m['part']}: {m['label']}" for m in step["markers"]]
        lines = []
        for entry in legend:
            line = ""
            for word in entry.split():
                candidate = f"{line} {word}".strip()
                if line and face.getlength(candidate) > image.width - 32:
                    lines.append(line)
                    line = word
                else:
                    line = candidate
            lines.append(line)
        canvas = Image.new("RGB", (image.width, image.height + 20 + 36 * len(lines)), "#0f172a")
        canvas.paste(result)
        draw = ImageDraw.Draw(canvas)
        for i, label in enumerate(lines):
            draw.text((16, image.height + 8 + 36 * i), label, font=face, fill="white")
        canvas.save(directory / f"step_{number}.png")


def write_report(summaries, mode):
    lines = ["# Set-of-Mark ექსპერიმენტი", "", f"მდგომარეობა: **{mode}**.", "",
             "კითხვა — მუშაობს თუ არა ID-ზე დაფუძნებული მიდგომა? "
             "საბოლოო პასუხს სჭირდება რეალური API ცდები და ვიზუალური შეფასება. "
             "სქემის ვალიდურობა ან ცდებს შორის თანხმობა სწორი ნაწილის არჩევას არ ამტკიცებს.", "",
             "მეთოდი: SAM2 automatic, 1024px, 16-წერტილიანი batch; grid/crop პარამეტრები ქვემოთაა. "
             "ფილტრი: <0.03% და >85% ფართობის მასკები იშლება; დუბლირება IoU≥0.90. "
             "ჩადგმული ნაწილები რჩება. ID-ები უცვლელია ქეშის ფარგლებში; ეს არ ამოწმებს ვიდეოტრეკინგს ან AR-ს.", "",
             "მოდელს მიეწოდება დანომრილი ფოტო და artboard-ის ხუთი მოქმედების title/text, იმავე რიგით. "
             "სწორი focus/avoid ID-ები, SVG კონტურები და მარკერების კოორდინატები არ ეგზავნება. "
             "ეს არის კონტროლირებული grounding ტესტი; ინსტრუქციების დამოუკიდებლად დაგეგმვას არ აფასებს.", "",
             "## შედეგები", "", "| სცენა | მასკები (საწყისი → დარჩენილი) | სეგმენტაცია | API წარმატებული ცდები | ID თანმიმდევრულობა |",
             "|---|---:|---:|---:|---:|"]
    for s in summaries:
        m = s["meta"]
        same = consistency(s["plans"])
        lines.append(f"| {s['scene']} | {m['raw_masks']} → {m['kept_masks']} | {m['seconds']:.2f} წმ | {len(s['plans'])}/3 | "
                     + (f"{same:.3f}" if same is not None else "ჯერ არ გაზომილა") + " |")
    for s in summaries:
        scene = s["scene"]
        config = s["meta"]["config"]
        lines += ["", f"## {scene}", "", f"პარამეტრები: {config['model']}, {config['device']}, grid={config['points_stride']}², crop layers={config['crop_n_layers']}.",
                  "", f"[დანომრილი ფოტო](out/{scene}/marked.png) · [ცალკეული მასკები](out/{scene}/parts.png) · "
                  f"[დიზაინის კონტურები](out/{scene}/ground_truth.png)", "",
                  "დიზაინის თითო ნაწილის საუკეთესო ერთეული SAM მასკა (მიახლოებითი IoU; სემანტიკური სიზუსტე არაა):", "",
                  "| ნაწილი | ID | IoU |", "|---|---|---:|"]
        for row in s["coverage"]:
            lines.append(f"| {row['part']} | {row['best_id']} | {row['best_iou']:.3f} |")
        for i, metrics in enumerate(s["metrics"], 1):
            usage = metrics.get("usage", {})
            cost = metrics.get("estimated_usd")
            cost_text = f"${cost:.5f}" if cost is not None else "უცნობია — ტარიფი შესამოწმებელია"
            lines += ["", f"ცდა {i}: {metrics['seconds']:.2f} წმ; input={usage.get('input_tokens', '?')}, "
                      f"output={usage.get('output_tokens', '?')}; შეფასებული ფასი: {cost_text}."]
        for error in s["errors"]:
            lines += ["", f"შეფერხება: {error}"]
    review = HERE / "VISUAL_REVIEW.md"
    if review.exists():
        lines += ["", review.read_text()]
    lines += ["", "## შეფასების საზღვრები და შემდეგი ნაბიჯი", "",
              "- ground_truth.json უშუალოდ artboard-ებიდან იკითხება; მათი SHA256 ინახება. SVG-ები დიზაინის მონიშვნებია და შეიძლება ფოტოს არ ემთხვეოდეს.",
              "- evaluation.json ითვლის თითო ნაბიჯის focus/avoid კონტურების გაერთიანების IoU-ს დიზაინთან. ეს მხოლოდ გეომეტრიული proxy-ა; ნამდვილი ID სიზუსტე ხელით უნდა შეფასდეს.",
              "- თანმიმდევრულობა: სამი ცდის ყველა წყვილის საშუალო Jaccard, თითო ნაბიჯის focus/avoid ID-ებზე; ორი ცარიელი სიმრავლის თანხმობა 1-ია.",
              "- უმასკვო პატარა ნაწილი unknown_parts-ში უნდა მოხვდეს; უცნობი ID სქემით იკრძალება.",
              "- key-ის გარეშე არც API latency, არც ტოკენები/ფასი და არც ID-არჩევის სიზუსტე არ გაზომილა.",
              "- ფასი არის standard short-context ტარიფით შეფასება, არა ინვოისი. უცნობი მოდელის/ბილინგის კატეგორიის ფასი არ გამოითვლება.",
              "- API ეტაპის შემდეგ შეამოწმეთ out/<scene>/run_<n>/step_*.png და review_template.json-ში მონიშნეთ ID-ის სისწორე; განსაკუთრებით მცირე ღილაკები, ქინძისთავი და სითხეების ხუფები.",
              "", "## წყაროები", "",
              "- [Ultralytics SAM2](https://docs.ultralytics.com/models/sam-2/)",
              "- [OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)",
              "- [OpenAI მოდელები](https://developers.openai.com/api/docs/models)",
              "- [OpenAI ფასები](https://developers.openai.com/api/docs/pricing) — გადამოწმებულია 2026-10-17."]
    (HERE / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--segment-only", action="store_true", help="Never call OpenAI, even when a key exists")
    parser.add_argument("--scene", choices=list(SCENES), action="append")
    parser.add_argument("--device", choices=["mps", "cpu"])
    parser.add_argument("--sam-model", choices=["sam2.1_b.pt", "sam2.1_s.pt"], default="sam2.1_b.pt")
    parser.add_argument("--points-stride", type=int, default=32)
    parser.add_argument("--crop-layers", type=int, choices=[0, 1, 2], default=1)
    parser.add_argument("--resegment", action="store_true", help="Recompute masks and discard outputs that refer to old IDs")
    args = parser.parse_args()
    if args.points_stride < 1:
        parser.error("--points-stride must be positive")
    load_dotenv(HERE / ".env")
    summaries = []
    for scene in args.scene or SCENES:
        image, masks, meta = segment(scene, args)
        out = HERE / "out" / scene
        truth = ground_truth(scene)
        save_json(out / "ground_truth.json", truth)
        contact_sheet(image, masks, out / "parts.png")
        refs = truth_masks(truth, image.size)
        paint(image, refs, [(255, 190, 30)] * len(refs), [p["name"] for p in truth["parts"]]).save(out / "ground_truth.png")
        score = coverage(truth, masks, image.size)
        save_json(out / "coverage.json", score)
        summaries.append({"scene": scene, "image": image, "masks": masks, "meta": meta, "truth": truth,
                          "coverage": score, "plans": [], "metrics": [], "errors": []})
        write_report(summaries, "სეგმენტაცია მიმდინარეობს; API არ გაშვებულა")
    if args.segment_only or not os.getenv("OPENAI_API_KEY", "").strip():
        write_report(summaries, "სეგმენტაცია დასრულებულია; API key-ს ელოდება" if not args.segment_only
                     else "მხოლოდ ლოკალური სეგმენტაცია; API არ გაშვებულა")
        print("სეგმენტაცია დასრულდა. API ეტაპისთვის დაამატეთ OPENAI_API_KEY experiments/som-test/.env-ში. key ჩატში არ ჩაწეროთ.")
        return 0 if args.segment_only else 2

    from openai import OpenAI
    client = OpenAI(max_retries=0, timeout=180)
    model = select_model(client, HERE / "out")
    print(f"OpenAI model: {model}", flush=True)
    failed = False
    for s in summaries:
        out = HERE / "out" / s["scene"]
        ids = [p["id"] for p in s["meta"]["parts"]]
        fingerprint = {"model": model, "marked_sha256": digest(out / "marked.png"),
                       "truth_sha256": s["truth"]["source_sha256"], "protocol": 1}
        for n in range(1, 4):
            dest = out / f"run_{n}"
            dest.mkdir(exist_ok=True)
            try:
                if (dest / "plan.json").exists():
                    if json.loads((dest / "fingerprint.json").read_text()) != fingerprint:
                        raise ValueError("Cached API result belongs to another model/input; move run folders before retrying")
                    plan = json.loads((dest / "plan.json").read_text())
                    validate_plan(plan, schema_for(ids))
                else:
                    save_json(dest / "fingerprint.json", fingerprint)
                    plan = request_plan(client, model, out / "marked.png", s["truth"], ids, dest)
                save_json(dest / "evaluation.json", evaluate(plan, s["truth"], s["masks"], s["image"].size))
                render_steps(s["image"], s["masks"], plan, dest)
                if not (dest / "review_template.json").exists():
                    save_json(dest / "review_template.json", {"reviewed": False, "steps": [
                        {"step": i, "correct_ids": None, "incorrect_ids": None, "missing_parts": None, "notes": ""}
                        for i in range(1, 6)]})
                if n == 1:
                    for p in dest.glob("step_*.png"):
                        shutil.copyfile(p, out / p.name)
                s["plans"].append(plan)
                print(f"{s['scene']}: API {n}/3 validated", flush=True)
            except Exception as exc:
                # Avoid dumping SDK exceptions that might contain request data or credentials.
                error = f"run_{n}: {type(exc).__name__}; იხილეთ შენახული response.json, თუ არსებობს"
                s["errors"].append(error)
                save_json(dest / "error.json", {"type": type(exc).__name__, "status_code": getattr(exc, "status_code", None)})
                failed = True
            if (dest / "metrics.json").exists():
                s["metrics"].append(json.loads((dest / "metrics.json").read_text()))
            write_report(summaries, "API ცდები მიმდინარეობს")
    write_report(summaries, "API ეტაპზე არის შეცდომები" if failed else "API ცდები დასრულებულია; ვიზუალური ID შეფასება დარჩენილია")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
