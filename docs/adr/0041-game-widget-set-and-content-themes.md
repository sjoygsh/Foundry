# ADR-0041: The game widget set draws from content themes, and the kernel stays below the renderer

**Status:** Proposed
**Date:** 2026-09-19
**Builds on:** [ADR-0024](0024-ui-own-immediate-mode.md), [ADR-0021](0021-asset-identity.md) and
[ADR-0026](0026-abi-module-and-host.md)

## Context

ADR-0024 chose one UI kernel with two widget sets. M6 built the kernel and the debug set, and
postponed "the content-driven, skinnable game widget layer". It asked the kernel for one
promise: no colour, font, metric or string in the kernel is a literal. `ui.md` then recorded what
the game layer would want:
- a style that becomes a content record, with an ABI call to resolve one (§13);
- "almost certainly" new draw commands: "a nine-slice for a skinned panel, an image by content
  ID" (§14).

M14 needs that layer. Its exit criterion puts a mod manager screen in front of a player, and a
game's screen is skinned, translated and replaceable by a mod (I5). The kernel sits at L1,
beside `platform`, and never sees `render2d`, a texture or a content record. That is the property
that makes it testable with nothing linked. Whatever the game layer adds must keep it.

## Decision

**1. A theme is a content record,** of an engine-declared schema `foundry:ui_theme`, registered at
runtime beside `foundry:texture`, because `fpack` must check it (`public-abi.md` §11's reasoning).
A game ships its theme in its own package, and any later package may override it. A theme names:
- an atlas texture and a font, by content id;
- the font's grid;
- text scale, line height, padding and spacing;
- colours;
- nine-slice patches for a fixed list of parts;
- icons by the game's own names.

The schema's name, its field names and its part names are a compatibility decision (`CLAUDE.md`
§7), fixed when this is accepted.

**2. The kernel stays at L1 and gains three additive things:**
- an `image` draw command;
- a `nine_slice` draw command;
- a disabled scope.

Each command names its image by an opaque `u32` the caller defines, never by a texture handle.
The walker in `app` resolves the reference through a table the caller passes. This is the kind
of addition `ui.md` §14 anticipated, a new case in a tagged union and a matching walker branch,
and it is not the rewrite ADR-0024 names as its revisit.

**3. `app` resolves a theme** into a `ui.Skin` value and the walker's image table. The font goes
through `app.UiFont`, the one sanctioned producer of font metrics. A theme that fails validation
is one warning and the debug style, never a failed frame. A new content generation resolves it
again, so a reload re-skins a running screen.

**4. The game widget set is:**
- every existing widget, drawn from the skin when a theme is active;
- `tabs`, `selectable` rows and a reorderable list, by drag or by buttons;
- `icon` and `image`.

Interaction is one function per widget, shared by both sets, and only drawing differs. Drag
within one list is that widget's own gesture. Drag-and-drop between widgets stays out.

**5. Skin and strings are content; layout stays code.** A game lays its screens out in code with
the kernel's regions. This decision does not answer:
- whether layouts are authored as content, or how such widgets derive their ids (`ui.md` §14);
- keyboard or gamepad navigation;
- popups, tooltips and an overlay layer.

All three stay open.

**6. The ABI gains the layer additively in `FoundryApi_v3`:**
- `ui_theme_resolve` returns a handle valid for one content generation, refused when stale (I1);
- `ui_theme_push` and `ui_theme_pop`;
- the new widgets and the disabled scope.

This keeps `ui.md` §13's promise that a mod's UI gets what the game's gets.

## Consequences

- **A mod can re-skin a game's screens,** including the one that manages mods, by overriding one
  record. A translation replaces strings the same way.
- **The kernel remains testable with nothing linked.** The new commands carry numbers, not
  handles, and the walker's image table is the only place a texture appears.
- **The debug overlay is unaffected.** It keeps its built-in style, and themes never reach it
  unless a caller pushes one.
- **Cost: a second style producer, and a schema to keep compatible.** A theme's shape reaches
  every game and mod that authors one, so adding a part later is additive, and renaming one is a
  break.
- **Cost: games write layout in code** until content-authored layouts are designed. The room's
  screen shows that is workable at one screen; it may not be at fifty.

## Alternatives considered

- **Each game builds its `Style` in code.** No schema, no resolver. Rejected: I5 puts a game's look
  in content, and a mod could never re-skin it.
- **Layouts as content now.** The fuller answer to ADR-0024's "laid out by a designer". Rejected
  for M14: it is an authoring language, it forces the widget-id question `ui.md` §14 left open, and
  one screen is not the evidence to design it on.
- **Let `ui` see textures,** by moving it above `render2d` or giving it `render2d`'s types.
  Rejected: it undoes the L1 placement ADR-0024 resolved for testability, for a gain the opaque
  reference already provides.
- **A retained widget tree for the game layer.** ADR-0024 rejected it for M6 on I1 grounds, and a
  mod manager screen gives no new reason.
- **Popups and tooltips in M14.** They are staples of game UI, but they need an overlay layer and
  its input rules. The room's screen does without them, so they wait for a screen that cannot.

## Revisit if

- A game's screen cannot be expressed without an overlay layer, keyboard navigation or
  content-authored layout. Each is then its own decision.
- The game set needs a kernel change beyond additive commands and scopes. That would test
  ADR-0024's "one kernel" claim, and deserves a superseding record rather than a quiet change.
- A theme needs a value the schema cannot carry, such as sounds, animation or per-state fonts.
