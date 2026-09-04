# Foundry Project State

**Last updated:** 2026-09-05
**Updated by:** **M3, step 9.** `content/core` is package zero. The engine loads it
through the same call a mod's package goes through, the sandbox ships a package of its own
and embeds nothing, and a third package dropped in after them overrides both — an asset and
a value — without naming a path

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

**Phase 2 — A real 2D engine.** Phase 1 (M0, M1) closed with the first pixels; M2 and M3
are done. Next is **M4 — World: "it has entities."**

## Current milestone

**M0 — Skeleton: "it runs." Complete, 2026-09-03.** Every item on its ROADMAP list is
done and both exit criteria are met: `zig build run` opens a window on macOS that responds
to input, and both platform backends cross-compile for Windows and Linux. Nothing is
drawn, which M0 deliberately excludes.

**M1 — First pixels: "it draws." Complete and tagged `m1`, 2026-09-04.** `zig build run
-Drhi=metal` opens a window on macOS and draws a rotating, nearest-filtered textured quad,
vsync-paced, which survives being resized.

**M2 — Sprites: "it draws a lot." Complete, 2026-09-04.** All six steps are done and the
exit criterion is met and seen: `zig build run -Drhi=metal` draws 4,185 sprites at vsync
under a camera driven by keyboard and mouse, with the batcher's own numbers on screen in a
space that does not move when the camera does — 4 batches and 4 draw calls, because the
sheet, the font and the selection outline share one atlas.

**M3 — Content: "it has data." Complete, 2026-09-05.** All ten steps done. It started at
the only place it could: its decisions. The first modding-relevant milestone, and it comes due on two of
`CLAUDE.md` §9's postponed decisions — both now spent, as **ADR-0020** and **ADR-0021**, and
struck from the §9 table. The two design documents `docs/design/README.md` has owed since M2
are written, and `data` is built behind them, front to back: text in, checked records out,
compiled to a package file, merged with other packages by load order — and `fpack` now
drives the whole of it from a directory. The asset registry sits above it now, and a
content id resolves all the way to a GPU texture. `content/core` is package zero, the
sandbox embeds nothing, a mod dropped in after them overrides by id, and an edit reaches the
running program without restarting it. **All three exit criteria were met and seen.** One
roadmap item was deliberately not built: shaders did not become assets, because the engine's
own stay embedded (ADR-0019) and a content-owned one has nothing to reference it yet. See
`docs/ROADMAP.md`.

**M1, for reference.** All five ROADMAP items are done: the Metal backend and its Objective-C shim (1), the
`xcrun metal` → `.metallib` build step (2), runtime MSL compilation (3), the validation
backend (4), and Metal API validation enabled and clean (5).

**The exit criterion is met in full** — *a textured quad on screen, surviving window resize,
with Metal validation clean and the null backend raising no complaints about the same
command stream* — and every clause of it was checked rather than inferred. The resize half
was the last to close and needed a new platform capability to do it; see the decisions
below.

Xcode GPU frame capture is confirmed as far as a terminal can confirm it: the sandbox runs
clean under `MTL_CAPTURE_ENABLED=1` alongside both validation layers, so the capture layer
loads and accepts the command stream. Opening the resulting trace in Xcode and reading MSL
source in it is a GUI action, and is the one M1 item verified by its prerequisites rather
than by being done.

---

## What has been implemented

**`core` (L0), `platform` and `data` (L1), `rhi` (L2) with two backends, `asset` (L2),
`render2d` (L3), `app` (L4), plus `tools/fpack`. `scene` does not exist yet. It draws
thousands of sprites under a camera that pans, zooms and picks, and it loads content by
content id.**

New this session:

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

**`zig build test` passes 502 tests** (52 `core`, 70 `platform`, 102 `data`, 92 `rhi`,
36 `asset`, 103 `render2d`, 28 `app`, 14 `fpack`, 5 integration), and **510 under
`-Drhi=metal`**, where `rhi` gains the backend's own 8. Everything but those 8 is headless: nothing calls `SDL_Init`, and `app`'s tests
instantiate `EngineOf(null_backend.Platform, null_backend.Device)` so the frame loop is
measured against a synthetic clock and a validating device, never against this machine. The
8 exceptions need a real GPU and compile only when Metal is selected.

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

**The text was looked at, not inferred**, the same way M1's quad was. A capture of the
sandbox's own window (by window id, so nothing else on the screen is read) shows the
statistics panel and the help line in screen space, the world-space banner, and the
`#1863` label above the outlined sprite, all legible — over 2,400 frames with Metal API
*and* GPU validation on and **zero messages**. That capture is also what caught the Y-axis
bug: the first windowed run drew the whole readout upside down, which no unit test had
asked about because until then every space was Y-up.

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

**M3 — Content: "it has data."** It opened with two decisions §9 had been holding since M0
and the two design documents they needed, per `CLAUDE.md` rule 1 — design before
implementation — and rule 10, which says never make a major architectural decision silently.
Both are spent, as ADR-0020 and ADR-0021, and `data` is built behind them.

**Steps 1 to 9 are built.** `data` exists end to end — identity, schemas, the registry, the
lexer, the parser, diagnostics, the checking pass, the `.fpk` writer and reader, and the
store that merges packages — `tools/fpack` drives all of it from a directory, and the asset
registry above it turns a content id into a loaded payload, `content/core` is package zero,
and content reloads under a running program. 502 tests, up from 346 at the end of M2; all
eight target/backend combinations compile; `zig fmt` clean.

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
are written, and the design README's owed table is now down to `entity-storage.md` for M4.

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
only be judged by using it.

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

**M3 is done and tagged.** Two things are outstanding, and neither is a bug:

* The key and button *bindings*, carried from M2 and still needing a person to judge them —
  that WASD pans the right way, that dragging carries the world with the cursor, that the
  wheel zooms toward the pointer.
* **Shaders are not assets**, which was an M3 roadmap item and was deliberately not built.
  Engine-owned shaders stay embedded (ADR-0019), so the only case is a *content-owned*
  shader, and nothing can reference one until there is a material system. Building an asset
  kind with per-backend variant selection (ADR-0015) for no consumer is the hypothetical
  requirement rule 7 warns about. Due with the material system, or the first time a sample
  wants its own shader. Adding it is a schema and a runtime-registered loader; nothing has
  to be reshaped.

**M4 — World: "it has entities"** is next, and its decisions come first as M3's did: ADR-0010
already constrains the component model, and `docs/design/` owes a document before any of it
is written.

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
* **`platform` has no gamepad support, file watching, IME preedit or audio.** Each is
  deferred with a recorded reason in the design doc's Resolution; none requires the
  interface to change to accommodate it later.
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

**This session (M3, the decisions it comes due on):**

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
2. **What "package zero" means for the engine itself.** Does the engine ship content of its
   own — default font, error texture — as a real content package? Probably yes, and it is a
   good early test of Invariant I3. Decide during M3. **Narrowed 2026-09-04 by ADR-0019**:
   the fallback *shader* is no longer part of this question, because engine-owned shaders are
   engine machinery rather than content. The font still is, and M2 deliberately dodges it by
   having the sample supply one. **Sharpened 2026-09-04 by ADR-0021**: the question is no
   longer *how* engine content would be identified — it is a record with a content ID like
   everything else — only *whether* the engine ships any. M3 step 9 forces the answer.
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
* **Lazy analysis makes negative tests lie.** A function body is only analysed when something
  reaches it, and an *undeclared identifier* is caught earlier than a *type error*, so a
  probe using the former proves nothing about branch analysis. Break things with a genuine
  type mismatch, and check the failure lands on the target you expect and not on others.
* **The build test runner reprints a command as "failed" when a test logs at `warn` or
  above**, while the build still exits 0. Two tests do this deliberately (handle generation
  wraparound, and an unclassifiable OS read error). Noise, not failure — check the exit code
  and the `Build Summary` line.
* **`.lazy = true` still extracts a dependency into `zig-pkg/`** on every build; it governs
  how `build.zig` must ask for it (`b.lazyDependency`, returning an optional), not whether it
  is materialised. `zig-pkg/` is build output and is gitignored.
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
