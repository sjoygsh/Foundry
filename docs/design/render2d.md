# Design: `render2d` — the 2D renderer

**Status:** Implemented as `engine/src/render2d/`, except the screen-space overlay M2's
last step needs. The batcher, camera, textures and blending 2026-09-04; the atlas, text and
`Region` the same day, which is when the resolutions in §8, §10 and §11 were written.
**Date:** 2026-09-04, revised 2026-09-04
**Implements:** I1, I5, I8, I9 · **Informed by:** ADR-0003, ADR-0007, ADR-0015, CLAUDE.md §4.2

`render2d` is layer L3. It depends on `core`, `rhi` and `asset`. It is the **first
game-facing rendering boundary** — the one games, tools and eventually mods actually use.

That makes this document more consequential than `rhi.md`, not less. The RHI has exactly
one consumer, which we write, and can be changed by changing both sides in one commit. The
renderer API will have consumers we do not control: games in other repositories (ADR-0017)
and, from M7, mods compiled against a frozen ABI. **Names and shapes chosen here are
compatibility decisions**, in the sense CLAUDE.md §7 means: renaming `drawSprite` later
breaks other people's code, and no amount of internal tidiness pays that back.

The governing constraint is CLAUDE.md §4.2:

> Games never touch the RHI. Backends never appear above it.

Everything below follows from taking that literally.

---

## 1. What this is, and what it is not

`render2d` turns *what the game wants drawn* into *as few draw calls as possible*. It owns
the sprite batcher, the 2D camera, GPU textures, atlases, text drawing and frame
statistics.

It is **not** a scene graph and it does not own the world. `scene` (L3, M4) owns entities
and components; the renderer is told what to draw each frame and forgets it afterwards. The
two are siblings, not a stack — a game can drive `render2d` with no `scene` at all, which
is exactly what `samples/sandbox` will do in M2.

It also does not own the frame. See §3.

| Concern | Owner |
| --- | --- |
| What exists in the world | `scene` (M4), or the game |
| What to draw this frame | The game |
| How to draw it in few draw calls | `render2d` |
| GPU objects and command recording | `rhi` |
| Bytes on disk becoming pixels in memory | `asset` |

## 2. Immediate submission, retained resources

Two obvious shapes exist. A **retained** renderer holds a list of sprite objects the game
mutates; a **immediate** one takes draw calls each frame and forgets them.

**Foundry uses immediate submission with retained resources.** Each frame, the game calls
`drawSprite` as many times as it likes; textures, atlases and fonts are long-lived and
referred to by handle.

The reasons, in order of weight:

1. **`scene` would otherwise be duplicated.** A retained renderer is a second place where
   game objects live, which must be kept in sync with the first. Every engine that has
   done this has regretted it.
2. **Draw order becomes explicit and deterministic** (I9). Submission order is data, not a
   side effect of when objects happened to be created or destroyed.
3. **It survives the ABI.** An immediate call is a function taking a plain struct — trivial
   to express as a C ABI entry point at M7. A retained renderer needs object lifetime rules
   across the ABI boundary, which is precisely the class of problem I1 exists to avoid.
4. **Culling stays where the information is.** The renderer sees a flat list and cannot know
   what a quadtree would. Whoever owns spatial structure — `scene`, or the game — is the
   only layer that can cull well, and it can simply not call `drawSprite`.

The cost is honest and worth stating: a game drawing 50,000 static sprites pays the
submission cost every frame even when nothing moved. If that becomes real, the answer is a
retained *batch* object — "draw this prepared set" — added alongside immediate submission,
not replacing it. Recorded in §14 rather than built now (rule 7).

## 3. Who owns the frame

The renderer does **not** call `beginFrame`, open the render pass, or submit. `app` does,
because `app` owns the device and because a frame will eventually carry more than sprites —
a debug UI in M6, a 3D pass later — and whoever opens the pass decides what shares it.

```
app.Engine ──beginFrame────────────────────► rhi.Device
           ──beginRenderPass──────────────► rhi.RenderPass
           ──renderer.record(&pass)───────► render2d.Renderer
           ──(future: debug_ui.record(&pass))
           ──endFrame─────────────────────► rhi.Device
```

The game sees none of this. It calls `renderer.drawSprite(...)` during its update, and the
`rhi.RenderPass` never appears in any signature a game can reach. `Renderer.record` is
public to `app`, not to games — a distinction Zig cannot enforce within a module, so it is
enforced by the ABI at M7 and by this paragraph until then.

Frame shape:

| Call | Who calls it | What it does |
| --- | --- | --- |
| `Renderer.beginFrame(frame)` | `app` | Resets the draw list and stats, adopts `frame.slot` |
| `Renderer.drawSprite/drawText/...` | **The game** | Appends to the draw list. No GPU work. |
| `Renderer.record(pass)` | `app` | Sorts, uploads, emits draw calls |
| `Renderer.endFrame()` | `app` | Publishes stats, advances the retirement queue |

## 4. Coordinate spaces

Three spaces, named and never conflated — the same discipline `platform` applies to logical
versus pixel size.

| Space | Units | Origin | Y | Where it comes from |
| --- | --- | --- | --- | --- |
| **World** | Whatever the game means by one unit | Arbitrary | **Up** | The game |
| **Screen** | Pixels | Top-left of the window | **Down** | `platform` — mouse, window size |
| **NDC** | −1..1 | Centre | Up | The camera's projection, consumed by the GPU |

**World Y points up.** This is a decision, not a default. Y-down would match screen
coordinates and tilemap row indexing, and several 2D engines choose it. Y-up wins because:

* Rotation signs, cross products and trigonometry behave the way the maths in `core.math`
  already assumes. A y-down world silently makes positive rotation clockwise, which is a
  permanent low-grade tax on every gameplay calculation.
* **3D is coming** (CLAUDE.md §1). Having `render2d` and `render3d` disagree about which
  way is up would be a genuinely bad thing to discover at M-something-large.

A tilemap that wants row 0 at the top is free to map rows to descending Y. That is a
content convention, not an engine one, and it belongs to whoever authors the map.

**UVs are Y-down**, because that is what Metal, Vulkan and D3D all do with texture memory.
The flip lives in exactly one place — the vertex writer in §6 — and nothing above it needs
to know.

Conversions are the camera's job and are exact, not approximate:

```zig
camera.worldToScreen(p: Vec2) Vec2
camera.screenToWorld(p: Vec2) Vec2   // picking, drag, "what did I click"
```

## 5. The camera

```zig
pub const Camera2D = struct {
    /// World point at the centre of the viewport.
    center: Vec2 = .zero,
    /// Pixels per world unit. Larger means closer.
    zoom: f32 = 1.0,
    /// Radians, counter-clockwise, about `center`.
    rotation: f32 = 0.0,
    /// The pixel rectangle this camera draws into. Usually the whole window.
    viewport: Rect,
};
```

`zoom` is **pixels per world unit** rather than its reciprocal, because that is the number
a 2D game actually reasons about ("this sprite is 16 world units and I want it 64 pixels
across, so zoom is 4"). The inverse convention reads better in a projection matrix and
worse everywhere else, and everywhere else is where people work.

The view-projection is built as `ortho * rotate(−rotation) * translate(−center)`, and needs
one addition to `core.math`:

```zig
pub fn orthographic(left, right, bottom, top, near, far: f32) Mat4
```

`screenToWorld` is **not** implemented with a general 4×4 inverse. The camera's transform is
a similarity — translate, rotate, uniform scale — so it is inverted analytically, in closed
form, which is exact, cheap, and impossible to get subtly wrong near degenerate zoom. A
general `Mat4.inverse` will arrive when 3D needs one and not before (rule 7).

Zoom is validated, not asserted: a zero or negative or non-finite zoom is a legitimate thing
for a settings file or a mod to contain, so it returns `error.InvalidCamera` rather than
tripping an assertion (CLAUDE.md §7).

**Pixel-perfect rendering is a policy, not a mode.** The renderer offers no "pixel perfect"
flag. A game that wants crisp pixel art picks a nearest sampler (§8), an integer `zoom`, and
a camera centre snapped to a whole pixel. Those are three lines in a game and three
irreversible assumptions in an engine.

### Views: more than one space in a frame

A frame is not all one space. Statistics have to sit still while the camera moves, a
minimap looks at the world from somewhere else, and a mod's overlay is neither. So the
renderer holds a small table of **views** for the frame, and a draw is recorded against
whichever one is current:

```zig
pub const ViewId = enum(u16) { world = 0, screen = 1, _ };

pub const ViewDesc = union(enum) {
    /// World units through a 2D camera. Its `viewport` is where it draws.
    camera: Camera2D,
    /// Screen points, origin at the top-left of the rectangle, **+Y down** — the same
    /// units and direction as mouse input, so a HUD is placed where the pointer is read.
    screen: Rect,
};

pub fn addView(self: *Renderer, desc: ViewDesc) !ViewId
pub fn setView(self: *Renderer, id: ViewId) !void
```

`begin` fills views 0 and 1 from the frame's camera and resets the current view to
`.world`, so a game that never mentions views behaves exactly as before. Everything else is
`addView`.

**Not a two-valued `space` flag, and not a field on `Sprite`.** A flag answers M2 and
nothing after it — a parallax layer, a split screen, a minimap and a mod's own overlay are
all *spaces*, and none of them is "screen". A field on `Sprite` would also have to be
copied onto `TextOptions` and onto every draw struct that ever exists, and would still only
carry two values. A view table costs one indirection and answers all of it, and a mod can
add an entry the way a mod can add anything else (I6).

**The current view is renderer state, not a parameter.** `setView` is called far less often
than `drawSprite` — a HUD is one call and then a hundred draws — and putting it in every
draw struct would be paying per sprite for something that changes per screenful. It resets
with `begin`, which is the only place it could go stale.

Views are cheap because the view-projection is **inline constants** (`rhi.md` §9), re-set
per batch rather than per frame. A view change costs one `setInlineConstants`, one
`setViewport` and a batch break — the same order as a blend-mode change, which the batcher
already handles.

**A view is validated, never asserted.** Its camera can come from a settings file and its
count from a mod, so `addView` refuses a bad camera with `error.InvalidCamera` and refuses
more than `max_views` with `error.TooManyViews`; `setView` refuses an id this frame does
not have with `error.InvalidView`.

## 6. Sprites, and how they become vertices

```zig
pub const Sprite = struct {
    texture: TextureHandle,
    /// Sub-rectangle in UV space. An atlas region supplies this; a whole texture is 0,0,1,1.
    uv: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    /// Where the sprite's origin sits, in world units.
    position: Vec2,
    /// Extent in world units, before rotation.
    size: Vec2,
    /// Which point of the sprite `position` refers to, normalised. Centre by default.
    origin: Vec2 = .{ .x = 0.5, .y = 0.5 },
    /// Radians, counter-clockwise.
    rotation: f32 = 0.0,
    /// Multiplied into the sampled texel. Linear, not sRGB — see below.
    color: Color = .white,
    /// Draw order. Lower draws first. Ties break on submission order.
    layer: i16 = 0,
    blend: BlendMode = .alpha,
    flip_x: bool = false,
    flip_y: bool = false,
};
```

Every field after `texture`, `position` and `size` has a default, so the simplest possible
call is three fields. This matters more than it looks: the shape of this struct is what
every game and every mod will type thousands of times.

**Rotation is applied on the CPU**, to four corners, not by a per-sprite matrix on the GPU.
Four rotated points cost eight multiplies; a per-sprite matrix costs a uniform binding or an
instance buffer and ends the batch. The whole point of a batcher is that ten thousand
sprites are one draw call.

### Colour is linear, and this is not negotiable

The swapchain is `bgra8_unorm_srgb` and textures decoded from PNG are created as
`rgba8_unorm_srgb`. The GPU therefore converts sRGB→linear on sample and linear→sRGB on
write, and **everything in between is linear light**. `Color` is four `f32` in linear space,
and the conversion for the numbers artists actually type lives in one function:

```zig
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };
pub fn srgb8(r: u8, g: u8, b: u8, a: u8) Color   // what a colour picker gives you
```

Getting this wrong is the most common silent rendering bug in existence — everything works,
and alpha blends and fades are subtly wrong forever. It costs one function to be right.

### Vertex format

```
offset  size  field
  0      8    position : f32×2   (post-transform, world space)
  8      8    uv       : f32×2
 16      4    color    : u8×4    (linear, premultiplied at write time)
                                  20 bytes per vertex, 80 per quad
```

`u8×4` colour rather than `f32×4` saves 12 bytes per vertex — a quarter of the buffer at
scale — and eight bits of linear colour is enough for a multiply. Premultiplying alpha at
write time makes `alpha` and `additive` blending differ only in one blend factor, which
removes a pipeline permutation.

`extern struct` with `comptime` assertions on every offset, exactly as the sandbox does
today: the shader's `[[stage_in]]` layout is a contract, and a silent padding change is the
kind of bug that costs an afternoon.

## 7. Batching

The draw list is sorted, then walked, and a new batch begins whenever the GPU state must
change.

**Sort key: `(view, layer, submission_index)`.** Nothing else. Sorting by texture within a
layer would produce fewer batches and *would reorder overlapping translucent sprites*,
which is wrong in a way that shows up as flickering in someone else's game six months
later. The atlas (§8) is the correct answer to batch count; reordering is not.

`view` comes first, so a view is drawn **entirely** before the next one and `layer` orders
within a view rather than across views. That is what makes a HUD a HUD: nothing in the
world can be given a layer high enough to cover it. It also means the floor on batch count
is the number of views in use, which is the honest cost of having them.

Because the key includes `submission_index`, it is a **total order**, so the result does not
depend on the sort algorithm's stability. That is an I9 requirement discharged by
construction rather than by choosing a stable sort and hoping nobody swaps it.

A batch breaks when the next sprite differs in **view**, **texture** or **blend mode**, or
when the current vertex buffer is full (§8). With a well-packed atlas and a couple of layers, a
typical frame is a handful of draw calls regardless of sprite count.

### Buffers, and the frame ring

`rhi.FrameContext.slot` exists for exactly this and its documentation already says so:
writing to slot-indexed memory is safe because `beginFrame` waited for that slot's previous
use. So:

* **Vertex data** lives in a pool of `upload` buffers, **per slot**. Each frame claims
  buffers from its slot's pool, writes them through a persistent mapping, and returns them
  at `endFrame`. The pool grows to the high-water mark and then stops allocating, so a
  steady-state frame performs no allocation at all.
* **Index data** is one `device_local` buffer, built once at startup with the repeating
  `0,1,2, 0,2,3` quad pattern. It never changes, so it is uploaded once and never touched
  again. `u32` indices: `u16` would cap a draw at 16,384 quads and buy back 2 bytes a
  vertex, and a cap that produces a rare, size-dependent bug is a bad trade.
* **The camera transform** is inline constants (`rhi` guarantees 128 bytes; a `Mat4` is 64),
  so there is no per-frame uniform buffer and no bind group churn for the camera.

On **unified memory** (`capabilities().unified_memory`) the upload buffer is bound directly
as the vertex buffer. On a discrete GPU it is copied once per frame into a `device_local`
buffer, because a GPU reading vertices over PCIe every frame is the slow path that makes
people think batching does not work. The branch is one `if` at buffer-creation time, and it
exists now because it is trivial now and archaeological later.

## 8. Textures, atlases, and ownership

`asset` decodes bytes into a CPU-side `Image`. `render2d` owns everything on the GPU. The
seam is one call:

```zig
pub fn createTexture(self: *Renderer, image: asset.Image, options: TextureOptions) !TextureHandle
pub const TextureOptions = struct { filter: Filter = .nearest, wrap: Wrap = .clamp };
```

**`TextureHandle` is `render2d`'s own generational handle** (I1), not an `rhi` handle passed
through. A game holding a raw `rhi.TextureHandle` would be holding an RHI type, which §4.2
forbids, and would also be holding something whose lifetime rules it cannot see.

**The default filter is `nearest`.** Linear filtering silently blurs upscaled pixel art and
nothing in the API tells you why; nearest is visibly wrong for photographic content, which
sends you to look for the setting. Defaults should fail loudly.

An **atlas** is a texture plus a rectangle packer:

```zig
pub fn createAtlas(self: *Renderer, size: Extent2D, options: AtlasOptions) !AtlasHandle
pub fn atlasAdd(self: *Renderer, atlas: AtlasHandle, image: asset.Image) !Region
pub const Region = struct { texture: TextureHandle, uv: Rect, size_px: Extent2D };
```

Packing is a **shelf packer** — sort by height, fill rows, start a new row when full. Not a
skyline or MAXRECTS packer: shelf is a hundred lines, gets within a few percent of optimal
for same-height sprites (which is what sprite sheets are), and can be replaced without any
caller noticing because the only thing that escapes is a `Region`.

**Resolution (implementation).** Sorting is not available: `atlasAdd` takes one image at a
time, because a mod adds one sprite at load time long after the others were packed. The
incremental equivalent is **best fit by height** — the shelf that wastes the least — which
degenerates to the sorted result when the images are the same height, and that is what a
sprite sheet and a glyph grid both are. Ties go to the first shelf, so packing is a pure
function of insertion order (I9).

Two further things implementation settled:

* **`Region.sub` cuts in the region's own pixel space**, not the texture's. A caller
  slicing a sheet into cells should not have to know whether the sheet is a texture of its
  own or a corner of a shared atlas — which is exactly what makes moving a font into an
  atlas a change to one creation call and to nothing else.
* **One texel of padding, by default.** Linear filtering samples four texels and reaches
  across a shared edge; nearest does too at a non-integer scale, because the sample point
  is a position rather than an index. A neighbour bleeding into a sprite's edge is the
  classic atlas artefact and is confusing precisely because the sprite is right on its own.
  What has to *fit* is the image and not its padding: the reserved texels past the last
  thing on a shelf are never written, so an image exactly as large as the atlas is legal.

Two answers, not one, when an image does not fit. `error.AtlasFull` means try another
atlas; `error.RegionTooLarge` means no atlas this size will ever take it, and a caller that
answered both the same way would allocate atlases until it ran out of memory. Content comes
from files, so that path is reachable.

The atlas needed one thing from below it: `copyBufferToTexture` gained a `dst_origin`
(`rhi.md` §8), since writing a rectangle of a texture rather than the whole thing is the
difference between adding one sprite and re-uploading megabytes.

Packing happens at **runtime**, deliberately. An offline packer in `tools/fpack` would pack
better, but a mod that adds a sprite needs packing to work at load time, and I3 says the
base game uses the same path mods do. An offline *pre-pack* can be added at M3 as an
optimisation of the same mechanism.

Texture size is validated against `capabilities().max_texture_dimension` and refused with an
error, never asserted: the image came from a file, and files come from mods.

## 9. Destruction, and the debt this design refuses to lean on

`rhi/interface.zig` documents deferred destruction that **no backend implements** (recorded
in PROJECT_STATE). Destroying a texture that a frame in flight still references is undefined
behaviour today, and it would be reached by the most ordinary game code imaginable —
unloading a level while two frames are in flight.

`render2d` therefore does not rely on the RHI's promise. It keeps its own **retirement
queue**:

```
destroyTexture(h):
    invalidate h's generation immediately   // stale handle now fails a lookup, not a crash
    push { rhi_handle, retire_after = frame_index + frames_in_flight }

endFrame():
    pop everything whose retire_after <= frame_index, and call rhi.destroyTexture
```

Two frames of latency on a texture free is nothing. A use-after-free in a renderer is a
week. This is the concrete payoff of I1: the generation bump means a stale handle produces a
clean `error.InvalidTexture` at the call site instead of sampling freed GPU memory.

This does **not** discharge the RHI debt — the interface still promises something it does
not do, and that stays on the list. It means the renderer is correct regardless.

## 10. Text

Text is not a separate pipeline. A glyph is a sprite from the font's texture, so text goes
through the same batcher, the same sort key and the same draw call as everything else. Text
and sprites in the same layer with the same atlas are one draw call.

**M2 supports fixed-grid bitmap fonts only**:

```zig
pub const BitmapFont = struct {
    glyphs: Region,        // where the grid lives
    cell: Extent2D,        // glyph cell size in pixels
    columns: u32,          // cells per row of the grid
    first_codepoint: u21,  // usually 32, space
    glyph_count: u32,
    substitute: ?u21,      // drawn for anything the font lacks
};
```

**Resolution (implementation).** `glyphs` is a `Region` rather than a `TextureHandle`, and
that is what makes the paragraph above true rather than aspirational: a font packed into a
shared atlas and a font on a texture of its own are the same thing to everything
downstream, because `Region.sub` (§8) cuts the grid the same way either. A font on its own
texture is `Region.whole(handle, size)`.

`substitute` is a font property because it is the font that does or does not have the
glyph. Null draws nothing and still advances, so a missing character leaves a gap rather
than shifting the rest of the line; a substitute the font also lacks yields nothing rather
than looking itself up again.

A fixed grid needs **no metrics file**, and that is the whole reason it was chosen. The
authoring text syntax is a deliberately postponed decision due at M3 (CLAUDE.md §9), and
inventing a font-metrics format in M2 would resolve part of it opportunistically — exactly
what the standing instruction on ADR-0003 forbids. Variable-width fonts, kerning, and fonts
as a real content-system asset arrive in M3 alongside the format that can describe them.

The font is **an asset the game supplies**, not something the engine embeds. `render2d`
ships no glyphs (I5); `samples/sandbox` ships a font with its licence recorded, and uses the
same call a game or a mod would. The M6 debug overlay will need to state where its font comes
from, and the answer will be "the same place", not "a private one" (I3, I4).

Text drawing takes untrusted bytes and must never trip on them: invalid UTF-8 and codepoints
outside the font's range draw a substitution glyph, and drawing stops at the string's end,
not at a terminator. A mod's translation file is text from a stranger.

## 11. Frame statistics

Required by M2's roadmap entry, and required rather more by everything after it: a batcher
whose batch count you cannot see is a batcher you cannot tune.

```zig
pub const Stats = struct {
    sprites: u32, glyphs: u32,
    batches: u32, draw_calls: u32,
    vertices: u32, vertex_bytes: u32,
    buffers_used: u32, textures_resident: u32, views: u32,
};
```

**Resolution (implementation).** `atlas_fill` is not here: an atlas's fill is a property of
that atlas and not of a frame, and a renderer with three atlases has no single number to
report. It is `Renderer.atlasFill(handle)` instead. `cpu_record_ns` is not here either —
`app.Engine.frameDelta` already measures the frame, and a second clock read that measured
*almost* the same thing would mostly generate arguments about which one was right.

Glyphs are counted in `sprites` as well as in `glyphs`, because a glyph *is* a sprite by the
time the batcher sees it. Counting it once would make the sprite count disagree with the
vertex count.

Counters reset in `beginFrame` and are published in `endFrame`, so a reader always sees a
complete frame rather than a half-written one. **Statistics never feed simulation** (I9):
they are outputs. GPU timing is deferred — it needs timestamp queries the RHI does not have,
and the CPU-side numbers are what M2 can act on.

## 12. What this exposes to mods

CLAUDE.md §5 requires that adding a subsystem includes deciding what it exposes, even if the
answer is "nothing yet". For M7's ABI, the intended surface is:

**Exposed:** create/destroy texture, create atlas and add to it, load a font, draw a sprite,
draw text, add and select a view, set and query the camera, convert between screen and
world, read frame stats.

`addView` is deliberately in that list. A mod that draws an overlay needs a space to draw it
in, and the alternative — a fixed `screen` and nothing else — would mean a mod wanting a
minimap has to reimplement the projection in world coordinates and get it wrong under
rotation.

**Not exposed:** the render pass, the vertex format, the batcher's internals, buffer pools,
`rhi` handles, and anything that would let a mod reorder or bypass batching.

The consequence, recorded now because it constrains M7: **a mod cannot supply its own
shader through `render2d`.** That capability belongs to the material system, which does not
exist yet, and ADR-0015 already records that it must not be designed assuming all shaders
are known at build time.

## 13. Errors

Anything that can come from a file or from a mod is validated and returns an error.
Anything that is a programmer mistake asserts.

| Situation | Response |
| --- | --- |
| Malformed or oversized image | `error.InvalidImage` / `error.TextureTooLarge` |
| Atlas is full | `error.AtlasFull` — a normal condition, the caller makes another atlas |
| Atlas cannot ever hold it | `error.RegionTooLarge` — retrying with a fresh atlas would loop |
| Stale or foreign handle | `error.InvalidTexture` / `error.InvalidAtlas`, from the generation check |
| A view id this frame does not have | `error.InvalidView` |
| More views than `max_views` | `error.TooManyViews` |
| Zero, negative or non-finite zoom | `error.InvalidCamera` |
| Invalid UTF-8 in a string | Substitution glyph, no error |
| `drawSprite` or `drawText` before `begin` | `error.NotRecording` |
| A font with zero columns or an empty cell | No glyph, no error — at M3 those fields come from a file |

## 14. Deliberately not here

Tilemaps (a batcher tuned for a grid, once there is content to fill one), materials and
custom shaders, render targets and post-processing, lighting, particles, retained batches
for static geometry, sorting by texture within a layer, GPU timing, sprite culling, and
anything 3D.

Each is a real thing this design leaves room for. None of them is M2.

## 15. Open questions

* **Whether `layer` should be `i16` or a float depth.** `i16` is exact and sorts trivially;
  a float would let content place things between layers without renumbering. Revisit when
  content authoring exists and it is clear which one authors actually want (M3).
* **Whether an opaque layer may opt into texture sorting.** Correct for opaque content,
  wrong for translucent, and the renderer cannot tell which it has. Revisit if batch counts
  ever actually hurt.
* **Where `Image` lives long-term.** `asset` owns it now. When the content system arrives it
  may want to own the decoded form too, which is an M3 question and is left alone here.
* **Whether the atlas should repack.** Currently it cannot; a full atlas stays full. Repacking
  invalidates every `Region` handed out, which needs a handle indirection nobody needs yet.
