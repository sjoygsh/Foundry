# Design: ui — an immediate-mode kernel that draws nothing

**Status:** **Steps 1-2 implemented 2026-09-06** (`engine/src/ui/`). Written before any UI code
existed, so implementation was transcription rather than invention; see the two Resolution
sections at the end for what each step corrected and settled. Steps 3-6 of §16 remain.
**Date:** 2026-09-06
**Implements:** I1, I4, I5, I6, I8, I9 · **Informed by:** ADR-0004, ADR-0007, ADR-0011,
ADR-0021, ADR-0024

M6 asks for an in-process debug overlay. ADR-0024 already decided *who writes it* — Foundry
does, one kernel with two widget sets — and resolved the module edge: **`ui` sits at L1,
depends on `core` and `platform` only, and emits a renderer-agnostic draw list.** This document
works out the interfaces, and it spends most of its length on the two things that make a UI
unlike every other subsystem in Foundry so far:

> **It is the first subsystem whose state is a memory of what the user was doing a frame ago.**

Everything in a fixed-step simulation is recomputed from state the game owns. A UI is not: a
half-finished drag, which widget the keyboard is in, where a list is scrolled, are all facts
that exist *only* inside the UI and must survive from one frame to the next while the widget
they belong to is described afresh every frame. That is the whole problem immediate mode
solves, and identity is how it solves it.

> **It is also the first subsystem that competes with the game for input.**

A click that lands on a slider must not also move the player. No subsystem before this one has
had to say "I took that."

---

## 1. What is already decided

**ADR-0024** fixed these; this document does not reopen them.

* Foundry writes its own immediate-mode UI. No Dear ImGui, no cimgui.
* **One kernel, two widget sets.** M6 builds the kernel and a debug set. The content-driven,
  skinnable game widget layer is designed for and postponed.
* **No colour, font, metric or string in the kernel is a literal.** Style is a value passed in.
* **`ui -> core, platform`, at L1.** It never sees `rhi` and never sees `render2d`.
* The kernel emits a draw list. Something above walks it into `render2d` calls.
* Its interaction logic is unit-testable with no device, no window and no frame.

## 2. The mechanism, in one page

An immediate-mode UI is three ideas and a loop. Stating them plainly here means the rest of the
document can refer to them without re-deriving them.

**A widget is a function call, not an object.** `ui.button(&ctx, id, "Save")` both describes a
button and returns whether it was clicked. There is no button object, no callback, no
invalidation, and — the reason this suits a debug overlay — no second copy of the state being
displayed that can drift from the first.

**Two ids carry all the interaction state.** `hot` is the widget under the pointer this frame.
`active` is the widget the pointer went down on and has not released. A button is clicked when
the mouse comes up while it is both hot and active. A slider drags because it stays active
while the pointer moves off it. That pair, plus a `focus` id for the keyboard, is the entire
persistent interaction model.

**Layout is a cursor, not a solver.** A region has bounds and a cursor; each widget consumes a
rectangle and advances the cursor. Nothing is measured twice and nothing iterates to a fixed
point.

The loop, once per frame, in the order the phases must run:

```
ui.begin(&ctx, input, viewport)      // adopt input, clear the list, decide `hot` from last
                                     //   frame's rectangles
  ...the caller's widget calls...    // describe, and read back what happened
ui.end(&ctx)                         // resolve capture, finalise the draw list
```

**`hot` is decided from the previous frame's rectangles, not this one's.** This is the one piece
of an immediate-mode UI that surprises people, and **the reason is overlap.** Widgets are
described back to front, so whether a given widget is the topmost one under the pointer is not
known until every widget has been described — which is long after the first of them asked
whether it was clicked. Resolving `hot` at `end` and reading it during the next frame buys two
things at once: a widget's hot state is consistent for the whole frame it draws in, and the
topmost widget wins regardless of description order.

One frame of latency between the pointer arriving and the control accepting a press is the
honest cost. With a physical pointer it is invisible — a person cannot see a button and press it
inside 16ms — and it is what every immediate-mode UI that handles overlap correctly pays. §14
records the case where it is not free.

## 3. Identity, and the mistake Foundry will not make

A widget must be recognisable next frame from nothing but the call that describes it. Three
sources of identity are available, and the conventional choice is wrong for Foundry.

**Not the pointer.** I9 forbids behaviour that depends on pointer values, and a UI keyed on
addresses changes behaviour when an allocator hands back a different block. This is not a
theoretical objection: it would make a saved layout unreproducible.

**Not the displayed text.** This is what Dear ImGui does, with `##` to hide the disambiguating
part, and it is a genuinely good trade *for a debug tool that is never translated*. Foundry's
game UI is content: laid out in `.fdt`, skinned from assets, and **translated**. If identity is
derived from the string on screen, then switching language changes every widget's id at once —
scroll positions reset, a half-typed field loses focus, an open tree collapses. The bug is
subtle, it appears only in the language a developer does not test in, and it is unfixable later
without changing every call site.

So: **identity and display text are separate parameters, always.**

```zig
pub const Id = enum(u64) {
    none = 0,
    _,

    /// Combine a name into a parent seed. FNV-1a's mixing step, seeded by the parent
    /// rather than by the offset basis, so nesting is one pass and order matters.
    pub fn child(parent: Id, name: []const u8) Id { ... }
    pub fn childIndex(parent: Id, i: usize) Id { ... }
};

pub fn button(ctx: *Context, id: Id, label: []const u8) bool
```

The debug widget set may offer `ui.debug.button(ctx, "Save")` deriving the id from the label,
because a debug panel is never translated and the verbosity is not worth paying there. **The
kernel does not offer it**, so the game layer cannot acquire the habit.

**A UI id is not a `ContentId` and must never be one.** They are both 64-bit FNV values and the
resemblance is a trap. A `ContentId` is stable across builds, reaches compiled packages and save
files, and its algorithm is frozen for that reason (`core/id.zig` says so). A UI id is
**runtime-only, never serialized, never persisted, and free to change whenever a layout changes**
— which is exactly why it uses a seeded variant local to `ui` rather than calling
`core.id.fnv1a64`. Sharing the function would invite sharing the guarantees.

**An id stack handles the two cases the flat call cannot.** `pushId`/`popId` seed the ids
generated inside them, so a panel drawn twice with different seeds has distinct children, and a
loop over two hundred entities uses `childIndex(i)` without inventing two hundred names.

**Collisions are reported, not asserted.** Two widgets with the same id in one frame is a caller
bug, and the caller may be a mod (I4: untrusted input is validated, not asserted). The kernel
names the id in a log line, counts the collisions, and lets the second widget be **inert but
still drawn** — rather than silently giving one widget's clicks to another. Drawn, because an
inert control is easier to find than a missing one.

## 4. Input, and who took it

The kernel is *given* input; it never reads a device. `ui -> platform`, so it takes platform's
own types rather than restating them:

```zig
pub const Input = struct {
    /// Captured once in `app.beginFrame`, so two steps in a frame see the same UI input
    /// as they see the same game input.
    keys: *const platform.InputSnapshot,
    pointer: core.math.Vec2,        // screen points, +Y down — the same space as `ViewId.screen`
    wheel: core.math.Vec2,
    /// Characters typed this frame, in order. Already valid UTF-8 and already bounded by
    /// `platform.event.max_text_bytes`; the kernel re-validates anyway.
    text: []const platform.event.TextInput,
};
```

**Capture is the part that matters, and it is why this is a subsystem rather than a helper.**
After `ui.end`, the caller asks:

```zig
pub fn wantsPointer(ctx: *const Context) bool   // a widget is hot or active
pub fn wantsKeyboard(ctx: *const Context) bool  // a widget has focus and consumes typing
```

A game that does not check these will move its player while the user drags a slider. The
overlay is the first consumer and will check them; **`samples/room` is where this gets proven**,
because a game that walks with WASD and opens a panel over the hall is the smallest case where
getting it wrong is visible.

Capture is deliberately **advisory, not enforced.** The kernel cannot filter the game's input
without sitting between the game and `platform`, which would invert the layering and make the
UI a mandatory part of every frame. This matches `app-and-frame-loop.md`'s existing rule that
the engine does not intercept input events, and for the same reason: what is obviously the
overlay's key today is a game's binding tomorrow.

## 5. Layout

A stack of regions. Each region is a rectangle, a cursor, a direction and a spacing.

```zig
pub const Region = struct {
    bounds: Rect,
    cursor: Vec2,
    axis: enum { vertical, horizontal },
    spacing: f32,
    /// Widest/tallest thing placed, so a panel can size itself to its contents.
    extent: Vec2,
};

pub fn beginPanel(ctx: *Context, id: Id, bounds: Rect) void
pub fn endPanel(ctx: *Context) void
pub fn row(ctx: *Context, id: Id, height: f32) void   // horizontal region, one line tall
pub fn endRow(ctx: *Context) void
```

A widget asks the region for a rectangle of the height it wants and the region's full width,
the region advances, and that is all. **No constraint solver, no flex, no fractional weights**
— a debug panel is a stack of full-width rows with the occasional side-by-side pair, and
anything more is the game widget layer's problem, where a designer's intent actually needs
expressing.

**Sizes come from the style, not from constants**, so a row's height is `style.line_height` and
a panel's padding is `style.padding` (§7). A widget that hardcodes `20` has broken the one rule
ADR-0024 asked the kernel to keep.

## 6. The draw list

The kernel's output. A flat, ordered array of commands, in submission order, which is also
paint order — back to front, no sorting. Immediate mode makes this free: the caller already
described the panel before the button on it.

```zig
pub const Command = union(enum) {
    rect: struct { bounds: Rect, color: Color },
    text: struct { at: Vec2, text: TextRef, color: Color, scale: f32 },
    /// Intersected with whatever is already on the clip stack, so a scrolling list inside
    /// a panel clips to both without the caller computing the intersection.
    clip_push: Rect,
    clip_pop,
};
```

**Strings are copied, not borrowed.** `TextRef` is an offset and a length into a per-frame arena
the `Context` owns and resets in `begin`. This costs a memcpy per label and removes an entire
class of bug: the natural way to draw a number is to format it into a stack buffer, and a
borrowed slice into that buffer is dangling by the time the walker runs. A UI whose most obvious
call site is a use-after-free is a UI that will produce one.

`Color` is `ui`'s own four-float struct, not `render2d.Color`, because `ui` cannot see
`render2d`. They are the same four numbers; the walker converts. This is the seam's smallest and
most irritating cost, and it is stated here so nobody spends an afternoon looking for a way to
share the type that does not break the layering.

**The list is public and read-only after `end`.** A tool that wants to dump a layout, a test
that wants to assert a rectangle is where it should be, and the walker all read the same array.
That is what makes §11's tests possible.

## 7. Style is a value

```zig
pub const Style = struct {
    font: FontMetrics,
    line_height: f32,
    padding: Vec2,
    spacing: f32,
    text: Color,
    text_dim: Color,
    surface: Color,
    control: Color,
    control_hot: Color,
    control_active: Color,
    accent: Color,
};
```

Held on the `Context`, replaceable between frames, and **the kernel reads it and never writes
it.** The debug widget set ships a `Style` value — that is where the dark grey and the blue
live, in a widget set, not in the kernel. The game layer will build one from content, and
because the kernel already only reads, that is a new producer rather than a rewrite.

**`FontMetrics` is the piece ADR-0024 turned on**, so it is worth showing:

```zig
pub const FontMetrics = struct {
    cell: Vec2,            // one glyph cell, in pixels, before scale
    letter_spacing: f32 = 0,
    line_spacing: f32 = 0,

    pub fn measure(self: FontMetrics, text: []const u8, scale: f32) Vec2 { ... }
};
```

Four numbers. `render2d.BitmapFont` has six fields and exactly one of them — `glyphs: Region` —
is a renderer thing; the rest is this arithmetic plus the glyph lookup that only drawing needs.
The kernel measures; the walker draws.

## 8. The walker, and the one hazard the seam creates

The walker turns a `ui.DrawList` into `render2d` calls. **It lives in `app`**, which is the only
layer that can see both, exactly as §4.3 describes. Roughly:

```zig
// app/ui_draw.zig
pub fn draw(list: *const ui.DrawList, r: *render2d.Renderer, font: render2d.BitmapFont,
            blank: render2d.Region, view: render2d.ViewId) !void
```

It is small — a switch over four cases, a clip stack, and a colour conversion — and it is the
price of the seam. The design's job is to name what can go wrong with it.

**The hazard is measurement drift.** The kernel lays out with `FontMetrics.measure`; the
renderer draws with `render2d.measureText` and `text.Layout`. If those two ever disagree about
the width of a string, the UI clips text it thought would fit, or leaves a gap, and the symptom
appears far from the cause. Nothing in the type system prevents it, because the whole point of
the seam is that the two do not share code.

**The mitigation is a test, and it is not optional.** One integration test in `engine/tests/`
builds a `ui.FontMetrics` from a `render2d.BitmapFont` through the single conversion function
that is allowed to do it, then asserts both measure identically across a fixed corpus: empty,
ASCII, multi-byte UTF-8, a codepoint the font lacks, an invalid byte, multiple lines, and every
combination of scale and spacing the style permits. **The conversion function is the only
sanctioned way to build a `FontMetrics` from a font**, so the test covers every path that
matters.

This is the same shape as the null RHI backend and the stepped null audio device: the part of a
subsystem nobody can see is the part that rots, so it gets a test that makes it visible.

## 9. What `render2d` gains

Two additions, both named in ADR-0024, both needed by any UI regardless of who wrote it.

**Clipping.** The RHI already has `setScissor` and `command.ScissorRect`, and both backends
implement it, so this is exposure and batching, not invention:

```zig
pub fn setClip(self: *Renderer, rect: ?Rect) void
```

Screen-space pixels, `null` to disable. A change of clip is a **batch break**, alongside the
existing texture and blend breaks, and it is recorded into the pass with `setScissor` before the
draw call it guards. `Stats` gains nothing; a clip change shows up as one more batch, which is
the number a person tuning this would already be reading.

**A blank region.** A renderer-owned white texture, created in `Renderer.init`, exposed as:

```zig
pub fn blankRegion(self: *const Renderer) Region
```

This is the thing both samples wrote by hand. `samples/sandbox` and `samples/room` each allocate
an 8×8 white `asset.Image`, upload it, and inset by `sub(2, 2, 4, 4)` to stay off the filtered
edge — independently, identically. **Both delete that code when this lands**, and that deletion
is the evidence the addition was right, in the same way the engine gaining nothing for
`samples/room` was M5's.

It is engine-owned, not content: the same category as ADR-0019's built-in shaders. A game may
still draw a filled rectangle from its own sheet and nothing stops it; this is so that no game
*has* to.

## 10. The debug widget set

Built on the kernel, shipped beside it, and the thing M6's bullets actually use:

| Widget | Needed by |
| --- | --- |
| `label`, `labelFmt` | everything |
| `button` | content reload trigger, log clear |
| `checkbox` | toggling overlay panels, subsystem flags |
| `slider` (f32, int) | tuning a value while watching its effect |
| `collapsingHeader` | entity inspector, content browser |
| `scrollRegion` | log console, content browser |
| `textField` (single-line) | filtering a log or a content list |
| `plot` (one line, ring buffer) | frame profiler |
| `separator`, `spacer` | legibility |

That is the whole list, and it is short on purpose. An entity inspector, a content browser, a
log console and a per-allocator memory report are these widgets arranged differently, not new
widgets.

**The overlay itself is not designed here.** M6's real deliverable is its fourth bullet —
introspection APIs designed with the future ABI in mind — and what an entity inspector may ask
`scene` for, what a content browser may ask `data` for, and how per-subsystem timing is
collected are a different subject with different invariants. They get their own design document
once this one is implemented and the shape of a panel is known rather than imagined.

**The overlay's font comes from `content/core`.** `foundry:fonts.debug` has been there since M3
for exactly this, acquired as an ordinary `foundry:texture` by content ID — the call
`samples/sandbox` already makes and the call a mod would make (I3, I4). A mod overriding that ID
re-skins the overlay's glyphs without being told the directory exists (ADR-0021).

## 11. Testing, and what the seam bought

The kernel is testable with **nothing linked**: no device, no window, no renderer, no frame.
That was the argument for L1, and it is only worth the walker's cost if the tests are actually
written. They are:

* **Interaction.** Press inside a button, release inside → clicked once. Press inside, release
  outside → not clicked, and not clicked on the following frame either. Press, drag off, drag
  back, release → clicked. A slider stays active while the pointer leaves its rectangle.
* **Identity.** The same widget across a hundred synthetic frames keeps its state while its
  *label* changes every frame — the localisation case from §3, asserted rather than hoped for.
  Two widgets given the same id are reported and the second is inert.
* **Capture.** `wantsPointer` is false over empty space and true over a control, on the frame it
  matters and not one frame late.
* **Layout.** Rectangles land where the arithmetic says, at several styles and scales.
* **Clipping.** A widget entirely outside its clip still occupies layout space and still emits
  its commands; clipping is a draw concern, not a layout one. (Culling is §14.)
* **The draw list.** A known widget sequence produces a known command sequence — the closest
  thing to a golden-image test that runs headlessly.

**Determinism (I9).** The kernel is not simulation and never runs inside the fixed step. It is
called once per frame from the render phase, reads state, and returns what the user did. Nothing
in it may read a clock — a blinking caret is driven by a frame counter the caller passes in, not
by wall time, so a test that runs a hundred frames sees the caret blink the same way every run.

**The overlay changing a simulation value is a real input to the simulation**, not an
observation, and it must travel the path a game input would. Dragging a debug slider on gravity
makes that run different from a run without it, which is correct and expected; what would be
wrong is a debug control writing simulation state from the render phase, behind the fixed step's
back. That is stated here because it is exactly the shortcut a future session will want.

## 12. Errors

Allocation is the only failing operation: the arena for text, the command array, and the
per-widget state map all grow. So the widget calls return `Allocator.Error!`-shaped errors where
they must and plain values where they cannot fail, rather than every call returning an error
union for symmetry's sake.

**Nothing in the kernel asserts on caller input.** Ids, labels, rectangles and style values all
come from a caller that will be a mod at M7. An empty rectangle draws nothing; a NaN in a
rectangle is rejected at the region boundary; a label that is not valid UTF-8 measures and draws
its substitution glyph exactly as `render2d.md` §10 already requires. `core.assert` is for
kernel-internal invariants only.

## 13. What this exposes to mods

`CLAUDE.md` §5 requires deciding this now even if the answer were "nothing". It is not nothing —
a UI is one of the first things a mod author wants.

**Exposed at M7:** begin/end a frame, push/pop an id, begin/end a panel and a row, every widget
in §10, get and set the style, and query capture. Every one of those is a function taking a
plain struct and returning a plain value, which is what ADR-0024 and `render2d.md` §2 both mean
by immediate mode surviving the ABI: no object lifetime crosses the boundary, so I1's problem
class never arises.

**Not exposed:** the draw list's memory, the arena, the widget state map, the walker, and any
`render2d` handle. A mod describes a UI; it does not get to draw arbitrary geometry through the
UI's pipe, because that is the material system's job and ADR-0015 already says why it is not
ready.

**The one deliberate asymmetry**, recorded so it is a decision and not an oversight: a mod
cannot yet supply a `Style` from content, because the content-driven style layer does not exist.
At M7 a mod gets the same built-in style the overlay uses. When the game widget layer lands, a
style becomes a content record and the ABI gains a call to resolve one — additive, `_v2`, no
break.

## 14. Open questions

* **Input that arrives already inside a control.** The one frame `hot` costs is invisible to a
  physical pointer, which is over a button for many frames before a person presses it. It is not
  free for a touch that lands on a control, or for a synthesised or scripted click, both of
  which can be inside and pressed on their very first frame — and the press is dropped. The fix
  is a same-frame path for a press whose position had no previous frame to be hot in, and it
  needs a case that actually exists before it is written.
* **Culling.** A scrolling list of ten thousand log lines emits ten thousand text commands, of
  which forty are visible. The kernel knows the clip rectangle and could skip them. It is not
  done at M6 because the honest answer needs the profiler M6 is building, and guessing at it now
  would be optimising before measuring (rule 2).
* **Keyboard navigation and tab order.** Deliberately absent from M6. It needs a notion of
  focus order that the flat id model does not have, and a debug overlay driven by a mouse does
  not need it. It is the first thing a game UI will.
* **Whether the game widget layer needs commands this vocabulary does not have.** Almost
  certainly: a nine-slice for a skinned panel, an image by content ID, and a rotated or clipped
  glyph run for a stylised HUD. `Command` is a tagged union and adding a case is additive, but
  the *walker* then needs the corresponding `render2d` capability. Recorded so the vocabulary is
  not assumed final.
* **Multi-line text editing with selection.** Out at M6 (§15). When a game needs a dialogue
  editor or a chat box, it is a substantial subsystem, not a widget.
* **Whether a game UI defined in content addresses widgets by `ContentId`.** §3 forbids a UI id
  from *being* a content id; it does not settle whether a content-authored widget's id is
  *derived* from one. That is the game widget layer's question and it should be answered there,
  with the authoring format in front of it.

## 15. Deliberately not here

Docking and floating windows. Tables with sortable, resizable columns. A colour picker. Plots
beyond a single line. Multi-line text editing. Keyboard navigation. Animation and transitions.
Nine-slice and skinning. Localisation and bidirectional text. Accessibility. Drag-and-drop
between widgets. Undo.

Each is real and several are load-bearing for the editor (§9, post-M6) or for the game widget
layer. None of them is M6, and none of them is blocked by anything above.

## 16. Implementation order

Each step ends with something that runs and something that is tested.

1. **The kernel's spine.** `Id`, `Context`, `begin`/`end`, `Input`, hot/active/focus, the draw
   list and its arena, `Style`, `FontMetrics`. One widget — `button` — to prove the loop. Tests
   from §11's first two groups. **No renderer, no `app` change, nothing on screen.**
2. **Layout and the rest of the interaction model.** Regions, panels, rows, capture,
   `clip_push`/`clip_pop`. `label`, `separator`, `spacer`, `checkbox`. Layout and clipping tests.
3. **`render2d` gains `setClip` and `blankRegion`**, with batch-break tests against the null
   backend. `samples/sandbox` and `samples/room` delete their hand-rolled white textures. This
   step is visible only as a diff that gets smaller.
4. **The walker in `app`**, plus the `BitmapFont` → `FontMetrics` conversion and the drift test
   from §8. `samples/sandbox` draws one real panel — its existing frame statistics, moved out of
   `drawText` calls and into widgets. **First pixels from the UI.**
5. **The rest of the debug widget set.** `slider`, `collapsingHeader`, `scrollRegion`,
   `textField`, `plot`.
6. **`samples/room` checks capture**, because a game that walks with WASD and opens a panel over
   the hall is where getting it wrong is visible, and the room is the sample that plays.

M6's remaining bullets — the inspector, the browser, the console, the profiler and the
introspection APIs under them — follow in their own design document, on top of this one.

---

## Resolution: the kernel's spine (step 1, 2026-09-06)

`engine/src/ui/` — `id.zig`, `style.zig`, `draw.zig`, `input.zig`, `context.zig`, `widget.zig`,
`root.zig`. **36 tests, all of them headless**: 832 under `-Drhi=null` and 840 under
`-Drhi=metal`, up from 796 and 804. No renderer, no device, no window, no `app` change, and
nothing on screen — which was the point of the step, because a step 1 that had needed a device
would have meant the layering was wrong.

**Two things this document said were wrong, and are corrected above rather than left standing.**

**§2's justification for deferring `hot` was muddled.** It claimed a widget's rectangle is not
known until after the caller has asked whether it was clicked. That is false for the widget's
*own* rectangle: a widget computes its bounds inside its own call, before it returns anything.
The real reason is **overlap** — whether *this* widget is the topmost one under the pointer
depends on every widget described after it, which is not known until `end`. The mechanism was
right and the sentence explaining it was not, which is the more dangerous of the two failures: a
future session simplifying away a mechanism whose stated reason is visibly wrong would have been
doing the obvious thing.

**§3 said collisions are logged "with both call sites' ids".** There is one id, by definition —
that is what makes it a collision. The kernel names the id, counts them, and reports the count
at `end`.

**The bug the tests caught is worth recording, because it is the shape of bug this whole design
is arranged to make findable.** The safety net that ends a drag when the pointer is released
outside the window was written in `begin`, where it cleared `active` *before* any widget ran —
so the release every button was waiting for had already been consumed, and no button in the
system could ever report a click. Six tests failed at once and said so in one run. It belongs in
`end`, after the widgets have had their chance, and it is now commented there with the reason.
A UI that could only be tested by clicking it would have shipped this.

**What implementation settled:**

* **`Input.keys` is by value, not `*const`.** `platform.InputSnapshot` documents itself as
  containing no pointers and no allocation precisely so it can be copied, and a by-value field
  removes a lifetime question from a struct a caller synthesises in tests constantly. `Input.at`
  is that synthesiser, and it lives beside the type rather than in each test file.
* **`ui.Color` deliberately has no `srgb8`.** Duplicating the sRGB transfer function would be a
  second thing that can silently disagree with the renderer, and the kernel has no need for one:
  whoever builds a `Style` is above the seam and can convert there. `withAlpha` is the one
  operation a widget genuinely needs, because dimming a disabled control at each call site is
  how a style stops being one value.
* **The text arena is an `ArrayList(u8)` cleared each frame, not a `core.mem.Arena`.** It gives
  the same per-frame lifetime with offsets that survive the storage reallocating mid-frame,
  which a pointer into an arena would not. `TextRef` is therefore an offset and a length, and a
  test appends 256 strings after taking a reference to prove the reference still resolves.
* **The one-frame latency is pinned by a test**, not only by a comment: a button hovered for the
  first time still draws cold, and the frame after draws hot. A future session moving where
  `hot` resolves finds out from the suite rather than from a user.
* **A truncated UTF-8 sequence substitutes per byte**, so `"\xe4\xb8"` measures two glyphs and
  not one. This is not a choice — it is what `render2d.text.Layout.decode` already does, for the
  stated reason that a stray lead byte must not swallow what follows it. The measurement code
  here mirrors that decode exactly, including `\r` being skipped without advancing a column and
  a trailing `\n` counting as a line. §8's drift test at step 4 is what will keep it mirrored.
* **Duplicate detection is always on**, costing one hash insert per widget. Gating it behind
  `runtime_safety` was considered and refused: that would be optimising before the profiler this
  milestone is building exists to measure it (rule 2). The comment in `context.zig` says what
  the fix is if it ever shows up there.
* **`button` takes explicit bounds**, because layout is step 2 and a cursor invented in
  `widget.zig` would have put layout in the wrong file.
* **`ui` reaches the integration test module** in `build.zig` already, so §8's drift test has
  somewhere to live at step 4 without another build change.

---

## Resolution: layout, clipping and capture (step 2, 2026-09-06)

`engine/src/ui/layout.zig` joins the seven files from step 1, and `context.zig`, `draw.zig`,
`style.zig` and `widget.zig` grow into it. **24 more tests, still all headless**: 856 under
`-Drhi=null` and 864 under `-Drhi=metal`. No renderer, no device, no window and no `app` change
— the same claim step 1 made, and it is worth repeating because layout and clipping are where a
UI usually starts needing one.

**Capture is the part this step changed, and the change is not what §4 describes.** §4 defines
capture as "a widget is hot or active". That is right for a control and wrong for the thing
around it: **a panel is not a widget**, so clicking its empty half would have found nothing hot,
reported that the UI did not want the pointer, and walked the player through the wall behind the
panel. `beginPanel` therefore calls `Context.blockPointer`, which takes the pointer for the
frame without entering the hot/active model at all.

Making the panel a widget instead was the obvious alternative and it is wrong. A container that
competed for `hot` would take the press meant for a control the pointer had just moved onto,
because `hot` is a frame old and the container is described first. Blocking without competing is
the only version that does not create a new bug while fixing one. `samples/room` at step 6 is
where this stops being an argument.

**What §11 asked for in capture was already true.** It requires capture to be right "on the frame
it matters and not one frame late", and `hot` is resolved in `end`, which runs before any caller
asks — so a pointer arriving over a control is captured on the frame it arrives, even though the
control will not accept a press until the next one. Erring that way round is deliberate: a frame
where neither the UI nor the game acts is a missed click, and a frame where both act is a player
who walked into a wall while closing a panel. There is now a test saying so.

**What implementation settled:**

* **`begin` takes a viewport, and the outermost region is a field rather than the first element
  of the stack.** There is therefore always somewhere to put a widget, `begin` cannot fail for
  want of memory, and a widget described with no panel open lands in the viewport instead of
  being dropped or asserted on.
* **Clip rectangles are intersected when pushed, not when walked.** The recorded command carries
  the resolved rectangle, so the walker hands it straight to a scissor and the "intersected with
  whatever is already on the stack" promise in §6 is kept in one place rather than in every
  consumer. `core.math.Rect.intersect` was added for it — the first thing in Foundry to need one.
* **A widget that does not fit keeps the size it asked for**, running past its region's edge
  rather than being squashed into what is left. Clipping is a draw concern (§11), and a widget
  that silently changed height when a panel filled up would be far harder to explain than one
  that is visibly cut off.
* **Ids are seeded by the region they are asked in.** That is what the `id` parameter on
  `beginPanel` and `beginRow` is for, and it is §3's id stack without a second stack to keep in
  step: `ctx.childId("save")` inside two panels names two widgets. A region opened with `.none`
  inherits its parent's seed rather than resetting to the root.
* **`Style` gained `separator_thickness`.** A separator needs a line weight, and ADR-0024 does
  not let the kernel invent one. It is defaulted, so no existing style literal had to change.
* **`button` is now two functions.** `button` is placed by the current region and sized to its
  text; `buttonIn` takes an explicit rectangle. The second is not legacy: a debug overlay is not
  always inside a panel, and every layout test wants a form that does not also exercise the
  cursor.
* **A vertical region gives a widget the region's full width**, exactly as §5 says, which means a
  button in a panel is a full-width bar and side-by-side buttons need a row. That is the first
  visible consequence of "layout is a cursor, not a solver", and it is recorded here because it
  looks like a bug until the sentence in §5 is read.
* **`row`/`endRow` are spelled `beginRow`/`endRow`**, matching `beginPanel`/`endPanel` and
  `beginRegion`/`endRegion`. A bare `row` reads like a widget that draws one.
* **Every unbalanced case is reported and survivable**, never asserted: an extra `endRegion`, an
  extra `popClip`, a frame that ends with either still open. All of them are caller bugs, and
  from M7 the caller may be a mod (CLAUDE.md §7).
