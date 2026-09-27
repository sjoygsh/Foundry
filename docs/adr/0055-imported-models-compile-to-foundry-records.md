# ADR-0055: Imported models compile to Foundry records, with derived IDs

**Status:** Accepted 2026-09-27 when the owner requested M20 Step 1
**Date:** 2026-09-27
**Informed by:** ADR-0006, ADR-0021, ADR-0048, ADR-0053, `docs/design/meshes.md` §5 and §6,
`assets.md` §3

## Context

ADR-0053 keeps glTF's shape out of everything below the compiler: an import produces a runtime
mesh, textures, materials and a model, and nothing downstream can tell which importer made
them. That leaves two questions every imported file raises, and both are public: mods and saves
will name what an import produces.
- **Where do import settings live?** An import needs a few choices the file cannot make: which
  way the model faces (`3d.md` §2), and which of its materials are ones the package already
  has. The tile grid, the only authoring format compiled today, has no settings at all.
- **What are the generated things called?** One glTF file yields several records: a model,
  one mesh per glTF mesh, materials and embedded textures. Each needs a content ID (I2).
  Derivation takes an ID from a path and transforms nothing (`assets.md` §3). glTF's own names
  are optional, may repeat, and are rarely valid ID segments.

## Decision

**An import record is the authoring form of a model, and the compiler replaces it.**
- A `foundry:model_import` record (`source`, `front`, `materials`) compiles into the
  `foundry:model` of the same ID, and never reaches the `.fpk`. This is ADR-0006's two
  representations, applied to one record.
- A `.gltf` or `.glb` file with no import record imports with every default. The model's ID is
  derived from the file's path, as any asset's is.
- An authored record wins over derivation, as everywhere.

**Generated records take the model's ID plus one segment, numbered by the glTF array they came
from:**
- `M.mesh<i>`;
- `M.material<i>`, unless the import maps that glTF material, by name, to an existing
  `foundry:material`;
- `M.texture<i>`.

**Every generated record is written as `.fdt` text and checked by the one checker.** Every
generated asset is written under the compiler's asset output. The output is a function of the
source bytes alone (I9).

**A placement the runtime cannot hold is refused, never approximated.** A model's part is a
TRS (ADR-0048). A flattened node chain whose product shears fails `3d.md` §7.1's exact
decomposition, and is an import error that names the node.

## Consequences

- **Nothing at runtime knows an import happened.** A compiled package holds a model, meshes,
  materials and textures, exactly as if a person or a second importer had written them. A mod
  overrides a generated material or model by ID, like any record.
- **The importer's ID scheme is a public specification.** A tool that references a generated
  record must compute the same ID. It is one rule, with no transformation in it.
- **Indices are unstable across re-exports that insert an element.** This is the honest hole
  derived paths already have (`assets.md` §3). The material mapping closes it for the kind a
  mod is most likely to reference, and gives that material a name a person chose.
- **A record type exists that the runtime never sees.** The editor edits it like any record,
  and a build replaces it. A package's source and its compiled form therefore differ in more
  than encoding, for this one schema.
- **Sheared exports are refused.** An artist must apply the transform in the exporter, or
  restructure the hierarchy. A refusal naming the node is cheaper than a model that looks
  subtly wrong.

## Alternatives considered

- **IDs from glTF names.** These are stable across re-exports and meaningful. Most exporters
  write names like `Cube.001`, which derivation's no-transformation rule refuses. Transforming
  names would be a second specification that every tool must match (`assets.md` §3).
  Refusing them would make almost every real file fail. Names are kept for people, as a slot's
  `name`, and never as identity.
- **Settings in the model record itself,** with the compiler filling in the parts. Then the
  runtime record would carry a path to an interchange file it never reads, and one record would
  be half authored and half generated.
- **Settings in the glTF file's `extras`.** That puts Foundry's settings in a file an exporter
  rewrites, where a diff cannot show them and the editor cannot edit them.
- **Keeping the import record in the `.fpk` beside the model.** That needs two IDs for one
  thing, or a record with no runtime meaning that a mod could override to no effect.
- **Storing parts as matrices,** so that shear is representable. A model could then not be
  written by hand in the same terms as the pose M21 authors. The one sheared case would become
  every consumer's problem.

## Revisit if

- A mod needs a stable name for a generated mesh or texture, and breaks when an index moves.
  The fix is a mapping like the material one, or the per-package ID ledger ADR-0021 names.
- A second importer (OBJ, FBX, a procedural generator) needs settings `foundry:model_import`
  cannot express.
- Real assets are refused for shear often enough that artists cannot reasonably fix them at
  export.
