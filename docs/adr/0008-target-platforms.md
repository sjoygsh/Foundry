# ADR-0008: Target platforms and the macOS development host

**Status:** Accepted
**Date:** 2026-09-02

## Context

Windows and Linux are the shipping targets. Development happens on macOS, which the
developer also wants as an eventual shipping target.

Developing on a platform you do not ship creates a real hazard: code that is never run on the
target until late. Zig's built-in cross-compilation removes the *build* half of that problem
but not the *test* half — a cross-compiled binary still has to run somewhere.

## Decision

**Supported platforms:**

| Platform | Role | Graphics path |
| --- | --- | --- |
| Windows | Ship target | Vulkan |
| Linux | Ship target | Vulkan |
| macOS | Dev host now, ship target later | Vulkan via MoltenVK now; native Metal at ship time |

All three are built from any host via Zig cross-compilation. All three must **build** on every
milestone; a build break on a non-host platform is treated as a bug, not as acceptable drift.

Because one Vulkan backend covers all three platforms initially, no additional renderer work
is owed to macOS until it actually ships.

**Testing discipline:** Windows and Linux must be *run*, not merely compiled, at least once
per milestone — on real hardware or a VM. Cross-compiling successfully is not evidence that
anything works. The null RHI backend makes a large share of the engine testable headlessly,
which is what makes automated cross-platform testing practical at all.

Out of scope indefinitely: consoles, mobile, VR, web. Web in particular is excluded
deliberately, as it would constrain threading, file I/O, the graphics API and the mod sandbox.

## Consequences

* macOS being a real target rather than a convenience means platform-specific assumptions get
  caught continuously instead of at the end.
* Endianness is a non-issue (all targets are little-endian), but alignment, path handling,
  line endings, case-sensitive vs. case-insensitive filesystems, and dynamic library naming
  all differ and must be handled in `platform` from the start.
* Cost: a native Metal backend is eventually owed. Deferred, not avoided.
* Cost: real testing requires a Windows machine or VM. This is a standing logistical
  requirement, not a one-off.

## Alternatives considered

* **macOS as a dev host only, never shipped** — cheaper; no Metal backend ever needed.
  Rejected by developer preference.
* **Drop macOS entirely and develop in a Linux VM** — removes the host/target mismatch.
  Rejected: it degrades the daily development experience on the actual machine available.

## Revisit if

MoltenVK proves inadequate for daily development, or macOS is dropped as a shipping target,
which would let the Metal backend be cancelled outright.
