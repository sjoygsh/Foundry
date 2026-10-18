# Design: M27 — Background work: a task graph, assets that load without stalling a frame, and the editor's background compile

**Status:** Accepted 2026-10-18, when the owner asked for Step 1, with §14 as written (including item 1: `FoundryApi_v7` in M27, so M48 publishes v8). **Steps 1–9 of 11 are done**; their Resolutions follow §16.
**Date:** 2026-10-18
**Baseline:** `8182188`, tag `m26`. M0–M26 are complete, and with them Phase 5.
**Decisions:**
- ADR-0036 (explicit, chunked, order-independent jobs) is the model this extends. Its
  decision 2 says there is no task graph and no background job; M27 is the consumer its
  "Revisit if" named ("a consumer needs work that outlives a call, most likely background
  asset loading").
- ADR-0013 (determinism), ADR-0021 (asset identity), ADR-0026 (the host supplies
  subsystems), ADR-0042/0043 (authoring through the public API, explicit builds) and ADR-0053
  (assets are not the renderer) constrain it.
- It proposes [ADR-0061](../adr/0061-background-tasks-beside-the-frame.md): background work
  is a small task graph run by a second, separate pool. Its completions reach the main thread
  only at a frame boundary, and only presentation state may depend on when they arrive. This
  amends ADR-0036's decision 2.
- It proposes [ADR-0062](../adr/0062-assets-load-in-two-phases.md): an asset loader may split
  into a pure `decode`, run on a background thread, and a `finish` on the main thread that
  touches the device. `acquire` stays synchronous.

M27 spans `core`, `platform`, `asset`, `app`, `render2d`, `render3d`, `audio`, `author`,
`abi`, the editor and `sandbox3d`, so it has its own document, and this is it.
`jobs-and-threading.md`, `assets.md` and `editor.md` point here.

## 1. Purpose and boundary

M27 is the first milestone of Phase 6, "a complete game toolkit". `docs/ROADMAP.md` gives it
one line: *"A task graph and background jobs over `core.Jobs`; assets load without stalling a
frame; also the editor's background compile."* No parent design allocated it a row, so this
section supplies the contract the roadmap line leaves implicit.

- **Runnable result:** `sandbox3d` can load a gallery of large textures while its tour walks.
  The walker never stutters and the gallery appears when it is ready. In the editor, Build
  runs while the window keeps drawing and accepting edits, and the build appears when it is
  done. Both run on macOS/Metal and Windows/Vulkan.
- **Exit condition:** two parts.
  - Frames: in the measured runs of §12, no frame's work exceeds 16.67 ms while the gallery
    loads in the background, and `assets.pump` stays at or under 2.0 ms at p95. The same
    gallery loaded synchronously must exceed 16.67 ms in one frame; otherwise the proof proves
    nothing.
  - Results: a background load and a synchronous one produce the same bytes, and so do a
    background build and a synchronous one. Every existing determinism test passes unchanged,
    and the tour's pinned hashes do not move.

**What M27 builds:**
1. `core.tasks`: a task interface shaped like `core.Jobs`, a small graph of background and
   main-thread nodes, an inline executor and a test executor that completes in any chosen
   order (§3);
2. `platform.Background`: a second, separate pool of threads for work that outlives a frame,
   created by `app` beside the frame pool, with a thread-safe counted allocator (§4);
3. the determinism rule for background work: arrival is presentation (§5);
4. two-phase asset loading in `asset.Registry`: `request`, `pump`, per-asset state,
   background reloads, and `quiesce` before the store changes (§6);
5. a `decode` phase for every engine loader that does real CPU work (§7);
6. `render3d.Content.requestModel`, with a model drawn only once every part is resident, and
   the overlay's view of pending work (§8);
7. background validate and build in `author`, published as `FoundryApi_v7`, and the editor's
   client using them (§9, §10);
8. `sandbox3d`'s gallery (§11).

**What M27 does not build**, each with the milestone that owns it:
- Asynchronous acquisition for mods, `asset_acquire` with a pending state, and jobs for native
  mods: M48's table. A mod's `asset_acquire` stays synchronous (§6.6).
- Level and scene streaming around a point, and unloading by distance: M60.
- Streamed music and compressed audio decoded while playing: M30.
- Texture streaming by mip level and compressed formats: M93.
- Runtime-created meshes, materials and textures: M28. M27 gives them the finish path they will
  use.
- A render thread, multi-threaded recording and thread priority or QoS: M99.
- Parallel system scheduling: M100.
- The court and `room` change nothing visible. They gain the pump through `app`, and every
  existing synchronous call keeps its meaning.

## 2. What exists

Read from the code at `8182188`.

- **`core.jobs`** (`engine/src/core/jobs.zig`): `Jobs` is a pointer and a one-function table,
  `run(count, task)`, plus `forChunks`, `serial` and `reversed`. It is fork-join only: every
  call joins before it returns, so outside a call no engine state is shared (ADR-0036).
- **`platform.Workers`** (`platform/workers.zig`): the frame pool. It has a fixed size and
  defaults to one fewer than the logical CPUs. Workers park on an `std.Io` mutex and two
  conditions. One dispatcher at a time is asserted, and a nested split runs inline. `Os` creates
  it (`startWorkers`), `app.Engine` owns it, and `engine.jobs()` hands it out.
- **`Os`** (`platform/os.zig`) owns one `std.Io.Threaded` and never lets it out.
  `readFileConfined` keeps no state between calls beyond that `Io`.
- **`core.mem.Counted`** asserts in Debug builds that only the thread which first used it
  allocates through it (M12 Step 2). Nothing a background thread does may go through one.
- **`asset.Registry`** (`asset/registry.zig`) is synchronous throughout. `acquire`,
  `acquireOf` and `acquireWith` look up the record, read the source through
  `Os.readFileConfined`, then call `Loader.load`, which decodes and creates the payload in one
  call. `reloadChanged` compares stamps and reloads in place. An entry is keyed by (content ID,
  loader), and `Payload` is one opaque word. `assets.md` §9's second open question has said
  since M2 that "everything here is synchronous", and that the job system would decide it.
- **Loaders** that do real CPU work:
  - `render2d.textureLoader` and `render3d.textureLoader`: PNG decode, then
    `asset.mips.generate` inside `Renderer.createTexture`;
  - `render3d.meshLoader`: `asset.mesh_file.read` validates, then `createMesh` copies streams
    into staging buffers;
  - `asset.skeletonLoader`, `animationLoader`, `collisionMeshLoader` and `tilegridLoader`:
    parse and validate;
  - the mixer's `soundLoader`: WAV decode;
  - the script `SourceLoader`: text only.
- **The RHI does not block on submission.** `CommandBuffer.submit` commits on Metal and calls
  `vkQueueSubmit2` on Vulkan, and neither waits. `Renderer.createTexture` records its own
  one-off command buffer per texture. A load's cost on the main thread is therefore the read,
  the decode, the mips and the staging copies: CPU work that can move.
- **`render3d.Content`** (`render3d/content.zig`) resolves a `foundry:model` and acquires each
  mesh, texture, skeleton and clip synchronously. A material is rebuilt whenever its texture's
  current payload changes, which is the mechanism §8 reuses.
- **`app.Engine.beginFrame`** runs hot reload's check: a notification from `platform.watch`
  (M26 Step 11), or the timer. That is where the pump goes.
- **`author.build`** (`author/build.zig`) validates and builds synchronously. It creates a
  candidate, copies the saved inputs, compiles them with the one compiler, validates the load
  order and the store, then publishes a build handle. `editor.md` §8 says "M15 adds no compiler
  subprocess, background job queue or build tool; synchronous bounded compilation is
  sufficient". §12 there lists background compile among the first editor's limitations.
- **The editor's client** (`tools/editor/client/root.zig`) calls `author_build` and
  `author_validate` through the table on its frame. While a build runs, no frame is drawn.
- **`FoundryApi_v6`** is frozen at 261 calls (M25). Results are codes. Out-parameters are
  written only on `FOUNDRY_OK`, and refusals are `FOUNDRY_ERR_REFUSED`.
- **The samples' own content is small.** `sandbox3d`'s largest file is 21 KB, and the court's
  is an 87 KB WAV. No frame stalls on loading today, which is why §11 adds a workload that
  would.

## 3. `core.tasks`: the interface and the graph (`core`, L0)

### 3.1 Why `core`, and why beside `core.Jobs`

`asset`, `render3d` and `author` cannot see `platform`'s threads; `asset` sees `platform` but
must not own threads. So, as with `core.Jobs`, they are handed a capability. `core` holds the
interface, the graph and two executors without threads. `platform` holds the one with threads
(§4). `core` gains no thread.

Background work is not a kind of `core.Jobs`. A fork-join call promises to return having run
everything. Background work promises the opposite, so it has its own interface. A background
task never calls `forChunks` on the frame pool: the frame pool asserts a single dispatcher, and
a decode that waits for frame workers would hold back the frame it exists to protect. A task
is handed `core.jobs.serial` if it needs a `Jobs` at all.

### 3.2 The interface

```zig
pub const Tasks = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Runs `task.call(task.context)` once, later, on some thread, and then sets `done`
        /// (release). Never blocks the caller for the task's duration. May refuse with
        /// `error.Full`, and the caller retries at its next poll.
        start: *const fn (ptr: *anyopaque, task: Task, done: *Done) StartError!void,
        /// Blocks until every task started through this executor has set its flag.
        /// For teardown and `quiesce` only, never on a frame's path.
        wait: *const fn (ptr: *anyopaque) void,
    };
};

pub const Task = struct { context: *anyopaque, call: *const fn (*anyopaque) void };
pub const Done = struct { value: std.atomic.Value(bool) = .init(false) };
```

There are three executors:
- **`core.tasks.inline`** runs the task inside `start` and sets the flag. It is the default
  everywhere: code handed nothing behaves as it does today, synchronously and in order.
- **`core.tasks.Manual`**, for tests, holds started tasks until the test calls `runNext`,
  `runLast` or `runAt(i)`. A test can then force any completion order, and hold a task "not
  yet" across as many polls as it likes, on one thread. It is the counterpart of
  `core.jobs.reversed`: an order dependence becomes an ordinary failing test, not a race to
  wait for.
- **`platform.Background`** has the threads (§4).

### 3.3 The graph

`core.tasks.Graph` is a small, caller-owned set of nodes:

- **Capacity is fixed when it is made**, and adding a node allocates nothing.
- **Each node is `background` or `main`.** A background node's call runs through `Tasks`. A
  main node's call runs on the thread that polls.
- **A node names its prerequisites by index, and only nodes added before it,** so a graph is
  acyclic by construction, with no cycle check to get wrong.
- **All bookkeeping is on the polling thread.** `poll()` does the work:
  - it starts each background node whose prerequisites are done;
  - it runs each ready main node, in ascending node index;
  - it reports `.pending`, `.done` or `.failed`.

  A worker writes only its own node's output and its `Done` flag. So the graph needs no lock,
  and a node's output is read only after its flag is seen (acquire).
- **A node may fail.** It records an error in its own slot. The first failure by node index is
  the graph's, and the nodes that depend on it are skipped.
- **Cancellation is cooperative and safe.** `cancel()` stops new nodes from starting. A running
  node still finishes, and its output is handed to the node's `discard` at the next poll. A
  graph is freed only when `idle()`, so no worker ever writes into freed memory.
- **A poll may be bounded.** `poll(budget)` passes each main node a `Budget` it may charge
  (bytes, for uploads). Once the budget is spent, the remaining ready main nodes wait for the
  next poll. That is how §6.4 bounds a frame.

**Why a graph, and why this small.** The two consumers have the same shape. An asset is a read
and decode in the background followed by a finish on the main thread. A model joins on all its
parts' finishes before its materials are built and it is marked drawable (§8). A build is a
snapshot on the main thread, then a compile and a validation in the background, then a publish
on the main thread (§9). Prerequisites, two kinds of node and cancellation cover all three.
Priorities, futures that return values to arbitrary waiters, work stealing between graphs and
fibers are not needed by either. Building them would be designing against a guess (CLAUDE.md
§2, rules 7 and 14).

### 3.4 What a background node may touch

| A background node may | It may not |
| --- | --- |
| Read memory that nothing writes until its flag is seen | Read anything the main thread may change meanwhile |
| Write its own node's output | Call the RHI, a window, input, audio, a script or the ABI |
| Allocate through the thread-safe allocator it is handed (§4.3) | Allocate through a `core.mem.Counted` or a frame arena |
| Read files through `Os.readFileConfined` and `statFileConfined` | Use any other `Os` call, or `Os`'s `Io` |
| Call pure functions, log and assert | Touch a world, the store, the registry or `Content` |
| Return an error into its slot | Observe a clock to decide its output, or a global RNG |

Logging from a background node is allowed: the sink is safe from any thread (M12).

## 4. `platform.Background`: a second pool (`platform`, L1)

### 4.1 Separate from the frame pool

The frame pool must be idle between `forChunks` calls, and its join waits for the slowest
chunk. If background decodes ran on the same threads, a frame's join would sometimes wait
behind a 30 ms PNG. That is exactly the stall M27 removes. So `platform.Background` is its own
fixed set of threads, in its own file, `platform/background.zig`. Like `workers.zig`, it is the
only file that names `std.Thread` and `std.Io`'s synchronization for its pool.

- **Its queue is bounded and first in, first out.** `start` refuses with `error.Full` beyond its
  capacity, and the graph retries at its next poll. Starting allocates nothing.
- **Size:** `app.Config.background_workers: ?u16`. Null is the engine's default, and `0` makes
  `engine.tasks()` the inline executor. **Until Step 9 measures otherwise, the default is two**,
  or one on a machine with four logical CPUs or fewer. Background threads compete with the
  frame pool for cores. Step 9 sweeps 1, 2 and 4 on the gallery and records the default it
  chooses and why.
- **Priority is not lowered in M27.** Thread priority and QoS are M99's. If Step 9's sweep shows
  background decoding slowing the frame's own spans on either platform, the frame budget fails,
  and that is a finding this design must answer before it closes, not a reason to reach into
  M99.
- **Teardown** marks the queue closed, waits for running tasks and joins. The engine stops this
  pool after the registry and the author service are gone, because both may have work in
  flight.
- **A panic in a task is a panic in the process**, as on the frame pool.

### 4.2 The engine's part

`app.Engine` creates the pool at `init`, after `Os` and the frame pool, and returns it as
`engine.tasks()`. As with `engine.jobs()`, the engine owns no world or renderer (ADR-0026), so
the game hands `engine.tasks()` to what it owns. The engine's own registry is the exception
because the engine owns it, and it is handed the pool at `init`.

### 4.3 A thread-safe counted allocator

`core.mem.Counted` stays single-threaded, and its Debug owner check stays. M27 adds
`core.mem.SharedCounted`: the same counters, kept in atomics, with no owner check. The engine
makes one over its own `gpa`, registers it with the overlay's memory list as
`background`, and returns it as `engine.taskAllocator()`. Background nodes allocate through
it. A decoded result is freed through the same allocator by its `finish` or `discard`, on the
main thread. Its counts at shutdown show any leak.

This requires the engine's `gpa` to be thread-safe whenever `background_workers` is not zero.
Zig's `DebugAllocator` and `smp_allocator` are thread-safe in their default configuration.
Step 2 checks every sample's `gpa` and records it. `Engine.init` cannot check this, so it is
documented on `Config.background_workers`.

## 5. Determinism: arrival is presentation

ADR-0036 made parallel work deterministic by construction: the same chunks, combined in the
same order. Background work cannot be made deterministic that way. *When* a decode finishes
depends on the machine, the disk and the other processes, so the frame on which an asset
becomes ready differs between runs. M27 does not pretend otherwise. **It confines the
difference instead (ADR-0061):**

1. **What a completed task produces is deterministic.** A decode is a pure function of the
   record and the source bytes (§3.4). A background load and a synchronous one therefore make
   the same payload, and Step 5 tests exactly that.
2. **When it arrives is presentation only.** Whether an asset is ready may decide what is
   *drawn* or *heard*, such as a gallery not yet visible or a placeholder. It must never reach
   simulation: no system, collision, rule or save may branch on readiness. This is I9's "no
   wall-clock reads inside simulation" restated, because readiness is a wall-clock fact.
3. **A game that must gate play on loading does it through input.** A level that starts "when
   loaded" is told so by an event the host delivers at a frame boundary, of the same class as a
   key press. A replay records that event, as the court's script records a key. M27's sample
   never needs this: the gallery is drawn and has no collision. The rule is written down now
   because M60 will need it.
4. **Main-thread completions run at one place in the frame**: `engine.beginFrame`'s pump,
   before any simulation step. They never interleave with a system.

**How it is checked.** Steps 4–6 run the registry and `Content` under `inline`, under
`Manual` in forward and reverse completion order and with tasks held "not yet" across polls,
and under the real pool. Payload bytes must match in every case. Step 6 runs `sandbox3d`'s tour
with the gallery requested on a fixed tick, under all three executors, and its pinned
simulation hashes must not move.

## 6. Two-phase loading in `asset.Registry` (`asset`, L2)

### 6.1 The loader gains an optional split

```zig
pub const Loader = struct {
    schema: SchemaId,
    ctx: ?*anyopaque = null,
    max_source_bytes: usize = ...,
    load: *const fn (...) LoadError!Payload,        // unchanged: the synchronous path
    unload: *const fn (...) void,                    // unchanged
    /// Optional. Pure: it reads `decode_ctx`, the record and the bytes and nothing else, and
    /// returns an owned value through the thread-safe allocator it is handed.
    decode: ?*const fn (decode_ctx: ?*const anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Decoded = null,
    /// On the main thread: turns a decoded value into a payload, charging the budget.
    finish: ?*const fn (ctx: ?*anyopaque, gpa: Allocator, record: Record, decoded: Decoded, budget: *Budget) LoadError!Payload = null,
    /// Frees a decoded value nobody will finish.
    discard: ?*const fn (gpa: Allocator, decoded: Decoded) void = null,
    decode_ctx: ?*const anyopaque = null,
};
```

`decode`, `finish` and `discard` are all present or all absent. `registerLoader` and
`acquireWith` refuse a partial set, with a named error. `decode_ctx` is read-only for the
loader's lifetime: `render3d` puts its device's maximum texture dimension there, never the
renderer. **`load` stays, and for a split loader it is `decode` followed by `finish` on the
calling thread.** One implementation serves both paths, so a synchronous and a background load
cannot drift apart. That is ADR-0062.

A loader with no split still loads in the background request path. Its read happens on a
worker, and its `load` runs as a finish on the main thread. This is how a loader nobody split
keeps working, mods' loaders included when M48 publishes them (I6). It just does not move its
decode.

### 6.2 New calls

- **`request(gpa, id)`, `requestOf` and `requestWith(gpa, id, loader)`** return an
  `AssetHandle` at once, counted exactly as `acquire` counts.
  - A handle that is already resident is ready.
  - Otherwise its entry is `pending`, and the registry adds two graph nodes: the read and
    decode in the background, and the finish on the main thread.
  - Every refusal that does not need the bytes is returned synchronously and named, as
    `acquire` names it: a missing record, the wrong schema, no loader, an unsafe path, an
    unmounted package.
- **`state(handle)`** returns `.ready`, `.pending` or `.failed`. A failure carries the same
  `LoadError` a synchronous load would report, and is logged once.
- **`get` and `payloadOf` return null while pending.** Every existing caller already handles
  null for a stale handle.
- **`pump(gpa, budget) PumpStats`** polls the registry's graph. The engine calls it once per
  frame, inside `beginFrame`, under the profiler span `assets.pump`.
- **`quiesce()`** cancels and waits until nothing is in flight. Its outputs are discarded.
- **`acquire` on a pending entry completes that entry synchronously**: it waits for its decode,
  or does it on the calling thread if it has not started, then finishes it. `acquire` keeps its
  meaning, which the public ABI relies on (§6.6).

### 6.3 Records, the store and reloads

A decode reads its `Record`, and a record's bytes are borrowed from the store. **So the store
must not change while a decode is in flight.** The engine calls `assets.quiesce()` before
`reloadContent` replaces packages. That is a content reload, which already rebuilds everything
and is a development action. Stalling it until in-flight decodes finish is the honest cost.
Nothing else replaces the store.

**Source reloads move to the background.** When `reloadChanged` finds a changed stamp on a
split loader's entry, it requests a new decode. The old payload stays current and keeps
drawing. When the new one finishes, the payload is swapped and the old one unloaded in the same
pump. `Content`'s existing rebuild-on-new-payload check follows the swap without being told. A
failed background reload leaves the old payload current and logs the failure once, which is
today's behaviour for a failed reload. `reload(handle)`, the synchronous call, is unchanged.

### 6.4 The per-frame budget

`pump`'s `Budget` counts bytes a finish uploads (`PumpBudget.upload_bytes`, default 8 MiB) and
finishes run (`max_finishes`, default 16). A finish that would exceed the byte budget still
runs if it is the first of the pump, so a single large texture cannot wait forever. Steps 3 and
9 measure the defaults against the 2.0 ms target and record them. The budget bounds only work
that moved to the main thread. The decode cost it removed is visible in the measurement as the
difference between §12's two runs.

### 6.5 Release, eviction and teardown while pending

- **A release that takes a pending entry's count to zero cancels it.** The decode's output is
  discarded at the next pump, and the entry is removed then, not before.
- **`evictUnused` skips pending entries.**
- **`deinit` quiesces first.** That is why the background pool outlives the registry (§4.1).

### 6.6 What the public ABI sees

**Nothing changes in `FoundryApi_v1`–`v6`.** `asset_acquire` keeps calling `acquire`, so a
mod's acquisition is synchronous and complete, as it always was. A mod never sees a pending
handle: an asset the host requested is completed by a mod's `asset_acquire` before it returns.
Asynchronous acquisition for mods is a new public shape, with a pending result, polling and
cancellation, and it is M48's (ROADMAP, "jobs for native mods").

## 7. A decode phase for every engine loader that works (`render2d`, `render3d`, `asset`, `audio`)

| Loader | `decode` (background) | `finish` (main thread) |
| --- | --- | --- |
| `render3d.textureLoader` | PNG decode and `asset.mips.generate` | create the texture and its sampler from the chain, staging copy, one submit |
| `render2d.textureLoader` | PNG decode and mips if asked | the same, through `render2d` |
| `render3d.meshLoader` | `asset.mesh_file.read`, its validation and per-submesh bounds | `createMesh` from the validated view: staging copies and buffers |
| `asset.skeletonLoader`, `animationLoader`, `collisionMeshLoader`, `tilegridLoader` | the whole parse and validation | hand over the decoded value as the payload |
| the mixer's `soundLoader` | WAV decode and conversion | register the sound with the mixer |
| the script `SourceLoader` | none: it copies text | today's `load` |

For textures, `Renderer.createTexture` already calls `asset.mips.generate` itself.
`render3d` and `render2d` therefore each gain `createTextureFromChain`, and `createTexture`
becomes the chain's generation followed by that call. The texture bytes must be identical
whichever path made them. Step 5 reads them back on Metal and pins their hash.

## 8. Models that appear when they are ready (`render3d`, L3; `debug`, L5)

- **`Content.requestModel(id) ModelHandle`** resolves the model record synchronously, since it
  is in the store and is a lookup. It then requests every mesh, texture, skeleton and clip
  through §6. A graph join node depends on all their finishes, builds the model's materials and
  marks it ready.
- **`modelReady(handle)`** answers readiness. **`drawModel` of a model that is not ready draws
  nothing and returns ok.** It is counted in `Stats.pending_models`. A model is never drawn half
  loaded, and never with the magenta placeholder standing in for a texture still on its way: a
  half-drawn model pops in, and the placeholder means "broken", which a pending load is not.
- **A part whose load failed** is handled as it is today: the part is dropped and the failure
  reported once. Its failure also completes the join, so a model with one broken mesh still
  appears.
- **`acquireModel` is unchanged and synchronous**, and every existing caller keeps it. The
  court, `sandbox3d`'s room, its walker and its props load at startup as they do now.
- **The overlay** shows the pump's last-frame stats (pending, finished, bytes uploaded,
  failures) in its profiler panel. The content browser shows each asset's state. Both read
  through calls the ABI could expose: counts and per-handle states, in the registry's
  documented order.

## 9. Background validate and build (`author`, L4)

### 9.1 What runs where

A build already has stages. M27 puts them on a graph:
1. **Snapshot, on the main thread**, when the job starts.
   - Check the expected revision, the grants and that nothing is dirty, as `build` does now.
   - Take the save lock.
   - For a validate, copy the unsaved drafts into the job, since validate compiles drafts.
   - Copy the dependency set's immutable view.
2. **Compile, in the background.**
   - Create the candidate.
   - Copy the inputs under the existing confined rules.
   - Run the one compiler.
   - Run the load-order and store validation into the job's own `Diagnostics`.
3. **Publish, on the main thread.**
   - Insert the build into the workspace's pool, or free the candidate on failure.
   - Release the lock.
   - Replace the workspace's diagnostics with the job's.

Same saved bytes and options must still give the same `.fpk` and generated-asset bytes as the
synchronous call and as `fpack`. Step 7 compares them byte for byte.

### 9.2 What the workspace does while a job runs

- **Edits continue in memory.** The revision moves, and the job keeps the revision it started
  from, so its result is stamped with that revision, as a synchronous build's is.
- **Saves are refused `Busy`**, a refusal v4 already maps to `FOUNDRY_ERR_REFUSED`. The build
  reads saved files, so they must not change under it. The existing re-inventory still detects
  a writer outside the editor.
- **One job per workspace.** A second start is refused `Busy`.
- **Closing a workspace with a job in flight cancels the job and waits for it.** That is a
  closing action, like `quiesce`.

### 9.3 `FoundryApi_v7`: three calls

The editor's client is a header-only consumer and gets no private path (I4, ADR-0042). A
background compile it can use must therefore be in the table. **M27 publishes `FoundryApi_v7`,
flat v6 plus three calls, frozen at 264 when M27 closes:**

| Call | Meaning |
| --- | --- |
| `author_job_start(FoundryWorkspace, uint32_t kind, uint64_t expected_revision, FoundryAuthorJob *out)` | `kind` is validate or build. It refuses exactly what `author_validate` and `author_build` refuse, plus `Busy` |
| `author_job_poll(FoundryAuthorJob, FoundryAuthorJobStatus *out)` | `status` is pending, succeeded or failed. A succeeded build carries its `FoundryBuild`. A finished job's diagnostics are the workspace's, read through `author_diagnostic_next` |
| `author_job_release(FoundryAuthorJob)` | Forgets a finished job, or cancels a pending one; a cancelled build's candidate is removed when it finishes. A stale job handle is refused |

`FoundryAuthorJob` is a generational handle (I1). The calls are additive: v4's synchronous
`author_validate` and `author_build` are unchanged, and `fpack` keeps using them, because a
command-line compile is happy to block.

**This takes the number v7 from M48.** The roadmap names M48 "Public API v7". With this design,
M48 publishes `FoundryApi_v8`, and its line is amended by a dated note at M27's close. The
alternative, keeping the client's use of these calls for M48, would leave M27's editor half
without a runnable result and the calls without a consumer for twenty milestones (§14, item 1).

## 10. The editor's client (`tools/editor`)

The Build and Validate buttons start a job. The status line shows "Building…" with the elapsed
time, and the build list gains the build when its poll succeeds. The client polls once per
frame, before it draws.

During a job:
- Build and Validate are disabled, and Save is disabled with the reason shown.
- Edits, navigation, the schema and dependency browsers and the preview of an earlier build all
  work.

The `--plan` workflow, which drives the editor's 489 actions, gains a step that edits while a
build runs and then waits for it. The plan's existing synchronous steps are unchanged.

## 11. `sandbox3d`'s gallery

- **The content.** `scripts/m27/make_gallery.py` generates a package section under
  `samples/sandbox3d/content`:
  - eight 2048×2048 sRGB textures with mipmaps, procedural and highly compressible, so the
    committed bytes stay small while the decoded pixels are large;
  - one material per texture;
  - one model of eight framed panels, with no collision.

  `--check` compares the committed output byte for byte, as `scripts/m26/make_court.py` does.
  The committed total is bounded at 2 MB, and Step 3 measures it. The panels are what the
  sample shows; the rest of the package is unchanged.
- **Loading it.** The tour requests `sandbox3d:model.gallery` at a fixed tick, and a person can
  press G to request it. The model is drawn on the frame its join completes, at a place the
  tour's camera passes; Step 3 chooses the place and records it. `FOUNDRY_SANDBOX3D_LOAD=sync|background` selects the path for
  the measurement. `sync` uses `acquireModel` on that tick, so it is the baseline and stalls.
  The default is `background`.
- **What it proves.** The tour's simulation hash is pinned
  (`samples/sandbox3d/props_tests.zig` and `native_tests.zig`) and must not move. The
  gallery adds no body, no collision and no rule, so §5's rule holds by construction, and
  Step 6 tests it anyway.

## 12. Measuring the exit

**Where:**
- the windowed `sandbox3d`, ReleaseSafe, API validation off, on this Mac (Metal) and on the PC
  (Windows/Vulkan);
- the editor with the sandbox package open, on both.

**Workloads:**
- the gallery, requested on the tour's fixed tick;
- in the editor, a build of `sandbox3d`'s package, the largest in the repository once the
  gallery is in it.

**Comparison:** the same binary, `sync` against `background`, three runs each, alternated.

**What is recorded:**
- frame work, measured as the court measures it (without the pacing sleep, image acquire or
  present), median, p95 and maximum over the frames from the request to 60 frames after the
  gallery is ready;
- `assets.pump`: median, p95 and maximum;
- the time from the request to readiness;
- in the editor, the longest gap between drawn frames while a build runs, and the build's
  duration, against the synchronous button's single blocked frame.

**Claims:**
- The exit holds if every `background` run's maximum frame work is at or under 16.67 ms, its
  `assets.pump` p95 is at or under 2.0 ms, and every `sync` run's maximum exceeds 16.67 ms.
- The editor's claim is that its longest frame gap during a build is at or under 33.3 ms, two
  frames, against a synchronous build's whole duration.
- The numbers are recorded whatever they show. A failed claim is answered in the step, not
  re-measured until it passes.

## 13. Platform assessment

- **macOS/Metal** is primary. Every step runs here.
- **Windows/Vulkan: runtime required.**
  - A background thread's file reads go through Windows' file APIs under `Io.Threaded`, which
    no earlier milestone exercised off the main thread.
  - The finish path uses the Vulkan upload path.
  - The editor's build behaviour must hold where M15 proved it.

  Step 10 runs the suites, the gallery measurement, the editor workflow and the editor proof
  natively, with validation and synchronization validation required for the Vulkan suites. PC
  courtesy as always: `-j2`, below-normal priority, a worktree, an idle check.
- **Linux: compile only.** Nothing M27 adds is Linux-specific. Threads and confined file reads
  go through `std` paths that the frame pool and hot reload already run on Linux (M18, M26),
  and nothing touches windows, surfaces, presentation or a driver (3d.md §10.2). The
  cross-compiled check stays in the bar. **The trigger that would make it a runtime
  requirement:** any Linux-only code path in `platform/background.zig`, such as a thread
  priority or affinity call. §4.1 rules that out.

## 14. Decisions acceptance fixes

Nothing blocks Step 1 once these are accepted. Each is recommended as written:

| # | Choice | Where |
| --- | --- | --- |
| 1 | The editor's background compile is published in M27 as `FoundryApi_v7` (three calls, frozen at 264), so M48's table becomes `FoundryApi_v8`, amending its roadmap line. The alternative is to do only `author`'s side now and leave the client's use for M48 | §9.3 |
| 2 | Background work runs on a second, separate pool, default two threads, and never on the frame pool. Priority is left to M99 (ADR-0061) | §4.1 |
| 3 | The graph is minimal: background and main nodes, prerequisites added earlier, cooperative cancellation and a budgeted poll. No priorities, futures, stealing or fibers (ADR-0061) | §3.3 |
| 4 | Arrival is presentation: readiness may decide what is drawn, never what is simulated; a gate on loading is input (ADR-0061, amending ADR-0036's decision 2) | §5 |
| 5 | A loader may split into a pure `decode` and a main-thread `finish`; `load` is their composition, and a loader with no split still loads in the background request path (ADR-0062) | §6.1 |
| 6 | `acquire` stays synchronous, and completes a pending entry; the ABI's `asset_acquire` is unchanged, and asynchronous acquisition for mods is M48's | §6.2, §6.6 |
| 7 | The store is replaced only after `quiesce`; source reloads of split loaders move to the background, keeping the old payload until the new one finishes | §6.3 |
| 8 | A pending model draws nothing, not a placeholder; `acquireModel` and every existing caller are unchanged | §8 |
| 9 | While a job runs, a workspace accepts edits and refuses saves and a second job with `Busy` | §9.2 |
| 10 | `core.mem.SharedCounted` for background allocation; the engine's `gpa` must be thread-safe when background workers are on | §4.3 |
| 11 | The gallery is generated, committed and checked byte for byte, at most 2 MB; it has no collision | §11 |
| 12 | The exit's numbers: maximum frame work at or under 16.67 ms and `assets.pump` p95 at or under 2.0 ms in the background runs; a synchronous run that exceeds 16.67 ms; the editor's frame gap at or under 33.3 ms | §1, §12 |
| 13 | Windows: runtime required. Linux: compile only, with §13's trigger | §13 |

## 15. Implementation order — eleven bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `core`: tasks, the graph and the shared counter

§3 in full: `Tasks`, `Task`, `Done`, `inline`, `Manual` and `Graph`, with prerequisites,
failure, cancellation, `idle` and a budgeted poll. §4.3's `core.mem.SharedCounted`.

Tests:
- a graph's nodes run once each, in prerequisite order, under `inline` and under `Manual` in
  forward order, reverse order and with nodes held across polls;
- the first failure by index is the graph's, and its dependants are skipped;
- a cancelled graph discards outputs of nodes that finished after the cancel and is idle only
  when nothing runs;
- a budget defers main nodes to the next poll, but never the first;
- adding a node past capacity is refused;
- `SharedCounted` balances across threads.

Nothing uses it yet. **Exit:** the graph's ordering, failure, cancellation and budget rules
each have a test that fails when the rule is broken.

### Step 2 — `platform` and `app`: the background pool

- §4: `platform.Background`, `app.Config.background_workers`, `engine.tasks()`,
  `engine.taskAllocator()` and teardown order.
- Record each sample's `gpa`, and confirm its thread safety.

Tests:
- every task runs exactly once across real threads, over many starts at varied counts;
- a full queue refuses, and the graph retries;
- a background thread's `readFileConfined` and `statFileConfined` agree with the main
  thread's on the same files, while the main thread reads others;
- start and stop with nothing queued, and with work in flight;
- zero workers is the inline executor.

**Exit:** a graph run on the real pool computes what `inline` computes.

### Step 3 — Measurement and baseline

- §11's generator and the committed gallery, with its size recorded.
- `sandbox3d` requests the gallery on its tick with the synchronous path only, behind
  `FOUNDRY_SANDBOX3D_LOAD=sync`, and the request is also bound to G.
- The `assets.pump` span exists, empty.
- §12's `sync` measurement on Metal, three runs, and the editor's synchronous build of the
  sandbox package, timed.

**Exit:** the baseline is recorded, and a synchronous gallery load exceeds 16.67 ms. If it does
not, the gallery is resized within its 2 MB before anything else is built.

### Step 4 — `asset`: request, pump and state

§6 except §7's loaders: the optional split and its refusals, `request*`, `state`, `pump` and
its budget, `quiesce`, the background reload of split loaders, release and eviction while
pending, `deinit`, and `acquire` completing a pending entry. The engine pumps in `beginFrame`
and quiesces before `reloadContent`.

Tests run on fake split loaders under `inline`, `Manual` and the pool:
- payloads identical across all of them;
- every refusal returned synchronously and named;
- a failure reported once;
- a reload that keeps the old payload until the new one, and one that fails;
- release to zero while pending;
- `quiesce` with work in flight.

The registry's existing tests pass untouched. **Exit:** every pending-entry path has a test,
and nothing synchronous changed.

### Step 5 — The engine's loaders split

§7's table:
- `createTextureFromChain` in both renderers;
- the mesh, skeleton, animation, collision mesh and tile-grid splits;
- the mixer's sound split.

Tests:
- each loader's synchronous and background payloads are equal;
- a texture's bytes read back from Metal through both paths share one pinned hash;
- the mixer plays a background-loaded sound with the same samples.

**Exit:** every engine loader with a decode runs it off the main thread, and every payload is
the same either way.

### Step 6 — `render3d` and `sandbox3d`: models when ready

- §8: `requestModel`, the join, `modelReady`, `Stats.pending_models`, and the overlay's pump
  stats and per-asset state.
- §11's background path in `sandbox3d`.

Tests:
- on null, a pending model draws nothing, and a ready one draws exactly what `acquireModel`'s
  does;
- a failed part still completes the join;
- the tour's pinned hashes are identical under `inline`, `Manual` reversed and the pool, with
  the gallery requested on its tick.

**Exit:** the gallery appears in the windowed sample on Metal, and the tour's hashes did not
move.

### Step 7 — `author` and `abi`: background jobs and `FoundryApi_v7`

- §9.1–§9.3: jobs in `author.Service`, the three calls, the header, the agreement table and the
  C header compile check.

Tests:
- a background build's `.fpk` and assets are byte-identical to `author_build`'s and to
  `fpack`'s;
- a validate job compiles the drafts;
- saves and a second job are refused `Busy`;
- the stale-revision, stale-handle and cancelled-job refusals;
- closing a workspace mid-job;
- v1–v6 unchanged.

**Exit:** a header-only consumer starts, polls and releases a build through v7 and gets the
synchronous call's bytes.

### Step 8 — The editor's client

§10, and the `--plan` workflow's new step, through the table only.

Tests:
- `editor-workflow` and `editor-smoke` pass;
- a build started from the window lets an edit land during it;
- the forbidden-import boundary test still holds.

**Exit:** on Metal, the editor draws and accepts edits while a build runs.

### Step 9 — The exit proof on Metal

- §12's comparison on this Mac, three runs of each path, and the editor's frame gaps.
- The background worker sweep (1, 2 and 4), with the default chosen and recorded.
- The pump budget's defaults confirmed or changed.
- Run the court and `room` to confirm they are unchanged.

**Exit:** §12's claims hold on Metal, or this step answers the one that failed.

### Step 10 — Windows/Vulkan

- The native suites with validation and synchronization validation required.
- The gallery measurement and the editor proof, relocated, in the desktop session.
- `sandbox3d`'s and the court's plays unchanged.

**Exit:** §12's claims hold on Windows/Vulkan, validation-clean.

### Step 11 — Close M27

- Confirm §13's assessment.
- Resolve every contract discrepancy in its originating document:
  - `jobs-and-threading.md` §3.2 and §9, for background work and the task graph (ADR-0036's
    decision 2 amended by ADR-0061);
  - `assets.md` §9's second question, answered;
  - `editor.md` §8 and §12, for "synchronous bounded compilation" and the background-compile
    limitation;
  - `public-abi.md`, for `FoundryApi_v7`;
  - the ROADMAP's M48 line, amended to `FoundryApi_v8` by a dated note.
- Move ADR-0061 and ADR-0062 to Accepted and into `CLAUDE.md` §4.1. Update §4.3's `platform`
  and `core` lines, and §9's rows. Update `AGENTS.md`'s bar if a step changed it,
  `PROJECT_STATE.md`, the roadmap and the design index.

Tag `m27`, push when asked, and stop before M28's design. **Exit:** §1's exit holds as written,
and every item §1 sets aside names its milestone.

**Verification is bounded, as in M12 and M26.** Each step:
- runs the bar;
- breaks its own guards deliberately to show named tests fail (a main node run out of index
  order, a background node started before its prerequisite, a discard skipped on cancel, a
  pending entry visible to `get`, a store replaced without `quiesce`, a save allowed during a
  job), then restores the files byte for byte;
- ends with a dated Resolution recording what implementation settled.

There are no recursive audits.

## 16. What stays open, deliberately

Nothing M27 takes on is left open (CLAUDE.md §2, rule 17). What it sets aside belongs to named
milestones, each listed in §1: M28, M30, M48, M60, M93, M99 and M100. Two questions are
measured rather than decided here, and both are answered before M27 closes:
1. **The background pool's default size:** Step 9's sweep.
2. **The pump's budget defaults:** Steps 3 and 9.

## Resolution — Step 1: tasks, the graph and the shared counter (2026-10-18)

`engine/src/core/tasks.zig` holds the interface, the graph and the two executors without
threads. `core` exports it as `core.tasks`, and `core.Tasks` beside `core.Jobs`.
`core.mem.SharedCounted` is beside `Counted`. Nothing uses either yet.

**What implementation settled:**
- **The immediate executor is `core.tasks.immediate`, not `inline`.** `inline` is a Zig keyword.
  §3.2's text and §14 mean this value.
- **A node's function returns an `Outcome`, `ok` or `failed`, not an error.** The graph orders
  work and does not interpret errors. A consumer keeps its own named error in the node's
  context, which is where Step 4's registry will keep its `LoadError`. This keeps the graph's
  error set narrow (CLAUDE.md §7) rather than `anyerror`.
- **One signature for both kinds.** Every node is `fn (context, *Budget) Outcome`. A background
  node is handed an unlimited budget of its own, which it may ignore.
- **`poll` is one ascending pass**, and that one pass is the whole scheduling rule:
  - a running background node whose `Done` is set takes its outcome;
  - a waiting node whose prerequisites all finished `ok` starts if it is background, or runs if
    it is main and the budget allows;
  - a node with a failed or skipped prerequisite is skipped.

  Prerequisites always come earlier, so a node's consequences reach as far as they can within
  the same pass. A background node that `immediate` ran inside `start` is settled at once, so
  under `immediate` a whole graph finishes in one poll.
- **Main nodes ready at one poll run in ascending index**, by construction of the pass.
  Background completions may arrive in any order. The order test shows both.
- **A failure skips only what depends on it.** Independent nodes keep running. The registry
  needs this, so that one broken texture does not stop the others. `firstFailure()` is the
  lowest failed index, and `status()` is `failed` once nothing is waiting or running.
- **Cancellation and discard.**
  - `cancel` stops anything new from starting, and `add` then refuses with `Cancelled`.
  - At the next poll, every node that had finished `ok` gets its `discard`, and waiting nodes
    become cancelled.
  - A node still running is discarded at the poll after it finishes.
  - `status()` adds `cancelled`, the state §3.3 implied but did not name.
- **`deinit` asserts `idle`** (a programmer error, not input): a graph freed with a node running
  would be written into after it was gone.
- **The budget counts bytes and nodes**, and is `Budget.unlimited` by default. Its "never the
  first" rule is tested with a budget already spent before the poll begins.
- **A full executor stops further starts for that poll.** The refused node stays waiting and is
  started at a later poll.
- **`Manual`'s capacity is fixed at `init`**, so the full path is testable.
  - `runNext`, `runLast` and `runAt` choose the order.
  - `wait` runs everything held, since nothing else would.
  - `deinit` asserts nothing was left unrun.
- **`SharedCounted`** keeps `Counted`'s five numbers in atomics.
  - The peak is kept by `fetchMax`.
  - A shrink saturates through compare-and-swap, for `Counted`'s underflow reason.
  - `counts()` returns a reading, exact when nothing is in flight.
  - It has no owner check, which is the point. Its threaded test spawns threads from a test,
    which `core`'s code still never does.

**Tests:**
- Nine in `tasks.zig`:
  - a graph under `immediate` completes in one poll, in prerequisite order, and nothing runs
    twice;
  - under `Manual`, in forward order, reverse order, and with one node held across polls, main
    nodes still run in index order;
  - the first failure, its skipped dependants and an independent node that still runs;
  - cancellation, discard, `idle` and `cancelled`;
  - byte and node budgets, including a budget spent before the poll;
  - a full executor;
  - capacity and prerequisite refusals;
  - an empty graph;
  - `Manual` itself.
- Two in `mem.zig`:
  - four threads allocate 2,000 blocks and the main thread frees them, and the counts balance;
  - refusals are counted, and a shrink does not underflow.

**Evidence:**
- **Breaking the guards one at a time** against `tasks.zig`'s tests failed every time, and the
  file was restored byte for byte:
  - ignoring prerequisites failed the order test;
  - not propagating a failure failed the failure test;
  - skipping `discard` on cancel failed the cancellation test;
  - letting the budget block a poll's first node failed the budget test, and so did ignoring the
    budget;
  - treating a refused start as started failed the full-executor test;
  - allowing a node to name itself failed the refusal test;
  - running the pass in descending order failed three tests.

  Three of these runs ended in `deinit`'s idle assertion, as the failing test unwound with a
  task still held. That is the assertion doing its job after the expectation had already
  failed.
- `core`'s 123 tests pass standalone in Debug and ReleaseSafe.
- **The bar passed: 2,149/2,150 (one skip)**, eleven new tests. This covered formatting, the
  four `check` variants, the four headless samples and `fdt-check`. The first `check
  -Drhi=metal` of the run exited 1 without its output captured. Two reruns on unchanged code
  passed, so the failure is recorded as unexplained. No file this step changes is
  Metal-specific.

Step 2 adds `platform.Background`, the pool with threads, and the engine's `tasks()` and
`taskAllocator()`.

## Resolution — Step 2: the background pool (2026-10-18)

- `engine/src/platform/background.zig` is the pool. `Os.startBackground(gpa, options)` builds
  it on the process's `Io`, which still never leaves `platform`.
- `platform.Background` and `platform.background` are exported, and the file imports only
  `std` and `core`, so its tests also compile standalone.
- `app.Config.background_workers: ?u16` sizes it. The engine starts it after the frame's pool,
  stops it after everything the engine owns, the registry included, and before the frame's
  pool, and returns it as `engine.tasks()`.
- `engine.taskAllocator()` is a `core.mem.SharedCounted` named `background`, over the engine's
  `gpa`. Nothing uses either yet.

**What implementation settled:**
- **The pool's shape mirrors `Workers`.** Threads are fixed at `init`, and an `std.Io` mutex
  and two conditions do the waiting: `work` for workers, and `settled` for `wait`. A thread that
  will not start is a warning, and `max_count` is 16.
- **The queue is a ring of `Options.capacity` entries, default 256.**
  - `start` refuses `Full` when the ring is full, under the lock, and allocates nothing.
  - A worker sets a task's `Done` after the task returns, outside the lock, and only then
    leaves the running count, so `wait` returning means every flag is set.
- **With no threads, `start` runs the task on the caller**, which is `immediate`'s behaviour.
  Zero configured workers, or none that started, is therefore exactly `immediate` (§4.1's "the
  inline executor"). An engine never hands out a pool that silently queues forever.
- **`deinit` runs what is queued before it joins.** A task whose flag is never set leaves its
  graph unfreeable (Step 1's idle assertion). Starting a task on a stopping pool is asserted as
  a programmer error.
- **`defaultCount()` is two, or one on four logical CPUs or fewer, or one when the count cannot
  be read.** Step 9 sweeps it.
- **The memory report is not changed automatically**, correcting §4.3's "registers it with the
  overlay's memory list". `engine.zig` documents, and a test pins, that the report holds
  exactly what somebody registered. The engine follows `registerMemory`'s own argument: the
  game chooses what to count. So the engine exposes `taskMemory()`, and
  `registerSharedMemory(*SharedCounted)` adds it beside `Counted` counters.
  - Internally the report's entries became a union of the two kinds, and `MemoryReport` is
    unchanged.
  - `debug`'s memory panel and the sandbox's summary read it as before.
  - A sample that wants the line registers it. Step 6 does so for `sandbox3d`.
- **Every program's `gpa` is thread-safe** (§4.3's check). `court`, `sandbox3d`, `room`,
  `sandbox` and the editor hand the engine `std.process.Init`'s `gpa`. In Zig 0.16 that is a
  `DebugAllocator(.{})` in Debug, whose `thread_safe` defaults to true, and `c_allocator` or
  `smp_allocator` otherwise. Tests use `std.testing.allocator`, also a default
  `DebugAllocator`. The requirement is documented on `Config.background_workers`.

**Tests:**
- Six in `background.zig`:
  - every task runs exactly once over fifty rounds of 64 starts, at one, two and four threads;
  - a full queue refuses, and accepts again once a task is taken;
  - `wait` returns only after a task already taken from the queue has finished;
  - zero threads runs a task on the caller, inside `start`;
  - a 33-node graph, 32 background squares joined by a main sum, computes on the pool what it
    computes under `immediate`, twenty times;
  - twenty starts and stops, with and without queued work, every queued flag set by `deinit`.
- One in `os.zig`: sixteen files read and stat'ed on two background threads agree byte for
  byte with the main thread's reads of the same files, made concurrently in reverse order.
- One in `app`: with zero and with two background workers, a task allocates through
  `taskAllocator` and the main thread frees it. The registered `background` counter shows 1,024
  live bytes and then zero, and with zero workers the task ran on the calling thread.

**Evidence:**
- **Breaking the pool's guards one at a time,** each restored byte for byte:
  - stopping without draining the queue failed the stop test;
  - queueing with no threads failed the zero-thread test;
  - setting `Done` before the task ran failed the graph test.
- **Two mutations exposed weak tests, which were fixed and rerun:**
  - A `wait` that ignored running tasks passed every test. The `wait` test above was added for
    it, and it fails that mutation.
  - Removing the queue's bound made the full-queue test hang rather than fail: its gate thread
    spun forever once the expectation failed. The gate now opens on any exit. With that change
    the full-queue test fails, and the graph test after it then hangs, because an overwritten
    task's flag is never set. That is still a detection, but a hang, so the graph test's
    capacity-8 run is the evidence that the bound matters.
- **The bar passed: 2,157/2,158 (one skip)**, eight new tests. All four `check` variants, the
  four headless samples and `fdt-check` passed.

Step 3 builds the gallery and measures the synchronous baseline.

## Resolution — Step 3: the gallery and the synchronous baseline (2026-10-18)

- `scripts/m27/make_gallery.py` writes the gallery, and `--check` compares it byte for byte,
  as `make_court.py` does.
- `samples/sandbox3d/gallery.zig` loads it, and records the frames around the load.
- `app`'s `beginFrame` has an `assets.pump` span, and it is empty.
- The editor's host now logs the longest gap between two finished frames.

**What implementation settled:**
- **The ID is `sandbox3d:models.gallery`**, correcting §11's `sandbox3d:model.gallery` to the
  package's own `models.` prefix, which the room, the course, the crate and the walker use.
- **The generator writes the record too.** It writes `content/gallery.fdt`, the package's
  second record file, holding one `foundry:model_import`, so `--check` covers what the
  package compiles and not only the files the record names.
- **The committed total is 624,507 bytes of the 2 MiB bound,** and the generator refuses to
  write past the bound. There are eleven files:
  - eight PNGs of 66–79 KB each;
  - `gallery.gltf` (21.6 KB) and `gallery.bin` (7.8 KB);
  - the record.

  Each texture is 2048² RGBA, sRGB, with mipmaps, which is what the import gives every image.
  The texture is stripes inside a border, periodic in each row, so zlib keeps the file small
  while a load still inflates 16 MiB of pixels before mips.
- **The place is a ring above the crates** (§11 left it to this step).
  - Eight panels stand 7 m from the room's centre, centred 2.4 m up and facing in.
  - Each picture is 1.8 m square, in a frame 0.1 m wider.
  - The orbiting camera always has some in view, beyond the far wall. From inside the room
    they show above the 1.2 m walls.
  - There are nine materials: eight pictures and one untextured frame. The design's "one
    material per texture" holds.
- **When and how it loads:**
  - The request tick is 120, two seconds in. With `FOUNDRY_SANDBOX3D_LOAD=sync`, the step
    on that tick calls `acquireModel`.
  - Without the variable, the gallery waits for G. `background` and any other value are
    said and ignored until Step 6 adds that path.
  - G loads the gallery, or releases it if it is held. It is the sample's first letter key,
    so unlike the F keys it is ignored while the overlay's filter box has focus.
  - `FOUNDRY_SANDBOX3D_KEYS` also takes `g@frame`.
- **How frame work is counted.** `sandbox3d` sleeps for pacing inside its frame, before
  `endFrame`, unlike the court. So the sample times its own sleep, and frame work is:
  - the frame's total;
  - less `render.acquire` and `render.present`, as the court counts them;
  - less that sleep.

  §12's window runs from the request's frame to sixty frames after ready. Ready is the same
  frame on the synchronous path.
- **`assets.pump` is opened and closed on the reading that ends `input`,** before any step,
  so it is zero-length until Step 4 gives it work. Four engine tests that pin a frame's span
  order now include it.
- **The tick is fixed, and the frame it lands on is not.** In one run, tick 120 fell on frame
  114, because of the start's catch-up steps. This is decision 4's distinction already
  visible: what is loaded follows a tick, and when it is seen follows the frame.

**Baseline on Metal:**
- **Setup:** Apple M5 and SDL3 `cocoa`.
  - The build is ReleaseSafe, with 4× MSAA and shadows, in a 1280×720 window paced at 60 Hz.
  - No Metal validation layer is on (`MTL_DEBUG_LAYER` unset).
  - Each run is `FOUNDRY_SANDBOX3D_LOAD=sync FOUNDRY_SANDBOX3D_FRAMES=300`, over 61 frames.

| Run | Load (ms) | On frame | Frame work median (ms) | p95 (ms) | max (ms) |
| --- | --- | --- | --- | --- | --- |
| 1 | 588.4 | 114 | 1.160 | 1.567 | 594.185 |
| 2 | 564.6 | 120 | 1.078 | 1.387 | 565.110 |
| 3 | 571.2 | 120 | 1.110 | 1.354 | 571.661 |

- **The exit holds without resizing.** Every synchronous run's maximum is at least 565 ms,
  thirty-four times the 16.67 ms budget. The other sixty frames of each window stay near
  1.1 ms.
- `assets.pump` read 0.000 ms throughout, as an empty span should.
- **What that is per texture:** about 71 ms each for the eight textures, which is the load's
  whole cost. Step 5 splits it into a decode and a finish, and Step 9 measures the finish's
  share against the pump's 2.0 ms.
- **The tour:** headless in Debug, with `FOUNDRY_SANDBOX3D_LOAD=sync`, the tour loads the
  gallery (2,778 ms) and passes. Its hash, `cb99ccfcf2b6d6c3`, is unchanged.

**The editor's synchronous build:**
- **Setup:**
  - The same ReleaseSafe build, windowed on Metal.
  - A throwaway copy of `samples/sandbox3d/content`, with `core.fpk` as its dependency.
  - A plan of four idle frames, `click build`, then five more.
- **Result:** in three runs, the longest gap between frames was 193.5, 190.0 and 191.9 ms, each
  ending on frame 6, the frame the build ran in.
  - An idle plan's longest gap was 9.2 ms.
  - A build followed by `click export_package` exported a package byte-identical to the
    20,902-byte `sandbox3d.fpk` that `zig build` makes. So the timed build compiled the whole
    package, gallery included.
- This is the synchronous frame §12's 33.3 ms claim is measured against in Step 8.

**Tests:**
- Two in `gallery.zig`:
  - the load switch takes `sync` and refuses everything else to "wait for G";
  - the window records from the request's frame to sixty frames after ready. It subtracts
    acquire, present and the pacing sleep, sums `assets.pump`, ignores earlier frames, and
    closes once.

**Evidence:**
- **Each window guard was broken in turn, and each restored byte for byte:** dropping the
  lower bound, the pacing subtraction, the close, or the stop after closing each failed the
  window test. Two first attempts were compile errors, not detections, and were redone.
- Removing the `assets.pump` span failed four engine tests.
- **The bar passed: 2,159/2,160 (one skip)**, with two new tests. fmt, all four `check`
  variants, the four headless samples and `fdt-check` passed.
- The editor changed, so `editor-workflow`, `editor-smoke` and the windowed `--script` run on
  Metal also passed.
- `dist` was not staged. `sandbox3d` is not a released application, and no asset kind
  changed.

Step 4 gives `asset.Registry` its `request`, `pump`, `state` and `quiesce`.

## Resolution — Step 4: request, pump and state (2026-10-18)

`asset.Registry` gains `request`, `requestOf`, `requestWith`, `state`, `pump`, `quiesce`,
`busy` and `useTasks`. `asset` exports `Split`, `Decoded`, `Budget`, `State`, `PumpBudget` and
`PumpStats`.

The engine wiring:
- the engine hands the registry its background pool and `taskAllocator`;
- it pumps once in `beginFrame`, inside `assets.pump`, under `Config.asset_pump`;
- it bumps the content generation when a pump swaps in a background reload;
- it calls `quiesce` before `reloadContent` adopts new packages.

No engine loader is split yet, so every load the engine does today behaves as before.

**What implementation settled:**
- **The split is one optional struct, `Loader.split: ?Split`, holding `decode_ctx`, `decode`,
  `finish` and `discard`.** This corrects §6.1's three optional fields and its "refuse a
  partial set": with one struct, a partial set cannot be written, so nothing refuses one.
  `AcquireError` is unchanged, and the three ABI maps and `render3d`'s switches that list its
  members exhaustively need no new member.
- **The registry composes a split loader's synchronous load itself.** `Loader.loadWhole` runs
  `decode`, then `finish` under an unlimited budget, then `discard`, on the calling thread.
  `acquire`, `acquireWith`, `reload` and the retry of a failed entry all go through it. So a
  synchronous and a background payload come from one implementation, as ADR-0062 asks, and a
  split loader's own `load` can be written as `loadWhole` (the test loader's is).
- **A finish neither frees nor keeps its decoded value.** The registry discards the value
  through the allocator that decoded it, whatever `finish` returned. The finish makes its
  payload through the allocator the payload is later unloaded with.
  - This corrects §4.3's "freed by its `finish` or `discard`".
  - It also corrects §7's "hand over the decoded value as the payload" for the skeleton,
    animation, collision-mesh, tile-grid and sound loaders. In Step 5 those copy into their
    payload instead.
  - **Why:** a decode allocates through the engine's counted `background` allocator, and a
    payload is unloaded through the engine's `gpa`. A handed-over buffer would be counted in
    one and freed past it, so the "background" line would drift for the asset's whole life.
    The copy is a bounded memcpy on the main thread, charged to the pump's budget.
- **One small graph per load, in request order.** A request or background reload owns a
  two-node `core.tasks.Graph`, on the heap because the executor points into it:
  - a background read, and decode if the loader is split;
  - a main-thread finish after it.

  `pump` polls the jobs in the order they were requested, with one budget, and retires each
  one whose graph has nothing left running.
- **Two changes to Step 1's graph:**
  - "a budgeted poll always runs its first main node" is now counted by the budget
    (`Budget.ran`), not per poll. One budget handed to every job's poll then runs a single
    finish past its limit, the pump's first, rather than one per job. A single poll behaves
    as before, and Step 1's tests pass unchanged.
  - `Graph.started(index)` reports whether a node has left waiting.
- **A request starts nothing.** Its decode starts at the next pump, and its finish runs at a
  pump after the decode is done. The decode could start sooner, but under `immediate` that
  would run the finish outside the pump, and decision 4 allows main-thread completions at
  that one point only. A request therefore costs at most one frame before its decode starts.
- **`acquire` on a pending entry never waits on the pool**, correcting §6.2's "waits for its
  decode":
  - a decode that has finished is finished on the spot;
  - one that has not started, or is still queued or running, is cancelled, and the asset is
    decoded again on the calling thread. `Tasks` has no wait for a single task, and waiting
    behind other queued work would make `asset_acquire`'s latency depend on the queue;
  - `Graph.started` keeps that path from starting a decode it is about to repeat. Without it,
    `acquire` on an unstarted request queued a decode it then threw away, which a test
    caught.
- **Failures:**
  - `acquire` on a failed entry tries again synchronously. On failure it returns the error
    and leaves the count unchanged.
  - A second `request` of a failed entry only counts it, so a broken file is said once, not
    on every request.
- **A release to zero while pending** takes the entry out of the lookups at once, so a new
  request starts afresh. The entry itself goes at the pump that frees its cancelled job.
- **`quiesce` leaves held entries pending** and sets a flag, so the next pump starts them
  again against whatever store is current. A cancelled background reload puts back the
  entry's previous stamp, so the change is seen again.
- `unregisterLoader` and `unloadWith` quiesce first if a job uses that loader, because a
  decode may be running its functions. `deinit` quiesces first too, and unloads only ready
  entries.
- **Nothing is logged off the main thread by the registry.** A background read's failure is
  mapped without logging (`readFailure`) and said by the pump. `Os` still logs its own
  `IoFailed` cause where it happens, and the log ring is behind a spin lock, so that rare line
  is safe from a worker.
- **`get`, `getIfLoader` and `payloadOf` return null unless the entry is ready.**
  `evictUnused` skips anything with work in flight, and removes a failed entry without
  unloading it.

**Tests:**
- **Twelve in `registry.zig`:**
  - A request makes what `acquire` makes, under `immediate`, under `Manual` completing
    forwards and backwards with decodes held across pumps, and on the pool at zero, one and
    two threads.
  - Every bytes-free refusal is immediate, named, and leaves nothing behind.
  - Missing and corrupt sources fail in the background, are said once, and are retried by
    `acquire`.
  - `acquire` completes a pending entry in all three positions: decoded, queued, unstarted.
  - The budget finishes in request order and always finishes the first.
  - Releasing to zero while decoding, and before starting.
  - `quiesce` with work in three states, then a restart.
  - A background reload keeps the old payload, is not started twice, is not evicted under,
    and is retried after a `quiesce`.
  - A background reload that fails in its decode, and one that fails in its finish.
  - A loader nobody split, and a private split loader, through requests.
  - `deinit` and `unregisterLoader` with work in flight.
- **One in `tasks.zig:`** one budget across three graphs.
- **One in `engine.zig`:** a tile grid requested through the engine finishes in a later
  `beginFrame` on a two-thread pool, and one requested just before `reloadContent` is
  quiesced, restarted and finished.
- The fixture that builds the engine tests' packages now registers the engine's asset
  schemas, as `readAll` does.
- Every existing registry test passes untouched.

**Evidence:**
- **Eleven guards were each broken in turn against the whole suite,** and each restored byte
  for byte. Every one failed a test:
  - a release that does not cancel;
  - eviction that does not skip work in flight;
  - `acquire` polling a decode that has not started;
  - `get` answering while pending;
  - the first finish not guaranteed;
  - the first-finish rule counted per poll;
  - `quiesce` forgetting held entries;
  - a cancelled reload keeping its new stamp;
  - a reload started twice;
  - a reload that does not unload the old payload;
  - a failure not recorded.
- **Weak tests found and fixed along the way:**
  - The first eviction and double-start mutations passed. The eviction check had run while
    the handle was held, and the double start was hidden by the stamp the first start had
    already written. The reload test now releases the handle before evicting, and changes
    the file again mid-reload. Both mutations then failed it.
  - The first release mutation was a compile error, not a detection, and was redone.
- **The bar passed: 2,172/2,173 (one skip)**, with thirteen new tests. fmt, all four `check`
  variants, the four headless samples and `fdt-check` passed.
- The headless tour with `FOUNDRY_SANDBOX3D_LOAD=sync` still passes, with hash
  `cb99ccfcf2b6d6c3`.

Step 5 splits the engine's loaders (§7). The skeleton, animation, collision-mesh, tile-grid
and sound finishes copy into their payloads, by the rule above.

## Resolution — Step 5: the engine's loaders split (2026-10-18)

Every loader in §7's table now has a `split`. The script `SourceLoader` has none, as §7 says.

| Loader | `decode`, on any thread | `finish`, in the pump |
| --- | --- | --- |
| `render3d.textureLoader` and `render2d.textureLoader` | `asset.texture_decode.decode`, shared: PNG decode bounded by the device limit, then the whole mip chain if the record asks | `createTextureFromChain`, or `createTexture` for one level |
| `render3d.meshLoader` | the file copied and fully validated by `mesh_file.read` | `createMesh` from the validated view |
| skeleton, animation, collision mesh, tile grid | today's whole parse and copy | `asset.adoptDecoded`: the decoded value becomes the payload |
| the mixer's `soundLoader` | WAV decode and conversion | the samples handed to the mixer |

Supporting changes:
- **Texture upload:** both renderers gain `createTextureFromChain`. `createTexture` is now
  `mips.generate` followed by that call.
- **Device limit:** each renderer keeps `texture_limits`, its device's maximum dimension
  copied at `init`. A decode reads only that, so no background thread reaches a device.
- **Composition:** every split loader's own `load` is `loadWhole`, so there is one
  implementation per kind.

**What implementation settled:**
- **A finish now owns its decoded value on success, correcting Step 4's Resolution.** Step 4
  said a finish neither frees nor keeps it, so that the counted `background` allocator would
  stay balanced. §7 hands the decoded value over as the payload for five loaders, and under
  that rule each would have parsed and then copied everything a second time.
  - The balance is kept another way: a request decodes through the allocator it is handed,
    which is the one its payload is made and unloaded with.
  - The engine passes its `gpa`, which `Config.background_workers` already requires to be
    thread-safe. `useTasks` therefore takes only the executor.
  - `engine.taskAllocator` and the `background` counter remain, for Step 7's builds.
  - §4.3's "freed by its `finish` or `discard`" stands as written. Only Step 4's narrowing of
    it is withdrawn.
- **A texture's decode and finish agree on the colour space.** Both read the same field with
  the same `srgb` default. The decode stays silent, and the finish warns about an unknown
  spelling as before.
- **A mesh's decode copies the file once,** because the view its validation returns borrows
  the bytes it validated. The finish then builds buffers from that view without reading it
  again.
- **Content textures gain `copy_src` usage in `render3d`,** so their levels can be read back
  for the pinned hash.
- **The null backend keeps no texel memory, and reads back zeros.** The first hashes pinned
  in this step were of those zeros, and Metal's run exposed it. The pins are now of the bytes
  the CPU makes, and every backend checks them:
  - on any backend, the CPU bytes must match the pin, and the two paths' readbacks must
    match each other;
  - on Metal and Vulkan, the readback must also equal the CPU bytes exactly.
- **One integration test needed updating.** `model_content`'s reload test called
  `reloadChanged` on a bare registry and expected a synchronous reload. A texture's source
  change now reloads in the background (§6.3), so the test pumps once and expects one
  reload. This is the behaviour the design asked for, not a regression.

**Tests:**
- **Registry, the parsed kinds:** skeleton, animation, collision mesh and tile grid each make
  a payload that re-encodes to its source file byte for byte. This holds synchronously, under
  `immediate`, under `Manual` in reverse, and on a two-thread pool.
- **Registry, the shared texture decode:** it makes exactly `mips.generate`'s chain in the
  record's colour space, linear and sRGB, or the bare image without mipmaps, both ways.
- **Registry, a failed finish:** a synchronous reload whose finish fails discards its decoded
  image.
- **`model_content`:** three textures (sRGB mipped, linear mipped, linear flat) read back
  every level identically through `acquireWith` and through `requestWith` on the pool.
  - Their CPU bytes are pinned: `64b56f963c423089`, `dfc24b10be58e500` and
    `d73f519507e3037d`.
  - On Metal the readback equals those bytes.
  - A mesh's bounds, submesh boxes and streams match either way.
- **`asset_pipeline`:** a `render2d` texture requested on the pool has the same descriptor,
  levels and sampler as an acquired one, and draws with no violation.
- **`sound_pipeline`:** a sound requested on the pool plays exactly the samples a synchronous
  load plays.

**Evidence:**
- **The integration tests on Metal (`-Drhi=metal`) passed: 97/102 (five skips),** including
  every texture's exact readback.
- **Guards were broken in turn, and each restored byte for byte:**
  - Detected: a failed finish's decode kept, a finished decode discarded again, mips never
    made, a sound's box leaked, and the decode ignoring the colour space.
  - The colour-space mutation first survived, because on null no test read the loader's own
    bytes. The shared-decode test was added for it and fails it.
  - Dropping `mipmaps` from the `render3d` finish's options is an equivalent mutant:
    `createTextureFromChain` uploads every level of its chain whatever that flag says.
  - The sound mutation's first form was a compile error, and was redone.
- **The bar passed: 2,177/2,178 (one skip)**, with five new tests. fmt, all four `check`
  variants, the four headless samples and `fdt-check` passed.
- **The tour:** the headless tour with `FOUNDRY_SANDBOX3D_LOAD=sync` passes, with hash
  `cb99ccfcf2b6d6c3`.
- **Timing, recorded rather than smoothed over:**
  - The bar's tour logged a synchronous gallery load of 18.7 s, against Step 3's 2.8 s, and
    one rerun gave 19.3 s. Both ran while the load average was six to seven, straight after
    the mutation and Metal runs.
  - Two later reruns of the same command gave 2.73 s and 2.75 s. Step 4's commit in a
    separate worktree gave 2.74 s, and a directly run binary of this step gave 2.74 s.
  - So the split adds no cost to the synchronous path, and the outliers were the machine.

Step 6 gives `render3d.Content` its `requestModel`, and loads `sandbox3d`'s gallery in the
background.

## Resolution — Step 6: models when ready (2026-10-18)

`render3d.Content.requestModel` asks for a model without waiting. `sandbox3d` now loads its
gallery that way by default, and the room keeps drawing while it loads.

**What it added:**
- **`requestModel(id)`.** It reads and refuses the record now, exactly as `acquireModel`
  does. It requests every mesh, texture, skeleton and clip the record names through §6, and
  the model is pending until all of them have finished or failed.
- **`modelState(handle)`** answers `pending`, `ready` or `failed`, with the join checked
  first. **`modelReady(handle)`** is that state compared with `ready`. Both are exported as
  `render3d.ModelState`.
- **`drawModel` of a model that is not ready submits nothing and returns ok.** A pending one
  is counted in the new `Stats.pending_models`. A model is never drawn half loaded, and never
  with the placeholder standing in for a texture still on its way.
- **The overlay:**
  - The profiler panel shows `Engine.assetPumpStats()` as a line: pending, finished,
    reloaded, failed and KiB uploaded in the frame's pump. Its `render3d` lines add "models
    pending".
  - The content browser labels each asset `pending` or `failed (error)`. The registry's
    listing (`AssetInfo.state`) carries the state, in the listing's documented order.
- **`sandbox3d`:**
  - `FOUNDRY_SANDBOX3D_LOAD` is now `background` when unset. `sync` keeps Step 3's
    baseline, and `off` waits for G.
  - A value the sample does not know is said, and waits for G, as Step 3's did.
  - G uses the background path unless the run asked for `sync`.
  - The window starts at the request and closes sixty frames after the frame the gallery is
    first ready, which `Gallery.poll` notes before each draw.

**What implementation settled:**
- **The join is a check, not a graph node.** §8 described "a graph join node" depending on
  every part's finish.
  - Each part's load is its own two-node graph inside the registry, and finishes in the pump.
    A node depending on several of them would need an edge between graphs that the registry
    does not expose.
  - Instead, `Content` checks its parts' states where readiness is asked: by a draw, and by
    `modelState`. A model is ready on the first frame that asks after its last part
    finished, which is when §11 says the gallery is drawn.
  - The check costs one state read per part, and only while a model is pending.
- **What fails, and how:**
  - A failed mesh is handled as `acquireModel` handles one: its parts are dropped, it is
    said once, and it is released, so nothing failed stays held.
  - A failed texture makes its material the placeholder, as it always has. The model is
    still ready.
  - A skeleton or clip that failed, or whose joint counts do not fit the meshes, is what
    `acquireModel` refuses. A requested model cannot be refused after the fact, so it
    becomes `failed`: said once, never drawn, and no draw of it is an error.
- **A draw of a pending model still validates its world matrix and overrides.** A draw that
  would be refused when ready is refused while pending too, so readiness never hides a
  caller's mistake.
- **The same ID is one model either way.**
  - `requestModel` of a model already held counts it.
  - `acquireModel` of a pending one completes it on the calling thread, as
    `Registry.acquire` completes a pending asset. For that, the registry's `complete` is now
    public: `acquire` without the count.
  - `Registry.idOf(handle)` names a part in any state, for the warning.
- **Materials wait too.** A material whose requested texture is still loading is marked
  pending, holds what it asked for, and stays the placeholder until it resolves again. No
  model waiting on it is drawn, so nobody sees that placeholder.
  - Resolving again requests the same entries, which only counts them, so nothing loads
    twice.
  - `acquireModel` or `acquireMaterial` of a pending material completes it.
- **A content reload keeps a pending model requested.** `contentChanged` rebuilds it from the
  new record with requests rather than acquisitions. A reload is no reason to wait.
- **The sample's tests now mount the package as an install stages it.** Sources and compiled
  assets are in one tree beside the package, a `WriteFiles` step in `build.zig`. The test
  tree held only the compiled assets, so the gallery's PNGs, which are sources, were missing
  from it.

**Tests:**
- **`model_content`, on any backend:**
  - A requested `models.pair` draws nothing while pending, is counted, and is ready after
    its parts finish. It then draws exactly what an acquired one drew: the same parts,
    submeshes, world matrices and materials, the crate's textured. This holds under
    `immediate`, `Manual` in newest-first order, and a two-thread pool.
  - Its missing mesh fails, and the join still completes. The parts are dropped, and no
    failed entry is still held.
  - A texture whose file is not a PNG leaves the model ready, drawn with the placeholder in
    that slot. A skeleton that is not one fails the model: not drawn, not counted pending,
    not an error.
  - With the meshes finished and the crate's texture still queued, the model is pending.
    Once the texture finishes, the model is ready and drawn textured.
  - `acquireModel` of a pending model completes it without the queued decodes having run.
  - A content reload during a request leaves the model pending, and it is ready once its
    parts are.
- **`sandbox3d` (`props_tests`):** the tour's hash is `cb99ccfcf2b6d6c3` with the gallery
  requested on tick 120, under all three orders.
  - The gallery is pending for some ticks in each order, because its parts are unloaded
    between orders.
  - Once settled it draws sixteen parts: eight frames and eight pictures.
- **Unit tests:**
  - The registry's `complete` finishes without a count and refuses a stale handle, and the
    listing reports each entry's state.
  - The profiler's pump line, and its absence without an answer.
  - The switch's three values, and the background window kept open through the pending
    frames.

**Evidence:**
- **The exit, on Metal:** ReleaseSafe, windowed, three runs of 300 frames, with the default
  load.

  | Run | Requested on frame | Ready on frame | Request to ready (ms) | Frame work median / p95 / max (ms) | `assets.pump` median / p95 / max (ms) |
  | --- | --- | --- | --- | --- | --- |
  | 1 | 120 | 140 | 333.9 | 1.018 / 6.981 / 7.694 | 0.000 / 6.750 / 7.490 |
  | 2 | 120 | 140 | 333.9 | 0.989 / 7.071 / 7.345 | 0.000 / 6.871 / 7.147 |
  | 3 | 120 | 140 | 333.6 | 1.010 / 7.003 / 7.751 | 0.000 / 6.796 / 7.545 |

  - The same binary with `sync` stalled one frame for 545.1 ms.
  - The gallery's state reached `ready` and it was drawn from frame 140. I did not look at
    the window: no screen capture is taken on this machine. Seeing it is the owner's, by
    running the sample and waiting two seconds.
- **For Step 9, recorded and not answered here:**
  - Every frame stayed under 16.67 ms, but the pump's p95 is about 6.8 ms, above §12's
    2.0 ms.
  - Each 2048² texture's finish uploads about 21 MiB in one call. The pump always runs its
    first finish, so the default 8 MiB budget cannot split one. The gallery's eight textures
    are eight such finishes, each in its own frame's pump.
  - Step 9 measures the claim and answers it.
- **Headless:**
  - The tour passes with hash `cb99ccfcf2b6d6c3` in both modes.
  - In the background the gallery was ready after 1,480 ms. Headless frames are not paced,
    so that was frame 1,559.
  - `sync` took 2,745 ms on its one frame.
- **Guards were broken one at a time against the full `zig build test`.** Each source was
  restored and checked by hash.
  - **Detected:**
    - a pending draw not counted;
    - a pending model drawn as if ready;
    - the join ignoring meshes;
    - a failed mesh kept held;
    - `acquireModel` leaving a pending model pending;
    - a reload acquiring a pending model;
    - `requestModel` acquiring;
    - the sample defaulting to `off`;
    - `complete` accepting a stale handle.
  - **Detected after a test was added:**
    - The join ignoring materials first survived, because the crate's texture always
      finished in the same pump as the meshes. The texture-wait test holds the texture back
      and fails it.
    - Dropping the pump line from the profiler-off path survived, because the line's test
      called it directly. The profiler-off test now expects it.
  - **Equivalent:**
    - Dropping the failed-skeleton check still fails the model: `checkAnimation` finds no
      skeleton payload, and only the wording of the message changes.
    - Building a material before its pending texture arrives leaves it pending, so it is
      rebuilt before any model that uses it is drawn. That costs one wasted
      `updateMaterial`, and nothing visible.
- **The bar passed: 2,186/2,187 (one skip)**, with nine new tests. fmt, all four `check`
  variants, the four headless samples and `fdt-check` passed. The integration tests passed
  on null, 107/107.

Step 7 gives `author` its background validate and build, and publishes them as
`FoundryApi_v7`.

## Resolution — Step 7: background jobs and `FoundryApi_v7` (2026-10-18)

`author` validates and builds off the host's thread, and `FoundryApi_v7` publishes it in three
calls: `author_job_start`, `author_job_poll` and `author_job_release`. With v6's 261 entries
that makes the table's 264, as §9.3 planned.

**What it added:**
- **The build has three stages.** `author.build_mod.Job` divides a validate or build into:
  - `start`, on the main thread: §9.1's checks, the writer's lock, a fresh candidate, and a
    copy of what the compile reads;
  - `run`, on any thread: the snapshot, the one compiler and the load validation;
  - `finish`, on the main thread: the build published or its candidate removed, the lock
    released, and documents the compile found changed on disk marked.
- **The synchronous calls are the same stages run back to back.** `validate` and `build`
  now call `start`, `run` and `finish` in a row. There is one path, so a background build
  cannot differ from a synchronous one by construction, and the byte tests below check it.
- **`author.Service` runs the jobs.**
  - `Options.tasks` names the executor, inline by default.
  - Each job is a one-node graph. `startJob`, `pollJob`, `jobInfo` and `releaseJob` drive
    it, with one job per workspace.
  - Diagnostics written while the job runs are its own until it is published. Then they
    become the workspace's, stamped with the job's starting revision.
- **The workspace, while a job runs:**
  - Saves, synchronous validates and builds, and a second start are refused `Busy`. The
    refusal's diagnostic says a background job is running.
  - Edits, new documents, refresh and discard all continue, because the job compiles its
    own copies.
- **The ABI:**
  - `FoundryAuthorJob` is a new handle, and `FoundryAuthorJobStatus` (32 bytes) carries
    revision, build, state, kind and result. `FoundryAuthorJobKind` and
    `FoundryAuthorJobState` are new enums.
  - The header's `FOUNDRY_API_VERSION` is now 7, and the native loader offers v7.
  - Both halves of the agreement check the new layouts and the tail's offsets.
  - The sweeps walk the v7 table, and `get_api` hands it out beside v1–v6, whose entries are
    the same functions at the same offsets.

**What implementation settled:**
- **What is copied, and what is borrowed:**
  - The job owns a copy of each document's path, its compile bytes and its baseline. A
    validate's compile bytes are the draft; a build's are the baseline.
  - The dependency set is borrowed, not copied as §9.1 said. It is fixed for the workspace's
    life, and closing a workspace cancels its job and waits for it, so the borrow cannot
    outlive the set.
- **When a cancelled candidate is removed.** §9.3 said "when it finishes". The service has no
  per-frame call of its own, so a released job is discarded at the first job call (start,
  poll or release) after its compile returns, or when its workspace closes.
- **Closing a workspace mid-job cancels it and waits:** it polls the graph, waiting on the
  executor, until the compile has returned, then discards it. `Service.deinit` does the same
  for every open workspace.
- **`finish` does not check the build limit again.** `start` checks it, and while a job runs
  nothing can add a build: the workspace refuses another compile `Busy`.
- **With a threaded executor, the service's allocator must be thread-safe.** That is the same
  rule the engine's `Config.background_workers` states.
- **The host keeps the job handles, so `abi` holds no state.**
  - Its four slots (`max_author_jobs`) recycle as jobs are released.
  - The first poll that sees a build succeed issues its `FoundryBuild`, and every later poll
    answers that same handle. Releasing the job does not release the build.
  - If the boundary's build slots are full, the build is released and the job reports
    failed with `FOUNDRY_ERR_LIMIT`.
  - A job whose workspace closed is refused `FOUNDRY_ERR_INVALID_HANDLE`, and releasing it
    still frees its slot.
- **Errors map as the synchronous calls map them.** A kind other than validate or build is
  `FOUNDRY_ERR_INVALID_ARGUMENT`, and `Busy` is `FOUNDRY_ERR_REFUSED`, as v4 maps it.

**Tests:**
- **`author`:**
  - A background build makes the synchronous build's package and generated `.fgrid` byte
    for byte, inline and held by `Manual`. Its package is also `fpack`'s compiler's bytes.
  - A validate job compiles the drafts. Its diagnostics become the workspace's, at the
    starting revision.
  - While a job runs, save, save all, validate, build and a second start are `Busy`, and an
    edit lands. The build and its diagnostics are stamped with the starting revision.
  - A stale revision is refused at start. A released job's handle goes at once, and its
    candidate once the compile has returned.
  - Closing mid-job runs the compile to its end and leaves no candidate and no lock.
  - A job that finds a source changed on disk fails `ExternalChange` and marks the document,
    so the next build is refused before it compiles anything.
- **`abi`:**
  - The v7 tail agrees with the header, and every earlier offset is unchanged.
  - The job values' shapes and numbers match.
  - `get_api(7)`, and 264 entries.
  - Malformed arguments are refused, and job handles recycle over nine jobs through four
    slots. A build job's build stays valid after its job is released. A closed workspace's
    job is refused.
- **The exit proof, in the integration tests:** `fixtures/author_job_mod.c`, a C99 library
  that sees only `foundry.h`, runs as a native mod against a service compiling on a
  two-thread `platform.Background` pool.
  - It writes a package, then runs a validate job on the unsaved draft. After saving, it
    builds synchronously to destination 0 and through a job to destination 1, and checks
    that the job's handle is refused once released.
  - The host finds the two exported packages, and `fpack`'s compiler's, identical byte for
    byte.

**Evidence:**
- **Guards were broken one at a time against the full `zig build test`.** Each source was
  restored and checked by hash.
  - **Detected:**
    - a validate compiling the baseline;
    - a build stamped with the current revision;
    - a cancelled job keeping its candidate;
    - the diagnostics left unpublished;
    - the diagnostics stamped with the current revision;
    - a released job never reaped;
    - close leaving its job;
    - a released handle still resolving;
    - a poll issuing a new build each time;
    - `build` read as validate;
    - release keeping the boundary's slot.
  - **Detected after a test was added:**
    - `finish` forgetting a document changed on disk first survived, because no test
      changed a source during a job. The disk-change test fails it.
    - Dropping the explicit save refusal first survived, because the job's writer lock still
      refused the save `Busy`, under a message blaming another editor. The `Busy` test now
      checks that the refusal names the background job.
- **Header compile:** the installed header compiles `author_job_mod.c`, `author_client.c` and
  `render3d_client.c` as C99 and C++17 for macOS, Linux and Windows.
- **Editor proofs:** `editor-workflow` and `editor-smoke` pass. The synchronous build under
  them is now the three stages.
- **The bar passed: 2,196/2,197 (one skip)**, with ten new tests. fmt, all four `check`
  variants, the four headless samples and `fdt-check` passed.

Step 8 moves the editor's client onto these calls.

## Resolution — Step 8: the editor's client (2026-10-18)

The editor builds and validates through v7's jobs, and keeps drawing and accepting edits
while a package compiles.

**What it added:**
- **The client moves to `FoundryApi_v7`, and still sees only `foundry.h`.**
  - Validate and Build each start a job (`author_job_start`).
  - Every frame polls the job once, before anything is described, and publishes its result
    once.
  - A build's handle is adopted as the synchronous build's was: the previous build is
    released unless the preview holds it.
  - A failure goes to the status bar as before, and its diagnostics stay in the message log.
- **While a job runs:**
  - Validate and Build are disabled, and so are their shortcuts. Save and Save All are
    disabled with the reason in the status bar.
  - The status bar reads "Building…" or "Validating…", the elapsed time from the table's
    `elapsed_ns`, and "Saving waits for it."
  - Those words are three new fields of `foundry:editor.screen`. Everything else — edits,
    navigation, the browsers and the preview of an earlier build — works as before.
- **The host** hands the service the engine's background pool, logs each job's frames, result
  and the edits that landed during it, and asks for v7.
- **Plans gain `wait`.**
  - `wait` idles until no job is running, bounded at 3,600 frames.
  - The client records `Targets.job_running` at the end of every frame, and a plan's `wait`
    reads it.
  - A replay given no explicit `--frames` now ends one frame after its last step, which is
    exactly where the old frame count ended a plan with no `wait` in it. So `wait`'s bound
    is never idled through.
- **`docs/modding/editor.md`** says what Validate and Build now do, and documents `wait`.

**What implementation settled:**
- **Job calls no longer invalidate walks they do not change.** The first workflow run lost a
  failed build's diagnostics. Two calls caused it:
  - Starting, polling and releasing a job each marked the service as moved. That made the
    next frame reopen the document's parse.
  - Reopening a parse clears the workspace's diagnostics.

  A synchronous validate marks nothing, and a synchronous build marks the service only when
  it publishes a build. Jobs now do the same: only a published build moves the service. This
  also corrects Step 7's `author_job_start` and `author_job_release`, which had marked the
  host's authoring state changed.
- **The 489-action `--plan` is not in the repository.** It was a throwaway file of M15 Step 8.
  So §10's new step exists in two other forms:
  - the editor's own workflow test, which edits while a build runs and then waits for it;
  - `wait`, for any author's plan.
- **`requestPreview`** (`--preview`) keeps the synchronous `author_build`, which v7 still
  carries. It is a one-shot host action, not a frame.

**Tests:**
- **The editor workflow, 22 tests:**
  - Under a held executor, Build starts a job, and an edit is applied and lands while the
    job runs.
  - Save All and Validate are disabled and attempt nothing.
  - After the compile, the next frame publishes the build, stamped with the saved revision,
    and Save works again.
  - The existing save/build/reload, refused-build and export tests pass on jobs.
- **The script runner:** `wait` holds while a job runs and steps on after. It parses, and
  refuses an argument.
- **The other editor proofs:** `editor-smoke` replays 25 of 25 actions in 48 frames, with its
  workspace unchanged. The forbidden-import boundary test still holds.

**Evidence, on Metal (the exit):**
- **Setup:** ReleaseSafe and windowed, over a fresh copy of `samples/sandbox3d/content` with
  `core.fpk`. The plan selects the first record, clicks Build, edits a field while the build
  runs, and waits.
- **Every run:** the job answered `FOUNDRY_OK`, the revision moved during it, and the
  workspace ended with unsaved changes.
- **First three runs:**
  - the job ran from frame 12 to frame 24;
  - the longest gap between frames was 20.6–38.3 ms, at startup (frames 1–5), not during the
    build.
- **Six later runs:**
  - the job ran 60–71 frames, about 1.1 s;
  - the longest gap was 35.2–41.0 ms, during the build;
  - the load average was about 2.9. Nothing in the code changed between the two sets except
    one log line.
- **What it shows:** the window drew and took edits throughout the build, against Step 3's
  single blocked frame of about 190 ms.
- **For Step 9, recorded and not answered here:** the later runs' gaps exceed §12's 33.3 ms
  editor claim, and the build is slower on the background thread than on the frame.
  Possible causes, none tested:
  - the background thread's scheduling class;
  - contention on the shared thread-safe allocator.
- **Guards were broken one at a time against the full `zig build test`**, and each source was
  restored and checked by hash.
  - **Detected:**
    - the job never polled;
    - Validate allowed while a job runs;
    - `job_running` never recorded;
    - a failed job's build adopted;
    - `wait` never waiting.
  - **Detected after a test was fixed:** Save allowed while a job runs first survived. The test
    read the result of the Save All click only after the Validate click, which resets it. Each
    click is now checked on its own.
- **The bar passed: 2,199/2,200 (one skip).** fmt, all four `check` variants, the four
  headless samples and `fdt-check` passed.

Step 9 is the exit proof on Metal: §12's numbers, three runs each way.

## Resolution — Step 9: the exit proof on Metal (2026-10-18)

§12's claims hold on Metal, once the step's one fix was made. The pump missed its 2.0 ms p95
in Step 6, and the cause was not the upload.

**What the step found, and changed:**
- **Each texture's finish spent 5.3 ms returning its decoded chain to the system.** Measured
  with probes that were not committed, on the gallery's 21 MiB mip chains:
  - creating the texture: 15–60 µs;
  - creating the staging buffer: 9–27 µs;
  - copying the chain in: 1.26–1.56 ms;
  - recording and submitting: 34–76 µs;
  - then freeing the decoded chain: **5.24–5.29 ms**.
- **The allocator is the system's `malloc`.** `std.process.Init` hands out `c_allocator`
  wherever libc is linked, and returning a 21 MiB block costs that much on macOS whatever
  allocator asks. So the free moves off the main thread, rather than the allocator changing.
- **A finish now borrows its decoded value.** `Split.after_finish` says what happens to it
  next. This corrects Step 5, whose finishes owned the value:
  - `free`, the default: discarded on the main thread straight after, for values small
    enough that a task would cost more than their free;
  - `free_on_pool`: discarded by a third node of the job, on the pool. Both renderers'
    texture loaders use it;
  - `adopt`: the finish keeps it. The parsed kinds (`adoptDecoded`) and the mixer, whose
    samples become its sounds, use it.
- **A job that frees on the pool:**
  - The entry is ready, and detached from the job, the moment its finish installs the
    payload. The pump counts it then.
  - The job retires once its free has run.
  - A free the executor had no room to start is done by `retire` on the main thread, when the
    job is cancelled or quiesced.
  - `load`, the synchronous path, discards straight after its finish, on the calling thread.
- **Tests that waited only for `ready` now wait for nothing to be in flight.** These are the
  pool loops in `model_content` and `asset_pipeline`, and two `Manual` drains.
- **New measurement switches:** `FOUNDRY_SANDBOX3D_BACKGROUND=n` sets the sample's background
  pool for the sweep, and `FOUNDRY_EDITOR_TASKS=inline` compiles the editor's builds on the
  frame, as the synchronous button did.

**The gallery: ReleaseSafe, windowed, Apple M5. Three runs each way, alternated, 300 frames,
on the default pool of two:**

| Run | Path | Request to ready | Frame work median / p95 / max (ms) | `assets.pump` p95 / max (ms) |
| --- | --- | --- | --- | --- |
| 1 | sync | 573.9 ms, frame 120 | 0.912 / 1.006 / **574.294** | 0.001 / 0.001 |
| 1 | background | 333.9 ms, frame 140 | 0.893 / 1.680 / **2.349** | **1.457** / 2.140 |
| 2 | sync | 551.5 ms | 0.940 / 1.018 / **551.913** | 0.000 / 0.001 |
| 2 | background | 333.8 ms | 0.994 / 1.774 / **2.435** | **1.528** / 2.193 |
| 3 | sync | 550.2 ms | 0.992 / 1.095 / **550.677** | 0.001 / 0.004 |
| 3 | background | 333.8 ms | 0.979 / 1.711 / **2.654** | **1.474** / 2.386 |

- **Every claim holds:**
  - every background maximum is at or under 16.67 ms (worst 2.654 ms);
  - every background pump p95 is at or under 2.0 ms (worst 1.528 ms);
  - every synchronous maximum exceeds 16.67 ms (least 550.677 ms).
- **The pump's maximum is a single frame, above 2.0 ms.** At most 2.39 ms, in the frame a
  finish shares with another job's free. The claim is the p95, and it holds.

**The worker sweep (background pool threads), three runs each:**

| Threads | Request to ready | Frame work max (ms) | Pump p95 (ms) |
| --- | --- | --- | --- |
| 1 | 534–550 ms | 1.82–1.94 | 1.47–1.49 |
| 2 | 333.8–333.9 ms | 2.35–2.65 | 1.46–1.53 |
| 4 | 250.4 ms | 2.15–2.46 | 1.62–1.77 |

- **The default stays `platform.background.defaultCount()`:** two threads, or one on four
  CPUs or fewer.
  - Four threads gain 84 ms to ready, but bring the pump's p95 nearer its 2.0 ms, as more
    frees and decodes share the machine with the frame.
  - One thread costs 200 ms.
- **The pump budget's defaults are confirmed** (8 MiB and 16 finishes). A 2048² chain is
  larger than 8 MiB, so the always-run first finish uploads one texture per pump, and that
  finish now costs about 1.5 ms.

**The editor: the same build, `sandbox3d`'s package with `core.fpk`.** The plan is four idle
frames, click Build, wait, then five idle frames.

| Run | Path | Build frames | Longest gap between frames |
| --- | --- | --- | --- |
| 1 | inline | 6–7 | **192.9 ms**, frame 6 |
| 1 | background | 6–19 | 21.0 ms, frame 1 (start-up) |
| 2 | inline | 6–7 | **194.3 ms**, frame 6 |
| 2 | background | 6–18 | 17.8 ms, frame 1 |
| 3 | inline | 6–7 | **193.8 ms**, frame 6 |
| 3 | background | 6–19 | 17.6 ms, frame 1 |

- **The claim holds:** every background run's longest gap is at or under 33.3 ms. It is the
  start-up frame, not the build. An idle-only plan's longest gap was 20.5 ms, at start-up.
- **Step 8's plan, with an edit during the build,** ran 12 frames three times again, with
  gaps of 20.5–21.8 ms, all at start-up.
- **Step 8's slower set did not recur.** That set saw 60–71-frame builds and 35–41 ms gaps.
  Nothing has reproduced it in the nine runs since, and its cause is not established. It is
  recorded in Step 8's Resolution as it was measured.

**The court and `room`,** windowed on Metal, ReleaseSafe, 300 frames:
- both exited cleanly, with no warning or error line;
- the court's skin cost was median 0.054 ms and p95 0.073 ms;
- `room` stopped where it does unattended.

**Evidence:**
- **Guards were broken one at a time against the full `zig build test`.** Each source was
  restored and checked by hash.
  - **Detected:** the free node freeing nothing, the pump counting at retire rather than at
    the finish, and `load` not discarding.
  - **Detected after a test was added:**
    - Retire forgetting a never-started free first survived, because every test's executor
      had room to start it. A test whose executor is full fails it now.
    - The entry staying attached to its job first survived. Its effect is that the entry
      cannot be evicted while its free waits, and the test now evicts it then.
  - **Not unit-tested:** which loaders free on the pool decides speed, not results. It is what
    the measurements above show.
- **The integration tests on Metal passed: 103/108 (five skips),** with every texture's exact
  readback.
- **The headless tour passes,** with hash `cb99ccfcf2b6d6c3`.
- **The bar passed: 2,201/2,202 (one skip).** fmt, all four `check` variants, the four
  headless samples and `fdt-check` passed.

Step 10 repeats the proof on Windows/Vulkan.
