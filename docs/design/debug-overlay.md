# Design: the debug overlay, and the introspection underneath it

**Status:** written 2026-09-07, before implementation. M6's second and last design document.

`ui.md` designed a UI kernel and a widget set and then stopped, on the grounds that what an
inspector may ask `scene` for is a different subject with different invariants. This is that
subject: M6's remaining three roadmap bullets — the entity inspector, the content browser and
the log console; the frame profiler with per-subsystem timing and per-allocator memory
reporting; and the introspection APIs beneath all of them.

**The fourth bullet is the milestone.** The widgets are replaceable and the panels are a
weekend; the calls the panels are built on reach the public ABI at M7 and are renamed only by
breaking mods. This document is mostly about those calls, and the panels are what proves them.


## 1. What is already decided

| Decision | Where |
| --- | --- |
| Foundry writes its own immediate-mode UI; one kernel, a debug widget set now | ADR-0024, `ui.md` |
| The kernel emits a draw list and never sees a renderer; `app` walks it | ADR-0024, `ui.md` §8 |
| Capture is advisory: the kernel reports, the game holds input back | `ui.md` §4 |
| The overlay is a module above `app`, and may use no call the ABI could not expose | **ADR-0025** |
| One public API surface, opaque handles, no private back door — including the editor | I4, ADR-0004 |
| Generational handles across every subsystem boundary | I1, ADR-0005 |
| Statistics are outputs and never feed simulation | I9, `render2d.Stats` |
| Tools are Foundry applications built on the public API | ADR-0011 |
| `core` owns time's types; `platform` owns reading the clock | ADR-0007, `core-memory-and-handles.md` §7 |
| A component type **is** a schema; its serialized shape is the public one | ADR-0010, `entity-storage.md` §3 |
| An override replaces the value behind a handle; merge order is fixed | `content-schemas.md` §6 |

Two of those are load-bearing here in a way that is easy to miss.

**`core` owns time's types and `platform` owns reading the clock.** That split is what makes
I9's "no wall-clock reads inside simulation" structural: an `Instant` can only be *produced* by
`platform`, and `scene` and `physics2d` do not depend on `platform`. A profiler is a wall clock
with extra steps, so the first thing this document has to decide is whether that protection
survives contact with M6. It does — §4.

**A component type is a schema.** A component's *serialized* shape is public, described,
versioned and readable by anything holding the schema. Its *in-memory* shape is a Zig struct's
layout, which is nobody's business and is not described anywhere. An inspector that casts
component bytes to a struct works only for component types it was compiled against, which is to
say not for mods. §7 is the consequence.


## 2. The shape, in one page

```
  a game
    |
    |  engine.beginScope("simulate")   <- spans, from a caller that has a clock
    |  overlay.describe(&ui, sources)  <- one call per frame, before the game reads input
    v
  debug (L5)  ...........  panels: profiler, memory, log, entities, content
    |                      each one is ui widget calls and nothing else
    |
    +--> ui        describe a frame of widgets            (already exists)
    +--> app       spans, memory counters, the log ring, the frame index
    +--> scene     entities, component types, a component's values
    +--> data      packages, records, schemas, who overrode whom
    +--> asset     what is loaded, how many references
    +--> render2d  Stats: sprites, batches, draw calls, textures
    +--> audio     active voices, dropped commands, sounds resident
```

Four claims in that picture, each of which the rest of the document has to pay for:

1. **The overlay reads; it does not reach.** Every arrow above is a public call on a module
   `debug` depends on, and every one of them is a call a mod could be given at M7 (ADR-0025).
2. **The overlay is described, not drawn.** It is `ui` widget calls, so it inherits the kernel's
   entire testability: the overlay unit-tests with no device, no window and no frame, and a
   test asserts on the draw list rather than on pixels.
3. **The overlay never mutates what it inspects.** Not the world, not the store, not a voice.
   The one exception is deliberate and is not introspection: a button that asks the engine to
   reload content, which is the game's own `Engine.reloadContent` call and was public already.
4. **The engine collects nothing the overlay needs unless it is asked to.** The profiler, the
   counters and the log ring are all opt-in, default-on in development builds and default-off in
   release, in the same shape and for the same reason as `Config.hot_reload`.

**What the overlay is not.** It is not a framework the game hands its loop to. `app-and-frame-loop.md`
established that `Engine` is a library you drive rather than a framework that calls you back, and
the overlay is the same: the game decides when to describe it, where to put it, and what key
toggles it. The engine hardcodes no binding — `engine.zig` already refuses to intercept input on
the grounds that "what looks like an obviously engine-level key today is a game's binding
tomorrow", and an overlay that grabbed F1 would be that mistake in a new place.


## 3. What an introspection call may be

ADR-0025 states the rule; this is what it means in Zig, so that the additions in §9 can be
checked against something.

**Identity is a handle or a content ID.** `Entity`, `ComponentType`, `RecordHandle`,
`PackageHandle`, `AssetHandle`, `SchemaHandle` all exist and all cross the boundary already. A
call that returned `*const Registration` would be handing out a pointer into a live pool, which
is I1's whole objection.

**Enumeration is an iterator with a documented order, and the order is a promise.** Entities
iterate in slot-index order, which is what `save.zig` already writes and therefore what a
reloaded world already reproduces (I9). Records iterate in the store's merge order, which
`content-schemas.md` §6 pinned. A panel that sorts differently sorts a copy; the source order
never changes to suit a view.

**Borrowed data is valid for the frame.** A record's `name` points into a package's bytes and a
log line points into the ring. Both are alive now and neither is promised past `endFrame`. This
is not a new lifetime rule — it is the frame arena's rule, which everything in a frame already
lives under, and `ui.TextRef` copies what it is given into a per-frame arena of its own
precisely so a widget can safely be handed a borrow like that.

**Answers are values, not error unions, wherever a C caller would need a result code.** An
absent thing is `null`; a malformed thing is a value that says it is malformed. Errors are kept
for what they are for — allocation failure, and a serializer that refuses.

**Nothing an introspection call returns may reach simulation.** `render2d.Stats` already carries
the sentence — *"Outputs only: statistics never feed simulation (I9)"* — and it applies to every
number in this document. For the modules below `app` the layering enforces it: they cannot read
a clock, so they cannot branch on one. For the game it is a rule, exactly as it is today for
`frameDelta`.

**A call added for the overlay is added because a panel needs it**, not because it might be
useful. The list in §9 is short for that reason, and half of it already exists.


## 4. The frame profiler

The roadmap asks for "per-subsystem timing". The first question is not how to store spans; it is
**who is allowed to look at a clock**, because the answer decides everything else.

### 4.1 The clock stays above, and the layering is not perforated

The tempting design is a `Recorder` carrying a clock function pointer, handed down to every
subsystem so each can time itself. It would work, and it would quietly undo the thing ADR-0007
is repeatedly praised for: `scene` and `physics2d` have no `platform` dependency, so a
simulation cannot read a clock, so I9's fourth rule is structural rather than remembered. A
recorder with a clock inside it is a clock inside `scene` with a polite interface.

**Decision: timing is collected by the caller, at the call site.** `app` times the parts of the
frame it owns; the game times the parts it owns. A subsystem that cannot read a clock is not
asked to time itself, and nothing is handed downward.

This is not a compromise — it is the right granularity for the question M6 is asking. "Where did
the frame go?" is answered by a handful of spans around the subsystems, and every one of those
boundaries is a call the caller makes:

```
frame 41,882                     14.8 ms
  input + events                  0.2
  content watch                   0.0
  simulate                        3.1        <- the game's span
    physics                       1.9        <- the game's span, nested
  describe ui                     0.4
  render prepare                  2.2
  render record                   1.1
  submit + present                7.6        <- waiting for the display, most likely
  debug overlay                   0.3        <- the overlay's own cost, always shown
```

What it cannot answer is "which of my forty ECS systems was slow", and §15 records that as an
open question with the two honest answers, neither of which is a clock in `scene`.

### 4.2 Storage lives in `core`, and holds no clock

`core/profile.zig` gets the storage and the arithmetic; every timestamp is **handed in** by the
caller. This is exactly the split `core/time.zig` already makes, and it is why the profiler's
data structure is unit-testable with a synthetic clock and no platform at all.

```zig
pub const Span = struct {
    /// Index into the recorder's name table. Not a slice: a mod's name must outlive the
    /// call that supplied it, and interning is how that is arranged without allocating
    /// per frame.
    name: u16,
    depth: u16,
    /// Nanoseconds from the frame's start, saturating. See below for why these are not
    /// `Instant`s and why 32 bits is enough.
    begin_ns: u32,
    end_ns: u32,
};

pub const Frame = struct {
    index: u64,           // the engine's frame index, so a span lines up with a log line
    total_ns: i64,
    spans: []const Span,
    dropped: u16,         // spans that did not fit. Counted, never fatal.
};

pub const Recorder = struct {
    pub fn beginFrame(self: *Recorder, index: u64, at: Instant) void;
    pub fn open(self: *Recorder, name: []const u8, at: Instant) void;
    pub fn close(self: *Recorder, at: Instant) void;
    pub fn endFrame(self: *Recorder, at: Instant) void;

    pub fn frames(self: *const Recorder) FrameIterator;   // newest last
    pub fn latest(self: *const Recorder) ?Frame;
};
```

Four properties, each chosen against a failure the mixer taught us to expect:

* **Fixed capacity, allocated once.** A frame holds up to `max_spans` and a recorder holds
  `history` frames, both from `Config`, both allocated at `init`. Nothing in a frame allocates,
  so the profiler cannot fail in the middle of the thing it is measuring — the same property
  `audio.md` §5 required of `mix`, for the same reason.
* **Overflow is counted, not fatal.** A frame that opens more spans than fit records `dropped`
  and keeps going. A profiler that panicked on a busy frame would be a profiler that failed
  exactly when it was needed.
* **Unbalanced scopes are survivable.** A `close` with nothing open is counted and ignored; a
  frame that ends with spans open closes them at the frame boundary and counts that too. This is
  the rule `ui.md` §12 already applies to regions and clip stacks, and for the same reason: from
  M7 the caller may be a mod.
* **Names are interned, and the table is bounded.** A name is copied once, on first use, into a
  small fixed table. A span is then four fields and twelve bytes, the history is a flat array,
  and a mod's `[]const u8` does not have to outlive anything.

**Timestamps are stored relative to the frame's start**, and that is what makes them `u32`
rather than `i64`. Two absolute `Instant`s per span would be sixteen bytes of which the high
half is identical across a whole frame; two offsets are eight, and a span longer than the 4.29
seconds a `u32` of nanoseconds holds is not a measurement — it is a hang, and saturating at the
maximum says so more usefully than a wider field would. The other half of the reason is that a
frame carrying its own origin is **self-contained**: it can be summarised, plotted, compared
against another frame or written to a file without anyone needing to know when the program
started.

### 4.3 What `app` adds, and what the game calls

```zig
// app
pub fn beginScope(self: *Engine, name: []const u8) Scope;   // reads platform.now()
pub fn profiler(self: *Engine) *const core.profile.Recorder;
```

`Scope` is a two-field value with an `end()` method, so the call site is
`var s = engine.beginScope("simulate"); defer s.end();` and a scope cannot be left open by an
early return. The engine opens its own spans inside `beginFrame`, the content watcher and
`renderFrame`; everything else is the game's, and the game's spans nest inside the engine's
frame without either knowing about the other.

**The engine's spans are named once and never renamed**, because a name is what a person
recognises across builds and what a saved profile is compared against. They are: `input`,
`content`, `render.prepare`, `render.record`, `render.submit`, `render.present`.

### 4.4 What the profiler cannot see, stated plainly

**GPU time.** `renderFrame` returns after submit and the GPU is still working. Attributing time
to passes needs backend timestamps — Metal has them on the command buffer, and the RHI does not
expose anything of the kind. That is out of M6. What the CPU spans *can* honestly say is where
the CPU waited, and with vsync the wait lands in `render.present`, which is enough to separate
"we are CPU-bound in a subsystem" from "we are waiting for something else" — which is the first
question anybody diagnosing a frame actually asks. §15 records the trigger for doing better.

**Anything below `app` in finer detail than its call site.** By construction, §4.1.

**Time spent outside the frame.** A hitch caused by the OS scheduler, a page fault or a shader
compile inside a driver appears as an inflated span rather than as itself. `frameDelta` and the
sum of the spans disagreeing is the signal that this happened, and both are shown.

### 4.5 Summarising, without allocating

The panel wants min / median / p95 / max over the history window, and a plot of frame totals.
`ui.plot` already draws a caller's samples and keeps no copy, so the overlay owns a small array
of frame totals it refreshes each frame. The percentiles are computed by `core.profile.summarise`
over a caller-supplied scratch buffer — the frame arena's, in practice — because a sort needs
somewhere to put a copy and `core` is not going to allocate one behind anybody's back.


## 5. Memory, per allocator

There is no global allocator (`CLAUDE.md` §7), so there is no global to ask, and this is a place
where the discipline has a real cost that has to be paid rather than dodged: **the engine cannot
report what it does not own.** The renderer, the world and the mixer are the game's, built with
the game's allocator.

**`core.mem.Counted` is a wrapper any owner can apply.**

```zig
pub const Counted = struct {
    name: []const u8,
    child: Allocator,
    live_bytes: usize, peak_bytes: usize,
    allocations: u64, frees: u64, failures: u64,
    pub fn allocator(self: *Counted) Allocator;
};
```

It costs one indirect call and a few arithmetic operations per allocation, which is why it is
opt-in per owner rather than something `Engine` imposes. Foundry allocates in bulk and rarely —
pools, arenas, and a batcher that reuses its buffers — so a counted allocator on a subsystem is
cheap in exactly the places it is interesting.

**Counters are single-threaded, and that is a documented property rather than an omission.**
A counter is owned by whoever owns the allocator, and Foundry's second thread does not allocate:
`audio.md` made "nothing in the callback can fail" a design property, and no-allocation is half
of what that means. Making the fields atomic would cost every allocation in the engine to serve
a caller that does not exist. §15 records what a job system would change.

**The engine keeps a registry of named counters**, runtime-populated, which the overlay walks:

```zig
pub fn registerMemory(self: *Engine, counter: *core.mem.Counted) MemoryHandle;
pub fn unregisterMemory(self: *Engine, handle: MemoryHandle) void;
pub fn memory(self: *const Engine) MemoryIterator;
```

Runtime-populated on purpose (I6): a game registers its renderer's and its world's with the same
call a mod would use at M7. A registry a mod cannot add to would be a report that goes stale the
first time somebody extends the engine.

> **Revised at step 2.** This paragraph originally said *the engine registers its own — the
> store, the asset registry, the package bytes*. It does not, and cannot sensibly: the engine is
> **handed** an allocator, so wrapping one inside `init` would leave everything allocated before
> the wrapper existed — the engine struct itself among them — being freed through it, which is a
> counter that underflows on the way down. Counting the engine is the caller's choice, made by
> handing `Engine.init` an already-counted allocator, which counts every byte the engine takes
> with nothing crossing between a counted and an uncounted path. See the step 2 Resolution.

**The frame arena gets a high-water mark.** It is the single most informative number about
per-frame garbage, and it is currently invisible because `Arena.reset` in a safe build frees
everything to catch use-after-reset. `Arena` gains `highWater()`, sampled in `endFrame` *before*
the reset, which is the only moment the number exists.

**What the report shows:** per counter, live bytes, peak, allocation and free counts; the frame
arena's high-water for the last frame and the largest seen; and the totals. What it deliberately
does not show is a breakdown by call site, which needs stack capture and is §16.


## 6. The log console

`app/log_sink.zig` already carries the argument this section extends. Logging is the one piece of
genuinely ambient state in Foundry, "defensible only because logging is ambient by nature:
`std.log` reaches it from code that has no engine pointer to ask." A console needs the log lines
in memory, and the sink is the only thing that sees them, so the ring lives there and is ambient
for the same reason and under the same defence.

### 6.1 A second sink, never a replacement

Every line still goes to stderr. A crash loses the ring and does not lose the terminal, and the
terminal is what a bug report contains. The ring is *added* to `logFn`, beside the level check
that already exists and before `defaultLog`.

> **Revised at step 3.** This said the ring goes *after* the existing level check, which
> contradicts §6.3 two paragraphs later: a ring filtered by the terminal's level is a ring that
> goes quiet exactly when somebody quietens the terminal. The two destinations are decided
> independently and neither gates the other.

### 6.2 Fixed memory, no allocation, contiguous lines

```
records:  a ring of { level, scope, frame, sequence, offset, len }
text:     a byte ring, written contiguously
```

* **Formatted into a stack buffer, then copied.** `logFn` has no allocator and must not acquire
  one. A line longer than the buffer is truncated with a visible marker, because a truncated
  line is a diagnostic and a failed one is a mystery.
* **A message never straddles the end of the byte ring.** If it does not fit in the tail, the
  tail is skipped and the message starts at the beginning. That wastes a few bytes and buys the
  property the console needs: **every line is one contiguous slice**, so a substring filter
  matches against one slice and §6.5's copy is one `memcpy`. The alternative is every reader —
  the filter included — reassembling two halves.
* **Eviction is oldest-first, and drops are counted.** The console shows "N earlier lines
  dropped" rather than pretending it has the whole history.
* **The scope is stored as a static string.** `logFn` receives it as a `comptime` enum literal,
  so its name is a compile-time constant with a program-lifetime address; there is nothing to
  copy and nothing to free.
* **Each record carries the frame index**, written by `beginFrame` into an atomic the sink reads.
  It is what lets a person line a log line up against a span in §4 and against the frame the
  hitch was in, and it costs one relaxed store per frame.

### 6.3 Two levels, on purpose

The ring has **its own level**, independent of the terminal's. Quietening stderr to `err` at
three in the morning should not also blind the console you opened to find out what happened. The
cost is stated: a line that is formatted for the ring and not printed is formatting work done for
a reader who may never look, so the ring's level is configurable and defaults to the compiled
level in development builds and to `warn` in release.

### 6.4 Threading, and a rule that becomes load-bearing

The ring is guarded by a mutex. That is not a new hazard: `std.log.defaultLog` already takes a
lock to write stderr, so every logging call site already blocks on a lock today.

**The audio callback must never log**, and `audio.md` §4 already says so in as many words —
"no allocation, no lock, no logging, no filesystem, no `core.log`, no error return" — with the
honest admission that nothing enforces it. What changes here is the consequence of breaking it.
Today a stray `log.warn` in the callback would be a deadline risk through `defaultLog`'s stderr
lock; after this it is also a lock this design put there, contended by the game thread once per
frame. The rule is unchanged and now has a second reason, which is worth writing down because a
rule with one forgotten reason is a rule someone eventually relaxes.

### 6.5 What the console reads

The overlay copies the visible lines into the frame arena while holding the lock, once per frame.
That copy is bounded by what is on screen — forty lines, not forty thousand — which is only true
because of the windowing in §11, and it is the reason the console can hand slices to widgets
without the ring being free to move underneath them mid-frame.

Filtering is by level, by scope, and by substring, and the substring comes from the `textField`
that `samples/sandbox` is already drawing over a scrolling list. That panel was built at `ui.md`
step 5 as "the log console's shape"; this is the step where it stops being a shape.


## 7. The entity inspector

Three questions, in the order a person asks them: *what entities are there*, *what does this one
have*, and *what is in it*. The first two are enumeration and the third is the interesting one.

### 7.1 Enumeration, in the order the save already uses

`World` gains two iterators and nothing else:

```zig
pub fn entities(self: *const World) EntityIterator;        // slot-index order
pub fn componentTypes(self: *const World) TypeIterator;    // registration order
```

Neither is new machinery. `save.zig` already walks `world.entities.slotAt(slot)` ascending and
`world.types.iterator()`, because that is the order a save file is written in and therefore the
order a reloaded world comes back in. The inspector using the same order means **the list you
were looking at is the list that gets saved**, and it costs nothing to promise because the
promise is already kept.

"What does this entity have" is `hasComponent` over the type iterator. There are a handful of
component types and one selected entity, so a loop is the whole answer; an index from entity to
its types would be a structure to keep correct for a cost nobody is paying, which is the
reasoning `data.Store.iterate` already carries in its own comment.

### 7.2 Reading a component the way a save does

A component's bytes are a Zig struct's layout. The schema describes its *serialized* shape, and
those are different things: field order is the same, but sizes, padding and representation are
not. Casting the bytes works for a type the overlay was compiled against and produces garbage for
a mod's — which makes it not an implementation shortcut but a wrong answer that looks right for
the whole of M6 and starts lying at M7.

**Decision: the inspector reads a component by serializing it, exactly as a save would.**

```zig
/// The component's values, as a save would write them. `arena` is the frame's.
pub fn describeComponent(
    self: *World, arena: Allocator, entity: Entity, t: ComponentType,
) DescribeError!?data.fpk.Fields;
```

The implementation is the round-trip `data` already provides: a `BlockWriter` over the arena, one
`begin(schema.fields)`, the type's own `serialize`, and a `Blocks.view` back over what it wrote.
Four consequences, and three of them are gifts:

* **It works for a component type the engine has never heard of**, because the type supplied its
  own serializer at registration and that is the entire contract (ADR-0010).
* **It cannot disagree with the save**, because it is the save's path. An inspector that showed
  something a reload would not restore is a debugging tool that creates bugs.
* **It shows the schema's field names**, which are the names the author wrote and the names a mod
  overrides. Nothing has to invent a display vocabulary.
* **A type with no serializer is not inspectable**, and the inspector says so in those words.
  `Registration.savable()` already names the condition — a type that can be written and not read
  back is refused by the save for its own reasons — and the panel prints "not saved, so not
  shown" beside the type's name and size rather than an empty row. The alternative is a panel
  that silently omits exactly the component someone is hunting for.

The cost is a copy of one entity's components into the frame arena, once per frame, for the
entity that is selected. Nothing is serialized for an entity nobody is looking at.

### 7.3 Entities have no names, and the inspector does not invent one

An entity is not content and has no content ID — `save.zig`'s own header says entity identity is
slots and generations and warns off exactly the load-order-indexed identity I2 forbids. So the
inspector's list is `#index.generation` plus whatever a component says.

It would be easy and wrong to add a `foundry:name` component so the list reads nicely. M5 refused
`foundry:collider` on the grounds that a name invented now is a name every mod is stuck with from
M7, and that reasoning is not weaker here. **The game tells the inspector which component and
field to use as a label**, as configuration:

```zig
label: ?struct { type: ComponentType, field: u32 } = null,
```

Neither sample has a component with a name in it — the room's six are `transform`, `visual`,
`solid`, `animation`, `lamp` and `doorway` — so both pass nothing and both lists read
`#index.generation`, which is honest. The hook exists so that a game which *does* have a name
component is not made to choose between a readable list and an engine-owned vocabulary it will
be stuck with from M7.

### 7.4 Read-only, deliberately

The write path exists — `deserialize` from an edited block is how `spawn` already works — and it
is not being used. Editing a live component raises three questions M6 has no business answering:
whether an edit is a change to *state* or to *content* (and therefore whether it survives a
reload), what undo means, and what happens when a value is refused. Those are the editor's
questions, `CLAUDE.md` §9 puts the editor at M6+, and the mechanism will still be there.


## 8. The content browser

The store was built with introspection in it, so most of this section is a list of calls that
already exist. `packageCount`, `loadOrder`, `package`, `count`, `all`, `iterate(schema_id)`,
`get`, `provenance` and `lookup` are the browser's spine, and `Record` already carries the
authored spelling of its ID, its schema *as its own package holds it*, and the package that won.

**A hash can be shown as a name**, and that is not an accident: `.fpk` interns the source
spelling of every package, schema and record ID because "a package that can only state its own id
is a package no diagnostic can name". The browser is the payoff. A content ID with no name is a
content ID naming nothing loaded — which is itself the answer to the most common content bug, and
the browser says so rather than printing sixteen hex digits and shrugging.

**Fields are read with `Fields.valueAt` against the record's own schema**, and a field a newer
schema version added is filled from `Record.missingDefault`. That is the record as the store reads
it, defaults and all, which is what the game sees and therefore what a person debugging an
override needs — not the bytes on disk.

### 8.1 The override chain, which the store does not keep

The one thing missing is the question a mod author asks first: **who else defines this?**
`Store.Entry` is four fields written over four fields, so an override leaves no trace of the
definition it replaced, and `iterate`'s comment defends that: an index kept correct across every
override is "a cost nobody is paying yet".

It is still answerable, because nothing was thrown away. Every package's bytes are retained for
the life of the store — the store reads records in place out of them — and every package's
`Reader` can walk its own record table. So:

```zig
/// Every package that defines `id`, in load order. The last is the one that won.
pub fn definitions(self: *const Store, id: ContentId, out: []PackageHandle) []PackageHandle;
```

A linear walk of each package's record table, on demand, for one ID, when a person clicks it.
No index, no bookkeeping, no cost until it is asked — which keeps the store's existing position
intact rather than overturning it. The caller supplies the output slice, so the call allocates
nothing and a C version of it is the same signature.

### 8.2 Assets and schemas

`asset.Registry` needs one iterator over its entries — id, schema, reference count, and whether
the payload is resident — built on the `HandlePool` iterator it already uses internally in five
places. `data.Registry` needs the same over its schemas. Both are enumeration of things that are
already public individually, and both are how a browser shows what is loaded rather than what
exists.

The assets panel is where **reference counts become visible**, which is worth a sentence because
it is the first time anyone can see them. `assets.md` made zero references mean *evictable*, not
freed, and nothing evicts on a schedule; a panel that shows a texture at zero references is
showing a real answer to "why is this still in memory".

The one button in the browser is **reload content**, calling the public `Engine.reloadContent`.
It is not introspection and it is not a back door — it is the call a game already makes on a key
press, and having it under the panel that shows what is loaded is where a person looks for it.


## 9. What each subsystem gains

The whole of the "introspection APIs" bullet, in one table. **These names reach mods at M7**
(`CLAUDE.md` §7), so they are compatibility decisions and are chosen once.

| Module | Added | Why it is not already there |
| --- | --- | --- |
| `core` | `profile.Recorder`, `profile.Span`, `profile.Frame`, `profile.summarise` | Storage and arithmetic for spans; holds no clock, by §4.1 |
| `core` | `mem.Counted`, `Arena.highWater()` | Per-allocator accounting, opt-in; the arena's peak exists only before a reset |
| `platform` | **nothing** | It already has `now()`, and that is the whole of its part |
| `data` | `Registry.all()`, `Store.definitions(id, out)` | Enumeration, and the override chain §8.1 reconstructs rather than stores |
| `asset` | `Registry.assets()` | Enumeration over entries; every field of one is public already |
| `scene` | `World.liveEntities()`, `World.componentTypes()`, `World.describeComponent()` | The orders `save.zig` already uses, and the serialize round-trip of §7.2 |

> **Named at step 4.** Two of these read `entities()` and `schemas()` above, and both collide
> with a field of the very struct they hang off — `World.entities` and `Registry.schemas` are
> where the things being enumerated actually live. `liveEntities` is the better name anyway,
> since it yields only the live ones, and `all()` matches `data.Store.all`, the other
> enumeration in that module.
| `ui` | **nothing** | §11's windowing is `stateOf`, `spacer` and `beginScroll`, all shipped at step 5 |
| `render2d` | **nothing** | `Stats` was built for this from M2 |
| `audio` | **nothing** | `activeVoices`, `commandsDropped`, `soundCount` exist |
| `physics2d` | **nothing at M6** | Body and broadphase counts are wanted; nobody has needed one yet, and §3's last rule says wait |
| `app` | `beginScope`, `profiler`, `registerMemory`, `memory`, the log ring and its accessor, three `Config` fields | The frame is here, and so is the only clock above the subsystems |
| `debug` | the module | ADR-0025 |

Five modules gain nothing at all — `platform`, `ui`, `render2d`, `audio` and `physics2d`. That
is the strongest thing this table says: the subsystems were mostly built inspectable, and what is
missing is what nobody had a reader for.


## 10. The overlay: panels, input, and its own cost

### 10.1 A panel is a registration, not a case in a switch

```zig
pub const Panel = struct {
    id: ui.Id,
    title: []const u8,
    ctx: ?*anyopaque = null,
    describe: *const fn (ctx: ?*anyopaque, view: *View) anyerror!void,
    open: bool = false,
};

pub fn addPanel(self: *Overlay, panel: Panel) Allocator.Error!PanelHandle;
```

The five built-in panels register through this call at `Overlay.init`, and a game's own panel —
or a mod's at M7 — registers through the same one. This is I3's discipline in a small place: the
built-in panels are not special, so the path a third party uses is the path we are on.

It is ten lines, not a framework, and the alternative is a `switch` over an enum that a mod cannot
add a case to — which would have to be replaced by exactly this the first time somebody wanted to.

`View` is what a panel is handed: the `ui.Context` to describe into, the frame arena, and const
access to the sources the overlay was given. A panel that wants something the `View` does not
carry is a panel asking for a call that does not exist yet, which is the conversation ADR-0025
wants to force.

### 10.2 The game drives it

```zig
pub fn describe(self: *Overlay, ui_ctx: *ui.Context, sources: Sources) !void;
```

One call, once per frame, from the game, before it reads its own input — which is where
`samples/sandbox` and `samples/room` already put their `describeUi`, and for the reason `ui.md`
step 6 nailed down: capture is advisory, so the game can only hold an input back if the overlay
has already been described when the game looks.

`Sources` is a struct of optional pointers: `?*const data.Store`, `?*asset.Registry`,
`?*scene.World`, `?*const render2d.Renderer`, `?*const audio.Mixer`, and the `*Engine`. A game
with no world passes no world and the entity panel says so instead of not existing — a panel that
vanishes is indistinguishable from a panel nobody wrote.

**The overlay declares no key.** The game toggles it. `Engine` refuses to intercept input for the
same reason and says so in its own comment; an overlay that grabbed F1 would be making that
mistake one layer up, and in a mod-friendly engine the binding is content anyway.

### 10.3 The overlay's own cost is on the overlay

Two numbers, both always visible when the profiler panel is open:

* **A span named `debug.overlay`**, so the cost of describing the panels is inside the profile
  they are drawing, not hidden beside it.
* **The batch count**, which is already in `render2d.Stats` and is the number this overlay is
  known to inflate. `ui.md` recorded it twice while the widget set was being built — six batches
  for the hand-drawn HUD, ten once the overlay existed, **fifteen** by the end of step 5 — with
  the same suspected cause each time and no measurement behind it: panel rectangles come from the
  blank texture and labels come from the font atlas, so every alternation between them is a
  texture break and a new batch. The candidate fix, packing the blank patch into the font's
  atlas so both come from one texture, is a `render2d` change worth making *after* the number
  exists rather than before (rule 2), and until then nine extra batches are a suspicion with a
  number attached to it rather than a diagnosis.

That second one is not a footnote. **M6's exit criterion is that a performance problem can be
diagnosed from inside the running game**, and the overlay's own batch cost is a real problem, of
the right size, already written down, with a plausible cause nobody has confirmed. Diagnosing it
with the tool is a better closing argument than any synthetic case.


## 11. Long lists, and the culling question `ui.md` left open

`ui.md` §14 recorded culling as an open question and refused to answer it: a scrolling list of ten
thousand log lines emits ten thousand text commands of which forty are visible, and *"the honest
answer needs the profiler M6 is building, and guessing at it now would be optimising before
measuring"*. It also said the kernel could do it, since the kernel knows the clip rectangle.

The inspector and the console are the case that exists, and the answer is not in the kernel.

**The caller emits only the visible rows**, because the caller is the only one that knows a row
is a row. `beginScroll` keeps the scroll offset in `stateOf(id)`, which the caller can read
*before* it opens the region:

```zig
const scroll = ctx.stateOf(list_id).scroll;          // last frame's, which is this frame's
const first  = @intFromFloat(scroll / row_height);
const count  = visible_rows + 1;
try ui.beginScroll(ctx, list_id, bounds, row_height * total);
ui.spacer(ctx, row_height * first);                  // the rows above, as one gap
// ... describe `count` rows ...
ui.spacer(ctx, row_height * (total - first - count));
try ui.endScroll(ctx);
```

Three reasons this is the right seam rather than a kernel feature:

* **The kernel would have to guess a row's height** to know which rows to skip, and it cannot: a
  region's contents are arbitrary widgets and a "row" is a fiction the caller maintains. It could
  only skip commands *after* they were built, which saves the draw and not the formatting — and
  for a log console the formatting is the cost.
* **The caller skips the work, not just the drawing.** Ten thousand rows that are never formatted,
  never measured and never copied into the arena. Kernel-side culling could not reach any of that.
* **It needs nothing new.** `stateOf`, `spacer` and `beginScroll` all exist and shipped at step 5.

So `ui.md` §14's culling question is answered by a caller-side convention and the kernel stays
dumb — which is the answer that document would have preferred, and the answer is written beside
the question there rather than left open. What the kernel may still want one day is a cheap reject of
commands entirely outside the clip rectangle, for the case where the caller genuinely cannot know;
that case has still not appeared.


## 12. Errors

The overlay is handed live subsystems and reads them while a game runs, so its failure modes are
"the thing I was showing went away" rather than "the input was malformed". Four rules:

* **A stale handle is `null`, never a crash.** The selected entity can be destroyed by a system
  the frame after it was selected, the selected asset can be evicted, and a package can be
  replaced by a hot reload. Every panel re-resolves what it is showing from a handle each frame
  and falls back to "gone" — the same discipline `assets.md` gives a handle across a reload.
* **A serializer that refuses is a line of text.** `describeComponent` can fail, because a mod
  wrote the serializer. The panel prints the error's name against the component and moves on to
  the next one. A tool that dies on the broken thing is useless at precisely the moment it is
  needed.
* **Nothing here asserts on data.** `CLAUDE.md` §7 draws the line at "programmer error" versus
  "invalid external input", and everything the overlay reads is on the far side of that line —
  content, component values, mod-registered types. `core.assert` is for the overlay's own
  invariants, of which there are almost none.
* **The overlay allocates from the frame arena and from nowhere else** during a frame. Its
  fixed state — the panel list, the filter buffers, the frame-total ring — is allocated at `init`.
  A tool that can run out of memory while diagnosing an out-of-memory problem is a bad tool.

**Content generation.** Anything the overlay derived from content — a record's name, a schema's
field names — is derived again when `Engine.contentGeneration()` moves, which is the one signal
`app-and-frame-loop.md` §8 says a game needs. In practice the overlay derives nothing across
frames and this is free; the rule is stated so that a panel which starts caching knows what it
has taken on.


## 13. Testing

**Everything in this document is headless**, and that is inherited rather than arranged. The UI
kernel needs no device, no window and no frame (`ui.md` §11); `scene`, `data` and `asset` are
already hermetic; the profiler's storage takes its timestamps as arguments, so a test drives it
with a synthetic clock and asserts exact nanoseconds.

What gets tested, by layer:

* **`core.profile`** — spans nest and close in order; an unbalanced `close` is counted and
  ignored; a frame that overflows records `dropped` and keeps the spans that fit; the history
  ring wraps and the oldest frame is the one lost; `summarise` returns the right percentiles for a
  known set, including the degenerate one-sample and all-equal cases.
* **`core.mem.Counted`** — live bytes follow a known alloc/free/resize sequence exactly; peak
  survives the frees that follow it; a failing child allocator increments `failures` and does not
  corrupt the live count. `Arena.highWater` reports the largest reset-to-reset peak, in both safe
  and release reset modes, which is the one place the two modes differ.
* **`app`'s log ring** — a line longer than the buffer is truncated with its marker; a message
  that will not fit in the tail starts at the beginning and is still one contiguous slice; the
  oldest record is evicted first and the drop count is right; the ring's level is independent of
  the terminal's; the frame stamp on a record is the frame it was logged in.
* **`scene`** — `entities()` yields exactly the live entities in slot order and agrees with what
  a save writes; `describeComponent` round-trips every field type through a registered component;
  a type with no serializer reports why rather than returning an empty block; a destroyed entity
  is not yielded and its handle describes as `null`.
* **`data`** — `definitions` returns every package defining an id, in load order, with the winner
  last; a package that does not define it is absent; the answer is unchanged by iteration order.
* **`debug`** — the panels, described into a `ui.Context` with no device, asserting on the draw
  list: the entity panel lists the entities of a world built in the test; the component values
  shown are the values that were set; the content panel names a record by its authored spelling;
  the console shows only lines passing the filter; the windowed list emits a bounded number of
  text commands for a ten-thousand row source, which is §11's claim as an assertion.

That last one is the test this design is proudest of: **"a ten-thousand line log does not emit ten
thousand draw commands" is checkable with no window open.**

`engine/tests/` gains one integration test — a headless engine with content, a world and an
overlay, run for a few frames, asserting that a frame's spans sum to something sane, that the log
ring caught the lines the run produced, and that the panels describe without error. It is the
shape of `sound_pipeline.zig`, for the same reason: the parts are unit-tested, and what the
integration test proves is that they are wired to each other.


## 14. What this exposes to mods

`CLAUDE.md` §5 requires this section even when the answer is "nothing". Here it is most of the
document, because ADR-0025 made "what a mod could be given" the design constraint on every call.

**Exposed at M7**, and shaped for it from the first line of code:

* **Enumeration and reading** — entities, component types, a component's values, packages,
  records, schemas, assets and their reference counts. All read-only, all handle-addressed, all
  in a documented order.
* **Timing** — open and close a named scope. A mod's script that wants to know what its own
  systems cost gets the same recorder the engine's spans go into, and its names are interned
  beside ours.
* **Memory** — register a named counter, and read the report. A mod that allocates and does not
  appear in the memory panel is a mod nobody can diagnose.
* **The log** — write to it (already true through `std.log`) and read the ring back. Reading is
  what lets a mod's own console exist.
* **Panels** — `addPanel` with a context pointer and a function pointer. A mod adds a panel to
  the same overlay through the same call, which is the whole reason §10.1 is a registry.

**Not exposed:** the recorder's internal arrays, the ring's memory, the panel list itself, and any
pointer into a subsystem's storage. The pattern is the one `ui.md` §13 already set — a consumer
describes and reads; it does not get the container.

**The deliberate asymmetry**, recorded so it is a decision: **a mod cannot write.** No editing a
component, no destroying an entity, no unloading an asset through these calls. That is not a
permanent position — a script mod that cannot change anything is not much of a mod, and Tier 2
will have a mutation surface — but the mutation surface is the *gameplay* API, designed when the
ABI is, and it is not going to be reached through the inspector's back door. §7.4 refuses the
same thing to the engine's own overlay, which is what makes it a rule rather than a restriction.


## 15. Open questions

* **GPU timing.** The profiler is CPU-only (§4.4). Metal exposes command-buffer GPU start and end
  times and the RHI exposes nothing of the kind; doing it properly means a timestamp facility in
  `rhi` that each backend owes a version of, which is a `rhi.md` change and a second backend's
  problem too. **The trigger:** when the CPU spans say the frame is mostly waiting and nobody can
  say what the GPU was doing. Not before.
* **Per-system timing inside `scene`.** A world with forty systems will eventually want to know
  which one is slow, and §4.1 refuses to put a clock in `scene` to find out. The two honest
  answers are a sampling profiler (which needs a signal handler or a second thread, and is a
  project) or a caller-driven schedule where the game runs the systems it cares about itself and
  times its own calls (which is a change to how `World.update` is used, not to what it can see).
  Neither is M6, and the choice should be made by whoever actually has the slow world.
* **Threading.** The memory counters are single-threaded and the profiler's recorder is
  single-threaded, both because Foundry has one thread that allocates. A job system (`CLAUDE.md`
  §9, and overdue for re-dating) changes that: counters would need atomics or per-thread
  shadows, and the profiler would need a recorder per worker plus a merge. **Recorded now so that
  the job system's design knows it owes this**, and deliberately not paid for in advance.
* **Persisting a profile.** Writing a frame's spans to a file — for comparing two builds, or for
  attaching to a bug report — is obviously wanted and needs a format, which means a version
  (I8). It is small, and it is not M6.
* **Whether the overlay should be able to pause and single-step the simulation.** It is the most
  useful debugging control there is and it is a mutation, so §7.4's reasoning applies: the
  stepper is `Engine`'s, a pause is a public engine call rather than an overlay trick, and the
  question of what a paused frame does to the mixer and to hot reload deserves more than a
  checkbox. First thing the editor will want.
* **Whether panels should remember their state across runs.** Which panels were open, where they
  were, what the filter said. It needs a place to write per-user settings, which `platform` has
  (the user data directory) and nothing yet uses. Small, real, and not needed to diagnose
  anything.
* **A crash dump of the log ring.** The ring is lost on a crash, which is when it would be most
  valuable. Writing it out from a panic handler is a `platform` question with real hazards and no
  current answer.


## 16. Deliberately not here

A flame graph, which needs a widget the set does not have and a lot of screen. Allocation call-stack
capture. Remote or networked profiling. Triggering a GPU frame capture from the overlay. Editing
anything — entities, content, assets, style. Docking, floating or resizable panels (`ui.md` §15
already refused those and nothing here changes the argument). A save-state diff view. Console
commands. A crash reporter. Hot-reloading the overlay itself.

Each is real; several are the editor's, and the editor is M6+ by `CLAUDE.md` §9. None of them is
blocked by anything above.


## 17. Implementation order

Six steps, each ending in something that runs and something that is tested. The order is chosen
so that the profiler exists before the things whose cost is in question, and so that the module
that composes everything is built last, when everything it composes is already testable.

1. **The profiler's storage, and the engine's own spans.** `core/profile.zig` — recorder, span,
   frame ring, name table, `summarise` — with a synthetic clock in its tests and no platform.
   Then `Engine.beginScope`/`profiler`, the six engine-named spans, and the `Config` field.
   *Runnable:* `samples/sandbox` plots the frame total and lists the engine's spans using widgets
   that already exist, so the first step draws a real profile with no new UI code.

2. **Memory: counted allocators and the arena's high-water.** `core.mem.Counted`,
   `Arena.highWater()`, the engine's counter registry, and the engine wrapping its own store,
   asset registry and package bytes. *Runnable:* the sandbox's panel gains live and peak bytes per
   subsystem, and the frame arena's high-water — which is the first time anyone can see what a
   frame allocates.

3. **The log ring.** `app/log_sink.zig` gains the record and byte rings, the frame stamp, its own
   level, drop counting and the `Config` fields. *Runnable:* the sandbox's second panel — built at
   `ui.md` step 5 as "the log console's shape" over a list of key bindings — is pointed at the
   ring and becomes an actual log console, with the filter box it already has.

4. **Introspection in the subsystems.** `scene`'s two iterators and `describeComponent`; `data`'s
   `schemas()` and `definitions()`; `asset`'s `assets()`. Every one of them tested in its own
   module, headless, with the stable orders asserted rather than assumed. *Runnable:* nothing new
   on screen, and that is correct — this is the step whose output is an API, and the next step is
   its first consumer.

5. **The `debug` module and its five panels.** The module, `Overlay`, `Panel`, `View`, `Sources`,
   the panel registry, the windowed list convention of §11, and the profiler, memory, log, entity
   and content panels. *Runnable:* the sandbox replaces its hand-built panels with the overlay,
   and deletes the hand-built ones. Tested by describing every panel into a context with no
   device.

6. **`samples/room` adopts it, and the exit criterion is met by using it.** The room gets the
   overlay behind a key, which proves the second consumer needs no engine change — the same test
   `ui.md` step 6 applied to capture. Then the criterion itself: **diagnose the overlay's own
   batch cost with the overlay**, confirm or refute that panel rectangles and glyphs coming from
   two textures is what inflates the batch count, and write down which it was. A milestone about
   diagnosing a performance problem should close by diagnosing one that was already written down
   and not yet understood.

Each step's Resolution goes at the end of this document, as `ui.md` and every design document
before it does: what implementation settled, and what this document said wrong.


---

## Resolution: the profiler's storage and the engine's spans (step 1, 2026-09-07)

`engine/src/core/profile.zig`, `Config.profiler`, `Engine.beginScope`/`profiler`, the engine's
own spans in `beginFrame`, `endFrame` and `renderFrame`, and the sandbox reading all of it.
**926 tests**, up from 900: 21 in `core.profile` and 5 in `app`, every one of them headless and
driven by a clock the test hands in.

**§4.3 named six engine spans and there are seven.** The missing one is `render.acquire`, and
where it sits is the point: the document assumed a vsynced frame waits in `render.present`, and
on Metal it does not. `Device.beginFrame` both waits on the command buffer that last used this
ring slot *and* asks the layer for the next drawable, which is what blocks; `endFrame` only
schedules the present and commits. A profile built on the document's six spans would have shown
the wait as time that vanished between frames. It is closed explicitly on its error path too,
unlike the three after it, because `SurfaceLost` is the *routine* answer for a minimised window
rather than a fault, and a span left open on every minimised frame would be noise rather than a
signal.

**The profiler perturbs a synthetic clock, and this is not a small footnote.** The null
backend's clock advances by a fixed step *per reading* — deliberately, so a headless loop runs
identically on every machine — so a profiler that read it freely changes how much simulated time
a frame carries. It showed up immediately as an existing test failing: a thousand frames that
should produce 60 simulation steps produced 304. Three things came out of it, and the first is
an improvement the design did not ask for:

* **Clock readings are shared where the frame already makes one.** The `input` span now closes
  on the very instant `frameDelta` is computed from, rather than reading the clock again a line
  later. This is `frameDelta`'s own argument — *"a second clock read would give a second,
  slightly different answer"* — and applying it leaves a profiled frame reading the clock three
  times instead of five.
* **The test helper turns the profiler off**, for the same class of reason it forces `headless`:
  a test measuring the loop should measure the loop. The tests that want the profiler use a
  second helper and say so.
* **The sandbox turns it off when headless.** The headless run is the deterministic one, and it
  does not get an observer that moves the thing it observes. A windowed build reads a real
  monotonic clock, where a reading costs time but does not create it.

**A dropped span's `close` must not close the span underneath it**, and that took two mechanisms
rather than one. A span dropped because the frame's budget is full still pushes a **sentinel**
onto the open stack, so its `close` pops the sentinel instead of its parent; an `open` deeper
than the stack itself cannot push at all, so those are counted in a separate overflow depth that
`close` unwinds first. Both are correct only because nesting is LIFO, and both have a test named
after the bug they prevent — without the sentinel, an `outer` span that ran 890µs reports 10µs
and nothing anywhere says why.

**§4.2's size argument was wrong and was corrected before any code was written.** It claimed
absolute `Instant`s would cost sixteen bytes against relative offsets' eight; two `i64` offsets
are also sixteen. What relative offsets actually buy is that 32 bits is *enough* — a span longer
than the 4.29 seconds a `u32` of nanoseconds holds is a hang rather than a measurement, and
saturating says so — which takes a span to twelve bytes and makes a frame self-contained.

**The first profile raised a suspicion and then killed it, which is the whole point.** Four
hundred frames of the windowed sandbox, 4,603 sprites, debug build:

```
frame 239 spent 11.44ms: input 0.05  describe ui 0.24  simulate 1.42  step 1.42
  audio 0.00  submit 2.37  render.acquire 0.02  render.prepare 7.24
  render.record 0.06  render.submit 0.02  render.present 0.01
```

`render.acquire` is two hundredths of a millisecond, so this build is **not** waiting for the
display, and `render.prepare` — the batcher's sort and its vertex upload — is 63% of the frame on
its own. That reads like a finding. It is not one. The same run, `-Doptimize=ReleaseFast`:

```
last 240 frames: median 8.37ms, p95 9.57ms, max 9.88ms
frame 299 at 8.43ms went mostly to: render.acquire 6.88ms, render.prepare 1.07ms,
  render.record 0.15ms
```

**`render.prepare` collapses from 4.4ms to 1.07ms and the frame becomes 82% waiting for the
display.** The optimised sandbox is display-bound at about 120Hz with the CPU idle most of the
frame; the debug build's dominant cost was the debug build. A profiler that only ran in the mode
where everything is slow would have sent somebody to optimise a sort that was never the problem —
which is why the exit summary logs at `info`, since `core.log.compiled_level` drops `debug` in
exactly the build whose numbers are worth reading.

The spans also sum to the frame: 11.49 against a measured 11.44, with `step` nested inside
`simulate` and therefore not double-counted. That agreement is the cheapest possible check that
the spans are in the right places, and it is the one to run first after moving any of them.


---

## Resolution: counted allocators and the arena's high-water (step 2, 2026-09-07)

`core.mem.Counted`, `Arena.highWater()`, `Engine.registerMemory`/`unregisterMemory`/`memory` and
`frameArenaHighWater`, and the sandbox reporting two counters and the arena in its panel and at
exit. **935 tests**, up from 926.

**§5 had the engine wrapping its own allocator, and it cannot.** The engine does not own the
allocator it is handed, and a wrapper created inside `init` would arrive *after* the engine
struct and its content paths had already allocated through the raw one — so the frees on the way
down would subtract bytes the counter never added. Saturating subtraction would hide it and lie.
What works instead is one line at the call site:

```zig
var engine_memory = core.mem.Counted.init("engine", gpa);
const engine = try app.Engine.init(engine_memory.allocator(), .{ ... });
_ = try engine.registerMemory(&engine_memory);
```

Every byte the engine takes, including its own struct, goes through the counter, and the test
that pins it asserts `live_bytes` returns to **exactly zero** after `deinit` with `allocations ==
frees`. This is the better answer for the reason §5 was written around in the first place: there
is no global allocator, so the owner of one is the only one who can answer for it — and the
engine's owner is `main`, not the engine.

**Counting revealed which allocator a shared container actually belongs to.** `samples/sandbox`
passed *its* allocator into `engine.assets.registerLoader`, `acquire` and `unregisterLoader`,
which grow containers the engine's registry owns. Memory-wise that was harmless — both counters
forward to the same child — but the attribution crossed: bytes allocated under `sample` and
freed under `engine`. Foundry's per-call allocator style (`CLAUDE.md` §7) makes ownership
implicit exactly where two owners meet, and a counter is what makes it visible. The fix is to
pass `engine.gpa` at those call sites, and it had a pleasing side effect: `reacquire` lost its
last use of `self` and became a free function, because once the allocator belonged to the engine
there was nothing of the sample's left in it.

**The report explained a thirteen-fold difference between two builds on its first run.**

```
headless (-Drhi=null)   engine 5,534 KiB live    sample 1,356 KiB live
windowed (-Drhi=metal)  engine   401 KiB live    sample 1,356 KiB live
```

The null RHI backend allocates real CPU storage for every buffer — it models what Metal hands to
the GPU, which is the whole reason it can validate a command stream — so the renderer's vertex
and staging buffers are five megabytes of host memory in a headless build and nearly none in a
Metal one. **The sample's number is identical in both**, which is the cross-check that the
attribution is right rather than merely plausible: the sample's allocations do not depend on the
backend, and the counters agree.

**The frame arena's high-water mark is zero, and that is the right answer.** Nothing calls
`engine.frameAllocator()` — the UI kernel keeps an arena of its own (counted under `sample`,
because the sample built it) and everything else formats into stack buffers. The engine's frame
arena is available and unused, and the panel says so rather than hiding a zero. `highWater`
samples `queryCapacity` *before* the reset, which is the only moment the number exists in a safe
build, and it means slightly different things in the two reset modes — the worst single frame
under `free_all`, the largest the arena ever grew under `retain_capacity` — which are the same
high-water mark reached from opposite sides.


---

## Resolution: the log ring (step 3, 2026-09-07)

`app/log_sink.zig` grows a statically-sized ring, its own level, a frame stamp and a reader;
`Config.log_capture` turns it on; `samples/sandbox`'s second panel stops being the log console's
*shape* and becomes one. **943 tests**, up from 935.

**§6.1 contradicted §6.3 and the implementation had to pick one.** "The ring is added after the
level check that already exists" makes the ring a slave to the terminal's verbosity, which is
precisely what §6.3 forbids two paragraphs later. `logFn` now decides the two destinations
independently and returns early only when neither wants the line. The section is corrected in
place.

**The ring is statically sized, and that follows from what it is.** An ambient thing has no owner
to hand it an allocator — the same argument `log_sink` already made for the runtime level being
the one piece of genuinely ambient state in Foundry — so the capacities are constants (64 KiB of
text, 1,024 records, 512 bytes a line) rather than `Config` fields. Nothing here allocates, which
was the requirement; what changed is that it does not need to.

**`std.Io.Mutex` needs an `Io` and there is nowhere to get one.** Zig 0.16 made locking an `Io`
operation, the same move `std.fs` and `std.Thread.sleep` made, and `logFn` is the one place in
Foundry with no instance to ask. The ring is guarded by a five-line spin lock instead. That is
defensible because contention is essentially zero — the writer is the game thread, the reader is
the game thread once a frame, and the engine's one other thread is forbidden from logging — and
because the critical section is a `memcpy` and some arithmetic. **What would change it** is a
second thread that legitimately logs: a job system's workers, at which point there will be an
`Io` to hand a real mutex.

**Two bugs, both found by a test that had to be made stricter afterwards.**

The first: the "keep nothing" sentinel is `0xff`, and severity is ordered *most-severe-first*, so
`level <= 0xff` is true for every level — capture-off captured everything. There is no `u8` below
`err` for an off state to live at, so the sentinel has to be excluded explicitly rather than
compared against.

The second is the one worth remembering. `reserve` returns the offset a line is written at, and
its empty-ring branch returned zero **without advancing the head**. Every line then landed at
offset zero, each overwriting the last, and the older records' slices quietly began reading the
newer one's bytes — so a filter for "played" matched two lines when only one contained it. The
existing test walked every record and checked its *shape* (a colon, then nothing but `z`), and an
overwritten line still has that shape. It now parses each line's own index and asserts they are
consecutive and end where the run ended, which is a test of identity rather than of form.

**The console is §11's windowing convention's first user, and the case it was written for.** The
ring holds up to a thousand lines and six are on screen: the caller reads
`stateOf(list_id).scroll` *before* `beginScroll`, asks the ring for exactly the window it will
draw, and emits two `spacer`s for the rest. Ten thousand lines would cost two spacers and six
labels.

**It also gave step 2's instrument its first reading.** The frame arena's high-water mark was
zero after step 2 because nothing called `engine.frameAllocator()`; the console copies its
visible lines into it under the lock, and the number is now 396 bytes headless and 696 windowed.
The engine's allocation count went from 222 to 1,422 over a 600-frame run for the same reason,
which is per-frame arena traffic being visible rather than a leak — `live_bytes` is unchanged.

**And the panel kept its contents by losing its copy of them.** It listed the sample's key
bindings from a hardcoded array; it now lists them because `main` *logs* them at startup and the
console reads the ring. `matchesFilter` was deleted with the array's reader, and the sample is
one fewer place where a key map can go stale.


---

## Resolution: the introspection calls (step 4, 2026-09-07)

`World.liveEntities`, `World.componentTypes` and `World.describeComponent`; `data.Registry.all`
and `Store.definitions`; `asset.Registry.assets`. **951 tests**, up from 943, and **nothing new
on screen** — which is what §17 said this step's output would be, since its output is an API and
step 5 is its first consumer.

**Two of the five names collided with the field they enumerate.** `World.entities` and
`data.Registry.schemas` are where the entities and the schemas actually live, so a method cannot
share the name. `liveEntities` is the better name regardless — it yields the live ones and skips
free slots, which is a promise worth making in the name — and `all()` matches `data.Store.all`,
the other enumeration in that module. §9's table is corrected.

**`describeComponent` compiled with a field that does not exist.** It read
`self.limits.max_list_elements`, and `scene.Limits` has no such field: it has `max_entities`,
`max_component_types` and `max_systems`. `zig build check` passed anyway, because Zig analyses a
function body only when something reaches it and nothing called this one yet. This is the hazard
`PROJECT_STATE.md` already records under "lazy analysis makes negative tests lie", met from the
other direction — **a green check on code that cannot compile** — and the only defence is the
one that caught it: a test that calls the thing. The limit was wrong to reach for in any case,
and the bound is now `data`'s default with a sentence saying why: these bytes were produced a
line earlier by the type's own serializer, so a list bound is a formality here rather than the
defence it is on input from a file.

**Three calls became `*const World` on the way through.** `hasComponent` and `componentCount`
did not need a mutable world and only took one because `storeFor` returns a mutable store; a
`storeOf` beside it made all three of the new calls read-only in the type system as well as in
fact. Widening like this is safe — a `*World` still coerces — and it is worth doing, because
"everything introspection does is a read" is a claim the compiler can hold rather than a
sentence in a document.

**The override chain cost nothing to add**, which is the part of §8.1 that had to be checked
rather than argued. `definitions` walks each package's own record table on demand, for one id,
into a caller's buffer: no index, no bookkeeping, no allocation, and no cost until somebody
clicks. The test asserts the shape a mod author actually wants — both packages, in load order,
winner last, agreeing with `provenance` — and that an id nobody defines is an **empty slice**
rather than an error, because a content id with no definitions is the answer to the most common
content bug.

**`data.Registry.Entry` carries no name, and that is a real finding for the browser.** A schema
knows its id and its version and not its spelling: the spelling lives in the packages that carry
it, because that is where somebody wrote it down. A schema browser therefore has to ask the store
for a name, which §8's "a hash can be shown as a name" already depends on — it is just true one
level further down than that paragraph implies.

**The asset listing made reference counts visible for the first time.** `assets.md` made zero
references mean *evictable, not freed*, and nothing evicts on a schedule; until now nobody could
see the state. The test walks an asset from two references to zero to evicted, and the middle
step — resident, resolving, referenced by nobody — is the answer to "why is this still in
memory" that no existing call could give.


---

## Resolution: the `debug` module and its five panels (step 5, 2026-09-07)

`engine/src/debug/` — `Overlay`, `Panel`, `View`, `Frame`, `Sources`, the panel registry,
§11's windowing convention and the profiler, memory, log, entity and content panels — plus
`samples/sandbox` deleting its hand-built ones and registering one of its own through
`addPanel`. **974 tests**, up from 951: 23 in `debug` and one integration test in
`engine/tests/debug_overlay.zig`.

**ADR-0025's dependency list was three modules too long, and the ADR's own rule is what
trimmed it.** `platform` and `rhi` were listed and neither was needed: the overlay reads the
*engine's answers* rather than the devices underneath them — `app.Engine` owns the window and
the device, `render2d.Stats` is a value, and no signature in the module names a platform or
graphics type. With `physics2d` already excluded for the same reason, three of the original
eleven are absent because `build.zig`'s rule says a dependency a module does not use is a
claim the build cannot check. The ADR carries a dated revision note; it was written before any
code depended on it, which is exactly the window §8 of `CLAUDE.md` allows one in.

**§10.2's `Sources` had two answers to "which store", and the fix is a rule.** It listed
`?*const data.Store` and `?*asset.Registry` beside the `*Engine` — but the engine *has* a
store and an asset registry, so a content panel handed both would have had to pick one.
`Sources` now carries exactly what the engine does **not** own: the world, the renderer and
the mixer, which is precisely the set `app.Engine` has no field for and the set `build.zig`
already says a game owns. It is a shorter struct and a sentence rather than a convention.

**Panels are handed a `Frame`, not the engine, and that turned out to be the important
decision in the module.** A panel written against a snapshot of public answers is a panel that
ports to M7 by changing where the snapshot comes from, which is the claim ADR-0025 makes in
Consequences and could otherwise only assert. Three things fell out of it that the design did
not predict:

* **Every panel is non-generic**, so the five of them read as ordinary code rather than as
  `fn PanelOf(comptime E: type) type`. Only `Overlay.describe` is generic, and it is generic
  the way `Engine.renderFrame`'s recorder already is — `anytype`, because the engine is
  generic over its platform and its device and a test drives a headless one.
* **Every panel test needs no engine at all.** A test builds a `Frame` by hand and asserts on
  the draw list; `debug`'s unit tests open no window, touch no device and construct no engine,
  which is a stronger version of the headlessness §13 asked for.
* **`Engine.reloadContent` became a bound pointer pair** — a context and a function — because
  a non-generic `Frame` cannot hold a method. That is six lines, and it is *literally* the
  shape the ABI will hand a mod at M7, arrived at by the type system rather than by intent.

**`beginScroll` places itself where it is told and never moves the cursor**, which is a real
trap and had already been fallen into. The console at `ui.md` step 5 read
`region().remaining()`, opened a scroll region over it, and then described its footer — at a
cursor the scroll had not advanced, so the footer drew on top of the list's first row. Every
list in this module reserves its area with `region().take(height)` first. The kernel is right
not to advance: `beginScroll` takes an explicit rectangle precisely so a caller can put one
anywhere. But "takes a rectangle" and "is placed by the layout" are different contracts and
the call reads like the second.

**The log ring is only reachable when the *root* source file installs `std_options`.** A
`debug` unit test's root is `debug/root.zig`, so `std.log` in one of its tests goes to the
default handler and never reaches the ring — the console tests would have passed vacuously if
they had asserted the wrong way round. They write through `app.log_sink.logFn` instead, which
is the same call the installed hook makes. `engine/tests/root.zig` *did* gain
`pub const std_options = app.std_options;`, because an integration test binary is a root and a
game's is too: the point of that test is that a running engine's own lines land in the ring the
console reads.

**Two numbers came out of the first windowed run, and one of them is step 6's whole subject.**
Five panels open, 4,908 sprites, `-Drhi=metal -Doptimize=Debug`:

```
frame 239 spent 7.69ms: input 0.01  describe ui 0.21  debug.overlay 0.21
  simulate 0.00  audio 0.00  submit 0.97  render.acquire 3.42  render.prepare 3.05
  render.record 0.02  render.submit 0.01  render.present 0.00
```

* **`debug.overlay` is 0.21ms**, and it is *inside* `describe ui` rather than beside it — the
  overlay's own cost is in the profile it is drawing, which is §10.3's requirement met rather
  than asserted. Describing five panels is 2.7% of a debug frame.
* **31 batches**, against six for the hand-drawn HUD and fifteen at the end of `ui` step 5.
  The suspicion is still the one `ui.md` recorded twice — panel rectangles come from the blank
  texture and glyphs from the font atlas, so every alternation is a texture break — and it is
  still a suspicion. **Step 6 diagnoses it with the overlay**, which is what M6's exit
  criterion asks for and why the number was left alone here.

**The frame arena finally has a real user.** Step 2 measured its high-water at zero, step 3
took it to 696 bytes, and the overlay takes it to **11,802**: every formatted line, the memory
snapshot and each inspected component's fields are the frame's and are thrown away with it.
That is the arena working as designed rather than growth to worry about — `live_bytes` is
unchanged and the number resets every frame.

**The sandbox kept its controls by registering a panel**, which is the part of §10.1 that
needed demonstrating rather than arguing. `follow`, the zoom slider and the player's position
are the game's, not the overlay's; they now arrive through the same `addPanel` a mod calls at
M7, with a `*anyopaque` context that is the sample's own struct. Nothing in `debug` knows the
difference between that panel and the five built-in ones, which is I3's discipline in a small
place.

**One thing this step did not fix and should not have.** `zig build check -Drhi=metal` fails to
compile `app`'s *test* binary — `NothingRecorder.prepare` names `rhi.CommandBuffer`, which is
Metal's under that flag, while `TestEngine` is built on the null device. It fails identically
at the commit before this one, so it predates the overlay; it is recorded in
`PROJECT_STATE.md` rather than repaired here, because a milestone's steps are not the place to
fix a neighbouring module's test wiring.
