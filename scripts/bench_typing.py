#!/usr/bin/env python3
"""Replay scripted typing through the real Swift controller, panel and Python backend.

Usage: .venv/bin/python -B scripts/bench_typing.py [--cases FILE.jsonl] [--out RESULTS.jsonl]

The unregistered temporary app uses an isolated personal store and shows its candidate panel.
Terminal's Secure Keyboard Entry must be off. This measures a scripted IMK host, not a real
application's text-field quirks. Model warm-up is excluded. On-screen measures row geometry,
not untruncated readability. Slate changes are observable; identical/ignored backend replies
cannot be counted without instrumenting the client.
Cases have ctx, raw, gold, optional id/picks, or actions (type/wait/pick/key/host). --learn persists
only within this run; --repeat can exercise that learning. No real typing is recorded.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEYS = {"space", "return", "escape", "backspace", "tab", "left", "right", "down", "up", "pageDown", "pageUp"}
MODIFIERS = {"shift", "control", "option", "command"}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def scenarios(path):
    result = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        gold = row["gold"] if isinstance(row["gold"], str) else row["opts"][row["gold"][0]]
        item = {"id": row.get("id", "case-%d" % number), "ctx": row.get("ctx", ""),
                "raw": row.get("raw", row.get("key", "")), "gold": gold}
        if not all(isinstance(value, str) for value in item.values()):
            raise ValueError("case %d: id, ctx, raw and gold must be strings" % number)
        if "picks" in row:
            if not row["picks"] or not all(isinstance(pick, str) for pick in row["picks"]):
                raise ValueError("case %d: picks must be a nonempty list of strings" % number)
            item["picks"] = row["picks"]
        if "actions" in row:
            for action in row["actions"]:
                kind = action.get("type")
                if kind not in {"type", "wait", "pick", "key", "host"}:
                    raise ValueError("case %d: unknown action" % number)
                if kind in {"type", "pick"} and not isinstance(action.get("text"), str):
                    raise ValueError("case %d: action text must be a string" % number)
                if kind == "wait" and (not isinstance(action.get("ms"), (int, float)) or action["ms"] < 0):
                    raise ValueError("case %d: wait ms must be nonnegative" % number)
                if kind == "key" and (action.get("key") not in KEYS
                                      or not set(action.get("modifiers", [])).issubset(MODIFIERS)):
                    raise ValueError("case %d: unknown key or modifier" % number)
                if kind == "host" and ("text" in action and not isinstance(action["text"], str)
                                       or "caret" in action and not isinstance(action["caret"], int)):
                    raise ValueError("case %d: host text/caret must be a string/integer" % number)
            item["actions"] = row["actions"]
        result.append(item)
    if not result or len({row["id"] for row in result}) != len(result):
        raise ValueError("cases must be nonempty with unique ids")
    return result


def run(args, cases):
    python = ROOT / ".venv/bin/python"
    if not python.is_file() or not (ROOT / "models/dictionary.sqlite3").is_file():
        raise ValueError("run scripts/setup.sh first")
    model = args.model.resolve()
    if model.is_dir():
        model /= "laya_ime.safetensors"
    if not model.is_file() and not args.dictionary_only:
        raise ValueError("missing model: %s" % model)
    with tempfile.TemporaryDirectory(prefix="laya-bench-") as temporary:
        work = Path(temporary)
        app = work / "LayaBench.app/Contents"
        resources = app / "Resources"
        for directory in (app / "MacOS", resources / "models", resources / "runtime/bin"):
            directory.mkdir(parents=True, exist_ok=True)
        # Freeze sources so an in-progress edit cannot change the child midway through replay.
        shutil.copytree(ROOT / "backend", resources / "backend", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(ROOT / "native", work / "native")
        shutil.copy(ROOT / "scripts/bench_client/main.swift", work / "main.swift")
        sources = [p for p in sorted((work / "native").glob("*.swift")) if p.name != "main.swift"]
        (resources / "runtime/bin/python3").symlink_to(python)
        packages = Path(subprocess.check_output([str(python), "-B", "-c",
                        "import sysconfig; print(sysconfig.get_path('purelib'))"], text=True).strip())
        # The relocated interpreter loses its venv prefix; BackendClient supplies this bundle PYTHONPATH.
        (resources / "python").symlink_to(packages, target_is_directory=True)
        (resources / "models/dictionary.sqlite3").symlink_to(ROOT / "models/dictionary.sqlite3")
        (resources / "models/multilingual").symlink_to(ROOT / "models/multilingual", target_is_directory=True)
        (resources / "models/laya-chinese-tuned").mkdir()
        if model.is_file():
            (resources / "models/laya-chinese-tuned/laya_ime.safetensors").symlink_to(model)
        blend = model.with_name("blend.json")
        if blend.is_file():
            shutil.copy(blend, resources / "models/laya-chinese-tuned/blend.json")
        config = {"scenarios": cases, "intervalMS": args.interval_ms, "pauseMS": args.pause_ms,
                  "betweenMS": args.between_ms, "policy": args.policy, "ranked": not args.dictionary_only,
                  "learning": args.learn, "horizontal": args.horizontal, "repeatCount": args.repeat}
        config_path = work / "config.json"
        config_path.write_text(json.dumps(config, ensure_ascii=False))
        metadata = {"type": "metadata", "host": "scripted Swift IMKTextInput", "cases_sha256": digest(args.cases),
                    "model": str(model), "model_sha256": digest(model) if model.is_file() else None,
                    "blend_sha256": digest(blend) if blend.is_file() else None,
                    "dictionary_sha256": digest(ROOT / "models/dictionary.sqlite3"),
                    "sources_sha256": {p.name: digest(p) for p in sources},
                    "harness_sha256": digest(work / "main.swift"), "runner_sha256": digest(Path(__file__)),
                    "backend_sha256": {p.name: digest(p) for p in sorted((resources / "backend").glob("*.py"))},
                    "settings": {key: value for key, value in config.items() if key != "scenarios"},
                    "warmup_excluded": not args.dictionary_only or args.learn,
                    "reply_acceptance_count": "not instrumented"}
        executable = app / "MacOS/LayaBench"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-target", "arm64-apple-macosx26.2",
                        "-module-name", "LayaIME", str(work / "main.swift"), *map(str, sources),
                        "-framework", "Cocoa", "-framework", "InputMethodKit", "-framework", "Carbon",
                        "-lsqlite3", "-o", str(executable)], check=True)
        env = dict(os.environ, LAYA_DATA_DIR=str(work / "personal"), LAYA_BENCH_CONFIG=str(config_path),
                   PYTHONDONTWRITEBYTECODE="1")
        completed = subprocess.run([str(executable)], env=env, text=True, stdout=subprocess.PIPE, check=True)
        results = [{"type": "scenario", **json.loads(line)} for line in completed.stdout.splitlines() if line.strip()]
        return metadata, results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cases", type=Path, default=ROOT / "scripts/typing_cases.jsonl")
    parser.add_argument("--out", type=Path, help="new JSONL file with provenance and full scripted traces")
    parser.add_argument("--model", type=Path, default=ROOT / "models/laya-chinese-tuned")
    parser.add_argument("--interval-ms", type=float, default=80, help="scheduled start-to-start key interval")
    parser.add_argument("--pause-ms", type=float, default=80, help="pause after the last letter before selection")
    parser.add_argument("--between-ms", type=float, default=200)
    parser.add_argument("--policy", choices=("space", "select"), default="space",
                        help="Space once, or oracle page+number selection; explicit actions always run as written")
    parser.add_argument("--dictionary-only", action="store_true")
    parser.add_argument("--learn", action="store_true", help="learning in this run's temporary store only")
    parser.add_argument("--horizontal", action="store_true")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("requires macOS on Apple Silicon")
    if min(args.interval_ms, args.pause_ms, args.between_ms) < 0 or args.repeat < 1:
        parser.error("timings must be nonnegative and repeat must be positive")
    if args.out and args.out.exists():
        parser.error("refusing to overwrite %s" % args.out)
    try:
        metadata, results = run(args, scenarios(args.cases))
    except (OSError, ValueError, KeyError, IndexError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("x") as output:
            for row in [metadata, *results]:
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
    observations = [o for r in results if not r["scripted_actions"] for o in r["observations"]]
    scripted = [r for r in results if r["scripted_actions"]]
    print("Scripted Swift host; personal data isolated; not a real-app compatibility test.")
    print("ranking %s; startup excluded; identical/ignored backend replies are not counted." % (
        "off" if args.dictionary_only else "on (model warmed)"))
    print("cases %d | exact %d | unfinished %d | selection keys %d | editing/control keys %d" % (
        len(results), sum(r["exact"] for r in results), sum(bool(r["remaining"]) for r in results),
        sum(r["selection_keys"] for r in results), sum(r["editing_or_control_keys"] for r in results)))
    if observations:
        print("ordinary typing observations %d | top1 %.3f top3 %.3f on-screen %.3f" % (
            len(observations), *(sum(o[key] for o in observations) / len(observations) for key in ("top1", "top3", "visible"))))
    if scripted:
        print("scripted picks/correction checks %d | exact %d (deliberate alternatives excluded from prediction metrics)" % (
            len(scripted), sum(r["exact"] for r in scripted)))
    for row in results:
        print("%-24s #%d %-4s %5.0fms %2d selection keys | %s | remainder %r" % (
            row["id"], row["iteration"], "OK" if row["exact"] else "MISS", row["elapsed_ms"],
            row["selection_keys"], row["output"], row["remaining"]))
    if args.out:
        print("traces:", args.out)


if __name__ == "__main__":
    main()
