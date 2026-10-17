#!/usr/bin/env python3
"""Visible end-to-end run of the photo flow in the iOS Simulator, with Codex playing the user.

Codex generates each photo; the app (Debug build, `--autopilot <dir>`) submits it to the staging Worker,
walks the steps and writes `round-N.result.json`. When the model asks for another photo, Codex makes the
next one from the previous photo and the model's request. Screenshots follow `status.json`.

    python3 ios/Tools/e2e_codex_loop.py --udid <simulator-udid>

Stdlib only. The session token is never printed or written to disk.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUNDLE_ID = "ge.kadri.app"
SCHEMA = {
    "type": "object",
    "properties": {"image_path": {"type": "string"}, "comment": {"type": "string"}},
    "required": ["image_path", "comment"],
    "additionalProperties": False,
}
PHOTO_STYLE = (
    "ფოტორეალისტური კადრი, თითქოს ჩვეულებრივი ტელეფონით არის გადაღებული: ბუნებრივი სინათლე, "
    "ოდნავ არასრულყოფილი კომპოზიცია. კვადრატული ფორმატი 1:1 (1024×1024). არანაირი ტექსტი, წარწერა, "
    "ისარი, ლოგო, ადამიანის სახე. ობიექტი მკაფიოდ ჩანს კადრის ცენტრში."
)


def log(message: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kwargs)


def write_atomic(path: Path, data: bytes) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


# MARK: - Setup


def session_token(env_name: str) -> str:
    token = os.environ.get(env_name, "").strip()
    if token:
        return token
    env_file = Path.home() / ".config/kadri/staging.env"
    if not env_file.exists():
        sys.exit(f"{env_name} is not set and {env_file} does not exist")
    script = (
        'import { devToken, devVarsSecret } from "./scripts/dev_token.mjs";'
        'process.stdout.write(devToken({ secret: devVarsSecret(), sub: "kadri-e2e", email: "e2e@kadri.local", ttl: 7200 }));'
    )
    shell = f'set -a; source "{env_file}"; set +a; exec node --input-type=module -e \'{script}\''
    env = {**os.environ, "PATH": f"/opt/homebrew/opt/node@22/bin:{os.environ.get('PATH', '')}"}
    result = subprocess.run(["bash", "-c", shell], cwd=REPO / "backend/worker", env=env,
                            capture_output=True, text=True)
    token = result.stdout.strip()
    if result.returncode != 0 or token.count(".") != 2:
        sys.exit("could not mint a dev token (check SESSION_SECRET in staging.env); output suppressed")
    return token


def build_app(derived: Path) -> Path:
    log(f"Debug build → {derived}")
    log_file = derived.parent / f"{derived.name}-build.log"
    derived.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("w") as out:
        code = subprocess.run([
            "xcodebuild", "-project", str(REPO / "ios/Kadri.xcodeproj"), "-scheme", "Kadri",
            "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(derived), "build", "CODE_SIGNING_ALLOWED=NO",
        ], stdout=out, stderr=subprocess.STDOUT).returncode
    if code != 0:
        sys.exit(f"build failed, see {log_file}")
    return derived / "Build/Products/Debug-iphonesimulator/Kadri.app"


def boot(udid: str) -> None:
    listing = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True, check=True)
    devices = [d for group in json.loads(listing.stdout)["devices"].values() for d in group]
    device = next((d for d in devices if d["udid"] == udid), None)
    if device is None:
        sys.exit(f"no simulator {udid}")
    if device["state"] != "Booted":
        log(f"booting {device['name']}")
        run(["xcrun", "simctl", "boot", udid])
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], stdout=subprocess.DEVNULL)
    subprocess.run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], check=False)


# MARK: - Codex


class Codex:
    def __init__(self, out: Path, reuse: Path | None):
        self.dir = out / "codex"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.schema = self.dir / "schema.json"
        self.schema.write_text(json.dumps(SCHEMA))
        self.reuse = reuse
        self.generated = 0

    def photo(self, number: int, prompt: str, previous: Path | None) -> tuple[Path, str]:
        target = self.dir / f"round-{number}.png"
        if self.reuse and (self.reuse / "codex" / target.name).exists():
            shutil.copy(self.reuse / "codex" / target.name, target)
            meta = read_json(self.reuse / "codex" / f"codex-{number}.json") or {}
            log(f"round {number}: photo reused from {self.reuse}")
            return target, meta.get("comment", "")
        started = time.time()
        output = self.dir / f"codex-{number}.json"
        cmd = ["codex", "exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "-C", str(self.dir),
               "--output-schema", str(self.schema), "-o", str(output)]
        if previous:
            cmd += ["-i", str(previous)]
        log(f"round {number}: Codex is generating the photo…")
        # The prompt goes through stdin: `-i` takes several values and would swallow a positional prompt.
        with (self.dir / f"codex-{number}.log").open("w") as out:
            code = subprocess.run(cmd, input=prompt, text=True, stdout=out, stderr=subprocess.STDOUT,
                                  timeout=600).returncode
        self.generated += 1
        if code != 0:
            raise RuntimeError(f"codex exited {code}, see {self.dir / f'codex-{number}.log'}")
        meta = read_json(output) or {}
        source = Path(meta.get("image_path", ""))
        if not target.exists():
            if not source.is_file():
                fresh = [p for p in (Path.home() / ".codex/generated_images").rglob("exec-*.png")
                         if p.stat().st_mtime >= started]
                if not fresh:
                    raise RuntimeError(f"codex produced no image for round {number}")
                source = max(fresh, key=lambda p: p.stat().st_mtime)
            shutil.copy(source, target)
        log(f"round {number}: photo ready in {time.time() - started:.0f} s ({size(target)})")
        return target, meta.get("comment", "").strip()


def size(path: Path) -> str:
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         capture_output=True, text=True).stdout.split()
    try:
        return f"{out[out.index('pixelWidth:') + 1]}×{out[out.index('pixelHeight:') + 1]}"
    except (ValueError, IndexError):
        return "?"


def first_prompt(scenario: str) -> str:
    return (
        f"შენ თამაშობ მომხმარებელს, რომელსაც სახლში პრობლემა აქვს: „{scenario}“. "
        f"დააგენერირე ერთი ფოტო, რომელსაც ეს ადამიანი ტელეფონით გადაიღებდა და დამხმარე აპს აჩვენებდა. {PHOTO_STYLE} "
        "შეინახე სურათი ფაილად round-1.png ამ დირექტორიაში. JSON პასუხში image_path იყოს ამ ფაილის აბსოლუტური გზა, "
        "comment კი — ერთი მოკლე ქართული წინადადება, რომელსაც მომხმარებელი აპს სურათთან ერთად უწერს "
        "(პრობლემის აღწერა, არა შენი მოქმედებების ანგარიში)."
    )


def next_prompt(number: int, scenario: str, done_titles: list[str], prompt: str, reason: str) -> str:
    steps = "; ".join(done_titles) or "—"
    return (
        f"მიმაგრებული სურათი არის მომხმარებლის წინა ფოტო (პრობლემა: „{scenario}“). "
        f"მან უკვე შეასრულა ეს ნაბიჯები: {steps}. ახლა დამხმარე აპი სთხოვს: „{prompt}“ (მიზეზი: {reason}). "
        "დააგენერირე შემდეგი ფოტო: იგივე სცენა, იგივე ობიექტი და გარემო, მაგრამ შესრულებული ნაბიჯების შედეგით "
        f"და ზუსტად ისე, როგორც აპი ითხოვს. {PHOTO_STYLE} "
        f"შეინახე სურათი ფაილად round-{number}.png ამ დირექტორიაში. JSON პასუხში image_path იყოს ამ ფაილის "
        "აბსოლუტური გზა, comment კი — ერთი მოკლე ქართული წინადადება მომხმარებლის სახელით (რას აჩვენებს ფოტო)."
    )


def deliver(png: Path, out: Path, number: int) -> None:
    """JPEG copy into the autopilot folder, renamed into place so the app never reads half a file."""
    tmp = out / f".round-{number}.tmp.jpg"
    run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "90", str(png), "--out", str(tmp)],
        stdout=subprocess.DEVNULL)
    os.replace(tmp, out / f"round-{number}.jpg")


# MARK: - App


class Watcher:
    def __init__(self, udid: str, out: Path):
        self.udid = udid
        self.out = out
        self.shots_dir = out / "shots"
        self.shots_dir.mkdir(exist_ok=True)
        self.last: dict | None = None
        self.shots: dict[int, list[str]] = {}

    def poll(self) -> dict | None:
        status = read_json(self.out / "status.json")
        if status is None:
            return None
        key = {k: v for k, v in status.items() if k != "updatedAt"}
        if key != self.last:
            self.last = key
            self.screenshot(key)
        return status

    def screenshot(self, status: dict) -> None:
        time.sleep(0.4)  # let SwiftUI draw the new state
        name = f"r{status.get('round')}-{status.get('phase')}-s{status.get('stepIndex')}"
        if status.get("streaming"):
            name += f"-of{status.get('stepsCount')}"
        if status.get("waitingForPhoto"):
            name += "-waiting"
        path = self.shots_dir / f"{name}.png"
        n = 2
        while path.exists():
            path = self.shots_dir / f"{name}-{n}.png"
            n += 1
        subprocess.run(["xcrun", "simctl", "io", self.udid, "screenshot", str(path)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if path.exists():
            self.shots.setdefault(int(status.get("round") or 1), []).append(path.name)

    def wait(self, timeout: float, done) -> str | None:
        """Polls until `done()` returns a value; None on timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.poll()
            value = done()
            if value:
                self.poll()
                return value
            time.sleep(0.25)
        return None


# MARK: - Report


def report(out: Path, args, rounds: list[dict], stop: str, watcher: Watcher, codex: Codex) -> Path:
    total = sum(r["result"].get("costUsd") or 0 for r in rounds if r.get("result"))
    lines = [
        "# Kadri E2E — Codex ავტოპილოტი", "",
        f"- სცენარი: „{args.scenario}“",
        f"- სიმულატორი: `{args.udid}`, step-delay {args.step_delay} წმ",
        f"- round-ები: {len(rounds)}; დასრულება: {stop}",
        f"- ჯამური ხარჯი (steps `costUsd`): ${total:.4f} (cap ${args.cost_cap:.2f}); /ai/parts-ის ხარჯი აქ არ ითვლება",
        f"- Codex-ის სურათები: {codex.generated}", "",
    ]
    for r in rounds:
        n = r["number"]
        lines += [f"## Round {n}", "", f"![round {n}](codex/round-{n}.png)", "",
                  f"- ფოტო: [codex/round-{n}.png](codex/round-{n}.png) ({r.get('size', '?')})",
                  f"- კომენტარი: {r.get('comment') or '—'}"]
        if r.get("request"):
            lines.append(f"- მოთხოვნა, რომელზეც ფოტო გადაიღო: „{r['request']}“")
        result = r.get("result")
        if r.get("error"):
            lines.append(f"- **შეცდომა**: `{r['error'].get('code')}` — {r['error'].get('message')}")
        if result:
            parts = ", ".join(f"{p['name']} `{p['id']}` {p['box']}" for p in result.get("parts", []))
            cont = result.get("continuation", {})
            cont_text = cont.get("kind", "?")
            if cont.get("kind") == "needs_photo":
                cont_text += f" — „{cont.get('prompt')}“ (მიზეზი: {cont.get('reason')})"
            t = result.get("timings", {})
            cost = result.get("costUsd")
            lines += [
                f"- object: **{result.get('object')}**",
                f"- parts: {parts}",
                f"- continuation: {cont_text}",
                f"- costUsd: {'$%.4f' % cost if cost is not None else '—'}",
                f"- დროები: scan {t.get('scanMs')} ms, პირველი ნაბიჯი {t.get('firstStepMs')} ms, ყველა ნაბიჯი {t.get('stepsDoneMs')} ms",
                "", "| # | ნაბიჯი | ტექსტი | focus |", "|---|---|---|---|",
            ]
            for s in result.get("steps", []):
                text = (s.get("text") or "").replace("|", "/").replace("\n", " ")
                lines.append(f"| {s.get('index')} | {s.get('title')} | {text} | {', '.join(s.get('focus') or [])} |")
        shots = watcher.shots.get(n, [])
        if shots:
            lines += ["", "სქრინშოტები: " + ", ".join(f"[{s}](shots/{s})" for s in shots)]
        lines.append("")
    run_dir = out.name
    lines += [
        "## ხელახლა ნახვა შენს სიმულატორზე", "",
        "იგივე ფოტოებით (Codex აღარ ეშვება; AI პასუხები staging-იდან ახლიდან მოდის, ~$0.05–0.10 თითო round):", "",
        "```sh",
        f"python3 ios/Tools/e2e_codex_loop.py --udid 6C9A34B2-7783-4246-BCBE-6D8BE57B3ADA --reuse {out} "
        f"--out /tmp/kadri-e2e/{run_dir}-replay",
        "```", "",
        "რა უნდა ნახო: აპი თავისით იხსნება, ჩნდება round 1-ის ფოტო და კომენტარი, „ვასკანერებ…“, შემდეგ ნაწილების "
        "მონიშვნა და ნაბიჯები ავტომატურად იცვლება ყოველ ~3.5 წამში; needs_photo-ზე ბოლო ნაბიჯზე ჩანს „ახალი ფოტო“ "
        "მოთხოვნა, ცოტა ხანში ჩნდება შემდეგი ფოტო (chip „ფოტო 2“) და ციკლი მეორდება; ბოლოს — დასრულების ეკრანი.",
        "",
    ]
    path = out / "report.md"
    path.write_text("\n".join(lines))
    return path


# MARK: - Main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--scenario", default="ნიჟარის ქვეშ სიფონიდან წყალი ჟონავს")
    parser.add_argument("--max-rounds", type=int, default=5)
    parser.add_argument("--step-delay", type=float, default=3.5)
    parser.add_argument("--out", type=Path, default=Path(f"/tmp/kadri-e2e/{datetime.now():%Y%m%d-%H%M%S}"))
    parser.add_argument("--app", type=Path, help="Kadri.app (Debug, simulator); built into /tmp/kadri-e2e-dd if omitted")
    parser.add_argument("--cost-cap", type=float, default=0.60)
    parser.add_argument("--token-env", default="KADRI_SESSION_TOKEN")
    parser.add_argument("--timeout", type=float, default=300, help="seconds per wait for the app")
    parser.add_argument("--reuse", type=Path, help="earlier --out folder: reuse its codex/round-N.png instead of Codex")
    args = parser.parse_args()

    out: Path = args.out.resolve()
    if out.exists() and any(out.iterdir()):
        sys.exit(f"{out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    codex = Codex(out, args.reuse.resolve() if args.reuse else None)
    watcher = Watcher(args.udid, out)
    rounds: list[dict] = []
    stop = "?"

    token = session_token(args.token_env)
    app = args.app or build_app(Path("/tmp/kadri-e2e-dd"))
    if not app.exists():
        sys.exit(f"no app at {app}")

    try:
        png, comment = codex.photo(1, first_prompt(args.scenario), None)
        comment = comment or args.scenario
        rounds.append({"number": 1, "comment": comment, "size": size(png)})

        boot(args.udid)
        subprocess.run(["xcrun", "simctl", "terminate", args.udid, BUNDLE_ID], capture_output=True)
        run(["xcrun", "simctl", "install", args.udid, str(app)])
        run(["xcrun", "simctl", "launch", "--terminate-running-process", args.udid, BUNDLE_ID,
             "--autopilot", str(out), "--autopilot-step-delay", str(args.step_delay), "--dev-token", token],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"app launched with --autopilot {out}")
        if not watcher.wait(30, lambda: (out / "status.json").exists()):
            raise RuntimeError("the app wrote no status.json (is it a Debug simulator build?)")

        write_atomic(out / "comment.txt", comment.encode())
        deliver(png, out, 1)
        number = 1
        while True:
            def finished(n=number):
                if (out / f"round-{n}.error.json").exists():
                    return "error"
                return "result" if (out / f"round-{n}.result.json").exists() else None

            outcome = watcher.wait(args.timeout, finished)
            if outcome is None:
                stop = f"timeout: round {number} gave no result in {args.timeout:.0f} s"
                break
            if outcome == "error":
                rounds[-1]["error"] = read_json(out / f"round-{number}.error.json") or {}
                stop = f"error in round {number}: {rounds[-1]['error'].get('code')}"
                break
            result = read_json(out / f"round-{number}.result.json") or {}
            rounds[-1]["result"] = result
            cont = result.get("continuation", {})
            total = sum(r["result"].get("costUsd") or 0 for r in rounds if r.get("result"))
            log(f"round {number}: {len(result.get('steps', []))} steps, {cont.get('kind')}, "
                f"cost ${result.get('costUsd') or 0:.4f} (total ${total:.4f})")
            if cont.get("kind") != "needs_photo":
                watcher.wait(30, lambda: (out / "done.json").exists())
                stop = f"complete after {number} round(s)"
                break
            if number >= args.max_rounds:
                stop = f"max rounds ({args.max_rounds}) reached with needs_photo"
                break
            heaviest = max(r["result"].get("costUsd") or 0 for r in rounds if r.get("result"))
            if total + heaviest > args.cost_cap:
                stop = f"cost cap: ${total:.4f} spent, another round (~${heaviest:.4f}) would pass ${args.cost_cap:.2f}"
                break
            titles = [s.get("title", "") for r in rounds for s in (r.get("result") or {}).get("steps", [])]
            number += 1
            png, comment = codex.photo(number, next_prompt(number, args.scenario, titles, cont.get("prompt", ""),
                                                           cont.get("reason", "")), png)
            rounds.append({"number": number, "comment": comment, "size": size(png), "request": cont.get("prompt")})
            deliver(png, out, number)
    except (RuntimeError, subprocess.SubprocessError) as error:
        stop = f"driver error: {error}"
    except KeyboardInterrupt:
        stop = "interrupted"
    finally:
        watcher.poll()
        path = report(out, args, rounds, stop, watcher, codex)
        log(f"{stop}\nreport: {path}")
    return 0 if stop.startswith("complete") else 1


if __name__ == "__main__":
    sys.exit(main())
