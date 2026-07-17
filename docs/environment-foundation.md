# Neura Environment Foundation

Character asset structure, animation extraction, and the planned player/NPC
authoring system are documented separately in [characters.md](characters.md).
The generated environment catalog workflow is documented in
[`tool/environment_importer/README.md`](../tool/environment_importer/README.md).
Runtime pathfinding and the Native Assets workflow are documented in
[native-runtime.md](native-runtime.md).
The next persistence and simulation foundation is split across the
[world simulation implementation plan](world-simulation-plan.md),
[SQLite world/save architecture](world-persistence.md),
[logical road network](road-network.md), and
[NPC schedule simulation](npc-simulation.md).
The plan for expanding that workflow across the remaining Other Worlds visual
library is documented in
[asset-catalog-import-plan.md](asset-catalog-import-plan.md).
Rendering bands, elevation, editor layers, selection, collision authoring, and
chunked-world streaming are specified in
[world-editor-improvements.md](world-editor-improvements.md).

Status: proposed foundation for the greenfield environment vertical slice.

## Objective

Build the smallest isometric environment system that proves the Other Worlds
assets can support a playable world. The vertical slice must render terrain,
place environmental objects, sort sprites, represent obstacles, pathfind around
them, cross one bridge or dock, and round-trip the authored world.

The current implementation is disposable. Reuse the repository layout,
Flutter/Flame setup, purchased-content boundary, and any projection tests that
still express the new rules. Replace the current catalogs, world schema,
renderers, editor controller, and starter world.

Do not delete the old implementation until the vertical slice reaches its
acceptance gate. Build the new foundation alongside it, switch the applications,
then remove the obsolete code in one deliberate cleanup.

## Asset findings

Other Worlds Core Tiles 3 supplies the environment layer missing from packs 1
and 2:

- 56 square 512x512 ground textures and 56 corresponding ground decals;
- 40 tree families, normally with eight views;
- 30 grass families and 30 bush families, normally with four views;
- rocks, cliffs, riverbanks, water textures, docks, fences, crops, flowers, and
  small environmental props;
- 7,077 PNGs grouped into roughly 1,720 filename families.

The pack is systematic enough to discover families automatically, but not
consistent enough to infer production metadata without review. Variant suffixes
include both `_1` and `_01`, some unnumbered files are icons or special views,
and animation sheets use separate naming conventions.

The established directional order is:

1. south
2. west
3. east
4. north
5. southwest
6. northwest
7. southeast
8. northeast

The source pack remains ignored under `content/`. Only reviewed, optimized
runtime derivatives enter `packages/neura_assets`.

## World and screen coordinates

The simulation uses a right-handed logical world:

- `x` and `y` lie on the ground plane;
- one world unit is one navigation/grid cell;
- `z` is elevation in world units;
- actors and objects may have fractional `x` and `y` positions.

The screen projection uses the true-isometric ratio found in the source art:

```text
screenX = originX + (x - y) * tileWidth / 2
screenY = originY + (x + y) * tileHeight / 2 - z * elevationPixels
```

Initial presentation constants:

```text
tileWidth       = 128 px
tileHeight      = 128 / sqrt(2) = 90.51 px
elevationPixels = 64 px
```

These constants describe projection, not source-image dimensions. They can be
changed without changing saved worlds or collision geometry.

The projected ground axes are approximately 35.264 degrees. The earlier 128x64
2:1 dimetric projection produced 26.565-degree axes and did not align with the
pack's own isometric floor diamonds or directional environment sprites.

## Terrain model

The 512x512 ground images are top-down material textures, not ready-made sprite
diamonds. A square region on the logical ground plane becomes a diamond after
isometric projection. Rendering therefore maps texture coordinates onto world
plane quads; it does not edit or manually warp every source PNG.

For a normalized source point `(u, v)` on a square ground region:

```text
screenX = (u - v) * projectedRegionWidth / 2
screenY = (u + v) * projectedRegionHeight / 2
```

This is an affine transform: rotation into the isometric axes plus vertical
foreshortening. In Flutter it can be represented by textured vertices or an
equivalent canvas transform.

Terrain is stored as material IDs on logical cells, but textures are sampled in
continuous world coordinates. A 512px texture covers a configurable number of
world units instead of restarting once per cell. The calibration scene decides
the initial texel density; `64 source pixels per world unit` is the first value
to test, making one texture repeat cover 8x8 world units.

Authored environment terrain has three ordered levels:

1. `baseMaterialId` is the world default used by untouched terrain and new
   chunks;
2. `terrainRegions` are opaque, world-space polygons that assign a regional
   ground material without generating brush stamps;
3. `terrainStrokes` are blended detail paint and decals above the regional
   ground.

Regional fills are authored independently from runtime chunks and are clipped
into each affected chunk during export. A regional clear operation reveals the
current world default. A detail reset clears only the paint layer, revealing
the regional fill beneath it. This distinction keeps chunk boundaries out of
terrain design and allows the world default to change without rewriting every
fill polygon.

Terrain renders in chunks, initially 16x16 cells. Each visible chunk builds a
textured quad mesh and is cached until its terrain changes.

Vertical-slice terrain restrictions:

- one base ground material per map;
- optional projected decals for variation;
- a rectangular water region using one water material;
- no blended boundaries, cliffs, elevation painting, or terrain autotiling.

Later, multiple materials blend through authored masks or a splat map. This is
preferable to requiring a giant catalog of diamond transition tiles.

### Terrain material painting

The `Ground_tile_OtherWorldsCore_N` and
`Ground_Decal_OtherWorldsCore_N` images are paired representations of a
material:

- `Ground_tile` is an opaque, repeatable 512x512 material texture;
- `Ground_Decal` is a soft-edged, partially transparent stamp of that material.

For example, decal 50 is an earth/dirt stamp and decal 51 is a grassy stamp.
These are not specifically road assets. They demonstrate the general operation:
paint any ground material into any other material through a soft, irregular
mask. The same mechanism produces paths, meadows, muddy patches, moss on stone,
sandy banks, worn courtyards, and other natural boundaries without exposing the
logical grid.

The editor presents this as a continuous terrain-material brush. The durable
authored form is a `TerrainStroke`, not hundreds of unrelated placed sprites:

```text
TerrainStroke
  materialId
  centerline[]       // continuous world points
  radius
  hardness
  opacity
  variationSeed
```

The renderer rasterizes strokes into weight masks for the affected terrain
chunks. Each material texture is sampled in stable world coordinates, then the
samples are combined by their weights:

```text
terrainColor = materialA * weightA
             + materialB * weightB
             + materialC * weightC
             + materialD * weightD

weightA + weightB + weightC + weightD = 1
```

An RGBA chunk mask can therefore hold the weights of four local materials.
Painting increases the selected material's weight and renormalizes the others.
Chunks needing more materials can use another pass later, but the proof should
cap each chunk at four.

The matching decal alpha, the neutral soft mask from decals 55/56, and optional
procedural noise can shape the brush edge. The decal's baked RGB does not need
to be stamped repeatedly; sampling the full `Ground_tile` texture in world
coordinates keeps the material continuous through overlapping brush strokes.

During the earliest prototype, directly compositing projected decal stamps is
an acceptable visual experiment. The saved representation should still be
material strokes so the renderer can be upgraded to weight-mask blending
without migrating authored maps.

A road is simply a wide dirt or gravel stroke. It may later carry semantic
metadata such as movement cost, but visually it uses the same compositor as all
other terrain transitions.

Decals 55 and 56 contain identical alpha data with pure white and pure black
RGB respectively. They are convenience light/dark overlays or generic soft
blend masks, not separate physical terrain. The importer can retain their shared
alpha once as a neutral soft-round brush mask. Visible lighting or darkening is
a rendering choice and should not affect terrain material, collision, or
navigation.

## Environmental object model

Objects such as trees, rocks, grass, bushes, fences, and docks are already
isometric sprite renders. They are not projected like ground textures. Each
sprite is drawn at native aspect ratio, scaled by catalog metadata, and attached
to the world through a per-view pixel pivot.

```text
AssetDefinition
  id
  category
  renderScale
  views[direction]
    imagePath
    pivotPx
  footprint
  collision
  navigation
  rendering
  tags

PlacedObject
  id
  assetId
  position(x, y, z)
  direction
  state
```

Asset categories used in the first foundation:

- `groundMaterial`: projected/repeated texture;
- `groundDecal`: projected transparent overlay;
- `scatter`: grass and flowers; no collision;
- `prop`: bushes, rocks, stumps; optional collision;
- `canopy`: trees; trunk collision plus tall occluding sprite;
- `edge`: fence or riverbank aligned to a cell edge;
- `traversal`: dock or bridge with an explicit walkable connection.

The catalog stores stable semantic IDs. Saved worlds never refer to source
filenames directly.

## Calibration workflow

Every reviewed sprite family passes through an asset calibration scene:

1. show the isometric grid and a reference character;
2. choose a family view;
3. adjust render scale without modifying the source file;
4. move the sprite pivot to its ground contact point;
5. draw or edit its footprint and collision shapes;
6. preview the character walking in front of and behind it;
7. rotate the definition and verify all supplied views;
8. save reviewed metadata to the source catalog;
9. generate optimized runtime images and the runtime catalog.

The importer may propose a bottom-center pivot and filename rotations, but these
remain draft values until visually approved.

## Collision, navigation, and perception

The character is a continuous world-space circle, initially radius `0.25` world
units. Environmental collision uses authored simple shapes:

- circles for trunks, bushes, and small rocks;
- capsules or thin rectangles for logs and fences;
- convex polygons for large irregular rocks and bridge boundaries;
- walkable polygons plus entry portals for bridges and docks.

Never derive collision from opaque sprite pixels. Pixels contain shadows,
canopies, overhangs, and empty-looking areas that do not describe the ground
footprint.

Navigation is a derived grid, initially four-neighbor A*. Static collision marks
blocked navigation cells. Traversal objects add explicit connections. Continuous
steering follows the path while collision resolution remains the final physical
authority.

Movement, vision, and projectiles are independent flags. A bush may block
movement but not vision; a tree canopy may obscure rendering while only its
trunk blocks movement.

## Rendering and draw order

Ground materials and decals render first. Objects and actors then enter a shared
render queue.

For point-like objects the initial depth key is:

```text
depth = x + y + depthBias
```

The visual sprite uses its authored pivot, while collision stays in logical
world coordinates. A character with lower depth renders behind a tree; a
character with greater depth renders in front.

Large edge and traversal objects may provide an authored sort point or be split
into multiple render parts. The vertical slice only admits assets that behave
correctly with one sort point.

## World document

The first schema contains only data required by the vertical slice:

```text
WorldDocument
  schemaVersion
  id
  name
  bounds
  baseMaterialId
  waterRegions[]
  terrainStrokes[]
  decals[]
  objects[]
  actors[]
  playerSpawn
```

Navigation meshes, blocked cells, render queues, and chunk caches are derived
runtime data and are not serialized.

## Package boundaries

Keep the current workspace shape but rebuild the internals:

```text
packages/neura_world
  pure Dart coordinates, projection, world document, collision shapes,
  spatial queries, navigation, and serialization

packages/neura_assets
  catalog models, reviewed runtime JSON, and optimized runtime images

packages/neura_rendering
  Flame terrain chunks, sprite views, pivots, render queue, camera, and debug
  overlays

apps/editor
  world editing and asset calibration UI

apps/game
  minimal playable vertical slice using the exact same world and renderer
```

`neura_world` must remain independent of Flutter, Flame, and image dimensions.

## Proof catalog

Start with a deliberately small reviewed catalog:

### Materials

- `ow3.ground.moss`: `Ground_tile_OtherWorldsCore_6.png`
- `ow3.ground.earth`: `Ground_tile_OtherWorldsCore_7.png`
- `ow3.ground.sparse_grass`: `Ground_tile_OtherWorldsCore_54.png`
- `ow3.water.clear`: `WaterTile1.png`

Only one ground material needs to be active in the first milestone. The others
exist to verify that material definitions are data-driven.

### Objects

- `ow3.tree.blossom`: `Tree1` family;
- `ow3.bush.small`: `Bush1` family;
- `ow3.grass.tuft`: `Grass1` family;
- `ow3.rock.small`: `Rock1` family;
- `ow3.fence.wood`: `Fence3` family;
- `ow3.dock.short`: `Dock1` family.

The dock initially proves traversal between two ground regions separated by
water. A larger bridge can replace or supplement it after the traversal model
works.

## Vertical-slice acceptance gate

The foundation is proven when:

1. a 20x20 world renders one repeated rectangular ground texture as a seamless
   isometric plane;
2. a freeform earth stroke produces a soft, curving road over the base material;
3. a water region and at least one projected decorative ground decal render
   without breaking projection;
4. the editor can place, select, move, rotate, and delete the six proof objects;
5. object pivots remain visually stable through rotation;
6. a reference character moves continuously and sorts correctly around trees;
7. collision prevents walking through a tree, rock, and fence;
8. A* routes around those obstacles;
9. the character can cross the dock but cannot walk onto surrounding water;
10. collision, navigation, pivots, and depth can be shown as debug overlays;
11. save and reload produces an equivalent world;
12. both editor and game consume the same catalog, world model, and renderer;
13. automated tests cover projection round-trips, world serialization,
    collision queries, navigation around an obstacle, and traversal connectivity.

After this gate, remove the obsolete engine code and expand the catalog one
reviewed category at a time.

## Explicitly deferred

- buildings and interiors;
- terrain material blending and automatic transitions;
- elevation, cliffs, ramps, and stairs;
- animated water and vegetation;
- dynamic doors and destructible objects;
- eight-direction character animation integration;
- multiplayer, combat, inventory, and procedural world generation;
- bulk import of all 7,077 source images.
