# ADR-0061: Background work is a small task graph on its own pool, and its arrival is presentation

**Status:** Accepted 2026-10-18 (the owner asked for M27 Step 1); being implemented in M27
**Date:** 2026-10-18

Amends ADR-0036's decision 2 ("there are no futures, task graph, priorities, cancellation or
background jobs"). The rest of ADR-0036 stands unchanged.

## Context

ADR-0036 made parallelism explicit and fork-join: every split joins before it returns, so no
engine state is shared outside a call. Its "Revisit if" named the consumer that would end that:
"a consumer needs work that outlives a call, most likely background asset loading". M27 is that
consumer. The roadmap line asks for "a task graph and background jobs over `core.Jobs`; assets
load without stalling a frame; also the editor's background compile"
(`docs/design/background.md` §1).

Three facts constrain it:
- **The frame pool cannot host long work.** Its join waits for the slowest chunk, and it
  asserts one dispatcher at a time. A 30 ms decode on its threads would delay the frame it is
  meant to protect.
- **When background work finishes is a wall-clock fact.** It depends on the disk, the machine
  and other processes. I9 forbids wall-clock reads inside simulation, so readiness cannot be
  allowed to reach simulation.
- **The consumers are small.** An asset is a read and decode, then a main-thread finish. A
  model joins on its parts. A build is a snapshot, a compile and a publish.

## Decision

1. **Background work goes through an explicit capability, `core.Tasks`,** handed to whatever
   needs it, as `core.Jobs` and allocators are. `core.tasks.inline` runs a task at once on the
   caller and is the default everywhere. A test executor, `Manual`, completes tasks in any
   order the test chooses.
2. **The graph is minimal.**
   - It has background nodes and main-thread nodes.
   - A node's prerequisites are nodes added before it, so it is acyclic by construction.
   - Capacity is fixed, a failure skips the nodes that depend on it, and cancellation is
     cooperative: a running node finishes, and its output is discarded.
   - A poll may be budgeted.
   - All bookkeeping runs on the polling thread. A worker writes only its node's output and an
     atomic flag.
3. **Background work runs on a second pool, `platform.Background`,** separate from the frame
   pool, fixed in size (default two) and with a bounded queue. A background task never
   dispatches onto the frame pool.
4. **Arrival is presentation.** What a task computes must be deterministic, a pure function of
   its inputs. When it arrives may decide only what is drawn or heard, never what is simulated
   or saved. A game that gates play on loading does so through an input event delivered at a
   frame boundary and recorded like any other input. Main-thread completions run at one point
   in the frame, before any simulation step.
5. **A background node touches no engine state.** It may not use the RHI, windows, audio,
   scripts, the ABI, a world, the store or the registry. It allocates only through a
   thread-safe counted allocator and reads files only through `Os`'s confined calls.
6. **Every consumer is tested under `inline`, under `Manual` in forward and reverse completion
   order with tasks held across polls, and on the real pool,** and the results must be
   identical.

## Consequences

- Loading and building move off the frame without a scheduler. The graph is small enough to
  read in one sitting and to test exhaustively.
- Determinism holds where it matters. Simulation never sees readiness, and every computed
  result is identical whichever executor made it. Frame-level timing of presentation now
  varies between runs, and that is recorded as the cost.
- A game that needs "start when loaded" has to route it through input. M27's sample does not
  need to, and M60 (streaming) will.
- Cost: a second pool competes with the frame pool for cores. Its size is measured, and
  lowering its priority is left to M99.
- Cost: the engine's general-purpose allocator must be thread-safe whenever background workers
  are on, which `Engine.init` cannot verify.
- Cost: a content reload must wait for in-flight decodes (`quiesce`), because records are
  borrowed from the store.
- Mods gain nothing yet. Jobs for native mods are M48's.

## Alternatives considered

- **Run background tasks on the frame pool.** One pool, no second set of threads. Rejected:
  the frame's joins would wait behind decodes, which reintroduces the stall in another place,
  and the single-dispatcher rule would have to be broken.
- **A general job system: futures, priorities, work stealing.** This is what large engines
  have. Rejected because neither consumer needs it, and its scheduling freedom is what
  decision 4 would then have to fence off (CLAUDE.md §2, rule 14).
- **`std.Io.async` or `Group` on `Os`'s `Io.Threaded`.** No pool to own. Rejected for
  ADR-0036's reasons: it hands `Io` out of `Os`, shares a growing pool with filesystem work and
  ties the engine to `std`'s least stable API.
- **Make arrival deterministic,** by finishing loads only at fixed ticks and stalling until
  they are done. Rejected: it reintroduces the stall exactly when a load is slow, which is the
  case M27 exists for.
- **Fibers or coroutines.** Rejected for ADR-0036's reasons: nothing needs a task to suspend,
  and fibers complicate debugging, profiling and the C boundary.

## Revisit if

- A consumer needs a node to wait on a value a later node produces, or dependencies across
  graphs, which would mean a richer graph.
- Step 9's sweep, or a later measurement, shows the background pool slowing a frame's own
  spans past its budget, which would bring M99's thread priority forward.
- A game needs simulation to depend on loading in a way input cannot express.
- The pinned `std` gains a background primitive that meets decisions 2–5.
