# ADR-0067: Buses and effects are content, mixed by engine-implemented nodes

**Status:** Proposed 2026-10-27 (`docs/design/mixing.md`)
**Date:** 2026-10-27

## Context

M30's mixer adds every voice into one buffer, multiplies it by a master gain, and clamps it.
`audio.md` §11 left buses open ("a gain per named category is a few lines; a real bus graph is
a subsystem"), and §12 left out effects and "a real limiter or compressor". M31's roadmap line
asks for all of them.

Three facts shape the answer:
- **Which buses exist is game content.** "Music", "world" and "UI" are a game's categories,
  not the engine's, so I5 keeps them out of engine source. A mod that adds sounds may need a
  bus of its own.
- **Effects run on the device thread**, inside the callback that cannot fail, allocate, lock
  or log (ADR-0023). A fault there is not containable. `audio.md` §10 already ruled that mod DSP
  would be "a graph of engine-implemented nodes a mod configures, not a function pointer".
- **Decibels need `exp` and `log`.** Zig's builtins resolve to whatever math library a binary
  links, which is ADR-0064's problem: a pin then depends on the binary.

## Decision

1. **The mix is a tree of buses described by `foundry:audio_bus` records.**
   - Each record names its parent, so a mod adds a bus by adding one record and overrides
     nobody's list.
   - A game names the root with `Mixer.useMix(root)`. Every bus whose chain reaches it joins.
   - The tree is limited to 32 buses and depth 8. A cycle is refused by name on the game
     thread.
   - A voice routes to the bus its `foundry:sound` record names.
2. **Each bus has an ordered chain of up to eight effects, each its own record type:**
   `foundry:audio_filter` (a biquad, six shapes), `foundry:audio_delay`,
   `foundry:audio_reverb` (an eight-line feedback delay network), `foundry:audio_compressor`
   and `foundry:audio_limiter` (lookahead). The set is fixed engine code. Mods configure
   effects through records and never supply DSP.
3. **Mixing order is documented:** children before parents, siblings by ascending content ID,
   never load order. The root's gain is the master gain, and the clamp stays after it as the
   last safety net.
4. **Everything the callback uses is allocated when the tree is built**, on the game thread:
   one buffer per bus, and each effect's state.
   - A parameter change is a command, and the effect's state carries on.
   - A shape change builds a new tree and installs it with one command between two buffers.
     The old tree comes back through the events ring to be freed.
5. **No tree is M30's mixer exactly**: one implicit root with no effects, whose buffer is the
   device's. Existing output, pins and the 2D samples are unchanged by construction.
6. **`core.math.exp`** gives `exp2`, `log2`, `dbToGain` and `gainToDb` in arithmetic alone,
   beside `core.math.trig`. Coefficients and the dynamics' gain computers use them, never a
   linked math library.

## Consequences

- A game's mix, a mod's change to it and an editor's view of it are all records. `nocturne`
  lengthens a reverb and adds an echo with no code.
- The callback's work grows with buses and effects. The design bounds it (criterion 6: at
  least 20× real time on the i3 with the court's full load), and the tree's limits bound the
  worst case.
- A shape change restarts every effect's tail. Only edits to the mix's structure are heard,
  and only at the reload that made them.
- The limiter's lookahead delays its subtree by a constant (96 frames by default). The sample
  clock and scheduled starts stay exact against mixed frames, and the mixer reports the
  latency.
- The set of effects can grow only by engine change. That is the price of keeping mod code off
  the device thread, and it is paid deliberately.

## Alternatives considered

- **A fixed set of categories in the engine** (music, effects, voice, UI). Rejected: the names
  are game content (I5), and a game with a different split would have no answer.
- **Parent lists children.** Rejected: two mods each adding a bus would both override the
  parent's list, and the later would erase the earlier.
- **One effect schema with a `kind` and generic parameters.** Rejected: fields could not carry
  their own ranges, `fpack` could not refuse a reverb's `ratio`, and the editor could not show
  the fields that apply.
- **A general graph with sends.** Rejected for now: a DAG needs ordering and latency
  compensation across paths, and an insert reverb with wet and dry covers the court and the
  common case.
- **Mod-supplied DSP**, as native callbacks or scripts. Rejected permanently: device-thread code
  a mod supplies is the one fault Foundry cannot contain (`audio.md` §10).
- **A third-party DSP library.** Rejected: five well-documented structures in a few hundred
  lines each do not justify a dependency (CLAUDE.md §2, rule 3). Their results must also be
  pinned across binaries, which a library's math calls would prevent.

## Revisit if

- **Two buses need the same reverb instance**, so that one shared tail is heard rather than two.
  Sends would then be decided.
- **The court-shaped load falls below 20× real time** on a supported machine. The bus buffers
  and effect order would then be measured for a cheaper form, such as block processing or SIMD.
- **A game needs an effect outside the set**, such as a chorus, a pitch shifter or convolution.
  It is added as engine code, by its own decision, never as a mod hook.
