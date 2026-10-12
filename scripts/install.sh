#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENABLE=1
if [[ "${1:-}" == --register-only && $# == 1 ]]; then
    ENABLE=0
elif [[ $# != 0 ]]; then
    echo "Usage: scripts/install.sh [--register-only]" >&2
    exit 1
fi
[[ "$(uname -s)" == Darwin && "$(id -u)" != 0 ]] || {
    echo "Run this on macOS as the current user, without sudo." >&2
    exit 1
}
# A release archive keeps the app beside this script; a checkout builds it into build/.
SOURCE="$(cd "$(dirname "$0")" && pwd)/LayaIME.app"
[[ -d "$SOURCE" ]] || SOURCE="$ROOT/build/LayaIME.app"
DESTINATION="$HOME/Library/Input Methods/LayaIME.app"
DATA="$HOME/Library/Application Support/LayaIME"
BUNDLE_ID="com.laya.inputmethod.Laya"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -d "$SOURCE" && ! -L "$SOURCE" ]] || { echo "Run scripts/build.sh first." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" == "$BUNDLE_ID" ]] || {
    echo "Unexpected build bundle identifier." >&2
    exit 1
}
codesign --verify --deep --strict "$SOURCE"
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    [[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || { echo "Refusing to replace a symlink or non-app destination." >&2; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")" == "$BUNDLE_ID" ]] || {
        echo "Refusing to replace a different app at $DESTINATION." >&2
        exit 1
    }
    "$DESTINATION/Contents/MacOS/LayaIME" --stop
fi
mkdir -p "$HOME/Library/Input Methods" "$DATA/Backups"
STAGING="$(mktemp -d "$DATA/.install.XXXXXX")"
BACKUP=""
NEW_APP=0
SUCCESS=0
cleanup() {
    if [[ "$SUCCESS" == 0 ]]; then
        if [[ "$NEW_APP" == 1 || -d "$STAGING/previous.app" ]] && [[ -d "$DESTINATION" ]]; then
            "$LSREGISTER" -u "$DESTINATION" || true
            mv "$DESTINATION" "$STAGING/failed.app"
        fi
        if [[ -d "$STAGING/previous.app" ]]; then
            mv "$STAGING/previous.app" "$DESTINATION"
            "$LSREGISTER" -f "$DESTINATION" || true
            "$DESTINATION/Contents/MacOS/LayaIME" --register "$DESTINATION" || true
            echo "Restored the previous LayaIME app after installation failed." >&2
        fi
    fi
    for app in "$STAGING/LayaIME.app" "$STAGING/previous.app" "$STAGING/verify/LayaIME.app" "$STAGING/failed.app"; do
        if [[ -d "$app" ]]; then "$LSREGISTER" -u "$app" || true; fi
    done
    if [[ -n "$BACKUP" ]]; then rm -f "$BACKUP/LayaIME.tar.partial"; fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
# ditto preserves executable permissions and the validated resource layout.
ditto "$SOURCE" "$STAGING/LayaIME.app"
codesign --verify --deep --strict "$STAGING/LayaIME.app"
if [[ -d "$DESTINATION" ]]; then
    BACKUP="$(mktemp -d "$DATA/Backups/install-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    tar -cpf "$BACKUP/LayaIME.tar.partial" -C "$HOME/Library/Input Methods" LayaIME.app
    mkdir "$STAGING/verify"
    tar -xpf "$BACKUP/LayaIME.tar.partial" -C "$STAGING/verify"
    codesign --verify --deep --strict "$STAGING/verify/LayaIME.app"
    mv "$BACKUP/LayaIME.tar.partial" "$BACKUP/LayaIME.tar"
    "$LSREGISTER" -u "$DESTINATION"
    mv "$DESTINATION" "$STAGING/previous.app"
    "$LSREGISTER" -u "$STAGING/previous.app" || true
fi
mv "$STAGING/LayaIME.app" "$DESTINATION"
NEW_APP=1
# Only the installed copy should be chosen when macOS launches this bundle ID.
"$LSREGISTER" -u "$SOURCE" || true
"$LSREGISTER" -f "$DESTINATION"
"$DESTINATION/Contents/MacOS/LayaIME" --register "$DESTINATION"
if [[ "$ENABLE" == 1 ]]; then
    "$DESTINATION/Contents/MacOS/LayaIME" --enable
fi
SUCCESS=1
echo "Installed for this user: $DESTINATION"
if [[ -n "$BACKUP" ]]; then
    echo "Previous app preserved as a verified archive: $BACKUP/LayaIME.tar"
    echo "To restore it after uninstalling the current app: tar -xpf \"$BACKUP/LayaIME.tar\" -C \"$HOME/Library/Input Methods\""
    echo "Then run: \"$LSREGISTER\" -f \"$DESTINATION\""
    echo "Then run: \"$DESTINATION/Contents/MacOS/LayaIME\" --register \"$DESTINATION\""
    echo "Then run: \"$DESTINATION/Contents/MacOS/LayaIME\" --enable"
fi
echo "The selected input source was not changed. Choose Laya 拼音 in the input menu."
echo "If absent, add it in System Settings > Keyboard > Text Input > Edit, or log out and back in."
