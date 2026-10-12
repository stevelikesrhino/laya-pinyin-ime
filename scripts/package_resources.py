import importlib.metadata
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import sysconfig

from packaging.requirements import Requirement


ROOT = Path(__file__).resolve().parent.parent
# What the engine imports. jieba and pypinyin only build the dictionary; setup tools stay out of the bundle.
RUNTIME = ("mlx", "tokenizers")
MODEL = ("multilingual", "laya-chinese-tuned")
MODEL_FILES = ("multilingual/model.safetensors", "laya-chinese-tuned/laya_ime.safetensors",
               "laya-chinese-tuned/blend.json")


def copy_directory(source, destination):
    shutil.copytree(
        source, destination, symlinks=False,
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"),
    )


def runtime_files():
    """site-packages files of the runtime distributions and their dependencies."""
    pending, seen, files = list(RUNTIME), set(), set()
    while pending:
        name = re.sub(r"[-_.]+", "-", pending.pop()).lower()
        if name in seen:
            continue
        seen.add(name)
        try:
            distribution = importlib.metadata.distribution(name)
        except importlib.metadata.PackageNotFoundError:
            raise SystemExit(f"{name} is not installed; rerun scripts/setup.sh.")
        files.update(f for f in distribution.files or [] if not f.parts[0] == ".."
                     and "__pycache__" not in f.parts and f.suffix != ".pyc")
        for line in distribution.requires or []:
            requirement = Requirement(line)
            if requirement.marker is None or requirement.marker.evaluate({"extra": ""}):
                pending.append(requirement.name)
    return files


def check_libraries(path):
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    identifiers = subprocess.check_output(["otool", "-D", str(path)], text=True).splitlines()[1:]
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        # A dylib's own install name is metadata, not a linked dependency.
        if dependency in identifiers:
            continue
        if dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/")):
            raise RuntimeError(f"Nonportable library dependency in {path}: {dependency}")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: .venv/bin/python scripts/package_resources.py APP/Contents/Resources")
    if sys.version_info[:2] != (3, 12) or platform.machine() != "arm64":
        raise SystemExit("Packaging requires the Apple Silicon Python 3.12 environment from setup.sh.")
    resources = Path(sys.argv[1]).resolve()
    prefix = Path(sys.base_prefix).resolve()
    executable = Path(sys.executable).resolve()
    if not (prefix / "lib/libpython3.12.dylib").is_file():
        raise SystemExit("Python is not a portable standalone runtime. Use a uv-managed Python 3.12.")
    check_libraries(executable)
    check_libraries(prefix / "lib/libpython3.12.dylib")
    if not (ROOT / "models/dictionary.sqlite3").is_file():
        raise SystemExit("Missing models/dictionary.sqlite3; run scripts/setup.sh first.")

    runtime = resources / "runtime"
    (runtime / "bin").mkdir(parents=True)
    shutil.copy2(executable, runtime / "bin/python3.12")
    (runtime / "bin/python3").symlink_to("python3.12")
    copy_directory(prefix / "lib", runtime / "lib")
    site = Path(sysconfig.get_path("purelib"))
    for file in runtime_files():
        (resources / "python" / file).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(site / file, resources / "python" / file)
    copy_directory(ROOT / "backend", resources / "backend")
    (resources / "models").mkdir()
    shutil.copy2(ROOT / "models/dictionary.sqlite3", resources / "models")
    if all((ROOT / "models" / name).is_file() for name in MODEL_FILES):
        for name in MODEL:
            copy_directory(ROOT / "models" / name, resources / "models" / name)
    else:
        print("No ranking model in models/; the app keeps dictionary order.")

    # A wheel containing Homebrew or project-path dylibs must not silently ship.
    for path in resources.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(resources):
            raise RuntimeError(f"External bundle symlink: {path}")
        if path.suffix in (".so", ".dylib"):
            check_libraries(path)
    env = dict(os.environ, PYTHONPATH=str(resources / "python"), PYTHONNOUSERSITE="1",
               PYTHONDONTWRITEBYTECODE="1")
    env.pop("PYTHONHOME", None)
    subprocess.run([
        str(runtime / "bin/python3"), "-c",
        "import sys, sqlite3, mlx.core, tokenizers; "
        "sys.path.insert(0, 'backend'); from dictionary import CACHE_VERSION; "
        "db = sqlite3.connect('file:models/dictionary.sqlite3?mode=ro', uri=True); "
        "version = db.execute(\"SELECT value FROM metadata WHERE key='version'\").fetchone()[0]; "
        "db.close(); assert version == CACHE_VERSION, 'Dictionary is stale; rerun setup.sh'; "
        "print('Bundled Python:', sys.executable, 'dictionary version:', version)",
    ], cwd=resources, env=env, check=True)


if __name__ == "__main__":
    main()
