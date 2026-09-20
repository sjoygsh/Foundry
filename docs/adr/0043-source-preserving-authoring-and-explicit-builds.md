# ADR-0043: Preserve source bytes and separate editing, saving and building

**Status:** Accepted, 2026-09-20. The owner accepted M15's design and asked for Step 1.
**Date:** 2026-09-19 (proposed); 2026-09-20 (accepted)

## Context

`.fdt` is human-editable, commentable source (ADR-0006/0020). The parser keeps semantic
declarations and diagnostic origins, but does not retain every comment or a complete editable
syntax tree. Runtime records are merged definitions: reconstructing source from them would
lose comments, imports, omitted fields, schema declarations and overridden definitions.

M15 needs an editor that can save without damaging an author's text. It also needs an honest
failure model: `Os.replaceFileConfined` atomically replaces one file, not a package directory;
the current compiler may emit generated assets before the whole compile succeeds; and runtime
reload can retain the old content after a failed load.

## Decision

**1. Source bytes are authoritative.** Keep original bytes per file and extend the existing
parser with optional source ranges needed for editing. A field edit replaces its value span;
insertion, removal and list operations splice the smallest relevant range. Bytes outside the
explicitly edited or deleted construct are preserved exactly, including comments, newline
style and imports. New constructs use a deterministic emitter over the existing grammar.

Deleting a construct deletes comments inside its span; the editor previews that deletion and
supports undo. A scalar edit never rewrites an enclosing record. This is not a whole-file
formatter and does not settle `content-schemas.md`'s formatter or external-editor grammar
questions. There is no second parser or alternative authoring format.

**2. Draft, disk and loaded content are separate states.** A command creates a candidate draft,
checks its syntax and local type/range constraints, then installs it as one revision or leaves
the old one intact. An incomplete required field or unresolved reference can remain in a
draft; package validation names it. Bounded undo/redo restores exact bytes, not approximate
runtime values. Runtime handles are never serialized into source.

**3. Save is explicit and per file.** Before replacement, compare current disk bytes with the
document's last-read/saved baseline. A changed file refuses the save; there is no silent force
overwrite or automatic semantic merge. A cooperating-editor workspace lock covers compare
and replacement. It cannot lock an unrelated text editor: a racing external writer after the
comparison remains an explicit limit. Use confined atomic replacement and report its durability
answer accurately. A multi-file save reports which files succeeded; it never claims a
transaction across files. Undo is not a write to disk until Save is requested again.

**4. Build is explicit and consumes a stable, saved snapshot.** Refuse a build with dirty
documents. Snapshot the bounded source/asset inputs and dependency bytes, use the same compiler
as `fpack`, and place all products in a new private candidate directory under the granted
output root. Only a completely validated candidate becomes a successful build handle. A
failure leaves previous successful products and loaded content intact. Generated assets and
source files are never intermixed.

The output is the existing `.fpk` plus its asset tree, not an editor-only runtime format.
No source package executes code merely because it was opened or compiled.

**5. Reload consumes a successful build through the public surface.** The editor requests
activation of that build at a safe frame boundary. The host uses the ordinary package loader
and content generation mechanism; it does not inject records into a store. Failure retains
the previous preview, and the UI distinguishes saved, built and loaded revisions. M15's
preview is loaded-record and asset-metadata inspection, not an arbitrary game
simulation. A consuming sample's normal mod path provides the final visible-behaviour proof.

## Consequences

- The editor and a text editor can share a source tree without every GUI edit reformatting it.
- Draft mistakes are recoverable; failed saves/builds/reloads have different, visible outcomes.
- Integer precision, `f64`, authored absence and schema versions survive round trips; v1's
  narrowed runtime readers cannot be used as an authoring serializer.
- Cost: parser source ranges, revisioned documents, bounded history and candidate output
  lifetime. This is more work than serializing the live store, because the latter is lossy.
- Cost: explicit Build requires Save first, and concurrent unrelated filesystem writers cannot
  be made transactional by an ordinary rename. These limitations are visible, not hidden.

## Alternatives considered

- **Regenerate a whole package from the merged store:** destroys source information and
  collapses overrides. Rejected.
- **Normalize every opened file:** erases comments/layout merely by using the tool. A future
  formatter may be explicit; it is not a save policy.
- **Save every keystroke and compile automatically:** makes incomplete edits persistent and
  repeated expensive failures normal. Explicit commands are sufficient for M15.
- **Transactional filesystem/database project format:** a second authoritative representation
  and a recovery protocol for a problem one-file atomic saves can state honestly.
- **Write compilation output over the last good package:** generated-asset failures can leave
  a mixture of generations. Isolated candidates keep the existing compiler's failure safe.

## Revisit if

Real authors need atomic multi-file refactors, collaborative editing, background autosave or
build-on-edit; source-splice complexity exceeds a measured lossless syntax-tree alternative;
or large assets make bounded input snapshots impractical. Each requires evidence and its own
scope, rather than weakening source preservation or silently extending M15.

## Implementation

- **Step 1, 2026-09-20:** decision 1's source ranges and deterministic emission are in `data`:
  opt-in parser spans, `emit.zig` and `splice.zig`. The chosen span representation is in
  `editor.md`'s Step 1 Resolution.
- **Step 3, 2026-09-20:** decision 2's revisioned drafts and bounded exact-byte history are in
  `author/edit.zig` and `author/workspace.zig`. Typed commands validate candidates before an
  atomic in-memory install; incomplete required fields remain diagnosed drafts; exact
  dependency values come from `.fpk` readers rather than narrowed runtime getters.
- **Step 4, 2026-09-20:** decisions 3 and 4 are in `author/save.zig`, `author/build.zig` and the
  workspace. Saves use a confined create-or-replace primitive under an exclusive cooperating-
  writer token, compare bytes rather than timestamps and report per-file publication and
  durability. Validation/build capture bounded source, asset and dependency snapshots into
  fresh private candidates; only a fully compiled and load-validated candidate receives a
  generational handle, and prior candidates live until release. Decision 5 remains Steps 5–7:
  Step 4 publishes no ABI and activates no preview. Details and evidence are in `editor.md`'s
  Step 4 Resolution.
