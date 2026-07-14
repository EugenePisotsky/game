# Asset Catalog Import Plan

Status: implemented.

This document defines how Neura will discover, classify, import, preview, and
place the remaining Other Worlds environment artwork. It covers visual assets
only. Gameplay prefabs, interactions, pickups, inventory items, loot, health,
and persistent entity state are deliberately outside this phase.

The environment rendering and world-model decisions that consume these assets
are documented in [environment-foundation.md](environment-foundation.md) and
[world-editor-improvements.md](world-editor-improvements.md). Character sheets
and future character-part authoring are documented in
[characters.md](characters.md). The current Rust command-line workflow is
described in
[`tool/environment_importer/README.md`](../tool/environment_importer/README.md).

## Outcome

The completed system must let us add thousands of source images without either
hand-authoring every catalog record or presenting one enormous flat list in the
editor. It must:

- inventory every PNG from the selected source packs;
- group related directional images into one visual asset;
- preserve the vendor's fixed, four-direction, and eight-direction sets;
- assign stable IDs and useful hierarchical categories;
- report ambiguous names and incomplete families instead of guessing;
- generate small previews while retaining full-resolution editor sources;
- let the editor browse categories and load previews lazily;
- keep the full purchased library out of the Flutter release bundle; and
- leave gameplay meaning to a later prefab and item layer.

## Current implementation snapshot

The foundation described here is implemented across the Rust importer, shared
Dart catalog, and Flutter editor. The current full-pack build produces 59
materials and 2,382 placeable object families. All 8,234 configured PNG files
are accounted for: 7,784 are classified into valid visual assets, 437 are
explicitly deferred, and 13 are reviewed superseded/excluded sources. There are
no invalid or unclassified source files.

The review-required files are intentional rather than import failures. Visual
inspection shows several distinct formats hidden behind similar suffixes:

- three-piece wall construction sets such as `Wall1_1..3`;
- rectangular and isometric alternatives such as `Floor7_1..2`;
- five- and seven-facing building parts with deliberately absent views; and
- incomplete furniture or wall-mounted sets that cannot safely claim a normal
  four-way or eight-way rotation mode.

Rather than pretending these sets are rotations, reviewed families list an
explicit `splitIncompleteKinds` policy. Each image becomes a separately
placeable fixed visual variant with a stable `.vN` ID. This imports all usable
art, disables incorrect rotation, and preserves the strict fixed/four-way/
eight-way contract used by ordinary complete families. We can later add richer
construction or sparse-facing semantics without migrating placed visuals.

## Source inventory

The initial source scope is:

| Pack | PNG count | Main content |
| --- | ---: | --- |
| Other Worlds Core Tiles 1 | 577 | Buildings |
| Other Worlds Core Tiles 2 | 580 | Castles, interiors, bridges, castle parts |
| Other Worlds Core Tiles 3 | 7,077 | Environment, structures, furniture, props, small items, character parts |

Core Tiles 3 contains roughly 1,720 filename families. Its major families
include `BuildingAddon`, `Wall`, `Tree`, `Chest`, `Flower`, `Shelf`, `Book`,
`Cliff`, `Grass`, `Bush`, `Table`, `Cart`, `Door`, `Rock`, `Chair`, `Wagon`,
`Barrel`, `MarketStand`, `Bench`, `Crate`, and `Mushroom`.

Not every PNG belongs in the environment catalog. At least 376 Core Tiles 3
images use character-part families such as `Top_*`, `Bottom_*`, and `Head_*`.
Discovery must account for them, but the environment importer must defer them
to the future character-part workflow.

The filename grammar is regular enough to automate but not regular enough for
one universal heuristic:

- direction suffixes may be `_1`, `_01`, or occasionally wider zero padding;
- some assets contain one directionless image;
- some contain four complete directional images;
- some contain eight complete directional images;
- an underscore and number may identify an asset variant rather than a view;
- some families mix an unnumbered file with numbered directional files;
- some apparent families have partial or unexpected view sets; and
- similarly named art can have different semantics, such as environment props
  and character parts.

Consequently, the importer will use explicit family rules and a complete
discovery report. It will not infer production metadata from arbitrary names.

## Scope boundary

### Imported visual metadata

An asset in this phase may contain only information needed to identify, render,
preview, select, and rotate its artwork:

- stable asset ID;
- display name;
- source pack and source family;
- hierarchical category path;
- minimal searchable tags derived from reviewed family metadata;
- fixed, four-way, or eight-way view set;
- source and generated image paths;
- source dimensions and hashes in the discovery manifest;
- per-view pivot;
- render scale and render band;
- thumbnail path; and
- optional existing reviewed geometry.

Scale, pivot, render band, and views are rendering requirements rather than
gameplay properties. They are unavoidable even for a purely visual catalog.

### Deferred gameplay metadata

The asset catalog must not define:

- whether an object can be picked up;
- interaction prompts or actions;
- inventory category, weight, value, or stack size;
- loot tables or container contents;
- health, damage, destructibility, or effects;
- dialogue, quests, scripts, or persistent state; or
- a gameplay role inferred from its filename.

A later world-prefab catalog will reference visual asset IDs and add behavior.
A later item catalog will define inventory concepts and optionally reference a
pickup prefab. The same barrel artwork must be reusable by decorative, loot,
locked, or explosive barrel prefabs without duplicating the visual asset.

### Geometry during this phase

Existing reviewed geometry remains valid. Newly imported families receive no
movement-blocking geometry by default. Their geometry is empty or explicitly
marked unreviewed until it is calibrated in the geometry editor.

This avoids silently making shadows, canopies, floors, or entire sprite bounds
impassable. An asset may be visible and placeable before collision authoring is
complete.

## Catalog concepts

Three fields serve different purposes and must not be conflated:

```text
family       technical filename grouping and import behavior
categoryPath editor browsing hierarchy
tags         cross-category search terms and themes
```

For example:

```json
{
  "id": "ow3.barrel.001",
  "name": "Barrel 001",
  "family": "barrel",
  "categoryPath": ["Props", "Containers"],
  "tags": ["barrel", "wood", "storage"],
  "viewMode": "fourWay",
  "views": {
    "south": {"image": "..."},
    "west": {"image": "..."},
    "east": {"image": "..."},
    "north": {"image": "..."}
  }
}
```

Changing a category or tag must not change the stable ID. Saved worlds refer to
the ID, never to a category, source filename, or generated image path.

## Stable IDs and pack namespaces

Existing Core Tiles 3 IDs keep the `ow3` namespace for compatibility. New
automatic IDs use the pack, normalized family, and zero-padded source asset
number:

```text
ow1.building.001
ow2.bridge.002
ow2.interior.017
ow3.barrel.001
ow3.barn.002
ow3.book.017
```

An override may provide a semantic ID such as `ow3.tree.blossom`, but the
generated source ID remains its lookup key. Renaming categories, changing
display names, or tuning pivots does not affect identity.

The importer must fail if two generated assets or overrides produce the same
final ID.

## Directional views

The vendor direction order is:

| Source suffix | Semantic direction |
| ---: | --- |
| 1 | south |
| 2 | west |
| 3 | east |
| 4 | north |
| 5 | southwest |
| 6 | northwest |
| 7 | southeast |
| 8 | northeast |

The source order is not clockwise. The importer translates suffixes into
semantic direction names so the rest of the engine never depends on vendor
numbers.

Each generated asset declares one of these modes:

```text
fixed       one image; visual rotation is unavailable
fourWay     complete suffixes 1 through 4; 90-degree rotation
eightWay    complete suffixes 1 through 8; 45-degree rotation
```

Only complete sets are accepted automatically. A family containing views
`1,2,3,4,5`, for example, is reported for review. It is not silently treated as
four-way and it is not padded with guessed images.

Directionless art is not automatically copied to eight logical facings. It is
represented as `fixed`, making the editor disable rotation. If a visually
rotation-independent asset genuinely needs multiple logical directions, that
choice must be an explicit family rule or override.

Editor rotation uses the clockwise semantic order filtered to the available
views:

```text
eight-way: south, southwest, west, northwest, north, northeast, east, southeast
four-way:  south, west, north, east
fixed:     no rotation
```

Rendering must not silently fall back to the south image for a missing selected
direction. Such a state would rotate collision geometry without rotating the
art and must be rejected or repaired during loading.

## Category hierarchy

The first reviewed hierarchy is:

```text
Environment
  Trees
  Bushes
  Flowers
  Ground Cover
  Rocks
  Cliffs

Buildings
  Houses
  Agricultural
  Interiors
  Fortifications
  Building Parts

Structures
  Bridges & Docks
  Fences & Gates
  Stairs & Platforms

Furniture
  Seating
  Tables & Desks
  Beds
  Shelving & Cabinets

Props
  Containers
  Tools & Workshop
  Market
  Lighting & Fire
  Decoration

Small Items
  Books & Scrolls
  Bottles & Potions
  Food & Drink
  Weapons
  Tableware

Terrain Pieces
  Walls
  Floors
  River Banks
```

Example mappings:

| Family | Category path |
| --- | --- |
| `Barrel`, `Crate`, `Bag`, `Basket` | Props / Containers |
| `Barn` | Buildings / Agricultural |
| `Building` | Buildings / Houses |
| `BuildingAddon` | Buildings / Building Parts |
| `Bridge`, `Dock` | Structures / Bridges & Docks |
| `Fence`, `Gate` | Structures / Fences & Gates |
| `Chair`, `Bench`, `Stool` | Furniture / Seating |
| `Table`, `Desk` | Furniture / Tables & Desks |
| `Book`, `Scroll` | Small Items / Books & Scrolls |
| `Bottle`, `Potion`, `Vial` | Small Items / Bottles & Potions |
| `Wall`, `Floor`, `RiverBank` | Terrain Pieces |

Themes such as `dungeon`, `castle`, `market`, or `agricultural` are generally
tags. They should not duplicate the whole category hierarchy.

`Misc` is permitted only for a small number of genuinely miscellaneous,
reviewed assets. `Unclassified` is a discovery status and must not become a
shipping editor category.

## Importer configuration

The current configuration has one source root and a fixed expected view count
per rule. It will evolve into global paths, source-pack definitions, and family
definitions. These may remain in one JSON file initially, but the Rust model
must keep the concepts separate.

Example source packs:

```json
{
  "packs": [
    {
      "id": "ow1",
      "sourceRoot": "content/Other Worlds Core Tiles 1"
    },
    {
      "id": "ow2",
      "sourceRoot": "content/Other Worlds Core Tiles 2"
    },
    {
      "id": "ow3",
      "sourceRoot": "content/Other Worlds Core Tiles 3"
    }
  ]
}
```

Example family definition:

```json
{
  "packId": "ow3",
  "family": "barrel",
  "pattern": "^Barrel(?<asset>\\d+)_0*(?<view>[1-8])\\.png$",
  "directionlessPattern": "^Barrel(?<asset>\\d+)\\.png$",
  "allowedViewModes": ["fixed", "fourWay", "eightWay"],
  "categoryPath": ["Props", "Containers"],
  "renderBand": "depthSorted",
  "pivot": {"x": 0.5, "y": 1.0},
  "renderScale": 1.0,
  "tags": ["barrel", "container"]
}
```

Rules remain explicit per filename family. This is more verbose than a global
heuristic but keeps ambiguity visible and makes changes reviewable.

Per-asset `overrides.json` remains the place for exceptions:

- semantic name or ID;
- exclusion;
- category correction;
- render scale;
- per-view pivot;
- preview direction;
- tags; and
- geometry once reviewed.

## Discovery workflow

`scan` will inspect every source PNG from configured packs before attempting to
build the environment catalog. Every file must receive exactly one status:

| Status | Meaning |
| --- | --- |
| `classified` | Matches one environment family rule and forms a valid asset |
| `deferred` | Recognized but belongs to another future importer |
| `unclassified` | No rule currently owns the filename |
| `invalid` | Intended family has duplicate, missing, or unexpected views |
| `excluded` | Explicitly ignored with a reviewed reason |

Example report:

```text
classified    Barrel1_1.png           Props / Containers
deferred      Top_Assassin1_01.png    Character Part
unclassified  StrangeAsset7_3.png
invalid       Barrel3                 found views 1,2,3,4,5
```

Rules must be mutually exclusive. A file matching two rules is an importer
error. A known family with an invalid view set is also an error for strict
builds.

Discovery and build have different coverage behavior:

- discovery always completes and writes the review report when possible;
- normal incremental build imports valid classified families;
- strict check can require selected batches or packs to have no unknowns; and
- final full-library completion requires every PNG to be classified, deferred,
  or explicitly excluded.

The discovery manifest retains source paths, dimensions, SHA-256 hashes, family
grouping, resolved direction, and classification status. It makes additions,
removals, and vendor-source changes visible in code review.

## Build workflow

For each valid classified visual asset, `build` will:

1. derive its stable source ID;
2. translate source view numbers to semantic directions;
3. merge family defaults with per-asset overrides;
4. copy each full-resolution PNG into the generated editor library;
5. generate a transparent 192 by 192 thumbnail without cropping;
6. prefer a southeast preview for eight-way objects and south otherwise,
   unless overridden;
7. write the generated catalog entry;
8. write the deterministic source discovery record; and
9. reject duplicate IDs, missing images, invalid directions, and stale output.

Generated files must never be edited manually. A second build with unchanged
sources and rules must produce no diff.

The editor-side generated library may be large because images are loaded from
the workspace on demand. Release export continues to follow world references
and copy only the assets and directional views actually required by exported
chunks. Importing the full library must therefore not embed it into every
Flutter application.

## Editor catalog work

The editor must be upgraded before thousands of records are added.

### Browsing

The Objects panel will provide:

- a hierarchical category browser with counts;
- an `All` entry;
- search over display name, stable ID, family, category, and tags;
- a breadcrumb for search results;
- a virtualized grid backed by lazy thumbnail loading; and
- later, optional Recent and Favorites sections.

Selecting a parent category includes its descendants. Search may operate within
the selected category or across all assets, but the UI must make the current
scope clear.

### Asset cards

Each card shows:

- generated thumbnail;
- concise display name;
- category breadcrumb when showing mixed search results; and
- a `Fixed`, `4-way`, or `8-way` badge.

The grid must decode only visible or near-visible thumbnails. Full-resolution
directional images are loaded only when an asset is selected, placed, or becomes
visible on the canvas. The image cache must remain bounded.

### Direction controls

The selected-object inspector will use a compass-like control or another clear
direction selector. Unavailable directions are disabled. The rotate command
advances to the next available direction rather than cycling through all eight
enum values.

The catalog loader validates that a placed direction exists for its visual
asset. Legacy invalid data may be repaired once during migration, but normal
rendering must not hide the problem with a fallback view.

### Raw assets versus future prefabs

During this phase, the Objects panel places visual assets directly as it does
today. When the gameplay-prefab system is introduced, imported assets can
produce automatic decorative prefabs and the normal world palette can switch
to prefabs. The raw visual library will remain available as an advanced asset
browser and calibration source.

The current asset import must not pre-empt that migration by adding gameplay
properties to visual records.

## Import batches

The import will proceed in reviewable batches. Each batch includes family
rules, source-discovery fixtures, catalog tests, generated thumbnails, category
UI verification, and a short visual calibration pass.

### Phase 0: importer and editor foundation

- support multiple source packs;
- add `family`, `categoryPath`, and `viewMode` to the catalog schema;
- retain backward compatibility for the existing single `category` field;
- support fixed, four-way, and eight-way family validation;
- add classified, deferred, unclassified, invalid, and excluded statuses;
- add category browsing and lazy grids to the editor;
- fix rotation to use only available directions; and
- preserve existing IDs and reviewed overrides.

### Phase 1: common props and furniture

Import representative small and medium families:

```text
Barrel, Crate, Bag, Basket, Pot, Jar, Chest
Chair, Bench, Stool, Table, Desk, Shelf, Bed
Book, Scroll, Bottle, Potion, Vial
```

This batch deliberately includes fixed, four-way, eight-way, zero-padded, and
ambiguous families. It proves the rule model before the catalog becomes large.

`Chest` requires separate reviewed rules for directionless numbered variants
and directional families; its underscore-number syntax must not be interpreted
by a universal direction heuristic.

### Phase 2: outdoor structures

```text
Fence, Gate, Door, Bridge, Dock, Stairs
Cart, Wagon, MarketStand, Barn
```

Large structures remain visually placeable without automatic collision.
Geometry authoring follows separately.

### Phase 3: environment expansion

```text
Flower, Mushroom, Vine, Crop
Cliff, Wall, Floor, RiverBank
additional rocks, vegetation, and exterior decoration
```

Terrain-piece categories remain distinct from painted ground materials. This
phase imports their art but does not yet promise autotiling, shoreline topology,
or elevation semantics.

### Phase 4: large architecture

- Core Tiles 1 `Building*` families;
- Core Tiles 2 castles, keeps, towers, interiors, and castle parts; and
- Core Tiles 3 `BuildingAddon*`, towers, gatehouses, and related structures.

This batch needs particular attention to preview direction, thumbnail framing,
pivots, placement scale, and large-image memory behavior.

### Phase 5: special and ambiguous families

Review remaining environment families with unusual suffixes, incomplete view
sets, multipart art, potential animations, or specialized terrain semantics.
Add explicit rules or exclusions; do not widen generic patterns merely to make
the unknown count reach zero.

### Deferred catalogs

Character-part families such as `Top_*`, `Bottom_*`, and `Head_*` are marked
`deferred: characterPart`. Animation sheets, creature sprites, UI art, and
other non-environment resources receive corresponding deferred classifications
when encountered. Their files stay visible in discovery coverage without
polluting the environment palette.

## Migration strategy

The catalog schema change must preserve the existing editor and authored world:

1. add new optional fields and parse the old `category` field as a one-segment
   category path;
2. make generated entries emit both representations temporarily if needed;
3. update editor grouping and search to use category paths;
4. update direction rotation and validation;
5. regenerate the catalog while preserving stable IDs and overrides;
6. migrate tests and fixtures;
7. stop emitting the legacy category after all consumers have migrated; and
8. bump the catalog schema version only at the point old readers can no longer
   consume it.

The asset build must not implicitly rebuild the authored world, its chunks, or
the release package. Those remain explicit commands so importing art cannot
overwrite editor changes.

## Verification

### Rust importer tests

- source pack paths and namespaces are unique;
- family patterns are mutually exclusive;
- `_1` and `_01` normalize to the same view index;
- fixed, complete four-way, and complete eight-way families succeed;
- partial, duplicate, extra, and mixed ambiguous sets fail or enter review;
- vendor numbers map to the documented semantic directions;
- stable IDs do not depend on categories or display names;
- override collisions fail;
- every scanned file receives exactly one status;
- thumbnails preserve alpha and do not crop source artwork; and
- two identical builds produce identical manifests and catalogs.

### Dart catalog tests

- old single-category entries remain readable during migration;
- hierarchical categories round-trip;
- fixed, four-way, and eight-way view modes validate;
- missing selected directions are rejected;
- search fields include names, IDs, families, categories, and tags; and
- geometry remains empty or unreviewed for new asset-only imports.

### Editor tests

- category parent selection includes descendants;
- category counts match the catalog;
- search respects or clearly escapes category scope;
- the grid builds lazily;
- unavailable compass directions are disabled;
- rotate advances only through supported directions;
- fixed assets do not rotate;
- selecting and placing an asset loads only required images; and
- large thumbnails fit without being cropped.

### Release tests

- the release catalog contains only world-referenced visual assets;
- only required directional views are copied;
- no absolute workspace or purchased-content paths remain;
- unused imported art does not affect the release byte budget; and
- export is deterministic.

## Acceptance criteria

The asset-catalog import foundation is complete when:

- every PNG in the configured packs is classified, deferred, unclassified,
  invalid, or explicitly excluded;
- no file matches more than one rule;
- selected completed batches have no unclassified or invalid files;
- fixed, four-way, and eight-way assets render and rotate correctly;
- changing a category does not change a stable ID;
- the editor presents hierarchical categories instead of a flat object list;
- editor preview memory depends on visible thumbnails rather than catalog size;
- newly imported art has no inferred gameplay behavior or collision;
- generated output is deterministic;
- world authoring files are not modified by asset build commands; and
- release size depends on the authored world, not the full source library.

## Implementation order

The next development sequence is:

1. update the Rust configuration and discovery model;
2. update the generated catalog schema and Dart reader;
3. fix supported-direction rotation and missing-view validation;
4. implement hierarchical editor browsing and lazy preview behavior;
5. import and review the common props and furniture batch;
6. verify deterministic build and reference-driven release export; and
7. continue through the remaining batches only after the first batch passes its
   acceptance checks.

This order proves the scalable foundation with a deliberately varied catalog
before committing to thousands of generated records.
