"""Gemini parts-only adapter. REST, no retries, no OpenAI requests or step generation."""
import base64
import copy
from datetime import date
import hashlib
import json
import math
import os
from pathlib import Path
import time
import urllib.error
import urllib.request

import numpy as np
from PIL import Image
from jsonschema import Draft202012Validator

from realism import Budget, atomic_json
from variant_b import segment_boxes, render_parts, mask_quality
from variant_c import assign_ids, prompt_parts, schema_parts

PRICE_SOURCE = 'https://ai.google.dev/gemini-api/docs/pricing'
# Standard paid rates, USD / 1M; verified 2026-10-17. Never assume free-tier billing.
MODELS = {
    'gemini-3.8-flash': {'input': .75, 'output': 3.75, 'thinking': 'low'},
    'gemini-robotics-er-2-preview': {'input': 1., 'output': 5., 'thinking': 'minimal'},
    'gemini-3.5-flash-lite': {'input': .30, 'output': 2.50, 'thinking': 'minimal'},
}
MAX_OUTPUT = 8192
INPUT_CEILING = 1048576  # Reserve the full model context, not an unverified token estimate.


def model_config(model):
    if model not in MODELS:
        raise ValueError('Unknown model price; API blocked')
    if date.today() > date(2026, 12, 31):
        raise ValueError('Pricing needs re-verification; API blocked')
    return MODELS[model]


def box_xyxy(box):
    if not isinstance(box, list) or len(box) != 4:
        raise ValueError('box_2d must contain four coordinates')
    if any(type(v) not in (int, float) or not math.isfinite(v) or not 0 <= v <= 1000 for v in box):
        raise ValueError('Invalid box coordinate')
    y0, x0, y1, x1 = box
    if y1 <= y0 or x1 <= x0:
        raise ValueError('Box must have positive area')
    return [x0, y0, x1, y1]


def gemini_schema():
    schema = copy.deepcopy(schema_parts())
    part = schema['properties']['parts']['items']
    part['properties']['box_2d'] = part['properties'].pop('box')
    part['required'] = ['label', 'box_2d']
    return schema


def parse_parts(text):
    if not isinstance(text, str) or not text.strip():
        raise ValueError('Empty model response')
    # Structured JSON only: no repairing malformed/truncated output or discarding bad parts.
    result = json.loads(text)
    Draft202012Validator(gemini_schema()).validate(result)
    parts = []
    for part in result['parts']:
        if not part['label'].strip():
            raise ValueError('Empty label')
        parts.append({'label': part['label'], 'box': box_xyxy(part['box_2d'])})
    return {'object': result['object'], 'parts': parts}


def prompt(instructions):
    return prompt_parts(instructions).replace('box=[x0,y0,x1,y1]', 'box_2d=[ymin,xmin,ymax,xmax]')


def usage_cost(usage, config):
    if not isinstance(usage, dict) or 'promptTokenCount' not in usage or 'totalTokenCount' not in usage:
        raise ValueError('Missing usage; reservation retained')
    names = ('promptTokenCount', 'candidatesTokenCount', 'thoughtsTokenCount', 'totalTokenCount')
    counts = {k: usage.get(k, 0) for k in names}
    if any(type(v) is not int or v < 0 for v in counts.values()):
        raise ValueError('Invalid usage; reservation retained')
    inp = counts['promptTokenCount']
    # Include thinking; conservative if provider total contains any other generated tokens.
    output = max(counts['candidatesTokenCount'] + counts['thoughtsTokenCount'], counts['totalTokenCount'] - inp)
    return (inp * config['input'] + output * config['output']) / 1e6


def rest_generate(model, payload, key):
    request = urllib.request.Request(
        f'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent',
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json', 'x-goog-api-key': key}, method='POST')
    # No automatic retries, key in header only. Never persist exception text/HTTP bodies.
    try:
        with urllib.request.urlopen(request, timeout=55) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f'Gemini HTTP {exc.code}') from None
    except Exception:
        raise RuntimeError('Gemini transport failure') from None


def request_parts(model, source, instructions, destination, budget, transport=rest_generate):
    config = model_config(model)
    if budget.limit > 5:
        raise ValueError('Gemini budget must not exceed $5')
    key = os.environ.get('GEMINI_API_KEY', '').strip()
    if not key:
        raise ValueError('GEMINI_API_KEY missing')
    source, destination = Path(source), Path(destination)
    with Image.open(source) as im:
        if max(im.size) > 768:
            raise ValueError('Expected historical thumbnail <=768 pixels')
    image_bytes = source.read_bytes()
    schema = gemini_schema()
    text = prompt(instructions)
    payload = {'contents': [{'role': 'user', 'parts': [
        {'text': text}, {'inlineData': {'mimeType': 'image/png', 'data': base64.b64encode(image_bytes).decode()}}]}],
        'generationConfig': {'responseMimeType': 'application/json', 'responseJsonSchema': schema,
                             'thinkingConfig': {'thinkingLevel': config['thinking']},
                             'maxOutputTokens': MAX_OUTPUT, 'candidateCount': 1}}
    destination.mkdir(parents=True, exist_ok=True)
    request_key = str(destination.resolve())
    reservation = (INPUT_CEILING * config['input'] + MAX_OUTPUT * config['output']) / 1e6
    budget.change(request_key, reservation)
    atomic_json(destination / 'request.json', {'model': model, 'prompt': text, 'schema': schema,
        'generation_config': payload['generationConfig'], 'input_sha256': hashlib.sha256(image_bytes).hexdigest(),
        'price': config, 'price_source': PRICE_SOURCE, 'reserved_usd': reservation,
        'stream': False, 'stage': 1, 'retries': 0})
    started = time.perf_counter()
    try:
        raw = transport(model, payload, key)
        elapsed = time.perf_counter() - started
        atomic_json(destination / 'response.json', raw)
        cost = usage_cost(raw.get('usageMetadata'), config)
        budget.change(request_key, cost, settle=True)
        candidates = raw.get('candidates', [])
        if len(candidates) != 1 or candidates[0].get('finishReason') != 'STOP':
            raise ValueError('Missing or unfinished candidate')
        texts = [p['text'] for p in candidates[0].get('content', {}).get('parts', [])
                 if 'text' in p and not p.get('thought')]
        result = parse_parts(''.join(texts))
        validated_seconds = time.perf_counter() - started
        atomic_json(destination / 'result.json', result)
        metrics = {'first_box_full_response_seconds': elapsed if result['parts'] else None,
                   'response_seconds': elapsed, 'validated_parts_seconds': validated_seconds,
                   'part_count': len(result['parts']), 'usage': raw['usageMetadata'], 'usd': cost,
                   'model_version': raw.get('modelVersion'),
                   'definition': 'Full parts response including network; no count preflight; excludes SAM; empty parts has no first box'}
        atomic_json(destination / 'latency.json', metrics)
        return result, metrics
    except Exception as exc:
        atomic_json(destination / 'error.json', {'type': type(exc).__name__, 'elapsed_seconds': time.perf_counter()-started})
        raise


def render_stage1(source, result, destination, device='mps', sam=None):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    parts = assign_ids(result['parts'])
    atomic_json(destination / 'parts.json', {'object': result['object'], 'parts': parts})
    masks, seconds = segment_boxes(source, parts, device, sam)
    with Image.open(source) as image:
        render_parts(image.convert('RGB'), parts, masks, destination / 'parts.png')
        quality = mask_quality(parts, masks, image.size)
    np.savez_compressed(destination / 'masks.npz', masks=masks, ids=np.array([p['id'] for p in parts], dtype=str))
    atomic_json(destination / 'segmentation.json', {'seconds': seconds, 'device': device, 'quality': quality})
    return parts, masks
