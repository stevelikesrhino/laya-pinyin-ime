#!/bin/bash
# Backend and client tests. They need the dictionary from scripts/setup.sh, not a ranking model.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ $# == 0 ]] || { echo "Usage: scripts/test.sh" >&2; exit 1; }
[[ -x .venv/bin/python && -f models/dictionary.sqlite3 ]] || { echo "Run scripts/setup.sh first." >&2; exit 1; }
export PYTHONDONTWRITEBYTECODE=1

echo "== Backend"
.venv/bin/python -m unittest discover -s tests

echo "== Client"
# The client finds its dictionary and engine in its bundle's Resources, as the installed app does.
APP="build/tests/LayaTests.app"
rm -rf build/tests
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/models" "$APP/Contents/Resources/backend" \
    "$APP/Contents/Resources/runtime/bin"
ln -s "$ROOT/models/dictionary.sqlite3" "$APP/Contents/Resources/models/dictionary.sqlite3"
ln -s "$ROOT/.venv/bin/python" "$APP/Contents/Resources/runtime/bin/python3"
cp tests/engine.py "$APP/Contents/Resources/backend/server.py"
SOURCES=()
for source in native/*.swift; do [[ "$source" == native/main.swift ]] || SOURCES+=("$source"); done
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.2 -module-name LayaIME \
    tests/client/main.swift "${SOURCES[@]}" \
    -framework Cocoa -framework InputMethodKit -framework Carbon -lsqlite3 \
    -o "$APP/Contents/MacOS/LayaTests"
DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"' EXIT
LAYA_DATA_DIR="$DATA" LAYA_BACKEND="$ROOT/backend" "$APP/Contents/MacOS/LayaTests"
