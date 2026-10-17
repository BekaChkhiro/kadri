"""Offline paired hybrid analysis; design geometry is a proxy, not semantic truth."""
import json
import cv2
import numpy as np
from evaluation import iou
from prepare_gemini import load
from realism import atomic_json, percentiles, match_frames
from segmentation import HERE

FIELDS = {'first_box': 'real_wall_time_to_first_box_seconds', 'outline': 'time_to_first_outline_seconds',
          'first_step': 'time_to_first_step_from_start_seconds', 'total': 'total_seconds'}


def evaluate_run(run, truth_dir):
    plan = load(run / 'plan.json')
    truth = load(truth_dir / 'truth.json')
    with np.load(truth_dir / 'truth_masks.npz') as data:
        refs = data['visible']
    with np.load(run / 'masks.npz') as data:
        masks = data['masks']
    h, w = refs.shape[1:]
    masks = [cv2.resize(m.astype(np.uint8), (w,h), interpolation=cv2.INTER_NEAREST).astype(bool) for m in masks]
    rows = []
    for step, expected in zip(plan['steps'], truth['steps']):
        row = {'empty_focus': not step['focus']}
        for field in ('focus', 'avoid'):
            actual, ref = np.zeros((h,w), bool), np.zeros((h,w), bool)
            for pid in step[field]: actual |= masks[int(pid[1:])-1]
            for idx in expected.get(field, []): ref |= refs[idx]
            row[field + '_iou'] = iou(actual, ref)
        rows.append(row)
    return rows


def main():
    out = HERE / 'out_hybrid'
    rows = []
    for frame in load(out/'frames.json'):
        run = out/'runs'/frame['key']
        if not (run/'latency.json').exists(): continue
        baseline = HERE/frame['baseline']
        transform = load(baseline.parent/'transform.json')
        rows.append({'frame': frame['key'], 'scene': frame['scene'], 'kind': frame['kind'],
            'hybrid': load(run/'latency.json'), 'astra': load(baseline/'latency.json'),
            'hybrid_quality': evaluate_run(run, baseline.parent),
            'astra_quality': evaluate_run(baseline, baseline.parent),
            'id_match': match_frames(load(baseline/'parts.json')['parts'], load(run/'parts.json')['parts'], transform, transform, .5)})
    report = {'n': len(rows), 'rows': rows}
    for name in ('hybrid','astra'):
        report[name] = {key: percentiles([r[name][field] for r in rows]) for key,field in FIELDS.items()}
        steps = [s for r in rows for s in r[name+'_quality']]
        report[name].update(steps=len(steps), empty_focus=sum(s['empty_focus'] for s in steps),
            focus_iou=float(np.mean([s['focus_iou'] for s in steps])) if steps else None,
            avoid_iou=float(np.mean([s['avoid_iou'] for s in steps])) if steps else None)
    ledger = load(out/'budget.json')
    report['cost'] = {p: sum(v['usd'] for k,v in ledger['requests'].items() if k.startswith(p+':')) for p in ('gemini','openai')}
    report['unsettled'] = sum(v['state'] != 'settled' for v in ledger['requests'].values())
    atomic_json(out/'summary.json', report)
    print(json.dumps({k:v for k,v in report.items() if k != 'rows'}, indent=2))


if __name__ == '__main__': main()
