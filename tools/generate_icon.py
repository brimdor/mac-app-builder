#!/usr/bin/env python3
"""tools/generate_icon.py — generate the Odysseus app icon.

Produces a 1024x1024 PNG of a stylized boat/odysseus motif on a dark
blue background (matching the app's dark theme), then converts it
to a multi-size .icns file.

Concept:
  - Background: dark blue gradient (matches #282c34)
  - Sail: cyan triangle (#9cdef2)
  - Hull: white/light gray curve
  - Waves: subtle dotted pattern at the bottom

Usage:
    python3 tools/generate_icon.py

Outputs:
    apps/odysseus/icon-1024.png    (1024x1024 source PNG)
    apps/odysseus/icon.iconset/    (multi-size PNGs)
    apps/odysseus/icon.icns        (final macOS icon)
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("ERROR: Pillow is required. Install with: pip install Pillow", file=sys.stderr)
    sys.exit(1)


# Colors (matching the Odysseus login page palette)
BG_TOP = (40, 44, 52)         # #282c34
BG_BOTTOM = (24, 28, 36)      # slightly darker
SAIL_COLOR = (156, 222, 242)  # #9cdef2 (light cyan)
HULL_COLOR = (240, 240, 240)  # near-white
WAVE_COLOR = (156, 222, 242)  # cyan dots
PANEL_COLOR = (17, 17, 17)    # #111


def make_gradient(size, top, bottom):
    """Vertical gradient fill."""
    img = Image.new("RGB", (size, size), top)
    for y in range(size):
        t = y / (size - 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        for x in range(size):
            img.putpixel((x, y), (r, g, b))
    return img


def draw_wave_dots(img, color, count=20):
    """Draw a single row of dots at the bottom for the wave effect.
    Used as a sparse accent (just a few dots), not a busy line.
    """
    draw = ImageDraw.Draw(img, "RGBA")
    size = img.width
    y = int(size * 0.84)
    spacing = size / count
    r = max(1, size // 80)
    for i in range(count):
        x = int(i * spacing + spacing / 2)
        # Stagger the y a bit for organic feel
        y_jitter = ((i % 3) - 1) * (size // 200)
        draw.ellipse(
            (x - r, y + y_jitter - r, x + r, y + y_jitter + r),
            fill=color + (140,)
        )


def draw_boat(img):
    """Draw a stylized boat: a triangular sail above a curved hull.
    The boat is centered in the lower 60% of the icon.
    """
    draw = ImageDraw.Draw(img, "RGBA")
    size = img.width
    cx = size // 2
    cy = int(size * 0.55)  # boat center

    # Mast line
    mast_x = cx
    mast_top = int(size * 0.20)
    mast_bottom = int(size * 0.62)
    draw.line([(mast_x, mast_top), (mast_x, mast_bottom)], fill=SAIL_COLOR + (220,), width=max(2, size // 96))

    # Triangular sail (primary)
    sail_top = (cx, int(size * 0.20))
    sail_left = (cx - int(size * 0.20), int(size * 0.58))
    sail_right = (cx + int(size * 0.20), int(size * 0.58))
    draw.polygon([sail_top, sail_left, sail_right], fill=SAIL_COLOR + (255,))

    # Smaller jib sail (foreground) for depth
    sail2_top = (cx + int(size * 0.04), int(size * 0.32))
    sail2_left = (cx + int(size * 0.04), int(size * 0.58))
    sail2_right = (cx + int(size * 0.16), int(size * 0.58))
    draw.polygon([sail2_top, sail2_left, sail2_right], fill=SAIL_COLOR + (180,))

    # Hull (curved trapezoid) — pointed bow & stern
    hull_top = int(size * 0.62)
    hull_bottom = int(size * 0.74)
    hull_w = int(size * 0.30)
    bow_extension = int(size * 0.06)
    draw.polygon(
        [
            (cx - hull_w // 2 - bow_extension, hull_top + (hull_bottom - hull_top) // 2),  # bow point
            (cx + hull_w // 2, hull_top),
            (cx + hull_w // 2 - int(size * 0.05), hull_bottom),
            (cx - hull_w // 2 + int(size * 0.05), hull_bottom),
        ],
        fill=HULL_COLOR + (255,)
    )

    # Waterline (single, subtle wave line)
    water_y = int(size * 0.78)
    import math
    wave_amp = int(size * 0.012)
    wave_wavelength = int(size * 0.08)
    points = []
    for x in range(int(size * 0.15), int(size * 0.85), 2):
        y = water_y + int(wave_amp * math.sin((x - int(size * 0.15)) / wave_wavelength * 2 * math.pi))
        points.append((x, y))
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=SAIL_COLOR + (160,), width=max(2, size // 128))


def add_rounded_corners(img, radius):
    """Add rounded corners to a square image (macOS icons get rounded
    by the OS, but a slightly rounded source looks better in some
    places like the Dock). For v1.1 we don't add this; the OS handles
    rounding.
    """
    return img


def main():
    out_dir = Path("apps/odysseus")
    out_dir.mkdir(parents=True, exist_ok=True)

    size = 1024
    img = make_gradient(size, BG_TOP, BG_BOTTOM)

    # Layer 1: wave dots
    draw_wave_dots(img, WAVE_COLOR, count=24)

    # Layer 2: the boat
    draw_boat(img)

    # Save the source PNG
    src_png = out_dir / "icon-1024.png"
    img.save(src_png, "PNG")
    print(f"  ✓ {src_png}")

    # Build a .iconset with all required sizes
    iconset = out_dir / "icon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()

    sizes = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (64, 1), (64, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]
    for dim, scale in sizes:
        actual = dim * scale
        out_path = iconset / f"icon_{dim}x{dim}{'@2x' if scale == 2 else ''}.png"
        resized = img.resize((actual, actual), Image.LANCZOS)
        resized.save(out_path, "PNG")
        print(f"  ✓ {out_path} ({actual}x{actual})")

    # Convert to .icns
    icns_path = out_dir / "icon.icns"
    result = subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"  ✗ iconutil failed: {result.stderr}")
        sys.exit(1)
    print(f"  ✓ {icns_path}")

    # Verify
    print()
    print("Verification:")
    print(f"  icon.icns is a valid macOS icns: {icns_path.is_file()}")
    result = subprocess.run(["sips", "-g", "all", str(icns_path)], capture_output=True, text=True)
    print(result.stdout[:500])

    # Clean up the iconset (it's a build artifact, not source)
    shutil.rmtree(iconset)
    print(f"  ✓ cleaned up {iconset}")


if __name__ == "__main__":
    main()
