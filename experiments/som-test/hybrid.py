"""Fresh Gemini -> SAM2 -> streamed Astra steps; no retries or cached timing."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.request

import numpy as np
from PIL import Image

from gemini_stage1 import model_config, gemini_schema, prompt, parse_parts, usage_cost, rest_generate
from realism import Budget, atomic_json
from variant_c import assign_ids, prompt_steps, schema_steps, request_stage, validate_steps
from variant_b import segment_boxes, render_parts, mask_quality
from run import render_steps

GEMINI = 'gemini-3.8-flash'
ASTRA = 'gpt-6-astra'
MAX_OUTPUT = 2048


class ProviderBudget:
    """Provider caps and shared cap checked under one lock; failures keep reservations."""
    def __init__(self, path, provider):
        self.path, self.provider = Path(path), provider
        self.limit = {'gemini': .5, 'openai': 2.}[provider]
        self.shared = Budget(self.path, limit=2.5)

    def change(self, key, amount, settle=False):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.with_suffix('.providers.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = json.loads(self.path.read_text()) if self.path.exists() else {'requests': {}}
            used = sum(v['usd'] for k, v in data['requests'].items() if k.startswith(self.provider + ':'))
            if not settle and used + amount > self.limit + 1e-10:
                raise RuntimeError(f'{self.provider} budget exhausted')
            self.shared.change(self.provider + ':' + key, amount, settle)

    def reserve(self, amount, label):
        self.change(label, amount)
        return label

    def settle(self, ticket, cost):
        if cost is not None:
            self.change(ticket, cost, settle=True)


def count_tokens(model, payload, key):
    req = urllib.request.Request(
        f'https://generativelanguage.googleapis.com/v1beta/models/{model}:countTokens',
        data=json.dumps({'generateContentRequest': {'model': 'models/' + model, **payload}}).encode(),
        headers={'Content-Type': 'application/json', 'x-goog-api-key': key}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=55) as response:
            return json.load(response)['totalTokens']
    except Exception:
        raise RuntimeError('Gemini countTokens failed') from None


def gemini_parts(source, instructions, dest, budget, counter=count_tokens, transport=rest_generate):
    config = model_config(GEMINI)
    dest.mkdir(parents=True, exist_ok=True)
    # Persist attempt before even the free count request: no implicit retry after failure.
    attempt = dest / 'attempt.json'
    with attempt.open('x') as handle:
        json.dump({'model': GEMINI, 'retries': 0}, handle)
    payload = {'contents': [{'role': 'user', 'parts': [
        {'text': prompt(instructions)}, {'inlineData': {'mimeType': 'image/png',
         'data': base64.b64encode(source.read_bytes()).decode()}}]}],
        'generationConfig': {'responseMimeType': 'application/json', 'responseJsonSchema': gemini_schema(),
         'thinkingConfig': {'thinkingLevel': 'low'}, 'maxOutputTokens': MAX_OUTPUT, 'candidateCount': 1}}
    key = os.environ.get('GEMINI_API_KEY', '').strip()
    if not key:
        raise ValueError('GEMINI_API_KEY missing')
    start = time.perf_counter()
    count = counter(GEMINI, payload, key)
    preflight = time.perf_counter() - start
    if type(count) is not int or not 0 < count <= 1048576:
        raise ValueError('Invalid input count')
    # Count covers the exact generation request, including structured response schema.
    reserve = (count * config['input'] + MAX_OUTPUT * config['output']) / 1e6
    budget.change(str(dest), reserve)
    atomic_json(dest / 'request.json', {'model': GEMINI, 'prompt': prompt(instructions),
        'schema': gemini_schema(), 'generation_config': payload['generationConfig'],
        'counted_input_tokens': count, 'count_seconds': preflight, 'reserved_usd': reserve,
        'input_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'rates': config})
    raw = transport(GEMINI, payload, key)
    atomic_json(dest / 'response.json', raw)
    cost = usage_cost(raw.get('usageMetadata'), config)
    budget.change(str(dest), cost, settle=True)
    candidates = raw.get('candidates', [])
    if len(candidates) != 1 or candidates[0].get('finishReason') != 'STOP':
        raise ValueError('Unfinished Gemini response; retry forbidden')
    result = parse_parts(''.join(p['text'] for p in candidates[0]['content']['parts']
                                if 'text' in p and not p.get('thought')))
    atomic_json(dest / 'result.json', result)
    metrics = {'seconds': time.perf_counter()-start, 'count_seconds': preflight, 'usd': cost}
    atomic_json(dest / 'metrics.json', metrics)
    return result, metrics


def process(client, source, instructions, dest, ledger, device='mps', sam=None):
    dest.mkdir(parents=True, exist_ok=True)
    with (dest / 'attempt.json').open('x') as handle:
        json.dump({'fresh_timeline': True, 'retries': 0}, handle)
    start = time.perf_counter()
    result, gem = gemini_parts(source, instructions, dest / 'parts_request', ProviderBudget(ledger, 'gemini'))
    first_box = time.perf_counter()-start if result['parts'] else None
    parts = assign_ids(result['parts'])
    atomic_json(dest / 'parts.json', {'object': result['object'], 'parts': parts})
    masks, sam_seconds = segment_boxes(source, parts, device, sam)
    with Image.open(source) as original:
        image = original.convert('RGB')
    render_parts(image, parts, masks, dest / 'parts.png')
    outline = time.perf_counter()-start if masks.any() else None
    np.savez_compressed(dest / 'masks.npz', masks=masks, ids=np.array([p['id'] for p in parts]))
    atomic_json(dest / 'segmentation.json', {'seconds': sam_seconds, 'quality': mask_quality(parts, masks, image.size)})
    steps_start = time.perf_counter()
    steps, sm = request_stage(client, ASTRA, 'steps', prompt_steps(result['object'], parts, instructions),
        schema_steps(parts, len(instructions)), source, dest / 'steps_request', 'low',
        ProviderBudget(ledger, 'openai'), {}, parts)
    plan = {'object': result['object'], 'parts': parts, **steps}
    atomic_json(dest / 'plan.json', plan)
    adapted = validate_steps(steps, parts, len(instructions))
    adapted['object'] = result['object']
    render_steps(image, masks, adapted, dest)
    metrics = {'real_wall_time_to_first_box_seconds': first_box,
        'time_to_first_outline_seconds': outline,
        'time_to_first_step_from_start_seconds': steps_start-start+sm['time_to_first_step_seconds'],
        'total_seconds': time.perf_counter()-start, 'sam_seconds': sam_seconds,
        'gemini_count_seconds': gem['count_seconds'], 'gemini_usd': gem['usd'],
        'definition': 'Fresh sequential wall time, includes Gemini countTokens and artifact writes; OpenAI has no count preflight; total includes render_steps.'}
    atomic_json(dest / 'latency.json', metrics)
    return metrics
