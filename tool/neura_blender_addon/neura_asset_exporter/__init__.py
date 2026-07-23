"""Blender add-on for authoring and exporting Neura isometric assets."""

from __future__ import annotations

import math
import traceback
from array import array
from pathlib import Path

import bpy
from bpy.props import (
    BoolProperty,
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
    build_surface_map_metadata,
    direction_angle_radians,
    directions_for_mode,
    expand_bounds_to_point,
    normalized_pivot,
    split_category_path,
    split_list,
    validate_asset_id,
    write_data_rgba_png,
    write_manifest,
)


bl_info = {
    "name": "Neura Asset Exporter",
    "author": "Neura",
    "version": (0, 3, 0),
    "blender": (4, 2, 0),
    "location": "3D View > Sidebar > Neura",
    "description": "Render and export isometric sprite assets for Neura",
    "category": "Import-Export",
}


CAMERA_NAME = "NEURA_CAMERA"
ROOT_NAME = "NEURA_ASSET_ROOT"
HELPER_COLLECTION_NAME = "NEURA_EXPORT_HELPERS"
SHADOW_COLLECTION_NAME = "NEURA_SHADOW"
MAX_SHADOW_PROXY_TRIANGLES = 32
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
    export_surface_maps: BoolProperty(
        name="Export lighting surface maps",
        description=(
            "Export aligned world-normal and root-height data for dynamic lighting"
        ),
        default=True,
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
    for name in (*GEOMETRY_COLLECTION_NAMES.values(), SHADOW_COLLECTION_NAME):
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


def _export_shadow_proxy(
    context: bpy.types.Context,
    root: Object,
) -> dict[str, object] | None:
    """Export one deliberately small mesh used only for cast shadows."""

    collection = bpy.data.collections.get(SHADOW_COLLECTION_NAME)
    if collection is None:
        return None
    meshes = [obj for obj in collection.all_objects if obj.type == "MESH"]
    if not meshes:
        return None
    if len(meshes) != 1:
        raise ValueError(
            f"{SHADOW_COLLECTION_NAME} must contain exactly one mesh; "
            f"found {len(meshes)}"
        )

    obj = meshes[0]
    dependency_graph = context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(dependency_graph)
    mesh = evaluated.to_mesh()
    try:
        mesh.calc_loop_triangles()
        triangles = [list(value.vertices) for value in mesh.loop_triangles]
        if not triangles:
            raise ValueError(f"{obj.name}: shadow proxy mesh has no faces")
        if len(triangles) > MAX_SHADOW_PROXY_TRIANGLES:
            raise ValueError(
                f"{obj.name}: shadow proxy has {len(triangles)} triangles; "
                f"the limit is {MAX_SHADOW_PROXY_TRIANGLES}"
            )
        local_matrix = root.matrix_world.inverted_safe() @ evaluated.matrix_world
        vertices = []
        for vertex in mesh.vertices:
            point = local_matrix @ vertex.co
            vertices.append(
                {
                    "x": round(point.x, 6),
                    "y": round(point.y, 6),
                    "z": round(point.z, 6),
                }
            )
        return {
            "type": "triangleMesh",
            "vertices": vertices,
            "triangles": triangles,
            "reviewed": False,
        }
    finally:
        evaluated.to_mesh_clear()


def _root_hierarchy(root: Object) -> list[Object]:
    result: list[Object] = []
    pending = [root]
    while pending:
        obj = pending.pop()
        result.append(obj)
        pending.extend(obj.children)
    return result


def _is_non_rendering_helper(obj: Object) -> bool:
    helper_names = {
        *GEOMETRY_COLLECTION_NAMES.values(),
        SHADOW_COLLECTION_NAME,
        HELPER_COLLECTION_NAME,
    }
    return any(collection.name in helper_names for collection in obj.users_collection)


def _asset_height_range(
    context: bpy.types.Context,
    root: Object,
) -> tuple[float, float]:
    """Return visible geometry bounds in asset-root-local Z units."""

    geometry_types = {"MESH", "CURVE", "SURFACE", "META", "FONT"}
    root_inverse = root.matrix_world.inverted_safe()
    dependency_graph = context.evaluated_depsgraph_get()
    heights: list[float] = [0.0]
    for obj in _root_hierarchy(root):
        if (
            obj.type not in geometry_types
            or obj.hide_render
            or _is_non_rendering_helper(obj)
        ):
            continue
        evaluated = obj.evaluated_get(dependency_graph)
        for corner in evaluated.bound_box:
            point = root_inverse @ evaluated.matrix_world @ Vector(corner)
            heights.append(point.z)
    if len(heights) == 1:
        raise ValueError(
            "Asset root has no renderable geometry children for a surface map"
        )

    height_min = min(heights)
    height_max = max(heights)
    if height_max - height_min < 1e-6:
        height_max = height_min + 1.0
    return height_min, height_max


def _math_node(nodes, operation: str, first=None, second=None):
    node = nodes.new("ShaderNodeMath")
    node.operation = operation
    if first is not None:
        node.inputs[0].default_value = first
    if second is not None:
        node.inputs[1].default_value = second
    return node


def _create_surface_material(
    root: Object,
    height_min: float,
    height_max: float,
) -> bpy.types.Material:
    """Create a temporary emission material packing normal RG and height B."""

    z_axis = root.matrix_world.to_3x3() @ Vector((0.0, 0.0, 1.0))
    if abs(z_axis.x) > 1e-5 or abs(z_axis.y) > 1e-5 or z_axis.z <= 0.0:
        raise ValueError(
            "NEURA_ASSET_ROOT may rotate around Z, but its local Z axis must "
            "remain upright for height-map export"
        )
    world_height_min = root.matrix_world.translation.z + height_min * z_axis.z
    world_height_range = (height_max - height_min) * z_axis.z

    material = bpy.data.materials.new("NEURA_SURFACE_EXPORT")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()

    geometry = nodes.new("ShaderNodeNewGeometry")
    normal = nodes.new("ShaderNodeVectorMath")
    normal.operation = "NORMALIZE"
    links.new(geometry.outputs["Normal"], normal.inputs[0])

    absolute = nodes.new("ShaderNodeVectorMath")
    absolute.operation = "ABSOLUTE"
    links.new(normal.outputs["Vector"], absolute.inputs[0])
    normal_sum = nodes.new("ShaderNodeVectorMath")
    normal_sum.operation = "DOT_PRODUCT"
    normal_sum.inputs[1].default_value = (1.0, 1.0, 1.0)
    links.new(absolute.outputs["Vector"], normal_sum.inputs[0])
    denominator = nodes.new("ShaderNodeCombineXYZ")
    for value_input in denominator.inputs:
        links.new(normal_sum.outputs["Value"], value_input)
    projected = nodes.new("ShaderNodeVectorMath")
    projected.operation = "DIVIDE"
    links.new(normal.outputs["Vector"], projected.inputs[0])
    links.new(denominator.outputs["Vector"], projected.inputs[1])
    components = nodes.new("ShaderNodeSeparateXYZ")
    links.new(projected.outputs["Vector"], components.inputs[0])

    abs_x = _math_node(nodes, "ABSOLUTE")
    abs_y = _math_node(nodes, "ABSOLUTE")
    sign_x = _math_node(nodes, "SIGN")
    sign_y = _math_node(nodes, "SIGN")
    links.new(components.outputs["X"], abs_x.inputs[0])
    links.new(components.outputs["Y"], abs_y.inputs[0])
    links.new(components.outputs["X"], sign_x.inputs[0])
    links.new(components.outputs["Y"], sign_y.inputs[0])
    one_minus_abs_y = _math_node(nodes, "SUBTRACT", 1.0)
    one_minus_abs_x = _math_node(nodes, "SUBTRACT", 1.0)
    links.new(abs_y.outputs[0], one_minus_abs_y.inputs[1])
    links.new(abs_x.outputs[0], one_minus_abs_x.inputs[1])
    folded_x = _math_node(nodes, "MULTIPLY")
    folded_y = _math_node(nodes, "MULTIPLY")
    links.new(one_minus_abs_y.outputs[0], folded_x.inputs[0])
    links.new(sign_x.outputs[0], folded_x.inputs[1])
    links.new(one_minus_abs_x.outputs[0], folded_y.inputs[0])
    links.new(sign_y.outputs[0], folded_y.inputs[1])

    lower_hemisphere = _math_node(nodes, "LESS_THAN", second=0.0)
    links.new(components.outputs["Z"], lower_hemisphere.inputs[0])
    upper_hemisphere = _math_node(nodes, "SUBTRACT", 1.0)
    links.new(lower_hemisphere.outputs[0], upper_hemisphere.inputs[1])

    encoded_components = []
    for original, folded in (
        (components.outputs["X"], folded_x.outputs[0]),
        (components.outputs["Y"], folded_y.outputs[0]),
    ):
        original_weighted = _math_node(nodes, "MULTIPLY")
        folded_weighted = _math_node(nodes, "MULTIPLY")
        combined = _math_node(nodes, "ADD")
        scaled = _math_node(nodes, "MULTIPLY", second=0.5)
        encoded = _math_node(nodes, "ADD", second=0.5)
        links.new(original, original_weighted.inputs[0])
        links.new(upper_hemisphere.outputs[0], original_weighted.inputs[1])
        links.new(folded, folded_weighted.inputs[0])
        links.new(lower_hemisphere.outputs[0], folded_weighted.inputs[1])
        links.new(original_weighted.outputs[0], combined.inputs[0])
        links.new(folded_weighted.outputs[0], combined.inputs[1])
        links.new(combined.outputs[0], scaled.inputs[0])
        links.new(scaled.outputs[0], encoded.inputs[0])
        encoded_components.append(encoded.outputs[0])

    position = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geometry.outputs["Position"], position.inputs[0])
    height_offset = _math_node(nodes, "SUBTRACT", second=world_height_min)
    links.new(position.outputs["Z"], height_offset.inputs[0])
    height = _math_node(nodes, "DIVIDE", second=world_height_range)
    height.use_clamp = True
    links.new(height_offset.outputs[0], height.inputs[0])

    packed = nodes.new("ShaderNodeCombineColor")
    packed.mode = "RGB"
    links.new(encoded_components[0], packed.inputs[0])
    links.new(encoded_components[1], packed.inputs[1])
    links.new(height.outputs[0], packed.inputs[2])
    emission = nodes.new("ShaderNodeEmission")
    links.new(packed.outputs[0], emission.inputs[0])
    output = nodes.new("ShaderNodeOutputMaterial")
    links.new(emission.outputs[0], output.inputs["Surface"])
    return material


def _use_eevee(render: bpy.types.RenderSettings) -> None:
    """Select Eevee across Blender 4.x and 5.x engine identifier changes."""

    try:
        render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        render.engine = "BLENDER_EEVEE"


def _save_cropped_render(
    scene: bpy.types.Scene,
    camera: Object,
    ground_origin: Vector,
    output_path: Path,
    threshold: float,
    margin: int,
    bounds: tuple[int, int, int, int] | None = None,
    alpha_source: array | None = None,
    data_map: bool = False,
) -> tuple[dict[str, object], tuple[int, int, int, int], array]:
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
    projected = world_to_camera_view(scene, camera, ground_origin)
    origin_x = projected.x * width
    origin_y = projected.y * height
    if bounds is None:
        bounds = alpha_bounds(pixels, width, height, threshold, margin)
        if bounds is None:
            raise RuntimeError("The render is fully transparent")
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
    if alpha_source is not None:
        if len(alpha_source) != len(cropped):
            raise ValueError("Surface map and albedo crop dimensions do not match")
        for offset in range(3, len(cropped), 4):
            cropped[offset] = alpha_source[offset]
    pivot_x, pivot_y = normalized_pivot(
        origin_x,
        origin_y,
        bounds,
    )

    try:
        if data_map:
            write_data_rgba_png(
                output_path,
                cropped,
                cropped_width,
                cropped_height,
            )
        else:
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

    return (
        {
            "image": output_path.name,
            "logicalWidth": cropped_width,
            "logicalHeight": cropped_height,
            "pivotX": round(pivot_x, 8),
            "pivotY": round(pivot_y, 8),
        },
        bounds,
        cropped,
    )


class _RenderState:
    def __init__(self, scene: bpy.types.Scene, view_layer: bpy.types.ViewLayer):
        render = scene.render
        self.scene = scene
        self.view_layer = view_layer
        self.camera = scene.camera
        self.engine = render.engine
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
        self.material_override = view_layer.material_override
        self.view_transform = scene.view_settings.view_transform
        self.look = scene.view_settings.look
        self.exposure = scene.view_settings.exposure
        self.gamma = scene.view_settings.gamma

    def restore_color_and_engine(self) -> None:
        render = self.scene.render
        render.engine = self.engine
        self.view_layer.material_override = self.material_override
        self.scene.view_settings.view_transform = self.view_transform
        self.scene.view_settings.look = self.look
        self.scene.view_settings.exposure = self.exposure
        self.scene.view_settings.gamma = self.gamma

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
        self.restore_color_and_engine()


class NEURA_OT_export_asset(Operator):
    bl_idname = "neura.export_asset"
    bl_label = "Export Neura Asset"
    bl_description = (
        "Render directional albedo and lighting-data PNGs and write asset.json"
    )

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
        render_state = _RenderState(scene, context.view_layer)
        original_root_matrix = root.matrix_world.copy()
        original_root_rotation_mode = root.rotation_mode
        root.rotation_mode = "XYZ"
        original_root_rotation = root.rotation_euler.copy()
        original_camera_matrix = camera.matrix_world.copy()
        original_camera_type = camera.data.type
        original_camera_ortho_scale = camera.data.ortho_scale
        ground_origin = original_root_matrix.translation.copy()
        views: dict[str, dict[str, object]] = {}
        surface_material = None
        surface_map = None
        shadow_proxy = None

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
            if settings.export_surface_maps:
                height_min, height_max = _asset_height_range(context, root)
                surface_material = _create_surface_material(
                    root,
                    height_min,
                    height_max,
                )
                surface_map = build_surface_map_metadata(height_min, height_max)

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
                view, crop_bounds, albedo_pixels = _save_cropped_render(
                    scene,
                    camera,
                    ground_origin,
                    asset_directory / f"{direction}.png",
                    settings.alpha_threshold,
                    settings.trim_margin,
                )
                views[direction] = view

                if surface_material is not None:
                    surface_path = asset_directory / f"{direction}.surface.png"
                    context.view_layer.material_override = surface_material
                    _use_eevee(scene.render)
                    scene.view_settings.view_transform = "Raw"
                    scene.view_settings.look = "None"
                    scene.view_settings.exposure = 0.0
                    scene.view_settings.gamma = 1.0
                    scene.render.filepath = str(surface_path)
                    bpy.ops.render.render(write_still=True)
                    _save_cropped_render(
                        scene,
                        camera,
                        ground_origin,
                        surface_path,
                        settings.alpha_threshold,
                        settings.trim_margin,
                        bounds=crop_bounds,
                        alpha_source=albedo_pixels,
                        data_map=True,
                    )
                    view["surfaceImage"] = surface_path.name
                    render_state.restore_color_and_engine()

            root.matrix_world = original_root_matrix
            root.rotation_mode = original_root_rotation_mode
            context.view_layer.update()
            geometry = _export_geometry(root)
            shadow_proxy = _export_shadow_proxy(context, root)
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
                surface_map=surface_map,
                shadow_proxy=shadow_proxy,
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
            if surface_material is not None:
                bpy.data.materials.remove(surface_material)
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
        layout.label(text="Version 0.3.0")
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
        rendering.prop(settings, "export_surface_maps")

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
