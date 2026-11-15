# ADR-0085: Lights are records a model places

**Status:** Accepted 2026-11-15, when the owner requested M41 Step 1
**Date:** 2026-11-15
**Informed by:** ADR-0053, ADR-0055, ADR-0056, `docs/design/light.md` §7.1 and §14, `docs/design/environment.md` §6

## Context

Since M22, lights are values a game submits each frame, and every sample keeps them in its own
schema. Three things are missing:
- a mod can change a sample's lights only through that sample's schema;
- an imported glTF scene's `KHR_lights_punctual` lights are ignored;
- there is no engine name for a light that M48 could later publish.

`light.md` §14 set the record and the import aside for "when an imported scene carries lights
someone wants". M41 is that milestone.

## Decision

- **`foundry:light` v1** is an engine record with `render3d.Light`'s fields except its world
  matrix: kind, colour, intensity, range, inner and outer cones, `casts_shadow` and
  `source_radius`. Its meaning is `KHR_lights_punctual`'s, with ADR-0056's units. It has no
  position. It is validated at load as `addLight` would validate it.
- **`foundry:model` v4 places lights** as it places parts: a list of a light ID, a translation
  and a rotation, relative to the model.
- **Lights remain submitted values.** `render3d.Content.modelLights` writes a model's placed
  lights at a world matrix into the caller's slice, and the game submits them. No light is
  drawn because a model is.
- **glTF import** copies each node's `KHR_lights_punctual` light field for field into
  `<model>.light<i>`, refuses a light under non-uniform or negative scale, and lets
  `foundry:model_import` v4 set `casts_shadow` and `source_radius` by the light's name.

## Consequences

- A content mod changes any light by overriding its record (I3). The samples move onto records.
- An artist's lamp arrives from Blender with its light.
- **Cost:** a schema version on `foundry:model` and `foundry:model_import`. Old packages still
  read, since the new fields are optional.
- **Cost:** a game that wants a light to move with a model calls `modelLights` each frame with
  the model's world matrix.

## Alternatives considered

- **A light component in `scene`** that the engine draws. Rejected: `render3d` does not see
  entities (ADR-0053), and lights would gain a second submission path. A component is a game's
  choice over `modelLights`.
- **A light record with a position.** Rejected: one lamp would need one record per placement,
  and a mod changing every streetlamp's colour would have to override each.
- **Importing lights into a separate scene record.** Rejected: a model is what an import
  produces (ADR-0055). The lights of an imported lamp belong to the lamp.

## Revisit if

- A game needs a light that animates with a skeleton's joint (M77's animated nodes are the
  likely trigger).
- A model's lights must be culled or limited by the engine because games keep exceeding sixteen
  (ADR-0052's trigger).
- M48's publication needs a light to be addressable by placement, not only by record.
