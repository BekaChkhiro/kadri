"""Responses API strict schema; account visibility checked before selecting a model."""
import base64
import json
import os
import time

from jsonschema import Draft202012Validator

from segmentation import save_json

# Ordered documented general-purpose vision models, checked 2026-10-17.
# models.list exposes IDs/access, not capability or quality rankings.
MODEL_ORDER = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.4", "gpt-5.2", "gpt-4.1", "gpt-4o"]
PRICES = {"gpt-6-astra": (10, 1, 12.5, 50), "gpt-6.1-sol": (2, 0.1, 2.5, 10)}
PRICE_SOURCE = "https://developers.openai.com/api/docs/pricing"


def obj(properties):
    return {"type": "object", "properties": properties, "required": list(properties), "additionalProperties": False}


def array(items):
    return {"type": "array", "items": items}


def schema_for(ids, count=5):
    string = {"type": "string"}
    part = {"type": "string", "enum": ids}
    step = obj({"title": string, "text": string, "focus": array(part), "avoid": array(part),
                "markers": array(obj({"part": part, "label": string,
                                      "tone": {"type": "string", "enum": ["brand", "danger", "neutral"]}})),
                "arrows": array(obj({"part": part, "type": {"type": "string", "enum": ["rotate", "move"]},
                                     "dir": {"type": "string", "enum": ["cw", "ccw", "up", "down", "left", "right", "toward", "away"]}})),
                "tools": array(string), "warn": {"type": ["string", "null"]}})
    # Strict schemas require all object properties. Empty label means unknown/background.
    return obj({"object": string, "parts": obj({part_id: string for part_id in ids}),
                "steps": {**array(step), "minItems": count, "maxItems": count},
                "unknown_parts": array(string)})


def validate_plan(plan, schema):
    Draft202012Validator(schema).validate(plan)
    for step in plan["steps"]:
        if set(step["focus"]) & set(step["avoid"]):
            raise ValueError("Same ID cannot be focus and avoid")
        for field in ("focus", "avoid"):
            if len(step[field]) != len(set(step[field])):
                raise ValueError("Duplicate ID in step")
        for arrow in step["arrows"]:
            if (arrow["type"] == "rotate") != (arrow["dir"] in ("cw", "ccw")):
                raise ValueError("Arrow direction incompatible with arrow type")
        referenced = step["focus"] + step["avoid"] + [m["part"] for m in step["markers"] + step["arrows"]]
        if any(not plan["parts"][pid].strip() for pid in referenced):
            raise ValueError("Referenced ID must have a recognized label")


def select_model(client, out):
    available = sorted(m.id for m in client.models.list())
    save_json(out / "available_models.json", available)
    override = os.getenv("OPENAI_MODEL", "").strip()
    model = override or next((m for m in MODEL_ORDER if m in available), None)
    if not model or model not in available:
        raise ValueError("No configured vision model is visible; set OPENAI_MODEL after checking available_models.json")
    return model


def estimate_cost(usage, model):
    if model not in PRICES or usage["input_tokens"] > 200_000:
        return None
    details = usage.get("input_tokens_details") or {}
    # Do not invent cache-write charges if the response reports a new billing category.
    if any(v for k, v in details.items() if k not in ("cached_tokens", "cache_write_tokens")):
        return None
    normal, cached, cache_write, output = PRICES[model]
    cached_count = details.get("cached_tokens", 0)
    write_count = details.get("cache_write_tokens", 0)
    return ((usage["input_tokens"] - cached_count - write_count) * normal + cached_count * cached + write_count * cache_write
            + usage["output_tokens"] * output) / 1_000_000


def request_plan(client, model, marked, truth, ids, destination):
    schema = schema_for(ids, len(truth["steps"]))
    instructions = [{"title": s["title"], "text": s["text"]} for s in truth["steps"]]
    prompt = (
        "ეს არის ფიქსირებული ფოტოს Set-of-Mark კვლევა. ტექსტი დაწერე ქართულად. "
        "ფოტოზე კონტურები და p1..pN არის სეგმენტები, არა სემანტიკური ნაწილები. "
        "მოცემულ ხუთ მოქმედებას დაუკავშირე რეალურად ხილული ნაწილები, იმავე რიგით. "
        "ნაწილს შეიძლება რამდენიმე ID დასჭირდეს. არ მოიგონო ID, კოორდინატები ან უხილავი ნაწილი. "
        "parts-ში უცნობი/ფონის სეგმენტის მნიშვნელობა იყოს ცარიელი სტრიქონი. "
        "unknown_parts-ში აღწერე საჭირო, მაგრამ უხილავი ან უსეგმენტო ნაწილები. "
        "ასეთ შემთხვევაში დატოვე შესაბამისი focus ცარიელი და warn-ში ახსენი. "
        "თავისუფლად მონიშნე რამდენიმე ID. avoid ნიშნავს ნაწილს, რომელსაც არ უნდა შეეხო. "
        "rotate: cw/ccw; move: up/down/left/right/toward/away ეკრანის მიმართ, არა 3D. "
        "არ მიიჩნიო ინსტრუქციების ზომები/დოზები ფოტოდან დადასტურებულად. "
        "გეგმა კვლევითი შედეგია, არა პროფესიული რჩევა.\n"
        + json.dumps(instructions, ensure_ascii=False)
    )
    save_json(destination / "request.json", {"model": model, "prompt": prompt, "schema": schema,
                                             "marked_image": str(marked), "reasoning_effort": "high"})
    encoded = base64.b64encode(marked.read_bytes()).decode()
    kwargs = {"reasoning": {"effort": "high"}} if model.startswith(("gpt-5", "gpt-6")) else {}
    start = time.perf_counter()
    response = client.responses.create(
        model=model, store=False, max_output_tokens=12000, **kwargs,
        input=[{"role": "user", "content": [{"type": "input_text", "text": prompt},
                {"type": "input_image", "image_url": f"data:image/png;base64,{encoded}", "detail": "high"}]}],
        text={"format": {"type": "json_schema", "name": "som_plan", "strict": True, "schema": schema}},
    )
    seconds = time.perf_counter() - start
    raw = response.model_dump(mode="json")
    save_json(destination / "response.json", raw)
    usage = raw.get("usage") or {}
    save_json(destination / "metrics.json", {"seconds": seconds, "usage": usage,
              "estimated_usd": estimate_cost(usage, model) if usage else None,
              "price_source": PRICE_SOURCE, "price_checked": "2026-10-17", "status": response.status,
              "model": model, "returned_model": response.model})
    if response.status != "completed" or not response.output_text:
        raise ValueError("Response incomplete/refused; see response.json")
    plan = json.loads(response.output_text)
    validate_plan(plan, schema)
    save_json(destination / "plan.json", plan)
    return plan
