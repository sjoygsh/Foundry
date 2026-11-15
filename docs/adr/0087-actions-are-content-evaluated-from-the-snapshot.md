# ADR-0087: Actions are content, evaluated from the frame's snapshot by an `input` module

**Status:** Proposed 2026-11-15
**Date:** 2026-11-15
**Informed by:** ADR-0006, ADR-0007, ADR-0013, ADR-0041, `docs/design/platform-interface.md` §4,
`docs/design/playable3d.md` §13, `docs/design/input.md` §6 and §7

## Context

Every sample reads keys by name in code: the court's walk is `isHeld(.w)`, its menus
`wasPressed(.up)`. That means:
- a binding cannot be changed without recompiling the game;
- a mod cannot change one;
- a gamepad would need every call site rewritten.

I5 says content specifics are data, and a game's controls are content specifics.

The snapshot (`platform.InputSnapshot`) is already the one value simulation reads, and it is
deterministic from the event sequence. Engine record types are normally declared in `asset`, so
that `author` can register them for `fpack`. In this milestone's pair, though, `asset` and `author`
are M41's (ADR-0082).

## Decision

**Actions are content records, and evaluating them is a pure function of the snapshot.**

**The records:**
- **`foundry:input_action`** is one record per action, so a mod overrides or adds one action
  without touching another. It holds:
  - a kind: `button`, `axis`, `vector` or `delta`;
  - the contexts it belongs to (one to four), named by the action;
  - up to eight default bindings, each a source name with an axis, a scale, a threshold and a
    deadzone.
- **`foundry:input_context`** has a priority and a `blocks` flag. The game enables contexts. They
  are read from the highest priority down, ties by content ID, and a blocking context hides every
  source it binds from lower ones.
- **Source names are a compatibility surface**: `key.<Key>`, `mouse.<button>`, `mouse.motion`,
  `mouse.wheel` and its four buttons, `pad.<button>`, `pad.<axis>`, `pad.left_stick` and
  `pad.right_stick`.
- A record this engine finds wrong is refused whole, by name. An unknown source name is skipped
  with a warning, so content written for a later engine still runs.

**The module:**
- A new L2 module, `input -> core, data, platform`, reads the records from the merged store into a
  `Map`.
- It evaluates actions in content-ID order with per-binding deadzones, rescaled, radial for sticks,
  and vectors clamped to length 1.
- It gives a frame view and a **tick view**, in which an edge or a delta reaches exactly one step:
  the first after it happened.
- `app` evaluates it in the frame. `abi` is granted it to publish actions. `author` is granted it
  to register its schemas, one line in the compiler.

## Consequences

- Controls become data a mod changes with no code, and a pad needs no new call site.
- The court's `Pending`, which made edges survive a frame with no tick, becomes an engine rule that
  every game and every mod's system gets.
- Two `Actions` over one snapshot with different device selections are two local players, with
  nothing more built.
- **Cost:** engine record types now live in two homes, `asset` and `input`, and the reason must be
  remembered: `input` owns their meaning, as `mod` owns `foundry:mod`.
- **Cost:** `author`'s compiler gains a registration line, a textual change to M41's module during
  the pair.
- **Cost:** source names, kinds and field names are frozen once content outside the repository
  uses them.

## Alternatives considered

- **Bindings in each game's own records.** That is what the samples do in code today, and it gives
  mods no common shape to override.
- **One map record per game.** A mod adding one action would have to override the whole map, and
  two mods would collide.
- **Contexts that list their actions.** A mod adding an action to the game's context would override
  the game's context record. The action naming its contexts avoids that.
- **The records in `asset`.** That is the house home, but it is M41's module, and nothing here is
  an asset.
- **The records declared by `@schema` in package zero.** The engine would read untyped records, and
  every game's package would need `foundry:core` at compile time.
- **Evaluation in `platform`.** It has no `data`, and it should stay the OS layer.
- **Evaluation in `app` alone.** `author` cannot see `app`, so the schemas would have nowhere to
  live.

## Revisit if

- A game needs per-player maps whose actions differ, not only their devices.
- Evaluation with a real map is measured over 0.05 ms at p95.
- A source a shipped game needs cannot be named in the scheme above.
- A mod needs a context whose order is not expressible as one priority.
