#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_PATH="$BUILD_DIR/Build/Products/Release/MacOnCall.app"
DMG_PATH="$PROJECT_ROOT/MacOnCall.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/maconcall-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg is required. Install it with: brew install create-dmg" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "Release app not found. Build it first with -derivedDataPath build." >&2
    exit 1
fi

ditto "$APP_PATH" "$STAGING_DIR/MacOnCall.app"

create-dmg \
    --overwrite \
    --volname "MacOnCall" \
    --window-pos 200 120 \
    --window-size 650 400 \
    --icon-size 128 \
    --icon "MacOnCall.app" 180 200 \
    --hide-extension "MacOnCall.app" \
    --app-drop-link 470 200 \
    "$DMG_PATH" \
    "$STAGING_DIR"

echo "Created $DMG_PATH"
