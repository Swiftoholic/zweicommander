#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${ZWEI_BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${ZWEI_OUTPUT_DIR:-$(dirname "$PROJECT_DIR")}"
APP="$OUTPUT_DIR/ZweiCommander.app"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
if [[ -d "$APP" && -f "$APP/Contents/Info.plist" ]]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
  [[ "$EXISTING_ID" == 'local.zweicommander.app' ]] || { echo 'Ziel enthält eine andere App.' >&2; exit 1; }
fi
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_ROOT/intel" -c release --triple x86_64-apple-macosx13.0 --product ZweiCommander
INTEL_BIN=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_ROOT/intel" -c release --triple x86_64-apple-macosx13.0 --show-bin-path)
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_ROOT/arm64" -c release --triple arm64-apple-macosx13.0 --product ZweiCommander
ARM_BIN=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_ROOT/arm64" -c release --triple arm64-apple-macosx13.0 --show-bin-path)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create "$INTEL_BIN/ZweiCommander" "$ARM_BIN/ZweiCommander" -output "$APP/Contents/MacOS/ZweiCommander"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
swift "$PROJECT_DIR/scripts/icon.swift" "$BUILD_ROOT/AppIcon.iconset"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$BUILD_ROOT/AppIcon.iconset"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Erstellt: $APP"
