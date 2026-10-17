"""Local SAM2 masks and reviewable, deterministic Set-of-Marks artifacts."""
import hashlib
import json
import os
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCENES = {
    "sink": ("sink-trap.png", "repair.tsx"),
    "gym": ("gym-lat-pulldown.png", "gym.tsx"),
    "car": ("car-engine.png", "car.tsx"),
}


def save_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def font(size=22, georgian=False):
    candidates = ([os.environ.get("SOM_FONT", ""), "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
                   "/Library/Fonts/Arial Unicode.ttf"]
                  if georgian else ["/System/Library/Fonts/Supplemental/Arial Bold.ttf"])
    candidates += ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default(size=size)


def filter_masks(masks, scores, min_fraction=0.0003, duplicate_iou=0.9):
    """Keep small useful parts; remove near-identical masks, not nested parts."""
    candidates = []
    for mask, score in zip(masks, scores):
        mask = np.asarray(mask, dtype=bool)
        area = int(mask.sum())
        if min_fraction <= area / mask.size <= 0.85:
            candidates.append((mask, float(score), area))
    candidates.sort(key=lambda m: (-m[1], m[2]))
    kept = []
    for mask, score, area in candidates:
        if any(np.logical_and(mask, old[0]).sum() / np.logical_or(mask, old[0]).sum()
               >= duplicate_iou for old in kept):
            continue
        kept.append((mask, score, area))
    # Stable top-to-bottom ordering within a cached segmentation, not across frames.
    kept.sort(key=lambda m: (np.where(m[0])[0].mean(), np.where(m[0])[1].mean(), m[2]))
    return kept


def mask_anchor(mask):
    distance = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
    y, x = np.unravel_index(distance.argmax(), distance.shape)
    return int(x), int(y)


def paint(image, masks, colors, labels):
    pixels = np.array(image.convert("RGB"))
    for mask, color in zip(masks, colors):
        pixels[mask] = (pixels[mask] * 0.82 + np.array(color) * 0.18).astype(np.uint8)
        contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(pixels, contours, -1, color, 2)
    result = Image.fromarray(pixels)
    draw = ImageDraw.Draw(result)
    face = font(max(18, image.width // 42))
    used = []
    for mask, label, color in zip(masks, labels, colors):
        ax, ay = mask_anchor(mask)
        box = draw.textbbox((0, 0), label, font=face)
        w, h = box[2] + 12, box[3] - box[1] + 10
        # Move colliding labels, retaining a leader to a point inside their mask.
        positions = [(ax, ay)] + [(ax + dx, ay + dy) for dy in range(-100, 101, 25)
                                  for dx in range(-100, 101, 50)]
        for x, y in positions:
            x = max(0, min(image.width - w, x - w // 2))
            y = max(0, min(image.height - h, y - h // 2))
            rect = (x, y, x + w, y + h)
            if not any(x < b[2] + 3 and x + w > b[0] - 3 and y < b[3] + 3 and y + h > b[1] - 3
                       for b in used):
                break
        used.append(rect)
        draw.line((ax, ay, x + w // 2, y + h // 2), fill=color, width=2)
        draw.rounded_rectangle(rect, radius=4, fill=(15, 23, 42), outline=color, width=2)
        draw.text((x + 6, y + 5 - box[1]), label, font=face, fill="white")
    return result


def segment(scene, args):
    import importlib.metadata
    import torch

    out = HERE / "out" / scene
    out.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Camera/assets" / SCENES[scene][0]
    device = args.device or ("mps" if torch.backends.mps.is_available() else "cpu")
    config = {"source_sha256": digest(source), "model": args.sam_model, "device": device,
              "points_stride": args.points_stride, "crop_n_layers": args.crop_layers, "imgsz": 1024,
              "min_fraction": 0.0003, "duplicate_iou": 0.9,
              "ultralytics": importlib.metadata.version("ultralytics"), "pipeline_version": 1}
    meta_path = out / "segments.json"
    if meta_path.exists() and not args.resegment:
        meta = json.loads(meta_path.read_text())
        if meta["config"] != config:
            raise ValueError(f"{scene}: segmentation settings changed; use --resegment to invalidate IDs/results")
        return Image.open(source).convert("RGB"), np.load(out / "masks.npz")["masks"], meta

    # Results referring to previous mask IDs must never survive resegmentation.
    for path in list(out.glob("run_*")) + list(out.glob("step_*.png")):
        if path.is_dir():
            import shutil
            shutil.rmtree(path)
        else:
            path.unlink()
    os.environ.setdefault("YOLO_CONFIG_DIR", str(HERE / ".cache/ultralytics"))
    os.environ.setdefault("MPLCONFIGDIR", str(HERE / ".cache/matplotlib"))
    from ultralytics import SAM
    from ultralytics.models.sam import SAM2Predictor

    models = HERE / "models"
    models.mkdir(exist_ok=True)
    checkpoint = models / args.sam_model
    # SAM downloads the official weights to the explicit experiment-local path.
    SAM(str(checkpoint))
    predictor = SAM2Predictor(overrides={"model": str(checkpoint), "task": "segment", "mode": "predict",
                                        "imgsz": 1024, "device": device, "verbose": False, "conf": 0.25,
                                        "save": False, "project": str(HERE / ".cache/predict")})
    print(f"{scene}: SAM2 automatic ({device}, {args.points_stride}² prompts)", flush=True)
    start = time.perf_counter()
    results = predictor(source=str(source), points_stride=args.points_stride, points_batch_size=16,
                        crop_n_layers=args.crop_layers, crop_downscale_factor=2)
    elapsed = time.perf_counter() - start
    result = results[0]
    if result.masks is None:
        raise RuntimeError(f"{scene}: no SAM masks")
    image = Image.open(source).convert("RGB")
    raw = result.masks.data.cpu().numpy()
    raw = [cv2.resize(m.astype(np.uint8), image.size, interpolation=cv2.INTER_NEAREST).astype(bool) for m in raw]
    scores = result.boxes.conf.cpu().numpy()
    kept = filter_masks(raw, scores)
    if not kept:
        raise RuntimeError(f"{scene}: no masks survived filtering")
    masks = np.stack([m[0] for m in kept])
    parts = []
    for i, (mask, score, area) in enumerate(kept, 1):
        ys, xs = np.where(mask)
        parts.append({"id": f"p{i}", "score": score, "area": area,
                      "box_xyxy": [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())],
                      "anchor": mask_anchor(mask)})
    meta = {"config": config, "seconds": elapsed, "raw_masks": len(raw), "kept_masks": len(kept),
            "image_size": list(image.size), "checkpoint_sha256": digest(checkpoint), "parts": parts}
    np.savez_compressed(out / "masks.npz", masks=masks)
    save_json(meta_path, meta)
    colors = [(int(80 + (i * 71) % 176), int(80 + (i * 113) % 176), int(80 + (i * 43) % 176))
              for i in range(len(masks))]
    paint(image, masks, colors, [p["id"] for p in parts]).save(out / "marked.png")
    print(f"{scene}: {len(raw)} → {len(kept)} masks, {elapsed:.1f}s", flush=True)
    return image, masks, meta
