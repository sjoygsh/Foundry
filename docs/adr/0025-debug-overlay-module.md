# ADR-0025: The debug overlay is an engine module above `app`, with no private path

**Status:** Proposed
**Date:** 2026-09-07

## Context

M6's first bullet is done: ADR-0024 chose Foundry's own immediate-mode UI, `docs/design/ui.md`
is written, and all six steps of its §16 are implemented. What remains is the rest of the
milestone — an entity inspector, a content browser, a log console, a frame profiler with
per-subsystem timing and per-allocator memory reporting, and, in the roadmap's own words,
"introspection APIs designed with the future public ABI in mind."

`ui.md` §10 stopped deliberately short of all of it, on the grounds that what an inspector may
ask `scene` for is a different subject from what a button is. That subject has to be settled
before any of it is written, because two questions in it are structural and both are expensive
to reverse.

**Where does the overlay live?** It needs the UI kernel, the renderer's statistics, the content
store, the asset registry, the world, and the engine's own frame. There is no existing module
that can see all of those. `app` — the layer that is allowed to see everything (ADR-0007) —
deliberately does not depend on `scene`, and the comment in `build.zig` beside its dependency
list says why: *a dependency a module does not use is a claim about the architecture the build
cannot check.* An engine loop that imports the ECS in order to inspect it would be making
exactly that false claim, in the one place where the layering is supposed to be self-describing.

**What is the overlay allowed to reach for?** This is the question that actually matters, and
it is a question about M7 rather than about M6. I4 says there is exactly one public API surface
and that nothing gets a private back door — *including the editor*. ADR-0011 says tools are
Foundry applications built on that surface, and `CLAUDE.md` §9 schedules a separate editor
application for M6+ with "in-process debug overlay first." So the overlay is the editor's first
draft, and it is being written a milestone before the ABI that the editor will have to stand on.

If it is written against whatever internal Zig call is convenient — reaching into `World.types`,
borrowing `Store.entries`, reading a private field because it is right there — then one of two
things happens at M7, and both are bad. Either the editor is rewritten from scratch against an
ABI nobody validated, or the ABI grows a set of calls shaped by what one internal consumer
happened to need, discovered at the worst possible moment: after the surface is versioned.

Foundry has already solved this problem once. I3 says the base game is content package zero, and
the reason is not tidiness — it is that *the only durable way to know the mod path works is to be
on it ourselves*. The overlay is the same shape of problem and deserves the same shape of answer.

## Decision

**1. The overlay is a Foundry module named `debug`, above `app` in the layering.**

```
L5  debug   -> core, data, platform, ui, rhi, asset, render2d, scene, audio, app
L5  abi     -> app                                                       (M7)
```

`physics2d` is deliberately absent: nothing in M6 asks it a question, and `build.zig` already
states the rule that a dependency a module does not use is a claim about the architecture the
build cannot check. It joins the day a panel wants body and broadphase counts.

Nothing in the engine depends on `debug`. A game opts in by importing it, exactly as it opts into
`render2d` or `audio` today, and a game that does not import it does not build it.

**2. The introspection lives in the subsystem being introspected, never in the overlay.**

Enumerating entities is `scene`'s to offer, because `scene` owns the entity pool and its
documented iteration order. Enumerating packages is `data`'s, and most of it already exists.
`debug` composes those answers into panels and holds no privileged knowledge of anyone's
internals. The module boundary is what makes this checkable rather than aspirational: `debug`
can only call what its dependencies made public, and what they made public is by definition
available to every other consumer too — including, at M7, a mod.

**3. Every call the overlay makes must be one the public ABI could expose.**

Concretely, an introspection call added for the overlay must be shaped so that a C ABI version of
it is a mechanical translation and not a redesign:

* Identity is a **handle or a content ID**, never a pointer into a subsystem's storage (I1).
* Enumeration has a **documented, stable order** (I9), so two runs and two consumers agree.
* Reads are **read-only**, and a returned borrow is valid for the current frame only, which is
  the lifetime rule the frame arena already gives everything else.
* Anything returned that a mod might have supplied — a name, a component's field values — is
  **validated, not asserted** (`CLAUDE.md` §7). The overlay renders a bad answer as a line of
  text saying so, and does not crash the game the player is trying to diagnose.
* No signature depends on a Zig-only type — no error unions in the shape of the answer, no
  tagged unions with slices in them that a C caller could not read.

**4. The overlay is engine code and is not privileged.**

If a panel wants something no public call provides, the answer is to add the public call and
justify it, not to reach around. This is I4 applied a milestone before I4's surface exists, and
it is the whole point of the decision: the overlay is package zero for the introspection API.

## Consequences

**What it makes easy.**

* The editor at M6+ is a re-host of code that already exists rather than a rewrite. Its panels
  move from calling Zig functions directly to calling the same functions through `FoundryApi_v1`,
  and the panel logic between the two is unchanged.
* A mod-authored debug panel at M7 is the same call the built-in panels make, so the mod tier
  gets tooling for free rather than as a later project.
* The introspection API arrives at M7 already validated by a demanding consumer. An API whose
  only user is a specification is a guess.
* A game gets an overlay by importing a module, which is what "a performance problem can be
  diagnosed from inside the running game" requires of *any* game rather than of our sample.

**What it makes hard, and what it costs.**

* **Every introspection call is a compatibility decision.** These names reach mods (`CLAUDE.md`
  §7), so they are chosen with the care given to schema and component names, and adding one is
  slower than reaching into a struct would be. That is the cost, it is charged on purpose, and
  it is the reason this is an ADR rather than a paragraph in a design document.
* Some things are simply slower to reach. Reading a component's field values goes through the
  type's own serializer rather than casting its bytes, because the in-memory layout of a
  component is a Zig struct's and only its *schema* is public. The overlay pays a small copy for
  the entity it is showing, and gets an answer that is correct for a mod-defined component type
  it has never heard of.
* **The engine cannot use `debug` itself.** It is above `app`, so nothing below it can call it —
  no engine subsystem can pop up a panel about itself. This is a real limitation and it is
  accepted: subsystems report through logs and through the values they expose, which is what
  makes them testable headlessly in the first place.
* Per-subsystem timing can only be collected where a clock legitimately exists. `scene` and
  `physics2d` have no `platform` dependency and therefore no clock, by an ADR-0007 decision that
  I9 depends on. The profiler measures those subsystems from their call sites, not from inside,
  and inner detail stays out of M6 rather than being bought by punching a clock downward.

## Alternatives considered

**The overlay lives in `samples/sandbox`.** Rejected. It makes the exit criterion true of our
sample rather than of a game, it leaves the introspection API with no in-repo consumer to prove
it sufficient, and it guarantees the work is written a second time by the first real game.
`docs/design/README.md` already records this bill being paid twice: `samples/room` re-wrote
`samples/sandbox`'s collision wiring near-identically, which turned "the game wires it" from a
design position into evidence about what every game will do.

**The overlay lives in `app`.** Rejected. It forces `app` to depend on `scene` — a claim about
the engine loop that is not true — and makes the overlay non-optional in the one layer every game
links. The frame loop and the tools that watch it have different audiences and different reasons
to change.

**Start with the separate editor application now.** Rejected, and not by us: `CLAUDE.md` §9 says
in-process overlay first and defers the editor to M6+. A separate process needs the ABI, which is
M7, and needs a transport for everything the overlay reads by pointer today. Doing it in this
order is what lets the ABI be designed against a working consumer.

**A general reflection layer** — a module that describes every engine type, from which panels are
generated. Rejected. It is a second description of data that already has one, and
`entity-storage.md` refused precisely this when it made a component type *be* a schema: "kept in
lockstep" is a synonym for "eventually diverges". Foundry already has a runtime description of
every serializable thing, and it is the schema.

**Write the panels first and extract the API afterwards.** Rejected. It is how the API gets
shaped by one consumer's convenience, and the extraction never happens, because by then the
panels work.

## Revisit if

* **M7 arrives and a panel needs something the ABI cannot express.** That is the falsification.
  Either the rule is wrong or the ABI is short a capability, and the answer must say which.
* **`debug` acquires a consumer below it.** If an engine subsystem wants the overlay, the
  layering here is wrong and the split between "introspection" and "the thing that draws it" is
  in the wrong place.
* **The editor becomes a separate application and cannot re-host these panels.** The claim in
  Consequences is that it can; if it cannot, this decision bought nothing.
* **The overlay's own cost becomes the thing being diagnosed.** It reports its own frame time and
  its own batch count for exactly this reason, and if those numbers stop being small the panel
  set needs a different drawing strategy, not a different architecture.
