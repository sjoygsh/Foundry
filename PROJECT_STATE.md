# Foundry Project State

**Last updated:** 2026-09-04
**Updated by:** **M1 exit criterion met.** A textured quad, both validation halves clean

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

**Phase 1 — Foundation.**

## Current milestone

**M0 — Skeleton: "it runs." Complete, 2026-09-03.** Every item on its ROADMAP list is
done and both exit criteria are met: `zig build run` opens a window on macOS that responds
to input, and both platform backends cross-compile for Windows and Linux. Nothing is
drawn, which M0 deliberately excludes.

**Current milestone: M1 — First pixels. Exit criterion met, one check outstanding.**
`zig build run -Drhi=metal` opens a window on macOS and draws a rotating, nearest-filtered
textured quad, vsync-paced.

All five ROADMAP items are done: the Metal backend and its Objective-C shim (1), the
`xcrun metal` → `.metallib` build step (2), runtime MSL compilation (3), the validation
backend (4), and Metal API validation enabled and clean (5). The exit criterion —
*a textured quad, Metal validation clean, the null backend raising no complaints about the
same command stream* — is met and was confirmed by looking at the window, not only by
inference from a clean run.

**The one part not confirmed is "surviving window resize."** The path is written and its
headless half is tested; driving a real window resize turns out to need macOS Accessibility
permission this environment does not have. See the debt list — it is a gap in the *check*,
not a known bug, and there are exactly two ways to close it.

---

## What has been implemented

**`core` (L0), `platform` (L1), `rhi` (L2) with two backends, `app` (L4). It draws a
textured quad.**

New this session:

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

**`zig build test` passes 225 tests** (50 `core`, 68 `platform`, 85 `rhi`, 22 `app`), and
**233 under `-Drhi=metal`**, where `rhi` gains the backend's own 8. Everything but those 8
is headless: nothing calls `SDL_Init`, and `app`'s tests instantiate
`EngineOf(null_backend.Platform, null_backend.Device)` so the frame loop is measured
against a synthetic clock and a validating device, never against this machine. The 8
exceptions need a real GPU and compile only when Metal is selected.

**It draws a textured quad.** `platform` (SDL3, `cocoa` driver) hands an opaque
`CAMetalLayer` to `rhi`, which brings up a real Metal device and renders:

```
info(platform): platform backend: SDL3 3.4.14, video driver 'cocoa'
info(rhi): rhi backend: metal on 'Apple M5', 2 frames in flight, surface bgra8_unorm_srgb
info(app): engine up: 60Hz simulation, windowed, rhi backend 'metal', 2 frames in flight
info(sandbox): window: 1280x720 points, 2560x1440 pixels, scale 2.00
info(sandbox): gpu: 'metal' backend, surface bgra8_unorm_srgb, 4 bind groups, 128 inline bytes
info(sandbox): native surface ready: metal_layer
info(sandbox): clean exit after 600 frames, 299 ticks, 4983ms simulated
```

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

**M1, complete but for one check.** Every ROADMAP item is done and the exit criterion is
met and seen. Nothing is half-built: the tree is green on both backends and the sandbox
runs. What remains is confirming the resize path against a real window, which is blocked on
a machine permission rather than on any code — and confirming Xcode frame capture, which is
a look rather than a change.

M0 is complete and tagged `m0`. It was re-audited after the outage that interrupted the
session finishing it — every commit builds from a clean worktree, a cold-cache rebuild
passes, the pinned SDL3 hash re-verifies, and layering, both conformance checks and the
Windows compile scoping were each re-confirmed by deliberately breaking them.

---

## Immediate next steps

**Closing M1.** Two checks, then the milestone is done and tagged.

1. **Confirm a real-window resize.** The only substantive thing left. Driving one
   programmatically needs macOS Accessibility permission, which this environment does not
   have, so there are two ways to close it and they are a real choice rather than a
   formality:
   * **Look at it.** Run `zig build run -Drhi=metal` and drag the window edge. If the quad
     stays square and the log shows `resized:` lines with no error, the path works. Ten
     seconds, no code, but it is a one-off that no future session repeats.
   * **Add `setWindowSize` to `platform`.** Then the check is automatable and repeatable.
     This is *not* a test hook: any game with a settings menu needs to set its resolution,
     so it is a genuinely missing platform capability rather than scaffolding. But it is an
     interface change — the conformance check, both backends and the design doc — and
     `CLAUDE.md` rule 10 says that is the user's call, not something to slip in while
     finishing a milestone.
2. **Confirm Xcode GPU frame capture** works against the shim, which is one of the stated
   reasons Metal is the first backend (ADR-0012). The shaders are already built with
   `-frecord-sources`, so a capture should show source rather than disassembly.

**Then M2 — sprites.** The quad is one draw; M2 is thousands, which means batching, a
texture atlas, PNG decode, a real 2D camera and bitmap text. The camera is the first thing
that will want more of `core.math` than `Mat4.scaling` — the sandbox's `aspectCorrection` is
deliberately the three lines M1 needed and no more.

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
* **A real-window resize has still never been run.** The Metal backend's resize path is
  written and the headless half of it is tested, but the `CAMetalLayer` branch has not been
  exercised. Driving a window resize from outside the process needs macOS Accessibility
  permission (`osascript is not allowed assistive access`), and `platform` exposes no way to
  do it from inside. Until it is checked, "survives a resize" is a claim about code, not
  about behaviour. This is a gap in the *check*, not a known bug — and the two ways to close
  it are in "immediate next steps" above.

* **`FrameError` cannot distinguish transient from fatal surface failure.** Metal returning
  no drawable — a minimised or occluded window, or every drawable still in flight — is
  transient and the right response is to skip the frame. A genuinely lost surface is fatal.
  The RHI has one error, `SurfaceLost`, for both, so the backend reports the transient case
  as `SurfaceLost` and the sandbox skips. Vulkan draws exactly this distinction
  (`OUT_OF_DATE` versus `SURFACE_LOST`), which is a hint that the RHI should too — but
  adding an error is a contract change, so it is recorded rather than done quietly.

* **Xcode GPU frame capture is not yet confirmed** against the shim, despite being one of
  ADR-0012's stated reasons for the design. Nothing suggests it is broken; it simply has
  not been checked.

* **Where a compiled shader lives is unsettled, deliberately.** The build step exists and
  `createShaderModule` has a producer, but the only shader belongs to `samples/sandbox`,
  which `@embedFile`s the `.metallib` into its executable. That is the smallest thing that
  proves the interface has a producer; naming and finding an asset is M3's question, and
  inventing half an answer here would prejudge the package-zero decision that milestone owes
  (unresolved question 2 below).

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

**This session (M1, the quad):**

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
   own — default font, error texture, fallback shader — as a real content package? Probably
   yes, and it is a good early test of Invariant I3. Decide during M3.
3. **Authoring format syntax.** Postponed to M3 by ADR-0006. Requirements recorded;
   candidates are adopting an existing format versus a small purpose-built one.
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
