# Neura environment importer

This Rust CLI converts purchased Other Worlds source files into deterministic,
runtime-ready Neura assets. Its reviewed registry covers Core Tiles 1, 2, and
3: ground, water, vegetation, buildings, structures, furniture, props, small
items, and dungeon art. Opaque `WaterTile` sources receive deterministic
soft-edged brush decals during `build`; their original images remain the
repeating textures.

Run commands from the repository root:

```bash
cargo run --manifest-path tool/environment_importer/Cargo.toml -- scan
cargo run --manifest-path tool/environment_importer/Cargo.toml -- build
cargo run --manifest-path tool/environment_importer/Cargo.toml -- check-assets
cargo run --manifest-path tool/environment_importer/Cargo.toml -- build-world
cargo run --manifest-path tool/environment_importer/Cargo.toml -- clear-world --yes
cargo run --manifest-path tool/environment_importer/Cargo.toml -- export-world
cargo run --manifest-path tool/environment_importer/Cargo.toml -- check
```

- `scan` inventories every source PNG, validates source families, and writes
  `environment_discovered.json`. Each source is classified, deferred,
  excluded, invalid, or unclassified.
- `build` also copies runtime PNGs, generates 192 x 192 thumbnails, merges
  overrides and manual entries, and writes `environment_catalog.json`.
- `check-assets` verifies only source discovery, the generated visual catalog,
  copied images, and thumbnails. It never checks or writes authored worlds,
  chunks, or release exports.
- `build-world` is a legacy/bootstrap command that deterministically splits the
  starter document into 32 x 32 chunks. It overwrites the editable manifest
  and chunks; do not run it after resizing or authoring the world in the
  editor.
- `clear-world --yes` destructively resets every authored chunk to the base
  material, clears objects, paint, overlaps, travel points, and custom layers,
  and places the player at the center of chunk `0_0`. It preserves the current
  dimensions and chunk grid.
- `check-world` validates the editable manifest, complete rectangular chunk
  grid, player spawn, and chunk identities directly. The authored chunk files
  are the source of truth after bootstrap.
- `export-world` follows the generated chunks, filters non-exported layers,
  resolves only referenced material and directional object images, rewrites
  them to bundle-local paths, and emits an asset-size report. Duplicate placed
  object IDs are reported with both owning chunks, assets, and world positions;
  the editor's **Build release** flow can repair legacy collisions and continue.
- `check` is read-only and fails when the source manifest, catalog, copied
  images, chunked world, release references, or release byte budget are stale.
  `check-world` and `check-release` are also available as focused checks.

## Files

- `rules.json` defines source packs, filename patterns, supported view counts,
  category defaults, pivots, scales, and collision profiles. `sourcePrefix`
  handles the common `FamilyN_view` grammar, while explicit `pattern`,
  `directionlessPattern`, and `singletonPattern` fields cover reviewed naming
  exceptions.
- `overrides.json` contains small human-reviewed corrections keyed by the
  generated stable ID. It may replace the final ID/name, tune scale/pivot,
  attach tags, change collision profile, or exclude an asset.
- `manual_catalog.json` retains assets not covered by the current automatic
  rules, such as the prototype buildings, fence, and dock.
- `environment_discovered.json` records source paths, dimensions, and SHA-256
  hashes so source changes are visible and reproducible.

Never hand-edit `environment_catalog.json` or files below
`assets/images/environment_generated`; rebuild them through this tool.

Full generated PNGs and thumbnails are an editor-side source cache loaded from
the workspace on demand. Pack-wide `ow1`, `ow2`, and `ow3` cache directories
are reproducible from the ignored purchased sources and are therefore ignored
by Git. The generated catalog and discovery manifest remain versioned. The
release export under
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
ow3.barrel.012
ow2.castleTower.003
```

Directional suffixes follow the vendor order: south, west, east, north,
south-west, north-west, south-east, north-east. Four-view families use the
first four directions. A directionless source such as `Rock24.png` is a fixed
asset and cannot be rotated. Families with incomplete or unexpected sets are
reported as invalid unless their reviewed family appears in
`splitIncompleteKinds`. Those sets are emitted as separate fixed `.vN` visual
variants, never as guessed rotations.

## Adding another category

Add one explicit rule to `rules.json`; avoid a universal filename heuristic.
Declare one or more of the supported complete modes (`1`, `4`, or `8`). A
directional family must contain exactly `1..4` or `1..8`; otherwise discovery
keeps its files in the invalid/review report unless the family explicitly
splits them into fixed variants. Use `singletonPattern` when one logical asset
is named only by view, for example `Ladle_1..8`. Extend the model only when a
new asset type has genuinely different semantics, such as animation frames,
sparse facings, construction variants, or terrain topology.
