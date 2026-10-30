# ADR-0070: Agents are values a game ticks, and a rebuilt mesh reaches them as an input

**Status:** Proposed 2026-10-30 (`docs/design/agents.md`)
**Date:** 2026-10-30

## Context

M33 puts agents on M32's meshes: path search, agents that follow paths and avoid each other,
and obstacles that cut a running mesh, with the court's warden as the consumer that plays. Three
questions decide its shape:
- **Where agents live.** `nav` sits at L1 on `core` alone (ADR-0069), and the warden is moved by
  `physics3d`'s controller, also at L1. `navigation.md` left open whether an engine service or a
  higher module should join them.
- **How agents avoid each other.** The method must be deterministic on one machine (I9), must
  use no global RNG, and must not depend on a linked libm.
- **How a running mesh reaches a tick.** A rebuild takes milliseconds, so it belongs on
  `core.Tasks`. But when a task arrives is a wall-clock fact, and ADR-0061 forbids that reaching
  simulation. Until now nothing in a tick read a mesh. The warden will.

## Decision

1. **Paths, agents and avoidance are in `nav`.** `nav.Query` searches. `nav.Crowd` holds agents
   behind generational handles (I1). A crowd is a value a game owns and ticks beside its
   collision world, as ADR-0051's characters leave velocity, gravity and time to their caller.
   There is no engine service and no store of meshes: a crowd borrows the mesh it is given.
2. **An agent wishes, and the game moves it.** `Crowd.step` computes each agent's displacement
   for the tick. The game applies it however it likes, by a controller, directly, or along a
   link, and reports the body's place with `place`. `nav` never sees `physics3d`, and the
   collision world stays the truth about where a body is.
3. **Avoidance is ORCA,** reimplemented from the published method. Each agent solves a small
   2D linear program from last tick's velocities, so the order of agents doesn't matter. A
   perfect symmetry is broken by turning every preferred velocity by the same tiny angle, so
   agents keep to one side. There is no randomness and no trig. Walls are not ORCA constraints: the mesh clamps the move.
4. **A running obstacle is a source, and cutting is a whole rebuild.** A box joins the sources at
   its current pose, and the ordinary build runs on the background pool, one at a time with
   later changes coalesced. There is no incremental update and no retained heightfield.
5. **A rebuilt mesh reaches simulation only as a recorded input.** This is ADR-0061's decision
   4, used for the first time. A frame that receives a mesh gives it a generation number and
   puts that number in the next tick's input. The tick applies it first. A replay given the
   same input reads the same mesh, because a mesh's bytes are a pure function of its inputs.
   A game gates play the same way, until its first mesh is there. ADR-0061 stands unamended.

## Consequences

- `nav` stays small and testable with no engine, and a game can move agents any way it likes.
- A game writes a few lines per tick to join crowd and controller, and the glue that reads
  recipes stays in the samples until M48 needs a shared form.
- Two runs of the same game can differ: a slow machine adopts a mesh a few ticks later. That is
  a different input, and each run still replays exactly. Tests must force adoption ticks to
  compare runs with each other, which is the cost of never stalling.
- During a rebuild an agent uses the old mesh. Collision keeps it out of a new obstacle, but it
  may press against one for a few ticks.
- A whole rebuild costs a game's level, not its obstacle's size. A level near ADR-0069's 150 ms
  would feel that first, and M60's tiles are its answer.
- Agents cannot pass in a passage one wide. They report `blocked`, and a game decides who backs
  up.
- Mods gain areas and links as content now. Paths and crowds wait for M48.

## Alternatives considered

- **An engine service, or a new L3 module joining `nav` and `physics3d`.** Rejected. `app` owns
  no world, so a service would hold agents apart from the body each one moves. The joint is a
  few lines, and a service would have to expose the very choices a game makes.
- **`nav` moving bodies itself through a callback.** Rejected. A game then reasons about a
  callback inside a step, for a seam that is simpler as two calls.
- **Detour's sampled velocity avoidance.** Rejected as the default. It tolerates wall contact
  and crowding well, but costs tens of samples per agent per tick, while ORCA is one small
  program, and the samples' numbers do not need the difference.
- **Reactive steering (separation forces).** Rejected. It gives no guarantee, and criterion 3's
  separation bound could not be asserted.
- **ORCA with random perturbation.** Rejected. It needs an RNG threaded through a tick for
  something a fixed rule does.
- **Boundary segments as ORCA lines.** Rejected for now. It is the textbook form and costs a
  gather of nearby edges per agent, where a clamp on the mesh already holds agents in place.
- **Toggling polygons, or clipping them at run time.** Rejected. Flags need every obstacle known
  at build time, which a moved crate is not. Clipping needs partial-edge portals, which M32's
  whole-edge graph avoids entirely, and is much the most code.
- **A retained heightfield, marked and re-processed.** Rejected until measured. It saves
  rasterisation only, and the whole build is 14 ms on the i3.
- **Adopting a mesh at a fixed tick, stalling if it is late.** Rejected, as ADR-0061 rejected it
  for loads: it stalls exactly when a build is slow.
- **Building a rebuild on the main thread inside the tick.** Rejected. It is the simplest
  determinism, and costs a frame of 14 ms on the i3 every time a door opens.

## Revisit if

- A crowd step of 32 agents passes 3 ms on the i3, or a game needs more than 256 agents. Sampling
  or a parallel step is reconsidered.
- A scene's agents keep leaving the separation bound at walls. Boundary segments become ORCA
  lines.
- A rebuild takes more than ADR-0069's 150 ms on the i3, or a game moves obstacles fast enough
  for rebuilds to lag visibly. Tiles move ahead of M60.
- A game needs a mesh in a tick before input can bring it, which is ADR-0061's own revisit.
- A second game needs agents and bodies joined the same way, which would argue for a shared
  helper.
