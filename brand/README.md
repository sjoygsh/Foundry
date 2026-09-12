# The Foundry marks

The engine's identity: the `F` glyph, the wordmark, and the icon a Foundry application wears
when Foundry is the application.

| File | What it is | Where it is used |
| --- | --- | --- |
| `foundry-logo.png` | The glyph, 1254×1254, transparent | The icon master, the README, anywhere the name is already present |
| `foundry-wordmark.png` | The wordmark, 2172×724, transparent | Headers, the social card, anywhere the glyph alone would not say the name |
| `foundry.icns` | The macOS icon set, 16px through 1024px | `Contents/Resources/AppIcon.icns` in the samples' bundles |
| `social-preview.png` | 1280×640 lockup on the dark ground | GitHub's repository social preview |

`foundry.icns` and `social-preview.png` are generated from the two masters, and both are
reproducible: the icon by `sips` into an `.iconset` and `iconutil -c icns`, the card by
[`scripts/brand_card.py`](../scripts/brand_card.py). The masters are the source of truth; if
one changes, regenerate rather than editing a derivative.

## What the marks are for

**These marks identify Foundry.** They belong on Foundry's own artifacts — this repository, its
documentation, its tools, and the samples it ships, which are the engine demonstrating itself.

**They do not belong on your game.** An application built with Foundry supplies its own name,
its own bundle identifier and its own icon; `release.Description.icon` is a field the
*application* fills in, exactly like `product_name`. A game that shipped wearing this glyph
would be telling a player that they are running Foundry, which is not what they are running.
That is the whole distinction, and it is why the release helpers never supply a default.

## What you may do with them

[ADR-0034](../docs/adr/0034-brand-and-trademark.md) is the decision; this is the short version.

**Yes, without asking:**

* Say your game, mod or tool is *built with Foundry*, *powered by Foundry*, or *a Foundry mod*.
* Use the marks unmodified to refer to Foundry — in a credits screen, a README, an article, a
  talk, a comparison, a video.
* Link to this repository with the glyph or the wordmark as the link.

**No, not without asking:**

* Using a mark as your own product's icon, logo or app icon.
* Naming a product in a way that reads as the engine's own — "Foundry Pro", "Foundry Studio",
  "FoundryEngine.com" — or registering a domain, account or package that does.
* Changing a mark and calling the result Foundry: re-colouring, re-drawing, adding text inside
  it, or stretching it out of proportion.
* Any use that implies Foundry endorses, maintains or has approved what you made.

**The code's license is not the marks' license.** Apache-2.0 covers the source and says so
explicitly: §6 grants no trademark rights. The marks are licensed separately and narrowly, by
the rules above, and nothing here restricts your use of the *software* in any way.

If a case is not obviously one of those, ask before shipping. The answer is usually yes.
