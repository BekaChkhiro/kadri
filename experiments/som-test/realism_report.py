"""Offline JSON and Markdown report generator for SOM realism experiments.

Consolidates metrics from out_realism/<campaign>/<scene>/<photo>/<kind>/run_N/
including plan.json, proxy.json, latency.json, budget_cost.json, complete.json,
runner_config.json, and parent transform.json metadata.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from urllib.parse import quote
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

import numpy as np

EXPECTED_SCENES = ("sink", "gym", "car", "chemistry", "microscope", "psychology", "laundry")

EXPECTED_KINDS = (
    "original",
    "dark_noise",
    "motion_blur",
    "tilt_crop",
    "lowres",
    "jpeg",
    "occlusion",
    "shift_left",
    "shift_right",
)

LATENCY_FIELDS = (
    ("first_box_full_response_seconds", "პირველი box (სრული პასუხი)"),
    ("first_box_realwall_seconds", "პირველი box (რეალური wall დრო)"),
    ("model_only_seconds", "მოდელი (მხოლოდ API)"),
    ("preflight_seconds", "Preflight"),
    ("outline_seconds", "პირველი კონტური (Outline)"),
    ("first_step_start_seconds", "პირველი ნაბიჯი გაშვების დასაწყისიდან"),
    ("sam_seconds", "SAM სეგმენტაცია"),
    ("total_seconds", "სრული დრო (Total Wall)"),
)


def load_json(path: Path) -> Optional[dict]:
    try:
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        pass
    return None


def calculate_percentiles(values: Sequence[float]) -> dict:
    valid = [float(v) for v in values if v is not None and math.isfinite(v)]
    if not valid:
        return {"n": 0, "p50": None, "p90": None, "mean": None, "min": None, "max": None}
    arr = np.asarray(valid, dtype=float)
    return {
        "n": len(valid),
        "p50": float(np.percentile(arr, 50)),
        "p90": float(np.percentile(arr, 90)),
        "mean": float(np.mean(arr)),
        "min": float(np.min(arr)),
        "max": float(np.max(arr)),
    }


def is_run_cached_or_replay(run_dir: Path, latency_data: dict, runner_config: dict) -> bool:
    """Robust detection of cached, replayed, or resumed records across schema variations."""
    for record in (latency_data, runner_config):
        for key in ("cached", "replay", "resumed", "is_cached", "is_replay", "is_resumed", "from_cache", "partial_recovery"):
            if str(record.get(key, "")).lower() in ("true", "1", "yes"):
                return True
        if record.get("source") in ("cache", "replay", "disk"):
            return True
    if runner_config.get("resume") and not (run_dir / "budget_response.json").exists():
        return True
    for key in ("model_only_seconds", "first_box_model_only_seconds", "first_box_full_response_seconds", "adapter_wall_seconds", "total_seconds"):
        value = latency_data.get(key)
        if isinstance(value, (int, float)) and 0 <= value < 0.01:
            return True

    return False


def extract_latency_values(latency_data: dict) -> dict:
    """Extract standard latency metrics mapping alternative keys."""
    res = {"first_box_realwall_seconds": latency_data.get("first_box_realwall_seconds", latency_data.get("real_wall_time_to_first_box_seconds"))}
    # 1. first box full response
    res["first_box_full_response_seconds"] = latency_data.get("first_box_full_response_seconds")

    # 2. model-only seconds
    model_sec = latency_data.get("model_only_seconds", latency_data.get("first_box_model_only_seconds"))
    if model_sec is None:
        model_sec = latency_data.get("model_seconds", latency_data.get("api_seconds"))
    res["model_only_seconds"] = model_sec

    # 3. preflight seconds
    res["preflight_seconds"] = latency_data.get("preflight_seconds")

    # 4. outline seconds
    outline_sec = latency_data.get("outline_seconds")
    if outline_sec is None:
        outline_sec = latency_data.get("time_to_first_outline_seconds")
    res["outline_seconds"] = outline_sec

    # 5. first step start
    first_step = latency_data.get("first_step_start_seconds")
    if first_step is None:
        first_step = latency_data.get("first_step_from_start_seconds", latency_data.get("time_to_first_step_from_start_seconds"))
    res["first_step_start_seconds"] = first_step

    # 6. SAM seconds
    res["sam_seconds"] = latency_data.get("sam_seconds")

    # 7. Total seconds
    total_sec = latency_data.get("total_seconds")
    if total_sec is None:
        total_sec = latency_data.get("total_wall_seconds", latency_data.get("adapter_wall_seconds"))
    res["total_seconds"] = total_sec

    return res


def scan_campaign_data(root: Path) -> dict:
    """Scan root directory for campaigns, prepared frames, runs, and ledgers."""
    root = Path(root).resolve()
    if not root.exists():
        return {
            "root": str(root),
            "campaigns": {},
            "all_runs": [],
            "prepared_frames": [],
            "ledgers": {},
            "summary_comparisons": [],
        }

    # Locate transform.json files to discover frames: <scene>/<photo>/<kind>/transform.json
    # Could be nested under root/<campaign>/<scene>/<photo>/<kind>/ or root/<scene>/<photo>/<kind>/
    transform_files = sorted(root.glob("**/transform.json"))

    campaigns: Dict[str, Dict[str, Any]] = {}
    prepared_frames: List[dict] = []
    all_runs: List[dict] = []
    visited_ledger_paths: Set[str] = set()
    ledgers: Dict[str, dict] = {}
    summary_comparisons: List[dict] = []

    # Also search for summary.json files
    for summary_path in sorted(root.glob("**/summary.json")):
        s_data = load_json(summary_path)
        if s_data and "comparisons" in s_data:
            summary_comparisons.extend({**row, "summary_path": str(summary_path.relative_to(root))} for row in s_data["comparisons"])

    for trans_path in transform_files:
        kind_dir = trans_path.parent
        photo_dir = kind_dir.parent
        scene_dir = photo_dir.parent
        campaign_dir = scene_dir.parent

        kind_name = kind_dir.name
        photo_name = photo_dir.name
        scene_name = scene_dir.name

        if campaign_dir == root or campaign_dir == root.parent:
            campaign_name = campaign_dir.name
        elif root in campaign_dir.parents:
            # relative campaign path under root
            campaign_name = campaign_dir.relative_to(root).parts[0]
        else:
            campaign_name = campaign_dir.name

        transform_meta = load_json(trans_path) or {}
        truth_data = load_json(kind_dir / "truth.json")
        has_image = (kind_dir / "image.png").exists()
        has_truth_masks = (kind_dir / "truth_masks.npz").exists()

        frame_info = {
            "campaign": campaign_name,
            "scene": scene_name,
            "photo": photo_name,
            "kind": kind_name,
            "frame_dir": str(kind_dir),
            "transform": transform_meta,
            "has_image": has_image,
            "has_truth": bool(truth_data),
            "has_truth_masks": has_truth_masks,
        }
        prepared_frames.append(frame_info)

        # Look for run directories inside kind_dir: run_*
        run_dirs = sorted([d for d in kind_dir.glob("run_*") if d.is_dir()])
        for r_dir in run_dirs:
            complete_data = load_json(r_dir / "complete.json")
            runner_config = load_json(r_dir / "runner_config.json") or {}
            latency_data = load_json(r_dir / "latency.json") or {}
            proxy_data = load_json(r_dir / "proxy.json") or {}
            plan_data = load_json(r_dir / "plan.json") or {}
            budget_cost = load_json(r_dir / "budget_cost.json") or {}

            # Ledger discovery
            ledger_spec = runner_config.get("ledger")
            if ledger_spec:
                ledger_path = Path(ledger_spec)
                if not ledger_path.is_absolute():
                    ledger_path = (r_dir / ledger_path).resolve()
                ledger_path = ledger_path.resolve()
                if ledger_path.is_file() and str(ledger_path) not in visited_ledger_paths:
                    visited_ledger_paths.add(str(ledger_path))
                    ledgers[str(ledger_path)] = load_json(ledger_path) or {}

            # Real unannotated photos never acquire a design proxy from stale files.
            if transform_meta.get("real_photo") or transform_meta.get("proxy_available") is False:
                proxy_data = {"available": False, "steps": []}
            for index, step in enumerate(proxy_data.get("steps", [])):
                plan_steps = plan_data.get("steps", [])
                truth_steps = (truth_data or {}).get("steps", [])
                if index < len(plan_steps):
                    step["focus_empty"] = not plan_steps[index].get("focus", [])
                if index < len(truth_steps):
                    step["avoid_empty"] = not truth_steps[index].get("avoid", [])
            is_cached = is_run_cached_or_replay(r_dir, latency_data, runner_config)
            is_complete = bool(complete_data and complete_data.get("complete", False))

            parts_png = r_dir / "parts.png"

            run_entry = {
                "campaign": campaign_name,
                "scene": scene_name,
                "photo": photo_name,
                "kind": kind_name,
                "frame_dir": str(kind_dir),
                "run_name": r_dir.name,
                "run_dir": str(r_dir),
                "complete": is_complete,
                "runner_config": runner_config,
                "latency_raw": latency_data,
                "latency": extract_latency_values(latency_data),
                "is_cached_or_replay": is_cached,
                "proxy": proxy_data,
                "transform": transform_meta,
                "plan": plan_data,
                "budget_cost": budget_cost,
                "has_parts_png": parts_png.is_file(),
                "parts_png_path": str(parts_png) if parts_png.is_file() else None,
            }
            all_runs.append(run_entry)

    # Check for root/campaign-level budget.json ledgers as well
    for b_path in sorted(root.glob("**/budget.json")):
        b_resolved = str(b_path.resolve())
        if b_resolved not in visited_ledger_paths:
            visited_ledger_paths.add(b_resolved)
            ledgers[b_resolved] = load_json(b_path) or {}

    return {
        "root": str(root),
        "prepared_frames": prepared_frames,
        "all_runs": all_runs,
        "ledgers": ledgers,
        "summary_comparisons": summary_comparisons,
    }


def analyze_realism_metrics(data: dict, grouped: bool = True) -> dict:
    """Compute consolidated statistics and tables from scanned data."""
    prepared_frames: List[dict] = data.get("prepared_frames", [])
    all_runs: List[dict] = data.get("all_runs", [])
    ledgers: Dict[str, dict] = data.get("ledgers", {})
    comparisons: List[dict] = data.get("summary_comparisons", [])

    # 1. Campaigns & Config Overview
    scenes_seen: Set[str] = set()
    kinds_seen: Set[str] = set()
    campaigns_seen: Set[str] = set()
    models_seen: Set[str] = set()
    efforts_seen: Set[str] = set()
    maxsides_seen: Set[str] = set()
    variants_seen: Set[str] = set()

    for f in prepared_frames:
        scenes_seen.add(f["scene"])
        kinds_seen.add(f["kind"])
        campaigns_seen.add(f["campaign"])

    for r in all_runs:
        scenes_seen.add(r["scene"])
        kinds_seen.add(r["kind"])
        campaigns_seen.add(r["campaign"])
        cfg = r.get("runner_config", {})
        if cfg.get("model"):
            models_seen.add(str(cfg["model"]))
        if cfg.get("reasoning_effort"):
            efforts_seen.add(str(cfg["reasoning_effort"]))
        if cfg.get("effort"):
            efforts_seen.add(str(cfg["effort"]))
        if cfg.get("max_side"):
            maxsides_seen.add(str(cfg["max_side"]))
        if cfg.get("variant"):
            variants_seen.add(str(cfg["variant"]))

    # 2. Denominators (Expected, Prepared, Complete, Failed, Missing)
    # Expected modes: 9 per scene
    # Each campaign/photo has its own mode/run grid; observed original repeats
    # are additional trials, never multiplied across every degradation.
    photo_groups = {(f["campaign"], f["scene"], f["photo"]) for f in prepared_frames}
    expected_total_trials = 0
    for group in photo_groups:
        rows = [r for r in all_runs if (r["campaign"], r["scene"], r["photo"]) == group]
        repeat_count = max([int(r.get("runner_config", {}).get("runs", 1)) for r in rows] or [1])
        for kind in EXPECTED_KINDS:
            observed = [r for r in rows if r["kind"] == kind]
            expected_total_trials += max([repeat_count] + [int(r["run_name"].removeprefix("run_")) for r in observed if r["run_name"].removeprefix("run_").isdigit()])
    prepared_frames_count = len(prepared_frames)

    complete_runs_count = sum(1 for r in all_runs if r["complete"])
    failed_runs_count = sum(1 for r in all_runs if not r["complete"])
    # If a prepared frame has no run at all (dry run), it's missing execution
    dry_run_only_frames_count = sum(
        1 for f in prepared_frames if not any(r["frame_dir"] == f["frame_dir"] for r in all_runs)
    )
    missing_trials_count = max(0, expected_total_trials - complete_runs_count - failed_runs_count)

    # 3. Step Focus and Avoid IoU (Proxy Geometry, NOT Semantic Accuracy)
    # Focus and Avoid are strictly decoupled: empty avoid does not dilute focus IoU.
    focus_full_ious: List[float] = []
    focus_visible_ious: List[float] = []
    avoid_full_ious: List[float] = []
    avoid_visible_ious: List[float] = []

    total_steps_count = 0
    empty_avoid_steps_count = 0

    for r in all_runs:
        proxy = r.get("proxy", {}) if r["complete"] else {}
        steps = proxy.get("steps", [])
        for s in steps:
            total_steps_count += 1
            # Focus full & visible
            ff = s.get("focus_full_iou")
            fv = s.get("focus_visible_iou")
            if ff is not None and math.isfinite(ff):
                focus_full_ious.append(float(ff))
            if fv is not None and math.isfinite(fv):
                focus_visible_ious.append(float(fv))

            # Avoid full & visible (only if non-empty target was evaluated)
            af = s.get("avoid_full_iou")
            av = s.get("avoid_visible_iou")
            # If s indicates whether avoid target was empty
            is_avoid_empty = s.get("avoid_empty", False)
            if af is not None and math.isfinite(af) and not is_avoid_empty:
                avoid_full_ious.append(float(af))
            if av is not None and math.isfinite(av) and not is_avoid_empty:
                avoid_visible_ious.append(float(av))

            if is_avoid_empty or s.get("target_avoid_empty"):
                empty_avoid_steps_count += 1

    # 4. Latency Analysis (Separated: New API calls vs Replayed/Cached)
    new_api_latency_pools: Dict[str, List[float]] = {k: [] for k, _ in LATENCY_FIELDS}
    cached_latency_pools: Dict[str, List[float]] = {k: [] for k, _ in LATENCY_FIELDS}

    new_api_count = 0
    cached_count = 0

    for r in all_runs:
        lat = r.get("latency", {})
        if not any(isinstance(v, (int, float)) and math.isfinite(v) for v in lat.values()):
            continue
        is_cached = r.get("is_cached_or_replay", False)
        if is_cached:
            cached_count += 1
            for k, _ in LATENCY_FIELDS:
                v = lat.get(k)
                if v is not None and math.isfinite(v) and v >= 0:
                    cached_latency_pools[k].append(float(v))
        else:
            new_api_count += 1
            for k, _ in LATENCY_FIELDS:
                v = lat.get(k)
                if v is not None and math.isfinite(v) and v >= 0:
                    new_api_latency_pools[k].append(float(v))

    new_api_latency_stats = {
        k: calculate_percentiles(new_api_latency_pools[k]) for k, _ in LATENCY_FIELDS
    }
    cached_latency_stats = {
        k: calculate_percentiles(cached_latency_pools[k]) for k, _ in LATENCY_FIELDS
    }

    # 5. Matching Stability & Association IoU Sweep (.25, .5, .75)
    sweep_thresholds = (0.25, 0.5, 0.75)
    stability_by_thresh: Dict[float, dict] = {
        t: {"retentions": [], "dropouts": [], "raw_id_stabilities": [], "raw_label_stabilities": []}
        for t in sweep_thresholds
    }

    for comp in comparisons:
        results = comp.get("results", [])
        for res in results:
            t = res.get("threshold")
            if t in stability_by_thresh:
                # Retention calculation
                matches = res.get("matches", [])
                dropout = res.get("dropout", [])
                total_prev = len(matches) + len(dropout)
                retention = len(matches) / total_prev if total_prev > 0 else None
                if retention is not None:
                    stability_by_thresh[t]["retentions"].append(retention)
                    stability_by_thresh[t]["dropouts"].append(len(dropout) / total_prev)

                raw_id_s = res.get("raw_id_stability")
                if raw_id_s is None and matches and all(isinstance(m, dict) and "raw_id_equal" in m for m in matches):
                    raw_id_s = sum(m["raw_id_equal"] for m in matches) / len(matches)
                if raw_id_s is not None and math.isfinite(raw_id_s):
                    stability_by_thresh[t]["raw_id_stabilities"].append(float(raw_id_s))

                raw_lbl_s = res.get("raw_label_stability")
                if raw_lbl_s is None and matches and all(isinstance(m, dict) and "raw_label_equal" in m for m in matches):
                    raw_lbl_s = sum(m["raw_label_equal"] for m in matches) / len(matches)
                if raw_lbl_s is not None and math.isfinite(raw_lbl_s):
                    stability_by_thresh[t]["raw_label_stabilities"].append(float(raw_lbl_s))

    stability_summary = {}
    for t in sweep_thresholds:
        entry = stability_by_thresh[t]
        stability_summary[str(t)] = {
            "mean_dropout": float(np.mean(entry["dropouts"])) if entry["dropouts"] else None,
            "mean_retention": float(np.mean(entry["retentions"])) if entry["retentions"] else None,
            "raw_id_n": len(entry["raw_id_stabilities"]),
            "raw_label_n": len(entry["raw_label_stabilities"]),
            "mean_raw_id_stability": float(np.mean(entry["raw_id_stabilities"])) if entry["raw_id_stabilities"] else None,
            "mean_raw_label_stability": float(np.mean(entry["raw_label_stabilities"])) if entry["raw_label_stabilities"] else None,
            "n": len(entry["retentions"]),
        }

    # 6. Budget & Costs (Ledger Deduplication: No Double Counting)
    # A single ledger path may be shared across multiple runs or campaigns.
    ledger_summaries = []
    total_settled_usd = 0.0
    total_reserved_usd = 0.0
    total_settled_count = 0
    total_reserved_count = 0
    count_allowance = {"settled_usd": 0.0, "reserved_usd": 0.0, "settled_count": 0, "reserved_count": 0}

    for l_path, l_data in ledgers.items():
        all_requests = l_data.get("requests", {})
        requests = {}
        for key, row in all_requests.items():
            if key.endswith(":count") or row.get("kind") == "count":
                state = row.get("state")
                if state in ("settled", "reserved"):
                    count_allowance[state + "_usd"] += float(row.get("usd", 0))
                    count_allowance[state + "_count"] += 1
            else:
                requests[key] = row
        limit = l_data.get("limit", 15.0)

        settled_usd = sum(
            float(r.get("usd", 0.0)) for r in requests.values() if r.get("state") == "settled"
        )
        reserved_usd = sum(
            float(r.get("usd", 0.0)) for r in requests.values() if r.get("state") == "reserved"
        )
        settled_cnt = sum(1 for r in requests.values() if r.get("state") == "settled")
        reserved_cnt = sum(1 for r in requests.values() if r.get("state") == "reserved")

        total_settled_usd += settled_usd
        total_reserved_usd += reserved_usd
        total_settled_count += settled_cnt
        total_reserved_count += reserved_cnt

        ledger_summaries.append({
            "ledger_path": l_path,
            "limit": limit,
            "settled_usd": settled_usd,
            "reserved_usd": reserved_usd,
            "settled_count": settled_cnt,
            "reserved_count": reserved_cnt,
            "total_requests": len(all_requests),
        })

    has_paid_runs = (
        (total_settled_usd > 0 or total_settled_count > 0)
        or any((r.get("budget_cost") or Path(r["run_dir"], "budget_response.json").exists()) for r in all_runs)
    )

    # Synthetic geometry alone can never establish production readiness.
    is_ready_for_production = False

    # Keep distributions and denominators attached to the campaign and scene/kind.
    groups = []
    campaign_configs = []
    if grouped:
        for campaign in sorted(campaigns_seen):
            rows = [r for r in all_runs if r["campaign"] == campaign]
            configs = []
            for r in rows:
                cfg = r["runner_config"]
                item = {"variant": cfg.get("variant"), "model": cfg.get("model"),
                        "effort": cfg.get("effort", cfg.get("reasoning_effort")),
                        "max_side": cfg.get("max_side")}
                if item not in configs:
                    configs.append(item)
            campaign_metrics = analyze_realism_metrics({"all_runs": rows, "prepared_frames": [f for f in prepared_frames if f["campaign"] == campaign], "ledgers": {}}, grouped=False)
            campaign_configs.append({"campaign": campaign, "configurations": configs,
                                     "latency": campaign_metrics["latency"], "denominators": campaign_metrics["denominators"]})
        keys = sorted({(f["campaign"], f["scene"], kind) for f in prepared_frames for kind in EXPECTED_KINDS})
        for campaign, scene, kind in keys:
            frames = [f for f in prepared_frames if (f["campaign"], f["scene"], f["kind"]) == (campaign, scene, kind)]
            rows = [r for r in all_runs if (r["campaign"], r["scene"], r["kind"]) == (campaign, scene, kind)]
            sub = analyze_realism_metrics({"prepared_frames": frames, "all_runs": rows, "ledgers": {}}, grouped=False)
            photos = {f["photo"] for f in prepared_frames if f["campaign"] == campaign and f["scene"] == scene}
            expected = sum(max([1] + [int(r["run_name"].removeprefix("run_")) for r in rows if r["photo"] == photo and r["run_name"].removeprefix("run_").isdigit()]) for photo in photos)
            denom = sub["denominators"]
            denom["expected_total_trials"] = expected
            denom["missing_trials_count"] = expected - len(rows)
            groups.append({"campaign": campaign, "scene": scene, "kind": kind,
                           "denominators": denom, "proxy_iou": sub["proxy_iou"],
                           "latency": sub["latency"], "step_counts": sub["step_counts"]})
    step_counts = []
    known_focus = empty_focus = 0
    for r in all_runs:
        if not r["complete"]:
            continue
        steps = r.get("plan", {}).get("steps")
        if steps is not None:
            step_counts.append(len(steps))
            for step in steps:
                if "focus" in step:
                    known_focus += 1
                    empty_focus += not step["focus"]
        else:
            for step in r.get("proxy", {}).get("steps", []):
                if "focus_empty" in step:
                    known_focus += 1
                    empty_focus += bool(step["focus_empty"])
    empty_focus_steps_count = empty_focus
    empty_focus_fraction = empty_focus / known_focus if known_focus else None

    return {
        "campaign_configurations": campaign_configs,
        "scene_kind": groups,
        "step_counts": calculate_percentiles(step_counts),
        "original_repeats": [{"campaign": r["campaign"], "scene": r["scene"], "photo": r["photo"],
                              "run": r["run_name"], "complete": r["complete"], "latency": r["latency"]}
                             for r in all_runs if r["kind"] == "original"],
        "metadata": {
            "campaigns": sorted(campaigns_seen),
            "expected_scenes": list(EXPECTED_SCENES),
            "missing_scenes": sorted(set(EXPECTED_SCENES) - scenes_seen),
            "scenes": sorted(scenes_seen),
            "kinds": sorted(kinds_seen),
            "models": sorted(models_seen),
            "efforts": sorted(efforts_seen),
            "maxsides": sorted(maxsides_seen),
            "variants": sorted(variants_seen),
        },
        "denominators": {
            "expected_total_trials": expected_total_trials,
            "prepared_frames_count": prepared_frames_count,
            "complete_runs_count": complete_runs_count,
            "failed_runs_count": failed_runs_count,
            "dry_run_only_frames_count": dry_run_only_frames_count,
            "missing_trials_count": missing_trials_count,
            "expected_modes_per_scene": len(EXPECTED_KINDS),
        },
        "proxy_iou": {
            "focus_full_iou": calculate_percentiles(focus_full_ious),
            "focus_visible_iou": calculate_percentiles(focus_visible_ious),
            "avoid_full_iou": calculate_percentiles(avoid_full_ious),
            "avoid_visible_iou": calculate_percentiles(avoid_visible_ious),
            "total_steps": total_steps_count,
            "empty_focus_steps": empty_focus_steps_count,
            "empty_focus_denominator": known_focus,
            "empty_focus_fraction": empty_focus_fraction,
            "empty_avoid_steps": empty_avoid_steps_count,
            "claim": "Design geometry proxy only; NOT real semantic validation",
        },
        "latency": {
            "new_api_samples": new_api_count,
            "new_api_metrics": new_api_latency_stats,
            "cached_or_replayed_samples": cached_count,
            "cached_metrics": cached_latency_stats,
        },
        "matching_stability": {
            "sweep_results": stability_summary,
            "comparisons": comparisons,
            "claim": "Matching retention is geometric greedy association, NOT semantic correctness",
        },
        "costs": {
            "ledgers": ledger_summaries,
            "count_allowance": count_allowance,
            "actual_billed_usd": None,
            "ledger_available": bool(ledgers),
            "total_settled_usd": total_settled_usd,
            "total_reserved_usd": total_reserved_usd,
            "total_settled_count": total_settled_count,
            "total_reserved_count": total_reserved_count,
            "note": "Ledger estimates and count allowance are NOT actual billing; shared ledger counted once",
        },
        "status": {
            "is_ready_for_production": is_ready_for_production,
            "has_paid_runs": has_paid_runs,
            "is_dry_run_only": prepared_frames_count > 0 and not all_runs,
        },
    }


def generate_markdown_report(metrics: dict, output_file: Path, root_dir: Path) -> str:
    """Render comprehensive Georgian Markdown report adhering to all specifications."""
    meta = metrics["metadata"]
    denom = metrics["denominators"]
    proxy = metrics["proxy_iou"]
    lat = metrics["latency"]
    stab = metrics["matching_stability"]["sweep_results"]
    costs = metrics["costs"]
    status = metrics["status"]

    md: List[str] = []

    # Title
    md.append("# რეალისტურობის ტესტის შეფასების ანგარიში (REALISM)")
    md.append("")

    # Status Callouts
    if status["is_dry_run_only"] or not status["has_paid_runs"]:
        md.append("> [!IMPORTANT]")
        md.append("> **ფასიანი API გაშვებები არსებული ჩანაწერებით არ დასტურდება.**")
        md.append(f"> მომზადებული კადრი: {denom['prepared_frames_count']}; შესრულების გარეშე: {denom['dry_run_only_frames_count']}. მომზადება API შედეგს არ ნიშნავს.")
        md.append("> აპლიკაცია **არ არის მზად რეალური გარემოსთვის** (Production / Real-world validation is missing).")
        md.append("")
    elif not status["is_ready_for_production"]:
        md.append("> [!WARNING]")
        md.append("> მონაცემები არასრულია ან შეიცავს ჩაშლილ ცდებს. სისტემა ჯერ არ აკმაყოფილებს სრული მზადყოფნის კრიტერიუმებს.")
        md.append("")

    md.append("> [!WARNING]")
    md.append("> **მეთოდოლოგიური შეზღუდვა:**")
    md.append("> 1. **სინთეზური სტრეს-ტესტები არ უდრის რეალური ფოტოებით ვალიდაციას.** ხელოვნური ხმაური, tilt/crop, occlusion და lowres ვერ ცვლის რეალურ კამერის ოპტიკურ და განათების პირობებს.")
    md.append("> 2. **IoU მაჩვენებლები არის მხოლოდ დიზაინის გეომეტრიული proxy** (`Design geometry proxy only`) და **არა სემანტიკური სისწორე** (`NOT semantic accuracy`).")
    md.append("> 3. **Matching retention არის გეომეტრიული მიბმა (greedy association)** და არა სემანტიკური იდენტობის შენარჩუნება.")
    md.append("")

    # Section 1: Campaign and Configuration
    md.append("## 1. კამპანია და კონფიგურაცია")
    md.append("")
    md.append("| პარამეტრი | მნიშვნელობა |")
    md.append("|---|---|")
    md.append(f"| კამპანიები (Campaigns) | {', '.join(meta['campaigns']) if meta['campaigns'] else 'N/A'} |")
    md.append(f"| ვარიანტები (Variants) | {', '.join(meta['variants']) if meta['variants'] else 'N/A'} |")
    md.append(f"| მოდელები (Models) | {', '.join(meta['models']) if meta['models'] else 'N/A'} |")
    md.append(f"| Reasoning Effort | {', '.join(meta['efforts']) if meta['efforts'] else 'N/A'} |")
    md.append(f"| Max Side | {', '.join(meta['maxsides']) if meta['maxsides'] else 'N/A'} |")
    md.append(f"| სცენები (Scenes) | {len(meta['scenes'])} სცენა ({', '.join(meta['scenes']) if meta['scenes'] else 'არ არის'}) |")
    md.append(f"| მოსალოდნელი რეჟიმები (Kinds) | {denom['expected_modes_per_scene']} თითო სცენაზე ({', '.join(EXPECTED_KINDS)}) |")
    md.append("")

    md.append("სრული სამიზნე: 7 სცენა × 9 რეჟიმი = 63 კადრი თითო კამპანიაზე. დაუფიქსირებელი სცენები: " + (", ".join(meta["missing_scenes"]) or "არცერთი") + ".")
    md.append("")
    # Section 2: Denominators & Execution Completion
    md.append("| კამპანია | variant / model / effort / maxside |")
    md.append("|---|---|")
    for row in metrics["campaign_configurations"]:
        md.append(f"| {row['campaign']} | {json.dumps(row['configurations'], ensure_ascii=False)} |")
    md.append("")
    md.append("## 2. ცდების სისრულე და მნიშვნელი (Denominators)")
    md.append("")
    md.append("| კატეგორია | რაოდენობა | წილი / აღწერა |")
    md.append("|---|---:|---|")
    md.append(f"| მოსალოდნელი ცდები აღმოჩენილ კამპანია/ფოტოებზე | **{denom['expected_total_trials']}** | 9 რეჟიმი თითო ფოტოზე + აღმოჩენილი განმეორებები |")
    md.append(f"| მომზადებული კადრები (Prepared Frames) | **{denom['prepared_frames_count']}** | სინთეზური კადრები (dry-run) |")
    md.append(f"| დასრულებული API ცდები (Complete Runs) | **{denom['complete_runs_count']}** | წარმატებით დასრულებული |")
    md.append(f"| ჩაშლილი ცდები (Failed Runs) | **{denom['failed_runs_count']}** | ერორები / შეუმოწმებელი |")
    md.append(f"| მხოლოდ Dry-run კადრები (No Run) | **{denom['dry_run_only_frames_count']}** | API მოთხოვნის გარეშე |")
    md.append(f"| ნაკლული ცდები (Missing Denominators) | **{denom['missing_trials_count']}** | დარჩენილი შესასრულებელი |")
    md.append("")
    if denom["complete_runs_count"] == 0:
        md.append("> [!NOTE]")
        md.append(f"> დასრულებული გაშვებების მნიშვნელია **0 / {denom['expected_total_trials']}**. ფასიანი API გაშვება დაბლოკილია explicit ტარიფისა და ledger-ის დადასტურებამდე.")
        md.append("")

    # Section 3: Design Geometry Proxy Evaluation (IoU)
    md.append("## 3. გეომეტრიული Proxy შეფასება (Design Geometry Proxy)")
    md.append("")
    md.append("დიზაინის IoU მიახლოებითია: პოლიგონები არ არის რეალური სურათის გადამოწმებული ანოტაციები.")
    md.append("")
    md.append("*(გაფრთხილება: Focus და Avoid მკაცრად დამოუკიდებელია; Avoid-ის ცარიელი ნაბიჯები არ აზავებს Focus IoU-ს)*")
    md.append("")

    ff_p50 = f"{proxy['focus_full_iou']['p50']:.3f}" if proxy['focus_full_iou']['p50'] is not None else "N/A"
    ff_mean = f"{proxy['focus_full_iou']['mean']:.3f}" if proxy['focus_full_iou']['mean'] is not None else "N/A"
    fv_p50 = f"{proxy['focus_visible_iou']['p50']:.3f}" if proxy['focus_visible_iou']['p50'] is not None else "N/A"
    fv_mean = f"{proxy['focus_visible_iou']['mean']:.3f}" if proxy['focus_visible_iou']['mean'] is not None else "N/A"

    af_p50 = f"{proxy['avoid_full_iou']['p50']:.3f}" if proxy['avoid_full_iou']['p50'] is not None else "N/A"
    af_mean = f"{proxy['avoid_full_iou']['mean']:.3f}" if proxy['avoid_full_iou']['mean'] is not None else "N/A"
    av_p50 = f"{proxy['avoid_visible_iou']['p50']:.3f}" if proxy['avoid_visible_iou']['p50'] is not None else "N/A"
    av_mean = f"{proxy['avoid_visible_iou']['mean']:.3f}" if proxy['avoid_visible_iou']['mean'] is not None else "N/A"

    md.append("| სამიზნე ველი | სრული მასკა Mean (p50) | ხილული მასკა Mean (p50) | შეფასებული ნაბიჯები (n) | ცარიელი ნაბიჯების წილი |")
    md.append("|---|---:|---:|---:|---:|")
    md.append(f"| **Focus** (სამიზნე არე) | {ff_mean} ({ff_p50}) | {fv_mean} ({fv_p50}) | {proxy['focus_full_iou']['n']} | {format(proxy['empty_focus_fraction']*100, '.1f') + '%' if proxy['empty_focus_fraction'] is not None else 'N/A'} ({proxy['empty_focus_steps']}/{proxy['empty_focus_denominator']}) |")
    md.append(f"| **Avoid** (თავიდან ასაცილებელი) | {af_mean} ({af_p50}) | {av_mean} ({av_p50}) | {proxy['avoid_full_iou']['n']} | N/A (ცარიელი არ ითვლება) |")
    md.append("")
    md.append(f"- **სულ შეფასებული ნაბიჯი:** {proxy['total_steps']}")
    md.append(f"- **ცარიელი Avoid ნაბიჯების რაოდენობა:** {proxy['empty_avoid_steps']} (გამორიცხულია Avoid საშუალოდან Focus-ის დაცვის მიზნით)")
    md.append("")

    md.append("### სცენა × რეჟიმი (თითო კამპანია)")
    md.append("")
    md.append("| კამპანია | სცენა | რეჟიმი | complete / fail / missing | Focus full / visible (n) | Avoid full / visible (n) | ნაბიჯები p50 / n | ცარიელი focus / n |")
    md.append("|---|---|---|---|---|---|---|---|")
    def cell(stats):
        return f"{stats['mean']:.3f} ({stats['n']})" if stats['mean'] is not None else "N/A (0)"
    for row in metrics["scene_kind"]:
        d, p = row["denominators"], row["proxy_iou"]
        md.append(f"| {row['campaign']} | {row['scene']} | {row['kind']} | {d['complete_runs_count']} / {d['failed_runs_count']} / {d['missing_trials_count']} | {cell(p['focus_full_iou'])} / {cell(p['focus_visible_iou'])} | {cell(p['avoid_full_iou'])} / {cell(p['avoid_visible_iou'])} | {row['step_counts']['p50']} / {row['step_counts']['n']} | {p['empty_focus_steps']} / {p['empty_focus_denominator']} |")
    md.append("")
    md.append(f"Original განმეორებები ცალკეა JSON-ის original_repeats-ში: {len(metrics['original_repeats'])}. უანოტაციო რეალურ ფოტოებს proxy არ ენიჭება. ნაკლული გაზომვა არის N/A.")
    md.append("")

    # Section 4: Latency Analysis
    md.append("## 4. დაყოვნების ანალიზი (Latency: p50 / p90 / n)")
    md.append("")
    md.append("*(Replay, Cached და Resumed ჩანაწერები მკაცრად გამოყოფილია ახალი API გაშვებებისგან)*")
    md.append("")

    md.append("### 4.1 ახალი API ზარები (Valid New API Samples)")
    md.append("")
    md.append("| მეტრიკა | p50 (წმ) | p90 (წმ) | Mean (წმ) | ნიმუშები (n) |")
    md.append("|---|---:|---:|---:|---:|")
    new_metrics = lat["new_api_metrics"]
    for key, label in LATENCY_FIELDS:
        st = new_metrics[key]
        p50_s = f"{st['p50']:.3f}" if st['p50'] is not None else "N/A"
        p90_s = f"{st['p90']:.3f}" if st['p90'] is not None else "N/A"
        mean_s = f"{st['mean']:.3f}" if st['mean'] is not None else "N/A"
        md.append(f"| {label} | {p50_s} | {p90_s} | {mean_s} | {st['n']} |")
    md.append("")

    md.append("### 4.2 Replay / ქეშირებული ჩანაწერები (Cached / Resumed Samples)")
    md.append("")
    md.append(f"- **სულ ქეშირებული/Replay ნიმუში:** {lat['cached_or_replayed_samples']}")
    cached_metrics = lat["cached_metrics"]
    if lat["cached_or_replayed_samples"] > 0:
        md.append("")
        md.append("| მეტრიკა | p50 (წმ) | p90 (წმ) | ნიმუშები (n) |")
        md.append("|---|---:|---:|---:|")
        for key, label in LATENCY_FIELDS:
            st = cached_metrics[key]
            p50_s = f"{st['p50']:.3f}" if st['p50'] is not None else "N/A"
            p90_s = f"{st['p90']:.3f}" if st['p90'] is not None else "N/A"
            md.append(f"| {label} | {p50_s} | {p90_s} | {st['n']} |")
        md.append("")
    else:
        md.append("- ქეშირებული გაშვებები არ ფიქსირდება.")
        md.append("")

    md.append("### დაყოვნება კამპანიების მიხედვით")
    md.append("")
    md.append("| კამპანია | მეტრიკა | p50 | p90 | n |")
    md.append("|---|---|---|---|---|")
    for campaign in metrics["campaign_configurations"]:
        for key, label in LATENCY_FIELDS:
            stat = campaign["latency"]["new_api_metrics"][key]
            md.append(f"| {campaign['campaign']} | {label} | {stat['p50'] if stat['p50'] is not None else 'N/A'} | {stat['p90'] if stat['p90'] is not None else 'N/A'} | {stat['n']} |")
    md.append("")
    md.append("### Original განმეორებები")
    md.append("")
    md.append("| კამპანია | სცენა / ფოტო | ცდა | დასრულდა |")
    md.append("|---|---|---|---|")
    for row in metrics["original_repeats"]:
        md.append(f"| {row['campaign']} | {row['scene']} / {row['photo']} | {row['run']} | {'კი' if row['complete'] else 'არა'} |")
    md.append("")

    # Section 5: Geometric Stability & IoU Matching Retention
    md.append("## 5. კადრებს შორის გეომეტრიული სტაბილურობა (Matching Sweep)")
    md.append("")
    md.append("*(Association IoU ზღურბლები summary.json-დან; ადასტურებს მხოლოდ გეომეტრიულ მიბმას და არა სემანტიკურ სისწორეს)*")
    md.append("")
    md.append("| IoU ზღურბლი | Retention (შენარჩუნება) | Raw ID სტაბილურობა | Raw Label სტაბილურობა | შედარებები (n) |")
    md.append("|---|---:|---:|---:|---:|")
    for t_str, s_data in stab.items():
        ret_s = f"{s_data['mean_retention']*100:.1f}%" if s_data['mean_retention'] is not None else "N/A"
        id_s = f"{s_data['mean_raw_id_stability']*100:.1f}%" if s_data['mean_raw_id_stability'] is not None else "N/A"
        lbl_s = f"{s_data['mean_raw_label_stability']*100:.1f}%" if s_data['mean_raw_label_stability'] is not None else "N/A"
        md.append(f"| **Threshold ≥ {t_str}** | {ret_s} | {id_s} | {lbl_s} | {s_data['n']} |")
    md.append("")

    md.append("Dropout (წინა ობიექტების დაკარგვის წილი): " + "; ".join(f"{t}: {v['mean_dropout'] if v['mean_dropout'] is not None else 'N/A'}" for t, v in stab.items()))
    md.append("")
    # Section 6: Budget & Accounting
    md.append("## 6. ბიუჯეტი და Ledger აღრიცხვა (Costs)")
    md.append("")
    md.append("*(ხარჯები დედუბლიცირებულია; მრავალი კამპანიის ანალოგიური ledger არ ორმაგდება)*")
    md.append("")
    md.append("| მაჩვენებელი | მნიშვნელობა | განმარტება |")
    md.append("|---|---:|---|")
    md.append(f"| **Settled შეფასება (არა ფაქტობრივი გადასახადი)** | **${costs['total_settled_usd']:.4f}** | ledger-ის settled შეფასებები; actual billing უცნობია |")
    md.append(f"| **რეზერვირებული ლიმიტი (Reserved Allowance)** | **${costs['total_reserved_usd']:.4f}** | დროებით დაბლოკილი მაქსიმალური ჭერი (არა გადასახადი!) |")
    md.append(f"| Settled მოთხოვნების რაოდენობა | {costs['total_settled_count']} | დასრულებული API ტრანზაქციები |")
    md.append(f"| Reserved მოთხოვნების რაოდენობა | {costs['total_reserved_count']} | აქტიური ან ჩარჩენილი რეზერვაციები |")
    md.append("")

    ca = costs["count_allowance"]
    md.append(f"Count allowance: settled=${ca['settled_usd']:.4f}; reserved=${ca['reserved_usd']:.4f}. ეს ბიუჯეტის შეფასებაა და არა actual billing. Generation settled/reserved ზემოთ ცალკეა; run cost ფაილები ledger-ს არ ემატება.")
    md.append("")
    if costs["ledgers"]:
        md.append("### აღმოჩენილი Ledger ფაილები")
        md.append("")
        for l in costs["ledgers"]:
            p_rel = l["ledger_path"]
            try:
                p_rel = str(Path(l["ledger_path"]).relative_to(root_dir.parent))
            except Exception:
                pass
            md.append(f"- `{p_rel}`: Limit=${l['limit']}, Settled=${l['settled_usd']:.4f} ({l['settled_count']}), Reserved=${l['reserved_usd']:.4f} ({l['reserved_count']})")
        md.append("")
    else:
        md.append("- Ledger ფაილები ვერ მოიძებნა; ხარჯი დაუდასტურებელია.")
        md.append("")

    # Section 7: Visual Inspection Placeholders & Links
    md.append("## 7. ვიზუალური შეფასების სივრცე (Manual Visual Inspection)")
    md.append("")
    md.append("*(პროგრამული მაჩვენებლები ავტომატურად არ ადასტურებს ვიზუალურ ხარისხს. საჭიროა ადამიანის მიერ დათვალიერება)*")
    md.append("")

    # Links are evidence locations, never claims of visual review.
    md.append("| სცენა | რეჟიმი (Kind) | შეყვანის სურათი (Input) | სეგმენტაცია (parts.png) | ვიზუალური შემოწმება | შენიშვნა |")
    md.append("|---|---|---|---|:---:|---|")

    # Group prepared frames by scene
    scenes_map: Dict[str, List[dict]] = {}
    for f in metrics.get("prepared_frames", []):
        scenes_map.setdefault(f["scene"], []).append(f)

    count_samples = 0
    for sc, frames in sorted(scenes_map.items()):
        # Include all modes; individual repeats remain in machine-readable data.
        sample_kinds = EXPECTED_KINDS
        for f in frames:
            if f["kind"] in sample_kinds:
                count_samples += 1
                kind_dir = Path(f["frame_dir"])
                # Compute relative paths from output_file parent
                out_parent = output_file.parent.resolve()
                try:
                    img_rel = quote(os.path.relpath(kind_dir / "image.png", out_parent))
                except Exception:
                    img_rel = str(kind_dir / "image.png")

                # Check if parts.png exists in any run
                parts_rel = "არ არის (Dry-run)"
                for r_dir in sorted(kind_dir.glob("run_*")):
                    p_file = r_dir / "parts.png"
                    if p_file.exists():
                        try:
                            parts_rel = f"[parts.png]({quote(os.path.relpath(p_file, out_parent))})"
                        except Exception:
                            parts_rel = f"[parts.png]({p_file})"
                        break

                md.append(f"| {sc} | `{f['kind']}` | [image.png]({img_rel}) | {parts_rel} | [ ] შემოწმდა | ხელით შესაფასებელი |")

    if count_samples == 0:
        md.append("| - | - | - | - | [ ] | მონაცემები არ არის |")

    md.append("")
    md.append("---")
    md.append("*ანგარიში დაგენერირებულია `experiments/som-test/realism_report.py`-ის მიერ.*")

    return "\n".join(md)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("out_realism"),
        help="Root directory containing realism campaign outputs (default: out_realism)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("REALISM.md"),
        help="Output Markdown report path (default: REALISM.md)",
    )
    parser.add_argument(
        "--json",
        type=Path,
        help="Optional path to output raw structured JSON metrics",
    )
    args = parser.parse_args(argv)

    root_path = args.root.resolve()
    out_path = args.out.resolve()

    data = scan_campaign_data(root_path)
    metrics = analyze_realism_metrics(data)
    metrics["prepared_frames"] = data.get("prepared_frames", [])

    md_content = generate_markdown_report(metrics, out_path, root_path)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(md_content, encoding="utf-8")

    json_path = (args.json or out_path.with_suffix(".json")).resolve()
    json_path.parent.mkdir(parents=True, exist_ok=True)
    # Avoid serializing prepared_frames twice in json
    metrics_copy = dict(metrics)
    metrics_copy.pop("prepared_frames", None)
    json_path.write_text(
        json.dumps(metrics_copy, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print(f"ანგარიში შექმნილია: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
