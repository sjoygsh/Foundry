# ADR-0047: M17 publishes an unsigned preview; paid certification waits for a 3D game

**Status:** Accepted 2026-09-23; carried out in M17, complete the same day
**Date:** 2026-09-23
**Supersedes:** [ADR-0032](0032-defer-macos-release-certification.md) in its timing only. The
first public macOS release is no longer the certified one, and certification is re-dated. Its
rule that an uncertified artifact is never published *as verified* stands and is applied here.

## Context

The roadmap made M17 the one credentialed release: Developer ID signing, Apple notarization
and a quarantined launch on a clean recipient Mac (ADR-0032). Its entry gate was a full review
and polish pass over `main`. Windows had no release step at all.

On 2026-09-23 the owner decided three things:
- **No paid membership or certificate** is bought until a fully playable 3D game exists on
  Foundry. That covers Apple's Developer Program and any Windows code-signing certificate or
  service. It is far in the future, beyond the first game and Phase 5's 3D work.
- **M17 is a GitHub release now,** for macOS and Windows. Linux is excluded: its graphics
  have never run (ADR-0039, ADR-0046).
- **Clean-machine checks use what exists:**
  - Windows: the owner's PC, with every Foundry remnant and development tool removed first;
  - macOS: a fresh macOS virtual machine on the development Mac.

A GitHub release needs no credential; it is a page with files attached. What signing changes
is what a stranger sees on opening the file:
- **macOS:** an app that is not notarized is blocked until the user chooses **Open Anyway**
  in System Settings → Privacy & Security.
- **Windows:** an unsigned executable raises SmartScreen until the user chooses **More info →
  Run anyway**.

## Decision

**M17 is renamed "Published: a stranger can download it and be told how to open it."** It
releases the samples on GitHub as a **pre-release**, labelled unverified:
- **macOS:** `zig build dist`'s ad-hoc-signed application zip for Apple Silicon.
- **Windows:** a new `zig build dist` configuration for x86_64 Vulkan, staged natively on
  Windows and zipped with the system's `tar.exe`. It uses the same loose layout, inventory and
  generated attribution as every staged release, and it is unsigned.
- **Beside them:** SHA-256 checksums, and release notes that give both "open anyway"
  procedures, the GPU requirement (Metal on Apple Silicon; a Vulkan 1.3 driver, tested on one
  Intel Arc card) and what is not verified.

**Clean-machine checks, before publishing and again from the published download.**
- **Windows:** the owner's PC after removing Foundry's trees, installs, user data, the Zig
  cache, and the Vulkan SDK's variables and `PATH` entry. The artifact is downloaded through
  a browser, so it carries the Mark of the Web.
- **macOS:** a fresh macOS virtual machine created for the check, with the archive downloaded
  in it, so quarantine applies.

A virtual machine is **not** the "genuinely clean recipient Mac" ADR-0032 asks for, and
nothing here calls it one. That standard returns with certification.

**The full review-and-polish entry gate moves with certification.** It existed to earn the
trust a signature confers, and nothing is being signed. M17 keeps:
- the bar;
- both staged releases;
- both clean-machine runs.

**M17 also makes the repository's public page accurate.**
- The README leads with what Foundry is and how to use it; milestone status moves below.
- The repository description and topics are updated.
- The AI systems that contributed are named, for transparency.

**Credentialed certification becomes a postponed decision, due after a fully playable 3D
game.** This means Developer ID, notarization, the clean-Mac quarantine launch, and Windows
Authenticode or a signing service. `dist-developer-id` stays implemented, compiled and unused,
and it is the path to exercise then. Nothing in the engine depends on the choice.

## Consequences

* **People can download Foundry now,** at no cost. Every such download is honestly an
  unverified preview. The notes must say how to open it, which is exactly what the old M17
  exit criterion ("a download nobody has to be told how to open") ruled out. That criterion
  now belongs to the certification milestone.
* **Windows gains a release path,** which the first game will need regardless of signing.
* **Trust is limited, and said so.** A checksum proves the file matches the release page, not
  who built it. Without signatures, a tampered mirror is indistinguishable from the real
  archive to anyone who does not compare checksums from GitHub.
* **SmartScreen and Gatekeeper warnings will persist,** and SmartScreen reputation does not
  accumulate for unsigned files. This is accepted until certification.
* **The review pass is not lost; it is moved.** Known defects ship in a preview, and the
  release notes point to where they are recorded.

## Alternatives considered

* **Keep M17 as written and wait for credentials.** The owner rejected paying for them before
  a 3D game exists. Nothing would be published for a long time.
* **Publish unsigned but call it a release, not a pre-release.** That breaks ADR-0032's
  surviving rule that no uncertified artifact is presented as verified. Rejected.
* **Cross-compile the Windows release on the Mac.** `dist` runs the content compiler as a
  program, and a cross-built one cannot run on the Mac. It would need a host `fpack` path that
  does not exist (`distribution.md` §8). Staging natively on Windows reuses what works.
* **Test macOS in a second user account instead of a VM.** It is quicker, but it shares the
  system and anything installed system-wide. The owner chose a VM.
* **Include Linux.** Its desktop has never run (ADR-0039). Rejected.

## Revisit if

* A fully playable 3D game exists. Certification then comes due.
* A distribution channel requires signing (a storefront, an enterprise user or a package
  manager) before that.
* A preview download causes a real support or trust problem that signing would have prevented.

## M17 result — 2026-09-23

Both published downloads open by the documented steps and run. The release is
`v0.17.1-preview`, built from `c37c01d`; `v0.17.0-preview` is marked superseded.

**Windows.** The owner's PC was wiped of Foundry, Zig and the Vulkan SDK. The zip, downloaded
through a browser:
- matched its published SHA-256, and carried the Mark of the Web;
- was held back by SmartScreen when launched through Explorer;
- ran once allowed, on Vulkan on the Arc A750, with no console window.

The checks caught two defects before they reached a stranger, both fixed in 0.17.1: a Windows
build compiled with the macOS bundle flag, and a console window beside the game.

**macOS.** A fresh macOS 26.6.2 VM under UTM, installed from Apple's restore image with its
checksum verified and no Apple ID. The Room zip, downloaded in Safari:
- was refused by Gatekeeper as unnotarized;
- opened through **Privacy & Security → Open Anyway**;
- played on Metal.

**Not claimed:** a genuinely clean recipient Mac, notarization, or any signature beyond
macOS's ad-hoc one. Those wait for certification.
