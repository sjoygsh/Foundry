# Design documents

Per-subsystem design written **before** implementing anything non-trivial (development
rule 1). A design doc explains the shape of a system and why, so that implementation is
transcription rather than invention, and so a future session can tell intent from accident.

Not everything needs one. Write one when a subsystem has real structural choices, will be
depended on by several others, or will be hard to change later.

## Owed, in order

| Document | Needed before | Why it matters |
| --- | --- | --- |
| `core-memory-and-handles.md` | M0 | Allocator model and the generational handle table. Invariant I1 depends on getting this right, and every subsystem uses it. |
| `platform-interface.md` | M0 | The interface Foundry owns, with SDL3 as one implementation behind it. Watch for SDL concepts leaking into the *design*, not just the implementation. |
| `rhi.md` | M1 | **The highest-leverage document in the project.** Must include the concept mapping table across Metal, Vulkan and D3D12 (see ADR-0003). Designing this against Metal alone is the single most likely way to force a renderer rewrite later. |
| `content-schemas.md` | M3 | Schema model, versioning, package load order and override semantics. |
| `entity-storage.md` | M4 | Type-erased component storage with runtime registration (ADR-0010). |

## Written

| Document | Covers | Decisions worth knowing about |
| --- | --- | --- |
| [`core-memory-and-handles.md`](core-memory-and-handles.md) | Allocator model, generational handles, content ID hashing, logging, assertions, math, time, RNG | Handles are `extern struct` because they cross the C ABI later; null handle is all-zero bits; FNV-1a 64 and PCG32 are **specified in the document**, not delegated to `std`, because both are persisted; simulation time is an integer tick count, never a float |
| [`app-and-frame-loop.md`](app-and-frame-loop.md) | The engine loop, subsystem lifecycle, allocator ownership, the log sink | `Engine` is a library you drive, not a framework that calls you back; input is captured once per frame so every simulation step in it sees the same value; teardown is strictly reverse of initialisation; `alpha` is for the render only |
| [`platform-interface.md`](platform-interface.md) | Window and surface, events and input, filesystem, dynamic libraries, clock, the null backend | Compile-time backend selection with a `comptime` conformance check; logical size and pixel size are never conflated; input is captured into a per-frame immutable snapshot (an I9 requirement); keys are identified by physical position, with text entry as a separate event. **Implemented 2026-09-03**, both backends — see its Resolution for what implementation changed (chiefly the `Os`/`Platform` split and `std.Io` stopping at this layer) and what SDL3 needed absorbing |
