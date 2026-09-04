# ADR-0020: A purpose-built authoring text format

**Status:** Accepted (implementation begins in M3)
**Date:** 2026-09-04

## Context

ADR-0006 decided the content model — schemas are canonical, content is instances of schemas,
two representations — and deliberately deferred the authoring syntax to M3, recording its
requirements: comments, unambiguous typed scalars, stable diffs, imports, hand-writable,
machine-generatable, good error messages. JSON was disqualified there and is not reopened.

M3 is that milestone. Four candidates were weighed against those requirements, and three
facts decided it.

**We write the parser either way.** There is no mature permissively-licensed Zig parser for
TOML or KDL that ADR-0016's policy and development rule 3 would let us adopt without
inheriting a dependency larger than the thing it parses. So the usual adopt-versus-build
argument collapses: adopting buys a spec somebody else maintains and editor syntax
highlighting, not saved work.

**No candidate has imports.** TOML has none, KDL has none, ZON has none. ADR-0006 lists
imports as a requirement, so every adopted format needs a Foundry-specific extension bolted
on — at which point the file is no longer that format, and its error messages cite a spec
that does not describe it.

**The record shape is the format's main job.** Content is named records: a schema, a
`namespace:name`, and typed fields. A syntax whose primary shape is that costs a mod author
nothing to learn; a syntax that expresses it through array-of-tables or nested object
literals makes the most important thing on the page look like every other line.

There is also precedent, and it is loud. ADR-0018 wrote a PNG decoder rather than take an
image library. `core/id.zig` specifies FNV-1a in full rather than call `std`. Both for the
same reason: **a persisted format is a compatibility contract, and we own our contracts.**
Content text is the most persisted, most mod-facing thing in the engine.

## Decision

**Foundry has its own authoring text format**, in files with the extension `.fdt`. Its shape
is deliberately unoriginal — anyone who has read a configuration file can read it — but it is
ours, specified in `docs/design/content-schemas.md`, and its parser, its diagnostics and its
compatibility story belong to Foundry.

The decisions that are expensive to reverse, and therefore belong here rather than in the
design doc:

**A record is `<schema> <id> { fields }`.** Schema first because it is what you look for when
scanning; the ID second because it is what you search for.

**Content IDs are bare tokens, not strings.** `foundry:item.ash`, never `"foundry:item.ash"`.
This is the single most consequential syntactic choice in the format. An ID is visibly a
reference rather than a piece of text, so a mistyped reference fails at compile time instead
of becoming a string that happens to be wrong; and `grep foundry:item.ash` finds every use
across every package on disk.

**Directives are `@`-prefixed: `@import`, `@schema`, `@patch`.** Any bare leading token is a
schema name. This costs one character and permanently removes a compatibility hazard: schema
names come from mods (I6), so a future directive spelled as a bare word could collide with
content that already exists. There will never be a Foundry release that has to choose between
adding a directive and breaking someone's schema.

**No commas, no `=`, no significant whitespace.** Whitespace separates, braces nest, brackets
list. Fewer characters to get wrong, and every diff stays line-oriented.

**Scalars are unambiguous by construction.** Integers are exact and never silently become
floats; a float is written with a decimal point or an exponent, so `1` and `1.0` are
different tokens with different types; strings are double-quoted with a small, fixed escape
set. The ambiguity ADR-0006 objected to in JSON is designed out rather than documented
around.

**The format is not a programming language.** No expressions, no arithmetic, no conditionals,
no variables, no string interpolation. `fpack` is a compiler, not an interpreter, and content
that cannot compute cannot be non-deterministic (I9).

**Diagnostics are the deliverable, not a nicety.** Every error names the file, the line, the
column, the schema, the field and what was expected. This is the concrete thing owning the
parser buys, and ADR-0006 already recorded why it matters: a mod author cannot debug a crash.

**Overrides are expressed in the format.** A later package restating a record replaces it;
`@patch` merges named fields. ADR-0006 committed to designing merge semantics now and
implementing them incrementally starting with replace, and that is what happens: `@patch` is
specified in the design doc and lands after replace works.

## Consequences

* The format fits the content model exactly, because it was drawn around it. Records, IDs,
  imports, schemas and overrides are first-class rather than encodings.
* Error messages can be as good as we are willing to make them, and improving them is a local
  change rather than a request to an upstream project.
* No dependency, no upstream spec revision to track, no version of someone else's format to
  pin. The `.fdt` grammar changes when Foundry decides it changes, under I8.
* **Cost: no editor support exists.** Nobody's editor highlights `.fdt` until we ship a
  grammar for one, and we owe at least a TextMate/tree-sitter grammar before `docs/modding/`
  is honest. This is the largest real cost of the decision and it is not zero.
* **Cost: mod authors learn something new.** Mitigated by the shape being familiar and the
  whole format fitting on one page, but it is a tax on the first hour of every mod author's
  time.
* **Cost: a parser is ours to get right.** Untrusted input from files, which means fuzzing,
  bounds on nesting depth and file size, and no assertion where a validation belongs
  (CLAUDE.md §5).
* Machine generation is easy: the format has no context-sensitive quoting and no indentation
  rules, so a tool emitting it cannot produce something subtly unparseable.

## Alternatives considered

* **TOML** — universally known, editor support everywhere, a maintained spec. Rejected: we
  would still write the parser; the record ID degrades into an ordinary field; nesting a table
  inside an array-of-tables is a genuine subtlety that mod authors get wrong; it carries
  datetimes we do not need; and it has no imports, so we would extend it and lose the
  familiarity we adopted it for.
* **KDL** — the node shape matches named records almost exactly, and someone else maintains
  the spec. Rejected: obscure enough that the familiarity argument mostly evaporates, and
  claiming the name means owing the whole 2.0 spec — type annotations, slashdash comments, raw
  strings, unicode identifier rules — which is more than content needs. Its shape is
  nonetheless the closest to what we chose, and that is not a coincidence.
* **ZON** — the only candidate with a parser already in `std`, so genuinely zero parser work.
  Rejected: it ties Foundry's most persisted format to a pre-1.0 language artifact that moves
  between releases, it is unreadable to a mod author who does not write Zig, and CLAUDE.md
  §4.1 deliberately keeps `std` churn concentrated behind `core` rather than spread across
  every content file on disk.
* **JSON** — disqualified by ADR-0006 and by explicit developer decision. Not reconsidered.

## Revisit if

Mod authors report the format itself as friction rather than the tooling around it; or the
parser and its diagnostics grow large enough that an off-the-shelf format plus a Foundry
preprocessor would genuinely be less code; or an authoring tool becomes the primary way
content is produced, at which point the text format's ergonomics matter less than its
round-tripping.
