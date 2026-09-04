# Design: `data` — schemas, content, packages

**Status:** §2 through §8 implemented as `engine/src/data/` (2026-09-04) — identity,
schemas and the registry, the lexer, the parser, diagnostics, the pass that checks a parsed
document against the schemas it names, the `.fpk` writer and reader, and the store that
merges packages in load order and answers by content id. Still design: `@patch`, `@remove`
and list-append semantics (§7), which M3 deliberately omits and which parse and are refused
until they exist. See §4.7 and the three Resolution sections at the end for what
implementation changed.
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
    name: []const u8,   // ASCII identifier, [a-z][a-z0-9_]*
    type: FieldType,
    presence: Presence = .required,
    since: u32 = 1,     // the schema version that introduced it
};

/// Whether a field has to be present, and what its absence means.
pub const Presence = union(enum) { required, optional, default: Value };
```

**`optional` and `default` are different things, and collapsing them is not available.** A
missing optional field reads as *absent*; a missing defaulted field reads as *the default*.
One `?Value` would make "this item drops nothing" and "this item's drop was never
specified" the same state, which is the sort of conflation that is free to avoid now and
impossible to unpick once content depends on it.

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
    pub fn get(self: *Registry, handle: SchemaHandle) ?*const Schema;
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
header      72 bytes
  0   magic            [4]u8   "FPKG"
  4   format_version   u32     bumped when this layout changes (I8)
  8   package_id       u64     ContentId hash of the package's namespace:name
  16  package_version  u32
  20  flags            u32     must be zero; an unknown flag is refused
  24  schema_count     u32
  28  record_count     u32
  32  section table    offset+length for each of the four sections below
  64  name             offset+length of the package's own namespace:name

schemas     schema_count entries of { id, version, name, declaration offset },
            then the field declarations they point at — every schema the package's
            records are laid out against, declared here or not
records     record_count entries of { content_id, schema_id, name, offset, length }
fields      the packed field data, laid out per each record's schema
strings     every string in the package, deduplicated; refs carry their own length
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
   outright replacement. Whether a mod *should be permitted* to add a field to another
   package's schema is still open, and is an M7 question: it is a policy about what a mod
   may do to content it does not own, not a mechanism.

   The second half of this — *what happens to records already laid out against the shorter
   version* — was closed by the store, because building one forced it. Each package carries
   the schemas its records use, at the version they were compiled against, and its records
   are read against that copy; a field a record's package predates reads as absent and is
   filled from the newer version's default, which is what §3 already promised. So the
   mechanism is safe whatever the policy turns out to be, and the policy can still be
   "no".
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

---

## Resolution: checking (implementation, 2026-09-04)

§4.7 records what writing the parser settled about the *format*. This records what writing
the checker — the step between the parser and the package writer — settled about the
*pipeline*. Same rule as before: written down rather than absorbed, because each of these
is visible either to a mod author or to the code that comes next. §3's `Field` sketch was
also corrected in place: it showed a `?Value` default where the registry has held a
`Presence` since the day it was written, and leaving the two disagreeing would have made
the document the less trustworthy of the pair.

**The parse tree carries a location for every field, and every location carries its source
line.** §4.5's own worked example is a schema type error with a caret under the offending
value, and the parse tree could not produce one: it held a location per *record*, and by
the time a record is checked the bytes it was parsed from belong to whoever answered the
`@import` and may be gone. So a record's fields now carry two locations each — one for the
name, one for the value, because "no such field" and "wrong type" are complaints about
different words — and a location carries the text of its line. The cost is one copy of each
source line that a diagnostic could ever point at, paid in the document's arena during
compilation; the parser remembers the last line it copied, which collapses the common case
of a field name and its value written together.

**The rules that decide a type and the walk that names it are different things.** §3 says
`checkValue` is the one place the typing rules live, and it still is: whether an integer
literal fits an `f32` is decided there and nowhere else. But `checkValue` can only say
*that* a value is the wrong type, never *which* value — so the recursive walk over lists
and inline structs lives in the checker, where the field names are, and calls `checkValue`
at the leaves. That is what turns "expects f32, found string" into "field `light.falloff`
of schema `foundry:item` expects f32, found string", and `grid[1][1]` for a list of lists.

**Defaults are filled at every level, and the one place a checked value is not positional
is an absent optional inside an inline struct.** A checked record's fields are an array
indexed by schema field index — resolved once, per §8 — and an inline struct's fields come
out in schema order with its own defaults filled. An optional the author left out is
*omitted* there rather than given a slot, because a `Value` has no way to spell absence and
inventing one would put a variant into every switch in the module to serve a handful of
names inside one value. The top level, where §8's hot path is, keeps its slots. Anything
walking an inline struct scans it, which is affordable for exactly the reason §3 gives for
inline structs existing at all.

**`@patch` and `@remove` parse, and are refused with a message that says why.** §7 defers
both to a later milestone; it did not say what happens to somebody who writes one now. They
still *parse*, because their syntax is frozen either way and freezing it early is the point,
and the checker then reports that the semantics do not exist yet. Silently dropping a mod's
patch would be the one genuinely bad answer: the mod would appear to load and would not
work.

**A type error names the schema but does not point at it.** §4.5's example carries a note —
"schema `foundry:item` declared at item.fdt:3:1" — and the checker does not emit one,
because the registry keeps no declaration sites. It cannot: a schema registered by native
code or, later, through the ABI has no file to point at, and a diagnostic that appears only
when the schema happened to be declared in a `.fdt` file would be worse than one that never
appears. Revisit if schema declarations ever grow a provenance table for the content
browser, which would make the note free.

---

## Resolution: `.fpk` (implementation, 2026-09-04)

§5 was a sketch of a file format, which is the kind of design that only becomes true when
something writes one. Nine things it left open, settled by `engine/src/data/fpk.zig`.

**Two encodings, for two different jobs.** Schemas are self-describing — a tag byte per
type, a tag byte per value — and are *decoded* at load, because they have to become
`Schema` values a registry can hold. Records are the opposite: laid out by their schema at
fixed offsets and never decoded at all. §5.3 argued for exactly this and the code makes the
split explicit, which is worth naming because the temptation on any future field type will
be to use the self-describing form for both.

**Every tag byte is spelled out, not taken from a Zig declaration order.** `bool` is 1,
`i32` is 2, and so on, in a table that exists only to be a table. This is the same rule
`core/id.zig` follows in specifying FNV-1a rather than calling `std`: a persisted format is
a compatibility contract, and reordering a union in an editor must not be able to change
what a byte in a shipped package means. Zero is never written, so a zeroed buffer fails.

**A record entry carries the record's name.** §5.1 had `{ content_id, schema_id, offset,
length }`. A `u64` cannot answer "why is this torch heavy?", which §8 promises is
answerable, and ADR-0005 asks that a hash always be traceable to the string it came from.
The entry is 32 bytes with the name ref in it, and the strings it points at are shared with
everything else in the package.

**Absence is a bitmap, one bit per field, at the head of every block** — a record's and an
inline struct's alike. §5.1 did not say how an absent optional was represented, and the
alternatives (a sentinel value, a separate list) are both worse: a sentinel steals a value
from the field's range, and a list turns a constant-time read into a search.

**Strings are `{ offset, length }` into a raw blob, not length-prefixed entries.** §5.1
said both, and they are redundant with each other. Dropping the prefix is what lets two
identical strings be one span — a test asserts that a string written four times appears in
the file once — and nothing ever needs to walk the section without a ref in hand.

**"Read in place" means explicit little-endian loads, not a cast over a mapped struct.**
Every value is read with a byte-order-explicit load at a computed offset, which compiles to
a plain load on every platform Foundry targets and stays correct on one it does not. Nothing
is copied and nothing is parsed, which is what §5.3 was actually asking for. Slots are still
aligned to their natural alignment even though the loads no longer require it, because that
is the cheap half of keeping a genuine zero-copy mapping possible later.

**UTF-8 is validated once over the whole strings section, and each ref is checked for
landing on a codepoint boundary.** §5.2's "every string is UTF-8-validated on the way in"
cannot be done exhaustively at open: a record's strings are only reachable through a schema,
and a package may reference schemas another package declares. One scan of the section plus
two byte tests per resolve is exactly equivalent — a slice of valid UTF-8 is valid UTF-8
precisely when neither end lands mid-codepoint — and it is O(1) per read rather than O(n).

**A package carries the schemas it declares, not the schemas it uses.** §5.1 said
"schema_count entries" without saying which. Carrying every schema a record *references*
would make a mod that adds items ship a second copy of `foundry:item`, and loading it would
then be refused by §3's rule against re-registering a schema at the same version. So
`check.Package` records what its documents declared, and `.fpk` carries that.

> **Reversed the next day**, by the store — see the resolution below. A package carries
> every schema its records use. The premise above was right about the registry rule and
> wrong about which rule should give way: the alternative was a record whose layout no file
> states, which is worse than a duplicated schema. The registry now accepts a re-declaration
> that agrees with what it holds.

**The reader trusts nothing, in two stages.** `open` validates the header, the sections, the
entry tables, every string in those tables and every record's field-block bounds, then
decodes the schemas under depth and count limits — believing a count only after finding the
bytes to hold it. Everything past that is checked at the point of use, because a block's
shape depends on a schema the file is under no obligation to agree with. Both halves are
tested by mutating a valid package one byte at a time: of four thousand mutations, roughly
five in eight still open, and every accessor on every one of them either reads a value or
returns an error. A byte-for-byte random file is refused outright.

**A package is at most four gigabytes**, because every offset in the format is a `u32`.
Recorded rather than argued: it is a bound worth knowing before something bumps into it, and
`format_version` is how it would be raised.

---

## Resolution: the store (implementation, 2026-09-04)

§6 to §8 described a merge, and a merge is the kind of design that looks finished until
something has to iterate the result. Six things `engine/src/data/store.zig` settled.

**The store reads compiled packages and nothing else.** Not a parse tree, not a checked
`check.Package` — `.fpk` bytes. §6 says the base game is package zero and loads through the
path a mod uses; the strongest available reading of that is that there is only one path to
keep working. A development build hot-reloading a `.fdt` file compiles it to bytes in memory
and comes back through the same call, which costs a buffer and removes an entire class of
"works for content, not for mods" bug.

**A package carries every schema its records use**, reversing what writing the writer had
concluded a day earlier. A record's block is laid out by field count and field types, so
reading a package with a schema that has since grown a field is not a stale read but a wrong
one — and if the schema lives in *another* package, nothing in the file says which version
the bytes were shaped like. So the file states it. The cost is a duplicated schema
declaration per package, measured in tens of bytes; what it buys is that a `.fpk` can be read
with nothing but itself, which is also what a tool inspecting one will want.

**Registering a schema twice is not a conflict, and the registry keeps the newest version.**
The rule that made carrying used schemas look impossible was §3's refusal to re-register a
schema at the same version. That refusal exists to stop two packages *disagreeing* about
what `foundry:item` is, and it was doing more than that. Three cases now: an identical
declaration is accepted and changes nothing; an older one is accepted if it is a prefix of
what is held, which additive-only versioning guarantees; a different declaration at the same
version is refused, as it always was.

**A record sits at the position where it was first defined.** §6 pins the two orderings the
merge depends on and §8 says iteration follows "the documented merge order", which leaves
one thing unsaid: where a record that two packages define ends up. It stays where the first
package put it, and a later package overriding it replaces the value behind the handle
without moving it. Same choice the registry makes for an extended schema, and the same
reason — everything already holding the handle follows (I1) — with the side benefit that
installing a mod does not renumber the records it did not touch.

**Loading a package is all or nothing.** Every fault a package can contain — a header that
does not parse, a schema that conflicts, a record naming a schema the package does not
carry, a field whose bytes disagree with the schema, one id defined twice inside one package,
an override that changes a record's schema — is found in a pass that merges nothing, and any
of them leaves the store exactly as it was. Half a mod's items is a worse outcome than none
of them and a message saying which file to remove. The one thing not unwound is schema
registration, and it does not need to be: the registry only ever gains additive definitions,
and nothing reads a schema no record uses.

**Iteration by schema is a filtered linear pass.** §8 asks for "every record of one schema"
and does not ask how fast. Content iteration happens at load and in tools, not in a frame:
a system reading content in a loop holds handles it resolved once, which is the mitigation
ADR-0005 named. An index per schema would be another structure to keep correct across every
override, bought for nobody. Revisit when something iterates content per frame — and ask
first why it is doing that.

**What §8 asked for and did not get:** `Store.get` returns a record whose fields are read
through the schema its package carries, not a `Record` with typed accessors of its own, and
resolving a record's `id` fields to handles at load is the *caller's* job rather than a pass
the store runs. A `.fpk` is read in place and cannot be rewritten, so pre-resolution would
mean a side table per record per field, built for consumers that do not exist yet. `find`
makes "resolve once, then use handles" available to anything that wants it; M4 is where
something will.
