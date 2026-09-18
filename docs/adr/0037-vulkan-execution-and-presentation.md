# ADR-0037: Vulkan keeps submission and presentation-resource lifetime separate

**Status:** Accepted 2026-09-14; implemented in M13, complete 2026-09-19. Superseded by [0039](0039-linux-after-the-first-game.md)
in its M13 Linux completion clause only.
**Date:** 2026-09-14
**Revised:** 2026-09-14 — windowed operation no longer requires swapchain maintenance1, after
the first candidate target's driver lacked it; one unextended presentation path replaces it.
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

The first candidate target, an Intel Arc A750 on Windows 11 x64 with driver 32.0.101.8991,
meets this proposal's Vulkan 1.3 requirements but exposes neither swapchain nor surface
maintenance1. Its capability report and the owner's choice are recorded in
[`vulkan.md`](../design/vulkan.md)'s floor-revision Resolution.

## Decision

1. **Target Vulkan 1.3**, with `dynamicRendering`, `synchronization2` and `timelineSemaphore`
   queried and enabled. Use a single graphics queue that also supports presentation to the
   chosen surface. An incompatible device is refused with a diagnostic listing unmet needs.
   There is no Vulkan 1.0/1.1 fallback or second presentation queue in M13.
2. **Windowed operation uses unextended WSI only.** `VK_KHR_swapchain` and the matching surface
   extensions are required. Swapchain maintenance1 is neither required nor enabled, even where
   offered, so every driver runs one presentation path. Present-wait semaphores belong to
   swapchain images, indexed by acquired image index; reacquiring an index is the evidence
   that the presentation which waited on its semaphore consumed it. An opened frame that drew
   nothing holds its acquired image for the next frame rather than presenting undrawn
   contents. Retired presentation resources are destroyed after submission completion and
   queue idleness. Headless offscreen Vulkan requires no WSI.
3. **Keep `rhi/lifetime.zig` as the retirement authority.** A timeline semaphore measures
   submissions on the one queue, uploads included. Command pools and buffers recycle only
   after the corresponding submission completes. Presentation resources follow swapchain-image
   identity and swapchain retirement instead; frame slots, submission serials and simulation
   time never stand in for them.
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

Unextended WSI keeps every driver meeting the Vulkan 1.3 requirements on one path, including
the first candidate target. Its cost is recorded rather than hidden: presentation has no
completion signal, so destroying present-wait semaphores and retired swapchains after queue
idleness relies on practice the specification does not guarantee. Khronos documents that gap
and validation does not report it. An undrawn acquired image cannot be returned, so at most
one is held, and a rebuild discards it once its submitted uses finish. Step 1 still records
each qualified target's actual capability report.

Descriptor persistence and separate completion tracking cost bookkeeping, but preserve the
engine's existing handle and asynchronous upload contracts. Resource allocation may start
with individual Vulkan allocations with explicit device-limit refusal; suballocation is a
measured follow-up, not a new allocator dependency purchased in advance.

## Alternatives considered

* Vulkan 1.1 plus extension fallbacks: broader coverage, but several execution paths before
  any real workload demands them. Revisit if intended hardware cannot meet the proposed floor.
* Require swapchain maintenance1, this proposal's original floor: presentation fences and
  acquired-image release would close the teardown gap, but the first candidate target's
  Windows driver lacks both extensions. The owner rejected excluding it on 2026-09-14.
* Make maintenance1 optional: two resize, abort and retirement paths, each needing its own
  native evidence, for a guarantee the single path has not yet shown it needs.
* Present an undrawn image after clearing it, or rebuild the swapchain after every undrawn
  frame: the first shows contents no draw produced, contrary to ADR-0035's frame contract; the
  second churns presentation resources for a routine outcome.
* Treat queue idleness as proof of presentation completion: not claimed. It is the accepted
  practical boundary, recorded as a gap, and a quiet validation run does not close it.
* Pool bind groups per frame: breaks existing persistent handle semantics.
* Let SDL create Vulkan surfaces or give `rhi` an SDL window: breaks Foundry's established
  native-surface boundary. Native OS payloads already express the required information.
* Add render threads, transfer queues or a task graph: outside M13; M12's explicit caller-thread
  RHI rule remains in force.

## Revisit if

Required target hardware fails the floor; separate graphics/present families are needed on
a supported machine; a supported driver shows a presentation-teardown fault attributable to
the idle boundary, or a needed capability such as present-mode change or multiple windows
must release acquired images, which makes maintenance1 a decision rather than a fallback;
descriptor or memory allocation churn becomes measurable; or a valid existing RHI command
cannot be implemented under this model. Such a finding changes the
proposal before implementation, or gets a subsequent ADR after code depends on it.

## Technical references

* [Khronos: swapchain semaphore reuse](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
  explains why queue completion does not formally cover presentation resources, indexes
  present semaphores by acquired image, and records the practical idle-wait gap.
* [`vkDestroySwapchainKHR`](https://docs.vulkan.org/refpages/latest/refpages/source/vkDestroySwapchainKHR.html)
  requires only that outstanding operations on acquired images have completed;
  [`VkSwapchainCreateInfoKHR`](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainCreateInfoKHR.html)
  retires `oldSwapchain` even when creation fails.
* [KHR swapchain maintenance1](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_swapchain_maintenance1.html)
  is the extension deliberately not used.
* [SDL window properties](https://wiki.libsdl.org/SDL3/SDL_GetWindowProperties) describe the
  native handle data, corroborated against Foundry's pinned SDL 3.4.14 source during planning.

## Subsequent decision — 2026-09-18

[ADR-0039](0039-linux-after-the-first-game.md) closes M13 on Windows x64 alone. The Linux
qualification and the X11 and Wayland surface evidence required under Consequences move to M18.
That milestone follows the first game built on Foundry and precedes any 3D work. The Linux
payloads and surface paths this record specifies stay implemented and build-checked. The
execution model is unchanged.
