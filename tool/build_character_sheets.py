#!/usr/bin/env python3
"""Build small runtime character sheets from PVGames 10k compositing layers."""

from __future__ import annotations

import argparse
import gc
from pathlib import Path

try:
    from PIL import Image
except ImportError as error:  # pragma: no cover - developer tooling guard
    raise SystemExit("Pillow is required: python -m pip install Pillow") from error


FRAME_SIZE = 200
SOURCE_COLUMNS = 50
ANIMATIONS = {
    "walk": (0, 8),       # documented frames 1-64
    "idle": (128, 5),     # documented frames 129-168 (Idle 1)
}
LAYER_PATHS = (
    "Shadow/Spritesheet.png",
    "Base/OtherWorlds_1/Spritesheet.png",
    "Bottom/OtherWorlds_1/Spritesheet.png",
    "Top/OtherWorlds_1/Spritesheet.png",
    "Hair/OtherWorlds_1/Spritesheet.png",
    "Head/OtherWorlds_1/Spritesheet.png",
)


def frame_box(index: int) -> tuple[int, int, int, int]:
    column = index % SOURCE_COLUMNS
    row = index // SOURCE_COLUMNS
    left = column * FRAME_SIZE
    top = row * FRAME_SIZE
    return left, top, left + FRAME_SIZE, top + FRAME_SIZE


def build_character(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    outputs = {
        name: Image.new("RGBA", (frames * FRAME_SIZE, 8 * FRAME_SIZE))
        for name, (_, frames) in ANIMATIONS.items()
    }

    for relative_path in LAYER_PATHS:
        path = source / relative_path
        if not path.exists():
            raise FileNotFoundError(path)
        with Image.open(path) as encoded:
            sheet = encoded.convert("RGBA")
            for name, (start, frames_per_direction) in ANIMATIONS.items():
                output = outputs[name]
                for direction in range(8):
                    for frame in range(frames_per_direction):
                        source_index = (
                            start + direction * frames_per_direction + frame
                        )
                        cell = sheet.crop(frame_box(source_index))
                        output.alpha_composite(
                            cell,
                            (frame * FRAME_SIZE, direction * FRAME_SIZE),
                        )
        del sheet
        gc.collect()

    for name, output in outputs.items():
        output.save(destination / f"{name}.png", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--content", type=Path, default=Path("content"))
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("packages/neura_assets/assets/images/characters"),
    )
    args = parser.parse_args()
    for gender in ("Male", "Female"):
        build_character(args.content / gender, args.output / gender.lower())
        print(f"Built {gender.lower()} idle and walk sheets.")


if __name__ == "__main__":
    main()
