# Other Worlds Character System

This document records how the PVGames Other Worlds character assets are
structured, how Neura currently converts and renders them, and the intended
foundation for player customization and NPC authoring.

The primary vendor reference is
`content/Documents/Info_Spritesheet.docx`. Treat it as the source of truth if a
future asset pack differs from the observations below.

## Mental model

The source files are a paper-doll system, not finished character sprites.
Every compatible sheet uses the same canvas, cell size, animation positions,
and directional order. A character is produced by drawing selected transparent
layers over one another at exactly the same source coordinates.

The first runtime characters currently use this layer order:

1. `Shadow/Spritesheet.png`
2. `Base/OtherWorlds_1/Spritesheet.png`
3. `Bottom/OtherWorlds_1/Spritesheet.png`
4. `Top/OtherWorlds_1/Spritesheet.png`
5. `Hair/OtherWorlds_1/Spritesheet.png`
6. `Head/OtherWorlds_1/Spritesheet.png`

All layers remain optional except the body base. Male assets additionally
provide `FacialHair`; both source sets provide weapon layers. Weapons and
off-hand equipment require a dedicated visual validation pass because their
correct front/behind relationship may vary by pose and facing.

## Source layout

- Sprite sheet size: 10,000 x 10,000 pixels.
- Grid: 50 columns x 50 rows.
- Frame size: 200 x 200 pixels.
- Frame order: row-major, from the top-left.
- Vendor frame numbers are one-based; code indices are zero-based.
- Each animation contains all eight directions before the next animation.
- Direction order is always:

| Direction index | Catalog name | Meaning |
| ---: | --- | --- |
| 0 | `south` | screen down |
| 1 | `west` | screen left |
| 2 | `east` | screen right |
| 3 | `north` | screen up |
| 4 | `southWest` | screen down-left |
| 5 | `northWest` | screen up-left |
| 6 | `southEast` | screen down-right |
| 7 | `northEast` | screen up-right |

To find a source frame from a zero-based global frame index:

```text
column = globalFrameIndex % 50
row    = globalFrameIndex ~/ 50
x      = column * 200
y      = row * 200
```

To extract a direction and local animation frame:

```text
globalFrameIndex = animationStartIndex
                 + directionIndex * framesPerDirection
                 + localFrameIndex
```

Example: Walk starts at zero and has eight frames per direction. East is
direction index 2, so its first walk frame is global index `0 + 2 * 8 = 16`
(vendor frame 17).

## Portrait layout

Most selectable layers also contain `Portraits.png`. These sheets are
8,000 x 8,000 pixels and use the same paper-doll principle: matching portrait
layers are composited to produce one character portrait. The vendor lists 16
expressions in order:

`neutral` x2, `happy` x2, `sad` x2, `angry` x2, `nervous` x2, `scared`,
`injured`, `thoughtful` x2, and `annoyed` x2.

Portrait extraction has not yet been implemented. Before implementing it,
measure and verify its cell grid rather than assuming the 200 x 200 world-frame
layout also applies.

## Animation map

The ranges below are the vendor's one-based, inclusive frame ranges. Divide
the total by eight to get frames per direction. `Loop` repeats; `Singular`
stops on completion; `Ping-pong` reverses back through its frames.

### General movement and interaction

| Animation | Vendor frames | Frames/direction | Playback |
| --- | ---: | ---: | --- |
| Walk | 1-64 | 8 | Loop |
| Run | 65-128 | 8 | Loop |
| Idle 1 | 129-168 | 5 | Loop |
| Idle 2 | 169-208 | 5 | Loop |
| Idle 3 | 209-248 | 5 | Loop |
| Idle 4 | 249-288 | 5 | Loop |
| Idle Fidget 1 | 289-312 | 3 | Singular or ping-pong singular |
| Idle Fidget 2 | 313-336 | 3 | Singular |
| Idle Fidget 3 | 337-360 | 3 | Singular or ping-pong singular |
| Talking 1 | 361-400 | 5 | Loop |
| Talking 2 | 401-440 | 5 | Loop |
| Interact | 441-480 | 5 | Singular |
| Use Item | 481-504 | 3 | Singular |
| Sitting | 505-528 | 3 | Ping-pong |
| Climb | 529-568 | 5 | Ping-pong |
| Praying | 569-592 | 3 | Ping-pong |
| Jump | 593-632 | 5 | Singular |
| Sneaking | 633-696 | 8 | Loop |
| Crouch | 697-720 | 3 | Ping-pong |
| Casting | 721-744 | 3 | Singular |
| Dead/down forward | 745-784 | 5 | Singular |
| Dead/down backward | 785-824 | 5 | Singular |
| Down poses | 825-856 | 4 | Static poses, not an animation |
| Evade roll | 857-896 | 5 | Singular |
| Get hit 1 | 897-920 | 3 | Singular |
| Get hit 2 | 921-944 | 3 | Singular |
| Critical idle 1 | 945-968 | 3 | Ping-pong |
| Critical idle 2 | 969-992 | 3 | Ping-pong |
| Block | 993-1016 | 3 | Singular |
| Drink | 1017-1040 | 3 | Singular or ping-pong singular |
| Riding | 1041-1064 | 3 | Static poses; manual editing required |

### Weapon stances

| Animation | Vendor frames | Frames/direction | Playback |
| --- | ---: | ---: | --- |
| One-hand walk | 1065-1128 | 8 | Loop |
| One-hand idle | 1129-1168 | 5 | Loop |
| One-hand attack 1 | 1169-1192 | 3 | Singular |
| One-hand attack 2 | 1193-1216 | 3 | Singular |
| One-hand attack 3 | 1217-1240 | 3 | Singular |
| One-hand fidget | 1241-1264 | 3 | Ping-pong singular |
| Two-hand walk | 1265-1328 | 8 | Loop |
| Two-hand idle | 1329-1368 | 5 | Loop |
| Two-hand run | 1369-1432 | 8 | Loop |
| Two-hand attack 1 | 1433-1456 | 3 | Singular |
| Two-hand attack 2 | 1457-1480 | 3 | Singular; positional offset required |
| Dual-wield walk | 1481-1544 | 8 | Loop |
| Dual-wield idle | 1545-1584 | 5 | Loop |
| Dual-wield attack 1 | 1585-1608 | 3 | Singular |
| Dual-wield attack 2 | 1609-1632 | 3 | Singular |
| Dual-wield fidget | 1633-1656 | 3 | Singular |
| Bow walk | 1657-1720 | 8 | Loop |
| Bow idle | 1721-1760 | 5 | Loop |
| Bow attack 1 | 1761-1800 | 5 | Singular |
| Bow fidget | 1801-1824 | 3 | Ping-pong |
| Unarmed idle | 1825-1864 | 5 | Loop |
| Unarmed attack 1 | 1865-1904 | 5 | Singular |
| Unarmed attack 2 | 1905-1928 | 3 | Singular or ping-pong singular |
| Unarmed fidget | 1929-1952 | 3 | Singular |
| Polearm/staff walk | 1953-2016 | 8 | Loop |
| Polearm/staff run | 2017-2080 | 8 | Loop |
| Polearm/staff idle | 2081-2120 | 5 | Loop |
| Polearm/staff attack 1 | 2121-2144 | 3 | Singular |
| Polearm/staff attack 2 | 2145-2168 | 3 | Singular |
| Pistol walk | 2169-2232 | 8 | Loop |
| Pistol idle | 2233-2272 | 5 | Loop |
| Pistol attack 1 | 2273-2296 | 3 | Singular |
| Pistol attack 2 | 2297-2320 | 3 | Singular |
| Pistol fidget | 2321-2344 | 3 | Singular |
| MG/rifle/crossbow walk | 2345-2408 | 8 | Loop |
| MG/rifle/crossbow idle | 2409-2448 | 5 | Loop |
| MG/rifle/crossbow attack 1 | 2449-2472 | 3 | Singular |
| MG/rifle/crossbow fidget | 2473-2496 | 3 | Singular |

The vendor document prints the final fidget range as `2472-2496`, which
overlaps the previous animation and contains 25 frames. The sequential,
eight-direction interpretation is `2473-2496`; verify it visually before this
animation is added.

## Current Neura pipeline

The source directories are approximately 1.0 GB for Male and 868 MB for
Female. A single decoded 10,000 x 10,000 RGBA image can occupy about 400 MB, so
the original sheets must never be runtime game assets.

`tool/build_character_sheets.py` currently extracts only Walk and Idle 1. It
composites one fixed recipe for Male and Female and writes:

```text
packages/neura_assets/assets/images/characters/
  male/idle.png       # 1000 x 1600: 5 columns x 8 directions
  male/walk.png       # 1600 x 1600: 8 columns x 8 directions
  female/idle.png
  female/walk.png
```

Together these optimized sheets are about 1.4 MB. Their metadata is stored in
`packages/neura_assets/assets/catalogs/character_catalog.json` and parsed by
`CharacterCatalog`.

The game renders a frame with:

- column = animated frame within the current action;
- row = facing direction from `directionRows`;
- destination anchor = `(pivotX: 0.5, pivotY: 0.75)`;
- world depth = the character's foot point, ordered by `x + y`;
- scale = `renderScale`, currently `1.0`.

The character's logical position is the foot point, not the center of the
200 x 200 image. Collision, navigation, selection, interaction distance, and
depth sorting must all use this foot point. Transparent pixels and the cast
shadow do not define gameplay geometry.

The original prototype used `pivotY: 0.88`, but inspection of the compact
200 x 200 frames placed the visible feet around 74-78% of the cell height. The
old value therefore put the logical destination roughly 25 pixels below the
feet. The runtime pivot is calibrated to `0.75`; click markers and world
positions represent the point beneath the character's feet.

## Movement with eight directional animations

The available character art has eight facings. Moving continuously at an
arbitrary angle while displaying the nearest facing causes visible lateral
sliding. Neura instead decomposes every direct movement into at most two
segments that exactly match supported directions. Future grid pathfinding will
produce the same kind of major-direction segments.

Movement speed is measured in projected screen pixels per second rather than
raw world units per second. Isometric projection gives different pixel lengths
to world axes and diagonals, so raw world speed would make some directions look
up to twice as fast.

Infinity Engine animation formats used both eight- and sixteen-orientation
schemes. Its documented `path_smooth` behavior could either restrict
pathfinding to major creature directions or allow arbitrary angles. Neura uses
the restricted-major-direction approach because these Other Worlds sheets have
eight authored facings. See the
[Infinity Engine creature-animation format](https://iesdp.bgforge.net/file_formats/ie_formats/ini_anim).

## Target appearance model

Save a customized character as a stable appearance recipe, not as PNG paths
scattered across game or editor state. A proposed initial schema is:

```json
{
  "schemaVersion": 1,
  "sourceSet": "other_worlds.male",
  "base": "OtherWorlds_1",
  "head": "OtherWorlds_1",
  "hair": "OtherWorlds_4",
  "facialHair": null,
  "bottom": "OtherWorlds_3",
  "top": "OtherWorlds_7",
  "mainHand": null,
  "offHand": null,
  "renderScale": 1.0
}
```

Use `sourceSet`, not a hardcoded gameplay gender enum. The source-set choice
determines compatible catalogs and can still be presented as Male/Female in
the UI. Stable asset IDs should be independent of display names and source
folder paths.

Keep four kinds of state separate:

1. **Appearance recipe**: visual layers and scale.
2. **Character definition**: ID, name, portrait, stats, tags, and appearance.
3. **NPC definition**: dialogue, schedule, faction, behavior, inventory, and
   optional character-definition reference.
4. **NPC placement**: world position, facing, spawn rules, and per-instance
   overrides.

This lets many NPC placements share one definition, permits a player and an
NPC to use the same appearance system, and avoids embedding world coordinates
in reusable character data.

## Recommended editor and runtime architecture

### Preprocess source layers

Extend the build tool to generate compact transparent animation sheets for
every selectable layer, rather than baking only two finished characters. Start
with Walk and Idle 1. A generated layer manifest should record:

- stable ID and display name;
- source set and slot (`base`, `top`, `hair`, and so on);
- compact idle/walk asset paths;
- compatible weapon stance, if applicable;
- portrait-layer path when portrait support is added;
- preview thumbnail;
- any animation offset or layer-order exception.

### Preview and runtime composition

For the first customizable implementation, draw the selected compact layers
in order for each animated frame. Six to eight small sprite draws are an
acceptable starting point and allow immediate previews without generating a
file inside the game.

Later, cache a composed atlas by a deterministic hash of the appearance
recipe. Identical NPC appearances can share that cached atlas. Editor export
may optionally bake finalized NPC recipes, but the recipe remains the source
of truth.

Do not load or crop the original 10,000 x 10,000 sheets during gameplay. They
belong only to developer-side preprocessing.

### Shared character editor

Build the customization UI as a reusable widget/controller shared by:

- the in-game player creator;
- the editor's character library;
- the editor's NPC inspector.

The shared editor should provide:

- source-set selection;
- slot tabs with thumbnails and a `None` option where valid;
- animated preview with facing and action controls;
- character scale preview next to a standard doorway or measurement marker;
- validation of incompatible weapon/off-hand combinations;
- randomize and reset actions;
- serializable `CharacterAppearance` output.

The NPC editor adds NPC-specific fields around this shared appearance editor
rather than duplicating it.

## Implementation sequence

1. Introduce `CharacterAppearance`, `CharacterDefinition`, `NpcDefinition`,
   and `NpcPlacement` models with versioned JSON.
2. Extend the Python preprocessing tool to output compact per-layer Walk and
   Idle 1 sheets plus a generated layer catalog.
3. Add a reusable layered-character renderer and recipe-hash cache.
4. Replace the two baked catalog entries with appearance recipes while
   retaining them as sample presets.
5. Build the shared character customization widget.
6. Add the player creation screen in the game.
7. Add character-library and NPC-placement panels in the editor.
8. Add portraits, more animations, weapons, and equipment compatibility only
   after the Walk/Idle customization path is stable.

## Validation checklist

For every generated layer or customized recipe:

- all eight directions use the documented row order;
- all animation layers remain pixel-aligned through every frame;
- feet remain stable at the configured pivot;
- shadow is drawn first and only once;
- hair, facial hair, and head combinations do not visibly clip;
- clothing does not reveal unintended base pixels;
- character scale is credible next to a fence and doorway;
- north/south depth ordering works around a tree or building;
- serialized recipes reload to the identical appearance;
- missing or renamed source assets produce a build-time error, not an
  invisible runtime character;
- weapon and off-hand combinations are checked in every facing before being
  marked supported.

## Licensing constraint

The vendor permits use and modification in commercial and non-commercial
projects but prohibits redistributing the source resources, including edited
material bases. Keep `content/Male`, `content/Female`, and developer-facing
layer previews out of public examples and source distributions unless the
project's distribution rules have been reviewed. Ship only the game output
needed by the project.
