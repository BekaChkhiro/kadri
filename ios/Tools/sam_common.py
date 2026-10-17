"""Shared geometry: original image -> longest-side resize -> bottom/right pad."""
from pathlib import Path
import hashlib
import json
import math

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MEAN = np.array([123.675, 116.28, 103.53], dtype=np.float32)
STD = np.array([58.395, 57.12, 57.375], dtype=np.float32)
SCENES = {"sink": "sink-trap", "car": "car-engine", "gym": "gym-lat-pulldown"}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def resized_size(size, side=1024):
    w, h = size
    if w <= 0 or h <= 0 or side <= 0:
        raise ValueError('Dimensions must be positive')
    scale = side / max(w, h)
    return int(w * scale + 0.5), int(h * scale + 0.5)


def box_pixels(box, size):
    """Match experiments/som-test/variant_b.py: round bounds outwards."""
    if any(isinstance(v, (bool, np.bool_)) for v in box):
        raise ValueError('Boolean coordinates are invalid')
    b = np.asarray(box)
    if b.shape != (4,) or b.dtype.kind not in 'iuf' or not np.isfinite(b).all():
        raise ValueError('Expected four finite numeric coordinates')
    if np.any(b < 0) or np.any(b > 1000) or b[0] >= b[2] or b[1] >= b[3]:
        raise ValueError('Expected positive XYXY box in 0..1000')
    w, h = size
    if min(w, h) <= 0:
        raise ValueError('Dimensions must be positive')
    return np.array([math.floor(b[0]*w/1000), math.floor(b[1]*h/1000),
                     math.ceil(b[2]*w/1000), math.ceil(b[3]*h/1000)], np.float32)


def prompt_box(box, size, side=1024, *, square=False):
    pixels = box_pixels(box, size)
    rw, rh = (side, side) if square else resized_size(size, side)
    w, h = size
    return pixels * np.array([rw/w, rh/h, rw/w, rh/h], np.float32)


def prepare_image(image, side=1024, *, square=False):
    """Float32 RGB NCHW 0..255; pad with mean so normalization gives zero."""
    image = image.convert('RGB')
    if square:
        import torch
        import torch.nn.functional as F
        raw = torch.from_numpy(np.asarray(image, dtype=np.float32).copy()).permute(2, 0, 1)[None]
        return F.interpolate(raw, (side, side), mode='bilinear', align_corners=False).numpy()
    size = resized_size(image.size, side)
    resized = np.asarray(image.resize(size, Image.Resampling.BILINEAR), dtype=np.float32)
    padded = np.broadcast_to(MEAN, (side, side, 3)).copy()
    padded[:size[1], :size[0]] = resized
    return np.ascontiguousarray(padded.transpose(2, 0, 1)[None])


def restore_masks(logits, size, side=1024, *, square=False):
    import torch
    import torch.nn.functional as F
    value = torch.as_tensor(np.asarray(logits, dtype=np.float32))
    if square:
        return F.interpolate(value, (size[1], size[0]), mode='bicubic', align_corners=False)[0].numpy() > 0
    value = F.interpolate(value, (side, side), mode='bilinear', align_corners=False)
    rw, rh = (side, side) if square else resized_size(size, side)
    value = value[..., :rh, :rw]
    return F.interpolate(value, (size[1], size[0]), mode='bilinear', align_corners=False)[0].numpy() > 0


def mask_iou(a, b):
    a, b = np.asarray(a, bool), np.asarray(b, bool)
    if a.shape != b.shape:
        raise ValueError('Mask shapes differ')
    union = np.logical_or(a, b).sum()
    return float(np.logical_and(a, b).sum() / union) if union else 1.0


def cases(root=ROOT):
    base = root / 'experiments/som-test/out_realism/c_astra_tracking'
    for scene, asset in SCENES.items():
        run = base / scene / asset / 'original/run_1'
        plan = json.loads((run / 'plan.json').read_text())
        parts = plan['parts']
        quality = json.loads((run / 'segmentation.json').read_text())['quality']
        if [x['id'] for x in quality] != [p['id'] for p in parts]:
            raise ValueError(f'{scene}: reference mask IDs do not match plan')
        source = run / 'input.png'
        image = Image.open(source).convert('RGB')
        with np.load(run / 'masks.npz', allow_pickle=False) as data:
            masks = data['masks'].astype(bool)
        if masks.shape != (len(parts), image.height, image.width):
            raise ValueError(f'{scene}: reference shape mismatch: {masks.shape}')
        for p, q in zip(parts, quality):
            if box_pixels(p['box'], image.size).tolist() != q['box_pixels']:
                raise ValueError(f'{scene}: reference box differs')
        yield scene, image, parts, masks, {
            'image_sha256': digest(source), 'plan_sha256': digest(run / 'plan.json'),
            'masks_sha256': digest(run / 'masks.npz'), 'run': str(run.relative_to(root)),
        }
