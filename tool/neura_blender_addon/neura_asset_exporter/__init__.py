"""Blender add-on for authoring and exporting Neura isometric assets."""

from __future__ import annotations

import math
import traceback
from array import array
from pathlib import Path

import bpy
from bpy.props import (
    EnumProperty,
    FloatProperty,
    IntProperty,
    PointerProperty,
    StringProperty,
)
from bpy.types import Collection, Object, Operator, Panel, PropertyGroup
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

from .core import (
    PIXELS_PER_CAMERA_UNIT,
    alpha_bounds,
    build_manifest,
    direction_angle_radians,
    directions_for_mode,
    expand_bounds_to_point,
    normalized_pivot,
    split_category_path,
    split_list,
    validate_asset_id,
    write_manifest,
)


bl_info = {
    "name": "Neura Asset Exporter",
    "author": "Neura",
    "version": (0, 1, 3),
    "blender": (4, 2, 0),
    "location": "3D View > Sidebar > Neura",
    "description": "Render and export isometric sprite assets for Neura",
    "category": "Import-Export",
}


CAMERA_NAME = "NEURA_CAMERA"
ROOT_NAME = "NEURA_ASSET_ROOT"
HELPER_COLLECTION_NAME = "NEURA_EXPORT_HELPERS"
GEOMETRY_COLLECTION_NAMES = {
    "footprints": "NEURA_FOOTPRINT",
    "blocking": "NEURA_BLOCKING",
    "walkable": "NEURA_WALKABLE",
    "selection": "NEURA_SELECTION",
}


class NeuraExportSettings(PropertyGroup):
    asset_id: StringProperty(name="Asset ID", default="custom.asset")
    display_name: StringProperty(name="Name", default="Custom Asset")
    source_pack: StringProperty(name="Source pack", default="custom")
    category_path: StringProperty(
        name="Category path",
        default="Props/Custom",
        description="Slash-separated catalog path, for example Props/Custom",
    )
    tags: StringProperty(name="Tags", default="custom")
    render_band: EnumProperty(
        name="Render band",
        items=(
            ("groundCover", "Ground cover", "Draw beneath depth-sorted objects"),
            ("depthSorted", "Depth sorted", "Sort with actors and environment objects"),
            ("overhead", "Overhead", "Draw above the depth-sorted scene"),
            ("effects", "Effects", "Draw in the effects band"),
        ),
        default="depthSorted",
    )
    view_mode: EnumProperty(
        name="Views",
        items=(
            ("FIXED", "Fixed", "Render only the south view"),
            ("FOUR_WAY", "Four way", "Render south, west, east, and north"),
            ("EIGHT_WAY", "Eight way", "Render all eight directions"),
        ),
        default="FOUR_WAY",
    )
    render_scale: FloatProperty(name="Runtime scale", default=1.0, min=0.001)
    output_directory: StringProperty(
        name="Output directory",
        subtype="DIR_PATH",
        default="//neura_export",
    )
    asset_root: PointerProperty(name="Asset root", type=Object)
    export_camera: PointerProperty(name="Camera", type=Object)
    resolution_x: IntProperty(name="Canvas width", default=1024, min=64, max=4096)
    resolution_y: IntProperty(name="Canvas height", default=1024, min=64, max=4096)
    trim_margin: IntProperty(name="Trim margin", default=4, min=0, max=128)
    alpha_threshold: FloatProperty(
        name="Alpha threshold", default=0.001, min=0.0, max=1.0, precision=4
    )


def _link_object_to_collection(obj: Object, collection: Collection) -> None:
    if obj.name not in collection.objects:
        collection.objects.link(obj)


def _ensure_child_collection(scene: bpy.types.Scene, name: str) -> Collection:
    collection = bpy.data.collections.get(name)
    if collection is None:
        collection = bpy.data.collections.new(name)
    if collection.name not in scene.collection.children:
        scene.collection.children.link(collection)
    return collection


def _ensure_root(scene: bpy.types.Scene) -> Object:
    root = bpy.data.objects.get(ROOT_NAME)
    if root is None:
        root = bpy.data.objects.new(ROOT_NAME, None)
        root.empty_display_type = "PLAIN_AXES"
        root.empty_display_size = 1.0
        scene.collection.objects.link(root)
    return root


def _configure_camera(scene: bpy.types.Scene, target: Vector) -> Object:
    helper_collection = _ensure_child_collection(scene, HELPER_COLLECTION_NAME)
    camera = bpy.data.objects.get(CAMERA_NAME)
    if camera is None or camera.type != "CAMERA":
        camera_data = bpy.data.cameras.new(CAMERA_NAME)
        camera = bpy.data.objects.new(CAMERA_NAME, camera_data)
        _link_object_to_collection(camera, helper_collection)

    distance = 20.0
    camera.location = target + Vector((distance, distance, math.sqrt(2.0) * distance))
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = scene.render.resolution_y / PIXELS_PER_CAMERA_UNIT
    camera.data.lens = 50.0
    camera.data.clip_start = 0.01
    camera.data.clip_end = 1000.0
    scene.camera = camera
    return camera


def _ensure_geometry_collections(scene: bpy.types.Scene) -> None:
    for name in GEOMETRY_COLLECTION_NAMES.values():
        collection = _ensure_child_collection(scene, name)
        collection.hide_render = True


class NEURA_OT_setup_scene(Operator):
    bl_idname = "neura.setup_scene"
    bl_label = "Set Up Neura Scene"
    bl_description = "Create the export root, camera, and geometry collections"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        scene = context.scene
        settings = scene.neura_export
        root = settings.asset_root or _ensure_root(scene)
        settings.asset_root = root
        scene.render.resolution_x = settings.resolution_x
        scene.render.resolution_y = settings.resolution_y
        camera = _configure_camera(scene, root.matrix_world.translation)
        settings.export_camera = camera
        _ensure_geometry_collections(scene)
        scene.render.film_transparent = True
        scene.render.image_settings.file_format = "PNG"
        scene.render.image_settings.color_mode = "RGBA"
        self.report({"INFO"}, "Neura camera and authoring collections are ready")
        return {"FINISHED"}


def _root_local_matrix(root: Object, obj: Object) -> Matrix:
    return root.matrix_world.inverted_safe() @ obj.matrix_world


def _point(root: Object, obj: Object, coordinate: Vector) -> dict[str, float]:
    local = _root_local_matrix(root, obj) @ coordinate
    return {"x": round(local.x, 6), "y": round(local.y, 6)}


def _center(root: Object, obj: Object) -> dict[str, float]:
    local = _root_local_matrix(root, obj).translation
    return {"x": round(local.x, 6), "y": round(local.y, 6)}


def _local_xy_size(root: Object, obj: Object) -> tuple[float, float]:
    """Return unrotated XY dimensions expressed in asset-root world units."""

    local_matrix = _root_local_matrix(root, obj)
    scale = local_matrix.to_scale()
    if obj.type == "EMPTY":
        diameter = obj.empty_display_size * 2.0
        return abs(diameter * scale.x), abs(diameter * scale.y)
    corners = [Vector(corner) for corner in obj.bound_box]
    local_width = max(corner.x for corner in corners) - min(
        corner.x for corner in corners
    )
    local_height = max(corner.y for corner in corners) - min(
        corner.y for corner in corners
    )
    return abs(local_width * scale.x), abs(local_height * scale.y)


def _shape_for_object(root: Object, obj: Object) -> dict[str, object]:
    shape = obj.neura_shape
    local_matrix = _root_local_matrix(root, obj)
    scale = local_matrix.to_scale()
    width, height = _local_xy_size(root, obj)
    rotation = math.degrees(local_matrix.to_euler("XYZ").z)

    if shape == "AUTO":
        shape = "POLYGON" if obj.type == "MESH" else "RECTANGLE"
    if shape == "CIRCLE":
        return {
            "type": "circle",
            "center": _center(root, obj),
            "radius": round(max(width, height) / 2.0, 6),
        }
    if shape == "ELLIPSE":
        return {
            "type": "ellipse",
            "center": _center(root, obj),
            "radius": {"x": round(width / 2.0, 6), "y": round(height / 2.0, 6)},
        }
    if shape == "RECTANGLE":
        return {
            "type": "rectangle",
            "center": _center(root, obj),
            "size": {"x": round(width, 6), "y": round(height, 6)},
            "rotationDegrees": round(rotation, 6),
        }
    if shape == "CAPSULE":
        radius = height / 2.0
        half_segment = max(0.0, width / 2.0 - radius)
        start = local_matrix @ Vector((-half_segment / max(scale.x, 1e-9), 0.0, 0.0))
        end = local_matrix @ Vector((half_segment / max(scale.x, 1e-9), 0.0, 0.0))
        return {
            "type": "capsule",
            "start": {"x": round(start.x, 6), "y": round(start.y, 6)},
            "end": {"x": round(end.x, 6), "y": round(end.y, 6)},
            "radius": round(radius, 6),
        }
    if shape == "POLYGON":
        if obj.type != "MESH" or not obj.data.polygons:
            raise ValueError(f"{obj.name}: polygon geometry requires a mesh face")
        face = max(obj.data.polygons, key=lambda value: value.area)
        points = [_point(root, obj, obj.data.vertices[index].co) for index in face.vertices]
        if len(points) < 3:
            raise ValueError(f"{obj.name}: polygon geometry requires at least three points")
        return {"type": "polygon", "points": points}
    raise ValueError(f"{obj.name}: unsupported geometry shape {shape}")


def _export_geometry(root: Object) -> dict[str, object] | None:
    geometry: dict[str, object] = {}
    for role, collection_name in GEOMETRY_COLLECTION_NAMES.items():
        collection = bpy.data.collections.get(collection_name)
        if collection is None:
            continue
        shapes = [
            _shape_for_object(root, obj)
            for obj in collection.all_objects
            if obj.neura_shape != "IGNORE"
        ]
        if shapes or role == "blocking":
            geometry[role] = shapes
    if not geometry:
        return None
    geometry["reviewed"] = False
    return geometry


def _save_cropped_render(
    scene: bpy.types.Scene,
    camera: Object,
    ground_origin: Vector,
    output_path: Path,
    threshold: float,
    margin: int,
) -> dict[str, object]:
    render_result = bpy.data.images.get("Render Result")
    source_image = render_result
    remove_source_image = False
    if source_image is None or min(source_image.size) <= 0:
        if not output_path.is_file():
            raise RuntimeError(
                "Blender produced neither an in-memory Render Result nor a "
                "rendered PNG. Check the render engine in Output Properties."
            )
        source_image = bpy.data.images.load(str(output_path), check_existing=False)
        remove_source_image = True

    width, height = source_image.size
    if width <= 0 or height <= 0:
        if remove_source_image:
            bpy.data.images.remove(source_image)
        raise RuntimeError(
            f"Blender produced an empty {width}x{height} image at {output_path}."
        )
    pixels = array("f", [0.0]) * (width * height * 4)
    source_image.pixels.foreach_get(pixels)
    bounds = alpha_bounds(pixels, width, height, threshold, margin)
    if bounds is None:
        raise RuntimeError("The render is fully transparent")
    projected = world_to_camera_view(scene, camera, ground_origin)
    origin_x = projected.x * width
    origin_y = projected.y * height
    bounds = expand_bounds_to_point(
        bounds,
        width,
        height,
        origin_x,
        origin_y,
        margin,
    )
    left, bottom, right, top = bounds
    cropped_width = right - left
    cropped_height = top - bottom
    cropped = array("f")
    for y in range(bottom, top):
        start = (y * width + left) * 4
        cropped.extend(pixels[start : start + cropped_width * 4])
    pivot_x, pivot_y = normalized_pivot(
        origin_x,
        origin_y,
        bounds,
    )

    try:
        image = bpy.data.images.new(
            f"NEURA_EXPORT_{output_path.stem}",
            width=cropped_width,
            height=cropped_height,
            alpha=True,
            float_buffer=True,
        )
        try:
            image.pixels.foreach_set(cropped)
            image.alpha_mode = "PREMUL"
            image.filepath_raw = str(output_path)
            image.file_format = "PNG"
            image.save_render(str(output_path), scene=scene)
        finally:
            bpy.data.images.remove(image)
    finally:
        if remove_source_image:
            bpy.data.images.remove(source_image)

    return {
        "image": output_path.name,
        "logicalWidth": cropped_width,
        "logicalHeight": cropped_height,
        "pivotX": round(pivot_x, 8),
        "pivotY": round(pivot_y, 8),
    }


class _RenderState:
    def __init__(self, scene: bpy.types.Scene):
        render = scene.render
        self.scene = scene
        self.camera = scene.camera
        self.resolution_x = render.resolution_x
        self.resolution_y = render.resolution_y
        self.resolution_percentage = render.resolution_percentage
        self.filepath = render.filepath
        self.film_transparent = render.film_transparent
        self.use_border = render.use_border
        self.use_crop_to_border = render.use_crop_to_border
        self.file_format = render.image_settings.file_format
        self.color_mode = render.image_settings.color_mode
        self.color_depth = render.image_settings.color_depth

    def restore(self) -> None:
        render = self.scene.render
        self.scene.camera = self.camera
        render.resolution_x = self.resolution_x
        render.resolution_y = self.resolution_y
        render.resolution_percentage = self.resolution_percentage
        render.filepath = self.filepath
        render.film_transparent = self.film_transparent
        render.use_border = self.use_border
        render.use_crop_to_border = self.use_crop_to_border
        render.image_settings.file_format = self.file_format
        render.image_settings.color_mode = self.color_mode
        render.image_settings.color_depth = self.color_depth


class NEURA_OT_export_asset(Operator):
    bl_idname = "neura.export_asset"
    bl_label = "Export Neura Asset"
    bl_description = "Render directional PNGs and write asset.json"

    def execute(self, context):
        scene = context.scene
        settings = scene.neura_export
        error = validate_asset_id(settings.asset_id)
        if error:
            self.report({"ERROR"}, error)
            return {"CANCELLED"}
        root = settings.asset_root
        if root is None:
            self.report({"ERROR"}, "Choose an Asset root or run Set Up Neura Scene")
            return {"CANCELLED"}
        camera = settings.export_camera
        if camera is None or camera.type != "CAMERA":
            camera = _configure_camera(scene, root.matrix_world.translation)
            settings.export_camera = camera

        output_root = Path(bpy.path.abspath(settings.output_directory))
        asset_directory = output_root / settings.asset_id
        asset_directory.mkdir(parents=True, exist_ok=True)
        render_state = _RenderState(scene)
        original_root_matrix = root.matrix_world.copy()
        original_root_rotation_mode = root.rotation_mode
        root.rotation_mode = "XYZ"
        original_root_rotation = root.rotation_euler.copy()
        original_camera_matrix = camera.matrix_world.copy()
        original_camera_type = camera.data.type
        original_camera_ortho_scale = camera.data.ortho_scale
        ground_origin = original_root_matrix.translation.copy()
        views: dict[str, dict[str, object]] = {}

        try:
            scene.camera = camera
            scene.render.resolution_x = settings.resolution_x
            scene.render.resolution_y = settings.resolution_y
            scene.render.resolution_percentage = 100
            scene.render.film_transparent = True
            scene.render.use_border = False
            scene.render.use_crop_to_border = False
            scene.render.image_settings.file_format = "PNG"
            scene.render.image_settings.color_mode = "RGBA"
            scene.render.image_settings.color_depth = "8"
            camera.data.ortho_scale = settings.resolution_y / PIXELS_PER_CAMERA_UNIT
            camera.location = ground_origin + Vector((20.0, 20.0, math.sqrt(2.0) * 20.0))
            camera.rotation_euler = (ground_origin - camera.location).to_track_quat(
                "-Z", "Y"
            ).to_euler()

            for direction in directions_for_mode(settings.view_mode):
                root.rotation_euler = original_root_rotation
                root.rotation_euler.z = (
                    original_root_rotation.z + direction_angle_radians(direction)
                )
                context.view_layer.update()
                print(
                    "Neura: rendering "
                    f"{direction} at root Z "
                    f"{math.degrees(root.rotation_euler.z):.1f} degrees"
                )
                scene.render.filepath = str(asset_directory / f"{direction}.png")
                bpy.ops.render.render(write_still=True)
                views[direction] = _save_cropped_render(
                    scene,
                    camera,
                    ground_origin,
                    asset_directory / f"{direction}.png",
                    settings.alpha_threshold,
                    settings.trim_margin,
                )

            root.matrix_world = original_root_matrix
            root.rotation_mode = original_root_rotation_mode
            context.view_layer.update()
            geometry = _export_geometry(root)
            manifest = build_manifest(
                asset_id=settings.asset_id,
                name=settings.display_name,
                source_pack=settings.source_pack,
                category_path=split_category_path(settings.category_path),
                tags=split_list(settings.tags),
                view_mode=settings.view_mode,
                render_scale=settings.render_scale,
                render_band=settings.render_band,
                views=views,
                geometry=geometry,
            )
            write_manifest(asset_directory / "asset.json", manifest)
        except Exception as error:
            traceback.print_exc()
            self.report({"ERROR"}, f"Neura export failed: {error}")
            return {"CANCELLED"}
        finally:
            root.matrix_world = original_root_matrix
            camera.matrix_world = original_camera_matrix
            camera.data.type = original_camera_type
            camera.data.ortho_scale = original_camera_ortho_scale
            render_state.restore()
            context.view_layer.update()

        self.report({"INFO"}, f"Exported {settings.asset_id} to {asset_directory}")
        return {"FINISHED"}


class NEURA_PT_export_panel(Panel):
    bl_label = "Neura Asset Exporter"
    bl_idname = "NEURA_PT_export_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Neura"

    def draw(self, context):
        layout = self.layout
        settings = context.scene.neura_export
        layout.label(text="Version 0.1.2")
        layout.operator(NEURA_OT_setup_scene.bl_idname, icon="SCENE_DATA")

        metadata = layout.box()
        metadata.label(text="Catalog")
        metadata.prop(settings, "asset_id")
        metadata.prop(settings, "display_name")
        metadata.prop(settings, "source_pack")
        metadata.prop(settings, "category_path")
        metadata.prop(settings, "tags")
        metadata.prop(settings, "render_band")

        rendering = layout.box()
        rendering.label(text="Rendering")
        rendering.prop(settings, "asset_root")
        rendering.prop(settings, "export_camera")
        rendering.prop(settings, "view_mode")
        rendering.prop(settings, "render_scale")
        row = rendering.row(align=True)
        row.prop(settings, "resolution_x")
        row.prop(settings, "resolution_y")
        rendering.prop(settings, "alpha_threshold")
        rendering.prop(settings, "trim_margin")

        geometry = layout.box()
        geometry.label(text="Selected Geometry")
        selected = context.active_object
        if selected is None:
            geometry.label(text="Select a geometry helper", icon="INFO")
        else:
            geometry.label(text=selected.name, icon="OBJECT_DATA")
            geometry.prop(selected, "neura_shape")

        output = layout.box()
        output.label(text="Output")
        output.prop(settings, "output_directory")
        output.operator(NEURA_OT_export_asset.bl_idname, icon="EXPORT")


CLASSES = (
    NeuraExportSettings,
    NEURA_OT_setup_scene,
    NEURA_OT_export_asset,
    NEURA_PT_export_panel,
)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    bpy.types.Scene.neura_export = PointerProperty(type=NeuraExportSettings)
    bpy.types.Object.neura_shape = EnumProperty(
        name="Neura shape",
        items=(
            ("AUTO", "Auto", "Polygon for meshes, rectangle for other objects"),
            ("CIRCLE", "Circle", "Use the largest XY dimension as a diameter"),
            ("ELLIPSE", "Ellipse", "Use the object's XY dimensions as diameters"),
            ("RECTANGLE", "Rectangle", "Use XY dimensions and Z rotation"),
            ("CAPSULE", "Capsule", "Use local X as length and local Y as diameter"),
            ("POLYGON", "Polygon", "Use the largest mesh face"),
            ("IGNORE", "Ignore", "Do not export this geometry object"),
        ),
        default="AUTO",
    )


def unregister():
    del bpy.types.Object.neura_shape
    del bpy.types.Scene.neura_export
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
