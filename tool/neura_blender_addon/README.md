# Neura Asset Exporter for Blender

This Blender add-on renders static 3D models into the directional RGBA sprites
and metadata consumed by Neura. Version 0.3 supports fixed, four-way, and
eight-way environment objects plus aligned normal/height surface maps for the
dynamic-lighting pipeline and low-poly 3D cast-shadow proxies. Animated
characters and terrain materials are outside this version.

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
   - footprint, blocking, walkable, selection, and shadow-proxy collections.
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
5. Leave **Export lighting surface maps** enabled unless the asset deliberately
   does not participate in dynamic lighting. The root may rotate around its Z
   axis, but its local Z axis must remain upright. Apply tilted root transforms
   before export.
6. Fill in the catalog metadata, choose a view count, and select an output
   directory.
7. Press **Export Neura Asset**.

The add-on rotates the asset root while keeping the camera and lighting fixed,
renders every required direction, crops transparent pixels, calculates the
ground pivot after cropping, restores the scene, and writes:

```text
<output>/<asset-id>/
  asset.json
  south.png
  south.surface.png
  west.png
  west.surface.png
  east.png
  east.surface.png
  north.png
  north.surface.png
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

## Lighting surface maps

When **Export lighting surface maps** is enabled, every albedo view gets a
matching `<direction>.surface.png`. The exporter renders this pass with an
unlit temporary material; the scene's materials and render settings are
restored afterward. A surface map always has exactly the same dimensions,
crop, alpha silhouette, and pivot as its albedo view.

The packed 8-bit RGBA contract is:

| Channel | Data |
| --- | --- |
| R, G | Octahedrally encoded world-space surface normal |
| B | Asset-root-local Z normalized between `heightMin` and `heightMax` |
| A | Corresponding albedo alpha |

`asset.json` records the surface filename in each view and describes the
encoding once at asset level:

```json
{
  "views": {
    "south": {
      "image": "south.png",
      "surfaceImage": "south.surface.png"
    }
  },
  "surfaceMap": {
    "encoding": "octahedralWorldNormalRGHeightB",
    "normalSpace": "world",
    "heightSpace": "assetRootZ",
    "heightMin": 0.0,
    "heightMax": 2.4
  }
}
```

Runtime height decoding is
`heightMin + blue * (heightMax - heightMin)`. Octahedral normal decoding must
use the sampled red and green values as the encoded two-dimensional vector.
The data PNG is written without a display color profile; load and sample it as
non-color linear data, never as an sRGB texture.

The pass adds one Eevee render per direction. It is intended as a source asset,
so this increases export time but does not affect runtime performance. Original
material alpha is copied from the albedo render, allowing cutout assets to keep
their silhouette even though the temporary surface material is opaque.

## Cast-shadow proxy

A directional surface map contains only the surfaces visible to its render
camera. It is suitable for lighting that sprite, but it cannot describe hidden
walls and roof faces well enough to cast correct shadows for every light angle.

For assets that cast substantial shadows, put one closed, low-poly mesh in
`NEURA_SHADOW`. Shape it like the asset's solid mass, not like every decorative
detail. A house proxy should normally contain its wall volume and pitched roof;
a barrel can use a coarse 8-sided cylinder. Keep it in asset-root-local space.
The collection never appears in the albedo or surface renders.

Export writes the evaluated proxy as root-local vertices and triangles under
`shadowProxy` in `asset.json`. The runtime limit is 32 triangles, and export
fails with a clear error if the proxy exceeds it. Use modifiers only when their
evaluated result remains within that budget. The proxy metadata is marked
`reviewed: false` until it has been checked in the editor's lighting preview.

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
catalog. Version 0.3 produces a source package; it does not edit generated
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

Version 0.3.0 disables Blender's saved render-region and crop-to-border state
during export, then restores it afterward. Those settings can otherwise make
Blender expose a zero-sized Render Result. It also writes a full PNG first and
uses that file when Blender's in-memory Render Result remains empty. Rebuild
and reinstall the zip, confirm that the Neura panel says **Version 0.3.0**, then
run **Set Up Neura Scene** once before exporting.

If Blender still reports an empty result, confirm that:

- the Output canvas width and height are at least 64;
- the scene uses Eevee or Cycles rather than an unavailable external engine;
- the asset meshes are enabled for rendering; and
- the asset root and its visible children are inside the camera canvas.
