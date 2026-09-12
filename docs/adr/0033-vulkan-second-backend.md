# ADR-0033: Vulkan is the second graphics backend

**Status:** Accepted (constraint only; implementation is M13)
**Date:** 2026-09-13

## Context

[ADR-0003](0003-renderer-own-rhi-metal-first.md) chose Metal first and left the second backend
open in as many words: "Vulkan / D3D12 — unscheduled … Linux implies Vulkan; Windows may be
either, decided then." M13 now exists as the milestone that starts it, and a milestone has to
design against one API rather than two. The choice is therefore made ahead of the work, not
during it.

Three facts decide it. **One Vulkan backend covers both of ADR-0008's non-macOS targets**,
Windows x64 and Linux x64; D3D12 covers one of them. **The RHI's strict model was taken from
Vulkan's guaranteed minimums** — four bind groups because `maxBoundDescriptorSets >= 4`,
128-byte inline constants because that is the push-constant guarantee, declared resource-state
transitions, explicit frames in flight, and +Y-down clip space corrected by a negative-height
viewport. And **an abstraction validated against one API is not validated** (ADR-0003), which
is a debt the second backend is supposed to pay, not defer.

Vulkan is therefore also the API that *tests* the abstraction's premises rather than
confirming them: the assumptions were copied from it, so if they were copied wrongly, this is
where that shows.

## Decision

**The second backend is Vulkan**, serving Windows x64 and Linux x64. **D3D12 is not planned.**

Metal remains macOS's backend and **MoltenVK is still not used** — ADR-0003 rejected routing
the primary platform through a translation layer, and nothing here reopens that. Graphics API
symbols stay inside `rhi` (I7, enforced by the build graph), so this changes no interface above
the RHI and nothing in `render2d` or above learns the word Vulkan.

Vulkan owes its own written binding convention in `docs/design/rhi.md` §9 before implementation,
exactly as Metal's arrived with the Metal backend: the convention is shader-visible, so it is a
contract rather than an implementation detail.

**What this does not decide, and M13 still must.** The shader path to SPIR-V — ADR-0015's
cross-compiler-versus-hand-written-variants question comes due with this milestone and stays
open until then. Whether the loader is linked or opened at runtime. What the build assumes
about validation layers and the Vulkan SDK, which is a toolchain question and therefore
ADR-0014's (a new build tool needs its own ADR). And several of `rhi.md` §13's open questions
that only a second backend can answer: device loss, bind-group lifetime, and whether usage-flag
conformance becomes an eleventh validation rule.

## Consequences

* **Windows and Linux stop being compile-only together**, rather than one at a time. ADR-0008's
  build-check obligation becomes a runtime claim for both at once.
* **The unvalidated-abstraction debt gets paid where it is largest.** Expect RHI design errors;
  ADR-0003 already budgeted for them, and finding them against the API the rules were derived
  from is the most informative place to find them.
* **Cost: Vulkan is the most verbose of the three.** ADR-0003 recorded that a Vulkan-first plan
  would have made M1 "a months-long wall". That wall still exists; it has been moved to M13,
  which makes M13 a large milestone. That is budgeted, not a surprise.
* **Cost: the shader question arrives with it.** Vulkan consumes SPIR-V only, so MSL alone stops
  being sufficient the moment this starts.
* **Windows-only capabilities and their tooling stay out of reach** — PIX, DirectStorage, Xbox.
  RenderDoc covers both Vulkan platforms, which is the tooling that matters for bring-up.
* Licensing is unproblematic: Vulkan-Headers are Apache-2.0 and the loader belongs to the
  platform. Anything vendored still arrives with its `THIRD_PARTY_LICENSES/` entry in the same
  commit (ADR-0016).

## Alternatives considered

* **D3D12 instead** — rejected: it covers one platform where Vulkan covers two, and it exercises
  the RHI's premises least, because those premises were derived from Vulkan. The parts most
  likely to be wrong would go on being untested.
* **Both, in one milestone** — rejected: two backends' worth of work serving one purpose, with
  nothing yet distinguishing which Windows needs. If a reason for D3D12 appears, it is a later
  milestone with its own trigger, exactly as this one had.
* **MoltenVK to unify all three platforms** — rejected again, for ADR-0003's reason: it makes the
  primary development target a second-class citizen.
* **Leave the choice open until M13 begins** — rejected: the milestone's design document has to
  target one API, and deferring meant either writing two designs or writing one and calling the
  decision accidental. `CLAUDE.md` rule 10 puts this in front of the user instead.

## Revisit if

A reason to ship on Xbox or to use a Windows-only capability appears; a Windows GPU vendor's
Vulkan driver proves unusable for this engine's workload on hardware that matters; or bring-up
shows the RHI is Metal-shaped in some way a different second API would have exposed sooner —
which would be a reason to change the RHI, not to change this choice.
