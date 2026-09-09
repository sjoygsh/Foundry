# Modding Foundry

**Status:** Tier 1 (content mods) works as of M3, 2026-09-05. Tier 3's C ABI and native
library lifecycle work as of M7, 2026-09-09. Tier 2 is not built yet. This directory
documents what a mod author can actually do today, and says plainly what is not built.

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
| **2 — Script mods** | Sandboxed, hot-reloadable code against the public API; script faults are contained. | Not built. Restricted Lua 5.5.1 is selected; [M8's design and eight steps](../design/scripting.md) are written, with implementation pending. |
| **3 — Native mods** | Dynamic libraries through the C ABI. Full speed, full power, no sandbox. | **ABI and loader work.** `foundry.h` is installed to `<prefix>/include/`, compiles as C99 and C++, and `FoundryApi_v1` has 135 calls: content, records, packages, schemas, assets, world, rendering, UI, audio and collision. A native-capable host loads the library after content. See [`native-mods.md`](native-mods.md) and [`design/public-abi.md`](../design/public-abi.md). |

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

* **Discovery, manifests and load order work; a mod *manager* does not.** Every package
  carries a `foundry:mod` record naming itself ([ADR-0027](../adr/0027-mods-are-content-packages.md)),
  a host reads every package in its content directory, and the order is computed from what the
  manifests say — a stable topological sort that keeps your ordering wherever the dependencies
  permit. What is missing is the *interface*: nothing yet lists your mods on screen or lets you
  drag them around. The sandbox reads an environment variable of content IDs, which is enough to
  try one.
* **`@patch` and `@remove` parse and are then refused.** Their syntax is frozen, deliberately
  and early, so that content written later does not have to change. Their semantics are not
  implemented, and a mod using one is told so rather than having it quietly ignored —
  because a mod that appears to load and does not work is the worst outcome available.
  Overriding a whole record works today.
* **No scripting.** Tier 2's language, sandbox, resource limits and hot reload are M8 work.
  Native code is deliberately different: it is trusted, unsandboxed code and can crash the
  host. See [`native-mods.md`](native-mods.md) for the complete C99 package and loader guide.
* **Instances of a component type a mod registers are not saved or built from content — yet.**
  The engine reads a component through the type's own serializer rather than by casting its bytes,
  which is what lets it show a type it was never compiled against. A native type registered
  through the ABI supplies no serializer, so it holds runtime state and behaviour, and
  `world_component_type_savable` says false before you find out the hard way. The additive fix
  is a later descriptor with serializer slots; nothing about today's shape blocks it.
* **No signing, no sandboxing, no trust model.** A content package is data and is validated
  as untrusted input, but nothing here is a security boundary yet.

## Where to go next

* [`content-mods.md`](content-mods.md) — write one, compile it, load it.
* [`native-mods.md`](native-mods.md) — build a C99 library against `foundry.h`, register a
  component and system, and load it through a native-capable host.
* [`../design/content-schemas.md`](../design/content-schemas.md) — the `.fdt` format and the
  content model, in full.
* [`../design/assets.md`](../design/assets.md) — how assets are identified and loaded.
* [`../adr/`](../adr/) — why each of these decisions was made, and what would make us
  revisit it.
