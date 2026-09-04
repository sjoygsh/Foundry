# Modding Foundry

**Status:** Tier 1 (content mods) works as of M3, 2026-09-05. Tiers 2 and 3 do not exist
yet. This directory documents what a mod author can actually do today, and says plainly
what is not built.

Modding is a fundamental feature of Foundry rather than something added later
(`CLAUDE.md` §5). That is a claim about *architecture*, not about features: the mod system
proper is M7, but the disciplines that make it possible are in force from the first commit,
because they are the ones that cannot be retrofitted.

---

## The three tiers

Listed in order of how many people will use them, which is the inverse of how much power
they grant.

| Tier | What it is | Status |
| --- | --- | --- |
| **1 — Content mods** | Data only: items, entities, rules, text, assets. No code, no compiler, no sandbox. | **Works.** See [`content-mods.md`](content-mods.md). |
| **2 — Script mods** | Sandboxed, hot-reloadable code against the public API. Cannot crash the host. | Not built. The language is an M8 decision (`CLAUDE.md` §9). |
| **3 — Native mods** | Dynamic libraries through the C ABI. Full speed, full power, no sandbox. | Not built. The ABI is M7 (ADR-0004). |

Tier 1 is first on purpose. It is where most mod value actually lives, and its requirements
constrain the content model and the serialization format in ways that are impossible to add
afterwards.

## What makes a mod survive

Four decisions, made before there was anything to mod, that a mod author benefits from
without ever reading about them.

**Content is identified by a name, not a position.** `foundry:item.torch` is a string you
can read, grep for and type. It is hashed to a number at build time, and that number depends
on the string and nothing else — not on load order, not on where the record sits in a file,
not on which mods are installed. This is Invariant I2, and it exists specifically to avoid
the load-order-indexed identity that makes large mod lists fragile in other engines.

**An asset's identity is a content ID too, never its path** ([ADR-0021](../adr/0021-asset-identity.md)).
A mod replacing a texture says which texture, by ID. It does not have to reproduce the base
game's folder structure to be found, and the base game can reorganise its own directories
without breaking anything. Your files live wherever you like.

**The base game is package zero.** Foundry's own content is compiled by the same tool, into
the same format, and loaded by the same call yours is. There is no privileged path — no
faster route the engine takes for its own content and denies to you. That is Invariant I3,
and the reason for it is simple: a path we are always on ourselves is a path that works.

**Everything that crosses a boundary is versioned** (I8). Schemas carry a version, the
package format carries a version, and a schema can grow fields without invalidating content
written against the older one.

## What is *not* built yet

Being honest about this is more useful than a feature list.

* **No mod manager, no discovery, no dependency resolution.** The engine is *handed* a load
  order and does not compute one. That is an M7 decision and inventing it early would answer
  it in the wrong place. Today an application names its packages; the sandbox reads an
  environment variable so you can try one.
* **No manifests.** A package's name and version are arguments to the compiler, not a file
  in the directory. Same reason.
* **`@patch` and `@remove` parse and are then refused.** Their syntax is frozen, deliberately
  and early, so that content written later does not have to change. Their semantics are not
  implemented, and a mod using one is told so rather than having it quietly ignored —
  because a mod that appears to load and does not work is the worst outcome available.
  Overriding a whole record works today.
* **No scripting, no native mods.** Tiers 2 and 3 above.
* **No signing, no sandboxing, no trust model.** A content package is data and is validated
  as untrusted input, but nothing here is a security boundary yet.

## Where to go next

* [`content-mods.md`](content-mods.md) — write one, compile it, load it.
* [`../design/content-schemas.md`](../design/content-schemas.md) — the `.fdt` format and the
  content model, in full.
* [`../design/assets.md`](../design/assets.md) — how assets are identified and loaded.
* [`../adr/`](../adr/) — why each of these decisions was made, and what would make us
  revisit it.
