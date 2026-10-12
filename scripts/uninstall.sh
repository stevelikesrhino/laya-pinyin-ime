#!/bin/bash
set -euo pipefail
[[ $# == 0 ]] || { echo "Usage: scripts/uninstall.sh" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(id -u)" != 0 ]] || {
    echo "Run this on macOS as the current user, without sudo." >&2
    exit 1
}
DESTINATION="$HOME/Library/Input Methods/LayaIME.app"
DATA="$HOME/Library/Application Support/LayaIME"
BUNDLE_ID="com.laya.inputmethod.Laya"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]]; then
    echo "LayaIME is not installed at $DESTINATION. Nothing changed."
    exit 0
fi
[[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || { echo "Refusing to touch a symlink or non-app destination." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")" == "$BUNDLE_ID" ]] || {
    echo "Refusing to touch a different app at $DESTINATION." >&2
    exit 1
}
# Refuses removal while selected, rather than silently changing your keyboard.
"$DESTINATION/Contents/MacOS/LayaIME" --disable
"$DESTINATION/Contents/MacOS/LayaIME" --stop
mkdir -p "$DATA/Backups"
BACKUP="$(mktemp -d "$DATA/Backups/uninstall-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
STAGING="$(mktemp -d "$DATA/.uninstall.XXXXXX")"
SUCCESS=0
cleanup() {
    if [[ "$SUCCESS" == 0 && -d "$STAGING/removed.app" ]]; then
        mv "$STAGING/removed.app" "$DESTINATION"
        "$LSREGISTER" -f "$DESTINATION" || true
        "$DESTINATION/Contents/MacOS/LayaIME" --register "$DESTINATION" || true
        echo "Restored the LayaIME app after uninstallation failed." >&2
    fi
    for app in "$STAGING/verify/LayaIME.app" "$STAGING/removed.app"; do
        if [[ -d "$app" ]]; then "$LSREGISTER" -u "$app" || true; fi
    done
    rm -f "$BACKUP/LayaIME.tar.partial"
    rm -rf "$STAGING"
}
trap cleanup EXIT
tar -cpf "$BACKUP/LayaIME.tar.partial" -C "$HOME/Library/Input Methods" LayaIME.app
mkdir "$STAGING/verify"
tar -xpf "$BACKUP/LayaIME.tar.partial" -C "$STAGING/verify"
codesign --verify --deep --strict "$STAGING/verify/LayaIME.app"
mv "$BACKUP/LayaIME.tar.partial" "$BACKUP/LayaIME.tar"
"$LSREGISTER" -u "$DESTINATION"
mv "$DESTINATION" "$STAGING/removed.app"
"$LSREGISTER" -u "$STAGING/removed.app" || true
SUCCESS=1
echo "Uninstalled LayaIME for this user. No other input sources were changed."
echo "App preserved as a verified archive: $BACKUP/LayaIME.tar"
echo "Settings and personal learning data remain at: $DATA"
echo "To restore: tar -xpf \"$BACKUP/LayaIME.tar\" -C \"$HOME/Library/Input Methods\""
echo "Then run: \"$LSREGISTER\" -f \"$DESTINATION\""
echo "Then run: \"$DESTINATION/Contents/MacOS/LayaIME\" --register \"$DESTINATION\""
echo "Then run: \"$DESTINATION/Contents/MacOS/LayaIME\" --enable"
echo "A stale disabled entry may remain until the next login."
