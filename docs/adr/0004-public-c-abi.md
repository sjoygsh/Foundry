# ADR-0004: One versioned C ABI as the single public API surface

**Status:** Accepted (constraint only; implementation deferred to M7)
**Date:** 2026-09-02

## Context

Foundry requires a stable interface between games and mods, and treats modding as
fundamental rather than an addition. Several different consumers will eventually need access
to engine capability: native mods, a scripting host, external tools, an editor, and possibly
bindings for other languages.

The naive approach gives each consumer its own interface. That produces four surfaces to
design, version, document and test, and guarantees they drift — with the editor inevitably
getting privileges mods do not have.

Zig has no stable ABI, so any dynamically loaded native code must cross a C boundary anyway.

## Decision

There is **exactly one public API surface**: a narrow, versioned **C ABI**. Native mods, the
future scripting host, tools and the editor all go through it. Internal engine code does not.

Its shape:

* A **struct of function pointers** — an API table — passed to the consumer at load time
  (`FoundryApi_v1`). New versions are **added alongside** old ones, never replacing them, so
  old mods keep working.
* **Opaque handles only.** No engine struct layouts cross the boundary. Changing an internal
  struct must never break a compiled mod.
* Explicit ownership and lifetime rules on every call that transfers memory.
* Result codes, not Zig error unions.
* All input from the other side is **untrusted**: validated, never asserted.

**What is built now: nothing.** This ADR constrains how subsystems are designed, not what is
implemented. Every subsystem gets a clean internal interface using handles and IDs so that
wrapping it in C later is mechanical rather than a redesign.

## Consequences

* One surface to design, version, document and test.
* The editor cannot cheat. Because tools use the same API as mods (ADR-0011), the mod API
  stays honest and complete — if the editor needs a capability, mods get it too.
* **A capability not reachable through the public API cannot be used by mods.** Therefore
  adding a subsystem includes deciding what it exposes, even when the answer is "nothing yet."
* Cost: an FFI boundary adds indirection and marshalling. For gameplay-rate calls this is
  irrelevant; for per-vertex or per-pixel work it would not be, so the API must be designed
  at the right granularity — batch operations, not per-item calls.
* Cost: additive-only versioning accumulates dead surface over time. Acceptable; the
  alternative is breaking mods.

## Alternatives considered

* **Expose Zig types directly to mods** — no marshalling, full expressiveness. Rejected:
  Zig has no stable ABI, so every engine recompile could break every mod, and mods would be
  locked to Zig.
* **A separate interface per consumer** — each optimally shaped. Rejected: guaranteed drift,
  and the editor ends up with private access, which rots the mod API.
* **Scripting-only modding, no native tier** — simpler and safer. Rejected: it caps what
  power users can do and forecloses tooling and language bindings.

## Revisit if

The FFI boundary proves to be a real performance problem in profiling, or a consumer emerges
whose needs the table model genuinely cannot express.
