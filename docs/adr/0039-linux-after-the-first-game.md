# ADR-0039: Linux waits for the first game, and comes before 3D

**Status:** Accepted
**Date:** 2026-09-18
**Supersedes:** [ADR-0033](0033-vulkan-second-backend.md) and
[ADR-0037](0037-vulkan-execution-and-presentation.md) in their M13 Linux runtime obligation only

## Context

ADR-0033 chose Vulkan because one backend serves both of ADR-0008's non-macOS targets. It
said Windows and Linux would "stop being compile-only together", with ADR-0008's
build-check becoming a runtime claim for both at once. ADR-0037 then made M13's completion
depend on it: Windows x64 and Linux x64 each needed a qualified runtime environment, and
Linux needed X11 and Wayland surface evidence. Code depends on both records, so neither can
be revised in place.

By M13 Step 8 on 2026-09-18, Windows x64 was a runtime claim: on the owner's Intel Arc A750,
the whole test graph passed with Vulkan selected, and both samples ran from a relocated
install under synchronization validation with no error. Linux had only a recorded route: a
Linux installation on a second drive of that same PC, which has not been made. Its code
paths exist and are compile-checked:
- the X11 and Wayland window payloads;
- the automatic choice of window system;
- the loader opened through `dlopen`;
- Xlib and Wayland surface creation.

None has run.

On 2026-09-18 the owner set the platform order. The first game built on Foundry, developed in
its own repository (ADR-0017), targets macOS and Windows. Linux is added only once that game
is complete, and immediately before any 3D work.

## Decision

**Linux is removed from every current milestone.** M13 closes on Windows x64. Its remaining
steps:
- prove Windows: the RenderDoc capture, frame pacing and what Step 8 left;
- close the milestone.

Its exit criterion was always a sample on Vulkan on a second platform, with the RHI's rules
surviving or changed by ADR, and Windows meets it. M14 to M17 never owed Linux anything, and
still do not.

**Linux x64 runtime support becomes its own milestone, M18, the first of Phase 5.** It is
trigger-started. It begins when the first game is complete, and it finishes before any 3D
work starts. It owes what M13 owed Linux:
- a qualified machine with a hardware Vulkan driver;
- the native test graph with validation required;
- X11 and Wayland as separate runs;
- both samples from a relocated install, with a user package;
- the window icon, with Wayland's compositor limitation documented honestly;
- one inspected RenderDoc capture;
- input and pacing.

**Until then Linux keeps ADR-0008's obligation, build-check and no runtime claim.** The
Linux code paths stay. The bar keeps its null `x86_64-linux-gnu` cross-check, and Vulkan work
keeps compiling that target with `check -Drhi=vulkan` and `vulkan-check`. A Linux compile
failure is still a bug fixed in the milestone that finds it. No document may describe Linux as
supported at runtime until M18 proves it.

**Nothing else changes.** Vulkan remains the backend for Linux, D3D12 remains unplanned, and
ADR-0033's backend choice and ADR-0037's execution model stand as written.

## Consequences

* **The platforms the first game needs are the ones the engine proves first.** macOS is
  primary, and Windows became a runtime claim in M13. No current milestone spends effort on a
  platform that game does not ship on.
* **M13 no longer waits on a machine that does not exist yet.** Its remaining work is
  Windows-only and reachable today.
* **The Linux paths are written but unproven.** Nothing has exercised them on:
  - X11 or Wayland under a real SDL driver;
  - Mesa or any Linux Vulkan driver;
  - Linux window-manager icon behaviour.

  A compile check keeps them building, not working. The longer M18 waits, the more the engine
  grows around them unexercised. M18 should expect to find faults there, as M13 did on
  Windows.
* **Placing M18 before 3D proves the platform against the smaller RHI.** Phase 5 adds depth,
  MSAA, cubemaps, mipmapping and compute to `rhi`. A Linux fault found first is a platform
  fault, not one entangled with new 3D capability. The cost is that 3D waits on both the
  first game and Linux.
* **ADR-0033's "both at once" consequence is withdrawn.** `README.md` and `CLAUDE.md` say
  that Linux is compile-only rather than implying coverage that does not exist (ADR-0008).
* **The Linux SDK pin is kept but unused.** AGENTS.md's Linux archive and hash stay
  recorded. M18 re-qualifies them, and any tool upgrade happens deliberately between
  milestones.

## Alternatives considered

* **Keep Linux in M13:** M13 would stay open until a Linux installation exists. It would also
  spend effort now on a platform the first game does not ship on. The owner rejected it.
* **Drop Linux as a target:** this contradicts ADR-0008 and ADR-0033, and was not the
  owner's decision. Linux stays an intended target with a backend already written.
* **Remove the Linux code paths until M18:** they cost little to keep compiling. They also
  keep the native surface seam honest about more than one window system. Deleting them
  would throw away designed, reviewed work that M18 would then rewrite.
* **Place Linux after 3D:** this is the owner's ordering reversed. It would also prove the
  platform against a larger RHI, entangling platform faults with new capability.

## Revisit if

* The first game decides to ship on Linux. M18 is then pulled into that game's schedule.
* A Linux machine becomes available cheaply and Linux work stops competing with the game.
* 3D work is about to begin, which is when M18 comes due.
* The Linux build-check stops catching anything, in which case ADR-0008's revisit applies.
