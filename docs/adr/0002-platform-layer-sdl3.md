# ADR-0002: SDL3 as the platform backend, behind Foundry's own interface

**Status:** Accepted
**Date:** 2026-09-02

## Context

Foundry needs windowing, input (keyboard, mouse, gamepad with hotplug), events, a
high-resolution clock, filesystem access, dynamic library loading and an audio device, on
Windows, Linux and macOS. Writing these ourselves means Win32, X11, Wayland and Cocoa
backends before the engine does anything interesting.

Foundry's philosophy requires minimal dependence on *proprietary* technology and forbids
adding a dependency to save a *small* amount of code. SDL3 is zlib-licensed, plain C, and
replaces a genuinely large amount of code — including the parts most likely to be quietly
wrong (gamepad hotplug, IME, HiDPI, display enumeration).

## Decision

Use **SDL3** for window, input, events, timing and audio device access.

Foundry defines its **own** `platform` interface. SDL3 sits behind it as one implementation.
**SDL3 types and headers appear only inside `engine/src/platform/`** (Invariant I7,
enforced by the build graph). No other module may reference SDL.

SDL3's GPU abstraction is **not** used; rendering is Foundry's own (ADR-0003). SDL3 is used
for Vulkan surface creation (`SDL_Vulkan_CreateSurface`, `SDL_Vulkan_GetInstanceExtensions`)
and for Metal view creation later.

## Consequences

* A running, input-driven, cross-platform application is reachable in the first milestone.
* Platform-specific bugs in the hard areas are someone else's problem.
* The interface boundary means SDL can be replaced piecemeal — a hand-written Win32 backend
  later would be an addition, not a rewrite.
* Cost: SDL3 must be built or vendored for each target. Building it from source through
  `build.zig` is preferred for cross-compilation; linking a prebuilt library is the fallback
  if that proves painful.
* Cost: Foundry's platform interface will initially be shaped by what SDL provides. Watch for
  SDL concepts leaking into the interface's *design*, not just its implementation.

## Alternatives considered

* **Write our own platform layer** — maximum control and learning. Rejected on schedule: it
  costs months before the engine does anything, and Vulkan bring-up is already the long pole.
* **GLFW** — smaller and cleaner, but no audio, weaker gamepad support, and less coverage of
  the awkward platform cases.
* **SDL3 including its GPU API** — one dependency for everything. Rejected by explicit
  developer decision; the renderer is to be Foundry's own (ADR-0003).

## Revisit if

SDL3's release cadence or licensing changes, a platform we need is unsupported, or SDL's
abstractions start distorting the design of Foundry's platform interface.
