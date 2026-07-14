# World simulation implementation plan

Status: proposed implementation sequence.

This document connects three related foundations:

- [World persistence](world-persistence.md): SQLite ownership, authored world
  data, save-game overlays, migrations, and imports.
- [Road network](road-network.md): persistent logical roads, weighted local
  navigation, and coarse long-distance routing.
- [NPC simulation](npc-simulation.md): schedules, off-screen progression,
  materialization, interruptions, and meetings.

The existing environment JSON and native navigation implementation remain the
starting point. The migration should be incremental; the editor and game must
continue to open a small world at the end of every phase.

## Target architecture

```text
Asset files and catalogs
          |
          v
Editor -> authoring world.sqlite -> release world.db (read-only)
                    |                        |
                    |                        +----+
                    v                             v
             JSON debug export             Rust world service
                                                   |
                                      +------------+------------+
                                      |                         |
                                save_<slot>.db             Flame snapshots
                                (mutable overlay)           (active entities)
```

Rust owns SQLite, the road graph, the scheduler, abstract NPC state, and native
navigation. Flutter owns editor interaction, rendering, animation, camera,
conversation UI, and active Flame components. FFI calls operate on batches and
commands, never on individual database rows or navigation cells.

## Guiding decisions

1. Authored facts and playthrough state are stored separately.
2. Every persisted entity has a stable opaque ID; SQLite row IDs are internal.
3. Game time is an integer tick, not a floating-point wall-clock time.
4. Off-screen NPCs are event-driven and are not updated every frame.
5. Roads are logical persistent geometry, independent of their painted texture.
6. Local navigation is weighted; roads are preferred but not mandatory.
7. Long journeys use a coarse road/location graph before local pathfinding.
8. Derived data such as occupancy grids, weighted grids, compiled daily plans,
   and chunk pictures may be cached but can always be rebuilt.
9. Rust is the only database writer. Editor undo/redo sends commands through the
   same service instead of writing SQL from Dart.
10. The first version remains single-player and local. Networking and server
    authority are out of scope.

## Phase 0: contracts and fixtures

Before replacing storage, define the contracts that later phases depend on.

- Choose stable ID conventions for worlds, chunks, objects, locations, road
  nodes, road edges, NPCs, schedules, activities, and appointments.
- Add an integer `GameTick` convention and calendar conversion rules.
- Create a tiny fixture world containing two houses, one farm, one river, one
  bridge, and three NPC definitions.
- Record the current environment JSON as an import fixture.
- Add architecture tests asserting that save data refers to stable authored IDs
  rather than SQLite row IDs.

Acceptance gate:

- The fixture and its expected IDs are committed.
- Time conversion and stable-ID rules are documented and tested.
- No runtime behavior changes yet.

## Phase 1: SQLite foundation

Implement the database boundary inside the existing `neura_world` Rust crate.

- Add bundled SQLite through Rust.
- Add schema migrations using `PRAGMA user_version`.
- Add typed Rust commands and snapshots for world metadata and chunks.
- Import the current manifest/chunk JSON into an authoring database.
- Export a deterministic, chunked JSON debug snapshot from the database.
- Produce a compact, checkpointed release database.
- Add transactions, foreign-key enforcement, integrity checking, and editor
  backup rotation.
- Keep the existing JSON repository available behind the same Dart interface
  until the SQLite repository passes parity tests.

Acceptance gate:

- Editor changes survive restart.
- A JSON world imports into SQLite and exports without semantic loss.
- The game streams the same visible chunks from `world.db`.
- Release builds never open the authoring database for writing.
- A failed editor command rolls back atomically.

## Phase 2: semantic world locations

Add authored places before schedules refer to them.

- Add named locations, zones, entrances, and activity slots.
- Support tags such as `home`, `farm`, `fishing`, `meeting`, and `sleeping`.
- Support capacity and slot reservations.
- Add editor overlays and inspectors for locations and slots.
- Connect important slots to the local navigation grid.

Acceptance gate:

- The fixture contains homes, farm work positions, fishing positions, and a
  meeting position.
- The editor detects duplicate IDs, missing references, and unreachable slots.
- Game code resolves semantic location IDs to concrete world positions.

## Phase 3: logical roads and weighted navigation

Implement the persistent road model described in
[road-network.md](road-network.md).

- Add editable road nodes and polyline edges.
- Add explicit intersections, bridges, gates, and entrances.
- Rasterize road influence into the native weighted navigation grid.
- Extend Rust A* from blocked/open cells to traversal costs.
- Build a coarse graph for travel between semantic locations.
- Add navigation debug views for blocked cells, movement cost, and chosen road
  edges.

Acceptance gate:

- A character prefers the fixture road when it is a reasonable route.
- It crosses only the authored bridge when travelling over water.
- A nearby destination does not produce an absurd road detour.
- The same road route supplies deterministic off-screen travel duration.

## Phase 4: game clock and scheduler

Build the smallest event-driven simulation without visible NPC components.

- Add a deterministic game clock with pause and configurable time scale.
- Add a Rust min-heap of scheduled events.
- Persist enough scheduler state to resume exactly after loading.
- Add schedule templates, activities, and compiled daily plans.
- Implement `stay`, `travel`, and one work activity.
- Process only due events when advancing from one tick to another.
- Add a scheduler inspection panel and accelerated-time test mode.

Acceptance gate:

- Thousands of dormant fixture NPCs do not create per-frame work.
- Advancing directly from 07:00 to 18:00 produces the same deterministic state
  as advancing minute by minute.
- Save/load preserves current activities and future event order.

## Phase 5: NPC materialization

Connect abstract simulation to active Flame characters.

- Add prewarm, active-simulation, and visible radii around the player.
- Query which NPC trajectories intersect nearby chunks during an upcoming time
  horizon.
- Materialize characters outside the visible radius when possible.
- Convert coarse travel progress into a valid local navigation position.
- Let active characters use weighted native pathfinding.
- Compress stable active state back into an abstract activity when an NPC leaves
  the active radius.

Acceptance gate:

- An NPC travelling between fixture villages appears on the expected road.
- Entering and leaving the active region does not reset its schedule.
- No visible teleport occurs during ordinary streaming.
- Repeated materialize/dematerialize cycles preserve deterministic progress.

## Phase 6: interruptions and delay recovery

- Add interruptible activities and an interruption stack.
- Report player conversations and other active-world delays to Rust.
- Replan the remaining day using activity windows, priority, minimum duration,
  and slack.
- Support shift, shorten, skip, cancel, and hard-deadline outcomes.
- Preserve the authored schedule template; store only runtime deviations in the
  save database.

Acceptance gate:

- Holding an NPC in conversation makes it late rather than teleporting it back
  onto its original plan.
- A flexible activity shortens before a hard appointment is missed.
- Missed activities have explicit recorded outcomes visible in diagnostics.

## Phase 7: shared appointments

- Add an appointment entity shared by all participants.
- Reserve one venue and compatible activity slots.
- Plan participant travel against the same arrival window.
- Implement waiting, grace period, start, completion, cancellation, and no-show
  states.
- Resolve appointments abstractly off-screen and visibly when materialized.

Acceptance gate:

- Two fixture NPCs meet at the same position and time window.
- The first arrival waits for the second.
- Player interference can delay or cancel the meeting without corrupting either
  NPC schedule.
- Off-screen and active resolution produce equivalent durable outcomes.

## Phase 8: scale, tooling, and hardening

- Add scheduler, database, road, and materialization profiling counters.
- Add an editor timeline preview that does not mutate the actual save.
- Add world validation for broken references, disconnected roads, unreachable
  activity slots, and incompatible schedules.
- Add migration fixtures for every released schema version.
- Add recovery for interrupted writes and incompatible world/save revisions.
- Stress-test world streaming and at least 10,000 dormant NPC schedules.

Acceptance gate:

- The game maintains its frame budget while abstract simulation advances.
- Database queries and simulation work have explicit time budgets and counters.
- Old fixture saves migrate or fail with a precise compatibility explanation.

## Features deliberately postponed

- General-purpose constraint-solving or machine-learning planners.
- Fully dynamic road construction during play.
- Multiplayer synchronization.
- Continuous simulation of every off-screen action.
- Storing rendered images, navigation cells, or sprite bytes in SQLite.
- Arbitrary SQL access from widgets or Flame components.

The vertical slice is successful when one day in the fixture world remains
coherent whether the player watches it, leaves the area, accelerates time,
interrupts an NPC, saves and reloads, or arrives late to an NPC meeting.
