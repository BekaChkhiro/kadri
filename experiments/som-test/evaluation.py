"""Artboard extraction and explicitly approximate, geometric evaluation."""
import itertools
import json
import re

import cv2
import json5
import numpy as np
from svgpathtools import parse_path

from segmentation import ROOT, SCENES, digest


def ground_truth(scene):
    source = ROOT / "Camera/artboards" / SCENES[scene][1]
    text = source.read_text()
    constants = {name: int(n) for name, n in re.findall(r"const ([A-Z_]+) = (\d+);", text)}
    shapes = json5.loads(re.search(r"const (?:parts|machine) = (\[.*?\]);", text, re.S)[1])
    steps_text = re.search(r"const steps: Step\[\] = (\[.*?\n\]);", text, re.S)[1]
    # Substitute only focus/avoid identifier arrays; never alter human text.
    def replace(match):
        values = [constants[name.strip()] for name in match[2].split(",") if name.strip()]
        return match[1] + json.dumps(values)
    steps_text = re.sub(r"((?:focus|avoid):\s*)\[([^]]*)\]", replace, steps_text)
    steps = json5.loads(steps_text)
    dimensions = (1024, 1536) if scene == "sink" else (941, 1672)
    names = {value: name for name, value in constants.items()}
    return {"source": str(source.relative_to(ROOT)), "source_sha256": digest(source),
            "design_size": dimensions, "parts": [{"name": names[i], "path": path} for i, path in enumerate(shapes)],
            "steps": steps}


def truth_masks(truth, size):
    width, height = size
    sx, sy = width / truth["design_size"][0], height / truth["design_size"][1]
    masks = []
    for part in truth["parts"]:
        mask = np.zeros((height, width), np.uint8)
        for subpath in parse_path(part["path"]).continuous_subpaths():
            points = []
            for segment in subpath:
                points.extend(segment.point(t) for t in np.linspace(0, 1, 32))
            polygon = np.array([[round(p.real * sx), round(p.imag * sy)] for p in points], np.int32)
            cv2.fillPoly(mask, [polygon], 1)
        masks.append(mask.astype(bool))
    return np.stack(masks)


def iou(a, b):
    union = np.logical_or(a, b).sum()
    return float(np.logical_and(a, b).sum() / union) if union else 1.0


def coverage(truth, masks, size):
    refs = truth_masks(truth, size)
    return [{"part": part["name"], "best_id": f"p{int(np.argmax(values)) + 1}",
             "best_iou": max(values)}
            for part, values in zip(truth["parts"], [[iou(ref, m) for m in masks] for ref in refs])]


def evaluate(plan, truth, masks, size):
    refs = truth_masks(truth, size)
    rows = []
    for index, (step, expected) in enumerate(zip(plan["steps"], truth["steps"]), 1):
        row = {"step": index}
        for field in ("focus", "avoid"):
            actual = np.zeros(masks.shape[1:], bool)
            reference = np.zeros_like(actual)
            for part_id in step[field]:
                actual |= masks[int(part_id[1:]) - 1]
            for n in expected.get(field, []):
                reference |= refs[n]
            row[field + "_design_iou"] = iou(actual, reference)
        rows.append(row)
    return {"metric": "Approximate IoU against design polygons; NOT verified semantic ID accuracy", "steps": rows}


def consistency(plans):
    if len(plans) < 2:
        return None
    values = []
    for a, b in itertools.combinations(plans, 2):
        for step_a, step_b in zip(a["steps"], b["steps"]):
            for field in ("focus", "avoid"):
                x, y = set(step_a[field]), set(step_b[field])
                values.append(len(x & y) / len(x | y) if x | y else 1.0)
    return sum(values) / len(values)
