# Network sessions and the shared-world proof

**Milestone:** M16 — Connected: “it plays with others”
**Status:** Accepted design, 2026-09-21. **Complete 2026-09-23: all nine steps, tagged `m16`.**
**Revision, 2026-09-21:** the owner selected **public-internet multiplayer**. The earlier
LAN-only scope is withdrawn. Internet security and a real WAN proof are required in M16. The
owner's instruction to begin Step 1 accepted the authority, topology, admission and bounded
reference-envelope choices below.
**Decisions:** accepted [ADR-0044](../adr/0044-authoritative-network-sessions.md) and
[ADR-0045](../adr/0045-bounded-direct-connect-transport.md).
**Built on:** ADR-0004/0005/0007/0010/0013/0017/0026/0029/0036/0039;
`entity-storage.md`, `app-and-frame-loop.md`, `platform-interface.md`, `public-abi.md`.

## 1. Entry gate and runnable result

M15 is complete at `94bc204`, tagged `m15`; its accepted tests are not repeated for this
planning change. The owner requested M16 planning, explicitly required public-internet
multiplayer for the first networked game, and then instructed implementation to begin at Step
1. That accepts the bounded entry scope below.

**Accepted:** one operator-hosted authoritative server at a reachable internet endpoint,
TLS 1.3 mutually authenticated clients, explicit commands and full state snapshots:

1. Authoritative rather than lockstep simulation.
2. Operator-hosted direct connection and provisioned player certificates, rather than
   anonymous/account-based joins or player-hosted sessions requiring NAT traversal/relays.
3. The initial scale: one server and up to four remote peers in the reference proof, with no
   client prediction, under §10's accepted measurable WAN envelope. This is not a promise
   that all competitive-action games fit that envelope.

Acceptance is recorded in the two ADRs and this status; it is not inferred from M15's
completion. Step 1 implements qualification and the pure wire contract only. It adds no
socket, session, ABI or sample behavior.

**Exit:** two independently launched processes visibly share an authoritative world. A client
can affect only what the server permits; late join receives current state, disconnect removes
the departed participant, and reconnect creates a fresh participant without stale authority.
Run same-host proofs, a macOS/Windows cross-host proof with each host acting as server, and
an actual public-internet server with clients on independent networks. Authentication,
confidentiality/integrity, replay refusal, credential lifecycle and abuse limits are exit gates.
The engine capability must be usable through the public table, including from outside this
repository. A local simulation with two viewports or a fake transport alone does not pass.

LAN-only success cannot close M16. Report the tested internet deployment and its limits;
do not equate authenticated transport with anti-cheat or volumetric-DDoS protection.
Matchmaking, lockstep, prediction and general automatic ECS replication remain outside scope.
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
| `build.zig`, `net` | Enforced imports now place the Step 1 `net` module at L2 with only `core` and `platform`; it contains limits, channel descriptors, the pure wire codec and, since Steps 3–4, the session `Service` and what it delivers; the transport is `platform`'s. |

Do not serialize an `InputSnapshot`, C struct, ECS component or handle by copying its memory.
OS key codes, padding, pointer values and local entity generations are not a wire format.
Existing save/authoring formats remain unchanged.

## 3. Ownership and layers

The first two lines describe today's build graph; later lines remain the accepted destination:

```
platform (L1)  core + the qualified provider; Step 2's authenticated streams (`Transport`)
net (L2)       core, platform; Step 1 limits/channels/codec; Steps 3–4's `Service`: admission, baselines, batches, state
abi (L5)       existing imports + net (since Step 5); public argument validation and translation only
host           owns net.Service, endpoint grants, content identity, timing and subsystem life
sample client  public header only; command/state codecs and shared-world demonstration
```

`net` imports no `scene`, `data`, `app`, renderer, physics, authoring, ABI or Lua. Payloads are
copied bytes described by runtime channel registrations, not engine object pointers. `app`
does not gain `net`; `scene` does not gain `platform`. The host connects independently owned
services. Games that never create the service perform no networking and need no listener.

The service owns generational session and peer handles. TLS-provider types and secrets remain
inside `platform`, with host-owned credential contexts and copied public identity results.
The external C dependency is an implementation detail like SDL, not a sideways engine import.
Stream handles never leave `platform`
except as opaque generational identities. Destroying a session closes its listener and peers,
invalidates their handles, clears queued work and releases its budgets. Allocation failures
unwind without leaving a listener alive. A closed slot cannot confer a departed peer's rights
on its next occupant. One explicit main-thread owner; no detached threads or job-pool tasks.

Internal pumping accepts a monotonic elapsed-time value for connection/idle deadlines. Gameplay
sees only admitted tick-stamped data. Neither network I/O nor wall-clock calls enter a system
update, and no networking callback changes a world while a query is live.

## 4. Transport and bounded work

Accepted transport: TLS 1.3 over TCP, numeric IPv4 endpoints including loopback, explicit ports
and separately granted authenticated server identity. IPv6, DNS and discovery are not hidden
requirements. No plaintext application path, even for local sample runs. Accept, connect and
TLS handshake are incremental; read/write report progress, would-block, closed or a mapped
failure. Work is bounded; nothing waits for remote progress. Headless operation needs no GPU.

`platform` will contain the implementation over the pinned toolchain's facilities, or native OS
calls if required by the same contract. Step 1 selected and qualified Mbed TLS 3.6.7 LTS under
Apache-2.0; ADR-0045 and the Resolution below record the archive/hash, configuration,
transitive-license and advisory review. Step 2 recorded the concrete Zig 0.16 transport
mechanism — the OS's own nonblocking sockets, called from C, because `std.Io.net` blocks — in its
Resolution below. Zig compiles the provider directly; no CMake/Make/Python path was added. It
needed no worker and no different ownership model.

Session configuration has explicit checked limits. Accepted reference defaults:

| Limit | Initial value |
| --- | --- |
| Sessions / remote peers per session | 1 / 4 |
| Concurrent unauthenticated TLS handshakes | 8, separate from the admitted-peer pool |
| Starts limiter table | 256 source-IP entries; exhaustion falls back to the global limiter |
| Aggregate TLS allocation cap | 16 MiB, qualification must demonstrate enforcement |
| TLS progress per peer | 1 provider handshake call per pump; 64-call connection cap |
| Certificate chain / encoded chain bytes | 4 certificates / 32 KiB |
| Starts of TLS handshakes | global 8/s, burst 8; per source IP 2/s, burst 2 |
| Compatibility description | 256 items / 16 KiB of fixed wire entries |
| Registered application channels | 32 |
| Full-state channels per session | 1; the application defines its extensible complete-state payload |
| One complete frame, header included | 64 KiB |
| Per-peer receive storage / queued send storage | 256 KiB / 256 KiB |
| Service queued events, across all peers | 256, additionally bounded by 1 MiB of copied payloads |
| Read/write work per peer per pump | 64 KiB in each direction, at most 32 decoded frames |
| Admission/initial-sync deadline / no-progress deadline | 5 s / 10 s |
| Allowlisted client identities (added in Step 3) | 256 |
| Close linger, to deliver a last refusal or disconnect (added in Step 3) | 1 s |
| Commands admitted per peer per server tick (added in Step 4) | 16; later ones wait in the peer's bounded inbox |

These are configurable host bounds, not allocations triggered by received lengths. Validate
aggregate limits and arithmetic before creation. Fair round-robin pumping and accept budgets
prevent a noisy peer from monopolizing a frame. Queues, partial headers, pending handshakes
and closed-peer diagnostics all count toward limits. A small peer limit alone is insufficient.
The per-source limiter has a bounded table; exhaustion falls back to stricter global refusal,
not unbounded allocation or forgotten rate limits. IP addresses are abuse signals, not player
identity; shared-NAT clients can legitimately hit those limits. Bound cryptographic work per
pump as well as bytes: Step 1 qualifies allowed algorithms/key sizes and worst-case handshake
cost. If the provider cannot meet that budget, revise the design instead of blocking frames.
Timeouts depend on progress, not a byte dripped periodically; incomplete-frame lifetime is
bounded too. At expiry disconnect with a reason. A host polling no network cannot be held open
forever by a close handshake; shutdown is local and bounded.

An accepted send copies bytes. Refused enqueue changes no queue or sequence. Reliable commands
are never silently dropped. A slow peer that exhausts its budget disconnects, without blocking
others. Full state may replace a wholly unsent state frame for the same channel; once submitted
to TLS, including an operation awaiting retry, that frame is immutable until its pending write
finishes or the connection closes. Ordered transport
does not make a successful enqueue proof that the application applied the command.

### 4.1 Threat model, authentication and credential lifecycle

Protect against an unauthenticated remote connector, an on-path observer/modifier/replayer,
and a malicious admitted player. Trust the operator's server, approved TLS implementation,
host OS and out-of-band provisioning. A compromised endpoint, stolen currently authorized
key or malicious native mod inside a host is outside transport containment. Application
ownership checks remain mandatory even after successful TLS authentication.

- Require TLS 1.3, certificate verification on both sides, approved trust roots, expected
  server identity and allowed client certificate identities. Use a dedicated public
  certificate/key fingerprint mapped to a host-local participant principal; never trust an
  arbitrary certificate display name. Validate chain signatures, validity, key use and role.
  Also compare the provisioned server fingerprint; connecting to an IP is not permission to
  skip verification. Trust roots and pins arrive out of band, never from that connection.
- Use OS cryptographic entropy, never `core`'s deterministic simulation RNG. Certificate time
  checks use OS civil time in `platform`; connection deadlines use monotonic time outside
  simulation. Unavailable entropy, invalid time or verification failure refuses startup/join.
- Disable TLS early data and resumption initially. Every connection authenticates freshly.
  TLS record protection handles wire tampering/replay; application sequences additionally
  reject duplicate commands by an admitted peer. Neither replaces the other. Configure an
  application protocol identifier for FNET and refuse other protocols; no TLS downgrade or
  certificate-error override is offered to the sample or public API.
- Provision separate server and player keys using established operator tooling, never a
  Foundry-designed certificate issuer or shared embedded secret. The guide must walk trust
  distribution, key generation, issuance, secure file permissions, expiry, renewal and removal
  without secret command-line values or checked-in credentials. Platform secure-store support
  is optional; host-confined read-only credential files are sufficient for the initial proof.
  No production private keys, trust configuration or personal identity files enter packages,
  source, environment variables, crash logs, TLS key logs or captures. Tests generate disposable
  identities in scratch storage, with an explicitly supplied test clock when needed.
- Client admission is a bounded local allowlist after certificate validation. Removing an
  identity closes its live peers and denies future joins; the host can reload this allowlist
  independently of gameplay content. A trust/key rotation can deliberately close all sessions
  and require reconnect. Fail closed on an invalid replacement, retaining the last valid
  policy without pretending the requested rotation succeeded. A removed/expired identity
  cannot reuse a live session indefinitely: revalidate policy/expiry during pumping.
- Credentials and the verified remote principal stay in the transport/service, not mod
  payloads. The API exposes a non-secret session-local peer identity and diagnostic category.
  One principal has at most one active connection in the reference host; a second is refused,
  not allowed to evict the first or inherit its participant. Reconnect means a new participant.

M16 must prove rejection of missing/unknown/expired/not-yet-valid/wrong-use certificates,
incorrect server identity, denied/revoked clients, tampered records and replay. Mutual TLS
is not a moderation/account product; it is the accepted initial admission mechanism.

### 4.2 Public deployment and operational bounds

The operator supplies a reachable server, egress for clients and explicit permission to use
that endpoint. No automatic router/firewall changes, cloud provisioning, purchases, background
service installation or public exposure follow from this plan. Clients behind ordinary NAT
connect outbound; a player behind carrier NAT is not thereby able to host. If player-hosting
is required, design relay/traversal before promising it. Linux servers remain outside the
runtime claim until M18; qualify this milestone's server on macOS or Windows.

Cap accepts, handshake attempts/computation/allocations, authenticated bytes and command rate,
and log frequency. Do not let bad certificates fill the active-peer pool. Refusal messages
before authentication are generic and bounded. Do not persist peer IPs or certificate details
by default. Healthy established peers must continue under the finite adversarial load in §10.
These application bounds cannot prevent an upstream bandwidth flood; hosting/firewall/DDoS
protection is operator responsibility, explicitly outside the tested resilience claim.

Before an internet proof or shipped network release, check advisories against the exact TLS
pin and configuration. Relevant unfixed security issues block exposure. Record required fixes
and repeat the affected security/interoperability checks after updating; do not treat version
pinning as a reason to ship a known vulnerable configuration. No toolchain upgrade is implied.

## 5. Wire protocol and compatibility

FNET messages exist only inside the authenticated TLS stream. Use explicit little-endian
integer encoding, checked lengths and a wire version independent of
the C ABI version and the application payload revision. Never cast received bytes to a struct.
The fixed frame header is:

| Field | Encoding |
| --- | --- |
| Magic / protocol version / message kind | 4 bytes `FNET` / u16 / u16 |
| Total frame bytes / flags | u32 / u32; flags zero in version 1 |
| Connection sequence | u64, strictly increasing in each direction, starting at 1 |
| Channel content ID / simulation tick | u64 / u64; zero for control frames where unused |

The header is 40 bytes; frame length includes it. Refuse below-header/over-limit lengths before
allocating. No wrapping counters: refuse exhaustion and require a new session. The pure codec
rejects zero and exposes a checked increment; Step 3 owns per-peer strictly-increasing sequence
enforcement. Unknown versions, kinds, flags, channels, role violations, truncated EOF and
malformed payload lengths fail closed; they never invoke gameplay.

Wire-v1 message kinds are frozen: client hello `1`, server hello `2`, compatibility item `3`,
channel descriptor `4`, negotiation finished `5`, refusal `6`, baseline `7`, baseline
acknowledgement `8`, active `9`, command `10`, state `11`, heartbeat `12`, disconnect `13`.
All unlisted values and all reserved nonzero bytes are invalid. Fixed payloads are:

| Kind | Exact little-endian payload |
| --- | --- |
| client hello (56 bytes) | application ID u64, application revision u32, tick rate in millihertz u32, compatibility ID 32 bytes, catalogue count u16, channel count u16, reserved-zero u32 |
| server hello (72 bytes) | application ID u64, revision u32, tick rate u32, compatibility ID 32 bytes, session epoch u64, participant number u32, catalogue count u16, channel count u16, peer limit u16, six reserved-zero bytes |
| compatibility item (64 bytes) | kind u8, three reserved-zero bytes, namespaced item ID u64, semantic version as three u32 values, byte count u64, SHA-256 32 bytes |
| channel descriptor (24 bytes) | channel ID u64, revision u32, maximum payload u32, direction u8, delivery u8, six reserved-zero bytes |
| negotiation finished (64 bytes) | catalogue SHA-256 then channel-description SHA-256 |
| refusal (8 bytes) | reason u16, detail index u16, reserved-zero u32 |
| baseline acknowledgement (24 bytes) | session epoch u64, baseline sequence u64, baseline tick u64 |
| active (16 bytes) | session epoch u64, participant number u32, reserved-zero u32 |
| heartbeat (16 bytes) | session epoch u64, last received sequence u64; zero is allowed before any frame |
| disconnect (8 bytes) | reason u16, six reserved-zero bytes |

Baseline, command and state payloads are application bytes constrained by their registered
channel and the 64-KiB complete-frame cap. Compatibility item kinds are package `1`, gameplay
asset `2`, native code `3` and script code `4`; a package uses its namespaced package ID, and
an external input uses the namespaced `ContentId` derived from its normalized package-relative
identity. Step 3 must reject duplicate IDs while building the frozen catalogue. Exact golden
fixtures in `wire.zig` cover the header and every fixed payload.

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

Connection states: connecting, authenticating, authorizing, negotiating, synchronizing,
active, closed. Bound every non-active state. No FNET input reaches negotiation until TLS
verification and local identity admission pass; no commands reach gameplay before activation.

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

Host bootstrap creates the service and supplies endpoint/credential grants, identity policy,
compatibility inputs, limits and elapsed-time pumping. Secrets are not arguments to ABI calls;
grants refer to already constructed credential contexts. Authentication status/refusal is part
of public peer diagnostics. It may not substitute private send/receive, replicated-state or
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

Offer explicit offline, server and client launch modes with numeric endpoints and host-only
credential-file references; default offline. Never offer an insecure or verify-disabled mode.
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
how a host constructs grants/catalogues, provisions and rotates credentials, revokes a player,
and deploys the authenticated server. Include actual security and performance limits.

The public-internet proof uses an authorized reachable server and macOS/Windows clients on
separate internet access networks, not two machines on the same LAN, a local tunnel or an SSH
forward. Authenticate all peers and capture only controlled test traffic to demonstrate no
plaintext FNET/game payload. That observation alone does not prove cryptographic security:
provider verification and negative certificate/tamper tests are separate required evidence.
No real private keys or addresses need be committed; record topology generically and hashes
of tested builds/configuration with secrets excluded. Missing infrastructure blocks this proof.

## 10. Verification, faults and acceptance evidence

Follow AGENTS.md's bounded verification per step: focused tests, fix/rerun only failures,
one integration gate, one documentation pass. Run the required implementation bar before
each implementation commit. Step 1's focused codec/provider evidence is recorded below; later
steps do not repeat it unless their changes can invalidate it.

- **Codec:** golden bytes; all header truncations; split/coalesced frames; unknown enums,
  versions and flags; overflow, zero/maximum lengths, sequence exhaustion and malformed EOF.
  Bounded random hostile bytes must return a diagnostic, never assert or allocate unboundedly.
- **Transport:** real loopback on macOS and Windows; connection refusal, occupied bind,
  would-block, partial write, peer reset, close during connect/read/write and cleanup on OOM.
  Fake streams deterministically force fragmentation, stalled progress and queue saturation.
  Do not pretend TCP delivers reordered application bytes: inject corruption separately as
  malicious input; use delayed/stalled streams to model its loss consequences.
- **Security:** qualified provider/configuration, positive mutual authentication, every §4.1
  refusal, downgrade/early-data refusal, identity withdrawal on live peers, rotation/expiry,
  wrong trust roots, tampered/replayed TLS records and application messages, secure failure
  on entropy/clock/credential errors, and no secret-bearing diagnostics. Mutation-test a
  disabled certificate check and a bypassed allowlist; both must fail their focused guards.
- **Pre-authentication abuse:** exceed accept/handshake rates with invalid and stalled TLS
  clients; exhaust limiter slots/certificate bounds/TLS budget; verify bounded work, no leaked
  descriptors, rate-limited logs and continued established-peer service. TLS CPU/memory is
  measured separately from FNET queues; encrypted transport is not itself a DoS defense.
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
  actual authenticated public-internet deployment across independent client networks,
  optimized Windows build, external C consumer, and both release stages if content/release
  descriptions changed. Preserve successful evidence unless subsequent changes invalidate it.

Measure maximum queue occupancy, per-pump work and shutdown completion under the stated test
load; record actual bounds and test conditions, not unsupported claims of internet robustness.
The accepted reference workload is four peers, state payloads at most 1 KiB at 20 Hz and
60 Hz server simulation. For ten minutes under a controlled stream harness imposing 150 ms
round-trip delay, up to 30 ms additional jitter, 1 Mbit/s each direction per peer and one
250 ms head-of-line stall every five seconds, require p95 command-to-visible-acknowledgement
at most 500 ms, no unintended disconnect, and no state older than two seconds outside an
explicitly injected disconnect. This models stream stalls, **not a measured packet-loss
percentage**. Also record actual RTT and input acknowledgement latency on the real WAN path.
If this budget or the real experience is unacceptable, revise transport/prediction scope
before closure; a secure but unusable connection does not meet “plays with others.”

Real public listeners, production credentials, captures and firewall changes need explicit
operator authorization for the selected infrastructure. If an environment blocks internet
access, report the precise missing evidence; loopback or a fake WAN is not a replacement.

## 11. Open decisions and explicit limits

Public-internet scope and §1's authority, operator-hosted topology, provisioned-certificate
admission and initial performance envelope are settled. Mbed TLS 3.6.7 LTS and its exact
configuration passed Step 1's qualification. No new backlog system is introduced here, and
security is not deferred to M17.

Outside this milestone: matchmaking, relays, automatic NAT traversal, account services,
anti-cheat claims, host migration, resuming a departed participant, prediction/rollback,
lockstep and bit-exact physics, automatic content download, automatic component replication,
large-world interest management, remote editor/debug transport and new Lua networking bindings.
Existing open questions about per-mod tables, native unloading, system scheduling, save package
lists and editor features remain open. M17/M18 retain their own gates.

Step 1's provider/configuration and wire layouts, Step 2's transport mechanism, Step 3's
negotiation exchange, Step 4's delivery order, Step 5's v5 layouts and call count and Step 6's
sample protocol and credential file, and Step 7's protocol revision 2, envelope harness and
measured bounds, and Step 8's deployment findings, are resolved
below. No bounded implementation detail now awaits a Resolution before dependent code. No port numbers, machine names or personal paths belong in
committed configuration.

## 12. Implementation order

All nine steps are complete (2026-09-23). Each ended with its own tests, required bar,
Resolution, project-state update and focused commit, followed by a handoff. Do not chain steps
without the owner's instruction.

### Step 1 — Qualify security and define bounded wire messages — **complete 2026-09-21**

Qualify the selected TLS provider against §4: license and exact supported release/hash,
security advisories, Zig-only native/cross-build, mutual-authentication test endpoints in
memory, bounded resource use, certificate verification, OS entropy and timing interfaces.
Record the provider/configuration before dependent code. A failed qualification stops for
a design revision, not an insecure fallback. Add `net` and its minimal downward imports;
define checked limits, runtime channel descriptors, wire headers/control payloads,
incremental framing and the pure codec. Freeze exact wire v1
with golden byte fixtures and a dated Resolution. Test invalid bytes, partial frames and all
counter/length bounds. **No sockets, session lifecycle, ABI or sample changes.**

### Step 2 — Supply bounded authenticated platform streams — **complete 2026-09-21**

Implement opaque listeners/connections, numeric endpoints, nonblocking connect/accept/read/write,
TLS handshake/read/write, credential contexts, verified peer identities, error mapping and
bounded cleanup in `platform`, with a deterministic fake transport for net tests. Prove real
mutually authenticated loopback on macOS and Windows plus Linux compile coverage, certificate
failure paths and no plaintext fallback. Record the Zig 0.16 mechanism. Null operation needs
no window. **No public listener, shared-world or ABI implementation.**

### Step 3 — Establish compatible sessions and peer lifetimes — **complete 2026-09-22**

Implement service/grants, generational session/peer storage, frozen channel/catalogue negotiation,
authenticated identity allowlists/revocation, role checks, connection states, pre-auth limits,
deadlines, queue budgets, fairness and structured diagnostics.
Host-supplied compatibility inputs are copied and bounded. Test mismatches, resource exhaustion,
partial I/O, teardown and fresh reconnect. **No ECS ownership or automatic package fetching.**

### Step 4 — Deliver tick-admitted commands and complete state — **complete 2026-09-22**

Implement admitted input batches, their stable ordering, copied command queues, replaceable
full-state delivery, retained initial baseline/acknowledgement and activation. Test initial
sync failures, slow peers, stale sequences and replay using an in-memory reference model.
The application owns payload validation and object maps. **No engine gameplay schema and no
private application path that will bypass Step 5.**

### Step 5 — Publish networking in the single public API — **complete 2026-09-22**

Freeze v5 types/call inventory, including grant/authentication diagnostics but no secret access;
implement all §8 groups over the supplied service, add C/Zig agreement and adversarial ABI
tests, installed-header C99/C++ coverage, and teach native table
negotiation to offer v5. Keep v1–v4 and Lua binding 1 unchanged. Test absence/denial explicitly.
**No sample consumer before the public capability exists.**

### Step 6 — Connect the reference sandbox through that API — **complete 2026-09-23**

Add opt-in host modes and the separate header-only consumer, runtime-registered command/state
channels, content-defined marker behaviour, authoritative ticking, local presentation maps,
initial synchronization, operator credential references and visible authentication/connection
state. Headless multi-process input proves the same path. Show the real two-window result on
the primary desktop, retain offline behaviour,
and stage required releases. **No general lobby or gameplay feature expansion.**

### Step 7 — Prove refusal, authority and deterministic replay — **complete 2026-09-23**

Complete §10's adversarial/failure matrix through the public consumer: forged input, corrupted
frames, credential refusal/revocation/rotation, TLS replay/tamper, pre-authentication floods,
compatibility refusal, constrained allocations, stalled clients, bounded fairness, late join
and reconnect. Replay admitted batches and compare server state for the same binary/seed.
Measure work/storage bounds and the controlled WAN envelope. Reuse prior successful evidence;
run new combinations, not duplicate reviews. **No cross-platform bit-exact simulation claim.**

### Step 8 — Prove public-internet play, both desktops and an external consumer — **complete 2026-09-23**

Run the relocated macOS/Metal and Windows/Vulkan applications, with each machine serving the
other, real input and no runtime toolchain requirement. Then prove an authorized internet
server with clients on independent networks, authenticated join/disconnect/rejoin, rejected
identities and content mismatch. Record observed WAN conditions and limits. Build/run the
external C99 consumer; write the networking and credential-operations guide from that
experience. **No Linux runtime certification or blanket anti-cheat/DDoS claim.** Missing
target/infrastructure access is reported, not waived; LAN success cannot close this step.

### Step 9 — Close M16 against its accepted scope — **complete 2026-09-23**

Review the exit evidence once, fix concrete gaps, run the required final integration gate,
and update design Resolutions, API/platform documents, README, roadmap, AGENTS and project
state consistently. List the actual deployment limit and remaining decisions. Tag `m16` only
when the accepted entry scope, security and real-internet/public-consumer exit are met. **Do not start
M17 review/polish/release work or M18 qualification as part of closure.**

---

## Resolution — 2026-09-21, Step 1: a qualified provider and a frozen bounded wire

Step 1 built no transport. What it produced is the provider decision §4 demanded before
dependent code, and the pure message layer Step 2 will carry.

**The `net` module is L2 and cannot connect anything.** `engine/src/net/` holds `limits.zig`
(the accepted envelope as `struct` constants plus the validators that reject a structural
excess), `channel.zig` (message kind, direction and delivery as closed enums), `wire.zig` (the
FNET wire-v1 header codec and one decoder per payload, over an explicit byte source) and
`root.zig`. `build.zig`'s layering table grants the module `core` and `platform` only. There is
no service, listener, socket, session, credential context or ABI entry point, and no sample
reaches it: `net` is compiled and tested, never linked into a host that can talk. Its fifteen
declarations (three limits, three channel, eight wire, one aggregator) run in the ordinary
headless graph.

**Wire v1 is frozen with golden bytes.** Every message is a 40-byte little-endian header
(kind, protocol version, byte order, payload length, sequence, participant, tick, two reserved
fields) and a fixed per-kind payload: thirteen kinds from the handshake through the disconnect.
`wire.zig` encodes and decodes each with bounds checked against `limits.zig` before a length
can index anything, checks the `FNET` magic and the protocol version, refuses a non-little-endian
peer, and advances the accepted sequence as an exact increment. The golden fixtures in the file
are the layout's test, so a later step cannot drift a field silently.

**The provider is qualified, not merely pinned.** Mbed TLS 3.6.7 LTS is pinned in
`build.zig.zon` (archive SHA-256 and Zig package hash both recorded), Apache-2.0 is elected over
`GPL-2.0-or-later`, and the archive's disabled Project Everest and p256-m implementations are
neither enabled nor compiled. `engine/src/platform/foundry_mbedtls_config.h` supplies the
external configuration, `build.zig` names an explicit C-source inventory that excludes the
socket and timing helpers, and `THIRD_PARTY_LICENSES/mbedtls.md` records the version, provenance,
election and distribution status. The advisory index and 3.6.7 ChangeLog review is in ADR-0045.

`engine/tests/tls_qualification.{c,zig}` is the harness; `zig build tls-qualification` runs it
alone, and the ordinary `test` and `check` graphs carry it, including both required cross
targets. Two peers exchange records over fixed 64-KiB in-memory BIOs and it proves TLS 1.3
mutual authentication, the exact ciphersuite/group/signature/ALPN allowlist, bidirectional
peer-certificate verification, application bytes in both directions, OS entropy seeding, an
injected certificate clock, wrong-server-name refusal and missing-client-certificate refusal.
Measured peaks: **98,845 allocator-accounted bytes, at most 1,039 queued wire bytes and four
provider handshake calls**, under committed caps of 16 MiB, 64 KiB and 64 calls. The allocation
and call peaks are deterministic; the wire high-water mark varies with how the two peers'
handshake calls interleave, so ADR-0045 now states it as an observed maximum rather than a
single value, and corrects an earlier 98,893 to the measured 98,845.

**What the bar caught that nothing else would.** The Windows cross-compile check failed while
the native macOS run passed: Mbed TLS's X.509 IP-SAN parser selects the platform `inet_pton`
under MinGW (`_WIN32_WINNT >= 0x0600`), so the qualification must link `ws2_32` on Windows
alongside `bcrypt`. Neither opens a socket — records still cross only in memory — and ADR-0045
records the requirement. Only the cross-target check could see it.

**The bar is green.** `zig fmt --check` is clean; `zig build test` passes **1,602 of 1,603
headless tests** (the one skip predates M16) from **1,667 declared**; `check` passes natively,
under `-Drhi=metal`, and for the Linux-null and Windows-null cross targets; and both samples run
thirty frames headless. Step 1 adds no ABI call, so no C consumer recompile was due.

**Deliberately not done.** No socket, listener, connection, credential context or stream handle
exists, and none of the provider's types escapes L1. `networking.md` §6's connection states,
§5's credential lifecycle and §7's ABI additions are untouched. Step 2 must record Zig 0.16's
concrete nonblocking socket mechanism and implement the opaque boundary ADR-0045 describes;
passing an in-memory provider test is not a claim that a native transport, partial-I/O, cleanup
or real loopback path exists. §11's open questions stay open, and design authorization still
does not authorize infrastructure purchases, firewall changes, real credentials or a public
listener.

---

## Resolution — 2026-09-21, Step 2: authenticated streams, and no way around them

Step 2 built the transport §3 and §4 describe and nothing above it: `platform.Transport` —
listeners, connections and credentials behind generational handles — carrying TLS 1.3 with
mutual authentication over the OS's TCP or a deterministic in-process carrier. `net` gained no
code; sessions, allowlists and deadlines are Step 3's.

**The Zig 0.16 mechanism is the OS's own nonblocking sockets, called from C.** Verified against
the pinned compiler rather than its documentation: `std.Io.net` performs every operation as a
blocking call through an `Io` implementation — `std.Io.Threaded`'s connect with a timeout is
`@panic("TODO …")`, its read treats `EAGAIN` as a programming bug, and on Windows it drives AFD
directly — and `std.os.windows.ws2_32` declares Winsock's constants but not one function. A
would-block contract on one owning thread cannot be built on that without the worker §3 forbids.
`engine/src/platform/transport/socket.c` therefore calls BSD sockets on macOS and Linux and
Winsock 2 on Windows, compiled against each target's own headers, so no layout, flag or error
number is transcribed by hand. Readiness is a zero-timeout `poll`, or `select` on Windows, whose
exception set is the documented report of a failed nonblocking connect. `MSG_NOSIGNAL` or
`SO_NOSIGPIPE` keeps a peer's reset from raising a signal; `FD_CLOEXEC` and
`WSA_FLAG_NO_HANDLE_INHERIT` keep sockets out of child processes; every connection sets
`TCP_NODELAY`. Listeners use `SO_REUSEADDR` on POSIX and `SO_EXCLUSIVEADDRUSE` on Windows, whose
`SO_REUSEADDR` would let another process take the port. No thread, `Io` instance or callback into
a caller exists. `platform-interface.md` part six records what this did to that layer.

**`tls.c` applies Step 1's qualified configuration at runtime and adds two rules of Foundry's
own**, both within §4.1's mandate to verify "key use and role" and the provisioned server key:

- **A peer's leaf certificate must carry an extendedKeyUsage naming its role** — serverAuth for
  a server, clientAuth for a client. The provider checks the extension only when it happens to be
  present, so it would accept an identity issued without one in either role.
- **A client pins the server's key**: the SHA-256 of its SubjectPublicKeyInfo, provisioned out of
  band. A key rather than a certificate, so a renewal that keeps its key keeps its pin; the value
  is what `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256`
  prints. It is compared inside certificate verification, so a mismatch ends the handshake rather
  than being discovered after it. The name check is separate and still required: a numeric
  destination never replaces the granted server name.

Credentials are refused at creation, with a reason and before any peer sees them, when the key is
not the certificate's, not P-256, or the certificate does not name the role it is used in; a
client must name the server and pin its key, and a server must do neither. PEM or a single DER
certificate is accepted; an encrypted key is refused, because no password is ever an argument. A
chain may hold four certificates. The certificate clock is the OS civil clock, read before every
handshake call; one earlier than 2026-01-01 — a machine whose clock was never set — refuses rather
than guesses. Completion further requires a verified peer key and both sides' agreement on
`fnet/1`; a peer that names no protocol is refused rather than assumed.

**`platform.Transport` owns everything with a lifetime** (`engine/src/platform/transport.zig`).
A stream is `connecting`, `handshaking`, `established`, `closed` (the peer's close_notify) or
`failed`, and `read`/`write` refuse until it is established, so there is no plaintext path to
select and no option that skips verification. Each `advance` is one bounded step — finish a
connect, make exactly one provider handshake call (§4's per-pump budget), or retry a held write.
The per-connection budget counts only provider calls that moved ciphertext, so a long WAN round
trip costs nothing while a peer trickling its handshake is failed at `handshake_call_limit`. A
write takes at most one record; a record the carrier cannot take yet stays with the stream,
unchanged, and is retried with the same bytes, which is both the provider's contract and §4's
rule that a submitted frame is immutable. Accepting at capacity takes the pending connection and
closes it unauthenticated (`shed`), so a flood cannot sit in the OS backlog. The provider's
allocation is process-wide, counted, capped at `tls_allocation_limit` and zeroized on free. A
failed stream reports one `Failure` category and never a certificate's contents; stats report
counts only. `accept` also reports the remote address, as the abuse signal Step 3's per-source
limiter needs and never as an identity.

**The fake transport carries the same TLS.** `.memory` replaces the wire, not the
authentication: bounded in-process pipes whose tests can fragment every transfer, stall a stream,
reset a connection, flip a bit in flight and inspect the bytes on the wire. It is what Step 3's
tests of `net` will run on, deterministically and without a socket, and because it cannot carry
anything but TLS it cannot become a plaintext mode.

**Proofs.** `engine/tests/transport_streams.zig` (`zig build transport-test`, and part of
`zig build test`) runs 13 end-to-end proofs over identities that `fixtures/tls_identities.c`
generates for each run — fresh P-256 keys with fixed validity dates, never written anywhere —
linked into that test binary alone, so nothing able to issue a certificate reaches `platform` and
no key is committed. Over real loopback: mutual authentication with each side holding exactly the
other's key; 1 MiB in one direction and a greeting in the other, every byte in order; an orderly
close arriving as `closed`; a second session returning provider memory to the exact byte; an
occupied address, a refused connect and a server abandoning a handshake, each with its own
reason; and a plaintext client speaking a valid FNET frame, which is refused as `protocol`
without a byte or a session. Over the memory carrier: the certificate matrix — untrusted,
expired and not-yet-valid servers, a wrong name, a wrong pinned key, a four-certificate chain
accepted and a five-certificate one refused, and an untrusted and an expired client — the
ciphertext-only wire, a tampered record, 64 KiB through a 512-byte pipe seven bytes at a time
with records held back and delivered unchanged, a 500-pump stall that costs no budget, the
budget itself (reached at 64 calls, never reached at 4,096), resets during and after the
handshake, an untrustworthy clock, the allocation cap, shedding and stale handles, and one FNET
heartbeat frame decoded intact on the other side. `transport.zig` adds six unit tests for
endpoints, pipes, options, handles and credential shapes.

**Each guard was broken to see it fail.** Verification off failed eight proofs; the pin removed,
the chain limit removed, the handshake budget removed, the creation-time usage check removed and
the allocation cap removed each failed its own proof. Removing the post-handshake verification
check alone fails nothing, correctly: with verification required the handshake has already
failed. Weakening verification to optional showed it is a real second layer — with it the client
still refuses an untrusted server; without it the client establishes a session with one. The
peer-side usage rule cannot be reached through Foundry credentials, which refuse such an identity
at creation, so it was probed by removing that check: a client presenting a certificate with no
extendedKeyUsage is then refused by the server as `certificate_wrong_usage`, and with the peer
rule also removed the server accepts it. The provider itself refuses to present a server
certificate that lacks serverAuth, so the rule's reach is the EKU-less certificate — exactly the
case the provider would have let through.

**What implementation found that the design did not say.**

1. **A refusal is not always legible to the refused.** A client that rejects the server's
   certificate has not installed its handshake keys, so its alert travels unprotected (RFC 8446
   §6), and a server already reading encrypted records cannot authenticate it: the server reports
   `protocol`. A server that rejects the client's certificate protects its alert with keys the
   client has moved past, so the client, too, may see only `protocol`. The refusing side always
   names the exact reason. Step 3's diagnostics must take the refusing side's word and must not
   promise the refused side a reason.
2. **A TLS 1.3 client is `established` before the server has judged it.** Its handshake ends
   when it sends Finished; the server's verdict on its certificate arrives on its first read.
   Nothing reaches the server's application first — the server's handshake fails — but Step 3
   must treat a client's `established` as "the server was verified", not "this client was
   admitted".
3. **The provider's key store grows once and stays grown.** The first handshake leaves 904 more
   bytes allocated than before it on the macOS run, a bounded one-time allocation inside PSA; every
   later session returns exactly what it took. The proof allows 4 KiB for the first and requires
   exactness after it.

**Windows.** The same 28 changed files, hash-checked against the Mac's, ran natively on the Intel
Arc A750 Windows 11 PC over SSH at two jobs and below-normal priority, while its owner was
playing. `zig build transport-test`: 13 of 13, real Winsock loopback included, in 85 s from a
cold cache. The whole `zig build test` graph, every Windows test binary now linking libc,
`ws2_32`, `bcrypt` and the transport archive: 80 of 80 steps, 1,613 of 1,622 tests, the nine
skips being the tree's existing Windows-conditional ones, in 231 s. Linux compiled in the bar's
cross check and was not run.

**Deliberately not done.** No session, identity allowlist, revocation of live peers, deadline,
rate limiter, public listener, ABI or sample code: those are Steps 3 through 6. Credentials are
bytes a host hands over; reading operator credential files through host grants is Step 6's, and
provisioning and rotation are Step 8's guide. Linux compiles and is not run (ADR-0039). IPv6 and
names remain outside the transport. §11's open questions stay open, and nothing here authorizes
infrastructure, real credentials or a public listener.

---

## Resolution — 2026-09-22, Step 3: sessions, and what a connection passes through to become one

Step 3 built the admission path §4–§6 describe, up to the point where initial state would be
delivered, and stopped there: `net.Service` (`engine/src/net/service.zig`), with the canonical
compatibility description in `compatibility.zig` and the handshake-start limiter in `limiter.zig`.
A service runs over a `platform.Transport` it borrows and never owns. Commands, state, baselines
and activation are Step 4's; nothing here reaches a world, a package or the public ABI.

**Grants make every choice the host's.** A service is built from grants — an ID, a role, an
endpoint and credentials the host already created on the transport — plus an allowlist and a
frozen compatibility description. A session is created *by grant*, at most one per grant, and
`listen` or `connect` uses only that grant's endpoint and credentials, so nothing that reaches a
service can name an address, a file or a key (§8). A client grant must name a connectable
endpoint; a grant's credentials must exist on the transport in the grant's own role. `grantAt`
shows a grant's ID, role and endpoint and never its credentials. Channels are registered while a
session is configuring and frozen when it starts, in ID order, so registration order is not part
of the contract.

**A connection's path.** A server accepts at most `pending_handshakes` connections per pump. Each
is closed before any handshake call if the pending pool is full or the limiter refuses its start;
otherwise it authenticates in the pending pool, separate from admitted peers. When TLS completes,
the allowlist decides at once — `authorizing` is that decision, not a state a connection waits in
— and a verified key it does not hold, a principal that already has a live connection, or no room
in the peer pool or the event queue is refused with an FNET refusal (`policy` or `capacity`). Only
then does FNET input reach negotiation. The observable states are `connecting`, `authenticating`,
`negotiating`, `synchronizing` and `closing`; `active` is Step 4's. A client counts as admitted
only once the server's answer has arrived, which is how Step 2's finding — a client is
`established` before the server has judged it — is honoured.

**The negotiation exchange, which Step 1 froze the messages of and not the order.** The client
sends its hello, every catalogue entry, every channel descriptor and a finish carrying the SHA-256
over the concatenated encoded 64-byte entries and over the concatenated 24-byte descriptors. The
server compares in order and refuses at the first difference: application ID or revision
(`application`); tick rate or compatibility ID (`compatibility`); an entry count (`catalogue` or
`channel`, detail `0xFFFF`); an entry (`catalogue` or `channel`, detail = its index); a digest
that disagrees with matching entries (the same reason, detail `0xFFFF`). A first frame in another
wire version is answered with a `version` refusal in wire version 1 before anything else is read.
On success the server assigns the session's next participant number, never reused, and answers
with its hello — epoch, participant, its counts and peer limit — and a finish with its own
digests, without repeating its entries. The client checks every field of that answer and both
digests against its own description before it believes it, and a server that answers otherwise
ends as a protocol `mismatch`. The canonical catalogue is each package in load order followed by
its inputs sorted by kind and then ID; an input's version is `0.0.0`, because its bytes are its
identity; a duplicate ID anywhere is refused while freezing. Each direction's first frame is
sequence 1 and every later one exactly one more. A frame is numbered as it enters the send queue,
so Step 4's replaceable state must be numbered when it is queued, not when it is produced.

**Identity policy fails closed.** An `Identity` maps a key to a host-local principal; several keys
may share one. `replaceAllowlist` validates the whole replacement before touching the current
one, so an invalid replacement is refused and the last valid policy stays. A removed key, or a key
remapped to another principal, ends its live peer as `revoked`, and it is told `policy`.
`replaceCredentials` points a grant at new credentials: every connection its old ones
authenticated ends as `rotated`, pending handshakes included, and a listening session's later
connections authenticate with the new ones. This needed `Transport.setListenerCredentials`, which
keeps the port, and `Transport.credentialsRole`.

**Validity is judged for as long as a session lasts, in `platform`, where civil time is.** Step 2
verified a chain once. `transport.zig` now records the earliest notAfter in the verified chain
(`Peer.valid_until`), and `advance` fails an established stream as `certificate_expired` once the
civil clock passes it, or as `clock_unavailable` if the clock becomes untrustworthy. The service
advances a peer before reading anything more from it, so no byte from an identity is decoded after
the identity stops being valid. That is §4.1's "revalidate policy/expiry during pumping".
`Transport.setFixedClock` moves a proof's fixed clock, and nothing can move the system clock.

**Bounds, and where they come from.** Every allocation is made at `init`, from the limits and
the grants. A connection buffer — send queue, frame storage and one staged TLS record — exists
only for authorized connections, so the pending pool costs streams and nothing more. Each pump
gives each connection at most its budget: `tls_handshake_calls_per_peer_per_pump` handshake calls,
64 KiB in, 64 KiB out and 32 decoded frames. Bytes read beyond the frame budget stay staged for the
next pump, and the starting position rotates every pump. The limiter keeps its credit as time,
exactly, in integers: a start costs `1 s / rate` of credit and a bucket holds `burst` starts. A
source is judged before the global bucket, so one noisy address cannot spend what every other
address shares, and a refused start costs nothing. Its table is bounded: an entry whose bucket has
refilled carries no information and is reused, and a new source that finds no entry shares one
overflow bucket at the per-source rate, so a full table makes starts stricter and never forgets a
source still being limited. `Service.init` checks the transport against the limits: enough
streams and listeners, no looser handshake or allocation budget, and no limit stricter than the
transport can enforce. The transport enforces four certificates and one 16 KiB handshake message,
so a host asking for less than either is refused. `transportOptions` builds matching options.

**Deadlines and heartbeats.** Admission runs from accept or connect to admission, and a negotiating
server refuses with `timeout`. Initial synchronization runs from admission and, until Step 4
activates anything, always ends a session that reaches it. No progress means no complete frame for
the timeout, however slowly bytes drip. Write stall means queued output, including a record the
transport holds, that has not moved for the timeout. An admitted side sends a heartbeat after a
quarter of the no-progress timeout without sending anything, carrying its epoch and the last
sequence it received. A heartbeat for another epoch, or acknowledging a frame never sent, is a
protocol `mismatch`. Heartbeats keep an idle peer alive and extend neither the initial-sync nor
the write-stall deadline.

**Endings are structured, reserved and said.** `Ending` names why a connection ended: local,
peer-disconnected, peer-closed, refused, refused-by-peer, revoked, rotated, timed out (which
deadline), protocol (which fault), transport (the platform's `Failure`) or overloaded. It never
carries a payload or a certificate's contents. The service logs nothing; every outcome is an event
or a counter. An authorized connection reserves its two events, admission and ending, when it is
authorized, so the queue cannot overflow. A host that stops reading events stops admitting, with
`capacity`, and nothing is dropped. Pre-authentication failures, denied keys, duplicate principals
and capacity refusals are counters rather than events, so no unauthenticated flood can fill the
queue. A connection this side ends says why — a refusal while negotiating, otherwise a disconnect
— and then lingers for `close_linger_ms`, delivering it and reading only to discard, until the peer
closes or the linger runs out. `closeSession` is local and immediate: one disconnect attempt and
one close_notify per peer, its queued events purged, its handles stale.

**Proofs.** `engine/tests/net_sessions.zig` (`zig build net-session-test`, and part of `zig build
test`) runs 14 proofs. Each uses a server service and separate client services over one transport,
identities generated per run through `fixtures/identities.zig` (now shared with Step 2's proofs),
and a monotonic clock the proof advances itself. A `Raw` client speaks FNET by hand to be the peer
that stalls, floods or breaks the protocol. Over the memory carrier:
- Grants, roles and state refuse what they do not allow.
- A matching client is admitted and a reconnect is a fresh participant, both with whole transfers
  and with seven bytes at a time through a 512-byte pipe.
- Eleven compatibility differences are each refused with their category and index, on both sides,
  and no refusal takes a participant number.
- Allowlist behaviour: a stranger the root vouches for is refused with no event; a second
  connection of one principal is refused while the first carries on; an invalid replacement
  changes nothing; revocation and remapping each end exactly their peer; a withdrawn key cannot
  come back.
- Pre-authentication bounds: stalled handshakes fill the pending pool and then time out without
  becoming peers or leaking a stream; the per-source rate admits its burst and then one start per
  half-second.
- All four deadlines fire; thirty idle seconds pass on heartbeats alone.
- Twelve protocol breaches each end only the breaching peer.
- An inconsistent server's answer is disbelieved five ways.
- A thousand-frame flood is decoded at most 32 frames per pump, beside a quiet peer that
  carries on.
- The event reservation and the peer cap each refuse, and each recovers.
- Closing a session ends all it held and the next session takes the next epoch; a certificate
  that expires mid-session ends the session on both sides; rotation ends every connection and
  only the new pin is trusted afterwards.

One proof repeats the join over real loopback sockets. Ten unit tests cover canonical freezing,
the limiter, the send ring, configuration refusals and an initialization that fails at every
allocation. Step 2's proofs gained one: a stream is valid through its chain's last second and
fails at the next, or when its clock becomes untrustworthy.

**Each guard was broken to see it fail.** Eighteen mutations, each restored and checked
byte-identical afterwards, and each failed its own proof:
- the allowlist bypassed, and one principal allowed twice;
- sequences unchecked;
- catalogue entries uncompared, and the server's digest check removed;
- the limiter bypassed, and the pending pool unbounded;
- the frame budget removed, and events unreserved;
- allowlist changes not applied to live peers;
- each of the four deadlines removed;
- heartbeat claims unchecked;
- the client believing the server's hello, and believing its digests;
- live validity unjudged, which failed both Step 2's new proof and the session proof.

**What implementation found that the design did not say.**
1. **Closing a TCP socket with unread input resets the connection, and a reset can discard a
   refusal before the peer reads it.** Hence the linger, and its limit. A refusal to an identity
   that never gets a queue — denied, duplicate or no room — is written straight to the stream.
2. **A refused start still costs one provider session.** `Transport.accept` creates the TLS
   session with the stream, before the service can judge the source, so a refused start costs one
   session setup and never a handshake call. It is bounded by the accept budget. If Step 7's
   measurements show it matters, splitting accept from session creation in `platform` is the fix.
3. **Each side must judge its peer before reading.** Before that ordering, a client whose server
   certificate expired first read the server's abrupt close and reported `truncated`; judging
   first reports `certificate_expired` on both sides whatever order they run in.

**Deliberately not done.** No commands, state, baseline, acknowledgement or activation (Step 4);
no ABI (Step 5); no sample, credential files or host modes (Step 6); no provisioning guide (Step
8). The global start rate is proved in `limiter.zig`'s unit tests only, because every memory
connection comes from one address. Linux compiles and is not run (ADR-0039). This step was not run
natively on Windows: its platform change is C and Zig built by the cross-target check, and the
cross-host proofs are Step 8's. §11's open questions stay open, and nothing here authorizes
infrastructure, real credentials or a public listener.

## Resolution — 2026-09-22, Step 4: a baseline, then commands by tick and the newest state

Step 4 finished the path §6 describes inside `net.Service`: a peer is synchronized by one
baseline, activated by acknowledging it, and then exchanges commands and state. The service
carries bytes and gives them no meaning. Validating payloads, and every object map, stays the
application's. Nothing here reaches a world, the public ABI or a sample.

**The exchange, which Step 1 froze the messages of and not the order.**
1. After admission the server's host calls `sendBaseline(peer, tick, bytes)`. The baseline
   travels on the session's full-state channel as a reliable frame. The client's host takes it
   as a `baseline` delivery that names its frame sequence and tick.
2. When the client's host has applied it, it calls `acknowledgeBaseline` with that name, which
   sends a baseline acknowledgement carrying the epoch, sequence and tick.
3. The server activates the peer only if all three match the baseline it sent. It then answers
   `active` with the epoch and participant, and both sides report an `activated` event.
4. The client believes `active` only after acknowledging, and only for its own epoch and
   participant.

Every other order is a protocol fault that ends only that peer:
- an acknowledgement before the baseline, a second one, or a command before activation is
  `unexpected`;
- an acknowledgement naming another sequence, tick or epoch is `mismatch`;
- on the client, a second baseline, a baseline on another channel, state before activation, or
  a command on a channel that does not run toward clients is `unexpected`;
- an oversized baseline is `malformed`;
- activation for another participant, or state stamped earlier than the last, is `mismatch`.

A session registered without a full-state channel has nothing to carry a baseline, so its
peers cannot activate (`NoStateChannel`). Channels still need no state channel to start,
because the limits allow none. Activation must beat the initial-sync deadline, and does in the
proofs; the no-progress, heartbeat and write-stall deadlines carry on into `active`.

**Commands reach the server's host only in tick batches.**
- An active client's `sendCommand` queues a copied reliable message on a reliable channel that
  runs toward the server, and returns its number, counted from 1 on that connection.
- The server appends each arriving command to that peer's inbox. The inbox is the part of the
  peer's 256 KiB receive storage left after the frame being decoded, one staged TLS record and
  a client's untaken state: 112 KiB at the reference limits.
- `admitBatch(session, tick)` needs strictly increasing ticks and replaces the previous batch.
  It takes each active peer's oldest commands, one per peer per round, in participant order. It
  takes at most the new `commands_per_peer_per_tick` (16) from each peer, and stops taking from
  a peer whose next command does not fit. Everything it takes is copied into the session's
  batch storage, whose size is the existing `queued_event_payload_bytes` (1 MiB).
- The batch is then ordered by participant number and command number, never by arrival.
- A command the budget leaves behind waits, in order, for a later tick. A peer that fills its
  inbox is sending faster than its host admits, and is ended `overloaded` rather than read
  more slowly, because being read more slowly would look to it like a stall on the server.
- Copying is what lets a batch outlive its senders. A peer that leaves after admission keeps
  its admitted commands in the batch, and loses the ones still waiting, so a reconnect starts
  with nothing pending and numbers its commands from 1 again.
- `nextDelivery` and `takeDelivery` refuse a server's peers, so a host cannot read commands
  around admission.
- §4's table put the 1 MiB against "queued events". Events still carry no payload: they are
  admission, activation and ending, with three reserved per authorized connection, so the queue
  still cannot overflow. That is why the event-reservation proof now counts three.

**State replaces state, and is numbered only when it is queued.**
- `publishState(peer, tick, bytes)` copies the state into a slot beside the peer's send queue,
  one frame's worth. It needs a tick no earlier than the last one stamped for that peer.
- A state still in the slot is replaced. The slot's state enters the queue, and only then gets
  its sequence, as Step 3 required, once every byte of the last state queued has gone to TLS.
- So a slow peer holds at most two states — one being written and one waiting — and receives
  the newest it can rather than every state in turn. A reliable message to it is refused
  `QueueFull` once its queue is full, never dropped.
- Published during synchronization, after the baseline, the state waits until activation, so
  live state never overtakes or replaces the baseline.
- On the client, a state replaces any untaken state. Reliable messages from the server are
  delivered first, in arrival order, and then the newest state.

**Storage, all of it allocated at `init`.** A connection buffer is exactly `send_bytes_per_peer
+ receive_bytes_per_peer`:
- the send queue, plus one frame of unqueued state;
- one frame being decoded, one staged record, one frame of untaken state, and the inbox.

`Service.init` therefore refuses, as `QueueTooSmall`:
- receive storage under three frames plus a record;
- send storage under two frames;
- batch storage under one frame, since a command that could never fit would wait for ever.

Negotiation must now fit the queue alone.

**Proofs.** `net_sessions.zig` has seven new proofs, 21 in all:
- **Activation only by the baseline it was sent.** Nothing but a baseline flows before
  activation. A baseline is refused if oversized or sent twice. State published during
  synchronization waits behind the baseline, and the newest replaces the rest. A short buffer
  takes nothing. A wrong or repeated acknowledgement is refused. Activation beats the
  initial-sync deadline, and an idle active pair lives on heartbeats.
- **Initial synchronization fails closed.** Four ways:
  - A baseline that is never acknowledged times out.
  - A client that cannot apply its baseline disconnects with `application`. Its participant is
    released, and it rejoins as a new one.
  - Six false acknowledgements from a hand-driven client each end it.
  - Nine misbehaviours from a hand-driven server are each disbelieved by the client.
- **Three clients sending bursts larger than the budget, over a fragmenting carrier.** Every
  batch is in order, contiguous per participant and within budget. Nothing is lost. Each
  client's final view equals the server's. Replaying the captured batches into a fresh
  reference model — whose result depends on order across and within participants — rebuilds
  the same world.
- **A departed peer** keeps its admitted commands and loses its waiting ones, and rejoins with
  numbering from 1.
- **A stopped client beside a healthy one.** It is published a kilobyte every tick and more than
  fifty states are replaced, yet the queue never exceeds 4 KiB. Messages to it are refused once
  its queue is full, with every accepted one counted sent. It is ended by a deadline while the
  healthy peer stays active.
- **Command checks.** Eight command and state breaches from a hand-driven client each end only
  it, a flood of valid commands the host never admits included. The inbox peak stays within its
  bound.

**Each guard was broken to see it fail.** Thirteen mutations, each restored and checked
byte-identical afterwards, and each failed its intended proof:
- acknowledgement fields unchecked, and a wrong baseline acknowledged locally;
- commands before activation;
- the batch left unsorted, and the per-peer budget ignored;
- state never replaced, state sent while synchronizing, and state published before the
  baseline;
- a client's state allowed to go back, and activation believed without an acknowledgement;
- a channel's direction unchecked;
- a server's inbox readable as deliveries;
- the state delivered ahead of the messages before it.

**What implementation found that the design did not say.**
1. **A disconnect can outrun admission.** Commands are copied when admitted, not when read, so
   a batch keeps its commands however its senders leave. Borrowing the inbox would have let a
   reused connection buffer rewrite an admitted command.
2. **The per-tick budget needed a limit, and filling the batch needed an order.** Visiting peers
   by participant, one command per round, makes what fits a full batch depend only on what had
   arrived, and lets no participant's burst crowd out a later one.
3. **"Newer state waits behind the baseline" needed a place to wait.** Queued, state would be
   immutable and numbered, and could never be replaced. Hence the slot beside the queue, which
   also gives a slow peer the newest state.

**Deliberately not done.**
- No public ABI (Step 5), sample, host modes or presentation maps (Step 6).
- No WAN envelope, which Step 7 measures.
- No real-socket proof of delivery: it uses the same code as the memory carrier, and Step 3's
  real-loopback join is unchanged.
- Not run natively on Windows, since the change is Zig-only and inside `net`; Windows was
  covered by the cross-target checks.

§11's open questions stay open. Nothing here authorizes infrastructure, real credentials or a
public listener.

## Resolution — 2026-09-22, Step 5: the v5 inventory, frozen before any of it was written

§8 and §11 require the v5 types and call count to be recorded before dependent code. This
section is that record; what implementation then found is recorded after it, in its own
section.

**`FoundryApi_v5` is `FoundryApi_v4` byte for byte, followed by 22 networking calls.** It has
235 members, which is 233 calls plus `version` and `size`, and `get_api(5)` offers it beside v1–v4. No earlier declaration moves.
`FOUNDRY_API_VERSION` becomes 5. The native loader offers 5 alongside the others. Lua binding
1 stays v2-only.

| Group | Calls |
| --- | --- |
| Grants (1) | `net_grant_next` |
| Sessions (3) | `net_session_create` `_close` `_info` |
| Channels (2) | `net_channel_register` `net_channel_next` |
| Starting (2) | `net_session_listen` `net_session_connect` |
| Peers (3) | `net_peer_next` `net_peer_info` `net_peer_disconnect` |
| Events and stats (2) | `net_event_next` `net_stats` |
| Initial state (2) | `net_baseline_send` `net_baseline_acknowledge` |
| Sending (2) | `net_state_publish` `net_command_send` |
| Receiving (2) | `net_delivery_next` `net_delivery_take` |
| Admission (3) | `net_batch_admit` `net_batch_command` `net_batch_copy` |

**Two opaque handles**, eight bytes each: `FoundryNetSession` and `FoundryNetPeer`. They carry
the service's own generational handles, so a stale handle is `FOUNDRY_ERR_INVALID_HANDLE`.

**Enumerations cross as `int32_t` with `#define`d values**, never a C `enum`, because two of
them arrive from the caller and are validated as numbers:
- role: server 1, client 2;
- direction: client-to-server 1, server-to-client 2, bidirectional 3;
- delivery: reliable 1, latest complete state 2;
- session state: configuring 1, running 2;
- peer state: connecting 1, authenticating 2, negotiating 3, synchronizing 4, active 5,
  closing 6;
- event: admitted 1, activated 2, ended 3;
- delivery kind: baseline 1, state 2, message 3;
- ending: local 1, peer disconnected 2, peer closed 3, refused 4, refused by peer 5, revoked 6,
  rotated 7, timed out 8, protocol 9, transport 10, overloaded 11.

An ending's `code` is one of these, depending on its kind:
- a disconnect reason, which is also the one `net_peer_disconnect` takes: closed 1, protocol 2,
  policy 3, timeout 4, capacity 5, application 6;
- a refusal reason: generic 1, version 2, application 3, compatibility 4, catalogue 5, channel
  6, capacity 7, policy 8, timeout 9;
- a deadline: admission 1, initial sync 2, no progress 3, write stall 4;
- a protocol fault: malformed 1, unexpected 2, sequence 3, truncated 4, mismatch 5;
- a transport failure: `platform.transport.Failure`'s 23 categories, numbered 1–23 in their
  declared order and written out.

**Ten structs, each with its reserved bytes written as zero and its size stated in the
header, `net_types.zig` and both agreement files:**

| Struct | Bytes | Fields |
| --- | --- | --- |
| `FoundryNetEndpoint` | 8 | IPv4 address `uint8_t[4]`, port `uint16_t`, reserved `uint16_t` |
| `FoundryNetGrantInfo` | 24 | id, role, reserved, endpoint |
| `FoundryNetChannelDesc` | 24 | id, revision, max payload bytes, direction, delivery |
| `FoundryNetSessionInfo` | 40 | grant, role, state, epoch, channels, pending, peers, listening flag, reserved, listening endpoint |
| `FoundryNetPeerInfo` | 24 | session, state, participant, epoch |
| `FoundryNetEnding` | 16 | kind, code, refusal index (`0xFFFF` for none), reserved |
| `FoundryNetEvent` | 48 | session, peer, kind, participant, epoch, ending |
| `FoundryNetDelivery` | 32 | kind, bytes, channel, tick, sequence |
| `FoundryNetCommand` | 32 | peer, participant, bytes, number, channel |
| `FoundryNetStats` | 184 | five `uint32_t` gauges and one reserved; twenty `uint64_t` counters |

**What never crosses.** No key, certificate or credential, since a grant names credentials
the host built. No principal: it is host-local identity, and §4.1 says the principal stays in
the service. No remote address. A peer is its participant number within its session's epoch.

**Rights are the grants the host publishes.**
- The host binds its `net.Service` and a list of the grant IDs the table may use. Without a
  service, every call answers `FOUNDRY_ERR_UNAVAILABLE`.
- A grant the service holds but the host did not publish answers `FOUNDRY_ERR_REFUSED`, and so
  does every handle into a session on such a grant. A grant the service does not hold at all
  answers `FOUNDRY_ERR_NOT_FOUND`.
- `net_grant_next` walks only published grants.
- `net_event_next` returns only published sessions' events, leaving every other event queued in
  order for the host, so nothing is dropped or stolen. That needs one service addition: taking
  the first queued event that matches a set of grants.
- Pumping stays host-side and is not a call. `net_stats` is the whole service's counters, which
  name no session.

**Buffers.** A payload arrives as `const void *bytes, uint32_t size`. A null pointer with a
nonzero size is `FOUNDRY_ERR_INVALID_ARGUMENT`. `net_delivery_take` and `net_batch_copy` copy
into `uint8_t *buffer, uint64_t capacity`:
- they always set `*needed`;
- a short buffer is `FOUNDRY_ERR_LIMIT`, and a short delivery buffer takes nothing;
- no delivery, or no event, is `FOUNDRY_END`.

**Other refusals.**
- `FOUNDRY_ERR_REFUSED`: the wrong role, the wrong state, a stale tick, a stale baseline, or a
  channel that does not run that way.
- `FOUNDRY_ERR_NOT_FOUND`: an unknown channel.
- `FOUNDRY_ERR_LIMIT`: a full queue, a pool or event queue at capacity, or too many channels.
- `FOUNDRY_ERR_INVALID_ARGUMENT`: an oversized payload, or an out-of-range enumeration.
- `FOUNDRY_ERR_ALREADY_EXISTS`: a duplicate channel, or an address already in use.

Walks carry a generation, so a peer set that changed under a walk is detected: the service
gains a revision that moves whenever a connection is added or removed.

## Resolution — 2026-09-22, Step 5: what publishing the service found

The inventory above was implemented as frozen: 22 calls in `engine/src/abi/calls_net.zig`, and
ten structs and the enumeration numbers in `net_types.zig`. Their sizes are stated in the
header, `net_types.zig`, `agreement.c` and `agreement.zig`. `abi` gained `net` in the build
graph, an ordinary downward edge to L2. `Host` gained `net_service` and `net_grants`. Nothing in
v1–v4, Lua binding 1 or the script host changed.

**Proofs.**
- `zig build abi-net-test` (`engine/tests/abi_networking.zig`) runs one service holding a
  server grant and a client grant over the memory carrier, so a single process is both ends,
  and drives it through the table alone. One proof plays a whole session: grants, channels,
  listen, connect, admission, a short-buffer refusal that takes nothing, the baseline and its
  acknowledgement, activation, a command admitted and read back out of its batch, state,
  peers, statistics, a disconnect with a reason and teardown.
- The other proof makes every refusal the table owes:
  - an unpublished grant; the host's private session and its events;
  - duplicate sessions; bad enumerations; frozen channels;
  - wrong roles and states;
  - null and short buffers; oversized payloads; wrong and unknown channels;
  - stale ticks and baselines;
  - a walk invalidated by a departure;
  - stale and invented handles;
  - rights withdrawn; the service withdrawn.
- `sweep.zig` walks v5 instead of v4, so all 233 calls are checked for crash-free garbage
  handling with nothing bound and with everything bound, and for `unavailable` with no service.
  `get_api(5)` and the native loader's offered set are checked.
- `engine/tests/fixtures/net_client.c` calls every networking entry point and compiles against
  the **installed** header as C99 on macOS, Linux and Windows and as C++17. So does the v4
  authoring client, which is unchanged.

**Each guard was broken to see it fail.** Ten mutations, each restored byte-identical, and each
failed its intended proof:
- `get_api(5)` not offered, and the loader not offering 5;
- two v5 members swapped in the header;
- two event fields swapped;
- a command size widened in a header signature;
- unpublished grants usable, and events not filtered by grant;
- a null buffer with a capacity accepted;
- a server's deliveries reachable;
- any channel direction accepted.

**What implementation found that the design did not say.**
1. **A shared event queue needed a filter to make rights real.** Refusing an unpublished
   session's handles is not enough if the table's event call still takes that session's
   events. `Service.nextEventFor(grants)` takes the oldest event of a published session and
   shifts the earlier ones one place, so the host's own events keep their order and nothing is
   dropped.
2. **Peer walks needed a revision the service did not have.** A cursor's generation must
   change when the set it walks changes, so the service now moves a `revision` whenever a
   connection is added or removed.
3. **Payload pointers take the existing `const void *` convention.** They are `?[*]const u8` on
   the Zig side, as `world_add_component`'s are. The table sweep cannot build a sample value
   for an opaque pointer, and it caught the first spelling.

**Deliberately not done.**
- No sample, host modes, credential files or consumer (Step 6).
- No networking guide, which comes with Step 8's external proof.
- No Lua binding.
- Not run natively on Windows. The PC refused SSH at its recorded address, and this session is
  not permitted to scan the network to find it again. The header compiled for Windows as C99
  and in the optimized Windows checks.

## Resolution — 2026-09-23, Step 6: the connected sandbox, through the table alone

The sandbox has a connected mode, opted into at launch and never at build. Its offline path
is unchanged: with no arguments nothing below runs, and the bar's 30-frame null run is the
same run it was. It is two halves with a hard seam between them, as the editor is.

**The host half, `samples/sandbox/connected.zig`.** Everything a consumer cannot be trusted
with, and nothing else.
- **Launch.** `sandbox --serve <a.b.c.d:port> --credentials <file>` or `--join` with the
  same. Endpoints are numeric; a name is refused. There is no mode without credentials and
  no switch that weakens verification. Any other argument prints the usage and exits 2.
- **The credential file**, host-only and versioned: `foundry-credentials 1`, then `role`,
  `trust`, `certificate`, `key` and, for a client, `server-name` and `server-key`, or, for
  a server, repeatable `allow <key sha256> <principal>`. Relative paths are the file's own
  directory's. The key is wiped once the provider has its copy. A refusal names the line,
  never its value, and no path, key or fingerprint is logged.
- **The service.** One session's limits, the system carrier, and exactly one grant,
  `sandbox:net.serve` or `sandbox:net.join`. That grant is the one the table publishes.
  - The compatibility description is the loaded packages in load order, each with its
    version and the size and SHA-256 of the exact `.fpk` bytes loaded.
  - With them go the application `sandbox:application` at protocol revision 1, the tick
    rate, and an attestation hash for what the catalogue cannot see.
  - The first epoch comes from the wall clock in milliseconds, so a restarted server has a
    new one.
- **The table.** One host is bound per process. Where the scripts already bound theirs,
  networking joins it, setting the service, grant, renderer and UI context, and restores
  them on close. Otherwise it binds its own.
- **Pumping, input and pacing.** The service is pumped at the top of each frame and again
  after the frame's steps, always with `Os.monotonicNanos`. The keys come from content, by
  `platform` name. A headless run sets the null clock to one fixed step per reading and
  sleeps one step of real time per frame.

**The consumer half, `samples/sandbox/markers/`.** It sees `foundry.h` through `foundry_api`
and nothing else.
- **Its boundary** is held three ways. The build graph grants it no engine module. A source
  scan refuses engine imports and `std`'s filesystem, process, OS and socket routes. And
  `zig build markers-boundary` compiles a forbidden `@import("net")` inside the same graph
  and expects it to fail.
- **The protocol**, revision 1, is the consumer's. `sandbox:net.move` runs client to server,
  reliably: 4 bytes, `dx` and `dy` in -1..1 and two zero bytes. `sandbox:net.state` runs
  server to client as latest state: an 8-byte header and 24 bytes per marker (number, owner,
  x, y, the owner's last applied command), at most 8 markers, 200 bytes.
- **The server's authority.**
  - One marker for its own view (number 1, participant 0), and one per peer when it
    activates, numbered monotonically and never reused.
  - A marker is removed when its peer's connection ends.
  - Commands set an intent. The owner is the participant the admitted batch names, never
    anything in the payload.
  - Moves are clamped to the content's arena. A complete state goes to each active peer
    every `state_every` ticks, and a baseline goes once to each synchronizing peer.
- **The client's view.**
  - Every baseline and state is validated into a candidate and only then replaces the view.
    The view is keyed by wire number, and no ECS entity is created for it.
  - A refused state keeps the last view and disconnects as `protocol`. Refused states
    include:
    - a wrong length, too many markers, or non-zero reserved bytes;
    - a zero or duplicated number, or a duplicated owner;
    - a non-finite position, or one outside the arena;
    - a number already removed.
  - Input shows as pending until a state reports it applied. A view with no state for
    `stale_ms` says so. There is no prediction and no extrapolation.
- **Presentation.**
  - Markers are drawn through `render_draw_sprite`, and status through `ui_*` into a panel
    whose draw list the host walks.
  - The status panel shows:
    - the role;
    - the server's bound endpoint and peer count;
    - the view's participant and its own marker;
    - pending input and staleness;
    - the ending. A refusal names its category and first differing entry; a transport
      ending names its authentication category, such as "certificate untrusted" or "not the
      server this client was given".
- **Content.** The new schema `sandbox:net_markers` and record `sandbox:net.markers` hold
  every value a person sees or presses: look, size, speed, arena, spawn spacing, tints, state
  rate, stale time, keys (`i`, `j`, `k`, `l`) and words. The new `textures/marker.png` is a
  32-pixel white disc, which the tints colour.

**Proofs.**
- **`zig build sandbox-net-proof -Dplatform=null -Drhi=null`** runs installed headless
  sandboxes as separate processes over real loopback TCP, each through the path a window
  uses. The run takes a few seconds. Its driver, `samples/sandbox/net_proof.zig`:
  - generates disposable identities with the test-only fixture into a fresh temporary
    directory, gives every child its own home there, and deletes the directory at the end;
  - starts a server on a port the system chooses;
  - starts client A, which moves right and waits with every command acknowledged;
  - starts client B late, moves it down and has it leave;
  - lets A see B's marker arrive and go, then leave;
  - starts client C with one more package loaded;
  - reconnects A.

  It then checks that:
  - B's baseline held A's marker exactly where the server last had it;
  - B's commands moved only B's marker;
  - A and B were participants 1 and 2 on markers 2 and 3, and A's return was participant 3
    on marker 4;
  - C was refused by catalogue before it was a peer, on both sides;
  - the server counted 3 admitted and 1 refused, and stopped after three came and went;
  - every process exited 0;
  - no log holds the credential directory or a key.

  `-- --provision <dir>` writes the same disposable credentials for a hand-driven run.
- **Unit tests.**
  - The markers codec: 4 tests.
  - The host's command line, credential file and plan: 3 tests.
  - `Os.monotonicNanos`.
- **On the primary desktop**, macOS on Metal, three windowed sandboxes ran over loopback: a
  server and two clients, driven by scripted plans. Captures of each window, kept outside
  the repository, show the same markers at the same places in every view. Each view's own
  marker is framed in white, and each panel reads "serving … 2 peer(s)" or "joined –
  participant n", with the view's own position and the tick.

**The bar is green:**
- `zig build test`: 89/89 steps, 1,669 of 1,670 tests, with the one skip that predates M16;
- every `check` target;
- both samples for 30 frames;
- `sandbox-net-proof`;
- the optimized Windows checks;
- both release stages, since the sandbox's content changed.

**Each guard was broken to see it fail.** Ten mutations, each restored byte-identical, and
each failed its proof:
- the arena check, the resurrection check, the duplicate-owner check, and a command's
  reserved bytes, each caught by the codec tests;
- ownership taken from the first marker rather than the batch's participant;
- a departed peer's marker kept;
- a baseline truncated to one marker, each caught by the multi-process proof;
- a `std.fs` reference, and an unused `@import("net")`, each caught by the source scan;
- a used `@import("net")`, caught by the build graph.

Two first attempts failed only by compile error on an unused name and were redone.

**What implementation found that the design did not say.**
1. **A headless host has no real clock.** The null platform's clock is synthetic by design,
   yet a peer across a socket is not. `Os.monotonicNanos` is a real monotonic clock beside
   the wall clock. It is an integer, not an `Instant`, so it cannot reach simulation by
   accident.
2. **Pacing had to move the synthetic clock too.** Sleeping alone left the server at 93 ticks
   in 26 seconds, because a frame reads the null clock once and it moved 1 ms. Setting the
   step to one fixed step makes one tick per frame at real rate, still exactly reproducible.
3. **One table per process means networking shares the scripts' host.** Joining it and
   restoring what it held is the least invasive answer. It does mean a native mod in that
   process can also call networking; shared tables have no per-mod principals, as §8 says.
4. **An unused import is not analyzed.** The build graph alone does not reject a dead
   `@import("net")`. The source scan does, and a used one fails the graph. The editor
   client's boundary has the same property, which is recorded here and not changed.
5. **A tint cannot recolour a coloured sheet.** Participant colours needed a white image,
   which is content, as the sheet is.

**Limits, deliberately.**
- **Not run natively on Windows.** The PC still refuses SSH at its recorded address, and
  this session is not permitted to scan for it. The Windows cross-checks compile the sandbox
  and the new `@cImport`, and so does the optimized Vulkan check.
  **Later the same day** the owner authorized finding the PC on its new address. Step 6's
  commit was then run natively in a fresh worktree, at `-j2` and below-normal priority:
  - `zig build test`: 89/89 steps, 1,661 of 1,670 tests; the 9 skips are all Windows-only,
    as before;
  - `sandbox-net-proof`: all six processes over real Winsock loopback, every check passed.
- **No person pressed a key** in these runs. The windowed runs used the same plans as the
  headless ones. The `i`/`j`/`k`/`l` path is the same `step` call, and real input is Step 8's
  evidence.
- **There is no reconnect control in the window.** Reconnecting is relaunching, and it makes
  a fresh participant.
- **The description is frozen at start.** A hot reload changes this host's bytes but not the
  description it negotiated with.
- The consumer logs without a mod identity.
- The server's own marker always exists.
- **Not this step's:** Step 7's adversarial matrix and measured envelope; Step 8's
  cross-host, WAN, external consumer and guide.

## Resolution — 2026-09-23, Step 7: refusal, authority, replay and the measured envelope

Step 7 reuses what Steps 1–5 proved layer by layer. Those are the provider's qualification,
certificate refusals, a tampered record, plaintext refusal, handshake budgets, expiry,
rotation, allowlists, compatibility, deadlines, noisy-peer budgets, reserved events, baseline
order and service-level batch replay, together with `Service.init`'s allocation-failure sweep.
This step adds the combinations those tests could not reach: each case as the sandbox's own
consumer meets it, and the measured envelope.

**The matrix: `zig build sandbox-net-matrix`**, 11 tests in `zig build test`, file
`samples/sandbox/net_matrix.zig`.
- **The rig.** One service on the memory carrier holds a server grant and five client grants,
  so a single deterministic process is every end of a session.
  - Honest views are `markers` consumers.
  - Hostile ones are raw table calls on the same channels, so they negotiate as an honest
    peer would and then misbehave.
  - The host drains the table's one event queue and offers each event to its consumer.
- **Forged commands.** Three are sent: out of range, reserved bytes set, and short. Each is
  counted and moves nothing. A valid command moves only its sender's marker, because a
  command has no field that could name another.
- **A lying server.** A state that places a marker outside the arena is refused whole. So is
  a state that brings back a removed number. In both cases the view keeps its last complete
  state and tick, and disconnects.
- **Credentials.**
  - A revoked key ends its peer and removes its marker, while the other peer keeps receiving
    state.
  - Rotating the server's credentials ends every peer, and the server keeps serving.
  - A key the server does not allow is refused before it becomes a participant.
- **Records.** A client's command record, captured whole on the wire and replayed into the
  server's end after the original was applied, ends only that connection. So does one bit
  flipped in a record. The other peer plays on in both cases.
- **A stalled peer.** Both ends of one peer's link stalled for 60 ticks. The server kept its
  tick rate and the other view followed. When the stall ended, the stalled view jumped to the
  newest state rather than replaying the ones it missed, with states counted as replaced.
- **A flood of commands.** Forty commands at once never gets more than the per-peer budget
  into one tick. The quiet peer's command lands beside them in participant order.
- **A pre-authentication flood.** Twenty-four connections that never finish a handshake hold
  no more than the pending pool, and the admission deadline clears them. Meanwhile the active
  peer keeps getting state, and its input is applied.
- **Replay.** One recorded session contains:
  - moves, a late join and a departure;
  - a rejoin, and the server's own input.

  Its inputs are the lifecycle events between ticks and each tick's admitted batch, read back
  through the table. Fed to a fresh `markers.Authority`, they rebuild **every state it sent,
  byte for byte**, tick by tick, with the same rejected-command count. That is the same
  binary and the same inputs; nothing is claimed across machines.

**What made replay possible.** The consumer's server logic is now `markers.Authority`: pure,
with no table, clock or allocation. It spawns and removes markers, applies a command, advances
a tick and encodes a state. `Markers` wraps it, adds `initWith(Options)` for a chosen grant,
settings and tick, and `handle(event)` for hosts that run more than one consumer. The table
has one event queue, which `frame` documents.

**The protocol is revision 2.** A state's second header word is now a ballast length: that
many zero bytes follow the markers. A view checks it and ignores it. The latest-state channel
carries up to 1024 bytes, §10's ceiling. `FOUNDRY_SANDBOX_NET_BALLAST` pads a server's
states, so the envelope is measured at size without inventing objects.

**The envelope:** `zig build sandbox-net-proof -Dplatform=null -Drhi=null -- --envelope 600`.
- **Setup.** Four headless clients reach a headless server through a shaper in the driver: a
  TCP relay with blocking sockets and two threads per direction.
- **What the shaper imposes**, per direction of each connection:
  - 75 ms of delay plus 0–15 ms of jitter, without reordering: a 150 ms round trip plus up
    to 30 ms;
  - 1 Mbit/s;
  - a 250 ms head-of-line stall every 5 s.
- **The load.** States of 952 bytes (five markers plus 824 ballast bytes) at 20 Hz, from a
  60 Hz server. Each client runs a looping plan, one change of direction every 20–45 ticks.
- **The measurement.** Each client times every command in real time, from the step that sent
  it to the frame whose state showed it applied, and records the longest gap between states.
  The driver checks four things:
  - p95 at most 500 ms;
  - no state gap over 2 s;
  - no unintended disconnect;
  - p50 at least the imposed round trip, a floor that catches a broken shaper or measure.

**Measured on macOS, 2026-09-23, over 600 seconds.**

| client | commands acknowledged | p50 | p95 | max | longest gap between states |
| --- | --- | --- | --- | --- | --- |
| A | 1,199 | 198 ms | 201 ms | 202 ms | 302 ms |
| B | 1,199 | 183 ms | 200 ms | 230 ms | 317 ms |
| C | 1,798 | 200 ms | 234 ms | 302 ms | 286 ms |
| D | 799 | 183 ms | 233 ms | 399 ms | 286 ms |

- There was no unintended disconnect. The shaper forwarded 49.7 MB and applied 968 stalls.
- **The server.** It admitted 4 peers and 4,995 commands, and sent 47,967 states with none
  replaced.
- **Its peaks, which are the work and storage bounds:**
  - send queue 992 B;
  - per pump: 6 frames and 536 B in, 992 B out;
  - 1 event queued, 28 B in an inbox, and a batch of 2 commands (8 B).
- **Bandwidth.** 47.6 MB sent over 600 s is about 158 kbit/s per client, a sixth of the
  shaped link.
- **The plans are periodic and so is the stall.** Which commands a stall catches therefore
  depends on phase: the maxima show stalls were met, and the p95s show most commands missed
  them. This models stream delay and stalls, not a measured packet-loss rate, as §10 says.

**The bar is green:**
- `zig build test`: 91/91 steps, 1,680 of 1,681 tests;
- every `check` target;
- both samples;
- `sandbox-net-proof`;
- the optimized Windows checks;
- both release stages.

Natively on Windows (`-j2`, below-normal priority), in a fresh worktree:
- `zig build test`: 91/91 steps, 1,672 of 1,681 tests, with 9 Windows-only skips; the matrix
  is included;
- `sandbox-net-proof`: passed over real Winsock.

The envelope was run on the Mac only.

**Each guard was broken to see it fail.** Seven mutations, each restored byte-identical:
- a command applied to participant 1's marker whoever sent it, caught by the forged-command
  and record-replay tests;
- ballast accepted when it is not zero, caught by the codec test;
- the first command of a multi-command batch dropped, caught by the forged-command count;
- the live server ignoring its own intent while the replay honours it, caught only by the
  replay comparison;
- `memoryInjectInbound` claiming bytes it did not write, caught by the record-replay test;
- the envelope's percentile reading 0, and the shaper's delay removed, each caught by the
  round-trip floor.

**What implementation found that the design did not say.**
1. **Clients behind one address share one handshake budget.** Four clients joined through the
   relay at once, and the third and fourth were shed during the handshake. That is the
   per-source limit, 2 starts a second, doing its job. The harness joins 1.2 s apart. A real
   deployment with several players behind one NAT meets the same limit, which is Step 8's to
   measure and, if needed, to tune per deployment.
2. **Pacing had to aim at an absolute schedule.** Sleeping one step after each frame's work
   made every frame a little longer than a step. Over ten minutes the drift broke the run's
   bounds and inflated latency: an early 20-second trial read p95 440 ms, and the corrected
   one about 220 ms. The headless host now sleeps to the next step's absolute time, and it
   does not repay a long stall with a burst.
3. **One table means one event queue.** A host running more than one consumer must dispatch
   events itself, or a consumer drops another's. `Markers.handle` exists for that, and the
   matrix uses it.
4. **The flood waits in the backlog, not in the pool.** Beyond the pending pool, connections
   wait in the listener's bounded backlog, and none is shed in the first seconds. The
   admission deadline clears the pool at 5 s. Both bounds held, but what they cost a real
   flood is Step 8's to measure.
5. **Two host-only test aids.** `Service.streamOf` gives a host the stream under a peer, for
   fault injection. The memory carrier gained `memoryInjectInbound`, to replay captured
   bytes. Neither is published through the table.

**Limits, deliberately.**
- The envelope ran on one Mac over loopback through the shaper. It is a controlled harness,
  not a network.
- No cross-platform or bit-exact claim is made. Replay is the same binary and the same inputs.
- Real WAN RTT, a real flood's cost, cross-host play and the external consumer are Step 8's.

## Resolution — 2026-09-23, Step 8: the public internet, both desktops and an outside consumer

Step 8 added no engine code. It ran what Steps 1–7 built where the design said it must run,
and wrote the guide from an external program. The guide is
[`docs/modding/networking.md`](../modding/networking.md), and its §8–§9 hold the evidence in full.

**Both desktops, each serving the other.** The relocated macOS/Metal application (`zig build
dist`) and a relocated Windows/Vulkan install ran with no toolchain on PATH and with identical
package hashes, on the owner's local network.
- Each machine served the other, and the owner pressed real keys on both. Both markers moved
  on both screens.
- Across the two hosts, a stranger's key was refused by policy and an unrelated root as
  untrusted. A wrong-role certificate was refused before connecting, and a one-value content
  change by catalogue.
- Join, leave and rejoin were clean, with p95 acknowledgement 32–82 ms.

**The public internet.** The authority was a headless Windows build on an owner-authorized
cloud VM. The Windows client was on home broadband and the macOS client on a phone's mobile
hotspot: separate access networks, neither a tunnel nor a forward.
- **Joins:** join, leave and rejoin ×3 were clean on each network, p95 81–100 ms.
- **Refusals:** an unrelated root was cut off in the handshake and never admitted, an
  unlisted key refused by policy, and mismatched content by `catalogue, entry 1`.
- **Ten-minute measured runs,** 20 Hz state and a command every half second:
  - broadband: p50/p95 51/68 ms, longest state gap 450 ms;
  - hotspot: p50/p95 100/118 ms, with one stall of about 2.4 s and no disconnect.
- **Real keys** pressed on the Mac over the hotspot moved its marker on the PC's screen over
  broadband, with no lag the owner could see.
- **Packet capture:** a capture of a controlled session on the server found no `FNET` magic
  and no content name among 292 TLS application-data records; the TLS server name, sent in
  the clear by design, was present as a control.

**The external consumer.** `relay.c`, in the guide, is C99 compiled `-pedantic -Werror`
against the installed `foundry.h` alone.
- **Its host:** a Zig program outside the checkout that depends on Foundry as a package and
  imports only its exported `abi`, `core`, `net` and `platform` modules. It is the same shape
  as M7's and M15's sibling hosts.
- **What it proves:** it registers `relay:say` and `relay:heard`, round-trips a real message
  through a tick batch and a complete state, and checks two documented refusals: a server's
  `net_delivery_next`, and a session on an unpublished grant.
- **Where it ran:** as separate processes on macOS, and on Windows.
- **Credentials:** the guide's OpenSSL recipe produced working operator credentials, and
  removing a player's `allow` line refused them.

**What implementation found that the design did not say.**
1. **A home line behind carrier-grade NAT cannot host at all.** Forwarding a router port
   there does nothing, because the router's WAN address is not the public one. ADR-0045
   already requires a reachable endpoint, so its topology stands. The guide tells an operator
   how to recognize CGNAT, and that players behind it are unaffected.
2. **A mobile network stalls.** One 2.4 s gap exceeds the 2 s state-gap budget the controlled
   harness used. The session survived it, since the no-progress deadline is 10 s. It is a
   recorded observation, not a bound the engine can promise.
3. **Operating a Windows host has traps a design would not list:**
   - a cloud VM sits on the *Public* firewall profile;
   - a process started from an SSH session dies with it;
   - stripping inheritance from a credential directory locks its files.

   The guide's §6–§7 carry them.
4. **The client's view of an untrusted root is a reset.** Over the internet, the client saw
   the server's refusal as `transport failure: reset`, not the certificate category seen on a
   local network. The server never admitted it either way. The refusing side's reason is
   authoritative, as Step 2 recorded.

**Limits, deliberately.**
- Four peers per session and one authority; IPv4; no relay or NAT traversal.
- No anti-cheat claim beyond server authority, and no DDoS claim: a real flood's cost was
  not measured against a public server.
- Linux compiles and is not run (ADR-0039).
- Keys on the PC were proven on the local network; over the internet the PC watched and the
  Mac played.

## Resolution — 2026-09-23, Step 9: M16 is closed

**The gate.** Step 8 changed no code, so its desktop and internet runs are accepted, not
repeated. What was run is the whole bar and the checks networking and the ABI require:
- `zig fmt --check`;
- `zig build test`: **91 of 91 build steps, 1,680 of 1,681 headless tests**, with the skip it
  has carried since M15;
- `zig build check` on the native, Metal, Linux-gnu and Windows-gnu graphs, the Windows
  optimized graph, and the Windows Vulkan graph, debug and ReleaseSafe;
- both samples for thirty headless frames;
- `zig build sandbox-net-proof`, which passed;
- the installed header, compiled as C99 `-pedantic -Werror` for macOS, Linux-gnu and
  Windows-gnu and as C++17, with both the v5 fixture (`net_client.c`) and the v4 one;
- both sample releases, staged.

**The consistency pass.** It covered status in `README.md`, `AGENTS.md`, `docs/ROADMAP.md`,
`docs/design/README.md`, `public-abi.md`, `platform-interface.md`, `CLAUDE.md` §4, §8 and §9,
`PROJECT_STATE.md` and this file. Two statements had become false rather than just old:
- `README.md` still said no sample used v5 and that "the real WAN proof remains an M16 exit
  gate";
- `AGENTS.md` said Step 8 "has not begun".

Both are rewritten. Resolutions keep what they said on their dates.

**The exit criterion, and whether it is met.** The roadmap asks that "two processes share a
world convincingly over the public internet, with authenticated encrypted transport, validated
authority and bounded hostile-input handling, and the model was decided in writing first.
LAN/loopback evidence alone cannot close M16." Each part holds:
- **Over the public internet.** A cloud-hosted authority served a Windows client on home
  broadband and a macOS client on a mobile network. A player's keys on one were seen on the
  other (Step 8).
- **Authenticated and encrypted.** Every connection is TLS 1.3 with a certificate on both
  sides, a pinned server key and allowlist admission, with no plaintext path. This held under
  negative tests on the internet and in a packet capture (Steps 1–3 and 8).
- **Validated authority.** The server owns every marker, commands are admitted by tick, and
  clients validate every complete state before believing it (Steps 4, 6 and 7).
- **Bounded hostile input.** Forged commands, a lying server, replayed and tampered records,
  and stalls and floods were each contained (Step 7). Every pre-authentication cost is bounded
  (Step 3).
- **Decided first.** ADR-0044/0045 and this design were accepted before Step 1's code.

**The table is frozen at 233 calls.** `FoundryApi_v5` was published in Step 5. Steps 6–9
consumed it and added none: the sandbox's consumer, the external C99 consumer and the fixture
all use the same 22 calls.

**The actual deployment limit.** One operator-hosted authority at a reachable public IPv4
address, including a small cloud VM. Beyond that:
- **Size and reach:** four peers a session; no relay, NAT traversal, IPv6 or DNS resolution.
- **Credentials:** every player holds a provisioned certificate whose key the server
  allowlists. Revocation is by allowlist, and there is no revocation list.
- **Joining:** players behind one address share a handshake budget of 2 starts a second.
- **Timing:** the measured p95 command acknowledgement is 68 ms on broadband and 118 ms on a
  mobile network, against a 500 ms budget. A mobile stall of 2.4 s was observed and survived.
- **Not claimed:** anti-cheat beyond authority, DDoS resistance, and Linux at runtime.

`docs/modding/networking.md` is the operator's and author's account of all of it.

**Remaining decisions, recorded so they are not made by accident.**
- **§11's out-of-scope list is unchanged,** and each item is a later decision, not a gap:
  matchmaking, relays and NAT traversal, accounts, anti-cheat, host migration, resumption,
  prediction and rollback, lockstep, content download, automatic replication, interest
  management, remote editor transport, and Lua networking bindings.
- **ADR-0045's revisit clause stands:** player-hosted sessions, anonymous joins, IPv6/DNS or
  another scale reopen the topology.
- **ADR-0013's bit-exact subset** stays owed only to lockstep.
- **Other open questions stay open,** as `PROJECT_STATE.md` lists them.

**Neither later milestone was started.** No M17 review, polish or release work was done, and
no Linux runtime qualification (M18).
