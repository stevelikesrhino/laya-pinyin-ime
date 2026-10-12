#!/bin/bash
# Zip the built app with its install and uninstall scripts, for installing on another Apple Silicon Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ $# == 0 ]] || { echo "Usage: scripts/package.sh" >&2; exit 1; }
APP="build/LayaIME.app"
[[ -d "$APP" ]] || { echo "Run scripts/build.sh first." >&2; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="LayaIME-$VERSION"
STAGING="$(mktemp -d "$ROOT/build/.laya-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/$NAME"
ditto "$APP" "$STAGING/$NAME/LayaIME.app"
cp scripts/install.sh scripts/uninstall.sh "$STAGING/$NAME/"
mkdir -p dist
rm -f "dist/$NAME.zip"
ditto -c -k --keepParent "$STAGING/$NAME" "dist/$NAME.zip"
echo "Packaged dist/$NAME.zip ($(du -h "dist/$NAME.zip" | cut -f1))"
echo "On the target Mac: unzip it and run $NAME/install.sh. The app is ad-hoc signed, not notarized."
