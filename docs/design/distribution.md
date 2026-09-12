# Distribution: an application a stranger can run

**Status:** designed 2026-09-12; **3/8 implementation steps complete** (Steps 1-3, 2026-09-12).
**Stop point:** after Step 3. Step 4 is not started.

Rests on [ADR-0030](../adr/0030-distribution-artifacts.md) and
[ADR-0031](../adr/0031-application-configuration-and-user-data.md), with ADR-0008, ADR-0014,
ADR-0016, ADR-0017, ADR-0021 and ADR-0027. Existing [scripting](scripting.md),
[public ABI](public-abi.md), [assets](assets.md), [content](content-schemas.md),
[platform](platform-interface.md) and [application](app-and-frame-loop.md) contracts remain
authoritative. Proposed filenames, types and commands below are implementation specifications.

## 1. What M9 owes

The roadmap's exit is **a zip a stranger can download and run**. The concrete proof is the
existing room sample as a macOS application: extract, launch in Finder, play, change volume
and window size, quit and relaunch with preferences retained. Move the app and launch again.
Its packages, runtime assets, attribution and useful local failure diagnostics travel with
it; neither a compiler nor the repository is present on the recipient's machine.

Needed now: explicit release inputs, runtime-only staging, settings, writable user package
roots, generated notices, persistent diagnostics, macOS bundle/signing workflow and a guide
written from the resulting artifact. Design for external games consuming the same helpers.
Postpone: installer/updater, storefront integration, CI/releases infrastructure, network
telemetry, compression/VFS at runtime, resource encryption, editor, mod manager UI, profiles,
cloud saves, input remapping, fullscreen/display management, new render backends and 3D.
Durable Lua state across process restart remains scripting §15's open question.

## 2. Existing implementation and the seams to use

| Existing implementation | M9 consequence |
| --- | --- |
| `build.zig`: sample install, `fpack`, content source and generated asset copies | Add separate staging; do not change the development install into the release tree. |
| `app/Engine.zig`: `contentDirOf`, `Config`, content reload | Preserve loose-install lookup; supply explicit bundle paths and per-package roots. |
| `platform/os.zig`: executable/user-data dirs, confined reads, ordinary writes | Reuse directories; add confined atomic replacement and bounded diagnostic output here. |
| `data/fpk.zig`: `BlockWriter`, `Blocks`, schema codec | Reuse field layout for settings; no new value serializer. |
| `mod/discover.zig`: one directory, relative `.fpk`/root pairs | Compose discoveries with provenance; resolution never uses root enumeration order. |
| `asset/registry.zig`: roots keyed by package handle | Keep per-package mount identity through content replacement and source reload. |
| `app/log_sink.zig`: stderr plus bounded memory ring | Drain a bounded independent diagnostic capture outside the logging lock; no file I/O in the audio callback. |
| `samples/room`: volume control and window handling | Persist existing capabilities; add no new gameplay or generic settings UI toolkit. |
| `samples/sandbox/scripting.zig`: optional Lua host | Secondary artifact proves runtime `.lua` is retained and user scripts still load. |
| `THIRD_PARTY_LICENSES/*.md` | Generate notices from existing distributed entries, including SDL's elected bundled licenses. |

The M8 baseline is commit `8c27f07`, tagged `m8`, with 1,199 headless tests already verified
by Claude. Planning accepts that evidence. This is not a request to rerun or audit M8.

## 3. Ownership and layering

The application remains the composition root. It owns bootstrap metadata, package selection,
world, audio mixer, renderer, ABI host, script manager and settings policy. `Engine` remains
a library driven by the caller. Its existing ownership does not expand to those subsystems.

`app.settings` supplies schema-driven encode/decode and opt-in storage orchestration over
`data` and `platform`. `app.diagnostics` owns normal-context draining and session lifecycle.
Neither needs imports of `scene`, `audio`, `mod`, `abi` or `script`. The host supplies copied
package/version summaries to diagnostics. `platform.Os` supplies filesystem primitives and
any macOS-specific operations. `data` still sees only bytes. `mod` retains package policy.

Build helpers under `tools/distribution/` consume declared artifacts/files and metadata.
They are packaging machinery, not an alternative runtime or privileged gameplay tool. They
may reuse the existing compiler's package-reading path for staging validation, like `fpack`;
they may not inspect world/component internals. Any future interactive tool still owes I4.

## 4. Application bootstrap and defaults

One application-owned release description supplies product name, bundle identifier, product
version/build number, executable artifact, minimum macOS version, package input locations,
settings schema/version, and optional extra runtime files. Generate plist/build metadata
from it; do not repeat product versions in unrelated files. Package IDs/versions still come
from `foundry:mod`, not this description. The engine's ABI version is not a product version.

Runtime bootstrap supplies the established application directory name (`foundry-room` and
`foundry-sandbox` stay unchanged), required package IDs, and the ordinary configuration record
ID. Only host/build inputs select these. Validate directory names as a single ASCII component
of at most 64 bytes, letters/digits/dot/underscore/hyphen, excluding `.` and `..`.

Game configuration is an ordinary record with an application-owned versioned schema, authored
in that sample's package. M9's reference fields are window logical width/height and master
volume. Gameplay fields remain in their existing records. No engine-wide schema hardcodes a
room or sandbox. Settings schemas are registered by the application at runtime too.

Startup order:

1. Establish bootstrap identity and explicit installation/user paths; start diagnostics
   once Step 6 supplies them (earlier steps retain the existing stderr/ring path).
2. Read bounded settings, including the separate enabled-package list.
3. Discover/resolve packages, create the engine with bootstrap window defaults, mount/load
   through existing paths, then read the selected merged configuration record.
4. Resolve built-in fallback values -> validated content defaults -> valid user overrides.
   Apply presentation settings before the first normal frame through existing interfaces.
5. Drive the usual world/frame loop. Persist explicit preference changes in normal context.

An invalid required configuration record is a startup diagnostic/failure, not a silent change
of game identity. A missing optional field uses its documented fallback. User preferences
are never used as tick rate, RNG seed, quota, library-consent or filesystem-root overrides.
Existing sample environment controls remain explicit development/test inputs, documented
separately; release does not require them. Test frame budgets do not rewrite preferences.

## 5. Settings format and validation

Use `settings.fset` under the application's user-data root. Proposed envelope v1 is explicit
little-endian, not a dumped Zig struct:

| Offset | Field |
| --- | --- |
| 0 | four bytes `FSET` |
| 4 | `u32` envelope version, initially 1 |
| 8 | `u64` application settings schema ID |
| 16 | `u32` application schema version |
| 20 | `u32` reserved flags, zero |
| 24 | `u32` field section byte length |
| 28 | `u32` string section byte length |
| 32 | field bytes, then string bytes; exact total length, no trailing data |

The field section is one root block at offset zero, using `BlockWriter`/`Blocks` against
the caller's registered schema. No schema layout is inferred from the input. Total file
limit 64 KiB, nesting depth 4, list length 128, string length 1,024 bytes, at most 64 fields;
apply limits before allocation and validate every offset, presence bit and value type.
Only values supported by the shared data format are eligible; no runtime handles/pointers.

The sample schema includes optional logical width/height, master volume, and an optional
list of enabled package ID spellings. Width/height are each 320..8192 logical units; volume
must be finite in [0,1]. The host may impose tighter usable limits. IDs must validate by
`data.contentId`; duplicates in the enabled list are rejected. The list is a selected set,
not an instruction to override dependency order. Native execution is not consented by it.

Missing file means defaults. Malformed values/format mean a warning and defaults, with the
original retained; explicit user preference changes may replace a malformed current-version
file after a bounded backup. A future envelope/schema version is read-only to this build:
defaults in memory, no automatic overwrite. Wrong schema identity is refused similarly.
No migration framework is required for the initial schema; adding a migration later means
an explicit versioned conversion with old-file fixtures.

Canonical writes use schema field order and sort/deduplicate the selected package set before
encoding. Do not serialize the environment, host paths or UI/runtime transient fields.
Application preference values are copied, never borrowed from a content reload arena.
An ordinary content hot reload may change defaults only for fields without a user override;
apply presentation changes at a frame boundary. It never changes the enabled package set
mid-session or rewrites saved preferences.

## 6. Safe persistence and write lifecycle

Add an `Os` operation for bounded, confined replacement under a host-supplied directory.
The destination is a validated relative leaf. Open directory components without following
user-selected symlinks/reparse points, create an exclusive temporary sibling, write all
bytes, flush/sync the file, then atomically replace the destination using that same directory
capability. Never truncate the old file before the new file is ready. Clean up only the
temporary file this operation created. A failing pre-rename operation leaves old bytes intact.
If directory syncing fails after rename, report durability as uncertain without claiming
rollback. Document target-specific guarantees, including Windows replacement behavior.

Create user directories only when needed; reject relative environment-derived roots and
report missing/unwritable roots without falling back to the current directory or app bundle.
This is ordinary user-owned storage, not a sandbox against a hostile process running as the
same OS user. Still test final/intermediate symlink rejection and same-directory replacement.

Persist on an explicit apply action and normal shutdown if dirty; coalesce continuously
changing controls so dragging volume does not write every frame. Fatal exit never saves.
No watcher reloads preferences under a running simulation. Concurrent app instances are
last-successful-writer-wins, documented; locking/profiles are postponed. Interrupted writes,
disk full, access denial and OOM must preserve the prior complete file.

## 7. Read-only installation and user mods

Loose development layout stays `<prefix>/bin` plus `<prefix>/content`. Bundle layout is
explicitly selected by the host; no search of cwd, parent trees or guessed alternate roots.
Use executable location for relocation and the bundle's fixed relative Resources directory.

User state is obtained through `Os.userDataDirAlloc`: on macOS, the existing Application
Support application directory; current Windows/XDG behavior remains build-checked. It holds
`settings.fset`, `mods/`, `logs/` and existing application save files, if any. M9 does not
add a save format or serialize script state. Logs/settings must not collide across samples.

Discover `Resources/content` and `<user-data>/mods` using existing discovery validation.
Retain host-assigned origin per candidate and combine candidates before `mod.resolve`.
Duplicate package IDs anywhere are an explicit conflict even if versions differ; never
pick the last directory visited. Missing required packages fail startup with their names.
Installed optional or user packages are enabled only by an explicit selected ID set.

Extend `app.ContentPackage` with an optional host-supplied base directory, defaulting to
`Config.content_dir`, while keeping `file` and `root` confined relative paths. Carry it through
loading, remount, content watcher and reload transactions. Copy owned path strings for their
required lifetime. Application adapters carry the same root into native/script descriptors;
no script or manifest can supply that absolute base. `asset` already mounts each package
separately; do not combine assets into a flat staging directory at runtime.

Release defaults disable watchers; loading script source is still allowed. Explicit developer
mode can enable existing reload behavior on user packages without editing signed resources.
The sandbox exercises Tier 2; native libraries stay opt-in to hosts that already load them.
No M9 ABI table change is anticipated. If implementation demonstrates one is required,
specify an additive version before code and retain v1/v2 byte-for-byte.

## 8. Runtime staging and release configuration

Provide a local build target `dist` selecting a sample (default `room`) and a reusable Zig
helper for an external application's release description. `dist` explicitly builds
`ReleaseSafe`, SDL3/Metal, aarch64-macos. Reject conflicting target/backend/optimization
arguments instead of silently producing a headless or unsafe release. Leave existing
`zig build`, `run`, `room`, `test` and `check` defaults intact. Pin Zig 0.16.0 throughout M9.

Compile content with a host-runnable `fpack`; do not execute a cross-target tool. Declare all
source files in the build dependency graph as the current content steps do. Start staging
fresh, in a build-owned output directory. Select only the application's package closure;
the room release must not accidentally ship sandbox content or Lua.

Stage `.fpk` and referenced runtime files under their original package-relative paths.
Keep `.png`, `.wav`, compiled `.fgrid`, runtime shaders if content uses them, and `.lua`
text when selected packages use scripts. Do not ship `.fdt`, `.grid`, C/Zig sources, caches,
headers, fpack or authoring scripts in a player artifact. Resolve a referenced generated
asset from compiler output; other assets from the declared package source root. Native
libraries and files for custom loaders require explicit runtime declarations. No assumption
that every file extension is one of the engine's built-in loaders is allowed.

Inventory every staged path, size and SHA-256 in stable path order. Refuse absent assets,
symlinks, nonregular files, absolute/traversing paths, case-insensitive path collisions and
two inputs writing one destination. Validate references without executing scripts/native
libraries. The inventory is for completeness/reproducibility, not authentication or DRM.
Bound file counts/total bytes by explicit packager limits; overflow fails before copying.
Dirty source may build locally but is marked dirty in metadata, not represented as a clean
tag. Public publication requires an explicit revision and successful gates.

## 9. Attribution generation

Generate `THIRD_PARTY_NOTICES.txt` from every entry under `THIRD_PARTY_LICENSES/` marked
`distributed`, in filename order, excluding its README and entries marked `build-time only`.
Include the whole selected entry verbatim, with separators: SDL's entry contains elected
licenses and bundled notices beyond its primary license block. Do not scrape only the first
`License text` section or discard fenced license text. Including Lua in a non-Lua sample's
aggregate is a documented conservative superset; do not claim all listed code is linked.

Parse the existing metadata convention strictly: accept `distributed` followed by its
existing explanatory suffix, refuse missing/duplicate/unknown distribution fields, and
require version, upstream, license and nonempty license text. Add negative fixtures for
truncated/malformed metadata and stable output independent of directory enumeration.
Copy Foundry's `LICENSE` and `NOTICE` separately; neither replaces third-party attribution.
Package license identifiers alone are not license texts: additional redistributed package
content must supply its required notices as declared release inputs, or staging refuses it.
Never download license text during the build. Generator/build logic is Zig, no Python tool
or new dependency. Generated output belongs in the artifact, not in tracked source.

## 10. Diagnostics and fatal failures

M9 adds local evidence, not crash recovery. A native crash is not contained like a Lua
fault. Preserve the platform/Zig fatal termination behavior; do not catch a signal, resume
simulation or attempt teardown/world saving through potentially corrupt state.

An opt-in diagnostics session starts before content/engine initialization and finishes after
normal teardown. It owns a bounded capture separate from the UI ring, so a hidden overlay or
its filter cannot erase the release log. `logFn` copies bounded records without allocation;
normal main-thread drain writes them through `platform` outside the log lock, at least once
per frame and at startup/normal shutdown boundaries. Report dropped record counts. The audio
callback still never logs. Disable a failing sink once, report via stderr without recursion,
and leave the in-memory/terminal paths usable. Drain no more than 64 KiB per frame.

Keep one active session file capped at 1 MiB and at most four previous logs. Preserve the
early build/session header; once capped, stop adding lines and append a reserved truncation
marker. Rotation happens at session start, only over exact owned filenames; parallel sessions
must use exclusive names and may not rotate another active file. Retention races must fail
harmlessly. Reject symlinks when opening log/marker files. Each session has its own small
marker recording clean/unclean termination, written using §6's primitive; never share one
marker across simultaneous processes. An abandoned marker means "previous session did not close cleanly",
not "a crash was proven"; SIGKILL, power loss and overlapping sessions must not be mislabeled.

Log envelope version 1 includes build revision/dirty marker, application version, target,
backend, optimize mode, package IDs/versions in resolved order and normal/failure exit stage.
Do not collect environment dumps, usernames, absolute home paths, source text, saves or
credentials. Existing subsystem messages can contain paths/user strings; the sharing guide
must require user review, rather than promise total redaction. Nothing is uploaded.

For ordinary startup errors, log a concise named cause before returning nonzero, with the
local log location available to a Finder user via the shipping guide. For fatal errors,
rely on macOS crash reports and matching retained symbols, plus the last drained log. Losing
the final undrained records is an explicit limitation. Any panic hook must be nonallocating,
nonrecursive and delegate to the normal fatal handler; it is optional, not grounds for a
custom crash reporter. Exercise fatal behavior only in child processes under host deadlines.

## 11. macOS artifact and signing gates

The reference tree is:

```text
Foundry Room.app/Contents/
  Info.plist
  MacOS/room
  Resources/content/core.fpk
  Resources/content/core/...
  Resources/content/room.fpk
  Resources/content/room/...
  Resources/LICENSE
  Resources/NOTICE
  Resources/THIRD_PARTY_NOTICES.txt
  Resources/build-info.txt
  Resources/runtime-files.txt
```

Use a stable sample bundle ID owned by the project, generated `CFBundleExecutable`, name,
identifier, version/build version, package type `APPL`, and an explicit minimum OS. Initial
support is macOS 26 on Apple Silicon, matching the validated platform; do not advertise older
versions merely because compilation succeeds. Product metadata is XML-escaped and validated
with `plutil`. An icon is optional and does not justify new third-party artwork.

Inspect all Mach-O dependencies with `otool`: only system frameworks/libraries or deliberately
bundled relative dependencies are allowed. No Zig cache, Homebrew or build-machine absolute
load path. SDL/Lua remain static where selected. Embedded metallibs must run without Xcode.
Retain `dsymutil` output separately and match UUIDs with `dwarfdump`; symbols are not in the
player zip. Do not promise source locations if the retained artifact cannot symbolize them.

Local profile stages, validates and ad-hoc signs the complete app, then uses `ditto` to zip
it while preserving executable permissions. Distribution profile signs with an externally
supplied Developer ID identity and hardened runtime, submits with `notarytool`, staples the
accepted ticket, verifies signing and Gatekeeper assessment, then creates the final zip.
No credentials in arguments recorded to logs, repository files or environment dumps; use the
operator's external Keychain profile. Upload/signing with private identity is an explicit
operator action, not a side effect of `zig build dist`. Never mutate resources after signing.

No JIT entitlement is needed by the interpreted Lua host. A host loading unrelated native
mods may need the library-validation exception; do not enable it on every sample. Verify
the exact native-host profile with an outside-team plugin before claiming Tier 3 works under
that signing profile. Do not enable App Sandbox in M9 or constrain mods to the host's Team ID
silently. Distribution code signing is not a sandbox for consenting native code.

Apple's [signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
and [library-validation rules](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
support these gates (consulted 2026-09-12). A developer exception through
[Privacy & Security](https://support.apple.com/en-gb/102445) can be documented for local
artifacts, but it is not evidence that notarization succeeded. Never instruct players to
disable Gatekeeper globally or erase quarantine as the distribution procedure.

## 12. Verification obligations

Each step runs focused checks, fixes concrete failures, then one applicable integration bar
under AGENTS.md §§3/6. Accept successful evidence over unchanged work. The following are
distinct M9 obligations, distributed among steps, not repeated whole-repository audits:

| Boundary | Required evidence |
| --- | --- |
| Settings | Round trip, deterministic bytes, bad/truncated offsets, nonfinite/range violations, future versions preserved, allocation failures. |
| Persistence | Fail before each write/flush/replace boundary; old file intact; no symlink writes; unavailable root; actual platform replacement. |
| Defaults | Ordinary content mod changes defaults; saved override wins; changed settings persist across a fresh process; sample identities stay separate. |
| Roots | Move install, foreign cwd, spaces/non-ASCII host path, read-only app; user assets/scripts load from their own roots; duplicate IDs refused. |
| Staging | Missing/custom/generated assets, collision/traversal/symlink refusals, exact inventory; no authoring/build residue; two identical unsigned stages compare. |
| Notices | Every distributed entry preserved, build-only excluded, malformed entries fail; content notices included. |
| Diagnostics | Startup failure before engine exists, rollover/cap/drop counts, denied writes, unclean child exit, healthy next launch and matching symbols. |
| Distribution | SDL/Metal ReleaseSafe app visibly renders/plays/audio works; Finder launch after actual download/quarantine; relocation; no toolchain at runtime. |
| Modding | Packaged sandbox loads an outside-tree script/content package from user roots; native signing claims require separate native-host evidence. |

Break each newly introduced guard narrowly at its implementing step and observe its test
fail, then restore it. No repeated mutation of already-proven M8 guards. Release-mode tests
provide distinct evidence from Debug; macOS windowed artifact runs provide evidence that
null builds cannot. Cross builds remain compile evidence, not runtime support claims.

## 13. Risks and deliberately open work

Signing identity, notarization access and a clean recipient Mac are not assumed available.
Their absence does not block design or local steps; it does block reporting the full release
gate complete. Do not buy credentials, upload a release or invent recipient evidence.

PROJECT_STATE.md carries a Metal app-test compilation issue and a renderer texture staging
lifetime concern. Neither is re-audited during planning. At the affected release gate, a
concrete reproduced failure must be reported and scoped before claiming success; packaging
does not authorize a renderer redesign. Existing batching optimization, threading/editor,
networking and scripting open questions stay open.

Deferred questions: older macOS support, storefront-specific signing, settings migrations
once a second schema exists, profiles/concurrent preference merging, crash collection beyond
OS reports, and a runtime container if measured file overhead warrants one. These do not
prevent the scoped first release; they are not silently answered by helper implementation.

## 14. Implementation order

**Eight steps, stop after each.** Each ends with its targeted evidence, one applicable
integration bar, required documentation updates, a focused commit and handoff. Append a dated
Resolution when implementation exposes a design correction. No step is done by this plan.

1. **Persist bounded versioned preferences. Complete 2026-09-12.** Implement §5's codec and §6's atomic OS
   primitive/opt-in `app.settings` storage. Tests cover corruption, versions, failure injection
   and confinement. Runnable result: headless round trip through real user-root fixture files.
   No sample configuration changes, package roots or distribution build target yet.
2. **Apply ordinary content defaults and user settings. Complete 2026-09-12.** Implement §4 in both samples,
   application-owned schemas/default records and existing volume/window controls. Persist
   changes and selected package IDs; selection still uses the existing installed root until
   Step 3. Verify content override versus user override and fresh-process persistence.
   Runnable result: resize/change volume, quit/relaunch, keep both preferences.
3. **Load user packages beside a read-only installation. Complete 2026-09-12.** Implement §7's origin-preserving
   combined discovery and optional per-package base, including reload and script/native host
   adapters. Test duplicates, unavailable roots, relocation and confined asset loading.
   Runnable result: outside-tree user content/script package runs without modifying install.
4. **Stage a complete release from explicit inputs.** Implement §8's reusable Zig build
   helpers, host fpack and bounded runtime inventory; stage both sample variants. Verify
   ReleaseSafe, exact selected files, deliberate omissions/collisions and unsigned byte
   reproducibility. Runnable result: staged loose room runs from outside the checkout.
5. **Generate and ship complete attribution.** Implement §9 and integrate its required
   outputs with staging. Test malformed metadata and full SDL/Lua text retention; include
   package notices. Runnable result: staged release carries generated, reproducible notices.
6. **Keep useful evidence after startup and fatal failure.** Implement §10 and wire both
   application lifecycles. Child-process failures and persistence/rotation tests; prove
   read-only storage does not prevent play. Runnable result: failed launch leaves a useful
   local log; a subsequent successful launch remains usable. No custom native crash recovery.
7. **Build and verify the macOS application.** Implement §11's plist, bundle, symbols,
   signing profiles and zip steps. Run the real windowed ReleaseSafe artifact after moving
   it; inspect dependencies/signature/symbol UUIDs. Document exact operator notarization
   commands, execute only with authorized available credentials. Record any unmet external
   gate explicitly. Runnable result: Finder-launchable local `.app` and zip.
8. **Execute the recipient exit criterion.** Write `docs/shipping/macos.md` from an external
   consumer using the helpers and the reference room artifact. Reproduce the exact guide
   from a fresh directory; verify download/quarantine launch on a recipient environment
   without the development toolchain, play/audio, persistence, relocation, diagnostics and
   user-mod installation. Record actual signing/support limits. Update indices, counts and
   PROJECT_STATE; mark M9 complete/tag `m9` only after the exit evidence exists. Stop before
   backend #2, 3D or any other milestone.

## 15. Planning handoff

ADRs 0030/0031 and this design settle the M9 architecture and eight bounded steps. All M8
implementation/evidence is retained. Steps 1 through 3 are complete as of 2026-09-12; see
their Resolutions below. **Next is Step 4, not started and not authorized.** Nothing in Steps
4-8 — the `dist` target, generated notices, diagnostics or the macOS bundle — exists yet.

## Resolution — 2026-09-12, step 1

What implementing §5's codec and §6's replacement settled, corrected or made explicit.

**A file written against an *earlier* version of the same schema is preserved, not read.**
§5 says a *future* envelope or schema version is read-only to this build, and that a
migration later means an explicit versioned conversion. It did not say what an older file
does, and the layout forces the answer: a block's presence bitmap is
`presenceBytes(field_count)` wide, so a schema that grows from eight fields to nine moves
every slot that follows it. An older block's fields are therefore *not* at the offsets a
newer schema would read them from, and reading one anyway would return plausible wrong
numbers rather than an error. So `PastVersion` joins `FutureVersion` and `ForeignSchema` as a
reason to keep the file and use defaults. This is why §5's "explicit versioned conversion
with old-file fixtures" is a requirement rather than a nicety: without one, bumping a
settings schema version silently drops every user's preferences on the floor.

**Finiteness is the codec's business; range is the application's.** §5 puts "volume must be
finite in [0,1]" in the sample schema. The interval stays there — it is policy about one
field — but finiteness moved into `encode` and `decode`, because a NaN is a legal `f32` and
can never be a preference a person chose. Left to the schema, every consumer of every float
setting would have to defend against it separately, and the one that forgot would propagate
it into a mixer gain or a window size.

**Uncertain durability is a result, not an error.** §6 asks for durability to be reported as
uncertain "without claiming rollback". `replaceFileConfined` therefore returns
`Durability.durable` or `.entry_unflushed` rather than failing: by the time the directory
entry can fail to flush, the rename has already happened and the new bytes are what the file
holds. Zig 0.16's `std.Io.Dir` has no directory sync of its own, so the flush is done by
opening the parent as a file and syncing that; where an OS does not permit it — Windows among
them — the answer is `.entry_unflushed` and the replacement still happened.

**A destination name has a bound, and callers need to know it before they save.** The
replacement writes an exclusively created sibling named after its destination, so a name
close to the filesystem's 255-byte component limit has no room for the decoration.
`platform.os.max_replaceable_name` is public for that reason: a caller choosing its own file
name can refuse one at construction rather than discovering on the first save that its
settings can be read and never written.

**Confined reading and confined replacing share one walk.** Both now go through
`openParentConfined`, which opens every component below the host's root with following
disabled and hands back the parent directory and the leaf. Two implementations of "do not
follow a link" would be two places for the rule to be almost right, and the failure mode of
almost-right there is writing outside the root a host granted.

## Resolution — 2026-09-12, step 2

What applying §4 in two real applications settled, corrected or made explicit.

**Whether preferences are live at all is two rules, not one.** §4 says "test frame budgets do
not rewrite preferences", which covers writing. Reading needed a rule too, because a scripted
run that reads whatever happens to be saved on the machine running it is a run whose result
depends on that machine — the hidden input I9 objects to. So both samples apply two
conditions, each with its own reason. A **headless** run neither reads nor applies them: it
has no window to size and no audible mixer, so there is nothing for a preference to change
and everything for one to make unrepeatable. A **frame-budgeted** run reads and applies them
and never writes: a budget marks a run nobody is watching, and such a run must leave a
person's choices as it found them. The consequence is deliberate and worth stating: the
AGENTS.md §3 bar exercises the fallback and content layers and never the user layer, so the
user layer's evidence is `engine/tests/settings_startup.zig` and a windowed run by hand.

**Only a value the player chose is written back.** §4's layering implies it and does not say
it: a resolved value carries its origin, and `flush` writes a field only when that origin is
`.user`. Writing back a content default would freeze it — the file would outrank the package
from then on, so the package that supplied the value could never change it again, and a mod
overriding it would appear to do nothing. This is also what makes a first run leave a *small*
file rather than a copy of the package's defaults.

**Applying a window preference produces an event indistinguishable from the player making
one.** `setWindowSize` is a request; the result arrives as a `window_resized` event on a later
frame, by design, so that a program resizing itself takes the same path as a user dragging an
edge (`platform-interface.md`). That means the act of applying a saved width generates exactly
the input that records a saved width. Both samples suppress the echo by ignoring a resize
whose logical size already equals the resolved value — without which every launch would mark
the file dirty and rewrite it.

**A settings schema is not registered with the content registry.** §4's "Settings schemas are
registered by the application at runtime too" can be read as putting them in `data.Registry`
beside content schemas; ADR-0031's "not merged into the content store" rules that out. The
implementation resolves it the second way: the application declares its schema in its own
code and hands it to `app.settings`, which validates and encodes against it. Nothing about a
settings schema enters the store, so no package can see one, override one, or define a record
of one.

**The part that is the same for every application was extracted after it was written once.**
`app.settings.File` owns where the file is, whether this run may write it, and when a change
is written; `Layer`, `Origin`, `resolveInt`, `resolveFloat` and `IdSet` own the resolution
walk and the selected set. What stays in each sample is what is genuinely that sample's: which
fields exist, what counts as a usable value, and where a resolved value goes. This is the
`render2d` lesson applied early — the room and the sandbox would otherwise have carried two
copies of the "when may this be written" rule, which is the one piece where being almost right
costs a player their settings.

**The application directory name is validated where it enters.** §4 asks for a single ASCII
component of at most 64 bytes. `platform.os.isValidAppName` enforces it and `Os.init` refuses
one that fails, which widened `app.InitError` by one member. Checking it at the point it is
supplied rather than at each place that builds a path means no caller of `userDataDirAlloc`
has to wonder whether the name it is about to join is one.

**One resize is visible at startup, and it is the design's choice.** §4 creates the engine on
bootstrap window defaults and applies the resolved size after content is loaded, because the
content default cannot be known before then. A windowed sandbox run therefore opens at
1280x720 and resizes to the 1152x648 its package asks for. Keeping one apply path for both
layers is worth a frame of resize; the alternative — seeding the window from the preferences
file and the content default from somewhere else — makes bootstrap authority partly a
preference, which is the distinction ADR-0031 exists to hold.

## Resolution — 2026-09-12, step 3

What implementing §7's two roots and package provenance settled, corrected or made explicit.

**Provenance is the concrete base directory, not an origin enum.** Discovery is still one
directory per call. Each candidate now retains the host-supplied directory that was actually
searched, resolution copies it into each ordered entry, and the application may pass it as an
optional `ContentPackage.base_dir`. An `installed`/`user` label would still leave the loader
needing a second lookup table, while the concrete base is exactly the capability it needs.
The manifest cannot supply or alter it. A null application base preserves the original
`Config.content_dir` behaviour for hosts with one root.

**The script boundary does not learn a filesystem path.** The engine mounts each package's
host-assigned base and relative root in `asset`; binding 1 continues to obtain copied source
through `FoundryApi_v2`. Giving the script manager an absolute directory would duplicate that
route and violate I4. Native loading is different because the consenting host opens the
package-local dynamic library itself, so `native_loader` consumes the resolved entry's base.
Neither public ABI table changed.

**Every package operation keeps the same provenance.** Initial `.fpk` reads use a confined
same-open read/stamp operation beneath the package base. The watcher stats that same confined
file, reload reads it there again, and content replacement remounts the same base/root pair.
`file` and `root` must remain safe relative paths even when a host constructs
`ContentPackage` directly. Asset loading retains its existing confined walk beneath each
mount, so a user package cannot make an installed package's assets relative to itself or
escape its own root.

**A user-data path is either absolute or unavailable.** `userDataDirAlloc` now refuses
relative `HOME`, `XDG_DATA_HOME` and `APPDATA` values rather than returning a path relative to
the process working directory. An absent, invalid or unreadable user root produces a warning
and an empty user discovery; installed packages remain usable. Duplicate IDs across either
root are still one explicit resolution conflict, and the diagnostic names both origins.

**Headless discovery has no ambient user input unless selection is explicit.** Windowed
samples discover the user `mods/` directory normally. A null-backend run does so only when
`FOUNDRY_*_PACKAGES` explicitly supplies a selected package set. This is the Step-2/I9 rule
applied to package roots: the standard deterministic headless run must not vary with whatever
a developer happens to have installed, while an explicit selection must be able to exercise
an outside-tree user package. Watchers remain the existing opt-in developer setting; no
release default was introduced ahead of Step 4.
