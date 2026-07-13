# Neura environment importer

This Rust CLI converts purchased Other Worlds source files into deterministic,
runtime-ready Neura assets. The first rule set imports Core Tiles 3 ground,
trees, bushes, grass, and rocks.

Run commands from the repository root:

```bash
cargo run --manifest-path tool/environment_importer/Cargo.toml -- scan
cargo run --manifest-path tool/environment_importer/Cargo.toml -- build
cargo run --manifest-path tool/environment_importer/Cargo.toml -- build-world
cargo run --manifest-path tool/environment_importer/Cargo.toml -- export-world
cargo run --manifest-path tool/environment_importer/Cargo.toml -- check
```

- `scan` validates source families and writes `environment_discovered.json`.
- `build` also copies runtime PNGs, generates 192 x 192 thumbnails, merges
  overrides and manual entries, and writes `environment_catalog.json`.
- `build-world` deterministically splits the authored world into 32 x 32
  environment chunks.
- `export-world` follows the generated chunks, filters non-exported layers,
  resolves only referenced material and directional object images, rewrites
  them to bundle-local paths, and emits an asset-size report.
- `check` is read-only and fails when the source manifest, catalog, copied
  images, chunked world, release references, or release byte budget are stale.
  `check-world` and `check-release` are also available as focused checks.

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

Full generated PNGs and thumbnails are an editor-side source library loaded
from the workspace on demand. The release export under
`packages/neura_assets/assets/release` contains only the images referenced by
the exported chunks. The game reads that package through Flutter's asset
bundle in debug and release modes; it never searches for a repository.

The macOS editor remains unsandboxed during development because it authors
workspace catalogs and chunks. The game is sandboxed in every macOS profile.
Its release catalog contains hashed bundle-local paths and the validator
rejects unresolved references, stale files, unexpected files, and packages
over the configured byte limit.

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
