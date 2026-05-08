#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP_DIR="$DIST/Codex Limits.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="$ROOT/.build/CodexLimits.iconset"
ICNS="$RESOURCES/AppIcon.icns"
ZIP="$DIST/Codex Limits.zip"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_CACHE_PATH="$ROOT/.build/SwiftPMCache"
export XDG_CACHE_HOME="$ROOT/.build/XDGCache"

swift build -c release --disable-sandbox

rm -rf "$APP_DIR" "$ICONSET" "$ZIP"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"
cp "$ROOT/.build/release/Codex Limits" "$MACOS/Codex Limits"
cp "$ROOT/Sources/CodexLimitsApp/Info.plist" "$CONTENTS/Info.plist"

python3 - "$ICONSET" <<'PY'
from pathlib import Path
import struct
import zlib
import sys

out = Path(sys.argv[1])
sizes = [16, 32, 64, 128, 256, 512, 1024]

def png_rgba(path, width, height, pixels):
    raw = b''.join(b'\x00' + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n'
    data += chunk(b'IHDR', struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(raw, 9))
    data += chunk(b'IEND', b'')
    path.write_bytes(data)

def draw(size):
    pixels = bytearray()
    center = (size - 1) / 2
    radius = size * 0.42
    for y in range(size):
        for x in range(size):
            dx = x - center
            dy = y - center
            d = (dx * dx + dy * dy) ** 0.5
            if d > radius:
                pixels += b'\x00\x00\x00\x00'
                continue
            t = max(0, min(1, d / radius))
            r = int(28 + 22 * (1 - t))
            g = int(112 + 82 * (1 - t))
            b = int(92 + 58 * (1 - t))
            a = 255
            if abs(dx) < size * 0.035 and y < center:
                r, g, b = 235, 245, 241
            if d > radius * 0.72 and y < center and dx > 0:
                r, g, b = 245, 195, 74
            pixels += bytes([r, g, b, a])
    return pixels

for size in sizes:
    pixels = draw(size)
    name = f"icon_{size}x{size}.png"
    png_rgba(out / name, size, size, pixels)
    if size <= 512:
        double_size = size * 2
        png_rgba(out / f"icon_{size}x{size}@2x.png", double_size, double_size, draw(double_size))
PY

iconutil -c icns "$ICONSET" -o "$ICNS"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Codex Limits" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Codex Limits" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Codex Limits" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Codex Limits" "$CONTENTS/Info.plist"

xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
ditto -c -k --keepParent "$APP_DIR" "$ZIP"

echo "$APP_DIR"
echo "$ZIP"
