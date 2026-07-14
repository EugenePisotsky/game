# NPC schedules and simulation levels

Status: proposed simulation design.

## Objective

NPCs should appear to live continuously without requiring every character to
exist as a Flame component or perform realtime pathfinding while off-screen.
They may work, travel, fish, visit neighbours, meet one another, be interrupted
by the player, and recover from delays.

The simulation records intentions, trajectories, events, and outcomes. It does
not continuously animate the entire world.

## Simulation levels

| Level | Representation | Update model |
| --- | --- | --- |
| Dormant | Current stable activity plus next event | No work until event is due |
| Abstract | Timed activity or route trajectory | Event boundaries and queries |
| Prewarmed | Native state plus prepared visual definition | Fixed simulation tick |
| Active | Flame component, local path, animation, interaction | Realtime near player |

Suggested spatial bands:

```text
visible radius < active radius < prewarm radius
```

The prewarm band gives the game time to load sprites, calculate a local path,
and instantiate an NPC outside the player's view. Hysteresis between activation
and deactivation radii prevents repeated toggling near a boundary.

Simulation level is runtime state, not part of an authored schedule.

## Game clock

Simulation time is a signed 64-bit integer `GameTick` with a documented epoch
and fixed number of ticks per game minute. Calendar presentation converts ticks
into day, weekday, season, hour, and minute.

Requirements:

- Pause and configurable time scale.
- Deterministic advancement independent of frame rate.
- Direct advancement over long unloaded periods.
- Seeded random choices derived from stable IDs and relevant time periods.
- Save/load resumes at exactly the same tick.

Flutter supplies elapsed realtime and presentation controls. Rust owns the
authoritative accumulated game tick.

## Semantic locations and activity slots

Schedules refer to semantic IDs, not raw coordinates:

```text
elena.home
north_farm.work_zone
river.fishing_zone
marta.home.front_door
village_square.bench_2
```

A location may be a point or zone. It owns concrete slots for particular uses:

```text
ActivitySlot
  stableId
  locationId
  position and facing
  tags[]
  capacity
  allowedActorTags[]
  interactionTargetId?
```

Examples include a fishing bank position, crop row, chair, bed side, waiting
point, shop counter, or door entrance. The scheduler reserves capacity; active
navigation resolves the final local path.

## Schedule templates

A schedule describes intentions and constraints rather than exact poses at
every minute.

```text
ScheduleEntry
  activityType
  targetLocationId or locationQuery
  earliestStart
  preferredStart
  latestStart
  minimumDuration
  preferredDuration
  priority
  interruptPolicy
  missPolicy
  participantIds or appointmentId
  conditions[]
```

Templates can be selected by weekday, season, profession, quest state, weather,
or other world conditions. The first version only needs weekday and explicit
NPC assignment.

Example:

```text
06:00-07:30  wake/eat at home       flexible
07:00-08:30  travel to farm         derived duration
07:30-12:30  work at farm           may shorten
12:00-14:30  fish at river          optional
16:00-16:20  meet Marta             firm appointment
18:00-22:00  return home            flexible
```

The authored template is immutable during a playthrough. Rust compiles it into
a concrete daily plan and stores runtime deviations separately.

## Activities

All activities share a small lifecycle:

```text
planned -> travelling -> waiting -> performing -> completed
                    \-> skipped / failed / cancelled / interrupted
```

Initial activity implementations:

- `stay`: remain at a location until a time or condition.
- `travel`: follow a route to an activity slot.
- `work`: occupy a slot and produce a simple outcome.
- `meet`: participate in a shared appointment.

Fishing and farming should initially be configured forms of `work`, not unique
scheduler engines. Their active animations and outcome formulas can differ.

## Event-driven scheduler

Rust maintains a min-heap ordered by due tick and a stable sequence key. It does
not scan every NPC every simulation tick.

Example events:

```text
07:00 Elena starts travel to farm
07:18 Elena reaches farm entrance
07:21 Elena reaches reserved work slot
12:00 Tomas completes fishing outcome
15:45 Marta starts travel to appointment
```

Advancing time:

1. Pop all events whose due tick is at or before the target tick.
2. Apply each event deterministically.
3. Schedule resulting transitions.
4. Stop when the next event is beyond the target tick.
5. Return batched observable changes to Flutter.

Only durable future events need database rows. The in-memory heap is rebuilt
from them when opening a save.

## Abstract travel

Off-screen travel is a time-based trajectory over the logical road network:

```text
TravelTrajectory
  routeEdgeIds[]
  departureTick
  expectedArrivalTick
  current progress or edge entry ticks
```

Expected position is calculated along edge geometry only when queried. The
system does not record one location for every minute.

The spatial activation index records conservative chunk/time intervals for a
trajectory. When chunks enter the prewarm region, Rust can answer:

> Which NPCs may enter these chunks during the next N game minutes?

This avoids scanning every NPC. See [Road network](road-network.md) for route
geometry and long-distance travel cost.

## Materialization

When an abstract NPC approaches the player:

1. Calculate its expected route position at the authoritative tick.
2. Select a valid nearby point on the current local navigation field.
3. Create or reuse the active character state before it becomes visible.
4. Continue toward the current activity target using weighted native A*.
5. Report unexpected local delays or failures back to the scheduler.

When an active NPC leaves the deactivation radius:

1. Wait until it is not in conversation or another non-compressible action.
2. Reconcile actual position and time with its current route/activity.
3. Create a revised abstract trajectory if necessary.
4. Persist meaningful deviation and remove the Flame component.

Materialization is not a schedule reset. Repeating the transition must preserve
activity progress and deterministic outcomes.

## Interruptions and delays

Player conversation, combat, a blocked route, or a scripted event can interrupt
an active activity.

An interruption records:

- NPC ID.
- Start and end ticks.
- Actual position when released.
- Interrupted activity.
- Whether that activity may resume.
- Relevant outcome or cause.

Afterward, Rust replans the remaining day. Available recovery actions are:

- Shift a flexible activity.
- Shorten it to its minimum duration.
- Skip a low-priority activity.
- Cancel an activity whose latest start has passed.
- Preserve a hard appointment by sacrificing flexible work.
- Replace the remaining schedule with an emergency override.

Delay is not blindly added to every later timestamp. Each entry's window,
priority, duration, and miss policy determines the result.

The original schedule template remains unchanged. Only current plans and
deviations are stored in the save.

## Meetings and synchronization

NPC meetings use one shared appointment entity, not independent coincidentally
matching schedule entries.

```text
Appointment
  stableId
  participantIds[]
  venueLocationId
  reservedSlotIds[]
  preferredStart
  arrivalWindow
  minimumDuration
  gracePeriod
  latePolicy
```

Lifecycle:

```text
planned -> participants travelling -> waiting -> active -> completed
                                      \-> cancelled / no-show / rescheduled
```

The appointment coordinator owns synchronization:

- The first participant waits at its reserved slot.
- The meeting begins only when required participants are ready.
- A grace period determines how long late participants are tolerated.
- Player interference can cause a wait, shortened meeting, cancellation, or
  reschedule according to policy.
- Off-screen meetings resolve through the same states without animation.
- If the player approaches during the meeting, participants materialize at
  their reserved positions with correct progress.

This prevents two NPC schedulers from waiting on one another indefinitely or
making contradictory decisions.

## Off-screen activity outcomes

An abstract activity still changes the world. Completion evaluates a
deterministic outcome based on activity duration, skills, tools, location
quality, state, and seeded variation.

Examples:

- Fishing adds a calculated catch to inventory.
- Farming advances crop work or produces goods.
- A social meeting updates relationship or dialogue facts.
- Rest reduces fatigue.

Only important outcomes enter activity history. Realtime animation frames do
not.

If an NPC materializes partway through an activity, the completed fraction is
preserved. Visible behavior represents the remaining activity; it does not roll
the result again.

## Rust and Flutter boundary

Rust owns:

- Game clock and calendar calculations.
- Schedule compilation and replanning.
- Durable event queue.
- Abstract travel and road queries.
- Appointment coordination and slot reservations.
- NPC simulation state and persistence.
- Activity outcome calculation.
- Spatial activation queries.

Flutter/Flame owns:

- Active NPC components and sprites.
- Animation selection and interpolation.
- Local movement presentation.
- Conversation and interaction UI.
- Camera, audio, particles, and visible feedback.
- Reporting active-world facts back to Rust.

Example command flow:

```text
Rust -> materialize Elena, travelling to farm.work_slot_3
Flutter -> Elena delayed 8 minutes by player conversation at (x, y)
Rust -> revised plan; continue to farm, shorten work, preserve appointment
```

Use batch APIs such as `advance_simulation`, `query_region`, and
`apply_active_events`. Avoid one FFI call per NPC per frame.

## Save requirements

Persist enough state to reconstruct the exact abstract simulation:

- Authoritative game tick.
- Current NPC activity and progress.
- Current route/trajectory and network revision.
- Schedule template reference and compiled-plan deviations.
- Durable future events.
- Appointment and reservation states.
- Activity outcomes that affect game state.
- Deterministic seed inputs when they cannot be derived from stable IDs.

Sprite frame, interpolation state, hover state, and other visual details are not
persisted.

## Diagnostics and editor support

Required tools before scaling beyond the vertical slice:

- Game-clock controls and accelerated time.
- NPC inspector showing authored schedule, compiled plan, current activity,
  delays, and next event.
- Road and expected-trajectory overlay.
- Appointment participant/arrival status.
- Event queue counts and processing time.
- Active, prewarmed, abstract, and dormant NPC counts.
- Timeline preview in a disposable simulation state.
- Deterministic replay test for a selected NPC day.

## Vertical-slice scenario

The first test world has three NPCs:

- One travels from home to a farm and works.
- One travels to the river and fishes.
- Two share an evening neighbour visit.

Tests should cover:

1. Accelerating through a complete off-screen day.
2. Encountering the travelling NPC on the expected road.
3. Leaving and returning without resetting progress.
4. Delaying one NPC with a conversation.
5. Recovering the remaining schedule.
6. Starting, shortening, or missing the shared meeting correctly.
7. Saving and loading during travel, work, waiting, and the meeting.

The foundation is successful when these outcomes remain coherent regardless of
whether the player observes them in realtime.
