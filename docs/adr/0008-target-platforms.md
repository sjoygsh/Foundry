# ADR-0008: Target platforms

**Status:** Accepted
**Date:** 2026-09-02
**Revised:** 2026-09-02 — the initial version treated macOS as a development host with
deferred shipping status. Corrected the same session, before any code existed: macOS is the
primary development target and first-class supported. Revised in place per the policy in
`README.md`.

## Context

Development happens on Apple Silicon macOS 26 (M5). The architecture must be runnable and
usable locally on macOS from the beginning, not eventually.

Windows x64 and Linux x64 are intended supported targets. Under Metal-first (ADR-0003) they
will not have render backends for some time, which raises a concrete policy question: what
does each milestone actually owe a platform that cannot yet draw anything?

## Decision

**Initial target platforms:**

| Platform | Role | Graphics |
| --- | --- | --- |
| macOS on Apple Silicon | **Primary development target, first-class supported** | Metal (native, not MoltenVK) |
| Windows x64 | Intended supported target | Backend deferred until there is a reason |
| Linux x64 | Intended supported target | Backend deferred until there is a reason |

Other platforms — consoles, mobile, web, VR, x86-64 macOS — are considered later and do not
constrain the initial architecture. Web in particular stays out because it would constrain
threading, file I/O, the graphics API and the mod sandbox.

**Per-milestone obligation to Windows and Linux: build-check, no runtime.**

* Every milestone **cross-compiles** the non-rendering modules — `core`, `data`, `asset`,
  `scene`, and `platform` where SDL3 builds for the target — for `x86_64-windows` and
  `x86_64-linux`. A cross-compilation failure is a bug, fixed in that milestone.
* There is **no obligation to run** anything on Windows or Linux until a backend for them
  exists. Cross-compiling successfully is not evidence that anything works, and this policy
  does not pretend otherwise.
* When a backend for either platform is started, that milestone also establishes real
  hardware or VM testing. Until then, the logistics are not owed.

This keeps portability rot to one-line fixes found early, without making SDL3
cross-compilation a blocker for M0 and without pretending untested cross-builds are support.

## Consequences

* macOS being primary means the engine is genuinely usable locally from day one, with Apple's
  own debugging and profiling tools.
* Cheap, continuous portability pressure on the majority of the codebase. Endianness is a
  non-issue (all targets little-endian), but path handling, case-sensitive vs.
  case-insensitive filesystems, line endings, dynamic library naming and alignment all differ
  and get caught by the build-check.
* Cost: honest acknowledgement that "supported" currently means "compiles." Windows and Linux
  are targets we are *designing for*, not targets we are *testing*. Saying this plainly is
  better than implying coverage that does not exist.
* Cost: a second backend is owed eventually, and it will find RHI design errors (ADR-0003).

## Alternatives considered

* **macOS only until Phase 3** — fastest, zero cross-compilation work now. Rejected:
  platform assumptions accumulate silently in code nobody has ever compiled elsewhere, and
  the bill arrives all at once.
* **Full parity now** — treat all three as first-class immediately, requiring a Vulkan or
  D3D12 backend early. Rejected: contradicts building backends only when there is a reason,
  and would restore the months-long wall that Metal-first removes.
* **macOS as dev host only, never shipped** — cheaper, no Metal backend ever needed.
  Rejected by developer decision; macOS is first-class.

## Revisit if

A decision to ship Windows or Linux arrives, which triggers backend #2 and the corresponding
testing logistics; or the build-check proves to catch nothing useful, in which case it is
ceremony and should be dropped.
