# ADR-0014: Minimal toolchain — Zig only, no CMake or Ninja

**Status:** Accepted
**Date:** 2026-09-02

## Context

The starting machine has Xcode 26 (SDK 26.5) with the on-demand Metal toolchain downloaded,
Apple clang, git, Python 3.14 and Homebrew. It does not have Zig, CMake, Ninja or pkg-config.

The requirement is to add the minimum tooling actually needed, with a specific instruction not
to adopt large build systems or development tools merely because they are conventional, and to
evaluate whether CMake and Ninja are genuinely necessary before adding them.

## Decision

**Install exactly one thing: Zig.** A specific stable release, from the official release
tarball, unpacked at a versioned path, with the version and SHA256 recorded in-repo. Not via
Homebrew — a package manager can silently move the compiler under an unrelated upgrade, which
defeats the pinning ADR-0001 requires.

**Already present and sufficient, requiring no installation:**

| Need | Provided by | Notes |
| --- | --- | --- |
| Metal framework, headers | Xcode 26 SDK | `Metal.framework`, `QuartzCore.framework` |
| Objective-C compilation | Zig's bundled clang + Xcode SDK | For the shim (ADR-0012) |
| Metal shader compiler | On-demand Metal toolchain | `xcrun metal`, `xcrun metallib` |
| GPU frame capture, Metal debugger | Xcode 26 | The Metal equivalent of RenderDoc |
| Metal API validation | Environment variables | No install required |
| Version control | git | |
| Ad-hoc scripting | Python 3.14 | Developer convenience only, never load-bearing in the build |

**Important:** the Metal toolchain resolves through a versioned on-demand mount path.
**Always invoke it via `xcrun metal` / `xcrun metallib`, never a hardcoded path** — the path
changes when the toolchain component updates.

**Deliberately not added: CMake, Ninja, Make, pkg-config.** Zig's build system already
provides everything they would be adopted for:

* Compiling C, C++ and Objective-C sources — needed for SDL3 and the Metal shim.
* Cross-compilation to Windows and Linux, with no additional toolchains (ADR-0008).
* Dependency fetching with pinned content hashes, via `build.zig.zon`.
* A test runner.
* Custom build steps — which is how Metal shader compilation is wired in (ADR-0015).

Adding CMake and Ninja would buy nothing that is currently missing, at the cost of a second
build language, a second dependency model, and a second place for platform logic to live.

**Homebrew stays available as an escape hatch**, not as a build requirement. Nothing in the
build may assume it exists.

**Deferred until there is a reason:** the Vulkan SDK and RenderDoc, both only at backend #2
(ADR-0003). Note that RenderDoc does not support Metal; Xcode's frame capture is the tool for
the first backend, and it is already installed.

**Standing rule: adding a build tool requires an ADR.** Not a preference — the toolchain is
part of the project's reproducibility, and tools accumulate silently otherwise.

## Consequences

* Setup for a new machine is: install Xcode, install the pinned Zig, clone. That is a
  genuinely short list for a native engine project, and it stays short.
* One build language. Build logic is Zig, engine is Zig, tests are Zig.
* Reproducibility: pinned compiler, pinned dependency hashes, no package-manager drift.
* Cost: if the SDL3 Zig package fails against our pinned release, the fallback is writing our
  own `build.zig` for SDL3 — real work that CMake would have avoided (ADR-0002).
* Cost: Zig's build system is pre-1.0 and its API changes between releases, so `build.zig`
  itself is subject to the same churn as the rest of the language. Contained by the same
  pinning discipline.

## Alternatives considered

* **CMake + Ninja for C dependencies, Zig for engine code.** The conventional, best-supported
  path for building SDL3. Rejected: two build systems, two dependency models, and an explicit
  instruction not to add conventional tooling without need.
* **Homebrew for Zig.** One command, easy upgrades. Rejected precisely because upgrades are
  easy and implicit — the opposite of what ADR-0001 requires.
* **A Zig version manager (`zvm`, `anyzig`).** Convenient for switching versions. Rejected as
  unnecessary for a project that deliberately pins one version at a time; revisit only if
  multi-version testing becomes routine.

## Revisit if

A required dependency genuinely cannot be built by Zig's build system, in which case CMake
enters as a scoped, documented exception rather than as the project's build system.
