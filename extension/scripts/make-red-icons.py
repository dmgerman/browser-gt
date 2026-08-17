#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
# Assisted-by: Claude:claude-opus-4-7
"""Resize the canonical browser-gt toolbar artwork into icon sizes.

Reads two square source artworks from ../doc/:
    browser-gt-icon.png       — the default (orange/blue) variant
    browser-gt-icon-red.png   — the consent-granted (all-red) variant

Each artwork is delivered on a near-white square; the script
flood-fills that surround with transparency from the corners (so the
icon reads cleanly on any browser-theme background) and resizes the
result into ../icons/:
    icon{16,48,128}.png
    icon-red-{16,48,128}.png

Re-run whenever the source artwork changes.  The script's filename
is kept for git-history continuity; it now produces both default
and red sets from independent source images rather than tinting
one from the other.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

EXT_DIR    = Path(__file__).resolve().parent.parent
REPO_DIR   = EXT_DIR.parent
DOC_DIR    = REPO_DIR / "doc"
ICONS_DIR  = EXT_DIR / "icons"
SIZES      = (16, 48, 128)
TRANSPARENT = (0, 0, 0, 0)

# Flood-fill threshold for the off-white surround.  Tight enough that
# the fill cannot walk across the antialiased outline of the logo's
# coloured regions.
FLOOD_THRESHOLD = 6

# (source filename in doc/, output filename prefix in icons/)
# The prefix is concatenated directly with the size number: prefix
# "icon" gives icon16/48/128.png; prefix "icon-red-" gives
# icon-red-16/48/128.png.
SOURCES = [
    ("browser-gt-icon.png",     "icon"),
    ("browser-gt-icon-red.png", "icon-red-"),
]


def transparentise_corners(img: Image.Image) -> Image.Image:
    out = img.copy()
    w, h = out.size
    for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        ImageDraw.floodfill(out, corner, TRANSPARENT, thresh=FLOOD_THRESHOLD)
    return out


def emit(source_path: Path, stem: str) -> None:
    if not source_path.exists():
        sys.stderr.write(f"missing source artwork: {source_path}\n")
        sys.exit(1)
    raw = Image.open(source_path).convert("RGBA")
    cleared = transparentise_corners(raw)
    for size in SIZES:
        out = cleared.resize((size, size), Image.LANCZOS)
        dst = ICONS_DIR / f"{stem}{size}.png"
        out.save(dst)
        print(f"wrote {dst.relative_to(REPO_DIR)}")


def main() -> None:
    for source_name, stem in SOURCES:
        emit(DOC_DIR / source_name, stem)


if __name__ == "__main__":
    main()
