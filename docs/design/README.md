# Design documents

Per-subsystem design written **before** implementing anything non-trivial (development
rule 1). A design doc explains the shape of a system and why, so that implementation is
transcription rather than invention, and so a future session can tell intent from accident.

Not everything needs one. Write one when a subsystem has real structural choices, will be
depended on by several others, or will be hard to change later.

## Owed, in order

Written documents move to the table below. This one is a schedule, not an index.

| Document | Needed before | Why it matters |
| --- | --- | --- |
| `entity-storage.md` | M4 | Type-erased component storage with runtime registration (ADR-0010). |

## Written

| Document | Covers | Decisions worth knowing about |
| --- | --- | --- |
| [`core-memory-and-handles.md`](core-memory-and-handles.md) | Allocator model, generational handles, content ID hashing, logging, assertions, math, time, RNG | Handles are `extern struct` because they cross the C ABI later; null handle is all-zero bits; FNV-1a 64 and PCG32 are **specified in the document**, not delegated to `std`, because both are persisted; simulation time is an integer tick count, never a float |
| [`rhi.md`](rhi.md) | Devices, resources, memory intent, resource states, the frame ring, command recording, pipelines and binding, the validation backend | Every decision taken from the **strictest** API, not the first one implemented: four bind groups because Vulkan only guarantees four, 128-byte inline constants because that is Vulkan's push-constant minimum, `device_local` resources are never mappable so unified memory cannot become a habit, and state transitions are declared at pass boundaries and enforced by the null backend. **Metal backend implemented 2026-09-04**; §9 gained the binding index convention it forced — which is shader-visible, and so a contract each future backend owes its own written version of |
| [`app-and-frame-loop.md`](app-and-frame-loop.md) | The engine loop, subsystem lifecycle, allocator ownership, the log sink | `Engine` is a library you drive, not a framework that calls you back; input is captured once per frame so every simulation step in it sees the same value; teardown is strictly reverse of initialisation; `alpha` is for the render only |
| [`render2d.md`](render2d.md) | The game-facing 2D renderer: submission model, coordinate spaces, camera, sprites, batching, buffers, textures and atlases, text, statistics | The **first boundary with users we do not control**, so names here are compatibility decisions; immediate submission with retained resources, so `scene` is not duplicated and the ABI stays simple; `app` owns the frame and the game never sees a render pass; world Y is up and screen Y is down; the sort key is `(layer, submission_index)` and never texture, because reordering translucent sprites is wrong; colour is linear throughout; the renderer keeps **its own retirement queue** rather than trusting the RHI's unimplemented deferred destroy. **Design only — not yet implemented** |
| [`content-schemas.md`](content-schemas.md) | Schemas, records, packages, the `.fdt` authoring format, the `.fpk` runtime format, load order and override semantics | `data` depends on **`core` alone**, so it cannot open a file — the parser is handed bytes and resolves `@import` through a caller-supplied callback, which makes the whole content pipeline a pure function and every test hermetic; two separate ID spaces for schemas and content; `core` refuses to normalise IDs, so `data` refuses to accept anything that would need normalising; content IDs are bare tokens rather than strings so a typo fails at compile time and `grep` finds every use; directives are `@`-prefixed so a future one can never collide with a mod's schema name. **Parser, schema registry and checker implemented 2026-09-04**; see its two Resolution sections for the three syntax decisions implementation forced and the five the checking pass did |
| [`assets.md`](assets.md) | Asset identity, ID derivation, the registry, runtime-registered loaders, hot reload | An asset is a content record and its identity is its content ID; a path *derives* an ID at compile time and `fpack` materialises it into the package, so no runtime code can resolve anything by path; derivation transforms nothing, for the same reason `core` refuses to normalise; `render2d` registers the texture loader into `asset` from above, so the dependency points down while the capability points up. **Design for M3; the PNG decoder is implemented** |
| [`platform-interface.md`](platform-interface.md) | Window and surface, events and input, filesystem, dynamic libraries, clock, the null backend | Compile-time backend selection with a `comptime` conformance check; logical size and pixel size are never conflated; input is captured into a per-frame immutable snapshot (an I9 requirement); keys are identified by physical position, with text entry as a separate event. **Implemented 2026-09-03**, both backends — see its Resolution for what implementation changed (chiefly the `Os`/`Platform` split and `std.Io` stopping at this layer) and what SDL3 needed absorbing |
