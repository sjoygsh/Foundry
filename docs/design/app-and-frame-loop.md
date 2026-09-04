# Design: `app` — the engine loop and what owns what

**Status:** Implemented 2026-09-03 as `engine/src/app/`. 25 tests. Gained the content
subsystem at M3 step 9 (§8), which is where package zero is loaded.
**Date:** 2026-09-03, revised 2026-09-05
**Implements:** I3, I9 · **Informed by:** ADR-0007, ADR-0011, ADR-0021,
`core-memory-and-handles.md`, `platform-interface.md`, `assets.md`

`app` is layer L4. It depends on every module below it and nothing depends on it except
games, samples, tools, and eventually `abi` (L5).

It is short by design. `app` owns the **shape of a frame** and the **order subsystems come
up and go down** — and almost nothing else. Every structural decision here is one that
every future subsystem must fit into, which is the only reason a document this small is
worth writing.

---

## 1. A library, not a framework

**`Engine` is a thing you initialise and drive. It does not call you back.**

```zig
var engine = try app.Engine.init(gpa, .{ .window = .{ .title = "Sandbox" } });
defer engine.deinit();

while (!engine.shouldQuit()) {
    engine.beginFrame();
    while (engine.nextEvent()) |ev| { ... }
    while (engine.nextStep()) |step| { ...simulate with step.input... }
    // ...render, interpolated by engine.alpha()...
    engine.endFrame();
}
```

The alternative — `app.run(.{ .update = myUpdate, .render = myRender })` — was rejected:

* **Tools are Foundry applications** (ADR-0011), and an editor's loop is not a game's loop.
  A framework has to grow a configuration knob for every application shape that does not
  fit; a library has to grow nothing.
* **It inverts control**, which is the same objection `platform` already raised against
  event callbacks: engine code running at arbitrary points inside someone else's loop
  makes the ordering of state changes a property of the framework rather than of the
  program, and I9 is about not depending on that.
* **It is the reversible direction.** A `run` helper over a library is a dozen lines and
  can be added the moment a real use for it appears. A library extracted from a framework
  is a rewrite of every game's entry point.

## 2. The frame

Four phases, in this order, and the order is the point:

| Phase | What happens |
| --- | --- |
| `beginFrame` | Pump the OS once. Handle engine-level events. Capture the input snapshot. Read the clock and feed the accumulator. |
| `nextEvent` | The caller drains events the engine did not consume itself. |
| `nextStep` | Zero or more fixed simulation steps, each carrying the **same** input snapshot. |
| `endFrame` | Reset the frame arena. Advance the frame counter. |

**Input is captured once, in `beginFrame`, before any step runs.** Two steps in one frame
therefore see identical input rather than whatever the OS delivered between them — the
requirement `platform`'s snapshot design exists to serve (I9). A step never reaches the
device; it is handed a value.

**The clock is read once per frame**, in `beginFrame`, and the delta feeds
`core.time.FixedStepper`. Simulation time is the stepper's integer tick count, never the
wall clock and never a float accumulator.

**`alpha()` is for the render only.** It is how far the next step has progressed, for
interpolating what is drawn between two simulation states. Feeding it back into simulation
state would make the simulation depend on frame timing, which is precisely what the fixed
step exists to prevent.

### Events the engine consumes itself

`quit_requested` and `window_closed` set the quit flag; the event is still passed on, because
a game may want to show a "save first?" dialog rather than exit. Nothing else is intercepted.
The engine deliberately does **not** filter input events: what looks like an obviously
engine-level concern today (a debug overlay's key) is a game's binding tomorrow.

## 3. Lifecycle and ownership

`Engine` owns its subsystems as fields, brought up in dependency order and torn down in
**strictly reverse order**. `platform` comes up first and goes down last, and no platform
resource may require another subsystem to still be alive in order to be destroyed.

For M0 that is two objects — `platform.Os` and `platform.Platform` — so the ordering is
expressed as explicit fields and an explicit `deinit`, not as a registry. A registry of
lifecycle callbacks is the right answer at perhaps six subsystems; at two it is machinery
guarding nothing. **Revisit when `rhi`, `asset` and `scene` have joined**, which is also
when the ordering stops being obvious by inspection.

*As of M3 step 9 it is five: `Os`, `Platform`, the RHI device, and the content pair (schema
registry, store) with the asset registry over them. Still obvious by inspection, and the
open question above stands.*

**One ordering rule is not the engine's to enforce, and it is worth naming.** The asset
registry unloads through the loaders it was given, and the game owns the module that
registered one. So a game tearing down its renderer calls `assets.unregisterLoader` first,
which hands every payload back while there is still something to hand it to. `app` cannot
check this: it has no `render2d` and no idea who registered what.

Allocators follow `core-memory-and-handles.md` §1: the caller supplies the persistent
allocator, and `Engine` owns **one frame arena**, exposed as `frameAllocator()` and reset in
`endFrame`. Nothing allocated from it may outlive the frame. In safe builds the arena
releases to its child allocator on reset rather than retaining, so a pointer kept across a
frame boundary presents as a use-after-free at the point of use instead of as corruption
much later.

## 4. Configuration

`Config` is a plain struct with defaults, passed by value. There is no config *file* yet:
reading one is a content concern, it needs the authoring format that ADR-0006 postpones to
M3, and user settings are an M9 item. Until then a game writes its configuration in Zig,
which is honest about where the values come from.

The environment is part of `Config`, because Zig 0.16 hands the process environment to the
entry point and `app` is what owns the entry point. `app.environment` marshals it — the one
place in Foundry a `std.process.Init` appears.

### Content is not configuration

`Config.content` is a list of packages **in load order**, and `Config.content_dir` says
where they are. That is the whole of it. The engine consumes an order and does not compute
one: discovering packages, resolving dependencies between them and deciding what a player
has enabled is M7 (`content-schemas.md` §11), and answering it in a config struct would be
answering it in the wrong place.

## 5. Logging

`app` installs the log sink, resolving what `core.log` deliberately left open: `core` defines
the interface and the compile-time levels, and the application decides where the output goes.
A game wires it up with one line, `pub const std_options = app.std_options;`.

The sink adds a **runtime** level filter over `core.log`'s compile-time one. The two are not
redundant: the compile-time level decides what is *built* (and a disabled call never even
constructs its argument tuple), while the runtime level lets a shipped build be made quiet or
verbose without recompiling.

Deferred, with reasons: **timestamps** (they want a monotonic source, which lives on
`Platform`, and a free logging function has no instance to ask — worth solving when there is
a log *file* to correlate, at M9); **runtime scope filtering** (`std.Options.log_scope_levels`
already covers the compile-time case, and there are two scopes so far); **a destination other
than stderr** (M9, with packaging and crash diagnostics).

## 6. Testing

The null platform backend is what makes any of this testable. Its synthetic clock advances by
an exact amount per reading, so a loop test measures the loop rather than the machine, and its
event queue is scriptable, so "does a quit event actually stop the loop" is a unit test rather
than something you check by hand.

Every property worth asserting about the frame is a property about *values*: how many steps a
given sequence of frame times produces, that every step in a frame saw the same input, that
the arena is empty again after `endFrame`.

## 7. Open questions

1. **When the lifecycle becomes a registry.** See §3. The trigger is subsystem count, and
   the risk of waiting is that ordering bugs get harder to see, not that they get worse.
2. **Where the render step is expressed.** M0 has no renderer, so `alpha()` is currently a
   number nobody consumes. When `render2d` exists, whether interpolation is the engine's job
   or the renderer's is a real question, and answering it now would be guessing.
3. **Whether `app` should own a job system.** Postponed with the threading model
   (`CLAUDE.md` §9). The frame phases above are deliberately expressed as an order of
   *stages* rather than as a single-threaded call sequence, so that parallelism inside a
   stage does not require re-shaping the loop.

---

## 8. Content, and where package zero comes from

*Added at M3 step 9.*

The engine holds three things above `platform`: a schema registry, a merged store, and the
asset registry over both. At `init` it registers the record types it can load, then loads
every configured package in order and mounts each one's files.

**That code is deliberately unremarkable, and its being unremarkable is the point.**
Package zero goes through `store.add` exactly as a mod's package does — same reader, same
validation, same merge, same registry — because the only durable way to know the mod path
works is to be standing on it (I3). There is no branch anywhere that asks whether a package
is the base game.

### Where content lives

`<prefix>/content`, beside the executable rather than beside the working directory: a game
is launched from anywhere and its content is part of its installation. `zig build` installs
exactly that shape —

```
zig-out/
  bin/sandbox
  content/
    core.fpk      content/core compiled by fpack
    core/         its files, because an asset record names where its bytes are
    sandbox.fpk   samples/sandbox/content compiled the same way
    sandbox/
```

A package's `file` and `root` are **locations, never identity** (ADR-0021). The compiled
package states its own content id and the store checks it; the stem under `content/` is how
a launcher finds the bytes and nothing else depends on it.

### What the game supplies

The loaders. `app` has no `render2d` and no opinion about what a texture is, so a game
registers `render2d.textureLoader(&renderer)` into `engine.assets` at startup. The
dependency points down and the capability points up, which is what I6's runtime
registration is for — and is why the engine can own an asset registry without owning a
renderer.

### Failure

A configured package that cannot be read or is refused stops `init` with
`error.ContentUnavailable`, naming it. Package zero missing is not a state a game carries on
from, and neither is a mod the player asked for: half a load order is not a state worth
being able to describe, which is the same judgement `store.add` makes one level down.

Those failures are logged at `warn` and returned as an error — the convention the asset
registry already follows, where the returned error is the signal and the log line is the
context. It also keeps them testable: the test runner counts an `err`-level log as a failed
test, so a failure path that logs at `err` is a failure path nothing can exercise.
