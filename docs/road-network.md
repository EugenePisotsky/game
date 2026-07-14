# Logical roads and route network

Status: proposed navigation and editor design.

## Purpose

Painted dirt, grass, stone, and bridge images describe appearance. They do not
reliably describe connectivity, road width, allowed travellers, or expected
travel time. Neura therefore needs persistent logical roads that can follow the
visual artwork without being inferred from its pixels.

The same authored road geometry serves two navigation scales:

- A weighted local navigation field for active characters.
- A coarse graph for long journeys and abstract NPC simulation.

## Authored model

The first version uses editable polylines rather than Bézier splines. Polylines
are simple to serialize, select, split, rasterize, and measure. Curve handles can
be added later without changing road connectivity.

### Road node

A node represents an endpoint or meaningful connection:

- Intersection.
- Location entrance.
- Building door.
- Bridge or dock endpoint.
- Gate or portal.
- Region boundary handoff.

Suggested fields:

```text
RoadNode
  stableId
  position(x, y, surfaceId)
  kind
  locationId?
  enabled
  tags[]
```

### Road edge

An edge connects two nodes and owns ordered geometry between them:

```text
RoadEdge
  stableId
  fromNodeId
  toNodeId
  points[]
  width
  surfaceType
  traversalCost
  speedMultiplier
  allowedActorTags[]
  directionPolicy
  enabled
  visualStrokeId?
```

`visualStrokeId` is an optional association, not ownership. A logical trail may
have no visual paint, and a decorative dirt patch may have no logical road.

Edges are bidirectional by default. One-way direction is retained in the model
for gates, scripted passages, or future traffic rules.

### Portals and bridges

Bridges and doors must not be approximated only by cheap cells. They are
explicit connections between walkable regions or surfaces. A bridge edge owns
its deck width and endpoints; local navigation still avoids its railings and
other object collision.

## Local weighted navigation

The native navigation field evolves from one blocked byte per cell into a
traversal-cost field plus blocked state.

Initial example costs:

| Surface | Base cost |
| --- | ---: |
| Good road | 0.65 |
| Footpath | 0.80 |
| Ordinary ground | 1.00 |
| Dense vegetation | 1.20 |
| Mud or shallow water | 1.50 |
| Blocked | impassable |

A road edge is rasterized as a corridor using its centreline and width. The
step cost is based on geometric step distance and the relevant cells' traversal
cost. Obstacles remain absolute constraints.

Actor profiles may modify costs:

```text
Villager: prefers roads and avoids dense vegetation
Hunter:   mild road preference, lower forest penalty
Cart:     requires sufficiently wide permitted edges
Animal:   little or no road preference
```

Road preference is never an unconditional command. A sufficiently long road
detour must cost more than a short crossing over ordinary ground.

The first implementation should use fixed tested weights. Per-NPC preferences
can be added after the shared system behaves naturally.

## Coarse routing

Long journeys are planned in three stages:

1. Local path from the actor or semantic location to a suitable road node.
2. Coarse A* over road nodes and edges.
3. Local path from the final road node to the exact activity slot.

The coarse edge cost includes:

- Measured polyline length.
- Surface speed multiplier.
- Actor permissions and profile.
- Dynamic enabled/disabled state.
- Optional gate, ferry, or transition delay.

The resulting route is an ordered list of edges. It supports both active
movement and off-screen trajectory calculation.

## Off-screen trajectories

An abstract travel activity stores:

```text
routeEdgeIds[]
departureTick
expectedArrivalTick
currentEdgeIndex
edgeEntryTick
```

Given a game tick, Rust locates the current route edge and interpolates distance
along its polyline. It can therefore answer:

- Expected world position.
- Expected chunk and upcoming chunks.
- Remaining travel time.
- Whether the NPC should enter the player's prewarm region.

No per-frame off-screen movement is required.

When materializing, the expected point is projected onto the road centreline
and then reconciled with the current local navigation field. If the road has
become blocked, active navigation replans and reports the resulting delay to the
scheduler.

## Dynamic changes

The first road network is authored and static during play, but individual edges
may be enabled or disabled by world state:

- Closed gate.
- Destroyed or repaired bridge.
- Flooded path.
- Scripted blockade.

Changing an edge increments the route-network revision. New trips use the new
graph. Existing abstract trips are replanned at their next event boundary, or
immediately when the changed edge is part of their remaining route.

## Editor tool

Road mode should support:

- Click to create a polyline.
- Finish, cancel, undo, and redo while drawing.
- Keep the completed road selected.
- Drag existing points after creation.
- Insert and delete points.
- Split an edge at a point.
- Join endpoints and automatically create an intersection node.
- Snap endpoints to nearby nodes, entrances, bridges, and location slots.
- Edit width, surface, cost, permissions, and enabled state.
- Associate or generate an optional terrain material stroke.

The editor should display:

- Centreline and width corridor.
- Node and intersection handles.
- Edge direction.
- Disconnected endpoints.
- Bridge/portal connections.
- Weighted navigation overlay.
- A preview route for a selected actor profile.

Visual paint remains editable independently. Moving a logical road should ask
whether its associated visual stroke should move as well; it must not silently
rewrite hand-painted terrain.

## Validation

World validation reports:

- Edge endpoints referencing missing nodes.
- Consecutive duplicate or zero-length points.
- Disconnected location entrances.
- Road corridors narrower than permitted actor profiles.
- Bridges that do not connect compatible walkable surfaces.
- Intersecting visual roads without a logical graph intersection.
- Activity locations unreachable from the route network.

Some reports are warnings rather than errors. A forest cabin may intentionally
be reachable only by walking off-road.

## Debugging and profiling

Extend navigation debug mode with selectable overlays:

- Blocking geometry.
- Traversal cost heatmap.
- Road corridors and graph nodes.
- Coarse route.
- Final smoothed local path.
- Expanded cells and pathfinding duration.

Counters should distinguish coarse graph time, local weighted A* time, and grid
rasterization time.

## Vertical-slice acceptance scenario

Use two villages separated by water, with a farm branching from the main road:

1. A villager starts at a house.
2. It joins the village road.
3. It crosses the authored bridge rather than water.
4. It follows the main road toward the farm.
5. It leaves the road near a work slot.
6. A nearby target across grass remains a direct trip rather than a large road
   detour.
7. The same route produces an expected off-screen position and arrival time.

Only after this behaves well should road-type-specific visuals, curve handles,
or dynamically constructed roads be added.
