# ADR-0022: Foundry's own 2D collision, scoped to collision rather than dynamics

**Status:** Accepted
**Date:** 2026-09-05

## Context

`CLAUDE.md` §9 scheduled "physics: own vs. ported" for M5, with three notes attached: 2D
collision first, 3D physics far later, and it must respect I9. M5 is the milestone that needs
it — tilemaps with collision, collision detection and response, spatial partitioning, and a
top-down tile sample a person can play.

Licensing does not decide this one. Box2D v3 and Chipmunk2D are both MIT, both permitted by
ADR-0016, and both would compile under `build.zig` without a new build tool (ADR-0014). The
question is therefore entirely about what Foundry needs, what it owns, and what I9 costs.

**What a tile-based game actually needs is not what a rigid-body engine provides.** A
character walking around a tilemap needs: a moving box tested against static geometry, a
resolution that slides along a wall instead of stopping dead at it, overlap volumes that fire
an event rather than push, a ray for line-of-sight, and a broadphase so the moving things do
not test each other pairwise. It does not need mass, inertia tensors, restitution, friction
solving, joints, or stacking stability — the parts a rigid-body engine is mostly made of, and
the parts that are hard to get right.

**I9 raises the cost of a ported solver specifically.** ADR-0013 promises that the same binary
with the same inputs and seed produces the same result, which requires stable and *documented*
iteration order anywhere order affects outcomes. In a constraint solver, order affects
outcomes everywhere: the sequence in which contacts are resolved changes the answer. A
third-party solver either happens to satisfy this or does not, its ordering is an
implementation detail it is free to change between versions, and verifying the property means
reading someone else's solver as carefully as writing our own.

## Decision

**Foundry implements its own 2D collision, in a new `physics2d` module that depends on `core`
alone.** No third-party physics dependency.

The scope is stated precisely, and everything outside it is *absent* rather than
half-implemented:

**In scope for M5.**

* Shapes: axis-aligned box and circle. A closed set today.
* A **tile grid as a first-class static shape source**, not as a wall of generated boxes.
  Collision against a grid is a bounded cell walk, so the broadphase is not involved and a
  10,000-tile map costs nothing to have.
* Swept tests, so a fast mover cannot pass through thin geometry between two ticks.
* A uniform spatial hash broadphase for moving bodies.
* Queries: point, overlap, ray, and shape cast.
* Response: penetration resolution with sliding along the contacting surface.
* Trigger volumes — overlap reported, nothing pushed.

**Explicitly not in scope.** Mass and inertia, restitution, friction solving, joints,
stacking, torque, rotating bodies, convex polygons, and anything that would be called a
solver. These are not "later in M5"; they are absent, and content that asks for one gets an
error rather than an approximation.

**Floating point, `f32`, no fixed-point today.** ADR-0013 keeps a fixed-point subset available
as the upgrade path if lockstep networking is ever wanted, and this module is the place that
would happen. It is not paid for now, and no scalar type alias is introduced to pretend
otherwise — an alias that has never had a second instantiation is a guess dressed as an
abstraction. What *is* owed to the upgrade path is real and cheap: this module's arithmetic
stays self-contained and stays within `+ - * /`, `sqrt`, comparison, `min`/`max` and `abs`. No
transcendentals, no `std` float helpers whose precision is unspecified, no fast-math (I9 rule
7). That keeps a conversion a bounded, mechanical job rather than a research project.

**Determinism is a property of the module, not of its caller.** Two rules, both binding:

1. **The broadphase never determines order.** A spatial hash is a lookup accelerator; its
   bucket layout depends on coordinates and capacity and must never reach the result. Candidate
   pairs are collected and then ordered by body handle before anything is resolved.
2. **Bodies iterate in handle order**, which is insertion order, and that is documented in the
   interface rather than merely true of the implementation.

**`physics2d` sits at L1, depending on `core` alone** — alongside `data` and `platform`, not
above `scene`. Collision is pure computation. It has no entities, no components, no content and
no I/O; a caller hands it shapes and positions and it answers questions. That makes every test
in it hermetic, makes it usable by a tool or a headless server with no world, and means the
game — not the physics module — decides how an entity's collider becomes a body.

## Consequences

* **No dependency**: no `THIRD_PARTY_LICENSES/` entry, nothing to re-verify across a pinned
  toolchain move, nothing that can be abandoned upstream, and no C in a path that will
  eventually carry mod-supplied numbers. The same argument ADR-0018 made about PNG.
* **I9 is satisfied by construction rather than by inspection.** We wrote the iteration order,
  so we can document it, and the fixed-scenario-run-twice test ADR-0013 asked for extends to
  cover physics rather than needing to trust a library.
* We get the interface Foundry wants — handles, explicit allocators, no callbacks into user
  code from inside a query — rather than adapting one shaped by a different engine's history.
* **Cost: we own the correctness, and collision has famously sharp edges.** Two are named here
  so they are designed against rather than discovered: tunnelling at high speed, which the
  swept test exists to prevent; and **catching on the internal edges between adjacent solid
  tiles**, where a box sliding along a flat wall snags on the seam between two tiles that are
  individually correct. The tile grid being a first-class shape source rather than a pile of
  boxes is largely a response to the second.
* **Cost: no rigid-body dynamics.** A game wanting crates that stack, ropes, or ragdolls is a
  second and substantially larger job. That is an accepted trade, made with the knowledge that
  the first game this engine is aimed at is a tile-based one.
* The interface is shaped so that a dynamics solver could later sit behind it, the way the RHI
  is shaped for a second backend. That is a shape, not a promise, and no code is written for it.
* **Cost: a smaller feature surface than a mature library on day one**, permanently. Box2D has
  had a decade of edge cases reported against it. We start at zero and pay it down with tests.

## Alternatives considered

* **Port Box2D v3 (MIT).** The strongest alternative: excellent, C, permissively licensed,
  actively maintained, and its v3 API is allocator-friendly. Rejected on three grounds. It is a
  rigid-body engine and M5 needs a collision engine, so most of what we would carry is unused
  weight in a path we would still have to validate. Its contact-solving order is an
  implementation detail we would be resting I9 on. And it would put a C library in the path
  that mod-supplied collider dimensions eventually travel — the same distinction ADR-0018 drew
  between the Metal shim (C in the trusted path, by necessity) and `stb_image` (C in the
  untrusted path, by choice).
* **Port Chipmunk2D (MIT).** Similar shape, smaller, older, less actively maintained.
  Rejected for the same reasons plus the maintenance one.
* **Put collision inside `scene` as a set of systems.** Tempting because a collider will be a
  component anyway, and it would avoid a new module. Rejected because it makes collision
  unusable without a world — a tool, a test, or a future headless server would all have to
  construct an ECS to ask whether two boxes overlap — and because it would put a broadphase's
  spatial data structure inside the module that must keep I9's iteration order simplest.
* **Own, with a full rigid-body solver now.** Everything above plus impulses, restitution,
  friction and joints. Rejected on sequencing rather than on principle: it is the largest
  single item that could be put in M5, the milestone's exit criterion does not need any of it,
  and development rule 8 asks us to distinguish what we need now from what we design for now.
  The interface is designed for it; the code is not written.
* **Defer physics past M5 and ship the sample with hand-rolled tile collision in the sample
  itself.** Cheapest, and genuinely reasonable. Rejected because tile collision written inside
  a sample is tile collision that never gets an interface, and M5's whole point is that the
  engine can carry a playable game rather than that a sample can fake one.

## Revisit if

* **A game built on Foundry needs rigid-body dynamics** — stacking, joints, ragdolls, or
  torque. At that point the question is whether to write a solver behind this interface or to
  port one behind it, not whether to replace the module.
* **Lockstep networking or cross-machine replay verification becomes real**, which makes the
  fixed-point question in ADR-0013 concrete, and makes this module the subset to convert.
* **Profiling shows the broadphase is the bottleneck** in a real scene rather than in a
  synthetic one. A uniform spatial hash is the right first structure and the wrong last one;
  replacing it must not change any result, which is exactly what rule 1 above guarantees.
* **3D physics.** That is Phase 4 and a separate decision, not this one extended. Nothing here
  should be read as having chosen anything about 3D.
