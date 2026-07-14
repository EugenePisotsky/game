# World persistence and save architecture

Status: proposed storage design.

## Purpose

Neura needs durable storage for an expanding authored world and for mutable NPC,
quest, inventory, relationship, and scheduler state. The current JSON documents
are useful prototypes and interchange fixtures, but they are not intended to be
the final query or transaction layer.

SQLite will be introduced inside the existing Rust crate. It does not replace
image assets or require another Flutter package.

## Database roles

### Authoring database

`world.sqlite` is the editor's working database. It contains authored world
facts plus editor-only metadata. The editor opens it read/write and uses
transactions for every durable command.

### Release database

`world.db` is a compact export placed in the game asset bundle. It contains only
runtime data, is checkpointed before packaging, and is opened read-only by the
game.

### Save database

`save_<slot>.db` contains state specific to a playthrough. It references stable
IDs from `world.db` and stores overrides instead of copying unchanged authored
rows.

```text
world.db                             save_001.db
-------------------------------      ------------------------------
npc Elena has schedule farmer  <---- Elena is 12 minutes late
door A starts closed            <---- door A is open
chest B contains authored loot  <---- chest B has been emptied
road R connects village/farm          current tick and event queue
```

The save records the world ID and compatible world revision. Loading validates
that relationship before applying overrides.

## Ownership and concurrency

Rust is the sole owner of database connections and the only SQL writer.

- Flutter sends typed commands such as `place_object`, `move_road_node`, or
  `record_conversation_delay`.
- Rust validates each command and commits it in one transaction.
- Rust returns changed snapshots or IDs in batches.
- Widgets and Flame components never issue SQL.
- The first implementation uses one serialized writer. Read operations may be
  batched through the same worker until profiling proves a read pool necessary.
- Editor undo and redo execute inverse/forward domain commands, not arbitrary SQL
  text.

This keeps SQL, migrations, and consistency rules out of UI code and prevents
Dart and Rust connections from competing for write locks.

## Stable identity

All cross-table and save references use stable opaque text IDs. SQLite integer
primary keys may be used internally for performance, but must never appear in
world files, save commands, dialogue references, or editor copy/paste payloads.

Recommended properties:

- IDs are generated once and never derived from display names or coordinates.
- Renaming or moving an entity does not change its ID.
- Duplicating an entity generates a new ID and rewrites internal references.
- Imported legacy IDs are retained when valid.
- Deleting a referenced entity is rejected or handled by an explicit cascading
  domain command.

## Authoring schema outline

This is a responsibility map, not final SQL. Exact columns should be introduced
through migrations and verified by repository tests.

| Table | Responsibility |
| --- | --- |
| `world_metadata` | World ID, name, revision, chunk size, default material |
| `chunks` | Existing and enabled chunk coordinates |
| `editor_layers` | Authoring hierarchy, visibility, locking, grouping |
| `terrain_strokes` | Material strokes and affected chunk bounds |
| `placed_objects` | Asset instances, transforms, layer, bounds, direction |
| `locations` | Named points or zones used by gameplay and schedules |
| `location_slots` | Concrete activity, interaction, entrance, and waiting spots |
| `road_nodes` | Intersections, endpoints, gates, bridges, and portals |
| `road_edges` | Logical road properties and route connectivity |
| `road_edge_points` | Ordered polyline geometry for each edge |
| `npc_definitions` | Authored character identity and initial placement |
| `schedule_templates` | Reusable daily/weekly schedule definitions |
| `schedule_entries` | Activity intentions, windows, priorities, and constraints |
| `authored_appointments` | Planned shared activities and participants |

Rows that are selected spatially should store chunk coordinates or conservative
world bounds with indexes. The first implementation does not require an SQLite
spatial extension.

Example indexes:

```sql
CREATE INDEX placed_objects_chunk
    ON placed_objects(owner_chunk_x, owner_chunk_y);

CREATE INDEX terrain_strokes_bounds
    ON terrain_strokes(min_chunk_x, max_chunk_x, min_chunk_y, max_chunk_y);

CREATE INDEX locations_chunk
    ON locations(chunk_x, chunk_y);
```

Objects overlapping multiple chunks still have one owner. Bounds determine
which adjacent chunk snapshots reference them; ownership must never be inferred
by duplicating the object row.

## Save schema outline

| Table | Responsibility |
| --- | --- |
| `save_metadata` | Save ID, world ID/revision, current tick, player state |
| `npc_state` | Current activity, abstract trajectory, needs, active overrides |
| `scheduled_events` | Future durable scheduler events ordered by due tick |
| `activity_history` | Important completed, skipped, failed, or interrupted events |
| `appointment_state` | Runtime rendezvous and participant states |
| `entity_changes` | Added, changed, or deleted authored world entities |
| `inventory_entries` | Mutable ownership and quantity of game items |
| `relationships` | Directed or symmetric relationship state |
| `world_flags` | Quest, dialogue, door, container, and global facts |

The scheduler heap can be reconstructed from durable event rows. Ephemeral
frame-level commands and animation progress do not belong in SQLite.

## Structured columns and JSON payloads

Use normal columns for data that is indexed, joined, constrained, sorted, or
frequently inspected. Use JSON text for uncommon type-specific configuration.

For example:

```text
scheduled_events
  stable_id
  due_tick          -- indexed integer
  owner_npc_id      -- indexed reference
  event_type        -- indexed discriminator
  payload_json      -- event-specific parameters
```

This avoids both extremes: one unqueryable document blob and hundreds of tables
for every possible activity subtype.

Polyline point arrays may begin as ordered child rows. If profiling later shows
that geometry loading dominates, release export may encode them as compact
versioned blobs while preserving the authoring representation.

## Derived data policy

The following are not authoritative rows:

- Native blocked-cell grids.
- Weighted navigation grids.
- Smoothed A* routes.
- Terrain render pictures and texture caches.
- Compiled daily NPC plans.
- Spatial activation query caches.

They are derived from durable world/save facts. A cache may be persisted only
with a format version and source revision hash; the game must be able to discard
and rebuild it.

Do not create one SQLite row per navigation cell.

## Editor transactions and recovery

Every user-visible edit is a domain transaction:

```text
begin
  validate command
  change authored rows
  increment world revision
  append editor command metadata if required
commit
```

Recommended editor behavior:

- Enable foreign keys on every connection.
- Use WAL mode for the authoring database only.
- Keep a bounded set of periodic backup snapshots.
- Run `quick_check` on normal open and `integrity_check` during explicit
  validation/export.
- Checkpoint WAL before copying or exporting the project.
- Never package `-wal` or `-shm` files into the game.
- Surface migration and integrity failures before allowing further edits.

Undo history may initially remain session-local in Flutter. Later it can become
a persisted command log, but that is independent from the authoritative world
tables.

## Schema migrations

Use `PRAGMA user_version` as the database schema version. Rust contains an
ordered migration for every supported transition:

```text
0 -> 1 initial world tables
1 -> 2 logical locations
2 -> 3 road graph
3 -> 4 NPC schedules
```

Rules:

- Migrations run inside a transaction.
- The editor makes a backup before migrating an authoring database.
- Release databases are generated, not migrated in place by end users.
- Save migrations verify both save schema and referenced world compatibility.
- Every migration has a fixture test starting from the previous schema.
- Downgrades are not required; JSON export is the recovery/interchange path.

## Import, export, and version control

SQLite is the working source of truth, while JSON remains a useful interchange
and inspection format.

- Import the current manifest and chunk JSON once.
- Provide a deterministic JSON export grouped by world metadata and chunk.
- Sort exported entities by stable ID so diffs are meaningful.
- Exclude derived caches and editor-local UI state from debug exports.
- Validate both database and export through the same Rust domain model.

The binary authoring database can be backed up and checked in at milestones.
The deterministic JSON export supplies readable reviews and recovery without
forcing runtime queries back onto large JSON documents.

## Release packaging

The editor export command should:

1. Validate references and geometry.
2. Checkpoint pending writes.
3. Copy runtime tables into a fresh database.
4. Exclude editor-only columns/tables and unused content.
5. Build or invalidate versioned derived caches.
6. Run `ANALYZE` and integrity checks.
7. Atomically replace the packaged `world.db`.

The game opens `world.db` immutable/read-only and creates or opens a separate
save database in the application's writable data directory.

## Initial Rust API shape

Prefer commands and snapshots over generic CRUD:

```text
open_authoring_world(path)
import_environment_json(path)
apply_editor_commands(commands[])
load_chunk_snapshot(coordinates[])
validate_world()
export_release_world(path)

open_game_world(asset_path, save_path)
load_runtime_region(chunk_bounds)
advance_simulation(to_tick)
apply_game_events(events[])
flush_save()
```

The exact bridge types should contain domain values and stable IDs, not SQL
column names. Large operations are batched to keep FFI overhead predictable.

## First implementation slice

The first persistence slice deliberately excludes NPC simulation:

1. Add SQLite and migrations to the existing Rust crate.
2. Store world metadata, chunks, layers, terrain strokes, and placed objects.
3. Import the current environment JSON.
4. Load editor and game chunks through one Dart repository interface.
5. Export a read-only release database.
6. Add JSON debug export and round-trip tests.

Once this slice is stable, locations, roads, and schedules can be added without
changing ownership or packaging decisions.
