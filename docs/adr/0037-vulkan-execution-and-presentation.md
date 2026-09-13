# ADR-0037: Vulkan keeps submission and presentation completion separate

**Status:** Proposed (M13 design; no implementation)
**Date:** 2026-09-14
**Builds on:** ADR-0003, ADR-0008, ADR-0033 and ADR-0035

## Context

The owner requested M13's architecture after M12 closed at `f14caac`, supplying ADR-0033's
trigger of validating the RHI against a second API. Implementation has not been authorized
in this planning session. Vulkan already is the chosen backend; this record proposes its
execution contract, including the hardware requirements that must be accepted before Step 1.

The existing RHI has one graphics queue, persistent handles, explicit barriers, independent
command recordings, uploads outside frames, and completion-backed retirement. Its frame ring
is not a submission counter. In Vulkan it is not a presentation-completion counter either:
a submission fence does not establish that the presentation engine finished using its wait
semaphore. The distinction matters during ordinary reuse, resize, failed frames and teardown.

The native surface seam currently carries a tagged pointer. An X11 window ID alone lacks its
display connection; a Wayland surface lacks its display; Windows surface creation needs the
instance as well as the window. Completing the existing seam does not require SDL in `rhi`.

## Decision

1. **Target Vulkan 1.3**, with `dynamicRendering`, `synchronization2` and `timelineSemaphore`
   queried and enabled. Use a single graphics queue that also supports presentation to the
   chosen surface. An incompatible device is refused with a diagnostic listing unmet needs.
   There is no Vulkan 1.0/1.1 fallback or second presentation queue in M13.
2. **Windowed operation requires swapchain maintenance1**, accepting the KHR extension or
   its EXT predecessor, with the matching surface extension, dependencies and feature bit.
   Use its presentation fences and acquired-image release. Prefer KHR when both are usable.
   This deliberately narrows driver coverage: Vulkan 1.3 alone is insufficient for a window.
   Headless offscreen Vulkan requires neither WSI nor maintenance1.
3. **Keep `rhi/lifetime.zig` as the retirement authority.** A timeline semaphore measures
   submissions on the one queue, uploads included. Command pools and buffers recycle only
   after the corresponding submission completes. Presentation fences separately govern
   reuse and destruction of presentation resources; they never masquerade as submission
   serials or simulation time.
4. **Keep persistent, immutable bind groups.** Descriptor sets come from device-owned pools
   and retire through the existing recording/completion model. No frame reset invalidates a
   public handle. Pools reclaim only sets whose retirement is complete. A pipeline retains
   its native layout backing independently of the caller's layout handle.
5. **Keep explicit resize, with a bounded retry for WSI invalidation.** Resize is applied
   between frames. An out-of-date acquisition with no resize event permits rebuilding from
   fresh surface capabilities before the next successful acquisition; it opens no frame.
   Only extent/image identity may change this way. The negotiated surface format stays fixed
   for the device lifetime, because the renderer's pipelines were built against it. A true
   lost surface/device remains fatal; no automatic device reconstruction is introduced.
6. **Complete the native window seam with platform-owned payloads.** Keep the outer tagged
   pointer and the Metal payload meaning. Windows/X11/Wayland payloads contain only opaque OS
   handles and integer window identity, are stable until the window closes, and are copied
   by `rhi` at device creation. An automatic native-window request lets `platform` choose the
   actual active Linux window system. It returns a concrete surface kind, never a Vulkan or
   SDL object. Device destruction still precedes window destruction.
7. **Write down the portability gaps before enforcing them.** Descriptor-buffer alignment
   and range limits become internal RHI capabilities and validation rule-10 checks, populated
   by all backends. Arbitrary byte counts for inline constants remain legal: Vulkan pads a
   private copy to its four-byte command granularity. Host memory visibility and transfer
   layout restrictions are implemented inside the backend where possible. Any further
   restriction on formerly legal commands requires a dated design Resolution before code.

The complete ownership, barriers, error mappings, test matrix and step order are in
[`vulkan.md`](../design/vulkan.md). This proposal clarifies `rhi.md` §§7 and 9 rather than
replacing the RHI, its eleven rules, or ADR-0035. It changes no public C table, asset format,
system schedule or mod capability. Nothing above `rhi` acquires Vulkan API types.

## Consequences

Windows x64 and Linux x64 each need a qualified runtime environment before claiming M13
completion; Linux needs both X11 and Wayland surface evidence. A Mac can produce cross-builds
and run pure tests, but cannot provide those results. MoltenVK remains excluded by ADR-0033.
Step 1 qualifies an actual target and records a concrete route to the other platform before
backend implementation proceeds. No remote access or machine availability is assumed here.

Requiring maintenance1 buys a specified way to release an unused acquired image and to prove
presentation-resource teardown. It excludes older or incomplete drivers even when their core
Vulkan version suffices. Step 1 must expose that tradeoff with actual capability reports; it
must not quietly remove the requirement when the first device fails it.

Descriptor persistence and separate completion tracking cost bookkeeping, but preserve the
engine's existing handle and asynchronous upload contracts. Resource allocation may start
with individual Vulkan allocations with explicit device-limit refusal; suballocation is a
measured follow-up, not a new allocator dependency purchased in advance.

## Alternatives considered

* Vulkan 1.1 plus extension fallbacks: broader coverage, but several execution paths before
  any real workload demands them. Revisit if intended hardware cannot meet the proposed floor.
* Treat `vkDeviceWaitIdle` as proof of presentation completion: rejected; the unextended WSI
  shutdown gap is explicitly documented by Khronos, and a quiet validation run cannot fix it.
* Make maintenance1 optional immediately: requires a second resize, abort and retirement
  strategy whose purpose is compatibility not yet requested. The proposed floor makes that
  cost visible before implementation rather than obscuring it in a fallback.
* Pool bind groups per frame: breaks existing persistent handle semantics.
* Let SDL create Vulkan surfaces or give `rhi` an SDL window: breaks Foundry's established
  native-surface boundary. Native OS payloads already express the required information.
* Add render threads, transfer queues or a task graph: outside M13; M12's explicit caller-thread
  RHI rule remains in force.

## Revisit if

Required target hardware fails the floor; separate graphics/present families are needed on
a supported machine; descriptor or memory allocation churn becomes measurable; or a valid
existing RHI command cannot be implemented under this model. Such a finding changes the
proposal before implementation, or gets a subsequent ADR after code depends on it.

## Technical references

* [Khronos: swapchain semaphore reuse](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
  explains why queue completion is insufficient for presentation-resource reuse and shutdown.
* [KHR swapchain maintenance1](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_swapchain_maintenance1.html)
  specifies presentation fences, image release and extension dependencies;
  [the EXT predecessor](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_swapchain_maintenance1.html)
  documents its promotion and aliases.
* [SDL window properties](https://wiki.libsdl.org/SDL3/SDL_GetWindowProperties) describe the
  native handle data, corroborated against Foundry's pinned SDL 3.4.14 source during planning.
