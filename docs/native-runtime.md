# Native runtime

Neura keeps rendering, input, camera control, and animation playback in
Flutter/Flame. CPU-heavy world services can live in the Rust crate embedded in
`packages/neura_world` and are compiled into applications through Dart Native
Assets.

The first native service is navigation. Rust owns a rasterized collision grid
and runs A* with a binary-heap open set on a worker thread. Dart sends one path
request and receives the complete smoothed route; it does not cross FFI for
individual cells or collision checks.

## Layout

- `packages/neura_world/rust`: Rust crate and native navigation implementation.
- `packages/neura_world/hook/build.dart`: Native Assets build hook using
  `native_toolchain_rust`.
- `packages/neura_world/lib/src/rust`: generated `flutter_rust_bridge` files.
- `packages/neura_world/lib/src/native_runtime_io.dart`: development/test
  discovery of the Native Assets library.
- `apps/game/lib/native_navigation_adapter.dart`: translates authored terrain
  and blocking geometry into the native input model.

The Rust toolchain and `flutter_rust_bridge` versions are pinned so generated
bindings, compiled symbols, and CI remain reproducible.

## Development

Native Assets must be enabled once for the installed Flutter SDK:

```sh
flutter config --enable-native-assets
```

After changing public Rust API types or functions, regenerate and format both
sides of the bridge:

```sh
./packages/neura_world/tool/generate_rust.sh
```

Changing only private Rust implementation does not require regeneration.

Useful verification commands:

```sh
cargo test --manifest-path packages/neura_world/rust/Cargo.toml
(cd packages/neura_world && dart test)
(cd apps/game && flutter test test)
(cd apps/game && flutter build macos --release)
```

`dart test` runs the Native Assets hook and includes an end-to-end test that
loads the resulting dynamic library. The macOS build should contain
`neura_world_native.framework` under the application's `Contents/Frameworks`.

## Runtime behavior

At load time and after chunk streaming changes, the game sends these authored
inputs to Rust:

- base terrain movement policy;
- terrain stroke polylines in painter order;
- transformed outlines of object blocking geometry;
- actor radius and navigation cell size.

Rust rasterizes those inputs once. The returned byte grid is retained in Dart
for cheap direction-leg validation and F5 visualization, while Rust retains its
own copy for pathfinding.

Clicks use asynchronous native requests. Each carries an implicit generation
number on the Dart side. A later click invalidates older results, so obsolete
paths cannot replace the newest target and the character can continue its
existing route while calculation is in progress.

The same boundary can later support NPC simulation: send chunk changes and
batched commands to Rust, tick AI and movement at a fixed simulation rate, and
return batched snapshots for Flame to interpolate and render.

The proposed database ownership, logical roads, scheduler, and NPC simulation
phases are defined in [world-simulation-plan.md](world-simulation-plan.md).
