# ADR-0031: Separate application bootstrap, content defaults and user state

**Status:** Accepted (implemented through M9 Step 3)
**Date:** 2026-09-12

## Context

`app.Config` already takes explicit inputs. Applications discover packages before creating
the engine; `data` cannot perform I/O; `asset` mounts a root per package. User directories
already exist in `platform.Os`, but samples do not persist preferences. A release needs
configuration without giving content authority to choose filesystem roots, application
identity, native-code consent or the package set that is needed to load that very content.

## Decision

Keep three kinds of input separate:

1. **Host bootstrap**, supplied by the application/build: stable application directory name,
   product metadata, required package IDs, settings schema, installed layout and code-host
   capabilities. No content record can redefine these capabilities.
2. **Game defaults**, ordinary versioned records in the game's content package, compiled by
   `fpack` and merged through `data.Store`. They contain presentation/game configuration,
   not paths or authority. The application chooses the record ID and schema.
3. **User preferences**, bounded versioned binary field blocks in the OS user-data directory.
   They override permitted defaults, never bootstrap authority. Applications register their
   own settings schema at runtime; Foundry supplies validation/encoding and atomic storage.

Reuse `data.BlockWriter`/`Blocks` for settings fields with a small versioned envelope;
do not parse `.fdt` or JSON in a shipped runtime. Settings are not a content package, do not
have a mod manifest, and are not merged into the content store. They hold values and stable
IDs, never runtime handles, addresses or the script manager's transient state snapshots.

Discover built-in and user packages separately, retain each candidate's host-assigned
root, and resolve the combined candidates by existing `mod` rules. Duplicate package IDs
are refused, not resolved by filesystem precedence. Overrides use distinct packages and
existing record override semantics. User packages require explicit enabling by content ID.

`platform` owns OS operations; `data` owns field encoding; `app` provides opt-in settings
helpers; `mod` owns discovery and ordering; applications own policy and apply values through
existing subsystem interfaces. No new layer or reverse dependency is required. Mods gain
no arbitrary filesystem or settings-write ABI. A future editor or mod-facing preferences
API must be an additive public ABI design, not a private use of these host helpers.

## Consequences

Installed content can be read-only, relocated or signed. Each sample keeps its own existing
user-directory identity. A missing/unwritable user directory degrades to in-memory defaults
with a diagnostic, without writing beside the executable. Unknown settings versions remain
untouched so an older build cannot destroy newer preferences.

The application performs startup explicitly, including a bootstrap window size followed by
content defaults/user preferences through the existing resize interface. This avoids making
the engine own game configuration or constructing a second content-loading implementation.

## Alternatives considered

* One configuration file for everything: lets content participate in selecting its own
  authority, or creates a circular dependency before discovery.
* Settings as a synthetic mod: gives local preferences content merge and package identity
  semantics they do not need, and puts private state in the mod pipeline.
* A generic runtime text configuration language: duplicates the established data model and
  contradicts the shipped-runtime authoring-parser boundary.
* Install mods/settings inside the app: breaks read-only installs and signed resources.

## Revisit if

A concrete consumer needs settings before window creation beyond bootstrap defaults; an
editor needs public preference access; multiple profiles/cloud synchronization are required;
or package replacement rather than content override becomes a separately designed feature.
