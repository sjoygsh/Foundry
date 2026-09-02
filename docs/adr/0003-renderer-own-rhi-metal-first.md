# ADR-0003: Foundry's own RHI with native backends; Metal first

**Status:** Accepted
**Date:** 2026-09-02
**Revised:** 2026-09-02 — the initial version of this ADR made Vulkan the first backend and
treated macOS as Vulkan-via-MoltenVK. That was reversed the same session, before any code
existed, once macOS was established as the primary development target. Revised in place per
the policy in `README.md`. The superseded filename was
`0003-renderer-own-rhi-vulkan-first.md`.

## Context

Foundry is 2D first but must reach 3D without a renderer rewrite. macOS on Apple Silicon is
the primary development target and a first-class supported target; Windows x64 and Linux x64
are intended supported targets that do not yet have a reason to exist in the renderer.

The developer requires that Foundry own its renderer abstraction and speak to real graphics
APIs through backends — SDL3's GPU layer is explicitly not the foundation. Backends are not
Foundry's public API. Equally explicit: do not force everything through Vulkan merely to have
a single API, and do not build Windows or Linux backends before there is a reason.

The first backend should be chosen on learning, simplicity, maintainability, and the ability
to validate the engine locally.

## Decision

Foundry defines its own **RHI** (render hardware interface). Backends live under
`engine/src/rhi/backends/`. **Graphics API symbols appear nowhere outside `rhi`** (Invariant
I7, enforced by the build graph).

**Two distinct abstraction boundaries, not one:**

| Boundary | Audience | Exposed to games/mods |
| --- | --- | --- |
| Renderer API (`render2d`, later `render3d`) | Games, tools, eventually mods | **Yes** |
| RHI (`rhi`) | Engine internals only | **No** |

Games never touch the RHI. This is what the intended architecture diagram means: `Game →
Foundry APIs → Foundry Renderer → Graphics Backend`.

**Backend order:**

1. **Null backend** — first. Records and validates commands, draws nothing.
2. **Metal backend** — the first real backend. macOS on Apple Silicon, via a thin
   Objective-C shim (ADR-0012). Chosen because it is where the engine can actually be run,
   debugged and validated locally; because Metal is markedly simpler to bring up than Vulkan;
   and because Apple's tooling for it is already installed on this machine.
3. **Vulkan / D3D12** — unscheduled. Started when there is a reason: a decision to ship
   Windows or Linux, or a decision to validate the abstraction against a second API.
   Linux implies Vulkan; Windows may be either, decided then.

MoltenVK is **not** used. macOS gets a real Metal backend.

### Designing an abstraction with only one backend

This is the central risk of Metal-first, and it is worth stating plainly: **an abstraction
validated against a single API is not validated.** Metal is the most forgiving of the three,
so an RHI shaped by Metal alone will be one that Vulkan and D3D12 cannot implement
efficiently. Two mitigations, both required:

**1. Design to the strictest model, implement the most forgiving.** The RHI's *interface*
carries the explicit concepts Vulkan and D3D12 need, even where the Metal backend ignores
them:

| Concept | Metal | Vulkan / D3D12 | RHI stance |
| --- | --- | --- | --- |
| Resource hazards | Tracked automatically | Explicit barriers required | RHI declares resource state transitions; Metal backend no-ops them |
| Memory | Storage modes; allocation implicit | Explicit heaps and suballocation | RHI declares memory intent (device-local / host-visible / staging) |
| Unified memory | Real on Apple Silicon | Discrete GPUs have a real host/device split | Never assume writes are free; an engine tuned only on unified memory is slow on discrete hardware |
| Binding | Argument buffers | Descriptor sets / descriptor tables | RHI exposes resource groups that map to all three |
| Sync between submissions | Largely implicit in a queue | Semaphores and fences | RHI is explicit about frames in flight and completion |
| Render passes | Inline descriptors | Render pass objects (or dynamic rendering) | RHI uses inline description with explicit load/store actions |

**2. The null backend becomes a validation backend.** It enforces the strict rules Metal
would silently forgive — missing state transitions, misuse of memory intent, incorrect
lifetime and submission ordering. This recovers much of the discipline a second backend would
impose, at low cost, immediately. It is the reason the null backend is not throwaway
scaffolding.

`docs/design/rhi.md`, including the mapping table above filled out properly, must be written
**before** the Metal backend is implemented.

## Consequences

* The engine can be run, debugged and profiled locally from the first pixel, using Xcode's
  GPU frame capture and Metal validation — tooling already installed.
* "First pixels" becomes a small milestone rather than the largest in the project. Metal
  bring-up is genuinely modest: device, layer, command queue, pipeline state, buffers, draw.
  The earlier Vulkan-first plan made M1 a months-long wall; that wall is gone.
* Real Metal means macOS is a first-class target rather than an emulated one, with native
  performance and Apple's own debugging tools.
* Cost: the abstraction is unvalidated until a second backend exists. Mitigated above, not
  eliminated. Expect the second backend to surface RHI design errors; budget for that rather
  than being surprised by it.
* Cost: Metal is Objective-C, which requires a shim (ADR-0012).
* Cost: shaders are MSL for now (ADR-0015), and a second backend means shader variants.
* Open problem recorded for later: mod-authored shaders will need runtime compilation or a
  shipped compiler. The material system must not assume all shaders are known at build time.
  Metal's runtime MSL compilation makes this tractable on the first backend.

## Alternatives considered

* **Vulkan first, macOS via MoltenVK** — one backend covering all three platforms, and the
  strictest API shaping the abstraction correctly from the start. Rejected: it makes the
  primary development platform a translation-layer second-class citizen, and it front-loads
  the single largest chunk of work in the project before anything can be seen on screen.
* **SDL3 GPU API as the renderer** — backends already written for all three APIs. Rejected by
  explicit developer decision; Foundry owns its renderer.
* **wgpu-native / Dawn** — a good C API and genuinely portable. Rejected for the same reason:
  an abstraction layer we do not control sitting where Foundry's own belongs.
* **OpenGL first** — fastest path to pixels, portable. Rejected: deprecated on macOS,
  a guaranteed rewrite, and it teaches habits that do not survive the move to explicit APIs.

## Revisit if

The RHI proves Metal-shaped when a second backend is attempted; macOS ceases to be the
primary development target; or a decision to ship Windows or Linux arrives, which triggers
backend #2 on its own terms.
