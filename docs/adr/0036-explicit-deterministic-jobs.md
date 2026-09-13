# ADR-0036: Parallelism is explicit, chunked and order-independent

**Status:** Accepted
**Date:** 2026-09-13 (proposed and accepted the same day, with the design's §8 exit workload and
§6.3 sort rule as proposed)

## Context

`CLAUDE.md` §9 dated the job system and threading model post-M5, and M12 now owns it. Four
milestones passed without one, so nothing depends on a model yet — which is the only reason
choosing one is still cheap.

**I9 constrains it hardest.** A threading model that lets iteration or combination order float
changes results, and determinism cannot be restored afterwards. **Mods constrain it next.** The
system schedule and a query's iteration order are contracts a native mod already relies on
through `FoundryApi_v2`.

What exists is one thread Foundry did not create — the audio device's, with ownership split by
thread and no allocation — a log sink safe from any thread, and allocation counters and a
profiler that are single-threaded by stated assumption. `scene` and `render2d` cannot see
`platform`, so they cannot create threads and must be handed any they use. Zig 0.16 moved
blocking synchronization behind `std.Io`, the newest and least stable part of `std`.

Measured at the planning baseline (`jobs-and-threading.md` §2.3), the windowed sandbox is
display-bound at its own content: about 2 ms of CPU inside an 8.3 ms, 120 Hz frame. At 20,000
to 50,000 sprites the CPU cost that grows is `render.prepare` (about 3.8 ms) and the game's draw
submission (1–1.6 ms). Simulation stays small.

## Decision

1. **Parallelism is an explicit capability, like an allocator.** Any API that may split work
   takes a `core.Jobs`. There is no global pool and no ambient thread count. `core.jobs.serial`
   runs work on the caller, in order, and is the default everywhere.
2. **The only primitive is fork-join over fixed chunks.** Chunk boundaries depend only on the
   item count and the call site's grain; the caller participates and joins; nested calls run
   inline; results combine in chunk order after the join. There are no futures, task graph,
   priorities, cancellation or background jobs.
3. **A chunk writes only what no other chunk touches.** It does not allocate; call the RHI,
   `platform`, a script or the ABI; change a world's shape; or observe its thread or a clock.
   Where the engine provides a chunk's view — a query — the forbidden operations are absent
   from the view rather than asserted.
4. **Systems keep their order.** `World.update` runs systems sequentially in registration
   order. A system may split its own query into chunks of its driving store's dense order.
5. **The pool is Foundry's own, fixed in size, in `platform`, and created by `app`.** It names
   `std.Thread` and `std.Io`'s futex in one file, and `Os`'s `Io` is not handed out. The game
   passes `engine.jobs()` to the world and renderer it owns.
6. **Every call site that splits work is tested with `serial`, a reversed-order serial
   executor and a real pool**, and all three must produce identical bytes.
7. **The public ABI exposes nothing in M12.**
8. **An algorithm's cost is fixed as an algorithm before it is parallelised.** For the
   batcher's sort, the rule is fixed before the measurement that applies it
   (`jobs-and-threading.md` §6.3).

## Consequences

* Determinism is a property of the model rather than of care. Any number of workers, including
  none, computes the same bytes, and the reversed executor turns an order dependence into an
  ordinary failing test on one thread.
* Every existing call site and test is unchanged, because nothing runs in parallel until it is
  handed a `Jobs`.
* Allocation counters, the profiler, the RHI and `platform` stay single-threaded: the join
  means no engine state is shared outside a call.
* Cost: parallel code must be shaped as disjoint chunks with preallocated outputs. Work that is
  naturally a graph, or that must outlive a frame, has no home yet.
* Cost: a join waits for its slowest chunk, so on an asymmetric CPU the default worker count has
  to be measured rather than assumed.
* Cost: Foundry maintains a small thread pool instead of borrowing `std`'s.
* Cost: at the sandbox's own content, frames will not get faster, because the display bounds
  them. The milestone's evidence is CPU time per stage.
* Mods gain nothing yet. The contract is C-shaped, so a later ABI table can add it.

## Alternatives considered

* **A general job system — task graph, futures, work stealing.** What large engines have.
  Rejected because no consumer needs dependencies between jobs or work that outlives a call,
  and the ordering freedom it grants is exactly what I9 would have to take back afterwards
  (`CLAUDE.md` §2, rule 14).
* **Parallel system scheduling from declared read/write sets.** It removes sequential ordering
  between systems that do not conflict. Rejected for M12 because every system, every mod's
  included, would have to make a declaration the ABI must carry, to speed up simulation that is
  not a measured cost.
* **A render thread running a frame behind.** It overlaps work rather than removing it, adds
  latency, and moves renderer state across threads under ADR-0035's retirement model.
  Simulation is too small in either sample for the overlap to matter.
* **`std.Io.Group` or `async` on `Os`'s `Io.Threaded`.** No pool to maintain. Rejected because
  it hands `Io` out of `Os`, shares a growing pool with filesystem work, brings cancellation M12
  does not use, and ties the engine's parallelism to `std`'s least stable API (ADR-0001).
* **Fibers.** Suspendable jobs. Rejected because nothing needs a job to wait, and fibers
  complicate debugging, profiling and the C boundary.
* **Per-subsystem threads with message passing**, as audio does. Right for a device with a
  deadline; wrong for data-parallel loops, where the work is one computation over disjoint
  ranges.
* **No threading, only serial optimisation.** Enough for the samples at their own content.
  Rejected as the whole answer because a game's world will outgrow one core, and choosing the
  model after systems have come to assume a single thread is the expensive order. Decision 8
  keeps the serial fix where it is the right one.

## Revisit if

* A game's simulation is measured CPU-bound across systems → parallel scheduling with declared
  access.
* A consumer needs work that outlives a call, most likely background asset loading → a task
  model.
* M13's Vulkan backend, or a profile, makes command recording a CPU cost → multi-threaded
  recording.
* A native mod's system is measured CPU-bound → chunked iteration in a new ABI table.
* The pinned `std` gains a parallel primitive that meets decisions 1–3 and would retire the owned
  pool.
* M12's worker sweep shows that waiting for the slowest chunk defeats the model on asymmetric
  CPUs.
