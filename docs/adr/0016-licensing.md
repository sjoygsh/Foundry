# ADR-0016: Apache-2.0, and the third-party licensing policy

**Status:** Accepted
**Date:** 2026-09-02

## Context

Foundry is intended to support games and mods built by other people. The license determines
what those people are permitted to do, and it is far easier to choose deliberately at the
start than to relicense later once there are outside contributors.

Separately, Foundry will accumulate third-party dependencies: a platform library, image and
audio codecs, a font rasterizer, a physics library, a scripting runtime. Reconstructing what
is being shipped and under what terms, after the fact, is a genuinely unpleasant job, and one
GPL dependency reaching a load-bearing position is a project-ending problem.

## Decision

### Foundry is licensed Apache-2.0

Not MIT. Apache-2.0 was chosen for what it adds over MIT:

* An **explicit patent grant** from contributors, with a defensive termination clause. MIT is
  silent on patents. For a graphics and physics engine — areas with real patent activity —
  silence is worse than an explicit grant.
* **Explicit contribution terms**, so the basis on which outside contributions arrive is
  defined rather than assumed.
* A defined **NOTICE mechanism** for attribution, which is exactly the machinery needed for
  third-party attribution in shipped builds.
* An explicit statement that it grants no trademark rights.

It remains permissive: games and mods built on Foundry may be closed-source and commercial,
which is required for the ecosystem Foundry is meant to support.

Obligations Foundry itself takes on: ship `LICENSE` and `NOTICE`, retain existing notices in
copied code, and state significant changes to files carrying notices.

One-way incompatibility worth knowing: a GPLv2-only project cannot incorporate Apache-2.0
code. This does not constrain Foundry, but it will occasionally surprise someone.

### Third-party licensing policy

Full policy in `THIRD_PARTY_LICENSES/README.md`. The load-bearing parts:

**A dependency and its license entry land in the same commit.** No exceptions.

**Permissive licenses only:** Apache-2.0, MIT, BSD-2/3-Clause, ISC, Zlib, 0BSD, Unlicense,
CC0, public domain.

**Forbidden without an explicit, discussed decision:** GPL and AGPL (would force relicensing
Foundry — this is the one that ends projects), LGPL (dynamic-linking-only conflicts with
static linking and most storefront distribution), anything with field-of-use or
non-commercial restrictions (not open source, and creates obligations we cannot pass on to
game and mod authors), and anything unlicensed.

**Check the license before evaluating a library technically.** Discovering the license after
becoming attached to the library is how bad decisions get made.

**Distributed vs. build-time-only is recorded per dependency**, because only distributed
components must appear in shipped attribution.

**Shipped attribution is generated, never hand-maintained** — a hand-maintained notice file
drifts within two releases. Generation lands at M9 (packaging).

**Content licenses count.** Fonts, textures and audio frequently carry terms stricter than
code. They are recorded the same way. This connects forward to modding: content package
manifests (M7) carry a license field, so mod authors can state their terms and redistributing
a mod pack is a tractable question rather than a guess.

## Consequences

* Game and mod authors have clear, permissive terms, with a patent grant.
* Dependency provenance stays accurate continuously, at a cost of a few minutes per
  dependency, instead of being reconstructed archaeologically before a release.
* The forbidden-license list rules out some genuinely good libraries — FFmpeg for media
  decoding is the most likely to hurt. Accepted deliberately; permissively-licensed
  alternatives exist for everything Foundry actually needs.
* Cost: `NOTICE` and `THIRD_PARTY_LICENSES/` must be maintained, and Apache-2.0 imposes real
  (if light) obligations that MIT would not.

## Alternatives considered

* **MIT** — shorter, more familiar, marginally more permissive. Rejected by explicit developer
  decision; the patent grant and contribution terms are worth the extra length.
* **MPL-2.0** — file-level copyleft, so engine improvements return upstream while games and
  mods stay proprietary. A genuine middle path, rejected in favour of full permissiveness.
* **Proprietary / all rights reserved** — retain everything. Rejected: it discourages outside
  contribution and complicates the mod ecosystem, since mod authors care about the terms they
  build against.
* **Deciding later** — cheap while private. Rejected: "no license" legally means nobody may
  use it, and the choice only gets harder once contributors exist.

## Revisit if

Foundry is never published, in which case the license is moot; or a specific dependency worth
having is available only under terms this policy forbids, in which case the tradeoff is
discussed explicitly rather than the policy being quietly bent.
