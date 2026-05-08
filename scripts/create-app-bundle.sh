#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/.build/Codex Limits.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_CACHE_PATH="$ROOT/.build/SwiftPMCache"
export XDG_CACHE_HOME="$ROOT/.build/XDGCache"

swift build --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$MACOS"
cp "$ROOT/.build/debug/Codex Limits" "$MACOS/Codex Limits"
cp "$ROOT/Sources/CodexLimitsApp/Info.plist" "$CONTENTS/Info.plist"

echo "$APP_DIR"
