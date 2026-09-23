# Networking

**Status:** M16 Step 8, 2026-09-23. `FoundryApi_v5` publishes authoritative network sessions:
grants, runtime channels, peers, the one baseline, commands admitted by tick, and complete
state. This guide was written by building the external program below: a C99 consumer that
sees only the installed `foundry.h`, and a small host outside the Foundry checkout that
depends on Foundry as a package. It then ran on macOS and on Windows. The sandbox's shared
markers are the same shape, and they have been played over the public internet between the
two desktops. §8 gives the measured limits.

The contract is the installed [`foundry.h`](../../engine/src/abi/foundry.h). The design and
its reasons are [`design/networking.md`](../design/networking.md),
[ADR-0044](../adr/0044-authoritative-network-sessions.md) and
[ADR-0045](../adr/0045-bounded-direct-connect-transport.md).

## 1. Who owns what

A networked program has two halves. Keep them apart: it is how the security holds.

**The host** is the application's own executable. It alone:
* reads the operator's credential file, holding the trust root, its own certificate and
  key, and either the server's pinned key or the players it admits;
* builds the transport and the `net.Service`, with its limits and **compatibility
  description**: the application id, its revision, the tick rate, a host-attested id, and
  the content packages it loaded, in load order;
* declares **grants** (a role, an endpoint and credentials, under a content id) and publishes
  the ones a consumer may use;
* pumps the service every frame;
* rotates credentials and revokes players.

**The consumer** is gameplay code, native or scripted, reaching the engine only through the
table. It can:
* find the grants it was given;
* open a session on one and register its channels;
* listen or connect;
* walk peers, read events, send and receive.

It never sees an address it did not get from a grant, a file, a key or a principal. A peer
is a participant number and nothing that identifies the player.

The engine gives payload bytes no meaning. The consumer's channels, commands and state are
the application's protocol. The server is authoritative, clients hold the complete state it
last sent, and nothing predicts.

## 2. The protocol, in one screen

A **server** session:
1. `net_session_create` on its grant, `net_channel_register` for each channel, then
   `net_session_listen`, which freezes the channels.
2. Each frame, drains `net_event_next`: `ADMITTED`, `ACTIVATED`, `ENDED`.
3. Each tick, calls `net_batch_admit(session, tick, &count)` with a strictly increasing tick.
   It then reads each admitted command with `net_batch_command` and `net_batch_copy`,
   ordered by participant and then by number, never by arrival. It applies them.
4. Walks `net_peer_next`:
   - a `SYNCHRONIZING` peer gets its one `net_baseline_send`;
   - an `ACTIVE` one gets `net_state_publish`. A newer state replaces one not yet sent.

A **client** session:
1. Registers the same channels, then calls `net_session_connect`.
2. Is `ADMITTED` with its participant number.
3. Takes its baseline with `net_delivery_take`, and applies it. Only
   `net_baseline_acknowledge` makes it `ACTIVE`.
4. Sends commands with `net_command_send`, which returns the command's number on this
   connection.
5. Takes each newer state, validating it before believing it.

Both sides must register the same channels. Negotiation compares the application,
revision, tick rate, attested id, every package and every channel, and refuses by category
and first difference.

## 3. The consumer: `relay.c`

A client says one line. The server admits it in a tick's batch and publishes a state naming
who said what. The client leaves once its own words come back. Each side also makes one
call the header documents as refused, and checks that it is:
* the server asks for a delivery, which is refused because commands arrive only in batches;
* the client opens a session on a grant nobody published, which is not found.

The host calls `relay_start` once, then `relay_step` every fixed step.

```c
/*
 * relay: an external networking consumer in C99. It sees `foundry.h` and the table its
 * host hands it, and nothing else. It names no address, file or key: its session exists
 * only because the host published a grant.
 *
 * A client says one line; the server admits it in a tick's batch and publishes a complete
 * state naming who said what; the client leaves once it sees its own words come back.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "foundry.h"

#define SAY_BYTES 64
#define STATE_BYTES 256

static const FoundryApi_v5 *api;
static FoundryNetSession session;
static FoundryNetPeer peer; /* the client's one connection */
static int32_t role;
static uint64_t tick;

static char heard[STATE_BYTES]; /* the server's state: the last line it admitted */
static uint32_t heard_len;
static FoundryNetPeer baselined[8];

static uint32_t participant; /* a client's, once admitted */
static uint64_t said;        /* the number net_command_send gave our line */
static int saw_echo;
static int served_one;
static int done; /* 1 success, -1 failure */

static FoundryContentId id(const char *name) { return foundry_content_id(name, strlen(name)); }

static const char *result_name(FoundryResult r)
{
    switch (r) {
    case FOUNDRY_OK: return "OK";
    case FOUNDRY_END: return "END";
    case FOUNDRY_ERR_REFUSED: return "REFUSED";
    case FOUNDRY_ERR_NOT_FOUND: return "NOT_FOUND";
    case FOUNDRY_ERR_UNAVAILABLE: return "UNAVAILABLE";
    case FOUNDRY_ERR_LIMIT: return "LIMIT";
    case FOUNDRY_ERR_INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    default: return "other";
    }
}

static int fail(const char *what, FoundryResult r)
{
    fprintf(stderr, "relay: %s failed: %s\n", what, result_name(r));
    done = -1;
    return -1;
}

/* Called once by the host, after it bound the table and published one grant. */
FOUNDRY_EXPORT int relay_start(FoundryGetApi get_api)
{
    FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
    FoundryNetGrantInfo grant;
    FoundryNetChannelDesc say, state;
    FoundryResult r;

    api = (const FoundryApi_v5 *)get_api(FOUNDRY_API_VERSION_5);
    if (api == NULL || api->version != FOUNDRY_API_VERSION_5) {
        fprintf(stderr, "relay: this host offers no FoundryApi_v5\n");
        return -1;
    }
    if ((r = api->net_grant_next(&cursor, &grant)) != FOUNDRY_OK) return fail("net_grant_next", r);
    role = grant.role;
    if ((r = api->net_session_create(grant.id, &session)) != FOUNDRY_OK) return fail("net_session_create", r);

    memset(&say, 0, sizeof say);
    say.id = id("relay:say");
    say.revision = 1;
    say.max_payload_bytes = SAY_BYTES;
    say.direction = FOUNDRY_NET_CLIENT_TO_SERVER;
    say.delivery = FOUNDRY_NET_RELIABLE;
    memset(&state, 0, sizeof state);
    state.id = id("relay:heard");
    state.revision = 1;
    state.max_payload_bytes = STATE_BYTES;
    state.direction = FOUNDRY_NET_SERVER_TO_CLIENT;
    state.delivery = FOUNDRY_NET_LATEST_STATE;
    if ((r = api->net_channel_register(session, &say)) != FOUNDRY_OK) return fail("register relay:say", r);
    if ((r = api->net_channel_register(session, &state)) != FOUNDRY_OK) return fail("register relay:heard", r);

    if (role == FOUNDRY_NET_SERVER) {
        FoundryNetSessionInfo info;
        if ((r = api->net_session_listen(session)) != FOUNDRY_OK) return fail("net_session_listen", r);
        if (api->net_session_info(session, &info) == FOUNDRY_OK)
            fprintf(stderr, "relay: serving on %u.%u.%u.%u:%u\n", info.listen_endpoint.address[0],
                    info.listen_endpoint.address[1], info.listen_endpoint.address[2],
                    info.listen_endpoint.address[3], info.listen_endpoint.port);
        heard_len = (uint32_t)sprintf(heard, "nothing yet");
    } else {
        FoundryNetSession other;
        /* A refused operation: a grant this host never published is no session. */
        r = api->net_session_create(id("relay:not-granted"), &other);
        fprintf(stderr, "relay: a session on an unpublished grant is answered %s\n", result_name(r));
        if (r == FOUNDRY_OK) return fail("the refusal check", r);
        if ((r = api->net_session_connect(session, &peer)) != FOUNDRY_OK) return fail("net_session_connect", r);
        fprintf(stderr, "relay: connecting\n");
    }
    return 0;
}

static void server_event(const FoundryNetEvent *e)
{
    uint32_t i;
    if (e->kind == FOUNDRY_NET_EVENT_ACTIVATED) {
        FoundryNetDelivery none;
        FoundryResult r;
        fprintf(stderr, "relay: participant %u active\n", e->participant);
        served_one = 1;
        /* A refused operation, as documented: a server's commands arrive only in batches. */
        r = api->net_delivery_next(e->peer, &none);
        fprintf(stderr, "relay: a server asking its peer for a delivery is answered %s\n", result_name(r));
        if (r != FOUNDRY_ERR_REFUSED) fail("the refusal check", r);
    }
    if (e->kind == FOUNDRY_NET_EVENT_ENDED) {
        fprintf(stderr, "relay: participant %u left (ending kind %d)\n", e->participant, e->ending.kind);
        for (i = 0; i < 8; i++)
            if (baselined[i].bits == e->peer.bits) baselined[i].bits = 0;
    }
}

static void client_event(const FoundryNetEvent *e)
{
    if (e->peer.bits != peer.bits) return;
    if (e->kind == FOUNDRY_NET_EVENT_ADMITTED) {
        participant = e->participant;
        fprintf(stderr, "relay: admitted as participant %u\n", participant);
    } else if (e->kind == FOUNDRY_NET_EVENT_ACTIVATED) {
        char line[SAY_BYTES];
        int n = sprintf(line, "hello from C99, participant %u", participant);
        FoundryResult r = api->net_command_send(peer, id("relay:say"), line, (uint32_t)n, &said);
        if (r != FOUNDRY_OK) { fail("net_command_send", r); return; }
        fprintf(stderr, "relay: active; said \"%s\" as command %llu\n", line, (unsigned long long)said);
    } else if (e->kind == FOUNDRY_NET_EVENT_ENDED) {
        fprintf(stderr, "relay: connection ended (kind %d, code %d)\n", e->ending.kind, e->ending.code);
        done = saw_echo ? 1 : -1;
    }
}

static void server_tick(void)
{
    uint32_t count = 0, i, walks;
    FoundryResult r;

    if (api->net_batch_admit(session, tick, &count) == FOUNDRY_OK) {
        for (i = 0; i < count; i++) {
            FoundryNetCommand cmd;
            char text[SAY_BYTES + 1];
            uint64_t needed = 0;
            if (api->net_batch_command(session, i, &cmd) != FOUNDRY_OK) continue;
            if (api->net_batch_copy(session, i, (uint8_t *)text, SAY_BYTES, &needed) != FOUNDRY_OK) continue;
            text[needed] = 0;
            heard_len = (uint32_t)sprintf(heard, "%u:%llu:%s", cmd.participant,
                                          (unsigned long long)cmd.number, text);
            fprintf(stderr, "relay: tick %llu admitted \"%s\" from participant %u\n",
                    (unsigned long long)tick, text, cmd.participant);
        }
    }

    for (walks = 0; walks < 3; walks++) {
        FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
        FoundryNetPeer p;
        for (;;) {
            FoundryNetPeerInfo info;
            r = api->net_peer_next(session, &cursor, &p);
            if (r != FOUNDRY_OK) break;
            if (api->net_peer_info(p, &info) != FOUNDRY_OK) continue;
            if (info.state == FOUNDRY_NET_PEER_SYNCHRONIZING) {
                int sent = 0;
                for (i = 0; i < 8; i++)
                    if (baselined[i].bits == p.bits) sent = 1;
                if (!sent && api->net_baseline_send(p, tick, heard, heard_len) == FOUNDRY_OK) {
                    for (i = 0; i < 8; i++)
                        if (baselined[i].bits == 0) { baselined[i] = p; break; }
                }
            } else if (info.state == FOUNDRY_NET_PEER_ACTIVE) {
                (void)api->net_state_publish(p, tick, heard, heard_len);
            }
        }
        if (r != FOUNDRY_ERR_INVALID_ARGUMENT) break; /* the walk finished; else begin again */
    }
}

static void client_receive(void)
{
    uint8_t bytes[STATE_BYTES + 1];
    uint64_t needed = 0;
    FoundryNetDelivery d;
    char expect[STATE_BYTES];

    while (api->net_delivery_take(peer, bytes, STATE_BYTES, &needed, &d) == FOUNDRY_OK) {
        bytes[needed] = 0;
        if (d.kind == FOUNDRY_NET_DELIVERY_BASELINE) {
            fprintf(stderr, "relay: baseline at tick %llu: \"%s\"\n", (unsigned long long)d.tick, (char *)bytes);
            (void)api->net_baseline_acknowledge(peer, d.sequence, d.tick);
        } else if (d.kind == FOUNDRY_NET_DELIVERY_STATE && said != 0 && !saw_echo) {
            sprintf(expect, "%u:%llu:", participant, (unsigned long long)said);
            if (strncmp((char *)bytes, expect, strlen(expect)) == 0) {
                saw_echo = 1;
                fprintf(stderr, "relay: the server's state at tick %llu says \"%s\"; leaving\n",
                        (unsigned long long)d.tick, (char *)bytes);
                (void)api->net_peer_disconnect(peer, FOUNDRY_NET_DISCONNECT_CLOSED);
            }
        }
    }
}

/* Called once per fixed step, after the host pumped. 0 to go on, 1 finished, -1 failed. */
FOUNDRY_EXPORT int relay_step(void)
{
    FoundryNetEvent e;
    tick++;
    while (api->net_event_next(&e) == FOUNDRY_OK) {
        if (e.session.bits != session.bits) continue;
        if (role == FOUNDRY_NET_SERVER) server_event(&e);
        else client_event(&e);
    }
    if (role == FOUNDRY_NET_SERVER) {
        FoundryNetSessionInfo info;
        server_tick();
        /* A server that has served someone ends once nobody is left. */
        if (served_one && api->net_session_info(session, &info) == FOUNDRY_OK && info.peers == 0 && info.pending == 0)
            done = 1;
    } else {
        client_receive();
    }
    return done;
}

FOUNDRY_EXPORT void relay_stop(void)
{
    FoundryNetStats s;
    if (api != NULL && api->net_stats(&s) == FOUNDRY_OK)
        fprintf(stderr, "relay: stats: %llu admitted, %llu commands admitted, %llu states sent, %llu bytes sent\n",
                (unsigned long long)s.admitted, (unsigned long long)s.commands_admitted,
                (unsigned long long)s.states_sent, (unsigned long long)s.bytes_sent);
    if (api != NULL) (void)api->net_session_close(session);
}
```

## 4. The host, outside the Foundry checkout

The host is a Zig program in its own directory. It depends on Foundry by path and imports
only the modules Foundry exports to a dependent: `abi`, `core`, `net` and `platform`. A
game would do the same. The consumer is compiled separately with nothing on its include path
but the **installed** header, the one `zig build` puts in `<prefix>/include/`.

`build.zig.zon`:

```zig
.{
    .name = .relay,
    .version = "0.0.1",
    .minimum_zig_version = "0.16.0",
    .fingerprint = 0x5d3ae2b98e334c37, // from `zig init`; yours will differ
    .dependencies = .{
        // Relative to this directory: the Foundry checkout.
        .foundry = .{ .path = "../Foundry" },
    },
    .paths = .{""},
}
```

`build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The installed header, from a Foundry install prefix: what a mod author has.
    const include = b.option([]const u8, "foundry-include", "Directory holding the installed foundry.h") orelse
        @panic("pass -Dfoundry-include=<install prefix>/include");

    // Foundry as a dependency, headless: this host has no window and draws nothing.
    const foundry = b.dependency("foundry", .{ .target = target, .optimize = optimize, .platform = .null, .rhi = .null });

    // The consumer: C99, pedantic, and given nothing but the installed header.
    const consumer = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    consumer.addIncludePath(.{ .cwd_relative = include });
    consumer.addCSourceFile(.{ .file = b.path("relay.c"), .flags = &.{ "-std=c99", "-pedantic", "-Wall", "-Wextra", "-Werror" } });
    const relay = b.addLibrary(.{ .name = "relay", .root_module = consumer, .linkage = .static });

    const host = b.createModule(.{ .root_source_file = b.path("host.zig"), .target = target, .optimize = optimize });
    for ([_][]const u8{ "abi", "core", "net", "platform" }) |name| host.addImport(name, foundry.module(name));
    host.linkLibrary(relay);
    const exe = b.addExecutable(.{ .name = "relay-host", .root_module = host });
    b.installArtifact(exe);
}
```

`host.zig`. The host reads the same credential file format the sandbox reads, so one
provisioning procedure (§6) serves both:

```zig
//! relay-host: a host outside the Foundry repository, built from Foundry's exported modules.
//! It owns what a consumer never sees — the credential files, the transport, the service,
//! the one grant — and hands the C consumer the public table and 60 steps a second.
//!
//!     relay-host --serve|--join <a.b.c.d:port> --credentials <file> [--seconds N]
//!
//! The credential file is the sandbox's format (`foundry-credentials 1`), so the same
//! provisioning serves both.
const std = @import("std");
const abi = @import("abi");
const core = @import("core");
const net = @import("net");
const platform = @import("platform");

const transport = platform.transport;

extern fn relay_start(get_api: *const fn (u32) callconv(.c) ?*const anyopaque) c_int;
extern fn relay_step() c_int;
extern fn relay_stop() void;

const step_ns: u64 = std.time.ns_per_s / 60;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    var role: ?transport.Role = null;
    var endpoint: ?transport.Endpoint = null;
    var cred_path: ?[]const u8 = null;
    var seconds: u64 = 60;
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--serve") or std.mem.eql(u8, flag, "--join")) {
            role = if (flag[2] == 's') .server else .client;
            endpoint = transport.Endpoint.parse(args.next() orelse return usage()) catch return usage();
        } else if (std.mem.eql(u8, flag, "--credentials")) {
            cred_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, flag, "--seconds")) {
            seconds = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch return usage();
        } else return usage();
    }
    if (role == null or cred_path == null) return usage();

    const os = try platform.os.Os.init(gpa, .{ .app_name = "relay-host" });
    defer os.deinit();

    // -- the operator's credentials -----------------------------------------------------
    const text = try os.readFile(gpa, cred_path.?, 16 * 1024);
    defer gpa.free(text);
    const dir = std.fs.path.dirname(cred_path.?) orelse ".";
    var file: CredFile = .{};
    try file.parse(text);
    if (file.server != (role.? == .server)) {
        std.log.err("the credential file is for the other role", .{});
        return 2;
    }

    var limits: net.limits.Limits = .{};
    limits.sessions = 1;
    const t = try transport.Transport.init(gpa, net.service.transportOptions(limits, .system));
    defer t.deinit();

    const trust = try readPart(gpa, os, dir, file.trust);
    defer gpa.free(trust);
    const chain = try readPart(gpa, os, dir, file.certificate);
    defer gpa.free(chain);
    const key = try readPart(gpa, os, dir, file.key);
    const credentials = t.createCredentials(.{
        .role = role.?,
        .trust_roots = trust,
        .certificate_chain = chain,
        .private_key = key,
        .server_name = file.server_name,
        .server_key = file.server_key,
    });
    std.crypto.secureZero(u8, key);
    gpa.free(key);
    const handle = credentials catch |err| {
        std.log.err("the credentials were refused: {t}", .{err});
        return 1;
    };

    // -- the service and the one grant --------------------------------------------------
    // What both sides must agree on: this application, its revision and tick rate. It
    // loads no content packages, so it describes none; a host with content lists them.
    const grant_id = core.ContentId.fromString(if (role.? == .server) "relay:serve" else "relay:join");
    const service = try net.Service.init(gpa, t, .{
        .limits = limits,
        .compatibility = .{
            .application = core.ContentId.fromString("relay:app"),
            .application_revision = 1,
            .tick_rate_millihertz = 60_000,
            .compatibility_id = @splat(0x52),
        },
        .grants = &.{.{ .id = grant_id, .role = role.?, .endpoint = endpoint.?, .credentials = handle }},
        .identities = file.allowed[0..file.allowed_count],
        .first_epoch = @max(1, @as(u64, @bitCast(os.wallClockNanos())) / std.time.ns_per_ms),
    });
    defer service.deinit();

    // No engine, world or renderer: a capability this host lacks answers Unavailable.
    const published = [_]core.ContentId{grant_id};
    var host: abi.Host = .{ .net_service = service, .net_grants = &published };
    host.bind();
    defer host.unbind();

    if (relay_start(abi.TableOf(abi.Host).getApi) != 0) return 1;
    defer relay_stop();

    // -- the loop: pump, step, pump, on an absolute schedule ----------------------------
    const start = os.monotonicNanos();
    var steps: u64 = 0;
    const bound = seconds * 60;
    const outcome: c_int = while (steps < bound) : (steps += 1) {
        service.pump(os.monotonicNanos());
        const r = relay_step();
        service.pump(os.monotonicNanos());
        if (r != 0) break r;
        const next = start + (steps + 1) * step_ns;
        const now = os.monotonicNanos();
        if (next > now) os.sleep(core.time.Duration.fromNanos(@intCast(next - now)));
    } else 0;

    if (outcome == 1) {
        std.log.info("relay: finished after {d} step(s)", .{steps});
        return 0;
    }
    std.log.err("relay: {s} after {d} step(s)", .{ if (outcome == 0) "ran out of time" else "failed", steps });
    return 1;
}

fn usage() u8 {
    std.log.err("usage: relay-host --serve|--join <a.b.c.d:port> --credentials <file> [--seconds N]", .{});
    return 2;
}

const CredFile = struct {
    server: bool = false,
    trust: []const u8 = "",
    certificate: []const u8 = "",
    key: []const u8 = "",
    server_name: []const u8 = "",
    server_key: ?transport.KeyFingerprint = null,
    allowed: [16]net.service.Identity = undefined,
    allowed_count: usize = 0,

    fn parse(self: *CredFile, text: []const u8) !void {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        if (!std.mem.eql(u8, lines.next() orelse "", "foundry-credentials 1")) return error.NotACredentialFile;
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const word = words.next() orelse continue;
            const value = words.next() orelse return error.Malformed;
            if (std.mem.eql(u8, word, "role")) {
                self.server = std.mem.eql(u8, value, "server");
            } else if (std.mem.eql(u8, word, "trust")) {
                self.trust = value;
            } else if (std.mem.eql(u8, word, "certificate")) {
                self.certificate = value;
            } else if (std.mem.eql(u8, word, "key")) {
                self.key = value;
            } else if (std.mem.eql(u8, word, "server-name")) {
                self.server_name = value;
            } else if (std.mem.eql(u8, word, "server-key")) {
                self.server_key = try fingerprint(value);
            } else if (std.mem.eql(u8, word, "allow")) {
                if (self.allowed_count == self.allowed.len) return error.TooManyKeys;
                const principal = try std.fmt.parseInt(u32, words.next() orelse return error.Malformed, 10);
                self.allowed[self.allowed_count] = .{ .key = try fingerprint(value), .principal = principal };
                self.allowed_count += 1;
            } else return error.Malformed;
        }
    }
};

fn fingerprint(hex: []const u8) !transport.KeyFingerprint {
    if (hex.len != 64) return error.Malformed;
    var out: transport.KeyFingerprint = .{ .sha256 = undefined };
    _ = try std.fmt.hexToBytes(&out.sha256, hex);
    return out;
}

fn readPart(gpa: std.mem.Allocator, os: *platform.os.Os, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    return os.readFile(gpa, path, 64 * 1024);
}
```

Three things the host does that a consumer cannot:
* **It publishes exactly the grants it chooses.** `net_grants` is the consumer's rights: a
  grant not in it answers `FOUNDRY_ERR_REFUSED`, or `FOUNDRY_ERR_NOT_FOUND` for one the
  service does not hold.
* **It pumps** before and after the consumer's step, on an absolute schedule. The sandbox
  learned this the hard way: sleeping a step *after* each frame drifts, and over ten minutes
  that drift inflated measured latency.
* **Its compatibility description is the handshake's catalogue.** This host loads no
  content, so it describes none. A host that loads content packages must list each one (id,
  version, size and SHA-256 of the loaded bytes) in load order, as the sandbox does. That is
  how a client with a different package is refused as `catalogue, entry N`, not left to play
  a different game. The `compatibility_id` is the host's attestation of whatever the
  catalogue cannot prove, such as its native code. Change it when that changes.

## 5. Build and run it

```sh
cd "$FOUNDRY_ROOT" && zig build --prefix "$FOUNDRY_PREFIX"     # installs include/foundry.h
cd "$RELAY_ROOT"   && zig build -Dfoundry-include="$FOUNDRY_PREFIX/include"
# For Windows, from the same Mac:
zig build -Dtarget=x86_64-windows-gnu -Dfoundry-include="$FOUNDRY_PREFIX/include"
```

`relay.c` compiles as C99 with `-pedantic -Wall -Wextra -Werror`. With credentials from §6,
run a server and a client as separate processes:

```sh
relay-host --serve 127.0.0.1:47811 --credentials server.cred &
relay-host --join  127.0.0.1:47811 --credentials player.cred
```

The client prints:

```text
relay: a session on an unpublished grant is answered NOT_FOUND
relay: connecting
relay: admitted as participant 1
relay: baseline at tick 6: "nothing yet"
relay: active; said "hello from C99, participant 1" as command 1
relay: the server's state at tick 10 says "1:1:hello from C99, participant 1"; leaving
relay: connection ended (kind 1, code 1)
```

The server prints:

```text
relay: serving on 127.0.0.1:47811
relay: participant 1 active
relay: a server asking its peer for a delivery is answered REFUSED
relay: tick 10 admitted "hello from C99, participant 1" from participant 1
relay: participant 1 left (ending kind 2)
```

Both exit 0. Tick numbers depend on timing.

## 6. Credentials: provisioning, rotation and revocation

Every connection is TLS 1.3 with a certificate on **both** sides. There is no plaintext mode
and no switch that turns verification off. What the transport requires:

* **P-256 ECDSA** keys.
* **Role-marked** certificates: extendedKeyUsage `serverAuth` for the server and
  `clientAuth` for a player. The wrong one is refused as `WRONG_USAGE`. keyUsage is
  optional; if present, it must allow `digitalSignature`.
* **Server name.** The server's certificate carries the DNS name clients name in
  `server-name`. A numeric address never replaces the name check.
* **Pinned server key.** A client also pins the server's key: the SHA-256 of its
  SubjectPublicKeyInfo DER. A certificate the root signed for some other key is still refused.
* **Admission by allowlist.** A server admits a player only if the player's key fingerprint
  is on its allowlist. A trusted certificate is not enough; unlisted keys are refused as
  `policy`.
* **Chain limits.** Chains of at most 4 certificates and 32 KiB.

**Making them** with OpenSSL 3. This exact script produced the credentials §5 ran with. Keep
`root.key` off the server.

```sh
set -e
O=${OPENSSL:-openssl}
# 1. The root: signs every server and player certificate. Keep root.key offline.
$O req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout root.key -out root.pem \
  -days 365 -subj "/CN=Example Game Root" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
# 2. The server: serverAuth, and the DNS name clients will expect in server-name.
$O req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout server.key -out server.csr -subj "/CN=game server"
$O x509 -req -in server.csr -CA root.pem -CAkey root.key -CAcreateserial -out server.pem -days 90 \
  -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:play.example.test\n")
# 3. A player: clientAuth.
$O req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout player.key -out player.csr -subj "/CN=player 1"
$O x509 -req -in player.csr -CA root.pem -CAkey root.key -CAcreateserial -out player.pem -days 90 \
  -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n")
# 4. Fingerprints: SHA-256 of each public key's DER SubjectPublicKeyInfo.
fp() { $O x509 -in "$1" -pubkey -noout | $O pkey -pubin -outform DER | $O dgst -sha256 -r | cut -d' ' -f1; }
printf 'foundry-credentials 1\nrole server\ntrust root.pem\ncertificate server.pem\nkey server.key\nallow %s 1\n' "$(fp player.pem)" > server.cred
printf 'foundry-credentials 1\nrole client\ntrust root.pem\ncertificate player.pem\nkey player.key\nserver-name play.example.test\nserver-key %s\n' "$(fp server.pem)" > player.cred
rm -f *.csr *.srl
```

**The credential file** is host-only, never content, and never crosses the table. Relative
paths are resolved from the file's own directory, and its keys and paths are never logged.

```text
foundry-credentials 1
role        server | client
trust       <PEM roots>
certificate <PEM chain, leaf first>
key         <PEM private key>      unencrypted P-256; wiped from memory once loaded
server-name <name>                 client only
server-key  <64 hex>               client only: SHA-256 of the server's public key
allow       <64 hex> <principal>   server only, repeatable: a player key and who it is
```

Several keys may name one principal, for example one player's two machines. A principal has
at most one live connection. Protect the files like passwords: on Windows, restrict the
directory to Administrators and SYSTEM **with inheritance** (`icacls <dir> /grant:r
"Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F"`, then `icacls <dir>\* /reset`). Removing
inheritance from a directory alone leaves its files with no access at all, which the host
reports as `CredentialFileUnreadable`.

**Revoking a player.**
* **Offline:** delete their `allow` line and restart the server. At their next connection
  they end as `REFUSED_BY_PEER`, code `POLICY`; the procedure above was run to confirm this.
* **Live:** a host calls `Service.revoke(key)` or `Service.replaceAllowlist(entries)`. Either
  ends that player's live connection as `revoked` at once. Nothing in `FoundryApi_v5` can do
  this; it is the host's.

**Rotating the server's credentials.**
1. Issue a new server certificate and key.
2. Give every client the new `server-key` **before** the switch, because clients pin the key.
3. Switch: restart with the new files, or call `Service.replaceCredentials(grant, handle)`
   live. Everything the old credentials authenticated ends as `rotated`, and every later
   connection uses the new ones.

To change the root, issue new players and servers under it and distribute them the same way.
There is no revocation list and no OCSP. The allowlist is the revocation mechanism, and
expiry is the backstop, so keep certificate lifetimes short.

The sandbox proof's `-- --provision <dir>` writes disposable identities valid until 2035. They
are test fixtures for loopback and trials. Never use them for anything you would not publish.

## 7. Deploying the authoritative server

* **It needs a publicly reachable IPv4 address.** Foundry connects directly: there is no relay,
  no NAT traversal and no IPv6 yet.
  - **Home lines:** many are behind **carrier-grade NAT** (CGNAT). Forwarding a port on your
    router then does nothing, because the router's WAN address is not the public one. Compare
    the router's WAN address with what `https://checkip.amazonaws.com` reports: if they
    differ, you cannot host from home.
  - **Players:** CGNAT on the *player's* side is fine. Only the server must be reachable.
* **A small cloud VM is enough.** The proof below used a 2-vCPU, 2 GB Windows Server 2025
  instance. A four-player server is a few kilobytes of state at 20 Hz.
* **Open exactly one port, twice:**
  - **The cloud firewall:** allow inbound TCP `<port>`. From anywhere is appropriate, because
    players' addresses change and every connection still needs an allowlisted certificate.
  - **The OS firewall:** allow the same port **for the server's executable only**:
    `New-NetFirewallRule -Direction Inbound -Action Allow -Protocol TCP -LocalPort <port>
    -Program <path to exe> -Profile Any`. Cloud VMs sit on the *Public* profile, so a rule
    scoped to *Private* never matches. The same applies to OpenSSH's default rule if you
    administer the VM over SSH.
  - **Remote administration:** narrow SSH or RDP to your own address.
* **Listen on `0.0.0.0:<port>`.** The server logs `serving on …`, and clients join the VM's
  public address. `server-name` stays the name in the server's certificate: it is checked
  against the certificate, not resolved in DNS.
* **Run it detached and bounded.** A headless host with no window paces one fixed step of real
  sleep per frame. Give it a stop condition: the sandbox has `FOUNDRY_SANDBOX_FRAMES` and
  `FOUNDRY_SANDBOX_NET_UNTIL_DEPARTED`. On Windows over SSH, a process started from the session
  dies with it. Start it with `Invoke-CimMethod Win32_Process -MethodName Create` instead, and
  give it its working directory explicitly.
* **Several players behind one address share one handshake budget.** It is 2 starts a second,
  with a burst of 2. Players who all join from one NAT at the same instant will see some
  reset, so join them about a second apart, or raise
  `handshake_starts_per_source_per_second` for that deployment.
* **Logs** carry the role, endpoint, peer counts, admission or refusal category and state
  ticks. By default they carry no payload, key, path or certificate content.

## 8. Limits, as measured

**Envelope.** One authority; 4 peers per session; 16 commands per peer per tick; 256 KiB
queued each way per peer; 256 allowlisted keys; 5 s to authenticate and 5 s to synchronize;
10 s without progress ends a peer. The per-source handshake limit is described in §7.

**Security, and what is not claimed.**
- **What is claimed:** TLS 1.3 with mutual certificates, a pinned server key, allowlist
  admission, catalogue refusal, bounded pre-authentication work, and validation of every
  input.
- **Negative tests pass over the public internet:**
  - an untrusted root: cut off in the handshake, never admitted;
  - an unlisted trusted key: refused as `policy`;
  - mismatched content: refused as `catalogue, entry 1`.

  M16 Step 7's matrix covers forged commands, a lying server, revoked and rotated keys,
  replayed and tampered TLS records, stalls and floods.
- **Packet capture:** a packet capture of a controlled session on the server held 550 packets
  and 292 TLS application-data records. The `FNET` wire magic and every content name
  appeared 0 times; the one legitimately plaintext string, the TLS server name, appeared.
  That observation is not itself a cryptographic proof.
- **Not claimed:**
  - anti-cheat beyond server authority;
  - DDoS resistance: floods were bounded in a harness, never measured against a real
    attacker;
  - Linux at runtime: it compiles, and runs from M18.

**Performance over the public internet**, 2026-09-23. One authority on a cloud VM in the
players' nearest region; the macOS/Metal and Windows/Vulkan sandboxes as clients; ten-minute
measured runs of 20 Hz state and a command every half second:

| Client network | Commands | p50 ack | p95 ack | worst ack | longest state gap |
| --- | --- | --- | --- | --- | --- |
| Home fixed broadband | 1,200 | 51 ms | 68 ms | 500 ms | 450 ms |
| Phone hotspot (mobile, CGNAT) | 1,199 | 100 ms | 118 ms | 2,418 ms | 2,452 ms |

**How to read the table:**
- "Ack" is the time from sending a command to seeing a state that applied it.
- Joining, leaving and rejoining three times on each network gave p95 81–100 ms.
- The hotspot run held one stall of about 2.4 s with no disconnect. It is recorded because it
  exceeds the 2 s state-gap budget the controlled harness used. It is attributed to the mobile
  link, since the broadband run's worst gap was 450 ms, but the logs cannot prove that.
- Real key presses crossed the two networks, from the Mac on the hotspot to the Windows PC on
  home broadband, with no lag the player could see.

## 9. Step 8 verification record

Run on 2026-09-23:

* **The external consumer.** The files in §3 and §4 were built in a directory outside the
  Foundry checkout, against an installed `foundry.h`, as C99 `-pedantic -Werror`.
  - **Runtime:** `relay-host` ran as two processes over loopback on macOS (Apple Silicon),
    and again on the Windows PC (x64). Both produced the output in §5 and exited 0.
  - **Credentials:** the §6 OpenSSL script produced working credentials, and removing a
    player's `allow` line refused that player by policy.
  - **Status:** the host is a temporary verification harness and is not shipped. This guide
    is the durable artifact. The automated equivalents in the repository are
    [`engine/tests/abi_networking.zig`](../../engine/tests/abi_networking.zig), with the C
    fixture [`net_client.c`](../../engine/tests/fixtures/net_client.c), and
    `zig build sandbox-net-matrix`.
* **Both desktops, each serving the other.** The relocated sandbox applications ran on a local
  network, and the owner pressed real keys on both machines:
  - a macOS/Metal client of a Windows/Vulkan server;
  - the reverse.

  The refusals (untrusted root, unlisted key, wrong role, mismatched content) and join, leave
  and rejoin also held across the two hosts.
* **The public internet.** The server was a cloud VM as in §7. The Windows client was on home
  broadband and the macOS client on a phone's mobile hotspot, which are separate access
  networks. The results are the joins, refusals, measured runs and capture above.
  Addresses, keys and certificates are not recorded here. All were disposable, and the
  credentials were deleted from the server when the proof ended.
