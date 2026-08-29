#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Prefer the full Xcode installation when the user has not selected a
# developer directory explicitly. This avoids accidentally using CLT-only
# tools, while still allowing CI or the caller to override DEVELOPER_DIR.
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

xcodebuild \
    -project "$PROJECT_ROOT/MacOnCall.xcodeproj" \
    -scheme MacOnCall \
    -configuration Release \
    -derivedDataPath "$PROJECT_ROOT/build" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
