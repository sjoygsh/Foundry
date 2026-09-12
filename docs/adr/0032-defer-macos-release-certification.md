# ADR-0032: Separate shipping capability from macOS release certification

**Status:** Accepted
**Date:** 2026-09-13

## Context

ADR-0030 made Developer ID signing, Apple notarization and a quarantined launch on a clean
recipient Mac part of M9's completion gate. Steps 4-7 implemented the whole release path,
including a separate explicitly credentialed target, without making private credentials or a
network service part of ordinary builds. Step 8 then proved the reusable helpers and every
recipient behavior that this development environment can establish without those credentials.

The remaining proof is operational release certification. It depends on a project owner's
private Developer ID identity, an authorized notarytool Keychain profile, Apple's service and
a genuinely clean recipient Mac. None is an engine implementation dependency, none should be
invented for a milestone, and their absence no longer usefully distinguishes an unfinished
shipping subsystem from a finished one.

This changes the milestone boundary, not Apple's public-release requirement. An ad-hoc
signature establishes bundle integrity only. Gatekeeper correctly rejects that artifact, and
it is not equivalent to a notarized stranger download.

## Decision

ADR-0030's artifact architecture remains binding: applications are relocatable macOS bundles
around ordinary content packages; release inputs and staging are explicit; local ad-hoc and
public Developer ID profiles remain separate; symbols stay outside the player zip; and the
credentialed path signs with hardened runtime and a timestamp, submits, staples, validates and
assesses before producing the public archive.

M9 is complete when that path is implemented and its credential-independent engineering and
external-consumer behavior are proven. The proof includes consuming Foundry through its
exported build helpers, transporting and checksum-verifying the archive, running without the
development toolchain, relocating a read-only installation, persisting preferences, loading a
precompiled user package and retaining useful failure/healthy-launch diagnostics.

Actual Developer ID signing, Apple notarization and a quarantined stranger-download launch on
a genuinely clean recipient Mac are deferred to the first real public macOS release. That
release may not be published as verified until all three have succeeded against the exact
artifact being distributed. The test must preserve quarantine and normal Gatekeeper policy;
removing quarantine or disabling Gatekeeper is not a substitute.

The existing `dist-developer-id` path is the implementation to exercise then. Credentials
remain external operator state and their use remains an explicit authorized action. Native-mod
hosts still owe the separate outside-team signed-plugin evidence ADR-0030 required before
making a Tier 3 signing-policy claim.

## Consequences

M9 can close on engine-owned work and reproducible external-consumer evidence rather than on
private Apple account access. Foundry still has no verified public macOS release: its current
ad-hoc zip is a local artifact, and expected Gatekeeper rejection is recorded rather than
renamed a pass.

The first public release has a hard deferred gate and cannot discover then that the release
path was merely hypothetical: the code already performs the credentialed sequence, while the
operator supplies the identity, notarization access and clean recipient environment.

## Alternatives considered

* Keep M9 open indefinitely: ties an implemented engine milestone to private credentials and
  external hardware without increasing confidence in the code already proved.
* Treat the ad-hoc artifact as a public release: false; it is not Developer ID signed or
  notarized and Gatekeeper rejection is expected.
* Remove the public release gate: rejected; actual distribution still owes signing,
  notarization, stapling, Gatekeeper assessment and a clean-recipient quarantine test.
* Automate or store credentials in Foundry: rejected; credentials are operator-owned secrets,
  and release automation remains deferred.

## Revisit if

Apple changes its signing/notarization model, the first public release uses a different
delivery authority such as a storefront, or a signing policy for a native-mod host requires a
different entitlement or verification procedure. None permits an ad-hoc artifact to be called
a notarized public release.
