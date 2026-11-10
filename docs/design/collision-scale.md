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
