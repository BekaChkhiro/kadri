"""Regenerate Swift parity fixtures from the Python Core ML reference.

Run from the repo root with the ios/Tools environment:
  uv run --project ios/Tools python ios/KadriTests/Fixtures/make_fixtures.py

Writes, per scene: input.png (copied), boxes.json, coreml_<id>.png (Python Core ML
CPU_ONLY mask, the closest match to the simulator) and sam2_<id>.png (reference
from masks.npz). Masks are 0/255 grayscale at the original W×H. interp.json holds
small PyTorch bilinear/bicubic cases for the Swift resampling unit tests.
"""
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'ios/Tools'))

import coremltools as ct  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from PIL import Image  # noqa: E402

from sam_common import box_pixels, cases, mask_iou, prepare_image, prompt_box, restore_masks  # noqa: E402

MODELS = ROOT / 'ios/Models'


def save_mask(mask, path):
    Image.fromarray(np.where(mask, 255, 0).astype(np.uint8)).save(path, optimize=True)


def predict(encoder, decoder, image, parts):
    embedding = encoder.predict({'image': prepare_image(image, square=True)})['embedding']
    for part in parts:
        box = prompt_box(part['box'], image.size, square=True)
        out = decoder.predict({'embedding': embedding, 'box': box})
        scores = out['iou_scores'].flatten()
        index = int(scores.argmax())
        mask = restore_masks(out['mask_logits'], image.size, square=True)[index]
        yield box, scores, index, mask


def interp_cases():
    rng = np.random.default_rng(7)
    rows = []
    for mode, (sh, sw), (dh, dw) in [('bilinear', (3, 5), (7, 8)), ('bilinear', (7, 9), (3, 4)),
                                     ('bicubic', (5, 6), (9, 11)), ('bicubic', (9, 8), (4, 3))]:
        src = rng.uniform(-4, 4, (sh, sw)).astype(np.float32)
        out = F.interpolate(torch.from_numpy(src)[None, None], (dh, dw), mode=mode, align_corners=False)
        rows.append({'mode': mode, 'src_w': sw, 'src_h': sh, 'dst_w': dw, 'dst_h': dh,
                     'src': src.flatten().tolist(), 'dst': out.flatten().tolist()})
    return rows


def main():
    units = ct.ComputeUnit.CPU_ONLY
    encoder = ct.models.MLModel(str(MODELS / 'SAMEncoder.mlpackage'), compute_units=units)
    decoder = ct.models.MLModel(str(MODELS / 'SAMDecoder.mlpackage'), compute_units=units)
    encoder_all = ct.models.MLModel(str(MODELS / 'SAMEncoder.mlpackage'), compute_units=ct.ComputeUnit.ALL)
    decoder_all = ct.models.MLModel(str(MODELS / 'SAMDecoder.mlpackage'), compute_units=ct.ComputeUnit.ALL)
    for scene, image, parts, reference, provenance in cases(ROOT):
        out = HERE / scene
        out.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / provenance['run'] / 'input.png', out / 'input.png')
        rows = []
        results = zip(parts, reference, predict(encoder, decoder, image, parts),
                      predict(encoder_all, decoder_all, image, parts))
        for part, sam2, (box, scores, index, mask), (_, _, _, mask_all) in results:
            save_mask(mask, out / f"coreml_{part['id']}.png")
            save_mask(sam2, out / f"sam2_{part['id']}.png")
            rows.append({'id': part['id'], 'name': part['label'], 'box': part['box'],
                         'box_pixels': box_pixels(part['box'], image.size).tolist(),
                         'prompt_box': box.tolist(), 'scores': scores.tolist(), 'selected': index,
                         'iou_sam2': mask_iou(mask, sam2), 'iou_all_vs_cpu': mask_iou(mask, mask_all)})
            print(f"{scene} {part['id']} selected={index} IoU(SAM2)={rows[-1]['iou_sam2']:.4f} "
                  f"IoU(ALL vs CPU)={rows[-1]['iou_all_vs_cpu']:.4f}", flush=True)
        (out / 'boxes.json').write_text(json.dumps({
            'scene': scene, 'width': image.width, 'height': image.height, 'compute_units': units.name,
            'source': provenance, 'parts': rows}, ensure_ascii=False, indent=2) + '\n')
    (HERE / 'interp.json').write_text(json.dumps(interp_cases()) + '\n')


if __name__ == '__main__':
    main()
