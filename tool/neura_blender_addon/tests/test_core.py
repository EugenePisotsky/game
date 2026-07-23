import json
import math
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "neura_asset_exporter"))

from core import (  # noqa: E402
    PIXELS_PER_CAMERA_UNIT,
    alpha_bounds,
    build_manifest,
    build_surface_map_metadata,
    crop_rgba,
    direction_angle_radians,
    directions_for_mode,
    expand_bounds_to_point,
    normalized_pivot,
    project_world_point,
    split_category_path,
    split_list,
    validate_asset_id,
    write_data_rgba_png,
    write_manifest,
)


class ProjectionTests(unittest.TestCase):
    def test_projection_matches_engine_basis(self):
        self.assertEqual(project_world_point(1, 0, 0), (64.0, 64.0 / math.sqrt(2)))
        self.assertEqual(project_world_point(0, 1, 0), (-64.0, 64.0 / math.sqrt(2)))
        self.assertEqual(project_world_point(0, 0, 1), (0.0, -64.0))
        self.assertAlmostEqual(PIXELS_PER_CAMERA_UNIT, 128.0 / math.sqrt(2))

    def test_direction_contract(self):
        self.assertEqual(directions_for_mode("FIXED"), ("south",))
        self.assertEqual(
            directions_for_mode("FOUR_WAY"), ("south", "west", "east", "north")
        )
        self.assertAlmostEqual(direction_angle_radians("west"), math.pi / 2)
        self.assertAlmostEqual(direction_angle_radians("east"), -math.pi / 2)


class ImageTests(unittest.TestCase):
    def test_alpha_crop_and_pivot_use_blender_bottom_up_coordinates(self):
        width = height = 5
        pixels = [0.0] * (width * height * 4)
        for y in range(1, 4):
            for x in range(2, 4):
                pixels[(y * width + x) * 4 + 3] = 1.0

        bounds = alpha_bounds(pixels, width, height, threshold=0.01, margin=0)
        self.assertEqual(bounds, (2, 1, 4, 4))
        cropped, cropped_width, cropped_height = crop_rgba(pixels, width, bounds)
        self.assertEqual((cropped_width, cropped_height), (2, 3))
        self.assertEqual(len(cropped), 2 * 3 * 4)
        self.assertEqual(normalized_pivot(3.0, 1.0, bounds), (0.5, 1.0))

    def test_crop_margin_is_clamped_to_canvas(self):
        pixels = [0.0] * (3 * 3 * 4)
        pixels[3] = 1.0
        self.assertEqual(alpha_bounds(pixels, 3, 3, 0.0, 10), (0, 0, 3, 3))

    def test_ground_origin_is_kept_in_crop(self):
        self.assertEqual(
            expand_bounds_to_point((4, 4, 8, 8), 12, 12, 6.0, 2.0, 1),
            (4, 1, 8, 8),
        )

    def test_transparent_image_has_no_bounds(self):
        self.assertIsNone(alpha_bounds([0.0] * 16, 2, 2, 0.0, 0))

    def test_data_png_preserves_bytes_and_flips_bottom_up_rows(self):
        bottom_red_top_green = [
            1.0,
            0.0,
            0.0,
            1.0,
            0.0,
            1.0,
            0.0,
            0.5,
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "surface.png"
            write_data_rgba_png(path, bottom_red_top_green, 1, 2)
            png = path.read_bytes()

        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        offset = 8
        compressed = bytearray()
        while offset < len(png):
            length = int.from_bytes(png[offset : offset + 4], "big")
            kind = png[offset + 4 : offset + 8]
            payload = png[offset + 8 : offset + 8 + length]
            if kind == b"IDAT":
                compressed.extend(payload)
            offset += 12 + length
        rows = zlib.decompress(compressed)
        self.assertEqual(rows, bytes((0, 0, 255, 0, 128, 0, 255, 0, 0, 255)))


class ManifestTests(unittest.TestCase):
    def test_asset_id_validation(self):
        self.assertIsNone(validate_asset_id("custom.village_well"))
        self.assertIsNotNone(validate_asset_id("Village Well"))
        self.assertIsNotNone(validate_asset_id("single"))

    def test_ui_lists_are_normalized(self):
        self.assertEqual(split_list("wood, village, wood"), ["wood", "village"])
        self.assertEqual(
            split_category_path("Structures / Village, Wells"),
            ["Structures", "Village", "Wells"],
        )

    def test_manifest_is_engine_shaped_and_serializable(self):
        views = {
            direction: {
                "image": f"{direction}.png",
                "logicalWidth": 128,
                "logicalHeight": 256,
                "pivotX": 0.5,
                "pivotY": 0.9,
                "surfaceImage": f"{direction}.surface.png",
            }
            for direction in directions_for_mode("FOUR_WAY")
        }
        manifest = build_manifest(
            asset_id="custom.village_well",
            name="Village Well",
            source_pack="custom",
            category_path=["Structures", "Village"],
            tags=["well", "stone"],
            view_mode="FOUR_WAY",
            render_scale=1.0,
            render_band="depthSorted",
            views=views,
            geometry={"blocking": [], "reviewed": False},
            surface_map=build_surface_map_metadata(0.0, 3.25),
            shadow_proxy={
                "type": "triangleMesh",
                "vertices": [
                    {"x": 0.0, "y": 0.0, "z": 0.0},
                    {"x": 1.0, "y": 0.0, "z": 0.0},
                    {"x": 0.0, "y": 1.0, "z": 1.0},
                ],
                "triangles": [[0, 1, 2]],
                "reviewed": False,
            },
        )
        self.assertEqual(manifest["viewMode"], "fourWay")
        self.assertEqual(manifest["category"], "Village")
        self.assertEqual(manifest["geometry"]["blocking"], [])
        self.assertEqual(manifest["views"]["south"]["image"], "south.png")
        self.assertEqual(
            manifest["surfaceMap"]["encoding"],
            "octahedralWorldNormalRGHeightB",
        )
        self.assertEqual(manifest["surfaceMap"]["heightMax"], 3.25)
        self.assertEqual(manifest["shadowProxy"]["type"], "triangleMesh")

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asset.json"
            write_manifest(path, manifest)
            self.assertEqual(json.loads(path.read_text()), manifest)

    def test_manifest_rejects_incomplete_views(self):
        with self.assertRaisesRegex(ValueError, "requires views"):
            build_manifest(
                asset_id="custom.bad",
                name="Bad",
                source_pack="custom",
                category_path=[],
                tags=[],
                view_mode="FOUR_WAY",
                render_scale=1.0,
                render_band="depthSorted",
                views={"south": {"image": "south.png"}},
            )

    def test_manifest_rejects_missing_surface_image(self):
        views = {
            "south": {
                "image": "south.png",
                "logicalWidth": 64,
                "logicalHeight": 64,
                "pivotX": 0.5,
                "pivotY": 1.0,
            }
        }
        with self.assertRaisesRegex(ValueError, "requires surfaceImage"):
            build_manifest(
                asset_id="custom.bad_surface",
                name="Bad Surface",
                source_pack="custom",
                category_path=[],
                tags=[],
                view_mode="FIXED",
                render_scale=1.0,
                render_band="depthSorted",
                views=views,
                surface_map=build_surface_map_metadata(0.0, 1.0),
            )

    def test_surface_map_metadata_rejects_empty_height_range(self):
        with self.assertRaisesRegex(ValueError, "range must be positive"):
            build_surface_map_metadata(2.0, 2.0)


if __name__ == "__main__":
    unittest.main()
