# Design: M27 — Background work: a task graph, assets that load without stalling a frame, and the editor's background compile

**Status:** Accepted 2026-10-18, when the owner asked for Step 1, with §14 as written (including item 1: `FoundryApi_v7` in M27, so M48 publishes v8). **Steps 1–2 of 11 are done**; their Resolutions follow §16.
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
