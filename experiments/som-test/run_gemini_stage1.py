"""Opt-in Gemini pilot/matrix; offline paired geometry report. Never runs stage 2."""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from dotenv import load_dotenv

from evaluation import iou
from gemini_stage1 import MODELS, request_parts, render_stage1
from prepare_gemini import load
from realism import Budget, atomic_json, match_frames, percentiles
from segmentation import HERE


def destination(out, mode, model, frame):
    return out / mode / model / frame['key']


def geometry_proxy(masks, frame):
    baseline = HERE / frame['baseline']
    truth = load(baseline.parent / 'truth.json')
    with np.load(baseline.parent / 'truth_masks.npz') as data:
        refs = data['visible']
    h, w = refs.shape[1:]
    resized = [cv2.resize(m.astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST).astype(bool) for m in masks]
    rows = []
    for ref, part in zip(refs, truth['parts']):
        values = [iou(ref, m) for m in resized] if ref.any() else []
        best = int(np.argmax(values)) if values else None
        rows.append({'name': part['name'], 'visible_pixels': int(ref.sum()),
                     'best_iou': values[best] if best is not None else (0.0 if ref.any() else None),
                     'best_id': f'p{best+1}' if best is not None else None})
    return rows


def compare(out, mode, model, frame):
    dest = destination(out, mode, model, frame)
    parts = load(dest / 'parts.json')['parts']
    baseline = HERE / frame['baseline']
    previous = load(baseline / 'parts.json')['parts']
    meta = load(baseline.parent / 'transform.json')
    with np.load(dest / 'masks.npz') as data:
        proxy = geometry_proxy(data['masks'], frame)
    with np.load(baseline / 'masks.npz') as data:
        astra_proxy = geometry_proxy(data['masks'], frame)
    row = {'frame': frame['key'], 'labels': [p['label'] for p in parts],
           'match': match_frames(previous, parts, meta, meta, .5),
           'proxy': proxy, 'astra_proxy': astra_proxy,
           'astra_latency': load(baseline / 'latency.json'),
           'gemini_latency': load(dest / 'latency.json'), 'astra_part_count': len(previous)}
    atomic_json(dest / 'comparison.json', row)
    return row


def summarize(out, mode, models, frames):
    report = {}
    for model in models:
        rows = [compare(out, mode, model, frame) for frame in frames
                if (destination(out, mode, model, frame) / 'parts.png').exists()]
        # match_frames matches have per-frame counts derived from labels/parts above.
        matched = sum(len(r['match']['matches']) for r in rows)
        astra_n = sum(r['astra_part_count'] for r in rows)
        gemini_n = sum(len(r['labels']) for r in rows)
        report[model] = {'n': len(rows), 'first_box': percentiles([r['gemini_latency']['first_box_full_response_seconds'] for r in rows]),
            'under_5s': sum(0 < (r['gemini_latency']['first_box_full_response_seconds'] or 1e9) <= 5 for r in rows),
            'astra_historical_first_box': percentiles([r['astra_latency']['real_wall_time_to_first_box_seconds'] for r in rows]),
            'parts': gemini_n, 'astra_parts': astra_n, 'matched': matched,
            'matched_fraction_astra': matched/astra_n if astra_n else None,
            'matched_fraction_gemini': matched/gemini_n if gemini_n else None,
            'proxy_mean_best_iou': float(np.mean([p['best_iou'] for r in rows for p in r['proxy'] if p['best_iou'] is not None])) if rows else None,
            'astra_proxy_mean_best_iou': float(np.mean([p['best_iou'] for r in rows for p in r['astra_proxy'] if p['best_iou'] is not None])) if rows else None,
            'usd': sum(r['gemini_latency']['usd'] for r in rows), 'rows': rows}
    atomic_json(out / f'{mode}_summary.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['pilot', 'matrix'])
    parser.add_argument('--models', nargs='+', choices=list(MODELS), required=True)
    parser.add_argument('--out', type=Path, default=HERE / 'out_gemini')
    parser.add_argument('--run', action='store_true', help='Explicitly send Gemini API requests')
    parser.add_argument('--summary', action='store_true', help='Offline only')
    parser.add_argument('--device', default='mps', choices=['mps', 'cpu'])
    args = parser.parse_args()
    frames = load(args.out / 'frames.json')
    if args.mode == 'pilot':
        frames = [f for f in frames if f['scene'] == 'sink' and f['kind'] == 'original']
    if args.summary:
        report = summarize(args.out, args.mode, args.models, frames)
        print(json.dumps({m:{k:v for k,v in r.items() if k != 'rows'} for m,r in report.items()}, indent=2))
        return
    if not args.run:
        parser.error('Use --run for paid requests or --summary for offline analysis')
    load_dotenv(HERE / '.env')
    budget = Budget(args.out / 'budget.json', limit=5)
    for model in args.models:
        for frame in frames:
            dest = destination(args.out, args.mode, model, frame)
            if (dest / 'parts.png').exists():
                continue  # Saved results never count as new latency observations.
            baseline = HERE / frame['baseline']
            instructions = [{'title': s['title'], 'text': s['text']} for s in load(baseline.parent / 'truth.json')['steps']]
            if (dest / 'result.json').exists():
                result, metrics = load(dest / 'result.json'), load(dest / 'latency.json')
            else:
                result, metrics = request_parts(model, HERE / frame['input'], instructions, dest, budget)
            render_stage1(HERE / frame['input'], result, dest, args.device)
            print(f'{model} {frame["key"]}: {metrics["response_seconds"]:.3f}s, {metrics["part_count"]} parts, ${metrics["usd"]:.6f}', flush=True)
    summarize(args.out, args.mode, args.models, frames)


if __name__ == '__main__':
    main()
