# Surfaces, water, and elevation

Status: implemented foundation. This is the authoritative description of the
current environment height model.

## Core rule

Visual paint, physical floors, liquid, collision, and sprite artwork are
different things. They may refer to one another, but none of them implicitly
creates another.

- A **surface** is a physical plane an actor or object can stand on.
- A **terrain region** or **terrain stroke** is visual material paint attached
  to one surface.
- A **liquid volume** is water (or another liquid) above one bed surface.
- A **surface connector** is an authored transition between two surfaces.
- A **placed object** is artwork and geometry supported by exactly one surface.
- An **editor layer** organizes content. It has no physical height.

This separation is deliberate. Painting grass cannot raise the player,
changing water opacity cannot change its depth, and moving an editor group
cannot accidentally move an object to another floor.

## Saved model

The source world uses environment document schema 6, chunk schema 4, and world
manifest schema 2. Older experimental schemas are rejected rather than
migrated because the old terrain regions mixed paint, water, and elevation.

### `EnvironmentSurface`

A surface stores:

- a stable ID and display name;
- a world-space polygon;
- a default material;
- a kind (`terrain`, `platform`, or `interior`);
- a height definition;
- whether it is walkable;
- whether its default material is drawn or it is geometry-only;
- a render order; and
- an optional visibility-group ID reserved for interior/roof policies.

The world always has `surface_ground`. It spans the world and is reconstructed
from the manifest while chunks stream. Additional surfaces are chunked by
spatial overlap.

The schema supports flat planes and linear ramps. The editor currently authors
flat planes; ramp-handle authoring is a later UI task.

### Paint

Every `TerrainRegion` and `TerrainStroke` has a `surfaceId`. Paint changes the
surface's appearance only. Reset paint reveals that surface's own default
material, not the global ground material.

### `EnvironmentLiquidVolume`

A liquid stores:

- its polygon and material;
- the ID of its bed surface;
- a level liquid-surface elevation;
- either one constant depth or a shallow-to-deep bathymetry ramp;
- texture scale, opacity, edge softness, and render order.

The liquid polygon is the exact gameplay boundary. Opacity and edge softness
are visual only. Water is not inferred from a material tag on ordinary paint.
For a depth ramp, the bed elevation at each point is derived as
`liquid surface elevation - local depth`. The liquid plane itself never tilts.

### `EnvironmentSurfaceConnector`

A connector stores a source surface and landing, destination surface and
landing, traversal kind (`stairs`, `ramp`, `ladder`, or `portal`), landing
width, cost, and whether it is bidirectional.

Surfaces never become connected merely because their polygons overlap. This is
what lets a bridge exist above a road or water without merging both navigation
planes.

### Placed objects

Every object has `supportSurfaceId`. Its anchor elevation is sampled from that
surface, then `verticalOffset` is applied. Collision and footprint geometry
belong to the same support surface. The object inspector can reassign one or a
multi-selection to another surface.

Tall artwork may additionally enable `crossSurfaceOcclusion` and define an
`occlusionHeight`. These are rendering properties only. When the object's blue
footprint overlaps a later surface within that vertical reach, the object joins
that surface's depth pass. Its support surface, physical elevation, liquid
interaction, and collision do not change.

`verticalOffset` remains a small artistic or semantic offset—for example an
item on a table. It is not a substitute for making a second floor.

## Rendering and the cliff problem

Surfaces render from lower order to higher order. For each surface the engine
draws:

1. the surface default material;
2. its regions and strokes;
3. liquid whose bed is that surface;
4. ground-cover, depth-sorted, overhead, and effect objects supported by it;
5. then the next surface.

This ordering is important for cliff and platform artwork. Bind a cliff face
to the lower surface and draw the upper ground as a higher surface polygon.
The upper terrain then covers the part of the cliff sprite behind its boundary,
while the facade projecting outside the polygon stays visible. Bind trees,
buildings, and actors standing on top to the upper surface.

The system therefore does not need a generic manual “draw ground over this
object” offset. The physical relationship determines the useful default.
`sortBias` remains an exceptional correction inside one surface, not a floor
selector.

Objects on one surface are depth-sorted with actors on that same surface using
their authored footprints. Separate surfaces are composed by surface order.
The explicit tall-object opt-in above is the exception: it lets a ship mast,
cliff facade, or other tall artwork depth-sort with an overlapping upper deck
without pretending that the object is physically supported by that deck.

## Editor workflow

### Raised ground, cliff, or platform

1. Choose a non-water material.
2. Select **Surface** (the polygon authoring tool).
3. Set the new surface elevation.
4. Click the physical boundary and finish the polygon.
5. Keep the new surface selected as **Target surface** while painting its
   details and placing objects on it.
6. Place cliff-face artwork on the lower surface, or use the object inspector
   to change its support surface afterward.

Select **Edit fill** to select and move polygon vertices. A selected physical
surface exposes its elevation and can be made the active target surface.

Enable **Geometry only** for a surface whose appearance already comes from
object artwork, such as a pre-rendered dock, bridge deck, roof, or platform.
The surface remains available to navigation, collision, connectors, actors,
and supported objects, but its default material is not drawn. Explicit paint
attached to the surface still renders, so geometry-only means “no automatic
base fill,” not “hide everything on this floor.”

For tall artwork supported by a lower surface—such as a ship beside a raised
dock—select the object, enable **Occlude upper surfaces**, and set **Occlusion
height** high enough to reach the dock. The blue footprint must overlap the
dock surface. The object will then sort with actors and props on the dock while
remaining physically in the water. Leave this disabled for ordinary objects;
it is an authored exception for artwork spanning several vertical levels.

### Water

1. Select a water material.
2. Select **Surface** (or rectangular **Fill area**).
3. Choose the bed as **Target surface**.
4. Set liquid elevation, initial depth, opacity, edge softness, and texture
   size.
5. Draw the liquid boundary.

Water created this way is persistent and editable. The ordinary brush does not
paint physical water because disconnected decals would recreate the ambiguous
old model.

To make a beach or sloping river bed, select the liquid with **Edit fill** and
enable **Variable depth**. Set the start and end depths, then drag the cyan and
purple handles across the water polygon. Depth is interpolated along that
world-space line and clamped beyond its endpoints. Use **Swap depth ends** when
the handles point in the correct direction but shallow and deep are reversed.
The editor and game make shallower water more transparent so the profile is
visible while authoring.

Partly submerged objects use their liquid interaction:

- `automatic`: boats float; other assets submerge;
- `submerge`: anchor on the locally sampled bed and cover the portion below the
  level waterline;
- `float`: anchor at the liquid surface, adjusted by liquid draft;
- `ignore`: do not apply the liquid overlay.

Liquid occlusion uses the object's blue footprint geometry. Multiple footprint
shapes are combined. Geometry diagnostics show the calculated waterline.
Consequently, a bed-bound rock rises and becomes more visible in shallow water,
while a floating boat remains at the same water elevation.

A pre-rendered dock with pillars is still fixed artwork. Its deck can be bound
to an elevated geometry-only surface, but genuinely variable pillar lengths
require separate or generated support pieces spanning from that deck to the
sampled bed. Bathymetry deliberately does not stretch arbitrary sprites.

### Stairs and other transitions

1. Make the source floor the active **Target surface**.
2. Select **Link** (the surface connector tool).
3. Choose the destination surface, traversal kind, width, and directionality.
4. Click the source landing, then the destination landing.

In the game, walking into a connector landing changes the actor's current
surface and moves it to the paired landing. Navigation is rebuilt for the new
surface. The current first version treats the connector itself as an atomic
transition; animated travel along long stairs and ladders can be added without
changing the saved model.

## Navigation and collision

Navigation is generated for one surface at a time:

- cells outside a non-base surface polygon are blocked;
- an unwalkable surface or blocking paint material is blocked;
- blocking liquid on that bed surface is blocked;
- only object colliders with the same `supportSurfaceId` participate;
- a player cannot cross to another surface except through a connector.

Characters use a radius, so their whole ground contact stays away from object
collision instead of allowing their center to touch the polygon edge. Animals
also retain their authored support surface and use that elevation.

Collision shapes and render footprints still have different roles. A tree can
have a small blocking trunk and a larger depth footprint; a roofed shelter can
have several pillar blockers and several footprint shapes while leaving its
interior walkable.

## Streaming

Physical data remains chunk-local at runtime:

- non-base surfaces, liquid volumes, and connectors are stored in every chunk
  they overlap and deduplicated by stable ID when loaded;
- paint and placed objects retain their surface references;
- the base surface comes from the world manifest;
- the manifest stores both player-spawn and current editor surface IDs.

This allows an open world to load nearby chunks without loading every floor,
liquid, or object in the project.

## Current limitations and next work

- The editor creates flat surfaces; visual ramp-height handles are not yet
  exposed.
- Liquid bathymetry currently uses one linear shallow-to-deep ramp per liquid
  polygon. Freeform height-field sculpting and generated dock supports remain
  later extensions.
- Connector traversal snaps between landings. It does not yet play a bespoke
  stairs, ladder, or portal animation.
- `visibilityGroupId` is saved but automatic roof hiding and interior reveal
  policies are not implemented.
- Cross-surface route planning currently requires reaching a connector on the
  current surface first. A future graph router can plan through several
  surfaces and connectors in one click.
- Elevated worlds render their surface layers directly. Chunk raster caching
  remains optimized for the common one-surface case and can later be extended
  per surface without changing authored data.

These are extensions of the explicit model, not reasons to return to generic
z-order or paint-as-physics fields.
