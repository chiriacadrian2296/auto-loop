"""Export the landing's WebP assets from test/screenshot_test.dart output.

Render with SCREENSHOT_DIR=build/landing-screenshots, SCREENSHOT_SCALE=2,
and SCREENSHOT_LANG=it then en before running this script.
"""

import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SHOTS = ROOT / "build" / "landing-screenshots"
ASSETS = ROOT / "site" / "assets"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--map-only", action="store_true", help="Export only the timeline screenshots")
args = parser.parse_args()


def export(source: str, target: str, crop=None):
    with Image.open(SHOTS / source) as original:
        image = original.convert("RGBA")
        if crop:
            scale = original.width / 1440
            image = image.crop(tuple(round(value * scale) for value in crop))
        if source.endswith("real_map.png"):
            image = trim_map(image)
        image.save(ASSETS / target, "WEBP", quality=94, method=6)
        print(f"{target}: {image.width} x {image.height}")


def fade_right_edge(image: Image.Image, probe_y: int, panel, width: int = 60) -> None:
    """Fade the timeline strip into the panel on the right, like the app's fade on the left."""
    differs = lambda x: sum(abs(a - b) for a, b in zip(image.getpixel((x, probe_y))[:3], panel[:3])) > 20
    end = next(x for x in range(image.width - 40, 0, -1) if differs(x)) + 1
    pixels = image.load()
    for x in range(max(0, end - width), end):
        keep = (end - x) / width
        for y in range(image.height):
            r, g, b, a = pixels[x, y]
            pixels[x, y] = (
                round(panel[0] + (r - panel[0]) * keep),
                round(panel[1] + (g - panel[1]) * keep),
                round(panel[2] + (b - panel[2]) * keep),
                a,
            )


def trim_map(image: Image.Image, margin: int = 40) -> Image.Image:
    """Drop the panel's own border and most of its empty height around the timeline.

    The page draws the frame, like every other screenshot, so the map keeps only
    the timeline row with `margin` pixels of panel colour above and below it.
    """
    border = 2
    panel = image.getpixel((image.width // 3, image.height // 4))
    rows = [
        y
        for y in range(border, image.height - border)
        if any(
            sum(abs(a - b) for a, b in zip(image.getpixel((x, y))[:3], panel[:3])) > 20
            for x in range(40, image.width - 40, 3)
        )
    ]
    fade_right_edge(image, rows[0] + 4, panel)
    top = max(border, rows[0] - margin)
    bottom = min(image.height - border, rows[-1] + 1 + margin)
    return image.crop((border, top, image.width - border, bottom))


for prefix in ("", "en_"):
    asset_prefix = "en-" if prefix else ""
    if args.map_only:
        export(f"{prefix}real_map.png", f"{asset_prefix}map.webp")
        continue
    for theme in ("dark", "light"):
        export(f"{prefix}main_{theme}.png", f"{asset_prefix}app-{theme}.webp")
    export(f"{prefix}main_dark.png", f"{asset_prefix}progress.webp", (362, 60, 722, 812))
    export(f"{prefix}main_dark.png", f"{asset_prefix}activity.webp", (738, 60, 1424, 812))
    export(f"{prefix}setup_1_welcome.png", f"{asset_prefix}setup.webp", (310, 180, 1130, 720))
    export(f"{prefix}real_map.png", f"{asset_prefix}map.webp")

if not args.map_only:
    with Image.open(SHOTS / "main_dark.png") as image:
        image.resize((1440, 900), Image.Resampling.LANCZOS).save(ROOT / "docs" / "screenshot.png")
