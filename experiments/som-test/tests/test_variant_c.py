import base64
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import numpy as np
from jsonschema import Draft202012Validator, ValidationError
from PIL import Image

import run_c
from variant_c import (Budget, BudgetExceeded, MODES, assign_ids, consistency_c, cost_for,
                       degrade, first_step, forecast, match_parts, process_c, prompt_parts,
                       prompt_steps, rates_for, request_stage, schema_parts, schema_steps,
                       transform_parts, validate_steps)
from test_variant_b import plan as b_plan, truth, sam_for_boxes


def parts():
    return assign_ids([{k: v for k, v in p.items() if k != "id"} for p in b_plan()["parts"]])


def steps():
    p = b_plan()
    s = p["steps"][0]
    s["focus"], s["avoid"] = ["p1"], ["p2"]
    s["markers"][0]["part"] = s["arrows"][0]["part"] = "p1"
    return {"steps": [s], "unknown_parts": []}


def response(payload, status="completed"):
    raw = {"usage": {"input_tokens": 1000, "output_tokens": 100}, "status": status}
    return SimpleNamespace(output_text=json.dumps(payload), model="gpt-6-astra", status=status,
                           model_dump=lambda **kw: raw)


def stream_for(payload, status="completed", chunks=None):
    text = json.dumps(payload)
    chunks = chunks or [text[:30], text[30:-22], text[-22:]]
    events = [SimpleNamespace(type="response.output_text.delta", delta=c) for c in chunks]
    events.append(SimpleNamespace(type="response." + status, response=response(payload, status)))
    stream = Mock()
    stream.__iter__ = Mock(return_value=iter(events))
    return stream


class VariantCTests(unittest.TestCase):
    def test_ids_order_independent_and_center_sorted(self):
        original = [{"label": "right", "box": [600, 0, 800, 200]},
                    {"label": "bottom", "box": [0, 500, 20, 600]},
                    {"label": "left", "box": [0, 0, 100, 200]}]
        a = assign_ids(original)
        self.assertEqual(a, assign_ids(original[::-1]))
        self.assertEqual([p["label"] for p in a], ["left", "right", "bottom"])
        self.assertEqual([p["id"] for p in a], ["p1", "p2", "p3"])
        self.assertNotIn("id", original[0])
        for box in ([1, 0, 0, 1], [0, 0, float("nan"), 1], [0, 0, 1001, 1]):
            with self.assertRaises(ValueError):
                assign_ids([{"label": "x", "box": box}])

    def test_parts_schema_has_no_model_ids_or_steps(self):
        schema = schema_parts()
        self.assertEqual(set(schema["properties"]), {"object", "parts"})
        with self.assertRaises(ValidationError):
            Draft202012Validator(schema).validate({"object": "x", "parts": parts()})

    def test_all_references_enum_and_semantic_validation(self):
        schema = schema_steps(parts(), 1)
        Draft202012Validator.check_schema(schema)
        validate_steps(steps(), parts(), 1)
        for field in ("focus", "avoid", "markers", "arrows"):
            value = steps()
            if field in ("focus", "avoid"):
                value["steps"][0][field] = ["invented"]
            else:
                value["steps"][0][field][0]["part"] = "invented"
            with self.assertRaises(ValidationError):
                validate_steps(value, parts(), 1)
        value = steps()
        value["steps"][0]["avoid"] = ["p1"]
        with self.assertRaises(ValueError):
            validate_steps(value, parts(), 1)

    def test_no_parts_schema_is_valid_and_forbids_references(self):
        schema = schema_steps([], 1)
        Draft202012Validator.check_schema(schema)
        value = steps()
        for field in ("focus", "avoid", "markers", "arrows"):
            value["steps"][0][field] = []
        validate_steps(value, [], 1)
        value["steps"][0]["focus"] = ["p1"]
        with self.assertRaises(ValidationError):
            validate_steps(value, [], 1)

    def test_matching_geometry_not_labels_and_one_to_one(self):
        a, b = parts(), parts()
        b[0]["label"], b[0]["id"] = "სხვა სახელი", "p3"
        result = match_parts(a, b)
        self.assertEqual(result["matched"], 2)
        self.assertEqual(result["same_id_fraction_matched"], .5)
        self.assertEqual(match_parts(a, [b[0], b[0]])["matched"], 1)
        self.assertIsNone(match_parts([], [])["mean_iou"])
        self.assertEqual(len(consistency_c([a, b, a])["pairs"]), 3)
        self.assertEqual(consistency_c([a, b, a])["same_id_fraction_all_runs"], .5)
        dropped = match_parts(a, b[:1])
        self.assertEqual(dropped["matched_fraction_reference"], .5)
        self.assertEqual(dropped["count_change"], -1)

    def test_degrade_determinism_and_transform(self):
        pixels = np.random.default_rng(123).integers(0, 256, (180, 100, 3), dtype=np.uint8)
        image = Image.fromarray(pixels)
        for mode in MODES:
            a, ma = degrade(image, mode, 42)
            b, mb = degrade(image, mode, 42)
            self.assertTrue(np.array_equal(a, b), mode)
            self.assertFalse(np.array_equal(a, image), mode)
            self.assertEqual(ma, mb)
            self.assertEqual(a.size, image.size)
        dark, _ = degrade(image, "dark", 42)
        self.assertLess(np.array(dark).mean(), pixels.mean())
        self.assertFalse(np.array_equal(dark, degrade(image, "dark", 43)[0]))
        self.assertEqual(transform_parts(parts(), np.eye(3)), parts())
        matrix = [[1, 0, 100], [0, 1, 0], [0, 0, 1]]
        shifted = transform_parts(parts(), matrix)
        self.assertEqual(shifted[0]["box"], [200, 100, 500, 400])
        self.assertEqual(transform_parts(parts(), [[1, 0, 2000], [0, 1, 0], [0, 0, 1]]), [])

    def test_budget_reservation_persists_and_unknown_usage_is_not_free(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "budget.json"
            budget = Budget(.5, path)
            ticket = budget.reserve(.3, "test")
            budget.settle(ticket, None)
            with self.assertRaises(BudgetExceeded):
                Budget(.5, path).reserve(.3, "second")
            budget.settle(ticket, .1)
            self.assertAlmostEqual(Budget(.5, path).spent, .1)
            budget.reserve(.4, "exact boundary")
            with self.assertRaises(BudgetExceeded):
                budget.reserve(.001, "too much")
        for value in (0, -1, float("nan"), float("inf")):
            with self.assertRaises(ValueError):
                Budget(value)

    def test_prices_unknown_blocked_and_manual_cached_full_price(self):
        with self.assertRaises(ValueError):
            rates_for("unknown", {})
        self.assertEqual(rates_for("unknown", {"unknown": (1, 2)}), (1, 2))
        self.assertAlmostEqual(cost_for({"input_tokens": 1000, "output_tokens": 100,
            "input_tokens_details": {"cached_tokens": 1000}}, "unknown", {"unknown": (1, 2)}), .0012)
        self.assertGreater(forecast("gpt-6-astra", {}, "steps"), 0)

    def test_first_step_requires_complete_valid_object_and_escaped_strings(self):
        payload = steps()
        payload["steps"][0]["text"] = 'escaped " ] } steps: ['
        prefix = '{"steps":[' + json.dumps(payload["steps"][0])
        self.assertIsNone(first_step(prefix[:-1], parts()))
        self.assertEqual(first_step(prefix, parts()), payload["steps"][0])

    def test_mock_stream_measures_complete_first_step_and_closes(self):
        with tempfile.TemporaryDirectory() as d:
            stream = stream_for(steps())
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(return_value=stream)))
            budget = Budget(2)
            result, metrics = request_stage(client, "gpt-6-astra", "steps", "prompt", schema_steps(parts(), 1),
                None, Path(d), "minimal", budget, {}, parts(), clock=iter([10, 12, 15]).__next__)
            self.assertEqual(result, steps())
            self.assertEqual(metrics["time_to_first_step_seconds"], 2)
            self.assertEqual(metrics["seconds"], 5)
            self.assertTrue(client.responses.create.call_args.kwargs["stream"])
            stream.close.assert_called_once()
            self.assertAlmostEqual(budget.spent, .015)
            self.assertTrue((Path(d) / "first_step.json").exists())

    def test_stream_incomplete_keeps_usage_and_no_result(self):
        with tempfile.TemporaryDirectory() as d:
            stream = stream_for(steps(), "incomplete")
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(return_value=stream)))
            budget = Budget(2)
            with self.assertRaises(ValueError):
                request_stage(client, "gpt-6-astra", "steps", "p", schema_steps(parts(), 1),
                    None, Path(d), "low", budget, {}, parts())
            self.assertAlmostEqual(budget.spent, .015)
            self.assertTrue((Path(d) / "response.json").exists())
            self.assertFalse((Path(d) / "result.json").exists())
            stream.close.assert_called_once()

    def test_budget_stops_before_request_and_network_failure_retains_reserve(self):
        with tempfile.TemporaryDirectory() as d:
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(side_effect=RuntimeError)))
            with self.assertRaises(BudgetExceeded):
                request_stage(client, "gpt-6-astra", "parts", "p", schema_parts(), None,
                              Path(d), "minimal", Budget(.001), {})
            client.responses.create.assert_not_called()
            budget = Budget(2)
            with self.assertRaises(RuntimeError):
                request_stage(client, "gpt-6-astra", "parts", "p", schema_parts(), None,
                              Path(d), "minimal", budget, {})
            self.assertGreater(budget.spent, 0)

    def test_disconnected_stream_keeps_reservation_and_closes(self):
        with tempfile.TemporaryDirectory() as d:
            stream = Mock()
            stream.__iter__ = Mock(return_value=iter([
                SimpleNamespace(type="response.output_text.delta", delta='{"steps":[')]))
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(return_value=stream)))
            budget = Budget(2)
            with self.assertRaises(RuntimeError):
                request_stage(client, "gpt-6-astra", "steps", "p", schema_steps(parts(), 1),
                              None, Path(d), "minimal", budget, {}, parts())
            self.assertEqual(budget.spent, forecast("gpt-6-astra", {}, "steps"))
            stream.close.assert_called_once()
            self.assertFalse((Path(d) / "result.json").exists())

    def test_non_reasoning_model_omits_reasoning_parameter(self):
        with tempfile.TemporaryDirectory() as d:
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(return_value=response({"object": "x", "parts": []}))))
            request_stage(client, "gpt-4.1-mini", "parts", "p", schema_parts(), None,
                          Path(d), "minimal", Budget(2), {"gpt-4.1-mini": (.4, 1.6)})
            self.assertNotIn("reasoning", client.responses.create.call_args.kwargs)

    def test_full_mock_pipeline_outlines_exist_before_steps(self):
        with tempfile.TemporaryDirectory() as d:
            source, dest = Path(d) / "source.png", Path(d) / "run"
            Image.new("RGB", (100, 100), "white").save(source)
            payload = {"object": "სიფონი", "parts": [{k: v for k, v in p.items() if k != "id"} for p in parts()]}
            def create(**kw):
                if kw.get("stream"):
                    self.assertTrue((dest / "parts.png").exists())
                    return stream_for(steps())
                return response(payload)
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(side_effect=create)))
            result = process_c(client, "gpt-6-astra", source, truth(), dest, "cpu", "minimal",
                               768, "clean", 42, Budget(2), {}, Mock(side_effect=sam_for_boxes))
            self.assertEqual(result["parts"], parts())
            self.assertGreater(result["metrics"]["time_to_first_outline_seconds"], 0)
            self.assertTrue((dest / "step_1.png").exists())
            self.assertNotIn("NEVER_SEND_GT", str(client.responses.create.call_args_list))

    def test_pipeline_both_stages_receive_prepared_photo_without_truth_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            source, dest = Path(d) / "original.png", Path(d) / "run"
            Image.new("RGB", (200, 200), "white").save(source)
            fixture = truth()
            fixture["parts"][0].update(id="GT_ONLY_ID", path="GT_ONLY_PATH")
            fixture["steps"][0].update(focus=["GT_ONLY_ID"], path="GT_STEP_PATH")
            payload = {"object": "ობიექტი", "parts": [
                {k: v for k, v in p.items() if k != "id"} for p in parts()]}
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(
                side_effect=[response(payload), stream_for(steps())])))
            with patch("variant_c.request_stage", wraps=request_stage) as stage:
                process_c(client, "gpt-6-astra", source, fixture, dest, "cpu", "minimal",
                          100, "dark", 42, Budget(2), {}, Mock(side_effect=sam_for_boxes))
            prepared = dest / "input.png"
            self.assertNotEqual(prepared.read_bytes(), source.read_bytes())
            expected_instructions = [{"title": s["title"], "text": s["text"]}
                                     for s in fixture["steps"]]
            for call, api_call in zip(stage.call_args_list, client.responses.create.call_args_list):
                self.assertEqual(call.args[5], prepared)
                content = api_call.kwargs["input"][0]["content"]
                self.assertEqual(content[1], {"type": "input_image", "detail": "high",
                    "image_url": "data:image/png;base64," + base64.b64encode(prepared.read_bytes()).decode()})
                data = json.loads(content[0]["text"].split("\n", 1)[1])
                self.assertEqual(data if call.args[2] == "parts" else data["instructions"],
                                 expected_instructions)
                for secret in ("GT_ONLY_ID", "GT_ONLY_PATH", "GT_STEP_PATH", "NEVER_SEND_GT"):
                    self.assertNotIn(secret, str(api_call))
                saved = json.loads((dest / (call.args[2] + "_request") / "request.json").read_text())
                self.assertEqual(saved["source"], str(prepared))
            self.assertEqual(stage.call_count, 2)

    def test_cli_dry_run_and_missing_key_never_construct_client(self):
        for args in (["--dry-run"], []):
            with patch.dict("os.environ", {"OPENAI_API_KEY": ""}), patch.object(run_c, "load_dotenv"), \
                    patch("sys.argv", ["run_c.py", *args]), patch("openai.OpenAI") as client:
                self.assertEqual(run_c.main(), 0 if args else 2)
                client.assert_not_called()

    def test_prompts_contract_ambiguity_uncertainty_and_empty_focus(self):
        instructions = [{"title": "მოუშვი ქანჩი", "text": "ეს ქანჩი ჟონავს."}]
        p_prompt = prompt_parts(instructions)
        self.assertIn("მდებარეობა", p_prompt)
        self.assertIn("მარჯვენა/მარცხენა/ზედა/ქვედა", p_prompt)
        self.assertIn("უხილავი ნაწილი არ გამოიგონო", p_prompt)
        self.assertIn("მხოლოდ ფიზიკური ხილული კომპონენტები", p_prompt)
        self.assertIn("ნაწილი არ არის და parts-ში არ ჩასვა", p_prompt)
        self.assertIn("იმავე label string-ში", p_prompt)
        self.assertIn("მხოლოდ თუ ფოტოზე ჩანს", p_prompt)
        self.assertIn("არ მიაწერო ნავარაუდევი მტკიცებულება", p_prompt)

        s_prompt = prompt_steps("სიფონი", parts(), instructions)
        self.assertIn("plausible კანდიდატია", s_prompt)
        self.assertIn("ყველაზე სავარაუდო box", s_prompt)
        self.assertIn("uncertainty", s_prompt)
        self.assertIn("empty focus დასაშვებია მხოლოდ მაშინ, როცა სამიზნე ნაწილების სიაში ან ფოტოზე საერთოდ არ ჩანს", s_prompt)
        self.assertIn("არ გამოიგონო ID", s_prompt)
        self.assertIn("მიმაგრებულ ფოტოზე გადაამოწმე", s_prompt)
        self.assertIn("არ აირჩიო მხოლოდ სიაში პირველი კანდიდატი", s_prompt)
        self.assertIn("არ გამოიგონო მტკიცებულება", s_prompt)
        self.assertIn("ვედრო) არ ჩანს, დატოვე empty focus", s_prompt)
        self.assertIn("ცარიელი ადგილის, ფონის ან დასადგმელი ზონის ID-ის გამოყენება აკრძალულია", s_prompt)
        for prompt in (p_prompt, s_prompt):
            self.assertIn("წვეთები, სველი კვალი, შეერთება", prompt)

    def test_schema_descriptions_and_focus_optionality(self):
        schema = schema_steps(parts(), 1)
        Draft202012Validator.check_schema(schema)
        step_props = schema["properties"]["steps"]["items"]["properties"]
        self.assertNotIn("minItems", step_props["focus"])
        self.assertIn("plausible", step_props["focus"]["description"])
        self.assertIn("empty focus", step_props["focus"]["description"])
        self.assertIn("uncertainty", step_props["warn"]["description"])

    def test_sink_mocked_contract_plausible_resolution_and_invisible_empty_focus(self):
        sink_parts = [
            {"id": "p1", "label": "სიფონის ზედა პლასტმასის ქანჩი", "box": [268, 91, 488, 166]},
            {"id": "p2", "label": "მარცხენა ჩამკეტი ონკანის სახელური", "box": [12, 257, 88, 320]},
            {"id": "p3", "label": "მარჯვენა ჩამკეტი ონკანის სახელური", "box": [221, 261, 293, 326]},
            {"id": "p4", "label": "სიფონის მარჯვენა პლასტმასის ქანჩი", "box": [628, 249, 752, 378]},
            {"id": "p5", "label": "სიფონის მოხრილი მილი", "box": [307, 248, 650, 493]},
        ]
        plan_payload = {
            "steps": [
                {"title": "დაკეტე წყალი", "text": "დაკეტე ორივე ონკანი", "focus": ["p2", "p3"],
                 "avoid": [], "markers": [], "arrows": [], "tools": [], "warn": None},
                {"title": "ჩადგი ვედრო სიფონის ქვეშ", "text": "ვედრო დადგი", "focus": [],
                 "avoid": [], "markers": [], "arrows": [], "tools": ["ვედრო"],
                 "warn": "ვედრო სიაში არ არის და უხილავია"},
                {"title": "მოუშვი ქანჩი", "text": "ეს ქანჩი ჟონავს", "focus": ["p4"],
                 "avoid": [], "markers": [], "arrows": [{"part": "p4", "type": "rotate", "dir": "ccw"}],
                 "tools": ["ხელთათმანი"],
                 "warn": "სავარაუდოდ მარჯვენა ქანჩია p4, თუმცა შესაძლოა p1-ც იყოს (uncertainty)"},
                {"title": "შეამოწმე შუასადები", "text": "ნახე რეზინის რგოლი", "focus": [],
                 "avoid": [], "markers": [], "arrows": [], "tools": ["შუასადები 40 მმ"],
                 "warn": "შუასადები უხილავია და სიაში არ არის"},
                {"title": "მოუჭირე და შეამოწმე", "text": "მოუჭირე ხელით", "focus": ["p4"],
                 "avoid": [], "markers": [], "arrows": [{"part": "p4", "type": "rotate", "dir": "cw"}],
                 "tools": [], "warn": "დაშვება p4 ქანჩზე (uncertainty)"},
            ],
            "unknown_parts": ["ვედრო", "შუასადები 40 მმ"],
        }
        validated = validate_steps(plan_payload, sink_parts, 5)
        focus_lens = [len(s["focus"]) for s in validated["steps"]]
        self.assertEqual(focus_lens, [2, 0, 1, 0, 1])
        s1_encoded = '{"steps":[' + json.dumps(plan_payload["steps"][1])
        self.assertEqual(first_step(s1_encoded, sink_parts)["title"], "ჩადგი ვედრო სიფონის ქვეშ")
        s2_encoded = '{"steps":[' + json.dumps(plan_payload["steps"][2])
        self.assertEqual(first_step(s2_encoded, sink_parts)["title"], "მოუშვი ქანჩი")

    def test_pipeline_sink_plausible_resolution_preserves_empty_invisible(self):
        with tempfile.TemporaryDirectory() as d:
            source, dest = Path(d) / "sink.png", Path(d) / "run"
            Image.new("RGB", (100, 100), "white").save(source)
            sink_raw_parts = [
                {"label": "სიფონის ზედა პლასტმასის ქანჩი", "box": [268, 91, 488, 166]},
                {"label": "მარცხენა ჩამკეტი ონკანის სახელური", "box": [12, 257, 88, 320]},
                {"label": "მარჯვენა ჩამკეტი ონკანის სახელური", "box": [221, 261, 293, 326]},
                {"label": "სიფონის მარჯვენა პლასტმასის ქანჩი", "box": [628, 249, 752, 378]},
                {"label": "სიფონის მოხრილი მილი", "box": [307, 248, 650, 493]},
            ]
            parts_payload = {"object": "სიფონი", "parts": sink_raw_parts}
            steps_payload = {
                "steps": [
                    {"title": "დაკეტე წყალი", "text": "დაკეტე ორივე ონკანი", "focus": ["p2", "p3"],
                     "avoid": [], "markers": [], "arrows": [], "tools": [], "warn": None},
                    {"title": "ჩადგი ვედრო სიფონის ქვეშ", "text": "ვედრო დადგი", "focus": [],
                     "avoid": [], "markers": [], "arrows": [], "tools": ["ვედრო"],
                     "warn": "ვედრო სიაში არ არის და უხილავია"},
                    {"title": "მოუშვი ქანჩი", "text": "ეს ქანჩი ჟონავს", "focus": ["p4"],
                     "avoid": [], "markers": [], "arrows": [{"part": "p4", "type": "rotate", "dir": "ccw"}],
                     "tools": ["ხელთათმანი"],
                     "warn": "სავარაუდოდ მარჯვენა ქანჩია p4, თუმცა შესაძლოა p1-ც იყოს (uncertainty)"},
                    {"title": "შეამოწმე შუასადები", "text": "ნახე რეზინის რგოლი", "focus": [],
                     "avoid": [], "markers": [], "arrows": [], "tools": ["შუასადები 40 მმ"],
                     "warn": "შუასადები უხილავია და სიაში არ არის"},
                    {"title": "მოუჭირე და შეამოწმე", "text": "მოუჭირე ხელით", "focus": ["p4"],
                     "avoid": [], "markers": [], "arrows": [{"part": "p4", "type": "rotate", "dir": "cw"}],
                     "tools": [], "warn": "დაშვება p4 ქანჩზე (uncertainty)"},
                ],
                "unknown_parts": ["ვედრო", "შუასადები 40 მმ"],
            }
            captured_prompts = {}
            def create(**kw):
                if kw.get("stream"):
                    captured_prompts["steps"] = kw["input"][0]["content"][0]["text"]
                    return stream_for(steps_payload)
                captured_prompts["parts"] = kw["input"][0]["content"][0]["text"]
                return response(parts_payload)
            client = SimpleNamespace(responses=SimpleNamespace(create=Mock(side_effect=create)))
            sink_truth = {
                "design_size": [1000, 1000],
                "parts": [{"name": p["label"], "path": "M0 0 Z"} for p in sink_raw_parts],
                "steps": [{"title": s["title"], "text": s["text"]} for s in steps_payload["steps"]],
            }
            result = process_c(client, "gpt-6-astra", source, sink_truth, dest, "cpu", "minimal",
                               768, "clean", 42, Budget(2), {}, Mock(side_effect=sam_for_boxes))
            self.assertIn("plausible კანდიდატია", captured_prompts["steps"])
            self.assertIn("uncertainty", captured_prompts["steps"])
            plan = json.loads((dest / "plan.json").read_text())
            self.assertEqual([len(s["focus"]) for s in plan["steps"]], [2, 0, 1, 0, 1])
            self.assertEqual(plan["steps"][2]["focus"], ["p4"])
            self.assertEqual(plan["steps"][1]["focus"], [])
            self.assertTrue((dest / "step_1.png").exists())
            self.assertTrue((dest / "step_2.png").exists())
            self.assertTrue((dest / "step_3.png").exists())


if __name__ == "__main__":
    unittest.main()
