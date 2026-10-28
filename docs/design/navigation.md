# Design: M32 — Navigation I: navigation meshes built from collision geometry

**Status:** Accepted 2026-10-28, when the owner asked for Step 1, with §14 as written. Step 1 is done (2026-10-28); its Resolution follows §15.
**Date:** 2026-10-28
**Baseline:** `4aca795`, one commit past tag `m31` (`e46fa46`), which gave each sRGB byte one
linear value on every build. M0–M31 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0051 and ADR-0057: `physics3d` is collision without dynamics, and collision geometry
    is compiled content, `foundry:collision_mesh` (`.fcol`), that a consumer copies. Navigation
    is built from that same content, and it copies it too.
  - ADR-0048: right-handed, +Y up, −Z forward, metres, radians. "Up" for walking is +Y.
  - ADR-0061 and ADR-0062: background work is `core.Tasks`, and its arrival is presentation,
    never simulation. A navigation build runs there.
  - ADR-0063: what is built at run time is owned by handle or by its creator, never content.
    A built navigation mesh is that kind of thing.
  - ADR-0041 and ADR-0064: engine record types live in `asset`, so `fpack` checks them without
    linking their consumer.
  - ADR-0007: a new module takes its place in the build graph, and the graph enforces it.
  - ADR-0013: deterministic-friendly, not bit-exact across machines.
- It proposes one ADR:
  - [ADR-0069](../adr/0069-navigation-meshes-are-built-from-collision-at-load.md): Foundry
    builds its own navigation meshes, in a new L1 module `nav` on `core` alone, by the
    published voxel method (rasterise, filter, erode, partition, trace, polygonise, add
    detail). Geometry arrives as copied triangles. `foundry:nav_mesh` is a recipe, not a
    product: the mesh is built at load, on the background pool, from the merged content, so a
    mod that changes a level or an agent changes the navigation with no stale bake. A built
    mesh is owned by its creator, has no content ID and is never saved.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M32 | Navigation I | Navigation meshes built from collision geometry

The next row draws the line this milestone stops at:

> M33 | Navigation II | Pathfinding, agents and avoidance

Other documents point here by name:
- **`playable3d.md`:** §1 and §5 leave "navigation or a chasing AI (M32–M33)" out of M26, and
  §13's row says "a warden that sees and chases: M32–M33, navigation; the court's fixed patrol
  is deliberate".
- **`tilemaps-and-collision.md`:** it calls grid pathfinding "game logic" for 2D. That stays
  true: M32 is 3D navigation meshes, and 2D tile grids are not its subject (§13).

So M32 makes the **surface** an agent may stand on and the **graph** a path will be found
over. It finds no path. M33 searches the graph, moves agents along it and keeps them apart.
Splitting there is deliberate: a navigation mesh that is wrong (a step that does not connect,
a doorway the erosion closed, a table top joined to the floor) shows itself as a wrong
picture before any path is computed over it, and it is much cheaper to prove the picture
first.

**The runnable result** is the navigation mesh, built and drawn, in both 3D samples:
- **`sandbox3d`**, the capability demonstrator, draws the walker's navigation mesh over its
  room and course when `N` is pressed.
  - The four 0.15 m steps and the 25° ramp join the floor to the platform. The 55° ramp is not
    on the mesh.
  - The table, the crates, the pot and the glass are cut out of the floor, with the agent's
    radius around each.
  - Each region has its own colour, and the mesh's boundary is drawn darker.
  - **`plinth`**, the existing content mod, adds a solid prop. With `plinth` enabled, the mesh
    is cut around it, with no code.
  - Reloading content rebuilds the mesh on the background pool, and the old one is drawn until
    the new one arrives.
- **`samples/court`** builds the warden's navigation mesh from its level when it loads. M33's
  chasing warden will walk on it. It is drawn when `FOUNDRY_COURT_NAV=show` is set, and its
  shape is tested:
  - both of the warden's waypoints and the player's spawn are on one connected island;
  - the gap is not on it, and the pit's floor, if the level gives it one, is a separate
    island;
  - the low wall the player jumps cuts the mesh, because the warden cannot climb it.

**Exit criteria** (§11 gives each one's measure):
1. **Shape.** On every hand-made scene of §11, the mesh is what the scene implies: steps
   within the climb connect and steps beyond it do not; slopes within the limit are walkable
   and slopes beyond it are not; a corridor narrower than the agent closes; an obstacle's hole
   is its footprint grown by the radius; a floor under a ceiling too low for the agent is cut.
   Each is within one cell of its exact answer.
2. **Well-formed.** Every polygon of every mesh built in the suite is convex, wound
   counter-clockwise seen from +Y, and has at most its record's vertex count. Neighbour links
   are symmetric and share both vertices of their edge. Every detail triangle lies over its
   polygon, within `detail_max_error` plus one cell height of the source surface.
3. **Untrusted input.** Every out-of-range record field and build parameter is refused by
   name. Non-finite, out-of-bounds or oversized geometry is refused before allocation. A seeded
   sweep of mutated inputs and a full allocation-failure sweep neither panic nor leak.
4. **Determinism.** The same sources and record give the same mesh bytes every run. The
   course's mesh is pinned by hash, and the pin is equal in Debug, ReleaseSafe and under
   x86_64. Windows is compared and any difference recorded (ADR-0013).
5. **Cost.** In ReleaseSafe on one thread, the court's warden mesh builds in at most 50 ms on
   the M5 and at most 150 ms on the Arc PC's i3, and `sandbox3d`'s in no more. Built on the
   pool, it adds no frame over 16.67 ms to either sample at load or at a reload.
6. **The samples.** `sandbox3d` and the court, from a relocated ReleaseSafe install on the M5
   with Metal and on the Arc PC with Vulkan, under validation: the mesh is drawn, validation
   is clean, and the `plinth` cut and the court's island tests hold.
7. **Moddability.** `plinth` changes `sandbox3d`'s navigation with no code. A record override
   of the agent's radius changes it too, and the test proves both.
8. **Nothing else changes.** Every existing pin holds. No collision, rendering or audio
   behaviour moves.

**In M32:**
- the `nav` module at L1, on `core` alone (§3);
- the `foundry:nav_mesh` record, decoded and validated in `asset` (§4);
- the build: rasterisation, filters, erosion, regions, contours, polygons and detail (§5);
- the built mesh, its polygons, neighbour links, detail and `locate` (§6);
- the build as a task on `core.Tasks`, with the samples' glue (§7);
- a debug view of a mesh as coloured triangles (§8);
- `sandbox3d`'s and the court's meshes (§9).

**Not in M32**, each with its owner (§13 has them all):
- Path search, string pulling, agents, avoidance, off-mesh links, area types and costs, and
  obstacles that cut the mesh while a game runs (the court's gate) go to M33.
- Tiled meshes, a baked mesh shipped as an asset, and rebuilding tiles around a point go to
  M60 (Streaming).
- Navigation over heightfields goes to M63, and over voxels to M66.
- The table's navigation calls go to M48, and Lua to M49.

## 2. What exists

- **Collision geometry** (`engine/src/asset/collision_mesh.zig`): `.fcol` v1 holds positions
  and `u32` indices, bounds-checked against the same 8,192 m envelope as `physics3d`, with at
  most 3,145,728 vertices and 1,048,576 triangles. `View.copy` gives an aligned owned copy, and
  `fromPayload` reads a loaded one. `foundry:model_import`'s `collision true` derives it as
  `<model>.collision` (ADR-0057).
- **`physics3d`** (`engine/src/physics3d/`):
  - `World.addMesh` copies triangles into a median-split BVH, and bodies are static or
    kinematic, with rigid poses (`shape.Pose`: a position and a unit `Quat`, no scale).
  - The character controller (`character.zig`) is a capsule with `radius`, `height`,
    `max_slope` (radians), `step_height` and `snap_distance`. Navigation's agent uses the same
    four quantities, with the same meanings (§4).
  - `shape.positionValid` and `max_coordinate` are the numerical envelope.
- **Background work** (`engine/src/core/tasks.zig`): `core.Tasks` runs nodes on a second pool,
  with `Manual` for tests (`runNext`, `runAll`). M27–M31 put asset decodes, runtime geometry,
  and Vorbis on it.
- **Runtime meshes** (`engine/src/render3d/renderer.zig`, `uploads.zig`, and
  `engine/src/asset/mesh_builder.zig`): a sample builds an `asset.OwnedMesh` with the pure
  mesh builder and creates or updates a runtime mesh by handle (ADR-0063). The engine's
  shading models are `foundry:shading.lit`, `unlit` and `particle`; `particle` takes
  premultiplied vertex colour, so translucent and additive geometry share a pipeline
  (ADR-0064).
- **The samples:**
  - `samples/sandbox3d/content/sandbox3d.fdt`: the room and the course both have
    `collision true`. `sandbox3d:walk.main` lists both collision meshes and the walker's
    capsule (radius 0.3, height 1.8, `max_slope` 0.785398, `step_height` 0.35). The course
    (`collision3d.md` §10.2) is four 0.15 m steps to a platform 0.6 m up, a 25° ramp down from
    it, and a 55° ramp against the west wall. `plinth` adds a `sandbox3d:prop` with its own
    collision at (−2.2, 0, 1.6). `walker.zig`'s walker follows four fixed waypoints.
  - `samples/court/content/court.fdt`: one level collision mesh,
    `court:models.court.collision`. The gate is a kinematic box and the beacons are boxes on
    their own layer, all added by `game.zig`. `court:warden.main` has radius 0.22 and height
    1.7 and patrols two fixed waypoints. `walk.zig` loads collision by content ID and checks
    its schema.
- **Nothing for navigation exists.** No module, record, test or sample code.

## 3. The `nav` module (L1, `core` alone)

`nav` sits beside `physics3d`, `anim` and `particles`, and for their reasons:
- **No `asset`.** Geometry arrives as values the build copies (ADR-0057's rule for
  `physics3d`). A test, a tool or a game that generates its level can build a mesh with no
  package at all.
- **No `physics3d`.** Collision and navigation change for different reasons and are consumed
  by different code. The controller asks "where does this capsule stop?"; navigation asks
  "where could it stand, and what joins to what?". Sharing the triangles, not the module, keeps
  each small. A sideways dependency at L1 would also break §4.3's rule.
- **No entities, no content, no I/O, no clock.** A build is a function of its inputs.
- **No renderer.** The debug view (§8) is plain positions and colours, and the sample turns
  them into a runtime mesh.

The build graph gains `.{ .name = "nav", .deps = &.{"core"} }`. `sandbox3d` and `court` are
granted it. Nothing in the engine imports it in M32. M33's agents may join a higher module to
it, and M48 grants it to `abi`.

**Now:** the module, its build and its mesh. **Designed for:** M33's search needs a polygon
graph with stable indices, neighbour links, and a way to find the polygon under a point; §6
gives all three. **Postponed:** tiles (M60), which would change a polygon's identity from an
index to a tile and an index. M32's single-tile mesh is what a tiled mesh with one tile
would be, so M60 widens identity rather than replacing it.

## 4. The record: `foundry:nav_mesh` (`asset`)

A `foundry:nav_mesh` record is the **recipe** for one navigation mesh: what it is built from,
for which agent, and at what resolution. It is content: it has an ID, a mod can override it,
and `fpack` validates it. The mesh it describes is not (§7).

```
foundry:nav_mesh sandbox3d:nav.walker {
    sources [ sandbox3d:models.room.collision sandbox3d:models.course.collision ]
    agent_radius 0.3  agent_height 1.8  agent_climb 0.35  agent_slope 0.785398
}
```

| Field | Type, default | Bounds | Meaning |
| --- | --- | --- | --- |
| `sources` | `[id]` | 1 to 16 IDs, distinct, none `none` | `foundry:collision_mesh` records, at the identity pose |
| `agent_radius` | `f32` | 0 to 5 m | How far a wall must be from the agent's centre |
| `agent_height` | `f32` | 0.1 to 10 m, at least 2 × `agent_radius` | The clearance it needs above the floor |
| `agent_climb` | `f32` | 0 to `agent_height` | The tallest step it walks up or down |
| `agent_slope` | `f32` | (0, π/2) radians | The steepest walkable floor |
| `cell_size` | `f32`, 0.1 | 0.01 to 1 m | The horizontal voxel |
| `cell_height` | `f32`, 0.05 | 0.01 to 1 m | The vertical voxel |
| `region_min_area` | `f32`, 0.5 | 0 to 10,000 m² | A region smaller than this, with no neighbour, is dropped |
| `region_merge_area` | `f32`, 4 | 0 to 10,000 m² | A region smaller than this merges into a neighbour |
| `edge_max_length` | `f32`, 6 | 0 (no limit) to 100 m | Longer boundary edges are split |
| `edge_max_error` | `f32`, 0.13 | 0.01 to 3 m | How far a simplified boundary may stray from the voxels' |
| `polygon_max_vertices` | `u32`, 6 | 3 to 6 | The most vertices a polygon has |
| `detail_sample_distance` | `f32`, 0.6 | 0 (no samples) or 0.1 to 10 m | Spacing of height samples for the detail mesh |
| `detail_max_error` | `f32`, 0.05 | 0 to 1 m | How far the detail surface may stray from the voxels' |

The four agent fields mean exactly what the controller's do: `agent_climb` is
`step_height`, `agent_slope` is `max_slope`, in radians, as the samples' walk records already
write it. A game that keeps them in step keeps its agents on surfaces its controller can
walk. M32 does not join the two records: the warden's controller and its navigation are
different records in the court for good reason (the player jumps; the warden does not).

**Why these bounds.** The voxel grid is at most 2,048 × 2,048 columns (§5.1), so a 0.01 m
cell covers at most a 20 m level and a 1 m cell 2 km. Below 0.01 m the cell is smaller than
the 5 mm collision skin's resolution matters; above 1 m a doorway disappears. The agent's
bounds are those of anything the controller accepts, with room above.

**Validation in `asset`.** `asset.nav_mesh.Settings.read(fields)` decodes and refuses each out
of range field by name (`InvalidNavMesh` with the field), as M29–M31's records do, so
`fpack` and `fdt-check` refuse a bad record before it ships. That a source names a
`foundry:collision_mesh` is checked by the game at load, against the merged store (§7), as
`walk.zig` already checks its collision list: a mod may supply the mesh a source names.

**Versioning (I8).** The schema is version 1. M33's area types and off-mesh links are
version 2, and a version 1 record loads unchanged under it.

## 5. The build (`nav`)

The method is the one Mikko Mononen published with Recast: voxelise the level, decide which
voxels an agent can stand on, cut that surface into simple regions, trace their outlines, and
turn the outlines into convex polygons. Foundry reimplements it in Zig from the method, not
from Recast's code (ADR-0069 says why). Each stage is its own function over the previous
stage's value, so each is tested on its own, and the stages run in this order every time.

**Inputs.**

```zig
pub const Source = struct {
    positions: []const Vec3,
    indices: []const u32,
    /// Rigid: a position and a unit rotation, as `physics3d.Pose` is. No scale (ADR-0057).
    pose: Pose = .identity,
};
pub fn build(gpa: Allocator, config: Config, sources: []const Source) BuildError!Mesh
```

`Config` is the record's fields as values. `build` validates all of it before it allocates:
- every triangle's positions finite and within ±8,192 m after its pose, as `physics3d`'s
  envelope requires;
- at most 1,048,576 triangles and 3,145,728 positions in all, the `.fcol` limits;
- the bounds of all sources, grown by the radius, fitting 2,048 columns on X and on Z and
  65,535 cells on Y.

It refuses with `InvalidConfig`, `InvalidGeometry`, `TooLarge` or `OutOfMemory`. Degenerate
triangles (below `physics3d`'s 1e-12 m² area) are skipped, not refused, since a real model
has them.

### 5.1 Rasterisation and the solid heightfield

The grid's origin is the sources' minimum, lowered by one cell. Each triangle, in source
order and then index order, is clipped against each column it covers on X and Z, and the
clipped polygon's lowest and highest Y become a **span**, rounded outward to whole cells. A
column keeps its spans sorted bottom to top and merges spans that touch.

A span is **walkable** if its triangle's normal is within `agent_slope` of +Y. Where spans
merge, the walkable flag of whichever top is higher survives, and if the tops are within
`agent_climb` of each other the walkable one wins, so a walkable floor meeting a wall's
bottom edge stays walkable. Triangles are **two-sided** for this, as for collision: an
upward-facing triangle is walkable however it is wound.

### 5.2 The filters

Three passes, in this order, over every column:
1. **Low obstacles.** A non-walkable span whose top is within `agent_climb` of a walkable
   span directly below it becomes walkable. A kerb or a step's riser is climbable.
2. **Ledges.** A walkable span with a neighbour whose floor drops more than `agent_climb`,
   or that has no floor, is unwalkable. Standing with half the agent over a drop is not
   standing.
3. **Low ceilings.** A walkable span with less than `agent_height` of open space above it,
   to the next span's bottom, is unwalkable.

### 5.3 The open heightfield, and erosion

The walkable spans' tops become **open spans**: a floor and the clearance above it. Each open
span links to at most one open span in each of the four neighbouring columns: the one whose
floor is within `agent_climb` and whose clearance overlaps the agent's height. These links
are the walkable surface's connectivity, and every later stage walks them.

**Erosion.** A two-pass chamfer distance from the surface's boundary (an open span with fewer
than four links) is computed in cells. Every span nearer than `agent_radius` to the boundary
is removed. This is what keeps the agent's centre a radius from every wall, and why polygon
vertices never need offsetting afterwards.

### 5.4 Regions

The surface is partitioned into **regions**, each a connected set of spans with no holes,
by a **watershed** over the distance field: the spans farthest from any boundary seed
regions, and regions grow outward one distance level at a time, a span joining the region of
its neighbour that reached it first. Ties go to the lower region number, and regions are
numbered in the order their seeds are found, scanning columns by Z, then X, then bottom to top.

Then regions smaller than `region_min_area` with no neighbour are dropped, and regions smaller
than `region_merge_area` merge into the neighbour with which they share the longest border.

Watershed is chosen over the simpler monotone partition because its regions are compact, and
compact regions give polygons M33's search measures well. It costs one distance field, which
erosion has already computed.

### 5.5 Contours

Each region's outline is traced along the edges between its spans and anything else,
counter-clockwise seen from +Y, recording at each vertex the region across the edge. Then it
is simplified:
- every vertex where the neighbouring region changes is kept, so two regions' shared border
  has the same vertices on both sides;
- along the rest, vertices are added back Douglas–Peucker style wherever the outline strays
  more than `edge_max_error` from the simplified line;
- an edge on the mesh's outer boundary longer than `edge_max_length` is split at its middle
  until none is.

A region whose outline crosses itself after simplification is a build error to fix, not a
refusal: it fails the test suite and the step that wrote it.

### 5.6 Polygons

Each contour is triangulated by ear clipping, choosing at each step the ear with the
shortest new diagonal and, among equals, the lowest vertex index. Triangles in a region are
then merged pairwise into convex polygons of at most `polygon_max_vertices`, always merging
the pair whose shared edge is longest. Vertices are welded across regions on their cell
coordinates, so neighbouring regions share vertices exactly. Each polygon edge records the
polygon across it, or `none` on the boundary.

### 5.7 Detail

The polygon mesh's heights are the voxels' tops: right on average, but a polygon that spans
a ramp's top edge or four steps is a single plane through them. The **detail mesh** gives each
polygon a triangulated surface that follows the floor:
- each polygon edge is sampled every `detail_sample_distance` and the samples where the
  floor's height strays more than `detail_max_error` from the edge are added;
- the interior is sampled on the same spacing, and the sample farthest from the current
  surface is added while it strays more than `detail_max_error`;
- the points are triangulated by an incremental Delaunay triangulation constrained to the
  polygon's edges.

Heights come from the open heightfield, which is within one cell height of the triangles. The
detail mesh is what `locate` (§6) reads a height from, and what the debug view draws.

### 5.8 Determinism

The stages use `f32` arithmetic only in rasterisation and in the detail mesh, without
fast-math, in a fixed order. Everything between them is integer arithmetic over cells.
Iteration order is fixed at every stage, ties are broken by index, and no address, clock or
hash of a pointer is read. The same inputs give the same bytes on the same machine (I9); the
course's mesh is pinned (§11).

## 6. The built mesh (`nav`)

```zig
pub const Mesh = struct {
    origin: Vec3,
    cell_size: f32,
    cell_height: f32,
    /// Cell coordinates: x and z in columns, y in cell heights above `origin`.
    vertices: []const [3]u16,
    polygons: []const Polygon,
    detail: Detail,
    pub fn deinit(self: *Mesh, gpa: Allocator) void
    pub fn locate(self: *const Mesh, point: Vec3, extent: Vec3) ?Located
};
pub const Polygon = struct {
    vertices: [max_polygon_vertices]u32,
    neighbours: [max_polygon_vertices]u32, // `none_polygon` on the boundary
    count: u8,
    region: u16,
};
pub const Located = struct { polygon: u32, point: Vec3 };
```

- **Identity.** A polygon is its index in `polygons`, stable for the life of the mesh. It is
  never stored outside the mesh's owner or saved, because a rebuild renumbers it (I1's
  reason). M33's search returns paths as polygon indices into one mesh.
- **`locate`** finds the polygon under `point` within `extent` (a half-size box), and the
  nearest point on that polygon's detail surface. A point over two floors locates the one
  nearest in height within the box. A point over no polygon returns the nearest polygon
  within the box, or `null`. It allocates nothing, and it refuses a non-finite point or extent
  by returning `null`.
- **Bounds** and the polygon count are on the mesh, for the samples' logs and M33's overlay
  panel.
- **Ownership.** A `Mesh` is a value its creator owns and frees. M33 decides whether agents
  need a handle-addressed store of meshes; M32 gives none, because nothing yet holds a mesh
  across a subsystem boundary.

## 7. Building at load (`nav` and the samples)

**Why at load.** A navigation mesh depends on collision geometry that another package may
override: a mod replacing a level's collision mesh, adding a prop, or widening the agent.
Baked into the base package, the mesh would be right for the base game and wrong for every
mod that touched what it was built from, silently. Built from the merged store at load, it
is always the mesh of the content actually running (I3: package zero gets no shortcut a mod
does not). At the samples' sizes a build costs milliseconds (§1, criterion 5), off the main
thread. Where that stops being true, tiles and a cache keyed by the inputs' content are M60's
answer (§13).

**The task.** `nav.Build` puts one build on `core.Tasks`:
- `Build.start(tasks, gpa, config, sources)` copies the sources' triangles, posed, into one
  owned buffer on the calling thread, so nothing the caller frees afterwards is read;
- the build node runs `build` on the background pool;
- `Build.take()` on the main thread returns the mesh, an error, or "not yet". It never blocks.

A reload while a build runs starts another and discards the first's result when it arrives,
by a generation the samples keep. Until a new mesh arrives the old one stays drawn and in
use, as M27's assets do (ADR-0061: arrival is presentation, never simulation).

**The glue,** in each sample, about fifty lines: read the `foundry:nav_mesh` record with
`asset.nav_mesh.Settings.read`, check each source is a `foundry:collision_mesh` and is
loaded, collect their views as `nav.Source`s, and start the build. `sandbox3d` also adds each
`sandbox3d:prop`'s collision at its prop's position and yaw, which is how `plinth` reaches
navigation. A missing or wrong source is logged and left out, as `walk.zig` does with
collision.

This glue is in the samples, not the engine, in M32. It is small, it differs per game (which
props, which records), and M33 is where a game first needs navigation as an engine-owned
service (agents moved each tick). M33's design decides whether that service carries the glue.

## 8. The debug view (`nav`)

`nav.debugView(mesh, out)` writes the detail triangles as positions and premultiplied
colours, lifted 2 cm above the surface so they do not fight the floor's depth:
- each region in its own colour, from a fixed 12-colour palette indexed by region number, at
  45% alpha;
- each boundary edge as a 3 cm strip in the region's colour darkened, at 90%;
- each edge between neighbours as a 1 cm strip at 30%.

It allocates nothing; `debugViewCount(mesh)` sizes `out`. The sample builds an
`asset.OwnedMesh` from it with `asset.mesh_builder` and draws it as a runtime mesh with a
`foundry:shading.particle` material, the engine's translucent vertex-colour model. No
renderer change is needed, and the view is the only thing in M32 that touches a frame.

## 9. The samples

### 9.1 `sandbox3d`

- **Content:** `sandbox3d:nav.walker`, a `foundry:nav_mesh` over the room and the course
  with the walk record's capsule: radius 0.3, height 1.8, climb 0.35, slope 0.785398.
- **Code:** a `nav.zig` beside `walk.zig`: the glue of §7, the view's runtime mesh, the `N`
  toggle, and the log line (polygon count, regions, build time).
- **What it shows:** §1's list. The platform and the floor are one island through the steps
  and the 25° ramp. The table top is its own island, since nothing walkable reaches it.
- **Testdata:** `plinth` cuts the mesh. A new test mod, `stout`, overrides
  `sandbox3d:nav.walker` with `agent_radius 0.6`. That closes at least one passage the
  0.3 m walker fits through; Step 6 names it from the room's coordinates, and the test checks
  that it closes, that the floor's area shrinks by the wider border, and that nothing else
  differs.

### 9.2 The court

- **Content:** `court:nav.warden` over `court:models.court.collision`, with the warden's
  radius 0.22 and height 1.7, a climb of 0.25 (the player's step) and a slope of 0.785398.
- **Code:** a `nav.zig` with the same glue, built when the level loads and again on reload,
  drawn when `FOUNDRY_COURT_NAV=show`.
- **Tests,** in `court-test` against the real content: §1's island, gap, pit and low-wall
  checks, by `locate` and a flood over neighbour links.
- **The game does not use the mesh yet.** The warden patrols as before, and every scripted
  ending is unchanged. M33's warden walks on this mesh.

## 10. The public ABI: nothing in M32

The call count stays 264. A content mod reaches all of M32 today: `foundry:nav_mesh` is a
record, its sources are collision content, and `plinth` and `stout` show both. The table's
navigation calls (building, locating, the view and M33's search) reach it in M48's
`FoundryApi_v8`, and Lua in M49; the close adds them to M48's "also" clause.

## 11. Verification, pins and budgets

- **Records:** defaults; every refusal through `fpack`'s path and on hand-made records; an
  override replacing a recipe.
- **Hand-made scenes,** built in tests from boxes and ramps, each checked against its exact
  answer within one cell:
  - a 10 m floor: one region, the area of the floor less the radius border;
  - a box on it: a hole of the box's footprint grown by the radius;
  - steps of 0.15 m against a climb of 0.2 connect, of 0.35 m do not;
  - ramps of 25° and 55° against a 45° limit;
  - two floors 2.0 m apart, and 1.5 m apart, for a 1.8 m agent;
  - corridors of 2r − 2 cells and 2r + 2 cells;
  - a ledge over a drop, and a kerb within the climb;
  - a triangle wound either way.
- **Every stage on its own:** span merging and flags; each filter; link symmetry; the
  distance field against a brute-force one; region count and coverage; contour closure and
  shared borders; ear clipping on concave outlines with holes bridged.
- **Well-formed meshes:** criterion 2's checks, run on every mesh any test builds.
- **Detail:** heights at a grid of points over the course within the bound, against a
  downward ray into the source triangles.
- **`locate`:** points over the floor, over two floors, over holes, at and beyond the extent,
  and non-finite ones.
- **Refusals:** every config bound; non-finite and out-of-envelope positions; out-of-range
  indices; too many triangles; a grid past 2,048 columns. A seeded sweep of 1,000 mutated
  inputs neither panics nor hangs. `std.testing.checkAllAllocationFailures` over a small
  build.
- **The task:** with `core.Tasks.Manual`, a build that has not run is "not yet", a reload
  discards the stale result, and freeing the sources after `start` is safe.
- **The pin:** the course scene's mesh (vertices, polygons, links, detail) is hashed. The
  hash is equal in Debug, ReleaseSafe and x86_64 under Rosetta, and compared on Windows.
- **Cost:** a timing test builds the court's and `sandbox3d`'s meshes in ReleaseSafe on one
  thread and prints milliseconds, against criterion 5.
- **The samples:** criterion 6 and 7 from relocated ReleaseSafe installs, with `dist` staging,
  since both samples' content changes.
- **The bar** (`AGENTS.md` §3) at every step. `fdt-check` covers the new record.

## 12. Platform assessment

- **macOS (Metal):** everything new is pure Zig and runs here. The view is an existing
  runtime mesh through an existing shading model. Steps 1–7 run here.
- **Windows (Vulkan):** criterion 5's budget is decided on the slower i3, and the view must
  be validation-clean on Vulkan, so Step 8 runs on the Arc PC. It has no Foundry clone since
  M31's close, so the step clones again. The usual rules apply: check it is idle, `-j2`,
  below-normal priority, a scheduled task for windowed runs, and removal of exact Foundry
  paths only.
- **Linux:** nothing in M32 is Linux-specific, so 3d.md §10.2 calls for no Linux run. The
  Linux null cross-check in the bar builds `nav` too.

## 13. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| Path search over polygons and string pulling | M33 | Its line already names it |
| Agents moved along paths, and avoidance between them | M33 | Its line already names it; whether agents need a handle-addressed store of meshes is its decision (§6) |
| Off-mesh links: jumps, drops, ladders | M33 | `foundry:nav_mesh` version 2. Added to its intent at the close |
| Area types and their costs, marked by volumes | M33 | Version 2, with the links. Added to its intent at the close |
| Obstacles that cut a running mesh (the court's gate, a moved crate) | M33 | Avoidance's other half. Added to its intent at the close |
| A navigation panel in the overlay | M33 | Polygon counts, build times and the islands. Added to its intent at the close |
| Tiled meshes, a baked mesh asset, rebuilding tiles around a point | M60 | A world large enough to stream is the first whose build outgrows a load (§7). Added to its intent at the close |
| Navigation over terrain heightfields | M63 | Terrain's collision is a heightfield, not triangles. Added to its intent at the close |
| Navigation over voxel chunks | M66 | Chunk collision is a grid. Added to its intent at the close |
| Navigation in the public table, and in Lua | M48, M49 | §10. M48's line gains an "also" clause at the close, and M49's binding covers what M48 publishes |
| Grid pathfinding on 2D tile maps | Not planned for the engine | `tilemaps-and-collision.md` keeps it game logic; a tile map's grid is already its graph |

## 14. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | A new L1 module `nav` on `core` alone; geometry arrives as copied triangles with rigid poses; no asset, physics, entities, renderer or clock | §3, ADR-0069 |
| 2 | Foundry's own build, by the published voxel method, reimplemented in Zig; no Recast code or library | §5, ADR-0069 |
| 3 | `foundry:nav_mesh` version 1 is a recipe: up to 16 collision sources, the controller's four agent quantities with the same meanings, and the build's resolution and simplification, with the defaults and bounds of §4 | §4 |
| 4 | A mesh is built at load from the merged store, on the background pool, owned by its creator, with no content ID and never saved; a reload rebuilds it and the old one stays until the new arrives | §7, ADR-0069 |
| 5 | Watershed regions over the erosion's distance field; ear clipping and longest-edge merging into convex polygons of at most six vertices; a constrained Delaunay detail mesh | §5.4–§5.7 |
| 6 | A polygon is its index in one mesh; `locate` finds the polygon and detail point under a point within a box | §6 |
| 7 | The glue that reads the record and starts the build is the samples' in M32; M33 decides whether an engine service carries it | §7 |
| 8 | The debug view is coloured, lifted triangles drawn as a runtime mesh through `foundry:shading.particle`; no renderer change | §8 |
| 9 | The runnable result: `sandbox3d` draws its mesh (`N`), `plinth` cuts it and the new `stout` mod widens the agent; the court builds the warden's mesh and tests its island, with the game unchanged | §1, §9 |
| 10 | No ABI change; 264 calls; M48 publishes navigation and M49 binds it | §10 |
| 11 | The budgets: the court's mesh in at most 50 ms on the M5 and 150 ms on the i3, in ReleaseSafe on one thread; no frame over 16.67 ms while building | §1, §11 |
| 12 | Path search, agents, avoidance, off-mesh links, areas, running obstacles and an overlay panel to M33; tiles and baking to M60; heightfields to M63; voxels to M66; the table to M48/M49; the roadmap's intent lines gain these at the close | §13 |
| 13 | Nine steps, in §15's order | §15 |

Once these are accepted, nothing blocks Step 1.

## 15. Implementation order — nine bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `nav` and `asset`: the module, the inputs and the record

- Add `nav` to the build graph on `core` alone, with `Config`, `Source`, validation of both,
  and the limits (§3, §5's inputs).
- Add `foundry:nav_mesh` version 1, decoded and validated in `asset` (§4).
- Tests: §11's record items and the input refusals.

**Exit:** every record field decodes with its default and refuses its out-of-range values by
name through `fpack`'s path, and `nav` refuses every invalid input before allocating.

### Step 2 — `nav`: rasterisation and the filters

The solid heightfield, span merging and the walkable flag, and the three filters (§5.1,
§5.2). Tests: the span and filter items, and the slope, step, ceiling and ledge scenes at the
span level.

**Exit:** each hand-made scene's spans and walkable flags are the ones its geometry implies,
within one cell.

### Step 3 — `nav`: the open heightfield, erosion and regions

Open spans and their links, the distance field, erosion, the watershed, and dropping and
merging small regions (§5.3, §5.4). Tests: link symmetry, the distance field against brute
force, the corridor and obstacle scenes at the span level, region counts and coverage.

**Exit:** the corridor, obstacle and floor scenes erode to their exact widths within one
cell, and every span belongs to exactly one region.

### Step 4 — `nav`: contours and polygons

Tracing, simplification, the boundary split, ear clipping, merging, welding and neighbour
links (§5.5, §5.6); the mesh without detail (§6). Tests: contour items, criterion 2's polygon
checks on every scene.

**Exit:** every scene's mesh is well-formed by criterion 2, and its area and island count
match its exact answer within one cell.

### Step 5 — `nav`: detail, `locate`, the task, the view and the pin

The detail mesh (§5.7), `locate` (§6), `nav.Build` on `core.Tasks` (§7), `debugView` (§8),
the mutation and allocation-failure sweeps, the course scene's pin and the timing test.

**Exit:** criteria 1 to 4 hold, the pin is equal in Debug, ReleaseSafe and x86_64, and the
Mac's build times are recorded against criterion 5.

### Step 6 — `sandbox3d`: the walker's mesh, proved on the Mac

`sandbox3d:nav.walker`, the sample's `nav.zig`, the view and `N`, props as posed sources,
reload, the `stout` test mod, and the evidence from a relocated ReleaseSafe install (§9.1).

**Exit:** §1's `sandbox3d` result is visible and tested, `plinth` and `stout` change it with
no code, and no frame exceeds 16.67 ms while it builds, on the M5 with Metal.

### Step 7 — `court`: the warden's mesh, proved on the Mac

`court:nav.warden`, the court's `nav.zig`, `FOUNDRY_COURT_NAV`, and the island, gap, pit and
low-wall tests (§9.2); the court's build time; the scripted endings unchanged.

**Exit:** the court's tests hold against its real content, its build meets criterion 5 on
the M5, and every scripted ending and pin is unchanged.

### Step 8 — Windows/Vulkan

Clone on the PC. Run the null and Vulkan suites, the timing test and the pin. Run both
samples from a relocated, read-only ReleaseSafe install, with and without validation, with the
view shown.

**Exit:** criteria 4 to 6 hold on the Arc A750, with the pin checked against the Mac's and any
difference recorded.

### Step 9 — Close M32

Resolve the contract discrepancies where they were written:
- `playable3d.md` §1, §5 and §13's warden row, which give navigation to "M32–M33": M32's half
  is done;
- the intent lines of M33, M48, M60, M63 and M66 in `docs/ROADMAP.md` (§13).

Then:
- move ADR-0069 to Accepted and into `CLAUDE.md` §4.1;
- add `nav` to §4.3's layer graph and to the samples' grants, and update §9's deferred row;
- update `AGENTS.md`'s bar if a step changed it, and add the build-time measurement beside the
  optimized-only ones;
- update the ROADMAP's M32 row, the design index, the README and `PROJECT_STATE.md`;
- pack up the PC by exact path.

Tag `m32`, push when asked, and stop before M33's design.

## Resolution — Step 1: the module, the inputs and the record (2026-10-28)

**Accepted.** The owner asked for Step 1 with §14 as written. ADR-0069 is Accepted and in
`CLAUDE.md` §4.1. §4.3's layer graph gains `nav` at the close (Step 9), as §15 says.

**What exists now:**
- **`nav`** (`engine/src/nav/`), on `core` alone in `build.zig`, with its own `zig build
  nav-test` and a place in the integration suite's imports. No sample is granted it yet.
  - `config.zig`: `Config`, the record's fields one for one with §4's defaults, and
    `invalidField()`, which names the first field out of bounds in declaration order. A bound
    that depends on another field (height on radius, climb on height) is reported as the
    dependent one.
  - `input.zig`: `Pose` (rigid, as `physics3d`'s), `Source`, and `measure(config, sources)`,
    which validates everything and answers the `Grid` a build will use, or `InvalidConfig`,
    `InvalidGeometry` or `TooLarge`. It allocates nothing. Every later `build` calls it first.
- **`foundry:nav_mesh` version 1** (`engine/src/asset/nav_mesh.zig`): the schema, `Settings`,
  `decode`, `describe` and `checkSources`. Registered by the engine (`app/engine.zig`) and by
  the compiler (`registerAvailableSchemas`), checked in `checkMeanings` as "navigation mesh
  '<id>' <reason>", and listed in `engine_schema_names` so the editor's New Record form
  offers it.
- **`engine/tests/nav_mesh.zig`** holds the two modules' rules together: the record's defaults
  are the builder's, and over 31 float values per field (bounds, either side of them, NaN and
  infinity) and seven vertex counts, the record refuses exactly the field the builder
  refuses.

**Where the step sharpened the design:**
- **The grid.** §5's inputs said the bounds are "grown by the radius". They are not, because
  erosion only removes spans and nothing is ever placed outside the sources. Instead the grid
  has one cell of margin on every side: the origin is the minimum lowered by a cell, and each
  extent is the cell holding the maximum plus that cell plus one. Measured in `f64`, so a
  16 km extent at 1 cm cannot overflow before it is compared. A 10 m floor at 0.1 m is
  103 × 103 columns and 3 cells high.
- **Sources.** The record allows 16. `nav` allows 4,096, because a game adds its props to its
  level's sources (§7).
- **Every position is checked, referenced or not,** before and after its pose, as
  `physics3d.mesh.validate` does. A position that is not a coordinate means a damaged source,
  whichever triangle it would have joined.
- **The record's own refusals,** besides one per field: `NoSources`, `TooManySources`,
  `InvalidSource` (a `none`), `DuplicateSource`, and, at load, `NotACollisionMesh`. That one
  covers a source that is missing as well as one of the wrong schema, since both leave the
  mesh without geometry it was promised.
- **Degenerate triangles** are not looked at by `measure`. §5 skips them at rasterisation
  (Step 2), where the area is computed anyway.

**Guards verified by breaking them:**
- Removing `measure`'s index check fails the invalid-input test.
- Dropping the record's `agent_height ≥ 2 × agent_radius` rule fails "every refusal is named".
- Dropping the builder's copy of the same rule fails the agreement test.
- Skipping the compiler's `foundry:nav_mesh` branch fails its refused-at-its-line test.
- The engine-schema spelling test failed on its own, before the name was added: the guard
  that exists for this.

**Not yet:** rasterisation and everything after it (Steps 2–5). No sample content changes, so
no `dist` staging is needed.

Bar **2,452/2,456** (four skips), 126/126 steps, up 15 tests from M31's 2,437. The full bar,
all exit 0.
