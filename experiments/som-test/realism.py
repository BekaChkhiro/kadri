"""Deterministic pixel stress tests and conservative, crash-safe B adapter."""
import copy
import fcntl
import hashlib
import io
import json
import math
import os
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


def percentiles(values):
    values = [float(v) for v in values if v is not None]
    return {'n': len(values), 'p50': float(np.percentile(values,50)) if values else None,
            'p90': float(np.percentile(values,90)) if values else None}


class Budget:
    """Shared ledger; uncertain requests retain the entire reservation indefinitely."""
    def __init__(self, path, limit=15):
        if not math.isfinite(limit) or not 0 < limit <= 15:
            raise ValueError('Budget must be in (0,15]')
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


def run_b_adapter(client, model, source, truth, destination, device, budget, rates, process=None):
    """Reserve before the single Responses call; cached B plans need no new charge."""
    from types import SimpleNamespace
    from variant_b import process_run
    if rates is None or len(rates) != 2 or any(not math.isfinite(r) or r <= 0 for r in rates):
        raise ValueError('Explicit conservative input/output USD per million required')
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    # Whole-call lock also prevents concurrent SAM/resume writes to the same run.
    with (destination / '.run.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        def create(**kwargs):
            # Conservative input ceiling: bill at the declared all-context rate for
            # the entire model input context, irrespective of cache discounts.
            bound = 1_000_000
            reservation = (bound * rates[0] + kwargs['max_output_tokens'] * rates[1]) / 1_000_000
            key = hashlib.sha256(str(destination.resolve()).encode()).hexdigest()
            budget.change(key, reservation)
            response = client.responses.create(**kwargs)
            raw = response.model_dump(mode='json')
            usage = raw.get('usage') or {}
            inputs, outputs = usage.get('input_tokens'), usage.get('output_tokens')
            if isinstance(inputs, int) and isinstance(outputs, int) and 0 <= inputs <= bound and 0 <= outputs <= kwargs['max_output_tokens']:
                actual = (inputs * rates[0] + outputs * rates[1]) / 1_000_000
                # Save response before settlement; B may subsequently fail parsing.
                atomic_json(destination / 'budget_response.json', raw)
                budget.change(key, actual, settle=True)
                atomic_json(destination / 'budget_cost.json', {'usd_upper_estimate': actual, 'rates': rates})
            return response
        wrapped = SimpleNamespace(responses=SimpleNamespace(create=create))
        started = time.perf_counter()
        plan = (process or process_run)(wrapped, model, source, truth, destination, device)
        api = json.loads((destination/'metrics.json').read_text()) if (destination/'metrics.json').exists() else {}
        sam = json.loads((destination/'segmentation.json').read_text()) if (destination/'segmentation.json').exists() else {}
        atomic_json(destination/'latency.json', {'first_box_full_response_seconds': api.get('seconds'),
                    'sam_seconds': sam.get('seconds'), 'adapter_wall_seconds': time.perf_counter()-started,
                    'first_box_definition': 'B full response; no streaming; excludes SAM'})
        return plan
