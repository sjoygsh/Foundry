# ADR-0027: A mod is a content package, and its manifest is a record inside it

**Status:** Accepted
**Date:** 2026-09-07

## Context

M7's second and third bullets are mod manifests — id, version, dependencies, compatibility
range, and a **license field** ([ADR-0016](0016-licensing.md)) — plus discovery, dependency
resolution and deterministic load order.

Four places defer to this decision by name and refuse to pre-empt it:
`content-schemas.md` §11 ("`data` consumes an order; it does not compute one"), §6 (load order
is "an explicit, ordered list supplied from outside"), `assets.md` §7, and `tools/fpack`'s own
module doc, which takes the package's name and version as command-line arguments and says in
its header that inventing a manifest format there would be answering this question in the wrong
place.

What exists today: `app.Config.content` is a hand-written ordered list of `{ file, root }`
pairs, and `fpack --name foundry:core --version 1` supplies a package's identity from outside
the package. Both work exactly as long as the application knows every package by name, which is
the condition M7 removes.

**The question is not what format a manifest is.** It is what a mod is made of, and that
answers the format for free. Look at the three tiers (`CLAUDE.md` §5):

* **Tier 1** is a content package and nothing else — and it already works. M3's second exit
  criterion was a package placed after the sandbox's that changed a value and replaced a font,
  and M5's was a mod replacing a sound from a file under its own directory layout with nothing
  rebuilt. Neither needed a mod system. What they needed was to be named in a list by hand.
* **Tier 3** is that, plus a native library.
* **Tier 2** is that, plus scripts (M8).

Every tier is a content package with something optional attached. So the thing being discovered
is a package, the thing being ordered is a package, and the thing a dependency names is a
package.

## Decision

**1. A mod is a content package.** Its identity is the package's content id (I2). There is no
second identity space, no mod id distinct from a package id, and no directory name that means
anything — a folder is where bytes happen to sit, which is ADR-0021's rule for assets applied
one level up.

**2. The manifest is a record inside the package**, of a schema `foundry:mod` declared in
`content/core` — package zero declaring the vocabulary, which is what package zero is for (I3).
It needs no new syntax, no new parser and no new versioning scheme, because a record is already
all three:

```
foundry:mod  brighter:mod {
    name        "Brighter Lamps"
    version     3
    license     "MIT"
    requires    [ { id foundry:core  min 1 }  { id room:content  min 2 } ]
    engine      { min 7 }
}
```

The field set is `public-abi.md`'s to specify; what this ADR fixes is that it is a record, of an
engine-declared schema, living in the package it describes.

**3. Every package has one, including the engine's.** `content/core` carries a `foundry:mod`
record using the schema it declares, and is discovered, ordered and loaded by exactly the code a
mod goes through. That is I3 stated as strongly as it can be: package zero is not merely *like*
a mod, it is one.

**4. `fpack` reads the name and version from the manifest**, and `--name` / `--version` go away.
A package that says two different things about itself becomes impossible rather than merely
discouraged. The compiler gains a pre-pass — parse, find the `foundry:mod` record, take the
package name from the namespace of its id, then check everything else against it — because the
namespace of a locally declared schema depends on the package name, and the package name now
comes from inside.

**5. Discovery, dependency resolution and load order live in a new module, `mod`, at L2**
(`core`, `data`, `platform`), **below `app` rather than above it.** Two reasons, and the first
is decisive:

* **A Tier 1 mod list must be computable by a game that loads no code at all.** Most mods are
  content, most games hosting them will never call `dlopen`, and an answer that lived above the
  engine — in `abi`, or in a launcher — would put the common case behind the rare one.
* Its output is exactly the ordered list `app.Config.content` already consumes, so `data` still
  consumes an order and does not compute one. `content-schemas.md` §6 is unchanged; something
  else computes the order now, and that something is not the engine loop either.

`mod` reads a candidate package's manifest by opening its `.fpk` alone — the store's own
resolution already established that a `.fpk` can be read with nothing but itself, and this is
the consumer that property was predicted for.

**6. Load order is a deterministic function of `(available packages, enabled set)`** (I9).
Dependencies form a DAG; the order is a topological sort with a **documented tie-break — by
content id, ascending** — which is the only tie-break available that does not depend on
directory enumeration order or on hash-map iteration. Same packages, same enabled set, same
order, on every machine, every run. The algorithm and what happens to a cycle, a missing
dependency or an unsatisfiable range are `public-abi.md`'s to specify; the property is fixed
here.

**7. `mod` never opens a library.** The manifest *names* one; `abi` opens it
([ADR-0026](0026-abi-module-and-host.md)). The half of M7 a Tier 1 game needs therefore contains
no code loading at all, and a game can host content mods without linking the ABI.

## Consequences

* **Tier 1 modding stops needing a hand-written list**, which was the only thing between M3's
  claim and a mod a player installs. No new mechanism was required to get there, which is what
  I2, I3 and I5 were paying for all along.
* One identity, one version, one file. A mod manager reads one `.fpk` per candidate and needs
  nothing else — no sidecar to keep in sync, nothing that can go missing on a copy.
* A manifest is content, so it is *overridable* by content, which sounds alarming and is not:
  discovery reads each candidate's manifest from its own package, individually, before any merge
  exists. A later package overriding `brighter:mod` cannot change the order that loaded it. Worth
  stating because the reverse would be a genuine hole.
* **Cost: every package needs a manifest**, including `content/core` and both samples. Six lines
  each, and it is the same cost I3 always charges: the engine walks its own path.
* **Cost: `fpack` loses two arguments and gains a pre-pass**, which is a breaking change to a
  tool — affecting exactly the three packages in this repository, all rebuilt by `zig build`.
  `build.zig`'s content table loses its `id` field with them, which is the point: today the
  build and the package each state an identity and a test checks they agree, and afterwards
  there is only one place to state it.
* **Cost: a new module.** Justified by "the answer has to be below `app`", not by tidiness. It is
  small: enumerate, read manifests, sort, hand back a list.
* Recorded because two documents deferred it here and it must not be settled by silence: **the
  engine still freezes no component vocabulary.** `tilemaps-and-collision.md` §11 and
  `sprite-animation.md` §8 both named "the ABI freeze" as the trigger for choosing standard
  component types. What M7 freezes is the *registration mechanism*, not a vocabulary — a
  component type is a schema, a schema is content, and a standard vocabulary, if one is ever
  wanted, belongs in `content/core` where a mod can see it and override it, not in engine source,
  which I5 forbids. Two samples exist and chose different components; no second consumer has
  asked for a shared one, and none was manufactured to close the question.

## Alternatives considered

* **A manifest file beside the package** — `mod.fdt`, `mod.toml`, `mod.json`. Rejected: two
  files that can disagree about one identity, a second thing to version (I8), and either a
  second format or a `.fdt` file that is parsed without being a package. The only benefit is
  reading it without opening the `.fpk`, which is one function call.
* **A mod is a directory, identified by its folder name.** Rejected outright: identity derived
  from filesystem position is I2's named anti-pattern wearing a different coat, and it makes two
  copies of one mod two mods.
* **Manifest fields as `fpack` arguments, as today.** Rejected: it puts a package's identity in
  whatever invoked the compiler, which no downstream consumer can recover.
* **Load order computed in `app`.** Rejected: refused by name in two documents, and it makes a
  mod manager or a launcher start an engine to find out what would load.
* **Load order supplied by the player, forever.** Rejected: it is the thing M7 exists to
  replace, and it hands dependency resolution to the person least equipped to do it. The manual
  list survives as an override, because a player untangling a conflict needs one.
* **A version solver** (npm/cargo-style, backtracking over ranges). Rejected as premature (rule
  7): ranges plus a topological sort with a documented tie-break is what a game needs, a solver
  is a subsystem, and nothing has yet produced a conflict that ordering cannot express. The
  manifest's shape does not foreclose one.

## Revisit if

* A mod appears that is genuinely only code, with no content worth packaging — the first
  evidence that "a mod is a package" is too strong. Note that even then it has a manifest, so it
  is a package with one record, which is cheap enough that this may never bite.
* Load order needs to be remembered **per save** rather than per installation. Saves and I8 will
  eventually want this, and it is a change to who stores the order, not to how it is computed.
* The manifest needs a field the content model cannot express.
* A real dependency conflict arrives that ordering cannot resolve, which is the trigger for
  reopening the solver question.
