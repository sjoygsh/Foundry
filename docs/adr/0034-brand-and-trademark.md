# ADR-0034: The marks identify Foundry, and the application supplies its own

**Status:** Accepted
**Date:** 2026-09-13

## Context

Foundry had no visual identity at all until M10: no glyph, no wordmark, no icon. A staged
`.app` named no `CFBundleIconFile`, so every artifact the engine produced wore Finder's generic
icon, and the repository's own page showed nothing that said what the project was.

Marks are not decoration for a project whose whole architecture is about what a consumer may
and may not inherit. Two decisions come with them and neither answers itself.

**Whose icon does a Foundry application wear?** Nothing in the release path had an opinion,
which in practice means whatever the engine supplies becomes the default, and a default here
is a claim made on a player's Dock.

**What may other people do with the marks?** Apache-2.0 §6 grants no trademark rights — it says
so deliberately, because a permissive code license and an unrestricted name are different
things. Foundry's licensing policy (ADR-0016) is permissive by intent, and modding is the
project's reason to exist (ADR-0027), so mod and game authors need a stated answer rather than
silence. Silence reads as prohibition to the careful and as permission to everyone else.

## Decision

**The marks identify Foundry, and only Foundry.** They are used on this repository, its
documentation, its tools, and the samples it ships — which are the engine demonstrating itself
(ADR-0017), not products with identities of their own.

**An application supplies its own icon.** `release.Description.icon` is a field the consuming
application fills in, beside `product_name` and `bundle_id`, and the release helpers supply no
default. An application that supplies none ships without one; Finder draws the generic icon,
which is true rather than misleading. The engine never puts its mark on a game, because a game
wearing this glyph tells a player they are running Foundry, and they are not.

**The icon is staged like any other declared file** — `Contents/Resources/AppIcon.icns`, named
in the generated plist, hashed into the inventory — and the stager refuses a release whose plist
names an icon nothing stages. Naming an icon that is not there survives every build step and
appears as a generic icon on someone else's machine.

**Use of the marks by others is permitted for reference and denied for identity.** Anyone may
use them unmodified to refer to Foundry: "built with Foundry", a credits screen, a README, an
article, a comparison, a link. Nobody may use them as their own product's icon or logo, name a
product so it reads as the engine's own, alter a mark and still call it Foundry, or imply
endorsement. `brand/README.md` states this where the files are, which is where someone about to
use one will look. **Nothing about the marks restricts use of the software**, which is
Apache-2.0 and unaffected.

## Consequences

* A Foundry artifact is recognisable, and a game built on Foundry is recognisably the game's.
  The rule that made `product_name` the application's makes the icon the application's too, so
  this adds no new concept — it closes a gap where the engine could have leaked into a product.
* Mod and game authors have an answer they can act on without asking, and the answer is mostly
  yes. The narrow no's are the ones that would confuse a player about what they are running.
* Cost: the marks must be maintained as a derivative chain — masters, icon set, social card —
  and a change to a master means regenerating rather than editing. `scripts/brand_card.py` and
  the `sips`/`iconutil` recipe in `brand/README.md` exist so that is reproducible rather than
  remembered.
* Cost: a trademark claim only means something if it is asserted consistently. This is a small
  ongoing obligation, taken deliberately, and it is why the rules are short enough to follow.
* The engine gains no runtime dependency and no build tool: the icon is data staged by the
  existing release path, and the card generator is a developer script the build never runs
  (`CLAUDE.md` §4.4).

## Alternatives considered

* **No trademark statement at all** — rejected: Apache-2.0 §6 already declines to grant these
  rights, so silence leaves every author guessing, and the guess a modder makes is not the one
  a lawyer would.
* **Give the release path a default engine icon** — rejected: it would put Foundry's mark on
  other people's products by omission, which is precisely the leak I5 and ADR-0017 exist to
  prevent everywhere else.
* **A permissive "do anything" mark grant** — rejected: it makes the marks useless as
  identification, and the one thing a mark must do is tell a player what they are running.
* **A formal trademark policy document with legal scaffolding** — rejected as disproportionate
  (rule 16). A page beside the files, written for the person about to use one, is what gets read.

## Revisit if

Foundry is published under an organisation that holds a registered mark; a storefront or
platform requires specific attribution or icon rules that conflict with these; a naming
conflict with another project's mark surfaces; or the marks are redrawn, which would make the
derivative chain in `brand/README.md` the thing to update first.
