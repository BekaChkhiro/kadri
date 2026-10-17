"""Two-stage experiment; phone-owned IDs, streamed steps, and offline comparisons."""
import base64
import io
import itertools
import json
import math
import re
import time

import cv2
import numpy as np
from jsonschema import Draft202012Validator
from PIL import Image

from segmentation import save_json
from variant_b import box_iou, box_pixels, mask_quality, render_parts, segment_boxes
from run import render_steps
from vision import PRICES, PRICE_SOURCE, array, estimate_cost, obj, schema_for, validate_plan

DEFAULT_MODEL = "gpt-6-astra"
OUTPUT_LIMITS = {"parts": 1200, "steps": 2200}
MODES = ("dark", "blur", "tilt", "jpeg")


def schema_parts():
    return obj({"object": {"type": "string"}, "parts": {**array(obj({
        "label": {"type": "string", "minLength": 1, "maxLength": 120},
        "box": {**array({"type": "number", "minimum": 0, "maximum": 1000}),
                "minItems": 4, "maxItems": 4},
    })), "maxItems": 24}})


def assign_ids(parts):
    """Sort centers by y, then x; box/label break exact ties, never model order."""
    for p in parts:
        box_pixels(p["box"], (1000, 1000))
        if not p["label"].strip():
            raise ValueError("Empty label")
    ordered = sorted(parts, key=lambda p: ((p["box"][1] + p["box"][3]) / 2,
                                           (p["box"][0] + p["box"][2]) / 2,
                                           tuple(p["box"]), p["label"]))
    return [{"id": f"p{i}", "label": p["label"], "box": list(p["box"])}
            for i, p in enumerate(ordered, 1)]


def prompt_parts(instructions):
    return ("ამ ფოტოზე გამოყავი მოქმედებებისთვის საჭირო მხოლოდ ფიზიკური ხილული კომპონენტები. "
            "ცარიელი ადგილი, ფონი ან ზონა, სადაც ნივთი უნდა დადგას, ნაწილი არ არის და parts-ში არ ჩასვა. "
            "დააბრუნე object და parts: ქართული label და მჭიდრო box=[x0,y0,x1,y1], "
            "ფოტოს სიგანის/სიმაღლის მიმართ 0..1000. ID-ები და ნაბიჯები არ შექმნა. "
            "თუ რამდენიმე მსგავსი ან ერთგვაროვანი ნაწილია, label-ში აუცილებლად დააზუსტე "
            "მდებარეობა (მაგ. მარჯვენა/მარცხენა/ზედა/ქვედა), რათა მოქმედების სამიზნე მკაფიოდ გაირჩეს. "
            "იმავე label string-ში მოკლედ აღწერე ხილული განმასხვავებელი მტკიცებულება "
            "(წვეთები, სველი კვალი, შეერთება) მხოლოდ თუ ფოტოზე ჩანს; არ მიაწერო ნავარაუდევი მტკიცებულება. "
            "უხილავი ნაწილი არ გამოიგონო.\n" + json.dumps(instructions, ensure_ascii=False))


def prompt_steps(object_name, parts, instructions):
    return ("დაწერე მოცემული ნაბიჯები ქართულად, იმავე რიგით და title/text-ით. "
            "გამოიყენე მხოლოდ ტელეფონის მიერ მინიჭებული IDs. focus/avoid/markers/arrows "
            "მიუთითებს მხოლოდ ამ ნაწილებზე. avoid არის ნაწილი, რომელსაც არ უნდა შეეხო. "
            "როცა მოცემულ parts სიაში მოქმედების ხილული სამიზნის რამდენიმე plausible კანდიდატია, "
            "მიმაგრებულ ფოტოზე გადაამოწმე მდებარეობა და ხილული მტკიცებულება (წვეთები, სველი კვალი, შეერთება). "
            "აირჩიე ყველაზე სავარაუდო box ამ ხილული მტკიცებულების, მდებარეობის, label-ისა და ინსტრუქციის მიხედვით; "
            "არ აირჩიო მხოლოდ სიაში პირველი კანდიდატი და არ გამოიგონო მტკიცებულება. "
            "focus-ში მიუთითე მისი ID და warn-ში ჩაწერე გაურკვევლობა/დაშვება (uncertainty). "
            "არ დატოვო focus ცარიელი მხოლოდ იმიტომ, რომ რამდენიმე მსგავსი ხილული ნაწილია. "
            "empty focus დასაშვებია მხოლოდ მაშინ, როცა სამიზნე ნაწილების სიაში ან ფოტოზე საერთოდ არ ჩანს (უხილავია); "
            "ასეთ დროს არ გამოიგონო ID, არ აიძულო არარელევანტური ნაწილი, აღწერე unknown_parts-ში და warn-ში ახსენი. "
            "თუ დასადგმელი ნივთი (მაგ. ვედრო) არ ჩანს, დატოვე empty focus; "
            "ცარიელი ადგილის, ფონის ან დასადგმელი ზონის ID-ის გამოყენება აკრძალულია. "
            "rotate: cw/ccw; move: up/down/left/right/toward/away. "
            "ზომები/დოზები ფოტოდან დადასტურებულად არ მიიჩნიო. ეს კვლევაა. "
            "პირველი JSON გასაღები იყოს steps.\n" + json.dumps({"object": object_name,
            "parts": parts, "instructions": instructions}, ensure_ascii=False))


def schema_steps(parts, count):
    base = schema_for([p["id"] for p in parts], count)
    result = obj({k: base["properties"][k] for k in ("steps", "unknown_parts")})
    step = result["properties"]["steps"]["items"]["properties"]
    if not parts:
        # Empty enum is invalid JSON Schema; no references are possible instead.
        for field in ("focus", "avoid", "markers", "arrows"):
            step[field] = {"type": "array", "items": {"type": "string"}, "maxItems": 0}
    else:
        step["focus"]["description"] = (
            "მოქმედების სამიზნე ხილული ნაწილების ID-ები (p1..pN). როდესაც მოქმედების სამიზნის "
            "რამდენიმე plausible კანდიდატია, აირჩიე ყველაზე სავარაუდო ID მდებარეობის/ინსტრუქციის "
            "მიხედვით და warn-ში ჩაწერე გაურკვევლობა. empty focus დასაშვებია მხოლოდ მაშინ, როცა "
            "სამიზნე ნაწილი სიაში/ფოტოზე საერთოდ არ ჩანს (უხილავია). არ გამოიგონო ID."
        )
        step["warn"]["description"] = (
            "გაფრთხილება, უსაფრთხოების რჩევა ან გაურკვევლობის (uncertainty) ახსნა, მათ შორის თუ "
            "სამიზნე უხილავია ან რამდენიმე კანდიდატს შორის შეირჩა ყველაზე სავარაუდო."
        )
    return result


def validate_steps(result, parts, count):
    Draft202012Validator(schema_steps(parts, count)).validate(result)
    plan = {"object": "", "parts": {p["id"]: p["label"] for p in parts}, **result}
    if parts:
        validate_plan(plan, schema_for(list(plan["parts"]), count))
    return plan


def match_parts(reference, observed, threshold=.5):
    """Greedy one-to-one geometry proxy, independent of labels and assigned IDs."""
    candidates = sorted(((-box_iou(a["box"], b["box"]), i, j)
                         for i, a in enumerate(reference) for j, b in enumerate(observed)))
    used_a, used_b, matches = set(), set(), []
    for negative, i, j in candidates:
        if -negative >= threshold and i not in used_a and j not in used_b:
            used_a.add(i)
            used_b.add(j)
            matches.append({"reference": reference[i]["id"], "observed": observed[j]["id"],
                            "iou": -negative, "same_id": reference[i]["id"] == observed[j]["id"]})
    n = len(matches)
    return {"reference_count": len(reference), "observed_count": len(observed),
            "count_change": len(observed) - len(reference), "matched": n,
            "matched_fraction_reference": n / len(reference) if reference else None,
            "matched_fraction_observed": n / len(observed) if observed else None,
            "same_id_fraction_matched": sum(m["same_id"] for m in matches) / n if n else None,
            "same_id_fraction_reference": sum(m["same_id"] for m in matches) / len(reference) if reference else None,
            "mean_iou": sum(m["iou"] for m in matches) / n if n else None, "matches": matches}


def consistency_c(runs):
    common, stable = set(), set()
    if runs:
        common = {p["id"] for p in runs[0]}
        stable = set(common)
        for later in runs[1:]:
            matches = match_parts(runs[0], later)["matches"]
            common &= {m["reference"] for m in matches}
            stable &= {m["reference"] for m in matches if m["same_id"]}
    return {"method": "Greedy one-to-one box IoU >= 0.5; geometry proxy, not semantic truth",
            "runs": len(runs),
            "reference_parts_matched_in_all_runs": len(common) if len(runs) > 1 else None,
            "reference_parts_with_same_id_in_all_runs": len(stable) if len(runs) > 1 else None,
            "same_id_fraction_all_runs": len(stable) / len(runs[0]) if len(runs) > 1 and runs[0] else None,
            "pairs": [{"a": i + 1, "b": j + 1, **match_parts(a, b)}
            for (i, a), (j, b) in itertools.combinations(enumerate(runs), 2)]}


def degrade(image, mode="clean", seed=0):
    """Return pixels plus normalized clean->degraded homogeneous transform."""
    image = image.convert("RGB")
    pixels = np.array(image)
    rng = np.random.default_rng(seed)
    transform = np.eye(3)
    meta = {"mode": mode, "seed": seed}
    if mode == "dark":
        # Linear-light exposure -1.5 EV, then display gamma and sensor noise.
        linear = (pixels / 255.0) ** 2.2
        pixels = np.clip((linear * 2 ** -1.5) ** (1 / 2.2) * 255 +
                         rng.normal(0, 5, pixels.shape), 0, 255).astype(np.uint8)
        meta.update(exposure_ev=-1.5, gamma=2.2, noise_sigma=5)
    elif mode == "blur":
        kernel = np.zeros((15, 15), np.float32)
        kernel[7, :] = 1 / 15
        pixels = cv2.filter2D(pixels, -1, kernel)
        meta["motion_pixels"] = 15
    elif mode == "tilt":
        w, h = image.size
        angle = float(rng.choice([-12, 12]))
        rotation = np.vstack([cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1), [0, 0, 1]])
        # Fixed center crop removes rotation borders for these portrait fixtures.
        x0, y0 = int(w * .15), int(h * .15)
        cw, ch = w - 2 * x0, h - 2 * y0
        crop = np.array([[w / cw, 0, -x0 * w / cw], [0, h / ch, -y0 * h / ch], [0, 0, 1]])
        matrix = crop @ rotation
        pixels = cv2.warpAffine(pixels, matrix[:2], (w, h), flags=cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_REFLECT_101)
        transform = np.diag([1000 / w, 1000 / h, 1]) @ matrix @ np.diag([w / 1000, h / 1000, 1])
        meta.update(angle_degrees=angle, crop_xyxy=[x0, y0, w - x0, h - y0])
    elif mode == "jpeg":
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=35)
        buffer.seek(0)
        pixels = np.array(Image.open(buffer).convert("RGB"))
        meta["quality"] = 35
    elif mode != "clean":
        raise ValueError("Unknown degradation")
    meta["clean_to_image"] = transform.tolist()
    return Image.fromarray(pixels), meta


def transform_parts(parts, matrix):
    """Project clean boxes into degraded coordinates; exclude fully cropped boxes."""
    result = []
    for p in parts:
        x0, y0, x1, y1 = p["box"]
        corners = np.array([[x0, y0, 1], [x1, y0, 1], [x1, y1, 1], [x0, y1, 1]])
        xy = (np.asarray(matrix) @ corners.T).T[:, :2]
        box = np.clip([*xy.min(axis=0), *xy.max(axis=0)], 0, 1000).tolist()
        if box[2] > box[0] and box[3] > box[1]:
            result.append({**p, "box": box})
    return result


def rates_for(model, overrides):
    if model in overrides:
        return overrides[model]
    if model in PRICES:
        return PRICES[model][0], PRICES[model][3]
    raise ValueError(f"Unknown price for {model}; pass --price MODEL=IN_PER_1M,OUT_PER_1M")


def cost_for(usage, model, overrides):
    if model not in overrides:
        return estimate_cost(usage, model)
    inp, out = overrides[model]
    # Manual two-rate tariffs deliberately charge cached input at the full rate.
    return (usage["input_tokens"] * inp + usage["output_tokens"] * out) / 1_000_000


def forecast(model, overrides, stage, input_tokens=16000):
    inp, out = rates_for(model, overrides)
    return (input_tokens * inp + OUTPUT_LIMITS[stage] * out) / 1_000_000


class BudgetExceeded(RuntimeError):
    pass


class Budget:
    """Reserve before sending; uncertain failed requests keep their reservation."""
    def __init__(self, limit, path=None):
        if not math.isfinite(limit) or limit <= 0:
            raise ValueError("Budget must be finite and positive")
        self.limit, self.path = limit, path
        self.entries = json.loads(path.read_text())["entries"] if path and path.exists() else []

    @property
    def spent(self):
        return sum(e["charged_usd"] for e in self.entries)

    def save(self):
        if self.path:
            # Replace atomically; the CLI owns an exclusive lock for the whole batch.
            temp = self.path.with_suffix(".tmp")
            save_json(temp, {"estimated_spent_usd": self.spent, "entries": self.entries})
            temp.replace(self.path)

    def reserve(self, amount, label):
        if not math.isfinite(amount) or amount < 0:
            raise ValueError("Invalid estimate")
        if self.spent + amount > self.limit + 1e-12:
            raise BudgetExceeded(f"Budget: {self.spent:.4f} + {amount:.4f} > {self.limit:.4f}")
        self.entries.append({"label": label, "reserved_usd": amount, "charged_usd": amount,
                             "status": "reserved_or_unknown"})
        self.save()
        return len(self.entries) - 1

    def settle(self, ticket, cost):
        if cost is not None and math.isfinite(cost) and cost >= 0:
            self.entries[ticket].update(charged_usd=cost, status="usage_estimated")
        self.save()


def first_step(text, parts):
    """Decode one complete step, never a partial token or unclosed JSON object."""
    match = re.match(r'^\s*\{\s*"steps"\s*:\s*\[\s*', text)
    if not match:
        return None
    try:
        step, _ = json.JSONDecoder().raw_decode(text, match.end())
    except json.JSONDecodeError:
        return None
    validate_steps({"steps": [step], "unknown_parts": []}, parts, 1)
    return step


def request_stage(client, model, stage, prompt, schema, source, destination, effort,
                  budget, overrides, parts=None, clock=time.perf_counter):
    destination.mkdir(parents=True, exist_ok=True)
    content = [{"type": "input_text", "text": prompt}]
    if source:
        encoded = base64.b64encode(source.read_bytes()).decode()
        content.append({"type": "input_image", "image_url": f"data:image/png;base64,{encoded}", "detail": "high"})
    # Text bytes are a pessimistic token estimate; image allowance is an estimate,
    # not an account spending cap. The larger of this and 16k is reserved.
    input_estimate = max(16000, len((prompt + json.dumps(schema)).encode()) + (8192 if source else 0) + 512)
    reservation = forecast(model, overrides, stage, input_estimate)
    kwargs = {"model": model, "store": False, "max_output_tokens": OUTPUT_LIMITS[stage],
              "input": [{"role": "user", "content": content}],
              "text": {"format": {"type": "json_schema", "name": f"variant_c_{stage}",
                                    "strict": True, "schema": schema}}}
    if model.startswith(("gpt-5", "gpt-6")):
        kwargs["reasoning"] = {"effort": effort}
    if stage == "steps":
        kwargs["stream"] = True
    save_json(destination / "request.json", {"model": model, "stage": stage, "prompt": prompt,
              "schema": schema, "source": str(source) if source else None,
              "reasoning_effort": effort if "reasoning" in kwargs else None,
              "stream": stage == "steps", "max_output_tokens": OUTPUT_LIMITS[stage],
              "reserved_usd": reservation, "input_token_estimate": input_estimate})
    ticket = budget.reserve(reservation, str(destination))
    start = clock()
    ttfs, buffer, response = None, "", None
    try:
        if stage == "steps":
            stream = client.responses.create(**kwargs)
            try:
                for event in stream:
                    if event.type == "response.output_text.delta":
                        buffer += event.delta
                        if ttfs is None:
                            step = first_step(buffer, parts)
                            if step is not None:
                                ttfs = clock() - start
                                save_json(destination / "first_step.json", step)
                    elif event.type in ("response.completed", "response.incomplete", "response.failed"):
                        response = event.response
                    elif event.type == "error":
                        raise RuntimeError("Streaming error")
            finally:
                stream.close()
            if response is None:
                raise RuntimeError("Stream ended without terminal response")
        else:
            response = client.responses.create(**kwargs)
        seconds = clock() - start
        raw = response.model_dump(mode="json")
        save_json(destination / "response.json", raw)
        usage = raw.get("usage") or {}
        cost = cost_for(usage, model, overrides) if usage else None
        budget.settle(ticket, cost)
        save_json(destination / "metrics.json", {"seconds": seconds, "time_to_first_step_seconds": ttfs,
                  "usage": usage, "estimated_usd": cost, "reserved_usd": reservation,
                  "price_source": "manual --price" if model in overrides else PRICE_SOURCE,
                  "price_checked": "manual" if model in overrides else "2026-10-17",
                  "model": model, "returned_model": response.model, "status": response.status})
        if response.status != "completed" or not response.output_text:
            raise ValueError("Response incomplete/refused")
        result = json.loads(response.output_text)
        Draft202012Validator(schema).validate(result)
        if stage == "steps":
            validate_steps(result, parts, len(result["steps"]))
            if ttfs is None:
                raise ValueError("No complete first step found in stream")
        save_json(destination / "result.json", result)
        return result, {"seconds": seconds, "time_to_first_step_seconds": ttfs}
    except Exception as exc:
        save_json(destination / "error.json", {"type": type(exc).__name__,
                  "status_code": getattr(exc, "status_code", None), "partial_text": buffer,
                  "time_to_first_step_seconds": ttfs})
        raise


def process_c(client, model, source, truth, destination, device, effort, max_side,
              mode, seed, budget, overrides, sam=None):
    destination.mkdir(parents=True, exist_ok=True)
    start = time.perf_counter()
    with Image.open(source) as original:
        image = original.convert("RGB")
    image.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
    image, degradation = degrade(image, mode, seed)
    prepared = destination / "input.png"
    image.save(prepared)
    save_json(destination / "degradation.json", degradation)
    instructions = [{"title": s["title"], "text": s["text"]} for s in truth["steps"]]
    parts_prompt = prompt_parts(instructions)
    result, parts_metrics = request_stage(client, model, "parts", parts_prompt, schema_parts(),
        prepared, destination / "parts_request", effort, budget, overrides)
    parts = assign_ids(result["parts"])
    save_json(destination / "parts.json", {"object": result["object"], "parts": parts})
    masks, sam_seconds = segment_boxes(prepared, parts, device, sam)
    render_parts(image, parts, masks, destination / "parts.png")
    outline = time.perf_counter() - start if masks.any() else None
    metrics = {"time_to_first_outline_seconds": outline, "parts_seconds": parts_metrics["seconds"],
               "sam_seconds": sam_seconds, "part_count": len(parts), "mode": mode,
               "model": model, "effort": effort, "image_size": list(image.size)}
    save_json(destination / "metrics.json", metrics)
    np.savez_compressed(destination / "masks.npz", masks=masks, ids=np.array([p["id"] for p in parts], dtype=str))
    save_json(destination / "segmentation.json", {"seconds": sam_seconds, "device": device,
              "quality": mask_quality(parts, masks, image.size)})
    print(f"{model}/{mode}: outline={outline}, parts={len(parts)}", flush=True)
    prompt = prompt_steps(result["object"], parts, instructions)
    steps_start = time.perf_counter()
    steps, steps_metrics = request_stage(client, model, "steps", prompt, schema_steps(parts, len(instructions)),
        prepared, destination / "steps_request", effort, budget, overrides, parts)
    plan = {"object": result["object"], "parts": parts, **steps}
    save_json(destination / "plan.json", plan)
    adapted = validate_steps(steps, parts, len(instructions))
    adapted["object"] = result["object"]
    render_steps(image, masks, adapted, destination)
    metrics.update(time_to_first_step_seconds=steps_metrics["time_to_first_step_seconds"],
                   time_to_first_step_from_start_seconds=steps_start - start + steps_metrics["time_to_first_step_seconds"],
                   steps_seconds=steps_metrics["seconds"], total_seconds=time.perf_counter() - start)
    save_json(destination / "metrics.json", metrics)
    return {"parts": parts, "degradation": degradation, "metrics": metrics}
