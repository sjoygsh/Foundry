# ADR-0049: Engine-owned shading models, hand-written per backend, behind a registry

**Status:** Accepted 2026-09-27 (constraint only; M19–M24 implement it)
**Date:** 2026-09-27
**Informed by:** ADR-0015, ADR-0019, ADR-0038, `docs/design/3d.md` §5

## Context

3D needs lit, unlit and skinned shading on Metal and Vulkan. ADR-0015 and ADR-0038 left one
question for exactly this point: hand-written variants per backend, one source cross-compiled
(glslang with SPIRV-Cross), or a new shading language (Slang). ADR-0015 also warns that
mod-authored shaders will one day need runtime compilation or a shipped compiler, so the
material system must not assume every shader is known at build time.

## Decision

**Foundry ships a small fixed set of shading models** (unlit, lit, and their skinned variants).
Each is written by hand in MSL and in GLSL compiled to SPIR-V with the pinned SDK tools, and is
embedded (ADR-0019). **No shared shader language or cross-compiler is added** until games or
mods need to author shaders.

**The abstraction is independent of where shader bytes come from:**
- A shading model is a **runtime-registered entry** (I6). It holds its content ID, its parameter
  layout, its texture slots, its required pipeline state, and its per-backend variants.
- A `foundry:material` content record names a model and sets its parameters and textures. It
  never names shader code.
- `render3d` resolves materials through the registry, never through a backend's language.
- A future content-owned shader asset registers entries in the same registry.

## Consequences

- There is no new dependency, and the toolchain is ADR-0038's, unchanged.
- Content mods can make materials on day one, with no code (Tier 1).
- **Every model is written twice.** The set is kept small, and each pairing is a hand-written
  variant.
- Mods cannot author shader code yet. That is a known gap with a named path: a shared language
  or a shipped compiler changes only how entries get their bytes.

## Alternatives considered

- **Cross-compile one GLSL source through SPIRV-Cross now.** It is permissive, but it adds a C++
  build dependency, and at runtime if mods compile shaders, to save writing a handful of
  shaders twice. Its value arrives with mod shader code, which is not due.
- **Slang.** It is the largest dependency, and a language to learn, for the same deferred need.
- **A material system keyed by a switch over known shaders.** It is simpler today, and it would
  have to be torn out the day a mod adds a model. That violates I6 and ADR-0015's warning.

## Revisit if

- A game or mod needs to author shader code or a shading model the engine does not ship.
- The count of hand-written variants becomes a measured maintenance burden.
- A third backend makes writing each model per backend clearly worse than one source.
