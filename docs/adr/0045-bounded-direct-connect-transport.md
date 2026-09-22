# ADR-0045: Authenticated public-internet transport behind Foundry's boundary

**Status:** Accepted 2026-09-21; provider qualified in M16 Step 1; native transport built in Step 2;
admission and negotiation built in Step 3.
**Date:** 2026-09-21
**Revision, 2026-09-21:** replaces the unimplemented LAN-only proposal in place, under
`CLAUDE.md` §8. No code depended on the earlier text. The owner's subsequent instruction to
begin Step 1 accepted the operator-hosted, mutually authenticated direct-connect topology.

## Context

The owner explicitly requires public-internet multiplayer for the first networked game.
A trusted LAN demonstration no longer meets M16. Network attackers can observe, alter and
replay traffic, connect without invitation and consume resources; an admitted player can
still submit malicious commands. Transport authentication and game authority solve different
problems. Neither requires Foundry to become an account or matchmaking platform.

## Decision

**Use an operator-hosted authoritative server at a reachable internet endpoint, with TLS
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
Mbed TLS 3.6.7 LTS is selected under its Apache-2.0 option. Its exact pin, configuration,
license review, advisory disposition and qualification evidence are below. A later provider
failure still stops for a revised decision; it never permits an insecure fallback.

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
  Measure the accepted WAN envelope in the design; do not claim generic action-game fitness.
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

## Step 1 provider resolution — 2026-09-21

Mbed TLS **3.6.7 LTS**, tag `v3.6.7` at commit
`068ff080b369adfac81509f9b57b2afabaf82dc5`, is pinned from the tag archive. The downloaded
archive's SHA-256 is
`7312b70b067b6a271961c8d36c3b8f9ba3e86fe6b26f18af13cd70430ee52ed1`; Zig records package
hash `N-V-__8AALrvlQKVtYlvv9dpBnbrJfdwR_F0wAgwsvZhAF1Y`. The supported-branches policy marks
3.6 as LTS through March 2027, so public deployment after that date requires a supported-pin
upgrade and affected qualification rerun. This short remaining lifetime is accepted for the
initial implementation because 3.6.7 is the current patched 3.6 LTS archive and contains the
generated sources needed by the Zig-only build. It is not permission to ship an unsupported
library.

Foundry elects Apache-2.0 from Mbed TLS's dual license. The bundled Project Everest and p256-m
directories were reviewed; neither optional implementation is enabled or compiled. Their
disposition and the full elected license are in `THIRD_PARTY_LICENSES/mbedtls.md`.

`engine/src/platform/foundry_mbedtls_config.h` starts from the release configuration, disables
TLS 1.2, DTLS, renegotiation and tickets, and enables externally supplied allocation and time,
ALPN `fnet/1`, retained verified peer certificates and record-size-limit support. Runtime
qualification further allowlists TLS 1.3, `TLS_AES_128_GCM_SHA256`, P-256,
ECDSA-P256-SHA256, Suite B certificate profiles and ephemeral key exchange. Early data and
resumption are absent. Zig compiles an explicit C-source inventory; Mbed socket and timing
helpers are not in it. Windows alone links OS facilities: `bcrypt` for entropy, and `ws2_32`
because Mbed TLS's X.509 IP-SAN parser selects the platform `inet_pton` under MinGW
(`_WIN32_WINNT >= 0x0600`). Neither opens a socket; qualification still exchanges records only
through in-memory BIOs.

The upstream security-advisory index and 3.6.7 ChangeLog were reviewed on 2026-09-21. The
release contains the current 3.6-line fixes, including the 2026 TLS 1.3 record-boundary,
HelloRetryRequest, X.509 parsing, ECDH, ECC and error-handling corrections. TLS 1.2, DTLS,
early data, tickets and RSA key exchange are outside the allowed configuration, but fixes in
shared X.509/ECC/TLS 1.3 paths remain required; no listed advisory justified staying on an
older pin. Advisories must be checked again before an internet proof or public release.

The `tls-qualification` build step compiles natively and in both required cross-check graphs,
then runs two peers over fixed 64-KiB in-memory BIOs. It proves TLS 1.3 mutual authentication,
the exact suite/group/signature/ALPN allowlist, bidirectional peer-certificate verification,
application bytes, OS entropy seeding, an injected certificate clock, wrong server-name
refusal and missing-client-certificate refusal. On the 2026-09-21 macOS qualification, all
three cases peaked at 98,845 allocator-accounted bytes, at most 1,039 queued wire bytes and
four provider handshake calls, under committed caps of 16 MiB, 64 KiB and 64 calls. The
allocation and handshake-call peaks are deterministic; the wire high-water mark varies with
how the two peers' handshake calls interleave. Those are qualification measurements, not a
Step 2 transport-performance claim.

## Technical references

- [TLS 1.3, RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html), including certificate
  authentication and the early-data replay caveat. Foundry disables early data.
- [Mbed TLS license](https://raw.githubusercontent.com/Mbed-TLS/mbedtls/development/LICENSE):
  Apache-2.0 is an available option; verify the chosen archive and its transitive files too.
- [Supported branches](https://github.com/Mbed-TLS/mbedtls/blob/development/BRANCHES.md),
  [official releases](https://github.com/Mbed-TLS/mbedtls/releases) and
  [security advisories](https://mbed-tls.readthedocs.io/en/latest/security-advisories/):
  recheck at qualification, pin deliberately, never build against a moving branch.
- [Mbed TLS integration tutorial](https://mbed-tls.readthedocs.io/en/latest/kb/how-to/mbedtls-tutorial/).
  These define the upstream inputs reviewed by Step 1; later internet exposure requires a
  fresh advisory check.

## Step 2 transport resolution — 2026-09-21

The native transport exists as `platform.Transport` and follows this decision without changing
it. Four implementation facts are recorded here because later steps depend on them; the full
account is `networking.md`'s Step 2 Resolution.

- **Mechanism.** Zig 0.16's `std.Io.net` blocks and its Windows bindings declare no Winsock
  function, so `platform` calls each OS's own nonblocking socket API from a small C translation
  unit compiled against that target's headers, with zero-timeout readiness checks and no worker.
  The provider and that unit are one static archive linked into `platform` alone.
- **Role.** A peer's leaf certificate must carry an extendedKeyUsage naming its role; the
  provider would otherwise accept an identity issued without one for either role. Foundry's own
  credentials are held to the same rule at creation.
- **Server identity.** A client requires both the granted server name and the server's pinned
  key, the SHA-256 of its SubjectPublicKeyInfo, compared inside certificate verification. Pinning
  the key rather than the certificate lets a renewal that keeps its key keep its pin.
- **Time.** Certificate validity is judged by the OS civil clock, read before every handshake
  call; a clock earlier than 2026-01-01 refuses instead of guessing.

A refusal is not always legible to the refused side under TLS 1.3 — an early client alert is
unprotected, a server's late one is protected with keys the client has left — so the refusing
side's category is authoritative. This does not weaken the decision: the refused connection still
fails closed, with no application byte delivered.

## Step 3 admission resolution — 2026-09-22

`net.Service` enforces admission as decided above without changing it; `networking.md`'s Step 3
Resolution has the full account. Four facts later steps depend on:

- **Admission is by grant, allowlist and principal.** Sessions exist only by host grant. A verified
  key maps to a host-local principal through the allowlist; a principal holds at most one live
  connection; a key that is not listed is refused after TLS with a generic `policy` refusal and no
  event. Replacing the allowlist is all or nothing, and removing or remapping a key ends its live
  peer.
- **Validity is judged throughout a session.** `platform` fails an established stream once the
  civil clock passes the earliest notAfter in its peer's verified chain, and the service judges a
  peer before reading more from it. Rotating a grant's credentials ends every connection they
  authenticated.
- **Pre-authentication work is bounded before any handshake call.** The pending pool, the
  per-pump accept budget and the per-source and global start buckets all decide before the first
  provider handshake call. A refused start still costs one provider session setup, because the
  transport creates it at accept; that is recorded for Step 7 to measure.
- **A refusal is delivered, not assumed.** A side that ends a connection lingers, for a bounded
  time, to deliver its refusal or disconnect, because closing with unread input resets TCP and a
  reset can discard it.

