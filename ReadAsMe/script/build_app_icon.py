#!/usr/bin/env python3
"""Build a modern PNG-backed ICNS file without relying on iconutil."""

from __future__ import annotations

import struct
import sys
from pathlib import Path


ICON_ENTRIES = (
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png"),
)


def build_icon(iconset: Path, destination: Path) -> None:
    entries = []
    for type_code, filename in ICON_ENTRIES:
        image = (iconset / filename).read_bytes()
        if not image.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"{filename} is not a PNG file")
        payload = type_code.encode("ascii") + struct.pack(">I", len(image) + 8) + image
        entries.append(payload)

    body = b"".join(entries)
    destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_app_icon.py <iconset> <output.icns>")
    build_icon(Path(sys.argv[1]), Path(sys.argv[2]))
