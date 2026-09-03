# Design: `platform` — the interface Foundry owns

**Status:** Implemented 2026-09-03, both backends. `setWindowSize` added 2026-09-04.
See the Resolution at the end.
**Date:** 2026-09-02
**Implements:** I7, I9 · **Informed by:** ADR-0002, ADR-0003, ADR-0007, ADR-0008

`platform` is layer L1. It depends on `core` and nothing else. It is the only module in
Foundry that may reference SDL3.

This document exists because of a specific, named risk recorded in ADR-0002:

> Foundry's platform interface will initially be shaped by what SDL provides. Watch for SDL
> concepts leaking into the interface's *design*, not just its implementation.

A wrapper that renames SDL's types and calls it abstraction is worse than using SDL directly,
because it pays the indirection cost without buying replaceability. The whole value of this
layer is that SDL3 can be replaced, supplemented or dropped without the rest of the engine
noticing (ADR-0002, and "Foundry owns its abstractions" in `CLAUDE.md` §2).

**The test applied throughout, whenever a design choice was open:** *would this interface
still be the right shape if it were implemented by hand-written Cocoa and Win32, with no SDL
anywhere?* Where the answer was no, the design changed.

---

## 1. Shape of the interface

**One implementation is selected at build time**, not dispatched through a vtable at runtime.

Foundry runs on exactly one platform backend per binary, chosen when the build graph is
constructed. A runtime vtable would buy nothing — nobody swaps platform backends mid-run —
and would cost an indirect call on every input poll and clock read.

This is *not* in tension with I6 (registries are runtime-populated). I6 exists so mods can
add component types, asset loaders and content schemas. **Mods do not add platform
backends**; a platform backend is an engine port, and ports are compile-time decisions.

Because there is no vtable, nothing structurally forces two implementations to agree. That is
handled by:

* **A `comptime` conformance check.** The interface is a documented set of declarations, and
  a `comptime` function verifies that the selected implementation provides every one of them
  with the expected signature. A missing or misdeclared function is a compile error naming
  the offender, not a link error or a runtime surprise.
* **A `null` platform implementation** (§9), which every interface change must also satisfy.
  Two implementations is the minimum number at which an interface is actually an interface —
  the same reasoning that makes the null RHI backend worth having (ADR-0003).

## 2. Lifecycle

`platform` initialises first and shuts down last. It takes an allocator explicitly, like
everything else; it owns no global state and there is no implicit singleton.

Subsystem teardown is strictly reverse-of-initialisation order. This is `app`'s
responsibility, but it constrains `platform`: **no platform resource may require another
subsystem to still be alive in order to be destroyed.**

---

## 3. Window and surface

### Size is two different things

A window has a **logical size** in points and a **pixel size** in device pixels. On a Retina
display these differ by the display's scale factor, and they also differ from each other
after a window moves between monitors of different densities.

Both are exposed, separately and unambiguously named. Neither is called "size".

* Logical size drives UI layout and input coordinates.
* Pixel size drives the swapchain and viewport.

This is stated first because conflating them is the most common source of "everything is
half-size on my laptop but fine on my monitor" bugs, and because the mistake is cheap to
avoid at design time and expensive to unpick after a renderer depends on it.

### Resizing is a request, not a setter

`setWindowSize` takes a **logical** size, because logical is the only one of a window's two
sizes that can be set: pixel size follows from it and the display's scale factor, and the
scale belongs to the display rather than to us.

**The call does not change the window; it asks.** The new size is observed by draining
`window_resized` from the event queue, exactly as a user dragging an edge is observed. Three
reasons, in increasing order of how expensive they are to discover later:

* A window manager may decline, or comply partially. Asking for 900x900 on this machine
  yields 900x794, because the request exceeded the usable display height. A setter's return
  value would have to express that; an event just reports what happened.
* Some platforms apply the change synchronously and some do not, so a caller that read the
  size straight back would work on one and desynchronise on another.
* There is then exactly **one** resize path, whoever initiated it. A program that resizes
  itself is running the same code as a user dragging an edge — which means testing either
  one tests both, and it is why this function exists at all: without it, the swapchain
  resize path could only ever be checked by a person remembering to check it.

The null backend enforces the strict reading — it queues the event and changes nothing until
the queue is drained — for the same reason the null `rhi` backend enforces rules Metal
forgives. Making the strict contract the easy one to satisfy is that backend's job.

A zero dimension is reported as `InvalidWindowSize` rather than asserted: a resolution
usually arrives from a settings file or a mod, which is untrusted input and is validated at
the boundary (`CLAUDE.md` §7).

### The native surface seam

`platform` exposes an opaque, tagged handle:

```
NativeSurfaceHandle = { kind: enum { metal_layer, ... }, ptr: *anyopaque }
```

`rhi` switches on `kind` and interprets `ptr` per backend. On macOS this carries the
`CAMetalLayer` obtained from SDL3 — verified working during M0 setup (ADR-0002 resolution).

**No SDL type and no graphics-API type appears in this signature.** `platform` does not know
what Metal is; `rhi` does not know what SDL is. `rhi` already depends on `platform`
(ADR-0007), so this requires no sideways dependency.

Future kinds — `win32_hwnd`, `xlib_window`, `wayland_surface` — are added to the enum as
backends arrive. An `rhi` backend encountering a `kind` it does not handle returns an error;
it does not assert, because the combination is a configuration mistake rather than a
programmer error.

### Deliberately excluded

SDL offers a renderer, image loading, font rendering and a GPU abstraction. **Foundry uses
none of them.** `SDL_gpu` in particular is excluded by explicit decision (ADR-0003); the
renderer is Foundry's own. Nothing from `SDL_image`, `SDL_ttf` or `SDL_mixer` enters the
engine — those are asset concerns, and assets are Foundry's (ADR-0006).

---

## 4. Events and input

### Polling, not callbacks

Events are drained once per frame:

```zig
while (platform.pollEvent()) |ev| { ... }
```

Callbacks would invert control, run engine code at arbitrary points inside the OS event loop,
and make the ordering of state changes depend on the platform's dispatch behaviour — which is
exactly the kind of thing I9 forbids depending on. Polling puts event handling at one known
point in the frame.

Foundry defines its own event type. It is **not** a renamed SDL event union: it carries only
what the engine acts on, and every variant is one Foundry could deliver from a hand-written
Cocoa implementation. Events SDL reports that Foundry has no use for are dropped in the
backend, not passed through and ignored upward.

### Events versus state

Both exist, and the distinction is deliberate:

* **Events** are for discrete things that happen: key pressed, key released, mouse button,
  scroll, text entered, window resized, quit requested.
* **State** is for continuous things that *are*: which keys are currently held, where the
  mouse is, gamepad axis positions.

Deriving held-state from events alone forces every consumer to maintain its own tracking and
gets it wrong on focus loss. Deriving events from state alone loses presses that begin and end
within one frame.

### The input snapshot — an I9 requirement

**Input is captured once per frame into an immutable snapshot. Simulation reads the snapshot
and never queries the device.**

This is not tidiness. It is the mechanism that makes I9 achievable:

* Two simulation ticks within one frame see identical input, instead of whatever the OS
  happened to deliver between them.
* The simulation's inputs become a value that can be recorded, replayed, or eventually sent
  over a network — without redesigning anything.

Live device state is available to non-simulation code (debug tools, editor UI), and that is
fine, because those do not affect simulation outcomes.

### Key identity

Keys are identified by **physical position**, not by the character the current keyboard layout
produces. WASD must be the same three-across-plus-one-above cluster on AZERTY as on QWERTY,
and a binding saved on one layout must mean the same thing on another.

Text entry is a **separate event** carrying UTF-8, produced by the OS's input method. This is
the only correct way to handle composed characters, dead keys, and CJK input methods, none of
which can be reconstructed from key events.

Foundry defines its own key enum, based on physical position (the same model as USB HID usage
codes). It is not SDL's `SDL_Scancode` renamed — it is a smaller set covering keys Foundry
actually reports, mapped in the backend.

**These names are a compatibility surface.** Key names will appear in configuration files and
in mod-authored bindings, so per `CLAUDE.md` §7 they are named with more care than internal
identifiers and are not renamed casually.

---

## 5. Filesystem

`platform` provides **raw filesystem access only**:

* Read a file, write a file, check existence, get modification time.
* Enumerate a directory.
* Well-known base locations: executable directory, user data directory, temporary directory.
* Later, for hot reload: watch a path for changes.

**Mounts, overlays, package layering and override resolution are NOT here.** They belong to
`data` and `asset`, because they are content policy, not OS access — and because I3 requires
that the base game load through exactly the same path a mod does. Putting that logic in
`platform` would make it OS-shaped instead of content-shaped, and would be the beginning of a
privileged loading path.

### Paths

Paths are UTF-8 `[]const u8` using `/` as the separator, everywhere in the engine. Conversion
to and from the OS's native form happens **inside** the platform backend and nowhere else.

Content IDs are not paths and paths are not content IDs (I2). Whether asset IDs are
path-derived is an open decision due at M3, and this interface deliberately does not
prejudge it.

### Untrusted input

Everything the filesystem returns is untrusted (§5 of `core-memory-and-handles.md`). A missing
file, a directory where a file was expected, a truncated read and a path that escapes its
expected root are all **errors to be handled**, never assertions. Path traversal is a real
concern the moment mods can specify paths, which is why the rule is stated now rather than
retrofitted at M7.

---

## 6. Dynamic library loading

Open a library, resolve a symbol, close it. This is what native mods (Tier 3, M7) will be
loaded through, and it may also serve backend selection later.

Everything about it is untrusted: the library may be missing, may fail to load, may lack the
expected symbol, or may be built against an incompatible ABI version (I8). Every one of those
is a reported error. **Loading a native mod is a consenting-adults operation** (`CLAUDE.md`
§5) — but consenting to run someone's code is not consenting to crash on a typo in a filename.

---

## 7. Clock

`platform` provides the monotonic high-resolution clock; `core` owns the time types
(`core-memory-and-handles.md` §7). The split is what makes I9's "no wall-clock reads inside
simulation" structural: `core.time.Instant` can only be produced by `platform`, and
`platform` is not reachable from simulation code.

A wall-clock function also exists — logs need timestamps and saves need dates — and is named
so that its unsuitability for simulation is obvious at the call site, with a doc comment
saying so. It is not interchangeable with the monotonic clock and is not the same type.

---

## 8. Audio device

Not designed yet. The audio decision (own mixer versus a library) is postponed to M5, and SDL3
supplies the device either way.

What is owed *now* is only that nothing here precludes it: audio device enumeration and
callback-driven output need to fit this interface later without restructuring it. They do —
device access is a resource like a window, and the mixing that sits above it is not
`platform`'s concern.

---

## 9. The `null` platform

A headless implementation: no window, no real input, a synthetic clock.

* **It makes `app` testable.** The fixed-timestep loop, subsystem ordering and clean shutdown
  can be tested in CI without a display server.
* **It makes the interface honest.** A second implementation is what turns a set of functions
  into an interface. Every change to the interface must satisfy it.
* **Its synthetic clock advances by an exact amount per call**, which makes the fixed-timestep
  loop's behaviour reproducible in tests instead of dependent on how fast the test machine is.

Its input snapshot is scriptable, which is the seed of replay testing later — a direct payoff
of the snapshot design in §4.

---

## 10. Testing

* Conformance: the `comptime` check compiles for both the SDL3 and null implementations.
* Window: logical and pixel sizes are reported separately and both survive a resize event.
* Events: a synthetic sequence through the null backend produces the expected snapshot,
  including a press-and-release within a single frame.
* Filesystem: missing file, wrong type and traversal attempt all return errors and never
  panic.
* Clock: monotonic never decreases; the null backend's synthetic clock is exactly reproducible.
* Cross-compilation: `platform` builds for `x86_64-windows-gnu` and `x86_64-linux-gnu` every
  milestone (ADR-0008). Verified achievable during M0 setup — SDL itself cross-compiles.

---

## 11. Open questions

1. **Gamepad support timing.** SDL3 provides it well and it is tempting to expose early. Not
   needed before M5, and exposing it early risks shaping the input snapshot around SDL's
   gamepad model. Deferred, but the snapshot is designed to accept additional device state.
2. **File watching granularity.** Hot reload (M2+) needs change notification; whether that is
   per-file, per-directory or a polling fallback depends on what the OS APIs make cheap.
   Deferred until hot reload is actually built.
3. **Multiple windows.** The interface does not forbid them — windows are handles, not a
   singleton (I1) — but nothing supports them yet. The editor (M6+) is the first plausible
   consumer.
4. **Whether `platform` should own the main loop.** It should not, and does not: `app` owns
   the loop. Recorded because most platform libraries invert this, and SDL's examples do.

---

## Resolution — 2026-09-03

Implemented as `engine/src/platform/`, against Zig 0.16.0. Both backends exist: 60 tests
with the null backend, 68 with SDL3.

The design above survived contact with the compiler almost intact. Four things changed,
three of them forced by what Zig 0.16's `std` actually provides.

### The frame's event boundary is three calls, not one

§4 sketches `while (platform.pollEvent()) |ev|`. The implementation splits that into
`pumpEvents` (drain the OS queue once, at one known point), `nextEvent` (read what that
produced) and `captureInput` (freeze it into the value simulation reads). The single call
would have had to do the pumping on its first invocation, which makes "the OS queue is
drained at one known point in the frame" true only by convention. Three named calls make
the frame's shape explicit, and give the input snapshot a place to be taken that is
unambiguously *after* every event has been seen.

### `Os` was split out from `Platform`

The document treats the filesystem, dynamic library loading and the clock as part of one
platform interface. Implementation split them in two:

* **`Platform`** — window, surface, events, input, monotonic clock. Backend-specific,
  selected at build time, conformance-checked.
* **`Os`** — filesystem, base directories, dynamic libraries, wall clock. Identical under
  every backend, so it sits beside the backend seam rather than behind it.

The dividing line is *does a windowing backend change this?* A hand-written Cocoa backend
and a hand-written Win32 backend would share `os.zig` byte for byte, so putting it behind
the seam would only duplicate it — and would force the null backend to carry a fake
filesystem it has no use for. The monotonic clock stayed with `Platform` precisely because
it *does* differ: the null backend's is synthetic, which is what makes loop tests
reproducible (§9).

### The environment is an input, not something read from the air

§5 lists the user data directory as part of the interface, which in earlier Zig would have
been a `getenv` call. Zig 0.16 removed ambient environment access outright —
`std.posix.getenv`, `std.os.environ` and `std.process.getEnvVarOwned` are all gone — and
hands the environment to the process entry point instead.

So `Os.init` takes the variables it is allowed to see, and reads nothing else. This is the
better design regardless of what `std` forced: configuration read from the air is exactly
the kind of hidden input I9 objects to, and it makes the environment-dependent paths
testable without touching the real machine. Whoever owns `main` — `app`, from the next
milestone — passes them down.

### `std.Io` stops at this layer

Zig 0.16 completed its I/O migration: `std.fs` is a deprecation shim over `std.Io.Dir`,
every filesystem call takes an explicit `Io`, and `std.time.Instant` no longer exists.
`Os` owns one `std.Io.Threaded` and never lets it out, so **no `std` type appears in any
Foundry interface**. That is ADR-0001's containment argument applied to the module whose
job is owning OS specifics: when that API moves again, one file changes.

### Foundry declares the Windows dynamic loader itself

`std.DynLib` is a compile error on Windows in Zig 0.16 — its backing type resolves to a
stub whose `open` is `@compileError("unsupported platform")`, and `std.os.windows.kernel32`
has been stripped to a single binding. Verified against the pinned compiler by compiling
it, not by reading it.

Since Windows is a supported target (ADR-0008) and native mods are a fundamental feature
rather than a later addition (`CLAUDE.md` §5), waiting for `std` to fill the gap was not an
option. `library.zig` declares `LoadLibraryW`, `GetProcAddress` and `FreeLibrary` directly.
Three `extern` declarations, and `platform` is not hostage to a `std` gap.

### What the tests actually check

Beyond the per-file unit tests, four properties were verified by deliberately breaking
things and confirming the build noticed:

* **Layering (I7)** — `platform` cannot import `rhi`, and `core` cannot import `platform`.
  Both fail with *no module named X available within module 'root'*.
* **Conformance** — a backend missing a function, carrying a wrong signature, or lacking a
  `Platform` type each fails with a message naming the backend and the declaration.
* **The Windows target is really analysed** — breaking only the Win32 loader branch fails
  `zig build check -Dtarget=x86_64-windows-gnu` and no other target. Before this was
  checked, it silently passed, because the file was imported for its types and so
  contributed no tests (see below).
* **Determinism (I9)** — the same event sequence produces byte-identical snapshots, and
  the synthetic clock drives a fixed-timestep loop to the same step count every run.

### Deferred, deliberately

* **Gamepads.** Not needed before M5, and exposing them early risks shaping the input
  snapshot around SDL's gamepad model. The snapshot is designed to accept more device
  state without changing what already reads it.
* **File watching.** Hot reload needs it from M2+; what the OS makes cheap should decide
  its granularity, so it is not guessed at now.
* **IME preedit.** Committed text arrives as `text_input`; in-progress composition does
  not. Nothing needs it until there is a text field to show it in.
* **Double-click detection.** A UI concern, and the events carry enough to derive it.

---

## Resolution, part two — the SDL3 backend

Written after the interface, against it, and it needed no changes to accommodate SDL.
That is the result this document was hoping for: the interface was designed by asking
*"would this be right for hand-written Cocoa and Win32?"*, and SDL turned out to fit
inside it rather than the other way round.

**Verified live, not just compiled.** A throwaway probe opened a window under the `cocoa`
video driver and reported **logical 800x600, pixel 1600x1200, scale 2** — so §3's
insistence that these are different numbers is load-bearing on the very first machine
Foundry runs on, not a hypothetical about someone else's laptop. `SDL_Metal_CreateView`
followed by `SDL_Metal_GetLayer` produced a live `CAMetalLayer`, delivered upward as an
opaque `NativeSurfaceHandle` with no SDL or Metal type in the signature. 1500ms of real
time drove exactly 90 simulation steps at 60Hz.

**Both backends cross-compile to Windows and Linux**, SDL included, and
`scripts/check-targets.sh` now runs all six combinations. ADR-0008's "supported means
compiles" claim therefore covers the backend that actually ships, not only the headless
one.

Four things SDL does that the translation layer absorbs, so nothing above L1 sees them:

* **SDL reports a resize three ways** — `WINDOW_RESIZED`, `WINDOW_PIXEL_SIZE_CHANGED` and
  `WINDOW_DISPLAY_SCALE_CHANGED` — and one drag between monitors can produce all three.
  They collapse into Foundry's single `window_resized`, carrying both sizes, and only
  when something actually changed. Consumers react identically to all three, so telling
  them apart would be work with no payoff and a redundant swapchain rebuild as the cost.
* **SDL numbers mouse buttons left, middle, right.** Not the order the names are usually
  said in. There is a test for it, because swapping the last two is a bug that survives a
  long time — both buttons still do *something*.
* **SDL may report the wheel axes inverted** depending on OS settings, and says so in the
  event rather than normalising. Foundry's contract is fixed (positive y scrolls away
  from the user), so the sign is applied here.
* **SDL3 requires `SDL_StartTextInput` explicitly**, and without it `text_input` events
  never arrive at all. It is enabled for the window's lifetime. Per-window IME control —
  enabling it only while a text field has focus — is a UI concern that arrives with the UI
  system (M6); until then, always-on is what makes the event variant real rather than dead.

The scancode mapping has two tests that matter more than they look: every Foundry key is
reachable from some scancode, and no two scancodes map to the same key. Without the first,
a key could be bound in a config file but never pressed; without the second, one physical
key would be un-bindable and its twin would fire twice.

Surface kinds other than `metal_layer` return `SurfaceUnavailable` with a log line. SDL
can produce an `HWND` through its properties API, but there is no Windows RHI backend to
consume one and no way to test it, so it arrives with that backend.


---

## Resolution, part three — `setWindowSize`, 2026-09-04

Added while closing M1, and worth recording because it began as something deliberately *not*
done. The Metal swapchain resize path had been written for two sessions and never run: the
interface offered no way to resize a window, and driving one from outside the process needs
macOS Accessibility permission this machine does not grant. The path was therefore a claim
about code rather than about behaviour, and it was recorded as exactly that.

It was not added silently, and it was not added as a test hook. **Any game with a settings
menu needs to set its resolution**, so this is a capability the interface was missing rather
than scaffolding for a check — which is what makes it the right answer instead of a
convenient one. That it also makes the swapchain path testable is a consequence of there
being one resize path, not the justification.

What it found immediately, which is the argument for having done it: asking for 900x900
returns 900x794, because the window manager clamps to the usable display area. A design that
had treated the call as a setter would have been wrong on the first call on the first
machine it ran on.
