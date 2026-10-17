"""Mac Core ML benchmark: warm medians, SAM2 IoU, PyTorch parity, compute plans."""
import argparse
from collections import Counter
import json
import platform
import statistics
import subprocess
import time
from pathlib import Path
import coremltools as ct
import numpy as np
import torch
from PIL import Image
from coremltools.models.compute_plan import MLComputePlan
from candidates import load
from sam_common import HERE, cases, prepare_image, prompt_box, restore_masks, mask_iou


def timed(model, inputs, runs):
    # Two warmups per image/box. Compilation and first prediction excluded.
    model.predict(inputs)
    model.predict(inputs)
    values = []
    for _ in range(runs):
        start = time.perf_counter_ns()
        output = model.predict(inputs)
        values.append((time.perf_counter_ns() - start) / 1e6)
    return output, {'median_ms': statistics.median(values), 'samples_ms': values}


def compute_plan(model, units):
    plan = MLComputePlan.load_from_path(model.get_compiled_model_path(), compute_units=units)
    rows = []
    def block_ops(block):
        for op in block.operations:
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
            cost = plan.get_estimated_cost_for_mlprogram_operation(op)
            rows.append({'op': op.operator_name,
                         'preferred': type(usage.preferred_compute_device).__name__ if usage else None,
                         'supported': [type(d).__name__ for d in usage.supported_compute_devices] if usage else [],
                         'estimated_cost': cost.weight if cost else None})
            for inner in op.blocks:
                block_ops(inner)
    for function in plan.model_structure.program.functions.values():
        block_ops(function.block)
    return {'preferred_counts': dict(Counter(r['preferred'] for r in rows)), 'operations': rows}


def bench(model_dir, runs, output):
    info = json.loads((model_dir / 'conversion.json').read_text())
    name = info['candidate']
    square = name == 'efficientsam'
    torch.set_num_threads(4)
    encoder_pt, decoder_pt = load(name)
    data = list(cases())
    pt = {}
    with torch.inference_mode():
        for scene, image, parts, reference, provenance in data:
            embedding = encoder_pt(torch.from_numpy(prepare_image(image, square=square)))
            for part in parts:
                box = torch.from_numpy(prompt_box(part['box'], image.size, square=square))
                logits, scores = decoder_pt(embedding, box)
                pt[(scene, part['id'])] = (logits.numpy(), scores.numpy())
    result = {'candidate': name, 'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
              'macos': platform.mac_ver()[0], 'coremltools': ct.__version__, 'torch': torch.__version__,
              'runs': runs, 'warmups': 2, 'conversion': info, 'modes': {}}
    for units in [ct.ComputeUnit.ALL, ct.ComputeUnit.CPU_AND_NE]:
        print(f'Loading {name} {units.name}', flush=True)
        encoder = ct.models.MLModel(str(model_dir / 'SAMEncoder.mlpackage'), compute_units=units)
        decoder = ct.models.MLModel(str(model_dir / 'SAMDecoder.mlpackage'), compute_units=units)
        mode = {'scenes': {}, 'parts': [], 'compute_plan': {}}
        for title, model in [('encoder', encoder), ('decoder', decoder)]:
            try:
                mode['compute_plan'][title] = compute_plan(model, units)
            except Exception as error:
                mode['compute_plan'][title] = {'error': f'{type(error).__name__}: {error}'}
        for scene, image, parts, reference, provenance in data:
            encoded, timing = timed(encoder, {'image': prepare_image(image, square=square)}, runs)
            mode['scenes'][scene] = {**provenance, 'encoder': timing}
            for part, truth in zip(parts, reference):
                box = prompt_box(part['box'], image.size, square=square)
                predicted, timing = timed(decoder, {'embedding': encoded['embedding'], 'box': box}, runs)
                logits, scores = predicted['mask_logits'], predicted['iou_scores']
                if not np.isfinite(logits).all() or not np.isfinite(scores).all():
                    raise ValueError('Nonfinite Core ML prediction')
                masks = restore_masks(logits, image.size, square=square)
                index = int(scores.flatten().argmax())
                ious = [mask_iou(m, truth) for m in masks]
                pt_logits, pt_scores = pt[(scene, part['id'])]
                pt_masks = restore_masks(pt_logits, image.size, square=square)
                pt_index = int(pt_scores.flatten().argmax())
                row = {'scene': scene, 'id': part['id'], 'label': part['label'], 'iou': ious[index],
                       'all_ious': ious, 'oracle_iou': max(ious), 'selected': index,
                       'scores': scores.flatten().tolist(), 'decoder': timing,
                       'pytorch_mask_iou': mask_iou(masks[index], pt_masks[pt_index]),
                       'max_logit_abs_error': float(np.max(np.abs(logits - pt_logits))),
                       'max_score_abs_error': float(np.max(np.abs(scores - pt_scores)))}
                mode['parts'].append(row)
                print(f"{name:12} {units.name:10} {scene:4} {part['id']:3} IoU={ious[index]:.4f} enc={mode['scenes'][scene]['encoder']['median_ms']:.2f}ms dec={timing['median_ms']:.2f}ms", flush=True)
                # Cyan = agreement, red = predicted-only, yellow = reference-only.
                pixels = np.array(image)
                a, b = masks[index], truth
                overlay = pixels.copy()
                overlay[a & b] = [0, 220, 220]
                overlay[a & ~b] = [255, 0, 0]
                overlay[b & ~a] = [255, 220, 0]
                pixels = (pixels * 0.45 + overlay * 0.55).astype(np.uint8)
                review = HERE / 'out/review' / name / units.name
                review.mkdir(parents=True, exist_ok=True)
                Image.fromarray(pixels).save(review / f"{scene}_{part['id']}.png")
        mode['mean_iou'] = float(np.mean([r['iou'] for r in mode['parts']]))
        mode['scene_mean_iou'] = {s: float(np.mean([r['iou'] for r in mode['parts'] if r['scene'] == s])) for s in mode['scenes']}
        mode['quality_gate'] = {
            'scene_means_at_least_0_8': all(v >= 0.8 for v in mode['scene_mean_iou'].values()),
            'all_parts_at_least_0_8': all(r['iou'] >= 0.8 for r in mode['parts']),
            'failing_parts': [f"{r['scene']}/{r['id']}" for r in mode['parts'] if r['iou'] < 0.8],
            'iphone_latency_verified': False,
        }
        mode['encoder_median_ms'] = statistics.median(v for s in mode['scenes'].values() for v in s['encoder']['samples_ms'])
        mode['decoder_median_ms'] = statistics.median(v for r in mode['parts'] for v in r['decoder']['samples_ms'])
        result['modes'][units.name] = mode
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print('| Mode | Mean IoU | Encoder median ms | Decoder median ms |')
    print('|---|---:|---:|---:|')
    for mode, row in result['modes'].items():
        print(f"| {mode} | {row['mean_iou']:.4f} | {row['encoder_median_ms']:.2f} | {row['decoder_median_ms']:.2f} |")
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models', type=Path, default=HERE.parent / 'Models')
    parser.add_argument('--runs', type=int, default=10)
    parser.add_argument('--output', type=Path, default=HERE / 'out/bench.json')
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be positive')
    bench(args.models, args.runs, args.output)
