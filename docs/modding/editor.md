# The Foundry editor

**Status:** works as of M15, 2026-09-21, on macOS/Metal and Windows/Vulkan. It is a separate
application, not part of a game, and it authors content packages: the manifest, the records,
their fields, and the compiled `.fpk` a player installs. Everything it does it does through
`FoundryApi_v4` — the same forty-seven calls [`authoring.md`](authoring.md) documents, and no
others. There is no private path (Invariant I4, [ADR-0042](../adr/0042-authoring-through-the-public-api.md)).

This page is for someone using the editor. If you are writing a program that authors content,
read [`authoring.md`](authoring.md) instead; if you are writing `.fdt` by hand, read
[`content-mods.md`](content-mods.md), which is still a supported way to work and always will
be — the editor edits the same files and leaves the parts it did not touch alone.

---

## What it is, and what it is not

It **is** a content-record editor. You can make a package where there was nothing, declare
what it depends on, copy a definition out of a package you depend on and change it, edit
every field kind the format has, undo and redo, save per file, compile, load the result and
hand the compiled package to a directory.

It is **not** a level editor, a tile painter, a script editor, an asset importer or a text
editor. There is no scene viewport and no gizmo. Those are named in
[`../design/editor.md`](../design/editor.md) §1 as postponed, not forgotten.

## Running it

```sh
zig build editor -- --source <package-dir> --output <work-dir> \
    [--dependency <file.fpk>]... \
    [--export <file.fpk> [--export-assets <dir>]] \
    [--preview]
```

Every directory the editor can read or write is named on that command line. It opens nothing
else, and the client that draws the window cannot name a path at all: it is handed
destinations by number. The grants are:

| Argument | What it grants |
| --- | --- |
| `--source <dir>` | the package's source. Read, edited and saved. May be empty — that is where New Package starts. |
| `--output <dir>` | a private directory for builds. Must be outside every source and dependency root. |
| `--dependency <file.fpk>` | a compiled package to author against, repeatable and **ordered**. Its schemas register before yours; its records can be overridden. |
| `--export <file.fpk>` | where the Export button writes the compiled package. |
| `--export-assets <dir>` | where Export writes the assets the compiler produced. Only needed by a package that generates any. |
| `--preview` | build and load once at start-up, so the Preview tab has something in it. |

`--output` is not a place your package ends up. A build goes into a private candidate
directory there and stays there; **Export** is what hands you a file, and it writes only
where `--export` said.

## A whole mod, start to finish

This is the worked example the milestone's exit was proved with: a package that re-skins the
`room` sample by overriding its UI theme. Nothing about it is special to the sample.

```sh
mkdir -p ~/work/warm-room ~/work/build ~/work/out
zig build editor -- \
    --source ~/work/warm-room \
    --output ~/work/build \
    --dependency "<room>/Contents/Resources/content/core.fpk" \
    --dependency "<room>/Contents/Resources/content/room.fpk" \
    --export ~/work/out/warm-room.fpk
```

1. **New Package.** Fill in the id (`demo:warmroom`), the name, the version and the licence,
   and press Create. That writes `mod.fdt` with a `foundry:mod` record and the three fields
   the schema requires, and leaves it selected.
2. **Say what it depends on.** In the details panel, open `requires`, press Add to start the
   list, Add again to append an entry, open the entry and set `id` to `room:content`. A
   package that overrides another's record must declare it, or nothing guarantees it loads
   afterwards — load order is computed from these declarations, never from file names
   ([ADR-0040](../adr/0040-ordered-profiles-applied-at-next-start.md)).
3. **New Document**, `theme.fdt`. A record has to live in a file, and putting it beside the
   manifest is a choice, not a rule.
4. **Dependencies tab.** Choose the package (only the chosen one's records are listed), type
   into the filter, select `room:ui.theme`, and press **Override Here**. The whole record is
   copied into the document you have selected, exactly as it is stored.
5. **Change what you came to change.** Set `text_scale` and `line_height`. A value the schema
   refuses leaves the file *and* what you typed alone and says why in the message log, so you
   correct it where you typed it.
6. **Save All**, then **Validate**, then **Build**, then **Export**. Build compiles the
   *saved* bytes and is refused while anything is unsaved — the button is disabled and says
   so rather than compiling something you cannot see.
7. **Reload** loads the build into the editor's own runtime, and the Preview tab reads what
   was actually loaded, not what you wrote.

Then install it the way any content mod is installed
([`content-mods.md`](content-mods.md)): copy `warm-room.fpk` into the game's user `mods/`
directory, enable it on the game's mod screen, apply, and restart.

## What an override copies

**Exactly what is stored, at full precision.** A `u64` that no `double` could carry comes
across intact. An optional field the upstream package left unset stays unset.

Two things are worth expecting the first time:

* **Spelling is canonical, not the upstream author's.** A dependency is a compiled `.fpk`,
  which holds values and not the text someone typed, so `0xffbe6eff` is written back as
  `4290670335`. It is the same number.
* **Defaults become explicit.** A compiled record has every field resolved, so a field the
  upstream source omitted and let default appears in your copy with the default written out.
  That is what makes the override independent: it restates the record, and a later upstream
  change to that default will not reach through it.

An override restates a whole record. It is not a patch, and Foundry has no `@patch` yet.

## Saving, building and the message log

**Save** writes the selected document; **Save All** writes every dirty one, in a stable
order, stopping at the first failure — files already written stay written and the rest stay
dirty. It is a prefix, never a transaction, and the log says which files it published.

**Validate** compiles your drafts and keeps nothing. The diagnostics are the answer; use it
while you are still editing.

**Build** compiles the saved bytes into a private candidate. **Export** writes that candidate
to the destination `--export` named. **Reload** asks the application to load the build, and
the Preview tab then shows the loaded records. A preview holds its build; the editor will not
release a build the loaded content is reading from.

A file changed underneath you is marked `!` in the outliner, an unsaved one `*`. Both offer
their own action — Refresh adopts the bytes on disk, Discard throws your draft away — and
both ask first. So does closing the window with unsaved work.

## Keyboard

`Cmd` on macOS, `Ctrl` elsewhere:

| Shortcut | Action |
| --- | --- |
| `S` / `Shift-S` | Save / Save All |
| `Z` / `Shift-Z`, `Y` | Undo / Redo |
| `R` | Validate |
| `B` | Build |
| `W` | Close (asks about unsaved work) |

These are the *application's* keyboard, not a Foundry capability. The public table publishes
no key state, so a client — this one or anyone's — cannot bind a shortcut for itself; the
host reads its own keyboard and asks the client for the action. Whether the table should
publish key state is an open question ([`../design/editor.md`](../design/editor.md) §13).

## Replaying a session

The editor can replay input instead of reading a mouse, which is how it is tested and how the
milestone's proofs were run:

```sh
zig build editor -- --source … --output … --script          # a generic walk; changes nothing
zig build editor -- --source … --output … --plan plan.txt   # your own actions
```

A plan is one action per line. `#` starts a comment and a blank line is nothing:

```
# The first frame has drawn nothing yet, so there is nothing to aim at.
idle
click new_package
enter form_field_0 demo:warmroom
enter form_field_1 Warm Room
click form_create
idle
click field:6          # the seventh row of the details panel
key backspace
```

* `click <target>[:<row>]` — hover, press, release, at the rectangle the editor drew for that
  control. A control this frame did not draw is skipped, never clicked blind.
* `enter <target>[:<row>] <text>` — click it, run the caret to the end, clear it and type.
  A control keeps what was last in it, so a plan that only typed would be appending.
* `write <text>`, `key <name>`, `idle` — the pieces, for when you want them separately.

The row number picks among the details panel's rows, counted from the top as the schema
declares them; it also picks among the granted packages for `dependency_package`. The target
names are the controls: `new_package`, `new_record`, `new_document`, `save`, `save_all`,
`validate`, `build`, `reload`, `export_package`, `undo`, `redo`, `form_create`, `form_cancel`,
`form_field_0`–`3`, `first_schema`, `filter`, `tab_source`, `tab_dependencies`, `tab_preview`,
`tab_schemas`, `tab_assets`, `first_document`, `first_record`, `field`, `field_apply`,
`field_reset`, `list_add`, `list_element`, `list_remove`, `list_up`, `list_down`, `boolean`,
`record_delete`, `record_duplicate`, `dependency_package`, `dependency_override`,
`first_dependency_record`, `confirm_save`, `confirm_discard`, `confirm_cancel`,
`document_refresh`, `document_discard`.

Nothing in the editor knows a schema, a record or a field by name. A plan that names yours is
your file, kept beside the package it describes.

## Limits, said plainly

* **One workspace at a time**, and its roots come from the command line. There is no file
  picker and no recent-files list.
* **No raw text editing.** If you want to write `.fdt` by hand, write it by hand; the editor
  will read it back and preserve every byte it does not change.
* **No asset import or conversion.** Assets are files in your package; the compiler derives
  what it derives ([ADR-0021](../adr/0021-asset-identity.md)).
* **No schema editing.** You can use schemas the engine declares, schemas a dependency
  declares and schemas your own package declares in text; there is no visual editor for them.
* **Depth and size are bounded.** The details panel lays out three levels of nesting and a
  bounded number of rows; a workspace has limits on documents, history and builds, and
  `author_workspace_limits` publishes every one of them.
* **macOS and Windows are run; Linux is only built.** The editor has been driven end to end
  on macOS/Metal and on Windows/Vulkan, and the files it saves and the package it exports are
  byte-identical between them — the evidence is in
  [`../design/editor.md`](../design/editor.md)'s Step 8 Resolution. Linux builds in every
  graph and has never been run; runtime support for it is M18
  ([ADR-0039](../adr/0039-linux-after-the-first-game.md)).
* **Nobody has used it with their hands for a whole package.** Every workflow proof so far
  replayed a recorded action plan into the real widgets rather than a person moving a mouse.
  The controls are real and so is the input path; what is untested is whether a newcomer
  finds them.

## Where to go next

* [`content-mods.md`](content-mods.md) — the `.fdt` format, package layout and installing a mod.
* [`authoring.md`](authoring.md) — the calls under all of this, for a program of your own.
* [`../design/editor.md`](../design/editor.md) — why it is shaped this way, and what is left.
