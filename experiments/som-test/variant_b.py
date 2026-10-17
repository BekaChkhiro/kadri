"""AI-first boxes, dynamic part IDs, and adapters to the unchanged A pipeline."""
import base64
import copy
import itertools
import json
import math
import os
import time
import unicodedata

import cv2
import numpy as np
from jsonschema import Draft202012Validator
from PIL import Image, ImageDraw

from evaluation import evaluate, iou, truth_masks
from run import render_steps
from segmentation import HERE, digest, font, paint, save_json
from vision import PRICE_SOURCE, array, estimate_cost, obj, schema_for, validate_plan


class UnknownPartError(ValueError):
    def __init__(self, ids):
        self.ids = sorted(ids)
        super().__init__("Unknown part IDs")


def schema_b(count=5):
    # Reuse A's step contract, replacing only the precomputed ID enum.
    schema = schema_for([], count)
    def dynamic(value):
        if isinstance(value, dict):
            if value.get("enum") == []:
                value.pop("enum")
            for child in value.values():
                dynamic(child)
        elif isinstance(value, list):
            for child in value:
                dynamic(child)
    dynamic(schema)
    schema["properties"]["parts"] = array(obj({
        "id": {"type": "string", "pattern": "^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"},
        "label": {"type": "string", "minLength": 1},
        "box": {**array({"type": "number", "minimum": 0, "maximum": 1000}),
                "minItems": 4, "maxItems": 4},
    }))
    return schema


def box_pixels(box, size):
    """Normalized XYXY -> half-open pixel bounds, rounded outwards (no clipping)."""
    if len(box) != 4 or any(isinstance(v, bool) or not isinstance(v, (int, float))
                            or not math.isfinite(v) or not 0 <= v <= 1000 for v in box):
        raise ValueError("Box coordinates must be finite numbers in 0..1000")
    x0, y0, x1, y1 = box
    if x0 >= x1 or y0 >= y1:
        raise ValueError("Box must have positive width and height")
    w, h = size
    if w <= 0 or h <= 0:
        raise ValueError("Image dimensions must be positive")
    return [math.floor(x0 * w / 1000), math.floor(y0 * h / 1000),
            math.ceil(x1 * w / 1000), math.ceil(y1 * h / 1000)]


def as_a(plan):
    """Positional adapter only; the saved B plan retains semantic IDs."""
    result = copy.deepcopy(plan)
    mapping = {p["id"]: f"p{i}" for i, p in enumerate(plan["parts"], 1)}
    result["parts"] = {mapping[p["id"]]: p["label"] for p in plan["parts"]}
    for step in result["steps"]:
        for field in ("focus", "avoid"):
            step[field] = [mapping[pid] for pid in step[field]]
        for item in step["markers"] + step["arrows"]:
            item["part"] = mapping[item["part"]]
    return result


def validate_b(plan, count=5):
    Draft202012Validator(schema_b(count)).validate(plan)
    ids = [p["id"] for p in plan["parts"]]
    if len(set(ids)) != len(ids):
        raise ValueError("Duplicate part ID")
    for part in plan["parts"]:
        box_pixels(part["box"], (1000, 1000))
        if not part["label"].strip():
            raise ValueError("Empty part label")
    referenced = {pid for s in plan["steps"] for pid in
                  s["focus"] + s["avoid"] + [m["part"] for m in s["markers"] + s["arrows"]]}
    if referenced - set(ids):
        raise UnknownPartError(referenced - set(ids))
    adapted = as_a(plan)
    validate_plan(adapted, schema_for(list(adapted["parts"]), count))


def request_b(client, model, source, truth, destination):
    schema = schema_b(len(truth["steps"]))
    instructions = [{"title": s["title"], "text": s["text"]} for s in truth["steps"]]
    prompt = (
        "ორიგინალ ფოტოზე ამოიცანი მოცემული მოქმედებებისთვის საჭირო ხილული ნაწილები. "
        "object, label და სხვა ტექსტი დაწერე ქართულად. თითო ნაწილს მიანიჭე უნიკალური ინგლისური "
        "snake_case id და მჭიდრო box=[x0,y0,x1,y1], 0..1000 ნორმალიზებული ფოტოს სიგანის/სიმაღლის მიმართ, "
        "საწყისი ზედა მარცხენა კუთხეში. ნაბიჯებს შეუნარჩუნე title/text და რიგი. "
        "focus/avoid/markers/arrows-ში მიუთითე მხოლოდ parts-ის id. avoid არის ნაწილი, რომელსაც არ უნდა შეეხო. "
        "უხილავი ან გაურკვეველი ნაწილები არ გამოიგონო: აღწერე unknown_parts-ში, დატოვე focus ცარიელი "
        "და warn-ში ახსენი. rotate: cw/ccw; move: up/down/left/right/toward/away ეკრანის მიმართ, არა 3D. "
        "ინსტრუქციის ზომები/დოზები ფოტოდან დადასტურებულად არ მიიჩნიო. ეს კვლევაა, არა პროფესიული რჩევა.\n"
        + json.dumps(instructions, ensure_ascii=False)
    )
    effort = os.getenv("REASONING_EFFORT", "high")
    save_json(destination / "request.json", {"model": model, "prompt": prompt, "schema": schema,
                                             "original_image": str(source), "reasoning_effort": effort})
    encoded = base64.b64encode(source.read_bytes()).decode()
    kwargs = {"reasoning": {"effort": effort}} if model.startswith(("gpt-5", "gpt-6")) else {}
    start = time.perf_counter()
    response = client.responses.create(
        model=model, store=False, max_output_tokens=12000, **kwargs,
        input=[{"role": "user", "content": [{"type": "input_text", "text": prompt},
               {"type": "input_image", "image_url": f"data:image/png;base64,{encoded}", "detail": "high"}]}],
        text={"format": {"type": "json_schema", "name": "ai_first_plan", "strict": True, "schema": schema}},
    )
    seconds = time.perf_counter() - start
    raw = response.model_dump(mode="json")
    save_json(destination / "response.json", raw)
    usage = raw.get("usage") or {}
    save_json(destination / "metrics.json", {"seconds": seconds, "usage": usage,
              "estimated_usd": estimate_cost(usage, model) if usage else None,
              "price_source": PRICE_SOURCE, "price_checked": "2026-10-17",
              "status": response.status, "model": model, "returned_model": response.model})
    if response.status != "completed" or not response.output_text:
        raise ValueError("Response incomplete/refused; see response.json")
    plan = json.loads(response.output_text)
    validate_b(plan, len(truth["steps"]))
    save_json(destination / "plan.json", plan)
    return plan


def make_sam(device):
    os.environ.setdefault("YOLO_CONFIG_DIR", str(HERE / ".cache/ultralytics"))
    os.environ.setdefault("MPLCONFIGDIR", str(HERE / ".cache/matplotlib"))
    from ultralytics import SAM
    (HERE / "models").mkdir(exist_ok=True)
    return SAM(str(HERE / "models/sam2.1_b.pt"))


def segment_boxes(source, parts, device, sam=None):
    with Image.open(source) as image:
        size = image.size
    w, h = size
    start = time.perf_counter()
    masks = []
    if parts:
        sam = sam if sam is not None else make_sam(device)
    # One call per box preserves ID association even when SAM returns no mask.
    for part in parts:
        results = sam(source=str(source), bboxes=[box_pixels(part["box"], size)],
                      device=device, imgsz=1024, verbose=False, save=False,
                      project=str(HERE / ".cache/predict_b"))
        raw = results[0].masks
        if raw is None or len(raw.data) == 0:
            mask = np.zeros((h, w), bool)
        else:
            if len(raw.data) != 1:
                raise ValueError("Expected one SAM mask per box")
            mask = cv2.resize(raw.data[0].cpu().numpy().astype(np.uint8), size,
                              interpolation=cv2.INTER_NEAREST).astype(bool)
        masks.append(mask)
    stacked = np.stack(masks) if masks else np.zeros((0, h, w), bool)
    return stacked, time.perf_counter() - start


def mask_quality(parts, masks, size):
    rows = []
    for part, mask in zip(parts, masks):
        x0, y0, x1, y1 = box_pixels(part["box"], size)
        area, box_area = int(mask.sum()), (x1 - x0) * (y1 - y0)
        inside = int(mask[y0:y1, x0:x1].sum())
        rows.append({"id": part["id"], "box_pixels": [x0, y0, x1, y1], "mask_pixels": area,
                     "mask_fraction_inside_box": inside / area if area else 0.0,
                     "box_occupancy": inside / box_area, "mask_to_box_area": area / box_area,
                     "image_fraction": area / mask.size, "empty": area == 0,
                     "too_large": area / mask.size > 0.85 or area > 2 * box_area})
    return rows


def render_parts(image, parts, masks, destination):
    ids = [f"p{i}" for i in range(1, len(parts) + 1)]
    painted = paint(image, masks, [(47, 107, 255)] * len(parts), ids)
    face = font(22, True)
    lines = []
    for pid, part in zip(ids, parts):
        line = ""
        for word in f"{pid} · {part['id']} · {part['label']}".split():
            candidate = f"{line} {word}".strip()
            if line and face.getlength(candidate) > image.width - 32:
                lines.append(line)
                line = word
            else:
                line = candidate
        lines.append(line)
    canvas = Image.new("RGB", (image.width, image.height + 16 + 32 * len(lines)), "#0f172a")
    canvas.paste(painted)
    draw = ImageDraw.Draw(canvas)
    for i, line in enumerate(lines):
        draw.text((16, image.height + 8 + 32 * i), line, font=face, fill="white")
    canvas.save(destination)


def process_run(client, model, source, truth, destination, device, sam=None):
    """Persist errors without SDK exception text; never overwrite a different cached trial."""
    destination.mkdir(parents=True, exist_ok=True)
    fingerprint = {"model": model, "image_sha256": digest(source), "truth": truth,
                   "device": device, "sam_model": "sam2.1_b.pt", "protocol": 1}
    fp = destination / "fingerprint.json"
    if fp.exists() and json.loads(fp.read_text()) != fingerprint:
        raise ValueError("Cached run has different inputs; move its directory before rerunning")
    save_json(fp, fingerprint)
    try:
        path = destination / "plan.json"
        plan = json.loads(path.read_text()) if path.exists() else request_b(client, model, source, truth, destination)
        validate_b(plan, len(truth["steps"]))
        image = Image.open(source).convert("RGB")
        masks, seconds = segment_boxes(source, plan["parts"], device, sam)
        np.savez_compressed(destination / "masks.npz", masks=masks,
                            ids=np.array([p["id"] for p in plan["parts"]], dtype=str))
        adapted = as_a(plan)
        evaluation = evaluate(adapted, truth, masks, image.size)
        refs = truth_masks(truth, image.size)
        evaluation["parts"] = [{"id": p["id"], "design_ious":
                                {t["name"]: iou(mask, ref) for t, ref in zip(truth["parts"], refs)}}
                               for p, mask in zip(plan["parts"], masks)]
        save_json(destination / "evaluation.json", evaluation)
        save_json(destination / "segmentation.json", {"seconds": seconds, "device": device,
                  "model": "sam2.1_b.pt", "quality": mask_quality(plan["parts"], masks, image.size)})
        render_parts(image, plan["parts"], masks, destination / "parts.png")
        render_steps(image, masks, adapted, destination)
        (destination / "error.json").unlink(missing_ok=True)
        return plan
    except Exception as exc:
        error = {"type": type(exc).__name__, "status_code": getattr(exc, "status_code", None)}
        if isinstance(exc, UnknownPartError):
            error["unknown_ids"] = exc.ids
        save_json(destination / "error.json", error)
        raise


def box_iou(a, b):
    overlap = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    area = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1])
    return overlap / (area - overlap)


def consistency_b(plans):
    """One-to-one greedy matching: normalized equal labels and box IoU >= .5."""
    def label(p):
        return " ".join(unicodedata.normalize("NFKC", p["label"]).casefold().split())
    pairs = []
    for a, b in itertools.combinations(plans, 2):
        candidates = sorted([(box_iou(x["box"], y["box"]), i, j)
                             for i, x in enumerate(a["parts"]) for j, y in enumerate(b["parts"])
                             if label(x) == label(y)], reverse=True)
        used_a, used_b, matches = set(), set(), []
        for score, i, j in candidates:
            if score >= 0.5 and i not in used_a and j not in used_b:
                used_a.add(i)
                used_b.add(j)
                matches.append((i, j, score))
        mapping = {b["parts"][j]["id"]: a["parts"][i]["id"] for i, j, _ in matches}
        values = []
        for x, y in zip(a["steps"], b["steps"]):
            for field in ("focus", "avoid"):
                left = {("matched", pid) for pid in x[field]}
                right = {("matched", mapping[pid]) if pid in mapping else ("unmatched", pid) for pid in y[field]}
                values.append(len(left & right) / len(left | right) if left | right else 1.0)
        union = len(a["parts"]) + len(b["parts"]) - len(matches)
        pairs.append({"part_jaccard": len(matches) / union if union else 1.0,
                      "matched_box_iou": sum(m[2] for m in matches) / len(matches) if matches else None,
                      "step_jaccard": sum(values) / len(values) if values else None,
                      "matches": [{"a": a["parts"][i]["id"], "b": b["parts"][j]["id"], "iou": score}
                                  for i, j, score in matches]})
    return {"method": "Equal NFKC/casefold/whitespace-normalized labels; greedy one-to-one box IoU >= 0.5; synonyms not matched",
            "runs": len(plans), "pairs": pairs,
            "mean_part_jaccard": sum(p["part_jaccard"] for p in pairs) / len(pairs) if pairs else None,
            "mean_step_jaccard": sum(p["step_jaccard"] for p in pairs) / len(pairs) if pairs else None}
