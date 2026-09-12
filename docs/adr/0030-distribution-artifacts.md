# ADR-0030: Distribute an application around ordinary content packages

**Status:** Superseded by [0032](0032-defer-macos-release-certification.md) — in its M9
completion gate only. The artifact architecture below remains binding and is restated there.
**Date:** 2026-09-12

## Context

M9 owes a macOS application a stranger can run without Zig, Xcode or the repository.
The existing install has executables in `bin`, compiled `.fpk` records in `content`, and
each package's assets in a directory beside its `.fpk`. SDL and Lua are statically linked;
engine Metal shaders are compiled during the build and embedded. Development installation
also copies authoring inputs, so archiving all of `zig-out` is not a release specification.

Packaging must preserve content identity, overrides and the three mod tiers. A signed app
also cannot be the place players are expected to write settings or install mods.

## Decision

Keep the existing runtime formats. Bundle selected `.fpk` files with their runtime asset
directories inside a relocatable macOS `.app`, then distribute that app in a zip. No new
archive reader, virtual filesystem, encrypted content or Lua bytecode format enters the
engine. The zip is a transport container, extracted before execution.

The application owns its release description: executable, product identity/version,
supported OS floor, package inputs and explicit additional runtime files. Foundry's Zig
build helpers stage that description without hardcoding a game's content. `fpack` remains
the content compiler. Release staging starts in a fresh output directory and copies only
declared runtime inputs; it does not recursively redistribute a developer's installation.

The reference release is `samples/room`, built as Apple Silicon macOS, SDL3/Metal,
`ReleaseSafe`. The sandbox additionally proves packaged scripting. Neither sample gains
gameplay features for M9. Windows/Linux retain ADR-0008's build-check obligation.

For the macOS packaging step, explicitly admit the system tools `ditto`, `plutil`,
`codesign`, `otool`, `dsymutil`, `dwarfdump`, `spctl`, and Xcode's `notarytool`/`stapler`
through `xcrun` where applicable. These are scoped artifact, symbol and distribution tools,
not another build system or new package-manager dependencies. Zig builds all code and runs
local packaging steps. No CI, upload automation or credential storage is introduced.

Local ad-hoc signing and Developer ID distribution are distinct profiles. An ad-hoc zip
can prove staging and relocation, but cannot stand in for the quarantined, notarized
distribution test. M9 completion records the actual recipient launch evidence; missing
signing credentials or a recipient environment is an explicit gate, never an inferred pass.
Native-mod hosts must test their signing policy with an independently signed plugin; the
room and sandbox are not silently turned into native loaders to do this.

## Consequences

The shipped loader remains the loader mod authors already use. Static dependencies and
embedded shaders need no developer installation on a recipient's Mac. Loose runtime assets
cost files and disk space, but allow the present loaders and content identities to survive.
Settings and extra mods need separate writable roots (ADR-0031).

Reproducibility means a stable staged file inventory and identical unsigned payload bytes
for identical explicit inputs. Signing timestamps, notarization tickets and zip metadata
are not promised to be byte-identical. Symbols are retained separately and matched by
Mach-O UUID, rather than adding development artifacts to the player download.

## Alternatives considered

* Archive the whole install: includes tools, stale files and authoring inputs accidentally.
* A monolithic pack/VFS: duplicates a working asset path without an M9 requirement.
* A shell launcher: does not prove the Finder application experience.
* Require notarization to build locally: ties ordinary development to private credentials.
* Call an ad-hoc build a verified public release: does not establish the roadmap's exit.

## Revisit if

Measured startup/file-count costs justify a runtime container; another shipping platform
needs a different application layout; or a storefront requires a distinct delivery format.
None changes stable content IDs or licenses.

## Platform references

Consulted 2026-09-12: Apple's [distribution signing guide](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/),
[notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
and [library-validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
Recheck the operational commands when Step 7 is implemented; these are external platform rules.

## Implementation note — 2026-09-13

M9 Steps 4-7 implement this decision. `tools/distribution` stages the declared runtime closure
and attribution, maps it into a generated macOS application, rejects undeclared host load
paths, retains an exactly UUID-matched dSYM, and exposes distinct local ad-hoc and explicit
Developer ID/notarization build targets. A moved, read-only local app passed SDL3/Metal/audio
and LaunchServices execution. No Developer ID credential was supplied or authorized, and the
downloaded/quarantined no-toolchain recipient proof remains Step 8; neither is inferred from
the local artifact.
