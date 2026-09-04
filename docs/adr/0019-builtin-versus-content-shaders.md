# ADR-0019: Engine-owned shaders are embedded; content-owned shaders are assets

**Status:** Accepted (implementation begins in M2)
**Date:** 2026-09-04

## Context

ADR-0015 decided that "shaders are assets, referenced by content ID, with per-backend
variants selected at load," and explicitly rejected hardcoding shaders as strings in engine
source. That decision was made with mod-authored shaders in view, and it holds for them.

M2 forces a question it did not answer. `render2d` needs a sprite shader in order to draw
anything at all, and it needs it **before any content system exists** — `data` and the
content pipeline are M3. PROJECT_STATE has carried "where a compiled shader lives is
unsettled, deliberately" since M1, when the only shader in the project belonged to
`samples/sandbox` and could be embedded there without deciding anything. A shader belonging
to the engine cannot be deferred the same way, so implementation forces the decision, and
the standing instruction is to record it architecturally before proceeding rather than to
resolve it silently in code.

The tension is real and worth stating plainly. I3 says the base game is content package
zero and there is no privileged loading path. If the sprite shader is content, embedding it
in the engine binary is exactly the privileged path I3 forbids. If it is not content, ADR-0015
does not govern it and there is no conflict.

## Decision

**Shaders are divided by ownership, and the two halves live in different places.**

**Engine-owned shaders are compiled by the build and embedded in the engine binary.** These
are the shaders the renderer requires in order to function: the sprite/text shader in M2, a
blit shader when render targets arrive, and whatever a future `render3d` needs to draw at
all. They are compiled by the existing `xcrun metal` → `metallib` build step and reach the
module through `addAnonymousImport`, exactly as `samples/sandbox` does today.

**Content-owned shaders are assets**, per ADR-0015 unchanged: referenced by content ID,
carrying per-backend variants, loaded through the content path that mods use, resolved by
the material system when it exists.

The line between them is **not** "ours versus theirs" but a functional test:

> An engine-owned shader is one whose absence means the renderer cannot draw. It is part of
> the renderer's implementation, in the same category as its vertex format and its index
> buffer — not part of the game.

A consequence that falls directly out of that test: **the sprite shader is not overridable.**
It is the other half of a contract with the batcher's vertex layout (`render2d.md` §6), and a
mod that replaced it could not honour that contract without also replacing the batcher. A mod
that wants sprites to look different supplies a *material* with its own shader, through the
material system, which is the mechanism designed for it.

This does not weaken I3. I3 governs **content** — items, entities, maps, rules, text, assets
— and guarantees that first-party content loads the way mod content does. The sprite shader
is engine machinery, encodes no game specifics, and is exactly as much "content" as the
index buffer it draws with. When first-party *content* shaders exist — a material shipped in
`content/core/` — they will load through the content path like everyone else's, and this ADR
does not touch them.

## Consequences

* `render2d` works before any content exists, which is what makes M2 possible at all and what
  will later let the engine draw an error screen when content loading has failed — the moment
  you least want the renderer to depend on the content system.
* The build step written in M1 is reused unchanged for engine shaders, so this costs no new
  machinery.
* ADR-0015's constraint survives intact where it matters: the material system is still being
  designed on the assumption that shaders are assets with per-backend variants, and mod-authored
  shaders are still the case it must serve.
* **Cost: two places to look for a shader**, and a judgement call at the boundary. The
  functional test above is the tiebreaker, and it is narrow enough that the answer is obvious
  for every shader currently foreseeable.
* **Cost: engine shaders are frozen at build time.** Runtime MSL compilation
  (`createShaderModuleFromSource`) still exists and still gives hot reload in development
  builds, so this is a shipping-build property, not a development one.
* A mod cannot restyle every sprite in the game by swapping one shader. That is a real
  limitation and a deliberate one: the alternative is a mod that silently breaks whenever the
  batcher's vertex format changes.

## Alternatives considered

* **Everything is an asset, including the sprite shader, loaded from `content/core/`.** The
  purest reading of ADR-0015 and I3. Rejected because it makes the renderer depend on the
  content system for its own ability to function, inverts the layering (`render2d` is L3,
  `data` is L1 but the content *pipeline* is not), creates a bootstrap problem with no good
  answer when content is missing or corrupt, and would have to be built in M2 — pulling most
  of M3 forward to draw a quad.
* **Embed shader source as strings in Zig, compiled at runtime.** Simple, no build step,
  hot-reloadable. Rejected by ADR-0015 already, and additionally it would make every shipping
  build pay MSL compilation at startup for shaders that could have been compiled once.
* **Leave it unsettled and embed the shader in `samples/sandbox` again.** Possible for exactly
  one more milestone. Rejected because the sprite shader belongs to `render2d` — a sample
  owning the engine's shader would mean any other consumer of the engine has no way to draw.

## Revisit if

The material system's design shows that the engine's own shaders want to participate in it —
for instance if sprite rendering grows enough variants that a material-driven permutation
system would serve it better than a fixed shader — or if a genuine need appears for mods to
replace an engine shader wholesale, which would mean the vertex-format contract had been
stabilised enough to expose.
