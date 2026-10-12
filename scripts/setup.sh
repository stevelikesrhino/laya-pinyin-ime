#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "LayaIME requires macOS on Apple Silicon." >&2
    exit 1
fi
usage() { echo "Usage: scripts/setup.sh [--offline] [--model SOURCE]" >&2; exit 1; }
MODEL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) export UV_OFFLINE=1; MODEL_ARGS+=(--offline); shift ;;
        --model) [[ $# -ge 2 ]] || usage; MODEL_ARGS+=(--model "$2"); shift 2 ;;
        *) usage ;;
    esac
done
command -v uv >/dev/null || { echo "Install uv first: brew install uv" >&2; exit 1; }
[[ -f requirements.txt && -f backend/server.py ]] || {
    echo "Missing requirements.txt or backend/server.py." >&2
    exit 1
}

if [[ ! -x .venv/bin/python ]]; then
    export UV_PYTHON_INSTALL_DIR="$ROOT/.python"
    uv python install 3.12
    uv venv --python "$(uv python find --managed-python 3.12)" .venv
fi
.venv/bin/python -c 'import pathlib,sys; assert sys.version_info[:2] == (3,12), "Python 3.12 is required"; assert (pathlib.Path(sys.base_prefix)/"lib/libpython3.12.dylib").is_file(), "Use a uv-managed standalone Python runtime"'
uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python scripts/prepare_models.py ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}
.venv/bin/python backend/server.py --build-dictionary "$ROOT/models/dictionary.sqlite3"
echo "Setup complete. Run scripts/build.sh. No input source has been installed or activated."
