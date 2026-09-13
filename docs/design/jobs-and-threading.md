# Jobs and threading: parallel work that cannot change a result

**Status:** designed and **accepted 2026-09-13** (ADR-0036); Steps 1–3 of six implemented.
**Baseline:** `b101745`, M0–M11 complete and tagged `m11`.
**Stop point:** after each step of §11. Resolutions at the end record what each settled.

Specification for M12, **Parallel: "it uses more than one core"**, in
[`ROADMAP.md`](../ROADMAP.md). Rests on [ADR-0036](../adr/0036-explicit-deterministic-jobs.md),
ADR-0001/0007/0010/0013/0023/0026/0035, and the existing
[entity storage](entity-storage.md), [renderer](render2d.md),
[frame loop](app-and-frame-loop.md), [audio](audio.md), [overlay](debug-overlay.md) and
[platform](platform-interface.md) designs. It answers `CLAUDE.md` §9's job-system entry,
`app-and-frame-loop.md` §7's third open question, `entity-storage.md` §14's deferral of
parallel iteration and threading, and the threading notes `core.mem.Counted` and
`debug-overlay.md` §15 left for this document.

## 1. Scope and exit

M12 gives Foundry one way to use more than one core and applies it where a sample spends CPU
time. The exit is the roadmap's: a measured improvement on a real workload in a sample, with
every existing determinism test unchanged and still passing (§10 names them).

The design is one sentence long: **work is split into chunks whose boundaries depend only on
the data, each chunk writes only what no other chunk touches, and results are combined in
chunk order — so a run with any number of threads computes exactly what a run with none
computes.** Everything below is what that sentence costs and where it is allowed.

M12 does not add parallel system scheduling, a task graph, futures, fibers, background or
streaming asset loading, a render thread, multi-threaded command recording, parallel
collision, script concurrency, or anything in the public ABI. §9 says why each waits and what
would bring it back. It adds no dependency and no build tool.

## 2. Evidence at the planning baseline

### 2.1 Threads that already exist

| Thread or shared state | Where | Rule it already follows |
| --- | --- | --- |
| The audio device's callback | SDL3 backend, `audio/mixer.zig` | Foundry did not create it. State is split by owning thread and no field is written by both; two SPSC rings (`audio/ring.zig`) carry commands and retirements; it never allocates (`audio.md`). |
| The log sink | `app/log_sink.zig` | Reachable from any thread: atomic levels, and a spin lock around the ring and session buffer because `logFn` has no `Io` to ask for a mutex. A job system's workers are named as what would make it contend. |
| `Os`'s `std.Io.Threaded` | `platform/os.zig` | Filesystem I/O only. `Os` never lets the `Io` out. |
| Allocation counters, profiler recorder | `core/mem.zig`, `core/profile.zig` | Plain integers, single-threaded by stated assumption; both name a job system as owing them an answer. |

No engine stage runs on more than one thread. `World.update` runs systems in registration
order; a query iterates its first-named store's dense order and asserts on structural change;
`Batcher.plan` sorts by a **total** key, `(view, layer, submission index)`, so that its result
cannot depend on the sort algorithm.

### 2.2 The pinned toolchain

Zig 0.16's `std.Thread` spawns, joins and names threads and counts CPUs; it no longer has a
mutex, a pool or a wait group. Blocking synchronization — `Mutex`, `Condition`, `Semaphore`,
`RwLock`, `Event`, `futexWait`/`futexWake` — belongs to `std.Io` and needs an `Io`. `std.Io`
also offers `async`, `concurrent` and `Group` over `Io.Threaded`'s pool, which defaults to one
thread fewer than the logical CPUs and runs a task inline when every thread is busy.
`std.atomic.Value` needs nothing. Modules accept `sanitize_thread`. `std.Io` is the newest part
of `std` and the likeliest to move again.

### 2.3 Where a sample spends its CPU

Measured on this machine — Apple M5, 10 logical CPUs, 4 performance and 6 efficiency — with the
windowed sandbox on Metal and a 120 Hz display, profiler on. The span columns are the exit
summary's latest frame, top three: one frame's reading, and noisy.

| Build and content | Draws | Median / p95 frame | Latest frame's top spans (ms) |
| --- | --- | --- | --- |
| Debug, API validation, 4,000 sprites (M11 Step 7) | ~4,900 | 8.11 ms / — | prepare 4.09, acquire 2.27, submit 1.30 |
| ReleaseSafe, 4,000 sprites, run 1 | 4,910 | 8.19 / 9.18 ms | acquire 6.85, prepare 1.22, submit 0.60 |
| ReleaseSafe, 4,000 sprites, run 2 | 4,910 | 8.25 / 9.18 ms | acquire 5.71, prepare 1.19, submit 0.58 |
| ReleaseSafe, 20,000 sprites | 20,913 | 8.24 / 9.36 ms | prepare 3.87, acquire 2.55, submit 1.56 |
| ReleaseSafe, 50,000 sprites | 50,913 | 8.43 / 9.17 ms | prepare 3.82, acquire 3.79, submit 1.08 |

The 20,000 and 50,000 runs changed `sandbox:settings.main`'s `sprites` in the working copy,
which was restored byte-for-byte afterwards; nothing was committed.

Three conclusions, and the design depends on all of them:

1. **The sandbox as shipped is display-bound.** At its own content the CPU is busy for about
   two milliseconds of an 8.3 ms frame and waits for the drawable for the rest. No amount of
   parallelism can appear in its frame time, so M12's evidence is the CPU time of the stages it
   changes, not frame time (§8).
2. **The CPU stages that grow with the workload are `render.prepare` and the game's `submit`.**
   Simulation never reached the top three.
3. **The existing report cannot support the exit claim.** It is one frame's top three spans, and
   in it `render.prepare` did not grow between 20,000 and 50,000 draws — which is noise or a
   cost this report cannot see. Step 3 makes the stages measurable before anything is split.

A scratch benchmark mirroring `prepare`'s shapes — not engine code; four random layers and two
textures, so far more batches than the sandbox's fourteen — puts the comparison sort well ahead
of the vertex writes (ReleaseSafe, medians of 200):

| Items | Order + pdq sort | Batch loop | Vertex writes |
| --- | --- | --- | --- |
| 5,000 | 0.22 ms | 0.02 ms | 0.05 ms |
| 20,000 | 0.76 ms | 0.08 ms | 0.15 ms |
| 50,000 | 2.30 ms | 0.21 ms | 0.46 ms |

It is an approximation, and §8's measurement in the real program supersedes it. It is recorded
because it changes the question: if the sort dominates, it is an algorithm's cost before it is
a core count's (§6.3).

## 3. The model

### 3.1 Parallelism is explicit, the way allocation is

`CLAUDE.md` §7 makes allocators explicit so that ownership is visible at every call. M12 does
the same for threads. **Every API that may split work takes a `core.Jobs`.** There is no global
pool, no ambient thread count and no hidden worker. Code handed nothing, or handed
`core.jobs.serial`, runs on the calling thread in order — which is every existing call site and
every existing test, unchanged.

`core.Jobs` is a pointer and a one-function table, shaped like `std.mem.Allocator`:

```zig
pub const Jobs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Calls `task.call(task.context, i)` exactly once for every `i` in `0..count`,
        /// possibly concurrently and in any order, and returns after the last has returned.
        run: *const fn (ptr: *anyopaque, count: u32, task: Task) void,
    };
};

pub const Chunk = struct { index: u32, begin: u32, end: u32 };

/// Splits `0..len` into chunks of `grain` items and runs `chunkFn` on each.
pub fn forChunks(jobs: Jobs, len: u32, grain: u32, context: anytype, comptime chunkFn: anytype) void;
```

`core` holds the interface, the chunking, `serial`, and a test-only `Reversed` that runs chunks
last-to-first on the caller. `core` gains no thread: the interface is data and function
pointers, which L0 may hold, and it is what lets `scene` and `render2d` — which cannot see
`platform` — be handed parallelism rather than reach for it.

### 3.2 One primitive: fork-join over fixed chunks

`forChunks` is the only way work is split. Its contract:

1. **Chunk boundaries are a function of `len` and `grain` alone.** Chunk `i` covers
   `[i·grain, min((i+1)·grain, len))` — never the worker count, a CPU count, a timing or a load.
2. **The caller joins.** `forChunks` returns when every chunk has returned, and the calling
   thread runs chunks too. Nothing is left running between calls, so outside a call every piece
   of engine state is exactly as single-threaded as it is today.
3. **Grain is a named constant at the call site**, chosen for the work and tested at its
   boundaries: 0, 1, `grain − 1`, `grain`, `grain + 1`.
4. **A nested call runs inline.** A chunk that calls `forChunks` runs the inner chunks on its
   own thread in index order. The result is the same by rule 5, and a pool cannot deadlock or
   oversubscribe itself.
5. **Results combine in chunk order, after the join.** A chunk that produces anything writes it
   into a slot the caller preallocated for that chunk index, and the caller reads the slots in
   index order.

There are no futures, dependencies between jobs, priorities, cancellation or background jobs. A
general task system is additive later (§9); designing one now would be designing against a
guess (`CLAUDE.md` §2, rules 7 and 14).

### 3.3 What a chunk may touch

| A chunk may | A chunk may not |
| --- | --- |
| Read memory nothing writes during the call | Read anything another chunk writes |
| Write its own range of a caller-provided output, or its own slot | Write anything another chunk reads or writes |
| Call pure functions and assert | Allocate — outputs and scratch are preallocated per chunk by the caller |
| | Call the RHI, `platform`, a script or the ABI |
| | Change a world's shape, register anything or load content |
| | Observe which thread it is on, a clock or a global RNG |
| | Return an error — it records a failure in its slot, and the caller reports the lowest-indexed one |

Logging from a chunk is permitted and discouraged on a hot path. Log capture is presentation
(M11 Step 7); lines from different chunks arrive in scheduling order, and nothing may read the
log to decide a simulation result — which was already true.

### 3.4 Why this is deterministic

Suppose chunk boundaries depend only on the data (rule 1), chunks' writes are disjoint from each
other's reads and writes (§3.3), no chunk observes its thread or the time, and results combine in
index order (rule 5). Then every interleaving computes the same bytes as running the chunks
serially in index order. That is I9's property with nothing borrowed from luck, and it holds on
one core, on ten, and under `Reversed`.

It holds for floating point too: each element sees the same operations in the same order
whichever thread performs them, and the only reductions across chunks happen in rule 5's fixed
order. ADR-0013 already forbids the compiler reassociating any of it. Bit-exactness across
machines is still not promised.

**Testing follows from the argument.** Every call site that splits work gets a test that runs it
with `serial`, `Reversed` and a real pool of several workers and compares the outputs byte for
byte. `Reversed` makes an order dependence fail deterministically on one thread, rather than
waiting for a race to happen.

## 4. The worker pool, in `platform`

`platform.Workers` is the one implementation with threads. It lives beside `Os` because threads
are an OS service, because parking needs `Os`'s `Io` for futex waits, and because that keeps
`Io` inside `platform`, as `os.zig` already promises.

* **Fixed size, created once.** `Workers.init(gpa, os, .{ .count })` spawns `count` threads;
  `count = 0` is serial. Dispatch allocates nothing.
* **Claiming.** `run` publishes the task and a chunk counter and wakes the workers. Every
  participant, the caller included, claims the next chunk index with an atomic increment until
  none remain; the caller then waits for completion. Idle workers park on a futex. Whether they
  spin briefly first is measured in Step 2, not guessed.
* **Nesting** is detected by a thread-local flag, set on any thread while it runs a chunk, that
  makes an inner `run` serial (§3.2, rule 4).
* **Teardown** wakes, stops and joins every worker. Like an allocator, a `Jobs` must not outlive
  what it came from; hosts already destroy their worlds and renderers before the engine.
* **A panic in a chunk is a panic in the process**, as it is on the main thread today.
* **Containment.** One file, `platform/workers.zig`, names `std.Thread` and `std.Io`'s futex.
  The next `std` move changes that file and nothing else (ADR-0001).

`std.Io.Group` on `Os`'s `Io.Threaded` was the obvious alternative and is not used. It would
hand `Io` out of `Os`, share a dynamically growing pool with filesystem work, carry cancellation
semantics M12 has no use for, and put the engine's parallelism on the least stable API in the
pinned `std`. The pool it would replace is small enough to own (ADR-0036).

**Worker count.** `app.Config.workers: ?u16`, where `null` is the engine's default and `0` is
serial. Until Step 6 measures otherwise, the default is one fewer than the logical CPUs. On this
machine that includes efficiency cores, and a join waits for its slowest chunk, so Step 6 sweeps
the count on the real workload and records the default it chooses and why. Thread
quality-of-service is set only if that sweep shows it matters.

`app.Engine` creates the pool at `init`, after `Os`, destroys it at `deinit`, and returns it as
`engine.jobs()`. The engine owns no world and no renderer (ADR-0026), so **the game** hands
`engine.jobs()` to what it owns — the same shape as everything else a host supplies.

## 5. The engine's single-threaded parts, under jobs

* **Allocation counters** stay plain integers, because chunks do not allocate (§3.3). In Debug
  builds `core.mem.Counted` records the thread that first used it and asserts on any other, so
  the rule is checked where the engine counts memory rather than only written down.
* **The profiler** stays single-threaded. A parallel stage is one span on the calling thread,
  and its time includes the join; time on workers is not attributed.
* **The log sink's spin lock** is unchanged.
* **The audio device thread** is not a worker and never runs a chunk. `audio.md`'s ownership
  split is untouched.
* **The RHI** is called only from the main thread. A chunk may write into memory the caller
  mapped before the split and unmaps after the join, which is how `prepare` uses it (§6.2).
  Validation rule 3 is unaffected.
* **Windows, events and input** stay on the main thread, where SDL requires them.
* **Scripts** never run in a chunk. A Lua VM is single-threaded, and any ABI call a script makes
  may change the world.

## 6. Where M12 splits work

### 6.1 Simulation: systems stay in order; a system may split its own loop

**The schedule does not change.** `World.update` runs systems in registration order on the
calling thread, as `entity-storage.md` §7 defines, and a mod's system — which reaches the world
only through the ABI table — runs exactly as it does today. Automatic parallel scheduling would
need every system to declare what it reads and writes, which is a new contract with every mod
and a new ABI shape; §9 defers it.

What M12 adds is a way for **one system to split its own query**:

* `World` borrows a `core.Jobs`, set by its host with `setJobs` and `serial` until then, and a
  system asks `world.jobs()`.
* A typed query offers `forChunks(jobs, grain, context, chunkFn)`. Chunks are ranges of the
  **driving store's dense array** — the order a query already iterates in
  (`entity-storage.md` §5) — so a chunk visits exactly the matches the serial loop would visit
  in that range, in the same order.
* A chunk receives a **view**, not a world. The view iterates its range and hands out typed
  component pointers; it has no way to create, destroy, add, remove or look up another entity.
  Structural change is therefore unreachable from a chunk rather than asserted, and the world's
  mutation counter is checked on the calling thread before and after the call.
* Disjointness is structural. Each dense position belongs to one entity and each component of
  an entity has one place, so two chunks never write the same component. A system that reads
  *other* entities' components from inside a chunk, through its context, violates §3.3, and the
  view gives it no help doing so.

The sandbox's orbit system — one read and one write per entity — is the first user.

### 6.2 Rendering: `render.prepare`

`render2d.Config.jobs` defaults to `serial`, and both samples pass `engine.jobs()`. Inside
`prepare`:

* **Vertex writes** split by sorted position. Quad `p` writes its own four vertices, in its own
  buffer, from an item nothing writes during the call. Buffers are mapped before the split and
  unmapped after the join. The bytes are identical to serial by construction and are tested as
  such.
* **The sort** is decided at Step 3, from the program's own numbers (§6.3).

### 6.3 The sort is an algorithm question first

`Batcher.plan`'s key is total, so **any correct sort produces the same permutation** — which
makes a parallel sort deterministic for free. It also means the key is small and its tie-break
is submission order, so a stable bucketing by `(view, layer)` produces the same permutation in
linear time on one thread.

The rule, fixed before the measurement so that the measurement cannot choose its own conclusion:
**if Step 3 shows the sort to be the largest CPU cost inside `prepare`, it is replaced with a
serial stable bucketing that is proven to produce the comparison sort's permutation, and it is
not parallelised.** Threads are not used to disguise an algorithm's cost, and a parallel merge
sort is more machinery than a bucketing. If the sort is not the largest cost, it stays as it is.

### 6.4 Not split in M12

* **The game's draw submission** (`submit`, 0.6–1.6 ms in §2.3). Splitting it needs a new
  game-facing `render2d` call whose submission order is merged from chunks — a public name and
  an ordering contract (`CLAUDE.md` §7), which is its own design.
* **Collision and spatial queries.** The samples' collision is one moving body.
* **Content compilation in `fpack`, and asset decoding.** Neither is a sample's frame, and
  background loading changes hot-reload semantics.
* **Anything between frames.** No background job exists, so none has to be reconciled with a
  reload, a save or a frame boundary.

## 7. What this exposes to mods

**Nothing, in M12.** `FoundryApi_v2` is unchanged, a native or script system runs on the main
thread, and no ABI version moves. This is a decision rather than an omission (`CLAUDE.md` §5):
the fork-join contract is already C-shaped — a count, a context, and a function taking a chunk
index — so a later table can add chunked query iteration without changing anything that exists.
Script mods do not get it at all; a Lua VM is single-threaded.

## 8. Measuring the exit

Step 3 builds the measurement and records a baseline before any parallel code exists; Step 6
repeats it.

* **What is measured:** each engine and game span's median over the recorded frames, reported by
  both samples at exit; and `render.prepare` divided into its planning and its writes by two
  engine spans nested inside it, which keeps its name. The renderer cannot read a clock, so
  `app` times the two halves; how the recorder exposes them is settled in Step 3.
* **Where:** the windowed sandbox, Metal, ReleaseSafe, API validation off, on this machine.
* **Workloads:** the sandbox's own content, and a 50,000-sprite workload supplied through the
  ordinary user-package path — a one-record package overriding `sandbox:settings.main`, built
  with `fpack` in a temporary directory and removed afterwards, as M11 Step 9 did for a font. No
  workload content is added to the repository.
* **Comparison:** the same binary with `workers = 0` and with the default, three runs each.
* **Claim:** an improvement is claimed for a span only if every parallel run's median is below
  every serial run's. Frame time is reported and not claimed, because the display bounds it
  (§2.3). The numbers are recorded whatever they show.

## 9. Deferred, with what brings each back

| Deferred | Why not now | Revisit when |
| --- | --- | --- |
| Parallel system scheduling | Needs declared read/write sets from every system, mods' included, and an ABI shape for them | A game's simulation is measured CPU-bound across systems rather than within one |
| Task graph, futures, background jobs | Nothing in a sample needs work that outlives a call | A consumer needs work across frames — most likely background loading |
| Render thread, pipelined frame | Overlaps work rather than removing it; simulation is not a measurable cost in either sample; moves renderer state across threads under ADR-0035's retirement | Simulation and rendering are both measured CPU-heavy in the same frame |
| Multi-threaded command recording | The RHI and both backends are single-threaded by contract | M13's Vulkan backend, or recording measured as a CPU cost |
| Chunked draw submission | A new public renderer call and a merge-order contract | Submission is the largest CPU span left after Steps 4–5 |
| ABI exposure | No native mod needs it; additive later | A native mod's system is measured CPU-bound |
| Worker time in the profiler | The recorder is single-threaded, and one span per stage measures the exit | A parallel stage's efficiency cannot be explained from its span |
| Log sink contention | Chunks are discouraged from logging | A profile shows workers contending on its spin lock |
| Thread QoS or affinity | Unmeasured | Step 6's sweep shows chunks stalled on efficiency cores |

## 10. Determinism tests that must not change

Unchanged in source and passing at every step:

* `app/engine.zig` — "the same frame timings produce the same simulation, twice"; "every step
  in one frame sees the same input"; "capturing and stamping log lines changes neither the clock
  readings nor the simulation".
* `scene/system.zig` — "the same scenario run twice produces identical state"; "systems run in
  registration order, once per update".
* `scene/save.zig` — "two saves of one world are byte-identical"; "iteration order survives the
  round trip".
* `scene/query.zig`, `scene/store.zig` and `core/handle.zig` — their documented iteration-order
  tests.
* `render2d/batch.zig` — "the order is total, so it does not depend on the sort being stable".
* `engine/tests/world_pipeline.zig` — "the same fixed scenario run twice produces identical
  state".
* `engine/tests/script_bindings.zig` — "fresh deterministic runs agree across different frame
  pacing".
* `core/rng.zig`, `platform/backends/null.zig` and `tools/fpack/pack.zig` — the seed, synthetic
  clock and reproducible-package tests.

New tests may run these scenarios with a pool and compare. None of these is edited to make that
possible.

## 11. Implementation order

Six steps. Stop after each.

1. **`core.jobs`.** `Jobs`, `Chunk`, `forChunks`, `serial` and `Reversed`. Tests: boundaries at
   0, 1, grain ± 1 and multiples of grain; every index exactly once; nested calls inline; slots
   read in index order. Nothing uses it yet.
2. **`platform.Workers` and the engine's pool.** The pool (§4), `app.Config.workers`,
   `Engine.jobs()`, teardown, and the Debug owning-thread check in `core.mem.Counted`. Tests:
   repeated dispatch at varied counts; fewer chunks than workers; zero chunks; nesting; init and
   deinit with no dispatch; a counter per index proving every index ran exactly once across real
   threads. One thread-sanitized build of these tests is attempted and its result recorded; it
   is not added to the bar. Neither sample dispatches anything yet.
3. **Measurement and baseline.** Per-span medians in both samples' exit summaries;
   `render.prepare` divided into planning and writes; §8's serial baseline, recorded. §6.3's
   rule is applied and its outcome recorded.
4. **`scene`.** `World.setJobs` and `jobs()`, the chunked query and its view, and the orbit
   system split. Tests: `serial`, `Reversed` and a pool produce byte-identical saves after a
   scripted scenario; a structural change across the call is refused; the ABI's query tests pass
   unchanged.
5. **`render2d`.** `Config.jobs`, chunked vertex writes, and Step 3's sort outcome if it was a
   replacement. Tests: vertex bytes and batch lists identical across `serial`, `Reversed` and a
   pool, at buffer boundaries and at 0 and 1 quads; the validation backend reports nothing; both
   samples' 600-frame null runs print identical output at `workers` 0 and at the default.
6. **Exit proof.** §8's comparison and a worker-count sweep; §10's tests unchanged; the bar.
   Then the documents: `CLAUDE.md` §4.3's `platform` line and §9's row, ADR-0036's status, `entity-storage.md`
   §14, `app-and-frame-loop.md` §7, `debug-overlay.md` §15, `core.mem`'s comment,
   `PROJECT_STATE.md`, `ROADMAP.md` and `AGENTS.md`. Tag `m12`.

**Verification is bounded, as in M11.** Each step runs the bar, breaks its own guards
deliberately to show named tests fail — a chunk boundary derived from the worker count, a merge
out of index order, a view that can mutate — restores the files byte for byte, and ends with a
dated Resolution recording what implementation settled. No recursive audits.

## 12. Open questions

Left to measurement rather than decided here:

1. **Each call site's grain.** Chosen in Steps 4 and 5 and recorded in their Resolutions.
2. **Whether idle workers spin before parking.** Step 2.
3. **The default worker count on an asymmetric CPU.** Step 6.

## Resolution — Step 1, 2026-09-13

`engine/src/core/jobs.zig` holds the interface and nothing with a thread. `core` exports it as
`core.jobs`, and `core.Jobs` beside the other names reached for most often.

What implementation settled:

* **`forChunks` is a method**, `jobs.forChunks(len, grain, context, chunkFn)`, where §3.1
  sketched a free function taking the `Jobs` first. The call reads the way an allocator's does.
  `chunkFn` is `fn (@TypeOf(context), Chunk) void`, checked at compile time.
* **`Reversed` is the value `reversed`**, beside `serial`. Both are stateless `Jobs` constants,
  so neither needs constructing and a test swaps one for the other in a table.
* **A split allocates nothing.** The type-erased context lives on `forChunks`'s own stack
  frame, which outlives every chunk because `run` joins before it returns. A pool implementing
  the table inherits that guarantee.
* **Zero items never reach the executor.** `forChunks` returns before `run` when `len` is zero;
  `run` itself still accepts a count of zero, and calls nothing.
* **Chunk arithmetic cannot overflow.** `chunkCount` divides and adds one for a remainder
  rather than rounding up through `len + grain − 1`, and `chunkAt` computes the unclamped end in
  64 bits. The last chunk of `maxInt(u32)` items at a grain of 2³¹ is tested.
* `Chunk.len()` exists because every chunk body wants it.

Seven tests: boundaries at 0, 1, grain − 1, grain, grain + 1 and a multiple of the grain; the
widest length; every item visited exactly once, by exactly one chunk, under both executors;
`serial` forward and `reversed` backward; results folded from slots in index order agreeing
under both executors **while a shared running total does not** — the test that shows why §3.2
rule 5 exists; a nested split equal to a flat loop; and a shuffling executor that sees only a
count and a task, yet receives every chunk exactly once, and is never reached for zero items.

Evidence:

* Breaking the guards one at a time against the file's own tests, which are the whole blast
  radius because nothing else uses `core.jobs` yet: rounding the chunk count down failed 5 of 7;
  running `reversed` forward failed 2 of 7, the order test and the slot-versus-shared test;
  removing the end's clamp failed the boundary test and then aborted on the widest length's
  overflow check. The file was restored byte for byte after each.
* `zig build test` passed and the bar passed. **1,351 declared / 1,341 headless**, ten
  Metal-only.

Nothing splits work yet. Step 2 adds the pool that makes `run` concurrent.

## Resolution — Step 2, 2026-09-13

`engine/src/platform/workers.zig` is the pool. `Os.startWorkers(gpa, options)` constructs it
with the process's `Io`, which still never leaves `platform`. `platform.Workers` is exported, and
`workers.zig` imports only `std` and `core`, so its tests also compile standalone.
`app.Config.workers: ?u16` sizes the engine's pool — null is `platform.workers.defaultCount()`,
`0` is serial — which is created after `Os` and stopped before it; `Engine.jobs()` returns it.
Nothing splits work yet.

What implementation settled:

* **Parking is a mutex and two condition variables from `std.Io`,** not a hand-built futex
  protocol. The job is published under the lock, so a worker only ever reads a task that was
  completely written before it looked. Claiming stays one atomic increment per chunk; the lock
  is taken a few times per split, never per chunk. The caller waits under the same lock for the
  job's worker count to reach zero, which is what lets the job live on its stack.
* **The caller never waits for a worker that has not joined.** A worker that wakes after every
  chunk was claimed finds the job withdrawn and sleeps again, so a split the caller can finish
  alone costs it almost nothing.
* **A split of one chunk runs inline**, as does any split on a pool of zero threads and any split
  inside a chunk.
* **One dispatcher at a time is asserted**, with a message naming the rule. It is also what a
  nested split trips if the inline guard is removed.
* **A thread that cannot start is a warning.** The pool runs on the threads it got, since fewer
  workers compute the same bytes; `max_count`, 64, bounds a mistaken count. Threads are not
  named; nothing reads a name yet.
* **`core.mem.Counted` records its owning thread in Debug builds** and asserts on any other, in
  all four allocation paths. No existing counter was shared across threads, and the whole suite
  passed with the check on.
* **Idle workers do not spin** (§12, question 2). Measured in ReleaseSafe on this machine with
  50,000 quad-shaped items at a grain of 4,096, medians of two runs:

  | Workers | Split after split | Split after an 8 ms idle |
  | --- | --- | --- |
  | 0 | 0.38–0.42 ms | 2.64–2.68 ms |
  | 1 | 0.27–0.28 ms | 1.31 ms |
  | 3 | 0.20–0.21 ms | 0.64–0.65 ms |
  | 5 | 0.16 ms | 0.44–0.46 ms |
  | 9 | 0.15 ms | 0.48 ms |

  A split of four trivial chunks cost 0.1 µs or less at up to five workers and about 2 µs at
  nine. **After an idle, serial work slows six-fold with no thread to wake**, so the cost is the
  processor's own state rather than the pool's wake-up, and workers shrink it rather than add to
  it. Spinning would buy nothing measurable and would cost power every frame. Nine workers were
  no faster than five; Step 6's sweep on the real workload revisits the default.
* **The thread sanitizer does not run on this toolchain.** Zig 0.16.0's `-fsanitize-thread`
  binaries crash on macOS before running anything: the thread-free `core.jobs` tests, a program
  that only spawns and joins one thread, and one that only locks an `Io` mutex all exit on
  SIGSEGV with no output. There is no sanitizer evidence; the pool's safety rests on the lock
  discipline above and the tests below. It is not added to the bar.

Tests: six in `workers.zig` — every index exactly once across real threads, over 1,820 splits at
counts around the worker count and up to 70,000; bytes identical to `serial`; two chunks provably
running at the same time, bounded so a serial pool fails in ten seconds instead of hanging; a
nested split inline on its chunk's thread, in order; zero workers on the calling thread, in
order; and twenty starts and stops with and without splitting, with `defaultCount`. One in
`core.mem`, the owner recorded. One in `app`: the engine's jobs at 0 and 3 workers match a
serial reference.

Evidence:

* The standalone pool tests passed 20 of 20 repeated runs.
* Breaking the guards against the pool's tests: removing the inline guard tripped the
  one-dispatcher assertion in the nesting test; letting a claim run one index past the end
  aborted the exactly-once test; not advancing the generation, so no worker wakes, failed exactly
  the concurrency test, 5 passed and 1 failed. A counted allocator used from a second thread
  panicked with the owning-thread message. The file was restored byte for byte.
* The bar passed. **1,359 declared / 1,349 headless**, ten Metal-only.

Step 3 builds the measurement.

## Resolution — Step 3, 2026-09-13

Both samples report every span's median at exit, and `render.prepare` is timed in its two halves.
Nothing splits work yet.

What implementation settled:

* **`core.profile.spanMedians(recorder, gpa)`** returns, for each span name in the order it was
  first recorded, the median of each frame's total time in that name over the frames it appeared
  in, and how many frames that was. It sums within a frame, so the sandbox's one-per-step `step`
  spans count as the step cost a frame actually paid.
* **A median over mixed frames can mislead, and the report shows how.** At a 120 Hz display and
  a 60 Hz simulation half the frames run no step, so `simulate`, present on every frame, has a
  median of 0.000 ms while `step`, present on 120 of 240, shows the real cost. Every median is
  printed with its frame count for this reason.
* **One line per span:** `span '<name>': median <ms>ms over <n> of <m> frames`. The sandbox
  prints them after its existing summary; the room prints them when its engine profiles, which by
  default is a Debug build.
* **`render.plan` and `render.write`** are new engine span names, nested inside
  `render.prepare`, which keeps its name and still covers both. `renderFrame` times them only for
  a recorder with `plan() !void`, found at compile time through a pointer or a value. A recorder
  without one keeps the frame's shape from before M12, which a test pins.
* **`Renderer.plan()` is public.** `prepare` plans for itself unless a plan is current: the
  renderer records how many items the plan covered, and items are only ever appended within a
  frame, so an equal count means nothing was drawn since. Every existing caller, none of which
  plans, is unchanged.
* **The workload is §8's user package.** `stress:content` requires `sandbox:content`, is
  compiled with `fpack` into a scratch home's `mods` directory, is selected with
  `FOUNDRY_SANDBOX_PACKAGES`, and was removed afterwards. It carries a copy of the sandbox's
  `settings` schema, spelled `sandbox:settings`, because a package carries every schema its
  records use (`docs/modding/content-mods.md`); a first attempt that left the schema out was
  refused by `fpack` for exactly that. Each run's log names the package in the load order and
  reports 50,000 sprites.

**Baseline.** Windowed sandbox, Metal, ReleaseSafe, API validation off, this machine; 900 frames
per run, medians over the last 240; three runs of each workload, alternated. Ranges are across
the three runs.

| Span (ms) | Sandbox content, 4,952 draws | 50,000-sprite package, 50,954 draws |
| --- | --- | --- |
| `render.prepare` | 1.047–1.059 | 3.690–3.782 |
| — `render.plan` | 0.684–0.702 | 2.846–2.917 |
| — `render.write` | 0.348–0.351 | 0.845–0.865 |
| `submit`, the game's draw list | 0.588–0.590 | 1.096–1.142 |
| `step`, on 120 of 240 frames | 0.377–0.379 | 0.954–0.967 |
| `describe ui` | 0.080–0.081 | 0.017 |
| `render.acquire` | 6.330–6.332 | 2.532–2.533 |
| Frame median / p95 | 8.30–8.34 / 9.25–9.46 | 8.41–8.46 / 8.90–9.30 |

Three readings follow from it:

1. **Frame time is still the display's** in both workloads; even the 50,000-sprite frame waits
   2.5 ms for its drawable. §8's claims are about spans.
2. **Small spans get faster when the frame is busier** — `describe ui` falls from 0.081 to
   0.017 ms for the same work — most plausibly the processor's performance state that Step 2
   measured. Serial and parallel runs at Step 6 are therefore compared on the same workload only.
3. **The largest CPU costs are `render.plan`, then `submit`, `step` and `render.write`.**

**§6.3's rule applies: the sort is replaced, not parallelised.** `render.plan` is 66% of
`render.prepare` at the sandbox's own content and 77% at 50,000 sprites. It holds the batch walk
as well as the sort, but the planning benchmark (§2.3) put the walk at about a tenth of the sort,
so the sort is the largest cost inside `prepare` either way. Step 5 replaces `Batcher.plan`'s
comparison sort with a serial stable bucketing by `(view, layer)`, proven to produce the same
permutation, and splits only the vertex writes. `submit`, at 1.1 ms, is §9's trigger to watch
once Steps 4 and 5 land.

Tests: two in `core.profile` — medians over the frames a span appears in, summed within each and
in first-recorded order; and nothing recorded, nothing reported. One in `app` — a planning
recorder's frame is `input`, `render.acquire`, `render.prepare` with `render.plan` and
`render.write` at depth one, `render.record`, `render.submit` and `render.present`, and a recorder
without `plan` has neither nested span. One in `render2d` — a draw after `plan` makes the plan
stale and `prepare` orders all three sprites, while a current plan and no plan give the same
order.

Evidence:

* Breaking the guards one at a time: trusting any plan however stale aborted the renderer test on
  an out-of-bounds index; never timing the halves failed the engine's span test; counting frames
  in which a span was absent failed the medians test, 5 frames where 3 were expected. Each file was
  restored byte for byte.
* The bar passed, and the room's headless Debug run printed its nine span medians. **1,363
  declared / 1,353 headless**, ten Metal-only.
