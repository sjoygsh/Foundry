# Foundry Project State

**Last updated:** 2026-09-07
**Updated by:** **M6 has opened, and it opened where the last four did: at a decision.**
`CLAUDE.md` §9 had held "Debug/game UI: own IMGUI vs. cimgui" since the project started and
ADR-0011 had deferred it here by name. **ADR-0024 answers it: Foundry writes its own
immediate-mode UI**, and `docs/design/ui.md` is written against it. **All six steps of its §16
are implemented**: `engine/src/ui/` is nine files of kernel that never sees a renderer,
`engine/src/app/ui_draw.zig` is the forty-line walk that turns what it described into draw
calls, `samples/sandbox` draws every widget in the set, and `samples/room` opens a card over a
live hall and holds back the input the card took. 900 tests under `-Drhi=null`, 908 under
`-Drhi=metal`.

**Step 6 found the contract `ui.md` §4 had stated and the kernel had not kept.**
`wantsKeyboard` returned "something has focus", and focus is set by a press on *any* widget —
so dragging the room's volume slider took the keyboard away from the hall and did not give it
back until the player clicked the world again, WASD dead with nothing on screen to say why.
What §4 always said is "has focus **and consumes typing**". A widget now declares that it is
eating characters (`Context.blockKeyboard`), `textField` is the only one that does, and the
flag is per-frame like every other, so a field the caller stopped describing consumes nothing
whatever `focus` still says. **This was found by building the game, not by testing the
kernel**: every test that could have caught it would have had to know that a slider is not a
text field, and only the design document knew that.

**The second finding is an ordering rule with a bug behind it.** The card's close button cannot
close the card where it stands — `clearInteraction` mid-frame clears the capture that very click
was consumed by, and the click then reaches the hall as a place to walk to, which is exactly the
"player who walked into a wall because they closed a panel" the kernel's own comment warns
about. The button records and the game acts after `end`. The same reordering had to happen in
`samples/sandbox`, whose overlay was described *after* the fixed step: its filter box could only
ever have gated the next frame's movement, and the comment there claimed a check that did not
exist. Both samples now describe the UI before they simulate, and the sandbox holds back `r`,
`c` and the arrows while its filter box has the keyboard — but not escape, and not its save and
load keys, because what a game holds back is the bindings a keyboard **types**.

**The room proves capture the way it proves the hall can be finished: with a scripted run.** It
gained one thing in the world that wants the pointer — a click sends the walker there — because
a check guarding nothing proves nothing. The autopilot opens the card, clicks the name field,
types the walker's name a codepoint at a time, presses the card's empty half (the
`pointer_blocked` case step 2 left as an argument), and clicks its way out. The device and the
script produce the *same* `Pointer` value, read by both the kernel and the game, so a scripted
click cannot take a path a real one does not. A full headless run: **29 card visits, 87 clicks
taken, 0 capture failures**, 6 of 6 lamps lit, the walker out of the hall in 1,542 ticks.

**Step 5's one structural addition is a per-widget state store, and the rule for what goes in
it is the interesting part.** A checkbox's flag, a slider's value and a plot's samples all stay
with the caller — a kernel holding a second copy of gravity is a kernel that can be wrong about
gravity. What the store holds is the state with **no owner anywhere else**: how far a list is
scrolled, whether a tree node is open, where a caret is. Those are properties of *looking at* a
widget rather than of the thing displayed, and making the caller own them would mean an
inspector keeping an array of bools parallel to the world. Entries age in frames the caller
supplies rather than seconds, because the kernel reads no clock (I9), and are swept at a bounded
rate so the one function that gives memory back never asks for any.

**The text field found a bug three layers down, in `platform`.** `event.TextInput.fromSlice`
ran its truncation back-off on every slice instead of only on one it had cut, so any committed
text ending in a non-ASCII character lost that character — and a two-byte string became an
empty event. Typing an accented character would have inserted nothing. Dead keys and
input-method composition are the reason that type exists; its own tests were all ASCII.

**Step 4 is first pixels, and the walker's parameter list is the interesting part.** `ui.md` §8
sketched `draw(list, renderer, font, blank, view)`; what landed is
`draw(list, renderer, font, view, options)`. `blank` went because step 3 put the white patch on
the renderer, which was the point of putting it there. The font parameter is not a
`render2d.BitmapFont` but an `app.UiFont` — the font paired with its spacing — and that pairing
is a **stronger** answer to the drift hazard than the test §8 asked for: a `BitmapFont` carries
no spacing, so the kernel and the walker would each have had to be handed the same two numbers
separately, which is a bug waiting for someone to update one call site. One value produces both,
so they cannot disagree; `engine/tests/ui_text.zig` then covers what is left, comparing the two
measurement implementations **exactly** across 6,528 combinations of cell shape, scale, spacing
and string. `app` gained `ui` and `render2d` in the build graph to make this possible, which
ADR-0007 always allowed and which changes nothing about the game still owning its renderer.

**Drawing it found a bug in step 2's code, which is exactly what step 4 was for.** `checkbox`
clamped its tick mark to half the box height so a generous padding could not turn the rectangle
inside out — and at exactly half, the inset leaves zero width, so the mark was kept from being
wrong by being invisible. The sandbox's first style hit it on frame one. Step 2's own tests used
a padding a third of the box and passed happily. The clamp is a quarter now, with a test at the
old boundary.

**Step 3's evidence is a deletion.** `samples/sandbox` and `samples/room` had each written an
eight-pixel white `asset.Image`, a `createTexture` and a `sub(2, 2, 4, 4)` inset — independently,
identically, down to the same two numbers. `Renderer.blankRegion()` replaced both, and
`destroyTexture` refuses its handle because a game destroying it would break every other
consumer's panels rather than only the one that asked. Clipping went in beside it: `setClip`
takes screen **points**, not the pixels `ui.md` §9 had written, because every other public
rectangle in `render2d` is in points and the pixel scale is a frame property the renderer
already holds.

**Step 2 changed the design rather than transcribing it, in one place.** `ui.md` §4 defines
capture as "a widget is hot or active", and that is right for a control and wrong for the thing
around it: **a panel is not a widget**, so a click on its empty half would have found nothing
hot, reported that the UI did not want the pointer, and walked the player through the wall
behind the panel. A container now takes the pointer without entering the hot/active model at
all. Making the panel a widget instead is the obvious alternative and it is wrong — a container
competing for `hot` would take the press meant for a control the pointer had just moved onto,
because `hot` is a frame old and the container is described first. `samples/room` at step 6 is
where that stops being an argument.

**The bug step 1's tests caught is the shape of bug this design is arranged to make findable.**
The safety net that ends a drag when the pointer is released outside the window was written in
`begin`, where it cleared `active` *before* any widget ran — so the release every button was
waiting for had already been consumed, and no button in the system could ever report a click.
Six tests failed at once and said so in one run, on a machine with nothing rendering. A UI that
could only be checked by clicking it would have shipped that.

The decision was taken on I4 and I5 rather than on taste. Dear ImGui is explicitly not a game
UI toolkit, so cimgui would not remove the obligation to write one — it would add a second
system that never shares a line with the first. And at M7 it forces a choice between mods
getting no UI while the first-party overlay has one, which is the private back door I4 forbids
and ADR-0011 exists to prevent, and re-exporting a third party's API through an ABI Foundry has
promised to version and not break. The argument usually decisive for cimgui — that it saves the
work — is weak here: Dear ImGui ships no renderer, Foundry's graphics API is its own, and the
`ImDrawData` bridge and the input bridge would be ours to write either way. **What it buys is
the widget set, not the plumbing.**

**The part neither prior document had settled is the substance: one kernel, two widget sets.**
A debug panel and a game's HUD differ in presentation and authoring, not in mechanism, so the
identity / hot-active / layout / clip core is written once, M6 layers a debug widget set on it,
and the content-driven skinnable game layer is designed for and postponed — paid for now only
by the rule that **no colour, font, metric or string in the kernel is a literal.**

**The module edge was the open question, and it is resolved: `ui` is L1 on `core` and
`platform`, and emits a renderer-agnostic draw list.** It never sees `render2d`. The deciding
argument was found by reading `render2d.BitmapFont`, which has six fields of which exactly one
— `glyphs: Region` — is a renderer thing; the rest is arithmetic. The split the draw-list option
needed was already drawn inside the struct, so "measurement must be injected" is a small metrics
value rather than a callback into the renderer. The cost that made the option look expensive was
not there. What it does cost is two draw vocabularies and a walker in `app`, and the walker's
one real hazard — the kernel measuring text differently from the renderer drawing it — is
answered by a single sanctioned conversion function and a test that measures a corpus both ways.

*(Previously: M5 is complete.)* `samples/room` was played and judged, and the mixer was
listened to — the two things no amount of building could establish, both answered by a person,
which is the only way either of them can be. The three sequences — collision, sprite animation,
audio — were finished earlier the same day; the playable sample was the last bullet, and it is
the one that turned out to be about the *shape of the repository* rather than about the engine.

**The sandbox could not be the playable sample, and saying why is the finding.** By M5 it was
2,424 lines carrying M0 through M5's evidence at once: four thousand orbiting sprites, a
frame-statistics readout, entity picking, world save and load, a resize key. Every one of
those is load-bearing for an earlier milestone and every one of them is exactly what "without
knowing it is a tech demo" rules out, so the roadmap was asking one artifact to satisfy two
requirements that contradict each other. **The answer is that `samples/` was always plural**:
a sample that demonstrates and a sample that plays are two different smallest things.

`samples/room` is the second. A dim stone hall, thirty-two cells by twenty-four, six unlit
lamps, a door that will not open until they are all burning, and a way out beyond it. It has
no statistics, nothing to click and no debug keys. **The engine gained nothing for it** — not
one line under `engine/`, and `tools/fpack` did not change either — which is the strongest
form the exit criterion's evidence can take: what M5 is really claiming is that Foundry can
carry a game, and a second consumer that needed no engine change is the proof of it.

*(Previously: M5's audio sequence completed, and with it all three of M5's sequences.)*
The sandbox walks a room it ships, animates as it goes, and now makes a noise doing it: a
footstep every third of a second, a thud against a wall, and an ambience panned by where the
player stands — all three from `.wav` files in its own content package, none of which has a
record, because a `.wav` becomes a `foundry:sound` from its path exactly as a `.png` becomes a
`foundry:texture`.

**This is the first second thread in the project**, and every decision in `audio` is downstream
of that one fact: the device calls Foundry on a thread it did not create, under a deadline
measured in milliseconds, where a mistake is an audible click rather than a dropped frame. So
the mixer's state is split by *which thread owns it* — no field is written by both — two
single-producer/single-consumer rings carry commands out and retirements back, and there is no
lock anywhere in the module. The one memory-ordering argument in Foundry is written down in
`ring.zig` where a future session will find it before simplifying it away.

**`scene` still cannot see `audio`**, which is what keeps audio's nondeterminism out of the
simulation structurally rather than by a rule someone has to remember (I9): the sample *causes*
sounds from the fixed step and *observes* none, and nothing could observe one even if it wanted
to. Both lifetime hazards `audio.md` §7 names are tested by doing them — the game dropping its
last asset reference mid-voice, and a hot reload replacing a sound while the device thread is
reading it. §10's Tier 1 claim was paid the same way the other two sequences paid theirs: a mod
replaced a sound the sandbox never wrote a record for, from a file under its own directory
layout, with nothing rebuilt but the mod.

796 tests under `-Drhi=null`, 804 under `-Drhi=metal` (900 and 908 as of M6 step 5). **M5's remaining work is its exit
criterion, not its bullet list**: five minutes of play.

This document changes every session. Durable principles live in `CLAUDE.md`; individual
decisions live in `docs/adr/`; milestone definitions live in `docs/ROADMAP.md`.

---

## Repository

**Canonical home: `github.com/sjoygsh/Foundry`** — public, Apache-2.0, established
2026-09-02. This repository is the engine, its tools, its samples and its documentation.
Games live in their own repositories and consume Foundry as a dependency (ADR-0017).

No CI, release automation or contribution infrastructure yet; those arrive when the project
is mature enough to need them rather than as decoration.

## Current phase

**Phase 2 — A real 2D engine.** Phase 1 (M0, M1) closed with the first pixels; M2, M3 and M4
are done, and **M5 — Playable: "it's a game" — closed 2026-09-06**, having started where the
last three did: at the decisions `CLAUDE.md` §9 had been holding for it, then the design
document, then code. Phase 2 is finished. **M6 — Tools: "it's inspectable" — opened 2026-09-06**
at the `CLAUDE.md` §9 decision that was due: the ADR is accepted, the design document is
written, and the first three of its six steps are implemented.

## Current milestone

**M5 — Playable: "it's a game." Complete, opened 2026-09-05, closed 2026-09-06.** Every bullet
— collision, sprite animation, audio and the playable sample — and the exit criterion with
them: `samples/room` was played and judged to read as a place rather than as a demonstration.

**The five-minute number was not met literally and is not being rounded up.** The autopilot
finishes the hall in 1,542 ticks, about twenty-six seconds of simulated time, and a person
exploring takes longer but not five minutes. The sample was deliberately not grown until it
did: one that keeps adding rooms to reach a number has started wanting features rather than
being the smallest thing that is a game, which is the point at which ADR-0017 says it belongs
in its own repository. **The load-bearing half of the criterion was "without knowing it is a
tech demo", and that half was met.**

**M6 — Tools: "it's inspectable" is the current milestone, opened 2026-09-06.** Its first
roadmap bullet said the UI toolkit decision is made here, and it was: **ADR-0024, accepted**,
with `docs/design/ui.md` written against it. §16 of that document is the step list, it is under
"Immediate next steps" below, and steps 1 to 5 of six are done.

What follows in this section is what **M5** opened with, kept because the decisions and the
design are what a future session needs and they have not changed; what was built against them is
under "What is being worked on".

**Two `CLAUDE.md` §9 decisions came due and were made, neither silently (rule 10).**

* **ADR-0022 — Foundry's own 2D collision, scoped to collision rather than dynamics.**
  Licensing did not decide this: Box2D v3 and Chipmunk2D are both MIT and both permitted. Two
  things did. A tile game needs a moving box tested against static geometry with a response
  that slides — not mass, inertia, restitution, friction solving or joints, which is most of
  what a rigid-body engine is made of. And **I9 raises the price of a ported solver
  specifically**: contact-resolution order changes the answer, it is an implementation detail
  a library is free to change between versions, and verifying it means reading someone else's
  solver as carefully as writing our own. `physics2d` is **L1 on `core` alone** — no entities,
  no content, no I/O.
* **ADR-0023 — Foundry's own mixer, and its own WAV decoding.** `platform` was already
  chartered with the audio device (§4.3), so the device was never the question. The mixer is
  ours because SDL3_mixer would leak SDL past `platform` (a §10 non-negotiable) and make its
  channel/music model the shape of Foundry's audio API, and because miniaudio is device +
  decode + mix as one stack and would displace that charter entirely. WAV decoding sits beside
  PNG in `asset`, on ADR-0018's reasoning, with the supported subset stated and everything
  outside it refused by name. The **null device is stepped rather than threaded**, which is
  what makes the mixer testable — the same role the null RHI backend plays.

**One scope decision, also the user's:** the sample is **top-down tile movement**, matching the
PokeMMO-like yardstick. That is what decides gravity, jump tuning, slopes and one-way platforms
are out of M5's collision scope rather than merely unbuilt.

**`docs/design/tilemaps-and-collision.md` is written.** Its load-bearing decisions: three
separable things get called "tilemap" and it separates them (a grid of numbers, drawing it,
colliding against it), meeting only in the game that uses them; `physics2d` holds **no time and
no velocity** and integrates nothing, so a caller says *move this by that* and is told where it
stopped, which keeps movement feel in the game and leaves the module with no clock to read;
the tile grid is a **first-class shape source** rather than ten thousand static boxes, which is
what makes neighbour-aware face culling possible and turns the internal-edge snag into an exact
fix rather than a tolerance; the spatial hash may bucket however it likes but candidates are
**sorted by handle before use**, so the acceleration structure is replaceable without changing
a result; a body carries an opaque `u64` rather than an `Entity`, which is the entire coupling
to `scene` and is why collision works with no ECS at all; the grid's bulk is an **asset**,
because ten thousand integers in a `.fdt` file is a binary payload in disguise (§6); and M5
adds **no engine-owned component types**, because a `foundry:collider` invented now is a name
every mod is stuck with from M7, and that vocabulary should be chosen when the ABI freezes it.

**`docs/design/audio.md` is written**, and it is M5's longest document because audio is the
first subsystem in Foundry with a second thread. Its load-bearing decisions: mixer state is
**split by which thread owns it**, so no field is written by both, and **two SPSC rings** carry
commands out and retirements back — which is why no lock appears in the module. The device
speaks **`f32` interleaved and that is not negotiated** (a sample-format enum would put a
`switch` in the mixer's inner loop for a case that exists only because a driver is old); sample
rate and channel count *are* negotiated, because they change what the mixer computes. A
`VoiceHandle`'s generation is the answer to the oldest bug in game audio — stopping a footstep
that already ended and silencing the door that took its slot. **Two lifetime hazards get two
mechanisms**: the mixer holds the asset reference for a voice's life, and it keeps *its own*
retirement, the same answer `render2d` gave for GPU resources, so hot reload cannot free
samples out from under the callback. The document is explicit that the stepped null device
proves the arithmetic and the protocol but **not** the ring under real concurrency. Two things
it settled that ADR-0023 left implicit: **the mixer opens the device**, so `app` gains no
dependency on `audio` at all; and `scene` and `audio` are both L3 with no dependency between
them, so a system *cannot* reach the mixer — I9's emit-never-observe rule enforced by the build
graph rather than by documentation.

**`docs/design/sprite-animation.md` is written**, and short, because its answer is that the
crossing it was written to resolve is not one. Once animation state is an **integer tick
count**, `scene` holds a tick and a frame index and never learns what a texture is, `render2d`
turns an index into a region and never learns what an entity is, and I7 would not have let them
meet anyway. A float accumulator is refused on three grounds and the deciding one is that it
makes "which frame at tick 700?" only *nearly* answerable. The component stores a frame
**index, not a `Region`**, because a `Region` carries a `TextureHandle` and a component is
serialized — the rule ADR-0021 already set for textures. The engine's whole contribution is
`frameAt`, `frameAtVarying` and a `Region.cell` grid cut; the clip schema and the animation
component are the sample's, for the same reason M5 adds no `foundry:collider`.

**Nothing is owed before the code now.** Three documents, three implementation orders:
`tilemaps-and-collision.md` §15, `audio.md` §13, `sprite-animation.md` §10.

**All three sequences' implementation orders are in their own documents**, and two are
struck through: `tilemaps-and-collision.md` §15 (steps 1-7, done), `sprite-animation.md` §10
(steps 1-3, done) and `audio.md` §13 (six steps, not started). Each document's Resolution
sections carry what implementation settled that the design did not; those are the record, and
this file does not duplicate them.

**The milestone behind it — M4 — World: "it has entities." Complete, 2026-09-05.** Every item
on its ROADMAP list is done and both exit criteria are met. `docs/design/entity-storage.md`
settled six things ADR-0010 left open; the ones worth carrying forward are that a component
type is identified by a **handle** rather than an index, so unloading a mod one day cannot
leave dangling references; that a zero-size component is legal and means a marker; that a
component referencing an asset holds the **content ID**, never a handle, which is the same fact
as `scene` needing no `asset` dependency; that a world cannot borrow the engine's schema
registry, because hot reload replaces it; and that because the two registries are therefore
separate, a spawn has to **check that a package's schema agrees with the registered one** —
the deserializer matches by position, so an unchecked mismatch would read `y` into `x`.

## What has been implemented

**`core` (L0), `platform`, `data` and `physics2d` (L1), `rhi` (L2) with two backends,
`asset` (L2), `render2d` and `scene` (L3), `app` (L4), plus `tools/fpack`. It draws thousands
of sprites under a camera that pans, zooms and picks, and it loads content by content id.
`scene` holds entities, component types, queries and systems; entities can be described in
content, and a whole world can be written to a file and read back with its handles intact.
`physics2d` holds shapes, bodies and tile grids, and can move a body along a wall without
catching on the seams between its tiles. A map is content from a hand-written text grid
onward; the sandbox draws the one it ships, and a player walks it and is stopped by its
walls. There are **two samples**: `samples/sandbox` demonstrates the capabilities and
`samples/room` is a small game built out of them.**

**M5, newest — `samples/room` and its content package.** A second consumer of the engine,
built from the engine exactly as it already was:

* `samples/room/main.zig` — the sample. Its own `Settings`, `Map`, `Clip`/`Clips`, six
  component types (`room:transform`, `room:visual`, `room:solid`, `room:animation`,
  `room:lamp`, `room:doorway`), one system, and `Place.of` — the only function that knows the
  authoring grid is top-down, the runtime grid is Y-up and the world origin is the middle of
  the map.
* `samples/room/content/room.fdt` — four schemas the room defines (`settings`, `clip`, `lamp`,
  `door`, `way_out`), and every record the hall is made of. Nothing the sample draws, says,
  plays or places is in the source.
* `samples/room/content/grids/hall.grid` — 32x24, written the way it looks.
* `samples/room/content/textures/room.png` and five `.wav`s — generated by
  `scripts/gen-room-assets.py`, committed so the sample decodes them through the engine's own
  decoders, generated by a script so the binaries in the tree are reproducible.
* `build.zig` — a `room` module and executable, `room:content` in the load order, a `room`
  run step, and the sample added to the `check` step so it carries the portability obligation
  like the sandbox does.

**M5, new (steps 1 through 7 of `tilemaps-and-collision.md` §15 — the whole sequence):**

* `engine/src/physics2d/shape.zig` — `Shape` (box as **half-extents**, so every test is a
  Minkowski sum rather than four subtractions at the call site; circle), `Bounds`, `Contact`
  with the convention *the normal points from `b` toward `a`, and moving `a` by
  `normal * depth` separates them exactly*, and **`Rounded`, the one shape the module actually
  computes with**: an axis-aligned box grown by a disc. Every pair reduces to one and the
  reduction *composes* — the Minkowski sum of two rounded boxes is a rounded box whose
  half-extents and radius are the sums — so box-box is a rounded box of radius zero,
  circle-circle is one with no box left, and a raycast is the target's own form because a point
  adds nothing. That leaves **one static test** (`overlapRounded`) and **one swept test**
  (`sweepRounded`) answering every combination, and it removed the `flip` helper that existed
  to stop the box-circle and circle-box cases disagreeing.

  The swept test is the union of two overlapping boxes and four corner discs, because entering
  a union happens at the earliest entry into any part. Its two conventions both exist so a body
  sliding flush along a wall reports nothing — a graze is a miss, and on a zero-motion axis the
  slab boundary counts as outside. A sweep that **began** overlapping says so with a zero
  normal rather than pretending to hit at fraction zero, because a sweep cannot resolve a
  penetration that is behind it.
* `engine/src/physics2d/body.zig` — `Body`, `BodyHandle`, `BodyKind`, and the **symmetric**
  layer/mask filter: both sides must admit the pair, so the situation where A is pushed by B
  but B is not pushed by A cannot arise. `user` is an opaque `u64` and is the entire coupling
  to the rest of the engine.
* `engine/src/physics2d/grid.zig` — `Grid` (borrowed `tiles` and `solid`, so the module never
  learns what an asset is), the clamped cell range, the row-major cell walk, `overlapsShape`,
  `sweepShape`, `deepestOverlap`, and **`facesAt`, which is the internal-edge fix**: a face
  whose neighbouring cell is also solid is interior to the wall and cannot legitimately be hit.
  Four bit tests per cell, exact rather than a tolerance, and impossible for a pile of static
  boxes because a box does not know its neighbours. The rule extends to a **rounded corner**,
  which is admitted only when both of its adjacent faces are — the neighbour's own expansion
  covers it otherwise. Two regression tests slide a box and then a circle twelve half-cells
  along a tiled floor and fail on *any* reported contact. A walk records a cell it began inside
  and **carries on**, because stopping there would let a body overlapping one tile pass through
  every tile beyond it.
* `engine/src/physics2d/broadphase.zig` — a uniform spatial hash in **two tiers**, because
  most bodies do not move in most ticks: static bodies live in their own hash that is untouched
  while movable ones move. Updates are incremental and exit early when a body's cell span did
  not change, which is the common case. `Broadphase.query` collects, **sorts by handle index
  and deduplicates**, which is the rule that makes the whole file replaceable — a different
  structure producing the same candidates produces the same results. A body too large to bucket
  goes in a spill list every query considers, which is a guard against content rather than a
  tuning knob.
* `engine/src/physics2d/world.zig` — generational pools for bodies and grids, validation at
  the boundary (a degenerate shape or a malformed grid is refused, never asserted), `setPosition`
  named as the teleport it is, iteration in ascending handle-index order, and `queryBounds`,
  which narrows the broadphase's candidates by mask and by an exact bounds test. A body is read
  through a **const pointer** and changed through named calls, so nothing can move one without
  the broadphase hearing about it.

  And, from step 4, the movement: **`moveAndSlide`** — iterative swept resolution against grids
  first and then bodies, holding the body a `contact_skin` clear of what it hits and projecting
  what is left onto the contact plane, which is what makes a stop into a slide, within a
  `max_slide_iterations` budget of four that is documented because a caller can observe it. It
  **commits** the move and updates the broadphase, because a call that returned an answer and
  left the bookkeeping to the caller is one every caller eventually forgets to finish.
  **`resolveOverlaps`** is deliberately separate: a penetration is behind the sweep and cannot
  be swept out of, and keeping it apart makes "stuck in a wall" a state a game can detect
  rather than a silent teleport. Then **`overlapPoint`, `overlapShape`, `raycast` and
  `shapeCast`**, all with caller-supplied buffers that report how many hits there *would* have
  been — the shape ADR-0004 will need at M7, adopted now because it costs nothing. No query
  takes a callback. `Hit` and `QueryHit` use the **null handle** rather than an optional, for
  the same ABI reason.

  **`sync` is not implemented**, and that is the standing rule about open questions being
  honoured rather than an omission: design question 4 asks whether trigger enter/exit belongs
  in this module at all, and step 4 did not force the answer. Triggers block nothing and
  `overlapShape` finds them exactly.
* `engine/src/physics2d/root.zig`, and the module in `build.zig` at L1 on `core` alone.
* `engine/src/asset/tilegrid.zig` — the authoring format (decimal ids, `#` comments, rows
  **written top first and stored bottom first**, reversed once here because world Y is up) and
  the `foundry:tilegrid` runtime format (`"FGRD"`, the
  version in a **field** rather than in the magic, a little-endian `u16` array, row 0 at the
  bottom because world Y is up), its reader, its writer and its loader. Reader and writer are
  one file so the round trip is a test rather than a hope, and `fpack` uses the writer rather
  than owning a second idea of the format. No size limit is needed: `width * height` must
  agree with the byte length exactly, so a header claiming a billion cells is refused by the
  file it arrived in.
* `engine/src/asset/tilemap.zig` — `foundry:tileset`, `foundry:tilemap.layer` and
  `foundry:tilemap`, their typed readers, and `solidBitset`, which turns a tileset's `solid`
  list into the array `physics2d.Grid` borrows. **In `asset` rather than `render2d`** because
  `fpack` must register them without linking a renderer; the readers exist because the two
  domains the checker cannot hold — a list of exactly two, and a sort layer that fits an
  `i16` — have to be checked somewhere, and once rather than in every consumer.
* `tools/fpack/pack.zig` — a third walk category for authoring-format assets, and
  `compileGrids`, which turns each `.grid` into a `.fgrid` under `--assets-out` and appends
  the emitted path to `walk.assets`. Derivation then mints its record with **no special
  case**, because the authored path and the emitted one derive the same content id.
* `build.zig` — `--assets-out` wired through, installed over `content/<stem>`; and
  `addDirectoryInputs`, which fixes a **pre-existing staleness bug**: `addDirectoryArg` passes
  a directory and creates the dependency but does not put its contents in the Run step's cache
  key, so editing content did not re-run `fpack` and the build installed yesterday's `.fpk`.
* `samples/sandbox/content/grids/room.grid` and the map records in `sandbox.fdt` — a
  hand-written 12x10 room with a solid border, which is what the player now walks around.
* `engine/src/render2d/tilemap.zig` — `TilemapLayer` and `Tiles`, the pure half of drawing: a
  layer and a visible rectangle in, a run of ordinary `Sprite`s out, with no device, no
  allocation and no renderer state. The span is **half-open** to match `Rect.overlaps`, which
  is what keeps a view whose edge lands on a cell boundary from drawing an extra column and an
  extra row forever. Public, so a game can have the culled span without drawing it.
* `engine/src/render2d/renderer.zig` — `drawTilemap`, the loop over `Tiles` with the texture
  check made once rather than per tile, and `Stats.tiles`. **The signature drops the design's
  `view` parameter**: `setView` is how every other draw names a space, and an inconsistency on
  one entry point out of three is one the M7 ABI freeze would make permanent.
* `engine/src/render2d/view.zig` — `View.visible`, the rectangle of a view's own space that it
  displays. A camera's bounding box or a screen view's own rectangle, resolved once per frame.
* `engine/src/asset/tilemap.zig` — `foundry:tilemap.layer` **version 2**, appending optional
  `empty`: the tile id that draws nothing. `optional` and not defaulted, because absent and
  zero are different answers and tile 0 is usually a map's ground.
* `engine/src/app/engine.zig` — registers the `foundry:tilegrid` loader beside the tilemap
  schemas. A texture loader must come from whoever owns a renderer; a grid loader needs
  nothing, and a game that can compile a map should not find it cannot load one.
* `samples/sandbox/main.zig` — `Map`, which is §11's "the game wires them" written out: records
  in, two `acquire` calls by content id, and **both** consumers out — a `TilemapLayer` for
  `drawTilemap` and, for any layer whose record says `collides true`, a `physics2d.Grid` over
  the identical `[]const u16`. Where the map goes is the sample's decision (it centres its
  own); what is on top of what is content's (`order -10`); which layers are solid is content's
  too. One ordering rule runs through it: a grid leaves the collision world **before** the
  arrays it borrows are freed, because `addGrid` copies the descriptor and not the tiles.

  Then the player, and it is not a special case: an entity with a `Transform`, a `Visual` and
  the sample's own `Collider`, drawn by the same loop as the other four thousand. *Having a
  collider* is the whole of what makes it the player. The body is **not** on the entity —
  a `BodyHandle` is runtime identity that I1 forbids serializing — so the component is what a
  save carries and `adoptPlayer` derives a body from it, on a spawn, on a load and on a
  repopulate alike. `walk` runs in the fixed step, reads the step's frozen input snapshot and
  calls `moveAndSlide`; it cannot be a `scene` system, because a system is handed the tick and
  nothing else precisely so it cannot read a device.
* `samples/sandbox/content/sandbox.fdt` — `player_size` and `player_speed` on the settings
  schema. Gameplay numbers come from content; appearance is generated, like every other
  sprite's. The line I5 draws, in the one file that shows a game where to draw it.
* `build.zig` — the sandbox imports `physics2d` directly, as it already imports `scene`. `app`
  owns no collision world and should not: the module holds no time and integrates nothing, so
  when to move a body and what to do about what it hit is gameplay.
* `engine/tests/tilemap_pipeline.zig` — the seam no module can test alone: authored text and a
  real grid file, through the registry **by content id and never by path**, into a collision
  world, ending with a body stopped by a tile a file said was solid. It links no renderer,
  which is the placement decision being exercised rather than merely asserted. A second test
  adds the other consumer: the cell `render2d` *draws* at a world position is the cell
  `physics2d` *collides* with there — one slice, two modules that cannot see each other, and a
  claim neither can check alone, and the map in it is deliberately **not** at the origin,
  because an origin applied on one side of that diagram and not the other is a map you collide
  with several cells from where you see it. A third makes §12's Tier 1 claim a test rather than
  a paragraph: a second package restates one tileset record with a different `solid` list, the
  map and the grid asset and the layer record are byte-identical across both halves, and a body
  that was stopped by a wall walks straight through it.
* `engine/src/render2d/animation.zig` — `frameAt` and `frameAtVarying`, and **that is the
  engine's whole contribution to sprite animation** besides the grid cut below. Pure integer
  functions of a tick count, so the same tick yields the same frame on every machine, in a
  replay and after a reload (I9). A zero `frame_ticks`, a zero `frame_count` and an empty or
  all-zero hold list all yield frame 0 rather than dividing by it, because every one of those
  numbers came out of a file. Their own file rather than `atlas.zig`: the module surface puts
  them beside `Region`, which is what §3 asked for, and `atlas.zig` is about packing.
* `engine/src/render2d/atlas.zig` — `Region.cell`, the grid a sprite sheet is, built on `sub`
  so a sheet in a shared atlas slices identically to one with a texture of its own. **Out of
  range is empty rather than clamped** — a zero grid dimension, an index past the last cell, or
  a region too small to divide — because a clip running off its sheet should vanish and send
  its author to the clip, where a clamped one shows a *stuck* animation indistinguishable from
  a non-looping clip working correctly.
* `samples/sandbox/content/sandbox.fdt` — the `clip` schema and three clip records, plus
  `player_walk`, `player_idle` and `field_clip` on the settings record. **The engine defines no
  `foundry:clip`**, for the reason it defines no `foundry:collider`: a schema name is a
  compatibility decision, M7 is when the mod-facing vocabulary is chosen, and nothing in the
  engine reads a clip. Which clip plays is content too, not only the clip itself.
* `samples/sandbox/main.zig` — `Clip` and `Clips`, the table resolved once per content
  generation and handed to the system as its context, because a `scene` system is given the
  tick and nothing else and so cannot read a record. `Animation`, three integers, holding a
  content id rather than a handle or a table index because it is serialized. `animationSystem`,
  which *is* a system where `walk` could not be. `play`, which restarts a clip only when it is
  a different one. And `cellOf`, which is §6's diagram written out — and which replaced the
  hand-rolled sheet slicing `spriteOf` had carried since M2 with one `Region.cell` call.
* `engine/tests/sprite_animation.zig` — the check step 3 exists for, and it had to stand above
  two modules that cannot see each other: three entities on three clips of different periods,
  stepped to a tick that is a multiple of none of them, saved, loaded into a fresh world, and
  compared as **the UVs a draw call would carry, bit-exactly**. An epsilon there would pass for
  the float accumulator §4 refuses. Then four hundred more ticks on both, because a save that
  restored the frame but lost the elapsed count passes the first check and fails on the next
  tick. Also: a clip still in phase after a hundred thousand ticks, a one-shot pinning across a
  reload, and one cycle visiting every cell in order and wrapping onto the first.
* `docs/modding/content-mods.md` — a §7 for animations, and a "your first mod" that **is** a
  clip override, verified by following it verbatim. It replaced a settings-override example
  that had gone stale: a shorter settings schema now silently turns off the map and every
  animation, which is a bad first experience and a worse first document.

**M5, also new (steps 1 through 6 of `audio.md` §13 — the whole sequence):**

* `engine/src/asset/sound.zig` — `Sound`: interleaved `f32`, one or two channels, and the
  rate the file declared. `image.zig`'s counterpart, and the symmetry is the argument — one
  layout every decoder expands to, so the consumer that matters never switches on a format
  enum in its inner loop. Nothing here is resampled: a voice converts as it plays, which is
  the same operation as pitch.
* `engine/src/asset/wav.zig` — the decoder, written rather than depended on (ADR-0023, and
  ADR-0018's reasoning): PCM at 8, 16, 24 and 32 bits, IEEE float at 32,
  `WAVE_FORMAT_EXTENSIBLE` resolved through its sub-format GUID, mono and stereo. Everything
  else is refused **by name** — ADPCM, mu-law and A-law get a sentence saying what the file
  is. **The format is asked before the bit depth**, because four bits is nonsense for PCM and
  correct for ADPCM, and a decoder that asks the other way tells an author their file is
  corrupt when it is merely compressed. A non-finite sample in a float WAV refuses the file:
  one NaN in the mix accumulator silences everything for the rest of the session. The frame
  limit is *proved* to precede the allocation by a failing allocator, not asserted to.
* `engine/src/asset/schemas.zig` — `foundry:sound`, version 1, `source` only, with `wav` in
  the extension table. `fpack` needed no change at all: it already walks that table, so a
  `.wav` in a package becomes a record with no code and no authoring.
* `engine/src/platform/audio.zig` and the two backends — `AudioDeviceHandle` (generational,
  because an output device is closed and reopened in normal use when headphones are
  unplugged), `AudioConfig`, `AudioInfo`, and the callback rule written on the function
  pointer type where an implementer will read it. **The device speaks `f32` interleaved and
  that is not negotiated.** The null backend's device is **stepped, not threaded**: a
  synchronous pull of exactly the frames asked for, returning what the callback wrote, which
  is what makes every mixer test reproducible. SDL3 adopts the device's own sample rate —
  Foundry's voices resample anyway, so this removes SDL's resampler from the path — and fills
  whole blocks into the stream's queue, so Foundry's callback always gets the block size it
  was promised.
* `engine/src/audio/ring.zig` — the single-producer/single-consumer queue, twice over, and
  **the whole of Foundry's concurrency design**. Push writes the slot then stores the tail
  with release; pop loads the tail with acquire then reads the slot. For the retirement ring
  that pair is what makes the device thread's last read of a sound's samples happen-before the
  game thread's free of them. A full ring drops and counts, because it cannot block, cannot
  grow and cannot report to a caller on the other thread.
* `engine/src/audio/voice.zig` — one playing sound as the device thread sees it, plus the
  arithmetic separated out so it can be argued with rather than merely observed:
  constant-power pan (`cos`/`sin` of `(pan+1)·π/4`, computed once per command), the resample
  step as one multiplication of a rate ratio by a pitch, an `f64` cursor, and linear
  interpolation. A loop **wraps** its cursor rather than resetting it, so it does not
  accumulate a fractional-frame error every pass. Pan is ignored on a mono device rather than
  summed, which would make a centred sound quieter than a hard-panned one.
* `engine/src/audio/mixer.zig` — the voice table split by which thread owns it, the command
  and retirement rings, the callback, and the game-thread API. **No field is written by both
  threads**, which is why there is no lock. A `VoiceHandle`'s generation is the answer to
  stopping a footstep that ended 300 ms ago and killing the door that took its slot. Three
  things implementation forced: a dropped `play` **returns an error and undoes its claim**
  where every other dropped command is merely counted, because a `play` that vanished would
  strand a slot no retirement is coming for; the retirement ring is sized to the voice count,
  which makes dropping one structurally impossible rather than unlikely; and a one-shot ends
  in the buffer it runs out in rather than the one after. `soundLoader` registers upward into
  `asset.Registry` (I6) with a `SoundHandle` payload rather than a pointer, which is what lets
  a reload retire a sound a voice is still reading. `shutdown` is the third teardown call the
  design did not have, and §7's two requirements wanting opposite orders is why.
* `engine/tests/sound_pipeline.zig` — `.fdt` and a `.wav` on disk to samples in a device
  buffer, and the two lifetime hazards done rather than described: the game dropping its last
  asset reference mid-voice, and a reload saving a quieter take over a playing loop while two
  sounds live at once. `testing.allocator` is half of each assertion — early is a
  use-after-free on the device thread, late is a leak.
* `scripts/gen-sandbox-sounds.py` and `samples/sandbox/content/sounds/` — three WAVs, each
  exercising something different: 22050 Hz so the voice resamples, 48000 Hz so it does not,
  and a half-second ambience whose partials complete a whole number of cycles so the loop
  wraps silently. Generated by a script for the reason the sprite sheet is: a binary in the
  tree should be reproducible rather than mysterious.
* `samples/sandbox/main.zig` — the mixer created by the game, its loader handed up, and three
  sound ids read from the settings record. A footstep is a tick count in the fixed step, a
  thud is a contact, and the ambience is panned once a frame from where the player is drawn —
  the simulation causing sounds and observing none, which is structural rather than a rule
  (`scene` cannot see `audio`).
* `docs/modding/content-mods.md` — a §8 for sounds: the accepted subset, why an unsupported
  format is a different sentence from a corrupt one, that any sample rate is fine because a
  voice resamples, and that overriding works even when the original had no record.

**M4, new:**

* `engine/src/scene/entity.zig` — `Entity`, a `core.Handle` over an opaque tag. No entity
  object exists anywhere, which is why the type is not called `EntityHandle`.
* `engine/src/scene/component.zig` — `ComponentTypeInfo`, the runtime description ADR-0010
  requires, carrying a `data.Schema` as its identity and shape; `ComponentType`, a handle
  rather than an index because unloading a mod will one day unregister a type; and
  `Registration`, what the world keeps, which holds the schema **handle** so a later
  package's extension is followed rather than shadowed.
* `engine/src/scene/world.zig` — `World`: entity create and destroy over `core.HandlePool`,
  component type registration with every check in the design's §6, and the mutation counter
  step 4's query iterators will capture. It borrows the schema registry rather than owning
  one, so a component type and the record defining an instance of it cannot disagree.
* `engine/src/scene/store.zig` — `ComponentStore`, the type-erased sparse set: `sparse` by
  entity index, dense `owners` and dense bytes. Every lookup compares the **whole** handle
  against the owner recorded beside the data, which is what stops a reused slot inheriting a
  component. Swap-removal, `construct`/`destruct` including on teardown, and a dense block
  that over-allocates so it can align its own base — `Allocator.alloc` cannot express a
  runtime alignment and `rawAlloc` says it is not for callers.
* `engine/src/scene/derive.zig` — `componentType(T)`: the schema derived from a Zig struct,
  `deserialize` and `construct` generated over it, and a compile error naming any field that
  does not project onto the closed type list. It **produces** registration data rather than
  being a second registration path, which is what ADR-0010 requires of it.
* `engine/src/scene/save.zig` — `.fsav`, the save format. Not a package: giving every
  entity a content id would derive identity from position, which is what I2 forbids. It
  carries the entity pool's exact state, so a reloaded world hands out the same handles and
  an `Entity` inside component data needs no remapping pass; every component type's full
  schema, so an older file is read against the shape it was written with; and each store's
  dense array in dense order, so iteration order survives. A type this build does not know
  is reported and skipped. The reader validates everything before applying anything, and
  every single-byte change to a save is a test.
* `engine/src/core/handle.zig` — `slotAt`, `freeSlots` and `restore`. The only way to make
  a pool hand out a handle it did not issue, and therefore the only way the above works;
  the one entry point in `core` whose input is not the pool's own, so it validates rather
  than asserts.
* `engine/tests/world_pipeline.zig` — M4's exit criterion as one chain: `.fdt` text to
  package to store to entities to systems to a save to a second world that has never seen
  the content, checked to carry on bit-identically and save to the same bytes.
* `samples/sandbox/main.zig` — the sample defines three component types of its own
  (`sandbox:orbit`, `sandbox:transform`, `sandbox:visual`), registers them and one system,
  and spawns 4,000 entities. Drawing and picking are both queries over the same two
  components in the same order, which is what keeps "topmost" meaning the same thing to the
  pick as to the batcher. **It owns the `data.Registry` its world borrows**, because hot
  reload replaces the engine's. F5 writes the world and F9 reads it back, and
  `FOUNDRY_SANDBOX_SAVE` / `_LOAD` do the same from a script — so one run can leave a world
  behind and the next can start from it, which is the only honest check that a save survives
  a restart rather than a round trip in one process.
* `engine/src/scene/system.zig` — `System` and `Tick`, runtime-registered like everything
  else here, run in registration order. A system gets the world and the tick and **not**
  input or a clock, because `platform` is not below `scene`; input reaches it as data the
  game wrote down, which is the shape replay wants anyway.
* `engine/src/scene/schemas.zig` — `foundry:entity` (a list of component records) and
  `foundry:scene` (a list of templates). **No new `.fdt` syntax**: the closed type list
  already has `[id]`, and a component instance being its own record is what lets a mod
  override one component without restating the entity. `fpack` registers both, so an author
  never declares an engine-owned record type — the same treatment `asset.schemas` gets.
* `engine/src/scene/world.zig` — `spawn` and `spawnScene`, both all-or-nothing, both
  checking that the package's schema for a component agrees with the registered one about
  every field they share. Position matching would otherwise read the right bytes into the
  wrong field.
* `engine/src/data/fpk.zig` — `List.idAt`, so reading a list of references needs no
  allocator; and then the larger change M4 needed from `data`: the field-block layout and
  the self-describing schema encoding became their own types — `BlockWriter`, `Block`,
  `Blocks`, `SchemaWriter`, `SchemaDecoder` — with `.fpk` a container around them rather
  than their owner. `Fields` and `List` hold a `Blocks` instead of a `*fpk.Reader`, so the
  **reading** code cannot tell a save from a package. `PackageTooLarge` became `TooLarge`,
  since the writer is no longer only a package's.
* `engine/src/scene/query.zig` — `Query`, driven by the **first** named component's dense
  array rather than the smallest, so iteration order is a property of the query as written
  and not of the data (I9); and `TypedQuery`, the same iterator with the casts written for
  it. A query holds its types by value, so it has no lifetime of its own.
* `engine/src/scene/limits.zig` — `max_entities` and `max_component_types`. A save file says
  how many entities to create, so the bound is a refusal and not an assertion.
* `build.zig` — `scene` in the layering table with `core` and `data`. **Not** `asset`, which
  ADR-0007 allows: nothing here acquires one, and a dependency a module does not use is a
  claim the build cannot check. Confirmed by breaking it — importing `platform` fails with
  *"no module named 'platform' available within module 'root'"*.

The lists below are older, kept as the record of when each piece landed; italic notes mark
what a later milestone changed.

From M2, when this list was last rebuilt:

* `engine/src/render2d/atlas.zig` — `Packer` (a shelf packer, best fit by height, no GPU
  and no allocator beyond its own list) and `Region`, whose `sub` cuts in the region's own
  pixel space so that packed and standalone images slice identically.
* `engine/src/render2d/text.zig` — `BitmapFont` over a `Region`, and `Layout`, the one
  definition of where each glyph goes that both drawing and `measure` run. Untrusted bytes
  throughout: invalid UTF-8 and missing glyphs draw the substitute.
* `engine/src/render2d/renderer.zig` — `createAtlas`, `atlasAdd`, `atlasFill`,
  `destroyAtlas`, `textureRegion`, `drawText`, and `Stats.glyphs`. `render2d` also has its
  own `Extent2D` now: `textureSize` used to return an `rhi.Extent2D`, and a game that had
  to name an RHI type to ask how big its texture is would be touching the RHI (§4.2).
* `engine/src/rhi/` — `Origin2D`, `Extent2D.mipLevel`, and `BufferToTextureCopy.dst_origin`,
  threaded through the Metal shim. **Rule 10 grew** to cover a copy's region lying inside
  the resource it addresses; the contract in `rhi.md` §11 moved first, as that section
  demands of any tightening.
* `samples/sandbox/assets/font.png` and `scripts/gen-sandbox-font.py` — 95 glyphs on a 16x6
  grid of 8-pixel cells, drawn as ASCII art in the script so the font has a source and not
  only a binary. Ours, so no third-party licence entry (ADR-0016), and `render2d` still
  ships no glyphs (I5). *Moved at M3 step 9 to `content/core/fonts/debug.png` and
  `scripts/gen-debug-font.py`: it is the engine's font, loaded as `foundry:fonts.debug`.*
* `samples/sandbox/main.zig` — one atlas holds the sheet, the font and the white patch, so
  700 sprites, four outline quads and 31 glyphs are **three batches and three draw calls**.
  A world-space banner and a screen-constant selection label, deliberately both. *The atlas
  went at M3 step 9: assets arrive as standalone textures and the sample now draws 5
  batches. See step 9's notes for why that is the honest state rather than a regression to
  fix here.*

Earlier this session:

* `engine/src/render2d/camera.zig` — `panByScreen` and `zoomAround`, the two camera
  operations that are maths rather than policy, both derived from `screenToWorld` and both
  validating the whole change before committing it.
* `engine/src/render2d/sprite.zig` — `containsPoint`, the exact inverse of `writeQuad`'s
  transform, sharing its extents through one `localExtents`.
* `engine/src/app/engine.zig` — `frameDelta`, the wall-clock frame time the engine already
  measured for the stepper. Presentation only (I9).
* `samples/sandbox/main.zig` — the camera is state the sample owns and input drives; a
  click picks the topmost sprite under it and outlines it with a one-pixel white texture
  built in memory. `FOUNDRY_SANDBOX_PICK_EVERY` scripts a pick at the window's centre.

Earlier still this session:

* `engine/src/asset/` — `Image` (always RGBA8, straight alpha, sRGB), Foundry's own PNG
  decoder (ADR-0018) and `loadImage`. No cache: one with no consumer would be speculative.
  *`loadImage` was removed at M3 step 8, as its own doc comment said it would be; the
  registry replaced it.*
* `engine/src/render2d/` — the whole batcher. `color.zig`, `camera.zig`, `texture.zig` with
  its retirement queue, `sprite.zig`, `batch.zig` with the `(layer, submission index)` sort
  key, `renderer.zig` with the per-slot buffer pool and both memory paths, and
  `shaders/sprite.metal`.
* `engine/src/rhi/` — the `clip_space` contract, `waitIdle` on the interface and both
  backends, and the `premultiplied_alpha` and `additive` blend states.
* `engine/src/app/engine.zig` — `renderFrame`, which owns the frame and takes an `anytype`
  recorder so the game never sees a command buffer or a pass.
* `build.zig` — `asset` and `render2d` in the `layering` table; the `sprite_metallib`
  embed under Metal.

From M1:

* `engine/src/platform/` — **`setWindowSize` joins the backend interface**, with its
  conformance-check entry, both backend implementations, and four tests. Logical size only,
  and a *request* rather than a setter — see the decisions below. `Engine.setWindowSize`
  passes it through; `samples/sandbox` cycles window shapes on `R`, or on a timer when
  `FOUNDRY_SANDBOX_RESIZE_EVERY` is set, which is what finally made the swapchain resize
  path checkable.
* `build.zig` — `metalLibrary`, the shader build step (ADR-0015): `xcrun metal` per source
  to `.air`, then `xcrun metallib` to link. Always through `xcrun` and never a hardcoded
  path (ADR-0014), and compiled with `-gline-tables-only -frecord-sources` so a frame
  capture shows the shader rather than disassembly. This is also the concrete answer to
  ADR-0014's claim that Zig's build system suffices: a shader compiler is an ordinary build
  step with declared inputs and outputs, so it is cached and re-run exactly when a source
  changes.
* `samples/sandbox/shaders/quad.metal` — Foundry's first shader. Every binding index in it
  is spelled out with the `rhi.md` §9 rule it comes from, because that is the documentation
  a mod author will eventually be reading.
* `samples/sandbox/main.zig` — the textured quad: staging arena, `device_local`
  destinations, batched barriers, a bind group, a pipeline layout and a pipeline. Its
  `Vertex`, `Constants` and `Frame` structs are `comptime`-asserted against the sizes and
  offsets the MSL declares, the same discipline as the shim's `_Static_assert`s.
* `scripts/check-targets.sh` — a Metal `check` as well as a Metal `test`, since `zig build
  test` does not depend on the sample and would otherwise never run the shader build step.

Earlier this session:

* `engine/src/rhi/backends/metal/` — the first backend that produces pixels:
  * `metal_shim.h` / `metal_shim.m` — the C boundary of ADR-0012, 60 functions, ARC,
    clean under `-Wall -Wextra`. Mirrors Metal one-to-one and holds **no policy**.
    Declares Metal's enum values and `_Static_assert`s all 86 of them against the real
    `MTL*` constants, because Zig cannot parse Objective-C headers and an unchecked
    constant would render something subtly wrong with no error anywhere.
  * `backend.zig` — all 40 interface functions: format translation, the §9 argument-table
    flattening computed once per pipeline layout, the frame ring, resize, and the blit
    upload path. Does **not** validate, deliberately — that is the null backend's job.
* `build.zig` — `-Drhi=metal`, with the shim, its include path and the Metal, QuartzCore
  and Foundation frameworks attached to `rhi` and nothing else. Metal on a non-macOS
  target fails immediately with a message rather than at link time.
* `samples/sandbox/` — now clears the screen, on both backends, so the headless run puts
  the same command stream through the validation backend.
* `scripts/check-targets.sh` — seven combinations now, Metal included.

Earlier this session:

* `docs/design/rhi.md` §9 — the **Metal binding index convention**, written before the
  backend that needed it (see "decisions" below), plus `max_vertex_buffers` as a third
  guaranteed limit and its addition to rule 10.

From the previous session:

* `engine/src/platform/` — the whole L1 interface plus the null backend:
  * `key.zig` — keys by physical position, `KeySet`, mouse buttons, modifiers.
  * `event.zig` — Foundry's own event union; text input carried by value.
  * `input.zig` — the per-frame `InputSnapshot` and the `Accumulator` that builds it.
  * `window.zig` — `WindowHandle`, logical vs pixel size, `NativeSurfaceHandle`.
  * `os.zig` — filesystem, base directories, environment, wall clock. Owns `std.Io`.
  * `library.zig` — dynamic library loading, including Foundry's own Win32 bindings.
  * `interface.zig` — the backend interface and its `comptime` conformance check.
  * `backends/null.zig` — the headless backend, with a scriptable event queue and an
    exactly-reproducible synthetic clock.
  * `backends/sdl3.zig` — the SDL3 backend. **The only file in Foundry that may name an
    SDL type**, and the build graph is what enforces that: no other module is linked
    against SDL.
* `engine/src/rhi/` — the render hardware interface and its validation backend:
  * `format.zig`, `resource.zig`, `pipeline.zig`, `command.zig` — formats, memory intent,
    resource states, the binding model, render passes and draws.
  * `interface.zig` — the three-type backend interface (`Device`, `CommandBuffer`,
    `RenderPass`) and the `comptime` check that enforces all 40 of its functions.
  * `backends/null.zig` — the validation backend. 55 tests: at least one per rule, plus
    18 assertions that legal usage produces **zero** violations.
* `engine/src/app/` — the engine loop and lifecycle:
  * `engine.zig` — `EngineOf(Platform)`, the frame phases, subsystem ordering, the frame
    arena, and `environment` (the one place a `std.process.Init` appears in Foundry).
  * `log_sink.zig` — the log sink and the runtime level filter.
* `samples/sandbox/` — M0's runnable result, and the reference for what a game's `main`
  looks like. Opens a window, logs input, runs the loop, exits cleanly.
* `platform/os.zig` — gained `sleep`, an OS service beside the clock and filesystem.
* `docs/design/app-and-frame-loop.md` — written before the code, per development rule 1.
* `build.zig` — `app` added to the layering table; the `sandbox` executable and a `run`
  step; `-Dplatform=null|sdl3` selects the backend and **now defaults to `sdl3`**.
* `scripts/check-targets.sh` — runs both backends natively and cross-compiles both,
  sample included: six combinations, all green.
* `core/handle.zig` — `HandlePool` now takes a **tag type and a value type**
  (`HandlePool(Window, WindowState)`). See "decisions" below.
* `docs/design/platform-interface.md` — Resolution section recording what implementation
  changed about the design, and why.

Earlier sessions: pinned toolchain (`scripts/install-zig.sh`, `.zigversion`), the SDL3
dependency and its licence entry, ADRs 0001–0017, `core` (L0), `scripts/check-targets.sh`,
and the published repository.

## What currently works

**`zig build test` passes 796 tests** (56 `core`, 78 `platform`, 104 `data`, 82 `physics2d`,
92 `rhi`, 70 `asset`, 129 `render2d`, 79 `scene`, 33 `audio`, 28 `app`, 22 `fpack`,
23 integration), and **804 under `-Drhi=metal`**, where `rhi` gains the backend's own 8. Everything but those 8 is headless: nothing calls `SDL_Init`, and `app`'s tests
instantiate `EngineOf(null_backend.Platform, null_backend.Device)` so the frame loop is
measured against a synthetic clock and a validating device, never against this machine. The
8 exceptions need a real GPU and compile only when Metal is selected. **`samples/room` adds
no tests and neither does `samples/sandbox`**: a sample is a consumer, what it exercises is the
engine's, and the engine's tests are where that is held. What the room contributes to the suite
is the `check` step — it cross-compiles for Windows and Linux every milestone like everything
else.

**It draws thousands of sprites, under a camera, with text.** `platform` (SDL3, `cocoa`
driver) hands an opaque `CAMetalLayer` to `rhi`, which brings up a real Metal device:

```
info(platform): platform backend: SDL3 3.4.14, video driver 'cocoa'
info(rhi): rhi backend: metal on 'Apple M5', 2 frames in flight, surface bgra8_unorm_srgb
info(app): content: 2 package(s), 3 record(s), from '.../zig-out/content'
info(app): engine up: 60Hz simulation, windowed, rhi backend 'metal', 2 frames in flight
info(render2d): render2d up: 16384 quads per buffer, unified memory
info(sandbox): content: sheet 64x64, glyphs 128x48, 4000 sprites, grid 4
info(sandbox): window: 1280x720 points, 2560x1440 pixels, scale 2.00
debug(sandbox): frame 120: 4177 sprites (175 glyphs), 5 batches, 5 draw calls, 326 KiB of vertices, 17.0ms/frame, zoom 1.00
info(sandbox): clean exit after 180 frames, 178 ticks, 2966ms simulated
```

**And there is a hall somebody can walk.** `zig build room` opens `samples/room`; the same
binary built headless finishes it by itself and says so:

```
info(room): map 'content(0xce1cb76a47671773)': 32x24 cells of 16x16, 1 layer(s)
info(room): 6 lamp(s) in the hall, 0 already lit
info(room): headless build (null backend): running 60000 frames on autopilot
info(room): a lamp catches: 6 of 6
info(room): the way out is open
info(room): the walker steps out of the hall, after 1542 tick(s)
info(room): finished at (2, 128) after 25700 frames, 1542 ticks: 6 of 6 lamps lit, door open, 436 contact(s), 1 sound(s) started
```

`finished` rather than `stopped` is the whole point of that line: it is a scripted run
answering the question a sample can otherwise only assert about itself. **The windowed build
was looked at, not inferred** — screen captures of the room's own window show the hall filling
the frame with the camera clamped to it, the unlit lamps readable against the floor, the
counter and the hint on their panels, the sign over the rug, and the door across the north
doorway. Two of those captures changed the sample: the first showed the void past the west wall
(the camera now clamps) and the second showed unlit lamps four shades from the floor they stand
on (the sprite now has a cold halo).

**The text was looked at, not inferred**, the same way M1's quad was. A capture of the
sandbox's own window (by window id, so nothing else on the screen is read) shows the
statistics panel and the help line in screen space, the world-space banner, and the
`#1863` label above the outlined sprite, all legible — over 2,400 frames with Metal API
*and* GPU validation on and **zero messages**. That capture is also what caught the Y-axis
bug: the first windowed run drew the whole readout upside down, which no unit test had
asked about because until then every space was Y-up.

**The sandbox is a small game now, and the whole of it was watched running.** Under Metal,
900 frames at vsync with no validation message from either backend: a 12x10 room drawn from a
hand-written text grid, a player walked around it by a scripted circuit, stopped and slid by
its walls, 283 contacts, and — new today — a walk cycle while it moves and an idle pose while
it does not, over four thousand field sprites each playing one shared clip at its own phase.
The animation survives a restart exactly:

```
info(sandbox): 3 clip(s) loaded
info(sandbox): player saved on frame 3 of sandbox:clip.walk, 22 tick(s) in
info(sandbox): saved 4001 entities to 'anim.fsav' (593238 bytes)
--- second process ---
info(sandbox): loaded 4001 entities and 16004 components from 'anim.fsav'
info(sandbox): player resumed on frame 3 of sandbox:clip.walk, 22 tick(s) in
```

**And a mod changed the animation without a rebuild.** A package compiled with `fpack` and
placed after the sample's, restating `sandbox:clip.walk` with `first 12` and `hold 2`,
reskinned the walk onto another row of the sheet and ran it three times faster — while
leaving the player's finishing position and contact count identical, which is the right
answer for a change to how something looks.

**And it makes a noise, from its own package.** Under Metal the device is real and the
sandbox drives it:

```
info(platform): audio device: 48000 Hz, 2 channel(s), 512-frame buffer
info(audio): mixer: 32 voice(s) at 48000 Hz, 2 channel(s)
info(sandbox): player finished at (17.6, 35.0) with 6 contact(s), on frame 3 of ... after 22 tick(s)
info(sandbox): clean exit after 900 frames, 455 ticks, 7583ms simulated, 29 sound(s) started
```

Three `.wav`s, none of which has a record — a `.wav` in a package becomes a `foundry:sound`
from its path, so the settings record naming three ids is the only place the sample mentions
them. The footstep is 22050 Hz so the voice resamples it on the real path, the thud is at the
device's own rate so the same path runs with no resampling, and the ambience completes a whole
number of cycles in its half second so the loop wraps silently.

**The real device was verified by hand once**, because a unit test that opened one would fail
on a machine with no sound card — which is precisely the configuration `audio.md` §9 says must
keep working. A temporary probe reported 48000 Hz, 2 channels, a 512-frame buffer, 36 callbacks
in 400 ms at **exactly 1024 samples each** (which is the property the backend's whole-block
fill exists to guarantee), pausing stopping them, resuming restarting them, and closing stopping
them for good.

**And a mod replaced a sound the sandbox never wrote a record for.** A package declaring
`foundry:sound sandbox:sounds.hum { source "drone.wav" }` pointed the ambience at its own file,
under its own directory layout, at 16 kHz — a rate neither the device nor the original uses, so
the voice resampled it. Nothing was rebuilt but the mod.

**What the M1 record below describes is the quad**, kept because each row is a separate
property that was checked once and has not been rechecked since.

**Both halves of M1's cross-check hold, on the quad.** With `MTL_DEBUG_LAYER=1` and
`MTL_SHADER_VALIDATION=1`, Metal API validation *and* GPU validation produce **zero
messages** over 180 frames; the null backend reports **zero violations** on the same
command stream headlessly. That is the arrangement ADR-0003 is built around, now checking
something worth checking.

**And the pixels were looked at, not inferred.** A clean validation run proves the draw was
legal, not that anything is visible — a quad transformed off-screen or sampling to zero
would validate perfectly. Two captures of the sandbox's own window (by window id, so
nothing else on the screen is read) show a nearest-filtered checkerboard, square in a 16:9
window, at two different rotations. That is worth stating precisely, because each visible
property is a separate thing being right:

| What is visible | What it proves |
| --- | --- |
| A checkerboard at all | The staging upload and `copyBufferToTexture` path work |
| Hard-edged squares, no blur | The sampler is `nearest`, as a 2D engine's default must be |
| No skew, corners aligned | The vertex layout and UVs agree with what the shader declares |
| It is coloured, not black | Group 0's uniform reached `[[buffer(9)]]` — the §9 walk order |
| It rotates | Inline constants reached `[[buffer(8)]]` in the vertex stage |
| It is square in a 16:9 window | Aspect correction, and the surface size the device reports |

**The Objective-C bridge leaks nothing**, re-measured now that a frame binds textures,
samplers and buffers as well as acquiring a drawable. Peak RSS over 600 frames is 99.12MB
against 98.83MB over 60 — 0.30% across a tenfold frame count, which is flat. Drawables,
command buffers and blit encoders are all balanced.

**Live input is confirmed working** — focus and mouse events arrive and are logged. That
was the one thing left machine-unverified in the previous session.

**`zig build run` opens a window and exits cleanly** on the default `-Drhi=null` too,
where the window stays empty because that backend draws nothing by design — the same
command stream still goes through its ten rules.

Headless (`-Dplatform=null`) it is exact rather than merely plausible: 300 frames of a 1ms
synthetic clock produce 300ms of simulated time and 18 ticks at 60Hz, every run.

**Both platform backends cross-compile to Windows and Linux — SDL and the sandbox
executable included**, since the sample is part of the same per-milestone obligation.
ADR-0008's "supported means compiles" claim therefore covers the backend that actually
ships, not only the headless one. The cross builds keep `-Drhi=null`, which is itself the
check that matters now: a Windows or Linux build must not have acquired a dependency on
the macOS backend, and `-Drhi=metal` on a non-macOS target fails immediately by design.

**Four guarantees were verified by breaking them on purpose**, not by assertion:

| Claim | How it was checked |
| --- | --- |
| Layering (I7) | `platform` importing `rhi`, and `core` importing `platform`, both fail with *no module named X available within module 'root'* |
| Conformance | A backend missing a function, with a wrong signature, or with no `Platform` type each fails with a message naming the backend and the declaration |
| Windows really compiles | Breaking only the Win32 loader branch fails `zig build check -Dtarget=x86_64-windows-gnu` and no other target |
| Determinism (I9) | The same event sequence yields byte-identical snapshots; the synthetic clock drives a fixed-timestep loop to the same step count every run |

## What is being worked on

**M5, with every bullet finished and only the exit criterion left.** All three design
documents are written and all three are fully implemented, and the fourth bullet — a playable
sample — is `samples/room`.

### `samples/room`, and what a second consumer proved

**It is 1,834 lines — three quarters of the sandbox's 2,424, doing far less, because the
comment density is the project's — and it changed nothing under `engine/`.** That is the claim M5's exit
criterion is really making, paid: a hall, a walker that collides with it, six lamps that light
when walked into, a door that despawns when the last one catches, and a way out — built from
`render2d`, `physics2d`, `scene`, `asset` and `audio` exactly as they already were. `fpack`
did not change either; the room's `.png`, its five `.wav`s and its `.grid` all became content
by the rules the compiler already had.

**Four things the second sample settled that one sample could not.**

* **`samples/` is plural, and the roadmap's contradiction is resolved.** The M5 entry asked
  for a playable `samples/sandbox` in one line and insisted the sandbox stay a demonstration a
  paragraph later. Two samples, two smallest things.
* **Every game rewrites `Map`.** Two hundred lines that turn a `foundry:tilemap` into a
  `render2d.TilemapLayer` and a `physics2d.Grid` are now written twice, near-identically,
  because nothing in the engine joins them — `tilemaps-and-collision.md` §11 says the game
  wires them, which was a *claim* when one sample had paid it and is now *evidence* that every
  consumer will pay it. This is the argument for a `render2d`-side helper, and it is
  deliberately **not acted on here**: what shape it takes is a decision for the milestone that
  makes it, not a thing to slip into a sample commit.
* **Two samples independently defined the same `clip` schema.** Seven fields, arrived at twice,
  with no engine-owned `foundry:clip` to share (`sprite-animation.md` §5 deferred that name to
  M7 on purpose). That is the evidence the deferral was waiting for.
* **`@patch` is not implemented, and a mod meets that by name.** Writing the room's mod hit
  `'@patch' is not implemented yet; until it is, a later package overrides a record by
  restating it in full` — a designed-but-unbuilt directive refusing with the workaround in the
  message, which is the right way for an unfinished feature to behave and worth recording as
  the first time anybody hit it from outside.

**What implementation decided that the design of the sample did not.**

* **Content places things by column and row of the map *as written*.** Three coordinate
  conventions meet in this sample — the `.grid` file is top-down, the runtime grid is Y-up with
  row 0 at the bottom because `asset.tilegrid` reverses once at compile time, and the world
  origin is the middle of the map because the sample put it there. An author should meet
  exactly one of them, so `Place.of` is the only function that knows about the other two.
* **The door is an entity, not a tile.** A tile is a number in a grid that two subsystems are
  reading, and changing one means telling both; an entity that stops existing stops being drawn
  and stops being solid by the same call. That is the whole reason the room has a `scene`.
* **Lamps are trigger bodies**, so lighting one is an `overlapShape` against the broadphase
  rather than a loop measuring the distance to every lamp. It is also the first use of
  `BodyKind.trigger` anywhere — the sandbox never needed one.
* **The camera is clamped to the map.** Without it the walk shows the void past the west wall,
  and a room you can see the outside of is a rectangle of tiles rather than a place. Ten lines,
  and leaving them out was the single most noticeable way the room stopped looking like one —
  caught by screenshotting it, not by any test.
* **The autopilot is why the loop is checkable at all.** `FOUNDRY_ROOM_AUTOPILOT`, and on by
  default in a headless build, walks to the nearest unlit lamp and then to the way out; a
  headless run reports `finished` or it does not. It has no path-finding — `moveAndSlide`
  slides around the pillars, and a progress check strafes when it stops improving — because the
  question being answered is "can the hall be finished", not "can a sample play itself well".
  Its one real bug was found by that check: the progress measurement was not reset when the
  target changed from a lamp to the exit, so the walker arrived at the last lamp with `best`
  near zero, could never improve on it again, and strafed in place for the rest of the run.

**A mod paid Tier 1 on the second consumer too.** A package outside the repository added a
seventh lamp — a record of `room:lamp`, a schema the mod re-declares because `@import` is
confined to a package root — and replaced `room:tiles.hall` so the rug became solid. Nothing
was rebuilt but the mod, the hall went from six lamps to seven, and the door held out until all
seven were lit.

**What nobody has done is play it.**
All seven steps of `tilemaps-and-collision.md` §15 are implemented. `physics2d` is now complete as a *module*:
shapes and their tests, the tile grid with neighbour-aware face culling, the two-tier spatial
hash with its determinism sort, and movement — `moveAndSlide` with its four-iteration budget
and the projection that makes a stop into a slide, `resolveOverlaps` kept deliberately separate
so that "stuck in a wall" is a state a game can detect rather than a silent teleport, and
`overlapPoint`, `overlapShape`, `raycast` and `shapeCast` with caller-supplied buffers that
report how many hits there *would* have been.

**`sync` is deliberately absent.** The design's open question 4 asks whether trigger enter/exit
belongs in this module at all, and step 4 did not force the answer, so it was not settled
opportunistically. Triggers block nothing and `overlapShape` finds them exactly, which is what
a game needs to diff two overlap sets for itself — the shape the open question contemplates.

**Step 5 is done and a map is content.** `foundry:tileset`, `foundry:tilemap.layer` and
`foundry:tilemap` as record types, `foundry:tilegrid` as an asset with a versioned binary
format, a loader that turns one into `[]const u16`, and `fpack`'s text-grid front end. The
sandbox ships a hand-written 12x10 room; the build compiles it; an integration test carries a
map from authored text to a body that cannot walk through a wall.

Two things moved from where the design put them. **The schemas and the grid loader live in
`asset`, not `render2d`**, because `fpack` has to register the record types before it can check
a package and cannot link a renderer — design question 1's own stated trigger arriving earlier
than expected, and pointing *lower* rather than at a new module. And **`fpack` now emits two
things**: the `.fpk`, and a `--assets-out` tree holding what it compiled. A tile grid is the
first asset kind whose authoring and runtime forms are different files, and the sources tree
is where a person's files live, not a tool's.

**Step 6 is done and the sandbox draws its room.** `drawTilemap` culls to the current view and
emits ordinary sprites through the existing batcher — no chunk cache, no persistent vertex
buffer, no dirty rectangles, exactly as §10 asked. A layer is one texture at one sort layer and
so is **one batch**: the sandbox's frame went from four to five, and 120 tiles joined its 4,176
other quads. `Stats.tiles` exists from the first day there is a tilemap, because that number is
the stated trigger for ever caching one.

Three things the design did not settle. **The view is not a parameter** — `setView` already
names the space for `drawSprite` and `drawText`, and the design's `drawTilemap(view, layer)`
would have frozen an inconsistency at M7. **Culling is half-open**, matching `Rect.overlaps`;
with `floor` on both ends a screen-aligned camera at a whole zoom — the common case — draws one
extra row and column every frame, invisibly. And **`foundry:tilemap.layer` gained `empty` at
version 2**, because the `layers` list has always permitted a second plane and a second plane
with no way to say *nothing here* paints over the first; without the field that is expressible
only in Zig, which would make a decoration layer a program rather than a Tier 1 content mod.

**Step 7 is done and the sandbox is a game for about thirty seconds.** A player walks the room
with WASD, is stopped by its walls, slides along them, and the camera follows it. What that
took in the engine is **one line of build graph** — the sandbox imports `physics2d`, as it
already imports `scene` — and nothing else. §11 said the three parts meet in the game that uses
them, and this is that claim being paid rather than restated: `physics2d` did not learn what an
asset is, `render2d` did not learn what a body is, and `app` did not acquire a collision world.

`app` owning no `physics2d.World` is the load-bearing part. The module holds no time and
integrates nothing, so *when* to move a body and what to do about what it hit is gameplay; an
engine that owned the collision world would own the answer to both. For the same reason, moving
the player is **not** a `scene` system and could not be: a system is handed the tick and the
delta and nothing else, precisely so a simulation cannot read a device, and driving something is
reading a device. So it is the game's own function in the game's own fixed step, reading the
step's frozen input snapshot.

Four smaller things. The sample defines `sandbox:collider` and the engine still defines no
`foundry:collider` — §11's commitment kept, and it cost four lines, which is the evidence that
it was cheap. The collider holds half-extents and **not** a `BodyHandle`, because a handle is
runtime identity a save must never carry (I1), so the component is what persists and the body
is derived from it; a 4001-entity save round trip confirmed the player comes back with a body
it was given rather than restored. **WASD changed hands** — it panned, there is now something
to drive, and two things cannot answer to the same key; panning moved to the arrows and the
camera follows the player until a manual pan drops the follow. And `walk` reads `w` as **+y**
while `control` reads `up` as **−y**, which is correct in both places: one moves in world space,
the other pans in screen space, and the comment saying so exists because the next reader will
assume one is a bug.

`FOUNDRY_SANDBOX_WALK` walks the player in a square as a pure function of the tick, so a
headless run collides with something and reports how often — 400 frames, 145 ticks, 35 contacts,
and the room's border means zero contacts would mean the player walked through a wall. The
integration suite gained the same claim twice over: the drawn-versus-collided test now puts its
map **off** the origin, because an origin applied on one side of §11's diagram and not the other
is invisible at zero; and §12's Tier 1 claim is a test rather than a paragraph — a second package
restates one tileset's `solid` list and a body that was stopped by a wall walks straight through
it, with the map, the grid asset and the layer record byte-identical across both halves.

**The sprite-animation sequence is done, all three steps.** The engine gained
`render2d.frameAt`, `frameAtVarying` and `Region.cell` and nothing else — `sprite-animation.md`
§3 said that would be the whole surface and implementation found no fourth thing to add. The
sample gained a `sandbox:clip` schema, three clip records, a `sandbox:animation` component, the
system that advances one, and a `cellOf` that is §6's diagram written out. The player walks
with a walk cycle and stands with an idle one; the four thousand field sprites each play one
shared clip at their own phase, which is the split the component exists to express.

Step 1 settled three things reachable from a file. **An out-of-range grid cut is empty rather
than clamped** — a clip running off its sheet should vanish, because clamping shows a *stuck*
animation and a stuck animation is indistinguishable from a non-looping clip working. **A frame
held for zero ticks is never shown**, which falls out of the walk rather than being
special-cased. And **pinning clamps the tick rather than the index**, so looping and pinning are
one walk and a one-shot settles on the last frame actually displayed rather than on a trailing
zero-hold entry no playthrough would have reached.

Steps 2 and 3 settled how a clip's numbers reach a system, which §6's diagram does not show. A
`scene` system is handed the tick and the delta and nothing else, so it **cannot read a
record**: the game resolves every clip once per content generation and hands the table down as
the system's context. That is also why advancing a clip *is* a system where moving the player is
not — one wants the tick and nothing else, and the other wants a keyboard. The table is built by
iterating the store rather than by naming the clips the sample plays, so an id from a save or a
mod resolves. A looping clip **wraps its own elapsed count by the clip's duration** and a
one-shot saturates, with the wrap asserted to be invisible; `play` restarts a clip only when it
is a different one, because calling it every tick otherwise pins frame zero and looks exactly
like an animation that does not play; and a clip that is not loaded holds its frame rather than
resetting it, because a package can be edited between one tick and the next.

**§3's grid cut had a caller waiting for it.** The sample's `spriteOf` had been slicing its
sheet by hand since M2 — a modulo, a divide and a `sub`. That is one `Region.cell` call now.

**The reload check is an integration test, and had to be.** `scene` and `render2d` are both L3
and neither can reach the other's tests, so `engine/tests/sprite_animation.zig` is the consumer
that has both. It steps three entities on three clips of different periods to a tick that is a
multiple of none of them, saves, loads into a fresh world, and compares **the UVs a draw call
would carry, bit-exactly** — an epsilon there would pass for the float accumulator §4 refuses —
then runs both worlds four hundred ticks further, because a save that restored the frame but
lost the elapsed count passes the first check and fails on the next tick. Seen end to end as
well: `player saved on frame 3 of sandbox:clip.walk, 22 tick(s) in`, and from a second process
reading that file, `player resumed on frame 3 of sandbox:clip.walk, 22 tick(s) in`.

**§7's Tier 1 claim was checked by doing it.** A package compiled with `fpack` and placed after
the sample's, restating `sandbox:clip.walk` with `first 12` and `hold 2`, reskinned the walk
onto another row of the sheet and made it three times faster — no rebuild, no code that knew.
It changed nothing about where the player ended up or how many walls it hit, which is the right
answer for a purely presentational override. `docs/modding/content-mods.md` gained a §7 for
animations, and its "your first mod" example **is** that override, verified by following it
verbatim; the settings example it replaced had gone stale, since a shorter settings schema now
silently turns off the map and every animation.

**Open questions 2, 3, 4 and 5 are untouched**, because nothing forced them. `frameAtVarying`
has no consumer at all: the sample's schema exposes a single `hold`, exactly as §5 wrote it, and
a list field for a case nothing has asked for is the guess §8 refuses. It exists, it is tested,
and it agrees with `frameAt` on the uniform case so the schema can grow one later without
changing what an existing clip shows.

**The audio sequence is done, all six steps, and it brought the project's first second
thread.** Everything in `audio` is downstream of one sentence: the device calls Foundry on a
thread it did not create, under a deadline, where a mistake is an audible click rather than a
dropped frame. So the mixer's state is split by which thread owns it — no field is written by
both — two SPSC rings carry commands out and retirements back, and there is no lock in the
module. The one memory-ordering argument in Foundry lives in `ring.zig`, written down because
it is invisible and a later session would otherwise simplify it away, and it was run against
two real threads once: 100,000 values in order, none missing, none duplicated. That is not
proof of the ordering and the file says so.

**Step 1 needed nothing from `fpack`.** A `.wav` becomes a `foundry:sound` from its path
because the compiler already walks the asset extension table rather than knowing about PNG.
That is what the table was for and this is the first time anything proved it. The decoder added
two refusals the design's list did not have: **the format is asked before the bit depth**,
because four bits is nonsense for PCM and correct for ADPCM and a decoder that asks the other
way tells an author their file is corrupt when it is merely compressed; and a sound with **no
frames** is refused, because a looping voice wraps its cursor by the source length and
admitting one would put a division by zero in the one place that must never branch on a special
case. Two header fields — `nAvgBytesPerSec` and `nBlockAlign` — are read by nothing, because
both are derivable and both are wrong in a great many real files.

**Step 2's `comptime` interface check earned its keep the moment the four functions landed**:
adding them failed the build with the SDL3 backend named. Three things it settled. A device
**opens running**, because SDL's streams start paused and a backend that left it that way would
be an engine that ships silent until somebody investigates. The SDL3 backend **adopts the
device's own sample rate**, since Foundry's voices resample anyway and taking the hardware rate
removes SDL's resampler from the path entirely; the channel count goes the other way, because a
mixer that had to know about 5.1 to be heard on a 5.1 machine would be a worse trade. And
Foundry's callback **always gets the block size it was promised**, whatever SDL asks for, by
filling whole blocks into the stream's queue — overshoot is what the next callback does not have
to ask for.

**Step 4 forced three decisions §4 did not make.** A dropped `play` **returns an error and
undoes its claim**, unlike every other dropped command, because the game thread has already
taken a slot and a `play` that vanished would strand it forever. The retirement ring is **sized
to the voice count**, which makes dropping a retirement structurally impossible — a voice
retires at most once and cannot play again until `update` returns its slot — so the push
asserts rather than ignoring its result. And a one-shot **ends in the buffer it runs out in**,
not the one after, which is what makes the lifetime rule sayable. Two smaller ones: pan is
ignored on a mono device rather than summed, and `init` opens the device last behind an
acquire/release flag, because the device may call back the instant it exists and `AudioInfo` is
not known until after that call returns.

**Steps 5 and 6 found one thing the design had not: teardown wants two opposite orders.** The
registry unloads through a loader that borrows the mixer, so the loader has to go before
`deinit`; but the mixer holds an asset reference per playing voice, so those have to come back
*before* the loader goes. `Mixer.shutdown` is the call between them — it closes the device,
which is what makes the release safe, and hands the references back. `deinit` deliberately does
not call it, because `deinit` has to stay safe after the registry has already gone.

**The two lifetime hazards are tested by doing them**, in an integration test because nothing
below can stand above both modules: the game dropping its last asset reference mid-voice, and a
reload saving a quieter take over a playing loop with two sounds alive at once until the voice
holding the old one stops. `testing.allocator` is half of each assertion — early is a
use-after-free on the device thread, late is a leak, and it fails on both.

**A headless build does not emit one-shots**, and the reason is worth keeping: its device never
runs, so a command queued there sits in the ring until it fills and every one after it is
refused. That is the mixer behaving exactly correctly and the sample asking for something
pointless. The ambience still starts, so a headless run still decodes a `.wav` through the real
path.

**Audio's open questions 1 through 5 are all still open**, and step 6 was written to keep them
that way: the sample names three sound ids and **no gains**, because a per-sound gain field
would have answered question 2 — buses and category sliders — by accident.

What follows in this section is the record of the milestones behind it, kept because the
reasoning is what a future session needs and the commit log is not where reasoning lives.

### M4 — World: "it has entities"

All six steps of `entity-storage.md` §15 are built and both exit criteria are met. The
per-step account is under **Immediate next steps** below, and what each step settled is in
that document's seven Resolution sections. Three things are worth having in front of you
without opening it:

* **A component type is a schema, and that is what made the save cheap.** Identity,
  versioning, additive-only evolution, defaults and the field-block layout are all machinery
  `data` already had and already tested. The save format is a container around them, not a
  second serialization system — and the schema-carrying discipline that lets an older `.fpk`
  be read correctly is the same code that lets an older `.fsav` be.
* **Two registries, not one.** A world's schemas are declared by code and outlive any
  reload; a content set's are rebuilt from packages on every one. They therefore cannot be
  the same registry, and because they are not, nothing before a spawn notices that a package
  ordered a component's fields differently from the Zig struct — so `attach` checks, and the
  test that proves it swaps two fields and expects the refusal.
* **Iteration order is a property of the query as written.** Driving from the first named
  component rather than the smallest is the slower and less conventional choice, taken so
  that order cannot change when a mod adds a component to some of the entities (I9). It is
  tested by being reversed, and the save preserves dense order so a reload keeps it.

### M3 — Content: "it has data"

It opened with two decisions §9 had been holding since M0 and the two design documents they
needed, per `CLAUDE.md` rule 1 — design before implementation — and rule 10, which says never
make a major architectural decision silently. Both are spent, as ADR-0020 and ADR-0021, and
`data` is built behind them.

**All ten steps are built.** `data` exists end to end — identity, schemas, the registry, the
lexer, the parser, diagnostics, the checking pass, the `.fpk` writer and reader, and the
store that merges packages — `tools/fpack` drives all of it from a directory, and the asset
registry above it turns a content id into a loaded payload, `content/core` is package zero,
and content reloads under a running program.

**Step 10 — hot reload, and `docs/modding/`.** The watcher lives in `app` and runs at the
top of `beginFrame`; the swapping lives in `asset.Registry`. Six things worth carrying
forward, recorded in `assets.md`'s third Resolution section:

* **Nothing recompiles at runtime.** §6 said "recompile the changed package"; `fpack`
  compiles and the engine *reloads*. Putting a content compiler in the engine would ship one
  in every build to serve a development path, and what hot reload is worth is the process
  not dying — not who ran the compiler.
* **A reload builds a whole new content set and swaps it.** "A failed reload changes
  nothing" is not a check, it is a shape: a fresh schema registry, store and byte set are
  built to one side and only a complete one is ever swapped in. A package caught mid-save
  leaves the last thing that worked and the generation does not move.
* **The schema registry is rebuilt too**, which is what makes editing a schema work at all.
  Reusing it would refuse any schema changed without a version bump — correct, and
  intolerable in a development loop.
* **A handle survives a reload; anything derived from one does not.** §4's promise is exactly
  true of the handle and exactly false of a `Region` or a string borrowed from a package's
  bytes. So `app` publishes a **generation counter** and the sandbox re-derives from it —
  including copying its banner rather than borrowing it, because the freed-bytes case is
  real.
* **A file that turned to rubbish is complained about once.** The watcher stamps a source
  even when reloading it failed, so a half-written PNG does not produce the same complaint
  twice a second; the next real edit retries it.
* **`log.err` is for a failure with no other way to report itself.** Content problems have
  one — the reload does not happen, or `init` returns `ContentUnavailable` — so they log at
  `warn` with the severity in the text. The practical half: the Zig test runner counts an
  `err`-level log as a failed test, so a path that logs at `err` is a path no test can
  exercise. Making these testable found a double free and a leaked slice.

**Step 9 — package zero.** `content/core` exists and is compiled by `fpack` during the
build; `app` loads it and mounts it; the sandbox ships a package of its own and embeds
nothing. Seven things worth carrying forward:

* **The sample got its own package, rather than putting its sheet in `content/core`.**
  `content/core` is *engine* content — right now the debug font, which M6's overlay will
  want and which `render2d` must not ship (I5). A sprite sheet used by a sample is the
  sample's. `main.zig` already says the sandbox is the reference for what a game's entry
  point looks like, and a game has its own package; so it has one, loaded second, through
  the same call.
* **The engine consumes a load order and does not compute one.** `Config.content` is a list
  of packages in order and `Config.content_dir` says where they are. Discovery, dependency
  resolution and what a player has enabled are M7 (`content-schemas.md` §11), and answering
  any of it in a config struct would answer it in the wrong place.
* **The sandbox lost its runtime atlas, and that is the honest state.** It packed the
  sheet, the glyphs and a white patch into one atlas and drew them in 4 batches; assets
  arrive as standalone textures, so it now draws 5. Fixing that means either an
  atlas-aware loader or a texture-to-texture copy in the RHI, and both are policy decisions
  about what an asset *is* — `assets.md` §9's third open question territory. `render2d`'s
  atlas is unchanged and still covered by its own tests; the sample stopped using it.
* **A loader's owner needs a way to leave.** The registry unloads through its loaders, and
  the game owns the renderer that registered one — whose `deinit` runs *before* the
  engine's. `asset.Registry.unregisterLoader` hands everything a loader made back to it
  while it still exists. Step 8 declined to add it for want of a caller; step 9 produced
  one, which is the evidence the earlier note was waiting for.
* **`app` gained `data` and `asset`, and deliberately not `render2d`.** The engine owns the
  store and the asset registry; the *game* registers the texture loader. An engine that had
  to know what a texture is in order to own an asset registry would have the layering
  upside down.
* **Content failures are logged at `warn` and returned as errors.** The convention the asset
  registry already followed, and there is a second reason for it: the Zig test runner counts
  an `err`-level log as a failed test, so a failure path that logs at `err` is one no test
  can exercise. The three new `app` tests found a double free of the content directory on
  the failure path, which is precisely the kind of thing an untestable path keeps.
* **The mod path is demonstrable now, by hand.** `FOUNDRY_SANDBOX_PACKAGES=demo` appends a
  package. Compiling one with `fpack` into `zig-out/content/` and running it changed the
  sprite count from 4000 to 128 and replaced `foundry:fonts.debug` with an image at
  `whatever/i/like/glyphs.png` — a path mirroring nothing. Two thirds of M3's exit criteria,
  seen rather than declared.

**Step 8 — the asset registry.** `asset/registry.zig` plus `render2d/loader.zig`: content
id in, `AssetHandle` out, reference counted, with the loader that knows what a GPU texture
is registered upward at runtime. `loadImage` is gone. `engine/tests/` exists now, because
this is the first behaviour no single module can test on its own — `asset` is below
`render2d` and `render2d` is not granted `data`, so the seam between them is only reachable
from something standing above both. Seven things worth carrying forward, recorded in
`assets.md`'s second Resolution section:

* **`source` is location, never identity, and the design document now says so.** §2 called
  `source` meaningful "only to `fpack`" while §7 specified a `SourceMissing` error only a
  runtime file read can produce. The second is right: ADR-0021's promise is that *nothing
  can be looked up by path*, and `acquire` takes a `ContentId` with no other way in. Where
  a record says its own bytes live was never what the ADR was protecting.
* **A package's root is mounted on the registry, not carried by `data`.**
  `store.LoadedPackage.label` documents itself as diagnostics-only, and reusing it would
  have quietly made a diagnostic string load-bearing. `asset` still consumes a merged store
  and assembles nothing.
* **A loader's payload is one 64-bit word.** `render2d` returns a `TextureHandle`, which is
  a value; a `*anyopaque` payload would make every handle-producing loader box two `u32`s.
  `core.Handle` gained `bits`/`fromBits`, which is the packing the ABI already publishes.
* **`foundry:texture` is version 2, and version 1 content still loads.** `filter` and `wrap`
  arrived with the loader that reads them, appended with defaults. A package compiled when
  the schema had one field is read against the version it carries and filled from the
  newest schema's defaults — I8's additive versioning made real rather than asserted, and a
  test.
* **They are strings, because the type list is closed.** No enum type exists, so the domain
  is only knowable in the loader, whose enum tag names *are* the content spelling. An
  unrecognised value warns and falls back: answering a typo with a missing sprite is the
  least diagnosable outcome available.
* **§7's error table gained two rows.** `SourceRejected`, so a package trying to read
  outside itself is not filed under "not found"; `LoadFailed`, so a device refusing a
  texture does not tell a mod author their file is corrupt.
* **Eviction is a call nobody makes.** Zero references means evictable, not freed, exactly
  as §4 said. `evictUnused` is the mechanism and `assets.md` §9's open question — *when* —
  stays open, because answering it before there is a memory number to look at is guessing.
  A texture released between two levels that both use it stays resident and comes back
  without a decode.

**Step 7 — `tools/fpack`.** The first Foundry program that is not the engine: a plain
command-line tool (ADR-0011) that links `data`, `platform` and `asset`, walks a package
directory, and writes one `.fpk`. `zig build fpack -- --name foundry:core --out
zig-out/content/core.fpk content/core`. Five things worth carrying forward, recorded in
`assets.md`'s Resolution section:

* **The asset schemas live in `asset`, and the loaders stay above it.** `render2d` owns
  what a GPU texture is and will register the loader; the *record* — a source path — is
  not a GPU concept, and a content compiler must see it without linking a renderer. So
  `asset/schemas.zig` holds the schema and the extension table.
* **A derived asset record is `.fdt` text**, written into a buffer named `<derived>` and
  put through the same parser and checker as an authored one. `assets.md` §3 says a derived
  id is materialised "exactly as if it had been written by hand", and the cheapest way to
  be sure of that is for it to be. A collision with an authored record is then reported by
  the checker's existing message rather than by a second implementation of it.
* ~~**`foundry:texture` has one field.**~~ **Superseded by step 8**, which brought the
  loader that reads `filter` and `wrap` and so brought the fields: version 2, appended with
  defaults, and version 1 content still loads. This is what "arrive with the loader that
  reads them" was waiting for, not a reversal.
* **The package's name and version are arguments, not a manifest file.** Mod manifests are
  M7, and `data` consumes a load order rather than computing one.
* **Every listing is sorted and dot-prefixed names are skipped.** A filesystem's
  enumeration order is not a specification (I9): compiling the same directory twice
  produces identical bytes, and that is a test.

**Step 6 — packages and the store.** `store.zig`: packages added in an order supplied from
outside, records merged by content id with replace semantics, and provenance kept for every
one. Five things worth carrying forward, recorded in `content-schemas.md`'s fourth
Resolution section:

* **The store reads compiled packages and nothing else** — not a parse tree, not a checked
  `check.Package`. I3 says the base game loads through the path a mod uses; the strongest
  reading of that is that there is only one path. Hot reload will compile to bytes in
  memory and come back through the same call.
* **A package carries every schema its records use**, which reverses what step 5 concluded
  a day earlier. A record's block is laid out by field count and field types, so reading it
  against a schema that has since grown a field is not a stale read but a wrong one — and
  if the schema belongs to another package, nothing in the file said which version the
  bytes were shaped like. Now the file says. The registry was relaxed to match: an
  identical re-declaration changes nothing, an older one is accepted if it is a prefix of
  what is held, and only a genuine disagreement at one version is still refused.
* **A record sits where it was first defined.** A later package overriding it replaces the
  value behind the handle without moving it — the same choice the registry makes for an
  extended schema, and the same reason: everything holding the handle follows (I1).
* **Loading a package is all or nothing.** Every fault it can contain is found in a pass
  that merges nothing, and any of them leaves the store untouched. Half a mod's items is a
  worse outcome than none of them and a message naming the file.
* **The `.fpk` header carries the package's own name.** A package that can only state its
  id cannot be named in the answer to "who supplied this record?", which §8 promises is
  answerable.

**Step 5 — `.fpk`.** The runtime format, both halves, in `data` — so the round trip is a
pure function over byte buffers and every test of it is hermetic, the same property the
parser got for the same reason. Four things worth carrying forward, recorded in
`content-schemas.md`'s third Resolution section:

* **Two encodings, deliberately.** Schemas are self-describing and are decoded at load,
  because they have to become `Schema` values a registry can hold. Records are laid out by
  their schema at fixed offsets and are never decoded — read in place, with explicit
  little-endian loads, so nothing is copied and nothing is parsed. The temptation on the
  next field type will be to use the self-describing form for both; §5.3 is why not.
* **Every tag byte is spelled out rather than taken from a Zig declaration order**, the
  same rule `core/id.zig` follows in specifying FNV-1a by hand. Reordering a union in an
  editor must not be able to change what a byte in a shipped package means.
* ~~**A package carries the schemas it declares, not the ones it uses.**~~ **Reversed by
  step 6**, which needed a record's layout to be stated by the file it lives in. The
  registry rule this was working around was the thing that gave way.
* **The reader is tested by breaking packages, not by reading good ones.** A valid package
  is mutated one byte at a time, four thousand times: about five in eight still open, and
  every accessor on every one either reads a value or returns an error. A byte-for-byte
  random file is refused outright.

**Step 4 — checking.** `check.Package` holds records whose fields are an array indexed by
schema field index, with defaults filled at every level, so the name-to-index lookup happens
once per record and never again. Four things about it are worth carrying forward, all
recorded in `content-schemas.md`'s closing Resolution section:

* **The parse tree grew locations.** §4.5's own worked example is a type error with a caret
  under the offending value, and the parse tree could not produce one — it held a location
  per *record*, and by check time the source bytes belong to whoever answered the `@import`
  and may be gone. Record fields now carry a location for the name and one for the value,
  and a location carries the text of its line. The test for that error asserts the design
  document's example verbatim, line and caret included.
* **The typing rules and the walk that names them are different things.** `schema.checkValue`
  is still the only place that decides whether an integer fits an `f32`, but it can only say
  *that* a value is wrong, never *which* — so the recursive walk lives in the checker, where
  the names are. That is what turns "expects f32, found string" into "field `light.falloff`
  of schema `foundry:item` expects f32, found string", and `grid[1][1]` for a list of lists.
* **`@patch` and `@remove` parse and are then refused, loudly.** Their syntax is frozen
  either way and freezing it early is the point; their semantics are M3's deliberate
  omission. Quietly dropping a mod's patch would be the one genuinely bad answer — the mod
  would appear to load and would not work.
* **A record that fails is left out, and the pass keeps going.** Five records with three
  mistakes give three diagnostics and one surviving record, which is the test. A refused
  `@schema` no longer hides every mistake in the records under it either.

Three things worth knowing about how steps 1 to 3 came out:

* **The layering claim is now verified, not asserted.** Importing `platform` from `data`
  fails with *"no module named 'platform' available within module 'root'"*, checked by
  deliberately breaking it. And the predicted payoff is real: the import resolver is a
  callback, so the cycle, diamond and not-found tests run against a hash map, need no temp
  directory, and cannot be flaky.
* **The lexer validates nothing.** It classifies shape — a word is an identifier or a content
  id by whether it holds a colon — and `id.zig` answers whether it is *valid*. Uppercase,
  dots, colons and dashes are lexed *into* the word on purpose, so `Foundry:torch` reports
  "identifiers are lowercase" rather than a stray-character error pointing at the `F`, and
  every message about a malformed identifier comes from the one place that knows the rules.
* **Three things implementation forced**, all syntax, all recorded in `content-schemas.md`
  §4.7 rather than absorbed silently: a record's schema may be written bare and a content id
  may not; schema attributes are bracketed, because bare ones carried exactly the hazard
  ADR-0020 spent `@` to remove one level up; and a schema's version is the highest `since`
  on its fields rather than a declared number that can disagree with them.

**ADR-0020 — the authoring format is Foundry's own, `.fdt`.** Four candidates were weighed
against ADR-0006's recorded requirements, and three facts settled it. There is no permissive
Zig parser for TOML or KDL that rule 3 and ADR-0016 would let us adopt, so **we write the
parser either way** — which collapses the usual adopt-versus-build argument, since adopting
buys a maintained spec and editor highlighting, not saved work. **No candidate has imports**,
which ADR-0006 requires, so every adopted format gets extended until it is no longer that
format and its errors cite a spec that does not describe it. And **content is named records**,
which is the one shape a general-purpose format expresses worst. There is precedent too, and
it is loud: ADR-0018 wrote a PNG decoder rather than take a library, and `core/id.zig`
specifies FNV-1a in full rather than call `std` — both because a persisted format is a
compatibility contract. Content text is the most persisted thing in the engine.

Two syntactic choices in it are worth more than they look, and a future session should know
they are load-bearing rather than taste:

* **Content IDs are bare tokens, not strings** — `foundry:item.ash`, never `"foundry:item.ash"`.
  A reference is visibly a reference, so a typo fails at compile time instead of becoming a
  string that happens to be wrong; and `grep foundry:item.ash` finds every use across every
  package on disk, including in mods nobody has seen.
* **Directives are `@`-prefixed** — `@import`, `@schema`, `@patch`. Schema names come from
  mods (I6), so an unprefixed directive is a permanent hazard: some future release would have
  to choose between adding a keyword and breaking somebody's schema. One character buys that
  away forever. This deviates from the syntax sketch approved in the session — deliberately,
  and it is the cheapest irreversible decision in the format.

**ADR-0021 — an asset is a content record, and its identity is its content ID.** The
developer's framing is what settled it: a path is the default *way of obtaining* an ID, not
the *definition* of identity, and once a unique ID exists the path is not part of it. So
`source` is an ordinary field meaningful only to `fpack`; **`fpack` materialises every derived
ID into the compiled package**, which is the structural half — the runtime is never given the
chance to learn about paths, so it cannot come to depend on one.

Path-as-identity was refused for the same reason I2 refuses load-order indices: identity must
not be a consequence of where the bytes happen to sit. The concrete payoff is that
`content/core/` can be reorganised without breaking a mod, and a mod overriding
`foundry:texture.sprites` never has to mirror the base game's folders. The honest cost is
recorded in the ADR: a derived ID is only as stable as its path until someone writes it down,
and the ledger that would catch a rename is designed for and deliberately not built.

**`docs/design/content-schemas.md`** (560 lines) and **`docs/design/assets.md`** (272 lines)
are written, and `entity-storage.md` joined them at M4; the design README owes nothing.

Two things in them are worth carrying forward:

* **The layering caught a design decision before it was made.** `data` depends on `core`
  alone (ADR-0007), so it **cannot open a file**: the parser is handed bytes and resolves
  `@import` through a caller-supplied resolver callback. That was not designed for — it fell
  out of the layering table — and it makes the whole content pipeline a pure function:
  hermetically testable, trivially deterministic (I9), and safe on untrusted input without
  wondering what it might read. I7 earning its keep in a way that had nothing to do with
  preventing a bad import.
* **One principle now lives in three places without diverging.** `core/id.zig` refuses to
  normalise content IDs, because normalisation would be a second specification every mod tool
  must reimplement identically. So `data` refuses to *accept* anything that would need
  normalising — IDs are lowercase ASCII or they are not IDs — and asset ID derivation
  transforms nothing, offering a rename or an explicit ID instead of a `Panel-01` → `panel_01`
  rule somebody else would have to guess at.

**M2 is complete.** All six steps below are done: the clip-space contract is written down,
`asset` exists with the PNG decoder ADR-0018 called for, **`render2d` draws**, **the camera
moves**, **it has an atlas and words**, and **a frame has more than one space**. The sandbox
puts thousands of sprites on screen from a decoded PNG sheet, under a camera driven by
keyboard and mouse, surviving resize, with zero Metal validation messages and zero
null-backend violations on the same command stream. Clicking selects the topmost sprite
under the pointer, outlines it and labels it with its index, and the batcher's own numbers
sit in a screen-space panel that stays put while the camera moves.

**Everything the sample draws now comes out of one atlas** — sheet, glyphs and the white
patch the outline stretches — so the sprites, the outline and the text are **three batches
and three draw calls**, and all three breaks are blend-mode changes rather than texture
changes. Adding text cost no draw call at all. *True of M2. At M3 step 9 the sample's images
became content, which arrives as standalone textures, and it draws 5 batches; `render2d`'s
atlas is unchanged and still tested.*

346 tests pass under `-Drhi=null` and 354 under `-Drhi=metal`; all eight target/backend
combinations compile.

Measured on an M5, 600 frames per run: 4,000 and 20,000 sprites both hold vsync at 120Hz
(2 and 3 draw calls); 50,000 gives roughly 52fps and 100,000 roughly 25fps, at 5 and 8 draw
calls. Batching is plainly not the limit there. Whether the wall is fill-rate — 50,000
sprites of ~30 pixels on a 2560x1440 target is heavy overdraw — or submission cost is
**not measured, and so is not claimed**.

`docs/design/render2d.md` describes the whole subsystem — the submission model, coordinate
spaces, camera, sprite and vertex layout, batching and sort key, the per-slot buffer pool,
textures and atlases, the retirement queue, text, statistics and the intended M7 mod
surface. **All of it is now built** except the screen-space pass §11's statistics need, and
three places where implementation changed the design carry a *Resolution* note saying what
changed and why (§8's packer, §10's font, §11's counters).

**One thing in M2 has not been verified by a person:** the key and button *bindings*. That
WASD pans the right way, that dragging carries the world with the cursor, that the wheel
zooms toward the pointer — the maths under each is unit-tested with exact round-trip
properties, and picking is confirmed on screen, but which key means which direction can
only be judged by using it. (WASD became the player's at M5 step 7 and panning moved to the
arrows; the question survives with the keys renamed.)

Two decisions M2 forced were taken as ADRs rather than in code: **ADR-0018** (Foundry
decodes its own PNG) and **ADR-0019** (engine-owned shaders are embedded, content-owned
shaders are assets). A third — that `asset` arrives now, minimal, with no ID scheme — is
recorded below rather than as an ADR, because it changes sequencing rather than
architecture.

**M1 is complete and tagged `m1`.** Every ROADMAP item is done and the exit criterion is
met and seen, clause by clause. Nothing is half-built: the tree is green on both backends,
227 tests pass under `-Drhi=null` and 235 under `-Drhi=metal`, all eight target/backend
combinations compile, and the sandbox runs, resizes and exits cleanly. The resize path —
the last clause to close — needed a new platform capability, `setWindowSize`, and is now
confirmed against a real window under both Metal validation layers.

M0 is complete and tagged `m0`. It was re-audited after the outage that interrupted the
session finishing it — every commit builds from a clean worktree, a cold-cache rebuild
passes, the pinned SDL3 hash re-verifies, and layering, both conformance checks and the
Windows compile scoping were each re-confirmed by deliberately breaking them.

---

## Immediate next steps

**M5 is complete — four bullets and the exit criterion — and M6 is open.** The M6 steps are
below the M5 record.

1. ~~**Collision**, `tilemaps-and-collision.md` §15.~~ **Complete, all seven steps, 2026-09-06.**
   A player walks the sandbox's room and is stopped by its walls.
2. ~~**Sprite animation**, `sprite-animation.md` §10.~~ **Complete, all three steps,
   2026-09-06.** An animated sprite reloads onto the frame it was drawing, compared as the UVs
   a draw call would carry — the check that makes the integer-tick argument something the suite
   holds rather than something a document asserts.
3. ~~**Audio**, `audio.md` §13.~~ **Complete, all six steps, 2026-09-06.** The sandbox makes
   its footsteps, its thud and its ambience from `.wav`s in its own package, through a device
   the mixer opened on a thread Foundry did not create.

4. ~~**A small but genuinely playable sample.**~~ **Complete, 2026-09-06** — `samples/room`,
   a second sample that is a small game rather than a demonstration of one. The engine gained
   nothing for it.

**M5 is closed.** The exit criterion was met the only way it could be: `samples/room` was played
and judged to read as a place, and the mixer was listened to.

**M6 is open and its first document is finished.** ADR-0024 is accepted, `docs/design/ui.md` is
written, and **all six steps of its §16 are implemented**. The steps, each ending in something
that runs and something that is tested:

1. ~~**The kernel's spine.**~~ **Complete, 2026-09-06** — `engine/src/ui/`, seven files, **36
   tests and every one of them headless**. No renderer, no device, no window, no `app` change
   and nothing on screen, which was the point: a step 1 that had needed a device would have
   meant the layering was wrong. See `ui.md`'s Resolution section for what it settled and for
   the two things that document had said wrong.
2. ~~**Layout and the rest of the interaction model.**~~ **Complete, 2026-09-06** —
   `engine/src/ui/layout.zig` joins the seven, and **24 more headless tests**. Regions, panels,
   rows, capture, `clip_push`/`clip_pop`, `label`, `separator`, `spacer`, `checkbox`, and a
   `button` that places itself. Clip rectangles are intersected when they are pushed, so the
   walker hands each command straight to a scissor; `core.math.Rect.intersect` was added for it.
   Every unbalanced case — an extra `endRegion`, an extra `popClip`, a frame that ends with
   either open — is reported and survivable rather than asserted, because from M7 the caller may
   be a mod.
3. ~~**`render2d` gains `setClip` and `blankRegion`.**~~ **Complete, 2026-09-06** — ten more
   tests, and both samples deleted the white texture they had each written by hand. A clip is
   carried on the batcher's item rather than read at record time, because the sort moves sprites
   around and a clip resolved during recording would belong to whatever was submitted last —
   the same bug that put `view` on `Item`. The scissor is clamped to the viewport it is recorded
   in, which is a Metal validation error rather than a nicety.
4. ~~**The walker in `app`**, plus the `BitmapFont` → `FontMetrics` conversion and the drift
   test.~~ **Complete, 2026-09-06** — `engine/src/app/ui_draw.zig`, eleven more tests, and the
   sandbox's statistics are four labels in a panel with a working `follow player` checkbox
   under them. The conversion is `app.UiFont`, which pairs the font with its spacing so the
   kernel's metrics and the walker's draw calls cannot be given different numbers; the drift
   test compares the two measurement implementations **exactly** across 6,528 combinations.
   `app` gained `ui` and `render2d` in the build graph, which is the step's only layering
   change and one ADR-0007 always allowed.
5. ~~**The rest of the debug widget set.**~~ **Complete, 2026-09-06** — `slider`,
   `sliderInt`, `collapsingHeader`, `scrollRegion`, `textField` and `plot`, plus
   `engine/src/ui/state.zig` and twenty-three tests. The sandbox draws all of them: a
   frame-time plot over a ring the sample owns, a zoom slider over the value the wheel already
   changes, a collapsing detail section, and a second panel that is the log console's shape —
   a filter field over a scrolling list of the sample's key bindings.
6. ~~**`samples/room` checks capture.**~~ **Done, 2026-09-07** — the room opens a card over the
   live hall on tab (the walker's name, the volume, a way out), gained click-to-go so that
   there is something in the world the pointer competes for, and holds back what the card took.
   It found that `wantsKeyboard` reported focus rather than consumption, and that a panel
   closing itself mid-frame hands the click back to the game. `samples/sandbox` now describes
   its overlay before it simulates and gates its typed bindings too.

**§16 is finished, and `ui.md` with it.** The next M6 work is its second design document, not
another step of this one.

**A second M6 design document is owed next**: the overlay itself — the entity inspector,
the content browser, the log console, the frame profiler and the introspection APIs beneath
them. `ui.md` §10 stops short of it deliberately, because what an inspector may ask `scene` for
and how per-subsystem timing is collected are a different subject, and because it is better
written once the shape of a panel is known rather than imagined. **M6's fourth bullet — the
introspection APIs — is where the milestone's lasting value is**, not the widgets.

**The two things `ui.md` asks a future session not to quietly undo**, both of which look like
harmless simplifications:

* **Identity and display text are separate parameters** (§3). Every immediate-mode UI in
  existence derives the id from the label, and it is the right trade for a debug tool that is
  never translated. Foundry's game UI is translated content, and deriving ids from on-screen
  strings resets every scroll position and focus the moment the language changes — a bug that
  appears only in the language nobody tests, and is unfixable later without touching every call
  site. The debug widget set may offer a label-derived helper; **the kernel must not.**
* **A UI id is not a `ContentId`** (§3). Both are 64-bit FNV values and the resemblance is a
  trap. One is frozen, reaches compiled packages and save files, and `core/id.zig` says so; the
  other is runtime-only and free to change whenever a layout does. `ui` uses a seeded variant of
  its own rather than calling `core.id.fnv1a64`, because sharing the function would invite
  sharing the guarantees.

**One other §9 decision has come due and should not drift silently: the job system / threading
model, dated "Post-M5".** M5 is now past, and the audio sequence already put a second thread in
the project without one. It should be re-dated deliberately rather than left to rot, and it
should *not* be folded into M6 — a profiler wants timings, not concurrency.

**Both of the gaps that needed a person are now closed, and how the second one was closed is
worth keeping.**

The first was the exit criterion: `samples/room` was played and judged. The second was that the
mixer had never been *heard* — the callback counts, the sample counts and the bit-exact tests
all said the right numbers reached the device, and nobody had listened.

**The null device is stepped, so the mixer's output can be written to a file.**
`null_backend.Platform.stepAudio` returns the samples the callback wrote, for exactly the
frames asked for, on the calling thread — so a harness can drive a scripted arrangement,
collect the blocks and emit a WAV, deterministically, **on a machine with no audio hardware at
all**. That was done once with a throwaway test (removed before commit) and it produced twelve
seconds: ambience swept across, footsteps panned by the walk, three lamps catching at different
positions, a wall, then the door. Peak −10.1 dBFS, zero clipped frames, stereo energy moving
L 1252 / R 113 → L 303 / R 1219 monotonically, the door dead centre at L=R, and exact silence
after the last voice ended.

The numbers are what a test can hold; **what the listening added was that nothing clicks and
the resampled footstep sounds like a footstep**, which no assertion reaches. Making the harness
permanent — a `scripts/` entry or a build step that renders a mix — is a small job nobody has
done, and it is the difference between this check being repeatable and it having happened once.

**Four things carried forward, and none of them is a bug:**

* The key and button *bindings*, carried from M2 and still needing a person to judge them —
  that dragging carries the world with the cursor, and that the wheel zooms toward the
  pointer. Half of this closed itself at step 7: WASD no longer pans at all, it drives the
  player, and panning moved to the arrows. Whether *that* feels right is the remaining
  question, and it is the same kind of question.
* **Shaders are not assets**, which was an M3 roadmap item and was deliberately not built.
  Engine-owned shaders stay embedded (ADR-0019), so the only case is a *content-owned*
  shader, and nothing can reference one until there is a material system. Building an asset
  kind with per-backend variant selection (ADR-0015) for no consumer is the hypothetical
  requirement rule 7 warns about. Due with the material system, or the first time a sample
  wants its own shader. Adding it is a schema and a runtime-registered loader; nothing has
  to be reshaped.
* ~~**Nothing is pushed.**~~ **Pushed 2026-09-06**, thirteen commits, with the `m5` tag —
  M2 through M5's work reaching `origin/main` in one go. The repository had been four
  milestones ahead of its remote.
* The GitHub repository description still says the engine implementation has not started,
  which four complete milestones have made false. Outward-facing, so it is the user's call.

**M4 — World: "it has entities"** is complete. Its design was written first
(`docs/design/entity-storage.md` §15), and these were its six steps, each of which left the
tree green and the sandbox runnable:

1. ~~**The module, entities, and the type registry.**~~ **Done, 2026-09-05.** `scene` in the
   build graph with `core` and `data`; `Entity`; `World` with entity create/destroy;
   `ComponentTypeInfo` and registration, with every check the design's §6 asks for. Layering
   confirmed by breaking it, as `data`'s was — and, as with `data`, only once something
   *references* the illegal import, because Zig analyses top-level declarations lazily. Two
   things changed from the design and are recorded in its Resolution: a component type is a
   handle rather than an index, and a zero-size component is legal and means a marker.
2. ~~**Type-erased storage.**~~ **Done, 2026-09-05.** `store.zig`: sparse by entity index,
   dense owners and dense bytes, swap-removal, `construct` and `destruct` including on
   teardown, and markers. `World` gained `addComponent`, `getComponent`, `hasComponent`,
   `removeComponent`, and a `destroy` that clears every store before freeing the slot — so a
   `destruct` running there can still look the entity up. Tested against a component type
   built by hand, so the storage is proven before the `comptime` sugar exists to hide it.
3. ~~**The `comptime` wrapper.**~~ **Done, 2026-09-05.** `derive.zig`. Two things the design
   did not have right: an asset reference in a component is a `core.ContentId` and never an
   `AssetHandle` — a handle carries no content id, so serializing one would need the asset
   registry `scene` deliberately does not have — and `deserialize` does not take a schema,
   because the `Fields` it is given already carries the one it was read against. Fields match
   by **position**, since a schema may only append; that plus a generated `construct` is the
   whole of I8's forward compatibility for components.
4. ~~**Queries.**~~ **Done, 2026-09-05.** `query.zig`, `World.query` and `World.queryOf`. The
   order decision is tested by being reversed: the same two components named in both orders
   yield the same set in different orders, which is what "a property of the query as written"
   means and what driving from the smallest store would have hidden. A `Query` holds its types
   by value — borrowing made the typed wrapper self-referential — and the stores slice it
   borrows is stable because §6 refuses to register a type once a world has entities.
5. ~~**Systems, and the sandbox gets a world.**~~ **Done, 2026-09-05.** `system.zig`, and the
   sandbox converted. The interface survived its first non-test consumer with one correction:
   **a world cannot borrow the engine's schema registry**, because hot reload builds a whole
   new one and swaps it, so the sample owns the registry its world borrows. Step 6 has to
   answer the other half of that — content defining component instances is checked against the
   *content* registry, which must therefore learn the component schemas, the way
   `asset.schemas.registerAll` already teaches it the asset ones.
6. ~~**Content and saves.**~~ **Done, 2026-09-05.** `foundry:entity` and `foundry:scene`,
   `fpack` registering them, `World.spawn`/`spawnScene` — all-or-nothing, and refusing a
   package whose schema disagrees with the registered one about a field they share. Then the
   save: `serialize` beside `deserialize` in the wrapper, `.fsav` with §9's trust rules,
   `World.save`/`load`/`clear`, and the `data` factoring — which turned out to be two things
   rather than one, since a save carries schemas for exactly the reason a package does.
   `core.HandlePool` also had to learn `slotAt`, `freeSlots` and `restore`, because forcing a
   slot to a particular generation through the public interface would take 2^32 calls.

**What M5 opens with.** Two `CLAUDE.md` §9 decisions come due — physics (own vs. ported) and
audio (own mixer vs. library) — and both need an ADR before code, the way ADR-0020 and
ADR-0021 preceded `data`. M5's design document comes first either way, and the two open
questions `entity-storage.md` §13 expects M5 to force are worth reading before it is written:
per-instance overrides in a scene (`@patch`, frozen in syntax and unimplemented) and spatial
queries, which arrive with the tilemap and collision because that is where there is something
to accelerate.

**What M4 must not quietly break.** I6 above all: component types and systems are
runtime-registered, and the `comptime` wrapper *produces* registration data rather than
becoming a second registration path. A future session could undo ADR-0010 by accident simply
by making the ergonomic path the only one. Also §5's iteration rule — driving a query from
the smallest store is the faster and more conventional choice, and it is rejected on purpose
(I9), so switching to it is reversing a decision rather than finding an oversight.

**What M4 took from `data`, and left behind:** the field-block layout and the schema encoding
are now their own types — `BlockWriter`, `Block`, `Blocks`, `SchemaWriter`, `SchemaDecoder` —
and `.fpk` is a container around them rather than their owner. `Fields` and `List` hold a
`Blocks` instead of a `*fpk.Reader`, so the reading code cannot tell a save from a package.
That is what stops the two formats drifting apart, and it is worth more than the writer-side
sharing §15 originally asked for, because the save now inherits `.fpk`'s mutate-one-byte
discipline rather than needing its own.

**M3, for reference.** Ten steps, ordered so each left the tree green and the sandbox
runnable, and so nothing was a rewrite of the one before.

1. ~~**`data` (L1), and identity.**~~ **Done, 2026-09-04.** The module, the `namespace:name`
   validator, `SchemaId` as a type distinct from `ContentId` over the same hash, and the
   runtime schema registry. Layering confirmed by breaking it: importing `platform` from
   `data` fails with "no module named 'platform' available within module 'root'".
2. ~~**The `.fdt` lexer and parser.**~~ **Done, 2026-09-04.** Grammar per §4, the resolver
   callback for `@import` with cycle, diamond and depth handling, the `Limits` struct, and
   recovery to the next top-level item. Every test is hermetic — the import tests use a
   resolver over a hash map and touch no disk.
3. ~~**Diagnostics.**~~ **Done, 2026-09-04.** File, line, column, span, the source line and
   a caret under it, with a cap that counts what it swallows. Errors are collected, not
   returned: four records with three mistakes produce three errors, which is the test.
4. ~~**Values and validation.**~~ **Done, 2026-09-04.** `check.zig`: schemas registered,
   every record checked against the one it names, defaults filled at every level, and the
   result laid out by schema field index. `schema.checkValue` still owns the leaf rules, so
   the parser, the registry and `fpack` cannot come to disagree about them; the walk that
   names *which* value is wrong lives in the checker, where the field names are.
5. ~~**`.fpk`, writer and reader.**~~ **Done, 2026-09-04.** `fpk.zig`, both halves. The
   reader validates the header, the sections, the tables and every string in them at open,
   and re-checks everything it reads out of a record block, because a block's shape depends
   on a schema the file need not agree with. A random file is a test, and so is a valid
   package with one byte changed.
6. ~~**Packages and the store.**~~ **Done, 2026-09-04.** `store.zig`: ordered merge,
   replace semantics, provenance, and both documented iteration orders (§6) — packages in
   the order given, records at the position where they were first defined. Loading is all
   or nothing, a package carries every schema its records use, and each record is read
   against the copy its own package shipped rather than the registry's newer one.
7. ~~**`tools/fpack`.**~~ **Done, 2026-09-04.** Walks a package directory in sorted order,
   parses and checks every `.fdt` in it, derives asset ids per `assets.md` §3 as records
   that go through the same parser and checker as authored ones, reports collisions naming
   both files, and emits a `.fpk`. Its `@import` resolver is the first real one: relative
   to the importing file, textually normalised, and unable to climb out of the package.
8. ~~**`asset` gains its registry.**~~ **Done, 2026-09-05.** `registry.zig`: content id in,
   reference-counted handle out, loaders registered at runtime, and `render2d/loader.zig`
   registering the one that knows what a GPU texture is from above. `foundry:texture` went
   to version 2 with the `filter` and `wrap` the loader reads, and version 1 content still
   loads. `loadImage` is gone. `engine/tests/` exists, holding the first test that needs to
   stand above two modules at once.
9. ~~**`content/core` becomes package zero (I3).**~~ **Done, 2026-09-05.** `content/core`
   holds the debug font; the sandbox ships `samples/sandbox/content/` with its sheet and its
   settings; `build.zig` compiles both with `fpack` and installs them under
   `<prefix>/content`; `app` loads them in the order it is given and mounts each one's
   files. The sample embeds nothing and names no path. The sheet and font were expected to
   move into `content/core` together — the sheet went to the sample's own package instead,
   because a sample is the reference for what a game looks like and a game's content is
   its own.
10. ~~**Hot reload, and `docs/modding/` begins.**~~ **Done, 2026-09-05.** Stamps on every
    package file and every loaded asset source, checked at the top of `beginFrame`; packages
    reload by building a whole new content set and swapping it, assets reload behind their
    handles, and a failed reload changes nothing. `docs/modding/README.md` and
    `content-mods.md`, the second verified by following it verbatim.

**The exit criteria** are the sandbox's content living entirely in data, a second package
placed after it overriding a value visibly, and editing a content file live-updating the
running program. The third is the one that will be tempting to declare rather than see.

**What M3 must not quietly break:** I3 above all — there is no privileged loading path, and
`content/core` going through the same code a mod does is the only durable proof of it. Also
ADR-0019, which a future session could undo by accident: the sprite shader stays embedded in
the binary, because it is the other half of a contract with the batcher's vertex layout.
Moving it into the content system "for consistency" would be undoing a decision, not finding
an oversight.

**M2, for reference** — each step left the tree green and the sandbox runnable, and none was
a rewrite of the one before.

1. ~~**`core.math` grows what a camera needs.**~~ **Done differently, 2026-09-04.** The
   projection did *not* go into `core.math`, which opens by promising it "does not know
   which way is up" — `core` is L0 with consumers that are not renderers, and a matrix
   baking in one clip space would be a landmine for all of them. What was actually missing
   was the **convention**, which `core/math.zig` had said since M0 was "owed in
   `docs/design/rhi.md`" and which M1 shipped without writing. That debt is now paid:
   rhi.md §9 states it and `rhi.clip_space` expresses it. `render2d` will build its own
   projection and read the convention rather than hardcode it.
2. ~~**`asset` (L2), minimal.**~~ **Done, 2026-09-04.** `Image` (always RGBA8, straight
   alpha, sRGB-encoded), the PNG decoder, and `loadImage`. No cache yet: one with no
   consumer would be speculative, and it costs nothing to add when `render2d` gives it a
   reason. 16 tests, including fixtures generated by an implementation sharing no code with
   the decoder, and truncation checked at every prefix length.
3. ~~**`render2d` (L3), the batcher.**~~ **Done, 2026-09-04.** Sprite submission, the sort
   key, the per-slot buffer pool, both memory paths, the engine sprite shader, the texture
   pool with its retirement queue, and `app.Engine.renderFrame` owning the frame.
4. ~~**Camera input.**~~ **Done, 2026-09-04.** `Camera2D.panByScreen` and
   `Camera2D.zoomAround` in `render2d`; the bindings in the sandbox, because which key pans
   is input policy and `render2d` cannot import `platform` anyway. `sprite.containsPoint`
   answers what was clicked, and the sandbox scans its own sprites — the renderer retains no
   list to search. Confirmed on screen: the selection outline appears around the sprite under
   the pick point, rotated with it.
5. ~~**Atlas, then text.**~~ **Done, 2026-09-04.** `atlas.Packer` and `Region` in
   `render2d`, `text.BitmapFont` and `text.Layout` over a `Region` so a font in an atlas
   and a font on its own texture are the same thing, and `Renderer.drawText`. The RHI
   gained `dst_origin` on a buffer-to-texture copy, without which packing one sprite means
   re-uploading the whole atlas. The sandbox packs its sheet, its font and its white patch
   into one 512-pixel atlas and draws both world-space and screen-constant text.
6. ~~**Frame statistics on screen.**~~ **Done, 2026-09-04.** It needed a second space, and
   the answer was **views** rather than the screen/world flag the question suggested: a
   per-frame table with `world` and `screen` always present and `addView` for anything
   else. The sandbox's panel is `setView(.screen)` and then ordinary draws, converting no
   coordinates at all.

---

## Known bugs and technical debt

* **A texture hot reload destroys its staging buffer while frames are still in flight.**
  Found 2026-09-06 while checking that step 7 survived a content reload, and **not caused by
  it** — the same two lines appear on `main` before that commit, so it dates from step 5 or 6
  at the latest. The null backend's validation says it plainly: `rule 9 (lifetime): buffer
  'render2d texture staging' destroyed while frame 120 is in flight (completed: 118)`. Metal
  would forgive it and a Metal build says nothing, which is exactly what the validating
  backend exists for. To reproduce: run the sandbox, edit `samples/sandbox/content/sandbox.fdt`
  and `zig build` while it runs. The fix belongs with `render2d`'s texture loader — the
  staging buffer has to outlive the frames that reference it, the way every other transient
  does — and it is a `render2d`/`rhi` job rather than a collision one, which is why it is
  recorded here rather than folded into step 7.
* **The log sink has a runtime *level* filter but no timestamps, no scope filtering and no
  destination but stderr.** Timestamps want a monotonic source, which lives on `Platform`,
  and a free logging function has no instance to ask — worth solving when there is a log
  *file* to correlate against, at M9. Scope filtering is compile-time only for now
  (`std.Options.log_scope_levels`), and there are three scopes.
* **Frame pacing exists only on Metal.** A windowed Metal build is paced by the display,
  because the layer has vsync enabled and acquiring a drawable blocks. The null backend has
  no swapchain to wait on, so that path still sleeps 2ms per frame to avoid pegging a core.
  Still deliberately outside `Engine` — pacing is renderer policy.
* **Subsystem lifecycle is explicit fields, not a registry.** Correct at two subsystems and
  machinery guarding nothing; revisit at perhaps six, which is also when the ordering stops
  being obvious by inspection.
* **The handle pool is sparse and iterates dead slots.** Fine for its intended use — lookup
  by identity, rare iteration. Deliberately not optimised, and deliberately not generalised
  toward component storage (ADR-0010, M4).
* **`platform` has no gamepad support, file watching or IME preedit.** Each is deferred with
  a recorded reason in the design doc's Resolution; none requires the interface to change to
  accommodate it later. Audio was the fourth item on this list and arrived 2026-09-06, adding
  four functions and needing no reshaping of anything already there — which is the evidence
  that the deferral was the right kind.
* **Nothing has listened to the mixer.** The arithmetic is tested bit-exactly, the device is
  confirmed to call back with the block it was promised, and the sandbox reports how many
  sounds it started; none of that would catch a swapped stereo pair or an envelope that
  clicks. Thirty seconds with headphones is the check, and it has not been done.
* **A device that disappears mid-run is whatever SDL3 does about it.** `audio.md`'s open
  question 4: unplugging headphones today produces no event and no reopen. Owed when someone
  unplugs something and the answer is unsatisfying; `platform`'s interface has room for a
  device-changed event beside the window events, so nothing has to be reshaped.
* **Text input is enabled for a window's whole lifetime.** SDL3 requires
  `SDL_StartTextInput` explicitly, and without it `text_input` events never arrive at all.
  Per-window IME control belongs with the UI system (M6).
* **Only `metal_layer` surfaces are implemented.** `win32_hwnd` and the X11/Wayland kinds
  return `SurfaceUnavailable`. SDL can produce an `HWND` through its properties API, but
  there is no backend to consume one and no way to test it.
* **Reading a directory as a file reports `IoFailed`, not `WrongFileKind`,** because macOS
  opens the directory happily and fails at the read. The test asserts only that it errors.
  Classifying it would cost a `stat` on every read, which is not worth it.
* ~~**A real-window resize has never been run.**~~ **Closed 2026-09-04** by adding
  `setWindowSize` to `platform`. Five real resizes per run — 1280x720, 900x900 (clamped by
  the window manager to 900x794), 1400x500, 640x480 — each producing a `window_resized`
  event with the pixel size tracking it, the `CAMetalLayer` following, zero Metal API and
  GPU validation messages, and zero violations from the null backend on the same command
  stream. Driving it from *outside* the process is still impossible here (`osascript is not
  allowed assistive access`), which is why the capability went in the engine instead.

* **`FrameError` cannot distinguish transient from fatal surface failure.** Metal returning
  no drawable — a minimised or occluded window, or every drawable still in flight — is
  transient and the right response is to skip the frame. A genuinely lost surface is fatal.
  The RHI has one error, `SurfaceLost`, for both, so the backend reports the transient case
  as `SurfaceLost` and the sandbox skips. Vulkan draws exactly this distinction
  (`OUT_OF_DATE` versus `SURFACE_LOST`), which is a hint that the RHI should too — but
  adding an error is a contract change, so it is recorded rather than done quietly.

* **Xcode GPU frame capture is confirmed only by its prerequisites.** The sandbox runs
  clean under `MTL_CAPTURE_ENABLED=1`, and shaders carry `-frecord-sources`, so a capture
  should open and should show MSL rather than disassembly — but no one has yet opened one
  in Xcode and looked. This is one of ADR-0012's stated reasons for the shim design, so it
  is worth an actual look during M2, when there is more than one draw to inspect.

* ~~**Where a compiled shader lives is unsettled, deliberately.**~~ **Settled by ADR-0019**,
  2026-09-04, because M2 forced it: `render2d` needs a sprite shader before any content
  system exists. Engine-owned shaders — those whose absence means the renderer cannot draw —
  are compiled by the build step and embedded in the engine module. Content-owned shaders
  remain assets per ADR-0015. This does not prejudge M3: first-party *content* shaders will
  still load through the package-zero path like everyone else's.

* **No backend defers a destroy, though `interface.zig` says every one does.** The comment
  claims a destroy is deferred until no in-flight frame can reference the resource; neither
  backend implements that. Metal happens to be safe — `[queue commandBuffer]` retains its
  referenced resources, so a destroyed buffer outlives the GPU's use of it — and
  `Device.deinit` does wait on every in-flight command buffer before releasing anything. But
  a Vulkan or D3D12 backend would need a real deferred-destroy queue, and until one exists
  the interface is promising something it does not deliver. Found while writing the quad,
  which is why the sandbox holds its resources for the process lifetime instead of leaning
  on the guarantee. Fixing it is a design choice — a destroy queue, or an explicit
  `waitIdle` the interface also lacks — so it is recorded rather than settled quietly.
  **`render2d.md` §9 responds to this without discharging it**: the renderer keeps its own
  retirement queue and does not rely on the RHI's promise, so M2's code is correct whether or
  not the RHI ever keeps it. The interface still says something untrue, and that stays here.
  **Half of the fix landed 2026-09-04**: `waitIdle` now exists on the interface and in both
  backends, so a caller that must destroy safely has a way to reach a state where doing so
  is legal. The deferred-destroy *queue* the comment promises still does not exist.

* **Usage-flag conformance is declared but unenforced.** Buffers and textures carry a
  usage set because Vulkan and D3D12 require it at creation, and both treat using a
  resource outside its declared usage as undefined behaviour — so it is a real invariant.
  It is not one of the ten documented rules, so the validation backend deliberately does
  not check it. Enforcing it would be an eleventh rule and therefore a contract change;
  recorded as an open question in `docs/design/rhi.md` §13 rather than resolved quietly.
* **The RHI is still validated by one real backend.** ADR-0003's mitigations reduce this
  and are now demonstrably working — the null backend checks every command stream Metal
  runs — but they do not remove it. Expect backend #2 to find design errors, particularly
  in the parts Metal is most forgiving about: resource state and bind group compatibility.
* **SDL3 arrives through a third-party build script** that can bitrot against a future
  pinned Zig release. Checking it is part of the cost of every Zig upgrade. Fallbacks in
  ADR-0002.
* Shaders will need per-backend variants when a second backend lands (ADR-0015).
* Sparse-set entity storage (M4) is explicitly a first implementation, not a final one.
* The first content authoring format may need replacing once real content exists at scale.
  ADR-0006 contains this by separating schemas from syntax.

---

## Important decisions made recently

**M5 (2026-09-05), the two decisions `CLAUDE.md` §9 had been holding since M0:**

* **ADR-0022 — own 2D collision, scoped to collision rather than dynamics.** The deciding
  argument was **I9, not licensing**. Box2D v3 and Chipmunk2D are both MIT and both permitted
  by ADR-0016; what ruled them out is that a solver's contact-resolution order changes its
  answers, is an implementation detail it is free to change between versions, and I9 needs that
  order documented and stable — so resting on one means auditing someone else's solver as
  carefully as writing our own. Second argument: a tile game needs a swept box against static
  geometry with a sliding response, and mass, inertia, restitution, friction and joints are
  most of what a rigid-body engine *is*. `physics2d` is **L1 on `core` alone**, holds no time
  and no velocity, and integrates nothing.
* **ADR-0023 — own mixer, own WAV decoding.** `platform` already owned the audio device
  (§4.3), so the device was never the question. SDL3_mixer would leak SDL past `platform` — a
  §10 non-negotiable — and its channel/music model would become the shape of Foundry's audio
  API at a boundary games and mods see. miniaudio is device + decode + mix as one stack and
  would displace `platform`'s charter; taking a third of it is the worst version of the trade.
  WAV decoding sits beside PNG in `asset` on ADR-0018's reasoning. The **null device is
  stepped, not threaded**, which is the whole reason the mixer can have real tests.
* **The sample is top-down tile movement** — the user's call, and the thing that puts gravity,
  slopes, jump tuning and one-way platforms out of M5's scope rather than merely unbuilt.
* **M5 adds no engine-owned component types.** A `foundry:collider` invented now is a name
  every mod is stuck with from M7, chosen before any game has said what belongs on one. The
  sample defines its own, exactly as it already defines `transform` and `sprite`. The standard
  vocabulary is M7's decision, made when the ABI freezes it.

**Audio (2026-09-06), decided while implementing and recorded in `audio.md`'s four Resolution
sections rather than as ADRs, because each is an implementation choice inside a decision
ADR-0023 already made:**

* **A dropped `play` is an error; every other dropped command is only counted.** The design
  said a full ring drops and counts, which is right for a `set_gain` and catastrophic for a
  `play`: the slot is already claimed and the retirement that frees it can only come from a
  voice that started. So `play` undoes its claim and returns `CommandQueueFull`.
* **The retirement ring is sized to the voice count**, which turns "a dropped retirement would
  strand a slot forever" from a risk into an impossibility — a voice retires at most once and
  cannot play again until `update` returns its slot. The push therefore asserts rather than
  ignoring its result.
* **The SDL3 backend takes the device's sample rate and gives back the requested channel
  count.** Foundry resamples in the voice anyway, so adopting the hardware rate removes SDL's
  resampler; a mixer that had to understand 5.1 to be heard on a 5.1 machine would be the
  worse trade in the other direction.
* **`Mixer.shutdown` exists because teardown wants two opposite orders** — the loader must go
  before `deinit`, and the mixer's asset references must come back before the loader goes.
  `deinit` does not call it, so `deinit` stays safe after the registry has already gone.
* **The sample names sound ids and no gains**, deliberately, so that `audio.md`'s open
  question 2 — buses and category sliders — is not answered by accident.
* **The mixer opens the audio device**, which ADR-0023 left implicit. The device cannot be
  opened before a callback exists and the callback is the mixer's, so `Mixer.init` opens it and
  `deinit` closes it. The consequence is the useful part: **`app` gains no dependency on
  `audio`** and keeps the same shape it already has with `render2d`, where it owns the
  `rhi.Device` and the game owns the `Renderer`.
* **Audio's real-time discipline is a design property, not a rule to remember.** Everything
  that can fail was moved to the game thread — `play` acquires the asset, claims the voice and
  returns the error — so the callback has nothing left to report and no reason to reach for an
  allocation, a lock or a log. ADR-0023 named the permanent cost; this is what reduces it.
* **A non-finite sample in a float WAV refuses the whole file.** Stricter than the texture
  path, which prefers a wrong-looking sprite to a missing one, and deliberately asymmetric: a
  NaN entering the mixer propagates through the accumulator and silences *everything* for the
  rest of the session, which is the least diagnosable failure available.
* **Animation state is an integer tick count, and the component stores a frame index rather
  than a `Region`.** The first because a float accumulator drifts, does not survive a save, and
  makes "which frame at tick 700?" only nearly answerable; the second because a `Region`
  carries a `TextureHandle` and a component is serialized — the rule ADR-0021 and
  `entity-storage.md` §8 already set for textures, applied unchanged.

**M4 (2026-09-05), the decisions building it forced:**

* **A save is its own format, not a package.** `.fsav`, with its own magic and its version in
  a field. Reusing `.fpk` would require giving every entity a content ID, and a generated
  `save:entity.00417` is an identity derived from position — the precise anti-pattern I2
  exists to forbid. Content IDs name authored things; entities are not authored. What the two
  formats *do* share is everything below the container, which is the next entry.
* **The field-block layout and the schema encoding left `.fpk` and became their own types.**
  `BlockWriter`, `Block`, `Blocks`, `SchemaWriter`, `SchemaDecoder`. `Fields` and `List` hold
  a `Blocks` rather than a `*fpk.Reader`, so the reading code cannot tell a save from a
  package. The design asked only for the writer to be shared; sharing the *reader* turned out
  to matter more, because the save inherits `.fpk`'s mutate-one-byte discipline rather than
  needing a second one of its own.
* **A save carries every component type's full schema**, and a build whose component has
  gained a field reads an older file against the shape it was written with. Same guarantee a
  package gives, reached the same way — carry the schema, never assume the reader's (I8). A
  type the build does not know is **reported and skipped**, so a save made with a mod loaded
  opens without it.
* **`core.HandlePool` learned to be restored**, because nothing else could preserve entity
  identity: forcing a slot to a particular generation through `add` and `remove` would take
  2^32 calls. It is the one entry point in `core` whose input is not the pool's own, so it
  validates rather than asserts — and a save states each slot's occupancy *and* its free
  list, when either implies the other, precisely so the two can be cross-checked.
* **`serialize` is optional and its absence means "not saved".** A derived cache or a
  frame-local marker should not be in a save, and that is the type's decision rather than the
  format's. Both halves are required together: a type that writes and cannot read back would
  produce a file this build cannot open.

**M3, the decisions it came due on:**

* **Foundry gets its own authoring text format, `.fdt` (ADR-0020).** Not taste — three facts.
  There is no permissive Zig parser for TOML or KDL that rule 3 and ADR-0016 would let us
  adopt, so we write the parser either way and adopting buys a maintained spec and editor
  highlighting rather than saved work. No candidate has imports, which ADR-0006 requires, so
  every adopted format ends up extended past the point where it is still that format. And
  content is *named records*, the one shape a general-purpose format expresses worst. The
  precedent was already set twice: ADR-0018's PNG decoder and `core/id.zig`'s hand-specified
  FNV-1a, both because a persisted format is a compatibility contract. **The honest cost,
  recorded in the ADR: nobody's editor highlights `.fdt` until we ship a grammar**, and that
  is owed before `docs/modding/` can send anyone off to write content.
* **Content IDs are bare tokens in the text, not strings.** `foundry:item.ash`. A reference is
  visibly a reference, so a mistyped one fails at compile time instead of becoming a string
  that happens to be wrong, and `grep` finds every use across every package on disk. Making
  them strings later would silently convert a class of build error into a runtime lookup
  failure.
* **Directives are `@`-prefixed.** `@import`, `@schema`, `@patch` — so any bare leading token
  is a schema name. Schema names come from mods (I6), so an unprefixed directive is a
  permanent hazard: some future release would have to choose between adding a keyword and
  breaking somebody's schema. One character, and there will never be that release. **This
  deviates from the syntax sketch approved in the session**, deliberately and flagged.
* **An asset is a content record; a path derives an ID but never defines identity
  (ADR-0021).** The developer's framing settled it: the path is the default way of *obtaining*
  an ID, not the *definition* of one, and once a unique ID exists the path is not part of it.
  `fpack` materialises every derived ID into the compiled package, which is the structural
  half — the runtime never sees a path as identity, so it cannot come to depend on one.
  Refused for the same reason I2 refuses load-order indices: **identity must not be a
  consequence of where the bytes happen to sit.** The payoff is that `content/core/` can be
  reorganised without breaking a mod, and an override never mirrors somebody else's folders.
  The cost is that a derived ID is only as stable as its path until it is written down; the
  ledger that would catch a rename is designed for and not built.
* **Derivation transforms nothing.** `Panel-01.png` does not become `panel_01` — it is an
  error offering a rename or an explicit ID. Same principle `core/id.zig` states for hashing:
  a transformation is a second specification every external mod tool must reimplement
  identically, and any divergence produces IDs that differ invisibly. Refusing to transform
  means there is nothing to reimplement. That principle now holds in three places and has not
  diverged in any of them.
* **`data` cannot open a file, and that turned out to be the best thing about it.** ADR-0007
  gives L1 `data` only `core`, so the parser is handed bytes and resolves `@import` through a
  caller-supplied callback. Not designed for — it fell out of the layering table — and it
  makes the content pipeline a pure function: hermetically testable, trivially deterministic
  (I9), and safe on untrusted input without wondering what it might read. Worth remembering
  the next time the layering looks like it is in the way.
* **`render2d` registers the texture loader into `asset` from above.** *Built at step 8.* L2
  `asset` cannot know what a GPU texture is and does not need to; the payload it holds is one
  opaque word, freed by the module that made it. The dependency points down while the
  capability points up, which is what I6's runtime registration is for — a layering problem
  solved by the mechanism rather than by an exception. The one thing it costs is a teardown
  order the compiler cannot enforce: the registry unloads through its loaders, so it goes
  before the renderer, which goes before the device.
* **Merge semantics land incrementally, as ADR-0006 said they would.** M3 implements
  **replace**. `@patch` and `@remove` are specified in `content-schemas.md` §7 and land after,
  along with the schema-declared choice of whether a patched list replaces or appends —
  because "the loot table" and "the display name" want opposite answers and no global default
  is right for both.

**This session (M2, views and the readout):**

* **A frame has a table of views, not a screen/world flag.** The statistics readout needed a
  second space, and the smallest thing that answers *that* answers nothing after it: a
  parallax layer, a minimap, a split screen and a mod's overlay are all spaces and none of
  them is "screen". So the renderer holds a small per-frame table — `world` and `screen`
  always present, `addView` for the rest — and a draw is recorded against whichever is
  current. The alternative shapes were considered explicitly: a `space` field on `Sprite`
  would have to be copied onto `TextOptions` and every future draw struct while still
  carrying two values, and a second `begin`/`record` pair doubles a lifecycle that a game
  can forget half of.

* **The current view is renderer state, not a parameter.** It changes per screenful, not per
  sprite — a HUD is one `setView` and then a hundred draws — so paying for it in every draw
  struct is paying per sprite for something that changes per frame. It resets with `begin`,
  which is the only place it could go stale.

* **`view` leads the sort key.** A view is drawn entirely before the next, and `layer`
  orders *within* a view rather than across views. That is what makes a HUD a HUD: nothing
  in the world can be given a layer high enough to cover it. The honest cost is that the
  floor on batch count is the number of views in use, and `Stats.views` reports it so a
  surprising batch count has somewhere to be checked first.

* **A space knows which way is up, and the first windowed run is what insisted.** The world
  is Y-up and the screen is Y-down; `writeQuad` had assumed Y-up, so the whole readout drew
  upside down. `YAxis` now travels from the view to the quad builder, where it swaps which
  corner the texture's top row belongs to and flips the rotation sign so a positive angle
  turns the same way *as seen* in both. `containsPoint` takes it too, so a UI element will
  be clickable exactly where it is drawn — which M6 will want. Worth recording as a
  verification lesson as much as a design one: 102 `render2d` tests passed while every
  glyph on screen was inverted, because until then every space in the engine was Y-up.

* **Views were cheap because the transform was already inline constants.** A view change
  costs one `setInlineConstants`, one `setViewport` and a batch break — the same order as a
  blend-mode change, which the batcher already handled. Had the view-projection been a
  per-frame bind group this decision would have been much more expensive, and that is worth
  remembering the next time something looks like it belongs in a frame-wide uniform.

**Earlier this session (M2, the atlas and text):**

* **The RHI learned to write a rectangle of a texture, and the contract moved first.**
  `BufferToTextureCopy` could only write a whole texture, so packing one sprite into an
  atlas would have meant re-uploading megabytes. `dst_origin` defaults to the corner, so a
  whole-texture upload still reads as one, and Metal, Vulkan and D3D12 all express it
  natively. **Rule 10 grew** to cover a copy's region lying inside the resource it
  addresses — a clarification of its scope, the way rule 8 already gets one, since a
  texture's extent bounds writes to it exactly as the other numbers in rule 10 bound
  things. `rhi.md` §11 says a tightening changes the contract there first, and it did.

* **The packer is pure logic and only a `Placement` escapes it.** No allocator beyond its
  own list, no GPU, no renderer. That is what makes a better packer a drop-in replacement
  rather than an API change, and it is the reason the design doc could commit to "shelf"
  without committing to it forever.

* **Sorting by height was not available, so best fit by height replaced it.** The design
  said "sort by height, fill rows"; sorting is what an *offline* packer does, and
  `atlasAdd` takes one image at a time because a mod adds one sprite at load time long
  after the others were packed (I3). Best fit is the incremental equivalent and degenerates
  to the sorted result when the images are the same height — which a sprite sheet and a
  glyph grid both are. Recorded as a resolution in `render2d.md` §8 rather than left as a
  quiet divergence.

* **`Region.sub` cuts in the region's own pixel space, not the texture's.** This is the
  decision that makes "a font in an atlas and a font on its own texture are the same thing"
  true rather than aspirational: the sandbox's sheet-cell arithmetic did not change when
  the sheet moved into an atlas, and `BitmapFont` never learns which it has.

* **`AtlasFull` and `RegionTooLarge` are different answers.** The first means try another
  atlas. A caller that answered the second the same way would allocate atlases until it ran
  out of memory, and an image too large for any atlas of that size is exactly what a mod
  shipping a 4096-pixel sprite produces. Content comes from files, so the loop is reachable.

* **Text is not a separate pipeline, and there is nothing to make it one.** A glyph is a
  sprite by the time the batcher sees it, so "text and sprites from one atlas cost one draw
  call" falls out of there being no second path rather than being arranged — and there is a
  test that fails if that stops being true. Glyphs count in `sprites` as well as in
  `glyphs`, because counting them once would make the sprite count disagree with the vertex
  count.

* **`Layout` is the one definition of where a glyph goes, and `measure` runs it.** Same
  discipline as `writeQuad` and `containsPoint` sharing `localExtents`: two implementations
  that agree today are a bug you can only find in a screenshot.

* **A mod's translation file is text from a stranger.** Invalid UTF-8 draws a substitution
  glyph and advances one byte; a codepoint the font lacks draws the same; a substitute the
  font *also* lacks yields nothing rather than looking itself up again; iteration stops at
  the slice's end and not at a terminator; and a font with zero columns is refused rather
  than dividing by zero, because at M3 those fields come from a file.

* **`atlas_fill` and `cpu_record_ns` were dropped from `Stats`.** An atlas's fill belongs to
  that atlas, not to a frame — a renderer with three atlases has no single number — so it
  is `atlasFill(handle)`. And `frameDelta` already measures the frame; a second clock read
  measuring almost the same thing mostly generates arguments about which one is right.

* **The sandbox's font is ours, drawn as ASCII art in a script.** `scripts/gen-sandbox-font.py`
  is committed so the glyphs have a source rather than only a PNG, which is also the
  cheapest way to satisfy the permissive-only policy: there is no third-party asset and so
  no licence entry to make (ADR-0016). `render2d` still ships no glyphs (I5), and the M6
  debug overlay will get its font the same way a game does (I3, I4).

* **The outline is drawn from the *interior* of an 8-pixel white patch.** UVs interpolate to
  a region's edges, and in an atlas the texel past an edge belongs to somebody else's
  sprite. Addressing the middle four pixels means a sample that strays lands on more white.
  This is the atlas lesson the sample exists to carry, and it is why padding defaults to one
  texel as well.

**Earlier still this session (M2, the camera):**

* **The camera got two operations, and the sample got the bindings.** `panByScreen` and
  `zoomAround` are camera *maths* — decided by the projection, and wrong in subtle ways
  under rotation or an off-origin viewport if written at the call site. Which key drives
  them is input policy and belongs to the game. That seam was not a judgement call in the
  end: `render2d` does not depend on `platform`, so the build graph would refuse a
  binding table inside the renderer (I7). The layering picked the boundary.

* **Both movement operations derive from `screenToWorld` rather than re-deriving the
  transform.** `zoomAround` in particular *measures* the drift — ask what world point is
  under the anchor, change the zoom, ask again, move the centre by the difference — instead
  of solving for it. It is then correct under rotation and an offset viewport for free,
  because `screenToWorld` already is, and there is one transform to keep right rather than
  three that agree today.

* **A refused camera move leaves the camera untouched.** Both operations validate the whole
  change before committing it. A half-applied camera from a NaN scroll delta would render
  nothing and look like a renderer bug, and the input can come from a device, a config file
  or eventually a script.

* **Picking is geometry in the engine and a loop in the game.** `sprite.containsPoint` is
  the exact inverse of what `writeQuad` applies, sharing its extents through one
  `localExtents`. There is deliberately no `whatIsAt(point)`: submission is immediate, so
  the renderer retains no sprite list, and giving it one purely to answer that question
  would undo the submission model. The sandbox scans its own sprites and orders hits by
  `(layer, submission index)` — the batcher's own sort key, so "topmost" means the same
  thing to the pick as it does to the GPU.

* **`app.Engine` exposes the frame delta it already measured.** `beginFrame` computed it for
  the stepper and discarded it, so a caller wanting it read the clock again and got a
  different answer. Documented as presentation-only: integrating simulation against
  wall-clock time is what the fixed step exists to prevent (I9).

* **The sandbox builds a one-pixel white texture in memory.** It draws the selection
  outline, and being a *second* texture it makes the batcher break a batch on a texture
  change — 4,000 sprites in 2 batches, 4,004 in 3 when something is selected. That path had
  never run: a one-texture sample cannot exercise it, and the unit tests that cover it are
  not the real command stream. *Superseded the same day:* the patch is 8x8 and lives in the
  atlas with everything else, so the sample no longer changes texture at all — which is the
  atlas working. The texture-change break is still covered, by the renderer's own tests.

**Previous session (M2, building the batcher):**

* **`rhi` gained `waitIdle`, because teardown forced it.** Every consumer destroys its
  resources before the device that owns them — that is creation order reversed — and there
  was no way to reach the state in which that is legal. The validation backend's rule 9
  fired on the most ordinary shutdown imaginable, which is how this was found rather than
  reasoned about. PROJECT_STATE's own debt entry had already named `waitIdle` as one of the
  two candidate fixes, so this is that decision taken rather than a new one. Deliberately
  not an error union: waiting cannot fail in a way a caller could act on.

* **Shader entry points must be called `vertexMain` and `fragmentMain`.** The Metal backend
  has looked them up by those names since M1 and *nothing said so*; `render2d`'s shader
  found it by failing pipeline creation. Now written in `rhi.md` §10, with the alternative —
  naming them per pipeline, which all three APIs support — recorded as an open question
  rather than built. Second undocumented shader-visible contract found this way, after clip
  space; both were load-bearing and invisible.

* **`app.Engine.renderFrame` owns the frame, and takes an `anytype` recorder.** Not a
  `render2d.Renderer`: a frame will later carry a debug UI (M6) and a 3D pass, and whoever
  opens the pass should not care who records into it. The recorder provides `prepare` (before
  the pass, because copies cannot be recorded inside one) and `record`. The game sees
  neither argument, which is what keeps the RHI out of the game-facing surface (§4.2).

* **The RHI gained `premultiplied_alpha` and `additive` blend states.** Its existing
  `alpha_blend` is *straight* alpha, and the comment beside it already warned that confusing
  the two is a bug that looks almost right. `render2d` premultiplies on the CPU, so it needs
  the other one; naming both beats spelling them out per call site.

* **The sandbox embeds its sprite sheet rather than loading it from disk.** Finding an asset
  at runtime needs the content system to answer where assets live and what they are called,
  which is M3's question. Decoding is what M2 owes, and embedding exercises it in the real
  application without prejudging the postponed decision. `asset.loadImage` is unit-tested
  against a real file, so the disk path is covered where it can be covered honestly.
  *`loadImage` is gone as of M3 step 8; the sandbox still embeds, until step 9 gives it a
  `content/core` to load from.*

* **Both memory paths are implemented, and both are exercised.** Metal reports unified
  memory and binds the upload buffer as vertices directly; the validation backend
  deliberately reports memory as *not* unified, so every test run puts the staging-plus-copy
  path through its barrier discipline. The design doc's claim that the branch "is trivial now
  and archaeological later" turned out to understate it: the branch is genuinely tested on
  both sides, which would not have been true if the null backend had claimed unified memory.

* **Vertex buffers are mapped per frame, not persistently.** Rule 3 fires on `mapBuffer`
  when the slot is still in flight, so a persistent mapping would quietly switch off the
  exact check the per-slot ring exists to earn. The cost is a map/unmap pair per buffer per
  frame, which on Metal is a pointer.

**Session before that (M2, designing it):**

* **`render2d` uses immediate submission with retained resources.** The game calls
  `drawSprite` each frame; textures, atlases and fonts are handles that outlive the frame.
  The alternative — a retained list of sprite objects the game mutates — was rejected
  because it becomes a second place game objects live, which `scene` (M4) will already own,
  and because immediate calls are trivially expressible as C ABI entry points at M7 while
  retained object lifetimes across the ABI are exactly the problem I1 exists to avoid. The
  honest cost is that a game drawing 50,000 static sprites re-submits them every frame; if
  that ever bites, the answer is a retained *batch* alongside immediate submission, not
  instead of it.

* **`app` owns the frame; `render2d` records into a pass it is handed.** The renderer does
  not call `beginFrame` or open the render pass, because a frame will later carry a debug UI
  (M6) and eventually a 3D pass, and whoever opens the pass decides what shares it. The game
  never sees an `rhi.RenderPass` in any signature it can reach, which is what §4.2 requires
  and is easy to get wrong by having the renderer own the frame for convenience.

* **World Y points up; screen Y points down.** Not a default — y-down would match screen
  coordinates and tilemap rows, and several 2D engines choose it. Y-up wins because rotation
  signs and trigonometry then behave the way `core.math` already assumes, and because
  `render2d` and a future `render3d` disagreeing about which way is up would be a genuinely
  bad thing to discover late.

* **The batcher's sort key is `(layer, submission_index)` and deliberately not texture.**
  Sorting by texture within a layer would cut batch count and would reorder overlapping
  translucent sprites — wrong in a way that surfaces as flickering in someone else's game
  much later. The atlas is the answer to batch count. Including `submission_index` makes the
  key a *total* order, so determinism (I9) does not depend on the sort algorithm being
  stable, which is a property that survives someone swapping the sort.

* **Colour is linear everywhere above the texture sample.** The surface is
  `bgra8_unorm_srgb` and decoded textures are `rgba8_unorm_srgb`, so the GPU converts in
  both directions and everything between is linear light. One `srgb8()` helper converts the
  numbers a colour picker gives you. This is the most common silent rendering bug there is —
  everything looks fine and every blend and fade is subtly wrong forever.

* **PNG decoding is ours, not a dependency** (ADR-0018). The deciding argument is that
  images are the first thing a stranger's file reaches directly, and image decoders are
  historically the richest source of memory-safety bugs in this kind of software. Verified
  against the pinned toolchain before deciding: `std.compress.flate.Decompress` handles the
  zlib container with its checksum, and `std.hash.Crc32` is PNG's CRC — so this is the PNG
  layer only, not an inflate implementation. A stated subset (8-bit, non-interlaced) with
  everything outside it *refused* rather than approximated.

* **Engine-owned shaders are embedded; content-owned shaders are assets** (ADR-0019). M2
  forced the question PROJECT_STATE had carried as deliberately unsettled since M1, because
  `render2d` needs a sprite shader before `data` or the content pipeline exist. The line is
  functional, not proprietary: an engine-owned shader is one whose absence means the
  renderer cannot draw, making it machinery in the same category as the index buffer. A
  consequence worth knowing: **the sprite shader is not overridable**, because it is the
  other half of a contract with the batcher's vertex layout.

* **`asset` arrives now, minimal, with no ID scheme.** It gets `Image`, the decoder and a
  path-keyed cache, and it depends on `core` and `platform` only — ADR-0007's
  `asset -> core, data, platform` is unchanged as the end state, and `data` joins at M3.
  This keeps file I/O out of `render2d`, where the layering says it does not belong, while
  leaving the postponed asset-ID decision (CLAUDE.md §9) genuinely untouched. Recorded here
  rather than as an ADR because it changes sequencing, not architecture.

* **Bitmap fonts are fixed-grid in M2, and the font is an asset the game supplies.** A fixed
  grid needs no metrics file, which is the entire reason it was chosen: inventing a
  font-metrics format now would resolve part of the authoring-syntax decision that M3 owes.
  `render2d` ships no glyphs (I5) — the sample ships a font with its licence recorded, and
  uses the call a mod would. The M6 debug overlay will get its font the same way, not
  through a private path (I3, I4).

**Previous session (M1, closing it):**

* **`setWindowSize` was added to `platform`, deliberately and not quietly.** It had been
  refused twice as "a contract change, not something to slip in", and that was the right
  call both times — what changed is that it was raised as a decision and taken. The
  justification is not the test it unblocks: **any game with a settings menu needs to set
  its resolution**, so this was a capability the interface was missing. That it also makes
  the swapchain resize path checkable follows from there being exactly one resize path, and
  is a consequence rather than the reason.
* **A resize is a request, not a setter, and the interface says so.** `setWindowSize` does
  not change the window; the new size is observed by draining `window_resized` like any
  other resize. This was vindicated on the first call: asking for 900x900 yields **900x794**,
  because the window manager clamps to the usable display height. A setter would have been
  wrong on the first call on the first machine it ran on. The null backend enforces the
  strict reading — it changes nothing until the queue is drained — for the same reason the
  null `rhi` backend enforces rules Metal forgives.
* **`InvalidWindowSize` and `WindowResizeRefused` are separate errors.** The first is the
  caller at fault — a resolution from a settings file or a mod is untrusted input and is
  validated rather than asserted (`CLAUDE.md` §7). The second is the *environment* declining:
  a tiling compositor will, and so will a full-screen window. Collapsing them, or reusing
  `WindowCreationFailed` for a window that plainly exists, would make the error set say
  something untrue.
* **The sandbox resizes outside the step loop.** Which shape a window is is presentation,
  not simulation, and a step that resized a window would be reaching outside the world it
  is computing. It reads the frame's input snapshot, so it cannot disagree with what the
  steps saw (I9).

**Earlier this session (M1, the quad):**

* **The §9 binding convention survived contact with a real compiler.** It was written down
  before the backend and asserted in a unit test, but a unit test only checks our arithmetic
  against our own document — it cannot check that Metal agrees. The quad does: its uniform
  is group 0 binding 2, which the walk puts at `[[buffer(9)]]`, and the shader declares
  exactly that. Had the convention been wrong the quad would have rendered black rather than
  failing, which is precisely the failure mode §9 exists to prevent, and precisely why this
  needed a real draw and not another assertion.
* **A clean validation run is not evidence of pixels, so the pixels were looked at.** Metal
  API and GPU validation both check that a draw is *legal*; a quad transformed off-screen or
  sampling to zero passes both. The captures in "what currently works" are the other half of
  that, and the table there records which visible property proves which thing — because
  "it looks right" is not a result, and "the checkerboard has hard edges, therefore the
  sampler is `nearest`" is.
* **The shader is compiled by a build step, but where a shader *lives* is left to M3.** The
  sandbox embeds its `.metallib`. Loading one by content ID needs the asset system, and
  deciding where engine shaders live is the package-zero question M3 owes an answer to
  (unresolved question 2). Answering it here to avoid an `@embedFile` would have been
  exactly the opportunistic resolution that is not wanted.
* **Uniform buffers and inline constants are kept visibly separate in the sample.** The
  uniform is written once at startup and never again, because rewriting a buffer a frame in
  flight may still be reading is what rule 3 forbids and the per-frame ring that makes it
  safe is the renderer's job (M2). Everything that changes per frame goes through inline
  constants, which are command stream data and need no ring at all. A sample that blurred
  the two would teach the wrong habit.
* **The staging path is used even though this machine has unified memory.** The quad's
  vertex, index and uniform buffers are `device_local` and filled through an `upload`
  staging arena with batched barriers, rather than being made mappable because they could
  be. Same argument as `device_local` mapping to Metal *private*: an engine tuned only on
  unified memory develops habits that cost a fraction of the frame rate on hardware nobody
  here owns.
* **Sample structs are `comptime`-asserted against the MSL they must match.** `Vertex`,
  `Constants` and `Frame` are declared twice — once in Zig, once in `quad.metal` — and
  nothing checks the two against each other, so every size and offset that must agree is
  asserted. Same discipline as the shim's 86 `_Static_assert`s, same reason: a silent
  mismatch renders something subtly wrong with no error anywhere.

**Earlier this session (M1, the backend):**

* **The Metal binding index convention is written down, and was written *before* the code
  that needed it.** Metal has no descriptor sets, only three flat argument tables per
  stage, so something had to decide which `[[buffer(n)]]` an abstract binding lands on.
  That is shader-visible, therefore a contract — eventually with mod authors, since
  mod-authored shaders compile against it. `rhi.md` §9: eight reserved vertex-buffer slots,
  inline constants at buffer 8, bind group bindings from 9 upward in a documented walk
  order (groups ascending, entries ascending by `binding`, never descriptor order), and one
  index per binding rather than per stage. Deterministic, so identical layouts always
  produce identical indices.
* **`max_vertex_buffers` is the RHI's third guaranteed number, and the only one from
  Metal.** 31 shared buffer argument slots per stage is tighter than Vulkan's 16 vertex
  input bindings or D3D12's 32 input slots. Eight leaves twenty-two for bind group buffers.
  Being a contract limit rather than a backend capacity, exceeding it is a rule 10
  violation instead of an assertion.
* **Metal's enum values are declared in the shim header and `_Static_assert`ed against the
  real `MTL*` constants — all 86.** Zig cannot parse Objective-C headers, so the numbers
  had to be written down; writing them down unchecked would make a wrong one render
  something subtly incorrect with no error anywhere. `MTLColorWriteMask` is why: red is
  `1 << 3` and alpha `1 << 0`, the reverse of the obvious guess.
* **The frame ring waits on command buffers, not on a semaphore.** Each slot keeps the
  command buffer that last used it. Metal orders a queue, so waiting on a frame's last
  command buffer waits for all of it — no atomics, no completion callbacks, no
  synchronisation primitive. Which matters: Zig 0.16 moved those under `std.Io`, and `rhi`
  has no `Io` to hand.
* **The swapchain texture handle is stable across frames**, with only the `MTLTexture`
  behind it changing — the same shape the null backend already had. Code written against
  one therefore behaves identically on the other, which is what makes the null backend a
  useful check rather than merely a second implementation.
* **`device_local` becomes Metal *private* storage even on unified memory.** Shared would
  skip a copy on every machine we own. Private is chosen anyway, per `rhi.md` §5: it makes
  `mapBuffer` genuinely impossible rather than merely forbidden, and an engine tuned only
  on unified memory develops habits that cost a fraction of the frame rate on a discrete
  GPU we cannot test on.
* **`EngineOf` is generic over both ports, not just the platform.** `EngineOf(P, G)`, so
  `app`'s loop tests keep running against the null device instead of quietly requiring a
  GPU whenever Metal is selected. This was recorded as debt coming due when Metal landed,
  and it did.
* **`err` is for the engine failing; `warn` is for the caller's input being wrong.** An
  unusable surface kind, a shader that will not compile, a pipeline Metal rejects — all
  reported at `warn` alongside the error value. This is `CLAUDE.md` §7's
  assert-versus-validate distinction applied to diagnostics: a shader failing to compile is
  the *expected* case of the hot-reload path, not a malfunction. Found because Zig's test
  runner fails a test that logs at `err`, which turned out to be pointing at a real
  conflation rather than being an inconvenience.

**Previous session:**

* **`platform` splits into `Platform` and `Os`.** `Platform` is what a windowing backend
  changes — window, surface, events, input, monotonic clock — and is conformance-checked.
  `Os` is what it does not — filesystem, base directories, dynamic libraries, wall clock —
  and sits beside the seam rather than behind it. A hand-written Cocoa backend and a
  hand-written Win32 backend would share `os.zig` byte for byte.
* **`std.Io` stops at L1.** Zig 0.16 finished its I/O migration: `std.fs` is a deprecation
  shim over `std.Io.Dir`, every filesystem call takes an explicit `Io`, and
  `std.time.Instant` is gone. `Os` owns one `std.Io.Threaded` and never lets it out, so no
  `std` type appears in any Foundry interface. ADR-0001's containment argument, applied to
  the module whose job is owning OS specifics.
* **The environment is an input, never read from the air.** Zig 0.16 removed ambient
  environment access entirely (`std.posix.getenv`, `std.os.environ`,
  `std.process.getEnvVarOwned` are all gone) and hands the environment to the process entry
  point. `Os.init` takes the variables it may see. This is the better design regardless:
  configuration read from the air is exactly the hidden input I9 objects to, and it makes
  the environment-dependent paths testable without touching the real machine.
* **Foundry declares the Windows dynamic loader itself.** `std.DynLib` is a compile error on
  Windows in Zig 0.16, and `std.os.windows.kernel32` has been stripped to one binding.
  Windows is a supported target (ADR-0008) and native mods are fundamental (`CLAUDE.md` §5),
  so `library.zig` declares `LoadLibraryW`, `GetProcAddress` and `FreeLibrary` directly.
* **`core.HandlePool` now takes a tag type and a value type.** `HandlePool(Window,
  WindowState)` — a subsystem exposes a public handle over private state, and deriving the
  handle type from the stored type would either leak the private type into the public
  interface or force a cast at every boundary. Found by the first real consumer, which is
  when you want to find it. `HandlePool(T, T)` covers the simple case.
* **Path validation is in force before there are any mods.** `isSafeRelativePath` rejects
  absolute paths, drive letters, backslashes, `..` components and embedded NULs. Retrofitting
  this after untrusted paths are already flowing means auditing every call site instead of one.
* **`readFile` requires a size bound.** Every caller knows roughly how big the thing it is
  reading should be, and a content package naming a hundred-gigabyte file should fail rather
  than exhaust memory. Untrusted input is bounded at the boundary, not after it.
* **The frame's event boundary is three calls** — `pumpEvents`, `nextEvent`, `captureInput` —
  rather than one polling call that pumps on first use. It makes "the OS queue is drained at
  one known point" structural rather than conventional, and gives the snapshot an
  unambiguous place to be taken.

* **The RHI's two hard numbers come from Vulkan's guaranteed minimums, not from Metal.**
  Four bind groups (`maxBoundDescriptorSets >= 4`) and 128 bytes of inline constants
  (Vulkan's push-constant minimum, which D3D12's 64-DWORD root signature can also honour).
  Designing to what Metal permits would produce an engine that works on every machine here
  and fails on hardware nobody here owns.
* **Inline constants are push-constant-style and the semantics are written down in full**
  (`rhi.md` §9): part of the command stream rather than a resource, bytes copied at the
  call, scope is one render pass, writes replace the whole block, and binding a pipeline
  with a different layout invalidates them — which is Vulkan's real behaviour. Stated
  exhaustively because a small untyped byte block otherwise accretes into an accidental
  general-purpose parameter system.
* **The validation backend's remit is exactly the ten documented rules.** It is not a style
  checker: a call the design document permits must not be rejected, which is why 18 of its
  tests assert *zero* violations. Three checks were removed during implementation for
  overstepping this — zero-size descriptors (now just `error.InvalidDescriptor`) and
  usage-flag conformance (now an open question).
* **Recording follows Metal's encoder model, the one place Metal is the strictest.** No
  draw outside a pass and no nesting. Vulkan and D3D12 permit sloppier structures, so
  taking Metal's shape costs them nothing and yields a structure valid everywhere.
* **`app` is a library, not a framework.** `Engine` is initialised and driven; it does not
  call you back. Tools are Foundry applications (ADR-0011) and an editor's loop is not a
  game's loop, so a framework would grow a knob per application shape. It also inverts
  control, which is the same objection `platform` raised against event callbacks. And it is
  the reversible direction: a `run` helper over a library is a dozen lines, while extracting
  a library from a framework rewrites every game's entry point.
* **`Engine` is generic over its platform backend.** `EngineOf(P)`, with `Engine =
  EngineOf(platform.Platform)`. So that `app`'s own tests always run against the null
  backend's synthetic clock whatever the build selected — the frame loop is precisely what
  must be tested deterministically, and a test against SDL would measure the machine. It
  also keeps `app` honest: nothing in it can depend on a particular backend.
* **The default platform backend is now `sdl3`.** A milestone's runnable result must not be
  behind a flag. Nothing is lost: every test is headless either way, and
  `scripts/check-targets.sh` runs the null backend explicitly so that path cannot rot.
* **Input is captured once per frame, before any step runs.** Two steps in one frame see
  identical input rather than whatever the OS delivered between them — the requirement
  `platform`'s snapshot design exists to serve (I9).
* **A quit request is handled by the engine but still passed to the caller.** Handled, so
  that a game which never drains events still exits when asked; passed on, so a game can
  ask "save first?" rather than exiting immediately. Input events are never intercepted:
  what looks like an obviously engine-level key today is a game's binding tomorrow.
* **SDL's several resize events collapse into Foundry's one.** SDL reports logical resize,
  pixel-size change and display-scale change separately, and one drag between monitors can
  produce all three. Every consumer reacts identically, so they become a single
  `window_resized` carrying both sizes — emitted only when something actually changed,
  which also avoids redundant swapchain rebuilds.
* **The SDL3 backend needed no interface changes.** The interface was designed by asking
  "would this be right for hand-written Cocoa and Win32?", and SDL fitted inside it rather
  than the other way round. That is the outcome ADR-0002's named risk was worried about.

**Earlier sessions:** pinned Zig 0.16.0 (ADR-0001 resolution); SDL3 via `castholm/SDL`
(ADR-0002 resolution); HIDAPI licence elected BSD-3-Clause; the build graph as a data table;
handles are `extern struct` with an all-zero null; FNV-1a 64 and PCG32 specified in the
design docs rather than delegated to `std`; simulation time is an integer tick count;
input is captured into a per-frame immutable snapshot; the engine gets its own public
repository (ADR-0017). Before that, sixteen ADRs establishing the architecture.

---

## Major unresolved questions

1. ~~**RHI granularity.**~~ **Settled** in `docs/design/rhi.md` §6 and §9. Binding is four
   frequency-ordered bind groups plus 128 bytes of inline constants, both numbers taken from
   Vulkan's *guaranteed minimums* rather than from what Metal permits. State transitions are
   declared at pass boundaries and via explicit barriers between passes, never per draw —
   per-draw is the shape that makes Vulkan slow. The Metal backend will discard them; the
   validation backend checks them.
   *Still genuinely open, and recorded in that document's §13:* whether bind groups should be
   transient or persistent, how much the validation backend should model cost rather than
   just correctness, whether `frames_in_flight` should adapt, and what happens on device
   loss.
2. ~~**What "package zero" means for the engine itself.**~~ **Settled 2026-09-05 by M3
   step 9**, after being narrowed by ADR-0019 (engine-owned shaders are machinery, not
   content) and sharpened by ADR-0021 (the question was never *how* engine content is
   identified, only *whether* the engine ships any). The answer is yes: `content/core` is a
   real package holding the debug font, compiled by `fpack` and loaded through the same call
   a mod's package uses. What the question did not anticipate is where the *sample's* sheet
   went — into the sample's own package, not the engine's, because a sample is the reference
   for what a game looks like and a game's content is its own.
   *Still open:* whether an **error texture** belongs in `content/core`. It is the
   development-build placeholder `assets.md` §4 leaves undecided, and the case for it —
   a missing texture should be visibly wrong rather than absent — is not yet strong enough to
   pick what it looks like.
3. ~~**Authoring format syntax.**~~ **Settled 2026-09-04 by ADR-0020**: Foundry's own
   `.fdt`, specified in `docs/design/content-schemas.md` §4. *Still open, and recorded in
   that document's §10:* multi-line strings (deliberately absent until it is known whether
   prose lives in `.fdt` at all, or in string tables keyed by ID), whether `f64` earns its
   place given that I9 makes `f32` the simulation type, whether a mod may extend another
   package's schema, a canonical formatter, and the editor grammar ADR-0020 names as the
   decision's largest real cost.
4. **Zig upgrade cadence.** ADR-0001 says between milestones, never during. Whether that
   means *every* milestone boundary or only when there is a reason is still unresolved. Two
   concrete inputs now: each upgrade must re-verify the SDL3 port, and 0.16 showed that a
   single release can move `std.fs`, the clock and dynamic library loading at once.
5. **When backend #2 is triggered.** Deliberately unscheduled (ADR-0003). The trigger is a
   reason, not a date — but it is worth noticing if that reason never arrives, since the RHI
   stays unvalidated until it does.
6. ~~**Where the tilemap content types live.**~~ **Settled 2026-09-05 by M5 step 5**, by its
   own stated trigger arriving sooner than expected. `tilemaps-and-collision.md` §11 put the
   three schemas and the `foundry:tilegrid` loader in `render2d` and named the trigger as *the
   first real consumer that wants a grid and not a GPU*; that consumer is `fpack`, which has to
   register the record types before it can check a package and cannot link a renderer. So both
   sit in `asset`, which is the same split `assets.md` already made for `foundry:texture` — the
   record is not a GPU concept, and for a grid neither is the loader, since `[]const u16` is
   something `render2d` draws and `physics2d` collides against and *neither* owns.
   *Still open:* whether a separate module is ever wanted. Nothing forecloses one; what is
   settled is that the answer was lower rather than higher. The document's §13 records the
   smaller questions alongside it, including whether trigger enter/exit bookkeeping belongs in
   `physics2d` at all — deliberately still unanswered. The sequence finished at step 7 without
   the sample ever wanting a trigger, so no evidence has arrived either way, and none was
   manufactured to close the question.
7. **How much audio policy the engine owns.** `audio.md` §11 leaves five things open and two
   of them will be asked for early. **Buses or categories** — a music slider and an effects
   slider is the second thing every game wants, and a gain per named category is a few lines
   where a real bus graph is a subsystem; *trigger: the first time the sandbox wants two
   sliders.* **Voice stealing** — M5's `play` returns `error.NoFreeVoice` and lets the game
   decide, which is right until something actually exhausts the pool and wants an
   oldest-or-quietest policy; *trigger: exactly that.* Alongside them: streaming (which arrives
   with music, and with it WAV's size), device-change handling, and whether `foundry:sound`
   grows loop points. `sprite-animation.md` §8 adds one of the same shape — whether the engine
   owns the clip schema and animation component at M7, *triggered by a second consumer or by
   the ABI freeze*, not by convenience.

---

## Notes for the next session

* Read `CLAUDE.md` first, then this file, then `docs/ROADMAP.md`.
* The architecture is settled. Do not relitigate ADRs without a concrete reason; each records
  the conditions that would justify revisiting it.
* Sessions are bounded by available context, not calendar time. Prefer finishing a coherent
  piece and updating this file over leaving several things half-built.

**Zig 0.16 behaviours worth not rediscovering.** All confirmed against the pinned compiler:

* **`std.fs` is a deprecation shim.** The real API is `std.Io.Dir` / `std.Io.File`, and every
  call takes an explicit `Io`. `std.time` has only constants — no `Instant`, no
  `nanoTimestamp`. Get an `Io` from `std.Io.Threaded.init(gpa, .{})` then `.io()`; in tests,
  `std.testing.io` already exists.
* **Ambient environment access is gone.** `pub fn main(init: std.process.Init) !void` is how
  a program receives `gpa`, `io`, `environ_map` and `args`.
* **`std.DynLib` does not support Windows.** Its backing type resolves to a stub whose `open`
  is `@compileError("unsupported platform")`. `platform/library.zig` works around it.
* **A file imported only for its types contributes no tests.** Zig collects tests from files
  reached through a test block, so `os.zig` importing `library.zig` for `Library` did *not*
  pull in its tests — they silently never ran. Every file gets an explicit `_ =` line in its
  module root's test block. This is the same lazy-analysis family as the layering nuance.
* **`failed command:` in a test run does not mean a test failed.** A test step whose binary
  writes to stderr — most of ours do, deliberately, because refusal paths log warnings — has
  the command echoed under a `failed command:` line even when it passed. Read the exit code
  and the `Build Summary` line, never that line. `--summary all` also prints nothing at all
  when every step is cached, so a pass count is only visible after a real rebuild.
* **Lazy analysis makes negative tests lie.** A function body is only analysed when something
  reaches it, and an *undeclared identifier* is caught earlier than a *type error*, so a
  probe using the former proves nothing about branch analysis. Break things with a genuine
  type mismatch, and check the failure lands on the target you expect and not on others.
* **The build test runner reprints a command as "failed" when a test logs at `warn` or
  above**, while the build still exits 0. Six of the nine test binaries do this now — every
  module that tests a failure path deliberately logs one (`core` handle wraparound,
  `platform` read errors, `asset` and `render2d` rejections, `app` refused packages). Noise,
  not failure: `zig build test` exits 0 and the counts are in `--summary all`. The inverse
  is the rule in `assets.md` — `log.err` fails the test, which is why a failure with another
  way to report itself logs at `warn`.
* **`.lazy = true` still extracts a dependency into `zig-pkg/`** on every build; it governs
  how `build.zig` must ask for it (`b.lazyDependency`, returning an optional), not whether it
  is materialised. `zig-pkg/` is build output and is gitignored.
* **`std.Thread.sleep` is gone.** Sleeping is `std.Io`'s now (`io.sleep`), which is the same
  move `std.fs` made. Nothing in the engine needed one — `Os` has its own — but a throwaway
  probe will reach for it and find nothing.
* **`std.testing.FailingAllocator`** takes `.{ .fail_index = n }` and exposes `.allocations`,
  which is how `wav.zig` proves its frame limit is checked *before* the allocation rather
  than merely asserting that it is.
* Modules are created with `b.addModule` / `b.createModule` and wired through `.imports`;
  `addExecutable` and `addTest` take a `.root_module`; `build.zig.zon` requires `.fingerprint`
  and its `.name` is an enum literal. `b.addOptions()` emits its *own* definition of any enum
  passed to `addOption`, which is not the same type as the one the module declares — pass the
  name as a string and convert it back at comptime.

**Reference development environment**, which the verification above was performed against:
Apple Silicon, macOS 26, Xcode 26 with SDK 26.5, Zig 0.16.0. The Metal toolchain is always
invoked via `xcrun`, never a hardcoded path — it lives on a versioned mount that moves between
updates. Homebrew may exist on a developer's machine but nothing in Foundry may assume it.

`scripts/install-zig.sh` places Zig at `~/.local/zig/<version>` and symlinks `~/.local/bin/zig`.
If `~/.local/bin` is not on `PATH`, add it:
`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`
