# ADR-0069: Navigation meshes are built by Foundry from collision triangles, at load

**Status:** Accepted 2026-10-28 (the owner asked for M32 Step 1; `docs/design/navigation.md`); implemented in M32 (2026-10-29, tag `m32`)
**Date:** 2026-10-28

## Context

M32's row is "navigation meshes built from collision geometry", and M33's is pathfinding,
agents and avoidance over them. Foundry already compiles collision geometry as content
(`foundry:collision_mesh`, ADR-0057), and `physics3d` copies it into its own tree. Three
questions decide everything that follows:
- **Whose builder.** Recast is the standard navigation-mesh builder: mature, zlib-licensed,
  written in C++. Foundry has so far written its own decoders, collision and mixer where the
  subject sits at the engine's core (ADR-0018, ADR-0022, ADR-0023, ADR-0051, ADR-0065).
- **Where it lives.** `physics3d` has the triangles, but it is collision without content, and
  §4.3 forbids a sideways dependency at L1.
- **When it is built.** A mesh baked into a package at compile time loads instantly. But the
  base package's level may be overridden, or added to, by a mod (I3, ADR-0027), and a bake
  made from the base package's geometry would then be wrong with nothing to say so.

## Decision

1. **A new module `nav` at L1, on `core` alone.** It takes triangles with rigid poses as
   values and copies them, as `physics3d` does (ADR-0057). It knows no asset, no collision
   world, no entity, no renderer and no clock.
2. **Foundry builds its own navigation meshes**, in Zig, by the voxel method Recast published:
   rasterise into spans, mark walkable spans by slope, filter by climb, ledge and clearance,
   erode by the agent's radius over a distance field, partition by watershed into regions,
   trace and simplify their contours, triangulate and merge them into convex polygons of at
   most six vertices, and add a detail mesh for height. It is reimplemented from the method,
   not from Recast's code. Every stage validates what reaches it, has fixed limits, and runs in
   a fixed order, so a build is deterministic on one machine (I9) and its output can be pinned.
3. **`foundry:nav_mesh` is a recipe, and the mesh is built at load.** The record names its
   collision sources, the agent (radius, height, climb and slope, meaning what the character
   controller's quantities mean) and the build's resolution. It is content, decoded in
   `asset`. The mesh is built from the **merged** store on the background pool (`core.Tasks`,
   ADR-0061), so it is always the mesh of the content that is running.
4. **A built mesh is its creator's value.** It has no content ID, no override and no save,
   like ADR-0063's runtime geometry. Its polygons are indices into it, valid until it is
   rebuilt.

## Consequences

- A mod that replaces a level's collision, adds a solid prop or changes an agent changes the
  navigation with no code and no stale data (`plinth` and `stout` in M32 prove it).
- Every load pays for a build. At M32's samples that is tens of milliseconds off the main
  thread. A world too large for that needs tiles and a cache, which M60 schedules.
- Foundry carries several thousand lines of geometry code that Recast already has, and has to
  find its own bugs in it. In return the builder validates untrusted input rather than
  asserting, allocates through Foundry's allocators, fails allocation cleanly, and is pinned
  by hash like every other deterministic subsystem.
- `nav` is a new module whose layer M33's agents, M48's table and the samples' grants must
  name.
- Navigation and collision stay independent: a change to `physics3d`'s tree or narrowphase
  cannot move a navigation pin, and the reverse.

## Alternatives considered

- **Recast and Detour, as a C++ dependency.** Rejected. It would be the engine's first C++
  code, compiled by `zig c++` into every game that navigates; its assertions and `dtAlloc`
  model are not Foundry's refusal-and-allocator rules, which a mod-supplied level needs; and
  its tile-reference shapes would become Foundry's navigation API unless wrapped, at which
  point most of the value is in the wrapper. Its licence would have been acceptable
  (ADR-0016).
- **Navigation inside `physics3d`.** Rejected. The modules change for different reasons, and
  a navigation build has no use for bodies, layers or the narrowphase. Sharing the content,
  not the module, keeps both small.
- **Walkable triangles merged directly, without voxels.** Rejected. Eroding by a radius and
  cutting overlapping floors need robust polygon offsetting and boolean operations on art
  meshes that are rarely clean. Voxels are robust to cracks, overlaps and T-junctions, at the
  price of a cell's resolution.
- **A waypoint graph or a grid.** Rejected. Neither gives an agent the whole walkable surface,
  and both need placing by hand or scale badly.
- **A mesh baked at package compile time.** Rejected for now. It goes stale under an override
  from another package, and M32's builds are fast enough at load. M60 adds a cache keyed by
  the inputs' content, which keeps a mod's mesh correct and saves the build.
- **Monotone partitioning in place of watershed.** Rejected as the default. It is simpler and
  faster but makes long, thin polygons that M33's search measures badly, and watershed's
  distance field is already paid for by erosion.

## Revisit if

- A sample's or a game's level takes more than 150 ms to build on the Arc PC's i3 in
  ReleaseSafe. Tiles and the cache then move ahead of M60.
- A game needs navigation over something that is not triangles before M63 (heightfields) or
  M66 (voxels).
- A feature thinner than a practical cell (a railing, a thin wall) must block agents, and no
  cell size within §4's bounds both keeps it and stays within budget.
- The reimplementation's defect rate, measured as fixes after its milestone closes, exceeds
  what Recast's integration would have cost. Then Recast is reconsidered behind `nav`'s
  existing interface.
