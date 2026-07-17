# Neura

Flutter + Flame isometric game and environment editor workspace.

## Workspace

```text
apps/
  game/              Playable Flutter + Flame application
  editor/            Flutter environment editor shell
packages/
  neura_world/       Pure Dart world model, chunks, movement, and projection
  neura_rendering/   Shared Flame sprite and terrain renderers
  neura_assets/      Curated runtime assets used by both applications
content/             Original purchased asset packs (not bundled wholesale)
```

The repository uses Dart pub workspaces. Resolve all members from the root:

```sh
flutter pub get
```

Run the game from its application directory:

```sh
cd apps/game
flutter run
```

Run the editor shell:

```sh
cd apps/editor
flutter run -d macos
```

For release-mode editor profiling, use the launcher that avoids the
memory-intensive Material icon subsetting step:

```sh
apps/editor/tool/run_macos_release.sh
```

## World architecture

- World positions use continuous tile coordinates with a true-isometric
  128x90.51 footprint calibrated to the source art.
- `ChunkManager` retains only the chunks near the player.
- Ground layers, roads, vegetation, characters, and the subtle grid share the
  same projection and depth ordering.
- Worlds are hand-authored `WorldDocument` files; runtime chunking streams that
  authored data without generating terrain.
- Cells store integer elevation levels. Earth cliff edges and corners are
  derived from neighboring levels, and multiple-level differences repeat the
  cliff geometry vertically.
- An elevation brush session locks the level chosen by its first cell and
  interpolates edge-connected cells when pointer events skip across the grid.
- Movement between different elevations is blocked until an explicit stair or
  ramp connection is authored.
- The game camera renders at 1.5x zoom and converts taps back into world space.
