#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ $# == 0 ]] || { echo "Usage: scripts/build.sh" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo "Building LayaIME requires macOS on Apple Silicon." >&2
    exit 1
}
[[ -x .venv/bin/python ]] || { echo "Run scripts/setup.sh first." >&2; exit 1; }
for source in native/main.swift native/InputController.swift native/CandidatePanel.swift native/BackendClient.swift native/Settings.swift native/PinyinDictionary.swift; do
    [[ -f "$source" ]] || { echo "Missing $source" >&2; exit 1; }
done
mkdir -p build
STAGING="$(mktemp -d "$ROOT/build/.laya-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/LayaIME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp native/Info.plist "$APP/Contents/Info.plist"
cp -R native/Resources/. "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/"*.lproj/InfoPlist.strings
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx26.2 \
    -module-name LayaIME native/*.swift \
    -framework Cocoa -framework InputMethodKit -framework Carbon -lsqlite3 \
    -o "$APP/Contents/MacOS/LayaIME"
xcrun swift scripts/make-icon.swift "$APP/Contents/Resources/LayaIcon.tiff"
.venv/bin/python scripts/package_resources.py "$APP/Contents/Resources"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Keep the last successful output until compilation and resource validation pass.
if [[ -e "$ROOT/build/LayaIME.app" ]]; then
    mv "$ROOT/build/LayaIME.app" "$STAGING/previous.app"
fi
mv "$APP" "$ROOT/build/LayaIME.app"
# Only the installed copy should be launchable for this bundle ID.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$ROOT/build/LayaIME.app" 2>/dev/null || true
echo "Built $ROOT/build/LayaIME.app"
echo "Not installed. To install for this user: scripts/install.sh"
