import copy
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np
from jsonschema import ValidationError
from PIL import Image

from variant_b import (UnknownPartError, as_a, box_pixels, consistency_b, mask_quality,
                       process_run, schema_b, segment_boxes, validate_b)


def plan():
    return {"object": "სიფონი", "parts": [{"id": "slip_nut_right", "label": "ქანჩი",
            "box": [100, 100, 400, 400]}, {"id": "pipe", "label": "მილი", "box": [500, 500, 900, 900]}],
            "unknown_parts": [], "steps": [{"title": "შეამოწმე", "text": "ინსტრუქცია",
            "focus": ["slip_nut_right"], "avoid": ["pipe"],
            "markers": [{"part": "slip_nut_right", "label": "ქანჩი", "tone": "brand"}],
            "arrows": [{"part": "slip_nut_right", "type": "rotate", "dir": "ccw"}],
            "tools": [], "warn": None}]}


def truth():
    return {"design_size": [100, 100], "parts": [
        {"name": "NUT", "path": "M10 10 L40 10 L40 40 L10 40 Z"},
        {"name": "PIPE", "path": "M50 50 L90 50 L90 90 L50 90 Z"}],
        "steps": [{"title": "შეამოწმე", "text": "ინსტრუქცია", "focus": [0], "avoid": [1],
                   "secret": "NEVER_SEND_GT"}]}


def client_for(p):
    raw = {"usage": {"input_tokens": 1000, "output_tokens": 100}, "status": "completed", "fixture": p}
    response = SimpleNamespace(status="completed", model="gpt-6-astra", output_text=json.dumps(p),
                               model_dump=lambda **_: raw)
    return SimpleNamespace(responses=SimpleNamespace(create=Mock(return_value=response)))


def sam_for_boxes(**kwargs):
    mask = np.zeros((1, 100, 100), np.float32)
    x0, y0, x1, y1 = kwargs["bboxes"][0]
    mask[0, y0:y1, x0:x1] = 1
    tensor = SimpleNamespace(cpu=lambda: SimpleNamespace(numpy=lambda: mask[0]))
    return [SimpleNamespace(masks=SimpleNamespace(data=[tensor]))]


class VariantBTests(unittest.TestCase):
    def test_schema_and_adapter(self):
        p = plan()
        validate_b(p, 1)
        self.assertNotIn("enum", schema_b(1)["properties"]["steps"]["items"]["properties"]["focus"]["items"])
        self.assertEqual(as_a(p)["steps"][0]["arrows"][0]["part"], "p1")
        self.assertEqual(p["steps"][0]["focus"], ["slip_nut_right"])
        for mutate in (lambda p: p.update(extra=True), lambda p: p["parts"][0].update(id="Bad-ID"),
                       lambda p: p["parts"][0].update(box=[0, 0, 1001, 20]),
                       lambda p: p["parts"][0].update(box=[0, 0, 20]),
                       lambda p: p["steps"][0]["markers"][0].update(x=100)):
            p = plan()
            mutate(p)
            with self.assertRaises(ValidationError):
                validate_b(p, 1)

    def test_semantic_validation(self):
        for mutate in (lambda p: p["parts"].append(copy.deepcopy(p["parts"][0])),
                       lambda p: p["parts"][0].update(box=[10, 10, 5, 50]),
                       lambda p: p["parts"][0].update(label=" "),
                       lambda p: p["steps"][0]["avoid"].append("slip_nut_right"),
                       lambda p: p["steps"][0]["arrows"][0].update(dir="up")):
            p = plan()
            mutate(p)
            with self.assertRaises(ValueError):
                validate_b(p, 1)

    def test_unknown_ids_in_every_reference(self):
        for field in ("focus", "avoid", "markers", "arrows"):
            p = plan()
            if field in ("focus", "avoid"):
                p["steps"][0][field].append("missing")
            else:
                p["steps"][0][field][0]["part"] = "missing"
            with self.assertRaises(UnknownPartError) as ctx:
                validate_b(p, 1)
            self.assertEqual(ctx.exception.ids, ["missing"])

    def test_box_pixels(self):
        self.assertEqual(box_pixels([0, 0, 1000, 1000], (941, 1672)), [0, 0, 941, 1672])
        self.assertEqual(box_pixels([100, 200, 400, 600], (941, 1672)), [94, 334, 377, 1004])
        for box in ([0, 0, 0, 10], [20, 0, 10, 10], [-1, 0, 100, 100],
                    [0, 0, float("nan"), 10], [0, 0, float("inf"), 10], [False, 0, 10, 10]):
            with self.assertRaises(ValueError):
                box_pixels(box, (100, 100))

    def test_mock_end_to_end_and_cache(self):
        with tempfile.TemporaryDirectory() as d:
            source, dest = Path(d) / "source.png", Path(d) / "run_1"
            Image.new("RGB", (100, 100), "white").save(source)
            client = client_for(plan())
            sam = Mock(side_effect=sam_for_boxes)
            result = process_run(client, "gpt-6-astra", source, truth(), dest, "mps", sam)
            self.assertEqual(result, plan())
            for filename in ("response.json", "plan.json", "metrics.json", "masks.npz", "parts.png",
                             "step_1.png", "evaluation.json", "segmentation.json"):
                self.assertTrue((dest / filename).exists(), filename)
            self.assertEqual(sam.call_args_list[0].kwargs["bboxes"], [[10, 10, 40, 40]])
            self.assertEqual(sam.call_args.kwargs["device"], "mps")
            masks = np.load(dest / "masks.npz")
            self.assertEqual(masks["ids"].tolist(), ["slip_nut_right", "pipe"])
            self.assertEqual(masks["masks"].shape, (2, 100, 100))
            self.assertGreater(json.loads((dest / "evaluation.json").read_text())["steps"][0]["focus_design_iou"], .9)
            call = client.responses.create.call_args.kwargs
            self.assertTrue(call["text"]["format"]["strict"])
            self.assertNotIn("NEVER_SEND_GT", json.dumps(call))
            self.assertFalse(call["store"])
            import base64
            self.assertEqual(base64.b64decode(call["input"][0]["content"][1]["image_url"].split(",")[1]), source.read_bytes())
            pixels = np.array(Image.open(dest / "step_1.png"))
            for color in ([47, 107, 255], [239, 68, 68]):
                self.assertTrue(np.any(np.all(pixels == color, axis=2)))
            process_run(client, "gpt-6-astra", source, truth(), dest, "mps", sam)
            self.assertEqual(client.responses.create.call_count, 1)
            with self.assertRaises(ValueError):
                process_run(client, "different-model", source, truth(), dest, "mps", sam)
            self.assertEqual(client.responses.create.call_count, 1)

    def test_invalid_response_recorded_before_sam(self):
        with tempfile.TemporaryDirectory() as d:
            source, dest = Path(d) / "source.png", Path(d) / "run_1"
            Image.new("RGB", (100, 100)).save(source)
            p = plan()
            p["steps"][0]["focus"] = ["invented"]
            client, sam = client_for(p), Mock()
            with self.assertRaises(UnknownPartError):
                process_run(client, "gpt-6-astra", source, truth(), dest, "mps", sam)
            self.assertEqual(json.loads((dest / "error.json").read_text())["unknown_ids"], ["invented"])
            self.assertTrue((dest / "response.json").exists())
            self.assertTrue((dest / "metrics.json").exists())
            self.assertFalse((dest / "plan.json").exists())
            sam.assert_not_called()

    def test_refusal_preserves_response_and_usage(self):
        with tempfile.TemporaryDirectory() as d:
            source, dest = Path(d) / "source.png", Path(d) / "run_1"
            Image.new("RGB", (100, 100)).save(source)
            client, sam = client_for(plan()), Mock()
            client.responses.create.return_value.status = "incomplete"
            with self.assertRaises(ValueError):
                process_run(client, "gpt-6-astra", source, truth(), dest, "cpu", sam)
            self.assertTrue((dest / "response.json").exists())
            metrics = json.loads((dest / "metrics.json").read_text())
            self.assertEqual(metrics["usage"]["input_tokens"], 1000)
            self.assertGreater(metrics["estimated_usd"], 0)
            self.assertFalse((dest / "plan.json").exists())
            sam.assert_not_called()

    def test_empty_masks_parts_and_quality(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "source.png"
            Image.new("RGB", (100, 100)).save(source)
            sam = Mock(return_value=[SimpleNamespace(masks=None)])
            masks, _ = segment_boxes(source, plan()["parts"], "cpu", sam)
            rows = mask_quality(plan()["parts"], masks, (100, 100))
            self.assertTrue(all(r["empty"] for r in rows))
            rows = mask_quality(plan()["parts"], np.ones_like(masks), (100, 100))
            self.assertTrue(all(r["too_large"] for r in rows))
            empty = plan()
            empty["parts"] = []
            for field in ("focus", "avoid", "markers", "arrows"):
                empty["steps"][0][field] = []
            validate_b(empty, 1)
            process_run(client_for(empty), "gpt-6-astra", source, truth(), Path(d) / "empty", "cpu", sam)

    def test_consistency_matches_labels_boxes_not_ids(self):
        a, b = plan(), plan()
        b["parts"][0]["id"] = "renamed_nut"
        b["parts"][0]["label"] = "  ქანჩი  "
        b["steps"][0]["focus"] = ["renamed_nut"]
        result = consistency_b([a, b, a])
        self.assertEqual(len(result["pairs"]), 3)
        self.assertEqual(result["mean_part_jaccard"], 1)
        self.assertEqual(result["mean_step_jaccard"], 1)
        b["parts"][0]["box"] = [700, 700, 800, 800]
        self.assertLess(consistency_b([a, b])["mean_part_jaccard"], 1)
        b["parts"] = [copy.deepcopy(a["parts"][0])] * 2
        self.assertEqual(len(consistency_b([a, b])["pairs"][0]["matches"]), 1)
        self.assertIsNone(consistency_b([a])["mean_part_jaccard"])

    def test_cli_no_key_never_constructs_client(self):
        import run_b
        with patch.dict("os.environ", {"OPENAI_API_KEY": ""}), patch.object(run_b, "load_dotenv"), \
                patch("sys.argv", ["run_b.py"]), patch("openai.OpenAI") as client:
            self.assertEqual(run_b.main(), 2)
            client.assert_not_called()


if __name__ == "__main__":
    unittest.main()
