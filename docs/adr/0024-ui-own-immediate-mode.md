# ADR-0024: Foundry's own immediate-mode UI, one kernel and two widget sets

**Status:** Proposed
**Date:** 2026-09-06

## Context

`CLAUDE.md` §9 has scheduled "Debug/game UI: own IMGUI vs. cimgui" for M6 since the project
started, with a one-line lean — *we need a UI system regardless; that argues for our own* —
and ADR-0011 deferred the same question in more detail, naming `cimgui` as "the escape hatch
if debug tooling is blocking progress. Decided at M6." M6 has arrived, its first roadmap
bullet is the overlay, and nothing can be built until this is settled.

The lean is not the decision, and restating it is not deciding it. Three things constrain the
answer, and only one of them is about which toolkit is nicer to use.

**Foundry needs a game UI regardless, and Dear ImGui is explicitly not one.** Its own
documentation says so. A menu, a HUD, an inventory, a dialogue box and a settings screen are
not debug panels: they are skinned, localised, laid out by a designer rather than by a
programmer, and — for Foundry specifically — they are *content*, replaceable by a mod (I5).
Taking cimgui does not remove the obligation to write a UI system; it adds a second one and
guarantees the two never share a line.

**M7 freezes an ABI, and I4 says there is exactly one public surface.** If the debug overlay
is built on cimgui, then at M7 there are two possibilities and both are bad. Either mods get
no UI at all — while the first-party overlay has one, which is precisely the private back door
I4 exists to forbid and ADR-0011 was written to prevent — or Dear ImGui's API is re-exported
through `FoundryApi_v1`, which puts a third party's data model, naming and release cadence
inside a surface Foundry has promised to version and not break (I8). Dear ImGui makes no ABI
stability promise across versions, and it is entitled not to; it was never asked to be
somebody else's frozen boundary.

**Taking cimgui does not save the work people assume it saves.** Dear ImGui ships no renderer.
Its backends are per-graphics-API, and Foundry's graphics API is its own RHI, which no backend
targets. Adopting it means writing an `ImDrawData` → Foundry bridge — vertex and index upload,
per-command scissor rectangles, texture binding, a font atlas upload — plus an input bridge
from `platform`'s snapshot to `ImGuiIO`. That is the entire plumbing half of an immediate-mode
UI, written twice against someone else's structs. **What cimgui actually buys is the widget
set**, not the integration.

What already exists is more than the balance of this argument usually gets:

| Need | Already in the tree |
| --- | --- |
| A screen space to draw in | `render2d` `ViewId.screen`, `ViewDesc.screen: Rect`, +Y down |
| Text, laid out and measured | `BitmapFont`, `text.Layout`, `measureText` |
| Quads, batched, blended, sorted | `drawSprite`, `Color`, `BlendMode`, the batcher |
| Mouse position, buttons, wheel | `platform.InputSnapshot`, `MouseState`, `mouse_wheel` |
| **Typed characters** | `platform.event.Event.text_input` — already UTF-8, already bounded |
| A place in the frame to record | `app.renderFrame(options, recorder: anytype)` |

That last row is the one worth pausing on. `renderFrame` takes its recorder as `anytype`
requiring only `prepare` and `record`, deliberately, so that `app` "should not care who records
into it" — and `render2d.md` §3 drew `debug_ui.record(&pass)` into the frame diagram as a
future arrow at M2, on the stated grounds that "a frame will eventually carry more than
sprites — a debug UI in M6, a 3D pass later." The seam this needs was cut before it was
needed, deliberately, and it is still the right shape.

## Decision

**Foundry writes its own immediate-mode UI.** No Dear ImGui, no cimgui, no third-party UI
dependency. This is the answer §9 has held open and the one ADR-0011 leaned toward; it is
adopted for the I4 and I5 reasons above rather than for the aesthetic one.

**One kernel, two widget sets.** This is the substance of the decision and the part neither
prior document had settled.

A debug panel and a game's HUD differ in *presentation and authoring*, not in *mechanism*.
Both need the same small, genuinely hard core: stable widget identity across frames, a
hot/active pair driving interaction, input routing and capture, layout, clipping, and a draw
output. Both differ completely in everything above that: a debug panel is written in code with
a built-in style and no localisation, while a game's HUD is laid out as content, skinned from
assets, translated, and overridable by a mod.

So Foundry builds **one `ui` kernel** and layers widget sets on it:

* **M6 builds the kernel and a debug widget set** — label, button, checkbox, slider,
  collapsing header, scrolling region, filter field, table rows and a frame-time plot. That is
  the whole list M6's bullets need: an entity inspector, a content browser, a log console, a
  profiler and per-allocator memory reporting are those widgets arranged differently.
* **The content-driven, skinnable game widget layer is designed for and postponed.** It is not
  built at M6 and must not be faked at M6 by hardcoding a style into the kernel. What the
  kernel owes it now is only this: **no colour, font, metric or string in the kernel is a
  literal.** Style is a value passed in; text is a slice the caller supplies. A kernel that
  obeys that rule can be given a content-driven theme later without being rewritten; one that
  does not, cannot, and would violate I5 the moment a game used it.

**The kernel depends on no graphics backend and is testable without a renderer.** `ui` never
sees `rhi`, exactly as games never do (§4.2). Its interaction logic — which widget is hot,
what a click did, where the caret is in a text field — must be exercisable in a unit test with
no device, no window and no frame, for the same reason the null RHI backend exists: the
untestable part of a subsystem is the part that rots.

## Consequences

**`render2d` gains two things it does not have, and would have needed for cimgui too.** Both
are smaller than they sound, and the second is overdue for a reason unrelated to UI.

1. **Clipping.** A scrolling log console clips. The RHI already has this — `setScissor` is in
   `rhi.interface`, `command.ScissorRect` exists, and both the null and Metal backends
   implement it — so nothing needs inventing at that layer. What is missing is `render2d`
   exposing a clip rectangle and treating a change of one as a batch break. It is absent from
   §14's "deliberately not here" list only because nobody had needed it yet.
2. **A solid quad with no texture of the caller's.** `drawSprite` takes a region of a texture,
   and the engine cannot require every game to ship a white pixel in its own sheet.

   **This one has already been paid twice.** `samples/sandbox` and `samples/room` each allocate
   an 8×8 white `asset.Image`, upload it with `createTexture`, and inset the region by
   `sub(2, 2, 4, 4)` to stay off the filtered edge — independently, in near-identical lines,
   and the room's comment explains it is there "so the panels keep working when a mod replaces
   the sheet with one that does not." Two consumers writing the same workaround is the signal
   the duplicated `Map` raised at M5, and this time it arrives alongside the subsystem that
   needs it anyway. Whether the answer is a renderer-owned blank texture or an untextured path
   through the batcher is the design document's call; that there must be one is not. It is the
   same category of engine-owned resource as ADR-0019's built-in shaders.

**The overlay's font comes from where a game's does, and it is already there.**
`render2d.md` §10 committed to this at M2 — "the M6 debug overlay will need to state where its
font comes from, and the answer will be *the same place*, not *a private one*" (I3, I4) — and
`content/core` has shipped `foundry:fonts.debug` since M3 for exactly this reason, its README
saying so in as many words. The overlay acquires it as an ordinary `foundry:texture` by content
ID and describes the grid with a `render2d.BitmapFont`, which is the call `samples/sandbox`
already makes and the call a mod would make. There is no font schema and this does not add one:
a fixed-grid bitmap font needs no metrics file, which is the reason `render2d.md` §10 chose one,
and a mod overriding `foundry:fonts.debug` re-skins the overlay's glyphs without being told the
directory exists (ADR-0021).

**The widget set at M6 is small, and that is the price.** No docking, no tables with sortable
resizable columns, no plots beyond a line, no colour picker, no multi-line text editor with
selection. Text editing in particular is genuinely unpleasant to write well, and the M6 field
will be single-line, ASCII-first, with no selection. If a missing widget blocks a diagnosis,
that is a signal to write the widget, not to reopen this.

**The introspection APIs are the real deliverable.** M6's fourth bullet — "introspection APIs
designed with the future public ABI in mind" — is where the milestone's lasting value is, and
it is unaffected by which toolkit draws it. Choosing our own only keeps the drawing on the same
side of the ABI as the data.

**A cost worth naming: this is a UI system written by one project.** It will be worse than Dear
ImGui at everything Dear ImGui does, for years. The trade is that it is the same system the
game and mods use, in the same language, behind the same versioned surface.

## Alternatives considered

* **cimgui (Dear ImGui via C bindings).** Far more capable immediately, battle-tested, MIT and
  therefore fine under ADR-0016. Rejected on I4 and I5: it cannot become the game UI, so it
  guarantees two UI systems; and at M7 it forces either a private first-party capability mods
  do not get, or a third-party API inside Foundry's frozen ABI. The usual decisive argument in
  its favour — that it saves the work — is materially weaker here than it looks, because
  Foundry's renderer is its own and the backend would be ours to write either way.
* **Dear ImGui directly, in C++.** Same objections, plus a C++ toolchain and libc++ in every
  build of an engine whose toolchain ADR (0014) is deliberately narrow.
* **A retained-mode UI (widget tree, callbacks, invalidation).** Better for a complex editor,
  and eventually the right shape for some game UI. Rejected for M6 on exactly the grounds
  `render2d.md` §2 rejected a retained scene graph: retained objects across the ABI need
  lifetime rules, which is the class of problem I1 exists to avoid, and an immediate call is a
  function taking a plain struct and trivially expressible at M7. Immediate mode is also
  correct-by-construction for debug UI, which shows live state that changes every frame.
* **No UI at M6; diagnose with logs and external tools.** Cheapest, and honestly viable for a
  while. Rejected because M6's exit criterion is specifically *from inside the running game*,
  and because ADR-0011's staging depends on the overlay forcing the introspection APIs to
  exist early, where they still benefit mods and the eventual editor.
* **Two separate systems — a private `debug_ui` now, a game UI later.** The tempting shortcut,
  because the debug overlay could then hardcode whatever it liked. Rejected: the kernel is the
  expensive, subtle part, and writing it twice means the second one is written under deadline
  by someone who has forgotten why the first one made its choices.

## Open question, left open

**Whether `ui` draws through `render2d` or emits a renderer-agnostic draw list.** Both keep the
kernel free of `rhi`; they differ in where the module sits.

* *Draws through `render2d`* — `ui` imports `render2d`, calls `drawSprite`/`drawText`, and sits
  above L3, which makes `app` L5 and `abi` L6. Fewer moving parts, one draw vocabulary, and
  text measurement is simply available.
* *Emits a draw list* — `ui -> core, platform` only, at L1, producing rects, text runs and clip
  rectangles that `app` or the game rasterises, with font measurement supplied as a callback.
  This is how Dear ImGui itself is structured, and the reason it runs on backends its authors
  never wrote. It
  keeps the kernel testable with nothing linked at all, and lets `render3d` or a standalone
  tool draw the same UI later.

The second is the current lean, for the same "Foundry owns its abstractions" reason that put a
draw-list boundary between `render2d` and `rhi`. It is **not decided here.** This is a module-
edge question that the design document (`docs/design/ui.md`) should answer with the layering
written out, and resolving it inside this ADR would be exactly the opportunistic resolution the
standing instruction on ADR-0003 forbids.

## Revisit if

* A diagnosis that M6 exists to make possible is blocked by a missing widget that is genuinely
  large to write — a real table, a docking layout, a multi-line editor with selection — and the
  overlay is holding up engine work. That is the condition ADR-0011 already named as the escape
  hatch, and it is still the condition; it is not "cimgui would be nicer."
* The separate editor application (§9, post-M6) turns out to need a retained widget tree with
  undo, multi-select and drag-and-drop, and building it immediate-mode is fighting the tool. A
  retained layer *above* this kernel is the first answer; a different toolkit for the editor
  alone is the second, and would need its own ADR because it splits the surface I4 unifies.
* The kernel is finished and the game widget layer, when it is designed, cannot use it without
  changing it. That would mean the "one kernel, two widget sets" claim was wrong, and the honest
  response is a superseding ADR rather than quietly maintaining two.
