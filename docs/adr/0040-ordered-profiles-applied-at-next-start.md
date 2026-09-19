# ADR-0040: A player's mod selection is an ordered profile, applied at the next start

**Status:** Accepted 2026-09-19 (M14). On 2026-09-19:
- Step 1 implemented decision 4, the duplicate rules.
- Step 2 implemented profile files, their order and consent storage in the engine (decisions
  1, 2, 3 and 5).
- Step 3 implemented decision 7's migrations and merged writes, and moved both samples onto
  profiles.
- Step 7 implemented decision 6, the public API, as `FoundryApi_v3`'s `mods_*` calls.

**Date:** 2026-09-19
**Builds on:** [ADR-0026](0026-abi-module-and-host.md), [ADR-0027](0027-mods-are-content-packages.md)
and [ADR-0031](0031-application-configuration-and-user-data.md)

## Context

M14 gives the player the mod list that `mod` has computed since M7. Six facts shape how, and each
comes from an existing record:
1. **The player's order is thrown away.** `mod.resolve` keeps the player's order wherever the
   dependency graph allows, and ADR-0027 kept "the manual list … as an override, because a player
   untangling a conflict needs one". But `distribution.md` §5's canonical settings write sorts
   and deduplicates the enabled set. After the first save, the only order left is content-id
   order.
2. **ADR-0031 names this revisit.** "Multiple profiles/cloud synchronization are required" is one
   of its conditions, and M14's roadmap entry requires profiles.
3. **The loaded set is fixed for a session.** `distribution.md` §5 never changes the enabled set
   mid-session. `public-abi.md` §14 never closes a native library.
4. **Duplicates stop the game.** `mod.resolve` returns `DuplicatePackage` when any two candidates
   share an id, enabled or not. A player who copies a mod twice into `mods/` gets no game, and so
   no screen on which to fix it.
5. **I4 requires the capability in the ABI.** A game's mod screen may use nothing a mod could not.
   Native consent, though, is host authority under ADR-0031, and no mod may grant it.
6. **Concurrent instances lose changes.** Two running instances resolve by last-writer-wins, and
   settings migrations were deferred "once a second schema exists" (`distribution.md` §13).

## Decision

**1. A profile is a named, ordered selection, in a file of its own.** It lives at
`<user-data>/profiles/<key>.fset`, in the settings envelope under an engine-registered profile
schema.
- The key is the smallest unused number from 1. The display name is data inside the file and
  never becomes a path.
- A profile holds the enabled package ids in the player's order, and the native consents of
  decision 5. Nothing else in M14.
- Settings record the active profile's key. A missing or unreadable one falls back to another
  profile, then to a fresh "Default", with a warning.

**2. The order is the player's.** A profile's list is deduplicated and never sorted. This
supersedes `distribution.md` §5's canonical sort for the enabled list only. Dependencies still win,
and resolution is unchanged: ADR-0027's function of `(available packages, enabled list)`, with the
list's order as its first tie-break.

**3. A changed selection applies at the next start.** The running session keeps the order it
started with, and the screen shows that order beside the pending one. Switching profiles is a
change like any other.

**4. User duplicates are skipped, not fatal.** This supersedes `public-abi.md` §12.1 step 1 for
user packages:
- Two installed packages with one id remain fatal, because that is a broken install.
- A user package claiming an installed package's id is skipped, and the installed one loads.
  Replacing a package stays separately designed (ADR-0031).
- Two or more user packages with one id are all skipped, each named with its file.

Every skip is a diagnostic naming both files. None is a silent pick.

**5. Native consent is the host's alone.** It is recorded per `(package id, version)` in the
profile, only by the host's own screen, and asked again for a new version. It is never given by
content, by the ABI, or by a profile brought from elsewhere without the host's screen. A host that
loads no native code says so and never asks.

**6. The capability is published as `FoundryApi_v3`,** additively, with v1 and v2 byte-identical.
- **Reading** is answered whenever the host supplies its mod set to `abi.Host`: installed
  packages, the pending selection and preview, conflicts, providers and profiles.
- **Changing** the pending selection or profiles answers `REFUSED` unless the host granted writes
  when it supplied the set. That is one host-level grant, not per-mod policy.
- **Consent and paths** are never published.

**7. Writes merge, and schemas migrate.**
- A save re-reads the file, lays only the fields this process changed over its current values,
  and replaces it atomically. A newer version is still never overwritten.
- An application registers an explicit conversion from each older schema version to the next,
  and the old file is kept once as a backup before the first migrated write.
- Profiles follow both rules.

## Consequences

- **A player gets MO2's model with dependencies behind it.** The drag order means something and
  survives saving, and the screen can show both what was asked for and what will load.
- **M14 supplies its own second schema version.** Both samples move `enabled` out of settings
  into a "Default" profile. That exercises decision 7 on real files rather than hypothetical
  ones, and it is the exit criterion's "preferences survive a schema change".
- **Profiles migrated from v1 start in content-id order,** because v1 never kept the player's.
  From then on, the order is preserved.
- **A mod change needs a restart.** That is honest for native code, which cannot leave, and it
  avoids rebuilding content under a live world. The cost is a worse experience than a live
  toggle, and the screen has to say it plainly.
- **A mod can build an alternative mod manager,** when the host allows it. It can never approve
  native code, and never learn where files live.
- **Two instances no longer undo each other's unrelated changes.** The same field changed in both
  remains last-writer-wins, now narrowed to that field.
- **A duplicate is recoverable from inside the game,** at the price of a rule with three cases
  instead of one.

## Alternatives considered

- **Profiles inside `settings.fset`.** One file, but every profile shares its 64 KiB and its
  128-element lists. Two instances editing different profiles would also collide on one field.
  Rejected for separate files.
- **Apply changes live.** Better for players, and the reason MO2's model feels natural. Rejected
  for M14 because it needs three things M14 does not own: rebuilding content under a world whose
  entities name records that may vanish, starting and stopping script packages outside reload,
  and a native library that can leave. It is recorded as open, not refused.
- **Refuse a drop above a dependency.** Simpler to draw. Rejected because the resolver already
  keeps the dependency first; accepting the preference and showing the effective position loses
  nothing and explains more.
- **LOOT-style ordering rules** ("load A after B") instead of a list. Rules survive new mods
  better, but they add a second model a player has to learn. The list is what ADR-0027 and
  `mod.resolve` already take.
- **Keep duplicates fatal.** Consistent with the letter of `public-abi.md` §12.1. Rejected
  because it makes the commonest install mistake unrecoverable from the only screen that could
  fix it, against that section's own rule that one broken mod yields a game and a message.
- **A lock file for concurrent writes.** Rejected: a lock must survive crashes and stale holders,
  which is a larger problem than the milliseconds-wide race it would close.
- **Per-mod ABI grants.** That is `public-abi.md` §18 Q4, which stays open. A host-level grant
  answers M14 without deciding it.
- **A separate launcher application,** as MO2 is. Possible later, because the mod set sits below
  the engine loop (ADR-0027). The roadmap asks for the capability in a game.

## Revisit if

- A game needs a mod change to take effect without a restart. Live application then becomes its
  own design.
- Players manage more mods than a profile's bounds of 1,024 enabled packages and 256 consents.
- Saves need to record the package set they were made with, which is ADR-0027's per-save revisit.
- A mod needs per-mod permissions beyond the host's single grant, which is `public-abi.md` §18 Q4.
- The merge-by-field write loses a change in practice, which would be the evidence for locking.
