#!/usr/bin/env python3
"""Generate the multi-resolution Windows icon used by the CLI and installer."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw


def generate_icon(output: Path) -> None:
    size = 256
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(size):
        progress = y / (size - 1)
        for x in range(size):
            horizontal = x / (size - 1)
            pixels[x, y] = (
                int(7 + 2 * progress),
                int(24 + 82 * horizontal),
                int(45 + 126 * (1 - progress)),
                255,
            )

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((5, 5, 250, 250), radius=54, fill=255)
    image.putalpha(mask)
    draw = ImageDraw.Draw(image)

    white = (239, 249, 255, 255)
    cyan = (76, 225, 255, 255)
    gold = (255, 207, 78, 255)
    shadow = (0, 8, 24, 95)

    draw.rounded_rectangle((45, 174, 211, 195), radius=9, fill=shadow)
    draw.rounded_rectangle((48, 168, 208, 188), radius=8, fill=white)
    draw.rounded_rectangle((54, 76, 82, 183), radius=7, fill=white)
    draw.rounded_rectangle((174, 76, 202, 183), radius=7, fill=white)
    draw.rounded_rectangle((48, 70, 88, 91), radius=7, fill=cyan)
    draw.rounded_rectangle((168, 70, 208, 91), radius=7, fill=cyan)
    draw.arc((65, 79, 191, 207), start=180, end=360, fill=white, width=13)
    draw.line((74, 119, 74, 168), fill=cyan, width=6)
    draw.line((182, 119, 182, 168), fill=cyan, width=6)

    draw.ellipse((103, 100, 153, 150), fill=gold)
    draw.line((116, 126, 126, 136, 142, 114), fill=(22, 75, 111, 255), width=8, joint="curve")

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.suffix.lower() == ".png":
        image.save(output, format="PNG")
    else:
        image.save(
            output,
            format="ICO",
            sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    generate_icon(args.output.resolve())


if __name__ == "__main__":
    main()
