# Neura environment editor

Run the editor in debug mode from this directory:

```sh
flutter run -d macos
```

For release-mode profiling, use the checked-in launcher:

```sh
./tool/run_macos_release.sh
```

The release launcher disables Material icon font subsetting. On a heavily
loaded development machine, Flutter's font subsetter and AOT snapshotter can
otherwise be killed by macOS with exit code `-9`. The trade-off is a slightly
larger editor application; it does not change the game release package.

The complete imported environment cache is workspace-only and is not bundled
into this application. Catalog previews are read lazily from the repository.

## Blender lighting experiment

Run the editor centered on the manually integrated `custom.asset` house:

```sh
flutter run -d macos --dart-entrypoint-args=--debug-scene=lighting_experiment
```

The **Lighting experiment** panel changes the point-light angle and intensity,
the height-map self-shadow and cast-shadow strengths, and switches between lit,
decoded-normal, and height-map views. **Focus custom.asset** returns the camera
to the test house. F6 toggles lighting, F7 cycles visualization modes, square
brackets rotate the light, and minus/equal adjust intensity.

This experiment lights only `custom.asset`. Self-shadowing uses 12 height-field
samples inside its sprite. Cast shadows intersect a compact gabled 3D proxy for
the test house and therefore reach terrain, liquids, and ground-aligned details
without interpreting camera-visible surface pixels as a complete 3D volume. An
arbitrary neighboring sprite needs its own surface map before it can receive a
geometrically correct shadow across walls or roofs.

## Editing shortcuts

- Command-click toggles objects in the current selection. Shift-click remains
  available for the same additive-selection workflow.
- Arrow keys nudge the selection in visible screen directions by 0.25 world
  units; Shift-arrow uses a 1.0-unit step.
- Command-C copies selected environment objects. Command-P pastes an offset
  duplicate; Command-V is also supported.
- Delete removes the selection, Command-Z undoes, and Command-Shift-Z redoes.
- **Fill area** assigns the selected material as regional ground inside a
  dragged marquee. It is stored as one polygon rather than many brush stamps.
- **Reset paint** removes detail brush paint inside a marquee and reveals the
  regional fill underneath. **Clear fill** reveals the world default instead.
- **Use selected** changes the world default for untouched terrain and new
  chunks. All terrain operations participate in undo and chunk persistence.
