# ADR-0002: SDL3 as the platform backend, behind Foundry's own interface

**Status:** Accepted
**Date:** 2026-09-02
**Revised:** 2026-09-02 — acquisition strategy and the Metal surface seam added.

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

SDL3's GPU abstraction is **not** used; rendering is Foundry's own (ADR-0003). SDL3's role at
the graphics seam is limited to producing a native surface for the backend to draw into. On
macOS that is `SDL_Metal_CreateView()` followed by `SDL_Metal_GetLayer()`, which yields the
`CAMetalLayer` the Metal backend renders to.

**How the surface crosses the layer boundary.** `platform` exposes an opaque
`NativeSurfaceHandle` — a tagged pointer whose tag names the surface kind — and `rhi`
interprets it per backend. `rhi` already depends on `platform` (ADR-0007), so this needs no
sideways dependency, and no SDL or Metal type appears in the interface itself.

**Acquisition: a Zig package first.** SDL3 is fetched as a `build.zig.zon` dependency with a
pinned hash, built by a build script that compiles it with the Zig toolchain. This avoids
adding CMake and Ninja (ADR-0014) and cross-compiles cleanly. Because SDL sits behind
Foundry's own interface, that build script is *plumbing*, not an architectural dependency,
and is cheap to replace.

Two documented fallbacks, in order, if that path fails against our pinned Zig release
(ADR-0001): vendor SDL3's source and write our own `build.zig` for it; or, last, build it the
official way with CMake and vendor prebuilt static libraries. **Verifying this is the first
real task of M0** and the single most likely source of unpleasant surprises.

SDL3 is zlib-licensed. Its entry in `THIRD_PARTY_LICENSES/` lands in the same commit that
adds the dependency (ADR-0016).

## Consequences

* A running, input-driven, cross-platform application is reachable in the first milestone.
* Platform-specific bugs in the hard areas are someone else's problem.
* The interface boundary means SDL can be replaced piecemeal — a hand-written Win32 backend
  later would be an addition, not a rewrite.
* Cost: SDL3 must be built for each target. The Zig-package path handles this, but it is a
  third-party build script that can bitrot against a pinned Zig release — a real risk given
  ADR-0001's refusal to track master. Fallbacks are documented above.
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
