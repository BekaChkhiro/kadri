"""Offline point-decoder quality gate: deepest interior point of each SAM2 mask.

Points are chosen before inference, without tuning against model output. Writes
all results, including failures; argmax predicted IoU selects the output mask.
"""
import json
import time
from pathlib import Path
import coremltools as ct
import numpy as np
import torch
from candidates import load
from convert_sam_point import PointDecoder
from PIL import Image
from scipy.ndimage import distance_transform_edt
from sam_common import prepare_image, restore_masks, mask_iou


def main():
    root = Path(__file__).resolve().parents[1]
    fixture = root / 'KadriTests/Fixtures/sink'
    image = Image.open(fixture / 'input.png').convert('RGB')
    encoder = ct.models.MLModel(str(root / 'Models/SAMEncoder.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
    decoder = ct.models.MLModel(str(root / 'Models/SAMDecoderPoint.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
    start = time.perf_counter()
    embedding = encoder.predict({'image': prepare_image(image, square=True)})['embedding']
    torch.set_num_threads(4)
    _, box_decoder = load('efficientsam')
    torch_decoder = PointDecoder(box_decoder).eval()
    report = {'compute_units': 'CPU_ONLY', 'point_selection': 'SAM2 maximum interior Euclidean distance, row-major tie break',
              'embed_ms': (time.perf_counter() - start) * 1000, 'parts': []}
    for i in range(1, 6):
        reference = np.asarray(Image.open(fixture / f'sam2_p{i}.png')) > 127
        y, x = np.unravel_index(distance_transform_edt(reference).argmax(), reference.shape)
        points = np.array([[[x * 1024 / image.width, y * 1024 / image.height], [-1, -1]]], np.float32)
        start = time.perf_counter()
        result = decoder.predict({'embedding': embedding, 'points': points, 'labels': np.array([[1, -1]], np.float32)})
        decode_ms = (time.perf_counter() - start) * 1000
        assert result['mask_logits'].shape == (1, 3, 256, 256)
        assert result['iou_scores'].shape == (1, 3)
        with torch.inference_mode():
            torch_logits, torch_scores = torch_decoder(torch.from_numpy(embedding.copy()), torch.from_numpy(points), torch.tensor([[1., -1.]]))
        torch_mask = restore_masks(torch_logits.numpy(), image.size, square=True)[torch_scores.argmax().item()]
        masks = restore_masks(result['mask_logits'], image.size, square=True)
        selected = int(result['iou_scores'].argmax())
        Image.fromarray(masks[selected].astype(np.uint8) * 255).save(fixture / f'point_coreml_p{i}.png')
        row = {'id': f'p{i}', 'point': [int(x), int(y)], 'selected': selected,
               'scores': result['iou_scores'].flatten().tolist(), 'iou_sam2': mask_iou(masks[selected], reference),
               'iou_pytorch_same_embedding': mask_iou(masks[selected], torch_mask),
               'all_candidate_iou_sam2': [mask_iou(m, reference) for m in masks], 'decode_ms': decode_ms}
        report['parts'].append(row)
        print(json.dumps(row), flush=True)
    (fixture / 'point_results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS' if all(p['iou_sam2'] >= .7 for p in report['parts']) else 'FAIL: SAM2 IoU < 0.7', flush=True)


if __name__ == '__main__':
    main()
