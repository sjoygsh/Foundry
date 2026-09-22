//! The sandbox's connected demonstration: shared markers, authoritative on one server
//! (`networking.md` §7 and §9, M16 Step 6).
//!
//! **This module sees only `foundry.h`**, through `foundry_api`, and `std` utilities. The
//! build grants it nothing else, exactly as it grants the editor's client nothing else
//! (`editor.md` §3), and a boundary test plus a deliberately failing import keep it that
//! way. Every session, channel, peer, event, delivery, command, content record, texture,
//! sprite and label below crosses `FoundryApi_v5`. What the host does that this cannot —
//! build the service from credential files, read the keyboard, pump the network, pace a
//! headless run — it does outside, and hands in an `Intent`, a viewport and nothing more.
//!
//! ## What it is
//!
//! A marker is one participant's shared object. The server owns every marker: it creates
//! one when a peer activates and removes it when that peer's connection ends, and it moves
//! each by the latest **intent** its owner sent — a direction, not a position, so a client
//! can only ever ask. The server's own view drives marker 1 the same way, from its own
//! host's keys. Every `state_every` ticks the server sends each active peer the complete
//! list; a joining peer first gets that list as its **baseline** and is active only once
//! it has applied and acknowledged it.
//!
//! A client never advances anything. It holds the last complete state it validated, draws
//! it, and says how old it is. Its input stays visibly pending until a state reports the
//! server applied it.
//!
//! ## The wire, which is this module's and not the engine's
//!
//! Two channels. `sandbox:net.move`, client to server, reliable: four bytes, `dx` and `dy`
//! as signed bytes in -1..1 and two zero bytes. `sandbox:net.state`, server to client,
//! latest-state: an 8-byte header (`count` u32, a zero u32) and then `count` markers of 24
//! bytes each (`number` u32, `owner` u32, `x` f32, `y` f32, `applied` u64), little-endian.
//! Numbers are assigned monotonically by the server and never reused in its session.
//! A state that is short, long, over-full, non-zero where zero is owed, non-finite, outside
//! the arena, duplicated in number or owner, or that resurrects a number already removed,
//! is refused whole: the last complete view stands, and the view disconnects saying why.

const std = @import("std");
const c = @import("foundry_api").c;

pub const Api = c.FoundryApi_v5;

const Result = c.FoundryResult;
const Cursor = c.FoundryCursor;
const ContentId = c.FoundryContentId;
const Session = c.FoundryNetSession;
const Peer = c.FoundryNetPeer;
const Record = c.FoundryRecord;

/// The server's own marker and four peers, with room to spare. Bounded here because every
/// buffer below is sized from it; the service's own peer limit is lower.
pub const max_markers: u32 = 8;
/// Peers whose baseline the server has sent and whose activation it is waiting for.
const max_pending: u32 = 16;
/// Events and deliveries taken per frame. A frame that had more leaves them for the next.
const max_drain: u32 = 64;
const max_label: usize = 48;
const max_key_name: usize = 16;

pub const command_bytes: u32 = 4;
pub const state_header_bytes: u32 = 8;
pub const marker_bytes: u32 = 24;
pub const max_state_bytes: u32 = state_header_bytes + max_markers * marker_bytes;

pub const settings_name = "sandbox:net.markers";
const move_channel_name = "sandbox:net.move";
const state_channel_name = "sandbox:net.state";
/// Bumped whenever either payload layout changes. Both are compared at negotiation, so two
/// builds that disagree are refused by channel before a single marker crosses.
pub const protocol_revision: u32 = 1;

// -- the codec ------------------------------------------------------------------------

pub const Intent = struct {
    dx: i8 = 0,
    dy: i8 = 0,

    pub fn eql(a: Intent, b: Intent) bool {
        return a.dx == b.dx and a.dy == b.dy;
    }

    fn valid(self: Intent) bool {
        return self.dx >= -1 and self.dx <= 1 and self.dy >= -1 and self.dy <= 1;
    }
};

pub fn encodeCommand(intent: Intent) [command_bytes]u8 {
    return .{ @bitCast(intent.dx), @bitCast(intent.dy), 0, 0 };
}

/// An admitted command's bytes, or null if they are not one this protocol could have sent.
pub fn decodeCommand(bytes: []const u8) ?Intent {
    if (bytes.len != command_bytes) return null;
    if (bytes[2] != 0 or bytes[3] != 0) return null;
    const intent: Intent = .{ .dx = @bitCast(bytes[0]), .dy = @bitCast(bytes[1]) };
    return if (intent.valid()) intent else null;
}

pub const Marker = struct {
    number: u32,
    owner: u32,
    x: f32,
    y: f32,
    /// The owner's last command the server applied, by the number the owner's
    /// `net_command_send` returned. 0 before any.
    applied: u64 = 0,
};

pub const Arena = struct {
    x: f32 = -80,
    y: f32 = -64,
    w: f32 = 160,
    h: f32 = 128,

    fn contains(self: Arena, x: f32, y: f32) bool {
        return x >= self.x and x <= self.x + self.w and y >= self.y and y <= self.y + self.h;
    }

    fn clampX(self: Arena, x: f32) f32 {
        return std.math.clamp(x, self.x, self.x + self.w);
    }

    fn clampY(self: Arena, y: f32) f32 {
        return std.math.clamp(y, self.y, self.y + self.h);
    }
};

pub fn encodeState(markers: []const Marker, out: *[max_state_bytes]u8) u32 {
    std.debug.assert(markers.len <= max_markers);
    std.mem.writeInt(u32, out[0..4], @intCast(markers.len), .little);
    std.mem.writeInt(u32, out[4..8], 0, .little);
    for (markers, 0..) |m, i| {
        const at = out[state_header_bytes + i * marker_bytes ..][0..marker_bytes];
        std.mem.writeInt(u32, at[0..4], m.number, .little);
        std.mem.writeInt(u32, at[4..8], m.owner, .little);
        std.mem.writeInt(u32, at[8..12], @bitCast(m.x), .little);
        std.mem.writeInt(u32, at[12..16], @bitCast(m.y), .little);
        std.mem.writeInt(u64, at[16..24], m.applied, .little);
    }
    return state_header_bytes + @as(u32, @intCast(markers.len)) * marker_bytes;
}

pub const StateError = error{
    Truncated,
    TooMany,
    Reserved,
    ZeroNumber,
    DuplicateNumber,
    DuplicateOwner,
    NotFinite,
    OutsideArena,
    Resurrected,
};

pub const Snapshot = struct {
    count: u32 = 0,
    markers: [max_markers]Marker = undefined,

    pub fn slice(self: *const Snapshot) []const Marker {
        return self.markers[0..self.count];
    }

    fn find(self: *const Snapshot, number: u32) ?*const Marker {
        for (self.slice()) |*m| if (m.number == number) return m;
        return null;
    }
};

/// Validates `bytes` into `out` without touching anything else, so a refused state leaves
/// whatever the caller was showing exactly as it was. `highest` is the largest number the
/// view has ever accepted and `previous` what it holds now: a number at or below `highest`
/// that `previous` does not hold was removed, and numbers are never reused.
pub fn decodeState(bytes: []const u8, arena: Arena, previous: *const Snapshot, highest: u32, out: *Snapshot) StateError!void {
    if (bytes.len < state_header_bytes) return error.Truncated;
    const count = std.mem.readInt(u32, bytes[0..4], .little);
    if (std.mem.readInt(u32, bytes[4..8], .little) != 0) return error.Reserved;
    if (count > max_markers) return error.TooMany;
    if (bytes.len != state_header_bytes + count * marker_bytes) return error.Truncated;

    var candidate: Snapshot = .{ .count = count };
    for (0..count) |i| {
        const at = bytes[state_header_bytes + i * marker_bytes ..][0..marker_bytes];
        const m: Marker = .{
            .number = std.mem.readInt(u32, at[0..4], .little),
            .owner = std.mem.readInt(u32, at[4..8], .little),
            .x = @bitCast(std.mem.readInt(u32, at[8..12], .little)),
            .y = @bitCast(std.mem.readInt(u32, at[12..16], .little)),
            .applied = std.mem.readInt(u64, at[16..24], .little),
        };
        if (m.number == 0) return error.ZeroNumber;
        if (!std.math.isFinite(m.x) or !std.math.isFinite(m.y)) return error.NotFinite;
        if (!arena.contains(m.x, m.y)) return error.OutsideArena;
        for (candidate.markers[0..i]) |other| {
            if (other.number == m.number) return error.DuplicateNumber;
            if (other.owner == m.owner) return error.DuplicateOwner;
        }
        if (m.number <= highest and previous.find(m.number) == null) return error.Resurrected;
        candidate.markers[i] = m;
    }
    out.* = candidate;
}

// -- settings ---------------------------------------------------------------------------

pub const Direction = enum { up, down, left, right };

const Label = struct {
    bytes: [max_label]u8 = @splat(0),
    len: usize = 0,

    fn set(self: *Label, value: []const u8) void {
        self.len = @min(value.len, max_label);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }

    pub fn text(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// `sandbox:net.markers`, copied out of the record once: nothing here borrows content
/// across a frame.
pub const Settings = struct {
    sheet: ContentId = .{ .hash = 0 },
    columns: u32 = 4,
    rows: u32 = 4,
    cell: u32 = 0,
    size: f32 = 14,
    speed: f32 = 60,
    arena: Arena = .{},
    spacing: f32 = 24,
    tints: [max_markers][3]f32 = @splat(.{ 1, 1, 1 }),
    tint_count: u32 = 1,
    state_every: u32 = 3,
    stale_ms: u32 = 2000,
    keys: [4][max_key_name]u8 = @splat(@splat(0)),
    key_lens: [4]usize = @splat(0),
    title: Label = .{},
    server: Label = .{},
    client: Label = .{},
    waiting: Label = .{},
    you: Label = .{},
    pending: Label = .{},
    stale: Label = .{},
    ended: Label = .{},

    pub fn keyName(self: *const Settings, direction: Direction) []const u8 {
        const i = @intFromEnum(direction);
        return self.keys[i][0..self.key_lens[i]];
    }
};

pub const InitError = error{
    WrongVersion,
    NoSettings,
    BadSettings,
    NoGrant,
    SessionRefused,
    ChannelRefused,
    StartRefused,
};

fn readSettings(api: *const Api) InitError!Settings {
    var record: Record = undefined;
    if (api.content_find.?(id(settings_name), &record) != c.FOUNDRY_OK) return error.NoSettings;
    const r: Reader = .{ .api = api, .record = record };
    var s: Settings = .{};
    s.sheet = try r.contentId("sheet");
    s.columns = try r.unsigned("columns");
    s.rows = try r.unsigned("rows");
    s.cell = try r.unsigned("cell");
    s.size = try r.float("size");
    s.speed = try r.float("speed");
    s.spacing = try r.float("spacing");
    s.state_every = try r.unsigned("state_every");
    s.stale_ms = try r.unsigned("stale_ms");
    if (s.columns == 0 or s.rows == 0 or s.cell >= s.columns * s.rows) return error.BadSettings;
    if (s.state_every == 0 or !(s.size > 0) or !(s.speed >= 0) or !std.math.isFinite(s.spacing)) return error.BadSettings;

    const arena = try r.nested("arena");
    s.arena = .{
        .x = try arena.float("x"),
        .y = try arena.float("y"),
        .w = try arena.float("w"),
        .h = try arena.float("h"),
    };
    if (!(s.arena.w > 0) or !(s.arena.h > 0) or !std.math.isFinite(s.arena.x) or !std.math.isFinite(s.arena.y)) {
        return error.BadSettings;
    }

    const tints = try r.field("tints");
    var count: u32 = 0;
    if (api.record_list_len.?(record, tints, &count) != c.FOUNDRY_OK) return error.BadSettings;
    s.tint_count = @max(1, @min(count, max_markers));
    for (0..@min(count, max_markers)) |i| {
        var nested: Record = undefined;
        if (api.record_list_nested.?(record, tints, @intCast(i), &nested) != c.FOUNDRY_OK) return error.BadSettings;
        const t: Reader = .{ .api = api, .record = nested };
        s.tints[i] = .{ try t.float("r"), try t.float("g"), try t.float("b") };
    }

    inline for (.{ "key_up", "key_down", "key_left", "key_right" }, 0..) |name, i| {
        const text = try r.string(name);
        if (text.len == 0 or text.len > max_key_name) return error.BadSettings;
        @memcpy(s.keys[i][0..text.len], text);
        s.key_lens[i] = text.len;
    }
    s.title.set(try r.string("label_title"));
    s.server.set(try r.string("label_server"));
    s.client.set(try r.string("label_client"));
    s.waiting.set(try r.string("label_waiting"));
    s.you.set(try r.string("label_you"));
    s.pending.set(try r.string("label_pending"));
    s.stale.set(try r.string("label_stale"));
    s.ended.set(try r.string("label_ended"));
    return s;
}

/// A record read by field name, the way any mod reads a record type: ask the schema where a
/// field is, then call the reader for its type. Every failure is `BadSettings`, because a
/// package that overrides this record wrongly is a content error, not a crash.
const Reader = struct {
    api: *const Api,
    record: Record,

    fn field(self: Reader, name: []const u8) InitError!u32 {
        var index: u32 = 0;
        if (self.api.record_field_index.?(self.record, str(name), &index) != c.FOUNDRY_OK) return error.BadSettings;
        return index;
    }

    fn unsigned(self: Reader, name: []const u8) InitError!u32 {
        var value: u64 = 0;
        if (self.api.record_get_u64.?(self.record, try self.field(name), &value) != c.FOUNDRY_OK) return error.BadSettings;
        return std.math.cast(u32, value) orelse error.BadSettings;
    }

    fn float(self: Reader, name: []const u8) InitError!f32 {
        var value: f32 = 0;
        if (self.api.record_get_f32.?(self.record, try self.field(name), &value) != c.FOUNDRY_OK) return error.BadSettings;
        return value;
    }

    fn contentId(self: Reader, name: []const u8) InitError!ContentId {
        var value: ContentId = undefined;
        if (self.api.record_get_id.?(self.record, try self.field(name), &value) != c.FOUNDRY_OK) return error.BadSettings;
        return value;
    }

    fn string(self: Reader, name: []const u8) InitError![]const u8 {
        var value: c.FoundryStr = undefined;
        if (self.api.record_get_string.?(self.record, try self.field(name), &value) != c.FOUNDRY_OK) return error.BadSettings;
        return if (value.len == 0) "" else value.ptr[0..@intCast(value.len)];
    }

    fn nested(self: Reader, name: []const u8) InitError!Reader {
        var inner: Record = undefined;
        if (self.api.record_nested.?(self.record, try self.field(name), &inner) != c.FOUNDRY_OK) return error.BadSettings;
        return .{ .api = self.api, .record = inner };
    }
};

// -- the demonstration --------------------------------------------------------------------

pub const Role = enum { server, client };

pub const Phase = enum {
    /// A server listening, with or without peers.
    serving,
    /// A client whose connection has not yet been admitted.
    connecting,
    /// Admitted and sent a baseline it has not yet applied, or applied and not yet activated.
    synchronizing,
    active,
    /// The connection is over; `ending` says why.
    ended,
};

/// What a host or a proof can ask without reaching inside: counts, the phase and the last
/// ending. Nothing in it names a player.
pub const Status = struct {
    role: Role,
    phase: Phase,
    participant: u32 = 0,
    peers: u16 = 0,
    markers: u32 = 0,
    tick: u64 = 0,
    /// The last command this view sent, by number, and the last the server said it applied.
    sent: u64 = 0,
    acknowledged: u64 = 0,
    /// Server: peers that were active and have since gone. Client: 0.
    departed: u32 = 0,
    rejected_commands: u32 = 0,
    refused_states: u32 = 0,
    ending: ?c.FoundryNetEnding = null,
    listen: ?c.FoundryNetEndpoint = null,

    pub fn pending(self: Status) bool {
        return self.sent > self.acknowledged;
    }
};

pub const Markers = struct {
    api: *const Api,
    settings: Settings,
    role: Role,
    session: Session,
    /// A client's one connection. Stale once it has ended.
    peer: Peer = .{ .bits = 0 },
    phase: Phase,
    participant: u32 = 0,
    texture: c.FoundryTexture = .{ .bits = 0 },
    sheet_asset: c.FoundryAsset = .{ .bits = 0 },
    ending: ?c.FoundryNetEnding = null,

    // Server state: the authoritative markers and each one's current intent.
    objects: Snapshot = .{},
    intents: [max_markers]Intent = @splat(.{}),
    next_number: u32 = 1,
    tick: u64 = 0,
    baselined: [max_pending]u64 = @splat(0),
    departed: u32 = 0,
    rejected_commands: u32 = 0,

    // Client state: the last validated view and what it has sent.
    view: Snapshot = .{},
    view_tick: u64 = 0,
    highest: u32 = 0,
    sent_intent: Intent = .{},
    sent: u64 = 0,
    refused_states: u32 = 0,
    /// Simulation time of the last state applied, for staleness.
    view_at_ns: u64 = 0,
    have_view: bool = false,

    /// Finds the one grant this host published, starts a session on it and — as a server —
    /// listens, or — as a client — connects.
    pub fn init(api: *const Api) InitError!Markers {
        if (api.version != c.FOUNDRY_API_VERSION_5) return error.WrongVersion;
        const settings = try readSettings(api);

        var cursor: Cursor = .{ .bits = 0 };
        var grant: c.FoundryNetGrantInfo = undefined;
        if (api.net_grant_next.?(&cursor, &grant) != c.FOUNDRY_OK) return error.NoGrant;
        const role: Role = switch (grant.role) {
            c.FOUNDRY_NET_SERVER => .server,
            c.FOUNDRY_NET_CLIENT => .client,
            else => return error.NoGrant,
        };

        var session: Session = undefined;
        if (api.net_session_create.?(grant.id, &session) != c.FOUNDRY_OK) return error.SessionRefused;
        errdefer _ = api.net_session_close.?(session);
        const channels = [_]c.FoundryNetChannelDesc{
            .{
                .id = id(move_channel_name),
                .revision = protocol_revision,
                .max_payload_bytes = command_bytes,
                .direction = c.FOUNDRY_NET_CLIENT_TO_SERVER,
                .delivery = c.FOUNDRY_NET_RELIABLE,
            },
            .{
                .id = id(state_channel_name),
                .revision = protocol_revision,
                .max_payload_bytes = max_state_bytes,
                .direction = c.FOUNDRY_NET_SERVER_TO_CLIENT,
                .delivery = c.FOUNDRY_NET_LATEST_STATE,
            },
        };
        for (&channels) |*desc| {
            if (api.net_channel_register.?(session, desc) != c.FOUNDRY_OK) return error.ChannelRefused;
        }

        var self: Markers = .{
            .api = api,
            .settings = settings,
            .role = role,
            .session = session,
            .phase = if (role == .server) .serving else .connecting,
        };
        switch (role) {
            .server => {
                if (api.net_session_listen.?(session) != c.FOUNDRY_OK) return error.StartRefused;
                // The server's own marker is participant 0's, and number 1.
                self.spawn(0);
            },
            .client => if (api.net_session_connect.?(session, &self.peer) != c.FOUNDRY_OK) return error.StartRefused,
        }

        // A missing texture draws nothing and costs nothing else: the demonstration still
        // runs, and says so once.
        if (api.asset_acquire.?(settings.sheet, &self.sheet_asset) == c.FOUNDRY_OK) {
            if (api.render_texture_of_asset.?(self.sheet_asset, &self.texture) != c.FOUNDRY_OK) {
                self.say(c.FOUNDRY_LOG_WARN, "markers: the sheet is not a texture; markers will not be drawn", .{});
            }
        } else {
            self.say(c.FOUNDRY_LOG_WARN, "markers: the sheet is not loaded; markers will not be drawn", .{});
        }

        if (role == .server) {
            if (self.status().listen) |at| {
                self.say(c.FOUNDRY_LOG_INFO, "markers: serving on {d}.{d}.{d}.{d}:{d}", .{ at.address[0], at.address[1], at.address[2], at.address[3], at.port });
            }
        } else {
            self.say(c.FOUNDRY_LOG_INFO, "markers: connecting", .{});
        }
        return self;
    }

    pub fn deinit(self: *Markers) void {
        _ = self.api.net_session_close.?(self.session);
        if (self.texture.bits != 0) _ = self.api.render_destroy_texture.?(self.texture);
        if (self.sheet_asset.bits != 0) _ = self.api.asset_release.?(self.sheet_asset);
        self.* = undefined;
    }

    /// Once a frame, after the host pumped: what happened to peers, and — as a client — what
    /// arrived. Nothing here advances the world.
    pub fn frame(self: *Markers) void {
        var drained: u32 = 0;
        var event: c.FoundryNetEvent = undefined;
        while (drained < max_drain and self.api.net_event_next.?(&event) == c.FOUNDRY_OK) : (drained += 1) {
            if (event.session.bits != self.session.bits) continue;
            switch (self.role) {
                .server => self.serverEvent(event),
                .client => self.clientEvent(event),
            }
        }
        if (self.role == .client) self.receive();
    }

    /// Once per fixed step, with this view's input for it.
    pub fn step(self: *Markers, intent: Intent) void {
        switch (self.role) {
            .server => self.serverStep(intent),
            .client => self.clientStep(intent),
        }
    }

    /// A client leaves. The ending arrives as an event on a later frame.
    pub fn leave(self: *Markers) void {
        if (self.role != .client or self.phase == .ended) return;
        _ = self.api.net_peer_disconnect.?(self.peer, c.FOUNDRY_NET_DISCONNECT_CLOSED);
    }

    pub fn status(self: *const Markers) Status {
        var out: Status = .{
            .role = self.role,
            .phase = self.phase,
            .participant = self.participant,
            .departed = self.departed,
            .rejected_commands = self.rejected_commands,
            .refused_states = self.refused_states,
            .ending = self.ending,
            .sent = self.sent,
        };
        var info: c.FoundryNetSessionInfo = undefined;
        if (self.api.net_session_info.?(self.session, &info) == c.FOUNDRY_OK) {
            out.peers = info.peers;
            if (info.listening != 0) out.listen = info.listen_endpoint;
        }
        switch (self.role) {
            .server => {
                out.markers = self.objects.count;
                out.tick = self.tick;
            },
            .client => {
                out.markers = self.view.count;
                out.tick = self.view_tick;
                for (self.view.slice()) |m| {
                    if (m.owner == self.participant and self.participant != 0) out.acknowledged = m.applied;
                }
            },
        }
        return out;
    }

    /// The markers this view shows now: the server's own, or the client's last valid state.
    pub fn shown(self: *const Markers) []const Marker {
        return switch (self.role) {
            .server => self.objects.slice(),
            .client => self.view.slice(),
        };
    }

    /// The participant whose marker this view drives: 0 on the server.
    pub fn own(self: *const Markers) ?u32 {
        return switch (self.role) {
            .server => 0,
            .client => if (self.phase == .active or self.participant != 0) self.participant else null,
        };
    }

    // -- the server -------------------------------------------------------------------

    fn serverEvent(self: *Markers, event: c.FoundryNetEvent) void {
        switch (event.kind) {
            c.FOUNDRY_NET_EVENT_ADMITTED => self.say(c.FOUNDRY_LOG_INFO, "markers: participant {d} admitted", .{event.participant}),
            c.FOUNDRY_NET_EVENT_ACTIVATED => {
                self.forgetBaseline(event.peer);
                if (self.objects.count == max_markers) {
                    _ = self.api.net_peer_disconnect.?(event.peer, c.FOUNDRY_NET_DISCONNECT_CAPACITY);
                    return;
                }
                self.spawn(event.participant);
                const m = self.objects.markers[self.objects.count - 1];
                self.say(c.FOUNDRY_LOG_INFO, "markers: participant {d} active as marker #{d} at ({d:.3}, {d:.3})", .{ event.participant, m.number, m.x, m.y });
            },
            c.FOUNDRY_NET_EVENT_ENDED => {
                self.forgetBaseline(event.peer);
                var reason: [96]u8 = undefined;
                const why = endingName(event.ending, &reason);
                for (self.objects.slice(), 0..) |m, i| {
                    if (m.owner != event.participant or event.participant == 0) continue;
                    self.say(c.FOUNDRY_LOG_INFO, "markers: participant {d} left ({s}); marker #{d} last at ({d:.3}, {d:.3})", .{ event.participant, why, m.number, m.x, m.y });
                    self.remove(i);
                    self.departed += 1;
                    return;
                }
                self.say(c.FOUNDRY_LOG_INFO, "markers: a connection ended before it was active ({s})", .{why});
            },
            else => {},
        }
    }

    fn serverStep(self: *Markers, own_intent: Intent) void {
        self.tick += 1;
        var count: u32 = 0;
        if (self.api.net_batch_admit.?(self.session, self.tick, &count) == c.FOUNDRY_OK) {
            for (0..count) |i| self.apply(@intCast(i));
        }
        self.intents[0] = own_intent;

        var tick_ns: u64 = 0;
        _ = self.api.tick_delta_ns.?(&tick_ns);
        const seconds: f32 = @as(f32, @floatFromInt(tick_ns)) / 1e9;
        const arena = self.settings.arena;
        for (self.objects.markers[0..self.objects.count], self.intents[0..self.objects.count]) |*m, intent| {
            m.x = arena.clampX(m.x + @as(f32, @floatFromInt(intent.dx)) * self.settings.speed * seconds);
            m.y = arena.clampY(m.y + @as(f32, @floatFromInt(intent.dy)) * self.settings.speed * seconds);
        }

        var bytes: [max_state_bytes]u8 = undefined;
        const size = encodeState(self.objects.slice(), &bytes);
        const publish = self.tick % self.settings.state_every == 0;
        var walks: u32 = 0;
        walk: while (walks < 3) : (walks += 1) {
            var cursor: Cursor = .{ .bits = 0 };
            var peer: Peer = undefined;
            while (true) {
                const next = self.api.net_peer_next.?(self.session, &cursor, &peer);
                if (next == c.FOUNDRY_ERR_INVALID_ARGUMENT) continue :walk;
                if (next != c.FOUNDRY_OK) break :walk;
                var info: c.FoundryNetPeerInfo = undefined;
                if (self.api.net_peer_info.?(peer, &info) != c.FOUNDRY_OK) continue;
                switch (info.state) {
                    c.FOUNDRY_NET_PEER_SYNCHRONIZING => if (!self.baselineSent(peer)) {
                        if (self.api.net_baseline_send.?(peer, self.tick, &bytes, size) == c.FOUNDRY_OK) {
                            self.noteBaseline(peer);
                        }
                    },
                    c.FOUNDRY_NET_PEER_ACTIVE => if (publish) {
                        _ = self.api.net_state_publish.?(peer, self.tick, &bytes, size);
                    },
                    else => {},
                }
            }
        }
    }

    /// One admitted command. Its owner is the participant the batch names — never anything
    /// in the payload — so a client can move only its own marker, and only by asking.
    fn apply(self: *Markers, index: u32) void {
        var command: c.FoundryNetCommand = undefined;
        if (self.api.net_batch_command.?(self.session, index, &command) != c.FOUNDRY_OK) return;
        var payload: [command_bytes]u8 = undefined;
        var needed: u64 = 0;
        const copied = self.api.net_batch_copy.?(self.session, index, &payload, payload.len, &needed);
        const intent = if (copied == c.FOUNDRY_OK) decodeCommand(payload[0..@intCast(needed)]) else null;
        const slot = for (self.objects.slice(), 0..) |m, i| {
            if (m.owner == command.participant and command.participant != 0) break i;
        } else null;
        if (intent == null or slot == null) {
            self.rejected_commands += 1;
            return;
        }
        self.intents[slot.?] = intent.?;
        self.objects.markers[slot.?].applied = command.number;
    }

    fn spawn(self: *Markers, participant: u32) void {
        const arena = self.settings.arena;
        // 0, +1, -1, +2, -2 spacings from the centre, by participant, so a handful of
        // markers start apart and a reconnect starts somewhere predictable.
        const slot: i32 = @intCast(participant % 5);
        const offset: f32 = @floatFromInt(if (@mod(slot, 2) == 1) @divTrunc(slot + 1, 2) else -@divTrunc(slot, 2));
        const i = self.objects.count;
        self.objects.markers[i] = .{
            .number = self.next_number,
            .owner = participant,
            .x = arena.clampX(arena.x + arena.w / 2 + offset * self.settings.spacing),
            .y = arena.clampY(arena.y + arena.h / 2),
        };
        self.intents[i] = .{};
        self.objects.count += 1;
        self.next_number += 1;
    }

    fn remove(self: *Markers, index: usize) void {
        const last = self.objects.count - 1;
        // Order-preserving, so every view lists markers the same way.
        var i = index;
        while (i < last) : (i += 1) {
            self.objects.markers[i] = self.objects.markers[i + 1];
            self.intents[i] = self.intents[i + 1];
        }
        self.objects.count = last;
    }

    fn baselineSent(self: *const Markers, peer: Peer) bool {
        for (self.baselined) |bits| if (bits == peer.bits) return true;
        return false;
    }

    fn noteBaseline(self: *Markers, peer: Peer) void {
        for (&self.baselined) |*bits| if (bits.* == 0) {
            bits.* = peer.bits;
            return;
        };
    }

    fn forgetBaseline(self: *Markers, peer: Peer) void {
        for (&self.baselined) |*bits| if (bits.* == peer.bits) {
            bits.* = 0;
        };
    }

    // -- the client -------------------------------------------------------------------

    fn clientEvent(self: *Markers, event: c.FoundryNetEvent) void {
        if (event.peer.bits != self.peer.bits) return;
        switch (event.kind) {
            c.FOUNDRY_NET_EVENT_ADMITTED => {
                self.participant = event.participant;
                self.phase = .synchronizing;
                self.say(c.FOUNDRY_LOG_INFO, "markers: admitted as participant {d}", .{event.participant});
            },
            c.FOUNDRY_NET_EVENT_ACTIVATED => {
                self.phase = .active;
                self.say(c.FOUNDRY_LOG_INFO, "markers: active as participant {d}", .{self.participant});
            },
            c.FOUNDRY_NET_EVENT_ENDED => {
                self.phase = .ended;
                self.ending = event.ending;
                var reason: [96]u8 = undefined;
                self.say(c.FOUNDRY_LOG_INFO, "markers: connection ended ({s})", .{endingName(event.ending, &reason)});
            },
            else => {},
        }
    }

    fn receive(self: *Markers) void {
        if (self.phase == .ended or self.phase == .connecting) return;
        var taken: u32 = 0;
        while (taken < max_drain) : (taken += 1) {
            var delivery: c.FoundryNetDelivery = undefined;
            var bytes: [max_state_bytes]u8 = undefined;
            var needed: u64 = 0;
            const result = self.api.net_delivery_take.?(self.peer, &bytes, bytes.len, &needed, &delivery);
            if (result == c.FOUNDRY_END) return;
            if (result != c.FOUNDRY_OK) {
                // Too large to be a state of this protocol, or the connection is gone.
                if (result == c.FOUNDRY_ERR_LIMIT) self.refuse("a delivery larger than any state");
                return;
            }
            const payload = bytes[0..@intCast(needed)];
            switch (delivery.kind) {
                c.FOUNDRY_NET_DELIVERY_BASELINE => {
                    if (!self.accept(payload, delivery.tick)) return;
                    var listing: [max_markers * 40]u8 = undefined;
                    self.say(c.FOUNDRY_LOG_INFO, "markers: baseline tick {d}: {d} marker(s){s}", .{ delivery.tick, self.view.count, describe(self.view.slice(), &listing) });
                    _ = self.api.net_baseline_acknowledge.?(self.peer, delivery.sequence, delivery.tick);
                },
                c.FOUNDRY_NET_DELIVERY_STATE => {
                    if (delivery.tick <= self.view_tick) continue;
                    const before = self.view.count;
                    if (!self.accept(payload, delivery.tick)) return;
                    if (self.view.count != before) {
                        var listing: [max_markers * 40]u8 = undefined;
                        self.say(c.FOUNDRY_LOG_INFO, "markers: state tick {d}: {d} marker(s){s}", .{ delivery.tick, self.view.count, describe(self.view.slice(), &listing) });
                    }
                },
                // This protocol sends clients no messages; one is ignored, not believed.
                else => {},
            }
        }
    }

    /// Validates a complete state into a candidate and only then replaces the view.
    fn accept(self: *Markers, payload: []const u8, tick: u64) bool {
        var candidate: Snapshot = .{};
        decodeState(payload, self.settings.arena, &self.view, self.highest, &candidate) catch |err| {
            self.refuse(@errorName(err));
            return false;
        };
        self.view = candidate;
        self.view_tick = tick;
        for (candidate.slice()) |m| self.highest = @max(self.highest, m.number);
        var now: u64 = 0;
        _ = self.api.elapsed_ns.?(&now);
        self.view_at_ns = now;
        self.have_view = true;
        return true;
    }

    fn refuse(self: *Markers, why: []const u8) void {
        self.refused_states += 1;
        self.say(c.FOUNDRY_LOG_WARN, "markers: refused a state ({s}); keeping the last complete view", .{why});
        _ = self.api.net_peer_disconnect.?(self.peer, c.FOUNDRY_NET_DISCONNECT_PROTOCOL);
    }

    fn clientStep(self: *Markers, intent: Intent) void {
        if (self.phase != .active or intent.eql(self.sent_intent) or !intent.valid()) return;
        const bytes = encodeCommand(intent);
        var number: u64 = 0;
        // A full queue keeps the intent unsent, and the next step tries again.
        if (self.api.net_command_send.?(self.peer, id(move_channel_name), &bytes, bytes.len, &number) != c.FOUNDRY_OK) return;
        self.sent = number;
        self.sent_intent = intent;
    }

    // -- presentation -----------------------------------------------------------------

    /// Draws every shown marker into the world view, and this view's status into a panel
    /// at the bottom right of `viewport` (screen points). The host has begun the renderer
    /// and lent a UI context; it walks the panel's draw list after this returns.
    pub fn draw(self: *const Markers, viewport: c.FoundryUiRect) void {
        const s = &self.settings;
        const mine = self.own();
        if (self.texture.bits != 0) {
            const w = 1.0 / @as(f32, @floatFromInt(s.columns));
            const h = 1.0 / @as(f32, @floatFromInt(s.rows));
            const uv: c.FoundryRenderRect = .{
                .x = @as(f32, @floatFromInt(s.cell % s.columns)) * w,
                .y = @as(f32, @floatFromInt(s.cell / s.columns)) * h,
                .w = w,
                .h = h,
            };
            for (self.shown()) |m| {
                const tint = s.tints[m.owner % s.tint_count];
                var sprite = std.mem.zeroes(c.FoundryRenderSprite);
                sprite.texture = self.texture;
                sprite.uv = uv;
                sprite.origin = .{ .x = 0.5, .y = 0.5 };
                sprite.position = .{ .x = m.x, .y = m.y };
                // Every marker stands on a frame, so it reads above a busy field: black for
                // everyone else's, white for this view's own.
                const frame_tint: f32 = if (mine != null and mine.? == m.owner) 1 else 0;
                sprite.size = .{ .x = s.size + 6, .y = s.size + 6 };
                sprite.tint = .{ .r = frame_tint, .g = frame_tint, .b = frame_tint, .a = 1 };
                sprite.layer = 30;
                _ = self.api.render_draw_sprite.?(&sprite);
                sprite.layer = 31;
                sprite.size = .{ .x = s.size, .y = s.size };
                sprite.tint = .{ .r = tint[0], .g = tint[1], .b = tint[2], .a = 1 };
                _ = self.api.render_draw_sprite.?(&sprite);
            }
        }

        if (self.api.ui_begin.?(&viewport) != c.FOUNDRY_OK) return;
        // Bottom right, clear of the overlay's tabs, and wide enough for its longest line.
        const width = @min(580, viewport.w - 20);
        const height = @min(128, viewport.h - 20);
        const panel: c.FoundryUiRect = .{ .x = viewport.x + viewport.w - width - 10, .y = viewport.y + viewport.h - height - 10, .w = width, .h = height };
        if (self.api.ui_begin_panel.?(uiId("markers"), &panel) == c.FOUNDRY_OK) {
            self.lines();
            _ = self.api.ui_end_panel.?();
        }
        _ = self.api.ui_end.?();
    }

    fn lines(self: *const Markers) void {
        const s = &self.settings;
        const now = self.status();
        var buffer: [128]u8 = undefined;
        self.label(s.title.text());

        const role_line = switch (now.phase) {
            .serving => if (now.listen) |at|
                std.fmt.bufPrint(&buffer, "{s} {d}.{d}.{d}.{d}:{d} - {d} peer(s)", .{ s.server.text(), at.address[0], at.address[1], at.address[2], at.address[3], at.port, now.peers }) catch ""
            else
                s.server.text(),
            .connecting, .synchronizing => s.waiting.text(),
            .active => std.fmt.bufPrint(&buffer, "{s} - participant {d}", .{ s.client.text(), now.participant }) catch "",
            .ended => blk: {
                var reason: [96]u8 = undefined;
                const why = if (now.ending) |e| endingName(e, &reason) else "";
                break :blk std.fmt.bufPrint(&buffer, "{s}: {s}", .{ s.ended.text(), why }) catch "";
            },
        };
        self.label(role_line);

        var mine_buffer: [128]u8 = undefined;
        const own_marker = if (self.own()) |owner| for (self.shown()) |m| {
            if (m.owner == owner) break m;
        } else null else null;
        if (own_marker) |m| {
            const line = std.fmt.bufPrint(&mine_buffer, "{s} ({d:.0}, {d:.0}){s}{s}", .{
                s.you.text(),
                m.x,
                m.y,
                if (now.pending()) " - " else "",
                if (now.pending()) s.pending.text() else "",
            }) catch "";
            self.label(line);
        }

        var count_buffer: [128]u8 = undefined;
        const count_line = std.fmt.bufPrint(&count_buffer, "{d} marker(s) - tick {d}{s}{s}", .{
            now.markers,
            now.tick,
            if (self.stale()) " - " else "",
            if (self.stale()) s.stale.text() else "",
        }) catch "";
        self.label(count_line);
    }

    /// A client whose last state is older than the content says it may be.
    pub fn stale(self: *const Markers) bool {
        if (self.role != .client or self.phase == .ended) return false;
        if (!self.have_view) return self.phase == .active;
        var now: u64 = 0;
        if (self.api.elapsed_ns.?(&now) != c.FOUNDRY_OK) return false;
        return now -| self.view_at_ns > @as(u64, self.settings.stale_ms) * std.time.ns_per_ms;
    }

    fn label(self: *const Markers, text: []const u8) void {
        if (text.len == 0) return;
        _ = self.api.ui_label.?(str(text));
    }

    fn say(self: *const Markers, level: c.FoundryLogLevel, comptime format: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, args) catch return;
        // This view is not a mod and holds no identity; the log names it by its prefix.
        _ = self.api.log_write.?(.{ .bits = 0 }, level, str(text));
    }
};

// -- helpers ------------------------------------------------------------------------------

fn id(name: []const u8) ContentId {
    return c.foundry_content_id(name.ptr, name.len);
}

fn str(text: []const u8) c.FoundryStr {
    return .{ .ptr = text.ptr, .len = text.len };
}

fn uiId(name: []const u8) c.FoundryUiId {
    return .{ .bits = c.foundry_content_id(name.ptr, name.len).hash };
}

/// " #1 p0 (0.000, 0.000) #2 p1 (40.000, 0.000)", for a log a proof can compare.
fn describe(markers: []const Marker, out: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(out);
    for (markers) |m| writer.print(" #{d} p{d} ({d:.3}, {d:.3})", .{ m.number, m.owner, m.x, m.y }) catch break;
    return writer.buffered();
}

/// A category a person or a log can read, never a secret: the ending kind, and for a
/// refusal the category and the first differing entry.
fn endingName(ending: c.FoundryNetEnding, out: []u8) []const u8 {
    const kind = switch (ending.kind) {
        c.FOUNDRY_NET_ENDING_LOCAL => "closed here",
        c.FOUNDRY_NET_ENDING_PEER_DISCONNECTED => "the other side disconnected",
        c.FOUNDRY_NET_ENDING_PEER_CLOSED => "the other side closed",
        c.FOUNDRY_NET_ENDING_REFUSED => "refused",
        c.FOUNDRY_NET_ENDING_REFUSED_BY_PEER => "refused by the server",
        c.FOUNDRY_NET_ENDING_REVOKED => "revoked",
        c.FOUNDRY_NET_ENDING_ROTATED => "credentials rotated",
        c.FOUNDRY_NET_ENDING_TIMED_OUT => "timed out",
        c.FOUNDRY_NET_ENDING_PROTOCOL => "protocol fault",
        c.FOUNDRY_NET_ENDING_TRANSPORT => "transport failure",
        c.FOUNDRY_NET_ENDING_OVERLOADED => "overloaded",
        else => "ended",
    };
    const refusal = ending.kind == c.FOUNDRY_NET_ENDING_REFUSED or ending.kind == c.FOUNDRY_NET_ENDING_REFUSED_BY_PEER;
    if (!refusal) {
        // Authentication is visible here: a transport ending names its category.
        if (ending.kind == c.FOUNDRY_NET_ENDING_TRANSPORT) {
            return std.fmt.bufPrint(out, "{s}: {s}", .{ kind, failureName(ending.code) }) catch kind;
        }
        return kind;
    }
    const category = switch (ending.code) {
        c.FOUNDRY_NET_REFUSAL_VERSION => "version",
        c.FOUNDRY_NET_REFUSAL_APPLICATION => "application",
        c.FOUNDRY_NET_REFUSAL_COMPATIBILITY => "compatibility",
        c.FOUNDRY_NET_REFUSAL_CATALOGUE => "catalogue",
        c.FOUNDRY_NET_REFUSAL_CHANNEL => "channel",
        c.FOUNDRY_NET_REFUSAL_CAPACITY => "capacity",
        c.FOUNDRY_NET_REFUSAL_POLICY => "policy",
        c.FOUNDRY_NET_REFUSAL_TIMEOUT => "timeout",
        else => "generic",
    };
    if (ending.index == c.FOUNDRY_NET_NO_INDEX) return std.fmt.bufPrint(out, "{s}: {s}", .{ kind, category }) catch kind;
    return std.fmt.bufPrint(out, "{s}: {s}, entry {d}", .{ kind, category, ending.index }) catch kind;
}

fn failureName(code: i32) []const u8 {
    return switch (code) {
        c.FOUNDRY_NET_FAILURE_REFUSED => "connection refused",
        c.FOUNDRY_NET_FAILURE_UNREACHABLE_ADDRESS => "unreachable",
        c.FOUNDRY_NET_FAILURE_TIMED_OUT => "timed out",
        c.FOUNDRY_NET_FAILURE_RESET => "reset",
        c.FOUNDRY_NET_FAILURE_CLOSED_EARLY => "closed during the handshake",
        c.FOUNDRY_NET_FAILURE_TRUNCATED => "truncated",
        c.FOUNDRY_NET_FAILURE_NETWORK_DOWN => "network down",
        c.FOUNDRY_NET_FAILURE_CARRIER => "carrier",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_MISSING => "no certificate",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_UNTRUSTED => "certificate untrusted",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_EXPIRED => "certificate expired",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_NOT_YET_VALID => "certificate not yet valid",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_WRONG_USAGE => "certificate for the wrong role",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_WRONG_NAME => "certificate for another server",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_REJECTED => "certificate rejected",
        c.FOUNDRY_NET_FAILURE_CERTIFICATE_CHAIN_TOO_LONG => "certificate chain too long",
        c.FOUNDRY_NET_FAILURE_SERVER_KEY_MISMATCH => "not the server this client was given",
        c.FOUNDRY_NET_FAILURE_PEER_REFUSED => "the other side refused this certificate",
        c.FOUNDRY_NET_FAILURE_PROTOCOL => "TLS protocol fault",
        c.FOUNDRY_NET_FAILURE_HANDSHAKE_BUDGET => "handshake too long",
        c.FOUNDRY_NET_FAILURE_TLS_MEMORY => "no TLS memory",
        c.FOUNDRY_NET_FAILURE_CLOCK_UNAVAILABLE => "no trustworthy clock",
        else => "internal",
    };
}

// -- tests --------------------------------------------------------------------------------

const testing = std.testing;

test "a command is four bytes, and only a direction decodes" {
    const bytes = encodeCommand(.{ .dx = -1, .dy = 1 });
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x01, 0, 0 }, &bytes);
    try testing.expect(decodeCommand(&bytes).?.eql(.{ .dx = -1, .dy = 1 }));
    try testing.expectEqual(@as(?Intent, null), decodeCommand(&.{ 2, 0, 0, 0 }));
    try testing.expectEqual(@as(?Intent, null), decodeCommand(&.{ 0, 0, 1, 0 }));
    try testing.expectEqual(@as(?Intent, null), decodeCommand(&.{ 0, 0, 0 }));
    try testing.expectEqual(@as(?Intent, null), decodeCommand(&.{ 0, 0, 0, 0, 0 }));
}

test "a state round-trips, and every malformed one is refused whole" {
    const arena: Arena = .{};
    const markers = [_]Marker{
        .{ .number = 1, .owner = 0, .x = 0, .y = 0 },
        .{ .number = 2, .owner = 1, .x = 40, .y = -10, .applied = 3 },
    };
    var bytes: [max_state_bytes]u8 = undefined;
    const size = encodeState(&markers, &bytes);
    try testing.expectEqual(state_header_bytes + 2 * marker_bytes, size);

    const empty: Snapshot = .{};
    var out: Snapshot = .{};
    try decodeState(bytes[0..size], arena, &empty, 0, &out);
    try testing.expectEqual(@as(u32, 2), out.count);
    try testing.expectEqual(@as(f32, 40), out.markers[1].x);
    try testing.expectEqual(@as(u64, 3), out.markers[1].applied);

    const kept = out;
    try testing.expectError(error.Truncated, decodeState(bytes[0 .. size - 1], arena, &empty, 0, &out));
    try testing.expectError(error.Truncated, decodeState(bytes[0..4], arena, &empty, 0, &out));

    var bad = bytes;
    bad[4] = 1;
    try testing.expectError(error.Reserved, decodeState(bad[0..size], arena, &empty, 0, &out));

    bad = bytes;
    std.mem.writeInt(u32, bad[0..4], max_markers + 1, .little);
    try testing.expectError(error.TooMany, decodeState(bad[0..size], arena, &empty, 0, &out));

    bad = bytes;
    std.mem.writeInt(u32, bad[state_header_bytes + marker_bytes ..][0..4], 1, .little);
    try testing.expectError(error.DuplicateNumber, decodeState(bad[0..size], arena, &empty, 0, &out));

    bad = bytes;
    std.mem.writeInt(u32, bad[state_header_bytes + marker_bytes + 4 ..][0..4], 0, .little);
    try testing.expectError(error.DuplicateOwner, decodeState(bad[0..size], arena, &empty, 0, &out));

    bad = bytes;
    std.mem.writeInt(u32, bad[state_header_bytes + 8 ..][0..4], @bitCast(std.math.nan(f32)), .little);
    try testing.expectError(error.NotFinite, decodeState(bad[0..size], arena, &empty, 0, &out));

    bad = bytes;
    std.mem.writeInt(u32, bad[state_header_bytes + 8 ..][0..4], @bitCast(@as(f32, 1000)), .little);
    try testing.expectError(error.OutsideArena, decodeState(bad[0..size], arena, &empty, 0, &out));

    bad = bytes;
    std.mem.writeInt(u32, bad[state_header_bytes..][0..4], 0, .little);
    try testing.expectError(error.ZeroNumber, decodeState(bad[0..size], arena, &empty, 0, &out));

    // Every refusal above left the candidate's destination as the last success wrote it.
    try testing.expectEqualDeep(kept, out);
}

test "a removed marker cannot come back, and a new one can appear" {
    const arena: Arena = .{};
    var bytes: [max_state_bytes]u8 = undefined;
    var view: Snapshot = .{};
    var next: Snapshot = .{};

    // The view held #1 and #2; #2 was removed, so the view holds #1 and has seen up to 2.
    const first = [_]Marker{.{ .number = 1, .owner = 0, .x = 0, .y = 0 }};
    try decodeState(bytes[0..encodeState(&first, &bytes)], arena, &view, 0, &view);
    const back = [_]Marker{ .{ .number = 1, .owner = 0, .x = 0, .y = 0 }, .{ .number = 2, .owner = 1, .x = 0, .y = 0 } };
    try testing.expectError(error.Resurrected, decodeState(bytes[0..encodeState(&back, &bytes)], arena, &view, 2, &next));

    const fresh = [_]Marker{ .{ .number = 1, .owner = 0, .x = 0, .y = 0 }, .{ .number = 3, .owner = 1, .x = 0, .y = 0 } };
    try decodeState(bytes[0..encodeState(&fresh, &bytes)], arena, &view, 2, &next);
    try testing.expectEqual(@as(u32, 2), next.count);
}

test "an ending reads as a category, never a secret" {
    var out: [96]u8 = undefined;
    try testing.expectEqualStrings("refused by the server: catalogue, entry 2", endingName(.{
        .kind = c.FOUNDRY_NET_ENDING_REFUSED_BY_PEER,
        .code = c.FOUNDRY_NET_REFUSAL_CATALOGUE,
        .index = 2,
    }, &out));
    try testing.expectEqualStrings("timed out", endingName(.{ .kind = c.FOUNDRY_NET_ENDING_TIMED_OUT, .index = c.FOUNDRY_NET_NO_INDEX }, &out));
    try testing.expectEqualStrings("transport failure: not the server this client was given", endingName(.{
        .kind = c.FOUNDRY_NET_ENDING_TRANSPORT,
        .code = c.FOUNDRY_NET_FAILURE_SERVER_KEY_MISMATCH,
        .index = c.FOUNDRY_NET_NO_INDEX,
    }, &out));
}
