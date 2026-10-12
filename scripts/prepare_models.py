"""Put an optional ranking model into models/ for the build.

Without --model, candidates keep dictionary order. SOURCE is a local directory or a Hugging Face repo
(owner/name[@revision]) holding laya_ime.safetensors and blend.json, tuned on the pinned Laya base model.
"""
import argparse
from pathlib import Path
import shutil

from huggingface_hub import snapshot_download
from huggingface_hub.errors import LocalEntryNotFoundError


ROOT = Path(__file__).resolve().parent.parent
BASE_REPO = "convaiinnovations/laya"
BASE_REVISION = "7b928d828b7b0e022f929d9bd2e44165aa270148"
BASE_FILES = (
    "model.safetensors",
    "encoder/config.json",
    "tokenizer/tokenizer.json",
    "tokenizer/tokenizer_config.json",
    "rl_agent_config.json",
)
TUNED_FILES = ("laya_ime.safetensors", "blend.json")


def complete(directory, names):
    return all((directory / name).is_file() for name in names)


def fetch(repo, revision, patterns, names, offline):
    # A cached snapshot can exist with only some of the requested files.
    try:
        snapshot = Path(snapshot_download(repo, revision=revision, allow_patterns=patterns, local_files_only=True))
        if complete(snapshot, names):
            return snapshot
    except LocalEntryNotFoundError:
        pass
    if offline:
        raise SystemExit(f"{repo} is not fully cached; rerun without --offline.")
    return Path(snapshot_download(repo, revision=revision, allow_patterns=patterns))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", metavar="SOURCE")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    base, tuned = ROOT / "models/multilingual", ROOT / "models/laya-chinese-tuned"
    if args.model is None:
        if complete(base, BASE_FILES) and complete(tuned, TUNED_FILES):
            print(f"Using the ranking model already in {ROOT / 'models'}")
        else:
            print("No ranking model; candidates keep dictionary order. Add one with --model SOURCE.")
        return

    source = Path(args.model).expanduser()
    if not source.exists() and not args.model.startswith(("/", ".", "~")):
        repo, _, revision = args.model.partition("@")
        source = fetch(repo, revision or None, list(TUNED_FILES), TUNED_FILES, args.offline)
    if not complete(source, TUNED_FILES):
        parser.error(f"{args.model} must contain {' and '.join(TUNED_FILES)}")
    if not complete(base, BASE_FILES):
        snapshot = fetch(BASE_REPO, BASE_REVISION, ["multilingual/*"],
                         [f"multilingual/{name}" for name in BASE_FILES], args.offline)
        shutil.copytree(snapshot / "multilingual", base, dirs_exist_ok=True, symlinks=False)
    tuned.mkdir(parents=True, exist_ok=True)
    for name in TUNED_FILES:
        if (source / name).resolve() != (tuned / name).resolve():
            shutil.copy2(source / name, tuned / name)
    print(f"Ranking model ready: {tuned}")


if __name__ == "__main__":
    main()
