# ADR-0062: An asset loader may split into a pure decode and a main-thread finish

**Status:** Accepted 2026-10-18 (the owner asked for M27 Step 1); being implemented in M27
**Date:** 2026-10-18

## Context

`asset.Loader` has one `load(ctx, gpa, record, bytes)` that decodes and makes the payload in a
single call on the main thread. For a texture, that call decodes the PNG, generates its mip
chain and uploads it, and the first two are most of the cost. M27 must load assets without
stalling a frame (`docs/design/background.md`). Under ADR-0061 a background thread may not
touch the device, the registry or any engine state.

So the CPU work must be separable from the device work. That separation has to be one
implementation, or the synchronous and background paths will drift apart. The public ABI's
`asset_acquire` promises a complete, synchronous result to mods. Loaders are registered at
runtime (I6), and loaders nobody splits, a mod's included once M48 publishes registration,
must keep working.

## Decision

1. **A loader may add three optional functions, all or none:**
   - `decode(decode_ctx, gpa, record, bytes) LoadError!Decoded` is pure. It reads only its
     read-only `decode_ctx`, the record and the bytes, and allocates through the thread-safe
     allocator it is handed.
   - `finish(ctx, gpa, record, decoded, budget) LoadError!Payload` runs on the main thread and
     may use the device.
   - `discard(gpa, decoded)` frees what nobody will finish.

   A partial set is refused at registration.
2. **For a split loader, `load` is `decode` followed by `finish` on the calling thread.** The
   synchronous and background paths share one implementation and so make the same payload.
3. **`acquire` stays synchronous and complete.** It completes a pending entry if it meets one.
   `asset_acquire` and every existing caller keep their meaning.
4. **`request` is the background path.** It returns a counted handle at once, with every
   refusal that needs no bytes reported synchronously. The entry is `pending`, then `ready` or
   `failed`, and finishes run in the engine's per-frame `pump` under a byte and count budget.
5. **A loader with no split still loads through `request`.** Its read happens on a worker and
   its `load` runs as the finish. It works, and simply moves less.
6. **The store changes only after `quiesce`,** because records are borrowed from it. A source
   reload through a split loader decodes in the background, and the old payload stays current
   until the new one is finished.

## Consequences

- Every engine loader with real CPU work moves it off the frame without a second
  implementation. A texture's bytes are the same whichever path made it, which is tested.
- Mods are unaffected. A mod's acquisition is synchronous as before, and a host's pending
  entry is completed for it.
- Pending is a new state, but it is visible only through new calls. `get` returns null for it,
  which every caller already handles for a stale handle.
- Cost: a loader's author now chooses where its work runs, and must keep `decode` pure. The
  rule is written on the field, and the test executor makes a violation that depends on order
  fail.
- Cost: a decoded value lives in memory between decode and finish, bounded by what is in
  flight and by the pump's budget.
- Cost: a content reload waits for in-flight decodes.

## Alternatives considered

- **A second, asynchronous loader interface beside `Loader`.** This would keep `load`
  untouched. Rejected: two interfaces per kind means two implementations that must agree, and
  they would drift apart.
- **Decode on a worker and let the worker create the GPU resource too.** The RHI would be
  called from a background thread. Rejected because the RHI and its backends are
  single-threaded by contract (ADR-0035, ADR-0036). Making them thread-safe is M99's render
  thread, not a loading feature.
- **Make `acquire` itself asynchronous.** Rejected because it would break `asset_acquire`'s
  published meaning and every synchronous caller, the court's and the room's among them.
- **Generate mips at build time in `fpack`,** removing the largest decode cost without threads.
  Rejected here because ADR-0055/`meshes.md` §4.2 placed mips at load with measured load time
  as their trigger. M27 removes the stall either way, and moving mips into packages changes
  every package's size. That remains `meshes.md`'s question, now with M27's numbers to answer
  it.

## Revisit if

- A loader cannot be expressed as a pure decode and a device finish, for example one that must
  read several files whose names it learns while decoding.
- The pump's finish cost, rather than the decode it replaced, becomes a frame's largest
  loading cost. That would point at uploads from a transfer queue, which belong to M99.
- M48 publishes loader registration and mods need the split themselves.

## Revision note — 2026-10-18, in M27 Step 10

This note answers the second "Revisit if". On Windows/Vulkan a texture's finish became the
frame's largest loading cost. For each 21 MiB chain, the staging allocation took 1.1–5.8 ms and
the copy into uncached upload memory 1.6–9 ms, against a 2.0 ms pump p95. The owner chose to
move the copy rather than the queue. A transfer queue stays M99's.

So a split may add an optional **stage**:
- a main-thread `prepare`, which reserves mapped memory the device reads;
- a pool `fill`, which copies the decoded value into it and touches nothing else;
- a main-thread `release`, for a reservation that no finish consumed.

The finish consumes the reservation. Decision 1's three functions are unchanged. Decision 2
now reads: decode, then prepare, fill and finish when staged, on the calling thread. The RHI
is still called only on the main thread. A pool thread writes memory that the main thread
mapped, which is ordinary memory.
