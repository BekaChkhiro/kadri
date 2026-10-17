"""Meaningful offline tests for the four new scenes (chemistry, microscope, psychology, laundry)."""
import json
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from evaluation import evaluate, ground_truth, truth_masks
from segmentation import HERE, ROOT, SCENES, paint


NEW_SCENES = ("chemistry", "microscope", "psychology", "laundry")
EXPECTED_SIZES = {
    "chemistry": (941, 1672),
    "microscope": (1024, 1536),
    "psychology": (941, 1672),
    "laundry": (1024, 1536),
}
EXPECTED_PART_COUNTS = {
    "chemistry": 5,
    "microscope": 8,
    "psychology": 6,
    "laundry": 7,
}


class NewScenesTests(unittest.TestCase):
    def test_scenes_registered(self):
        """Verify that all four new scenes are present in SCENES dict with valid assets and artboards."""
        for scene in NEW_SCENES:
            self.assertIn(scene, SCENES)
            png_name, tsx_name = SCENES[scene]
            png_path = ROOT / "Camera/assets" / png_name
            tsx_path = ROOT / "Camera/artboards" / tsx_name
            self.assertTrue(png_path.is_file(), f"Asset image missing: {png_path}")
            self.assertTrue(tsx_path.is_file(), f"Artboard file missing: {tsx_path}")

    def test_image_dimensions_match_artboards(self):
        """Ensure photo pixel dimensions match artboard design size specifications."""
        for scene in NEW_SCENES:
            png_path = ROOT / "Camera/assets" / SCENES[scene][0]
            with Image.open(png_path) as img:
                self.assertEqual(img.size, EXPECTED_SIZES[scene],
                                 f"{scene} image size {img.size} does not match expected {EXPECTED_SIZES[scene]}")
            truth = ground_truth(scene)
            self.assertEqual(tuple(truth["design_size"]), EXPECTED_SIZES[scene],
                             f"{scene} design_size {truth['design_size']} mismatch")

    def test_ground_truth_structure_and_indices(self):
        """Verify ground_truth steps, part names, and focus/avoid indices are within bounds."""
        for scene in NEW_SCENES:
            truth = ground_truth(scene)
            parts = truth["parts"]
            steps = truth["steps"]

            self.assertEqual(len(parts), EXPECTED_PART_COUNTS[scene],
                             f"{scene} unexpected part count: {len(parts)}")
            self.assertEqual(len(steps), 5, f"{scene} must have exactly 5 steps")

            part_names = {p["name"] for p in parts}
            self.assertEqual(len(part_names), len(parts), f"{scene} part names must be unique")

            for step_idx, step in enumerate(steps, 1):
                self.assertIn("title", step, f"{scene} step {step_idx} missing title")
                self.assertIn("text", step, f"{scene} step {step_idx} missing text")
                self.assertIn("focus", step, f"{scene} step {step_idx} missing focus")
                self.assertIsInstance(step["focus"], list)

                # Focus part indices must be valid indices into parts
                for idx in step["focus"]:
                    self.assertIsInstance(idx, int)
                    self.assertTrue(0 <= idx < len(parts),
                                    f"{scene} step {step_idx} focus index {idx} out of range [0, {len(parts)-1}]")

                # Avoid part indices must be valid indices into parts if present
                if "avoid" in step:
                    self.assertIsInstance(step["avoid"], list)
                    for idx in step["avoid"]:
                        self.assertIsInstance(idx, int)
                        self.assertTrue(0 <= idx < len(parts),
                                        f"{scene} step {step_idx} avoid index {idx} out of range [0, {len(parts)-1}]")

    def test_truth_masks_geometry(self):
        """Verify that parsed SVG paths generate non-empty, binary masks without errors."""
        for scene in NEW_SCENES:
            truth = ground_truth(scene)
            size = EXPECTED_SIZES[scene]
            masks = truth_masks(truth, size)

            self.assertEqual(masks.shape, (len(truth["parts"]), size[1], size[0]))
            self.assertEqual(masks.dtype, bool)

            for idx, mask in enumerate(masks):
                part_name = truth["parts"][idx]["name"]
                area = int(mask.sum())
                self.assertGreater(area, 0, f"{scene} part {part_name} has empty mask")
                self.assertLess(area, size[0] * size[1], f"{scene} part {part_name} covers entire image")

    def test_identity_iou_evaluation(self):
        """Verify that an ideal plan matching ground-truth focus achieves 1.0 IoU."""
        for scene in NEW_SCENES:
            truth = ground_truth(scene)
            size = (240, 360)
            masks = truth_masks(truth, size)

            # Create an ideal plan using 1-based part IDs (p1, p2, ...)
            ideal_plan = {
                "steps": [
                    {f: [f"p{n + 1}" for n in step.get(f, [])] for f in ("focus", "avoid")}
                    for step in truth["steps"]
                ]
            }
            evaluation = evaluate(ideal_plan, truth, masks, size)
            rows = evaluation["steps"]
            self.assertEqual(len(rows), 5)
            for row in rows:
                self.assertAlmostEqual(row["focus_design_iou"], 1.0, places=5,
                                       msg=f"{scene} step {row['step']} focus IoU is not 1.0")

    def test_persisted_artifacts(self):
        """Check that out/{scene}/ground_truth.{json,png} exist and are non-empty."""
        for scene in NEW_SCENES:
            out_dir = HERE / "out" / scene
            json_file = out_dir / "ground_truth.json"
            png_file = out_dir / "ground_truth.png"

            self.assertTrue(json_file.is_file(), f"{json_file} does not exist")
            self.assertTrue(png_file.is_file(), f"{png_file} does not exist")

            self.assertGreater(json_file.stat().st_size, 100)
            self.assertGreater(png_file.stat().st_size, 1000)

            # Validate that persisted JSON loads and matches current ground_truth(scene)
            persisted_data = json.loads(json_file.read_text(encoding="utf-8"))
            live_data = json.loads(json.dumps(ground_truth(scene)))
            self.assertEqual(persisted_data, live_data, f"{scene} persisted JSON differs from live ground_truth")

            # Validate PNG dimensions
            with Image.open(png_file) as img:
                self.assertEqual(img.size, EXPECTED_SIZES[scene],
                                 f"{scene} PNG size mismatch: {img.size} vs {EXPECTED_SIZES[scene]}")


if __name__ == "__main__":
    unittest.main()
