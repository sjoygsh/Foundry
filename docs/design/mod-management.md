# Design: M14 — Managed, and what a player chooses

**Status:** Design accepted 2026-09-19 with [ADR-0040](../adr/0040-ordered-profiles-applied-at-next-start.md)
and [ADR-0041](../adr/0041-game-widget-set-and-content-themes.md). **Steps 1 to 5 are implemented
(2026-09-19): the mod set, profiles on disk, migrations with concurrent writes, the UI
kernel's additions, and themes as content. Step 6, the game widget set, is next.** Step 2 was re-scoped when it began; see §13.
**Date:** 2026-09-19
**Baseline:** `754665a` / `m13`; M0–M13 complete, 1,405 declared / 1,395 headless tests.
**Builds on:** ADR-0024 (one UI kernel, two widget sets), ADR-0026 (the host supplies
subsystems), ADR-0027 (a mod is a content package), ADR-0031 (bootstrap, defaults and
preferences kept apart); `public-abi.md` §§11–14, `distribution.md` §§5–7, `ui.md` §§7, 13–15.

## 1. Purpose and boundary

`CLAUDE.md` §5 records it plainly: a mod manager UI is still unbuilt. Discovery, dependency
resolution, deterministic order and user package roots all exist, and a player can reach none of
them. Today a mod is turned on by an environment variable or by a preferences file nobody edits
by hand. The roadmap gives M14 three pieces:
- enabling, disabling, ordering and conflict reporting, through the public API a mod could use
  (I4), with the order still deterministic (I2, I9);
- the content-driven game widget set ADR-0024 deferred, which is what such a screen is made of;
- the deferred preference work: profiles, concurrent merging, and settings migrations once a
  second schema version exists.

**Exit criteria:** a packaged sample where a player, not an environment variable, turns a mod on,
and preferences survive a schema change without losing what the player chose.

**The engine owes the capability, not the screen.** A game's mod screen is the game's, and so is
its look. The engine supplies:
- the mod set: what is installed, what is chosen, in what order, and what it conflicts with;
- profiles on disk, with migrations and concurrent writes that lose nothing;
- the game widget set and content themes;
- all of it through the public ABI.

One sample, the room, builds the screen from those parts as the reference a game copies. Its
layout follows Mod Organizer 2, the tool most players who mod already know, changed where
Foundry's model is different and better (§3).

**Not in M14:**
- downloading or installing mods from anywhere; installing is putting a `.fpk` in `mods/`;
- turning a mod on or off while the game runs (§8);
- unloading native libraries (`public-abi.md` §14);
- layouts authored as content, keyboard or gamepad navigation, popups and tooltips (§10);
- `@patch` and `@remove` content semantics, still "designed, later" (`content-schemas.md` §7).

## 2. What exists, inspected

- **`mod.discover` and `mod.resolve`** (`public-abi.md` §12). Resolution is a stable topological
  sort. Among mods whose dependencies are placed, the smallest `(position in the player's enabled
  list, content id)` goes next, so the player's order already decides everything a dependency
  does not. Skips carry a reason: not installed, missing dependency, dependency version,
  dependency skipped, cycle. **Two candidates with one id are fatal** (`DuplicatePackage`),
  whichever directories they sit in and whether or not either is enabled.
- **Both samples repeat the same host code.** Each discovers the installed `content/` and the
  user's `mods/`, and requires `foundry:core` plus its own package. It enables the ids in its
  settings, appends `FOUNDRY_*_PACKAGES`, and resolves. That is two copies of what a mod set is.
- **`app.settings`** (`distribution.md` §§5–6, ADR-0031). It is a `FSET` envelope over one
  field block against the application's registered schema:
  - bounded to 64 KiB and 128 list elements;
  - written by atomic replacement;
  - a future version is preserved and never overwritten;
  - two running instances resolve by last-writer-wins.

  **Its canonical write sorts and deduplicates the enabled set**, so the player's order is
  thrown away at the first save. "No migration framework is required for the initial schema."
- **The store remembers who won** each record (`content-schemas.md` §7), "for a mod manager".
  `FoundryApi_v1` answers `record_package` and `package_next`, for the loaded set only.
- **A `.fpk`'s record table lists every content id it provides** (`content-schemas.md` §5.1),
  so what a package provides is readable without merging anything. Assets are records
  (ADR-0021), so asset conflicts are record conflicts. Only whole-record replacement exists.
- **The enabled set never changes mid-session** (`distribution.md` §5), and native libraries
  are opened once and never closed (`public-abi.md` §14). Neither sample loads native code.
  "Native execution is not consented by" the settings file.
- **The UI kernel** (`ui.md`):
  - it sits at L1 and emits a draw list of rectangles, text and clip pushes;
  - it reads a `Style` value and holds no literal colour, font or metric;
  - its debug widget set is `label`, `button`, `checkbox`, `slider`, `collapsingHeader`,
    `scrollRegion`, `textField`, `plot`, `separator` and `spacer`;
  - the walker lives in `app`, with an optional solid region from content.

  `ui.md` §13 promised that "a style becomes a content record and the ABI gains a call to
  resolve one", and §14 expected the game layer to need image and nine-slice commands.

## 3. Mod Organizer 2 as the reference

What MO2 does, what Foundry takes, and what changes because Foundry's model differs:

| MO2 | Foundry | |
| --- | --- | --- |
| Left pane: the mod list, a checkbox per mod, priority by position, drag to reorder | The same. Position is the player's list, which `mod.resolve` already honours | Taken |
| Conflict flags per mod: overwrites, is overwritten, both, redundant | The same four, computed per **record** rather than per file, with the exact winner | Taken, sharper |
| Selecting a mod highlights the mods it beats and the mods that beat it | The same tints | Taken |
| Plugins tab: a second load order for plugin files | Not needed: a package is both what installs and what loads, so there is one order | Dropped |
| Data tab: the merged file tree, with which mod provides each file | A Records tab: for a record, every package providing it and which one wins | Taken, by record |
| Mod information dialog with tabs | The right pane's Details, Conflicts, Records and Problems tabs | Taken |
| Notifications, problems | The Problems tab and a count on it: skips, duplicates, dependency failures | Taken |
| Profiles: a mod list per profile, with optional per-profile saves and INIs | A profile is a named, ordered selection plus native consents. Settings stay global; saves are the game's | Narrowed |
| Virtual file system and the Overwrite folder | Nothing: `asset` mounts each package separately, and a mod cannot write files (`public-abi.md` §18 Q3) | Not needed |
| Downloads, installers, Nexus, executables, instances | Not M14. Installing is dropping a `.fpk` in `mods/`, and the screen shows where that is | Not taken |
| Categories, separators, notes | Not M14 | Not taken |

**What Foundry adds:**
1. **The effective order.** The list shows the order the next start will load, not only the order
   the player asked for. A mod the player dragged above its own dependency stays after it, and
   its row says why: "after The Room, which it requires". MO2 has no dependencies to show.
2. **Exact conflicts.** Content ids make "who wins" a fact, not a heuristic over file paths. The
   Records tab answers "why does the hall look different?" by naming every package providing
   `room:textures.room` and the one that won.
3. **Pending changes, said out loud.** Changes apply at the next start (§8). A bar at the bottom
   counts them and offers Revert. MO2 is a launcher, so it never needs to say this.
4. **Native code is visible and consented to per version.** A mod carrying a native library has a
   badge. A host that loads native code asks once per package version, on its own screen and
   never through a mod. A host that loads none says so.
5. **Broken mods explain themselves.** A skipped mod names what it needs and the version range it
   asked for, or the cycle it is in. Two copies of one mod are both listed with their files, and
   neither loads. That used to stop the game from starting (§4).
6. **The manager is content-skinned.** Its theme and every string are records in the game's
   package, so a mod can re-skin or translate the screen that manages it.
7. **Required packages are pinned.** `foundry:core` and the game's own package sit at the top,
   locked, as MO2 greys out the base game's plugins.

## 4. The mod set

One engine object answers every question the screen, the ABI and startup ask. The name is
illustrative:

```zig
// app/mods.zig
pub const ModSet = struct {
    /// Discovery of each host-granted root, with the root's origin.
    pub fn discover(gpa, os, roots: []const Root, required: []const ContentId, diags) !ModSet;
    /// The request the host starts its engine with: the active profile's order, then any
    /// developer override, which is never saved.
    pub fn startupRequest(self, extra: []const ContentId) mod.Request;

    pub fn installed(self) []const Installed;        // every candidate, with its state
    pub fn pending(self) *const Selection;           // what the next start will use
    pub fn preview(self) *const mod.Resolution;      // `pending` resolved; cached until it changes
    pub fn conflicts(self) *const Conflicts;         // over `preview`'s order; cached likewise

    pub fn setEnabled(self, id: ContentId, on: bool) !void;
    pub fn move(self, id: ContentId, to: u32) !void; // an index into the player's list
    pub fn revert(self) void;                        // pending := the saved profile
    pub fn apply(self) !void;                        // write the profile; takes effect next start
    // Profiles: list, create, copy, rename, delete, select (§5).
    // Consent: host only, never published (§8).
};

pub const Origin = enum { installed, user };
```

- **Roots carry origin.** The host assigns each discovery root an origin: installed content or
  the user's `mods/`. That origin is host authority (ADR-0031), never manifest data.
- **Required packages are not a choice.** `foundry:core` and the game's own package are host
  bootstrap. They never appear in a profile, always load, and are shown locked. A missing or
  skipped required package stays fatal.
- **The player's order is the list.** No new ordering algorithm is needed. `mod.resolve` already
  keeps the player's order wherever the dependency graph allows. `move` accepts any position;
  the preview shows where the mod actually lands and why.
- **Duplicates stop being fatal for user packages** (ADR-0040):
  - Two installed candidates with one id is a broken install, and still fatal.
  - A user package claiming an installed package's id is skipped, and the installed one loads.
    Replacing a package is not content override; ADR-0031 keeps it separately designed.
  - Two or more user packages with one id are all skipped, each named with its file, and none
    loads.

  A player who copies a mod twice gets a game and a message, the rule `public-abi.md` §12.1
  already applies to every other broken mod.
- **The developer override stays.** `FOUNDRY_ROOM_PACKAGES` and `FOUNDRY_SANDBOX_PACKAGES` are
  appended after the profile for that session only. They are never saved, and the screen marks
  those packages as enabled by the environment.
- **Both samples move to it.** The duplicated discovery code in each sample is deleted. That
  deletion is the evidence the object is the right one, as `blankRegion`'s was at M6.

## 5. Profiles on disk

A **profile** is a named, ordered selection. It holds, in the player's order, the ids of the
packages they enabled, and the native-code consents they gave (§8). It holds nothing else in M14:
settings stay global, and saves belong to the game.

- **One file per profile**, at `<user-data>/profiles/<key>.fset`. It uses the settings
  envelope, with an engine-registered profile schema, so it is the same format, validation and
  atomic write rather than a second one. Separate files let two instances edit different
  profiles without touching each other, and keep a large mod list within its own bounds rather
  than the settings file's 64 KiB.
- **The key is a number the engine assigns**, the smallest unused from 1. The player's display
  name is data inside the file, bounded and validated as UTF-8, and never becomes a path. A name
  typed into a filename is a path-traversal bug waiting for its first creative player.
- **Settings record which profile is active**, as a key. A missing or unreadable active profile
  falls back to the first readable one, then to a fresh "Default", with a warning. A game always
  starts.
- **Bounds:**
  - 1,024 enabled entries and 256 consents per profile;
  - 256 KiB per profile file;
  - 64 profiles.

  A profile past its bounds is refused with a diagnostic and left untouched, as a malformed
  settings file already is.
- **Order is stored as given.** The list is deduplicated, never sorted. This supersedes
  `distribution.md` §5's canonical sort for the enabled list (ADR-0040): the order is the player's
  override decision, and sorting it away made ADR-0027's "the manual list survives as an
  override" untrue after the first save. Other settings fields keep their canonical form.
- **Operations:** create (empty, or a copy of another), rename, delete (never the last), and
  select. Selecting another profile changes the pending selection, so it too applies at the next
  start (§8).

## 6. Migrations and concurrent writes

**Migrations.** An application registers one explicit conversion from each older schema
version to the next, `v1 → v2 → … → current`:
- A file at an older version is converted in memory at load. Nothing is written until the
  application saves.
- Before the first write at the new version, the old file is copied once to
  `settings.fset.v<old>`. A player who downgrades can put it back.
- A conversion is ordinary code over the old version's field values. There is no generic
  schema-diff machinery, which would be a framework guessing at intent.
- A future version stays read-only to an older build, exactly as now.

The profile schema follows the same rule.

**M14 supplies the second schema version itself**, which is what makes this milestone's exit
criterion honest rather than hypothetical. Each sample's settings schema goes from v1 to v2:
- `enabled` leaves settings, and a `profile` key arrives;
- the v1 → v2 conversion writes v1's enabled set into a new "Default" profile and makes it
  active;
- it does so only when no profile exists yet, so running it twice creates nothing twice.

v1 sorted its list, so "Default" starts in content-id order; the player's order is preserved
from then on. Window size and volume carry over untouched. The tests read real M9-era v1 files
kept as fixtures.

**Concurrent writes merge by field.** A save re-reads the file as it is now. At the same schema
version, it writes that file's values with only the fields this process changed laid over them.
At an older version, it migrates the file first. At a newer version, it writes nothing, as now.
Then it replaces the file atomically. So two running instances no longer undo each other:
- one changes the volume, and the other the active profile, and both survive;
- two instances changing the same field is still last-writer-wins, and documented.

There is no lock file. The window between re-reading and replacing is milliseconds, the worst
outcome is one field's last-writer-wins, and a lock that must survive crashes is a larger problem
than the one it solves. Profiles merge the same way: name, enabled list and consents are separate
fields.

## 7. Conflicts

Computed over the preview's order, never by loading anything. For each package in the order, the
record table of its `.fpk` lists the content ids it provides. Any id provided by two or more
packages is a conflict, and **the last in load order wins**: that is the whole override rule, so
the report is exact rather than estimated.

Per package, the report gives:
- **wins**: records this package provides that override an earlier one;
- **loses**: records a later package overrides;
- **redundant**: every record it provides is overridden, so it contributes nothing. MO2's grey
  flag.

Per record, the report gives the chain of providers in load order. Records a package provides
and nobody else does are counted, not listed.

What is not a conflict:
- **The manifest.** A package's manifest record id is the package's own id, so it cannot
  collide.
- **Additive schema extension.** A package extending another's schema additively
  (`public-abi.md` §11.3) is shown as information, because it adds fields and replaces nothing.

When `@patch` exists, a patch becomes a third relation beside replace and extend. The report's
shape leaves room for it and does not invent it now.

**Cost.** One read of each enabled package's record table when the preview changes, bounded by
`data.Limits`. It is cached until the pending selection changes. The screen emits only visible
rows (`debug-overlay.md` §11), so a total-conversion mod overriding thousands of records costs
what fits on screen.

## 8. Applying a selection, and native consent

**Changes apply at the next start** (ADR-0040). The running session keeps the order it started
with, as `distribution.md` §5 already requires. That order is shown as "loaded now" beside the
pending one. Applying writes the profile, and the screen then says how many changes wait for the
next start. Three facts make live application a different milestone rather than a feature:
- **Content** would have to be rebuilt around a live world whose entities name records that
  vanish.
- **Scripts** would need per-package start and stop outside their reload path.
- **Native libraries** are never closed, so a disabled native mod could not leave.

A later design may apply content-only and script-only changes live. Nothing here forecloses it.

**Native consent.** A package whose manifest names a native library carries a badge.
- A host that loads native code asks before the first start that would load it, on a screen of its
  own, naming the package, its version and the library. The consent is recorded in the profile as
  `(id, version)`, so a new version asks again.
- Consent is never given by content, by settings copied from elsewhere, or through the ABI. It is
  the host's authority (ADR-0031), as the decision to load native code at all already is.
- A host that loads no native code, like both samples, shows "this game does not load native
  code". The mod's content still loads, as `public-abi.md` §14 requires.

## 9. The public API

I4: the room's screen may use nothing a mod could not. The capability is published additively as
**`FoundryApi_v3`**: v2's calls unchanged and in place, new ones appended, v1 and v2 byte-identical.
Names are illustrative in shape and exact in prefix, as in `public-abi.md` §9.

**`mods_*`**, answered when the host supplies its `ModSet` to `abi.Host` (ADR-0026):
- **Reading:**
  - `mods_installed_next`: id, name, version, origin, flags (required, native, scripts,
    duplicate), loaded now, pending enabled, pending position and skip reason;
  - `mods_conflict_next` for a package;
  - `mods_provider_next` for a record;
  - `mods_profile_next` and `mods_profile_active`.
- **Changing** the pending selection or profiles: `mods_set_enabled`, `mods_move`,
  `mods_revert`, `mods_apply`, and `mods_profile_create`, `_copy`, `_rename`, `_delete` and
  `_select`. These answer `FOUNDRY_ERR_REFUSED` unless the host granted writes when it supplied
  the set. That is one grant for the host, not per-mod policy, so `public-abi.md` §18 Q4 stays
  open.
- **Never published:** consent, and any path. A mod may learn what is installed; it may not learn
  where, or approve native code.

**`ui_*`**, per ADR-0041:
- `ui_theme_resolve(content_id, FoundryTheme *out)` returns a handle valid for the current
  content generation. A reload makes it stale, and a stale handle is refused (I1).
- `ui_theme_push` and `ui_theme_pop`.
- The new widgets: `ui_tabs`, `ui_selectable`, the reorder-list calls, `ui_icon`, `ui_image`, and
  `ui_begin_disabled` and `ui_end_disabled`.

**Lua gains nothing in M14.** `scripting.md`'s binding is a validated subset of the table, and
adding to it is an additive later decision.

## 10. The game widget set

ADR-0024's second widget set, decided by ADR-0041.

**The kernel stays at L1 and gains three additive things**, the kind `ui.md` §14 anticipated:
- **`image`**: a rectangle drawn from a region of an image, with a tint;
- **`nine_slice`**: a rectangle drawn from a region cut by four insets, so corners keep their
  size, edges stretch one way and the centre both;
- **a disabled scope**: `beginDisabled`/`endDisabled`. Widgets inside are drawn with the
  disabled look and take no hover, press or focus.

An image is named by an **opaque `u32` the caller defines**, never by a texture handle. The kernel
still sees no renderer, and the walker resolves the reference through a table the caller passes.
Neither command measures text, so the walker's own tests cover them rather than the drift test.

**A theme is content.** It is a record of an engine-declared schema `foundry:ui_theme`,
registered at runtime beside `foundry:texture`, and ships in the game's package. Any later package
may override it. In sketch:

```
@schema ui_theme {
    atlas        id                 # a foundry:texture holding every patch and icon
    font         { texture id  cell_w u32  cell_h u32  columns u32  first u32  count u32 }
    text_scale   f32
    line_height  f32   padding_x f32   padding_y f32   spacing f32
    colors       { text dim accent positive negative warning selection surface … }
    patches      [{ part string  x u32  y u32  w u32  h u32  left u32  top u32  right u32  bottom u32 }]
    icons        [{ name string  x u32  y u32  w u32  h u32 }]
}
```

- **Part names are fixed:** panel, button, button_hot, button_active, button_disabled, field,
  check_off, check_on, row, row_selected, tab, tab_on, scroll_track and scroll_thumb.
- **Icon names are the game's own:** native, script, win, lose, both, redundant, warning and
  lock in the room's theme.
- **The names are a compatibility decision** (`CLAUDE.md` §7). ADR-0041 fixes them once.

**`app` resolves a theme** into a `ui.Skin` value and the walker's image table:
- It looks up the textures by content id and the font through `app.UiFont`, the one sanctioned
  producer of font metrics.
- A record that fails validation is a warning and the debug style, never a failed frame, which is
  `uiSolidRegion`'s rule.
- It resolves again when the content generation changes, so hot reload re-skins a running
  screen.

**The widgets.** Every existing widget draws from the skin when a theme is active, with a patch
where the theme has one and the flat colour where it has none. Interaction stays one function per
widget, and only the drawing differs between the two sets. New widgets:
- **`tabs`**: a row of tabs, returning the selected index;
- **`selectable`**: a row that knows it is selected;
- **the reorder list**: rows with a grip. A drag shows an insertion line and returns
  `move(from, to)` on release. Up, Down, Top and Bottom buttons do the same without a drag.
- **`icon`** and **`image`**.

Drag within one list is this widget's own gesture. Drag-and-drop *between* widgets stays out
(`ui.md` §15).

**What stays out, and open:**
- layouts authored as content, and whether their widget ids derive from content ids (`ui.md` §14);
- keyboard and gamepad navigation;
- popups, tooltips and any overlay layer;
- sortable or resizable columns;
- multi-line text.

The room's screen needs none of them. Its profile control is a strip, not a dropdown; its help is
a status line, not tooltips; and its consent screen replaces the page rather than floating over
it.

## 11. The room's mod screen

`M` opens it and Escape closes it. The hall keeps running behind it, as behind the card, and the
screen takes the pointer and keyboard by the same capture rules. At 1280×720:

```
┌ Mods ── Profile ◀ Default ▶  [New] [Copy] [Rename] [Delete] ──────────────────────── [Close] ┐
│ Filter [______________]         6 installed · 3 on · 1 problem  │ [Details][Conflicts][Records][Problems 1] │
│  #   on  Name                       Version  Origin    ⚑          │ Brighter Lamps                           │
│  ·   🔒  Foundry core                   1     built-in             │ brighter:content · version 3 · MIT      │
│  ·   🔒  The Room                       1     built-in   −         │ Requires  The Room ≥ 1   ✓               │
│  1   ☑   Brighter Lamps                 3     user       +         │ Provides  14 records, 3 textures         │
│  2   ☑   Night Palette                  1     user       ±         │ Wins 4 · Loses 2                         │
│  3   ⚠   Broken Thing                   1     user                 │ Loaded now: yes                          │
│      needs Lamp Kit, which is not installed                        │                                          │
│      ☐   Old Lamps                      2     user                 │                                          │
│  [Up] [Down] [Top] [Bottom]                                        │                                          │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│ 2 changes take effect the next time the hall opens.  [Apply] [Revert]   Drop mods into …/mods │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Left:**
  - the mod list: required packages locked at the top, then the player's list in effective order;
  - a checkbox, name, version, origin and conflict flag on each row;
  - drag, or the four buttons, to reorder, and a filter by name or id.

  Selecting a row tints the rows it beats and the rows that beat it.
- **Right:**
  - **Details:** the manifest, requirements with their status, the provides/wins/loses counts and
    whether the mod is loaded now;
  - **Conflicts:** each record in dispute, the other package and the winner;
  - **Records:** type an id and see its whole provider chain;
  - **Problems:** skips, duplicates and dependency failures.
- **Bottom:** the pending bar with Apply and Revert, and where to put mods. That path is the
  host's, shown as text; the ABI never gives it out.
- **Content:** every string comes from the room's own package, so a translation replaces it. The
  look comes from `room:ui.theme` and a small atlas in the room's package.
- **The autopilot visits the screen** once, as it visits the card. It changes and reverts a
  pending selection without saving, so a scripted run checks that no click or keystroke meant for
  the screen reaches the hall.

The sandbox moves to the mod set, profiles and migration, with no screen. It keeps its overlay,
and its environment switch for automation.

## 12. Verification and completion

The AGENTS.md bar at every step, with focused tests first. Each new invariant's test is made to
fail once by a local mutation, then restored. A documentation consistency pass happens at the end
of each step. The distinct evidence M14 owes:
- **Resolution and conflicts:**
  - discovery order shuffled, with the preview and conflict report byte-identical;
  - the last provider wins;
  - redundant packages found;
  - each duplicate rule, and required packages still fatal.
- **Profiles:**
  - bounds, hostile and truncated files, and names that are not valid UTF-8;
  - the smallest-free key, and deleting the last profile refused;
  - order preserved through save and load;
  - consent keyed by version.
- **Migrations:**
  - the real M9-era v1 fixtures for both samples converted, with the backup written once;
  - a second conversion creating nothing;
  - a future version untouched.
- **Concurrent writes:** two `Storage` handles interleaving saves of different fields and both
  surviving; the same field last-writer-wins; a newer file never overwritten.
- **Kernel and widgets, headless:**
  - golden draw lists for `image`, `nine_slice` and a disabled scope;
  - tabs, selection, and reorder by drag and by button;
  - capture over the screen.
- **Themes:** a valid theme resolves; each malformed field falls back with one warning; hot
  reload re-skins; a later package's theme wins.
- **ABI v3:**
  - header agreement for v1, v2 and v3;
  - the garbage sweep and the empty host;
  - writes refused without the host's grant;
  - consent and paths absent.
- **Windowed:**
  - the room's screen captured on Metal;
  - at closure, on Windows through Vulkan from a relocated install in the desktop session, with
    the owner's go (AGENTS.md's Windows rules).

**Exit proof.** A ReleaseSafe room `dist`, with a user-data root holding:
- an M13-era v1 `settings.fset` naming one enabled mod;
- that mod, plus a second one in `mods/`.

The proof then runs in order:
1. The new build migrates the file: "Default" holds the first mod, and size and volume are kept.
2. A player opens the screen, turns the second mod on with a click, and applies.
3. On the next start, the second mod is in the load order and visibly changes the hall.
4. A theme mod re-skins the screen.
5. Two instances at once keep each other's changes.

Mods are built outside the tree, as M7's and M8's exit proofs were.

## 13. Implementation order — nine bounded steps

Each step stops with its Resolution, PROJECT_STATE update, verification and commit; there is no
automatic chaining.

### Step 1 — The mod set, headless

`app.ModSet` over host-granted roots with origin, and conflicts in `mod` from record tables. The
duplicate rules of ADR-0040 go in, and both samples move to the mod set and delete their copies
of discovery. Behaviour is unchanged apart from duplicates. **Exit:** determinism, conflict and
duplicate tests, and both samples starting on the mod set.

### Step 2 — Profiles on disk

The profile schema and files: keys, bounds, create, copy, rename, delete and select, the ordered
list and consents. Settings gain the active profile key. **Exit:** the samples start from their
active profile, hostile files are refused, and order survives a round trip.

> **Re-scoped 2026-09-19, when Step 2 began.** A settings schema cannot gain a field inside its
> version. Fields sit at offsets behind a presence bitmap whose width is the field count, so the
> field has to arrive as version 2. `app.settings` reads a file of any other version as
> `PastVersion` and keeps it read-only. So without Step 3's migration, giving the samples an
> active-profile key would stop every existing preferences file from being read or written.
>
> The samples' adoption therefore moves to Step 3, where their v2 schema and its migration land
> together, and this step's exit criterion moves with it.
> - **Step 2** builds the profile files and their operations as engine capability, with the mod
>   set starting from, switching and applying a profile. The host passes the active key in.
>   **Exit:** hostile files refused, order and consents surviving a round trip, keys and bounds,
>   all in headless tests.
> - **Step 3** adds the samples' settings v2 with the active key, and the samples starting from
>   their active profile.

### Step 3 — Migrations and concurrent writes

The migration chain with its backup, and the samples' v1 → v2 conversion over real fixtures.
Merge-on-write for settings and profiles. Since the re-scope above, also the samples' active
profile key and their start from it. **Exit:** fixtures convert, two writers keep each other's
fields, future files are untouched, and the samples start from their active profile.

### Step 4 — The kernel's additions

The `image` and `nine_slice` commands with opaque image references, and the disabled scope. The
walker draws both. **Exit:** golden draw lists and walker tests for both commands.

### Step 5 — Themes as content

The `foundry:ui_theme` schema, the resolver into `ui.Skin` and an image table, fallback and
reload. The room gains its theme and atlas. **Exit:** valid, malformed, reloaded and overridden
themes behave as §10 states.

### Step 6 — The game widget set

Skinned drawing for the existing widgets, and the new `tabs`, `selectable`, reorder list, `icon`
and `image`. **Exit:** headless interaction tests for each, capture included.

### Step 7 — The public API

`FoundryApi_v3`: the `mods_*` calls, the theme calls and the new widgets, with the host's write
grant. `foundry.h`, the agreement tests, the sweep and the empty host, and `docs/modding` updated.
**Exit:** v1 and v2 byte-identical, v3 agreed, and writes refused without the grant.

### Step 8 — The room's mod screen

The screen of §11, built only from Steps 1–7, with its strings and theme as content. The
autopilot visits it. **Exit:** captures of the screen on Metal, and the scripted visit with no
capture failure.

### Step 9 — Prove and close

The exit proof of §12, and the Windows run with the owner's go. `CLAUDE.md`, AGENTS.md,
PROJECT_STATE, the roadmap, README, the design index, `public-abi.md`, `ui.md` and
`distribution.md` updated, and ADR statuses set. Commit, tag `m14`, and stop before M15.
**Exit:** a player, not an environment variable, turned a mod on in a packaged sample, and their
choices survived a schema change.

## 14. What stays open

M14 settles only what its work forces, per the standing instruction. Everything below stays
open:
- **From `ui.md` §14:** keyboard navigation and tab order; content-authored layouts and whether
  their widget ids derive from content ids; popups, tooltips and an overlay layer; multi-line
  editing.
- **From `public-abi.md` §18:** unloading and native hot reload (Q2), a mod's own storage (Q3),
  per-mod tables and per-mod policy (Q4), and what a mod may learn about its host (Q5).
- **From ADR-0027:** a load order remembered per save rather than per installation, and a
  version solver. Saves still do not record the package set they were made with.
- **Live application of a changed selection**, and a host restarting itself to apply one.
- **`@patch` and `@remove`**, and with them a third conflict relation.
- **Installing and updating mods** from anywhere but the `mods/` folder, and knowing that a newer
  version of an installed mod exists.

## 15. Planning references

- Mod Organizer 2's own documentation, for the conventions §3 borrows: the mod list's priority
  order, conflict flags, profiles and the data view. It was consulted for behaviour, not code;
  MO2 is GPL-3.0 and nothing from it enters the tree (ADR-0016).
- `public-abi.md` §§11–14 and its `mod` Resolution; `distribution.md` §§5–7 and its step
  Resolutions; `ui.md` §§7–15 and its step Resolutions; `debug-overlay.md` §11.

## Resolution — 2026-09-19, planning only

The owner asked for M14's documents, with a UI modelled on MO2 and Foundry's own additions where
one was needed. One is needed. The exit criterion wants a player to turn a mod on in a packaged
sample, and the roadmap assigns the game widget set to this milestone. The screen lives in the
room, and the engine owes the capability beneath it.

Two decisions are proposed rather than taken:
- **ADR-0040** makes the selection an ordered profile applied at the next start. It changes two
  recorded rules: `distribution.md` §5's sorted canonical write, and `public-abi.md` §12.1's fatal
  duplicate for user packages. It also answers ADR-0031's profile revisit.
- **ADR-0041** makes themes content and adds three things to the kernel, which ADR-0024 and
  `ui.md` §14 anticipated.

No code changed. The bar was run for this documentation-only change.

## Resolution — 2026-09-19, the design accepted

The owner accepted ADR-0040 and ADR-0041 as written, the same day. The records they change now
carry dated notes:
- ADR-0024 and ADR-0031;
- `public-abi.md` §12.1, for the duplicate rule;
- `distribution.md` §5, for the enabled list;
- `ui.md` §14, for the draw commands.

`CLAUDE.md` §4.1 indexes both ADRs. The code still behaves as those records described until the
steps that change it land. No code changed, and Step 1 is next.

## Resolution — 2026-09-19, Step 1: the mod set

**Landed.** `mod` gained the three things the mod set needs, and `app.ModSet` joins them:
- **Origin.** `mod.Origin` (`installed`, `user`) is stamped on every candidate by the host's
  discovery call and never read from a package. It defaults to `installed`, so a caller that
  never says keeps every duplicate fatal.
- **ADR-0040's duplicate rules**, in `mod.resolve`. Two installed candidates with one id stay
  `DuplicatePackage`. A user candidate claiming an installed id is skipped as
  `shadows_installed`, and user candidates sharing an id are all skipped as `duplicate`. These
  are reported whether or not anything enabled them, since they are faults in what is installed.
  A dependent of a duplicated id is `dependency_skipped`, whatever range it asked for. A `Skip`
  now carries its copy's `base_dir` and `file`, the only way to tell two copies apart.
- **Conflicts**, as `mod.conflicts` over a load order. Each package's `.fpk` record table is read
  alone, with the manifest record left out. Per package, the report gives provides, wins, loses
  and `redundant()`. Contested records are listed by spelling, each with its providers in load
  order. `providers(id)` answers any record, contested or not, which the Records tab will need.
  A package that can no longer be read is a diagnostic, and `readable = false`.
- **`app.ModSet`** takes host roots with their origins and the required ids. It offers
  `restore`, `start`, `loaded`, `environment`, `pending`, `changed`, `isEnabled`, `setEnabled`,
  `move`, `revert`, `preview`, `conflicts` and `contentPackages`, plus `app.mods.userRoot`.
  Preview and conflicts are cached until the pending selection changes, and nothing changes what
  `start` loaded. `app` gains `mod` in the build graph, which L4 allows.
- **Both samples moved to it.** Their copies of discovery, resolution and package copying are
  gone. Each names `foundry:core` and its own package as required, restores the saved selection,
  appends its environment override and starts. The room no longer imports `mod` at all.

**Decided by the implementation, within the accepted records:**
- **Resolution iterates a canonical order.** Candidates are sorted by id spelling, origin, root
  and file before anything else. That fixes three answers that had followed discovery order: the
  order skips were listed in, which failing dependency a skip named when two failed in one pass,
  and which duplicate a diagnostic named. The old determinism test compared only the load order,
  so none of it showed. The new test shuffles every kind of outcome twelve ways and compares the
  whole resolution and every diagnostic, byte for byte.
- **Diagnostics name a copy by whose root it is**, as in `mods/twice.fpk` or
  `installed/room.fpk`, and never by an absolute path. The samples now log the diagnostics of a
  fatal resolution before failing, where before they dropped them, so the installed-duplicate
  message reaches the session log. The log collects no home paths (`distribution.md` §10).
- **The game's own package is required**, as §4 says. Its load position is unchanged; a missing
  one now stops the sample instead of producing a warning and a room with no content.
- **The preview includes the environment override.** The next start in the same environment
  applies it too, and leaving it out would count every environment package as a pending change.
  `pending` and `changed` never include it.
- **Enabling appends to the end of the player's order; disabling forgets the position.** That is
  ADR-0040 decision 1: a profile holds enabled ids and nothing else. §11's mock numbered a
  disabled row, contradicting it, and now lists disabled mods unnumbered after the order.

**Evidence.** The bar passed, **1,405 of 1,406** with the one skip it had before. Focused tests:
- `mod`: the three duplicate cases, a required package the player duplicated staying fatal, the
  shuffled resolution, and three conflict tests: the last provider winning with every count, the
  player's order moving winners under rotated discovery, and an unreadable package.
- `app.ModSet`: two roots with duplicates starting the game; edits changing the preview and the
  conflicts but never what loaded; the environment override; roots in either order giving
  byte-identical previews and conflicts.

Three mutations were each caught, then restored byte for byte:
- dropping the canonical sort failed the shuffle test;
- reversing provider order failed all three conflict tests;
- leaving the environment out of the preview failed its test.

A throwaway mod was built outside the tree into a temporary `HOME`, as two copies alongside a
copy of `room.fpk`. The room started, printed three warnings naming both files each time, and
loaded `foundry:core` and `room:content`; the old rule refused every duplicate. A second copy of
`room.fpk` in the installed directory still stopped it, naming both files.

**Unchanged.** Settings still store the sorted `enabled` set, the saved selection is still read
from it, and a headless run still reads no user packages unless asked. There is no profile,
no ABI surface and no screen yet. Step 2, profiles on disk, is next.

## Resolution — 2026-09-19, Step 2: profiles on disk

**Re-scoped first, as §13's note records.** A settings schema cannot gain a field inside its
version, and `app.settings` keeps a file of any other version read-only. So the samples' active
key waits for Step 3's migration, and this step built the capability without them.

**Landed:**
- **`app.profiles`** holds the engine's `foundry:profile` schema, version 1, with fields `name`,
  `enabled` (spellings, ordered) and `consents` (`id`, `version`). Files use the settings
  envelope at `<user data>/profiles/<key>.fset`. A `Store` lists, reads, writes and removes them.
  - The bounds are ADR-0040's: 64 profiles, 1,024 enabled, 256 consents, 256 KiB per file, and
    64 bytes of name. A name must be UTF-8 with no control characters.
  - Only a canonical key between 1 and 64 is a profile. `007.fset`, `65.fset` and
    `3.fset.bak` are not.
  - A profile read from disk is refused whole, and left untouched, when it is past a bound, has
    no usable name, or repeats an id or a consent. A write refuses the same contents, so the
    store never writes what it would not read back. A write also never replaces a file another
    build wrote, and copies a damaged one aside first, as a settings file does.
- **`app.ModSet` gained profiles**, and a table of every id's spelling, because a profile names
  packages by spelling and an uninstalled one still has to be written back. `restore` now takes
  spellings.
  - `attachProfiles(store, active, fresh_name)` starts from the host's key. A key that cannot be
    used falls back to the first usable profile, then to a fresh one, with a warning.
  - `selectProfile`, `createProfile` (empty, or a copy), `renameProfile`, `deleteProfile`,
    `apply`, `savedProfile`, `pendingProfile` and `profileList` manage them.
  - `consented` and `setConsent` hold consent per `(id, version)`. The ABI never reaches them.

**Decided by the implementation:**
- **Nothing is written by starting.** A first run's fresh profile lives in memory, listed like
  the others, until the player applies, renames or copies it. A scripted run leaves no file, and
  a first run with no key and no profiles says nothing. A run that may not write keeps every
  change in memory, and `apply` answers `ReadOnly`.
- **Managing profiles is immediate; choosing one is pending.** Create, copy, rename and delete
  change files at once, as MO2's do. Which profile is active, and its selection and consents,
  wait for `apply`. Selecting another profile drops unapplied edits to the current one, and
  selecting the saved one again is `revert`.
- **Neither the saved profile nor the pending one can be deleted.** So the last one never can
  be, which is §5's rule without a separate count.
- **A copy is what the player sees.** Copying the pending profile includes its unapplied edits.
- **The fresh profile's name is the host's**, passed to `attachProfiles`, because it is a string
  a player reads and a translation replaces (I5).

**Evidence.** The bar passed, **1,415 of 1,416** with the one skip it had before. The new tests
cover:
- the profile store: a round trip keeping order, consents and a name full of path separators,
  in a file named `1.fset`; keys and canonical names; eleven hostile files, each refused or
  kept, and all byte-identical afterwards; a run that may not write;
- the mod set: starting from a key, from a missing one and from a damaged one; the silent first
  run that writes only on apply; select, revert and apply, with the player's order written
  unsorted and read back; create, copy, rename and delete, with in-use refusals and key reuse;
  consent by version, and a set with no profiles refusing to apply; a read-only run.

Two mutations were each caught, then restored byte for byte:
- dropping the repeated-id check failed the hostile-profile test;
- sorting the list on write failed the round-trip test.

**Unchanged.** The samples still read their sorted `enabled` settings, now handed to `restore` as
the spellings they are, and never attach profiles.
That is Step 3, with the migration that makes it safe. Merge-by-field writes are Step 3's too;
until then a profile write replaces the file whole.

## Resolution — 2026-09-19, Step 3: migrations, concurrent writes, and the samples on profiles

**Landed:**
- **`app.settings.Migration`:** one explicit conversion per older version, `from` schema plus a
  `convert` over its values, listed oldest first. There is no schema diff.
  - `Storage.load` converts an older file in memory through the whole chain and records
    `migrated_from`. It keeps the original bytes, and `File.older` reads them against an old
    schema.
  - A chain that does not reach the current version converts nothing, and the file is kept,
    exactly as before.
  - A malformed older file counts as damaged, as a current one does.
- **Saves merge by field.** `Storage.save` re-reads the file first and takes a baseline, what the
  process read or last wrote. A field whose value still equals the baseline is one this process
  did not change, so the file's current value is kept.
  - `File` holds the baseline and moves it to what it wrote after each save.
  - A file that is older at save time is converted first, then copied once to `<leaf>.v<old>`.
    That copy is not best effort: if it cannot be kept, nothing is replaced.
  - A newer file is still never replaced.
- **Profiles merge the same way.** `profiles.Store.write` takes a baseline. `ModSet.apply`
  writes the enabled list and the consents only when this process changed them, and never the
  name. `renameProfile` writes only the name.
- **Both samples are on version 2 and profiles.**
  - `enabled` left settings, and `profile` arrived. Version 1 is kept verbatim, with a
    conversion that carries the window and the volume.
  - `Preferences.attachProfiles` finishes the move. Version 1's list becomes the fresh
    "Default" through `ModSet.attachProfiles`, and a run that may write saves it with
    `saveFresh`. The move happens only when no profile exists, so a second start creates nothing.
  - A headless run still reads no user data, so it has no profiles.
- **The samples have tests.** `zig build test` and `zig build check` now build both samples'
  own tests, because the only honest test of a sample's conversion runs the sample's code.

**Decided by the implementation:**
- **The conversion only maps values; the host moves the list.** A conversion is a pure
  function, and it may run again when a save finds the file older. Creating a profile is a side
  effect, so it belongs to the host, which reads the old list through `File.older` and hands it
  to `attachProfiles`. The profile is written at startup, before settings are ever saved, so
  that a start which never saves still finds it. That is the one write a start makes, and only
  a run that may write makes it.
- **The fixtures are M9's own bytes.** They were written by M9's `app.settings.Storage.save`,
  from a worktree of tag `m9`, with the samples' version 1 schemas. Between `m9` and this step,
  `settings.zig`, `fpk.zig` and `value.zig` had not changed.
- **Merging is by field equality, not by change tracking.** A field is "changed" when the
  in-memory value differs from the baseline. A preference cleared in memory is a change, which
  is why a caller resolves before it saves.
- **AGENTS.md's test-count formula is corrected.** It had counted every declaration since the
  Vulkan tests arrived, so it no longer matched the quoted headless number, and it now includes
  `samples`.

**Evidence.** The bar passed, **1,421 of 1,422**, with the one skip it had before.
- `app.settings`: a version 1 file converted through two steps to version 3, loading writing
  nothing, the backup kept once across a later conversion, an older build refused over a newer
  file, and a broken chain kept.
- Two writers keeping each other's fields, the same field going to the last writer, and a newer
  file never replaced.
- `app.ModSet`: a moved selection becoming the first profile exactly once, and two instances
  editing one profile keeping each other's changes.
- Each sample: its M9 fixture keeping window, volume and mods through the move, the settings
  file untouched until a save, the save writing version 2 beside a byte-identical `.v1`, and
  the next start creating nothing more.

Three mutations were each caught, then restored byte for byte:
- turning merging off failed both two-writer tests;
- re-copying an existing backup failed the backup check;
- dropping the volume from the sandbox's conversion failed its sample test.

The real Metal room was started against the M9 room fixture, with the two mods it names built
outside the tree into a temporary `HOME`. It converted the file, opened at 1600×900 with volume
0.25, and loaded both mods in version 1's order. Being frame-limited, it wrote nothing: the
settings file stayed byte-identical and no profile directory appeared. The sandbox did the same
with its own fixture.

## Resolution — 2026-09-19, Step 4: the kernel's additions

**Landed, in `ui` at L1 with nothing new linked:**
- **The two commands.** `image` stretches a rectangle of an image over its bounds.
  `nine_slice` cuts a rectangle by four insets, and carries a `scale` of screen units per image
  pixel for its borders.
  - Both name the image by `ui.ImageRef`, an opaque `u32` the caller numbers, and carry numbers
    only.
  - `DrawList.addImage` and `addNineSlice` record nothing for empty bounds, an empty source, or a
    scale that is not a positive finite number.
- **`ui.nineSlice`**, the cut as pure arithmetic.
  - Corners keep their size, edges stretch one way, and the centre both.
  - Insets past the source are clamped to it, left and top first. Borders too wide for the
    bounds shrink in proportion.
  - A source past the end of `u32` cuts to nothing instead of overflowing.
- **The disabled scope.**
  - `beginDisabled`, `endDisabled` and `isDisabled`. Scopes nest, an unmatched end is a warning,
    and a scope left open ends with the frame.
  - A widget inside takes no hover, press or focus. `Interaction.disabled` says so, and one
    disabled mid-drag or while focused lets go.
  - It still keeps the pointer from the game, and it hides what is under it from the pointer.
  - What it draws is faded by `Style.disabled_alpha` through `DrawList.fade`.

**Landed in the walker (`app.drawUi`).** `UiDrawOptions.images` is the caller's table: the
texture at each `ImageRef`'s index. An image is one sprite from its rectangle, and a nine-slice is
up to nine sprites. A number past the table, a texture no longer loaded, or a rectangle not wholly
inside its texture draws nothing, without a word, as `solid` already did, because this runs every
frame. A nine-slice reaching past its image draws none of itself rather than the pieces that fit.

**Decided by the implementation:**
- **The cut belongs to the kernel, and the texture coordinates to the walker.** The geometry is
  the part worth testing, and in the kernel it tests with nothing linked. The walker only turns
  pixels into texture coordinates against the texture it resolved.
- **The disabled look is a fade, applied where commands are recorded.** Every widget, and every
  later one, looks disabled without being told how. The amount is style, per ADR-0024. Step 6's
  skinned widgets may draw a `button_disabled` part instead.
- **A disabled widget is not a hole.** Stopping hover and press is not enough: a click on a
  greyed-out button must not reach the game, or the widget under it.
- **The overlay's batch model now names what it does not model.**
  `engine/tests/overlay_batches.zig` reproduces the walker's batching for the debug overlay,
  which draws no images. It now panics with a message on an image command, rather than
  attributing batches it was never written for.

**Evidence.** The bar passed, **1,432 of 1,433** with the one skip it had before. The new tests
cover:
- golden lists for both commands and for a disabled scope;
- the cut's corners, edges, centre, exact tiling, proportional shrink, clamping and overflow;
- disabled widgets over a hover, press and release, layered over another, and disabled mid-drag;
- nesting and unbalanced scopes;
- walker tests for an image's texture coordinates, position, size and tint, and for a
  nine-slice's nine sprites in one batch;
- an image from the font's texture sharing the text's batch, and every unresolvable case
  drawing nothing.

Three mutations were each caught, then restored byte for byte:
- removing the proportional shrink failed the shrink test;
- dropping the disabled pointer block failed the disabled-scope test;
- dropping the walker's whole-source check drew three pieces of a nine-slice past its image.

**Not yet:** no widget draws an image, no theme exists, and no sample uses either. Those are
Steps 5, 6 and 8.

## Resolution — 2026-09-19, Step 5: themes as content

**Landed:**
- **The record type.** `foundry:ui_theme` is declared in `asset/ui_theme.zig`, for
  `asset.tilemap`'s reason: `fpack` checks it without a renderer, and `ui` has no `data` to hold
  a schema. Both the engine and `fpack` register it at runtime, beside `foundry:texture`.
- **`ui.Skin`,** in the kernel. It holds a nine-slice patch per `ui.SkinPart` (§10's fourteen
  names), `patch_scale`, icons by the game's own names, and four colours only a game screen
  uses: positive, negative, warning and selection. It is a value that carries `ImageRef`s and
  never textures.
- **`app.resolveUiTheme`.** It turns a record into a `UiTheme`, holding a `ui.Style`, a
  `ui.Skin`, the `UiFont` the walker draws with, and the image table (`ImageRef` 0 is the
  atlas). It acquires the atlas and font as `foundry:texture` assets and holds them until
  `deinit`.
- **The room's theme.** `room:ui.theme` states the card's former colours and metrics, and
  `textures/ui.png` is a 64×48 atlas that `scripts/gen-room-assets.py` now draws, with the
  fourteen patches and the mod screen's eight icons. The room resolves the theme on load and on
  every content change, draws its card and overlay from it, and releases it before its
  textures go.

**The names are now fixed** (`CLAUDE.md` §7). ADR-0041 fixed the names when it was accepted,
but §10 gave only a sketch, so the implementation settled these:
- **Top-level fields:** `atlas`, `font`, `text_scale`, `line_height`, `padding_x`, `padding_y`,
  `spacing`, `separator`, `scrollbar`, `disabled_alpha`, `patch_scale`, `colors`, `patches` and
  `icons`.
- **`font`:** `texture`, `cell_w`, `cell_h`, `columns`, `first` (default 32), `count`,
  `letter_spacing` and `line_spacing`.
- **`colors`:** `text`, `text_dim`, `surface`, `control`, `control_hot`, `control_active`,
  `accent`, `positive`, `negative`, `warning` and `selection`. Each is sRGB `0xRRGGBBAA`,
  converted above the kernel with the renderer's own function. The sketch's `dim` is
  `text_dim`, to match `ui.Style`, and its `…` became the four colours `ui.Skin` holds.
- **`patches`:** `part`, `x`, `y`, `w`, `h`, `left`, `top`, `right` and `bottom`.
- **`icons`:** `name`, `x`, `y`, `w` and `h`.

**Beyond the sketch, and why:**
- `patch_scale` is added, because a nine-slice needs screen units per image pixel.
- `separator`, `scrollbar` and `disabled_alpha` are optional; absent, they are `ui.Style`'s
  defaults.
- The font's spacing fields are added, because `UiFont` has them.

**Decided by the implementation:**
- **"The debug style" is the host's own built-in style.** §10 and ADR-0041 decision 3 say a
  failed theme falls back to "the debug style". The kernel has no style of its own, `app`
  cannot reach `debug`, and the overlay has none either: it draws with whatever style its
  host's context holds. So the resolver returns null and one warning, and the host keeps its
  own style. The room keeps `cardStyle`, now documented as that fallback, rather than deleting
  it as its comment once planned.
- **One bad field refuses the whole theme, with one warning naming it.** §12's "each malformed
  field falls back with one warning", read with decision 3: a theme half-applied is a screen
  nobody designed. The fields are checked before any texture is acquired, so a malformed theme
  acquires nothing.
- **An unknown part is ignored, not refused**, so a theme written for a later engine, with a
  part this one lacks, still loads. A part or an icon named twice is refused.
- **A warning names the theme by its spelling**, taken from the store's record. A theme that
  is not loaded has no spelling anywhere, so only its hash can be named.
- **The room names `room:ui.theme` in code**, as it already names `room:settings.main` and
  `room:config.main`. A mod re-skins it by overriding that record.

**Found, and left as it was.** Running `gen-room-assets.py` to add the atlas showed that the
committed `room.png` no longer matches what the script draws: the walker's four frames, cells 4
to 7, differ. The committed sheet was kept byte for byte, and only `ui.png` is new. Bringing
the script back into agreement with the sheet is a separate piece of work.

**Evidence.** The bar passed, **1,440 of 1,441**, with the one skip it had before, and both
releases staged. `engine/tests/ui_theme.zig` loads real packages and PNGs through the texture
loader, and shows:
- a valid theme resolving to every value, and a panel patch drawing as nine sprites from the
  acquired atlas;
- fourteen malformed variants each refused with exactly one warning naming their field;
- a missing theme and a non-theme record refused;
- a later package's override winning when resolved again.

Two mutations were each caught, then restored byte for byte: dropping the inside-the-atlas
check, and accepting a part named twice. Three real runs:
- the headless room logged "the card is drawn from room:ui.theme";
- a throwaway mod built outside the tree, overriding the theme with a zero `text_scale`, gave
  one warning naming the field, and the room ran on its fallback;
- the staged release resolved its theme from its own bundle.

**Not yet:** no widget draws a patch or an icon, so the room's card looks as it did. That is
Step 6.

