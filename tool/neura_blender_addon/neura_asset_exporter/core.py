"""Pure helpers shared by the Neura Blender add-on and its unit tests."""

from __future__ import annotations

import json
import math
import re
import struct
import zlib
from pathlib import Path
from typing import Iterable, Mapping, Sequence


TILE_WIDTH = 128.0
TILE_HEIGHT = TILE_WIDTH / math.sqrt(2.0)
ELEVATION_PIXELS = 64.0
PIXELS_PER_CAMERA_UNIT = TILE_HEIGHT

DIRECTION_ANGLES_DEGREES = {
    "south": 0.0,
    "southWest": 45.0,
    "west": 90.0,
    "northWest": 135.0,
    "north": 180.0,
    "northEast": -135.0,
    "east": -90.0,
    "southEast": -45.0,
}

VIEW_DIRECTIONS = {
    "FIXED": ("south",),
    "FOUR_WAY": ("south", "west", "east", "north"),
    "EIGHT_WAY": (
        "south",
        "west",
        "east",
        "north",
        "southWest",
        "northWest",
        "southEast",
        "northEast",
    ),
}

ENGINE_VIEW_MODES = {
    "FIXED": "fixed",
    "FOUR_WAY": "fourWay",
    "EIGHT_WAY": "eightWay",
}

SURFACE_MAP_ENCODING = "octahedralWorldNormalRGHeightB"

_ASSET_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)+$")


def validate_asset_id(asset_id: str) -> str | None:
    """Return a validation error, or ``None`` when the ID is safe and stable."""

    if not asset_id:
        return "Asset ID is required."
    if not _ASSET_ID_PATTERN.fullmatch(asset_id):
        return (
            "Asset ID must be lowercase and contain at least two segments; "
            "use letters, numbers, dots, underscores, or hyphens."
        )
    return None


def split_list(value: str) -> list[str]:
    """Split comma-separated UI text into stable, de-duplicated values."""

    result: list[str] = []
    seen: set[str] = set()
    for item in value.split(","):
        item = item.strip()
        if item and item not in seen:
            result.append(item)
            seen.add(item)
    return result


def split_category_path(value: str) -> list[str]:
    """Accept ``Environment/Trees`` or comma-separated category paths."""

    normalized = value.replace(",", "/")
    return [part.strip() for part in normalized.split("/") if part.strip()]


def directions_for_mode(view_mode: str) -> tuple[str, ...]:
    try:
        return VIEW_DIRECTIONS[view_mode]
    except KeyError as error:
        raise ValueError(f"Unsupported view mode: {view_mode}") from error


def direction_angle_radians(direction: str) -> float:
    try:
        return math.radians(DIRECTION_ANGLES_DEGREES[direction])
    except KeyError as error:
        raise ValueError(f"Unsupported direction: {direction}") from error


def project_world_point(x: float, y: float, z: float) -> tuple[float, float]:
    """Project a Neura world point relative to the asset ground origin."""

    return (
        (x - y) * TILE_WIDTH / 2.0,
        (x + y) * TILE_HEIGHT / 2.0 - z * ELEVATION_PIXELS,
    )


def alpha_bounds(
    rgba: Sequence[float],
    width: int,
    height: int,
    threshold: float,
    margin: int,
) -> tuple[int, int, int, int] | None:
    """Find an alpha crop as ``(left, bottom, right, top)`` (exclusive max)."""

    if width <= 0 or height <= 0:
        raise ValueError("Image dimensions must be positive.")
    if len(rgba) != width * height * 4:
        raise ValueError("RGBA buffer length does not match its dimensions.")
    if not 0.0 <= threshold <= 1.0:
        raise ValueError("Alpha threshold must be between zero and one.")

    left = width
    bottom = height
    right = -1
    top = -1
    for y in range(height):
        row = y * width * 4
        for x in range(width):
            if rgba[row + x * 4 + 3] > threshold:
                left = min(left, x)
                bottom = min(bottom, y)
                right = max(right, x)
                top = max(top, y)
    if right < left:
        return None

    margin = max(0, int(margin))
    return (
        max(0, left - margin),
        max(0, bottom - margin),
        min(width, right + margin + 1),
        min(height, top + margin + 1),
    )


def crop_rgba(
    rgba: Sequence[float],
    width: int,
    bounds: tuple[int, int, int, int],
) -> tuple[list[float], int, int]:
    """Crop a bottom-up Blender RGBA pixel buffer."""

    left, bottom, right, top = bounds
    if not (0 <= left < right <= width):
        raise ValueError("Invalid horizontal crop bounds.")
    height = len(rgba) // (width * 4)
    if not (0 <= bottom < top <= height):
        raise ValueError("Invalid vertical crop bounds.")

    cropped_width = right - left
    cropped_height = top - bottom
    result: list[float] = []
    for y in range(bottom, top):
        start = (y * width + left) * 4
        result.extend(rgba[start : start + cropped_width * 4])
    return result, cropped_width, cropped_height


def write_data_rgba_png(
    path: Path,
    rgba: Sequence[float],
    width: int,
    height: int,
) -> None:
    """Write exact linear RGBA values as an untagged 8-bit data PNG.

    Blender's image save path applies display color management on some
    versions even for generated non-color images. Surface maps are data, not
    display color, so encode them directly and reverse Blender's bottom-up
    pixel rows into PNG's top-down scanline order.
    """

    if width <= 0 or height <= 0:
        raise ValueError("Image dimensions must be positive.")
    if len(rgba) != width * height * 4:
        raise ValueError("RGBA buffer length does not match its dimensions.")

    raw = bytearray()
    row_values = width * 4
    for y in range(height - 1, -1, -1):
        raw.append(0)  # PNG filter: None
        start = y * row_values
        for value in rgba[start : start + row_values]:
            raw.append(round(max(0.0, min(1.0, float(value))) * 255.0))

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    payload = bytearray(b"\x89PNG\r\n\x1a\n")
    payload.extend(
        chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0),
        )
    )
    payload.extend(chunk(b"IDAT", zlib.compress(bytes(raw), level=6)))
    payload.extend(chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def expand_bounds_to_point(
    bounds: tuple[int, int, int, int],
    width: int,
    height: int,
    x: float,
    y: float,
    margin: int,
) -> tuple[int, int, int, int]:
    """Ensure a floating-point image location and margin remain in the crop."""

    left, bottom, right, top = bounds
    margin = max(0, int(margin))
    point_left = math.floor(x) - margin
    point_bottom = math.floor(y) - margin
    point_right = math.ceil(x) + margin + 1
    point_top = math.ceil(y) + margin + 1
    return (
        max(0, min(left, point_left)),
        max(0, min(bottom, point_bottom)),
        min(width, max(right, point_right)),
        min(height, max(top, point_top)),
    )


def normalized_pivot(
    origin_x: float,
    origin_y_from_bottom: float,
    bounds: tuple[int, int, int, int],
) -> tuple[float, float]:
    """Convert the projected origin to Flame's normalized top-left anchor."""

    left, bottom, right, top = bounds
    width = right - left
    height = top - bottom
    if width <= 0 or height <= 0:
        raise ValueError("Crop bounds must have positive area.")
    return (
        (origin_x - left) / width,
        (top - origin_y_from_bottom) / height,
    )


def build_manifest(
    *,
    asset_id: str,
    name: str,
    source_pack: str,
    category_path: Iterable[str],
    tags: Iterable[str],
    view_mode: str,
    render_scale: float,
    render_band: str,
    views: Mapping[str, Mapping[str, object]],
    geometry: Mapping[str, object] | None = None,
    surface_map: Mapping[str, object] | None = None,
    shadow_proxy: Mapping[str, object] | None = None,
) -> dict[str, object]:
    error = validate_asset_id(asset_id)
    if error:
        raise ValueError(error)
    directions = directions_for_mode(view_mode)
    if set(views) != set(directions):
        raise ValueError(
            f"{view_mode} requires views {list(directions)}, got {list(views)}."
        )
    if surface_map:
        missing_surface_views = [
            direction
            for direction in directions
            if not views[direction].get("surfaceImage")
        ]
        if missing_surface_views:
            raise ValueError(
                "Surface-map metadata requires surfaceImage for views "
                f"{missing_surface_views}."
            )

    categories = [value for value in category_path if value]
    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "id": asset_id,
        "name": name.strip() or asset_id,
        "sourcePack": source_pack.strip() or "custom",
        "category": categories[-1] if categories else "Uncategorized",
        "categoryPath": categories or ["Uncategorized"],
        "viewMode": ENGINE_VIEW_MODES[view_mode],
        "renderScale": float(render_scale),
        "renderBand": render_band,
        "tags": list(tags),
        "views": dict(views),
    }
    if geometry:
        manifest["geometry"] = dict(geometry)
    if surface_map:
        manifest["surfaceMap"] = dict(surface_map)
    if shadow_proxy:
        manifest["shadowProxy"] = dict(shadow_proxy)
    return manifest


def build_surface_map_metadata(
    height_min: float,
    height_max: float,
) -> dict[str, object]:
    """Describe the packed per-view surface textures.

    Red and green contain an octahedral world-space normal. Blue contains
    asset-root-local Z normalized across the asset-wide height range. Alpha
    mirrors the corresponding albedo image.
    """

    height_min = float(height_min)
    height_max = float(height_max)
    if not math.isfinite(height_min) or not math.isfinite(height_max):
        raise ValueError("Surface-map height bounds must be finite.")
    if height_max <= height_min:
        raise ValueError("Surface-map height range must be positive.")
    return {
        "encoding": SURFACE_MAP_ENCODING,
        "normalSpace": "world",
        "heightSpace": "assetRootZ",
        "heightMin": round(height_min, 6),
        "heightMax": round(height_max, 6),
    }


def write_manifest(path: Path, manifest: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
