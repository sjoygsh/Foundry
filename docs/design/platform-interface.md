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

**M13 Step 2, implemented 2026-09-14** ([vulkan.md](vulkan.md) §4, ADR-0037): the three
native kinds carry platform-owned payloads — `Win32Window` (`hinstance`, `hwnd`),
`XlibWindow` (`display` and a pointer-width `window` ID) and `WaylandSurface` (`display`,
`surface`) — read through `NativeSurfaceHandle.win32()`, `xlib()` and `wayland()`. The outer
tagged pointer and Metal's meaning are unchanged. `native_window` was appended as a
request-only kind: a window opened with it reports the concrete kind the running window
system provides, and an explicit request naming a different window system is
`SurfaceUnavailable` before any window exists. The SDL3 backend reads SDL's window properties
once, refuses an incomplete set, and keeps the payload in its own allocation, because pool
slots move as the pool grows; the payload stays valid until the window closes. SDL is never
asked for a Vulkan window, so it never loads the loader `rhi` owns, and no SDL or graphics
type crosses the seam. The null backend refuses every native kind.

**M13 Step 8, implemented 2026-09-18** ([vulkan.md](vulkan.md) §9): M10's deferred window
icon is `setWindowIcon(window, WindowIcon)`. A `WindowIcon` is 8-bit RGBA with straight alpha,
rows top to bottom, a stride and a byte slice, borrowed for the call alone. Its sides are
bounded to 1–256, its stride must cover a row and fit a signed 32-bit pitch, and its bytes
must cover every row; anything else is `InvalidWindowIcon`, reported rather than asserted,
because the image comes from a package. The SDL3 backend wraps the bytes in a surface that SDL
converts into its own copy before returning. A window system that cannot take an application
icon is `WindowIconRefused`, and the window keeps its default. The null backend validates and
records the size it accepted. `app.Engine.setWindowIcon` forwards to the window, or only
validates when headless. The engine supplies no default mark, reads no icon file and decodes no
image in this layer: each sample decodes its own through an asset kind it declares, and the C
mod API gains nothing, because the icon is host window configuration.

A window asks for the surface the selected graphics backend presents to through
`app.window_surface` (`rhi.window_surface`): `metal_layer` for Metal, the request-only
`native_window` for Vulkan, and `none` for the validation backend. No sample names a graphics
API to choose it.

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

**M11 correction, implemented at Step 8, 2026-09-13:** [hardening.md](hardening.md) §10.
Ordinary `Os.readFile` opens once, classifies that same handle and returns `WrongFileKind`
for a directory. Its read remains bounded after classification, ordinary symlinks still
follow, and confined reads retain their stricter component-by-component refusal. The dated
Resolution at the end records the evidence.

`platform` provides **raw filesystem access only**:

* Read a file, write a file, replace a file atomically, check existence, get modification
  time.
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

### Confined reads, and confined writes — added M9 step 1, 2026-09-12

Two operations take a **root** the host supplies and a path relative to it, and open every
component below that root with symlink following disabled: `readFileConfined`, which `asset`
uses for package files, and `replaceFileConfined`, which writes one.

A replacement creates an exclusively named temporary sibling, writes it, flushes it to the
device and renames it over the destination. Three properties follow, and all three are the
reason it exists rather than `writeFile`. Nothing truncates the old file, so every failure
before the rename leaves the previous bytes exactly as they were. The destination is replaced
as a *name*, so a symlink sitting there is overwritten rather than followed to whatever it
points at — which is what a user-writable directory requires. And the result says whether the
directory entry was flushed, because once the rename has happened there is nothing left to roll
back and a weaker guarantee is not a failed write (`distribution.md` §6).

`platform` still owns no policy about *what* is written. Deciding when a preference is dirty,
what a settings file contains and whether one may be replaced at all belongs to `app`
(ADR-0031); this is the primitive underneath it.

### One file at a time, and whether it is a program — added M9 step 4, 2026-09-12

`writeFileMode` takes a `FileMode` of `regular` or `executable`, and `FileInfo` reports whether
a file has the bit. Two values rather than a permission number, because the only thing above
this layer has an opinion about is that one file: a release stages a program the operating
system will be asked to run, and a program written as ordinary data does not run. The first
staged release found this the expensive way — "permission denied" from a path that plainly
exists looks nothing like its cause. Everything finer — owners, groups, read-only — belongs to
whoever installs a file, not to whoever writes it, and `FileMode.has_bit` is false on Windows,
where asking for one is not an error and is not a change either.

### Appending, and exclusive creation — added M9 step 6, 2026-09-12

`createAppendConfined` opens a file for appending under a host-supplied root, **creating it
exclusively**. That single choice does three jobs: it refuses a symlink at the name without
testing for one, it makes two processes racing for the same name resolve without a lock — one
wins, the other tries the next name — and it turns "is this name taken?" into the answer the
caller wanted rather than an error worth logging, which is why `AlreadyExists` is its own
member of `FileError` and is the one outcome that stays quiet.

There is no atomicity here, deliberately. `replaceFileConfined` exists so a settings file is
never half-written; a log is the opposite case — its value is that the lines written before a
crash survive it (`distribution.md` §10).

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

**A system library is opened by name, from the system's own location only** (M13 Step 2,
ADR-0038). `Library.openSystem`, reached as `Os.openSystemLibrary`, takes a bare file name and
refuses anything that could name a location. On Windows it searches `System32` alone, for the
library and its imports, so a same-named DLL planted beside the executable — the ordinary
loader's first stop — is never loaded; a Windows test plants one and checks both searches.
On Linux and macOS the name goes to the C runtime's `dlopen` and the system loader's own
policy; a Linux build that links no libc refuses. Native mods keep `open`, by explicit path.
`platform` names no library itself: `rhi` supplies `vulkan-1.dll` or `libvulkan.so.1`.

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

**Designed 2026-09-05, in [`audio.md`](audio.md) §3.** ADR-0023 settled the question this
section was holding open — Foundry mixes its own audio, and `platform` owns the device — and
what was written here in anticipation turned out to be right: device access is a resource like
a window, it needed no restructuring to fit, and the mixing above it is not `platform`'s
concern.

Four functions (`openAudio`, `closeAudio`, `audioInfo`, `setAudioPaused`), a handle rather
than a singleton because an output device is closed and reopened in normal use, and a
device-owned thread calling a callback that Foundry must treat as a real-time context. The
null backend's device is **stepped rather than threaded** — the same role its synthetic clock
plays in §9, for the same reason.

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
* Native windows (M13): `zig build native-window-test` opens real windows through SDL3 on
  Windows or Linux and checks the concrete kind, explicit-kind refusal, payload stability
  through pool growth and resize, stale handles and out-of-memory cleanup. It needs a desktop
  session, so it is not part of `zig build test`; on macOS it checks only the refusal.

---

## 11. Open questions

1. **Gamepad support timing.** SDL3 provides it well and it is tempting to expose early. Not
   needed before M5, and exposing it early risks shaping the input snapshot around SDL's
   gamepad model. Deferred, but the snapshot is designed to accept additional device state.
2. **File watching granularity.** Hot reload (M2+) needs change notification; whether that is
   per-file, per-directory or a polling fallback depends on what the OS APIs make cheap.
   Deferred until hot reload is actually built.
3. **Multiple windows.** The interface does not forbid them — windows are handles, not a
   singleton (I1) — but nothing supports them yet. The editor (M15) is the first plausible
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

---

## Resolution, part four — ordinary file-kind errors, 2026-09-13

`Os.readFile` used `Dir.readFileAlloc` for relative paths and a separate open/read helper for
absolute ones. On macOS both could open a directory, then discover only at the read that it was
not a file; the broad standard-library error consequently collapsed to `IoFailed`. The fix is
one shared sequence: open the requested path once with classification permitted, stat that
handle, require `.file`, and read from it through the caller's limit. There is no path-level
check followed by a second open, so the result cannot describe an object other than the one
whose bytes would have been returned.

The stat is useful for file kind and an early oversized refusal, but it is not authority for
the final size. The bounded reader remains in force and catches a file that grows after the
stat. Every path closes its handle; allocation failure frees partial bytes. Ordinary opening
retains the standard follow-symlink behavior, while the already-implemented confined walk
continues to refuse links below its root.

Tests require the exact `WrongFileKind` result for the same temporary directory through both
absolute and relative paths, exercise `OutOfMemory` followed by a successful reopen, and prove
that an ordinary symlink read succeeds where the confined read and stat reject it. Removing
the kind guard failed the exact-error test on macOS; the restored implementation and the
Linux/Windows compile checks pass. No interface declaration, file authority or write path
changed.
