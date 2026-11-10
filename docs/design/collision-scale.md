# Design: M38 — Collision at scale: a broadphase over bodies, the tree baked into `.fcol`, hull faces and hull assets, closed-form pairs and a physics panel

**Status:** Accepted 2026-11-10, when the owner asked for Step 1, with §17 as written. Each step's
Resolution follows §17, and the dated notes below say where the code sharpened this text.
**Date:** 2026-11-10
**Baseline:** `f066f63`, tag `m37`. M0–M37 are complete.
**Decisions:**
- ADR-0051 (3D collision, queries and a character controller, no dynamics), ADR-0057 (collision
  geometry is compiled content, copied into `physics3d`) and ADR-0076 (`.fcol` version 2) are the
  contracts this milestone extends. ADR-0013 (deterministic-friendly), ADR-0025 (the overlay
  reads answers and has no private path) and ADR-0059 (the public 3D table, frozen at v6)
  constrain it.
- [ADR-0077](../adr/0077-collision-structures-never-decide-an-answer.md): a broadphase
  over bodies and a tree baked into `.fcol` are structures that find candidates and never decide
  an answer. A baked tree is untrusted and validated in linear time. `author` is granted
  `physics3d`, so the compiler builds a tree with the code that would have built it at load.
- [ADR-0078](../adr/0078-hulls-have-faces-and-triangle-pairs-are-closed-form.md): a hull
  has faces, found by `physics3d` from its points, and is compiled content,
  `foundry:collision_hull`. A ray, a sphere and a capsule meet a triangle by closed-form
  routines in place of GJK, and every pin that walks on triangles moves once.

`collision3d.md` is `physics3d`'s document. Its §15 lists every item here with the trigger M23
gave it, and `collision-extras.md` §18 named M38 as their owner. ADR-0060 scheduled them. Rule 17
means each is built here, or named by the milestone that owns it.

## 1. Purpose and boundary

The roadmap's row is the contract:

> **M38 — Collision at scale.** A broadphase, the tree baked into `.fcol`, hull assets, and a
> physics panel in the overlay; also specialised pair routines such as analytic capsule–triangle.

**The runnable result.** `sandbox3d` gains a yard, east of the room and off every tour path:
- a hillside of about 32,000 triangles, whose collision arrives with its tree already built;
- 2,048 stones standing on it, boxes and hulls, each a body of its own;
- 64 boxes that circle among them, moved every tick;
- a boulder whose collision is a hull compiled from a glTF file, with a slanted face the player
  stands on and is told the slope of.

The player walks the yard in a new tour stage. The overlay's new physics panel shows what the
world holds and what each tick asked of it. The court is untouched in content. Its feet meet its
triangles through the new routines, and the owner plays it once more to say it feels the same.

**The exit condition:**
- the yard's tour stage passes on Metal and on Windows/Vulkan;
- with 2,100 bodies in the world, the player's move stays inside M23's budget (§14);
- the hillside's `addMesh`, with its baked tree, stays inside ADR-0057's 5 ms, and the same mesh
  built at load is measured beside it;
- every query answers as a scan in handle order would, proven by a test that runs both;
- the closed-form pairs agree with GJK within the tolerances of §8, and every tour walked with
  them stays within 1 mm of the same tour walked with GJK, at every tick;
- the pins that moved are re-pinned once, each with its old value recorded.

**In M38:**
- `physics3d`: the broadphase, a tree accepted from outside and validated, hull faces, the
  closed-form pairs, and a `Report`;
- `asset`: `.fcol` version 3, `foundry:collision_hull` and its `.fhul` payload, and
  `foundry:collision_import` version 2;
- `author`: baking the tree, and compiling a hull;
- `debug`: the physics panel;
- the two samples.

**Not in M38**, each with its owner (§16):
- dynamics, contacts between bodies and pair finding for a solver are M51's;
- heightfield collision is M63's;
- the public table gains nothing, and M48 publishes what is here;
- over-budget readings that parallel work would answer go to M100, as M35's to M37's did.

## 2. What exists

Read from the code at `f066f63`.

**`engine/src/physics3d/world.zig`.** Every query walks `self.bodies.iterator()`, every live body
in ascending handle index. For each it calls `candidate`, which checks the filter, computes the
body's world bounds afresh (`bodyBounds`, a support query on eight axes or a posed mesh box), and
tests them against the query's area. Ties resolve by that order: only a strictly earlier hit
replaces the best. The file's header says a broadphase "must see every change", so a body is read
through a const pointer and changed through setters, and `setPose`, `setShape`, `setScale`,
`removeBody` and `moveBody` already take an allocator "for the broadphase that does not exist
yet". Two places write a pose without a setter: `moveBodyAlone`, and `character.zig` lines 134
and 369, which place a character's own body.

**`engine/src/physics3d/mesh.zig`.** `Mesh.initWith` copies positions and indices and builds the
tree: a median split on the longest axis of the centroids, sorted by `(coordinate, index)` with
a heap sort at every level, four triangles a leaf, nodes in preorder. `candidates` walks it with
a fixed stack of 32 and sorts the triangles it found by index, so the tree's shape never reaches
an answer. The world keeps one `triangle_scratch`, sized for its largest mesh, so a query
allocates nothing. A query in progress holds a slice of it, so queries do not nest.

**`engine/src/physics3d/shape.zig` and `gjk.zig`.** A hull is 4 to 256 points and nothing else.
`Convex.surfaceNormal` gives a triangle its face and a box its nearest face, and a hull only the
contact normal. `earliestPair` prefers a walkable face at a box's edge, and has no such rule for
a hull. Every pair, a ray included, goes through GJK and conservative advancement
(`narrow.zig`), 32 iterations each at most.

**`engine/src/asset/collision_mesh.zig`.** `.fcol` version 2: positions, indices, a surface
table and a u32 per triangle. A mesh with nothing version 2 adds is written as version 1.
`asset` cannot see `physics3d`, so the game converts (`samples/court/walk.zig`'s
`addCollisionMesh`).

**`engine/src/author`.** It derives collision from `foundry:model_import` and compiles
`foundry:collision_import` into a proxy. Its grants are `core`, `data`, `platform`, `asset`,
`mod` and `scene`, so it cannot build a tree today.

**`engine/src/debug`.** Seven panels. `Sources` is what a game hands over, and
`Sources.navigation` is a `nav.Report`, a value the game fills. `debug` was granted `nav` at M33
for that type and `anim` at M34 for its own. It has no `physics3d`, and `collision3d.md` §15 says
that grant is the owner's decision.

**The samples.** `sandbox3d`'s walk world holds the room, the course, M37's corner and a
character: a dozen bodies. The corner's turntable is a hull the player stands on
(`extras.zig`). The court's world holds its level and two characters.

**What has been measured** (`AGENTS.md`, `collision-extras.md`'s Resolutions), p95 in the paced
loop at ReleaseSafe:

| What | Mac | i3 | Budget |
| --- | --- | --- | --- |
| The player's move | 0.231 ms | 0.090–0.114 ms | 0.25 ms |
| `addMesh`, the court's 132 triangles | 0.05–0.06 ms | 0.15–0.17 ms | 5 ms |
| The court's whole tick | 0.153–0.176 ms | 0.125–0.215 ms | 0.25 ms |
| The court's tick, the 80-frame `caught` run | within | 0.250 and 0.273 ms | 0.25 ms |

No trigger in `collision3d.md` §15 has fired on these worlds. They are small. ADR-0060 scheduled
the work anyway, and a trigger now decides an item's shape and budget, not whether it is built.
So the yard is the world large enough to read each item against.

## 3. Measure first, and the `Report` (`physics3d`)

**Now.** The world counts what it does, and Step 1 reads the present code before anything
changes. Three numbers size the rest of the design:
- what a move costs with 2,100 bodies under the scan;
- what `addMesh` costs to build a tree at 4,096, 32,768 and 262,144 triangles;
- how much of a move is GJK on triangles.

If the hillside's tree builds in under 5 ms at 32,768 triangles, Step 1 enlarges the hillside
until it does not, and records the size. The design's other numbers do not depend on it.

> **2026-11-10, Step 1:** the hillside's size stands, since 32,768 triangles build in 60 ms. The
> bake threshold moved from 4,096 triangles to 1,024 (§9's note).

**`physics3d.Report`** is a plain value, as `nav.Report` is:

| Field | What it says |
| --- | --- |
| `bodies_static`, `bodies_kinematic`, `characters` | What the world holds |
| `meshes`, `triangles`, `meshes_baked` | Its meshes, and how many arrived with a tree |
| `hulls`, `hull_faces` | Its hulls |
| `tree_nodes`, `tree_height` | The broadphase (§4) |
| `queries: [6]u32` | Rays, casts, sweeps, overlaps, contacts and character moves, since the counters were last taken |
| `bodies_visited`, `bodies_tested` | Broadphase nodes walked, and bodies whose exact bounds were tested |
| `triangles_tested`, `pairs_closed`, `pairs_gjk` | Narrowphase work, by routine (§8) |
| `refits` | Bodies whose place in the broadphase changed |
| `move_p95_ms` | The game's own timing, which it fills, as `nav.Report.step_p95_ms` is |

`World.report()` fills the counts. `World.takeCounters()` returns the counters and zeroes them,
so a game takes them once a tick or once a frame as it likes. The counters are u32 fields
incremented inside queries. They are not simulation state: nothing reads them to decide
anything, and two worlds compared byte for byte in a determinism test are compared without them.

**Designed for.** M51's solver adds its own lines to the same value.

## 4. The broadphase (`physics3d`)

**What it is.** One bounding-volume tree over every body, in `physics3d/broadphase.zig`:
- a leaf is a body, and holds the body's bounds, padded;
- an inner node holds the box around its two children;
- a body is inserted beside the sibling that grows the tree's surface least, the left child on a
  tie, and the tree is kept balanced by rotations, so its height stays under 1.45·log₂(n) + 2;
- a body is removed by joining its sibling to its grandparent.

A static body's box is its exact bounds plus the 2 mm the scan already adds. A kinematic body's
box is padded by `broadphase.margin`, 0.1 m, so a body that moves a little each tick usually
stays inside its box and costs nothing. When it leaves its box it is removed and inserted again.

**Why a tree and not `physics2d`'s spatial hash.** A hash needs a cell size, and a 3D world
holds a level mesh the size of the world beside a crate. A tree has no cell size and takes both.
It is also what M51's pair finding will ask for.

**It never decides an answer** (ADR-0077). A query:
1. walks the tree with its area, on a fixed stack of 64, and writes the index of each body whose
   padded box overlaps into `body_scratch`;
2. sorts those indices ascending;
3. runs today's `candidate` on each, in that order, exact bounds test included.

So every query sees the bodies a scan would have passed, in the order a scan would have met
them, and ties resolve as before. `collision3d.md` §6 promised this: "It will not change an
answer, because order already comes from handles and not from the structure."

**Queries still allocate nothing.** `body_scratch` grows in `addBody`, which takes an allocator,
to the pool's capacity. The tree's nodes grow there too. This is what the setters' unused
allocators were for.

**Every change goes through one place.** `World.place(handle, pose)` is the only writer of a
body's pose, and it refits the leaf. `setPose`, `moveBodyAlone` and the two writes in
`character.zig` call it. `setShape` and `setScale` refit too. The guard is the equivalence test
below: a setter that forgets to refit fails it.

> **2026-11-10, Step 2:** the equivalence test runs 48 rounds, not 200, and a walk that would pass
> the stack falls back to the scan (its Resolution).

**The scan stays, for tests alone.** `World.scan_reference`, a test-only switch, runs the old
loop. The equivalence test builds 2,048 random bodies, then moves, reshapes, rescales, removes
and adds them over 200 rounds, and after each round asks 64 queries of every kind both ways. The
answers must be equal byte for byte.

**A stack of 64 always suffices.** A balanced tree of 2³² leaves is under 49 high, and a handle
index is 32 bits.

**Not built.** `moveBody` still walks the characters, not the tree, to find whom it pushes. A
character's own test there is a filter and a bounds check, and a world has few characters beside
its bodies. M100 owns crowds past 256, and reads this then.

## 5. A tree from outside (`physics3d`)

**Now.** `mesh.Attributes` gains `tree: ?Tree`, where `Tree` is `{ nodes: []const Node, order:
[]const u32 }` in `mesh.zig`'s own layout. With a tree, `initWith` copies it and does not build.

**A tree is untrusted** (ADR-0077). It may come from a file a mod wrote. `mesh.validateTree`
checks it in one pass over the nodes and one over the triangles, with no sort:
- between 1 and 2n − 1 nodes, for n triangles, and `order` exactly n long;
- nodes in preorder: an inner node's left child is the next node, and its right child is later
  and in range, and the walk visits every node exactly once;
- no path deeper than 31, so `candidates`' stack of 32 holds;
- a leaf holds 1 to 4 triangles, and the leaves take `order` in contiguous runs, in the order
  the walk meets them;
- `order` is a permutation of 0 to n − 1, checked with a bit a triangle;
- a leaf's box contains each of its triangles, and an inner node's box contains both children's.

A box larger than it needs to be is slow and not wrong, so containment is the whole test. A tree
that fails is refused as `InvalidMesh`, and `validateTree` says which node and why, as `validate`
does for a triangle. It is refused, not rebuilt: a file whose tree is wrong is a damaged file, and
loading it quietly would hide that.

**Any valid tree gives the same answers,** because `candidates` sorts what it finds by triangle
index. So a baked tree need not be the one `build` would make, and the test for this section
feeds a deliberately lopsided valid tree and gets the built tree's answers.

**The cost.** Building is a sort at every level. Validating is linear. Step 1 measures the
first and Step 3 the second, at the three sizes of §3. The budget is ADR-0057's: 5 ms for a
shipped level, which the hillside is.

**`mesh.buildTree`** is made public: it returns the tree `initWith` would build, for `author`.

> **2026-11-10, Step 3.** `validateTree` takes an allocator for its bit a triangle, and frees it
> before it returns. A leaf of no triangles cannot be told from an inner node, since a count of
> zero is what marks one, so it is refused as a node out of preorder. Validation measured about
> 5 ns a triangle, so a quarter-million triangles check in 1.4 ms, not ADR-0077's "nears 5 ms"
> (its Resolution).

## 6. Hull faces (`physics3d`)

**Now.** `addHull` finds the hull's faces from its points and keeps them beside the points:
- `physics3d/hull.zig` builds the hull incrementally. It starts from four extreme points, chosen
  by coordinate and then by index, and adds each other point in the order given, removing the
  faces that point sees and closing the hole from its horizon;
- a point is on a face's plane within a tolerance scaled by the hull's extent, so the eight
  corners of a box give six faces and not twelve triangles;
- faces whose planes agree within that tolerance are one face. What is kept is each face's plane:
  a unit normal and an offset. At most 508, which 256 points cannot exceed.

**The points are kept exactly as given.** GJK's support function reads the points, so no
distance, cast or depth on a hull changes by a bit. Only two things change:
- `surfaceNormal` for a hull is the normal of the face the contact point lies on that best
  agrees with the contact normal, as a box's already is;
- `earliestPair`'s rule at a box's edge, which prefers a walkable face the contact lies on,
  applies to a hull's faces too.

So a character standing at the rim of a hull is on its top and not on its edge, which is what a
person sees. This is `collision3d.md` §15's "hull faces", and its trigger was "a game stands
characters on hulls". M37's turntable is that hull.

**What may move.** The corner tour stands on the turntable, so its pin `832fe43a3a82db13` may
move, in the last bits or at the rim. Step 4 says which, with the reason. No other pin touches a
hull.

**`hull.reduce`** is public for `author`: given any points, it returns the hull's own vertices in
their first-seen order, or says there are too many or that they are flat.

> **2026-11-10, Step 4.** The hull is built in two parts, not one. First the exact hull, as
> triangles, with no tolerance but f64's own. Then triangles whose corners share a plane within
> the tolerance are gathered into faces. A single pass that used the tolerance while building
> cut corners off hulls whose points sat at the tolerance. The first corner is the lowest x, and
> the other three are each the farthest from what is already chosen. The face a contact lies on
> is found from the contact's point, which `surfaceNormal` now takes. The corner's pin held
> (its Resolution).

## 7. The records (`asset`)

**`.fcol` version 3** is version 2's layout, with its surface table and u32 per triangle always
present, followed by the tree:
- a u32 node count;
- that many 32-byte nodes: the box's minimum and maximum, then two u32s. For a leaf they are the
  first place in `order` and a count of 1 to 4. For an inner node they are the right child's
  index and zero. The left child is the next node;
- a u32 per triangle, the order.

`asset` checks what it can without memory: the counts against the file's length and the limits,
a leaf's count, and a right child in range. `physics3d` checks the rest (§5), since it is the one
that trusts it. Versions 1 and 2 read as before. `asset.CollisionMesh` gains `tree`, empty for
versions 1 and 2, and the game hands it on, as it does surfaces.

**`foundry:collision_hull`** is a new asset schema with a `.fhul` payload, version 1: the magic
`FHUL`, the version, a count of 4 to 256, bounds, and the points. No faces: `physics3d` finds
them in microseconds from at most 256 points, and a file with none cannot disagree with its
points. The reader refuses a wrong magic, an unknown version, a count out of range, a point that
is not finite or is past the coordinate limit, and trailing bytes.

**`foundry:collision_import` version 2** gains one optional field, `shape`, which is `mesh` or
`hull`, `mesh` when absent. A version 1 record reads unchanged.

> **2026-11-10, Step 6.** `asset` also checks that a leaf's run lies inside the order and that the
> order names only triangles the mesh has, each a comparison. `.fhul`'s bounds must be finite and
> ordered and hold every point, as `.fcol`'s do. `author` refuses `shape hull` by name until Step 7
> compiles it, so no hull import is compiled as a mesh in between (its Resolution).

**Nothing names a hull from a model.** `foundry:model` version 3's `collision` names a mesh. A
game that wants a hull body adds it by the hull's ID. A model that names several shapes is a
compound, and compounds are M51's, with the bodies that need them.

## 8. Closed-form pairs (`physics3d`)

**Why now.** The Mac's move sits at 0.231 ms against 0.25, and the i3's court tick has crossed
its line three milestones running. `collision3d.md` §5.1 chose one GJK for every pair, and named
the measurement that would specialise one. Step 1 takes that measurement. The three pairs below
are the ones a walking character and its probes spend their time in.

**The three routines,** in `physics3d/pairs.zig`:

| Pair | Routine | Replaces |
| --- | --- | --- |
| A point core against a triangle (a sphere) | Closest point on a triangle, by its seven regions | GJK distance |
| A segment core against a triangle (a capsule) | The least of: each end against the triangle, the segment against each edge, and zero where the segment crosses the face | GJK distance |
| A ray against a triangle | The plane crossing and the three edge tests, in one step | GJK and up to 32 advances |

**The cast is unchanged.** A sphere's or a capsule's cast against a triangle is still
conservative advancement, with the same skin, the same tolerance and the same 32 advances. Only
the distance it asks for at each advance comes from the closed form. So what a cast means, and
where it stops, is `collision3d.md` §5 as written.

**Depth is unchanged.** When cores intersect, EPA still finds the way out. That is depenetration,
it is rare, and the closed forms do not answer it.

**Everything else stays on GJK:** boxes, hulls, and any pair without a triangle. The roadmap's
line says "such as". These three are the set, and they complete the line.

**The answers move, once** (ADR-0078). GJK stops when its simplex improves by less than 1e-7 m.
The closed forms are exact to rounding. So every position a character reaches on triangles
differs in its last bits, and every digest folded from those positions changes. That is every
walking pin: the player's, the walker's, the pacer's, the strafer's, the corner's, the crowd's,
and the court's four body digests. The navigation pins are built from triangles and never from
a cast, so they hold.

**How the move is made safe:**
1. **Pair by pair.** A test draws 100,000 configurations for each routine, over the rigid poses
   `collision3d.md`'s tests use, and compares it with GJK, which stays compiled for the other
   pairs. Distances agree within 2e-6 m and witness points within 1e-4 m. Ray hits agree within
   1e-5 of the ray's length.
2. **Never through.** After every closed-form cast in that test, the shape at its stopping place
   is at least the skin less the tolerance from the triangle.
3. **Tour by tour.** Before the switch, each tour and each court ending is run with GJK and its
   position at every tick is written to scratch. After, the same run must be within 1 mm at
   every tick. A tour that leaves that band has taken a different branch somewhere, and Step 5
   finds where and says why before any pin is changed.
4. **Then re-pin,** each new value beside its old one in the Resolution.

> **2026-11-10, Step 5.** Three things here turned out otherwise (its Resolution):
> - The routines work in f64 between f32 arguments and answers. In f32 a point's place on a thin
>   triangle lost most of its digits.
> - A ray is one step only where one step can be sure. A ray that starts within the cast's
>   tolerance of the triangle, lies in its plane, or passes an edge or corner within that
>   tolerance goes to the general cast, as before.
> - Fewer pins moved than this section lists. The walker's, the pacer's three and the strafer's
>   held. The player's, the corner's and the court's four moved.

**The other choice, and why not.** The routines could be used only to skip triangles a cast
cannot reach, and leave GJK to answer. No pin would move. But the cost is in the pairs that do
answer: the triangles under a character's feet, every tick. Skipping the far ones is what the
mesh tree already does.

## 9. Compiling them (`author`)

**`author` is granted `physics3d`** (ADR-0077). It is at L4 and `physics3d` at L1, so this is a
downward grant and not a sideways one. The other way to bake a tree would be a second builder in
`asset` or `author`, and two builders drift.

**The tree is baked at 4,096 triangles and above.** A derived or proxy mesh with fewer is
written exactly as M37 wrote it, version 1 or 2, so the room's, the course's, the corner's and
the court's collision keep their bytes. Below that size a tree builds in well under a
millisecond, and a file without one is smaller. The threshold is a constant in `author`,
`collision_tree_threshold`, and Step 1's measurements may move it once, before any file is
written with it.

> **2026-11-10, Step 1: the threshold is 1,024 triangles, not 4,096.** A tree of 4,096 triangles
> takes 4.7 ms to build on the Mac, which is ADR-0057's whole budget, and not "well under a
> millisecond". At 1,024 it takes 1.9 ms. That is this note's one move. The largest
> existing collision mesh is the court's, at 132 triangles, so every file still keeps its bytes.

**A hull import.** `foundry:collision_import` with `shape hull` compiles into the
`foundry:collision_hull` of its own ID. It takes every vertex of the file's triangles, after the
import's own transform, and keeps the hull's vertices (`hull.reduce`). It refuses, by name:
- `HullTooManyPoints`, when more than 256 vertices are on the hull. The author makes a simpler
  shape, and the diagnostic says how many there were;
- `HullFlat`, when the points span less than `min_hull_volume`;
- `surfaces` or `one_sided` on a hull import, which have no meaning for one.

> **2026-11-11, Step 7.** The vertices are those a triangle uses, degenerate triangles included,
> and not every vertex the file holds. `HullFlat` is refused twice: when `hull` finds the points
> flat for their size, and when the corners span less than `min_hull_volume`, so a hull that
> compiles is one `World.addHull` takes. `hull.cornersOf` is `reduce` without the limit, so the
> diagnostic can count. A model naming a hull as its collision is refused as a hull, by name. The
> twice-compiled test uses a grid and a cube of `author`'s own; the hillside and the boulder are
> Step 9's (its Resolution).

**Output depends on the source bytes alone,** as ADR-0055 requires, and a test compiles the
hillside and the boulder twice and compares the bytes. Step 11 compares them across machines.

## 10. The physics panel (`debug`)

**`debug` is granted `physics3d`,** for `Report` and nothing else, as it was granted `nav` at M33.
This is the owner's decision, which `collision3d.md` §15 reserved, and accepting §17 makes it.
`CLAUDE.md` §4.3's line for `debug` keeps "no `physics2d`".

**`Sources.physics: ?*const physics3d.Report`.** A game fills it. The panel, `physics`, prints
the counts, the broadphase's size and height, the tick's queries by kind, how many bodies and
triangles they tested, the split between closed-form pairs and GJK, and the game's move timing.
With no report it says so, as the navigation panel does. It has no write path, and it reads a
value any mod could be handed (ADR-0025).

**Not a view of the shapes.** The panel is numbers. Nothing in this milestone draws collision
shapes in the world.

## 11. `sandbox3d`: the yard

**Where.** East of the room, at `origin` (40, 0, 0), reached by walking and off every tour path.
It is in the walk world's own list and is not a navigation source or a prop, as M37's corner is
not, so no navigation pin moves. Every pose is turned by the walk's frame, so the tilted tour
turns the yard too.

**What.**
- **The hillside** is `models/yard.gltf`, written by `scripts/m38/make_yard.py`: a 127 by 127
  grid of quads, 32,258 triangles, rolling by a sum of sines, with no clock and no `random`. Its
  import derives its collision, which passes the threshold and is baked.
- **The stones** are 2,048 static bodies on a 64 by 32 grid, set on the hillside by the same
  function the script uses. Three in four are boxes. One in four is a hull, the boulder's, at one
  of four scales. They are drawn as one runtime mesh, built once (ADR-0063).
- **The movers** are 64 kinematic boxes on circles among the stones, moved by `moveBody` each
  tick before the player, in `collision-extras.md` §13's order.
- **The boulder** is `models/boulder.gltf` and a `foundry:collision_import` with `shape hull`. One
  stands by the yard's gate, large enough to walk onto, with a face tilted 20°.
- **`sandbox3d:yard.main`** is the record that sets the counts and the place, so a mod can thin
  the yard or move it.

**The tour's stage.** The player walks in at the gate, crosses the hillside between stones, is
turned aside by a mover, steps onto the boulder's tilted face and stops. The stage checks:
- the ground under the player on the boulder reports the face's normal, 20° from up, within
  0.01°, and is walkable;
- the player never passes through a stone or a mover;
- the report says 2,100 or more bodies, one baked mesh, and at least one closed-form pair and one
  GJK pair that tick;
- the stage's digest, new, is pinned.

**The overlay** hands the report to the panel. The sample logs the hillside's `addMesh` at load
against 5 ms, and the same mesh built without its tree beside it, once.

## 12. The court

Nothing in its content changes, and nothing in its code but one line that hands a report to the
overlay. Its two characters walk on triangles, so its four body digests move at Step 5 and are
re-pinned there, inside the 1 mm band: `win`, `caught`, `fell` and the ten-minute `soundtrack`.
A footstep that lands a tick earlier or later than before is a branch, and Step 5 reports it.

The owner plays it at Step 10. The question is only whether it feels the same.

## 13. Platform assessment and the public ABI

**Nothing here is platform-specific.** `physics3d` is `core` alone, and the file formats are
little-endian by `asset`'s own check. Metal and Vulkan see one more model and one more runtime
mesh.

**The Windows PC is needed once,** at Step 11, for three things a Mac cannot say: the budgets on
the i3, that `.fcol` version 3 and `.fhul` have the same bytes there, and whether the new pins
hold on x86_64. Every pin so far has been equal on both. ADR-0013 does not promise that, and if
one differs Step 11 finds why before recording two values.

**Linux is not run.** Nothing changes that is Linux-specific (3d.md §10.2).

**The public table gains nothing.** v6's bodies get the broadphase underneath, unseen. M48's
line already holds "hull and mesh shapes and contacts for mod bodies", and at the close it gains
hulls by content ID and the physics report.

## 14. Verification, pins and budgets

**`physics3d`:**
- **Report:** the counts match a world built by hand, and `takeCounters` zeroes.
- **Broadphase:** §4's equivalence test. Its height stays under the bound through 4,096 inserts
  in sorted order, the worst case for an unbalanced tree. A kinematic body moved inside its
  margin does not refit, and one moved past it does. Removing every body leaves an empty tree.
- **A tree from outside:** the built tree passes `validateTree`, and so does a lopsided valid
  one, with equal answers. Each refusal of §5 is its own test: a node count out of range, a child
  out of range, a node visited twice, a path of depth 32, a leaf of zero or five, a run out of
  order, a repeated triangle, a leaf box that misses a triangle, a parent box that misses a child.
- **Hull faces:** a box's corners give six faces. A tetrahedron, an octahedron and a 16-sided
  rim give theirs. Points inside the hull change nothing. A character on a hull ramp reports the
  face. The same points in the same order give the same faces twice.
- **Closed-form pairs:** §8's three tests.
- **Determinism:** two worlds stepping the same 1,200 ticks of the yard are equal byte for byte.

**`asset` and `author`:**
- `.fcol` versions 1 and 2 read unchanged, and version 3 round-trips;
- `.fhul` round-trips, and each refusal of §7 is named;
- `collision_import` version 1 reads under version 2;
- a mesh under the threshold keeps M37's bytes, and one at it gains a tree that `validateTree`
  passes;
- each refusal of §9 is named, and compiling twice gives the same bytes.

**`debug`:** the panel with no report, with an empty world's, and with the yard's.

**The samples:** the yard's stage passes and is pinned, the tilted tour matches the upright one,
and the navigation pins hold.

**Budgets, p95 in the paced 60 Hz loop at ReleaseSafe, on the Mac and the i3:**

| What | Budget |
| --- | --- |
| The player's move in the yard, 2,100 bodies | 0.25 ms, M23's |
| The 64 movers' `moveBody`, together | 0.10 ms |
| `addMesh` of the hillside with its baked tree | 5 ms, ADR-0057's |
| The court's whole game tick | 0.25 ms |

A reading over its line goes in the step's Resolution and to M100, as before. The move under the
scan, the hillside built at load, and a move with GJK alone are each recorded beside the reading
that replaced them, so the Resolutions say what each item bought.

**Guards verified by mutation,** each named in its step's Resolution: a setter that does not
refit, the sort of body indices, the depth bound, the permutation check, a leaf's containment,
the hull's coplanar tolerance, the segment-crosses-face case, and the bake threshold.

## 15. Implementation order — twelve bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `physics3d`: the `Report`, and the measurements
§3. The counters and `report()`, and the three baseline readings, taken on the Mac from a
scratch harness and written into the Resolution. Confirms or moves the hillside's size and the
bake threshold. **Exit:** the report's test passes, and the three readings are recorded.

### Step 2 — `physics3d`: the broadphase
§4. `broadphase.zig`, `World.place`, the scratch, and the test-only scan. **Exit:** the
equivalence test passes, and every existing pin holds.

### Step 3 — `physics3d`: a tree from outside
§5. `Attributes.tree`, `validateTree`, `buildTree`. **Exit:** a valid tree answers as the built
one, every malformed tree is refused by name, and validation's cost is recorded at three sizes.

### Step 4 — `physics3d`: hull faces
§6. `hull.zig`, faces kept by `addHull`, `surfaceNormal`, the edge rule, `hull.reduce`.
**Exit:** a character on a hull ramp reports the face, and the corner's pin holds or is re-pinned
with its reason.

### Step 5 — `physics3d`: closed-form pairs
§8. `pairs.zig`, the dispatch in `narrow.zig`, the three tests, the tour comparison, the re-pin.
**Exit:** every routine agrees with GJK within §8's tolerances, every tour is within 1 mm at
every tick, and each moved pin is recorded old and new.

### Step 6 — `asset`: `.fcol` version 3, `foundry:collision_hull`, `collision_import` version 2
§7. **Exit:** all three round-trip, older versions read unchanged, and every refusal is named.

### Step 7 — `author`: bake the tree, compile a hull
§9, with the `physics3d` grant in `build.zig`. **Exit:** a mesh at the threshold carries a valid
tree, one under it keeps its bytes, and a hull import compiles or is refused by name.

### Step 8 — `debug`: the physics panel
§10, with the `physics3d` grant. **Exit:** the panel prints a report, and says so when it has
none.

### Step 9 — `sandbox3d`: the yard
§11. The script, the models, the record, the stage, and the budgets read on Metal from a
relocated install. **Exit:** the stage passes and is pinned, the tilted tour matches, and the
four budgets are read.

### Step 10 — The court
§12. The report to the overlay, the tick read from a relocated install, and the owner's play.
**Exit:** the digests re-pinned at Step 5 hold in the relocated court, and the owner has played it.

### Step 11 — Windows/Vulkan
§13. From a fresh clone on the owner's PC, at `-j2` and below normal: the suites, the pins, the
bytes of the hillside's `.fcol` and the boulder's `.fhul`, the windowed tours and the court's
endings, and the budgets on the i3. **Exit:** every run passes, with validation clean.

### Step 12 — Close M38
Resolve each discrepancy in its own document:
- `collision3d.md` §15: strike the five rows with what was built, and §5.1's "one algorithm" and
  §6's "no broadphase yet" each gain a dated note;
- ADR-0051's third revisit and ADR-0057's second gain dated notes naming ADR-0077 and ADR-0078;
- `debug-overlay.md` gains the panel and the grant;
- `collision-extras.md` §18's M38 row is marked done.

Move ADR-0077 and ADR-0078 to implemented and into `CLAUDE.md` §4.1. Update its §4.3 for
`physics3d`, `asset`, `author` and `debug`, and §9's row. Update `AGENTS.md`'s costs and scripts,
the roadmap (M38 complete; M48 gains hulls by ID and the report, M51 compounds and pair finding
over the tree, M60 collision loaded in pieces, M100 `moveBody` through the tree), the design index, the README,
`docs/modding/content-mods.md` for hull imports and baked trees, and `PROJECT_STATE.md`. Remove
the PC's clone by exact name. Tag `m38`, push when asked, and stop before M39's design.
**Exit:** every document names M38 complete, and nothing it took on is open.

## 16. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| Pair finding between bodies, contacts, compounds of several shapes | M51 | Dynamics I. §4's tree is what it will walk |
| Heightfield collision | M63 | Terrain II |
| Collision streamed in pieces, for a level past a quarter-million triangles | M60 | Where a level outgrows one load, as `navigation.md` §13 says of its mesh |
| `moveBody` finding characters through the tree; crowds past 256 | M100 | §4 |
| All of this in the public table, and in Lua | M48, M49 | §13 |

## 17. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | Step 1 measures the present code before anything changes, and may move the hillside's size and the bake threshold once | §3 |
| 2 | `physics3d.Report` is a value the world fills and the game hands on; its counters are not simulation state | §3 |
| 3 | The broadphase is one balanced bounding-volume tree over all bodies, kinematic boxes padded by 0.1 m; not a spatial hash | §4, ADR-0077 |
| 4 | A structure never decides an answer: candidates are sorted by handle, then tested as today, correcting `collision3d.md` §6's "no broadphase yet" | §4, ADR-0077 |
| 5 | A tree from outside is validated in linear time and refused, not rebuilt, when wrong; any valid tree gives the same answers | §5, ADR-0077 |
| 6 | Hull faces are found by `physics3d` from the points, which are kept as given; a hull's surface normal becomes its face's, and the corner's pin may move | §6, ADR-0078 |
| 7 | `.fcol` version 3 appends the tree; `foundry:collision_hull` and `.fhul` hold points alone; `collision_import` version 2 gains `shape` | §7, ADR-0078 |
| 8 | Three closed-form pairs, ray, sphere and capsule against a triangle, replace GJK for those pairs; the cast and depth are unchanged, correcting `collision3d.md` §5.1's "one algorithm" | §8, ADR-0078 |
| 9 | **Every walking pin and the court's four body digests move once,** at Step 5, after each tour stays within 1 mm of its GJK run at every tick | §8, ADR-0078 |
| 10 | `author` is granted `physics3d`, so one builder makes every tree | §9, ADR-0077 |
| 11 | A tree is baked at 4,096 triangles and above, so every existing collision file keeps its bytes. (1,024 since Step 1, by choice 1) | §9 |
| 12 | `debug` is granted `physics3d`, for `Report` alone; the panel is numbers, with no view of shapes | §10 |
| 13 | The yard is new, off every tour path and not a navigation source; its hillside's glTF, about 0.4 MB, is committed | §11 |
| 14 | The court changes one line; the owner plays it at Step 10 | §12 |
| 15 | Nothing enters the public table; M48's line gains hulls by ID and the report at the close | §13 |
| 16 | Twelve steps, the Windows PC once at Step 11 | §15 |

Choice 9 is the one with the widest reach. Its alternative, in §8, keeps every pin and leaves
the cost where it is.

Nothing blocks Step 1 once these are accepted.

## Resolution — Step 1: the `Report`, and the measurements (2026-11-10)

**Acceptance.** The owner asked for Step 1 on 2026-11-10, which accepts §17 as written. ADR-0077
and ADR-0078 are Accepted, and both are in `CLAUDE.md` §4.1.

**What the step added.**
- `physics3d/report.zig`: `QueryKind`, `Counters` and `Report`, exported from the module's root.
- `World.counters`, `World.report()`, `World.takeCounters()` and `World.counted()`.
- Every query counts itself by kind once it has passed validation, so a refused query counts
  nothing. Every body loop counts a visit, `candidate` counts an exact bounds test after the
  filter, and every narrowphase call counts a pair, and a triangle when the part is one.
- `Report.withCounters` puts counters a game took itself back into a report. The design had
  `report()` fill the counts and `takeCounters()` return the rest, and did not say how the two
  meet. `report()` copies the counters as they stand and takes nothing.

**Where the code sharpened the design.**
- **`bodies_visited` is bodies under the scan and will be nodes under the tree.** §3 called it
  "broadphase nodes walked". Until Step 2 there are no nodes, so it counts every live body a
  query passes. Step 2 changes what it counts, and its drop is the broadphase's proof.
- **`tree_nodes`, `tree_height`, `meshes_baked`, `hull_faces`, `pairs_closed` and `refits` are in
  the value now and stay zero** until Steps 2 to 5 fill them, so the report's shape does not
  change under the panel.
- **`triangles` is a u64,** since a world may hold many meshes of up to 1,048,576 triangles.
- **`moveBody`'s own overlap test** counts bodies tested and pairs, and no visit, since it
  walks no bodies.

**The measurements.** Mac, ReleaseSafe, unpaced, from a harness in scratch that was not
committed. The world is the yard's shape: a 96 m hillside of 32,258 triangles, 2,048 static
boxes 1.5 m apart, 64 kinematic boxes circling, and one character walking a 32 m circle through
them for 6,000 ticks.

| What | Reading |
| --- | --- |
| A move with 12 bodies | median 0.012 ms, p95 0.020 ms |
| A move with 2,114 bodies, under the scan | median **0.357 ms**, p95 0.371 ms |
| Bodies visited in that move | 17,940, of which 17,931 had their bounds tested |
| Narrowphase in that move | 0.026 ms, 171 pairs, 164 of them triangles |
| GJK on triangles, of a move with 12 bodies | 0.009 of 0.013 ms, about **70%** |
| The 64 movers' `moveBody`, together | median 0.0026 ms |
| `addMesh`, 1,024 triangles | 1.9 ms |
| `addMesh`, 4,096 triangles | 4.7 ms |
| `addMesh`, 32,768 triangles | 60.5 ms |
| `addMesh`, 262,144 triangles | 737 ms |
| Copying 262,144 triangles, with no tree | 0.27 ms |

**What they say.**
- **The scan is the cost at scale.** At 2,114 bodies a move is over M23's 0.25 ms before any
  pacing, and 93% of it is walking bodies and computing their bounds: about 18 ns a body, nearly
  nine passes a move. The narrowphase is 7%. This is the broadphase's trigger, fired.
- **GJK on triangles is the cost of a move in a small world,** about 70% of it. This is
  `collision3d.md` §15's trigger for specialised pairs, read directly.
- **The tree's build is far slower than this design assumed.** It is about 1.9 µs a triangle, and
  `validate` is under 1% of it. So ADR-0057's 5 ms is crossed near 4,300 triangles on the Mac,
  and the hillside's 32,258 would take 60 ms at load. The hillside's size stands.
- **The bake threshold moves to 1,024 triangles** (§9's note), the one move choice 1 allows.
  The samples' collision meshes hold 24 to 132 triangles, so none gains a tree.
- **The 64 movers cost almost nothing,** 0.003 ms against a budget of 0.10, because `moveBody`
  walks characters and not bodies.
- **Paced readings will be higher.** M23 found the paced p95 about three times the unpaced one,
  and the budgets of §14 are read paced, at Step 9.

**The harness's timing of GJK** wrapped `narrow.separation` and `narrow.cast` in a scratch copy
of the module, with a clock read at about 14 ns a pair, which the 70% allows for.

**One observation, acted on by nothing here.** The builder's sort computes two centroids at
every comparison. A builder that computed them once would make the same tree faster. Baking
moves the build to compile time, where 60 ms is nothing, so this design does not need it.

**Guards verified by mutation,** each failing a test in `report_tests.zig`: `takeCounters` that
does not zero, a bounds test counted before the filter, every pair counted as a triangle, and a
move not counted.

**Tests.** Five new, in `report.zig` and `report_tests.zig`: the counts against a world built by
hand, each query counted by kind with the bodies and triangles it tested, a refused query
counting nothing, taking the counters, and that counting changes no answer.

**Bar.** `zig build test` 2,923/2,933 (ten skips), 132/132 steps, five new tests. The format
check, the four `check` variants, the four headless samples and `fdt-check` pass. No pin moved,
no ABI change, no new grant yet: `author`'s is Step 7's and `debug`'s is Step 8's.

## Resolution — Step 2: the broadphase (2026-11-10)

**What the step added.**
- `physics3d/broadphase.zig`: `Tree`, a bounding-volume tree with `reserve`, `insert`, `remove`,
  `update`, `query` and a `consistent` check for tests. Insertion descends by least surface
  growth, the left child on a tie, and rotations on the way back up keep it balanced.
- `World.tree`, `World.leaf_of` (each body's leaf, by handle index) and `World.body_scratch`.
- `World.place`, the one writer of a body's pose. `setPose`, `moveBodyAlone` and the
  controller's two writes call it.
- `World.near(area)`, which every query loop now walks in place of the bodies' iterator.
- `World.scan_reference`, the test-only switch.
- `core.HandlePool.entryAt(index)`, which turns a slot index back into an entry.
- `Report.tree_nodes`, `tree_height` and `refits` are filled.

**Where the code sharpened the design.**
- **A walk that would pass its stack falls back to the scan.** §4 argued that a stack of 64
  always suffices. It does for a balanced tree, but nothing should panic if that is ever wrong.
  `Tree.query` returns null in that case, and the world scans every body for that one query. A
  test builds a chain deeper than the stack by hand and gets the null.
- **Everything the tree needs is reserved in `addBody`, before the body exists.** So nothing
  after the pool's `add` can fail, and `place`, `removeBody` and the setters allocate nothing.
  Moving a leaf frees one inner node and takes it back.
- **`refit` decides by kind.** A kinematic body stays put while its bounds are inside its box. A
  static body's box is exactly its bounds, so any real move refits it and a `setPose` to the same
  pose does not.
- **`setKind` refits too.** A body made static gives up its margin at once. One made kinematic
  keeps its exact box until it moves out of it. Neither is needed for a right answer, since a
  loose box is only slow, so the equivalence test cannot see it. A counter test holds it.
- **`bodies_visited` now counts nodes walked,** as Step 1's Resolution said it would. Under
  `scan_reference` it still counts bodies.
- **The equivalence test runs 48 rounds, not §4's 200.** At 200 the scanning world took 86 s in a
  Debug build, which every run of the bar would pay. At 48 the whole physics suite takes about 20 s, and the test asks 3,072
  questions of each of the five kinds, plus 192 character moves, and every guard below that 200
  rounds caught, 48 catch.
- **The test is two worlds, not one world asked twice.** Each call is made of both, one through
  the tree and one by scan, so the controller's own queries and `moveBody`'s pushes are compared
  too, through the characters' moves.

**The tree's height.** After 4,096 inserts in sorted order it is at most 19, the bound of §4.
After the equivalence test's churn of about 2,400 bodies it is at most 18.

**Measured,** with Step 1's harness on the Mac, ReleaseSafe, unpaced:

| What | Scan (Step 1) | Tree |
| --- | --- | --- |
| A move with 2,114 bodies, median | 0.357 ms | **0.030 ms** |
| The same, p95 | 0.371 ms | 0.042 ms |
| Bodies or nodes visited in that move | 17,940 | 668 |
| Bodies whose bounds were tested | 17,931 | 16 |
| A move with 12 bodies, median | 0.0120 ms | 0.0118 ms |
| The 64 movers' `moveBody`, median | 0.0026 ms | 0.0070 ms |

The walk ends at the same place to the last digit printed, and counts the same 171.4 pairs a
move. The movers cost more than before because each now refits its leaf when it leaves its
margin, and are still a fourteenth of their 0.10 ms budget.

**Every pin holds.** The player's `cb99ccfcf2b6d6c3`, the walker's `655e865f98779129`, the
pacer's three, the corner's `832fe43a3a82db13`, and the court's four digests in `court-test`.

**Guards verified by mutation,** each failing the equivalence test, and most failing others too:
- `place` that does not refit;
- `setScale` and `setShape` that do not refit;
- a kinematic body that never leaves its box;
- the sort of body indices removed, which also failed `ties go to the lower handle index`;
- `removeBody` that leaves its leaf;
- the tree's rotation disabled, which also failed the height bound.

`setKind` without its refit failed only the counter test added for it.

**Tests.** Eight new: five in `broadphase.zig` (an empty tree and one leaf, ascending output,
balance under sorted inserts, churn against a pass over every box, and the stack's refusal) and
three in `broadphase_tests.zig` (the equivalence test, the margin and the kind change, and
emptying and refilling a world). Step 1's report tests now expect the tree's counts.

**Bar.** `zig build test` 2,931/2,941 (ten skips), 132/132 steps. The format check, the four
`check` variants, the four headless samples and `fdt-check` pass. No ABI change, no new grant.

## Resolution — Step 3: a tree from outside (2026-11-10)

**What the step added,** all in `physics3d/mesh.zig`:
- `Tree { nodes, order }`, a mesh's tree as a borrowed value, and `Tree.height`.
- `Attributes.tree: ?Tree`. With one, `Mesh.initWith` checks it, copies it and builds nothing.
  A tree that fails refuses the mesh as `InvalidMesh`. It is never rebuilt.
- `validateTree(gpa, positions, indices, tree)`, which answers `TreeValidation { valid, fault,
  node }`. `TreeFault` names twelve reasons: `mesh`, `node_count`, `order_length`, `child`,
  `preorder`, `depth`, `leaf_size`, `run`, `triangle`, `repeated`, `leaf_bounds` and
  `parent_bounds`.
- `buildTree(gpa, positions, indices)`, which returns an owned `Built`. `Mesh.init` now builds
  through the same routine, so the two cannot differ.
- `max_depth`, 31: one less than `candidates`' stack.
- `Mesh.baked` and `Mesh.tree()`. `Report.meshes_baked` is filled.
- `physics3d.MeshTree` names `Tree` at the module's root.

**How it checks.** One pass over the nodes in the order they are stored, which a valid tree
makes the order of the walk. A stack of at most 31 entries holds each right child the walk still
owes, with its parent and depth. At a leaf the next node must be the child owed. That one test
refuses a node named twice, a node skipped and nodes left over. Each leaf's run must start where
the last ended, so the leaves cover `order` once, and a bit a triangle refuses a repeat.

**Where the code sharpened the design.**
- **`validateTree` takes an allocator.** §5 said "a bit a triangle" and not where it lives. It
  is 128 KB at the largest mesh, allocated and freed inside the call.
- **A leaf of zero is refused as `preorder`, not `leaf_size`.** A count of zero is what marks an
  inner node in `mesh.zig`'s layout, so such a node is an inner one whose left child is wrong.
- **`parent_bounds` names the child.** Either box could be the wrong one. The child is where
  the walk finds it.
- **A NaN in a box refuses the tree,** because every comparison of containment must hold. An
  infinite box is valid: it is only slow.
- **`Mesh.node_count` is gone.** `nodes` is now exactly as long as the tree. A built mesh
  gives back the unused half of its node array.
- **Validation is cheaper than ADR-0077 guessed.** Its consequences say the check alone nears
  5 ms past a quarter-million triangles. It measured 1.4 ms there. The ADR stands as written,
  since code depends on it now. The number is corrected here and in §5.

**Measured** on the Mac, ReleaseSafe, unpaced, the median of seven, on Step 1's bumpy grids:

| Triangles | Nodes | Height | `validateTree` | `addMesh` with its tree | `addMesh` building |
| --- | --- | --- | --- | --- | --- |
| 1,024 | 511 | 8 | 0.007 ms | 0.008 ms | 0.77 ms |
| 4,096 | 2,047 | 10 | 0.021 ms | 0.032 ms | 4.7 ms |
| 32,768 | 16,383 | 13 | 0.173 ms | **0.275 ms** | 60.3 ms |
| 262,144 | 131,071 | 16 | 1.40 ms | 2.20 ms | 731 ms |

So the hillside, at 32,768 triangles, loads in 0.28 ms against ADR-0057's 5 ms, where building
it took 60 ms. A mesh of a quarter-million triangles loads inside the budget too.

The harness was run twice. The table is the second run. The first read the two small sizes
slower: 0.020 ms to validate and 1.86 ms to build at 1,024 triangles, and 0.030 ms and 6.2 ms at
4,096. The two large sizes agreed within one percent. Step 1's 1.9 ms at 1,024 matches the
first run, so a small build varies between about 0.8 and 1.9 ms from run to run.

**Any valid tree gives the same answers.** A chain of 32 leaves, each inner node's left child a
leaf, over 112 shuffled triangles with boxes a quarter-metre loose, puts its deepest node at
depth 31. A world holding it and a world holding the built tree answered 400 rays, 400 casts and
400 contact queries equally, byte for byte, on a rotated and scaled body.

**No pin moved.** The 2,400-frame tour printed the player's `cb99ccfcf2b6d6c3`, the walker's
`655e865f98779129`, the pacer's three and the corner's `832fe43a3a82db13`, and `court-test`
passed with the court's four digests.

**Guards verified by mutation,** each failing a test in `tree_tests.zig`:
- the depth bound, raised by one;
- the repeat check removed, which is the permutation check;
- a leaf's containment removed;
- a parent's containment removed;
- the run's start unchecked, and its length unchecked, which crashed;
- the pop's check removed, and the left child's;
- each half of the right child's range check;
- the leaf's size unchecked;
- the tree accepted without validation, which failed six tests.

**Tests.** Nine new, in `physics3d/tree_tests.zig`: the built tree is valid, equal to a mesh's
and accepted back; the lopsided tree's answers; a path of depth 32; wrong counts; children out
of range, a node named twice and nodes left over; leaves of five and of none and runs out of
place; a triangle repeated or not in the mesh; boxes that miss what is under them; and every
allocation failure on the three paths.

**The bar.** `zig build test` passed 2,940 of 2,950 tests (ten skips) in 132 of 132 steps. The four
checks, the four headless samples and `fdt-check` passed.

## Resolution — Step 4: hull faces (2026-11-10)

**What the step added.**
- `physics3d/hull.zig`: `Plane { normal, offset }`, `faces(gpa, points)`, which returns each
  face's plane with the largest face first, and `reduce(gpa, points)`, which returns the points
  that are corners of the hull in the order they were given. `max_faces` is 508.
- `World.addHull` finds the faces and keeps them beside the points. `World.hullFaces(handle)`
  lends them. `removeHull` and `deinit` free them. `Report.hull_faces` is filled.
- `shape.Convex.faces`, borrowed like a hull's points, and `Convex.face(index, point)`, which
  gives one face's world normal and how far over it a world point is, the body's scale applied.
- `Convex.surfaceNormal` takes the contact's point as well as its normal. For a hull it answers
  the face the point lies on that best agrees with the contact normal. Only a hull reads the
  point, so a box and a triangle answer as before.
- `earliestPair`'s rule at a box's edge is repeated for a hull's faces.
- `physics3d.HullPlane` names `Plane` at the module's root.

**The points are untouched.** GJK reads them and nothing else. A test asks 300 distances and
300 casts of a hull with its faces and of the same points without, and compares the bytes.

**Where the code sharpened the design.**
- **The hull is built in two parts.** §6 described one pass with a tolerance. Built that way, a
  hull whose points sat at about the tolerance from a plane lost corners: a point taken as on a
  face removed that face, and with it a vertex that was really outside the new one. The random
  test found it in its first run. Now the hull is built exactly, in f64, measured from the
  points' low corner so that distance from the origin costs nothing. A point is on a plane only
  within 1e-10 of the hull's diagonal, which is f64's rounding and not a judgement. Then
  triangles are gathered into faces: the largest triangle not yet in a face starts one, and
  takes each triangle reached across an edge whose three corners are within the tolerance of
  its plane. Gathering only labels triangles. It cannot open the surface.
- **The tolerance** is 1e-5 of the hull's diagonal, and never less than 8 f32 roundings at the
  hull's farthest coordinate. The second term is what makes a turned box 8 km from its origin
  six faces, where its corners were rounded by half a millimetre.
- **A new triangle exactly on its neighbour's plane takes that plane.** A point in line with an
  edge makes a triangle of no area, which has no plane of its own.
- **A hull too flat for faces has none, and is still a hull.** `addHull` accepts what it did
  before. A sheet 100 m wide and 0.1 mm thick collides by its points and reports the contact
  normal, as every hull did until now. `reduce` says `Flat` for it.
- **`reduce` has a fourth answer, `Tangled`,** for a hull whose surface does not close after
  building. No input is known to produce it: 1,500 random hulls, a third of them on a lattice
  and two sevenths shaken at the tolerance, never did. `faces` treats it as flat.
- **A corner is where three faces meet.** A point two faces share is along an edge, and a point
  one face holds is inside it. Neither is returned by `reduce`.
- **`surfaceNormal` needs the contact's point.** A contact normal alone can agree best with a
  face the contact is nowhere near. A face is "on" when it is within 1e-5 m of the highest face
  at that point, so a point a little off the surface is still told its nearest face.

**The corner's pin held.** §6 said it might move. The 2,400-frame tour printed
`832fe43a3a82db13` for the corner, which stands on the turntable's hull, and the player's
`cb99ccfcf2b6d6c3`, the walker's `655e865f98779129` and the pacer's three beside it.
`court-test` passed with the court's four digests. No pin moved.

**A hull against a box.** A slab as a box, and the same slab as a cube's corners scaled to it,
were given a character at fifteen places from just inside the rim to 0.26 m past it, upright and
turned. The two agreed at every place on whether it was grounded, on its feet within 0.1 mm and
on the face normal within 2e-6. Past 0.21 m the contact's own normal is steeper than the slope
limit, and both say the character stands on the top.

**Measured** on the Mac, ReleaseSafe, the median of seven:

| Points | Faces | `addHull` |
| --- | --- | --- |
| 8, on a sphere | 12 | 0.002 ms |
| 32, on a sphere | 60 | 0.02 ms |
| 64, on a sphere | 124 | 0.07 ms |
| 256, on a sphere | 506 | 0.75 to 1.0 ms |
| 256, in a ball | 78 | 0.06 to 0.10 ms |

A hit on a hull now walks its faces twice. That was not measured on its own: no sample holds a
hull of more than a few dozen faces until Step 9's boulder, whose budget reading will include it.

**Guards verified by mutation,** each failing a test:
- the gathering measured against the neighbour's plane and not the first triangle's;
- a new triangle on its neighbour's plane given its own plane;
- the building done with the gathering's tolerance, which is §6's single pass;
- the first tetrahedron's winding;
- the largest triangle starting a face;
- a corner counted at one face and not three;
- the plane's offset left measured from the low corner;
- the tolerance at 1e-9 and at 1e-2, and without its f32 term;
- `surfaceNormal` choosing among every face, and breaking a tie to the last;
- the scale left out of a face's normal;
- the edge rule removed, taking a face the contact is not on, and taking one that is not
  walkable;
- `addHull` keeping no faces.

**Tests.** Thirteen new. Six in `hull.zig`: a box in any order with points inside it; a turned
box, far away and with coarse corners; a tetrahedron, an octahedron and a drum; 1,500 random
hulls; flat points and too many corners; and allocation failures. Seven in `hull_tests.zig`: the
ramp; the rim against a box; a scaled hull and a flat one; the face the contact lies on; the
witness on the walkable face; the unchanged distances and casts; and a hull's faces living and
dying with it.

**The bar.** `zig build test` passed 2,953 of 2,963 tests (ten skips) in 132 of 132 steps. The four
checks, the four headless samples and `fdt-check` passed.

## Resolution — Step 5: closed-form pairs (2026-11-10)

**What the step added.**
- `physics3d/pairs.zig`: `pointTriangle`, by the triangle's seven regions; `segmentTriangle`,
  the least of each end against the triangle and the segment against each edge, and zero where
  the segment passes through the face; and `rayTriangle`, three edge tests and the plane.
- `physics3d/wide.zig`: `D3`, three f64s, which `pairs.zig` and `hull.zig` now share.
- `narrow.separation` measures a point core or a segment core against a triangle by those
  routines while the cores are apart, and `narrow.cast` answers a ray against a triangle in one
  step. `narrow.separationGeneral` and `narrow.castGeneral` are GJK for any pair, as before,
  and the tests' reference. `narrow.closedPair` says which route a pair takes.
- `Report.pairs_closed` is filled. `World`'s query logic is otherwise as it was.

**What did not change.** A cast is still conservative advancement to the same skin, tolerance
and 32 advances. When cores are within GJK's `intersect_distance` they meet, and the pair goes
to GJK and EPA on both routes, so depth is EPA's. Boxes, hulls and pairs without a triangle
never leave GJK.

**Where the code sharpened the design.**
- **The routines work in f64.** Their arguments and answers are f32. In f32 the comparison
  with GJK found witness points wrong by up to millimetres on a thin triangle far from the
  query, since a point's place on a triangle is a difference of products. In f64 the distances
  agree with GJK within 1e-6 m over 200,000 configurations.
- **A ray is one step only where one step can be sure.** The edge tests are exact negatives
  across a shared edge, so no ray passes between two triangles along a seam. At a corner
  several edges meet and each test's sign is rounding, and a first version let a ray aimed
  exactly at a corner through. Now a ray that passes an edge by less than the cast's tolerance,
  lies in the triangle's plane, or starts within the tolerance of it, is not called by one
  step: it goes to the general cast, which hits what a ray comes within 1e-5 m of, as it always
  did. 12,000 rays at the corners and seams of a closed ball of triangles, near and 1.5 km out,
  each hit it.
- **A ray's hit point is on the triangle.** It is the triangle's corners weighed by the edge
  tests, so a hit on a level floor is at the floor's height exactly, as GJK's witness was. The
  court's foot placement tests for that.
- **The contact normal over a face is the face's own,** the same bits as the hit's surface
  normal. Elsewhere it is the unit way between the two nearest points, found in f64.

**The general cast loses real ray hits, and the closed form does not.** This was found, not
looked for. A ray has no radius, so near a face GJK's normal comes from two points a rounding
apart. An advance that lands a few hundredths of a millimetre past the face then reads as
moving away, and the cast reports no hit. Over 100,000 random rays and triangles:

| What | Rays |
| --- | --- |
| Hits both casts report, in all three frames | 43,515 |
| Real crossings the general cast missed, within 10 m of the origin | 73 |
| Real crossings the general cast missed, 1.5 km from the origin | 14,257 |
| Hits the general cast alone reports, a rim grazed within its tolerance | 2 |

Each missed crossing was confirmed by measuring the ray as a segment against the triangle, a
different route from the ray's own. A third of the rays are in each frame. So before this step
a raycast near the origin could pass through a triangle about once in five hundred hits, and
1.5 km out it missed most of them. The samples' worlds are within tens of metres.

**Measured** on the Mac, ReleaseSafe, unpaced, with Step 1's harness:

| What | GJK alone (Step 2) | Closed forms |
| --- | --- | --- |
| A move with 12 bodies, median | 0.0118 ms | **0.0068 ms** |
| The same, p95 | 0.0201 ms | 0.0111 ms |
| A move with 2,114 bodies, median | 0.0300 ms | **0.0173 ms** |
| The same, p95 | 0.0420 ms | 0.0232 ms |
| Pairs sent to GJK in a move, 12 bodies | 74.9 | 0.3 |
| The same, 2,114 bodies | 171.4 | 7.8 |

The walks end within a centimetre of where they did. The paced budgets are read at Steps 9
to 11.

**The three tests of §8.**
1. *Pair by pair.* 100,000 points and 100,000 segments against triangles, in the three frames
   `collision3d.md`'s mesh tests use. Every distance agrees with GJK within 2e-6 m, plus what
   f32 holds at the frame's distance. The worst was 9.5e-7 m. Witness points agree within
   1e-4 m in 99,987 of 100,000 for a point and 99,253 of 99,265 for a segment. The rest are
   GJK's own: its tolerance is on the distance, which leaves a far witness loose. 735 segments
   passed through the face, where both routes are GJK's and the answers are equal.
2. *Never through.* 6,619 sphere and capsule casts that hit. At each stopping place GJK
   measures the shape at least the skin less the tolerance from the triangle. The closed-form
   cast and the general one stop within 0.16 mm of each other along the way.
3. *Tour by tour.* Below.

**Every run was compared with its GJK run, tick by tick.** A line added to the controller for
the comparison, and removed after it, printed the feet after every character move. It was
captured before the change and after, from the sandbox's tour and from `court-test`,
`sandbox3d-test`, the props and native tests, and the ABI and integration tests: 150,653 moves.

| Run | Moves | Worst difference |
| --- | --- | --- |
| The sandbox's tour, 2,400 frames | 10,886 | 0.0019 mm |
| `sandbox3d-test` | 27,726 | 0.12 mm, the walk over the generated patch. 0.002 mm elsewhere |
| The props and native tests | 3,330 | 0.0019 mm |
| The ABI and integration tests | 1,924 | none |
| `court-test`, with the four scripts | 106,787 | 0.0015 mm, but for one stretch |

The band was 1 mm. The court's four scripts end on the ticks they did: 2,441, 92, 185 and
42,023.

**The one stretch outside the band, and why.** In `court-test`'s footsteps test the warden
takes a different path for about 200 moves. That test walks the player along z = 1 on the low
wall, which is the seam between two polygons of the navigation mesh. The player's z was
1.0000001 and is now 0.99999994, one f32 step to either side. The warden's chase target is
where it last saw the player, so it falls on the other polygon, and the path to it crosses the
link over the wall. The warden's landing off a link has no surface, by design, so the test's
count of sounds with a surface was one short. The test now counts such a landing apart. No
scripted ending and no tour passes through this.

**The pins, old and new.**

| Pin | Before | After |
| --- | --- | --- |
| The player's tour | `cb99ccfcf2b6d6c3` | `b85b52c97d259db4` |
| The corner's replay | `832fe43a3a82db13` | `e2992f93e5323345` |
| The court's win | `2495783980aedff1` | `4cea12a2d26686ba` |
| The court's caught | `757a204cc05d1b02` | `448a83a95a46f1af` |
| The court's fell | `6b4fdba4db5b669e` | `489ec244f5946487` |
| The court's soundtrack | `806953eeb8f10db8` | `38ee55e6ad5b65da` |
| The generated patch's walk, end y | 0.074692 | 0.074569 |

**Pins §8 expected to move that held:** the walker's `655e865f98779129`, the pacer's
`e46c09dc62b1eeac`, `222e0a9b12fd152c` and `47f67027ff3a12b0`, and the strafer's
`27f549beaaf0e20b`. Why they held was not looked into. Each is still checked by its test.

**A tie rule tried, and taken out.** While the routines were still in f32, a tilted world took
a step a tick apart from the upright one: a capsule meets a riser and its tread at the edge
they share, and rounding chose between them. A rule preferring the face that best agreed with
the contact made a character jitter by 2 mm against the sandbox's plinth, which the tick
comparison caught. A rule giving such a tie to the lower triangle cured both. Once the routines
were in f64 no test could tell that rule from none, 200 turned steps included, so it was taken
out. `World`'s choice among hits is as M37 left it.

**Guards verified by mutation,** each failing a test:
- a point's edge region and its corner region left out;
- the segment's passage through the face, its other end, and its edges, each left out;
- a grazing ray called a miss, and a ray in the plane called a miss;
- a ray's hit past its end accepted;
- the closed form answering cores that meet;
- the face's own normal left for the line between the points;
- a ray that starts on the triangle sent to the one step;
- the hit point taken from the ray and not the triangle;
- the dispatch to the closed forms removed;
- every pair counted as GJK's.

**Tests.** Eleven new. Three in `pairs.zig`: the seven regions, the segment's cases, and the
ray's. Eight in `pairs_tests.zig`: a point and a segment against GJK; rays against the general
cast and their own crossing; casts that never pass through; seams and corners; the hit on the
triangle and the ray that starts on it; the face's normal and cores that meet; and a slide into
the seam of a riser and its tread.

**The bar.** `zig build test` passed 2,964 of 2,974 tests (ten skips) in 132 of 132 steps. The four
checks, the four headless samples and `fdt-check` passed. The physics suite takes about 25 s.

## Resolution — Step 6: `.fcol` version 3, `foundry:collision_hull`, `collision_import` version 2 (2026-11-10)

**What it pinned.**
- **`.fcol` version 3** is written by `collision_mesh.writeWith` whenever `Attributes.tree` is
  given, and only then; a mesh with no tree is version 1 or 2, byte for byte as before (the
  version 1 hash `c854ac2cc345318d` is still pinned). The file's node is
  `collision_mesh.TreeNode`, an extern struct of 32 bytes: `min`, `max`, then `link` and `count`.
  For a leaf, `link` is the first place in the order and `count` 1 to `max_leaf_triangles` (4);
  for an inner node `count` is zero and `link` is the right child. This is not
  `physics3d.mesh.Node`, which keeps `left`, `right`, `first` and `count` apart, so whoever hands
  a baked tree to `physics3d` converts it: an inner node's `left` is its own index plus one. That
  conversion is `author`'s at Step 7 and the samples' at Step 9, since nothing below them sees
  both modules.
- `View` gains `tree_nodes` and `tree_order`, `CollisionMesh` gains them owned, with `tree()`,
  which is null for versions 1 and 2. The loader copies them, and every allocation unwinds.
- **`foundry:collision_hull`** is a new kind in `asset.schemas.kinds`, appended last, which a
  `.fhul` derives, read by `asset.collision_hull` and loaded by `collisionHullLoader` into an
  `asset.CollisionHull` of points and bounds. `.fhul` version 1 is a 36-byte header (magic,
  version, count, bounds) and the points. `author`'s `engine_schema_names` gains its spelling.
- **`foundry:collision_import` version 2** has `shape`, a string defaulting to `mesh`
  (`asset.schemas.collision_import_shape_*`). A version 1 record read under version 2 has its
  default, `mesh`.

**Where the implementation sharpened the design.**
- **What `asset` checks of a tree.** §7 said the counts, a leaf's count and a right child in
  range. It also checks, still without memory, that a leaf's run lies inside the order and that
  every entry of the order names a triangle the mesh has, since both are a comparison each. A
  right child must come after the left one (`link > i + 1`) and be a node. What needs memory or
  a walk, a permutation, preorder, depth and containment, stays `physics3d.validateTree`'s, and a
  test shows a triangle named twice is read by `asset` and left to it. A node count is refused
  when it is zero or over 2n − 1, before its length is compared with the file's.
- **The writer refuses what the reader would,** as `InvalidMesh`, and nothing more: an empty
  tree, too many nodes, an order of the wrong length, and every shape the reader refuses.
- **An infinite box.** A node box of infinite extent passes both `asset` and `validateTree`,
  since containment is the whole test of a box. It is slow and not wrong: `candidates` compares
  boxes, so it is a box that always overlaps, and a NaN box contains nothing and is refused as
  `leaf_bounds` or `parent_bounds`. Nothing was changed for it.
- **`.fhul`'s refusals by name.** A count under 4 is `Malformed` and one over 256 is
  `OverLimit`, as `.fcol` names a zero count and one past its limit; a file longer than 256 points
  could make is `OverLimit` before its count is read. Beyond §7's list, the bounds must be finite
  and ordered, and every point inside them, as `.fcol` requires. `write` does not ask whether the
  points span a volume: that is `physics3d.hull`'s answer, which `author` asks at Step 7.
  `max_points` is 256 in `asset` and in `physics3d.hull`, two constants that cannot see each
  other; Step 7's `author`, granted both, checks they agree.
- **`shape hull` before Step 7.** Without a change, `author` would have compiled a hull import as
  the mesh it did not ask for. So `author` now reads `shape`, compiles `mesh` as before, refuses a
  value that is neither by name, and refuses `hull` as "which this compiler cannot compile yet".
  Step 7 replaces the second refusal with the compile. The proxy test now writes `shape "mesh"`
  and its bytes did not move.
- **Docs.** `docs/modding/content-mods.md`'s proxy section gains the hull when it compiles, at
  Step 7.

**Guards verified by mutation,** fifteen, each failing a test:
- in `.fcol`: a node count of 2n allowed; a leaf of five allowed; a right child that is the left
  one, or one past the last node; a leaf's run past the order; an order entry past the triangles;
  version 2's exact length dropped, so a version 2 file could carry a tree; and the writer's order
  length loosened;
- in `.fhul`: a count under 4, and over 256, each allowed; a length longer than the count's; a
  point past the bounds' maximum; and the writer's count range dropped;
- in `author`: `shape hull` compiled as a mesh, and an unknown shape accepted.

Two survived the first run, the node count and the count under four, because their tests' files
were also the wrong length and were refused for that. Each now has a test whose file is the
length its count makes.

**Tests.** Ten new. In `collision_mesh.zig`: version 3 round trips with and without surfaces, a
single leaf, and versions 1 and 2 carrying no tree; every read refusal of the tree; the writer's;
and the loader under every allocation failure. In `collision_hull.zig`: the round trip, from an
unaligned start and at 4 and 256 points; every read refusal; the writer's; and the loader. In
`schemas.zig`: `collision_import` version 1 under version 2, with `shape` of each kind and of the
wrong type; and `.fhul` deriving the hull. Two refusals joined `author`'s proxy test.

**The bar.** `zig build test` passed 2,974 of 2,984 tests (ten skips) in 132 of 132 steps. The four
checks, the four headless samples, `fdt-check`, the 2,400-frame tour and `court-test` (87 of 89,
two skips) passed, and no pin moved. Because the engine gained an asset kind, `zig build
distribution-test` (33 of 33) and the court's macOS staging were run too, and passed. Windows
staging was not run: no package holds a `.fhul` yet, and the first that does is the yard's, at
Step 9.

## Resolution — Step 7: `author` bakes the tree and compiles a hull (2026-11-11)

**What it pinned.**
- **`author` is granted `physics3d`** in `build.zig`, the downward grant ADR-0077 names, with its
  reason beside it. Nothing else changed in the graph.
- **The bake.** A derived or proxy collision mesh of `gltf.translate.collision_tree_threshold`
  (1,024) triangles or more is written as `.fcol` version 3 with the tree
  `physics3d.mesh.buildTree` builds for the same positions and indices. One under it is written as
  before, version 1 or 2, byte for byte. The conversion to the file's node is `bakeTree`: a leaf's
  `link` is its `first`, an inner node's its `right`, and an inner node whose `left` is not the
  next node is refused rather than written wrong. Every collision mesh that exists is under 1,024
  triangles, so no file in the repository moved.
- **The hull.** `foundry:collision_import` with `shape "hull"` compiles into the
  `foundry:collision_hull` of its own ID and a `hull0.fhul` beside the source's other generated
  files. Its points are every vertex a triangle of the placed, unexcluded nodes uses, after the
  import's `front`, in placement and vertex order; its corners are those points that are corners
  (`physics3d.hull.cornersOf`), in that order. Refusals, each naming the record:
  `HullTooManyPoints` with the count ("has 300 points on its hull, more than 256; make a simpler
  shape"); `HullFlat` when the builder finds the points flat, and again when the corners span less
  than `shape.min_hull_volume`; `HullTangled`, which no input is known to reach; an empty hull; and
  `surfaces` on a hull import, refused in `importSettings` before any geometry is read. `one_sided`
  lives inside a surface mapping, so refusing `surfaces` refuses it too. An empty `surfaces []` is
  accepted, as `exclude []` is.
- **Agreement between modules.** A comptime check in `translate.zig` fails the build when `.fhul`'s
  point limits differ from `physics3d.hull.max_points` and `shape`'s, or `.fcol`'s leaf size from
  `physics3d.mesh.leaf_capacity`: the two constants Step 6 left unable to see each other.

**Where the implementation sharpened the design.**
- **Which vertices.** §9 said "every vertex of the file's triangles". A vertex no triangle uses is
  left out, and a degenerate triangle's are kept: a degenerate triangle is dropped from a mesh
  because it has no face, but its corners are still points of the shape. The test's cube carries a
  far point no triangle uses, and it is not in the hull.
- **`HullFlat` twice.** `hull` measures flatness against the hull's own size, so a millimetre's
  tetrahedron is a hull to it, while `World.addHull` refuses anything under 1 mm³. Without the
  second check such a hull would compile and never load. A test compiles that tetrahedron.
- **`hull.cornersOf`.** `reduce` returned `TooManyPoints` with no count, and §9's diagnostic says
  how many there were. `physics3d.hull` gains `cornersOf`, `reduce` without the limit, and `reduce`
  is now that and the limit; its tests did not change.
- **A model naming a hull.** A model's `collision_mesh` naming a hull import was refused as "no
  foundry:collision_mesh or foundry:collision_import", which a hull import is. It now says the
  record is a `foundry:collision_hull`, and that a game adds a hull body by its ID (§7: nothing
  names a hull from a model).
- **What the bake test compares.** `buildTree`'s nodes keep values in the fields their kind does
  not use, such as an inner node's `first`. The file keeps only what each kind means, so the test
  compares a leaf's run and an inner node's two children, and the boxes exactly.
- **The fixtures.** §9's twice-compiled test names the hillside and the boulder, which are Step 9's
  yard. Step 7's tests use a 32 by 16 grid with a gentle rise, at 1,023 and 1,024 triangles, and a
  cube with points inside, on a face, along an edge and one unused; Step 9 compiles the yard's own.
- **The modding guide** gains baked trees and hull imports now, beside proxies, since this is the
  step that makes them compile; Step 12 still checks it.

**Guards verified by mutation,** twelve, each failing a test: the threshold as `>` and baking
never; an inner node's link written as its left child; a vertex no triangle uses taken; the points
written unreduced; the corner limit dropped; the volume check dropped; surfaces on a hull allowed;
a hull compiled as a mesh; a hull reference given the generic refusal; a hull's triangles sent down
the mesh's path; and `.fhul`'s `max_points` made 255, which the comptime check refuses to build.

**Tests.** Three new in `compiler.zig`: a mesh at and one under the threshold, the tree
`validateTree` passes and equal node for node to `buildTree`'s, taken by `World.addMeshWith`, and
the same bytes twice; a hull import's corners, six faces, `World.addHull`, its record and bytes
twice, and its load through `collisionHullLoader`; and the refusals of too many corners, too little
volume and a model naming a hull. Two cases joined the proxy refusal test, replacing Step 6's "cannot
compile yet".

**The bar.** `zig build test` passed 2,977 of 2,987 tests (ten skips) in 132 of 132 steps. The
four checks, the four headless samples, `fdt-check`, the 2,400-frame tour and `court-test` (87 of
89, two skips) passed, and no pin moved. The first run found one more place that compiles the
translator, the skin proof in `build.zig`, which names its imports by hand; it gains `physics3d`,
which `author` now has, so nothing is widened. Because `author` compiles a new kind, `zig build
distribution-test` (33 of 33) and the court's macOS staging ran too, and passed. Windows staging
waits for the yard's package, the first to hold a `.fhul` or a baked tree, at Step 9.

## Resolution — Step 8: the physics panel (2026-11-11)

**What it pinned.**
- **`debug` is granted `physics3d`** in `build.zig`, for `physics3d.Report` alone, with its reason
  beside the grant; `physics2d` stays out. The panel reads nothing else of `physics3d`; only its
  tests build a `World`, to print a report a real world gave.
- **`debug.Sources.physics: ?*const physics3d.Report`**, null by default, beside `navigation` and
  `animation`. A game fills it from `World.report()`, with the counters it takes itself
  (`Report.withCounters`) and its own `move_p95_ms`.
- **`debug.physics_panel`**, registered as the eighth built-in panel, titled `physics`, closed to
  begin with. It prints:
  - what the world holds: static and kinematic bodies and characters; meshes, triangles and how
    many were baked; hulls and their faces; the broadphase's nodes and height;
  - the queries asked, each kind that was asked by `QueryKind`'s own name and in its order, or
    "no queries";
  - when any were asked, the nodes walked, bodies tested and triangles tested, and the pairs sent
    to closed form and to GJK;
  - refits and the game's move p95, each only when it has one.

  With no report it says "no physics reported (debug.Sources.physics)", as the navigation panel
  does.

**Where the implementation sharpened the design.**
- **Kinds by their own names.** The panel prints `@tagName` of each `QueryKind` rather than a list
  of its own, so a kind M51 adds is printed without the panel changing and the two cannot disagree.
- **Zero lines left out.** A kind not asked, no refits and no timing are not printed, as the
  navigation panel leaves out an agent state with nobody in it. What the world holds is always
  printed, zeros included, so an empty world reads as one and not as a missing report.
- **What wires it.** No sample hands a report yet: the sandbox's is Step 9's, with the yard, and the
  court's one line is Step 10's (§11, §12). A state file naming the panels a host saved before
  this step opens them as before, since panels are matched by title.

**Guards verified by mutation,** seven, each failing a test: every kind printed, asked or not; the
"no queries" branch inverted; refits and timing each printed always; kinds named one place off;
static and kinematic swapped; and the panel left unregistered.

**Tests.** Four new in `physics_panel.zig`: no report; an empty `World`'s report; a world of two
bodies after one ray, with the game's timing; and every line of a full report. The overlay's
built-in count test is now eight.

**The bar.** `zig build test` passed 2,981 of 2,991 tests (ten skips) in 132 of 132 steps. The
four checks, the four headless samples, `fdt-check`, the 2,400-frame tour and `court-test` (87 of
89, two skips) passed, and no pin moved. No content or asset kind changed, so staging was not run.
