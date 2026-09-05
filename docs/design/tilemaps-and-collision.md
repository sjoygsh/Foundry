# Design: tilemaps and 2D collision

**Status:** Design only. Nothing here is implemented. This is M5's first document, written
before any collision code exists, so that implementation is transcription rather than
invention.
**Date:** 2026-09-05
**Implements:** I1, I2, I5, I6, I7, I9 · **Informed by:** ADR-0007, ADR-0013, ADR-0021,
ADR-0022

M5 asks for "tilemaps with efficient rendering and collision" and "2D collision detection and
response; spatial partitioning". Those two lines describe **three separable things** that get
conflated into one word, and conflating them is how a tilemap ends up as an unremovable lump
in the middle of an engine:

1. **A grid of numbers** — the map's data. It is content, and its bulk is an asset.
2. **Drawing that grid** — a `render2d` concern, and a small one, because a tilemap is a
   great many sprites that happen to be arranged regularly.
3. **Colliding against that grid** — a `physics2d` concern, and one that wants the grid as a
   *grid* rather than as ten thousand boxes.

The three meet only in the game that uses them. No module here depends on another that it
does not already depend on, and that is a load-bearing property rather than a happy accident:
a headless consumer that wants collision without a renderer, or a content compiler that wants
the map data without either, must both remain possible.

---

## 1. What is already decided

**ADR-0022** fixed the shape of collision before this document existed:

* Foundry writes its own; no ported library.
* Scope is **collision, not dynamics**. Axis-aligned boxes and circles, swept tests, a
  uniform spatial hash, queries, penetration resolution with sliding, trigger volumes, and a
  tile grid as a first-class static shape source. No mass, no restitution, no friction
  solving, no joints, no rotation, no convex polygons.
* `f32` throughout, no fixed-point today, and the module's arithmetic stays inside
  `+ - * /`, `sqrt`, comparison, `min`/`max` and `abs` so the ADR-0013 upgrade path stays a
  bounded job.
* **`physics2d` is L1 and depends on `core` alone.** No entities, no content, no I/O.
* Two determinism rules are binding: the broadphase never determines order, and bodies
  iterate in handle order.

**Everything else it needs already exists.** `render2d` has sprites, atlases, views, a camera
and a batcher that draws 4,185 quads at vsync in four batches. `asset` has a registry, content
IDs and runtime-registered loaders, with `render2d`'s texture loader as the worked example of
registering a capability upward (I6). `data` has schemas, packages and override-by-ID. `scene`
has components-as-schemas and systems. This document adds no new machinery to any of them.

---

## 2. `physics2d`: what a world is

```
World
  bodies:  HandlePool(Body)      // I1: { index, generation }
  grids:   HandlePool(Grid)      // static tile geometry
  hash:    SpatialHash           // movable and trigger bodies only
  overlaps: OverlapSet           // trigger state, for enter/exit
```

**The world holds no time and no velocity, and integrates nothing.** This is the single most
consequential choice in the module and it follows directly from ADR-0022's scope: a caller
says *move this body by this vector* and is told where it ended up and what it touched. There
is no `dt` parameter anywhere in the interface, no stored velocity, and no notion of a
simulation step inside collision.

Three things follow, all of them wanted:

* **Movement feel stays in the game**, which is where it belongs for a top-down tile game.
  Acceleration curves, input smoothing and speed caps are gameplay, and an engine that owned
  them would be an engine you fight.
* **I9 gets simpler.** A module with no clock cannot read one (I9 rule 4), and a module with
  no integration has no accumulated float state to diverge.
* **The module is trivially testable.** Every test is "put these shapes here, move this one,
  assert where it stopped" — no stepping, no settling, no tolerance for a solver converging.

### The one piece of frame-to-frame state

Triggers need to report *entered* and *exited*, not merely *overlapping*, and that needs
memory of the previous tick. So the world has exactly one synchronisation point:

```zig
pub fn sync(self: *World) void
```

`sync` recomputes trigger overlaps and produces enter/exit events. It is called once per
simulation tick, after the caller has finished moving things. It is **not** a step: it
advances nothing, it moves nothing, and calling it twice in a row produces an empty second
event set rather than a different world.

The broadphase is *not* rebuilt in `sync`. It is updated incrementally when a body moves,
because most bodies do not move in most ticks and rebuilding a structure to discover that is
work paid for nothing.

### Bodies

```zig
pub const BodyKind = enum { static, movable, trigger };

pub const Body = struct {
    shape: Shape,
    position: Vec2,     // the shape's centre, always
    kind: BodyKind,
    layer: u32,         // which layer this body is on   (one bit, conventionally)
    mask: u32,          // which layers it collides with (any bits)
    user: u64,          // opaque; the game's own identifier. Never interpreted.
};
```

`static` bodies are solid and live in a separate tier of the broadphase that is not re-sorted
as movable bodies move. A static body may still be repositioned — a door opening — and the
tier is updated then; "static" describes an expectation about frequency, not a prohibition.

`layer` and `mask` are the filter, and they are plain integers rather than a registry because
a filter that a mod has to register is a filter that fails at load time instead of at compile
time. A body collides with another when `a.mask & b.layer != 0` **and** `b.mask & a.layer != 0`
— symmetric, so a one-sided filter cannot produce the situation where A pushes B but B does
not push A.

`user` is the seam to the rest of the engine. `physics2d` cannot name an `Entity` — `scene` is
above it — so the game stores `entity.bits()` here and reads it back out of a contact. That is
the whole of the coupling, it is 64 bits wide, and it is why `physics2d` can be used with no
ECS at all.

---

## 3. Shapes

```zig
pub const Shape = union(enum) {
    box: Vec2,        // half-extents, so the centre is the position
    circle: f32,      // radius
};
```

Half-extents rather than min/max corners because every test in the module is a Minkowski
difference, and half-extents make that a sum rather than four subtractions at every call site.

The set is closed. A convex polygon is the obvious next member and is deliberately absent
(ADR-0022): adding it later changes no signature, because every entry point takes a `Shape`.

**Circles collide with boxes and with each other; boxes collide with boxes and with grids.**
Circle-versus-grid is supported through the same cell walk. There are four pair tests and one
grid test, all of them closed-form, none of them iterative.

---

## 4. The tile grid

```zig
pub const Grid = struct {
    origin: Vec2,          // world position of cell (0,0)'s lower-left corner
    cell: Vec2,            // cell size; non-square is legal
    width: u32,
    height: u32,
    tiles: []const u16,    // row-major, borrowed, width*height long
    solid: []const u32,    // bitset over *tile ids*, not cells
};
```

**The grid is a shape source, not a body**, and it does not enter the broadphase. Colliding a
swept box against it is a bounded walk over the cells the sweep's bounding box covers, which
costs the same for a 20×20 map as for a 2000×2000 one. That is the entire reason ADR-0022 made
it first-class instead of generating a static body per solid tile — the latter is correct, and
it is also ten thousand broadphase entries and a rebuild every time a mod changes one tile.

`tiles` and `solid` are **borrowed slices the world does not own**. The grid asset, its
lifetime and its reloading belong to whoever loaded it; `physics2d` reads it and nothing more.
This is what keeps the module at L1: it never learns what an asset is.

`solid` is a bitset over tile *ids* rather than over cells, so it is the size of the tileset
(tens of bytes) rather than the size of the map, and so hot-reloading a tileset's collision
data changes one small array rather than rebuilding the map.

### The internal-edge problem, and the answer to it

ADR-0022 named this as one of two sharp edges collision is famous for. A box sliding along a
flat wall made of adjacent solid tiles snags on the seam between two tiles that are each
individually correct: the sweep finds a vertical face on tile *n+1* that the box is already
past, and reports a normal pointing back the way it came.

**The fix is neighbour-aware face culling, and it is only possible because the grid knows it is
a grid.** When testing a cell, a face is ignored if the neighbouring cell in that face's
direction is also solid — that face is interior to the wall and cannot legitimately be hit.
Four bit tests per cell, no preprocessing, no merged-span bookkeeping, and it is exact rather
than a tolerance.

This is the concrete payoff for treating the grid as a grid, and it is worth stating plainly:
the pile-of-boxes representation cannot do this, because a box does not know its neighbours.

---

## 5. Broadphase

A **uniform spatial hash** over movable and trigger bodies. Cell size is configured at world
creation, defaulting to the largest body's bounding extent at first insert, and a body spanning
several cells is registered in each.

The determinism rule from ADR-0022 governs the whole structure, and it is worth being precise
about what it forbids. The hash may bucket however it likes. What it may not do is let a bucket
order reach a result. So:

> **Candidates are collected, then sorted by body handle index, then processed.** Nothing reads
> a bucket in bucket order and acts on it.

The sort is over a small set (the candidates for one query, typically single digits) and is
insertion sort. The cost is real and it is the price of I9; ADR-0013 already accepted that
determinism is paid for in small verbosities like this one.

A uniform hash is the right first structure and the wrong last one — it degrades when body
sizes vary by orders of magnitude. ADR-0022 records the revisit trigger, and rule 1 above is
exactly what makes replacing it safe: a different acceleration structure that produces the same
candidate set produces the same results, so the swap is invisible to every test.

---

## 6. Movement and response

One entry point does the work:

```zig
pub const Hit = struct {
    body: ?BodyHandle,   // null when the grid was hit
    grid: ?GridHandle,
    cell: ?[2]u32,       // which cell, when it was a grid
    normal: Vec2,        // pointing away from the surface, unit length
    fraction: f32,       // 0..1 along the motion that was requested
    user: u64,           // the struck body's `user`; zero for a grid
};

pub fn moveAndSlide(
    self: *World,
    body: BodyHandle,
    motion: Vec2,
    hits: []Hit,          // caller-owned; filled in contact order
) MoveResult
```

`MoveResult` carries the final position, how many hits were written, and **how many there
would have been** — so a caller whose buffer was too small learns that it truncated rather
than silently believing it saw everything. That pattern repeats for every query in the module.
It is chosen partly because it is the shape the C ABI will need at M7 (ADR-0004: explicit
ownership on every call that transfers memory), and adopting it now costs nothing.

### The algorithm, stated so it can be transcribed

Iterative swept resolution, with a fixed budget:

1. Sweep the body's shape along the remaining motion against every candidate — grid cells the
   sweep's bounds cover, then broadphase bodies, in that order.
2. Take the earliest time of impact. Advance the body to just short of it, by a fixed epsilon
   along the normal, so the next iteration does not start already touching.
3. Record the hit. Project the remaining motion onto the contact plane — `remaining -
   normal * dot(remaining, normal)` — which is what makes it *slide* rather than stop.
4. Repeat, up to **four** iterations, then stop wherever it is.

Four is a documented constant, not a tuned one: a corner needs two, a corner between a grid and
a body needs three, and the fourth exists so that a degenerate arrangement terminates with a
slightly wrong position rather than looping. It is in the interface documentation because a
caller can observe it.

**Depenetration is separate and explicit.** A body that starts a move already overlapping —
because it was teleported, because a mod resized it, because a tile turned solid underneath it
— is not something the sweep can fix, since the time of impact is behind it. `resolveOverlaps`
is a distinct call that pushes a body out along the shortest axis. Keeping it separate means
`moveAndSlide` has one job, and means "I am stuck in a wall" is a state the game can detect
rather than a silent teleport.

---

## 7. Queries

```zig
pub fn overlapPoint (self, p: Vec2, mask: u32, out: []QueryHit) QueryResult
pub fn overlapShape (self, shape: Shape, at: Vec2, mask: u32, out: []QueryHit) QueryResult
pub fn raycast     (self, from: Vec2, to: Vec2, mask: u32, out: []Hit) QueryResult
pub fn shapeCast   (self, shape: Shape, from: Vec2, to: Vec2, mask: u32, out: []Hit) QueryResult
```

All four take a caller-supplied buffer and report the true count. All four include the grid.
All four return results in the module's documented order: grid cells first in row-major order,
then bodies in handle order — except `raycast` and `shapeCast`, which return by increasing
`fraction`, with ties broken by that same order.

No query takes a callback. A callback into user code from inside a query is how a container
gets mutated mid-iteration, and it is also the one shape that does not survive contact with a
C ABI cleanly.

---

## 8. Determinism, concretely

I9 asks for stable, *documented* iteration order wherever order affects results. In this
module order affects everything, so the guarantees are stated as interface contract:

1. **Bodies iterate in handle-index order** — which is insertion order, since the pool reuses
   the lowest free slot.
2. **Grid cells iterate in row-major order** within the swept bounds.
3. **Grid before bodies**, always, in any operation that considers both.
4. **The spatial hash never determines order.** Candidates are sorted before use.
5. **No wall clock, no RNG, no global state.** The module has no clock to read (I9 rule 4) and
   takes no RNG at all.
6. **No pointer-derived behaviour** (I9 rule 5). Handles order things; addresses never do.

The test ADR-0013 asked for — a fixed scenario run twice, compared — extends to cover physics
here, and the M5 version is stronger than M4's: the same scenario run twice **in different
insertion orders that describe the same world** must agree, because that is the property that
catches an accidental dependence on the hash.

---

## 9. Tilemaps as content

Three record types and one asset. All four are engine-owned and registered by `fpack` before
it compiles anything, exactly as `foundry:entity` and `foundry:texture` are.

```fdt
foundry:tileset sandbox:tiles.overworld {
    texture   sandbox:textures.overworld    # a foundry:texture, by content id
    tile      [ 16 16 ]                     # pixels per tile in the source image
    columns   16
    solid     [ 1 2 3 17 18 ]               # which tile ids block; everything else is empty
}

foundry:tilemap.layer sandbox:map.town.ground {
    tileset   sandbox:tiles.overworld
    grid      sandbox:grids.town.ground     # a foundry:tilegrid asset
    order     0                             # render2d sort layer
    collides  false
}

foundry:tilemap sandbox:map.town {
    size      [ 64 48 ]
    cell      [ 16 16 ]                     # world units per cell
    layers    [ sandbox:map.town.ground  sandbox:map.town.walls ]
}
```

### Why the grid itself is an asset

A 64×48 map is 3,072 numbers; a real one is far more. `CLAUDE.md` §6 is unambiguous — binary
payloads are never embedded in content text — and a list of ten thousand integers in a `.fdt`
file is a binary payload wearing a disguise: unreadable, undiffable in any useful sense, and
expensive to parse at exactly the moment content loading is being measured.

So **the grid is `foundry:tilegrid`, an asset**, whose identity is its content ID and whose
path merely derives one (ADR-0021), exactly like a texture. Its runtime format is a header
(magic, version, width, height) and a little-endian `u16` array, and it is read in place.
Its authoring format is a plain text grid of numbers, compiled by `fpack` — the same division
of labour ADR-0018 chose for images, where the pipeline transcodes and the engine loads.

This also settles what a Tiled importer would be, if one is ever wanted: a `fpack` front end
that emits the same asset, and not an engine feature.

**A layer that collides names its tileset's `solid` list**, and the game builds the bitset
`physics2d.Grid` wants from it once at load. `physics2d` never sees a content ID.

---

## 10. Drawing a tilemap

`render2d` gains one entry point:

```zig
pub fn drawTilemap(self: *Renderer, view: ViewId, layer: TilemapLayer) void
```

where `TilemapLayer` carries the texture, the tile size in the atlas, the grid dimensions, the
borrowed `[]const u16`, the world origin and cell size, and the sort layer.

**It culls to the view and emits ordinary sprites through the existing batcher.** That is the
whole implementation, and the restraint is deliberate. A screen at 16-pixel tiles shows on the
order of 40×25 cells; even at four layers that is four thousand quads, and M2 demonstrated
4,185 quads at vsync in four batches. Every tile in a layer shares one texture, so a layer is
one batch.

**No chunk cache, no persistent vertex buffer, no dirty-rectangle tracking in M5.** Those are
optimisations, they are invisible to the interface above, and ADR-0022's discipline about the
broadphase applies here too: add them when a measurement asks for them, not when a larger
engine's architecture diagram does. The trigger is stated so it is not a matter of taste — a
tilemap draw appearing in the frame profiler M6 builds, at the layer counts a real map uses.

Culling is the part that is *not* optional, because it is the difference between drawing what
is visible and drawing the map.

---

## 11. How the three meet

The game wires them, and that is the design rather than a gap in it:

```
asset  ──loads──▶ foundry:tilegrid ──▶ []const u16
                                        │
                          ┌─────────────┴─────────────┐
                          ▼                           ▼
                 render2d.drawTilemap        physics2d.addGrid
                 (+ texture, atlas rect)     (+ solid bitset, cell size)
```

Both consumers borrow the same slice. Neither owns it. Neither knows the other exists.
`physics2d` stays at L1 with `core` alone; `render2d` gains nothing it did not already have.

**The tilemap schemas and the `foundry:tilegrid` loader live in `render2d`**, beside the
texture loader, for the reason `assets.md` gave: the dependency points down while the
capability points up. This is the one placement in the document that is a judgement call rather
than a consequence, and the wart is recorded honestly in §13.

### `scene`, and what M5 does *not* add to it

M5 adds **no engine-owned component types**. The sample defines its own `collider`, `velocity`
and `animation` components, exactly as it already defines `transform` and `sprite`.

This is deliberate and it is a compatibility argument, not a laziness one. `CLAUDE.md` §7:
naming things mods will see is a compatibility decision, and a `foundry:collider` invented in
M5 is a name every mod is stuck with from M7 onward, designed before a single game has said
what it needs on one. M7 fixes the mod-facing vocabulary; that is when a standard component
set should be chosen, with a year of use behind it. Until then the engine provides mechanism
and the game provides the components — which is I5 read literally.

---

## 12. What this exposes to mods

`CLAUDE.md` §5: adding a subsystem includes deciding what it exposes, even if the answer is
"nothing yet". At M5 there is no ABI, so this is a statement of intent that M7 will implement.

**Tier 1, content mods — works at M5, as a consequence of the content model.** A mod can add a
tileset, a tilemap, a tile grid asset, and can override any of them by content ID. Changing
which tiles are solid is editing a `solid` list in a record. Replacing a map's art is
overriding a `foundry:texture`. None of this needs the mod system, and that is I3 doing its
job.

**Tier 2 and 3, at M7.** The intended surface is: create and destroy bodies, move them, query,
read contacts. Not: the broadphase, the internal shape storage, or the iteration internals —
those are exactly the things that must stay replaceable for the revisit triggers in ADR-0022 to
be reachable. `user` being an opaque `u64` rather than an `Entity` is the first piece of that
already being true.

---

## 13. Open questions

Named rather than resolved, per the standing rule that implementation must not settle these
opportunistically.

1. **Should the tilemap schemas and grid loader be extracted into their own module?** They are
   in `render2d` because a tilemap is mostly a thing you draw and because that avoids a module
   for three hundred lines. The wart: a consumer wanting map data *without* a renderer — a
   headless server, a validating tool — must link `render2d`. Nothing needs that today, the
   future editor is a Foundry application and has a renderer anyway, and networking is
   indefinite. **Trigger: the first real consumer that wants a grid and not a GPU.**
2. **Does `fpack` gain the text-grid compiler in M5, or does the sample generate its grid?**
   The asset format is decided either way; only the authoring front end is in question. Leaning
   towards building it in M5, because a map nobody can hand-author is a map that proves nothing
   about Tier 1 modding.
3. **One-way platforms and slopes.** Out of scope by the sample decision (top-down), and the
   grid's `solid` bitset is deliberately a bitset rather than a per-tile shape id so that
   adding them later is an additive change to the tileset schema rather than a reinterpretation
   of existing content.
4. **Does `sync` belong in `physics2d` at all**, or should trigger enter/exit be the game's
   diff of two overlap sets? Keeping it here means the module has one piece of frame-to-frame
   state, which is the only thing in it that is not a pure function. It earns its place if
   games actually want enter/exit; it does not if they mostly want current overlaps.
5. **Continuous rotation is absent, and so rotated colliders are absent.** A top-down game with
   rotating sprites will want a rotated box before it wants a convex polygon. Recorded so that
   whoever adds it knows it was seen and skipped, not missed.

---

## 14. Deliberately not here

* **Any form of dynamics.** ADR-0022 §Decision, restated because it is the thing most likely to
  be added by accident, one convenience at a time.
* **A physics "step".** There is no time in this module.
* **Pathfinding.** Grid pathfinding is adjacent and is game logic; it belongs in a game, or in
  a much later engine module with its own document.
* **Tilemap animation, autotiling, and per-tile metadata beyond solidity.** All are content
  features, all are additive to the tileset schema, none is needed to prove the design.
* **Sprite animation**, which M5 also needs and which gets its own short document — it touches
  `render2d` and `scene`, and shares nothing with collision but the milestone it lands in.

---

## 15. Implementation order

Each step leaves the tree green, `zig build test` passing, and the sandbox runnable, per the
milestone rules.

1. **`physics2d` exists**: the module in `build.zig` with `core` as its only dependency, the
   layering confirmed by *breaking* it — an import of `data` must fail to build — the world,
   the body pool, shapes and the four static pair tests.
2. **The grid**: `Grid`, the cell walk, neighbour-aware face culling, and the swept box-versus-
   grid test that is the heart of a tile game.
3. **The broadphase**: spatial hash, incremental update on move, candidate collection and the
   determinism sort. This is the first step where an I9 test is meaningful.
4. **Movement and queries**: `moveAndSlide`, `resolveOverlaps`, the four queries, the truncation
   reporting, and the documented four-iteration budget.
5. **Tilemap content**: the three schemas, the `foundry:tilegrid` asset and its runtime format,
   the loader registered from `render2d`, and `fpack`'s text-grid front end.
6. **Drawing**: `drawTilemap` with view culling, and the sandbox showing a real map.
7. **The two meeting**: the sandbox's player collides with the map — the first moment M5 looks
   like a game rather than like a test.

Audio is a separate document and a separate sequence, and it does not block any of this.

---

## Resolution: shapes, the grid and the broadphase (steps 1–3, 2026-09-05)

§15's first three steps are implemented. The specification above was transcribable, which was
its job; six things it did not have to settle, implementation did.

**The layering was confirmed by breaking it, and the probe had to *reference* the import.**
`no module named 'data' available within module 'root'`, with `--dep core` and nothing else on
the failed command line. An unused `@import` compiles clean under Zig's lazy analysis, so a
probe that only names the module proves nothing — the same nuance `build.zig`'s comment
records.

**Touching exactly is not an overlap, and a sweep grazing is a miss.** Both fall out of one
requirement that §6 implies without stating: a body resting flush against a wall must report
nothing, every tick, forever, and a body sliding along one must report nothing as it goes. So
`overlap` uses strict inequalities, a sweep whose entry and exit coincide is rejected, and on
an axis with no motion the slab boundary counts as *outside*. The case given up in exchange —
motion exactly along a face plane, straight at the wall — is unreachable once `moveAndSlide`
stops a body an epsilon short of what it hits.

**A sweep that began overlapping reports that distinctly**, with a null face rather than a hit
at fraction zero. §6 says depenetration is a separate call; this is the value that makes the
separation visible to a caller instead of a convention it has to remember.

**Outside a grid is not solid.** §4 did not say, and it matters: the answer here is that a grid
is a shape source rather than a world boundary, so a closed map is a border of solid tiles,
which is content (I5). The opposite choice would make a grid unusable as a *local* patch of
geometry — one room, one platform chunk — because everything around it would be a wall.
Relatedly, a `solid` bitset shorter than the tileset leaves the remaining ids passable rather
than reading past its end, because that array comes from content that may predate a tile being
added.

**The broadphase's contract is "no false negatives", and the invariance claim belongs one level
up.** §5 says a different acceleration structure producing the same candidate set produces the
same results. Building it showed the first half is too strong: a larger cell size legitimately
returns *more* candidates, because a candidate is a body sharing a cell rather than a body
that is really there. What must not vary is the **narrowed** answer, so `World.queryBounds`
filters by mask and by an exact bounds test, and that is where the "cell size does not change
the answer" test lives. The broadphase's own test asserts the thing that would actually break a
result: that no cell size ever *loses* a body.

**`pdq` rather than the insertion sort §5 named.** The sort key is a slot index and is unique
per body, so stability buys nothing, and a query covering a large region can return hundreds of
candidates — a size at which an O(n²) sort is a frame rather than a rounding error. §5's
reasoning was that candidate sets are small, which is true of the common case and guaranteed by
nothing.

**Two things the design did not anticipate at all.** Cell size is chosen from the first body
inserted, so a body a million units across arriving after a handful of small ones would ask for
a million cells and hang the frame — and bodies come from files, which come from mods. Such a
body goes into a **spill list** that every query considers: correct, slower, and bounded.
Second, `World.body` returns a `*const Body` and every change that moves a body between cells
or between tiers goes through a named call. Handing out a `*Body` would let a caller move one
by assignment and leave the broadphase describing where it used to be, and the symptom of that
is "things sometimes do not collide" — the worst class of bug this module could ship.

**Still to come, unchanged by any of the above:** `moveAndSlide` and `resolveOverlaps` (step 4)
and everything from step 5 on.
