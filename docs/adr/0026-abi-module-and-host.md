# ADR-0026: The `abi` module is a peer of the overlay, and the host supplies its subsystems

**Status:** Accepted
**Date:** 2026-09-07

## Context

M7's first bullet is the public C ABI. [ADR-0004](0004-public-c-abi.md) settled *what* that
surface is — one versioned table of function pointers, opaque handles, result codes, explicit
ownership, untrusted input — and deferred the implementation to here. It did not say where the
module lives or how it reaches the engine, and both turn out to be the same question.

[ADR-0007](0007-module-layering.md) answered it in one line on 2026-09-02: `L5 abi -> app`.
[ADR-0025](0025-debug-overlay-module.md) copied the line forward. **The build graph has since
made it false**, in two separate ways, and both are checkable rather than arguable.

**`app` cannot see three of the modules the ABI has to publish.** Its dependencies are `core`,
`data`, `platform`, `ui`, `rhi`, `asset` and `render2d`. Not `scene`, not `audio`, not
`physics2d` — and each absence is deliberate, with a comment in `build.zig` saying why. Nothing
about that is going to change: `scene` has no `platform` so a simulation cannot read a clock,
`audio` has no `scene` so a system cannot reach the mixer, and both properties are how I9 is
kept structurally rather than by a rule someone has to remember.

Meanwhile six design documents have already written down what this surface publishes, each in
the "what this exposes to mods" section `CLAUDE.md` §5 requires of every subsystem:

| Document | Committed to publishing at M7 | Module | Visible to `app`? |
| --- | --- | --- | --- |
| `entity-storage.md` §11 | declare a component type, register a system, create/destroy entities, add/remove components, query | `scene` | **no** |
| `audio.md` §10 | play by content id, stop, gain/pan/pitch, master gain | `audio` | **no** |
| `tilemaps-and-collision.md` §12 | create/destroy bodies, move, query, read contacts | `physics2d` | **no** |
| `render2d.md` §12 | textures, atlases, fonts, sprites, text, views, cameras, screen↔world, stats | `render2d` | yes |
| `ui.md` §13 | frames, ids, panels, rows, every widget in §10, style, capture | `ui` | yes |
| `debug-overlay.md` §14 | enumerate entities, types, values, packages, records, schemas, assets; scopes; counters; the log; panels | `debug` | **no** |

So `abi -> app` publishes the frame loop, the log, the profiler and the memory counters — and
nothing a gameplay mod is for. M7's exit criterion is a mod that "adds a new component type,
new content, and new behaviour", and two of those three are behind a module `app` does not
import.

**`app` does not own the subsystems either**, which is the deeper half and the half that would
still bite if the dependency list were widened. `app.Engine` has no world, no renderer, no
mixer and no collision world. The game owns them — `samples/sandbox` and `samples/room` own
different sets — and `build.zig` says so in as many words about the renderer: what `app` gained
at M6 was "a function, not an opinion about what a texture is". An `abi` standing on `app`
would therefore have nothing to hand a mod even for `render2d`, which `app` *can* see.

The mistake is worth naming precisely, because it is the natural one: `abi -> app` assumes the
engine is an object that owns the subsystems and the ABI is a veneer over it. Foundry is not
built that way, deliberately. `app` owns the shape of a frame and the order things come up and
go down, and the layering is supposed to say so.

**M6 met this exact problem and answered it.** `debug` needed the UI kernel, the renderer's
statistics, the store, the asset registry, the world and the engine's frame, and no existing
module could see all of them; it became an L5 module with eight dependencies. It needed a world
the engine does not own; `Frame` became a snapshot of the engine's own answers and `Sources`
became what the engine does not own — world, renderer, mixer — supplied by the application. The
ABI is the same shape of problem one milestone later, and it deserves the same shape of answer.

## Decision

**1. `abi` is L5, a peer of `debug`, not a module above `app`.**

```
L5  debug -> core, data, ui, asset, render2d, scene, audio, app
L5  abi   -> core, data, physics2d, platform, ui, asset, render2d, scene, audio, app, mod
```

Under the same rule `build.zig` already states and ADR-0025 was revised by: **a dependency a
module does not use is a claim about the architecture the build cannot check**, so anything on
that list that the implementation does not reach for comes off before it lands.

`rhi` is absent and stays absent. §4.2 is the reason and it is not a matter of use: the RHI is
not public, and a module that could see it is one line away from publishing it.

`platform` is present for exactly one type — `platform.Library`, which is how a native mod is
opened (Tier 3). Everything else a mod reads arrives as content. `mod` is
[ADR-0027](0027-mods-are-content-packages.md)'s module, and `abi` depends on it to learn which
library a manifest names.

**2. The host supplies the subsystems.** `abi` creates no world, no renderer, no mixer and no
collision world, and never will. A game that wants mods hands it the ones it has, in a struct —
the same shape as `debug.Sources`, by the same argument, for the same reason.

**3. A capability whose subsystem is absent answers `Unavailable`. The table's shape does not
change.** Not a null function pointer: a mod author who forgets a null check crashes the host,
and a mod author who forgets a result code gets a no-op that logs. The table for a given
version is one shape, always, which is most of what a version means.

**4. Nothing in the engine depends on `abi`.** A game opts into mods by importing it, exactly
as it opts into the overlay. `app` gains no mod loader and the engine still cannot start one.

**5. `abi` holds no engine state of its own** — only the host's pointers and the bookkeeping
for the mods it has loaded. A call is argument validation, one subsystem call, and a result
code. This is the rule that keeps the widest module in the project from becoming the fattest,
and it is the one to check a proposed entry point against first.

## Consequences

* The six documents above become reachable rather than aspirational, and they were written
  against this without knowing it: every one of those surfaces is already a plain function over
  plain values, because each document was made to answer §5 before it was implemented.
* **The ABI is the union of the engine's game-facing modules, assembled in one place.** That is
  what makes it one surface (I4) rather than a phrase in an ADR: there is exactly one module
  that can see everything a mod may touch, and it is the one whose whole job is to publish.
* A tool is a host with a partial set. The editor (M6+) will hand over a world and a renderer
  and no mixer; a headless content tool hands over nothing. Both get `Unavailable` from the same
  mechanism a mod hits on a server, so there is one behaviour to document and one to test.
* **Cost: `abi` depends on almost the whole engine**, which makes it the widest module in the
  project and means a change anywhere below can break it. That is inherent — one surface over N
  subsystems has N dependencies — and the breakage is the surface failing loudly at build time
  instead of a mod failing quietly at run time. Decision 5 is the mitigation that matters.
* **Cost: two L5 peers now publish introspection**, and `debug-overlay.md` §14 promised mod
  panels at M7. `abi` does **not** depend on `debug`: that would make the overlay mandatory for
  every mod host, and nothing depending on `debug` is the entire reason it is opt-in. So panels
  are **not in `_v1`**, recorded as owed rather than quietly dropped. The shape when they arrive
  is `debug` installing its own section into a table the host assembles, which additive
  versioning already allows.
* Consumers of `abi` are hosts, not the engine, so the module can be built and tested against
  the null platform and null device like everything else — a table is a value, and calling every
  entry point with a garbage handle is a test that needs no window.

## Alternatives considered

* **`abi -> app` as written, with `app` growing to own the subsystems.** Rejected: it makes the
  engine own a world, a renderer and a mixer, which M6 demonstrated is not necessary — two
  samples own different sets — and turns the most honest statement the layering makes into a
  false one. It also makes the engine mandatorily fat: a headless content tool would link the
  mixer to get a frame loop.
* **`abi -> app` as written, publishing only what `app` can see.** Cheapest, and it fails the
  milestone: `entity-storage.md` §11, `audio.md` §10 and `tilemaps-and-collision.md` §12 have
  all committed, and "a new component type and new behaviour" is the exit criterion.
* **One ABI module per subsystem, each publishing its own table.** Rejected by I4: N tables is
  N versioning schemes, N sets of ownership rules, and N places for a tool to acquire something
  a mod does not have — which is exactly the rot ADR-0011 exists to prevent.
* **`abi` inside `app`.** Rejected for ADR-0025's reason, which has not weakened: `app` would
  import `scene`, `audio` and `physics2d` in order to publish them, making the false claim
  `build.zig` names, in the one place the layering is supposed to be self-describing.
* **Null function pointers for absent capabilities.** Rejected: a crash inside a mod, in the
  host, because a feature is missing, is the worst failure mode available here, and a result
  code makes it impossible.
* **A `Host` that is discovered rather than supplied** — the ABI finding the world by asking the
  engine. Rejected: there is nothing to ask. The engine does not have one, and inventing a
  registry for the ABI to look in is decision 5's failure mode with an extra indirection.

## Revisit if

* A capability genuinely needs state in `abi` that no subsystem can hold. That is the first sign
  decision 5 is wrong, and it should be argued rather than accreted.
* The editor finds `Host` too coarse — the cost ADR-0011 already predicted, and the diagnostic
  it said to read as "the mod API is missing something".
* A second host process appears — out-of-process tools, or a dedicated server — and the table
  has to cross a transport rather than a call. ADR-0025 already names that as the change that
  would reshape everything the overlay reads by pointer, and it would reshape this too.
* `debug` and `abi` grow enough shared publishing machinery that being peers costs more than it
  buys.
