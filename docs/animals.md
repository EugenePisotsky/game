# Animals

Status: first playable actor foundation.

## Asset format

`content/Animals/*/Sprite_1.png` uses a compact 20 x 20, row-major sheet.
Every frame is square and its native size is `sheet width / 20`. The different
frame sizes are intentional and preserve the relative scale of cats, dogs,
horses, poultry, and other species at render scale `1.0`.

The eight directions use the same order as the character assets:

```text
south, west, east, north,
southWest, northWest, southEast, northEast
```

The compact animal export differs from the generic 21 x 21 monster-sheet
document. Its relevant ranges are:

| Clip | Source frames | Frames per direction |
| --- | ---: | ---: |
| walk | 1-64 | 8 |
| run | 65-128 | 8 |
| idle | 129-152 | 3 |
| idle fidget/action | 153-176 | 3 |

The Rust importer extracts those ranges into separate 8-row runtime atlases.
The full source sheets must never be bundled or decoded at runtime: all 29
sources together would occupy approximately 1 GiB as decoded RGBA images.

## Authored representation

Animals are placed through the normal environment object workflow. A placed
object is the animal's stable identity and home point. Its catalog asset has an
`animalAnimation` definition that links it to a default shared behavior
profile. A placement can override that profile without duplicating artwork.

This deliberately reuses selection, layers, copy/paste, chunk ownership, and
release filtering. The game recognizes animated animal assets and does not
render them as static objects or include them as blocking navigation geometry.

When an animal is selected, the editor draws its configured home radius. The
circle is a behavior boundary, not collision geometry. The inspector's
**Behavior profile** field assigns a profile to the selected placement. Choosing
the asset's default profile stores no override, keeping world files compact.

## Behavior profiles

Profiles are catalog data shared by many visual variants. They contain:

- home roaming radius;
- projected walking and running speed;
- minimum and maximum pause duration;
- weights for idle, walk, run, and action choices.

Initial profiles:

| Profile | Intent |
| --- | --- |
| `cat_household` | Alternates walking, short runs, resting, and fidgeting within a small home area. |
| `dog_household` | Mostly walks, sometimes runs, and remains near its owner/home area. |
| `poultry_yard` | Walks frequently and uses the fidget clip as a peck/eat action. |
| `horse_stabled` | Remains at its authored home point and plays only idle animation. |
| `donkey_paddock` | Moves slowly within a small paddock. |
| `deer_wild` | Uses a larger home area and frequently runs. |
| `wolf_wild` | Uses a larger home area and strongly favors running. |

The runtime chooses activities deterministically from the placed object ID.
Movement targets are sampled inside the home circle and resolved through the
same native collision-aware navigation world as the player. A route is rejected
if any aligned waypoint leaves the home boundary.

## Runtime activation

Only animals belonging to loaded chunks can become active. Within those
chunks, activation uses separate enter and leave radii around the player so an
animal does not repeatedly load and unload at one exact boundary. Inactive
animals retain compact logical state but are neither updated nor rendered.

Active animals participate in dynamic depth insertion alongside the player.
Static environment depth order remains cached; it is not rebuilt every frame.

## Current limitations

- Animals do not avoid or push one another yet.
- The player and animals can currently overlap; animal footprints are used for
  depth and selection, not blocking.
- Abstract off-screen time advancement is not implemented yet.
- Behavior reactions such as fleeing, observing, following, hunger, and sleep
  will extend profiles and state transitions later.
- Profiles are shared presets; a one-off numeric radius override is not exposed
  yet. Create another profile when a reusable behavior boundary is needed.

These limitations keep the first slice focused while preserving the same
activation and event concepts intended for the later NPC simulation.
