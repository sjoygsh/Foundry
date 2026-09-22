//! The v5 networking boundary: `net.Service`, published (`networking.md` §8, M16 Step 5).
//!
//! **This file translates and nothing else.** It resolves a handle, validates what came from
//! the other side, calls one service function and maps the answer. The host owns the
//! service, supplies its grants and credentials, and pumps it; nothing here pumps, opens a
//! socket, names an address or touches a key.
//!
//! **Rights are the grants the host published.** A grant the service holds and the host did
//! not publish is `refused`, as is every handle into a session on it, and its events stay
//! queued for the host rather than being taken or dropped here.
//!
//! **Order of checks**, as everywhere in the table (`sweep.zig`): a pointer argument is
//! validated before the host is looked up, so a null out-parameter is `invalid_argument`
//! even with nothing bound; a value — a handle, an enumeration, a grant — after, because
//! whether it means anything is the service's question.
//!
//! Design: `docs/design/networking.md` §8 and its Step 5 Resolution; the header is
//! `foundry.h`.

const std = @import("std");
const net = @import("net");

const net_types = @import("net_types.zig");
const types = @import("types.zig");

const ContentId = types.ContentId;
const Cursor = types.Cursor;
const Result = types.Result;
const svc = net.service;

const salt_grant: u32 = 0x4E45_0001;
const salt_channel: u32 = 0x4E45_0002;
const salt_peer: u32 = 0x4E45_0003;

/// Enough for every peer one session can hold: `Limits.peers_per_session` is at most 256.
const max_listed_peers = 256;

const Denied = error{ InvalidHandle, Refused };

fn denied(err: Denied) Result {
    return switch (err) {
        error.InvalidHandle => .invalid_handle,
        error.Refused => .refused,
    };
}

/// A payload from the other side: null with a nonzero size is refused, a zero size is empty.
fn payloadIn(bytes: ?[*]const u8, size: u32) ?[]const u8 {
    if (size == 0) return &.{};
    return (bytes orelse return null)[0..size];
}

fn nonZero(value: u32) u32 {
    return if (value == 0) std.math.maxInt(u32) else value;
}

fn walk(c: *const Cursor, expected: u32, count: usize) ?usize {
    if (!c.isBegin() and c.generation() != expected) return null;
    return @min(c.index(), count);
}

pub fn Of(comptime H: type) type {
    return struct {
        const Active = struct {
            host: *H,
            service: *net.Service,

            fn holds(self: Active, grant: ContentId) bool {
                for (0..self.service.grantCount()) |index| {
                    if (self.service.grantAt(index).?.id.eql(grant)) return true;
                }
                return false;
            }

            fn published(self: Active, grant: ContentId) bool {
                for (self.host.net_grants) |allowed| {
                    if (allowed.eql(grant)) return true;
                }
                return false;
            }

            fn session(self: Active, handle: types.NetSession) Denied!svc.SessionHandle {
                const id = handle.unwrap(svc.SessionHandle);
                const info = self.service.sessionInfo(id) orelse return error.InvalidHandle;
                if (!self.published(info.grant)) return error.Refused;
                return id;
            }

            fn peer(self: Active, handle: types.NetPeer) Denied!svc.PeerHandle {
                const id = handle.unwrap(svc.PeerHandle);
                const info = self.service.peerInfo(id) orelse return error.InvalidHandle;
                _ = try self.session(.wrap(info.session));
                return id;
            }

            fn roleOf(self: Active, id: svc.PeerHandle) svc.Role {
                return self.service.sessionInfo(self.service.peerInfo(id).?.session).?.role;
            }
        };

        fn active() ?Active {
            const host = H.current() orelse return null;
            return .{ .host = host, .service = host.net_service orelse return null };
        }

        // -- Grants ----------------------------------------------------------------------

        pub fn grantNext(cursor: ?*Cursor, out: ?*net_types.GrantInfo) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const published = a.host.net_grants;
            const generation = nonZero(salt_grant ^ @as(u32, @truncate(published.len)) *% 0x9e37_79b9);
            var at = walk(c, generation, published.len) orelse return .invalid_argument;
            while (at < published.len) : (at += 1) {
                for (0..a.service.grantCount()) |index| {
                    const grant = a.service.grantAt(index).?;
                    if (!grant.id.eql(published[at])) continue;
                    dst.* = .{ .id = grant.id, .role = net_types.role(grant.role), .endpoint = .of(grant.endpoint) };
                    c.* = .at(generation, @intCast(at + 1));
                    return .ok;
                }
            }
            c.* = .at(generation, @intCast(published.len));
            return .end;
        }

        // -- Sessions --------------------------------------------------------------------

        pub fn sessionCreate(grant: ContentId, out: ?*types.NetSession) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            if (!a.holds(grant)) return .not_found;
            if (!a.published(grant)) return .refused;
            const id = a.service.createSession(grant) catch |err| return switch (err) {
                error.UnknownGrant => .not_found,
                error.GrantInUse => .already_exists,
                error.LimitReached => .limit,
            };
            dst.* = .wrap(id);
            return .ok;
        }

        pub fn sessionClose(session: types.NetSession) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            a.service.closeSession(id);
            return .ok;
        }

        pub fn sessionInfo(session: types.NetSession, out: ?*net_types.SessionInfo) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            const info = a.service.sessionInfo(id).?;
            dst.* = .{
                .grant = info.grant,
                .role = net_types.role(info.role),
                .state = net_types.sessionState(info.state),
                .epoch = info.epoch,
                .channels = info.channels,
                .pending = info.pending,
                .peers = info.peers,
                .listening = types.boolOut(info.listening != null),
                .listen_endpoint = if (info.listening) |endpoint| .of(endpoint) else .{},
            };
            return .ok;
        }

        // -- Channels --------------------------------------------------------------------

        pub fn channelRegister(session: types.NetSession, desc: ?*const net_types.ChannelDesc) callconv(.c) Result {
            const src = desc orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            const descriptor: net.channel.Descriptor = .{
                .id = src.id,
                .revision = src.revision,
                .max_payload_bytes = src.max_payload_bytes,
                .direction = net_types.directionIn(src.direction) orelse return .invalid_argument,
                .delivery = net_types.deliveryIn(src.delivery) orelse return .invalid_argument,
            };
            a.service.registerChannel(id, descriptor) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.ChannelsFrozen => .refused,
                error.InvalidDescriptor, error.PayloadTooLarge, error.InvalidStateChannel => .invalid_argument,
                error.TooManyChannels, error.TooManyStateChannels => .limit,
                error.DuplicateChannel => .already_exists,
                // The service's limits were validated when it was built.
                error.ZeroLimit, error.LimitTooLarge, error.FrameTooSmall, error.QueueCannotHoldFrame, error.TooManyFullStateChannels, error.AggregateOverflow => Result.fromError(err),
            };
            return .ok;
        }

        pub fn channelNext(session: types.NetSession, cursor: ?*Cursor, out: ?*net_types.ChannelDesc) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            const channels = a.service.channelsOf(id);
            const info = a.service.sessionInfo(id).?;
            // Registration adds and freezing reorders, and either is a different walk.
            const generation = nonZero(salt_channel ^ @as(u32, @truncate(channels.len)) *% 0x9e37_79b9 ^ @as(u32, @intFromEnum(info.state)) << 16 ^ id.generation);
            const at = walk(c, generation, channels.len) orelse return .invalid_argument;
            if (at >= channels.len) {
                c.* = .at(generation, @intCast(channels.len));
                return .end;
            }
            const descriptor = channels[at];
            dst.* = .{
                .id = descriptor.id,
                .revision = descriptor.revision,
                .max_payload_bytes = descriptor.max_payload_bytes,
                .direction = net_types.direction(descriptor.direction),
                .delivery = net_types.delivery(descriptor.delivery),
            };
            c.* = .at(generation, @intCast(at + 1));
            return .ok;
        }

        // -- Starting --------------------------------------------------------------------

        pub fn sessionListen(session: types.NetSession) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            a.service.listen(id) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongRole, error.AlreadyRunning, error.NoChannels => .refused,
                error.InvalidGrant, error.AddressUnavailable, error.PermissionDenied, error.NetworkUnavailable => .refused,
                error.EpochExhausted, error.LimitReached, error.SystemResources => .limit,
                error.AddressInUse => .already_exists,
                error.Unexpected => Result.fromError(err),
            };
            return .ok;
        }

        pub fn sessionConnect(session: types.NetSession, out: ?*types.NetPeer) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            const peer = a.service.connect(id) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongRole, error.AlreadyConnected, error.NoChannels => .refused,
                error.InvalidGrant, error.NetworkUnavailable => .refused,
                error.LimitReached, error.EventQueueFull, error.TlsMemoryExhausted, error.SystemResources => .limit,
            };
            dst.* = .wrap(peer);
            return .ok;
        }

        // -- Peers -----------------------------------------------------------------------

        pub fn peerNext(session: types.NetSession, cursor: ?*Cursor, out: ?*types.NetPeer) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            var listed: [max_listed_peers]svc.PeerHandle = undefined;
            const count = @min(a.service.sessionPeers(id, &listed), listed.len);
            // A connection added or removed anywhere is a different walk.
            const generation = nonZero(salt_peer ^ a.service.revision *% 0x9e37_79b9 ^ id.generation);
            const at = walk(c, generation, count) orelse return .invalid_argument;
            if (at >= count) {
                c.* = .at(generation, @intCast(count));
                return .end;
            }
            dst.* = .wrap(listed[at]);
            c.* = .at(generation, @intCast(at + 1));
            return .ok;
        }

        pub fn peerInfo(peer: types.NetPeer, out: ?*net_types.PeerInfo) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            const info = a.service.peerInfo(id).?;
            dst.* = .{
                .session = .wrap(info.session),
                .state = net_types.peerState(info.state),
                .participant = info.participant,
                .epoch = info.epoch,
            };
            return .ok;
        }

        pub fn peerDisconnect(peer: types.NetPeer, reason: i32) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            const why = net_types.disconnectReasonIn(reason) orelse return .invalid_argument;
            a.service.disconnect(id, why) catch return .invalid_handle;
            return .ok;
        }

        // -- Events and stats ------------------------------------------------------------

        pub fn eventNext(out: ?*net_types.Event) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const event = a.service.nextEventFor(a.host.net_grants) orelse return .end;
            dst.* = .{ .session = .wrap(event.session), .peer = .wrap(event.peer) };
            switch (event.kind) {
                .admitted => |admission| {
                    dst.kind = net_types.event_admitted;
                    dst.participant = admission.participant;
                    dst.epoch = admission.epoch;
                },
                .activated => |activation| {
                    dst.kind = net_types.event_activated;
                    dst.participant = activation.participant;
                    dst.epoch = activation.epoch;
                },
                .ended => |departure| {
                    dst.kind = net_types.event_ended;
                    dst.participant = departure.participant;
                    dst.ending = net_types.ending(departure.ending);
                },
            }
            return .ok;
        }

        pub fn stats(out: ?*net_types.Stats) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            dst.* = .of(a.service.stats());
            return .ok;
        }

        // -- Initial state ---------------------------------------------------------------

        pub fn baselineSend(peer: types.NetPeer, tick: u64, bytes: ?[*]const u8, size: u32) callconv(.c) Result {
            const payload = payloadIn(bytes, size) orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            a.service.sendBaseline(id, tick, payload) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongRole, error.WrongState, error.NoStateChannel, error.BaselineAlreadySent => .refused,
                error.PayloadTooLarge => .invalid_argument,
                error.QueueFull => .limit,
            };
            return .ok;
        }

        pub fn baselineAcknowledge(peer: types.NetPeer, sequence: u64, tick: u64) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            a.service.acknowledgeBaseline(id, .{ .sequence = sequence, .tick = tick }) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongRole, error.WrongState, error.StaleBaseline => .refused,
                error.QueueFull => .limit,
            };
            return .ok;
        }

        // -- Sending ---------------------------------------------------------------------

        pub fn statePublish(peer: types.NetPeer, tick: u64, bytes: ?[*]const u8, size: u32) callconv(.c) Result {
            const payload = payloadIn(bytes, size) orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            a.service.publishState(id, tick, payload) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongRole, error.WrongState, error.NoStateChannel, error.StaleTick => .refused,
                error.PayloadTooLarge => .invalid_argument,
            };
            return .ok;
        }

        pub fn commandSend(peer: types.NetPeer, channel_id: ContentId, bytes: ?[*]const u8, size: u32, number: ?*u64) callconv(.c) Result {
            const payload = payloadIn(bytes, size) orelse return .invalid_argument;
            const dst = number orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            dst.* = a.service.sendCommand(id, channel_id, payload) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongState, error.WrongChannel => .refused,
                error.UnknownChannel => .not_found,
                error.PayloadTooLarge => .invalid_argument,
                error.QueueFull, error.SequenceExhausted => .limit,
            };
            return .ok;
        }

        // -- Receiving -------------------------------------------------------------------

        fn deliveryOut(delivery: svc.Delivery) net_types.Delivery {
            return .{
                .kind = net_types.deliveryKind(delivery.kind),
                .bytes = delivery.bytes,
                .channel = delivery.channel,
                .tick = delivery.tick,
                .sequence = delivery.sequence,
            };
        }

        pub fn deliveryNext(peer: types.NetPeer, out: ?*net_types.Delivery) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            // A server's commands reach its host only through admission.
            if (a.roleOf(id) != .client) return .refused;
            dst.* = deliveryOut(a.service.nextDelivery(id) orelse return .end);
            return .ok;
        }

        pub fn deliveryTake(peer: types.NetPeer, buffer: ?[*]u8, capacity: u64, needed: ?*u64, out: ?*net_types.Delivery) callconv(.c) Result {
            const length = needed orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            if (capacity > 0 and buffer == null) return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.peer(peer) catch |err| return denied(err);
            if (a.roleOf(id) != .client) return .refused;
            const next = a.service.nextDelivery(id) orelse {
                length.* = 0;
                return .end;
            };
            length.* = next.bytes;
            if (next.bytes > capacity) return .limit;
            const room: usize = @intCast(@min(capacity, next.bytes));
            const taken = (a.service.takeDelivery(id, if (room == 0) &.{} else buffer.?[0..room]) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongRole => .refused,
                error.BufferTooSmall => .limit,
            }) orelse return .end;
            dst.* = deliveryOut(taken);
            return .ok;
        }

        // -- Admission -------------------------------------------------------------------

        pub fn batchAdmit(session: types.NetSession, tick: u64, count: ?*u32) callconv(.c) Result {
            const dst = count orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            const batch = a.service.admitBatch(id, tick) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.WrongRole, error.WrongState, error.StaleTick => .refused,
            };
            dst.* = batch.count;
            return .ok;
        }

        pub fn batchCommand(session: types.NetSession, index: u32, out: ?*net_types.Command) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            if (a.service.sessionInfo(id).?.role != .server) return .refused;
            const command = a.service.batchCommand(id, index) orelse return .not_found;
            dst.* = .{
                .peer = .wrap(command.peer),
                .participant = command.participant,
                .bytes = command.bytes,
                .number = command.number,
                .channel = command.channel,
            };
            return .ok;
        }

        pub fn batchCopy(session: types.NetSession, index: u32, buffer: ?[*]u8, capacity: u64, needed: ?*u64) callconv(.c) Result {
            const length = needed orelse return .invalid_argument;
            if (capacity > 0 and buffer == null) return .invalid_argument;
            const a = active() orelse return .unavailable;
            const id = a.session(session) catch |err| return denied(err);
            if (a.service.sessionInfo(id).?.role != .server) return .refused;
            const command = a.service.batchCommand(id, index) orelse return .not_found;
            length.* = command.bytes;
            if (command.bytes > capacity) return .limit;
            if (command.bytes == 0) return .ok;
            _ = a.service.copyBatchPayload(id, index, buffer.?[0..command.bytes]) catch |err| return switch (err) {
                error.InvalidHandle => .invalid_handle,
                error.NoSuchCommand => .not_found,
                error.BufferTooSmall => .limit,
            };
            return .ok;
        }
    };
}
