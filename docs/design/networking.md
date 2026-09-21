# Network sessions and the shared-world proof

**Milestone:** M16 — Connected: “it plays with others”
**Status:** Accepted design, 2026-09-21. **Step 1 of nine is complete.** Stop before Step 2.
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
| `build.zig`, `net` | Enforced imports now place the Step 1 `net` module at L2 with only `core` and `platform`; it contains limits, channel descriptors and the pure wire codec, not a transport or session. |

Do not serialize an `InputSnapshot`, C struct, ECS component or handle by copying its memory.
OS key codes, padding, pointer values and local entity generations are not a wire format.
Existing save/authoring formats remain unchanged.

## 3. Ownership and layers

The first two lines describe today's build graph; later lines remain the accepted destination:

```
platform (L1)  core + qualified TLS provider configuration; streams arrive in Step 2
net (L2)       core, platform; Step 1 limits/channels/codec; lifecycle arrives later
abi (L5)       existing imports + net; public argument validation and translation only
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
transitive-license and advisory review. Step 2 records the concrete Zig 0.16 transport
mechanism. Zig compiles the provider directly; no CMake/Make/Python path was added. Need for
workers or a different ownership model stops that step for a Resolution.

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

Step 1's provider/configuration and wire layouts are resolved below. Two bounded implementation
details still require a dated Resolution before dependent code: Step 2's transport mechanism
and Step 5's v5 layouts/call count. Those may refine this contract, not change its scope, module
placement or authority model. No port numbers, machine names or personal paths belong in
committed configuration.

## 12. Implementation order

Step 1 is complete; Steps 2–9 are **not started**. Each ends with its own tests, required bar,
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

### Step 2 — Supply bounded authenticated platform streams

Implement opaque listeners/connections, numeric endpoints, nonblocking connect/accept/read/write,
TLS handshake/read/write, credential contexts, verified peer identities, error mapping and
bounded cleanup in `platform`, with a deterministic fake transport for net tests. Prove real
mutually authenticated loopback on macOS and Windows plus Linux compile coverage, certificate
failure paths and no plaintext fallback. Record the Zig 0.16 mechanism. Null operation needs
no window. **No public listener, shared-world or ABI implementation.**

### Step 3 — Establish compatible sessions and peer lifetimes

Implement service/grants, generational session/peer storage, frozen channel/catalogue negotiation,
authenticated identity allowlists/revocation, role checks, connection states, pre-auth limits,
deadlines, queue budgets, fairness and structured diagnostics.
Host-supplied compatibility inputs are copied and bounded. Test mismatches, resource exhaustion,
partial I/O, teardown and fresh reconnect. **No ECS ownership or automatic package fetching.**

### Step 4 — Deliver tick-admitted commands and complete state

Implement admitted input batches, their stable ordering, copied command queues, replaceable
full-state delivery, retained initial baseline/acknowledgement and activation. Test initial
sync failures, slow peers, stale sequences and replay using an in-memory reference model.
The application owns payload validation and object maps. **No engine gameplay schema and no
private application path that will bypass Step 5.**

### Step 5 — Publish networking in the single public API

Freeze v5 types/call inventory, including grant/authentication diagnostics but no secret access;
implement all §8 groups over the supplied service, add C/Zig agreement and adversarial ABI
tests, installed-header C99/C++ coverage, and teach native table
negotiation to offer v5. Keep v1–v4 and Lua binding 1 unchanged. Test absence/denial explicitly.
**No sample consumer before the public capability exists.**

### Step 6 — Connect the reference sandbox through that API

Add opt-in host modes and the separate header-only consumer, runtime-registered command/state
channels, content-defined marker behaviour, authoritative ticking, local presentation maps,
initial synchronization, operator credential references and visible authentication/connection
state. Headless multi-process input proves the same path. Show the real two-window result on
the primary desktop, retain offline behaviour,
and stage required releases. **No general lobby or gameplay feature expansion.**

### Step 7 — Prove refusal, authority and deterministic replay

Complete §10's adversarial/failure matrix through the public consumer: forged input, corrupted
frames, credential refusal/revocation/rotation, TLS replay/tamper, pre-authentication floods,
compatibility refusal, constrained allocations, stalled clients, bounded fairness, late join
and reconnect. Replay admitted batches and compare server state for the same binary/seed.
Measure work/storage bounds and the controlled WAN envelope. Reuse prior successful evidence;
run new combinations, not duplicate reviews. **No cross-platform bit-exact simulation claim.**

### Step 8 — Prove public-internet play, both desktops and an external consumer

Run the relocated macOS/Metal and Windows/Vulkan applications, with each machine serving the
other, real input and no runtime toolchain requirement. Then prove an authorized internet
server with clients on independent networks, authenticated join/disconnect/rejoin, rejected
identities and content mismatch. Record observed WAN conditions and limits. Build/run the
external C99 consumer; write the networking and credential-operations guide from that
experience. **No Linux runtime certification or blanket anti-cheat/DDoS claim.** Missing
target/infrastructure access is reported, not waived; LAN success cannot close this step.

### Step 9 — Close M16 against its accepted scope

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
or real loopback path exists. §13's open questions stay open, and design authorization still
does not authorize infrastructure purchases, firewall changes, real credentials or a public
listener.
