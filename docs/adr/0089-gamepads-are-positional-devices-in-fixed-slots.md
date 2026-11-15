# ADR-0089: Gamepads are positional devices in fixed slots, and captured motion is in counts

**Status:** Accepted 2026-11-15, when the owner requested M45 Step 1
**Date:** 2026-11-15
**Informed by:** ADR-0002, ADR-0013, `docs/design/platform-interface.md` §4 and §11,
`docs/design/playable3d.md` §4.2 and §13, `docs/design/input.md` §3 and §4

## Context

`platform-interface.md` deferred gamepads so the snapshot would not be shaped around SDL's model,
and it designed the snapshot to accept more device state. Keys are identified by physical
position, never by the character a layout prints, so that a binding means the same place
everywhere. A game holding "player two's pad" needs to know when it has become a different pad.

Separately, `playable3d.md` §4.2 recorded that captured mouse motion is accelerated on some systems
and not on others, so one sensitivity value is a different feel per machine.

## Decision

**Gamepads:**
- **Buttons are named by position**: `south`, `east`, `west`, `north` and the rest, append-only
  stable names. The label printed on a button (`a`, `cross`, …) and the pad's kind are reported
  separately, for prompts.
- **Four fixed slots in the snapshot.** A pad takes the lowest free slot and keeps it, a fifth
  waits in connection order, and `GamepadHandle`'s generation counts connections (I1). Slot
  assignment is one shared helper, so every backend assigns alike.
- **Axes are normalised and unfiltered**: sticks in [-1, 1] with +y up (away from the player),
  triggers in [0, 1]. Deadzones belong to bindings (ADR-0087).
- **Focus loss releases held buttons and zeroes axes**, as for keys.
- Rumble is a platform call, output only.
- SDL3's gamepad API and built-in mapping database, with no external mapping file.

**Captured motion:**
- **By default it is the device's counts**: unaccelerated and unscaled by the OS (`MotionMode.raw`,
  the host's choice). `system` gives the OS's ballistics.
- **The snapshot's `motion_unit` names what `motion` holds**: `counts` or `points`. It is what is
  true, so a platform that cannot deliver counts says `points`. Counts are the same unit on every
  platform.

## Consequences

- A binding to `pad.south` is the same place on every pad, and a prompt still shows the right
  glyph.
- A slot and a handle are enough for local multiplayer's device assignment.
- One sensitivity value means one feel on macOS, Windows and Linux. The court's defaults are
  retuned once.
- **Cost:** the pad's +y up differs from the mouse's screen-down motion. Bindings' `scale` turns
  either, and the reason must be remembered.
- **Cost:** a pad SDL cannot map is ignored until M146.
- **Cost:** the button and axis names, and the slot count's place in the snapshot, are compatibility
  surfaces.

## Alternatives considered

- **Buttons named by label (A/B/X/Y).** A Nintendo pad swaps them, so a binding would move between
  pads.
- **Pads in a growable list by connection order.** Disconnecting player one would renumber player
  two.
- **Deadzones applied in `platform`.** Two actions could not read one stick differently.
- **Normalising motion to a physical unit.** No OS reports counts per inch, so the number would be
  invented.
- **Leaving acceleration to each platform.** That is today's behaviour, which is what the roadmap
  asked to fix.

## Revisit if

- A game needs more than four pads at once.
- A platform is found where neither counts nor points are what its relative mode reports.
- A shipped game's players need a pad SDL's database cannot map before M146.
