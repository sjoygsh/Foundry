# Network sessions and the shared-world proof

**Milestone:** M16 — Connected: “it plays with others”
**Status:** Proposed design, 2026-09-21. **Zero of nine steps implemented.** Stop before Step 1.
**Decisions:** proposed [ADR-0044](../adr/0044-authoritative-network-sessions.md) and
[ADR-0045](../adr/0045-bounded-direct-connect-transport.md).
**Built on:** ADR-0004/0005/0007/0010/0013/0017/0026/0029/0036/0039;
`entity-storage.md`, `app-and-frame-loop.md`, `platform-interface.md`, `public-abi.md`.

## 1. Entry gate and runnable result

M15 is complete at `94bc204`, tagged `m15`; its accepted tests are not repeated for this
planning change. The owner requested M16 planning, not implementation. Networking remains
trigger-started. The roadmap requires a game need and a written choice of simulation model.

**Recommendation:** one authoritative server, direct-connect clients, a small trusted-LAN
proof, explicit commands and full state snapshots. This is a proposal, not a newly accepted
game requirement. Before Step 1, the owner must accept or revise:

1. The networked-game trigger and authoritative rather than lockstep simulation.
2. Whether trusted-LAN scope is sufficient, or public-internet security belongs in M16.
3. The initial scale: one server and up to four remote peers in the reference proof, with no
   client prediction and no promise of competitive-action latency.

Record acceptance in the two ADRs and this status; do not infer it from M15's completion.
If different requirements are supplied, revise this unimplemented proposal first. No engine
code, socket experiment, dependency installation or API declaration belongs to this handoff.

**Exit:** two independently launched processes visibly share an authoritative world. A client
can affect only what the server permits; late join receives current state, disconnect removes
the departed participant, and reconnect creates a fresh participant without stale authority.
Run same-host proofs and a macOS/Windows cross-host proof with each host acting as server.
The engine capability must be usable through the public table, including from outside this
repository. A local simulation with two viewports or a fake transport alone does not pass.

The proposed LAN limit must appear beside every result. M16 would not establish secure public
internet deployment, matchmaking, lockstep, prediction or general automatic ECS replication.
M17's Apple release certification and M18's Linux runtime gate are unchanged.

## 2. Current implementation and reuse

| Existing code | What it supplies; what must not be assumed |
| --- | --- |
| `platform/os.zig`, `platform/root.zig` | Explicit OS ownership, separate from window backends. No existing Foundry socket service. Keep Zig 0.16 I/O and native handles here. |
| `app/engine.zig` | Fixed `Step` values, frame-frozen input and host-driven iteration. It owns no simulation world; networking must not change that. |
| `scene/world.zig`, `system.zig` | Runtime-registered components/systems, stable entity iteration and explicit ticks. `scene` actually imports only `core` and `data`; keep it OS-free. |
| `scene/save.zig`, `component.zig` | Versioned saves and field serialization. Saves preserve local pool identity and can skip unknown components; neither property is a network synchronization contract. |
| `abi/host.zig`, `api.zig`, `foundry.h` | Host-supplied optional services and additive versions through v4. No remote RPC transport and no networking calls. |
| `mod`, `app.ModSet`, `asset`, `script` | Existing ordered content and code lifecycle. A connection must not download, enable or execute a package. Lua binding 1 has no network authority. |
| `build.zig` | Enforced module imports, null/Metal/Vulkan builds and header-only consumer precedent. No network module exists. |

Do not serialize an `InputSnapshot`, C struct, ECS component or handle by copying its memory.
OS key codes, padding, pointer values and local entity generations are not a wire format.
Existing save/authoring formats remain unchanged.

## 3. Ownership and layers

Proposed additions, not a description of today's build graph:

```
platform (L1)  core; bounded byte streams, listeners, numeric endpoints, OS error mapping
net (L2)       core, platform; wire codec, peers, sessions, queues, grants and diagnostics
abi (L5)       existing imports + net; public argument validation and translation only
host           owns net.Service, endpoint grants, content identity, timing and subsystem life
sample client  public header only; command/state codecs and shared-world demonstration
```

`net` imports no `scene`, `data`, `app`, renderer, physics, authoring, ABI or Lua. Payloads are
copied bytes described by runtime channel registrations, not engine object pointers. `app`
does not gain `net`; `scene` does not gain `platform`. The host connects independently owned
services. Games that never create the service perform no networking and need no listener.

The service owns generational session and peer handles. Stream handles never leave `platform`
except as opaque generational identities. Destroying a session closes its listener and peers,
invalidates their handles, clears queued work and releases its budgets. Allocation failures
unwind without leaving a listener alive. A closed slot cannot confer a departed peer's rights
on its next occupant. One explicit main-thread owner; no detached threads or job-pool tasks.

Internal pumping accepts a monotonic elapsed-time value for connection/idle deadlines. Gameplay
sees only admitted tick-stamped data. Neither network I/O nor wall-clock calls enter a system
update, and no networking callback changes a world while a query is live.

## 4. Transport and bounded work

Initial backend: TCP streams, numeric IPv4 endpoints including loopback, explicit ports. IPv6,
DNS and discovery are not hidden requirements. Accept and connect are incremental; read and
write report progress, would-block, closed or a mapped failure. All operations have bounded
work and never wait for remote progress. Headless operation needs no SDL window or GPU.

`platform` contains the implementation over the pinned toolchain's facilities, or native OS
calls if required by the same contract. Step 2 records the concrete choice after inspecting
Zig 0.16; no guessed asynchronous API or new socket library is part of this design. Any need
for workers, extra dependency or a different ownership model stops that step for a Resolution.

Session configuration has explicit checked limits. Proposed reference defaults:

| Limit | Initial value |
| --- | --- |
| Sessions / remote peers per session | 1 / 4 |
| Registered application channels | 32 |
| Full-state channels per session | 1; the application defines its extensible complete-state payload |
| One complete frame, header included | 64 KiB |
| Per-peer receive storage / queued send storage | 256 KiB / 256 KiB |
| Service queued events, across all peers | 256, additionally bounded by 1 MiB of copied payloads |
| Read/write work per peer per pump | 64 KiB in each direction, at most 32 decoded frames |
| Admission/initial-sync deadline / no-progress deadline | 5 s / 10 s |

These are configurable host bounds, not allocations triggered by received lengths. Validate
aggregate limits and arithmetic before creation. Fair round-robin pumping and accept budgets
prevent a noisy peer from monopolizing a frame. Queues, partial headers, pending handshakes
and closed-peer diagnostics all count toward limits. A small peer limit alone is insufficient.
Timeouts depend on progress, not a byte dripped periodically; incomplete-frame lifetime is
bounded too. At expiry disconnect with a reason. A host polling no network cannot be held open
forever by a close handshake; shutdown is local and bounded.

An accepted send copies bytes. Refused enqueue changes no queue or sequence. Reliable commands
are never silently dropped. A slow peer that exhausts its budget disconnects, without blocking
others. Full state may replace a wholly unsent state frame for the same channel; once any byte
has entered the stream that frame finishes intact or the connection closes. Ordered transport
does not make a successful enqueue proof that the application applied the command.

## 5. Wire protocol and compatibility

Use explicit little-endian integer encoding, checked lengths and a wire version independent of
the C ABI version and the application payload revision. Never cast received bytes to a struct.
The fixed frame header is proposed as:

| Field | Encoding |
| --- | --- |
| Magic / protocol version / message kind | 4 bytes `FNET` / u16 / u16 |
| Total frame bytes / flags | u32 / u32; flags zero in version 1 |
| Connection sequence | u64, strictly increasing in each direction, starting at 1 |
| Channel content ID / simulation tick | u64 / u64; zero for control frames where unused |

The header is 40 bytes; frame length includes it. Refuse below-header/over-limit lengths before
allocating. No wrapping counters: refuse exhaustion and require a new session. Step 1 freezes
message-kind numbers, reserved-field rules and control payload layouts with golden fixtures
before another step depends on them. Unknown versions, kinds, flags, channels, role violations,
truncated EOF and malformed payload lengths fail closed; they never invoke gameplay.

Control messages cover hello, acceptance/refusal, initial-state acknowledgement, activation,
heartbeat and disconnect. Active idle clients answer bounded heartbeats; lack of gameplay
input alone is not a timeout. Heartbeats do not extend a stalled frame or write deadline.
Application messages are client commands and server state. The receiver derives
sender identity from its peer slot, never from a peer ID claimed inside a payload. The server
assigns a session epoch and participant number during admission; neither is authentication.

Hello compares a bounded compatibility description before admitting application messages:

- application namespaced ID, application protocol revision and host-declared compatibility ID;
- fixed tick rate, wire version, channel IDs/revisions/directions and their size limits;
- the effective ordered package set: package IDs, versions and SHA-256 of compiled `.fpk`
  bytes, plus a host-declared catalogue of simulation-relevant external assets/code inputs.

Catalogue entries use package ID and normalized package-relative identity with size/hash;
canonicalize their order within each package, preserving package load order itself. No absolute
paths, local handles or load-order-derived IDs cross the wire. Hash actual confined bytes, not
names/versions alone; bound entry count, total bytes and names before hashing/decoding. The host
builds and freezes the description before listen/connect. A mismatch identifies its category
and refuses; it does not fetch a replacement. A digest is compatibility evidence, not trust.

Platform-specific native binaries cannot be compared for byte equality across OSes. A host
enabling native gameplay must explicitly attest their common compatibility ID and channel
contract; the library cannot prove those binaries behave alike. The reference proof uses
content-only packages and its known application build, includes every external asset it uses,
and reports this limit. Presentation-only omissions from a real game's catalogue are an
explicit host policy, not an engine heuristic that labels unknown mod assets harmless.

Package, channel or gameplay-code changes invalidate a live session: disconnect and negotiate
again. M14 still applies package selections at next start; M8 hot reload remains available
offline, but the network proof must not run with an unannounced changed script revision.

## 6. Admission, authority and tick order

Connection states: connecting, negotiating, synchronizing, active, closed. Bound every
non-active state. No client commands reach the application before activation.

After compatibility passes, the server reports an admitted peer to its application. The
application creates the permitted participant and publishes a complete initial snapshot. This
baseline is retained unchanged for that peer until acknowledgement or timeout. The client
validates and applies it atomically, then explicitly acknowledges its snapshot revision through
the public API. Only the matching acknowledgement activates the peer; a fabricated or stale
acknowledgement is refused. Newer live state waits behind the baseline or replaces wholly
unsent live state, never the acknowledged baseline itself. An active notification establishes
the boundary after which input may be sent. Failure to construct/apply the baseline disconnects
the joining peer and releases its provisional participant.

At each server fixed tick:

1. Freeze the available admitted-command batch; later arrivals wait for the next tick.
2. Order it by server-assigned participant number, then accepted command sequence. Apply a
   per-peer/per-tick command budget. Overflow refuses/disconnects rather than spilling work
   without a defined bound. Record admitted tick and order for replay.
3. Validate game semantics and ownership before mutating state; invalid input cannot change
   somebody else's participant or request arbitrary entity/component writes.
4. Run the existing world's systems once, then publish full state stamped with that tick.

The host calls public service operations at those boundaries; it does not deliver commands
through a private callback to the sample. TCP arrival order across peers is not a deterministic
input specification. Replaying the captured admitted batches, same binary and seed, is.

The server never trusts a client-supplied simulation tick to rewind or fast-forward the world.
The first command protocol requests actions, not ticks or transforms. Client pending input is
bounded; disconnect and reconnect clear it rather than replaying it into a new participant.
Application-level rejected commands and acknowledgements are explicit in its state protocol.
Input that becomes stale is not silently reinterpreted as a current held key.

## 7. Replicated state and local identity

M16 supplies delivery, not a built-in gameplay schema. The reference application has a small
explicit codec for bounded commands and a full list of shared objects, their presentation
state, server tick and last-applied command sequences. Its values are fixed-width and checked;
unknown revisions, duplicate IDs, non-finite coordinates, bad ownership and excess counts
refuse the entire snapshot. Validate into bounded candidate storage before changing live state.

Wire object identity is `(session epoch, object number)`, with numbers assigned monotonically
by the authority and never reused in that session. Local ECS handles remain local. Reconcile a
candidate snapshot into a separate presentation model and its local entity map only after all
validation/allocation succeeds; failure preserves the last complete view and disconnects with
a diagnostic. Missing objects in a newer full snapshot are removals. A new epoch clears old
maps, outstanding input and interpolation history. A late snapshot cannot resurrect an object.

Clients do not advance authoritative gameplay while waiting. Rendering can interpolate two
validated states using presentation time, but interpolation never feeds back into the server
or world simulation. With no newer state, hold the last view and visibly report staleness;
there is no unbounded extrapolation. Input remains visibly pending until a server snapshot
acknowledges it. The server keeps running when one client stalls or disappears.

No generic field replication, entity-reference annotation system, interest management, delta
compression, persistent network IDs or world-save migration is required. An external game
may build different payload codecs over the same registered channel mechanism.

## 8. Public API and mod boundary

Proposed `FoundryApi_v5` appends to v4, leaving every older declaration and layout intact. The
exact C types, function names and count are frozen in Step 5's Resolution before coding them.
Required operation groups are concrete even though layouts are not yet frozen:

- enumerate host session grants; create/close a session by grant and read its state;
- register and enumerate channel descriptors before connection, using namespaced IDs,
  payload revisions, direction, delivery kind and maximum size; freeze on connection;
- start listen/connect using only the endpoint associated with the grant;
- enumerate/copy peer status, compatibility failures and bounded statistics;
- dequeue copied control/command/state events, preserving the event on insufficient capacity;
- enqueue copied commands or full state, with role/state/channel/size checks;
- acknowledge an applied initial snapshot and disconnect a peer with a bounded reason;
- admit the current server-tick input batch and read the admitted ordering.

Host bootstrap creates the service and supplies endpoint grants, compatibility inputs, limits
and elapsed-time pumping. It may not substitute private send/receive, replicated-state or
world-mutation callbacks for these operations. Public calls cannot nominate arbitrary addresses,
open a filesystem path, edit firewall settings or widen a grant. No service means `Unavailable`;
a present service with insufficient rights refuses distinctly. Native code is still
unsandboxed, and shared tables still do not implement per-mod security principals.

All handles are generational, incoming enum values validated integers, reserved bytes checked,
buffers bounded and inputs copied. Poll/read is nonblocking and has explicit ownership; no
borrow into a socket buffer survives a call. An undersized output buffer reports required size
without consuming the event. Reentrant or wrong-thread use follows the existing ABI policy.
The networking protocol never dispatches a remotely supplied public-API function index.

Native mods can use host-granted sessions and register channels before freezing. There is no
new Lua binding in M16: binding 1 remains v2-only, without sockets or networking calls. A
server may run its existing scripts against its own authoritative world under existing quotas;
that does not grant a client script authority or promise automatic script-state replication.
Channel registration must not be hardcoded to the sample or reserved to first-party code.

## 9. Reference application and external proof

Extend the sandbox with an opt-in connected demonstration; keep its offline path unchanged.
Use a separately compiled public-header-only consumer for shared-world commands, state and
presentation, following the editor-client boundary. The host owns startup, renderer/UI walks,
service grants and package loading. Controls, labels, speeds and visual assets come from the
sandbox's ordinary content package, not `engine/`. The demonstration consists only of moving
shared markers and their lifecycle, not a new game, lobby service or editor feature.

Offer explicit offline, server and client launch modes with numeric endpoints; default offline.
The server mode can present a window or run headlessly with a bounded test duration. It uses
the same fixed-tick simulation in either case. Headless pacing is explicit host policy, not a
busy loop made to look like network performance. Logs report local endpoint, role, peer counts,
admission/refusal reason and state tick without logging payloads or personal data by default.

On the two desktop targets, show a client controlling its assigned marker, the server and
another view observing it, late join, disconnect, fresh reconnect and mismatched-content refusal.
Use relocated installed artifacts, no compiler/SDK on PATH, scratch user directories and an
explicit package selection so ambient user mods cannot contaminate the evidence. Windows uses
the existing Vulkan target; networking itself does not depend on Vulkan. Linux remains
compile-only until M18, not newly runtime-qualified by successful socket cross-compilation.

Write `docs/modding/networking.md` from an external C99 consumer using only the installed
header and exported build helpers. It registers a channel with a non-sample namespace, sends
and receives a real application message against the reference host, and exercises a refused
operation. It uses no engine-private imports or repository-relative generated files. Include
how a host constructs grants/catalogues and the LAN/security limitations in that guide.

## 10. Verification, faults and acceptance evidence

Follow AGENTS.md's bounded verification per step: focused tests, fix/rerun only failures,
one integration gate, one documentation pass. Run the required implementation bar before
each implementation commit. Do not repeat M15 proofs to approve this documentation plan.

- **Codec:** golden bytes; all header truncations; split/coalesced frames; unknown enums,
  versions and flags; overflow, zero/maximum lengths, sequence exhaustion and malformed EOF.
  Bounded random hostile bytes must return a diagnostic, never assert or allocate unboundedly.
- **Transport:** real loopback on macOS and Windows; connection refusal, occupied bind,
  would-block, partial write, peer reset, close during connect/read/write and cleanup on OOM.
  Fake streams deterministically force fragmentation, stalled progress and queue saturation.
  Do not pretend TCP delivers reordered application bytes: inject corruption separately as
  malicious input; use delayed/stalled streams to model its loss consequences.
- **Session:** matching/mismatched catalogues, handshake timeout, command-before-active,
  stale/wrong baseline acknowledgement, partial baseline failure, reconnect generations,
  bounded pending accepts, noisy-peer fairness and one stalled peer alongside a healthy peer.
- **Authority/state:** forged ownership, invalid values, duplicate/old command sequence,
  future tick claims, duplicate object IDs, snapshot atomicity under allocation failure,
  removal/reconnect, stale snapshots and deterministic replay of admitted input batches.
- **ABI:** every new call with absent service, denied grant, stale/cross-session handles,
  wrong role/channel, null/short buffers and out-of-range integers. C/Zig agreement and the
  installed header as C99 on all three targets and C++17; v1–v4 prefix checks unchanged.
  Mutation-test the new version/length/authority guards and header-only import prohibition.
- **Integration:** multi-process null proof plus real desktop runs, cross-host in both roles,
  optimized Windows build, external C consumer, and both release stages if content/release
  descriptions changed. Preserve successful evidence unless subsequent changes invalidate it.

Measure maximum queue occupancy, per-pump work and shutdown completion under the stated test
load; record actual bounds and test conditions, not unsupported claims of internet robustness.
Public listeners, credentials, packet captures of unrelated traffic and firewall changes are
not authorized by running the milestone. If an environment blocks cross-host access, report
the precise missing evidence; loopback is not a replacement for it.

## 11. Open decisions and explicit limits

The owner-entry choices in §1 are still open. TCP/IPv4/trusted-LAN is the proposed first scope;
it is not an accepted answer for an unspecified public multiplayer game. Public networking
requires its security design before exposure. No new backlog system is introduced here.

Outside this proposal: matchmaking, relays, NAT traversal, accounts, encryption/authentication,
anti-cheat claims, host migration, resuming a departed participant, prediction/rollback,
lockstep and bit-exact physics, automatic content download, automatic component replication,
large-world interest management, remote editor/debug transport and new Lua networking bindings.
Existing open questions about per-mod tables, native unloading, system scheduling, save package
lists and editor features remain open. M17/M18 retain their own gates.

Three bounded implementation details require a dated Resolution before dependent code: Step
1's exact control payloads and counters; Step 2's pinned-toolchain transport mechanism; Step
5's v5 layouts/call count. Those may refine this contract, not silently change its scope,
module placement or authority model. No port numbers, machine names or personal paths belong
in committed configuration.

## 12. Implementation order

Every step below is **not started**. Each ends with its own tests, required bar, Resolution,
project-state update and focused commit, followed by a handoff. Do not chain steps without
the owner's instruction. Entry acceptance (§1) precedes Step 1, not an extra coding step.

### Step 1 — Define bounded channels and wire messages

Add `net` and its minimal downward imports; define checked limits, runtime channel descriptors,
wire headers/control payloads, incremental framing and the pure codec. Freeze exact wire v1
with golden byte fixtures and a dated Resolution. Test invalid bytes, partial frames and all
counter/length bounds. **No sockets, session lifecycle, ABI or sample changes.**

### Step 2 — Supply bounded platform streams

Implement opaque listeners/connections, numeric endpoints, nonblocking connect/accept/read/write,
error mapping and bounded cleanup in `platform`, with a deterministic fake transport for net
tests. Record the Zig 0.16 mechanism. Prove real loopback on macOS and Windows plus Linux
compile coverage; null operation must need no window. **No shared-world or ABI implementation.**

### Step 3 — Establish compatible sessions and peer lifetimes

Implement service/grants, generational session/peer storage, frozen channel/catalogue negotiation,
role checks, connection states, deadlines, queue budgets, fairness and structured diagnostics.
Host-supplied compatibility inputs are copied and bounded. Test mismatches, resource exhaustion,
partial I/O, teardown and fresh reconnect. **No ECS ownership or automatic package fetching.**

### Step 4 — Deliver tick-admitted commands and complete state

Implement admitted input batches, their stable ordering, copied command queues, replaceable
full-state delivery, retained initial baseline/acknowledgement and activation. Test initial
sync failures, slow peers, stale sequences and replay using an in-memory reference model.
The application owns payload validation and object maps. **No engine gameplay schema and no
private application path that will bypass Step 5.**

### Step 5 — Publish networking in the single public API

Freeze v5 types/call inventory, implement all §8 groups over the supplied service, add C/Zig
agreement and adversarial ABI tests, installed-header C99/C++ coverage, and teach native table
negotiation to offer v5. Keep v1–v4 and Lua binding 1 unchanged. Test absence/denial explicitly.
**No sample consumer before the public capability exists.**

### Step 6 — Connect the reference sandbox through that API

Add opt-in host modes and the separate header-only consumer, runtime-registered command/state
channels, content-defined marker behaviour, authoritative ticking, local presentation maps,
initial synchronization and visible connection state. Headless multi-process input proves the
same path. Show the real two-window result on the primary desktop, retain offline behaviour,
and stage required releases. **No general lobby or gameplay feature expansion.**

### Step 7 — Prove refusal, authority and deterministic replay

Complete §10's adversarial/failure matrix through the public consumer: forged input, corrupted
frames, compatibility refusal, constrained allocations, stalled clients, bounded fairness,
late join and reconnect. Replay recorded admitted batches and compare server state for the
same binary/seed. Measure work/storage bounds. Reuse prior successful codec/ABI evidence;
run new combinations, not duplicate reviews. **No cross-platform bit-exact simulation claim.**

### Step 8 — Prove both desktops and an external consumer

Run the relocated macOS/Metal and Windows/Vulkan applications, with each machine serving the
other, real input and no runtime toolchain requirement. Exercise join/disconnect/rejoin and
content mismatch, and record latency/stall limits honestly. Build and run the external C99
consumer; write the networking guide from that experience. **No Linux runtime certification
or public-internet security claim.** Missing target access is reported, not waived.

### Step 9 — Close M16 against its accepted scope

Review the exit evidence once, fix concrete gaps, run the required final integration gate,
and update design Resolutions, API/platform documents, README, roadmap, AGENTS and project
state consistently. List the actual deployment limit and remaining decisions. Tag `m16` only
when the accepted entry scope and two-process/public-consumer exit are met. **Do not start
M17 review/polish/release work or M18 qualification as part of closure.**
