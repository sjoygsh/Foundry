# ADR-0012: Metal accessed through a thin Objective-C shim exposing a C API

**Status:** Accepted (constraint; implemented at M1)
**Date:** 2026-09-02

## Context

Metal's API is Objective-C. Zig cannot speak Objective-C directly. With Metal as the first
real backend (ADR-0003), some bridge is required.

Zig bundles clang and its build system can compile Objective-C sources and link macOS
frameworks, so this is a design choice rather than a tooling problem.

## Decision

A **thin Objective-C shim** in `engine/src/rhi/backends/metal/`, compiled by `build.zig` with
ARC enabled (`-fobjc-arc`), linking `Metal`, `QuartzCore` and `Foundation`. It exposes a
narrow **C header** that the Zig backend calls.

**The shim mirrors Metal roughly one-to-one and contains no policy.** No caching, no state
machine, no cleverness, no decisions. Every design choice — pipeline caching, resource
lifetime strategy, submission scheduling, binding layout — lives in the Zig backend above it.
The shim's only jobs are language bridging and, via ARC, Objective-C object lifetime.

Objects cross to Zig as opaque pointers with explicit create/destroy pairs. Nothing about
Metal's type system is exposed to Zig, and nothing about Zig's is exposed to the shim.

**This is a C ABI boundary inside the engine.** It dogfoods the same discipline ADR-0004
requires of the public API, on a smaller and lower-risk surface, well before the public ABI
is built.

**Standing rule:** if the shim starts accumulating logic, that logic is in the wrong place.
The shim growing a decision is the signal to move it up into the Zig backend.

## Consequences

* Objective-C memory management stays in Objective-C, where ARC handles it correctly, rather
  than becoming hand-written `retain`/`release` calls scattered through Zig.
* The bridge is readable. A person can look at `metal_shim.m` and see exactly which Metal
  calls Foundry makes, which is valuable when debugging against Xcode's frame capture.
* The C header doubles as an inventory of Foundry's actual Metal surface area — useful when
  writing the RHI mapping table for other backends (ADR-0003).
* Cost: a third language in the tree, and a mechanical edit in two places whenever the
  backend needs a new Metal call.
* Cost: an extra indirection per call. Irrelevant at the granularity Foundry calls Metal
  (per-pass and per-draw-batch, not per-primitive), and the RHI is designed for batching
  anyway.

## Alternatives considered

* **Call `objc_msgSend` directly from Zig.** No shim, no extra language. Rejected: every call
  site needs `objc_msgSend` cast to the correct function pointer type, ARC is unavailable so
  lifetime becomes manual `retain`/`release`, and the result is unreadable and easy to get
  subtly wrong. It trades a small amount of build plumbing for a large, permanent readability
  and correctness cost.
* **`metal-cpp`** (Apple's official C++ headers). Well-maintained and complete. Rejected: it
  introduces C++ instead of Objective-C, and Zig-to-C++ interop is meaningfully worse than
  Zig-to-C — which is the boundary we want everywhere anyway.
* **A third-party Zig Metal binding.** Would save the shim entirely. Rejected: an unvendored
  dependency on the most load-bearing part of the first backend, and one likely to track Zig
  master, which ADR-0001 forbids.

## Revisit if

Zig gains usable native Objective-C interop, the shim's maintenance burden becomes
disproportionate, or the shim starts accumulating logic despite the standing rule — the last
being a design smell rather than a reason to change the decision.
