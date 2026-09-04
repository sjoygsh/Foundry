# Design: `data` — schemas, content, packages

**Status:** §2, §3 and §4 implemented as `engine/src/data/` (2026-09-04) — identity,
schemas and the registry, the lexer, the parser and diagnostics. §5 onward is still design.
See §4.7 for what implementation changed.
**Date:** 2026-09-04, revised 2026-09-04
**Implements:** I2, I3, I5, I6, I8, I9 · **Informed by:** ADR-0005, ADR-0006, ADR-0007,
ADR-0020, ADR-0021, CLAUDE.md §6

`data` is layer L1. It depends on **`core` alone** — and that single line of the layering
table (ADR-0007) is the most structurally important fact about this module, so it goes first
rather than in a footnote.

**`data` cannot open a file.** The filesystem lives in `platform`, which is L1 beside it, not
below it. Everything here operates on byte slices somebody else obtained: the text parser is
handed source, the package reader is handed a package's bytes, and `@import` resolves through
a caller-supplied callback. `asset` (L2, which has both) is where files become bytes.

That was not designed for; it fell out of the layering and turned out to be exactly right.
A content pipeline that cannot touch the disk is a pure function, which means it is
hermetically testable, trivially deterministic (I9), and safe to run on untrusted input
without wondering what it might read. The layering caught something a free hand would have
got wrong.

This document is the second most consequential in the project after `rhi.md`, for the reason
`render2d.md` gives about itself: **the names here are seen by people we do not control.**
A schema field name, a directive spelling, a type name — renaming any of them later breaks
mods and saves. CLAUDE.md §7 says to treat these with more care than internal names, and
that applies to every identifier in §4 and §5 below.

---

## 1. What this is, and what it is not

`data` owns four things and nothing else:

| | |
| --- | --- |
| **Schemas** | Named record *types*: a list of typed, versioned fields. Registered at runtime (I6). |
| **Records** | Instances of schemas, each with a stable `ContentId` (I2). |
| **Packages** | An ordered, named group of records — the unit that ships, and the unit a mod is. |
| **The store** | The result of merging packages in load order. What the rest of the engine reads. |

It is **not**: the filesystem, the asset system (`assets.md`), the entity system (M4, records
are not components), a scripting host, or a general-purpose configuration library for the
engine's own settings. Engine configuration is not content and does not come through here.

**What M3 implements**, of everything below: schemas, records, packages, the `.fdt` parser,
the `.fpk` reader and writer, and **replace** override semantics. `@patch`, `@remove` and
list-append merge are specified here and land after (ADR-0006 committed to designing merge
now and implementing it incrementally). Where a section describes something M3 does not
build, it says so.

---

## 2. Two ID spaces, both stable, neither derived

`core/id.zig` already owns the hash and refuses to normalise: `ContentId.fromString` hashes
the exact UTF-8 bytes, "no case folding, no trimming, no Unicode normalisation", because
normalisation would be a second specification every mod tool must reimplement identically.

`data` is where the other half of that goes. **`core` refuses to normalise; `data` refuses to
accept anything that would need normalising.** A valid ID is:

```
id        := namespace ":" name
namespace := [a-z] [a-z0-9_]*
name      := segment ("." segment)*
segment   := [a-z] [a-z0-9_]*
```

Lowercase ASCII only, at most 255 bytes total. So `Foundry:Torch` is not a differently-cased
version of `foundry:torch` — it is not an ID at all, and is rejected where it is written with
a diagnostic saying why. The trap that case-sensitive hashing would otherwise set is removed
without either half of the system having to guess at the other's intent.

An ID that hashes to zero is rejected: `ContentId.none` is the absence of an ID, and content
may not collide with absence.

**Schema IDs and content IDs are separate spaces.** Both are `namespace:name`, both hash the
same way, and they are resolved in different tables — so the schema `foundry:item` and a
record named `foundry:item` can coexist without either shadowing the other. They are never
confused in the text either, because a record names its schema first and its own ID second:
position disambiguates before the tables ever see them.

**Hash collisions are a build-time error, not a runtime mystery.** `fpack` keeps every source
string, and inserting two different strings that hash alike fails the build naming both.
ADR-0005 called for exactly this. 64 bits of FNV-1a makes it vanishingly unlikely; making it
loud costs a hash map.

---

## 3. Schemas

A schema is a named record type: an ID, a version, and an ordered list of field
declarations.

```zig
pub const Schema = struct {
    id: SchemaId,
    version: u32,
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,       // ASCII identifier, [a-z][a-z0-9_]*
    type: FieldType,
    default: ?Value = null, // absent means the field is required
    since: u32 = 1,         // the schema version that introduced it
};
```

### The type list is closed, and small

```
bool
i32  i64  u32  u64          exact integers, never silently floats
f32  f64
string                      UTF-8, validated
id                          a ContentId reference
[T]                         a list of T
{ ... }                     an inline struct: named fields, no identity of its own
```

Closed because every type costs three implementations that must agree — a text form, a
binary form and a validator — and because a type that reaches a compiled package can never be
removed. Small because a struct composes: a colour is `{ r f32  g f32  b f32  a f32 }` and
a position is `{ x f32  y f32 }`, which is one type doing the work of a dozen.

Deliberately **absent**, with reasons: no `any`/variant type, because a field whose type is
not known statically cannot be validated at compile time, which is the point of having
schemas; no expression type, per ADR-0020; no binary blob, because ADR-0006 says binary
payloads are assets, referenced by ID, never embedded in content text.

An inline struct has **no `ContentId` and cannot be referenced or overridden independently.**
Anything a mod might want to override on its own is a record with an ID, and choosing between
the two is a schema author's most consequential decision. `docs/modding/` owes a page on it.

### Versioning, and what happens to old content

I8 applies: a schema carries a `version`, and each field records the version that introduced
it. Loading a record written against an older schema version fills the fields it does not
have from their defaults; a field added without a default is a **breaking schema change**,
and `fpack` says so at the point the schema is compiled rather than at the point somebody's
save fails to load.

Loading a record written against a *newer* schema version than the engine knows is a clean
refusal naming both versions, never a partial read.

### Registration is runtime, including ours (I6)

The registry is a runtime table, and the engine's own schemas go in through the same call a
mod's `@schema` directive uses. There is no compile-time schema list.

```zig
pub const Registry = struct {
    pub fn register(self: *Registry, gpa: Allocator, schema: Schema) RegisterError!SchemaHandle;
    pub fn find(self: *const Registry, id: SchemaId) ?SchemaHandle;
    pub fn get(self: *const Registry, handle: SchemaHandle) ?*const Schema;
};
```

Registering a schema whose ID already exists is an error unless the incoming version is
higher and the change is additive — a later package *extending* a schema is a legitimate and
important thing for a mod to do, and it is the only form of schema override that can be
checked for safety. Replacing a schema outright is refused: records already parsed against
the old one would silently reinterpret their bytes.

Native code may use `comptime` helpers to *produce* a `Schema` from a Zig struct, and
probably will. I6 requires only that the registry accept entries a mod could also supply,
which it does, because the mod path and the `comptime` path both end at `register`.

---

## 4. The authoring format: `.fdt`

Decided in ADR-0020. This section is its specification.

### 4.1 A worked example

```
# content/core/items/light.fdt
#
# Everything after '#' to end of line is a comment. There is one comment syntax.

@import "items/shared.fdt"

item foundry:item.torch {
    name    "Torch"
    weight  0.5
    stack   20
    tags    ["light" "fuel"]
    light   { radius 6.0  falloff 2.0 }
    drops   foundry:item.ash
}

item foundry:item.ash {
    name   "Ash"
    weight 0.05
}
```

And, in a package that loads later:

```
# A mod that only wants the torch to be lighter.
@patch foundry:item.torch {
    weight 0.4
}
```

### 4.2 Grammar

```
file        := item*
item        := directive | record

directive   := "@import" string
             | "@schema"  schema_id "{" field_decl* "}"
             | "@patch"   content_id "{" field* "}"
             | "@remove"  content_id

record      := schema_ref content_id "{" field* "}"
schema_ref  := ident | content_id
field       := ident value
value       := bool | integer | float | string | content_id | list | struct
list        := "[" value* "]"
struct      := "{" field* "}"

field_decl  := ident type_expr attributes*
type_expr   := primitive | "[" type_expr "]" | "{" field_decl* "}"
attributes  := "(" attribute* ")"
attribute   := "optional" | "default" value | "since" integer
```

**No commas, no `=`, no significant whitespace or indentation.** Whitespace separates tokens,
braces nest, brackets list. Values are self-delimiting, so `weight 0.5 stack 20` on one line
parses exactly like two lines; one field per line is a convention the formatter enforces, not
a rule the parser needs.

### 4.3 Tokens

**Comments** are `#` to end of line. One syntax, so there is never a question of which.

**Identifiers** — field names, type names, attributes — are `[a-z][a-z0-9_]*`. Same character
set as ID segments, for one rule instead of two.

**Content IDs are bare tokens**, never strings: `foundry:item.ash`. This is ADR-0020's most
consequential syntactic choice and the reasons bear repeating, because they are what a future
session would otherwise "tidy away": a reference is *visibly* a reference rather than a piece
of text, so a typo fails at compile time rather than becoming a string that happens to be
wrong; and `grep foundry:item.ash` finds every use across every package on disk, including
in mods nobody has seen. The lexer separates the two cases on the presence of `:`.

**Integers** are optional `-`, then decimal digits or `0x` hex, with `_` permitted between
digits. The literal is checked against the field's declared range and a value that does not
fit is an error naming both.

**Floats** require a decimal point or an exponent — `0.5`, `1e-3` — so `1` and `1.0` are
different tokens carrying different types. `inf` and `nan` are **not** accepted: neither
survives content review, and I9 has enough to worry about.

An **integer literal in a float field is accepted when the conversion round-trips exactly**,
and is otherwise an error naming the loss. Refusing `0` for a float would be pedantry; the
ambiguity ADR-0006 objected to in JSON is the *reader's* inability to tell int from float,
and here the schema always can. A float literal in an integer field is always an error.

**Booleans** are `true` and `false`, valid only in value position.

**Strings** are `"..."`, UTF-8, validated. Escapes are exactly `\"  \\  \n  \r  \t  \u{...}`
and nothing else — an unknown escape is an error rather than a passed-through backslash,
because silently accepting `\d` is how a format acquires an accidental specification. A
literal newline inside a string is an error: it turns a missing quote into a diagnostic on
the right line instead of a parse failure a hundred lines later.

Multi-line strings are an **open question** (§10), not an omission.

### 4.4 Directives

Directives are `@`-prefixed so that any bare leading token is a schema name (ADR-0020). Schema
names come from mods, so an unprefixed directive would be a permanent hazard: some future
Foundry release would have to choose between adding a keyword and breaking somebody's schema.
One character buys that away forever.

**`@import "path"`** is textual inclusion at the package level. The imported file's records
belong to the *importing* package — an import is not a namespace and grants no identity.
Rules:

* Resolved relative to the importing file, and confined to the package root. `..` that
  escapes the package is an error, not a path.
* Importing the same file twice is a no-op, not a duplicate-record error. Diamond imports are
  the normal case, not a mistake.
* Cycles are detected and reported **as the chain**, because "cyclic import" alone is useless
  in a tree of forty files.
* Depth is bounded (§4.6).

Because `data` cannot open files, the parser takes a resolver:

```zig
pub const Resolver = struct {
    ctx: *anyopaque,
    /// Returns the bytes of `requested`, resolved relative to `importer`, or null if it
    /// does not exist. The returned memory is owned by the resolver.
    resolveFn: *const fn (ctx: *anyopaque, importer: []const u8, requested: []const u8) ?[]const u8,
};
```

Which also means every import test is hermetic: a resolver backed by a `StringHashMap` is
three lines, and no test in this module ever touches a disk.

**`@schema`** declares a record type. Its ID is a schema ID, in the separate space of §2.

```
@schema foundry:item {
    name    string
    weight  f32       default 0.0
    stack   u32       default 1
    tags    [string]  optional
    drops   id        optional
    light   { radius f32  falloff f32 }  optional
}
```

**`@patch id { ... }`** merges named fields onto whatever record currently wins for that ID
(§7). **Not implemented in M3.**

**`@remove id`** deletes a record a previous package defined. **Not implemented in M3**, and
noted here mostly because a mod that wants something *gone* has no other way to say it, and
discovering that at M7 would be late.

### 4.5 Diagnostics are the deliverable

ADR-0020 says owning the parser is bought principally for this, and ADR-0006 says why it
matters: a mod author cannot debug a crash. So every diagnostic carries **file, line, column,
the byte span, what was expected, and what was found** — and where a schema is in play, the
schema and field name too:

```
content/core/items/light.fdt:7:13: error: field 'weight' of schema 'foundry:item'
expects f32, found string
    weight  "0.5"
            ^~~~~
note: schema 'foundry:item' declared at content/core/schemas/item.fdt:3:1
```

Parsing **does not stop at the first error.** A parser that reports one error per run makes
fixing twenty a twenty-build afternoon. Recovery is to the next record boundary — the token
after a matched closing brace — which is a boundary the grammar makes unambiguous, and errors
are collected into a diagnostic list the caller renders. There is a cap, because a binary file
fed to the parser by accident should produce twenty errors and a note, not a hundred thousand.

### 4.6 It is untrusted input

Every `.fdt` file is input from a mod, so CLAUDE.md §5 applies without exception: **validated
and refused, never asserted.** The parser has hard limits, all configurable through a `Limits`
struct in the shape `asset`'s PNG decoder already uses:

| Limit | Default | Because |
| --- | --- | --- |
| source bytes per file | 16 MiB | Content text is not a data dump. |
| nesting depth | 32 | Bounds recursion; a struct 32 deep is a mistake. |
| import depth | 16 | With cycle detection, this only catches pathological trees. |
| identifier / ID length | 255 bytes | Matches the ID bound in §2. |
| fields per record | 4096 | |
| list elements | 1 << 20 | |
| diagnostics collected | 64 | Enough to fix an afternoon's worth; not a fork bomb. |

The parser is a target for fuzzing from the day it exists, and reaching an assertion or an
unhandled panic on *any* input is a bug regardless of how malformed the input was.

### 4.7 Resolution (implementation, 2026-09-04)

Three things the parser settled that this section had left ambiguous or open. All three are
syntax, and syntax is frozen the moment content outside this repository uses it, so they are
recorded rather than absorbed.

**A record's schema may be written bare; a content id may not.** §4.2 said
`record := schema_id content_id`, and §4.1's worked example wrote `item foundry:item.torch`.
Those disagreed. The resolution keeps both halves of what each was reaching for: a **bare
schema name means one in this package's own namespace**, so `item` in package `foundry` is
`foundry:item`, and a schema from elsewhere is written in full — `othermod:weapon
mymod:weapon.sword { ... }`.

The asymmetry with content ids is the point rather than an inconsistency. A schema name
repeats on every record of that type, so eliding it pays for itself immediately. A content id
is unique, so eliding it would save nothing and would cost the property ADR-0020 bought the
bare-token syntax for: `grep foundry:item.ash` finding every use across every package on
disk, including in mods nobody has seen.

**Schema attributes are bracketed: `weight f32 (default 0.5)`.** §4.2 had them bare, which
put attribute names in the same syntactic slot as field names — so a field could not be named
`optional`, and, worse, *adding an attribute in a later release would break any mod that had
used the new word as a field name*. That is precisely the hazard ADR-0020 spent a character
on `@` to remove at the directive level, and leaving it in place one level down would have
been inconsistent in the expensive direction. Parentheses make it impossible instead of
merely unlikely; a test asserts that `optional`, `default` and `since` are all usable as
field names. Repeated groups are accepted — `(since 5) (optional)` — because that is how
somebody who thinks of them as separate modifiers will write it.

**A schema's version is inferred, not declared.** §4.4 gave no syntax for declaring one,
which was a gap rather than a decision. The version is now **the highest `since` on any of
its fields**, defaulting to 1. One source of truth: a declared number could disagree with the
fields, and under the additive-only rule of §3 the only change that can bump a version *is*
adding a field. An author who forgets `since 2` on a new field gets a loud `DuplicateSchema`
from the registry rather than a silent reinterpretation.

---

## 5. The runtime format: `.fpk`

Shipped builds never parse `.fdt` (ADR-0006). `fpack` compiles a package directory into one
`.fpk` file, and that is what the engine loads.

### 5.1 Shape

Little-endian, 8-byte aligned sections, designed to be **read in place**: the goal is that
loading a package is a read (or a map) plus validation, not a parse.

```
header      64 bytes
  magic            [4]u8   "FPKG"
  format_version   u32     bumped when this layout changes (I8)
  package_id       u64     ContentId hash of the package's namespace:name
  package_version  u32
  flags            u32
  schema_count     u32
  record_count     u32
  section table    offset+length for each of the four sections below

schemas     schema_count entries: id, version, field count, field descriptors
records     record_count entries: { content_id, schema_id, offset, length } into fields
fields      the packed field data, laid out per each record's schema
strings     length-prefixed UTF-8; every string in the package, deduplicated
```

The version lives in a **field, not in the magic**, so a package from a future Foundry
reports "package format version 3, this build understands 1" rather than "not a package".
That distinction is the whole practical value of I8 at a file boundary.

Field data is laid out by the schema, so reading a field is an offset computed once when the
schema is resolved — not a string lookup per access. Variable-size fields (strings, lists)
store `{ offset, length }` into the strings or fields section.

### 5.2 The reader trusts nothing

Package files reach us from mod authors and from the internet. **Every offset and length in
the file is validated against the file's own size before anything is dereferenced**, section
bounds are checked before entry counts are believed, and every string is UTF-8-validated on
the way in. The reader is written so that a byte-for-byte random file produces an error, and
that is a test, not an aspiration.

`format_version` is checked first, and an unrecognised one refuses cleanly (I8) rather than
reading a struct that has since changed shape.

### 5.3 Why not just serialize the parse tree

Because the parse tree is pointer-shaped and the point of a runtime format is to not chase
pointers at load. Laying records out by schema means a package can be validated once and read
directly, which is what makes mapping a large content set viable later. That is the cost
ADR-0006 accepted when it chose two representations, and spending it in the layout is the
only way the choice pays for itself.

---

## 6. Packages, and load order

A package is a namespace, a version, and a set of records. It is the unit that ships and the
unit a mod is. **The base game is package zero** (I3) — `content/core/` compiles to a
`foundry:core` package that loads through exactly this path, with no privileged shortcut,
because being our own first user is the only durable proof the path works.

Load order is an **explicit, ordered list supplied from outside** `data`. Not directory
enumeration, not filesystem order, not alphabetical-by-accident: a list, given, in order, by
whoever assembled it. `data` does not discover packages, and mod dependency resolution is M7 —
until then the list is whatever the application passes.

That the merge is a pure function of `(packages, order)` is an I9 requirement, so the two
orderings it depends on are specified rather than incidental:

1. **Packages** merge in the order given.
2. **Records within a package** merge in the order they appear in the package's record table,
   which is the order they appeared in the authoring text with imports inlined at their point
   of use.

Both are stable and documented, so the same packages in the same order always produce the
same store — which is what makes it safe for anything downstream to depend on iteration
order at all.

---

## 7. Overrides and merge

Later packages override earlier ones **by content ID** (I2, ADR-0006). The ID is the whole
mechanism: nothing is matched by path, by file name, or by position, so a mod overriding a
record neither knows nor cares where the original lives.

**Replace — M3.** A later package restating `item foundry:item.torch { ... }` supplies a whole
new record. Simple, total, and impossible to get subtly wrong; also the reason `@patch` is
worth building, since replacing a forty-field record to change one field means silently
inheriting the other thirty-nine as they were *at the moment the mod was written*.

**Patch — designed, later.** `@patch id { ... }` merges named fields onto the current winner
and leaves the rest alone. Two mods patching different fields of one record both get their
way; two patching the same field resolve by load order, which is the only answer that stays
deterministic.

**List append — designed, later.** Whether a list field in a patch replaces or appends is a
*schema author's* decision, declared on the field, not a global rule — because "the loot
table" and "the display name" want opposite answers and no default is right for both.

**A patch or remove targeting a missing ID is reported and skipped, not fatal.** A mod
patching a record from a package the user did not install is an ordinary, expected situation,
and the correct response is a legible warning naming both, not a failure to start.

**The store remembers who won.** Each record keeps the package that supplied it. One `u16`,
and it turns "why is this torch heavy?" into an answerable question — for a diagnostic today,
and for a mod manager at M7.

---

## 8. The store

The merged result. Content IDs in, handles out (I1).

```zig
pub const Store = struct {
    pub fn find(self: *const Store, id: ContentId) ?RecordHandle;
    pub fn get(self: *const Store, handle: RecordHandle) ?Record;
    pub fn provenance(self: *const Store, handle: RecordHandle) ?PackageHandle;
    /// Every record of one schema, in the documented merge order of §6.
    pub fn iterate(self: *const Store, schema: SchemaId) RecordIterator;
};
```

**Resolve once, then use handles.** ADR-0005 named the mitigation for handle indirection and
this is where it is spent: content resolves its `id` fields to handles at load, and hot loops
iterate storage rather than chasing IDs. An ID that does not resolve is a reportable,
recoverable condition naming a readable string — never a crash, and never a silent zero.

Field access goes through the schema, by index resolved once:

```zig
const weight = record.f32(fields.weight) orelse schema_default;
```

Not by string per access, which would put a hash in the inner loop of every system that reads
content.

---

## 9. What this exposes to mods, and what it costs

Everything in §3 through §8 is mod-facing by construction — this is the module Tier 1 content
modding *is*. Which makes the naming rule in CLAUDE.md §7 bite hardest here: `@patch`, `f32`,
`optional`, `since`, `id`, the `namespace:name` shape and the `.fdt` extension are all frozen
the moment content outside this repository uses them.

The three that would hurt most to change, and are therefore worth being sure about now:

* **`@`-prefixed directives.** Reversing this means either colliding with schema names forever
  or breaking every file. It is the cheapest irreversible decision in the format.
* **Bare content IDs.** Making IDs strings later would silently turn every mistyped reference
  from a compile error into a runtime lookup failure.
* **Separate schema and content ID spaces.** Merging them later is a name collision waiting
  in somebody else's package.

---

## 10. Open questions

Recorded rather than resolved, per CLAUDE.md §8's rule that a decision nobody can falsify is
a habit.

1. **Multi-line strings.** Deliberately absent from M3. Long prose is probably a localisation
   problem — text in string tables keyed by ID, not inline in records — and designing a
   quoting scheme before knowing whether prose lives in `.fdt` at all would be inventing.
   Due when the first content that wants a paragraph appears.
2. **Whether `f64` earns its place.** I9 makes `f32` the simulation type; `f64` may be pure
   surface area. Cheap to remove now, impossible once a package uses it.
3. **Schema extension across packages.** §3 permits additive version bumps and refuses
   outright replacement. Whether a mod may add a field to *another* package's schema — and
   what happens to records already parsed against the shorter one — is the M7 question this
   leaves open on purpose.
4. **A canonical formatter.** `fdt fmt` would make diffs stable by construction rather than
   by convention, and the format was drawn to make one easy. Not M3.
5. **Editor support.** ADR-0020 recorded this as the decision's largest real cost. A
   tree-sitter or TextMate grammar is owed before `docs/modding/` can honestly tell somebody
   to go write content.

---

## 11. Deliberately not here

* **Mod manifests, dependency resolution, load-order computation** — M7. `data` consumes an
  order; it does not compute one.
* **Hot reload** — `assets.md`, because it needs a filesystem watcher and therefore a layer
  that can see files.
* **Save files.** They share the identity scheme and the versioning discipline, and they are
  M4's problem, not this document's.
* **Engine configuration.** Not content. It does not come through here and should not start.
