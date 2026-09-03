# Design: `core` — memory, handles and identity

**Status:** Implemented 2026-09-02 as `engine/src/core/`. 50 tests.
**Date:** 2026-09-02
**Implements:** I1, I2, I9 · **Informed by:** ADR-0005, ADR-0007, ADR-0013

`core` is layer L0. It imports `std` and nothing else. Every other module depends on it, so
its mistakes are the expensive kind — this document exists so the implementation is
transcription rather than invention.

Two rules shape everything below:

1. **`core` provides mechanism, never policy.** It knows nothing about entities, assets,
   rendering or content. If a decision belongs to a specific subsystem, `core` exposes the
   primitive and lets that subsystem decide.
2. **`core` is where `std` churn is absorbed.** Zig is pre-1.0 and `std` breaks between
   releases (ADR-0001). Every other module imports `core`, not `std`, for anything `core`
   covers. When `std` moves, few files change.

---

## 1. Allocators

### The model

**There is no global allocator.** Every allocating API takes an `Allocator` parameter. This
is already a project convention; what follows is the structure behind it.

Four allocator roles, distinguished by *lifetime*, not by implementation:

| Role | Lifetime | Freed by | Typical use |
| --- | --- | --- | --- |
| **Persistent** | Engine run | Explicit `deinit`, in reverse init order | Subsystem state, registries, loaded assets |
| **Frame** | One frame | Bulk reset at frame end | Per-frame garbage: command lists, culling results, transient strings |
| **Scratch** | One call | Bulk reset on return | Temporary working memory inside a function |
| **Pool** | Engine run, per object type | Slot recycling | Objects a subsystem allocates and frees repeatedly |

`core` supplies the frame/scratch arena wrapper and the pool; the persistent allocator is
chosen by `app` at startup and passed down.

### Concrete choices

* **Persistent, debug builds:** `std.heap.DebugAllocator` — leak detection and
  use-after-free detection are worth the cost while the engine is being built.
* **Persistent, release builds:** `std.heap.smp_allocator`. Chosen now to avoid designing
  around a single-threaded assumption we intend to abandon (the job system is a post-M5
  postponed decision); switching later is a one-line change in `app`.
* **Frame and scratch:** `std.heap.ArenaAllocator`, reset with `retain_capacity` so steady
  state performs no syscalls.

### Rules

* **A frame arena is reset, never freed piecewise.** Nothing allocated from it may outlive
  the frame. Anything that must survive is copied into persistent memory explicitly.
* **Storing a frame-arena pointer in persistent state is a bug**, and one that will look like
  memory corruption rather than a lifetime error. It is the single most likely misuse of this
  model. Debug builds poison arena memory on reset so the failure is loud and immediate
  instead of silent and intermittent.
* **Ownership is stated at every API boundary.** A function that allocates says which
  allocator frees the result. This is doubly binding at the C ABI, where ADR-0004 requires
  explicit allocation rules on every call that transfers memory.
* **Subsystems own their pools.** A subsystem allocating its own object type does so from a
  pool it owns, so its memory can be accounted, reset and torn down as a unit.

### Interaction with I9 (determinism)

Allocation is allowed to be nondeterministic in *address*; it must be deterministic in
*effect*. Concretely: **no behaviour may depend on a pointer value.** No sorting by address,
no hashing a pointer, no iteration ordered by allocation address. This is already an I9
rule; it is repeated here because the allocator is where it is easiest to violate by
accident.

Arena reset is deterministic and cheap, which is part of why per-frame work uses one.

---

## 2. Handles

### The type

```zig
pub fn Handle(comptime T: type) type {
    return extern struct {
        index: u32,
        generation: u32,
        // ...
    };
}
```

Eight bytes. `T` is a phantom tag — it is never stored — so `Handle(Texture)` and
`Handle(Buffer)` are distinct types and cannot be confused at a call site. This costs
nothing at runtime and removes an entire category of bug that plain integer handles invite.

**Layout is `extern struct` deliberately.** Handles will cross the public C ABI at M7
(ADR-0004), and their representation is therefore a compatibility decision, not an
implementation detail. Fixing it now costs nothing; changing it after mods exist costs
everything. At the ABI boundary a handle is passed as an opaque 64-bit value; the field
layout is not part of the published contract, only its size and alignment are.

**The null handle is all-zero bits.** `index = 0, generation = 0`. This makes
`std.mem.zeroes` and `= .{}` produce a null handle naturally, and makes a zeroed struct
safely invalid rather than accidentally pointing at slot 0.

For that to hold, **generations start at 1 and never take the value 0.** Slot 0 is a
perfectly usable slot; it is the *generation* that distinguishes null, not the index.

### The pool

`HandlePool(T)` owns values of type `T` and hands out `Handle(T)`.

```
slots:  [ {generation, state, value} , ... ]   grows, never shrinks
free:   LIFO list of free slot indices, threaded through free slots
```

* **Allocate:** pop a slot from the free list, or append a new one. Set its state to
  occupied. Return `{ index, generation }`.
* **Resolve:** bounds-check the index, then compare generations. A mismatch returns `null` —
  **a stale handle is a normal, recoverable condition, not a crash.** This is the entire
  point of the generation counter and it must never be an assertion, because handles arrive
  from saves, from mods and from tools, and those are untrusted (§5).
* **Free:** increment the generation, mark the slot free, push it onto the free list. Every
  outstanding handle to that slot is now stale and will fail to resolve.

**Slots are never removed from the array.** The array only grows. This keeps indices stable
forever, which is what makes handles meaningful.

### Resolving returns a borrow, not ownership

A successful resolve yields a pointer into the slot array, and that pointer is **valid
only until the next mutation of the pool** — `add` may reallocate. This is not a wart to
be engineered away with stable-address chunked storage; it is I1 restated. Hold the
handle, not the pointer. A pointer kept across an `add` is already the thing handles
exist to replace.

### Generation wraparound

A `u32` generation wraps after 2^32 reuses of *one particular slot*. At sixty
allocate-and-free cycles per second on the same slot, that is roughly two years of
continuous running. After wrapping, a handle held across the entire wrap could alias a
different object.

**Decision: wrap to 1 (skipping 0) and document it.** Retiring slots on wrap would leak a
slot per wrap and complicate the common path for a case that does not occur in practice.
Debug builds count wraps and log a warning at the first one, so if this assumption is ever
wrong we find out from a log line rather than from a bug report.

### Iteration order

**Iteration over a pool is by ascending slot index.** This is stable, documented and
required by I9 wherever iteration order affects outcomes. It is deliberately *not* insertion
order, because insertion order would require extra bookkeeping to maintain across frees.

Consequence worth stating plainly: freeing and reallocating changes iteration order, because
the free list is LIFO and a reused slot returns to its old position. That is deterministic —
the same sequence of operations always produces the same order — but it is not intuitive.
Any system whose *results* depend on iteration order must say so.

### What is deliberately not here

`HandlePool` is a sparse structure: live values are scattered across slots and iterating
them touches cold memory. That is the right trade for things that are looked up by identity
and iterated rarely — textures, buffers, windows, assets, loaded packages.

It is the *wrong* structure for entity components, which are iterated every frame in bulk.
Dense component storage is a separate design (`entity-storage.md`, M4), and ADR-0010
deliberately leaves the strategy open. **Do not generalise `HandlePool` in anticipation of
that**; it would produce a structure that serves neither case well.

---

## 3. Content identity and hashing

### Content IDs

Per I2 and ADR-0005, content is identified as `namespace:name` — `foundry:item.torch` —
hashed to a stable 64-bit value.

```zig
pub const ContentId = extern struct { hash: u64 };
```

The hash is computed over the **exact UTF-8 bytes of the full `namespace:name` string**,
including the colon, with no normalisation: no case folding, no trimming, no Unicode
normalisation. Normalisation would be a second specification that every modding tool would
have to reimplement identically, and any divergence would produce IDs that differ invisibly.
Content IDs are therefore case-sensitive, and the authoring format is expected to enforce a
lowercase convention at *validation* time rather than at hash time.

### The hash function

**FNV-1a, 64-bit.** Specified here rather than referenced, because this value is written
into compiled content and save files and can never change:

```
offset basis = 0xcbf29ce484222325
prime        = 0x00000100000001b3
for each byte b:  hash ^= b;  hash *= prime   (mod 2^64)
```

Test vectors (verified, not remembered):

| Input | FNV-1a 64 |
| --- | --- |
| `""` | `0xcbf29ce484222325` |
| `"a"` | `0xaf63dc4c8601ec8c` |
| `"foobar"` | `0x85944171f73967e8` |
| `"foundry:item.torch"` | `0x6194c021015aae87` |
| `"foundry:core"` | `0xe6c9a3c91df32f3f` |

**Why not simply call `std.hash.Fnv1a_64`?** We may, as an implementation detail — the
algorithm is a fixed published specification, so `std`'s version cannot silently produce
different numbers. What we must not do is let `std` be the *definition*. A `std` that renames,
removes or re-specifies its hash between Zig releases would otherwise invalidate every
compiled content file and every save. The specification above is the contract; `core` owns a
test that pins these vectors, so a `std` change becomes a failing test rather than silent
data corruption.

**Why FNV-1a rather than something faster or better-distributed?** Because the important
property is not speed — IDs are hashed once at content build time and at load. It is that a
mod tool written in Python, C#, or Rust by someone who has never seen Foundry's source can
reproduce it exactly from five lines of documentation. xxHash or Wyhash are better hashes and
worse specifications.

### Collisions

A 64-bit hash over realistic content counts makes accidental collision vanishingly unlikely,
but a collision would be **silent and catastrophic**: two different pieces of content
becoming the same thing.

**Detection belongs at content build time, not at runtime.** The content compiler (`fpack`,
M3) holds every ID string in the build and errors on a collision, naming both strings. This
is a build failure with an actionable message, which is the only acceptable outcome.

Runtime keeps a `hash → string` side table in development builds so logs and errors can say
`foundry:item.torch` instead of a bare number. Shipping builds may drop it. `core` provides
the hash and the `ContentId` type; **the string table belongs to `data`**, because it is tied
to package loading, and `core` holds no content knowledge (rule 1).

---

## 4. Logging

```zig
const log = core.log.scoped(.rhi);
log.warn("swapchain resize failed: {s}", .{reason});
```

* **Scopes are per-subsystem** and are the mechanism for filtering. Five levels: `err`,
  `warn`, `info`, `debug`, `trace`.
* **`debug` and `trace` compile to nothing in release builds.** A disabled log call must not
  evaluate its arguments — formatting cost in a hot loop that produces no output is a trap,
  and one that only shows up in profiles.
* **`core.log` wraps `std.log` rather than exposing it.** Callers never import `std.log`
  directly. This is rule 2 in practice: `std.log`'s API has moved between releases and will
  move again; when it does, one file changes.
* **Logging never allocates on the caller's behalf** and never takes a lock in the current
  single-threaded design — but the interface must not *assume* single-threaded, because the
  job system is postponed, not rejected (§9 of `CLAUDE.md`).
* `std.debug.print` in committed code is a convention violation, not a style preference.

---

## 5. Assertions versus validation

This distinction is a project convention; the reason it appears in a design document is that
`core` provides the two mechanisms and getting them confused is a security bug, not a tidiness
issue.

| | Assertion | Validation |
| --- | --- | --- |
| Guards against | **Our** bug | **Their** bad input |
| Applies to | Internal invariants | Content, mods, saves, tools, files, network |
| On failure | Panic — the program is already wrong | Return an error, log, continue |
| In release builds | May be compiled out | **Never** removed |

`core` exposes:

* `assert.debug(cond, ...)` — programmer error; compiled out in release.
* `assert.always(cond, ...)` — programmer error whose violation would mean memory corruption
  or silent data loss. Retained in release. Use sparingly; every one is a deliberate choice
  to crash rather than continue.

**Never assert on anything that came from outside the engine.** Mod and content input is
untrusted by definition (ADR-0004, §5 of `CLAUDE.md`). A malformed content file must produce
a diagnostic, not a panic — and certainly not undefined behaviour. A stale handle resolving
to `null` (§2) is the archetype: it is *expected*, because handles come from saves.

---

## 6. Math

`core` provides `Vec2/3/4`, `Mat4`, `Rect` and the usual operations, over `f32`. `f64` is
not provided until something needs it, and **quaternions arrive with 3D** — adding them
now would be unused code with no caller to validate the conventions they encode.

**Matrices are column-major in storage**, matching MSL, GLSL and HLSL's default and the
conventions of the graphics literature. `Mat4` is sixteen contiguous `f32` that can be handed
to a uniform buffer without transposition.

**Coordinate system, handedness and the 2D origin are deliberately NOT decided here.** They
are renderer-facing conventions that interact with clip-space differences between Metal,
Vulkan and D3D12, and choosing them before the RHI concept mapping exists would be guessing.
They are owed in `rhi.md` (M1). `core`'s math is convention-free linear algebra; it does not
know which way is up.

**No fast-math, ever** (I9, ADR-0013). This is a build setting, and it is not negotiable for
simulation code.

---

## 7. Time

The layering (ADR-0007) splits time deliberately: `core` owns the *types and arithmetic*,
`platform` owns *reading the clock*. That split is what makes I9's "no wall-clock reads
inside simulation" enforceable by structure rather than by discipline.

* `core.time.Duration` — signed 64-bit nanoseconds. Signed because durations get subtracted
  and a negative result should be representable rather than catastrophic.
* `core.time.Instant` — an opaque monotonic point, produced only by `platform`. Not a
  wall-clock date; not comparable across runs.

**Simulation time is an integer tick count, not a float and not nanoseconds.** The fixed
timestep is a rational — `1/60 s` is stored as numerator and denominator, never as
`0.016666...` — so simulation time is exact at any tick and accumulates no drift. Systems
inside the simulation see tick `N`, never a clock.

This is the concrete mechanism behind I9's fixed-timestep requirement. A float accumulator
would make two runs of the same input diverge for no reason other than rounding, which is
precisely the failure determinism-friendliness is meant to exclude.

The render step interpolates between ticks using an alpha value derived from leftover real
time. **Interpolation is presentation only and must never feed back into simulation state.**

---

## 8. Random numbers

**PCG32.** Small, well-specified, statistically sound, and reimplementable by an external
tool from published pseudocode. Same reasoning as the hash: the algorithm is written down
here, not delegated to `std.Random`, because a reproducible seed is a compatibility promise
and `std` is not a stability contract.

```
state' = state * 6364136223846793005 + inc          (mod 2^64)
xorshifted = ((state >> 18) ^ state) >> 27          (low 32 bits)
rot        = state >> 59
output     = rotr32(xorshifted, rot)                (computed from the OLD state)
```

`inc` is always odd — it is `(stream << 1) | 1` — which is what makes two streams with
different `stream` values genuinely independent sequences rather than offsets of one another.

Reference vector: seed `42`, stream `54` produces
`a15c02b7 7b47f409 ba1d3330 83d2f293 bfa4784b cbed606e`. This is PCG's own published test
output; `core` pins it in a test.

### Rules

* **Generators are passed in, never global** (I9 and project convention). A function that
  needs randomness takes a `*Rng` parameter. There is no `core.random()`.
* **Never seed from the clock inside the engine.** A seed is chosen once, deliberately, by
  whoever owns the run, and is recorded so the run can be reproduced.
* **Streams are split, not shared.** A subsystem derives its own generator from a parent seed
  plus a distinct stream identifier. Two systems sharing one generator couples them: adding a
  single `nextInt` call in the AI code would change the weather, and the resulting bug would
  be nearly impossible to attribute.

Stream identifiers are stable constants, chosen deliberately — they behave like content IDs
in that changing one changes every sequence derived from it.

No third-party code is used for either PCG32 or FNV-1a; both are implemented from their
published specifications, so neither adds a `THIRD_PARTY_LICENSES/` entry.

---

## 9. What `core` does not contain

Recorded because the pull to put things here is strong, and a `core` that accretes becomes a
layering violation with extra steps (I7).

* No content knowledge — no schemas, no records, no packages. That is `data`.
* No I/O beyond what `std` provides for tests. File and window access is `platform`.
* No graphics types. Not even `Color`, if `Color` implies a colour space — that decision
  belongs with the renderer.
* No dense component storage. That is `scene`, at M4 (ADR-0010).
* No job system or threading primitives beyond what `std` gives. Postponed (§9 of
  `CLAUDE.md`) — but nothing here may *assume* single-threaded forever.

---

## 10. Testing

Unit tests colocated in source (project convention). `core` is the one module where tests are
cheap and the payoff is high, because everything else stands on it.

Required before `core` is considered done:

* **Handle pool:** allocate, resolve, free, resolve-stale-returns-null, reuse gives a
  different generation, null handle never resolves, iteration order is ascending by slot,
  wraparound skips generation 0.
* **Hash:** the five vectors in §3 pinned exactly. This test failing after a Zig upgrade is a
  signal that `std` moved under us, which is exactly what it is there to catch.
* **RNG:** the PCG32 reference vector; two streams from one seed produce different sequences;
  the same seed reproduces bit-identically.
* **Arena:** reset reuses memory; debug poisoning triggers on use-after-reset.
* **Time:** tick arithmetic accumulates no drift over a large tick count — the test that
  would fail if someone "simplified" the rational timestep into a float.

---

## 11. Open questions

Deliberately unresolved, recorded so they are not decided by accident:

1. **Should `HandlePool` support a "weak" iteration that skips freed slots efficiently?** With
   heavy churn, iteration walks many dead slots. A live-count or occupancy bitset would fix
   it. Deferred until something actually iterates a sparse pool in a hot path — which may
   never happen, since the hot iteration case is component storage and that is a different
   structure entirely.
2. **Whether `ContentId` should carry the namespace separately** rather than hashing the full
   string. Splitting would allow "all content from package X" queries without a side table.
   Deferred to `content-schemas.md` (M3), where the need will be visible.
3. **Frame arena sizing and whether there are two** (one for simulation, one for render, if
   they ever run concurrently). Trivially changed later; genuinely unanswerable before there
   is a threading model.
