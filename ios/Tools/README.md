# SAM → Core ML tools

Python 3.11, Apple Silicon Mac; Core ML prediction/compute-plan inspection requires macOS.
Commands below run from the repository root. No API keys or paid calls are used.

```sh
uv sync --project ios/Tools --python 3.11 --locked
uv run --project ios/Tools pytest ios/Tools/tests -q
uv run --project ios/Tools python ios/Tools/evaluate_candidates.py
uv run --project ios/Tools python ios/Tools/convert_sam.py
uv run --project ios/Tools python ios/Tools/bench_sam.py
```

Default export: **EfficientSAM-Ti**, `ios/Models/SAMEncoder.mlpackage` and
`ios/Models/SAMDecoder.mlpackage`. This is an evaluation candidate, **not an accepted
iPhone performance result**. FP16 gym/p2 IoU is 0.7978; see [the report](../../docs/SAM_COREML.md).
`conversion.json` travels with the packages and defines the candidate/preprocessing.
Do not mix an encoder/decoder/manifest from different candidates.

The first load downloads only the pinned upstream Python package and license, and
weights verified against SHA-256 in `candidates.py`; all are cached under `.cache/`.
Internet is needed on first load. `uv.lock` pins dependencies. A failed checksum
aborts before loading the model. No upstream package needs an editable install.
EdgeSAM uses the inference-only commit immediately before its training dependencies
were introduced; its S-Lab license excludes it from the required Apache/MIT choice.
Its optional evaluation export must not be shipped as a permissively licensed model.

For each alternative, run sequentially (avoid concurrent inference during timing):

```sh
uv run --project ios/Tools python ios/Tools/convert_sam.py --candidate mobilesam --output ios/Models/mobilesam
uv run --project ios/Tools python ios/Tools/bench_sam.py --models ios/Models/mobilesam --output ios/Tools/out/mobilesam_coreml.json
uv run --project ios/Tools python ios/Tools/convert_sam.py --candidate edgesam --output ios/Models/edgesam
uv run --project ios/Tools python ios/Tools/bench_sam.py --models ios/Models/edgesam --output ios/Tools/out/edgesam_coreml.json
```

`evaluate_candidates.py --candidate efficientsam` evaluates a single candidate.
It records CPU PyTorch IoU, oracle IoU (diagnostic only), parameters, and fvcore FLOP
counts with unsupported operators. Core ML benchmark records both ALL and CPU_AND_NE,
two warmups and ten timed `predict` calls per image/box, per-part IoU, PyTorch parity,
MIL operator inventory, model size, and per-operation compute plans. Compilation,
pre/postprocessing, source loading and reference evaluation are excluded from timings;
Python/Core ML input/output bridge overhead is included. `--runs` changes repeat count.

Reference input is deliberately read-only:
`experiments/som-test/out_realism/c_astra_tracking/{scene}/{asset}/original/run_1/`.
The required files are `input.png`, `plan.json`, `segmentation.json`, `masks.npz`.
The benchmark checks ID order, box pixel rounding and mask dimensions before inference.
It uses **run masks**, not `truth_masks.npz` (which describes a different annotation set).
Missing/inconsistent fixtures cause an error; nothing in `experiments/` is regenerated
or modified. All 14 reference masks were available in this checkout.

`out/bench.json` is the default detailed result; `out/review/` holds per-part overlay
PNGs (cyan agreement, red candidate-only, yellow reference-only). These, `.cache/`,
`.venv/`, and everything under `ios/Models/` except its `.gitignore` are excluded from git.
Rebuild packages in the integration checkout with the commands above; git integration
does not transfer ignored model binaries. No Swift changes are included.
