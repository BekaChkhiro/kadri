"""Free local CPU evaluation of all candidates against saved SAM2 box masks."""
import argparse
import json
import time
import numpy as np
import torch
from fvcore.nn import FlopCountAnalysis
from candidates import CANDIDATES, load
from sam_common import HERE, cases, prepare_image, prompt_box, restore_masks, mask_iou


def run(name):
    torch.set_num_threads(4)
    encoder, decoder = load(name)
    square = name == 'efficientsam'
    result = {'candidate': name, 'source': CANDIDATES[name], 'scenes': {}, 'parts': []}
    with torch.inference_mode():
        for scene, image, parts, reference, provenance in cases():
            x = torch.from_numpy(prepare_image(image, square=square))
            start = time.perf_counter()
            emb = encoder(x)
            elapsed = (time.perf_counter() - start) * 1000
            result['scenes'][scene] = {**provenance, 'encoder_cpu_cold_ms': elapsed}
            for part, truth in zip(parts, reference):
                box = torch.from_numpy(prompt_box(part['box'], image.size, square=square))
                logits, scores = decoder(emb, box)
                masks = restore_masks(logits.numpy(), image.size, square=square)
                ious = [mask_iou(m, truth) for m in masks]
                index = int(scores.flatten().argmax())
                row = {'scene': scene, 'id': part['id'], 'label': part['label'],
                       'ious': ious, 'scores': scores.flatten().tolist(), 'selected': index,
                       'iou': ious[index], 'oracle_iou': max(ious), 'token0_iou': ious[0]}
                result['parts'].append(row)
                print(f"{name:12} {scene:4} {part['id']:3} score-selected={ious[index]:.4f} oracle={max(ious):.4f}", flush=True)
        result['mean_iou'] = float(np.mean([p['iou'] for p in result['parts']]))
        result['oracle_mean_iou'] = float(np.mean([p['oracle_iou'] for p in result['parts']]))
        result['parameters'] = {}
        result['flops'] = {}
        for label, model, inputs in [('encoder', encoder, (x,)), ('decoder', decoder, (emb, box))]:
            result['parameters'][label] = sum(p.numel() for p in model.parameters())
            count = FlopCountAnalysis(model, inputs).unsupported_ops_warnings(False).uncalled_modules_warnings(False)
            result['flops'][label] = {'macs': count.total(), 'unsupported_ops': dict(count.unsupported_ops()),
                                      'convention': 'fvcore: one fused multiply-add = one FLOP; unsupported ops excluded'}
    return result


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--candidate', choices=[*CANDIDATES, 'all'], default='all')
    args = p.parse_args()
    out = HERE / 'out'; out.mkdir(exist_ok=True)
    for name in CANDIDATES if args.candidate == 'all' else [args.candidate]:
        result = run(name)
        (out / f'{name}_pytorch.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(f"{name}: mean IoU {result['mean_iou']:.4f}", flush=True)
