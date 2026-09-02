# ADR-0003: Foundry's own RHI with native backends; Vulkan first, null backend for headless

**Status:** Accepted
**Date:** 2026-09-02

## Context

Foundry is 2D first but must reach 3D without a renderer rewrite. Ship targets are Windows
and Linux; macOS is a development host and eventual ship target. The developer explicitly
requires the renderer to talk to Vulkan/Metal/D3D directly rather than through SDL3's GPU
abstraction.

The relevant risk is schedule, not architecture: Vulkan bring-up — instance, device,
swapchain, render pass, pipeline, descriptors, buffers, synchronization, frames in flight,
resize — is the largest single unit of work in the near roadmap, and everything else in the
engine is small next to it.

## Decision

Foundry defines its own **RHI** (render hardware interface): a command-buffer and
render-pass shaped abstraction over explicit modern APIs. Backends live under
`engine/src/rhi/backends/`. **Graphics API symbols appear nowhere outside `rhi`.**

Backend order:

1. **Null backend** — validates and records commands, draws nothing. Built first.
2. **Vulkan backend** — serves Windows and Linux natively and macOS via MoltenVK. One
   backend covers all three platforms initially.
3. **Metal backend** — later, when macOS becomes a shipping target rather than a dev host.
4. **D3D12** — postponed indefinitely; Vulkan covers Windows.

The Vulkan loader is **loaded dynamically at runtime** (`dlopen`/`LoadLibrary`, resolving
function pointers ourselves). Shipped builds have no link-time dependency on the Vulkan SDK.

The RHI is shaped for 2D use initially but must not encode 2D-only assumptions: depth,
multiple render targets, and compute must be expressible later without redesign.

Shaders are authored in GLSL and compiled to SPIR-V offline as a build step, with the SPIR-V
committed for reproducible builds.

## Consequences

* The correct long-term architecture, with no abstraction layer we do not control between
  the engine and the GPU.
* **"First triangle" becomes the largest milestone in the project.** Accepted deliberately.
* The null backend is the mitigation and is not throwaway: it lets the loop, input, asset,
  content and world systems proceed while Vulkan is in progress, and it permanently buys
  headless tests, CI, and a possible future dedicated server.
* MoltenVK means macOS development works without a Metal backend, deferring that cost to
  when macOS actually ships.
* Cost: Vulkan is verbose and unforgiving; validation layers and RenderDoc become part of
  the standard workflow early.
* Open problem recorded for later: mod-authored shaders will need runtime compilation or a
  shipped compiler. The material system must not assume all shaders are known at build time.

## Alternatives considered

* **SDL3 GPU API as the renderer** — one dependency covering platform and GPU, backends for
  Vulkan/Metal/D3D12 already written. Rejected by explicit developer decision in favour of
  direct control.
* **OpenGL first, modern API later** — fastest path to pixels. Rejected: it is a guaranteed
  rewrite, it is deprecated on macOS, and its immediate-mode-ish shape teaches habits that
  do not survive the move to explicit APIs.
* **wgpu-native / Dawn** — a good C API and genuinely portable. Rejected for the same reason
  as SDL GPU: it is an abstraction layer we do not control.

## Revisit if

Vulkan bring-up stalls the project for an extended period, MoltenVK proves inadequate for
macOS development, or a target platform appears that Vulkan cannot serve.
