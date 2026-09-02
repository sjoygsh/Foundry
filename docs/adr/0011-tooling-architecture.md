# ADR-0011: Tools are Foundry applications built on the public API

**Status:** Accepted (direction; implementation staged from M6)
**Date:** 2026-09-02

## Context

Foundry will eventually need an editor and a set of content tools. The conventional approach
builds the editor as a privileged application with direct access to engine internals. This is
faster initially and produces two divergent code paths, an editor that can do things the
runtime cannot, and — critically for Foundry — an editor that can do things **mods** cannot.

Once the editor has private access, the mod API is no longer the real API. It becomes a
subset maintained out of goodwill, and it quietly rots.

## Decision

**Tools are built on Foundry, not beside it.** The editor and content tools are Foundry
applications that link the engine and use the same public C ABI exposed to mods (ADR-0004).
No tool gets a private back door (Invariant I4).

Staged:

1. **In-process debug overlay first (M6).** Frame timing, subsystem stats, entity inspector,
   log console, content reload trigger — inside the running game. Cheap, immediately useful,
   no separate application, and it forces the introspection APIs to exist.
2. **Content tools as standalone programs.** `tools/fpack` (content compiler) exists from M3
   and is a plain command-line program.
3. **A separate editor application later (post-M6).** Sharing the engine core, and only when
   the in-process tooling has demonstrated what the editor actually needs.

**Deferred:** the UI toolkit. Foundry needs a game UI system regardless, which argues for
writing a small immediate-mode UI on top of `render2d` rather than taking a dependency.
`cimgui` is the escape hatch if debug tooling is blocking progress. Decided at M6.

## Consequences

* One code path. Tools exercise the same API mods use, so **the mod API stays honest and
  complete by construction** — if the editor needs a capability, mods get it too.
* Mod authors can build their own tools with the same power as first-party ones.
* Building the debug overlay in-process forces introspection APIs to be designed early, which
  benefits both mods and the eventual editor.
* Cost: the editor is constrained by the public API, so some things are more awkward than
  direct internal access would be. That awkwardness is diagnostic — it means the mod API is
  missing something.
* Cost: the ABI must exist before a real editor can. This is why the editor comes after M7.

## Alternatives considered

* **A privileged editor with internal access** — faster to build, more capable sooner.
  Rejected: it forks the code path and lets the mod API rot, contradicting Invariant I4 and
  development rule 12.
* **An editor in a different language/toolkit** (e.g. a web or C# frontend over IPC) — better
  UI ecosystem. Rejected: a second toolchain, a second language, an IPC protocol to maintain,
  and no shared rendering of the actual game.
* **No editor; text files and hot reload only** — cheapest, and viable for a long time.
  Genuinely reasonable, and effectively what happens until M6. Rejected as a permanent answer
  because content authoring at scale needs visual tooling.

## Revisit if

The in-process overlay proves sufficient long-term, or the public API turns out to be a
genuinely poor fit for editor-specific needs like undo, multi-select and asset browsing.
