# ADR-0021: Assets are content; a path derives an ID but never defines identity

**Status:** Accepted (implementation begins in M3)
**Date:** 2026-09-04

## Context

CLAUDE.md §9 records the asset ID scheme as a decision postponed to M3, noted as
"path-derived vs. GUID" and as interacting with I2 and with mod-authored overrides. `asset`
today takes a path and returns an `Image`, and its module doc says so explicitly: paths are
what M3 replaces.

The two named candidates are both wrong in instructive ways.

**GUIDs** are stable across any rename, and ADR-0005 already rejected them for content —
"unreadable in files, in diffs, and in error messages, which is hostile to mod authors."
Nothing about assets changes that. They also require a sidecar file per asset to hold the
generated ID, which is Unity's model and a well-documented source of version-control pain.

**Paths as identity** are readable and free, and they are the trap. I2 says content IDs are
never derived from load order, array position or file offset — the shared property being that
identity must not be a consequence of where the bytes happen to sit. A path is exactly that,
one level up. An engine that identifies assets by path has decided that its directory layout
is a permanent compatibility surface: nothing can be reorganised, and a mod overriding a
texture must reproduce the base game's folder structure to be found. That is
path-shadowing, and it fails in the same way load-order-indexed FormIDs fail — quietly, at
the user's machine, for reasons no one involved can see.

The developer's instruction settles it directly: the path is the default *way of obtaining*
an ID, not the *definition* of identity, and once a unique ID exists the path is not part of
it.

## Decision

**An asset is content.** A texture, a shader, a sound is a record with a schema and a
`ContentId`, authored, compiled and overridden by exactly the mechanisms every other record
uses. There is no parallel asset-identity system, and `asset` becomes a loader of bytes named
by ID rather than a thing that knows about directories.

**Identity is the `ContentId`, and nothing else is identity.** Not the path, not the file
name, not the position in a package, not the order of anything.

**The path is an ordinary field.** `source` names the file `fpack` should read at compile
time. Changing it is a one-line content edit that no reference, save or other package can
observe.

**The ID may be omitted in authoring, and is then derived from the logical path within the
package.** This is a default value for a field, computed by `fpack`, and is the whole of what
"path-derived" means here. It exists so that adding five thousand sprites does not mean
authoring five thousand records.

**The compiled package always carries the ID explicitly.** `fpack` materialises every derived
ID into the runtime package, so the derivation is a compile-time convenience that no shipped
artifact depends on. This is the structural half of the decision, and it is what makes the
rest true rather than merely intended:

> **No runtime code derives an ID from a path, and nothing can be looked up by path.**
> The runtime never sees a path as identity, so it cannot come to depend on one.

**Derivation is documented, deterministic and collision-checked.** It is specified in
`docs/design/assets.md`, it is a pure function of the package-relative path, and two files
deriving the same ID is a `fpack` error naming both — never a silent last-one-wins.

**Overrides target the ID.** A mod replacing `foundry:texture.sprites` says so. It does not
mirror the base game's directory layout, does not need to know what that layout is, and does
not break when the layout changes.

**Once written down, an ID is fixed.** An author who moves a file and wants its derived ID
to survive writes the ID explicitly — one line, in the record that already exists. `fpack`
is designed to gain a per-package ID ledger later, so that a move which would silently mint
a new ID becomes a build error instead; that is a diagnostic improvement rather than a change
to this decision, and it is deliberately not built now.

## Consequences

* Assets stop being a special case. One identity scheme, one override mechanism, one
  registry story, one thing for `docs/modding/` to explain.
* Directory layout becomes a private matter for each package. The base game can reorganise
  `content/core/` without breaking a single mod, which is a guarantee a path-identified engine
  cannot make.
* I3 gets easier rather than harder: the base game's textures load through the same record
  path a mod's do, because they are the same kind of record.
* An unresolvable asset ID is a reportable, recoverable condition naming a readable string —
  the same property ADR-0005 bought for content, now applying to textures and shaders too.
* **Cost: a window of instability before an ID is written down.** A derived ID is only as
  stable as its path until someone commits it to text. Until the ledger exists, a rename can
  change an ID and the only signal is a reference that stops resolving. This is the honest
  weak point of the decision.
* **Cost: the derivation function is itself a compatibility surface.** Because it produces
  IDs that end up in shipped packages and saves, changing how a path becomes an ID is a
  breaking change and is versioned under I8 like everything else that crosses a boundary.
* **Cost: an extra indirection at authoring time.** "Which file is `foundry:texture.sprites`?"
  is answered by looking at a record rather than by the ID itself. Good tooling and good error
  messages are the mitigation; the ID appearing in every diagnostic alongside its source path
  is the cheap version.

## Alternatives considered

* **Path as identity, with no explicit ID** — simplest possible thing, nothing to author.
  Rejected: it makes directory layout permanent, forces mod overrides to shadow paths, and is
  the same class of mistake as load-order-indexed identity. This is the option the decision
  exists to refuse.
* **GUID with a sidecar `.meta` file** — stable across any rename, no coordination needed.
  Rejected on ADR-0005's grounds, which apply unchanged: unreadable in files, diffs and error
  messages. The sidecar is a second cost, not the main one.
* **Explicit declaration only, no derivation** — the strictest reading of I2 and genuinely
  correct. Rejected as friction: a line of content per sprite is exactly the tax that stops
  people adding sprites, and the compiled artifact is identical either way, so the strictness
  buys nothing the derivation does not already give.
* **A hash of the file's contents** — content-addressed, stable under rename, unique by
  construction. Rejected: editing a texture would change its identity, which is the opposite
  of what identity is for.

## Revisit if

The ID ledger proves insufficient and renames keep silently breaking references in practice;
or an editor becomes the primary way assets are added, at which point it can assign explicit
IDs at creation and the derivation may stop earning its cost; or a case appears where an
asset genuinely has no sensible authored identity, such as assets generated at runtime.
