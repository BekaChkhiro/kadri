import json
from pathlib import Path
import tempfile
import unittest

from realism_report import (
    EXPECTED_KINDS,
    EXPECTED_SCENES,
    validate_campaign_plan,
    analyze_realism_metrics,
    calculate_percentiles,
    extract_latency_values,
    generate_markdown_report,
    is_run_cached_or_replay,
    main as cli_main,
    scan_campaign_data,
)


class RealismReportTests(unittest.TestCase):
    def make_run(self, root, campaign="B", scene="sink", photo="p", kind="original", n=1,
                 complete=True, real=False, **files):
        run = root / campaign / scene / photo / kind / f"run_{n}"
        run.mkdir(parents=True, exist_ok=True)
        (run.parent / "transform.json").write_text(json.dumps({"real_photo": real}))
        files["complete"] = {"complete": complete}
        for name, data in files.items():
            (run / f"{name}.json").write_text(json.dumps(data))
        return run

    def test_campaign_photo_denominators_and_original_repeats(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_run(root, n=1)
            self.make_run(root, n=2)
            self.make_run(root, campaign="C", complete=False)
            self.make_run(root, campaign="C", photo="second")
            report = analyze_realism_metrics(scan_campaign_data(root))
            self.assertEqual(report["denominators"]["expected_total_trials"], 28)
            self.assertEqual(report["denominators"]["missing_trials_count"], 24)
            self.assertEqual(len(report["original_repeats"]), 4)
            self.assertEqual(len(report["scene_kind"]), 18)
            self.assertEqual(sum(r["denominators"]["expected_total_trials"] for r in report["scene_kind"]), 28)

    def test_explicit_scope_pilot_tracking_and_full_campaign(self):
        for scenes, kinds, expected in [
            (["sink"], ["original"], 1),
            (list(EXPECTED_SCENES), ["original", "shift_left", "shift_right"], 21),
            (list(EXPECTED_SCENES), list(EXPECTED_KINDS), 63),
        ]:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self.make_run(root)
                plan = {"B": {"scenes": scenes, "kinds": kinds, "runs": 1}}
                report = analyze_realism_metrics(scan_campaign_data(root), campaign_plan=plan)
                d = report["denominators"]
                self.assertEqual(d["scope"], "planned")
                self.assertEqual(d["expected_total_trials"], expected)
                self.assertEqual(d["missing_trials_count"], expected - 1)
                self.assertEqual(len(report["scene_kind"]), expected)
                self.assertEqual(sum(r["denominators"]["expected_total_trials"] for r in report["scene_kind"]), expected)
                self.assertEqual(report["campaign_configurations"][0]["denominators"], d)

    def test_explicit_scope_missing_campaign_and_excess_do_not_hide_gaps(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_run(root)
            self.make_run(root, n=2)
            self.make_run(root, campaign="unplanned")
            plan = {"B": {"scenes": ["sink"], "kinds": ["original", "jpeg"], "runs": 1},
                    "future": {"scenes": ["gym"], "kinds": ["original"], "runs": 2}}
            report = analyze_realism_metrics(scan_campaign_data(root), campaign_plan=plan)
            d = report["denominators"]
            self.assertEqual(d["expected_total_trials"], 4)
            self.assertEqual(d["missing_trials_count"], 3)
            self.assertEqual(d["excess_runs_count"], 1)
            self.assertEqual(d["out_of_scope_runs_count"], 1)
            self.assertEqual(len(report["scene_kind"]), 3)

    def test_incomplete_is_unverified_until_failure_artifact_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pending = self.make_run(root, complete=False)
            self.make_run(root, kind="jpeg", complete=False, error={"type": "ValueError"})
            nested = self.make_run(root, kind="lowres", complete=False)
            (nested / "parts_request").mkdir()
            (nested / "parts_request/request_error.json").write_text('{"error": "timeout"}')
            self.make_run(root, kind="dark_noise", error={"type": "stale"})
            scanned = scan_campaign_data(root)
            d = analyze_realism_metrics(scanned)["denominators"]
            self.assertEqual(d["complete_runs_count"], 1)
            self.assertEqual(d["failed_runs_count"], 2)
            self.assertEqual(d["incomplete_unverified_runs_count"], 1)
            self.assertEqual(d["missing_trials_count"], 5)
            (pending / "complete.json").unlink()
            d = analyze_realism_metrics(scan_campaign_data(root))["denominators"]
            self.assertEqual(d["incomplete_unverified_runs_count"], 1)

    def test_plan_cli_and_zero_complete_do_not_claim_tariff_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = root / "plan.json"
            plan.write_text(json.dumps({"pilot": {"scenes": ["sink"], "kinds": ["original"], "runs": 1}}))
            output = root / "report.md"
            self.assertEqual(cli_main(["--root", str(root / "missing"), "--out", str(output),
                                       "--campaign-plan", str(plan)]), 0)
            report = json.loads(output.with_suffix(".json").read_text())
            self.assertEqual(report["denominators"]["expected_total_trials"], 1)
            self.assertIn("planned scope", output.read_text())
            self.assertNotIn("დაბლოკილია", output.read_text())
            cli_main(["--root", str(root / "missing"), "--out", str(output)])
            self.assertIn("universal reference scope", output.read_text())

    def test_invalid_campaign_plan_is_rejected(self):
        for scope in ({}, {"scenes": ["sink"], "kinds": ["original"], "runs": True},
                      {"scenes": ["sink"], "kinds": ["typo"], "runs": 1},
                      {"scenes": ["sink", "sink"], "kinds": ["original"], "runs": 1}):
            with self.subTest(scope=scope), self.assertRaises(ValueError):
                validate_campaign_plan({"B": scope})

    def test_plan_empty_focus_counts_and_real_proxy_exclusion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = {"steps": [{"focus": []}, {"focus": ["p1"]}]}
            proxy = {"steps": [{"focus_full_iou": 1, "focus_visible_iou": 1}]}
            self.make_run(root, real=True, plan=plan, proxy=proxy)
            self.make_run(root, kind="jpeg", complete=False, plan=plan, proxy=proxy)
            report = analyze_realism_metrics(scan_campaign_data(root))
            self.assertEqual(report["step_counts"]["mean"], 2)
            self.assertEqual(report["proxy_iou"]["empty_focus_fraction"], .5)
            self.assertEqual(report["proxy_iou"]["empty_focus_denominator"], 2)
            self.assertEqual(report["proxy_iou"]["focus_full_iou"]["n"], 0)

    def test_latency_contract_does_not_substitute_stage_first_step(self):
        values = extract_latency_values({"first_box_model_only_seconds": 4,
            "preflight_seconds": 1, "real_wall_time_to_first_box_seconds": 5,
            "time_to_first_outline_seconds": 7, "time_to_first_step_seconds": 2,
            "time_to_first_step_from_start_seconds": 9, "total_seconds": 10})
        self.assertEqual(values["model_only_seconds"], 4)
        self.assertEqual(values["first_box_realwall_seconds"], 5)
        self.assertEqual(values["first_step_start_seconds"], 9)
        missing = extract_latency_values({"time_to_first_step_seconds": 2})
        self.assertIsNone(missing["first_step_start_seconds"])
        self.assertIsNone(missing["total_seconds"])
        self.assertEqual(extract_latency_values({"adapter_wall_seconds": 8})["total_seconds"], 8)

    def test_matching_raw_equality_and_empty_baseline_unavailable(self):
        data = {"summary_comparisons": [{"results": [
            {"threshold": .5, "matches": [{"raw_id_equal": False, "raw_label_equal": True}], "dropout": [1]},
            {"threshold": .75, "matches": [], "dropout": []}]}]}
        sweep = analyze_realism_metrics(data)["matching_stability"]["sweep_results"]
        self.assertEqual(sweep["0.5"]["mean_retention"], .5)
        self.assertEqual(sweep["0.5"]["mean_dropout"], .5)
        self.assertEqual(sweep["0.5"]["mean_raw_id_stability"], 0)
        self.assertEqual(sweep["0.5"]["mean_raw_label_stability"], 1)
        self.assertIsNone(sweep["0.75"]["mean_retention"])

    def test_nearzero_and_resumed_timing_excluded_even_with_response(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_run(root, latency={"model_only_seconds": 0, "total_seconds": 2}, budget_response={"id": "old"})
            self.make_run(root, kind="jpeg", latency={"total_seconds": 5, "partial_recovery": True})
            self.make_run(root, kind="lowres")
            report = analyze_realism_metrics(scan_campaign_data(root))
            self.assertEqual(report["latency"]["new_api_samples"], 0)
            self.assertEqual(report["latency"]["cached_or_replayed_samples"], 2)
            self.assertIsNone(report["latency"]["new_api_metrics"]["total_seconds"]["p50"])

    def test_count_allowance_dedup_is_not_generation_or_billing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / "budget.json"
            ledger.write_text(json.dumps({"requests": {
                "a:count": {"state": "settled", "usd": .1},
                "b:count": {"state": "reserved", "usd": .2},
                "a:create": {"state": "settled", "usd": .3},
                "b:create": {"state": "reserved", "usd": .4}}}))
            for campaign in ("B", "C"):
                self.make_run(root, campaign=campaign, runner_config={"ledger": str(ledger)},
                              budget_cost={"usd_upper_estimate": 999})
            costs = analyze_realism_metrics(scan_campaign_data(root))["costs"]
            self.assertEqual(len(costs["ledgers"]), 1)
            self.assertEqual(costs["count_allowance"]["settled_usd"], .1)
            self.assertEqual(costs["count_allowance"]["reserved_usd"], .2)
            self.assertEqual(costs["total_settled_usd"], .3)
            self.assertEqual(costs["total_reserved_usd"], .4)
            self.assertIsNone(costs["actual_billed_usd"])

    def test_all_63_prepared_frames_are_not_api_results(self):
        from realism_report import EXPECTED_SCENES
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for scene in EXPECTED_SCENES:
                for kind in EXPECTED_KINDS:
                    frame = root / "baseline" / scene / "photo" / kind
                    frame.mkdir(parents=True)
                    (frame / "transform.json").write_text("{}")
            report = analyze_realism_metrics(scan_campaign_data(root))
            self.assertEqual(report["denominators"]["expected_total_trials"], 63)
            self.assertEqual(report["denominators"]["missing_trials_count"], 63)
            self.assertEqual(report["denominators"]["complete_runs_count"], 0)
            self.assertTrue(report["status"]["is_dry_run_only"])
            self.assertFalse(report["status"]["has_paid_runs"])
            self.assertIsNone(report["proxy_iou"]["empty_focus_fraction"])

    def test_default_json_and_relative_visual_links_outside_report_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "inputs"
            run = self.make_run(root, runner_config={"variant": "C", "model": "m", "effort": "low", "max_side": 768})
            (run / "parts.png").write_bytes(b"fixture only, not visually reviewed")
            output = Path(tmp) / "reports" / "REALISM.md"
            cli_main(["--root", str(root), "--out", str(output)])
            report = json.loads(output.with_suffix(".json").read_text())
            self.assertEqual(report["campaign_configurations"][0]["configurations"][0]["variant"], "C")
            md = output.read_text()
            self.assertIn("../inputs/", md)
            self.assertNotIn(str(root), md)
            self.assertIn("ხელით შესაფასებელი", md)

    def test_percentiles_calculation(self):
        # Empty values
        p_empty = calculate_percentiles([])
        self.assertEqual(p_empty["n"], 0)
        self.assertIsNone(p_empty["p50"])
        self.assertIsNone(p_empty["p90"])

        # None and NaN filtering
        p_filtered = calculate_percentiles([10.0, None, float("nan"), 20.0, 30.0])
        self.assertEqual(p_filtered["n"], 3)
        self.assertAlmostEqual(p_filtered["p50"], 20.0)
        self.assertAlmostEqual(p_filtered["p90"], 28.0)
        self.assertAlmostEqual(p_filtered["mean"], 20.0)

    def test_mixed_success_failure_and_missing_denominators(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir) / "out_realism"
            camp = root / "campaign_a"

            # Create prepared frames for scene_1 with 2 kinds
            frame_orig = camp / "scene_1" / "photo_1" / "original"
            frame_orig.mkdir(parents=True, exist_ok=True)
            (frame_orig / "transform.json").write_text(json.dumps({"kind": "original"}))

            # Run 1: completed
            run_1 = frame_orig / "run_1"
            run_1.mkdir(parents=True, exist_ok=True)
            (run_1 / "complete.json").write_text(json.dumps({"complete": True}))
            (run_1 / "runner_config.json").write_text(json.dumps({"model": "gpt-6-astra"}))
            (run_1 / "latency.json").write_text(json.dumps({"first_box_full_response_seconds": 15.2, "sam_seconds": 1.8}))

            # Explicit error artifact confirms failure; complete:false alone does not.
            frame_dark = camp / "scene_1" / "photo_1" / "dark_noise"
            frame_dark.mkdir(parents=True, exist_ok=True)
            (frame_dark / "transform.json").write_text(json.dumps({"kind": "dark_noise"}))
            run_failed = frame_dark / "run_1"
            run_failed.mkdir(parents=True, exist_ok=True)
            (run_failed / "complete.json").write_text(json.dumps({"complete": False}))
            (run_failed / "error.json").write_text(json.dumps({"type": "RuntimeError"}))

            # Create third kind: lowres with dry-run only (no run directory)
            frame_dry = camp / "scene_1" / "photo_1" / "lowres"
            frame_dry.mkdir(parents=True, exist_ok=True)
            (frame_dry / "transform.json").write_text(json.dumps({"kind": "lowres"}))

            scanned = scan_campaign_data(root)
            metrics = analyze_realism_metrics(scanned)
            denoms = metrics["denominators"]

            self.assertEqual(denoms["prepared_frames_count"], 3)
            self.assertEqual(denoms["complete_runs_count"], 1)
            self.assertEqual(denoms["failed_runs_count"], 1)
            self.assertEqual(denoms["dry_run_only_frames_count"], 1)
            # 1 scene * 9 expected kinds * 1 run = 9 expected
            self.assertEqual(denoms["expected_total_trials"], 9)
            # missing = 9 - 1 (complete) - 1 (failed) = 7
            self.assertEqual(denoms["missing_trials_count"], 7)

    def test_empty_focus_and_avoid_separation(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir) / "out_realism"
            run_dir = root / "camp" / "scene_1" / "p1" / "original" / "run_1"
            run_dir.mkdir(parents=True, exist_ok=True)
            (run_dir.parent / "transform.json").write_text(json.dumps({"kind": "original"}))
            (run_dir / "complete.json").write_text(json.dumps({"complete": True}))

            # Step 1: focus IoU=0.8, avoid is empty (should not dilute focus)
            # Step 2: focus is empty (focus_empty=True), avoid has IoU=0.5
            # Step 3: focus IoU=0.6, avoid IoU=0.9
            proxy_data = {
                "metric": "Design geometry proxy only; NOT real semantic validation",
                "steps": [
                    {"focus_empty": False, "focus_full_iou": 0.8, "focus_visible_iou": 0.7, "avoid_full_iou": 1.0, "avoid_empty": True},
                    {"focus_full_iou": 0.0, "focus_visible_iou": 0.0, "focus_empty": True, "avoid_full_iou": 0.5, "avoid_visible_iou": 0.5},
                    {"focus_empty": False, "focus_full_iou": 0.6, "focus_visible_iou": 0.5, "avoid_full_iou": 0.9, "avoid_visible_iou": 0.9},
                ],
            }
            (run_dir / "proxy.json").write_text(json.dumps(proxy_data))

            scanned = scan_campaign_data(root)
            metrics = analyze_realism_metrics(scanned)
            proxy_res = metrics["proxy_iou"]

            # Focus full iou should have values [0.8, 0.0, 0.6] -> mean = (0.8 + 0.0 + 0.6) / 3 = 0.4667
            self.assertAlmostEqual(proxy_res["focus_full_iou"]["mean"], 0.466666, places=4)
            self.assertEqual(proxy_res["total_steps"], 3)
            self.assertEqual(proxy_res["empty_focus_steps"], 1)
            self.assertAlmostEqual(proxy_res["empty_focus_fraction"], 1 / 3)

            # Avoid full iou should EXCLUDE empty avoid (step 1), taking only step 2 and step 3: [0.5, 0.9] -> mean = 0.7
            self.assertEqual(proxy_res["empty_avoid_steps"], 1)
            self.assertEqual(proxy_res["avoid_full_iou"]["n"], 2)
            self.assertAlmostEqual(proxy_res["avoid_full_iou"]["mean"], 0.7)

    def test_cost_deduplication_and_settled_vs_reserved(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir) / "out_realism"
            ledger_file = Path(tmp_dir) / "shared_budget.json"
            ledger_content = {
                "limit": 15.0,
                "requests": {
                    "req_1": {"state": "settled", "usd": 0.35},
                    "req_2": {"state": "settled", "usd": 0.25},
                    "req_3": {"state": "reserved", "usd": 10.0},
                },
            }
            ledger_file.write_text(json.dumps(ledger_content))

            # Create two different runs in different campaigns pointing to the EXACT same ledger
            for camp in ("camp_1", "camp_2"):
                run_dir = root / camp / "scene_1" / "p1" / "original" / "run_1"
                run_dir.mkdir(parents=True, exist_ok=True)
                (run_dir.parent / "transform.json").write_text(json.dumps({"kind": "original"}))
                (run_dir / "runner_config.json").write_text(json.dumps({"ledger": str(ledger_file)}))
                (run_dir / "complete.json").write_text(json.dumps({"complete": True}))

            scanned = scan_campaign_data(root)
            metrics = analyze_realism_metrics(scanned)
            costs = metrics["costs"]

            # Deduplication: ledger must be counted only ONCE
            self.assertEqual(len(costs["ledgers"]), 1)
            # Settled fee is only settled requests: 0.35 + 0.25 = 0.60
            self.assertAlmostEqual(costs["total_settled_usd"], 0.60)
            self.assertEqual(costs["total_settled_count"], 2)
            # Reserved allowance is not billed fee: 10.0
            self.assertAlmostEqual(costs["total_reserved_usd"], 10.0)
            self.assertEqual(costs["total_reserved_count"], 1)

    def test_latency_sample_exclusions_replay_and_cached(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir) / "out_realism"
            camp = root / "campaign"

            # 1. Valid new API run
            r1 = camp / "scene" / "photo" / "original" / "run_1"
            r1.mkdir(parents=True, exist_ok=True)
            (r1.parent / "transform.json").write_text(json.dumps({"kind": "original"}))
            (r1 / "complete.json").write_text(json.dumps({"complete": True}))
            (r1 / "latency.json").write_text(json.dumps({"first_box_full_response_seconds": 25.0, "sam_seconds": 3.0}))

            # 2. Cached run with cached flag
            r2 = camp / "scene" / "photo" / "dark_noise" / "run_1"
            r2.mkdir(parents=True, exist_ok=True)
            (r2.parent / "transform.json").write_text(json.dumps({"kind": "dark_noise"}))
            (r2 / "complete.json").write_text(json.dumps({"complete": True}))
            (r2 / "latency.json").write_text(json.dumps({"cached": True, "first_box_full_response_seconds": 0.001, "sam_seconds": 2.5}))

            # 3. Replay run with is_replay flag
            r3 = camp / "scene" / "photo" / "lowres" / "run_1"
            r3.mkdir(parents=True, exist_ok=True)
            (r3.parent / "transform.json").write_text(json.dumps({"kind": "lowres"}))
            (r3 / "complete.json").write_text(json.dumps({"complete": True}))
            (r3 / "latency.json").write_text(json.dumps({"is_replay": True, "first_box_full_response_seconds": 0.002, "sam_seconds": 2.5}))

            # 4. Resumed run in runner_config without budget_response
            r4 = camp / "scene" / "photo" / "jpeg" / "run_1"
            r4.mkdir(parents=True, exist_ok=True)
            (r4.parent / "transform.json").write_text(json.dumps({"kind": "jpeg"}))
            (r4 / "complete.json").write_text(json.dumps({"complete": True}))
            (r4 / "plan.json").write_text(json.dumps({"parts": []}))
            (r4 / "runner_config.json").write_text(json.dumps({"resume": True}))
            (r4 / "latency.json").write_text(json.dumps({"first_box_full_response_seconds": 0.001, "sam_seconds": 1.0}))

            scanned = scan_campaign_data(root)
            metrics = analyze_realism_metrics(scanned)
            lat = metrics["latency"]

            # Only 1 new API sample
            self.assertEqual(lat["new_api_samples"], 1)
            self.assertEqual(lat["new_api_metrics"]["first_box_full_response_seconds"]["n"], 1)
            self.assertAlmostEqual(lat["new_api_metrics"]["first_box_full_response_seconds"]["p50"], 25.0)

            # 3 cached / replayed / resumed samples excluded from new API timing
            self.assertEqual(lat["cached_or_replayed_samples"], 3)
            self.assertEqual(lat["cached_metrics"]["first_box_full_response_seconds"]["n"], 3)

    def test_matching_stability_sweep_from_summary(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir) / "out_realism"
            root.mkdir(parents=True, exist_ok=True)
            summary_path = root / "summary.json"
            summary_content = {
                "comparisons": [
                    {
                        "baseline": "b/run_1/plan.json",
                        "current": "c/run_1/plan.json",
                        "results": [
                            {"threshold": 0.25, "matches": [1, 2], "dropout": [], "raw_id_stability": 1.0, "raw_label_stability": 1.0},
                            {"threshold": 0.5, "matches": [1], "dropout": [2], "raw_id_stability": 0.5, "raw_label_stability": 1.0},
                            {"threshold": 0.75, "matches": [], "dropout": [1, 2], "raw_id_stability": 0.0, "raw_label_stability": 0.0},
                        ],
                    }
                ]
            }
            summary_path.write_text(json.dumps(summary_content))

            scanned = scan_campaign_data(root)
            metrics = analyze_realism_metrics(scanned)
            sweep = metrics["matching_stability"]["sweep_results"]

            self.assertAlmostEqual(sweep["0.25"]["mean_retention"], 1.0)
            self.assertAlmostEqual(sweep["0.5"]["mean_retention"], 0.5)
            self.assertAlmostEqual(sweep["0.75"]["mean_retention"], 0.0)
            self.assertAlmostEqual(sweep["0.25"]["mean_raw_id_stability"], 1.0)
            self.assertAlmostEqual(sweep["0.5"]["mean_raw_id_stability"], 0.5)

    def test_cli_execution_and_markdown_warnings(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            root = tmp / "out_realism"
            out_md = tmp / "REALISM.md"
            out_json = tmp / "report.json"

            # Create minimal fixture
            frame_dir = root / "camp" / "sink" / "sink-trap" / "original"
            frame_dir.mkdir(parents=True, exist_ok=True)
            (frame_dir / "transform.json").write_text(json.dumps({"kind": "original"}))
            (frame_dir / "image.png").write_bytes(b"fake_image")
            run_1 = frame_dir / "run_1"
            run_1.mkdir(parents=True, exist_ok=True)
            (run_1 / "complete.json").write_text(json.dumps({"complete": True}))
            (run_1 / "parts.png").write_bytes(b"fake_parts_png")

            code = cli_main(["--root", str(root), "--out", str(out_md), "--json", str(out_json)])
            self.assertEqual(code, 0)
            self.assertTrue(out_md.exists())
            self.assertTrue(out_json.exists())

            content = out_md.read_text(encoding="utf-8")
            # Verify required warnings and Georgian structure
            self.assertIn("# რეალისტურობის ტესტის შეფასების ანგარიში", content)
            self.assertIn("ფასიანი API გაშვებები არსებული ჩანაწერებით არ დასტურდება", content)
            self.assertIn("არ არის მზად რეალური გარემოსთვის", content)
            self.assertIn("Design geometry proxy only", content)
            self.assertIn("NOT semantic accuracy", content)
            self.assertIn("სინთეზური სტრეს-ტესტები არ უდრის რეალური ფოტოებით ვალიდაციას", content)
            self.assertIn("არა ფაქტობრივი გადასახადი", content)
            self.assertIn("Reserved Allowance", content)
            self.assertIn("parts.png", content)


if __name__ == "__main__":
    unittest.main()
