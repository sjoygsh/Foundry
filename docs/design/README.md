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

None yet.
