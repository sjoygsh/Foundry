# ADR-0044: Authoritative sessions without cross-machine lockstep

**Status:** Proposed — design only; owner acceptance required before M16 Step 1.
**Date:** 2026-09-21

## Context

M15 is complete. The owner requested M16's design, explicitly stopping before implementation.
The roadmap makes networking trigger-started by a game's need, and requires the simulation
model to be decided in writing first. No player count, latency target, public-internet threat
model or lockstep requirement has been supplied. This proposal is not evidence that those
product decisions have been made.

ADR-0013 guarantees reproducibility for the same binary and inputs, not bit-exact simulation
across macOS and Windows. `scene.World` runs registered systems on a fixed tick and cannot
import `platform`. The application owns that world; `app.Engine` does not. World saves preserve
local entity-pool handles, which are neither remote identity nor authority to mutate a world.

## Decision

**Propose one authoritative server and clients that submit commands and display server state.**
The server alone advances the shared simulation. Clients do not run a second authoritative
simulation, and M16 does not add prediction, rollback or cross-platform fixed-point physics.
ADR-0013 and I9 remain unchanged. A replay records commands at their actual admitted server
ticks; it does not pretend live packet arrival is deterministic.

**The engine supplies sessions; the application supplies meaning.** Runtime-registered,
namespaced, versioned channels carry bounded copied messages. The host controls admission,
endpoints and limits. The application validates commands, defines the replicated state, and
maps session-scoped object IDs to its own local entity handles. Neither a component's memory
layout nor `FSAV` is a wire protocol. No automatic replication of every registered component.

**Add optional `net` at L2, depending only on `core` and `platform`.** `platform` owns OS
transport access; `net` owns framing, session state, compatibility negotiation, peer lifetime,
bounded queues and statistics. `scene`, `data`, physics, audio and rendering gain no networking
dependency. The host pumps the service outside simulation and admits copied input between
ticks. Network callbacks never execute gameplay inside a socket read.

**Publish the service in additive `FoundryApi_v5` before its reference consumer.** The host
hands `abi` an optional service and allowed session grants, following ADR-0026. V1–v4 remain
unchanged. There is no remote invocation of arbitrary table entries and no socket authority in
Lua binding 1. A separately built header-only sample client and an external C consumer must
prove the networking surface; private host bootstrap may not carry gameplay around the table.

The detailed contract, acceptance gate and nine implementation steps are in
[networking.md](../design/networking.md). ADR-0045 proposes the initial transport and limits
of the deployment claim. Both ADRs remain proposed until the owner accepts the scope.

## Consequences

- Different machines can share authoritative results without promising identical independent
  floating-point simulations. Mods can register channels through the same surface as the sample.
- The engine knows no player rule, movement speed, ownership policy or game-specific component.
- Networking stays optional; opening an editor or an offline sample opens no listener.
- Cost: input latency is visible; clients wait for authoritative state. Full snapshots cost
  bandwidth, and the initial bounded proof is not a large-world replication system.
- Cost: games write explicit codecs and authority checks. Introspection is not permission to
  replicate a component, and serialization is not permission to accept a client write.

## Alternatives considered

- **Lockstep:** useful when required by a particular game, but it would make ADR-0013's deferred
  bit-exact subset decision due without such a requirement. Not selected for this proposal.
- **Peer authority or host migration:** requires conflict resolution and recovery rules absent
  from the current requirement. One authority gives the first proof an unambiguous answer.
- **Automatic ECS/save replication:** copies local identity and potentially private state, and
  equates savable with remotely writable. Explicit application state avoids that assumption.
- **Networking inside `scene` or `app`:** breaks simulation's OS-free boundary or makes the
  loop own a world it deliberately does not own. Neither is necessary.

## Revisit if

The owner selects lockstep, prediction-sensitive competitive play, host migration, substantially
larger worlds or a different authority model. Revisit before implementation if the selected
game cannot accept the proposal's latency or explicit-codec cost. Public-internet deployment
also requires ADR-0045's security decision; it is not implied by accepting authority here.
