# Design: `render2d` — the 2D renderer

**Status:** Not implemented. Design only, written before M2 begins.
**Date:** 2026-09-04
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

**Sort key: `(layer, submission_index)`.** Nothing else. Sorting by texture within a layer
would produce fewer batches and *would reorder overlapping translucent sprites*, which is
wrong in a way that shows up as flickering in someone else's game six months later. The
atlas (§8) is the correct answer to batch count; reordering is not.

Because the key includes `submission_index`, it is a **total order**, so the result does not
depend on the sort algorithm's stability. That is an I9 requirement discharged by
construction rather than by choosing a stable sort and hoping nobody swaps it.

A batch breaks when the next sprite differs in **texture** or **blend mode**, or when the
current vertex buffer is full (§8). With a well-packed atlas and a couple of layers, a
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
pub fn createAtlas(self: *Renderer, size: Extent2D) !AtlasHandle
pub fn atlasAdd(self: *Renderer, atlas: AtlasHandle, image: asset.Image) !Region
pub const Region = struct { texture: TextureHandle, uv: Rect, size_px: Extent2D };
```

Packing is a **shelf packer** — sort by height, fill rows, start a new row when full. Not a
skyline or MAXRECTS packer: shelf is a hundred lines, gets within a few percent of optimal
for same-height sprites (which is what sprite sheets are), and can be replaced without any
caller noticing because the only thing that escapes is a `Region`.

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
    texture: TextureHandle,
    cell: Extent2D,        // glyph cell size in pixels
    columns: u32,          // cells per row in the texture
    first_codepoint: u21,  // usually 32, space
    glyph_count: u32,
};
```

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
    textures_resident: u32, atlas_fill: f32,
    cpu_record_ns: u64,
};
```

Counters reset in `beginFrame` and are published in `endFrame`, so a reader always sees a
complete frame rather than a half-written one. **Statistics never feed simulation** (I9):
they are outputs. GPU timing is deferred — it needs timestamp queries the RHI does not have,
and the CPU-side numbers are what M2 can act on.

## 12. What this exposes to mods

CLAUDE.md §5 requires that adding a subsystem includes deciding what it exposes, even if the
answer is "nothing yet". For M7's ABI, the intended surface is:

**Exposed:** create/destroy texture, create atlas and add to it, load a font, draw a sprite,
draw text, set and query the camera, convert between screen and world, read frame stats.

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
| Stale or foreign handle | `error.InvalidTexture`, from the generation check |
| Zero, negative or non-finite zoom | `error.InvalidCamera` |
| Invalid UTF-8 in a string | Substitution glyph, no error |
| `drawSprite` before `beginFrame` | Assertion — pure programmer error |

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
