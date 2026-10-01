# ADR-0059: Public 3D is retained instances by content ID, and mods change only what they own

**Status:** Proposed
**Date:** 2026-10-01
**Informed by:** ADR-0004, ADR-0026, ADR-0027, ADR-0040, ADR-0050, ADR-0051, ADR-0053, ADR-0058,
`docs/design/3d.md` §9 and §10, `docs/design/public-abi.md` §5–§8, `docs/design/public3d.md`

## Context

`3d.md` §9 says `FoundryApi_v6` publishes 3D: meshes, models and materials by content ID,
instances, the transform components, cameras, lights, and `physics3d` queries and the character.
It does not say how a mod gets a 3D object onto the screen, and the existing boundary does not
answer it. `render3d` accepts draws only between its `begin` and `prepare`, and a mod's code runs
only in `foundry_mod_init`, in systems at the fixed tick, and in loader and reload callbacks
(`public-abi.md` §8). None of those is inside the host's frame. v1's `render_draw_sprite` has the
same gap, hidden because no sample loads native code.

A second question comes with bodies. v1's `physics_destroy_body` accepts any body handle. A 3D
query returns the handles of everything it hits, including the player's character, so a mod
holding that answer could delete it.

Once v6 ships, its calls are frozen (ADR-0004), so both answers are permanent.

## Decision

**A mod draws in 3D by creating retained instances and lights, which the host submits in its own
frame.** An instance is a model named by content ID, a world matrix, optional material overrides
by content ID and a visibility flag. A mod creates, changes and destroys it from any code it runs;
the host calls `render3d.Instances.submit` once a frame, at a point it chooses, and every live
instance draws in slot order. The retained set lives in `render3d`, carrying an opaque owner tag;
`abi` translates calls into it and holds no engine state.

**Content crosses as content IDs, never as handles or payloads.** Models, materials and
collision meshes are named by ID and acquired by the boundary, so a mod never holds a payload
and another package's override reaches its instances at the next reload.

**A mod may change or destroy only what it created.** Every create call takes the caller's
`FoundryMod`, and instances, lights, bodies and characters remember it. Any other live handle is
`FOUNDRY_ERR_REFUSED` for mutation. Reading and querying anything stays open. Entities remain the
world's, as in v1.

**v6 does not publish** a camera write, animation, runtime meshes, materials or textures, shaders,
hull or mesh shapes, or 3D in the script host. Each is deferred with a trigger in `public3d.md` §14.

## Consequences

- No untrusted code runs on the render path, so `public-abi.md` §8's reentrancy rules need no
  new case, and a faulting draw cannot happen inside `prepare`.
- Determinism is structural: systems write poses at ticks, frames draw the last written pose in a
  documented order.
- Every value is validated once, at the call that sets it, not every frame.
- **Cost:** a mod that wants thousands of short-lived objects pays a create and destroy call each,
  and the set has a fixed capacity (1,024 by default). That is the trigger for an immediate path.
- **Cost:** a host must call `submit` and lend the set; a host that forgets draws no mod objects.
  The sample is the reference for where the call goes.
- **Cost:** 3D bodies are stricter than 2D's, so the two physics groups differ in one rule. 2D
  cannot be tightened without breaking v1 mods; the difference is documented.
- `render3d` gains a small mechanism a game may also use, and keeps immediate submission as its
  primary API (ADR-0052 is unchanged).

## Alternatives considered

- **Immediate drawing through a per-frame callback** (`draw_model` during a host-called draw
  hook). Rejected: it adds a callback kind on the render path, running untrusted code between
  `begin` and `prepare`, and every other call made inside it then needs a reentrancy rule. It
  buys nothing a mod needs today.
- **An engine-declared "draws this model" component, extracted by the host.** It would make
  entity-driven drawing uniform, but it is an engine component chosen before a second host shows
  what it should hold, and it would still need a host that extracts it. Deferred, not rejected.
- **The instance table inside `abi`.** Rejected: it is renderer state with renderer semantics
  (order, budgets, reload), and ADR-0026 keeps `abi` a translator.
- **v1's open body rule, for symmetry.** Rejected: queries hand out other bodies' handles, and
  a mod deleting the player is not a capability anyone should have by accident.
- **Handles for models and materials** (`render3d_model_acquire`). Rejected: a handle is a second
  lifetime a mod must manage for something a content ID already names, and the boundary can
  acquire on the mod's behalf.

## Revisit if

- A real mod needs many short-lived objects a frame, and retained create/destroy is measured as
  its bottleneck.
- A second host wants entity-driven drawing that mods can join, which argues for the engine
  component.
- A mod has a legitimate need to change bodies it did not create (a level-editing tool), which
  would need an explicit host grant rather than a relaxed rule.
