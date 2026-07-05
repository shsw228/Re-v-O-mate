#!/bin/bash
# Build a distributable RevOmate.app bundle from the SwiftPM executable target.
# Usage: Packaging/make-app.sh [--open]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Re-v-O-mate.app"

echo "▸ Building release…"
swift build -c release --product RevOmateApp --package-path "$ROOT"
BIN="$(swift build -c release --product RevOmateApp --package-path "$ROOT" --show-bin-path)/RevOmateApp"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RevOmate"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/RevOmate"

echo "▸ Ad-hoc code signing…"
codesign --force --sign - "$APP"

echo "✓ Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
