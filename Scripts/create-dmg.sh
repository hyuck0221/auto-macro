#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/dist/Auto Macro.app}"
OUTPUT_PATH="${2:-$ROOT/dist/AutoMacro.dmg}"
BACKGROUND="$ROOT/Scripts/Assets/dmg-background.png"

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi
if [[ ! -f "$BACKGROUND" ]]; then
    echo "DMG background not found: $BACKGROUND" >&2
    exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg is required. Install it with: brew install create-dmg" >&2
    exit 1
fi

SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/automacro-dmg.XXXXXX")"
cleanup() { rm -rf "$SOURCE_DIR"; }
trap cleanup EXIT

ditto "$APP_PATH" "$SOURCE_DIR/$(basename "$APP_PATH")"
mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

create-dmg \
    --volname "Auto Macro" \
    --background "$BACKGROUND" \
    --window-pos 100 100 \
    --window-size 660 420 \
    --text-size 13 \
    --icon-size 96 \
    --icon "$(basename "$APP_PATH")" 175 225 \
    --hide-extension "$(basename "$APP_PATH")" \
    --app-drop-link 485 225 \
    --filesystem APFS \
    --format UDZO \
    --hdiutil-quiet \
    --no-internet-enable \
    "$OUTPUT_PATH" \
    "$SOURCE_DIR"

echo "$OUTPUT_PATH"
