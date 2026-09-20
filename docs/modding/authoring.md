# Authoring content through the public API

**Status:** the authoring surface is published as `FoundryApi_v4` as of M15 step 5,
2026-09-20. The calls work, the header compiles as C99 and C++17, and `fpack` runs on them.
Foundry's own editor was built on them in step 7 and uses these calls and no others — it has
forms, commands, undo, saves, builds, export and preview, and it reaches the engine exactly
the way this page describes. Step 8 added a second client to keep that honest: a C99 library
that authors a package start to finish
([`engine/tests/fixtures/author_mod.c`](../../engine/tests/fixtures/author_mod.c)). This page
is for a program that wants to do the same thing itself; if you want to *use* the editor, read
[`editor.md`](editor.md).

Everything here goes through the one public table (Invariant I4,
[ADR-0042](../adr/0042-authoring-through-the-public-api.md)). The editor Foundry ships will
use exactly these forty-seven calls and no others, which is why they exist before it does: a
capability the editor needed and this table lacked would otherwise have become a shortcut.

---

## What you get, and what you are given

A **workspace** is one directory a host decided to grant you. You do not open it, and you
cannot name a path anywhere in this API — `author_workspace_next` enumerates what the
application already granted, and that is the whole of your reach into the filesystem.

```c
FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
FoundryWorkspace workspace;
if (api->author_workspace_next(&cursor, &workspace) != FOUNDRY_OK) return;  /* none granted */

FoundryAuthorWorkspaceInfo info;
api->author_workspace_info(workspace, &info);
```

`info` tells you the package's name and version from its `mod.fdt`, how many documents and
dependencies it has, whether anything is dirty, whether undo or redo would do something —
and, separately, what you are *allowed* to do: `can_edit`, `can_save`, `can_build`,
`can_preview`. A host may grant any subset. A read-only workspace answers every read and
refuses every command with `FOUNDRY_ERR_REFUSED`; that is the normal shape for a tool that
inspects a package.

`package_name` is empty when the directory has no readable manifest. That is a **state**,
not a failure: it is where a new package starts.

## Revisions

Every command carries the revision you believe you are editing:

```c
uint64_t revision;
api->author_workspace_revision(workspace, &revision);
```

A command whose revision does not match is `FOUNDRY_ERR_REFUSED` and changes nothing. That
is what stops a command built from a form the user has since changed from applying to
something that merely looks similar. Every successful command, save, refresh and discard
moves the revision, and hands the new one back in its result.

## Reading a record

Documents, records and their fields are all walked the same way:

```c
FoundryDocument document;
FoundrySourceNode record;
FoundryAuthorNodeInfo node;

cursor = FOUNDRY_CURSOR_BEGIN;
api->author_document_next(workspace, &cursor, &document);

cursor = FOUNDRY_CURSOR_BEGIN;
while (api->author_record_next(document, &cursor, &record) == FOUNDRY_OK) {
    api->author_node_info(record, &node);   /* node.name is the record's spelling */
}
```

A **node** is a record, one of its fields, a field of a nested block, or an element of a
list. `author_node_child` walks by position, `author_node_field` by name, and
`author_node_info` describes whichever you have:

* `field_type` is the declared `FoundryFieldType`.
* `child_count` is a nested block's fields or a list's elements. A nested block's count comes
  from its **schema**, so an optional block nobody has written still describes the fields it
  would have.
* `authored` says whether the source actually writes this node.
* `presence` says what the schema declares — required, optional, defaulted, or
  `FOUNDRY_AUTHOR_ELEMENT` for a list element, which has no declaration of its own.

Those last two are separate answers on purpose. A defaulted field that nobody wrote is
neither "missing" nor "set to the default", and a form that could not tell them apart would
write defaults into files nobody asked it to.

### Values are text

```c
FoundryAuthorValue value;
api->author_node_scalar(field, &value);
```

`value.text` is the canonical decimal spelling of a number, the bytes of a string, or the
`namespace:name` of an id; `value.boolean` carries a boolean; `value.id` carries an id's
hash even when no spelling could be recovered for it. A container answers
`FOUNDRY_ERR_UNSUPPORTED` — `author_node_info` already describes it.

**Numbers are text here and nowhere else in this API.** `record_get_f32` still reads a float,
because that is what a sprite's position is. An author typing `9007199254740993` into a
`u64` field is not describing a sprite, and a boundary that sent it through a float would
change it silently. What you read back is byte-for-byte what a save would write, so a value
that goes through your form and back is the same value.

### Borrows expire, and sooner than you think

Every string this API hands back is borrowed. Three rules, in increasing order of how likely
they are to catch you:

1. A formatted number lives until the **next** `author_node_scalar` call.
2. A name or a string lives until four more records have been read.
3. **Every node handle dies at the next accepted command**, even one that touched nothing
   near it, because a command replaces the parse the node was a position in.

Copy what you keep. `author_node_copy_text` and `author_document_copy_source` take your
buffer and a capacity, write the needed length into `*needed`, and answer
`FOUNDRY_ERR_LIMIT` rather than truncating.

## The schema tree

You cannot write a record without naming a schema, and a registry holds hashes rather than
words, so the words are published:

```c
FoundrySchemaNode schema;
cursor = FOUNDRY_CURSOR_BEGIN;
while (api->author_schema_next(workspace, &cursor, &schema) == FOUNDRY_OK) {
    FoundryAuthorSchemaNodeInfo s;
    api->author_schema_node_info(schema, &s);   /* s.name is what goes in the file */
}
```

The set is the engine's own schemas, every granted dependency's, and every one this package
declares. `author_schema_node_child` descends into a nested field, and into a list's single
child, which is its **element type**. `author_schema_node_default` hands back a declared
default as a value you can walk with the ordinary node calls.

Schemas are inspected, never edited. M15 has no schema designer.

## Editing

```c
FoundryAuthorValue set;
FoundryAuthorEdit edit;
memset(&set, 0, sizeof set);
set.field_type = FOUNDRY_FIELD_U64;
set.text = /* FoundryStr over "11" */;

if (api->author_value_set(field, revision, &set, &edit) == FOUNDRY_OK) {
    revision = edit.revision;
    /* edit.selection is a fresh node handle for where the change landed. */
}
```

`edit.selection` is the one node handle that survives the command — the service re-resolves
it against the new revision, which is what lets a form keep its cursor. Everything else you
were holding is stale.

An empty container is said as a value: `FOUNDRY_FIELD_NESTED` or `FOUNDRY_FIELD_LIST` with
empty text is how "add the optional block" and "start a list" are written.

`author_record_override` copies a whole dependency definition into one of your documents,
exactly — every stored field, at full precision, including absent optionals. It does **not**
merge fields a later version of the upstream package adds; tell your user so.

Undo and redo restore exact source bytes, and a new edit after an undo clears the redo
stack. When the history budget is reached the oldest complete commands are evicted and
`history_truncated` says so; a single command larger than the budget is refused rather than
quietly made non-undoable.

## Saving

```c
FoundryAuthorSaveResult saved;
api->author_save_document(document, revision, &saved);
```

`outcome` distinguishes *published* from *unchanged*: saving bytes that already match the
file writes nothing and says so. `durable` is a separate answer, and a false one is not a
failure — it means the bytes are in place and readable but the directory entry naming them
was not confirmed flushed, which is the ordinary result on some systems.

`author_save_all` processes dirty files in stable relative-name order and **stops at the
first failure**. Files already published stay published, the rest stay dirty, and `complete`
is false. It is a prefix, never a transaction; `author_save_entry_next` walks what actually
happened, file by file. A workspace holds a cooperating-writer lock while it saves, and a
busy lock is refused rather than broken — unrelated writers do not honour it, so an edit
racing in after the comparison is not prevented.

If the file on disk has changed under you, `externally_changed` is set and **both** versions
are kept. `author_document_discard` restores your last saved baseline, and then
`author_document_refresh` adopts the disk bytes. There is no "overwrite anyway".

## Building, exporting, previewing

```c
FoundryBuild build;
api->author_build(workspace, revision, &build);
```

A build compiles the **saved** bytes, into a private candidate directory the host granted,
and is refused while any document is dirty or has changed on disk. It is the same compiler
`fpack` runs, on the same snapshot, with the same dependency reading — the same saved bytes
and options give the same `.fpk` either way.

A successful build stays alive until you release it. Two are live at a time by default;
`author_workspace_limits` tells you that number and every other bound this workspace was
configured with, so a `FOUNDRY_ERR_LIMIT` can be explained rather than guessed at.

Export writes a build somewhere the **host** configured:

```c
FoundryAuthorExportInfo destination;
cursor = FOUNDRY_CURSOR_BEGIN;
while (api->author_export_next(workspace, &cursor, &destination) == FOUNDRY_OK) {
    uint32_t written;
    api->author_build_export(build, destination.index, &written);
}
```

You name a destination by number. There is no path parameter, and there will not be one:
files are replaced individually and `written` says how many were, so a partial publication
is reported rather than implied.

`author_preview_activate` asks the host to make a build the loaded content. Where the host
granted no preview it answers `FOUNDRY_ERR_UNAVAILABLE`, and editing, saving and building
all still work without it. Where it declined, whatever was loaded before is still loaded,
and `author_preview_info` says so. An active preview holds its build; releasing that build
is refused, because releasing deletes the files the loaded content is reading.
`author_preview_record_next` reads what was actually loaded, through the same node calls as
a draft.

## Diagnostics

Every operation leaves a snapshot behind, readable until the next one replaces it:

```c
api->author_validate(workspace, revision);   /* compiles the drafts, keeps nothing */

FoundryAuthorDiagnostic d;
cursor = FOUNDRY_CURSOR_BEGIN;
while (api->author_diagnostic_next(workspace, &cursor, &d) == FOUNDRY_OK) {
    /* d.file, d.line, d.column, d.message, d.source_line, and a note where there is one */
}
```

Nothing here requires scraping a log. `d.suppressed` is how many entries that operation did
not record because its cap was reached; it describes the snapshot, so it is the same number
on every entry.

## What the result codes mean

| Code | When |
| --- | --- |
| `FOUNDRY_ERR_UNAVAILABLE` | The host supplied no authoring service, or no preview grant. |
| `FOUNDRY_ERR_REFUSED` | Permitted in general, not now: no grant, a stale revision, a busy lock, a dirty source for a build, a build a preview is holding. |
| `FOUNDRY_ERR_INVALID_ARGUMENT` | Something you sent: a value the schema does not accept, a name that is not a package-relative `.fdt`, a path that names no node. |
| `FOUNDRY_ERR_INVALID_HANDLE` | Stale or never issued — most often a node handle from before a command. |
| `FOUNDRY_ERR_ALREADY_EXISTS` | A record id or a document name this package already has. |
| `FOUNDRY_ERR_NOT_FOUND` | Well-formed, and the answer is no: no such field, no default, nothing to undo. |
| `FOUNDRY_ERR_UNSUPPORTED` | A scalar read of a container, or a destination number the host did not configure. |
| `FOUNDRY_ERR_LIMIT` | A configured bound, or a buffer too small. |

## Limits

`author_workspace_limits` reports what this workspace was actually configured with. The
shipped defaults are one open workspace, 1,024 source files, 16 MiB per file and 64 MiB in
total, a 256 MiB editing budget, 128 undo commands and 64 MiB of retained history, 512 MiB
of snapshot input per build and two live builds. A host may configure tighter ones, and
exceeding any of them refuses without a partial change.

## What this is not

* **Not a second engine API.** `abi` creates no workspace; a host grants one or authoring is
  unavailable.
* **Not a filesystem.** Every path is the host's. New documents are package-relative `.fdt`
  names in directories that already exist.
* **Not a sandbox.** Opening a package whose manifest names a script or a native library
  lets you inspect it; its code is inert here. That is not a security boundary.
* **Not schema authoring, asset conversion, global rename, background compilation or
  autosave.** Those are recorded limits, not promised milestones
  ([editor.md](../design/editor.md) §13).
* **Not a keyboard.** The table reports `ui_wants_keyboard` and no key state, so a client
  cannot bind its own shortcuts; an application that wants them reads its own keyboard and
  decides what to call. Publishing key state is open.

## Where to go next

* [`../design/editor.md`](../design/editor.md) — the authoring design, the workspace's
  authority, §9's binding contract for this surface, and the Step 7 Resolution's account of
  what a complete form over it looks like.
* [`../design/public-abi.md`](../design/public-abi.md) — the boundary's rules: handles,
  cursors, borrows, result codes.
* [`editor.md`](editor.md) — Foundry's own editor, for someone using it rather than writing one.
* [`native-mods.md`](native-mods.md) — building against the installed `foundry.h`. A manifest
  that asks for this table declares `abi { min 4 }`; this build offers 1 through 4.
* [`content-mods.md`](content-mods.md) — the `.fdt` format these calls read and write.
