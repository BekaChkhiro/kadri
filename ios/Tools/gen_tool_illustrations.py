#!/usr/bin/env python3
"""Generate the clay-style tool illustrations for tool cards with the local Codex CLI.

Every catalog id becomes ios/Kadri/Assets.xcassets/Tools/tool-<id>.imageset/<id>.png (512 px),
loaded in the app as UIImage(named: "tool-<id>").

    python3 ios/Tools/gen_tool_illustrations.py                    # all 32
    python3 ios/Tools/gen_tool_illustrations.py --ids ph2,level --fix "the handle was black"

Only `codex exec` is used (the person's own Codex); no API keys are read.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "ios/Kadri/Assets.xcassets/Tools"

# id → (Georgian name, physical shape for the prompt). Same order as the worker and KadriCore catalogs.
CATALOG: list[tuple[str, str, str]] = [
    ("ph1", "ჯვარედინი სახრახნისი PH1", "small Phillips #1 screwdriver with a thin cross-tip steel shaft and a rounded handle"),
    ("ph2", "ჯვარედინი სახრახნისი PH2", "medium Phillips #2 screwdriver with a cross-tip steel shaft and a chunky rounded handle"),
    ("flat_small", "ბრტყელი სახრახნისი (პატარა)", "small slotted flat-blade screwdriver with a thin flat tip and a slim handle"),
    ("flat_large", "ბრტყელი სახრახნისი (დიდი)", "large slotted flat-blade screwdriver with a wide flat tip, long shaft and a thick handle"),
    ("torx_t10", "Torx სახრახნისი T10", "small Torx T10 screwdriver with a six-pointed star tip and a slim handle"),
    ("torx_t20", "Torx სახრახნისი T20", "medium Torx T20 screwdriver with a six-pointed star tip and a chunky handle"),
    ("hex_key", "ექვსკუთხა გასაღები", "L-shaped hexagonal Allen key (hex key), a bent metal bar with a hexagonal cross-section"),
    ("adjustable_wrench", "რეგულირებადი გასაღები", "adjustable wrench (crescent wrench) with an open jaw and a worm-screw adjuster"),
    ("open_wrench", "ქანჩის გასაღები", "double open-end spanner wrench with a U-shaped open jaw at each end"),
    ("socket_wrench", "თავაკიანი გასაღები", "ratchet socket wrench with a round ratchet head and one attached socket"),
    ("pipe_wrench", "მილის გასაღები", "heavy pipe wrench (Stillson wrench) with serrated hook jaws and a long handle"),
    ("pliers", "ბრტყელტუჩა", "combination pliers with flat gripping jaws and two padded handles"),
    ("needle_pliers", "წვრილტუჩა", "needle-nose pliers with long thin pointed jaws and two padded handles"),
    ("wire_cutter", "მავთულის საჭრელი", "diagonal side-cutting wire cutters with short angled cutting jaws and two padded handles"),
    ("wire_stripper", "კაბელის გამწმენდი", "wire stripper tool with notched stripping holes along the jaws and two padded handles"),
    ("crimper_rj45", "RJ45 კრიმპერი", "RJ45 network cable crimping tool with a square crimping die cavity in the jaw and two long handles"),
    ("multimeter", "მულტიმეტრი", "handheld digital multimeter with a blank screen, a rotary dial and two red and black test probes"),
    ("voltage_tester", "ძაბვის ინდიკატორი", "pen-shaped non-contact voltage tester with a pocket clip and a small light at the tip"),
    ("flashlight", "ფანარი", "handheld cylindrical flashlight (torch) with a wide lens head"),
    ("bucket", "ვედრო", "plastic bucket with a curved wire handle"),
    ("towel", "ტილო", "neatly folded cleaning towel (cloth rag)"),
    ("gloves", "ხელთათმანები", "pair of work gloves lying flat, empty, no hands inside"),
    ("antistatic_strap", "ანტისტატიკური სამაჯური", "anti-static wrist strap: an elastic band with a metal snap and a coiled grounding cord ending in an alligator clip, not worn"),
    ("thermal_paste", "თერმოპასტა", "small syringe of thermal paste with a plunger and a thin nozzle"),
    ("cable_ties", "კაბელის სამაგრები", "small bundle of plastic cable ties (zip ties)"),
    ("tape_measure", "რულეტკა", "retractable tape measure with a rounded case and a short length of blank tape pulled out"),
    ("level", "თარაზო", "spirit level: a long bar with small bubble vials"),
    ("drill", "დრელი", "cordless power drill with a pistol grip, a battery pack and a drill bit in the chuck"),
    ("hammer", "ჩაქუჩი", "claw hammer with a metal head and a wooden handle"),
    ("utility_knife", "საკანცელარიო დანა", "retractable utility box-cutter knife with a segmented snap-off blade slightly extended"),
    ("plumber_tape", "ფუმლენტა", "roll of white PTFE plumber's thread-seal tape on a small spool, with a short loose end"),
    ("spudger", "პლასტმასის სპუჯერი", "plastic spudger pry tool: a flat stick with a thin wedge tip at one end and a pointed hook at the other"),
]

PROMPT = """Generate one image with your image generation tool.

Subject: one single {subject}.

Style: soft matte 3D clay-style illustration, rounded forms, viewed from slightly above at a consistent 3/4 angle, \
the tool lying diagonally from lower-left to upper-right and filling about 80% of a square canvas, soft shadow \
under it, plain pure white background (#FFFFFF). Colours: white, light grey, brand blue #2F6BFF accents on the \
handle/grip, and one warm neutral (light wood or beige) only where natural; no black or dark grey parts \
(metal is light silver). No text, no numbers, no letters, \
no logos, no hands, no people, no other objects, no background scene.
{fix}
Output a 1024x1024 PNG saved as {id}.png in the current working directory ({dir}). \
Reply with JSON where image_path is the absolute path of that PNG and comment is one short sentence about the image.
"""

SCHEMA = {
    "type": "object",
    "properties": {"image_path": {"type": "string"}, "comment": {"type": "string"}},
    "required": ["image_path", "comment"],
    "additionalProperties": False,
}

INFO = {"author": "xcode", "version": 1}
MAX_BYTES = 300 * 1024


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def codex_image(tool_id: str, subject: str, fix: str, out: Path) -> Path:
    """One `codex exec` run in its own directory; returns the raw PNG copied to <out>/<id>.png."""
    work = Path(tempfile.mkdtemp(prefix=f"kadri-tool-{tool_id}-"))
    schema = work / "schema.json"
    write_json(schema, SCHEMA)
    answer = work / "out.json"
    target = work / f"{tool_id}.png"
    prompt = PROMPT.format(subject=subject, id=tool_id, dir=work,
                           fix=f"\nImportant correction from the previous attempt: {fix}\n" if fix else "")
    cmd = ["codex", "exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "-C", str(work),
           "--output-schema", str(schema), "-o", str(answer)]
    started = time.time()
    log_path = out / f"{tool_id}.log"
    with log_path.open("w") as stream:
        code = subprocess.run(cmd, input=prompt, text=True, stdout=stream, stderr=subprocess.STDOUT,
                              timeout=600).returncode
    if code != 0:
        raise RuntimeError(f"codex exited {code}, see {log_path}")
    try:
        meta = json.loads(answer.read_text())
    except (OSError, ValueError):
        meta = {}
    source = target if target.is_file() else Path(meta.get("image_path", ""))
    if not source.is_file():
        # Codex keeps generated images under ~/.codex/generated_images/<session id>/; prefer this run's session
        # so parallel runs do not pick up each other's images.
        root = Path.home() / ".codex/generated_images"
        session = re.search(r"session id:\s*([0-9a-f-]{36})", log_path.read_text(errors="ignore"))
        search = root / session.group(1) if session and (root / session.group(1)).is_dir() else root
        fresh = [p for p in search.rglob("exec-*.png") if p.stat().st_mtime >= started]
        if not fresh or (search == root and len(fresh) > 1):
            raise RuntimeError(f"codex produced no attributable image for {tool_id}, see {log_path}")
        source = max(fresh, key=lambda p: p.stat().st_mtime)
    raw = out / f"{tool_id}.png"
    shutil.copy(source, raw)
    (out / f"{tool_id}.comment.txt").write_text(meta.get("comment", "").strip() + "\n")
    shutil.rmtree(work, ignore_errors=True)
    log(f"{tool_id}: generated in {time.time() - started:.0f} s")
    return raw


def install(tool_id: str, raw: Path) -> Path:
    """Resize to 512 px and write the imageset UIImage(named: "tool-<id>") loads."""
    imageset = ASSETS / f"tool-{tool_id}.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    png = imageset / f"{tool_id}.png"
    # Busy textures (towel, gloves) can pass 300 KB at 512 px; step down until they fit.
    for side in (512, 480, 448):
        subprocess.run(["sips", "-s", "format", "png", "-Z", str(side), str(raw), "--out", str(png)],
                       check=True, stdout=subprocess.DEVNULL)
        if png.stat().st_size <= MAX_BYTES:
            break
    write_json(imageset / "Contents.json", {
        "images": [{"idiom": "universal", "filename": f"{tool_id}.png", "scale": "1x"}],
        "info": INFO,
    })
    log(f"{tool_id}: installed {png.relative_to(ROOT)} ({png.stat().st_size // 1024} KB)")
    return png


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ids", help="comma-separated catalog ids (default: all)")
    parser.add_argument("--out", type=Path, default=Path("/tmp/kadri-tool-illos"), help="raw images and logs")
    parser.add_argument("--parallel", type=int, default=3)
    parser.add_argument("--fix", default="", help="extra correction appended to the prompt (for retries)")
    args = parser.parse_args()

    known = {tool_id: subject for tool_id, _, subject in CATALOG}
    ids = [i.strip() for i in args.ids.split(",") if i.strip()] if args.ids else list(known)
    unknown = [i for i in ids if i not in known]
    if unknown:
        parser.error(f"unknown ids: {', '.join(unknown)}")

    args.out.mkdir(parents=True, exist_ok=True)
    ASSETS.mkdir(parents=True, exist_ok=True)
    write_json(ASSETS / "Contents.json", {"info": INFO})

    started = time.time()
    failed: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
        jobs = {pool.submit(codex_image, i, known[i], args.fix, args.out): i for i in ids}
        for job in concurrent.futures.as_completed(jobs):
            tool_id = jobs[job]
            try:
                install(tool_id, job.result())
            except Exception as error:  # noqa: BLE001 - report every failure, keep the rest going
                failed.append(tool_id)
                log(f"{tool_id}: FAILED {error}")
    log(f"done: {len(ids) - len(failed)}/{len(ids)} in {time.time() - started:.0f} s"
        + (f"; failed: {','.join(failed)}" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
