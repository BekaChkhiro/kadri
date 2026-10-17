"""Variant C: parts -> SAM outlines -> streamed steps. Writes only out_c/."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import math
import os
import uuid

from dotenv import load_dotenv

from segmentation import HERE, ROOT, SCENES, save_json
from variant_c import (Budget, BudgetExceeded, DEFAULT_MODEL, MODES, consistency_c,
                       forecast, match_parts, process_c, rates_for, transform_parts)


def parse_price(value):
    try:
        model, amounts = value.split("=", 1)
        rates = tuple(float(x) for x in amounts.split(","))
        if not model or len(rates) != 2 or any(not math.isfinite(x) or x <= 0 for x in rates):
            raise ValueError()
        return model, rates
    except ValueError:
        raise argparse.ArgumentTypeError("Use MODEL=IN_PER_1M,OUT_PER_1M with positive finite prices")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenes", nargs="+", choices=list(SCENES), default=list(SCENES))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--models", nargs="+", default=[DEFAULT_MODEL])
    parser.add_argument("--effort", choices=["minimal", "low"], default="minimal")
    parser.add_argument("--max-side", type=int, default=768)
    parser.add_argument("--device", choices=["mps", "cpu"])
    parser.add_argument("--degrade", nargs="*", choices=MODES, default=None,
                        help="No values means all four modes; a clean baseline is always included")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--budget-usd", type=float, default=2.0,
                        help="Cumulative estimated limit across invocations in out_c/budget.json")
    parser.add_argument("--price", action="append", type=parse_price, default=[])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.runs < 1 or not 32 <= args.max_side <= 2048 or args.seed < 0:
        parser.error("runs >= 1, max-side in 32..2048, seed >= 0 required")
    if any(not m or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in m)
           for m in args.models):
        parser.error("Invalid model ID")
    overrides = dict(args.price)
    models = list(dict.fromkeys(args.models))
    scenes = list(dict.fromkeys(args.scenes))
    modes = ["clean"] + (list(MODES) if args.degrade == [] else list(dict.fromkeys(args.degrade or [])))
    out = HERE / "out_c"
    try:
        budget = Budget(args.budget_usd, out / "budget.json")
        prices = {model: rates_for(model, overrides) for model in models}
    except ValueError as exc:
        parser.error(str(exc))
    count = len(scenes) * args.runs * len(modes)
    estimates = {model: count * sum(forecast(model, overrides, stage) for stage in ("parts", "steps"))
                 for model in models}
    plan = {"models": models, "scenes": scenes, "runs": args.runs, "modes": modes,
            "effort": args.effort, "max_side": args.max_side, "seed": args.seed,
            "requests": count * len(models) * 2, "rates_input_output_per_million": prices,
            "estimated_usd_by_model": estimates, "estimated_total_usd": sum(estimates.values()),
            "already_spent_estimated_usd": budget.spent, "budget_usd": budget.limit,
            "fits_budget_estimate": budget.spent + sum(estimates.values()) <= budget.limit,
            "estimate_basis": "16000 input tokens/stage; parts max 1200 output, steps max 2200. Larger prompts reserve more. Not a billing guarantee."}
    print(json.dumps(plan, ensure_ascii=False, indent=2), flush=True)
    if args.dry_run:
        return 0
    load_dotenv(HERE / ".env")
    if not os.getenv("OPENAI_API_KEY", "").strip():
        print("OPENAI_API_KEY არ არის; API არ გაშვებულა.")
        return 2
    import torch
    from openai import OpenAI
    device = args.device or ("mps" if torch.backends.mps.is_available() else "cpu")
    out.mkdir(parents=True, exist_ok=True)
    with (out / ".lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("C უკვე მუშაობს; ledger ერთდროულ გაშვებას კრძალავს.")
            return 1
        budget = Budget(args.budget_usd, out / "budget.json")
        client = OpenAI(max_retries=0, timeout=180)
        available = sorted(m.id for m in client.models.list())
        save_json(out / "available_models.json", available)
        if any(model not in available for model in models):
            print("მოდელი ანგარიშის სიაში არ არის; იხილეთ out_c/available_models.json")
            return 1
        batch = out / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "_" + uuid.uuid4().hex[:8])
        save_json(batch / "batch.json", plan)
        summary = {"geometry_proxy_only": True, "groups": [], "errors": [], "budget_stopped": False}
        failed = False
        try:
            for model in models:
                for scene in scenes:
                    truth = json.loads((HERE / "out" / scene / "ground_truth.json").read_text())
                    source = ROOT / "Camera/assets" / SCENES[scene][0]
                    runs = {mode: [] for mode in modes}
                    comparisons = []
                    group = {"model": model, "scene": scene, "degradation_comparisons": comparisons}
                    summary["groups"].append(group)
                    for n in range(1, args.runs + 1):
                        clean = None
                        for mode in modes:
                            dest = batch / model / scene / f"run_{n}" / mode
                            try:
                                result = process_c(client, model, source, truth, dest, device,
                                    args.effort, args.max_side, mode, args.seed, budget, overrides)
                            except BudgetExceeded:
                                raise
                            except Exception as exc:
                                failed = True
                                error = {"model": model, "scene": scene, "run": n,
                                         "mode": mode, "type": type(exc).__name__}
                                save_json(dest / "error.json", error)
                                summary["errors"].append(error)
                                print(json.dumps(error), flush=True)
                                continue
                            runs[mode].append({"run": n, "parts": result["parts"]})
                            group["consistency"] = {k: {**consistency_c([r["parts"] for r in v]),
                                                       "successful_run_numbers": [r["run"] for r in v]}
                                                    for k, v in runs.items()}
                            if mode == "clean":
                                clean = result["parts"]
                            elif clean is not None:
                                projected = transform_parts(clean, result["degradation"]["clean_to_image"])
                                comparisons.append({"run": n, "mode": mode,
                                    "clean_count_before_crop": len(clean),
                                    "raw_count_change": len(result["parts"]) - len(clean),
                                    **match_parts(projected, result["parts"])})
                            save_json(batch / "summary.json", summary)
        except BudgetExceeded as exc:
            summary["budget_stopped"] = True
            print(str(exc), flush=True)
        finally:
            summary["estimated_spent_usd"] = budget.spent
            save_json(batch / "summary.json", summary)
            client.close()
            print(f"შედეგები: {batch}", flush=True)
        return 1 if failed or summary["budget_stopped"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
