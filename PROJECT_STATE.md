# Foundry Project State

**Last updated:** 2026-09-03
**Updated by:** **M0 complete.** `rhi` implemented with its validation backend; 222 tests

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

**Next milestone: M1 — First pixels.** The Metal backend, behind the Objective-C shim
(ADR-0012), against the RHI that now exists. `docs/design/rhi.md` is written and
implemented; `engine.gpu` is a live device and `engine.nativeSurface()` already hands back
a `CAMetalLayer`.

Target: a window that opens and responds to input on macOS, a fixed-timestep loop, `core`
primitives, a null RHI backend, and cross-compilation checks for Windows and Linux. Full
definition and exit criteria in `docs/ROADMAP.md`.

---

## What has been implemented

**`core` (L0) and `platform` (L1). No renderer, and nothing yet opens a window.**

New this session:

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

**`zig build test` passes 222 tests** (50 `core`, 68 `platform`, 82 `rhi`, 22 `app`) with
the default SDL3 backend. Every test is headless: nothing in the suite calls `SDL_Init`,
and `app`'s tests instantiate `EngineOf(null_backend.Platform)` so the frame loop is always
measured against a synthetic clock rather than against this machine.

**The whole stack comes up.** `platform` (SDL3, `cocoa` driver) hands an opaque
`CAMetalLayer` handle to `rhi`, which brings up a validating device with a 2-frame ring:

```
info(platform): platform backend: SDL3 3.4.14, video driver 'cocoa'
info(rhi): rhi backend: null (validating), 2 frames in flight
info(sandbox): window: 1280x720 points, 2560x1440 pixels, scale 2.00
info(sandbox): gpu: 'null' backend, surface bgra8_unorm_srgb, 4 bind groups, 128 inline bytes
info(sandbox): native surface ready: metal_layer
```

**Live input is confirmed working** — focus and mouse events arrive and are logged. That
was the one thing left machine-unverified in the previous session.

**`zig build run` opens a window and exits cleanly.**

```
info(platform): platform backend: SDL3 3.4.14, video driver 'cocoa'
info(app): engine up: 60Hz simulation, windowed
info(sandbox): window: 1280x720 points, 2560x1440 pixels, scale 2.00
info(sandbox): native surface ready: metal_layer
info(sandbox): clean exit after 400 frames, 55 ticks, 916ms simulated
```

Headless (`-Dplatform=null`) it is exact rather than merely plausible: 300 frames of a 1ms
synthetic clock produce 300ms of simulated time and 18 ticks at 60Hz, every run.

**Both backends cross-compile to Windows and Linux — SDL and the sandbox executable included**, since the sample is part of the same per-milestone obligation. ADR-0008's "supported
means compiles" claim therefore covers the backend that actually ships, not only the
headless one — a better outcome than that ADR assumed was available.

**Four guarantees were verified by breaking them on purpose**, not by assertion:

| Claim | How it was checked |
| --- | --- |
| Layering (I7) | `platform` importing `rhi`, and `core` importing `platform`, both fail with *no module named X available within module 'root'* |
| Conformance | A backend missing a function, with a wrong signature, or with no `Platform` type each fails with a message naming the backend and the declaration |
| Windows really compiles | Breaking only the Win32 loader branch fails `zig build check -Dtarget=x86_64-windows-gnu` and no other target |
| Determinism (I9) | The same event sequence yields byte-identical snapshots; the synthetic clock drives a fixed-timestep loop to the same step count every run |

## What is being worked on

Nothing in progress. **M0 is complete and tagged `m0`.** The next session starts M1 at
step 1 below.

Verified after the fact, because a long outage interrupted the session that finished M0:
every commit builds and passes from a clean worktree (109, 109, 137, 137, 222 tests), a
cold-cache rebuild passes all 222, all six target/backend combinations compile, the pinned
SDL3 hash still verifies after deleting `zig-pkg/`, and layering, both conformance checks
and the Windows compile scoping were each re-confirmed by deliberately breaking them.

---

## Immediate next steps

**M1 — First pixels.** In ROADMAP order:

1. **The Metal backend** (`engine/src/rhi/backends/metal/`), via the thin Objective-C shim
   ADR-0012 specifies: device, command queue, the `CAMetalLayer` `platform` already
   provides, pipeline state objects, buffers, textures, draw submission, resize handling.
   The shim mirrors Metal one-to-one and holds **no policy** — that is a standing rule, and
   the shim growing a decision is the signal to move it up into the Zig backend.
2. **The Metal shader build step**: `xcrun metal` → `.air` → `xcrun metallib`, wired into
   `build.zig`, always through `xcrun` and never a hardcoded path (ADR-0014, ADR-0015).
3. **Runtime MSL compilation** for development builds, giving shader hot reload. Not merely
   a convenience: it is the same mechanism mod-authored shaders will need at M7.
4. **Metal API validation** on in debug builds, and Xcode GPU frame capture confirmed
   working.

The exit criterion is a textured quad that survives a window resize, with Metal validation
clean *and* the null backend raising no complaints about the same command stream. That last
clause is the whole point of having built the validation backend first.

---

## Known bugs and technical debt

* **The log sink has a runtime *level* filter but no timestamps, no scope filtering and no
  destination but stderr.** Timestamps want a monotonic source, which lives on `Platform`,
  and a free logging function has no instance to ask — worth solving when there is a log
  *file* to correlate against, at M9. Scope filtering is compile-time only for now
  (`std.Options.log_scope_levels`), and there are three scopes.
* **The frame loop has no pacing.** With no renderer there is no swapchain to block on, so
  the sandbox sleeps 2ms per frame to avoid pegging a core. Frame pacing is renderer
  policy and belongs with M1's present, not in `Engine`.
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
* **Usage-flag conformance is declared but unenforced.** Buffers and textures carry a
  usage set because Vulkan and D3D12 require it at creation, and both treat using a
  resource outside its declared usage as undefined behaviour — so it is a real invariant.
  It is not one of the ten documented rules, so the validation backend deliberately does
  not check it. Enforcing it would be an eleventh rule and therefore a contract change;
  recorded as an open question in `docs/design/rhi.md` §13 rather than resolved quietly.
* **The RHI's `Device` is not generic over its backend, unlike `app`'s `Engine`.** There is
  only one graphics backend, so there is nothing to parameterise over yet. When Metal
  lands, `app`'s tests will need the same treatment `platform` got, or the loop tests stop
  being headless.
* **The RHI will be validated by exactly one backend for a long time.** ADR-0003's
  mitigations (design to the strict model, null backend as validator) reduce this but do
  not remove it. Expect backend #2 to find design errors.
* **SDL3 arrives through a third-party build script** that can bitrot against a future
  pinned Zig release. Checking it is part of the cost of every Zig upgrade. Fallbacks in
  ADR-0002.
* Shaders will need per-backend variants when a second backend lands (ADR-0015).
* Sparse-set entity storage (M4) is explicitly a first implementation, not a final one.
* The first content authoring format may need replacing once real content exists at scale.
  ADR-0006 contains this by separating schemas from syntax.

---

## Important decisions made recently

**This session:**

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
