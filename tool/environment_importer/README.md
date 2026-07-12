# Neura environment importer

This Rust CLI converts purchased Other Worlds source files into deterministic,
runtime-ready Neura assets. The first rule set imports Core Tiles 3 ground,
trees, bushes, grass, and rocks.

Run commands from the repository root:

```bash
cargo run --manifest-path tool/environment_importer/Cargo.toml -- scan
cargo run --manifest-path tool/environment_importer/Cargo.toml -- build
cargo run --manifest-path tool/environment_importer/Cargo.toml -- check
```

- `scan` validates source families and writes `environment_discovered.json`.
- `build` also copies runtime PNGs, generates 192 x 192 thumbnails, merges
  overrides and manual entries, and writes `environment_catalog.json`.
- `check` is read-only and fails when the manifest, catalog, or copied images
  are stale. It is suitable for CI.

## Files

- `rules.json` defines source paths, filename patterns, view counts, category
  defaults, pivots, scales, and collision profiles.
- `overrides.json` contains small human-reviewed corrections keyed by the
  generated stable ID. It may replace the final ID/name, tune scale/pivot,
  attach tags, change collision profile, or exclude an asset.
- `manual_catalog.json` retains assets not covered by the current automatic
  rules, such as the prototype buildings, fence, and dock.
- `environment_discovered.json` records source paths, dimensions, and SHA-256
  hashes so source changes are visible and reproducible.

Never hand-edit `environment_catalog.json` or files below
`assets/images/environment_generated`; rebuild them through this tool.

Full generated PNGs and thumbnails are an editor-side source library and are
loaded from the workspace on demand. A future world-export step must package
the images referenced by that world; bundling the complete library in every
game or test would add roughly 200 MB and decode far more art than a scene
needs.

The macOS editor and game debug profiles therefore run without the macOS app
sandbox so they can read this workspace library during development. Release
profiles remain sandboxed; the planned world-export step must copy referenced
images into the release bundle instead of depending on repository paths.

## Stable IDs and views

Automatic IDs use the pack, kind, and zero-padded source family number:

```text
ow3.ground.017
ow3.tree.012
ow3.bush.007
ow3.grass.022
ow3.rock.004
```

Directional suffixes follow the vendor order: south, west, east, north,
south-west, north-west, south-east, north-east. Four-view families use the
first four directions. A directionless source such as `Rock24.png` is copied
to all required view slots and reported as a warning.

## Adding another category

Add one explicit rule to `rules.json`; avoid a universal filename heuristic.
Every directional family must contain exactly `1..expectedViews`, otherwise
the import fails with the incomplete family. Extend the Rust model only when a
new asset type has genuinely different semantics, such as animated props or
terrain topology.
