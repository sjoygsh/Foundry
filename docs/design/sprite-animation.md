# Design: sprite animation

**Status:** Design only. Nothing here is implemented.
**Date:** 2026-09-05
**Implements:** I1, I5, I6, I8, I9 · **Informed by:** ADR-0010, ADR-0013, ADR-0021

Short, and owed anyway, because animation looks like it lands in two modules at once — a clip
is content, its state is a component, the frame it selects is a texture region — and a thing
that spans `scene` and `render2d` is exactly the kind of thing that grows a sideways
dependency if nobody writes down why it does not need one.

The conclusion, stated first because it is the whole document:

> **The crossing dissolves once the state is an integer.** `scene` holds a frame index and a
> tick count and never learns what a texture is; `render2d` turns an index into a region and
> never learns what an entity is. The game joins them, in the same function where it already
> joins a transform and a visual into a sprite.

---

## 1. What is already decided

* **Simulation time is an integer tick count, never a float** (`core-memory-and-handles.md`,
  I9). `core.time.Timestep` makes a tick the unit; `app` runs a fixed timestep; a system is
  *given* the tick it runs at (`entity-storage.md`).
* **An asset reference inside a component is a content ID, not a handle**
  (`entity-storage.md` §8, ADR-0021). A component is serialized; a runtime handle is not.
* **Atlases and regions exist.** `Region.sub` cuts in the region's own pixel space, so a
  caller slicing a sheet does not know whether the sheet is its own texture or a corner of a
  shared atlas (`render2d.md` §8).
* **M5 adds no engine-owned component types** (`tilemaps-and-collision.md` §11). That decision
  covers this document too, and §5 says what it means here.

---

## 2. Three separable things, again

1. **A clip** — an ordered run of frames and how long each is held. Pure data, and content.
2. **Advancing a clip** — given a clip and a number of elapsed ticks, which frame is showing.
   Integer arithmetic, ten lines, and the only part that must not be got wrong.
3. **Turning a frame index into something drawable** — a cell of a grid cut from a region.

(2) and (3) are mechanism and belong to the engine. (1) is content and belongs to whoever
authors it (I5).

---

## 3. The engine's whole contribution

Two functions in `render2d`, and nothing else.

```zig
/// Which frame is showing after `elapsed` ticks, when every frame is held the same length.
///
/// Integer division, no accumulator, no float. `frame_ticks` of zero is a content mistake
/// and yields frame 0 rather than dividing by it — the value came from a file.
pub fn frameAt(elapsed: u32, frame_ticks: u32, frame_count: u32, looping: bool) u32

/// The same, when frames are held for different lengths. `holds` is `frame_count` long and
/// is borrowed for the call only.
pub fn frameAtVarying(elapsed: u32, holds: []const u16, looping: bool) u32
```

```zig
/// Cell `index` of a `columns * rows` grid cut from this region, row-major.
///
/// Built on `Region.sub`, so a sheet packed into a shared atlas slices identically to one
/// that got a texture of its own — which is what makes moving it into an atlas a change to
/// one creation call and to nothing else (`render2d.md` §8).
pub fn Region.cell(self: Region, columns: u32, rows: u32, index: u32) Region
```

That is the entire engine surface. It is small on purpose: everything above it is policy, and
policy invented before a game has asked for it is a name mods are stuck with (CLAUDE.md §7).

**Why `frameAt` is in `render2d` and not `core`.** It is about sprite sheets, which is a
rendering concept; `core` holds mechanisms with no domain. It has no rendering *dependency* —
it is pure integer arithmetic — so the placement is about where a reader looks for it, and a
reader looks next to `Region`.

---

## 4. Integer ticks, and why a float accumulator is not merely inelegant

The obvious implementation is `time += dt; frame = @intFromFloat(time / frame_time)`. It is
wrong here for three separate reasons, and the third is the one that decides it:

1. **It drifts.** Summing `dt` for ten minutes accumulates rounding, so two entities started
   together fall out of step, visibly, on long-lived content like an idle animation.
2. **It does not survive a save.** `entity-storage.md` made a save preserve identity exactly
   so that a reload resumes where it was. A float accumulator reloads to a value that is
   nearly the same and selects a frame that is sometimes not.
3. **It is not answerable.** I9's promise is that the same inputs produce the same result. An
   integer answers "which frame at tick 700?" the same way every time, on every machine, in a
   replay, and after a reload. A float answers it *nearly* the same way, which is the failure
   mode that costs a day to find because the animation is right in nineteen tests out of
   twenty.

So the state is `elapsed_ticks: u32`, advanced by `+= 1` in a system that runs on the fixed
timestep, and the frame is a pure function of it.

**`elapsed_ticks` rather than `started_at_tick`.** Both are integers and both are exact. The
elapsed form is chosen because pausing, rewinding and restarting are ordinary arithmetic on
it, where the start-time form makes each of them a fixup; and because a `u32` of ticks is four
bytes in a save where an absolute tick is eight. The cost is one write per animated entity per
tick, which is precisely the work an ECS query exists to do — the sandbox's `Orbit` system
already does exactly this shape of thing.

---

## 5. What lives in the game, in M5

Following `tilemaps-and-collision.md` §11: **the clip schema and the animation component are
the sample's, not the engine's.** A `foundry:animation` invented now is a name every mod is
stuck with from M7 onward, designed before a game has said what belongs on one — and unlike a
tile grid, nothing in the engine needs to read one.

The sample's shape, which is also the reference for what an engine-owned version would be:

```
@schema clip {
    # Where the frames live. A content id, never a path (ADR-0021).
    sheet id
    # The sheet is a grid; these are its dimensions in cells.
    columns u32
    rows    u32
    # The run of cells this clip plays, row-major from `first`.
    first u32 (default 0)
    count u32
    # Ticks each frame is held. At 60 Hz, 6 is a ten-frames-per-second animation.
    hold u32 (default 6)
    loops bool (default true)
}

clip sandbox:clip.walk_south {
    sheet   sandbox:textures.character
    columns 4
    rows    4
    first   0
    count   4
    hold    8
}
```

```zig
const Animation = struct {
    pub const component = "sandbox:animation";
    /// The clip being played, by content id — never a handle, because this is serialized
    /// (`entity-storage.md` §8).
    clip: core.ContentId = .none,
    elapsed_ticks: u32 = 0,
    /// Written by the animation system, read by the draw code. Cached so that drawing does
    /// not repeat the selection for an entity that did not tick.
    frame: u32 = 0,
};
```

**The component stores an index, not a `Region`.** This is not a preference: a `Region`
contains a `TextureHandle`, a component is serialized, and a runtime handle in a save file is
the exact thing ADR-0021 and `entity-storage.md` §8 already refused for textures. The same
rule, applied to the same kind of field, reached by the same argument.

---

## 6. Where the two modules meet, which is nowhere

The frame's data flow:

```
  content            scene                        render2d
  ───────            ─────                        ────────
  clip record  ──>   Animation.clip (ContentId)
                     Animation.elapsed_ticks
                            │  system, on the fixed tick
                            v
                     Animation.frame (u32)  ───>   frameAt / Region.cell  ──> Sprite.region
                                     the game's draw code joins these
```

`scene` never sees a texture, a region or a renderer, and gains no dependency (its module
comment already records that it takes `core` and `data` only, and that a dependency a module
does not use is a claim the build cannot check). `render2d` never sees an entity. The join
happens in the game's own `spriteFor`, which is where the sandbox already turns a transform
and a visual into a `render2d.Sprite`.

**The engine could not have joined them even if it wanted to**, because `scene` and `render2d`
are both L3 (I7). Discovering that the design wants nothing the layering forbids is the
outcome to hope for from a document like this one.

---

## 7. What this exposes to mods

Tier 1, at M5, as a consequence of the content model: a mod authors a clip record and a
sprite sheet and gets an animation, or overrides an existing clip's `sheet` to reskin one, or
its `hold` to retime one. No code.

Tiers 2 and 3, at M7: `frameAt` and `Region.cell` are pure functions over integers and cross
an ABI as-is. The interesting question is not these — it is whether the *clip schema* becomes
engine-owned, which §8 leaves open.

---

## 8. Open questions

1. **Does the engine own the clip schema and the animation component at M7?** The trigger is
   evidence rather than convenience: a second consumer that wants clips, or the ABI freeze
   forcing the standard vocabulary to be chosen. Until then this document is the record of
   what the engine-owned version would look like.
2. **Playback speed.** A half-speed clip with integer ticks needs either a rational rate or a
   per-entity accumulator, and an accumulator is the float problem wearing a hat. Not invented
   before something asks.
3. **Frame events.** "Play a footstep on frame 3" is the natural thing to want next, and it is
   also where this document touches `audio.md`. It should not be a callback — `physics2d`
   refused callbacks in queries for the same reason (`tilemaps-and-collision.md` §7). The
   likely shape is that the system records which frame it entered this tick and the game reads
   it, keeping the emit-never-observe rule of `audio.md` §8 intact.
4. **Transitions and blending.** Crossfades and state machines are game policy built on this,
   until something proves otherwise.
5. **Non-uniform frame holds in content.** `frameAtVarying` exists for it; the schema above
   does not expose it, because a list field for a case nothing has asked for is a guess. It is
   additive when it arrives (I8).

---

## 9. Deliberately not here

* **Tilemap animation and autotiling** — already excluded by `tilemaps-and-collision.md` §14,
  and animating a tile is a different problem: it is one clip shared by ten thousand cells,
  not ten thousand pieces of state.
* **Skeletal animation, deformation, tweening.** 2D skeletal animation is a subsystem with an
  authoring tool attached, and nothing in M5 needs it.
* **Animation-driven gameplay** — hitboxes on frames, root motion. Content-driven collision
  timing is a real feature and a much later one.
* **An offline sprite-sheet packer.** `render2d.md` §8 already covers why packing is a runtime
  operation.

---

## 10. Implementation order

1. **`frameAt`, `frameAtVarying` and `Region.cell` in `render2d`**, with tests: the first frame
   at tick zero, the last frame held for its full duration, a looping clip wrapping exactly on
   the boundary rather than one tick early or late, a non-looping clip pinning to its last
   frame, and a `frame_ticks` of zero not dividing by it.
2. **The sample's clip schema and animation component**, in its own package and its own source,
   with the system that advances `elapsed_ticks` on the fixed tick.
3. **The sandbox draws an animated sprite**, which is M5's rule for every piece of this
   milestone — and, with the save path `scene` already has, a reload that resumes on the frame
   it was saved on. That last check is what makes §4's argument something the suite holds
   rather than something this document asserts.

---

## Resolution: the engine's contribution (step 1, 2026-09-06)

*What implementing §3 settled. The two functions and the grid cut exist, in
`engine/src/render2d/animation.zig` and `Region.cell` in `atlas.zig`, with 13 tests.*

**The functions are their own file, and that does not contradict §3.** The document said a
reader looks for `frameAt` next to `Region`, and that is satisfied by the **module surface**:
`render2d.frameAt` and `render2d.frameAtVarying` sit beside `render2d.Region` in `root.zig`,
which is what a consumer sees. Putting them *in* `atlas.zig` would have been reading the
sentence as a claim about files — and `atlas.zig` opens by saying it is about packing many
images into one texture, which frame selection is not. `Region.cell` does belong there,
because it is a `sub` in a hat.

**Three things the document did not decide, all reachable from a file.**

* **An out-of-range grid cut is empty, not clamped.** Zero columns, zero rows, an index past
  the last cell, or a region too small to divide all yield an empty region. This follows
  `sub`, which already refuses to read past a region's edge because in an atlas the texels
  next door are somebody else's sprite — but the deciding argument here is diagnostic. A
  clip whose `first + count` runs off its sheet is an ordinary content mistake, and clamping
  to the last cell would show a *stuck* animation, which is indistinguishable from a
  non-looping clip working correctly. An animation that vanishes sends its author to the
  clip.
* **A frame held for zero ticks is never shown**, and it is not special-cased: a zero hold
  advances the running total by nothing, so no tick can land inside it. This extends to
  pinning, which is the second decision.
* **Pinning clamps the tick, not the index.** A non-looping clip computes
  `@min(elapsed, total - 1)` and then runs the same walk a looping one runs on
  `elapsed % total`. One walk covers both, and the last frame it settles on is the last
  frame *actually displayed* rather than a trailing zero-hold entry no playthrough would
  have reached. Clamping the index would have got that wrong and looked right.

**The uniform and varying forms agreeing is a test rather than a remark.** §8's question 5
says a hold list is additive when it arrives (I8), and additive means an existing uniform
clip must not change what it shows on the tick the schema grows. So `frameAtVarying` with
every hold equal is asserted to equal `frameAt`, across two hundred consecutive ticks, in
both looping modes. Two functions that disagreed about the uniform case would be a seam
between "the clip has a hold" and "the clip has a hold list", discovered by a mod author.

**Arithmetic is widened where content can overflow it.** `columns * rows` is computed in
`u64` because a grid that large is a content mistake rather than a crash, and
`frameAtVarying` sums and wraps in `u64` because 65,535 ticks per frame across a long clip
passes a `u32` easily. `frameAt` needs neither: `frame_ticks` is at least one there, so the
quotient cannot exceed `elapsed`.

**§4's argument is not yet held by the suite.** The drift and wrap claims are — a looping
clip is asserted in phase 32,000 ticks out, and at `maxInt(u32) - 7`. The *save* claim is
step 3's, and that is where it stays until an animated entity reloads onto the frame it was
saved on.
