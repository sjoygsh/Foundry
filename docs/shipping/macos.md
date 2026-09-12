# Shipping a Foundry application on macOS

This guide describes the release path implemented by M9 and the evidence actually obtained
from it. It is for an application that consumes Foundry as a dependency; the room sample is
the reference artifact, not a privileged packaging path.

The current supported reference is Apple Silicon, macOS 26, `ReleaseSafe`, SDL3 and Metal.
Foundry has **not** published or certified a public macOS release. The local zip is ad-hoc
signed. It proves the application layout and seal integrity, but Gatekeeper is expected to
reject it because it is neither Developer ID signed nor notarized.

## 1. Describe the release in the consuming build

Add Foundry as a normal dependency in the application's `build.zig.zon`. A sibling checkout
is sufficient during development:

```zig
.dependencies = .{
    .foundry = .{ .path = "../Foundry" },
},
```

The application build imports Foundry's build declarations, obtains the build-only tools from
the dependency, and describes its own product and packages. The important part is:

```zig
const foundry = @import("foundry");

const engine = b.dependency("foundry", .{
    .target = target,
    .optimize = optimize,
    .platform = .sdl3,
    .rhi = .metal,
});

const description: foundry.release.Description = .{
    .product_name = "My Game",
    .bundle_id = "com.example.my-game",
    .product_version = "1.0.0",
    .revision = revision,
    .executable = game,
    .packages = &.{
        .{ .dir = "content/core", .stem = "core" },
        .{ .dir = "content/my-game", .stem = "my-game" },
    },
    .license_id = "Apache-2.0",
    .license_file = b.path("LICENSE"),
    .notice_file = b.path("NOTICE"),
    .licenses_dir = "THIRD_PARTY_LICENSES",
};

const local = foundry.release.macosApplication(
    b,
    foundry.release.Tools.fromDependency(engine),
    description,
    .local,
);
```

Attach `local.ready`, `local.app`, `local.symbols` and `local.zip` to the consuming build's
explicit `dist`/install steps. `Tools.fromDependency` supplies `fpack`, `fstage` and
`fmacos-verify` without installing the latter two into the development prefix or release.
The full field contract is documented by `tools/distribution/release.zig`; the application,
not Foundry, owns its product name, bundle ID, version, license and package selection.

The application's release executable must select the bundle layout explicitly: installed
content is `Contents/Resources/content`, never a path guessed by searching from the working
directory. Keep the ordinary loose-layout executable for development.

## 2. Build the local artifact

With the pinned Zig 0.16.0 toolchain, run the consuming build's explicit target with an exact
source revision:

```sh
zig build dist -Doptimize=ReleaseSafe -Drevision=<commit>
```

The reference Foundry checkout exposes the equivalent sample target:

```sh
zig build dist -Dapp=room -Dplatform=sdl3 -Drhi=metal \
  -Doptimize=ReleaseSafe -Drevision=<commit>
```

It produces the application, a separate matching dSYM and a local transport zip. Keep the
dSYM by the revision recorded in `Contents/Resources/inventory.txt`; do not put it in the
player archive. Do not change anything inside the application after signing.

Before sharing even a local artifact, inspect the outputs the build has already gated:

```sh
/usr/bin/plutil -lint "My Game.app/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "My Game.app"
/usr/bin/otool -L "My Game.app/Contents/MacOS/my-game"
/usr/bin/dwarfdump --uuid "My Game.app/Contents/MacOS/my-game"
/usr/bin/dwarfdump --uuid "My Game.app.dSYM"
/usr/bin/shasum -a 256 "My Game-local.zip"
```

Only system load paths and explicitly declared bundle-relative dependencies are allowed, and
the executable/dSYM architecture and UUID sets must match. Publish the archive checksum over
a channel independent of the archive.

## 3. What a recipient receives

A public recipient receives only the final notarized zip. The player downloads it normally,
compares its SHA-256 with the publisher's value, extracts it without removing quarantine,
moves the application wherever desired and opens it through Finder. No Zig checkout, compiler,
Xcode, Homebrew library or writable application bundle is a runtime requirement.

Do not tell a player to run `xattr -d`, disable Gatekeeper globally or bypass quarantine. If
Gatekeeper rejects a purported public release, stop: that artifact has not passed the release
gate below.

Foundry keeps writable state outside the application. For the reference room it is:

```text
~/Library/Application Support/foundry-room/
  settings.fset
  mods/
  logs/
```

The application writes `settings.fset` only after an explicit preference change or a normal
dirty shutdown. A fatal exit does not save. Session logs are bounded and may contain paths or
user-provided strings, so a player should review one before sharing it.

The sample has no mod-manager UI. A precompiled package is installed as its `.fpk` and, when
it has runtime files, its same-stem directory under `mods/`. A developer can explicitly select
the package by content ID while proving a release:

```sh
FOUNDRY_ROOM_PACKAGES=mymod:changes \
  "/Applications/Foundry Room.app/Contents/MacOS/room"
```

An application intended for players should expose its own selection UI; it must still pass
the selected IDs to the same installed-plus-user package resolver. Merely placing a package in
`mods/` does not grant native-code consent.

For a startup-diagnostics proof, opt the sample in explicitly:

```sh
FOUNDRY_ROOM_DIAGNOSTICS=1 \
  "/Applications/Foundry Room.app/Contents/MacOS/room"
```

After a failed startup, keep the failed session's `.log` and `.marker`. A later healthy launch
uses another slot and ends with its own `clean`/`shutdown` marker; it does not overwrite the
failure evidence.

## 4. Public Developer ID and notarization gate

This section is mandatory for an actual public macOS release and was **not executed for M9**.
Use it only with the owner's authorization and credentials already stored in an external
notarytool Keychain profile. Never put passwords, API keys or private key material in the
repository, build arguments or logs.

For Foundry's reference target:

```sh
xcrun notarytool store-credentials "<profile>"
zig build dist-developer-id -Dapp=room -Dplatform=sdl3 -Drhi=metal \
  -Doptimize=ReleaseSafe -Drevision=<commit> \
  -Dsigning-identity="Developer ID Application: … (TEAMID)" \
  -Dnotary-profile="<profile>"
```

An external application applies the same two helpers: build with
`macosApplication(..., .{ .developer_id = identity })`, then pass its result to
`notarizeMacos(..., keychain_profile)` and attach only the returned `ready`/zip to its public
release target. That sequence performs hardened-runtime timestamped signing, submits and waits,
staples and validates the accepted ticket, checks the signature and Gatekeeper assessment, and
only then creates the final zip.

Before publication, perform the remaining release proof on a genuinely clean recipient Mac
that has never executed that application/code signature and has no development toolchain on
`PATH`:

1. Download the exact final zip through the intended public route and confirm quarantine is
   present.
2. Compare its SHA-256 with the independently published value.
3. Extract normally and open the application in Finder without an override.
4. Confirm visible rendering, input, audio and normal exit.
5. Change window size and volume, quit, and confirm a fresh process loads both.
6. Move the app to a path containing spaces, make its resources read-only, and launch again.
7. Install and select a precompiled user package from the application data `mods/` root.
8. Cause one bounded startup failure, inspect its log/marker, repair it, and confirm the next
   launch ends with a clean marker.

Record the artifact SHA-256, revision, signing identity/team, notarization acceptance, stapled
ticket validation, Gatekeeper result, macOS/hardware version and observed results. A launch on
the build Mac, a previously approved code signature, or an ad-hoc `codesign --verify` result is
not clean-recipient evidence.

## 5. M9 evidence and limits

Step 8 built an outside-tree consumer through `Tools.fromDependency` and
`macosApplication`; all 29 build steps passed. Its zip crossed HTTP into a separate recipient
directory with matching SHA-256
`7ee1e46701b1bb57f56c0634c8728f34e54748694ca72c5560122cb7edee4a22`. With a
system-only `PATH`, the app initialized SDL3/Cocoa, Metal and audio; a fresh process loaded the
saved `1000x650` window and `0.25` volume. A relocated app with read-only resources loaded a
precompiled user package and its `900x600`/`0.40` defaults. A duplicate package produced a
failed/discovery marker and named diagnostic, and the next repaired launch produced a
clean/shutdown marker.

Strict ad-hoc signature verification passed. Gatekeeper assessment rejected the artifact,
which is the expected and recorded result for an artifact with no Developer ID signature or
notarization ticket. Quarantine metadata was preserved in the local exercise, but this Mac had
already executed the code, so its later GUI launch is not claimed as a clean-recipient pass.

Therefore M9 proves the release machinery and credential-independent recipient behavior. It
does not prove older macOS versions, Intel macOS, Windows/Linux runtime, storefront delivery,
native-mod signing policy or a notarized public release. ADR-0032 defers the credentialed and
clean-recipient gate above to the first real public macOS release.
