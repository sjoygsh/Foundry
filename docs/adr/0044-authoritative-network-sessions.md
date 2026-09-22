# ADR-0044: Authoritative sessions without cross-machine lockstep

**Status:** Accepted 2026-09-21; M16 Step 1 implemented against it; its tick admission and
complete-state delivery built in Step 4, published as `FoundryApi_v5` in Step 5, consumed
by the sandbox's header-only shared markers in Step 6, and proved against hostile peers, by
replay and within the controlled envelope in Step 7.
**Date:** 2026-09-21
**Revision, 2026-09-21:** the owner requires public-internet multiplayer. The LAN-only
alternative is withdrawn. The owner's subsequent instruction to begin Step 1 accepts the
remaining entry choices: one operator-hosted authority, provisioned player certificates and
the four-peer/no-prediction reference envelope.

## Context

M15 is complete. The owner requested M16's design, explicitly stopping before implementation.
The roadmap makes networking trigger-started by a game's need, and requires the simulation
model to be decided in writing first. The owner has selected public-internet multiplayer;
the networked-game trigger and deployment scope are therefore established. The accepted first
proof is deliberately narrow: up to four remote peers, no prediction and the measurable WAN
envelope in `networking.md` §10. That is not a general latency promise.

ADR-0013 guarantees reproducibility for the same binary and inputs, not bit-exact simulation
across macOS and Windows. `scene.World` runs registered systems on a fixed tick and cannot
import `platform`. The application owns that world; `app.Engine` does not. World saves preserve
local entity-pool handles, which are neither remote identity nor authority to mutate a world.

## Decision

**Use one authoritative server and clients that submit commands and display server state.**
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
[networking.md](../design/networking.md). ADR-0045 fixes the initial transport and limits of
the deployment claim.

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
  bit-exact subset decision due without such a requirement. Not selected.
- **Peer authority or host migration:** requires conflict resolution and recovery rules absent
  from the current requirement. One authority gives the first proof an unambiguous answer.
- **Automatic ECS/save replication:** copies local identity and potentially private state, and
  equates savable with remotely writable. Explicit application state avoids that assumption.
- **Networking inside `scene` or `app`:** breaks simulation's OS-free boundary or makes the
  loop own a world it deliberately does not own. Neither is necessary.

## Revisit if

The owner selects lockstep, prediction-sensitive competitive play, host migration, substantially
larger worlds or a different authority model. Revisit before implementation if the selected
game cannot accept the accepted envelope's latency or explicit-codec cost. ADR-0045's authenticated
transport and actual internet proof are now required in M16, not deferred release polish.

## Step 1 resolution — 2026-09-21

The implemented `net` module is L2 and receives only `core` and `platform` from the build
graph. Step 1 adds no stream, listener, session, ABI call or sample behavior. It freezes FNET
wire version 1 as explicit little-endian bytes: a 40-byte header, thirteen numbered message
kinds, nonzero nonwrapping per-direction sequence numbers, fixed control payloads and bounded
application frames. Runtime channels are namespaced `ContentId` values with revisions,
directions, delivery rules and explicit payload limits; the engine assigns no gameplay meaning
to their copied bytes. Exact layouts and the qualification choice are recorded in
`networking.md`'s Step 1 Resolution.

## Step 4 delivery resolution — 2026-09-22

`net.Service` implements this decision's authority and delivery without changing them. A peer
is active only after acknowledging the baseline it was sent. Client commands reach the
server's host only as tick batches: copied, bounded per peer, and ordered by participant number
and then command number, never by arrival, so captured batches replay. Complete state replaces
unsent state instead of queueing behind it. Payload meaning and object maps stay the
application's. The exchange order and its bounds are recorded in `networking.md`'s Step 4
Resolution.

## Step 5 publication note — 2026-09-22

`FoundryApi_v5` publishes those operations additively. The host still supplies the service,
its grants and credentials, and pumps it. A consumer admits a tick's batch and reads its fixed
order through the table, so the authority's input specification is the same for a native mod
or a tool as for the host (I4). No principal, key or remote address crosses. The inventory and
rights model are in `networking.md`'s Step 5 Resolution.

## Step 6 consumer note — 2026-09-23

The first application of this decision is the sandbox's shared markers. The server owns every
marker, and a client's command is an intent whose owner is the participant its admitted batch
names, never its payload. Clients validate each complete state into a candidate before it
replaces their view, and they neither predict nor extrapolate. The payload layouts are the
application's, as this ADR says, and are recorded in `networking.md`'s Step 6 Resolution.

## Step 7 replay note — 2026-09-23

The decision's promise, that admitted batches in their fixed order are what a replay needs,
was tested through the consumer. A session's lifecycle events between ticks and each tick's
batch, fed to a fresh pure authority, rebuilt every state the server sent, byte for byte. This
holds for the same binary and the same inputs. No cross-machine claim is made, as ADR-0013
says.
