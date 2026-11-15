# ADR-0088: Rebinding is a preference keyed by action, which replaces its bindings whole

**Status:** Accepted 2026-11-15, when the owner requested M45 Step 1
**Date:** 2026-11-15
**Informed by:** ADR-0031, ADR-0040, ADR-0087, `docs/design/distribution.md` §5,
`docs/design/mod-management.md` §5, `docs/design/input.md` §8

## Context

ADR-0087 makes an action's default bindings content. A player who changes one makes a preference,
and ADR-0031 keeps preferences out of content: they are a bounded file in user data, which no
package can write and which survives an update. Mods come and go between runs, and a player's
bindings for a mod's action should outlive the mod's being disabled for a while.

## Decision

**A player's rebinding is an override that replaces one action's bindings whole**, keyed by the
action's content ID (I2).
- **Authority:** the player's override, then the last package's record (a mod over the game), then
  the game's. An action marked `rebindable false` ignores an override, with one warning.
- **On disk:** `<user data>/bindings.fset`, in the settings envelope, under the engine's settings
  schema `foundry:input_bindings` v1. It is `app.input_bindings`, following `profiles.zig`:
  - untrusted and bounded (256 actions);
  - written atomically;
  - **merged by action** with the file just before each write;
  - an override for an action the current content lacks is kept, not dropped;
  - an override invalid for its action's kind is refused for that action alone.
- **Capture:** `input.Capture` takes the first source that becomes active. Motion never captures,
  and neither does a source the caller ignores, which is how a cancel key cancels.
- **Conflicts:** `Map.conflicts` reports the actions that share a source in contexts that can be
  enabled together. The game decides what a conflict does.

## Consequences

- Every game gets persistent rebinding without writing a file format, and a game's screen is the
  only part it writes.
- A mod changing defaults never overrides what a player chose, and a player's choice for a mod's
  action survives disabling and re-enabling it.
- **Cost:** replacing whole means a later mod's new default binding for an action the player has
  rebound never reaches them. That is the intended reading of "my bindings are these", but it is
  a cost.
- **Cost:** a third file in user data beside settings and profiles.
- **Cost:** the field names in `foundry:input_bindings` are on players' disks.

## Alternatives considered

- **Overrides per binding slot.** These merge a player's change with a mod's change to the same
  action, and the result is a binding nobody chose.
- **Bindings inside the game's own settings file.** Every game would repeat the shape, and the
  engine could not apply it before the game runs.
- **Overrides as a content package the player owns.** That gives a preference package semantics,
  which ADR-0031 refused for settings, and it would let load order decide a player's own choice.
- **Dropping overrides for missing actions.** A player who toggles a mod off would lose their
  bindings for it.
- **Engine-decided conflict policy.** Swapping, refusing and allowing are each right for some game.

## Revisit if

- Players are seen losing a mod's new default because an old override replaced it.
- A game needs bindings per profile, which ADR-0040 leaves global.
- 256 overridden actions proves too few for a shipped game.
