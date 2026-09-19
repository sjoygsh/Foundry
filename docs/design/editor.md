# Content authoring and the standalone editor

**Milestone:** M15 — Editor: “content is authored in Foundry”
**Status:** Designed 2026-09-19. The owner accepted it on 2026-09-20, adding that the editor's
UI and UX follow Unreal Engine 5's (§10). Steps 1–3 are implemented (2026-09-20); Steps 4–9
are not started.
**Decisions:** accepted [ADR-0042](../adr/0042-authoring-through-the-public-api.md) and
[ADR-0043](../adr/0043-source-preserving-authoring-and-explicit-builds.md).
**Built on:** ADR-0004/0006/0011/0017/0020/0025/0026/0041; `content-schemas.md`,
`public-abi.md`, `debug-overlay.md`, `mod-management.md` and `distribution.md`.

## 1. The result and its boundary

A separate Foundry application opens or creates a source package, browses its schemas and
records, edits records through typed forms, saves `.fdt`, builds an ordinary `.fpk` and asset
tree, and reloads that result. A person completes the exit without typing `.fdt` syntax.
Every authoring and inspection operation used by its client is a public-table operation.

M15 is a **content-record editor**, not a level editor or a general game runtime. It uses
Foundry's existing UI, renderer, schemas, package compiler and loading path. A new package can
use engine schemas or schemas supplied by read-only dependency packages. Existing package-local
schema declarations are loaded and preserved. Visual schema-definition editing is outside
this first editor; no game schema or gameplay knowledge is built into the engine.

Required now: manifest creation, file/record browsing, create/duplicate/delete record,
whole-record override creation, all existing field kinds, undo/redo, diagnostics, conflict-safe
saves, build, reload and a real external-package proof. Design for later: more consumers of
the public authoring service. Postpone: scene gizmos, tile painting, raw text/code editing,
asset painting/import conversion, docking, project generators and plugin execution.

M0–M14's completed results remain the baseline. Steps 1–3 have implemented the source model,
bounded workspaces and typed in-memory commands; the save/build, ABI and application surfaces
specified below remain future implementation.

## 2. What the current code supplies

| Existing implementation | Reuse and missing piece |
| --- | --- |
| `data/parser.zig`, `lexer.zig`, `check.zig` | Grammar, exact values, imports and diagnostics; lexer tokens have byte ranges, semantic declarations need complete editable ranges. |
| `data/schema.zig`, `value.zig`, `fpk.zig` | Runtime-populated schemas, typed validation and serialization; no source-preserving writer. |
| `tools/fpack/pack.zig` | One ordered compilation pipeline, derivation and grid compilation; currently tool-local and writes generated assets during compilation. |
| `platform/os.zig` | Confined bounded reads and atomic single-file replacement; no claim of atomic multi-file save. |
| `abi/calls_content.zig`, v1–v3 | Read-only runtime records/schemas/packages; incomplete authoring metadata and no source mutation/save/build surface. |
| `debug/content_panel.zig`, other panels | Proven introspection and visible-row presentation; currently receive internal snapshots, so the editor needs public-call adapters. |
| `samples/room/mods_screen.zig` | A working table-driven screen with mutations after UI description, plus M14 themes and controls. |
| `app/engine.zig` | Candidate package loading, content generation and reload; no authoring workspace or editor preview policy. |

Do not rebuild these mechanisms. In particular, runtime getters narrow floats to `f32` and
cannot reconstruct authored values, omitted fields or source comments. They serve the loaded
browser, not the source serializer. Since Step 2, `fpack` and workspaces share `author`'s one
compiler and explicit dependency-package inputs; Step 3 reads dependency values through the
full-precision package reader.

## 3. Ownership and layering

The addition, preserving the established graph:

```
data (L1)       core; optional source ranges and deterministic literal emission
author (L4)     core, data, platform, asset, mod, scene; compiler and workspace
abi (L5)        existing dependencies + author; validation and translation only
editor host    constructs subsystems, grants roots, drives the loop and preview loading
editor client  public C declarations (+ core/std utilities); consumes FoundryApi_v4
```

`app` does not import `author`. `author` does not import `app`, UI, renderer or ABI. `scene`
is a compiler dependency only for its existing built-in schemas. `abi` still has no RHI.
The client must be a separate build module with no implementation imports; importing the
entire Zig `abi` module for convenient types is not the proof. Follow `script`'s header-consumer
boundary. Add a negative build probe that proves an implementation import fails.

`tools/editor/main.zig` is the host. It receives roots through explicit arguments, owns
subsystem lifetimes and hands the client a queried table. `tools/editor/client/` contains
forms and panel state. The host's only client-facing capability object is the public table;
no editor-specific service pointer or “temporary” compiler callback crosses beside it.
Client code must also contain no direct filesystem, process-launch or dynamic-library calls
through `std`; the separate module's import restriction does not by itself prohibit those.
Step 6's boundary check covers both the build imports and these escape routes.

The host never asks the client to supply an `Engine`, `Store`, filesystem object or renderer
pointer. Ordinary input and screen metrics come through existing calls. Private bootstrapping
is allowed on the same terms as a sample host: it assembles capabilities, not authoring policy.

## 4. Workspace authority, inputs and lifetime

An `author.Service` owns generational workspaces; a workspace owns source documents, schemas,
history and successful build objects. Host configuration supplies:

- one existing source directory, writable only when explicitly granted;
- an ordered, read-only set of dependency `.fpk` files and their asset roots;
- a separate writable output directory, outside every source/dependency root;
- concrete memory, file, history and build limits;
- a separate host callback for activating a successful build, if preview is available.

Grants distinguish document editing/saving, build/output writes and preview activation. A CLI
compiler needs build/export authority, not source-write authority. An empty granted source
directory is a valid workspace for New Package; compilation still requires a valid manifest.

The initial editor handles one workspace at a time. CLI roots are a sufficient initial open
workflow; a native file picker is not required. The application validates roots before binding
the service. The public client enumerates granted workspaces and files; it never opens an
arbitrary host path. New document names are validated root-relative `.fdt` paths; M15 only
creates files in existing directories. The package manifest is always `mod.fdt`.

Source/dependency reads, imports, asset copying, output creation and saving must keep the
confined/no-follow policy, including intermediate links and Windows path rules. Reject source
and output aliasing. Do not mount ambient user mods as editor dependencies. Dependencies are
explicit data inputs, resolved in a deterministic order under existing `mod` rules. Missing
or incompatible declared dependencies are diagnostics, not silently supplied packages.

No workspace operation loads a DLL or executes Lua. Opening a package with script/native
metadata permits inspection; its code is inert. This is not a native-code sandbox. Hosts with
no service return `Unavailable`; a read-only service returns `Refused` on mutation/save/build.
Do not add per-caller policy to the shared table, native consent fields, or Lua bindings.

Initial default limits, enforced cumulatively as well as per object:

| Resource | Limit |
| --- | --- |
| Open workspaces / source files per workspace | 1 / 1,024 |
| One source file / all source bytes | 16 MiB / 64 MiB |
| Documents' parsed/editing allocations | 256 MiB budget |
| Nesting, fields, list lengths, identifier lengths | existing `data.Limits` |
| Diagnostic entries per operation | 64, with truncation explicitly reported |
| Undo commands / retained undo bytes | 128 / 64 MiB |
| Snapshot input bytes including assets | 512 MiB, streamed file copies allowed |
| Live successful builds | 2; an active preview holds a reference |

Hosts may configure tighter bounds; exceeding one refuses without partial mutation. Do not
silently raise a limit in the editor. Report configured values through workspace info. Budgets
must cover candidate edits as well as committed state; an OOM leaves the previous state valid.

## 5. Source documents and edits

A document owns its current bytes and its disk baseline. A workspace revision changes after
any successful edit, undo, redo, save-baseline change or disk refresh. Each command carries the
expected revision. Reads return borrowed spans with the existing ABI borrow rule; clients copy
anything kept across callbacks/frames. On mutation, reacquire node handles and cursors. All
old nodes become stale even if their source offsets happen to remain the same.

Extend the existing parser with opt-in, per-source byte ranges for records, fields and values,
including nested/list children and insertion positions. Imports keep their source identity:
editing an imported record edits its actual file, once, not an expanded copy. Key source files
by confined relative names and deterministic traversal; follow `fpack`'s import semantics.
Do not infer byte spans from line/column diagnostic text or write a second grammar walker.

An edit builds candidate bytes, parses them and checks the affected value against its schema
before committing the new revision. Preserve all bytes outside the named construct. Emit new
syntax deterministically using the file's newline style, four-space indentation for new
blocks and fully qualified IDs. Escape strings using precisely the parser's supported escapes.
Integer output is exact decimal; floats must round-trip at their declared width, retain signed
zero and contain a decimal point or exponent. NaN/infinity are refused. ID spelling is retained
and collision-checked; a numeric hash with no recoverable spelling cannot be emitted as an ID.

Supported operations:

- create a record from an available schema, with explicit stable ID;
- duplicate a source record under a new ID;
- create a whole-record override of a read-only dependency definition in a writable file;
- delete a local definition (revealing an earlier definition if one exists);
- set/unset a field, add/remove an optional nested value, and insert/delete/move list items;
- set a scalar through a typed value control, with explicit presence/default information.

Whole-record overrides copy exact stored values through `author`'s data readers, including
`u64`, `f64`, nested/list values and authored presence. Existing runtime readers are not used
as a lossy bridge. The UI warns that future upstream fields are not automatically merged.
There is no `@patch` or `@remove`, global ID rename or automatic reference rewrite.

A missing required value can remain an incomplete draft and is visible as such; Build refuses
it. Invalid textual numeric input stays in the form's edit buffer until it can form a valid
command. An externally malformed document remains byte-preserved and diagnostic/read-only;
the editor does not offer a raw-text repair tool in M15. Other valid documents remain usable.

The manifest creation form emits an ordinary version-2 `foundry:mod` record using existing
defaults and required metadata, including licence and dependency fields. There is no separate
project identity file. It must not silently grant native consent or invent an ABI requirement
for a content-only package. Existing manifests are edited by the same schema mechanism.

Schema declarations are inspected, not changed. This retains local and dependency schemas
without requiring a schema designer to meet the milestone. The engine owns no game templates.

## 6. Undo, redo and dirty state

One accepted UI action is one command; a completed text edit is not one command per character.
The service, not the editor UI, owns bounded before/after byte changes and selection locators.
Every command is atomic in memory. Undo/redo restores exact source bytes and advances revisions;
a stale command never applies to a similar-looking new record. New edits after Undo clear Redo.

Dirty state compares current bytes with the last saved baseline, not an undo-stack index.
Saving does not destroy Undo; undoing a saved change makes the document dirty again. When the
history budget is reached, evict the oldest complete commands with visible history truncation.
A single command larger than the budget is refused, not silently made non-undoable. Discarding
a dirty document requires a deliberate UI action; close offers Save, Discard or Cancel in a
normal in-window confirmation region, needing no new popup layer.

## 7. Saving and external changes

Save takes one document and an expected revision. New-file creation must use confined atomic
publication of a completely written temporary file with create-if-absent semantics, not an
overwriting rename or an exposed partially written destination; implement that platform
primitive if needed. Existing files go through `Os.replaceFileConfined`. A successful save updates the
baseline only after publication; a failed write keeps the dirty bytes and previous baseline.
An `entry_unflushed` durability result means replacement succeeded with weaker crash durability,
not “failed, retry” and not guaranteed persistence after power loss.

Use a workspace-scoped exclusive lock for cooperating save operations, held through re-read,
comparison and replacement. Refuse a busy lock. On crash, do not automatically delete another
session's lock or guess from its timestamp; report recovery instructions. Lock creation and
cleanup use confined primitives and delete only the token this operation owns. This is separate
from M14's preferences merge policy: authoring never merges a changed source file implicitly.

If the disk differs from baseline, preserve both the draft and disk. The editor offers refresh
after explicit discard, or saving a copy under a fresh name. No “overwrite anyway” in M15.
Unrelated writers do not honour the lock, so an edit racing after the comparison is not
prevented; state that limit in the author guide. Modification time alone is not equality.

Save All processes files in stable relative-name order and reports each committed file and the
first failure. It stops there, leaves the rest dirty, and never claims package-wide atomicity.
The Build button remains disabled while any source is dirty or externally changed.

## 8. Validation and package compilation

Extract `pack.compile` and its helpers into `author` first, retaining its four passes, manifest
pre-pass, bounds, derivation rules and exact ordering. Existing CLI invocations and output
remain compatible. Add explicit dependency schema inputs shared by the service and CLI;
`fpack --dependency <file.fpk>` is repeatable and its order is documented. Load only validated
package bytes; no schema comes from executing its owner's code.

Validation returns bounded structured diagnostics with severity, relative source name, line,
column, record/schema/field identity where known and message. Diagnostic snapshots carry an
operation revision and remain readable until the next operation replaces them. Do not require
the editor to scrape log text. Local type checking and package-wide checks use the same `data`
and `mod` mechanisms as compilation/loading; never upgrade all `id` fields into hard references
where existing semantics do not impose that rule.

Build captures a stable saved snapshot: source list, contents, dependency bytes and assets.
Bound everything before allocation/copy; recheck the original input inventory/bytes at the
end of capture and refuse changes during capture. Compile only the captured inputs so later
source changes cannot mix generations. That is snapshot consistency, not a claim to an OS-wide
transaction against a hostile concurrent writer.

Build into a fresh exclusively created candidate directory. Copy required ordinary assets and
compiled grid products into its runtime asset root, applying existing derivation and confinement
rules. The compiler does not publish a successful handle until the `.fpk`, asset tree and
dependency/load validation all succeed. No generated file enters the source tree. Failure
cleans only the service-owned incomplete candidate, reports cleanup failure separately, and
preserves earlier builds. Closing/releasing a build cannot delete files a preview still uses.

Same saved bytes and options must give the same `.fpk` and generated-asset bytes through the
editor and `fpack`. Paths of scratch candidates are not package identity. M15 adds no compiler
subprocess, background job queue or build tool; synchronous bounded compilation is sufficient.

## 9. The public authoring contract

`FoundryApi_v4` is flat v3 plus the following capability groups. Final C spellings, field
layouts and call count are frozen in Step 5's Resolution before the editor client is built;
the semantics below are binding, not an invitation to add a private helper API.

| Group (planned `author_*` prefix) | Required operations |
| --- | --- |
| Workspace | enumerate granted workspaces; info, revision, limits, dirty/build/preview state |
| Documents | enumerate, info, create relative file, refresh/discard, copy source bytes |
| Schema tree | enumerate registered schemas; recursive field/list-element description, names, widths, presence, defaults and `since` |
| Source tree | enumerate local records and dependency definitions; node info, child iteration, exact scalar reads; inspect the last activated runtime snapshot through the same read-only node vocabulary |
| Commands | create/duplicate/override/delete record; set/unset scalar or container; list insert/remove/move; Undo/Redo |
| Persistence | save one document; each result reports publication and durability separately |
| Diagnostics | validate workspace; enumerate the last operation's diagnostic snapshot |
| Products | build; inspect/release build; export to host-configured destinations; request preview activation and inspect its outcome |

Workspace, document, source-node, schema-node and build are distinct generational handles.
They are never runtime `Record`/`Schema` handles. Info structs use fixed-width fields with
reserved bytes zeroed; descriptors carry size/version where their payload can grow. Iteration
uses existing cursor conventions and stable file/declaration/field/list order. Revision mismatch
returns `Refused` with a stale-revision diagnostic; dead handles return `InvalidHandle`.

Scalar transport has an explicit kind. Booleans use the existing ABI boolean. String and ID
spellings are UTF-8 spans, copied on input. Numeric authoring reads/writes use canonical decimal
UTF-8 spelling plus declared numeric kind: never send a `u64` through a float, or narrow `f64`
through v1's `f32` reader. This authoring-only representation preserves exact values without
altering the existing ABI's simulation-number convention. Nested/list traversal is structural;
the client never assembles `.fdt` snippets or submits a whole-file replacement as its edit API.

Unset/default/present are distinct. A schema-node can describe an absent field, a nested field
or a list element even if no record instance exists. Defaults are traversable typed values.
This fills the real gap in existing `schema_field_type`, rather than giving the editor a
private copy of the registry. Bounds include all recursive input and output paths.

No heap ownership crosses the boundary. Use borrowed answers or caller-supplied buffers with
needed length, following existing conventions; failed calls leave outputs untouched except a
documented size/diagnostic result. Enumerations and borrows invalidate on the relevant mutation.
Calls run on the host thread after UI description, never during a world query or RHI frame
recording. Build/reload requests may be refused in an unsafe host phase.

No service: `Unavailable`. No grant/unsafe phase/conflict: `Refused`. Invalid external input:
`InvalidArgument` plus diagnostics. Unsupported source operation/version: `Unsupported`.
Capacity: `Limit`; allocation failure: `OutOfMemory`. Ordinary file/content errors must have
an explicit mapping and diagnostic, not fall through to an error-level internal-bug log.

The host supplies preview activation behind this published operation. It accepts a build
handle, not a pathname or arbitrary function pointer from the client. When unavailable, editing,
saving and building still work. Lua is unchanged; v1–v3 remain usable. New handle validation,
layout/signature agreement and empty-host/garbage sweeps cover the whole tail.

The loaded-preview root is a read-only authoring node snapshot, carrying the actual loaded
content generation and build revision. The host prepares it from the candidate runtime
`data.Store` through `author`'s exact-value snapshot builder, then publishes it with that
candidate. It is not the source draft or an optimistic copy of compiler output. The existing
node readers work for source, dependency and loaded snapshots; there is no second set of typed
field calls. The host keeps the preview's runtime state alive until replaced. Existing v1–v3
calls remain bound to the host's ordinary engine and retain their original semantics.

After publication, `fpack`'s command execution also consumes the authoring table: its host
supplies roots/options and maps the successful build to the existing `--out`/`--assets-out`
destinations through the service's host-configured export operation. Add that operation to v4
for any granted consumer; never pass an arbitrary output path in the client call. Preserve
legacy CLI byte output and exit codes. Bootstrapping may construct `author.Service`; compiling
a package is the public capability, not a privileged tool-only shortcut.
Legacy CLI export preserves its existing output file set (generated assets under `--assets-out`,
not unsolicited copies of source assets). An editor build's complete runtime tree is a different
explicit export selection over the same successful products. Export uses atomic individual-file
replacement and reports partial publication on failure; only the private candidate tree has
the complete-build guarantee. It never silently overwrites source or dependency roots.

## 10. The editor application

One window, fixed regions, existing immediate-mode controls:

- a command bar with workspace status, New Package/Record, Save, Save All, Validate, Build,
  Reload, Undo and Redo;
- a filterable file/record/schema browser, showing read-only dependency provenance;
- a typed property form with required/optional/default state, lists and nested fields;
- a diagnostics region with source locations and a loaded-content browser;
- an explicit dirty/build/loaded revision indicator and confirmation region.

**The editor's UI and UX follow Unreal Engine 5's editor** (the owner's direction, 2026-09-20).
Someone who knows UE5 should find each region where they expect it, and each command under the
name they know:

- the command bar is UE5's main toolbar, across the top; a status bar along the bottom carries
  the dirty/build/loaded indicator;
- the browser works like UE5's Content Browser and Outliner: a filterable tree, with read-only
  dependency definitions marked by where they come from;
- the property form works like UE5's Details panel. It has a search filter, and nested fields
  and lists are collapsible groups. Beside each optional or defaulted value that is set, a
  reset-to-default arrow unsets it. List elements have add, insert, remove and move controls;
- diagnostics work like UE5's Message Log, where each entry selects its record and field; the
  re-hosted log is its Output Log;
- unsaved documents are marked as UE5 marks unsaved assets, and the close confirmation lists
  them;
- commands UE5 has keep its shortcuts: Ctrl+S, Ctrl+Shift+S for Save All, Ctrl+Z and Ctrl+Y,
  with Cmd in place of Ctrl on macOS.

The dark palette is the editor's own theme, in `foundry:editor` content (ADR-0041). UE5 is the
reference for layout, naming and interaction only. No Epic artwork, icons, fonts, code or marks
are copied, and the editor does not present itself as Unreal. UE5 relies on some things M15
leaves out: docking and tab tear-off, popup and context menus, modal dialogs and a level
viewport. M15 uses this section's fixed regions and in-window confirmation instead, and §13
keeps those questions open.

Use visible-row culling from the overlay's established pattern. Re-host content/schema/asset
inspection and log presentation using the public calls that already expose them. Do not rewrite
the in-process overlay or invent another engine-side inspector. Entity/profiler/memory views
may report unavailable when the host supplies no relevant capability; recreating every overlay
panel is not a prerequisite for record authoring.

Exact numeric fields are text-entry controls, not floating sliders. Strings are edited as
decoded UTF-8; represent newline/tab characters in a single-line escaped display with explicit
conversion at the form edge. This does not add a multi-line widget or require `.fdt` quoting.
ID controls accept a spelling or a choice from browsed IDs. A list has Add, Remove and Move
controls. Creating a record exposes incomplete required fields instead of inventing game values.

Editor UI strings/theme belong to its own ordinary `foundry:editor` package, loaded by the
usual content path. Its theme is applied around whole UI frames as v3 requires. Workspace
preview content must not override the editor's control labels or authoring authority: use a
separate host-owned preview content context. One ABI host stays bound; the loaded-content
browser reads §9's immutable loaded-preview nodes, while existing calls serve the editor's
own engine and content. This avoids rebinding the global host or redirecting UI/theme reads
while they hold live borrows. M15 does not require a GPU viewport for arbitrary workspace assets.

Build target `zig build editor` runs with explicit arguments after `--`; normal build/check
graphs compile the host and client, with null tests and a bounded smoke mode. A frame budget
exits cleanly and never saves/edits source automatically. The editor supplies its own icon
under ADR-0034. No native package code is loaded, even during preview.

## 11. Reload and the runnable proof

Editing, Save, Build and Reload are different commands with different status. Successful Build
does not silently replace loaded content. Successful Reload adopts dependency packages and the
candidate package through the ordinary loader, then publishes the new generation and build
revision. Failed loading preserves the previous preview and its assets. Asset refresh is not
assumed transactional merely because record loading is: load a candidate preview context and
release the old one only after the new preview's required resources are ready. Do not change
the established game-wide reload contract as an incidental editor fix.

For the first editor, Reload proves the compiled definitions and asset metadata can be
inspected in the loaded runtime snapshot. A visual asset viewport is postponed; no hardcoded game
scene adapter is required. In particular, opening a `foundry:scene` record does not execute its
scripts or run its game's systems.

M15's exit has two linked proofs:

1. In a source directory outside the repository, use the real editor UI to create a content
   package and manifest, choose an existing dependency schema, create an override/new record,
   edit scalar and composite fields, Undo/Redo, Save, Build and Reload. Close and reopen the
   editor and inspect the same values. No hand-written `.fdt` or scripted source generation
   substitutes for the authoring actions.
2. Put that generated artifact in a relocated sample's normal user-mod folder. Enable/apply it
   through M14's existing screen and restart. Demonstrate a visible sample change (for example
   an overridden UI string or theme), supplied by the authored record, with no engine rebuild.

The fixture can use sample schemas; production editor code cannot recognize their names.
Also edit a pre-existing commented/imported fixture and demonstrate that untouched bytes stay
unchanged. A separate installed-header C consumer performs the same core operations through
v4, proving this is a public capability and not just a clever UI host.

## 12. Verification, without repeated audits

Each implementation step runs its focused checks, fixes concrete failures and completes the
AGENTS.md bar once before committing. Subsequent documentation inspection is one consistency
pass. A successful result stays accepted unless later edits can invalidate it. No delegated
reviewers or repeated broad audits are needed.

Distinct evidence required by the affected boundaries:

- **Source model:** identity no-op round trip, comments/BOM/CRLF/imports, byte-exact unaffected
  spans, list/nested edits, defaults/absence, full integer endpoints, exact floats, escaping,
  collision diagnostics, malformed/unknown constructs, bounded depth and allocation failure.
- **Workspace/history:** stale handles/revisions/cursors; atomic command failure; edit/undo/
  redo/save sequences; history eviction; source changed externally; read-only dependencies.
- **Persistence/build:** symlink/traversal/alias rejection, create collisions, two cooperating
  writers, crash-left lock, partial Save All, write failure and weaker durability; failure after
  a generated asset is emitted; previous build retention; changed snapshot inputs and limits.
- **Compiler parity:** existing fpack fixtures and exact outputs before/after extraction;
  identical editor/CLI bytes with explicit dependency schemas and derived assets.
- **ABI:** v1–v3 unchanged, C/Zig layouts/signatures, installed C99 header on the three targets
  and C++17, absent/read-only services and malicious arguments, external C consumer. Deliberate
  wrong signature/layout and forbidden import must fail before guards are accepted.
- **UI/integration:** headless action sequences including confirmation/cancel, list clipping,
  input capture, failed Save/Build/Reload and status accuracy; real window authoring proof and
  a relocated sample consuming its output.

The editor is compiled for macOS, Windows and Linux in the existing graphs; Linux runtime
qualification remains M18. At closure run the editor authoring loop on macOS/Metal and the
existing Windows/Vulkan target, using the established target workflow. The null smoke test is
not a substitute for actual text entry, clicks, DPI/layout and visible results. Vulkan backend
requalification is not owed by unchanged docs or unrelated authoring code; the editor's new
Windows application does require its own runtime proof and optimized compile.

If sample content/release inputs change, stage both sample releases per AGENTS.md. Public Apple
signing and notarization remain M17; M15 does not claim an ad-hoc artifact meets that requirement.
Do not add CI or a general editor release/update system to close this milestone.

## 13. What stays open or outside M15

Unchanged open questions: native unloading/hot reload, mod-private storage and per-mod tables;
network/remote tooling; GPU/per-system profiling; pause/single-step and its audio/timestep policy;
keyboard/gamepad navigation, docking, popups, multiline widgets and content-authored layout;
`.fdt` multiline syntax, external-editor grammar and whole-file formatter; patch/remove
semantics and per-save package lists. M15 does not need these to meet its exit.

Explicit first-editor limitations: no visual schema authoring, asset creation/conversion,
multi-file atomic refactors, global ID rename, background compile, autosave/crash restoration,
gameplay execution, scene placement or plugin loading. These remain limits with demand as their
trigger, not new promised milestones. Existing game schemas can be supplied as `.fpk` data.

Two implementation details must be resolved in their named step and recorded before dependent
work: Step 1's smallest parser-span representation preserving imports, and Step 5's exact v4
layouts/call count. They may refine this design, not bypass its
boundaries. Any contradiction requiring a different architecture gets an ADR/Resolution first.

## 14. Implementation order — nine steps, Steps 1–3 done

Each step is one handoff: its tests, bar, Resolution, project-state update and commit, then stop.
ADR-0042/0043 were accepted on 2026-09-20, before any Step 1 code.

### Step 1 — Source ranges and deterministic value emission — done 2026-09-20

Add opt-in source ranges to the existing parser and pure emission/splice helpers in `data`.
Preserve source identities through imports. Record the selected span representation before
using it. Do not add workspace I/O or UI.

**Exit:** exact unaffected-byte tests and typed literal round trips cover §5; hostile bounds
and allocation failures refuse safely. Deliberately break one preservation guard and restore it.

### Step 2 — One reusable compiler and bounded workspaces — done 2026-09-20

Introduce `author` at the specified layer; extract fpack's implementation without changing its
CLI behaviour/output. Add explicit dependency-schema inputs, deterministic source discovery,
read-only dependency browsing, document baselines and configured budgets. Register its tests
and enforce dependencies in the build graph. No editing, saves or ABI publication yet.

**Exit:** existing fpack tests/byte fixtures pass, CLI dependency schemas work, and workspace
discovery refuses malformed/escaping/over-budget inputs without executing package code.

### Step 3 — Typed record commands and undo/redo — done 2026-09-20

Implement §5–6 over workspace documents: create/duplicate/override/delete, nested/list/scalar
edits, presence/default metadata, revisions, dirty tracking and bounded history. Use full-precision
data readers for dependency copies. Do not implement schema-definition editing.

**Exit:** all field kinds and exact-value/absence cases survive command/undo/redo cycles;
incomplete drafts have diagnostics; stale/failed commands leave old bytes and history intact.

### Step 4 — Safe saves and isolated builds

Implement confined create-if-absent if absent, cooperating-writer lock, baseline comparison,
per-file save results, structured validation, stable input snapshots and candidate builds.
Keep prior successful artifacts and their assets alive until released. No editor preview UI.

**Exit:** persistence/build failure matrix in §12 passes, including generated-asset failure,
external changes and partial save; same inputs match fpack byte-for-byte. Mutation-test the
source confinement and last-good-build retention guards.

### Step 5 — Publish authoring through FoundryApi_v4

Freeze exact §9 declarations in a Resolution, then implement the tail,
host service/grants, safe-phase preview request and candidate preview lifetime. Update header,
agreement/sweep/empty-host/native loader and the public authoring guide. Move fpack's command
execution onto the same table, preserving its CLI through host-configured export. No editor
client yet.

**Exit:** a C consumer can inspect, edit, save, build and request/inspect preview; no grant
refuses writes; v1–v3 are byte-identical; installed C/C++ and agreement mutation checks pass.

### Step 6 — Standalone host and ABI-only inspection client

Add the editor host, build/run/null smoke targets, separate header-only client module, ordinary
editor content package and icon. Re-host content/schema/asset browsing and diagnostics from
existing public introspection. Wire explicit roots and preview state without private handles.

**Exit:** a window and bounded null run browse a workspace and loaded preview; the negative
implementation-import probe fails as intended; all target graphs compile the new application.

### Step 7 — Complete the authoring workflow

Build the manifest and typed record forms, list controls, read-only override action, commands,
history, per-file/Save All reporting, confirmations and revision indicators. Use Step 5's table
alone; mutations occur after UI description. No new game-specific schema recognition.

**Exit:** deterministic headless input sequences create/edit/save/build/reload a package,
exercise every field shape and recover from refusal; a Metal window confirms real text entry,
clipping and capture. Unsaved close/refresh can be cancelled without losing work.

### Step 8 — External authorship and consumer proof

Perform §11 outside the tree via the real UI, then consume its artifact in the relocated room.
Exercise comments/imports and failure recovery. Run the editor workflow on Windows/Vulkan as
well as macOS/Metal, recording runtime evidence and platform limits. Write
`docs/modding/editor.md` from that workflow, with root grants, exact commands and limitations.

**Exit:** source was authored without manual `.fdt` edits, reopened faithfully, compiled with
the one compiler, reloaded through public calls, and changed a real sample through its normal
mod path. Both desktop targets have evidence; an external C client has equivalent capability.

### Step 9 — Close M15

Perform the final distinct integration gate and documentation consistency pass. Accept prior
successful evidence; repeat only what subsequent fixes invalidate. Update PROJECT_STATE,
AGENTS, roadmap, README, design index and affected design/ADR references; record any actual
limits in the existing debt/open-question locations. Commit, tag `m15`, and stop before M16.

**Exit:** all eight earlier exits are recorded, the roadmap's public-API author/save/reload
criterion is satisfied, and neither networking nor deferred release work has begun.

## Resolution — 2026-09-19, planning only

M14 is accepted complete at `be89db6`/`m14`; its tests and runtime proofs were not rerun for
this planning task. Inspection found that the table can browse content but cannot author it,
the compiler is tool-local, runtime numeric reads are lossy for source reconstruction, and
single-file replacement cannot honestly provide a package-wide transaction. ADR-0042/0043
propose the corresponding boundaries. Both are proposed, with acceptance before implementation.
Nine steps are specified. No source code, API header, build graph or content asset changes in
this handoff; Step 1 has not begun.

## Resolution — 2026-09-20, Step 1: source ranges and value emission

**The span representation, chosen before use (§13).** Spans are opt-in, through
`parser.Options.spans`, and cost nothing when off. A `Span` is a half-open byte range in one
file: `{ file, start, end }`, where `file` indexes `Document.files` and the offsets index that
file's own bytes, with any byte-order mark counted. Spans are a tree beside the values, not
fields inside `Value`:

- `RecordDecl.source` is a `RecordSource`: the whole record, its head, its ID, its braces, and a
  `FieldSource` per field;
- a `FieldSource` is a name span and a `ValueSource`;
- a `ValueSource` has the same shape as its `Value`: one span, plus `items` for a list or
  `fields` for a struct;
- `SchemaDecl.source` is only the declaration's whole extent, since schemas are inspected, not
  edited;
- `Document.imports` lists each `@import` with the file it reached, or none for a repeat.

`Value` is shared by the checker, schema defaults and the `.fpk` writer. Putting offsets into it
would make each of them carry offsets they never use. A tree of the same shape needs no index
arithmetic and no kind tags. The "insertion positions" §5 asked for are the containers' bracket
bytes, so there are no separate offsets for them.

**Imports keep their identity.** Each `SourceFile` is one parse of one resolver name, and
`importer` records the file that reached it first. A diamond import is parsed once, and its
repeat is listed with no file. A record's spans name its own file, so editing an imported
record edits that file's bytes, once. A span offered against another file's text is refused.

**Stale spans are refused.** A `SourceFile` also records its bytes' length and a Wyhash digest,
held in memory only. Every splice operation checks both first, then checks that each span lies
inside those bytes, names that file, and has the brackets its operation expects:
- `StaleSource` for changed bytes;
- `InvalidSpan` for a span that fails those checks;
- `IndexOutOfRange` for an index past the end.

This is the pure layer's own refusal. Step 3's revisions order edits.

**Emission, `data/emit.zig`.**
- **Integers** are exact decimal, with ranges from `schema.checkValue`, the checker's own rule.
- **Floats** are narrowed to their field's width first. They are written in the shortest spelling
  that reads back through the compiler's path, an `f64` parse narrowed as `BlockWriter.putFloat`
  narrows. If that spelling fails the check, the exact `f64` spelling is used instead.
  - The form is decimal for zero or `1e-4 ≤ |x| < 1e15`, and has an exponent otherwise.
  - `.0` is appended when neither a point nor an exponent appears.
  - Signed zero is kept, and NaN, infinity and an `f64` beyond `f32` range are refused.
- **Strings** use the parser's five escapes, plus `\u{..}` for every other control character, and
  are checked as UTF-8.
- **IDs** are written by their spelling from a caller's table (`Document.strings`), which is
  rehashed before it is trusted. `checkSpelling` refuses a malformed new spelling, and one whose
  hash another spelling already has.
- **Layout.** A list or struct holding only scalars stays on one line. Struct fields are
  separated by two spaces, as §4.1 of `content-schemas.md` writes them. Anything deeper is a
  block, indented four spaces per level from the line it opens on, in the file's first line
  ending.
- **Records.** A record is written in schema order, and a field it does not set is left out, so
  an incomplete draft stays incomplete. Unknown and repeated names are refused at every depth.
  Missing ones are not, at any depth, since drafts are allowed.

**Splicing, `data/splice.zig`.** Each operation returns one `Edit`: a range and its replacement.
`apply` requires edits in order, not overlapping, and no larger than the parser accepts.
- **Replace** covers exactly the value's span.
- **Insert, into a container on several lines**, starts a new line. It goes after the last
  element's line and any comment that ends it, or before the closing bracket if that bracket is
  on the same line. It takes the last element's indentation, or else the closing or opening
  bracket's plus four spaces.
- **Insert, on one line**, joins the line, after two spaces for a field and one for a list
  element. An empty `{}` becomes `{ x }`, and an empty `[]` becomes `[x]`.
- **Remove.** An element alone on its lines takes those lines, and one line ending, with it.
  Otherwise the element goes with the blanks that separate it from its neighbours. A comment
  beside it stays, at its indentation.
- **Move.** Elements trade places, and the gaps between them stay where they are. A comment
  between two list elements therefore stays in its gap rather than travelling with either one.
- **Records.** An appended record gets exactly one blank line before it, and the file's line
  endings. Insert-after goes past any comment that ends the neighbour's last line. Remove takes
  whole lines. Duplicate copies the record's own text under a new ID. A byte-order mark always
  stays at the start of its file.

**One parser change beyond spans.** The configured source limit now also stops at 4 GiB, since
token offsets are `u32`. A larger limit used to let a larger file reach the lexer and overflow
it.

**Left for later steps.** Step 1 adds no documents, workspaces, file access, history or ABI.
Choosing an edit from a schema, and re-parsing and checking the candidate before committing it
(§5), belong to Step 3. These helpers decide where bytes go, not whether an edit is right.

**Evidence.**
- **Tests.** Twenty-eight new tests: twelve in `emit.zig` and sixteen in `splice.zig`.
  - Every splice operation is checked for its exact output, and the result still parses.
  - Removals are checked to take only blanks and at most one line ending besides the construct.
  - A canonical file with a byte-order mark, CRLF endings and comments comes back byte-identical
    when every value is rewritten in place, and when no edit is made.
  - Integer endpoints of all four widths round-trip, and one past each is refused.
  - 200,000 `f32` bit patterns from a fixed seed read back through the compiler's path.
  - An edit to an imported record touches only that file.
  - Stale bytes, foreign or inverted spans, a list offered as a body, bad indices, overlapping
    edits and an oversized result are all refused.
  - Out-of-memory sweeps cover writing a record, and parsing with spans followed by every
    operation.
- **Mutation.** Whole-line removal was made to require only blanks before an element, not
  after it. Two tests failed, because a comment beside a removed field or list element was
  deleted with it. The guard was restored.

## Resolution — 2026-09-20, Step 2: one reusable compiler and bounded workspaces

**`author` is at L4, and `fpack` is its first consumer.** `engine/src/author/` is one module
whose dependencies are `core`, `data`, `platform`, `asset`, `mod` and `scene`, beside `app` in
`build.zig`'s layering table and with no `rhi`, `render2d`, `ui` or `audio` — so a workspace
unit-tests with no device, no window and no frame. `asset`, `mod` and `scene` are there because
the schemas a package's records are checked against are declared by them, and `platform`
because `data` cannot open a file. `tools/fpack` imports `author` and no longer carries a
compiler of its own (ADR-0042): a tool and an editor that each had one would be two compilers
that must agree, and the place they must agree is the output bytes.

**The extraction is a move, not a rewrite.** `tools/fpack/pack.zig` became
`engine/src/author/compiler.zig`, with `--out`/`--assets-out`/`--quiet`, the four passes, the
manifest pre-pass, the path-derived record ids and the grid compilation unchanged. Evidence:
the three packages in the tree compiled through the old tool and the new one are byte-identical
— `core.fpk` 965 bytes, `room.fpk` 11,077, `sandbox.fpk` 5,328 — and so are the generated asset
trees (`room-assets/grids/hall.fgrid`, `sandbox-assets/grids/room.fgrid`), with neither tool
writing an asset directory for `core`, which has nothing to compile.

**A dependency is a named file, never a search.** `dependency.Set` holds the `.fpk` files a host
granted, in the order it named them. Each is read through `platform`'s confined, no-follow
primitive with the host's own directory as the root and the file itself as the one component, so
a `.fpk` reached through a symlink is refused rather than followed; §4's bounds are enforced as
the bytes arrive (16 MiB per package, 64 MiB in total, 64 packages). A file named twice, under
any spelling of its path, or a byte-identical copy of one, is one dependency because a set is a
set; two different files that are the same package are refused, naming both, because which one
a record was checked against would otherwise be decided by the order they were named in.
`mod.manifest.read` gives each package its identity, and
`registerSchemas` registers every package's schemas *before* the authoring package's own
declarations — so a local `@schema` that disagrees with a dependency's is reported against the
local declaration, which is the one an author can change.

**`fpack --dependency <file.fpk>`, repeatable, is that same set** — §8's "dependency schema
inputs shared by the service and CLI". End to end, outside the tree: a package whose record
uses a granted package's type compiles with `--dependency` and is refused with
`unknown schema 'acme:torch'` without it; a file named twice produces identical bytes (793);
`room` with `core` granted is byte-identical to `room` alone, because `core` declares no
schemas; and a file that is not a package, or is not there, reports one diagnostic naming the
file and exits 1. `--help` states that they register in the order given, because that order is
the caller's and never the filesystem's (I9).

**`workspace.Workspace` is the bounded state an editor's later steps change.** `open` reads the
manifest, loads the granted dependencies, discovers sources deterministically (directory
listings sorted, asset paths sorted, never the filesystem's order), reads each one, and reports
a requirement no grant satisfies. §4's limits are one public `Limits`, so a host configures one
object, and a tighter bound is never raised. Discovery's own bounds are 1,024 sources (§4's
row), and two that are not rows of §4: 16,384 entries and 32 directories deep, because the
sources bound alone would let a tree of anything else be walked without end. **They are a
workspace's, not `fpack`'s.** A compile's walk is unbounded unless its host passes limits, which
is what keeps §8's "existing CLI invocations remain compatible": a person compiling their own
directory has already chosen its size, and an editor, which holds what it discovers, has not.
Nothing here edits, saves or compiles.

**What refuses, and what is only a diagnostic.** A tree past its walk, source or total budget, a
dependency that is not a package, a file that is not there, and a manifest that is not a
manifest all refuse before anything half-built is returned. An empty directory opens, because
that is where a new package starts; a malformed manifest opens with its diagnostic and no
identity, because the file that needs fixing must stay reachable by the tool that fixes it; and
an unsatisfied requirement is a diagnostic beside a workspace that still opens, because a
missing dependency is what the author is about to write down, not a reason to show them nothing.

**`readSelf` answers identity and requirements in one parse**, and reports nothing itself: it
runs before the ordinary passes, and a manifest the ordinary pass will diagnose as malformed
yields no requirements here, so one defect is one diagnostic, against `foundry:mod`, from the
pass that owns that rule.

**A defect the extraction surfaced, and the guard that now covers it.** `readSelf` returned an
`Origin` whose slices — `file` and `line_text` — were borrowed from the parse's document arena,
which is deinited before the caller reports; the requirement diagnostic then copied freed bytes,
a segfault in `memcpy`. Both are now copied into the caller's arena, for the same reason the
requirement's `name` already was: a diagnostic drawn from freed bytes is a crash rather than a
message. The first fix copied only `line_text` (see the review below).

**The bar.** `zig build test`: **1,511 of 1,512** headless tests passed, with the one skip it had
before, from **1,583 declared**. Twenty-three new tests: 12 in `dependency.zig`, 9 in
`workspace.zig` and 2 in `compiler.zig`. `zig fmt --check`, `check`, `check -Drhi=metal`, both cross-target checks
(`x86_64-linux-gnu` and `x86_64-windows-gnu`, `-Dplatform=null -Drhi=null`), and both samples at
30 frames under the null platform all pass.

- **Mutation.** The `findByPath` dedup was removed from `Set.load`, so a package named twice was
  read twice: `dependency.test.the same package named twice is one dependency` failed with
  `expected 1, found 2`. Restored. Since the review this mutation passes, correctly: the byte
  comparison it added also finds a file named twice, and the path check only saves the read.
- **Mutation.** `readRequirementList` was made to hand back the parser's own `line_text` instead
  of a copy: a workspace test aborted with a segmentation fault. Restored.
- **Mutations, after review.** The `origin.file` copy was removed, and then the `line_text` one:
  each time `compiler.test.what readSelf hands back outlives the parse it was read from` aborted
  — the first time in the checkout where the workspace tests had passed with the same bug.
  Restored.
- **Mutations, after review.** `fpack`'s walk was given the workspace's bounds, and the refusal of
  two files that are one package was removed: `compiler.test.fpack's walk is bounded only when a
  host asks for bounds` and `dependency.test.a copy of a package is the same package, and a
  different file claiming it is refused` failed. Restored.

**Review, 2026-09-20.** Step 2 was implemented by another model, and a review before it was
pushed found four things, fixed in the commit after it:

- **`origin.file` was still borrowed.** Only `line_text` had been copied, so the requirement's
  file name still pointed into the freed parse. Whether that crashed depended on the layout of
  earlier allocations: the bar passed in the owner's checkout, while the same commit checked out
  at another path failed `zig build test` with three crashed workspace tests. A test now reads
  `readSelf`'s answer through an allocator that overwrites what it frees, so a borrowed slice
  fails every time rather than some of the time.
- **`fpack` had become bounded.** The walk's limits applied to every compile, so a package with
  more than 1,024 sources, 16,384 entries or 32 levels of directories — each compiled by the old
  `fpack` — was refused, contradicting this step's "without changing its CLI behaviour". They
  now apply to a workspace only (above), and those three packages compile to the same bytes as
  before.
- **One package could be granted twice.** Two different files with the same package id were both
  loaded, and `find` and `satisfies` answered with whichever came first. Now refused (above).
- **Smaller gaps.** A test named for a package with no manifest tested a truncated file; it is
  now two tests, each of what its name says. The entries and depth bounds had no tests; they
  have. `fpack --help` listed `--help` below the prose; the build gave `fpack` four module
  imports it no longer uses.

The re-check: the three packages in the tree and their generated asset trees are byte-identical
to the pre-Step-2 `fpack`'s, and so is the installed content; nineteen edge cases (imports,
climbing paths, symlinks, CRLF and a byte-order mark, malformed manifests, usage errors) give
the same bytes, diagnostics and exit codes, except `--help`'s text and a leak the old tool had
on a manifest without a valid version. A package compiled with `--dependency` loads beside its
dependency in the sandbox. An allocation-failure sweep over opening a workspace and compiling
from it leaks nothing.

**Left for later steps, deliberately.** Nothing edits, saves, builds or publishes. A granted
dependency's `assets_root` is recorded and not used — Step 4's snapshot is what reads one. No ABI
changed: `FoundryApi_v4` is Step 5. And the CLI checks schemas where the workspace checks
requirements: §8 asks `fpack` for "dependency schema inputs", so a compile is held to the
schemas it was given, while a requirement no grant satisfies is the workspace's diagnostic.
`fpack --help` says what it does rather than more than it does.

## Resolution — 2026-09-20, Step 3: typed record commands and undo/redo

**A command is typed intent, never submitted source text.** `author/edit.zig` accepts a record
reference, structural field/list selectors and a `data.Value` with the spellings of IDs the
caller introduced. It resolves those selectors against the workspace's schema registry, asks
Step 1's splice helpers for one byte edit, reparses and validates the candidate, and installs it
only after the history entry and every other fallible allocation are ready. Create, duplicate,
whole-record dependency override, delete, set/unset, list insert/remove/move and Undo/Redo are
all reached through `workspace.Workspace`; schema declarations remain inspect-only.

**Parses are operation snapshots; source bytes remain the persistent model.** A workspace keeps
current bytes, a separately owned disk baseline and only the schema registry between commands.
An operation parses the documents it needs with source spans and releases those trees when it
finishes. This avoids retaining an expanded tree for every possible import root and means a
command always validates the bytes at its stated revision. The compiler and editor share the
same package-relative path normalizer and the same dependency/engine schema registration
function, so an import or available schema cannot mean one thing in `fpack` and another in a
workspace.

**Incomplete and invalid are different states.** Missing required record or nested fields emit
diagnostics but remain editable drafts. A syntax error, unknown schema, wrong value type,
repeated field or unsupported patch/remove construct makes that document read-only while other
valid documents stay usable. Each parser invocation owns a fresh bounded diagnostic collector
whose result is appended to the caller's collector; otherwise an earlier workspace diagnostic's
`failed` bit would make a later valid parse return `ContentInvalid` without reference to its
own bytes.

**Exact dependency copies do not cross the runtime ABI.** A whole-record override reads every
stored field through `fpk.Fields.valueAt`, including 128-bit integer transport for `u64`/`i64`,
`f64`, nested values, lists and the presence bitmap. Recoverable ID spellings come from the
dependency's package, schema and record names plus source spellings already in the workspace.
If a stored hash has no such spelling, emission returns `UnspelledId`; it never manufactures a
name. Optional absence stays absent, and a future upstream field is not silently merged into an
already-created override (§5).

**History owns bounded source fragments and structural selections.** One accepted command keeps
its before/after fragment and before/after locator. Undo and Redo replay those exact fragments,
validate the resulting source again and advance the workspace revision. A new edit clears Redo.
The 128-command/64-MiB defaults evict only oldest complete commands and expose that truncation;
a command larger than the configured history budget is refused. The 256-MiB persistent editing
budget counts current drafts, independent baselines and retained history, and candidate checks
also count the temporary old draft and emitted replacement present during validation.

**Atomicity includes allocation failure.** Candidate bytes replace the document only after
parse, structural validation, uniqueness, budget projection, owned history creation and stack
capacity all succeed. An allocation-failure sweep found two error cleanups freeing the same
snapshot array; removing the obsolete pre-ownership cleanup makes every induced failure leak-
free and leaves old bytes, revision and history intact. Stale revisions are refused before any
snapshot or candidate work.

**Evidence.** Six workspace tests cover all scalar widths/kinds, signed zero-capable float
transport, IDs, nested fields, scalar and nested lists, presence/default metadata, incomplete
drafts, create/duplicate/delete, exact dependency overrides and absence, an unspellable ID,
history eviction/branching, a command larger than its history budget and every allocation
failure point. All commands are driven back through inspection and exact Undo/Redo source
restoration. Disabling the expected-revision comparison made the stale-command test accept and
mutate old intent; the assertion failed, and the guard was restored. The full bar passes
**1,517 of 1,518** headless tests (one existing skip), from **1,589 declared**, including native,
Metal, Linux/Windows cross checks and both 30-frame null sample runs.

**Left for Step 4.** Step 3 changes memory only. It does not create files, acquire a workspace
lock, compare disk baselines, save, snapshot assets or build packages. Undo therefore never
writes to disk, and the baseline does not move. No ABI changed; publication remains Step 5.
