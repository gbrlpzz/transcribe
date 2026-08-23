#!/usr/bin/env python3
"""Quantize the generated iconset and hand-pack a minimal .icns.

iconutil re-encodes PNGs and bloats the icns ~2.5x; this keeps the
palette-quantized PNGs verbatim (icns = 'icns' + size + [type,len,data]...).
Usage: python3 scripts/pack-icon.py <iconset-dir> <output.icns>
"""
import struct, sys, pathlib
from PIL import Image

ENTRIES = [
    ("icon_16x16@2x.png", b"ic11"),
    ("icon_32x32@2x.png", b"ic12"),
    ("icon_128x128.png", b"ic07"),
    ("icon_128x128@2x.png", b"ic13"),
    ("icon_256x256.png", b"ic08"),
    ("icon_256x256@2x.png", b"ic14"),
]

def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    payload = b""
    for name, ostype in ENTRIES:
        f = src / name
        img = Image.open(f).convert("RGBA")
        q = img.quantize(colors=128, method=Image.FASTOCTREE, dither=Image.NONE)
        q.save(f, optimize=True)
        data = f.read_bytes()
        payload += ostype + struct.pack(">I", len(data) + 8) + data
    blob = b"icns" + struct.pack(">I", len(payload) + 8) + payload
    out.write_bytes(blob)
    print(f"{out} — {len(blob)} bytes")

if __name__ == "__main__":
    main()
