# Neura Asset Exporter for Blender

This Blender add-on renders static 3D models into the directional RGBA sprites
and metadata consumed by Neura. Version 0.1 supports fixed, four-way, and
eight-way environment objects. Animated characters and terrain materials are
outside this first version.

## Install

1. Create an installable Blender extension zip from the repository root:

   ```sh
   python3 tool/neura_blender_addon/build_zip.py
   ```

2. In Blender 4.2 or newer, open **Edit > Preferences > Add-ons**, choose
   **Install from Disk**, and select `neura_asset_exporter.zip`.
3. Enable **Neura Asset Exporter**.
4. Open the 3D View sidebar with `N` and select the **Neura** tab.

For add-on development, symlink or copy `neura_asset_exporter` into Blender's
user add-ons directory and reload scripts after changes.

## Author an asset

1. Press **Set Up Neura Scene**. The add-on creates:
   - `NEURA_ASSET_ROOT`, the ground contact and rotation origin;
   - `NEURA_CAMERA`, calibrated to the engine projection;
   - footprint, blocking, walkable, and selection collections.
   If an asset root is already selected in the panel, setup keeps it and aims
   the generated camera at its origin. Otherwise it creates
   `NEURA_ASSET_ROOT`. You never need to position or rotate the camera by hand;
   export also recreates it automatically if the configured camera is missing.
2. Model at real game scale: **one Blender unit is one Neura world unit**.
3. Parent every visible asset object to `NEURA_ASSET_ROOT`. Put the root at the
   asset's ground contact point. Do not parent the camera or lights to it.
4. Use an orthographic-friendly material and lighting setup. Everything that
   is render-visible in the scene is included, so hide reference meshes and
   guides from rendering.
5. Fill in the catalog metadata, choose a view count, and select an output
   directory.
6. Press **Export Neura Asset**.

The add-on rotates the asset root while keeping the camera and lighting fixed,
renders every required direction, crops transparent pixels, calculates the
ground pivot after cropping, restores the scene, and writes:

```text
<output>/<asset-id>/
  asset.json
  south.png
  west.png
  east.png
  north.png
  ...
```

The camera reproduces the engine projection exactly:

```text
screenX = (x - y) * 64
screenY = (x + y) * 45.2548 - z * 64
```

Canvas height determines the camera's visible world extent while pixel density
remains fixed at `90.5097` camera pixels per world unit. Increase both canvas
dimensions for large buildings rather than changing camera scale. The add-on
caps either dimension at 4096 pixels to keep Blender's render and crop buffers
within a practical memory budget.

## Geometry

Put non-rendering helper objects in these collections:

| Collection | Engine role |
| --- | --- |
| `NEURA_FOOTPRINT` | Depth-order ground extent |
| `NEURA_BLOCKING` | Impassable physical geometry |
| `NEURA_WALKABLE` | Walkable decks and surfaces |
| `NEURA_SELECTION` | Optional authored selection region |

Each helper has a **Neura shape** property in its Object properties. Supported
shapes are circle, ellipse, rectangle, capsule, and polygon. `Auto` exports a
mesh's largest face as a polygon and other objects as rectangles.

Geometry is exported in asset-root-local XY coordinates. Keep geometry helpers
out of the visible root hierarchy, and apply scale to geometry objects before
export when practical. The generated geometry is marked `reviewed: false` so it
can be checked and refined in Neura's geometry editor.

Do not trace the complete sprite silhouette. Trees should block at their trunk,
buildings at their walls, and bridges should use a walkable deck plus blockers
for rails where appropriate.

## Importer integration

`asset.json` intentionally uses the same object fields as Neura's environment
catalog. Version 0.1 produces a source package; it does not edit generated
catalogs or the Rust importer's reviewed configuration.

Until the importer has a custom-manifest scan command, copy the object entry
from `asset.json` into a reviewed catalog source and rewrite each view's image
path to its final package-relative location. Do not edit
`environment_catalog.json` directly because it is generated.

The next integration step is for `environment_importer build` to scan these
per-asset manifests, copy their PNGs into the editor cache, generate thumbnails,
and merge them before validation and release export.

## Test outside Blender

The projection, view mapping, alpha crop, pivot, validation, and manifest code
has no Blender dependency:

```sh
cd tool/neura_blender_addon
python3 -m unittest discover -s tests -v
```

The add-on itself must still receive a smoke test inside Blender because render
buffers, color management, and registration are Blender APIs.

## Troubleshooting

### Image dimensions must be positive

Version 0.1.3 disables Blender's saved render-region and crop-to-border state
during export, then restores it afterward. Those settings can otherwise make
Blender expose a zero-sized Render Result. It also writes a full PNG first and
uses that file when Blender's in-memory Render Result remains empty. Rebuild
and reinstall the zip, confirm that the Neura panel says **Version 0.1.3**, then
run **Set Up Neura Scene** once before exporting.

If Blender still reports an empty result, confirm that:

- the Output canvas width and height are at least 64;
- the scene uses Eevee or Cycles rather than an unavailable external engine;
- the asset meshes are enabled for rendering; and
- the asset root and its visible children are inside the camera canvas.
