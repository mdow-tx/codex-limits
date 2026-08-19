#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP_DIR="$DIST/Codex Limits.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICNS="$RESOURCES/AppIcon.icns"
ZIP="$DIST/Codex Limits.zip"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_CACHE_PATH="$ROOT/.build/SwiftPMCache"
export XDG_CACHE_HOME="$ROOT/.build/XDGCache"

swift build -c release --disable-sandbox

rm -rf "$APP_DIR" "$ZIP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/.build/release/Codex Limits" "$MACOS/Codex Limits"
cp "$ROOT/Sources/CodexLimitsApp/Info.plist" "$CONTENTS/Info.plist"

python3 - "$ICNS" <<'PY'
from pathlib import Path
import struct
import zlib
import sys

out = Path(sys.argv[1])

def png_rgba(width, height, pixels):
    raw = b''.join(b'\x00' + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n'
    data += chunk(b'IHDR', struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(raw, 9))
    data += chunk(b'IEND', b'')
    return data

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
    return bytes(pixels)

representations = [
    (b'icp4', 16),
    (b'icp5', 32),
    (b'icp6', 64),
    (b'ic07', 128),
    (b'ic08', 256),
    (b'ic09', 512),
    (b'ic10', 1024),
]
chunks = []
for kind, size in representations:
    png = png_rgba(size, size, draw(size))
    chunks.append(kind + struct.pack(">I", len(png) + 8) + png)

payload = b''.join(chunks)
out.write_bytes(b'icns' + struct.pack(">I", len(payload) + 8) + payload)
PY

/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Codex Limits" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Codex Limits" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Codex Limits" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Codex Limits" "$CONTENTS/Info.plist"

xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d "com.apple.fileprovider.fpfs#P" "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP"

echo "$APP_DIR"
echo "$ZIP"
