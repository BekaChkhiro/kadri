"""Offline preparation and opt-in B/C realism runs; never called by dry-run."""
import argparse
import hashlib
import json
import os
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

from realism import (KINDS, Budget, atomic_json, confidence_sweep, degrade,
                     mask_truth, percentiles, run_b_adapter, run_c_adapter)
from segmentation import HERE, ROOT, SCENES


def load(path):
    return json.loads(Path(path).read_text())


def prepare(source, truth, destination, kind, seed, real=False):
    from evaluation import truth_masks
    image = ImageOps.exif_transpose(Image.open(source)).convert('RGB')
    refs = (np.zeros((len(truth['parts']), image.height, image.width), bool) if real
            else truth_masks(truth, image.size))
    changed, full, visible, metadata = degrade(image, refs, kind, seed)
    metadata.update({'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                     'truth_sha256': hashlib.sha256(json.dumps(truth,sort_keys=True).encode()).hexdigest(),
                     'real_photo': real, 'proxy_available': not real})
    destination.mkdir(parents=True, exist_ok=True)
    existing = destination/'transform.json'
    if existing.exists():
        if load(existing) != json.loads(json.dumps(metadata)):
            raise ValueError('Prepared frame inputs changed; choose another output directory')
    else:
        changed.save(destination/'image.png')
        np.savez_compressed(destination/'truth_masks.npz', full=full, visible=visible)
        atomic_json(destination/'truth.json', mask_truth(truth, visible, image.size))
        atomic_json(existing, metadata)
    return metadata


def proxy_evaluation(destination, plan, truth):
    from evaluation import iou
    with np.load(destination/'masks.npz') as data:
        predicted = data['masks']
    with np.load(destination.parent/'truth_masks.npz') as data:
        references = {k: data[k] for k in ('full','visible')}
    target_shape = references['full'].shape[1:]
    if predicted.shape[1:] != target_shape:
        h_t, w_t = target_shape
        resized = []
        for m in predicted:
            rm = cv2.resize(m.astype(np.uint8), (w_t, h_t), interpolation=cv2.INTER_NEAREST).astype(bool)
            resized.append(rm)
        predicted = np.array(resized, dtype=bool) if len(resized) > 0 else np.zeros((0, h_t, w_t), bool)
    parts_list = plan.get('parts', [])
    if isinstance(parts_list, dict):
        parts_list = [{'id': k, 'label': v} for k, v in parts_list.items()]
    by_id = {p['id']: m for p, m in zip(parts_list, predicted)}
    result = {'metric': 'Design geometry proxy only; NOT real semantic validation', 'steps': []}
    for step, expected in zip(plan.get('steps', []), truth['steps']):
        row = {}
        for field in ('focus','avoid'):
            actual = np.zeros(target_shape, bool)
            for pid in step.get(field, []):
                if pid in by_id:
                    actual |= by_id[pid]
            for name, masks in references.items():
                target = np.zeros_like(actual)
                for index in expected.get(field, []):
                    if index < len(masks):
                        target |= masks[index]
                row[f'{field}_{name}_iou'] = iou(actual,target)
        result['steps'].append(row)
    atomic_json(destination/'proxy.json', result)


def summarize(out):
    api, sam, comparisons = [], [], []
    preflights, real_wall_boxes, outlines, steps_latencies = [], [], [], []
    for latency in sorted(out.glob('*/*/*/run_*/latency.json')):
        row = load(latency)
        if row.get('is_replay') or row.get('partial_recovery'):
            continue
        if row.get('first_box_full_response_seconds') is not None:
            api.append(row['first_box_full_response_seconds'])
        if row.get('sam_seconds') is not None:
            sam.append(row['sam_seconds'])
        if row.get('preflight_seconds') is not None:
            preflights.append(row['preflight_seconds'])
        if row.get('real_wall_time_to_first_box_seconds') is not None:
            real_wall_boxes.append(row['real_wall_time_to_first_box_seconds'])
        if row.get('time_to_first_outline_seconds') is not None:
            outlines.append(row['time_to_first_outline_seconds'])
        if row.get('time_to_first_step_seconds') is not None:
            steps_latencies.append(row['time_to_first_step_seconds'])
    for baseline in sorted(out.glob('*/*/original/run_*/plan.json')):
        source_meta = load(baseline.parent.parent/'transform.json')
        previous = load(baseline)['parts']
        for current in sorted(baseline.parent.parent.parent.glob(f'*/{baseline.parent.name}/plan.json')):
            if current == baseline:
                continue
            meta = load(current.parent.parent/'transform.json')
            comparisons.append({'baseline': str(baseline.relative_to(out)), 'current': str(current.relative_to(out)),
                                **confidence_sweep(previous,load(current)['parts'],source_meta,meta)})
    summary = {
        'first_box_full_response_seconds': percentiles(api),
        'sam_seconds': percentiles(sam),
        'preflight_seconds': percentiles(preflights),
        'real_wall_time_to_first_box_seconds': percentiles(real_wall_boxes),
        'time_to_first_outline_seconds': percentiles(outlines),
        'time_to_first_step_seconds': percentiles(steps_latencies),
        'comparisons': comparisons,
        'realism_claim': 'Synthetic stress is not real-photo validation'
    }
    atomic_json(out/'summary.json', summary)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', choices=['b', 'c'], default='b', help='Model variant pipeline: b or c')
    parser.add_argument('--effort', choices=['minimal', 'low', 'high'], default='high', help='Reasoning effort')
    parser.add_argument('--max-side', type=int, default=768, help='Max thumbnail side for variant c')
    parser.add_argument('--scenes', nargs='+', choices=list(SCENES), default=list(SCENES))
    parser.add_argument('--kinds', nargs='+', choices=KINDS, default=list(KINDS))
    parser.add_argument('--real', type=Path, help='Directory containing <scene>/*.jpg; no design geometry is assumed')
    parser.add_argument('--out', type=Path, default=HERE/'out_realism')
    parser.add_argument('--runs', type=int, default=1)
    parser.add_argument('--seed', type=int, default=20261017)
    parser.add_argument('--dry-run', action='store_true', help='Prepare pixels/masks/manifests, no client or SAM')
    parser.add_argument('--offline-summary', action='store_true', help='Recompute matching sweep and latency from disk')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--model', default='gpt-6-astra')
    parser.add_argument('--device', choices=['cpu','mps'], default='cpu')
    parser.add_argument('--budget', type=float, default=13)
    parser.add_argument('--ledger', type=Path, help='Shared campaign ledger for paid runs')
    parser.add_argument('--input-rate', type=float, help='Explicit conservative USD/M input tokens, including long context/cache-write')
    parser.add_argument('--output-rate', type=float, help='Explicit conservative USD/M output tokens')
    args = parser.parse_args(argv)
    if args.runs < 1:
        parser.error('--runs must be positive')
    if not 32 <= args.max_side <= 2048:
        parser.error('--max-side must be in [32, 2048]')
    if args.budget <= 0 or args.budget > 13:
        parser.error('Budget must be in (0,13]')
    if args.offline_summary:
        summarize(args.out)
        return 0
    ledger_path = args.ledger or (HERE/'out_realism'/'budget.json')
    if not args.dry_run and (args.input_rate is None or args.output_rate is None):
        parser.error('Paid runs require explicit --input-rate/--output-rate; unknown prices forbidden')
    budget = Budget(ledger_path, args.budget)
    rates = (args.input_rate, args.output_rate)
    if not args.dry_run:
        import math
        if any(not math.isfinite(r) or r <= 0 for r in rates):
            parser.error('Rates must be finite and positive')
        from dotenv import load_dotenv
        load_dotenv(HERE/'.env')
        if not os.getenv('OPENAI_API_KEY','').strip():
            print('OPENAI_API_KEY არ არის; API არ გაშვებულა.')
            return 2
        from openai import OpenAI
        client = OpenAI(max_retries=0, timeout=180)
    failed = False
    for scene in args.scenes:
        truth = load(HERE/'out'/scene/'ground_truth.json')
        sources = sorted((args.real/scene).glob('*.jpg')) if args.real else [ROOT/'Camera/assets'/SCENES[scene][0]]
        if not sources:
            print(f'{scene}: real/<scene>/*.jpg არ მოიძებნა')
            failed = True
        for source in sources:
            # Real photos use scene instructions only: design coordinates are invalid.
            if args.real:
                truth = {**truth, 'parts': [{'name':'UNANNOTATED','path':''}],
                         'steps': [{**s,'focus':[],'avoid':[]} for s in truth['steps']]}
            for kind in args.kinds:
                frame = args.out/scene/source.stem/kind
                try:
                    prepare(source,truth,frame,kind,args.seed,bool(args.real))
                    frame_hash = hashlib.sha256((frame/'image.png').read_bytes()).hexdigest()
                    for n in range(1,args.runs+1):
                        dest = frame/f'run_{n}'
                        config = {
                            'variant': args.variant,
                            'model': args.model,
                            'device': args.device,
                            'rates': list(rates) if rates[0] is not None else None,
                            'ledger': str(ledger_path.resolve()),
                            'effort': args.effort,
                            'reasoning_effort': args.effort,
                            'max_side': args.max_side,
                            'hash': frame_hash,
                            'truth_hash': hashlib.sha256((frame/'truth.json').read_bytes()).hexdigest(),
                            'seed': args.seed,
                        }
                        if args.dry_run:
                            continue
                        if (dest/'runner_config.json').exists():
                            old_cfg = load(dest/'runner_config.json')
                            if old_cfg != config:
                                raise ValueError('Resume configuration mismatch')
                            if not args.resume:
                                raise ValueError('Existing run requires --resume')
                        elif (dest/'complete.json').exists() or (dest/'plan.json').exists():
                            raise ValueError('Existing results lack runner configuration')
                        atomic_json(dest/'runner_config.json', config)
                        if args.variant == 'c':
                            plan = run_c_adapter(
                                client, args.model, frame/'image.png', load(frame/'truth.json'),
                                dest, args.device, budget, rates, effort=args.effort,
                                max_side=args.max_side, seed=args.seed, resume=args.resume
                            )
                        else:
                            os.environ['REASONING_EFFORT'] = args.effort
                            plan = run_b_adapter(
                                client, args.model, frame/'image.png', load(frame/'truth.json'),
                                dest, args.device, budget, rates
                            )
                        if not args.real:
                            proxy_evaluation(dest, plan, truth)
                        else:
                            atomic_json(dest/'proxy.json', {'available': False, 'reason': 'Real photo has no verified masks'})
                        atomic_json(dest/'complete.json', {'complete': True})
                except Exception as exc:
                    failed = True
                    print(f'{scene}/{source.stem}/{kind}: {type(exc).__name__}')
    summarize(args.out)
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
