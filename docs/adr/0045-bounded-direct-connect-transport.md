# ADR-0045: Bounded direct-connect transport, with an explicit deployment limit

**Status:** Proposed — the LAN scope needs owner acceptance before M16 Step 1.
**Date:** 2026-09-21

## Context

M16 needs two processes sharing a world. It does not yet have requirements for matchmaking,
internet identities, hostile-network confidentiality or latency under loss. Choosing a network
library or implementing a reliable datagram protocol before those requirements would create
an infrastructure project around an unselected game. Conversely, a local demonstration must
not silently become a claim that an unauthenticated service is ready for public deployment.

## Decision

**Propose direct numeric-address TCP connections for the first milestone**, behind Foundry's
own `platform` stream interface. Connect, accept, read and write make bounded nonblocking
progress; a partial operation is ordinary state, not a reason to block the frame loop. OS
socket types and Zig I/O details stay in `platform`. No networking dependency or new build
tool is selected. Step 2 must demonstrate this contract on the pinned toolchain, on macOS and
Windows, before session implementation depends on it.

`net` length-frames versioned messages, bounds every queue and parser allocation, applies
per-peer work budgets, and disconnects a stalled peer. A partially written frame is immutable;
only a wholly unsent replaceable state frame may be superseded. TCP does not remove the need
for message boundaries, admission checks, timeouts, application validation or flow control.

**The proposed qualification scope is loopback and an explicitly trusted LAN.** Listening is
off by default; a non-loopback bind is an explicit host/operator choice. No discovery, DNS,
NAT traversal, port forwarding, relay, matchmaking, account service or automatic downloads.
There is no encryption or authenticated identity claim. Content hashes and compatibility IDs
detect mismatches; they do not authenticate a peer. Input remains untrusted even on this LAN.

**If public-internet multiplayer is required for M16, do not implement this proposal as if it
met that need.** First revise the ADR/design with an authenticated encrypted transport,
credential provisioning, replay protection, abuse/resource policy and a relevant deployment
proof. Evaluate a replaceable, permissively licensed implementation rather than inventing
cryptography. There is no permission here to install a dependency, open a firewall or expose
a public listener. This is an entry decision, not a waiver to be discovered at closure.

## Consequences

- The first implementation can prove sessions, public API access, authority and desktop
  interoperability without also building a service platform.
- Ordered reliable delivery simplifies the initial explicit full-state/command model.
- Cost: head-of-line blocking can delay fresh state. A bounded disconnect and visible pending
  state are acceptable only for the proposed small LAN proof, not a claim of good WAN play.
- Cost: an on-path party can observe or modify traffic, and a connected peer's identity is not
  cryptographically established. Do not send credentials or private user information.
- A fake fragmented stream and explicit time inputs let protocol tests run without real ports,
  sleeps, firewall changes or a GPU. Native socket tests are distinct evidence.

## Alternatives considered

- **Reliable UDP/QUIC or a game-networking library now:** may be right for the selected game,
  especially under loss or for secure internet play. Requirements and dependency review must
  precede that choice; they are not silently settled by this LAN proposal.
- **Invent reliability or cryptography over UDP:** unnecessary complexity and security risk.
- **Blocking sockets or one thread per peer:** makes a slow peer consume a frame or an
  unbounded worker resource. Bounded polling makes ownership and shutdown explicit.
- **Only an in-memory transport:** necessary for tests but insufficient for the roadmap's
  two-process result or Windows/macOS interoperability.

## Revisit if

The owner requires public-internet play; measured loss-induced latency misses the game's
budget; IPv6/DNS/discovery becomes a requirement; or the pinned toolchain cannot provide
bounded transport progress without additional machinery. Such a change gets a Resolution or
replacement ADR before implementation dependent on it. It does not authorize an incidental
toolchain upgrade or a background task framework.
