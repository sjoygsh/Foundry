# ADR-0045: Authenticated public-internet transport behind Foundry's boundary

**Status:** Proposed architecture; public-internet scope is required by the owner.
**Date:** 2026-09-21
**Revision, 2026-09-21:** replaces the unimplemented LAN-only proposal in place, under
`CLAUDE.md` §8. No code depends on the earlier text. Step 1 has not begun.

## Context

The owner explicitly requires public-internet multiplayer for the first networked game.
A trusted LAN demonstration no longer meets M16. Network attackers can observe, alter and
replay traffic, connect without invitation and consume resources; an admitted player can
still submit malicious commands. Transport authentication and game authority solve different
problems. Neither requires Foundry to become an account or matchmaking platform.

## Decision

**Propose an operator-hosted authoritative server at a reachable internet endpoint, with TLS
1.3 over TCP and mandatory mutual certificate authentication.** Clients connect outbound;
automatic NAT traversal, relays and matchmaking are not part of this topology. Numeric IPv4
is sufficient for the first proof: a separately provisioned server identity is verified even
when the destination is numeric. If player-hosted sessions or different latency requirements
are needed, revisit this topology before implementation, not after building it.

The host supplies endpoint and credential grants, an explicit trust bundle, expected server
identity and admitted client identities. `platform` owns TLS and OS streams behind Foundry
types; no vendor type, secret or raw socket enters the public API. `net` consumes authenticated
streams, enforces admission and does compatibility negotiation only after authentication.
Certificate verification is mandatory, including validity and intended use. No plaintext
fallback, trust-on-first-use, ignored verification error, early data or session resumption in
M16. Every reconnect performs fresh authentication and authorization; no replay of queued input.

**Use a maintained permissively licensed TLS implementation, not custom cryptography.**
Mbed TLS is the candidate, under its explicit Apache-2.0 license option. Before dependent
code, Step 1 records the exact supported release, archive hash, transitive licenses, security
advisory disposition and configuration. It must qualify TLS 1.3 mutual authentication,
bounded nonblocking progress, OS entropy, certificate validation and a Zig-only build on the
pinned toolchain. If it cannot, stop for a revised provider decision. No dependency is added
by this planning revision; dependency and license entries must land together later.

`net` length-frames versioned messages inside TLS. Bound unauthenticated accepts, concurrent
handshakes, certificate chains, TLS allocations and computation as well as authenticated
queues. A partially submitted plaintext frame is immutable even if TLS has not yet emitted
its encrypted records. Transport success does not establish application authority or delivery.

**Credentials are operator-managed, not content.** Each player has a distinct private key and
an admitted public identity; no shared client key in the executable. Provision trust and keys
out of band, bound expiry, document rotation, and prove withdrawal of an identity prevents
new joins and terminates its existing connection. No secrets in source, packages, command-line
values, environment variables, logs or captures. Only host-granted credential file references
or secure-store references are configuration; packages cannot choose them. Revocation policy
uses the host's local allowlist, not an implied online account or certificate-status service.

**The exit includes real public-internet connectivity and a threat-focused proof.** LAN and
loopback remain development evidence only. Use macOS and Windows clients on independent
networks against an explicitly authorized server endpoint. Budget/rate-limit handshakes and
admitted traffic, test credential failures and replay, and retain evidence of correct behavior
under stated WAN conditions. No claim of protection from an upstream volumetric DDoS, a
compromised machine, cheating by the server or stolen authorized credentials.

## Consequences

- Internet transport security is an M16 obligation, not M17 polish. A fake stream or local
  tunnel cannot stand in for the deployment proof.
- Cost: certificate provisioning is explicit operator work; this is admitted multiplayer,
  not frictionless anonymous matchmaking. Accept that UX before implementation.
- Cost: a TLS dependency needs patch monitoring, attribution and release updates. Missing
  security fixes block public deployment even when an older functional proof passed.
- Cost: TCP head-of-line blocking and no prediction may limit the game's responsiveness.
  Measure the proposed WAN envelope in the design; do not claim generic action-game fitness.
- Infrastructure costs, public exposure, firewall/router changes and real credential use need
  explicit operator authorization. This design does not provision any of them.

## Alternatives considered

- **Plain TCP/LAN-only:** no longer meets the owner's requirement; withdrawn.
- **QUIC or a secure game-datagram library:** may suit the eventual game's latency better.
  The small full-state proof does not yet need independent unreliable channels; TLS/TCP is
  the simpler proposal, conditional on meeting the stated WAN budget. Revisit if it fails.
- **Server TLS plus password/bearer-token service:** possible, but introduces token issuance,
  storage and account policy. Distinct provisioned client certificates supply the first
  admitted-player proof without inventing that service.
- **Custom encryption or authentication:** unacceptable; use a maintained protocol provider.
- **Platform-specific TLS providers:** possible fallback, but multiple configurations and
  verification implementations cost more interoperability evidence than one pinned provider.

## Revisit if

The game needs anonymous joins, player-hosted NAT traversal, accounts, different latency,
IPv6/DNS, resumption, or a scale beyond the measured envelope; certificate provisioning is
unacceptable UX; or the provider fails qualification or becomes unsupported. Resolve before
dependent code. No incidental toolchain upgrade or background task framework is authorized.

## Technical references

- [TLS 1.3, RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html), including certificate
  authentication and the early-data replay caveat. Foundry proposes disabling early data.
- [Mbed TLS license](https://raw.githubusercontent.com/Mbed-TLS/mbedtls/development/LICENSE):
  Apache-2.0 is an available option; verify the chosen archive and its transitive files too.
- [Supported branches](https://github.com/Mbed-TLS/mbedtls/blob/development/BRANCHES.md),
  [official releases](https://github.com/Mbed-TLS/mbedtls/releases) and
  [security advisories](https://mbed-tls.readthedocs.io/en/latest/security-advisories/):
  recheck at qualification, pin deliberately, never build against a moving branch.
- [Mbed TLS integration tutorial](https://mbed-tls.readthedocs.io/en/latest/kb/how-to/mbedtls-tutorial/).
  These inform the proposal; none is evidence of a Foundry implementation or completed audit.
