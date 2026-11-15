# ADR-0090: The table publishes input read-only, as the tick sees it, in `FoundryApi_v8`

**Status:** Accepted 2026-11-15, when the owner requested M45 Step 1
**Date:** 2026-11-15
**Informed by:** ADR-0004, ADR-0026, ADR-0059, ADR-0087, `docs/design/public-abi.md`,
`docs/design/editor.md` §13, `docs/design/input.md` §7 and §10

## Context

Since M15 the table has published no keyboard state. `ui_wants_keyboard` says only that something
is typing, so neither the editor's client nor a native mod can read a key. `public-abi.md` gave
the reason a system gets no input snapshot: one snapshot is seen by every step in a frame and by
none when a frame runs no step, so a mod counting presses per step would depend on its host's
frame rate.

The roadmap gives M45 "keyboard state published to the table". `FoundryApi_v7` is frozen at 264
calls, and M48 is titled "Public API v8".

## Decision

**An additive `FoundryApi_v8` publishes input read-only, in eleven calls (275 in all):**
- the keyboard as three 256-bit sets, with modifiers and focus;
- key names both ways, and the layout's label;
- the mouse;
- the gamepad slot count and each slot's state;
- an action's state by content ID;
- its effective bindings;
- whether a context is enabled.

The other parts of the decision:
- **Key numbers are written out in the header** as `Key`'s values, freezing an order `key.zig`
  already keeps append-only.
- **As the tick sees it:** inside a system's callback, every input call answers that step's tick
  view (ADR-0087), so an edge or a delta reaches one step. Elsewhere it answers the frame's view.
- **The host supplies the input** (ADR-0026). Without it, every call is `FOUNDRY_ERR_UNAVAILABLE`.
  v1–v7 are byte-identical, and the native loader offers 1–8.
- **Writes wait for grants:** enabling contexts, writing bindings, capture, rumble and audio
  outputs are M48's, by host grant.
- **The renumbering:** M48 becomes "Public API v9" and M49 binds "v6 to v9", as M27's v7 once moved
  M48.

## Consequences

- A native mod can declare an action in its own package and read it, and the editor's client
  could bind its own shortcut.
- A mod's simulation reads input exactly as the game's does, with no frame-rate dependence. This
  corrects `public-abi.md`'s sentence at the close by answering its reason.
- **Cost:** the roadmap's M48 and M49 titles change, a churn every reader of the roadmap sees.
- **Cost:** local input read in a system is still local. A networked game must carry it as commands
  (ADR-0044). The guide must say so, because the table cannot enforce it.
- **Cost:** the key numbering and every struct layout here are frozen.

## Alternatives considered

- **Leave it to M48.** The roadmap gives the line to M45, and M48 is already the widest
  publication.
- **Publish the frame's snapshot to every step.** This is the frame-rate dependence
  `public-abi.md` refused.
- **Keys passed by name on every call.** Each query becomes a string lookup, and the table's rule
  is numbers written out.
- **Publish writes now.** These change what a player experiences or reveal the host, without a
  grant to say who may.
- **Publish audio output names.** They often carry a person's name, and they are M48's "what a mod
  may learn about its host".

## Revisit if

- A mod needs to react to input outside a system before M48's frame callbacks exist.
- A game finds the tick view's "first step after" rule wrong for an input it needs.
- The key enumeration has to change in the middle rather than at its end.
