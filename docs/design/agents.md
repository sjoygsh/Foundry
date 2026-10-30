# Design: M33 — Navigation II: paths, agents and avoidance

**Status:** Accepted 2026-10-30, when the owner asked for Step 1, with §16 as written. Each
step's Resolution follows §16.
**Date:** 2026-10-30
**Baseline:** `d59f5e5`, tag `m32`. M0–M32 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0069: `nav` is L1 on `core` alone, a mesh is built at load from the merged store, and
    its creator owns it. A polygon is an index, valid until a rebuild. It named version 2 of
    `foundry:nav_mesh` for areas and links.
  - ADR-0061: background work is `core.Tasks`, and arrival is presentation. Its decision 4 says
    a game that gates play on loading "does so through an input event delivered at a frame
    boundary and recorded like any other input". M33 is the first consumer of that sentence
    (§9).
  - ADR-0051: `physics3d` is collision without dynamics, and a caller owns a character's
    velocity, gravity and time. An agent asks the controller to move, like any other caller.
  - ADR-0063: what is built at run time is owned by its creator, never content.
  - ADR-0013 and ADR-0064: deterministic-friendly, not bit-exact, and a pin must not depend on
    which trig a binary linked.
  - ADR-0041: engine record types live in `asset`, so `fpack` checks them without linking
    their consumer.
  - ADR-0025: the overlay reads the subsystem's own answers and has no private path.
- It proposes one ADR:
  - [ADR-0070](../adr/0070-agents-are-values-a-game-ticks.md): paths, agents and avoidance live
    in `nav`, as values a game owns and ticks. `nav.Crowd` says where each agent wants to go;
    the game moves it, by a character controller or directly, and tells the crowd where it
    ended up. Avoidance is ORCA in a fixed order, with no random perturbation. A running
    obstacle cuts the mesh by an ordinary rebuild on the background pool, and a rebuilt mesh
    reaches simulation only as a recorded input, so a replay agrees with the run however late
    the build arrived.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M33 | Navigation II | Pathfinding, agents and avoidance; also off-mesh links (jumps, drops,
> ladders) and area types with their costs, as `foundry:nav_mesh` version 2, obstacles that
> cut a running mesh (the court's gate), and a navigation panel in the overlay

Other documents point here by name:
- **`navigation.md` §13:** paths, string pulling, agents, avoidance, links, areas, running
  obstacles ("the court's gate, a moved crate") and the panel, each owned by M33.
- **`navigation.md` §6 and §7:** M33 decides whether agents need a handle-addressed store of
  meshes, and whether an engine service carries the samples' glue. §4 and §6 here answer.
- **`engine/src/nav/locate.zig`:** "M33 decides whether its agents need something faster than a
  scan." §7 answers.
- **`playable3d.md` §13:** "A warden that sees and chases: M33 … gives it paths, an agent and
  the chase."

**The runnable result** is a warden that hunts you, and a crowd that gets out of each other's
way:
- **`samples/court`:** the warden walks its patrol on the mesh. If it sees the player, it
  chases: around the low wall, across the gap by a jump link, and through the gate once the
  gate is open. If it loses the player, it goes to where it last saw them and then back to its
  patrol. Every scripted ending replays to the tick.
- **`sandbox3d`:** a crowd of sixteen pawns crosses the room between four corners and keeps
  apart.
  - They prefer the floor to a costly area, and cross it only when it is much shorter.
  - They go up a ladder link to the table and down a drop link from the platform.
  - A crate moved with a key cuts the mesh, and they re-route around it.
  - `N` draws the mesh, the links and each agent's path.
  - The new content mod `marsh` changes where they walk, with no code.
- **The overlay** gains a navigation panel in both samples.

**Exit criteria** (§13 gives each one's measure):
1. **Paths.** On every hand-made scene, a path exists exactly when the mesh's islands and links
   say it should. No straightened path leaves the mesh or crosses a boundary edge. Its length
   is within 1.25 times a reference found by Dijkstra over the voxels. Raising an area's cost
   moves the path off that area, and only when the detour is cheaper.
2. **Agents.** An agent reaches its target within `arrival_radius`, up steps and ramps and
   through links of all three kinds, and stays on the mesh. A body the controller stopped
   short is re-seated without leaving its corridor. An agent whose mesh was rebuilt finds a
   new path, within its tick budget.
3. **Avoidance.** In the crossing, swap, ring and passage scenes, no two agents' centres come
   closer than the sum of their radii less 5 cm. Every agent arrives. Passages wide enough for
   two are passed in both directions.
4. **Running obstacles.** A box added, moved or removed changes the mesh to the one a static
   box in the same place gives, byte for byte. The court's gate closes and opens the way to
   the exit.
5. **Determinism.** Two runs with the same inputs give the same crowd bytes, under `immediate`,
   under `Manual` in forward and reverse order, and on the real pool. The crowd's pin is equal
   in Debug, ReleaseSafe and x86_64 and compared on Windows. The court's replay matches every
   tick however late a mesh arrived.
6. **Untrusted input.** Every out-of-range field of the v2 record and of `foundry:nav_area` is
   refused by name. Non-finite targets, positions and agent parameters are refused. A link
   that lands on no polygon is reported, not fatal. A seeded mutation sweep and an
   allocation-failure sweep neither panic nor leak.
7. **Cost**, in ReleaseSafe on one thread:
   - a path over the court's mesh, p95 at most 50 µs on the M5 and 150 µs on the i3;
   - a crowd step of 32 agents, at most 1 ms on the M5 and 3 ms on the i3, with no allocation;
   - the court's warden adds at most 0.1 ms to a tick on the M5 and 0.3 ms on the i3;
   - rebuilds stay inside `navigation.md` criterion 5, and no frame goes over 16.67 ms because
     of one.
8. **A person plays it.** The owner plays the court's chase from a relocated ReleaseSafe build
   and says it is fair. The warden's numbers are content, tuned from that play.
9. **The samples.** Both, from a relocated ReleaseSafe install on the M5 with Metal and on the
   Arc PC with Vulkan, under validation: clean, the endings replay, and `marsh` changes the
   crowd's route.
10. **Nothing else changes.** A version 1 record loads and gives the same mesh, so M32's pin
    holds. No collision, rendering or audio pin moves. The court's tick assertions change only
    where a warden's behaviour did, and each change is listed in its Resolution.

**In M33:** the v2 record and `foundry:nav_area` (§3); areas and links in the build (§4);
search and string pulling (§5); `nav.Crowd`, its corridor and link traversal (§6); `locate`'s
answer (§7); ORCA (§8); running obstacles and adoption as input (§9); the view and the panel
(§10); the samples (§11).

**Not in M33,** each with its owner (§15 has them all):
- Tiled meshes and rebuilding only the tiles around a point: M60. M33 rebuilds a whole mesh.
- Navigation in the public table and in Lua: M48 and M49.
- Sight, hearing and game AI as an engine feature: not planned. The warden's senses are the
  court's own, in `samples/court`.
- An engine `foundry:nav_agent` component in a world: no milestone needs it, because a game
  already owns its crowd as it owns its collision world.

## 2. What exists

- **`nav`** (`engine/src/nav/`), from M32:
  - `poly.zig`: `Mesh`, `Polygon` (six vertices, six neighbours, `count`, `region`, stable
    index), `none_polygon`, `position`, `area`.
  - `locate.zig`: `locate`, a linear scan that allocates nothing, and `heightOn`.
  - `task.zig`: `Build.start` copies its sources and `take` answers once. A superseded build
    is freed untaken.
  - `open.zig` and `regions.zig`: every open span already has an `area: u8`. The watershed,
    the blur and the flood already stop at a change of area. Only `walkable` is ever
    written, so the machinery is built and has never run with a second area.
  - `view.zig`: `debugView` writes coloured triangles.
  - Polygons meet whole edge to whole edge, because contours share vertices and welding is
    exact (`navigation.md` Step 4). Every portal is one whole edge, and search needs no
    partial-edge case.
- **`foundry:nav_mesh` v1** (`engine/src/asset/nav_mesh.zig`). `data` has additive versions:
  a field has a `since`, and one added after version 1 must be optional or defaulted.
- **`physics3d`:** `moveCharacter` takes a displacement and answers a `CharacterMove`;
  `setCharacterFeet` teleports; `raycast` takes a mask. Nothing allocates in steady state.
- **`debug`:** a panel is a registration, and `Sources` carries what a game hands over. `debug`
  is not granted `nav`.
- **`samples/court`:**
  - `warden.zig`: `WardenSettings` and `Warden.step`, a straight line between two waypoints
    fed to the controller. `court:warden.main` walks at 1.0 m/s and pauses for 1 s.
  - `game.zig`: `Game.step(intent, dt)` is the one simulation, and `hashTick` includes the
    warden. `main.zig` steps a second `Game` with the same `Intent`s and compares hashes, so
    an intent is already the recorded input.
  - `gate.zig`: a kinematic box that sinks 2.65 m into the ground, and `level_layer` blocks
    the warden. At `closed` it fills the two-metre doorway at z −7.7. At `open` its top is
    at y −0.15, under the floor.
  - The level (`scripts/m26/make_court.py`): the court floor, a 1.2 m gap, the ledge, and
    the exit floor beyond the gate. The exit floor is its own island while the gate is shut,
    but M32's mesh does not know that, because the gate is a body and not a source.
  - `nav.zig`: `Navigation` builds once at load. "The game does not use it yet."
  - `testdata/play.zig`: the scripts. `route_ledge` is written around today's fixed patrol,
    and the `soundtrack` run stands on the ledge for a minute.
- **`samples/sandbox3d`:** `nav.zig` rebuilds at each content refresh. `walker.zig`'s M24 walker
  follows four waypoints under pins, and stays as it is.

## 3. The records (`asset`)

### 3.1 `foundry:nav_area`, version 1

An area type is a named cost. It is a record so that a mod can add one or change one, and so
that it has a stable ID (I2).

```
foundry:nav_area sandbox3d:nav.area.mud { cost 4 }
```

| Field | Type, default | Bounds | Meaning |
| --- | --- | --- | --- |
| `cost` | `f32`, 1 | 1 to 1,000 | Metres of path this area charges per metre walked |

The lower bound of 1 is what keeps search's distance heuristic admissible (§5). An unmarked
floor has cost 1 and no record. "Never walk here" is not a cost, because it depends on the
agent, so it is a query's filter (§5).

### 3.2 `foundry:nav_mesh`, version 2

Version 2 adds two lists, both `since` 2 and empty by default. A version 1 record loads under
it unchanged and builds the same bytes (criterion 10).

```
foundry:nav_mesh sandbox3d:nav.walker {
    sources [ sandbox3d:models.room.collision sandbox3d:models.course.collision ]
    agent_radius 0.3  agent_height 1.8  agent_climb 0.35  agent_slope 0.785398
    # The coordinates show the shape. Step 8 takes the real ones from the room.
    volumes [ { area sandbox3d:nav.area.mud  min { x -3 y -0.5 z 0 }  max { x -1 y 0.5 z 2 } } ]
    links [
        { kind "ladder"  from { x 1 y 0 z -2 }  to { x 1 y 0.8 z -2.6 }  two_way true }
        { kind "drop"    from { x 3 y 0.6 z 1 }  to { x 3.8 y 0 z 1 } }
    ]
}
```

| Field | Type, default | Bounds | Meaning |
| --- | --- | --- | --- |
| `volumes` | list, empty | at most 32 | Axis-aligned boxes, each marking the floors inside it |
| `volumes[].area` | `id` | a `foundry:nav_area`, checked at load | Its area type |
| `volumes[].min`, `max` | `{x y z}` | finite, `min` below `max` on every axis | The box, metres |
| `links` | list, empty | at most 64 | Off-mesh links |
| `links[].kind` | `string` | `jump`, `drop` or `ladder` | How it is crossed (§6.3) |
| `links[].from`, `to` | `{x y z}` | finite, at least `0.1` m apart | Its two ends |
| `links[].two_way` | `bool`, false | | Whether it can be crossed from `to` |
| `links[].cost` | `f32`, 0 | 0 to 1,000 | Extra metres charged for crossing it |
| `links[].snap` | `f32`, 0.5 | 0.05 to 5 | How far each end may be from a polygon |
| `links[].arc` | `f32`, 0.5 | 0 to 10 | A jump's height above the higher end |

**Why at most 8 area types per mesh.** A polygon holds one `u8`, and a query's filter is a
fixed array, so a filter costs no allocation. Eight named costs is far above what either sample
needs, and a recipe naming a ninth is refused by name.

**A link's kind is a string, not an ID,** because the three motions are engine code. A mod
places links and cannot add a kind (compare ADR-0067: mods configure effects and never supply
DSP). A new kind is an additive engine change.

Validation stays where M32 put it. `asset.nav_mesh` decodes and refuses each field by name for
`fpack` and the editor's form. That a volume's area is a `foundry:nav_area` is checked at load
against the merged store, as `checkSources` does for sources, because a mod may supply it.
`engine/tests/nav_mesh.zig` keeps the record's rules and `nav`'s in step.

## 4. Areas and links in the build (`nav`)

`nav.Config` stays as it is. The build gains one more input, so a call that has none is the
M32 call:

```zig
pub const Features = struct {
    /// Each area's cost, by index; index 0 is unmarked floor, cost 1.
    costs: []const f32 = &.{},
    volumes: []const Volume = &.{},
    links: []const LinkInput = &.{},
};
pub fn buildWith(gpa, config, sources, features) BuildError!Mesh
```

**Areas.** After erosion and before the distance field, every open span whose floor lies inside
a volume takes the volume's area. Volumes apply in list order, and a later one wins. The
existing watershed then keeps areas apart, and contours and polygons follow. `Polygon` gains
`area: u8`. Region merging must refuse a merge across areas, which M32 never had a reason to
test. Marking after erosion is deliberate: an area changes what a floor costs, never where an
agent fits.

**Links.** After detail, each end is located within `snap` of the link's end. A link with an
end on no polygon is left out and counted in `Mesh.links_unattached`, and the sample logs it.
This is not an error, because a mod may have cut the floor it stood on. `Mesh` gains:

```zig
pub const Link = struct {
    kind: LinkKind,
    two_way: bool,
    from_polygon: u32, to_polygon: u32,
    from: Vec3, to: Vec3,  // on each polygon's detail surface
    cost: f32, arc: f32,
};
links: []Link,
/// `link_first[p] .. link_first[p + 1]` indexes `link_index`: the links leaving polygon `p`,
/// in link order, a two-way link appearing at both ends.
link_first: []u32, link_index: []u32,
costs: []f32,
islands: u32,  // for the panel
```

**The pin.** `hashMesh` gains `area` and the links only for a mesh that has them, so M32's
course pin stays `14865720887737603270`. A new scene with areas and links gets its own pin.

## 5. Search and string pulling (`nav`)

**Search** (`search.zig`) is A* over polygons, with a link as one more edge:

```zig
pub const Filter = struct {
    /// Multiplies an area's cost; zero excludes it. Indexed by area.
    area_scale: [max_areas]f32 = @splat(1),
    /// Bit `k` set excludes `LinkKind` `k`.
    excluded_links: u8 = 0,
};
pub const Query = struct {
    pub fn init(gpa, max_nodes: u32) !Query
    pub fn find(self, mesh, filter, start: Located, goal: Located, out: []Step) Path
};
pub const Step = struct { polygon: u32, link: u32 = none_link };  // the link that reached it
pub const Path = struct { count: u32, complete: bool };
```

- **A `Query` allocates once,** at `init`: a node per polygon up to `max_nodes` (default 4,096)
  and a binary heap. `find` allocates nothing, as the controller doesn't in steady state.
- **The cost of a step** is the distance between successive edge midpoints, times the area's
  cost. A link adds its length and its `cost`. **The heuristic** is the straight distance to
  the goal, which is admissible because every cost is at least 1. A filter's scale must also
  be at least 1 or zero, and is refused otherwise.
- **A goal it cannot reach** answers the path to the polygon nearest the goal, with
  `complete = false`. So the warden comes to the edge of the gap with no link and stands
  there, rather than doing nothing.
- **Ties** go to the lower polygon index (I9). The heap orders by `(f, polygon)`.
- **Measuring by midpoints is an approximation:** a polygon graph has no exact shortest path.
  Criterion 1 fixes the bound at 1.25 times a reference over voxels. If a scene breaks it,
  Step 3 records that, and a line-of-sight shortcut along the corridor is the first remedy.

**String pulling** (`funnel.zig`) is the simple stupid funnel algorithm over the corridor's
portals, on X and Z, with heights read by `heightOn`. A portal is the whole shared edge, shrunk
at each end by a small inset only where it ends at a boundary vertex, so a corner is rounded by
a hair and never clipped. A link ends the funnel at its `from`, and resumes from its `to`.

```zig
pub const Corner = struct { point: Vec3, polygon: u32, link: u32 = none_link };
pub fn corners(mesh, path: []const Step, from: Vec3, to: Vec3, out: []Corner) []Corner
```

## 6. Agents (`nav.Crowd`)

### 6.1 The shape of it

A crowd is a value a game owns and ticks, beside its collision world. It reads no clock, no
collision and no entity. It holds a pointer to the mesh it was given, which the game keeps
alive.

```zig
pub const Crowd = struct {
    pub fn init(gpa, options: CrowdOptions) !Crowd  // max_agents ≤ 256, all storage here
    pub fn setMesh(self, mesh: *const Mesh) void    // every agent re-seats and re-paths (§9)
    pub fn add(self, params: AgentParams, feet: Vec3) !AgentHandle
    pub fn remove(self, handle) bool
    pub fn setTarget(self, handle, point: Vec3) bool
    pub fn clearTarget(self, handle) bool
    /// One fixed tick: paths, corners, avoidance, and each agent's wish.
    pub fn step(self, dt: f32) void
    pub fn wish(self, handle) ?Wish                 // the displacement it asks for
    /// Where the body ended up. Skipped by a game that drives agents directly.
    pub fn place(self, handle, feet: Vec3) void
    pub fn agent(self, handle) ?AgentView           // state, velocity, corners, for view and panel
    pub fn hash(self) u64                           // for pins and hashTick
};
pub const AgentParams = struct {
    radius: f32, height: f32, speed: f32, acceleration: f32,
    arrival_radius: f32 = 0.25,
    /// Ticks between searches while the target moves.
    replan_ticks: u32 = 15,
    filter: Filter = .{},
};
pub const AgentState = enum { idle, walking, on_link, arrived, blocked, off_mesh };
```

An `AgentHandle` is a generational handle (I1), since a game holds it across ticks.

**The controller seam.** A tick goes: the game calls `step`, reads each `wish`, moves the body
however it likes, and calls `place`. The court gives a wish to `moveCharacter` with its own
gravity and calls `place` with `result.feet`. The sandbox's pawns have no bodies, so their wish
is applied directly: `step` has already kept them on the surface.

This is why `nav` needs no `physics3d`, and why neither a higher module nor an engine service
is needed. It answers `navigation.md` §6 and §7's two questions:
- **No store of meshes.** A crowd borrows one mesh, and a game that keeps two crowds keeps two
  meshes. Nothing yet holds a mesh across a subsystem boundary.
- **No engine service, and the glue stays in the samples.** `app` owns no world, and a crowd
  belongs with the world it walks. The samples' two `gather`s differ, and M48's table is what
  will first need a shared form. M48's design decides what `abi` hands over, and the roadmap's
  M48 line gains this at the close.

### 6.2 The corridor

Each agent keeps a **corridor**: its current `Step`s, at most 256, from its polygon toward its
goal. It is cheap to keep and cheap to update, which is why an agent does not search each tick.
- **Following.** Each tick the corners are recomputed from the agent's place along the corridor,
  and it steers at the first. This is what bends a path round a corner as it is reached.
- **Moving.** `moveOnSurface(from, polygon, to)` walks the polygons along the segment, sliding
  along a boundary edge if it meets one. It keeps the agent on the mesh and the corridor's head
  up to date, and takes its height from `heightOn`. It visits at most 16 polygons a move.
- **A moving target.** `setTarget` costs nothing but a new goal. If it locates in the
  corridor's last polygon, or a neighbour of it, the corridor just ends there. Otherwise the
  agent re-searches at its next `replan_ticks`.
- **Searches are budgeted.** A crowd runs at most `max_searches_per_step` (default 8) a tick, in
  a fixed queue by handle, oldest request first. A rebuilt mesh that re-paths thirty-two agents
  spreads over a few ticks, and they keep walking toward their last corner meanwhile.
- **`place`.** The body's feet are projected back: to the current polygon, then its neighbours
  along the corridor, then `locate` within the agent's radius. If that finds nothing the agent is
  `off_mesh` and asks for no move until `place` finds a floor again. The warden falling into the
  pit would be this case.
- **`blocked`.** An agent that has moved less than a tenth of its speed for `blocked_ticks`
  (default 60) reports `blocked` and keeps trying. Avoidance cannot let two agents pass in a
  passage one wide, whichever method is used, so what to do is a game's policy (§15).

### 6.3 Crossing a link

When the next corner is a link's `from` and the agent is within `arrival_radius` of it, the
agent is `on_link` and leaves avoidance. For the time the link takes, `wish` is the
displacement along a curve, and a tick-counted `t` runs 0 to 1:

| Kind | Curve | Time |
| --- | --- | --- |
| `jump` | A parabola from `from` to `to`, its top `arc` above the higher end | Length ÷ `speed` |
| `drop` | Straight out to the edge, then falling from there to `to` under 9.81 m/s² | Half the walk, plus the fall |
| `ladder` | Straight up or down over `to`'s or `from`'s X and Z, then a short step off | Height ÷ (`speed` × 0.5), plus the step |

The curves are `nav`'s, in plain arithmetic with no trig. The gravity is a fixed curve-shaping
constant and never a simulation one. A game with a body sets it directly during a crossing
(`setCharacterFeet`), because a controller would refuse the path a jump takes. `AgentView`
says which link and how far, so a game can play a clip. M34's animation events are where a
crossing gets a proper one. An agent that has begun a crossing finishes it even if the mesh
is rebuilt, and then re-seats at `to`.

## 7. `locate` stays a scan

M32 asked whether agents need something faster. They don't. A corridor means `place` and
`setTarget` rarely reach `locate`. The samples' meshes have at most 30 polygons, and the
court-sized stand-in, `yard`, has 75. Step 3 measures it on `yard`. A spatial index would have to live in the mesh, and M60's
tiles replace how a polygon is found. If a scan on a real level costs more than 50 µs on the
i3, §15's row brings an index forward.

## 8. Avoidance: ORCA (`nav`)

Each agent's new velocity is the one closest to its preferred velocity that satisfies one
half-plane per neighbour: Optimal Reciprocal Collision Avoidance (van den Berg et al., 2011).
Each agent takes half the responsibility for each pair. It is a small 2D linear program, on
X and Z, and is reimplemented in Zig from the paper.

- **Neighbours:** the eight nearest within `speed × horizon + radii`, ties by index. For at
  most 256 agents a plain pair scan is fine. It is 32,640 distance tests at the limit, and the
  32-agent budget is the one that is measured.
- **`horizon`** is 1.5 s, in `CrowdOptions`.
- **Walls are not ORCA lines.** `moveOnSurface` clamps the move and slides along a boundary.
  Avoidance's output is a request, and the mesh has the last word. It costs some
  wall-hugging in a busy passage, and is much smaller than feeding each agent the boundary
  segments near it.
- **An agent `on_link`, `off_mesh` or `idle`** counts as a neighbour with velocity zero and no
  share of the responsibility, so a crowd flows round someone standing still.
- **No randomness.** Many ORCA implementations perturb preferred velocities to break symmetry,
  and this one cannot take a global RNG (I9). A perfect head-on symmetry is broken by a fixed
  rule: every agent's preferred velocity is rotated by the same tiny angle, the same way. Two
  agents meeting head-on then each drift to their own side, as people keep to one side of a
  path. Four multiplications, no trig.
- **Determinism:** agents are computed from the last tick's velocities, then applied together,
  in index order. So the result doesn't depend on order at all, and it runs on one thread.
  `core.Jobs` over chunks would keep that, and is left until a game needs more than 256.

**Why ORCA and not sampling.** Detour samples candidate velocities on a pattern, which is more
tolerant and much more expensive per agent. ORCA is exact, and costs almost nothing for
the numbers these samples have. ADR-0070 records the comparison and what would change it.

## 9. Running obstacles, and a mesh as an input (`nav`, the samples)

**A running obstacle is a source.** The gate is a box. A crate is a box. Putting a box in the
sources and building gives the right mesh: a gate at `closed` cuts the doorway, and one at
`open` lies under the floor, so it cuts nothing. A gate half way down is whatever the voxels
say. So:

```zig
/// `out` holds its eight corners and its index list, for as long as the `Source` is read.
pub fn boxSource(half_extents: Vec3, pose: Pose, out: *BoxGeometry) Source
```

A game keeps its level's sources and adds a box per obstacle. `Build.start` already copies
everything. There is no incremental update, no retained heightfield and no new stage. The
court's mesh builds in 14 ms on the i3, so the whole rebuild is both the simplest answer and
fast enough. M60's tiles are what make it local. ADR-0069's revisit (150 ms on the i3) still
governs.

At most one rebuild runs at a time. A change during one marks the mesh dirty, and the next
request carries the poses as they are then, so a crate dragged across a room makes a few
rebuilds and not one a tick.

**How it reaches simulation.** ADR-0061 says when a build arrives must never decide what a
tick computes, because arrival is a wall-clock fact. The warden's path now depends on the mesh,
so the mesh's arrival has to be fenced off. ADR-0061's decision 4 already says how, and this
design takes it literally:

1. A frame polls `Build.take`. On arrival the mesh gets the next **generation** number, and the
   frame stores it. It does not touch the crowd.
2. That frame's `Intent` carries `navigation: u32`, the generation to adopt, or zero. An intent
   is recorded input already: `main.zig` hands the same intents to its replay, and tests
   compare the hashes.
3. `Game.step` applies it before anything else in the tick, by `crowd.setMesh(meshes.get(g))`.

So a run's result depends on the tick that intent landed on, and the replay is given the same
tick. A mesh's bytes are a pure function of its inputs, so **both `Game`s read the same mesh**
from one `nav.Meshes`, a small list of generations the frame owns. What a replay needs is never waited for, because the frame that recorded the intent had the
mesh in hand. The list keeps what a run may adopt again. The court's holds two entries, gate
shut and gate open, which are reused for the rest of the run, so restarts and later openings
need no rebuild. The sandbox has no replay and keeps the newest few.

Two consequences follow:
- **Play is gated, as ADR-0061 said a game would.** The title's Play is an intent, and the
  menu refuses it until the first mesh has arrived, which at a load takes tens of milliseconds
  (`navigation.md` Step 8). No tick ever runs without an answer. A build that fails counts as
  arrived: the warden stands where it is, with a warning, and the game is playable, as a
  missing warden record already leaves it. `FOUNDRY_COURT_NAV=off` is the same case.
- **Restart adopts generation 1,** which holds the gate shut, with no rebuild. Restart is
  already an input, so `Game.reset` does this itself and the intent need not say so. A build
  that arrives after a restart it no longer suits joins the list and is not adopted.

ADR-0061 stands unamended. M27 wrote "M60 (streaming) will" need this route, and M33 is simply
first to use it. It rejected making arrival deterministic "by finishing loads only at fixed
ticks and stalling", and this design doesn't: nothing stalls. A slow build costs a warden a
few more ticks on the old mesh, and the collision world remains the truth meanwhile.

**The sandbox** has no replay, so its proof is §13's: a recorded list of `(tick, generation)`
pairs replayed into a fresh crowd gives the same bytes.

## 10. The view and the panel (`nav`, `debug`)

**The view.** `debugView` gains each link as an arc of thin strips, in a colour per kind, and
area floors tinted by area. `nav.debugAgents(crowd, out)` writes a strip along each agent's
corners and a ring at its target, on a separate runtime mesh, rewritten at most once per tick
and only while shown. The samples draw it with the material M32 gave them. No renderer change.

**The panel.** `debug` gains `navigation_panel.zig`, one more registered panel, and `nav` joins
`debug`'s grants in `build.zig`:

```zig
pub const Sources = struct {
    ...
    /// What navigation is doing, from `nav.Report`. Null for a game with none, and the panel
    /// says so.
    navigation: ?*const nav.Report = null,
};
```

`nav.Report` is a plain value a game fills from its crowd and meshes:
polygons, detail triangles, islands, links and unattached links, per-area area in square
metres, build time, generation, rebuilds, agents by state, searches this tick and their
worst, crowd step p95, and a warning line for `skipped` regions. The introspection lives in
`nav`, and the overlay only prints it (ADR-0025). The panel has no write path. A `Report` is
values, so M48 can publish it without a redesign.

## 11. The samples

### 11.1 `sandbox3d`

- **Content:**
  - `sandbox3d:nav.walker` moves to version 2, with a `mud` area on the floor, a ladder link
    onto the table, and a drop link off the platform. Step 8 names the coordinates from
    `make_scene.py`'s room.
  - `sandbox3d:crowd.main`, a sample record: sixteen pawns, their speed and radius, the four
    corners they cycle between, and the pawn's model.
- **Code:** `crowd.zig` beside `nav.zig`. It ticks the crowd at the fixed step and applies
  wishes directly, and draws each pawn as an unskinned model. It takes area scales from the
  record. A key, `C`, slides a crate across the crowd's way and back, and it joins the sources
  as a box.
- **The M24 walker is untouched,** and its pins hold.
- **`marsh`,** a new test mod, restates the recipe with a second, costlier area over the short
  way and removes the drop link. The crowd's paths change, with no code.

### 11.2 The court

- **Content.** `court:nav.warden` moves to version 2, with a two-way `jump` link across the gap
  at x = 0 and another over the low wall. `@schema warden` gains, each with a default so that
  `noon` still reads:

  | Field | Default | Meaning |
  | --- | --- | --- |
  | `chase_speed` | 2.4 | Metres a second, under the player's 3, so a player can outrun it |
  | `sight_range` | 7 | How far it sees |
  | `sight_angle` | 0.6 | The half-angle of its view, radians |
  | `lose_seconds` | 2 | How long after losing sight it gives up the last place it saw |

  The numbers are starting points, for the owner's play to settle (criterion 8). At 7 m a
  warden on the patrol line (z 2.5) cannot see the ledge's beacon, so the ledge stays a place
  to catch your breath until it has seen you go there. At 0.6 rad it does not see the spawn
  from the patrol line's west end. It does see the open beacon, 0.42 rad off its eastward walk
  at 4.9 m, so lighting that beacon has to be timed. That is the game now, and `route_open`
  times it.
- **`warden.zig`.** `Warden.step` no longer draws a line. It has three states, `patrolling`,
  `chasing` and `searching`, and each sets the crowd target. It feeds `wish` to
  `moveCharacter` with gravity as before, or to `setCharacterFeet` on a link, and calls `place`.
  - **Sight** is three tests in a fixed order: within range, within the angle, and one ray from
    its eye to the player's against `level_layer`. So the low wall does not hide a player, but
    the gate does. The angle is compared as a cosine, computed once from the record by
    `core.math.trig`, so a tick reads no trig.
  - **The player's place** is `locate`d within 2 m below and 0.5 m around, so a player in the
    air or on the low wall still has a floor under them. If there is none the warden keeps the
    last place.
- **`game.zig`.** `Game` owns a `nav.Crowd`, and `Game.step` takes `meshes`. `Intent` gains
  `navigation`. The gate joins the warden's sources as a box, and when the gate's `progress`
  reaches 1 it requests a rebuild. `hashTick` adds the crowd's hash and the warden's state.
- **`main.zig`.** Play is refused until the first mesh has arrived or failed.
- **What changes for a player:** "The warden caught you. It walks the same patrol every time"
  is no longer true, so `caught_detail` changes. The goal line stays. The music still turns on
  `chase_distance`, as M30 made it, and that stays as it is.
- **The scripts.** `route_ledge` is re-laid around sight, `caught` still stands in the patrol,
  and `fell` is unchanged. `soundtrack`'s minute on the ledge holds if the warden has not seen
  the route. Step 10 records every script's new ticks, and the `game_tests` assertions move
  with them, each listed.

## 12. The public ABI, and platform assessment

**The ABI: nothing in M33.** The call count stays 264. A content mod reaches all of M33's
content: `foundry:nav_area`, volumes and links are records, and `marsh` shows it. Search,
crowds and `Report` reach the table in M48's `FoundryApi_v8`, and Lua in M49. M48's line gains
that at the close.

- **macOS (Metal):** everything new is pure Zig, and Steps 1–10 run here. The view stays a
  runtime mesh, and the panel an overlay panel.
- **Windows (Vulkan):** criterion 7 is decided on the i3, and criterion 5's pin is compared on
  x86_64, so Step 11 runs on the Arc PC. It has no clone since M32's close, so the step clones
  again. The usual rules apply: check it is idle, `-j2`, below-normal priority, a scheduled
  task for windowed runs, and removal of exact Foundry paths only.
- **Linux:** nothing in M33 is Linux-specific, so 3d.md §10.2 calls for no Linux run. The Linux
  null cross-check in the bar builds `nav` too.

## 13. Verification, pins and budgets

- **Records:** defaults; every refusal through `fpack`'s path; a v1 record under v2; an override
  replacing a recipe; a `nav_area` from a mod. `engine/tests/nav_mesh.zig` holds the two
  modules' rules in step.
- **Areas:** a floor with a volume makes polygons of two areas whose union is the unmarked
  floor's polygons' area. No region crosses areas. An area does not change the eroded outline.
- **Links:** each kind attaches; an end on no polygon is counted, not fatal; a two-way link is
  in both lists; a link joins two islands for search only.
- **Search:** the islands-and-links truth table on every M32 scene and on `yard`; partial
  paths; every filter case; `max_nodes` exhausted answers a partial path; ties are stable.
  - **The reference** for criterion 1 is Dijkstra over the open field's links on the same
    scene, with 8-way moves over the erosion's own spans.
  - **Property test:** 2,000 seeded start and goal pairs on `yard`, each path's corners on
    the mesh, inside the corridor, and within the bound.
- **Agents:** every scene of criterion 2; a body pushed off its corridor; a target that moves
  every tick; a rebuild mid-corridor, and mid-crossing; a removed handle refused (I1).
- **Avoidance:** the crossing, the swap, the 32-agent ring, the two-wide passage both ways,
  and a head-on exact symmetry, each with the separation bound of criterion 3 on every tick.
  A one-wide passage reports `blocked` and stays well-formed.
- **Refusals:** every parameter bound; non-finite targets and feet; a full crowd; a seeded sweep
  of 1,000 mutated crowds and targets; `checkAllAllocationFailures` over `init` and `add`. A
  test asserts `step` and `find` allocate nothing, with a failing allocator.
- **Running obstacles:** the same mesh bytes from a `boxSource` and from a static box mesh; a
  rebuild while one runs coalesces; a superseded build is freed.
- **Adoption, as ADR-0061's decision 6 requires:** one script under `immediate`, under
  `Manual` forward, reverse and held across polls, and on the real pool. Adoption ticks may
  differ between those runs, so each run's *own* replay must match, and a run forced to the same
  adoption ticks must give identical bytes.
- **The crowd pin:** the crowd's hash after 600 ticks of the ring on `course`, equal in Debug,
  ReleaseSafe and x86_64 under Rosetta, and compared on Windows.
- **The court, against compiled content:** the warden's route round the wall, across the gap
  by the link, and to the exit only after the gate opens. It sees across the wall and not through
  the gate. It loses a player, and goes back. `noon` still completes with an exact replay.
- **Cost:** a timing test beside M32's, in ReleaseSafe, over `yard` and the real court, against
  criterion 7. The Debug bar skips it, and `AGENTS.md`'s optimized list gains it.
- **The samples:** criteria 8 and 9, with `dist` staging, since the court's content changes.
- **The bar** (`AGENTS.md` §3) at every step. `fdt-check` covers the new records.

## 14. Implementation order — twelve bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `asset`: the version 2 record and `foundry:nav_area`

The two schemas, decoding and every refusal, load-time checks, the editor's New Record list, and
the agreement test (§3). Tests: §13's records.

**Exit:** a v1 record loads unchanged under v2, and every new field defaults and refuses by name
through `fpack`'s path.

### Step 2 — `nav`: areas and links in the build

`buildWith`, marking after erosion, the merge refusal, `Polygon.area`, link attachment,
`Mesh.links` and adjacency, `islands`, and the hash (§4). Tests: §13's areas and links.

**Exit:** a scene with areas and links builds well-formed by M32's criterion 2, and M32's course
pin is unchanged.

### Step 3 — `nav`: search and string pulling

`Query`, `Filter`, partial paths, the funnel, `locate`'s measurement (§5, §7). Tests: §13's
search, with the reference and the property test.

**Exit:** criterion 1 holds on every scene and the property test, and `find` allocates nothing.

### Step 4 — `nav`: `Crowd`, the corridor and links, without avoidance

`Crowd`, `AgentHandle`, `step`, `wish`, `place`, `moveOnSurface`, budgeted searches, the states
and the three crossings (§6). Tests: §13's agents.

**Exit:** criterion 2 holds for single agents, with bodies driven directly and through a test
controller.

### Step 5 — `nav`: ORCA, the crowd pin and the budget

Avoidance (§8), its scenes, the pin and the timing test.

**Exit:** criterion 3 holds, the pin is equal in Debug, ReleaseSafe and x86_64, and the Mac's
crowd step meets criterion 7.

### Step 6 — `nav`: running obstacles and adoption

`boxSource`, coalesced rebuilds, `nav.Meshes`, `setMesh` on a running crowd, and the adoption
proof under every executor (§9).

**Exit:** criterion 4's byte equality holds, and criterion 5's executors agree.

### Step 7 — `nav` and `debug`: the view and the panel

`debugView` with links and areas, `debugAgents`, `nav.Report`, `navigation_panel.zig` and the
grant (§10). Panel tests build a `Frame` and `Sources` by hand.

**Exit:** the panel describes a hand-made `Report` and an empty one, with no engine, and the view
holds every link and agent path of a test mesh.

### Step 8 — `sandbox3d`: the crowd, proved on the Mac

The record, `crowd.zig`, the pawns, the crate, `marsh`, and the evidence from a relocated
ReleaseSafe install (§11.1).

**Exit:** §1's `sandbox3d` result is visible and tested, `marsh` changes the route with no code,
and no frame goes over 16.67 ms for a rebuild, on the M5 with Metal.

### Step 9 — `court`: the warden walks the mesh

The warden's patrol through a `Crowd`, `Intent.navigation`, `Meshes`, Play gated, the gate as a
source and its rebuild, restart's generation (§9, §11.2). No sight yet, so every scripted
ending keeps its route.

**Exit:** the warden patrols by mesh, the gate closes and opens the way, and every script replays
tick for tick under §13's adoption proof.

### Step 10 — `court`: the warden sees and chases

Sight, the three states, the links, the words, the re-laid scripts, and `noon` (§11.2).
Timing against criterion 7. Then the staged build is offered to the owner.

**Exit:** the court's tests of §13 hold against its compiled content, every script replays, and
the owner has a build to play. Criterion 8's tuning lands as content in this step's Resolution.

### Step 11 — Windows/Vulkan

Clone on the PC. The null and Vulkan suites, the timing tests and both pins. Both samples from a
relocated, read-only ReleaseSafe install, with and without validation.

**Exit:** criteria 5, 7 and 9 hold on the Arc A750, with any pin difference recorded.

### Step 12 — Close M33

Resolve the contract discrepancies where they were written:
- `playable3d.md` §5.4's and §13's warden lines: the chase is done;
- `navigation.md`'s §13 rows, and `locate.zig`'s and `nav/root.zig`'s "M33 decides" comments;
- the intent lines in `docs/ROADMAP.md` of M34 (a link crossing's clip), M48 (paths, crowds,
  areas, `Report`), M60 (rebuilding around an obstacle, and a spatial index for `locate`) and
  M100 (crowds on `core.Jobs`).

Then:
- move ADR-0070 to Accepted and into `CLAUDE.md` §4.1;
- update §4.3 (`nav`'s line, `debug`'s grants) and §9's row;
- add the new timing tests and `scripts/m33/windows.ps1` to `AGENTS.md`;
- write the content-mod guide's navigation section in `docs/modding/content-mods.md`, since
  areas and links are mod-facing;
- update the roadmap's M33 row, the design index, the README and `PROJECT_STATE.md`;
- pack up the PC by exact path.

Tag `m33`, push when asked, and stop before M34's design.

## 15. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| Rebuilding only the tiles around an obstacle | M60 | M33 rebuilds a whole mesh; tiles make it local |
| A spatial index for `locate` | M60 | Tiles change how a polygon is found. Comes forward if a scan on a real level passes 50 µs on the i3 (§7) |
| Navigation in the public table, and in Lua | M48, M49 | §12. M48's line gains this at the close |
| The clip an agent plays on a link | M34 | Its events are the right hook. `AgentView` already reports a crossing |
| Crowds over 256 agents, on `core.Jobs` | M100 | Its parallel systems are the first general reason to split a step |
| Two agents meeting in a passage one wide | Not planned for the engine | No avoidance solves it. The engine reports `blocked`, and who backs up is a game's policy |
| Senses and game AI | Not planned for the engine | The warden's sight is the court's, in a sample (ADR-0017). A second game with the same needs would be a new decision |
| Moving a mesh with what carries it (a lift, a ship) | Not planned for the engine | M37's moving platforms move characters. A link timed to a platform is a game's, by replacing the link's recipe at a rebuild |

## 16. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | Paths, agents and avoidance live in `nav`, L1 on `core` alone. `nav.Crowd` is a value a game owns and ticks, with generational agent handles | §6, ADR-0070 |
| 2 | The seam: a crowd gives each agent a wish, the game moves the body, and `place` reports the result. `nav` never sees `physics3d` | §6.1, ADR-0070 |
| 3 | No handle-addressed store of meshes and no engine service; the glue stays in the samples, and M48's design decides what `abi` needs. This answers `navigation.md` §6 and §7 | §6.1 |
| 4 | `foundry:nav_area` is a record with one field, `cost`, at least 1. "Never walk here" belongs to a query's filter | §3.1, §5 |
| 5 | `foundry:nav_mesh` v2 adds `volumes` (axis-aligned boxes, at most 32) and `links` (at most 64) with defaults, so a v1 record builds the same bytes. At most 8 area types a mesh | §3.2 |
| 6 | Link kinds are three engine motions, named by a string; a mod places links and adds no kind | §3.2, §6.3 |
| 7 | Marking areas after erosion: an area changes what a floor costs, never where an agent fits | §4 |
| 8 | A* over polygons by edge midpoints, with a distance heuristic and partial paths; the simple funnel; the 1.25 reference bound | §5 |
| 9 | A corridor per agent with budgeted searches, at most 8 a tick, and at most 256 agents | §6.2 |
| 10 | `locate` stays a scan, with a stated trigger for an index | §7 |
| 11 | ORCA, in a fixed order with last tick's velocities and a deterministic symmetry break, no RNG; walls are the mesh's clamp, not ORCA lines. Not Detour's sampling | §8, ADR-0070 |
| 12 | A running obstacle is a source, and cutting is a whole rebuild on the pool: no incremental update and no retained heightfield. At most one rebuild at a time, coalesced | §9, ADR-0070 |
| 13 | A rebuilt mesh reaches simulation only as a recorded input, `Intent.navigation`, per ADR-0061's decision 4, which stands unamended. Both `Game`s share one list of meshes | §9, ADR-0070 |
| 14 | Play is refused until the first mesh arrives or fails; a failed build leaves the warden standing; restart re-adopts generation 1, and the court reuses its two meshes | §9 |
| 15 | The panel reads a `nav.Report` value handed through `debug.Sources`, and `debug` is granted `nav` | §10 |
| 16 | The runnable result: the court's warden sees, chases by the mesh, crosses the gap and the wall by jump links and is held by the gate, with `sight_angle` and the rest as content defaults; `sandbox3d`'s sixteen pawns; the `marsh` content mod. **This changes how the court plays** | §1, §11 |
| 17 | The warden's senses and states stay in the sample. The engine gets no AI feature | §11.2, §15 |
| 18 | The owner's play is an exit criterion, and tuning lands as content | §1, §14 |
| 19 | No ABI change; 264 calls. M48 publishes navigation and M49 binds it | §12 |
| 20 | The budgets of criterion 7 | §1, §13 |
| 21 | What stays open, each with its owner or "not planned for the engine". Correcting `navigation.md` §6's "M33 decides" and §7's by #3, and `playable3d.md`'s warden lines at the close | §15 |
| 22 | Twelve steps, in §14's order | §14 |

Once these are accepted, nothing blocks Step 1.

## Resolution — Step 1: the version 2 record and `foundry:nav_area` (2026-10-30)

**Accepted.** The owner asked for Step 1 with §16 as written. ADR-0070 is Accepted and in
`CLAUDE.md` §4.1. §4.3 changes at the close (Step 12), as §14 says.

**What exists now:**
- **`engine/src/asset/nav_mesh.zig`:**
  - `foundry:nav_mesh` is version 2, adding `volumes` and `links`, both optional and `since` 2.
  - `foundry:nav_area` is version 1, with `cost` defaulting to 1.
  - `Settings` holds its volumes and links in fixed arrays, read by `volumes()`, `links()` and
    `areas()`.
  - `decodeArea` reads an area, and `resolveAreas` turns a recipe's areas into costs at load.
- **`engine/src/nav/features.zig`:** `Features`, `Volume`, `LinkInput`, `LinkKind` and
  `Features.problem()`, `nav`'s half of the rules. It came forward from Step 2 because the
  agreement test needs both halves. Nothing builds with it yet.
- **`engine/src/author/compiler.zig`:** both records are checked as "navigation mesh" and
  "navigation area", and `foundry:nav_area` is in the editor's New Record list.
- **`engine/tests/nav_mesh.zig`** holds the modules' limits in step, and sweeps coordinates
  and amounts, NaN and infinity included, so that both refuse the same volumes and links.

**Where the step sharpened the design:**
- **Eight areas means eight named.** §3.2 says a recipe may name eight, and §4 says index 0 is
  unmarked floor. So `asset.max_areas` is 8 and `nav.max_areas` is 9, and a filter's array in
  Step 3 takes 9. The test asserts the one difference.
- **Area numbering.** An area's index in a mesh is one more than its place in `areas()`, the
  order of first use among the volumes. `resolveAreas` writes costs in that order. It is an
  index inside one mesh and is never saved, like a polygon (I2).
- **The envelope.** §3.2 says volumes and links are "finite". They are also held to ±8,192 m,
  `nav`'s `max_coordinate`, because nothing beyond it can be on a mesh.
- **Refusals,** beyond one per field: `TooManyVolumes`, `TooManyLinks`, `TooManyAreas`,
  `InvalidVolumeArea`, `InvalidLinkKind` and, at load, `NotANavArea`. That one covers a missing
  record as well as a wrong schema, as `NotACollisionMesh` does.
- **`InvalidVolumeArea` is refused by value only,** because `.fdt` text cannot write a `none`
  ID. A hand-built `Settings` tests it, as M32's `InvalidSource` left unwritten.
- **A mod may supply an area a recipe names,** and a test does: the base's recipe, one area in
  the base and one in the mod. A bad cost in a resolved area is refused at load, with its name.

**Measured, in the tests:**
- A version 1 package, compiled against the version 1 fields, reads under version 2 through
  the store, with no volumes and no links, and keeps its own `cell_size`.
- Every new field defaults and refuses by name through `fpack`'s path, and the 32, 8 and 64
  bounds hold on both sides.

**Guards verified by breaking them.** Each of these fails at least one test: the link-length
rule on the `asset` side, the snap bound on the `nav` side, a `links` field made required
(registration fails), the area's schema check, the compiler's `foundry:nav_area` branch, the
eight-area bound, and the distinct-area rule. Two of these first failed only by not compiling,
which proves nothing, and were redone as real mutations.

**An environment change, not this step's:** the bar's `zig build check -Drhi=metal` failed
with "missing Metal Toolchain". The Mac now has Xcode 27.2, whose on-demand toolchain was not
installed. `xcodebuild -downloadComponent MetalToolchain` installed build 27B47 (839 MB), and
the check then passed. `AGENTS.md` §4 records it.

Bar **2,520/2,527** (seven skips), 127/127 steps, up 10 tests from M32's 2,510. The full bar,
all exit 0, the Metal check after the toolchain install. No sample's content changed, so no
`dist` staging.

## Resolution — Step 2: areas and links in the build (2026-10-30)

**What exists now:**
- **`poly.buildWith(gpa, config, sources, features)`,** which refuses bad features with
  `InvalidFeatures` before it allocates. `build` is the same call with no features.
- **`OpenField.markAreas`,** run after erosion. A span's `area` is `walkable` plus the mesh's
  area index, and `Polygon.area` is the index.
- **`engine/src/nav/link.zig`:** `Link`, `none_link` and `attach`.
- **`Mesh`** gains `costs`, `links`, `link_first`, `link_index`, `links_unattached` and
  `islands`, with `linksFrom(p)` and `costOf(p)`.
- **`Build.startWith`,** which copies the features too. §14 did not name it, but Steps 8 and 9
  build on the pool. `start` is the same call with no features.
- **`engine/src/nav/features_tests.zig`.**

**Where the step sharpened the design:**
- **Area borders are simplified like walls: a correction to §4.** §4 said contours "follow".
  They did not. M32 keeps a border between regions straight between its change points, so a
  patch inside a floor, one neighbour all round, kept only its two extreme corners. A 1 m²
  volume came out as 0.5 m². The tests found it. A contour vertex now records `area_border`,
  and Douglas–Peucker runs along an area border as it does along a wall, from the same
  canonical direction, so both sides get the same vertices. This is what Recast does. A mesh
  with no areas has no such border, so M32's pin does not move.
- **A polygon's area is set after polygonising,** from a region-to-area table, rather than
  carried through contours. A region is one area, because growth stops at a change of area and
  merging now refuses one.
- **A column is inside a volume by its centre,** half-open on X and Z. A floor is inside by
  its height, inclusive, so a volume whose `max.y` equals a floor's height still marks it.
- **A link whose ends land in one polygon** is kept, and listed once.
- **A mesh with no links has no tables,** and `linksFrom` answers empty. `costOf` answers 1
  for a mesh with no costs.

**Measured, in the tests:**
- A 4 m by 4 m volume on a floor gives 16 m² of its area within the staircase's error, and
  all the polygons together keep the unmarked floor's area within 0.2 m². The floor around the
  patch is still one island through its neighbour links.
- A 1 m² area, under the 4 m² merge limit, keeps its own polygons.
- A later volume wins, and a floor outside a volume's height stays unmarked.
- Each of the three kinds attaches, a two-way link is listed at both ends, and two ends on no
  polygon leave a link out and counted.
- A link leaves `islands` at 2, and `islands` equals a flood's count on the course and `yard`.
- A build with features survives every allocation failure.
- **Pins:** M32's course stays `14865720887737603270`. The course with an area and two links
  is `14748995640725302437`, equal in Debug, ReleaseSafe and x86_64 under Rosetta.

**Guards verified by breaking them.** Each of these fails at least one test: merging across
areas, tessellating walls only, a volume ignoring height, the first volume winning, polygons
left unmarked, a two-way link not listed at its far end, the features check removed, and a
fixed island count.

**One rule changed no result:** marking before erosion gives the same meshes. `erode` looks at
walkable neighbours and not at areas, so the order cannot show in it. Marking stays after
erosion, because that is the rule §4 states, and this equivalence is why the "never where an
agent fits" test holds whichever way round the stages run.

Bar **2,533/2,540** (seven skips), 127/127 steps, up 13 tests from Step 1. The full bar, all
exit 0. No sample's content changed, so no `dist` staging.
