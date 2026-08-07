#!/bin/bash
# Turn any square image into a macOS AppIcon.icns.
#
#   ./Scripts/make-icon.sh <source.png> [--no-mask]
#
# macOS icons are NOT edge-to-edge: the artwork sits inside a "squircle" safe
# area with roughly 10% padding on each side, and the OS does not add that for
# you. Handing sips a full-bleed image produces an icon that looks oversized
# next to every other app in the Dock.
#
# So by default this insets the artwork and applies the standard superellipse
# mask. Pass --no-mask if the source already includes its own bezel.
#
# Requires only sips, iconutil and Python 3 — all present in Command Line Tools.

set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
MASK=1
[ "${2:-}" = "--no-mask" ] && MASK=0

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "usage: $0 <source.png> [--no-mask]" >&2
  exit 1
fi

OUT_DIR="Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$OUT_DIR"

# 1024pt canvas, artwork inset to the macOS safe area, corners masked.
CANVAS=1024
python3 - "$SRC" "$OUT_DIR/icon-1024.png" "$CANVAS" "$MASK" <<'PY'
import sys, subprocess, tempfile, os, math, struct, zlib

src, dst, canvas, mask = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1"

# macOS large-icon geometry: ~824/1024 of the canvas, centred, corner radius
# ~185/824. Apple publishes the grid; these are the values it works out to.
inset_px = round(canvas * 824 / 1024)
radius   = inset_px * 185 / 824

tmp = tempfile.mkdtemp()
scaled = os.path.join(tmp, "scaled.png")
# sips does the resampling; it is the only image tool guaranteed present.
subprocess.run(["sips", "-s", "format", "png", "-z", str(inset_px), str(inset_px),
                src, "--out", scaled],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# Compose onto a transparent canvas and apply the squircle, using CoreImage via
# a tiny AppleScript-free Objective-C bridge would be heavy — so do it with a
# PNG read/write in pure Python instead.
def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w = 8, b"", None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+ln]
        if typ == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        pos += 12 + ln
    raw = zlib.decompress(idat)
    channels = {0:1, 2:3, 3:1, 4:2, 6:4}[color]
    stride = w * channels
    out, prev = [], bytearray(stride)
    i = 0
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i+stride]); i += stride
        for x in range(stride):
            a = line[x-channels] if x >= channels else 0
            b = prev[x]
            c = prev[x-channels] if x >= channels else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a+b)//2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out.append(bytes(line)); prev = line
    return w, h, channels, out

def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)

w, h, ch, rows = read_png(scaled)
off = (canvas - w) // 2
out_rows = []
for y in range(canvas):
    row = bytearray(canvas * 4)
    sy = y - off
    if 0 <= sy < h:
        src_row = rows[sy]
        for x in range(canvas):
            sx = x - off
            if 0 <= sx < w:
                base = sx * ch
                if ch == 4:   r, g, b, a = src_row[base:base+4]
                elif ch == 3: r, g, b = src_row[base:base+3]; a = 255
                elif ch == 2: r = g = b = src_row[base]; a = src_row[base+1]
                else:         r = g = b = src_row[base]; a = 255
                if mask:
                    # Superellipse (squircle), n = 5, matching Apple's curve
                    # far better than a plain rounded rect.
                    cx, cy = (canvas - 1) / 2, (canvas - 1) / 2
                    half = w / 2
                    nx, ny = abs(x - cx) / half, abs(y - cy) / half
                    d = nx ** 5 + ny ** 5
                    # The squircle boundary is d == 1, and it touches the box at
                    # each edge midpoint. Feather only just outside it: a wider
                    # band (0.92 was the first try) visibly thins the flat edges
                    # to ~80% alpha, which reads as a soft grey halo.
                    if d > 1.06:
                        a = 0
                    elif d > 0.98:
                        a = int(a * (1.0 - (d - 0.98) / 0.08))
                row[x*4:x*4+4] = bytes((r, g, b, a))
    out_rows.append(bytes(row))

write_png(dst, canvas, canvas, out_rows)
print(f"composed {canvas}x{canvas}, artwork {w}px inset {off}px, mask={'yes' if mask else 'no'}")
PY

# Every size macOS asks for. Missing sizes make the Dock fall back to a blurry
# upscale of whatever is closest.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  sips -s format png -z "$1" "$1" "$OUT_DIR/icon-1024.png" --out "$ICONSET/$2.png" \
    >/dev/null 2>&1
done

iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
echo "wrote $OUT_DIR/AppIcon.icns ($(du -h "$OUT_DIR/AppIcon.icns" | cut -f1))"
