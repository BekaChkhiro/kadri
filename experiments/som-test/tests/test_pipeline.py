import copy
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
from jsonschema import ValidationError

from evaluation import consistency, evaluate, ground_truth, truth_masks
from segmentation import SCENES, filter_masks, mask_anchor
from run import render_steps
from PIL import Image
from vision import estimate_cost, request_plan, schema_for, select_model, validate_plan


def plan():
    return {"object": "სიფონი", "parts": {"p1": "ქანჩი", "p2": "მილი"}, "unknown_parts": [],
            "steps": [{"title": "შეამოწმე", "text": "ინსტრუქცია", "focus": ["p1"], "avoid": [],
                       "markers": [{"part": "p1", "label": "ქანჩი", "tone": "brand"}],
                       "arrows": [{"part": "p1", "type": "rotate", "dir": "ccw"}],
                       "tools": [], "warn": None} for _ in range(5)]}


class PipelineTests(unittest.TestCase):
    def test_filters_duplicates_but_preserves_nested_parts(self):
        big = np.zeros((100, 100), bool)
        big[10:80, 10:80] = True
        small = np.zeros_like(big)
        small[20:30, 20:30] = True
        tiny = np.zeros_like(big)
        tiny[0, 0] = True
        kept = filter_masks([big, big, small, tiny, np.ones_like(big)], [.8, .9, .95, 1, 1])
        self.assertEqual(len(kept), 2)
        self.assertEqual(sorted(k[2] for k in kept), [100, 4900])

    def test_anchor_is_inside_hollow_mask(self):
        mask = np.ones((30, 30), bool)
        mask[5:25, 5:25] = False
        x, y = mask_anchor(mask)
        self.assertTrue(mask[y, x])

    def test_valid_strict_plan(self):
        validate_plan(plan(), schema_for(["p1", "p2"]))

    def test_invalid_ids_and_coordinates_rejected(self):
        for mutate in (lambda p: p["steps"][0]["focus"].append("p99"),
                       lambda p: p["steps"][0]["markers"][0].update(x=12),
                       lambda p: p["parts"].update(p99="invented")):
            p = plan()
            mutate(p)
            with self.assertRaises(ValidationError):
                validate_plan(p, schema_for(["p1", "p2"]))

    def test_conflicting_ids_and_invalid_arrows_rejected(self):
        for mutate in (lambda p: p["steps"][0]["avoid"].append("p1"),
                       lambda p: p["steps"][0]["arrows"][0].update(dir="up"),
                       lambda p: p["parts"].update(p1="")):
            p = plan()
            mutate(p)
            with self.assertRaises(ValueError):
                validate_plan(p, schema_for(["p1", "p2"]))

    def test_ground_truth_all_scenes_and_identity_iou(self):
        for scene in SCENES:
            truth = ground_truth(scene)
            self.assertEqual(len(truth["steps"]), 5)
            masks = truth_masks(truth, (240, 360))
            self.assertTrue(all(m.any() for m in masks))
            p = {"steps": [{f: [f"p{n + 1}" for n in step.get(f, [])] for f in ("focus", "avoid")}
                            for step in truth["steps"]]}
            rows = evaluate(p, truth, masks, (240, 360))["steps"]
            self.assertTrue(all(row["focus_design_iou"] == 1 for row in rows))

    def test_consistency_does_not_confuse_agreement_with_accuracy(self):
        a = plan()
        b = copy.deepcopy(a)
        self.assertIsNone(consistency([a]))
        self.assertEqual(consistency([a, b, a]), 1)
        for step in b["steps"]:
            step["focus"] = ["p2"]
        self.assertEqual(consistency([a, b]), 0.5)  # empty avoid agrees; focus does not

    def test_model_selection_checks_account_visibility(self):
        client = SimpleNamespace(models=SimpleNamespace(list=lambda: [SimpleNamespace(id="gpt-6-astra"),
                                                                     SimpleNamespace(id="gpt-4o")]))
        with tempfile.TemporaryDirectory() as d, patch.dict("os.environ", {"OPENAI_MODEL": ""}):
            self.assertEqual(select_model(client, Path(d)), "gpt-6-astra")
            with patch.dict("os.environ", {"OPENAI_MODEL": "missing-model"}):
                with self.assertRaises(ValueError):
                    select_model(client, Path(d))

    def test_cost_uses_cached_tokens_and_unknown_is_not_zero(self):
        usage = {"input_tokens": 1000, "input_tokens_details": {"cached_tokens": 500}, "output_tokens": 100}
        self.assertAlmostEqual(estimate_cost(usage, "gpt-6-astra"), 0.0105)
        self.assertIsNone(estimate_cost(usage, "unknown"))

    def test_step_renderer_writes_focus_avoid_and_georgian_markers(self):
        image = Image.new("RGB", (400, 400), "white")
        masks = np.zeros((2, 400, 400), bool)
        masks[0, 30:130, 30:130] = True
        masks[1, 200:300, 200:300] = True
        p = plan()
        for step in p["steps"]:
            step["avoid"] = ["p2"]
        with tempfile.TemporaryDirectory() as d:
            render_steps(image, masks, p, Path(d))
            self.assertEqual(len(list(Path(d).glob("step_*.png"))), 5)
            pixels = np.array(Image.open(Path(d) / "step_1.png"))
            self.assertGreater(pixels.shape[0], 400)
            self.assertTrue(np.any(np.all(pixels == [47, 107, 255], axis=2)))
            self.assertTrue(np.any(np.all(pixels == [239, 68, 68], axis=2)))

    def test_response_contract_and_no_ground_truth_id_leakage(self):
        captured = {}
        p = plan()
        raw = {"usage": {"input_tokens": 100, "output_tokens": 40}, "status": "completed"}
        response = SimpleNamespace(status="completed", output_text=json.dumps(p), model="gpt-6-astra",
                                   model_dump=lambda **_: raw)
        def create(**kwargs):
            captured.update(kwargs)
            return response
        client = SimpleNamespace(responses=SimpleNamespace(create=create))
        with tempfile.TemporaryDirectory() as d:
            dest = Path(d)
            (dest / "image.png").write_bytes(b"test fixture")
            truth = {"steps": [{"title": "ქანჩი", "text": "შეამოწმე", "focus": ["SECRET_GT_ID"]} for _ in range(5)]}
            self.assertEqual(request_plan(client, "gpt-6-astra", dest / "image.png", truth, ["p1", "p2"], dest), p)
            self.assertTrue(captured["text"]["format"]["strict"])
            self.assertNotIn("SECRET_GT_ID", captured["input"][0]["content"][0]["text"])
            self.assertFalse(captured["store"])
            response.status = "incomplete"
            with self.assertRaises(ValueError):
                request_plan(client, "gpt-6-astra", dest / "image.png", truth, ["p1", "p2"], dest)
            self.assertTrue((dest / "metrics.json").exists())


if __name__ == "__main__":
    unittest.main()
