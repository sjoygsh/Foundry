# ADR-0015: Shaders authored in MSL now; shaders are assets with per-backend variants

**Status:** Accepted (implemented at M1)
**Date:** 2026-09-02

## Context

Metal is the first backend (ADR-0003) and its shading language is MSL. A second backend would
want SPIR-V (Vulkan) or DXIL (D3D12). The question is whether to pay the cost of a portable
shader pipeline now, or write MSL now and deal with portability when a second backend actually
exists.

Paying now means adopting a cross-compiler — Slang, or HLSL through DXC to SPIR-V and then
SPIRV-Cross to MSL. These are substantial C++ dependencies, and adopting one would be the
largest dependency in the project, taken on for a backend that does not exist and has no
scheduled date.

## Decision

**Author shaders in MSL directly, for now.**

**Build pipeline:** `xcrun metal` compiles MSL to `.air`, `xcrun metallib` links to
`.metallib`, wired in as a `build.zig` step. Invoked through `xcrun`, never a hardcoded path
(ADR-0014).

**Development builds may also compile MSL from source at runtime** via
`newLibraryWithSource:`, giving shader hot reload. This is not merely a convenience: it is the
same mechanism mod-authored shaders will eventually need, so exercising it early is
deliberate.

**The forward-compatibility constraint, which is the actual decision here:**

> **Shaders are assets, referenced by content ID, with per-backend variants selected at load.**

A material references `foundry:shader.sprite`, not a file path and not an MSL source string.
The asset carries variants keyed by backend. Adding a backend means **adding variants**, not
redesigning the material system. This costs almost nothing now and is what keeps the choice
reversible.

**Postponed to backend #2:** whether that backend's variants are hand-written, or produced by
adopting a cross-compiler and regenerating all variants from a single source language. That
decision is much better made when the shader set's actual size and complexity are known,
rather than guessed at now.

## Consequences

* No large C++ shader-toolchain dependency, at a point where it would serve a hypothetical
  backend.
* MSL is written directly against the API being targeted, with Xcode's shader debugger and
  profiler available — good for learning Metal properly rather than through a translation
  layer.
* Runtime MSL compilation gives shader hot reload from the first backend, and proves out the
  mechanism mods will need.
* Cost: when backend #2 arrives, every shader needs a variant in another language. This is
  small while the shader set is small — which is precisely the argument for deferring the
  decision rather than pre-paying it. It stops being small if the shader set grows large
  first, so **the size of the shader set is the trigger to revisit**, not the arrival of a
  backend.
* Cost: no single source of truth for shader logic in the interim. Mitigated by keeping early
  shaders few and simple; 2D sprite and text rendering does not need many.

## Alternatives considered

* **Adopt a cross-compiler now** (Slang, or DXC + SPIRV-Cross). One shader source, every
  backend generated. Rejected as premature: a large C++ dependency, added for a backend with
  no date, at the point in the project where dependency weight matters most.
* **Write our own shader language or IR.** Full control, no dependency. Rejected as
  substantially overengineered (development rule 14) — this is a compiler project bolted onto
  an engine project.
* **Hardcode shaders as strings in engine source.** Simplest possible. Rejected: it violates
  Invariant I5 in spirit, blocks hot reload, and forecloses mod-authored shaders.

## Revisit if

The shader set grows large enough that maintaining a second set of variants by hand would be
worse than adopting a cross-compiler — or when backend #2 is actually scheduled, whichever
comes first.
