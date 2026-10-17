"""AI-first comparison: original photo -> named boxes -> SAM2.1 masks. Writes only out_b/."""
import argparse
import json
import os

from dotenv import load_dotenv

from segmentation import HERE, ROOT, SCENES, save_json
from variant_b import consistency_b, process_run
from vision import select_model


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenes", nargs="+", choices=list(SCENES), default=list(SCENES))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--model", help="Override OPENAI_MODEL; default uses A's account-visible model selection")
    parser.add_argument("--device", choices=["mps", "cpu"])
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    load_dotenv(HERE / ".env")
    if not os.getenv("OPENAI_API_KEY", "").strip():
        print("OPENAI_API_KEY არ არის; API არ გაშვებულა. დაამატეთ experiments/som-test/.env-ში.")
        return 2
    if args.model:
        os.environ["OPENAI_MODEL"] = args.model
    import torch
    from openai import OpenAI
    device = args.device or ("mps" if torch.backends.mps.is_available() else "cpu")
    client = OpenAI(max_retries=0, timeout=180)
    out = HERE / "out_b"
    model = select_model(client, out)
    failed = False
    for scene in args.scenes:
        source = ROOT / "Camera/assets" / SCENES[scene][0]
        truth = json.loads((HERE / "out" / scene / "ground_truth.json").read_text())
        plans, successful_runs = [], []
        for n in range(1, args.runs + 1):
            dest = out / scene / f"run_{n}"
            try:
                plans.append(process_run(client, model, source, truth, dest, device))
                successful_runs.append(n)
                print(f"{scene}: B {n}/{args.runs} დასრულდა", flush=True)
            except Exception as exc:
                failed = True
                print(f"{scene}: B {n}/{args.runs}: {type(exc).__name__}; იხილეთ {dest}", flush=True)
        summary = consistency_b(plans)
        summary["successful_runs"] = successful_runs
        summary["requested_runs"] = args.runs
        save_json(out / scene / "consistency.json", summary)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
