"""Deterministic pixel stress tests and crash-safe, counted B/C adapters."""
import copy
import fcntl
import hashlib
import io
import json
import math
import os
import re
from contextlib import contextmanager
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

KINDS = ('original', 'dark_noise', 'motion_blur', 'tilt_crop', 'lowres', 'jpeg', 'occlusion', 'shift_left', 'shift_right')


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w') as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sanitized_error_field(value, limit=160):
    """Never stringify exception/request objects; redact before truncating."""
    if not isinstance(value, str):
        return None
    for name, secret in sorted(os.environ.items(), key=lambda item: len(item[1]), reverse=True):
        if secret and (len(secret) >= 8 or re.search(r'key|token|secret|password|credential|auth', name, re.I)):
            value = value.replace(secret, '[REDACTED]')
    value = re.sub(r'(?i)sk-[a-z0-9_-]+|bearer\s+[^\s\"\',;]+', '[REDACTED]', value)
    # Provider messages can echo arbitrary request JSON, headers or image bytes.
    # Drop such messages entirely instead of trying to parse an untrusted dump.
    if re.search(r'[{}]|data:|base64|authorization|api.key|input_image|image_url|headers|request\s*[:=]', value, re.I):
        return '[omitted: possible request echo]'
    value = re.sub(r'[A-Za-z0-9+/=_-]{64,}', '[REDACTED]', value)
    return ' '.join(value.split())[:limit]


@contextmanager
def request_errors(destination, stage):
    """Persist only allowlisted diagnostics and re-raise without retry/settlement."""
    try:
        yield
    except Exception as exc:
        body = getattr(exc, 'body', None)
        body = body if isinstance(body, dict) else {}
        if isinstance(body.get('error'), dict):
            body = body['error']
        status = getattr(exc, 'status_code', None)
        atomic_json(Path(destination) / 'request_error.json', {
            'stage': stage,
            'http_status': status if type(status) is int else None,
            'code': sanitized_error_field(body.get('code')),
            'type': sanitized_error_field(body.get('type')),
            'param': sanitized_error_field(body.get('param')),
            # str(exc) often contains the full response: never use it as fallback.
            'message': sanitized_error_field(body.get('message'), 500),
        })
        raise


def degrade(image, masks, kind, seed=0):
    """Return RGB, full/visible masks, source->frame homogeneous transform and seed."""
    if kind not in KINDS:
        raise ValueError(kind)
    image = image.convert('RGB')
    w, h = image.size
    rng = np.random.default_rng(seed)
    matrix = np.eye(3)
    params = {}
    if kind == 'tilt_crop':
        matrix[:2] = cv2.getRotationMatrix2D((w / 2, h / 2), 7, 1.15)
        params = {'angle_degrees': 7, 'zoom': 1.15}
    elif kind.startswith('shift_'):
        matrix[0, 2] = round(w * .04) * (-1 if kind == 'shift_left' else 1)
        matrix[1, 2] = round(h * .015)
    pixels = cv2.warpPerspective(np.asarray(image), matrix, (w, h), borderMode=cv2.BORDER_CONSTANT)
    full = np.asarray([cv2.warpPerspective(m.astype(np.uint8), matrix, (w, h), flags=cv2.INTER_NEAREST).astype(bool)
                       for m in masks], dtype=bool).reshape((-1, h, w))
    occluder = np.zeros((h, w), np.uint8)
    if kind == 'dark_noise':
        params = {'brightness': .28, 'noise_sigma': 13}
        pixels = np.clip(pixels.astype(float) * .28 + rng.normal(0, 13, pixels.shape), 0, 255).astype(np.uint8)
    elif kind == 'motion_blur':
        length = max(3, round(w * .025)) | 1
        kernel = np.zeros((length, length), np.float32)
        cv2.line(kernel, (0, length - 1), (length - 1, 0), 1, 1)
        pixels = cv2.filter2D(pixels, -1, kernel / kernel.sum())
        params = {'kernel_length': length, 'angle_degrees': -45}
    elif kind == 'lowres':
        small = (max(1, w // 8), max(1, h // 8))
        pixels = cv2.resize(cv2.resize(pixels, small, interpolation=cv2.INTER_AREA), (w, h), interpolation=cv2.INTER_LINEAR)
        params = {'small_size': small}
    elif kind == 'jpeg':
        buffer = io.BytesIO()
        Image.fromarray(pixels).save(buffer, format='JPEG', quality=12, subsampling=2)
        pixels = np.asarray(Image.open(io.BytesIO(buffer.getvalue())).convert('RGB'))
        params = {'quality': 12, 'subsampling': 2}
    elif kind == 'occlusion':
        # A rendered opaque bottle silhouette: explicitly synthetic object occlusion.
        points = np.array([(int(w*x), int(h*y)) for x, y in
                          [(.43,.30),(.57,.30),(.57,.39),(.65,.45),(.65,.82),(.35,.82),(.35,.45),(.43,.39)]])
        cv2.fillPoly(occluder, [points], 1)
        pixels[occluder.astype(bool)] = (89, 112, 126)
        params = {'object': 'synthetic opaque bottle', 'polygon': points.tolist()}
    return Image.fromarray(pixels), full, full & ~occluder.astype(bool), {
        'protocol': 1, 'kind': kind, 'seed': seed, 'source_to_frame': matrix.tolist(),
        'size': [w, h], 'parameters': params, 'border': 'constant black', 'mask_interpolation': 'nearest'}


def mask_truth(truth, masks, size):
    """Raster-exact pixel-cell SVG adapter for B's unchanged truth reader."""
    result = copy.deepcopy(truth)
    result['design_size'] = list(size)
    for part, mask in zip(result['parts'], masks):
        # Horizontal runs preserve holes and tiny/disconnected regions.
        paths = []
        for y, row in enumerate(mask):
            edges = np.flatnonzero(np.diff(np.r_[False, row, False].astype(np.int8)))
            for x0, x1 in zip(edges[::2], edges[1::2]):
                # B rasterizes inclusive polygon coordinates.
                paths.append(f'M{x0} {y} L{x1-1} {y} L{x1-1} {y} Z')
        part['path'] = ' '.join(paths) or 'M-10 -10 L-9 -10 L-9 -9 Z'
    return result


def compensated_boxes(parts, matrix, size):
    inverse = np.linalg.inv(np.asarray(matrix))
    w, h = size
    boxes = []
    for part in parts:
        x0, y0, x1, y1 = np.asarray(part['box']) / 1000 * [w, h, w, h]
        corners = np.array([[x0,y0,1],[x1,y0,1],[x1,y1,1],[x0,y1,1]]) @ inverse.T
        corners = corners[:, :2] / corners[:, 2:]
        boxes.append([*corners.min(axis=0), *corners.max(axis=0)])
    return boxes


def match_frames(previous, current, previous_meta, current_meta, threshold=.5, phone_ids=None):
    """Geometry-only deterministic greedy one-to-one matching; no label gate."""
    from variant_b import box_iou
    a = compensated_boxes(previous, previous_meta['source_to_frame'], previous_meta['size'])
    b = compensated_boxes(current, current_meta['source_to_frame'], current_meta['size'])
    candidates = sorted([(-box_iou(x,y), i,j) for i,x in enumerate(a) for j,y in enumerate(b)])
    used_a, used_b, matches = set(), set(), []
    old_ids = phone_ids or [f'phone_{i+1}' for i in range(len(a))]
    assigned = [None] * len(b)
    for negative, i, j in candidates:
        if -negative < threshold or i in used_a or j in used_b:
            continue
        used_a.add(i); used_b.add(j)
        assigned[j] = old_ids[i]
        matches.append({'previous': i, 'current': j, 'iou': -negative, 'phone_id': old_ids[i],
                        'raw_id_equal': previous[i]['id'] == current[j]['id'],
                        'raw_label_equal': previous[i]['label'] == current[j]['label']})
    occupied = set(old_ids)
    next_id = 1
    for j in range(len(b)):
        if assigned[j] is None:
            while f'phone_{next_id}' in occupied:
                next_id += 1
            assigned[j] = f'phone_{next_id}'
            occupied.add(assigned[j])
    return {'method': 'geometry-only greedy one-to-one IoU; inverse transform compensation',
            'threshold': threshold, 'matches': matches, 'phone_ids': assigned,
            'unmatched': sorted(set(range(len(b))) - used_b), 'dropout': sorted(set(range(len(a))) - used_a),
            'raw_id_stability': sum(m['raw_id_equal'] for m in matches)/len(matches) if matches else None,
            'raw_label_stability': sum(m['raw_label_equal'] for m in matches)/len(matches) if matches else None}


def confidence_sweep(previous, current, previous_meta, current_meta, thresholds=(.25,.5,.75)):
    # B provides no calibrated confidence; sweep association IoU, never invent scores.
    return {'confidence_available': False, 'sweep_parameter': 'association_iou',
            'results': [match_frames(previous,current,previous_meta,current_meta,t) for t in thresholds]}


from types import SimpleNamespace


def payload_sha256(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()


def percentiles(values):
    values = [float(v) for v in values if v is not None]
    return {'n': len(values), 'p50': float(np.percentile(values, 50)) if values else None,
            'p90': float(np.percentile(values, 90)) if values else None}


class Budget:
    """Shared ledger; uncertain requests retain the entire reservation indefinitely."""
    def __init__(self, path, limit=13):
        if not math.isfinite(limit) or not 0 < limit <= 13:
            raise ValueError('Budget must be in (0,13]')
        self.path, self.limit = Path(path), limit

    def change(self, key, amount, settle=False):
        if not math.isfinite(amount) or amount < 0:
            raise ValueError('Invalid amount')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.with_suffix('.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = json.loads(self.path.read_text()) if self.path.exists() else {'limit': self.limit, 'requests': {}}
            if data['limit'] != self.limit:
                raise ValueError('Ledger limit mismatch')
            rows = data['requests']
            if settle:
                row = rows[key]
                if row['state'] != 'reserved' or amount > row['usd']:
                    raise ValueError('Invalid settlement; reservation retained')
                rows[key] = {'state': 'settled', 'usd': amount}
            else:
                if key in rows:
                    raise RuntimeError('Request already reserved/charged; automatic retry forbidden')
                if sum(r['usd'] for r in rows.values()) + amount > self.limit + 1e-10:
                    raise RuntimeError('Budget exhausted')
                rows[key] = {'state': 'reserved', 'usd': amount}
            atomic_json(self.path, data)


def validate_adapter_config(destination, variant, model, source, truth, device, budget, rates,
                            effort, max_side=None, seed=None):
    import inspect
    if variant == 'c':
        from variant_c import prompt_parts, prompt_steps, schema_parts, schema_steps, OUTPUT_LIMITS
        protocol = [inspect.getsource(f) for f in (prompt_parts, prompt_steps, schema_parts, schema_steps)] + [OUTPUT_LIMITS]
    else:
        from variant_b import request_b, schema_b
        protocol = [inspect.getsource(f) for f in (request_b, schema_b)]
    config = {'variant': variant, 'model': model, 'device': device, 'rates': list(rates),
              'ledger': str(budget.path.resolve()), 'effort': effort, 'max_side': max_side,
              'seed': seed, 'truth': payload_sha256(truth), 'protocol': payload_sha256(protocol),
              'input_hash': hashlib.sha256(Path(source).read_bytes()).hexdigest() if Path(source).exists() else None}
    path = destination / 'adapter_config.json'
    if path.exists():
        if json.loads(path.read_text()) != config:
            raise ValueError('Resume configuration mismatch')
    elif (destination / 'complete.json').exists() or (destination / 'plan.json').exists():
        raise ValueError('Existing result lacks verifiable configuration')
    atomic_json(path, config)


def validate_model_effort(model, effort):
    # Confirmed by the campaign's diagnostic count HTTP 400 (2026-10-17).
    # Do not infer compatibility for other model IDs or effort values.
    if model == 'gpt-6-astra' and effort == 'minimal':
        raise ValueError('gpt-6-astra does not support reasoning.effort=minimal; use low or another supported effort')


def run_b_adapter(client, model, source, truth, destination, device, budget, rates, process=None):
    """Token-counted preflight and conservative Responses B adapter."""
    import copy
    validate_model_effort(model, os.getenv('REASONING_EFFORT', 'high'))
    from variant_b import process_run
    if rates is None or len(rates) != 2 or any(not math.isfinite(r) or r <= 0 for r in rates):
        raise ValueError('Explicit conservative input/output USD per million required')
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    # Whole-call lock also prevents concurrent SAM/resume writes to the same run.
    with (destination / '.run.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        validate_adapter_config(destination, 'b', model, source, truth, device, budget, rates,
                                os.getenv('REASONING_EFFORT', 'high'))
        if (destination / 'complete.json').exists() and (destination / 'plan.json').exists():
            return json.loads((destination / 'plan.json').read_text())
        replay = (destination / 'plan.json').exists()
        preflight_info = {'latency': 0.0}
        if (destination / 'preflight.json').exists():
            try:
                preflight_info['latency'] = json.loads((destination / 'preflight.json').read_text()).get('latency_seconds', 0.0)
            except Exception:
                pass

        def create(**kwargs):
            if not hasattr(client, 'responses') or not hasattr(client.responses, 'input_tokens') or not hasattr(client.responses.input_tokens, 'count'):
                raise NotImplementedError('Responses input_tokens.count unsupported by client')

            kwargs = copy.deepcopy(kwargs)
            call_model = kwargs.get('model', model)
            validate_model_effort(call_model, (kwargs.get('reasoning') or {}).get('effort'))
            kwargs['truncation'] = 'disabled'
            count_payload = {
                'model': call_model,
                'input': copy.deepcopy(kwargs.get('input', [])),
                'truncation': 'disabled',
            }
            if 'text' in kwargs:
                count_payload['text'] = copy.deepcopy(kwargs['text'])
            if kwargs.get('reasoning') is not None:
                count_payload['reasoning'] = copy.deepcopy(kwargs['reasoning'])

            payload_hash = payload_sha256(count_payload)
            dest_hash = hashlib.sha256(str(destination.resolve()).encode()).hexdigest()
            count_key = f"{dest_hash}:count"
            gen_key = f"{dest_hash}:gen"

            ceiling = 100_000
            count_reserve = (ceiling * rates[0]) / 1_000_000
            budget.change(count_key, count_reserve, settle=False)

            t_count_0 = time.perf_counter()
            with request_errors(destination, 'count'):
                count_res = client.responses.input_tokens.count(**copy.deepcopy(count_payload))
            preflight_latency = time.perf_counter() - t_count_0
            preflight_info['latency'] = preflight_latency

            if hasattr(count_res, 'input_tokens'):
                counted_tokens = count_res.input_tokens
            elif isinstance(count_res, dict) and 'input_tokens' in count_res:
                counted_tokens = count_res['input_tokens']
            else:
                raise ValueError(f"Invalid count response: {count_res}")

            if not isinstance(counted_tokens, int) or isinstance(counted_tokens, bool) or counted_tokens < 0:
                raise ValueError(f"Input token count must be non-negative int, got: {type(counted_tokens).__name__} ({counted_tokens})")

            if counted_tokens > ceiling:
                raise ValueError(f"Input token count {counted_tokens} exceeds {ceiling} ceiling")

            count_cost = (counted_tokens * rates[0]) / 1_000_000
            budget.change(count_key, count_cost, settle=True)
            atomic_json(destination / 'preflight.json', {
                'hash': payload_hash,
                'input_tokens': counted_tokens,
                'count_billing_confirmed': False,
                'latency_seconds': preflight_latency,
            })

            # Verify create payload matches preflight counted payload before sending
            create_verify = {
                'model': call_model,
                'input': copy.deepcopy(kwargs.get('input', [])),
                'truncation': 'disabled',
            }
            if 'text' in kwargs:
                create_verify['text'] = copy.deepcopy(kwargs['text'])
            if kwargs.get('reasoning') is not None:
                create_verify['reasoning'] = copy.deepcopy(kwargs['reasoning'])
            if payload_sha256(create_verify) != payload_hash:
                raise ValueError("Create payload does not match counted preflight payload")

            max_out = kwargs.get('max_output_tokens', 12000)
            gen_reserve = (ceiling * rates[0] + max_out * rates[1]) / 1_000_000
            budget.change(gen_key, gen_reserve, settle=False)

            with request_errors(destination, 'generation'):
                response = client.responses.create(**kwargs)
            raw = response.model_dump(mode='json')
            usage = raw.get('usage') or {}
            inputs, outputs = usage.get('input_tokens'), usage.get('output_tokens')
            if (isinstance(inputs, int) and not isinstance(inputs, bool) and
                isinstance(outputs, int) and not isinstance(outputs, bool) and
                0 <= inputs <= ceiling and 0 <= outputs <= max_out):
                actual = (inputs * rates[0] + outputs * rates[1]) / 1_000_000
                atomic_json(destination / 'budget_response.json', raw)
                budget.change(gen_key, actual, settle=True)
                atomic_json(destination / 'budget_cost.json', {
                    'count_allowance_usd': count_cost,
                    'count_billing_confirmed': False,
                    'generation_usd_estimate': actual,
                    'usd_upper_estimate': count_cost + actual,
                    'rates': rates,
                })
            return response

        wrapped = SimpleNamespace(responses=SimpleNamespace(create=create))
        started = time.perf_counter()
        plan = (process or process_run)(wrapped, model, source, truth, destination, device)
        api = json.loads((destination / 'metrics.json').read_text()) if (destination / 'metrics.json').exists() else {}
        sam = json.loads((destination / 'segmentation.json').read_text()) if (destination / 'segmentation.json').exists() else {}
        pref = preflight_info['latency']
        api_seconds = api.get('seconds')
        model_only = max(0.0, api_seconds - pref) if api_seconds is not None else None
        real_wall = api_seconds
        atomic_json(destination / 'latency.json', {
            'is_replay': replay,
            'first_box_full_response_seconds': None if replay else real_wall,
            'first_box_model_only_seconds': None if replay else model_only,
            'preflight_seconds': pref,
            'real_wall_time_to_first_box_seconds': None if replay else real_wall,
            'sam_seconds': sam.get('seconds'),
            'adapter_wall_seconds': time.perf_counter() - started,
            'first_box_definition': 'B full response; no streaming; includes preflight in real wall time; excludes SAM',
        })
        return plan


class CBudgetAdapter:
    """Lifecycle-only budget adapter for variant C to prevent double reservations."""
    def __init__(self, realism_budget):
        self.realism_budget = realism_budget
        self.wrapper = None

    def reserve(self, amount, label):
        path = Path(label)
        stage_key = hashlib.sha256(str(path.resolve()).encode()).hexdigest()
        return stage_key

    def settle(self, ticket, cost):
        # The Responses wrapper validates terminal usage and settles exactly once.
        pass


class CachedResponse:
    def __init__(self, raw, output_text):
        self._raw = raw
        self.status = raw.get('status', 'completed')
        self.output_text = output_text or raw.get('output_text', '')
        self.model = raw.get('model', '')

    def model_dump(self, mode='json'):
        return self._raw


class CachedStream:
    def __init__(self, raw, output_text):
        self.raw = raw
        self.output_text = output_text
        self.closed = False

    def __iter__(self):
        yield SimpleNamespace(type='response.output_text.delta', delta=self.output_text)
        yield SimpleNamespace(type='response.completed', response=CachedResponse(self.raw, self.output_text))

    def close(self):
        self.closed = True


class CResumeResponsesWrapper:
    def __init__(self, underlying_client, destination, realism_budget, rates, resume=False):
        import copy
        self.underlying_client = underlying_client
        self.underlying_responses = getattr(underlying_client, 'responses', underlying_client)
        self.destination = Path(destination)
        self.realism_budget = realism_budget
        self.rates = rates
        self.resume = resume
        self.replayed_stages = set()
        self.replayed_names = set()

    def create(self, **kwargs):
        import copy
        is_stream = bool(kwargs.get('stream'))
        stage = 'steps' if is_stream or 'steps' in kwargs.get('text', {}).get('format', {}).get('name', '') else 'parts'
        stage_dir = self.destination / f'{stage}_request'
        stage_key = hashlib.sha256(str(stage_dir.resolve()).encode()).hexdigest()
        kwargs = copy.deepcopy(kwargs)
        kwargs['truncation'] = 'disabled'

        req_signature = {
            'model': kwargs.get('model'),
            'input': copy.deepcopy(kwargs.get('input', [])),
            'text': copy.deepcopy(kwargs.get('text')),
            'reasoning': copy.deepcopy(kwargs.get('reasoning')),
            'truncation': 'disabled',
        }
        req_signature = {k: v for k, v in req_signature.items() if v is not None}
        req_hash = payload_sha256(req_signature)

        is_cached_match = False
        if self.resume and (stage_dir / 'result.json').exists() and (stage_dir / 'response.json').exists() and (stage_dir / 'request_hash.json').exists():
            try:
                saved_hash = json.loads((stage_dir / 'request_hash.json').read_text()).get('request_hash')
                raw = json.loads((stage_dir / 'response.json').read_text())
                if saved_hash == req_hash and raw.get('status') == 'completed':
                    is_cached_match = True
            except Exception:
                pass

        if self.resume and (stage_dir / 'response.json').exists() and not is_cached_match:
            raise ValueError('Cached stage does not match current prompt/schema/model/input')

        if is_cached_match:
            self.replayed_stages.add(stage_key)
            self.replayed_names.add(stage)
            raw = json.loads((stage_dir / 'response.json').read_text())
            out_text = raw.get('output_text')
            if not out_text and (stage_dir / 'result.json').exists():
                out_text = json.dumps(json.loads((stage_dir / 'result.json').read_text()), ensure_ascii=False)
            if is_stream:
                return CachedStream(raw, out_text)
            return CachedResponse(raw, out_text)

        if not hasattr(self.underlying_client, 'responses') or not hasattr(self.underlying_client.responses, 'input_tokens') or not hasattr(self.underlying_client.responses.input_tokens, 'count'):
            raise NotImplementedError('Responses input_tokens.count unsupported by client')

        ceiling = 100_000
        count_key = f"{stage_key}:count"
        gen_key = f"{stage_key}:gen"

        count_reserve = (ceiling * self.rates[0]) / 1_000_000
        self.realism_budget.change(count_key, count_reserve, settle=False)

        t_count_0 = time.perf_counter()
        with request_errors(stage_dir, 'count'):
            count_res = self.underlying_client.responses.input_tokens.count(**copy.deepcopy(req_signature))
        preflight_latency = time.perf_counter() - t_count_0

        if hasattr(count_res, 'input_tokens'):
            counted_tokens = count_res.input_tokens
        elif isinstance(count_res, dict) and 'input_tokens' in count_res:
            counted_tokens = count_res['input_tokens']
        else:
            raise ValueError(f"Invalid count response: {count_res}")

        if not isinstance(counted_tokens, int) or isinstance(counted_tokens, bool) or counted_tokens < 0:
            raise ValueError(f"Input token count must be non-negative int, got: {type(counted_tokens).__name__} ({counted_tokens})")

        if counted_tokens > ceiling:
            raise ValueError(f"Input token count {counted_tokens} exceeds {ceiling} ceiling")

        count_cost = (counted_tokens * self.rates[0]) / 1_000_000
        self.realism_budget.change(count_key, count_cost, settle=True)
        atomic_json(stage_dir / 'preflight.json', {
            'hash': req_hash,
            'input_tokens': counted_tokens,
                'count_billing_confirmed': False,
            'latency_seconds': preflight_latency,
        })
        atomic_json(stage_dir / 'request_hash.json', {'request_hash': req_hash})

        max_out = kwargs.get('max_output_tokens', 1200 if stage == 'parts' else 2200)
        gen_reserve = (ceiling * self.rates[0] + max_out * self.rates[1]) / 1_000_000
        self.realism_budget.change(gen_key, gen_reserve, settle=False)

        if payload_sha256({k: kwargs[k] for k in req_signature}) != req_hash:
            raise ValueError('Create payload does not match preflight')
        with request_errors(stage_dir, 'generation'):
            response = self.underlying_responses.create(**kwargs)

        def settle(response):
            raw = response.model_dump(mode='json')
            usage = raw.get('usage') or {}
            inp, out = usage.get('input_tokens'), usage.get('output_tokens')
            if (type(inp) is int and type(out) is int and
                    0 <= inp <= ceiling and 0 <= out <= max_out):
                cost = (inp * self.rates[0] + out * self.rates[1]) / 1_000_000
                atomic_json(stage_dir / 'budget_response.json', raw)
                self.realism_budget.change(gen_key, cost, settle=True)

        if not is_stream:
            settle(response)
            return response

        class SettlingStream:
            def __iter__(self):
                terminal_seen = False
                with request_errors(stage_dir, 'generation'):
                    for event in response:
                        if event.type in ('response.completed', 'response.incomplete', 'response.failed'):
                            if not terminal_seen:
                                settle(event.response)
                                terminal_seen = True
                        yield event

            def close(self):
                response.close()

        return SettlingStream()


class CResumeClientWrapper:
    def __init__(self, underlying_client, destination, realism_budget, rates, resume=False):
        self.underlying_client = underlying_client
        self.destination = Path(destination)
        self.resume = resume
        self.responses = CResumeResponsesWrapper(underlying_client, destination, realism_budget, rates, resume=resume)

    @property
    def replayed_stages(self):
        return self.responses.replayed_stages

    @property
    def replayed_names(self):
        return self.responses.replayed_names

    def __getattr__(self, name):
        return getattr(self.underlying_client, name)


def run_c_adapter(client, model, source, truth, destination, device, budget, rates,
                  effort='minimal', max_side=768, seed=0, resume=False, process=None, sam=None):
    """Run variant C with counted preflight on both stages, shared budget, partial resume, and timings."""
    validate_model_effort(model, effort)
    if rates is None or len(rates) != 2 or any(not math.isfinite(r) or r <= 0 for r in rates):
        raise ValueError('Explicit conservative input/output USD per million required')
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / '.run.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        validate_adapter_config(destination, 'c', model, source, truth, device, budget, rates,
                                effort, max_side, seed)
        if resume and (destination / 'complete.json').exists() and (destination / 'plan.json').exists():
            return json.loads((destination / 'plan.json').read_text())

        orig_parts_metrics = None
        if (destination / 'parts_request/metrics.json').exists():
            try:
                orig_parts_metrics = json.loads((destination / 'parts_request/metrics.json').read_text())
            except Exception:
                pass
        orig_steps_metrics = None
        if (destination / 'steps_request/metrics.json').exists():
            try:
                orig_steps_metrics = json.loads((destination / 'steps_request/metrics.json').read_text())
            except Exception:
                pass

        budget_adapter = CBudgetAdapter(budget)
        wrapped_client = CResumeClientWrapper(client, destination, budget, rates, resume=resume)
        budget_adapter.wrapper = wrapped_client
        overrides = {model: rates}
        started = time.perf_counter()
        try:
            if process is not None:
                res = process(wrapped_client, model, source, truth, destination, device, effort, max_side,
                              'clean', seed, budget_adapter, overrides, sam=sam)
            else:
                from variant_c import process_c
                res = process_c(wrapped_client, model, source, truth, destination, device, effort, max_side,
                                'clean', seed, budget_adapter, overrides, sam=sam)
        finally:
            for stage, original in (('parts', orig_parts_metrics), ('steps', orig_steps_metrics)):
                if stage in wrapped_client.replayed_names:
                    path = destination / f'{stage}_request/metrics.json'
                    if original is not None:
                        atomic_json(path, original)
                    else:
                        atomic_json(path, {'seconds': None, 'time_to_first_step_seconds': None,
                                           'is_replay': True})
        plan = json.loads((destination / 'plan.json').read_text()) if (destination / 'plan.json').exists() else res

        partial_recovery = bool(wrapped_client.replayed_names)
        metrics = json.loads((destination / 'metrics.json').read_text()) if (destination / 'metrics.json').exists() else {}
        parts_metrics = json.loads((destination / 'parts_request/metrics.json').read_text()) if (destination / 'parts_request/metrics.json').exists() else {}
        steps_metrics = json.loads((destination / 'steps_request/metrics.json').read_text()) if (destination / 'steps_request/metrics.json').exists() else {}

        if 'parts' in wrapped_client.replayed_names and orig_parts_metrics:
            metrics['parts_seconds'] = orig_parts_metrics.get('seconds')
        if 'steps' in wrapped_client.replayed_names and orig_steps_metrics:
            metrics['steps_seconds'] = orig_steps_metrics.get('seconds')
            metrics['time_to_first_step_seconds'] = orig_steps_metrics.get('time_to_first_step_seconds')
        if partial_recovery:
            metrics['total_seconds'] = None
            metrics['partial_recovery'] = True
        atomic_json(destination / 'metrics.json', metrics)

        parts_seconds = metrics.get('parts_seconds') or parts_metrics.get('seconds')
        outline = metrics.get('time_to_first_outline_seconds')
        ttfs = metrics.get('time_to_first_step_seconds') or steps_metrics.get('time_to_first_step_seconds')
        ttfs_from_start = metrics.get('time_to_first_step_from_start_seconds')
        sam_seconds = metrics.get('sam_seconds')
        steps_seconds = metrics.get('steps_seconds') or steps_metrics.get('seconds')
        total_seconds = metrics.get('total_seconds')

        preflights = {}
        for stage in ('parts', 'steps'):
            path = destination / f'{stage}_request/preflight.json'
            preflights[stage] = json.loads(path.read_text()).get('latency_seconds', 0) if path.exists() else 0
        atomic_json(destination / 'latency.json', {
            'preflight_seconds': None if partial_recovery else sum(preflights.values()),
            'parts_preflight_seconds': preflights['parts'],
            'steps_preflight_seconds': preflights['steps'],
            'real_wall_time_to_first_box_seconds': None if partial_recovery else parts_seconds,
            'first_box_full_response_seconds': None if 'parts' in wrapped_client.replayed_names else parts_seconds,
            'first_box_model_only_seconds': None if partial_recovery or parts_seconds is None else max(0, parts_seconds - preflights['parts']),
            'time_to_parts_response_seconds': parts_seconds,
            'time_to_first_outline_seconds': None if partial_recovery else outline,
            'time_to_first_step_seconds': None if partial_recovery else ttfs,
            'time_to_first_step_from_start_seconds': None if partial_recovery else ttfs_from_start,
            'sam_seconds': None if 'parts' in wrapped_client.replayed_names else sam_seconds,
            'steps_seconds': steps_seconds,
            'total_seconds': None if partial_recovery else total_seconds,
            'adapter_wall_seconds': None if partial_recovery else (time.perf_counter() - started),
            'first_box_definition': 'C parts response; streaming steps; outline after SAM',
            'partial_recovery': partial_recovery,
            'is_replay': partial_recovery,
            'original_wall_total_available': not partial_recovery,
        })
        parts_cost = parts_metrics.get('estimated_usd')
        steps_cost = steps_metrics.get('estimated_usd')
        total_cost = None
        if parts_cost is not None or steps_cost is not None:
            total_cost = (parts_cost or 0) + (steps_cost or 0)
        count_allowance = 0
        for stage in ('parts', 'steps'):
            path = destination / f'{stage}_request/preflight.json'
            if path.exists():
                count_allowance += json.loads(path.read_text())['input_tokens'] * rates[0] / 1_000_000
        atomic_json(destination / 'budget_cost.json', {
            'count_allowance_usd': count_allowance,
            'count_billing_confirmed': False,
            'parts_usd_estimate': parts_cost,
            'steps_usd_estimate': steps_cost,
            'usd_upper_estimate': total_cost + count_allowance if total_cost is not None else None,
            'rates': rates,
        })
        return plan
