//! Ogg, the container a Vorbis file is (RFC 3533; ADR-0065).
//!
//! Beside `wav.zig`, and for its reasons: **a sound is a stranger's file**, so the untrusted
//! path is Zig. Ogg is a sequence of pages, each carrying a run of packet segments, and this
//! file turns pages back into packets for the codec above it (`vorbis.zig`, from M30 Step 2).
//!
//! **What it accepts is stated, and everything else is refused by name** (`music.md` §3.2):
//! - one logical stream. A second serial number, multiplexed or chained, is
//!   `UnsupportedSound`: a game's track is one stream, and a chained file is a broken export
//!   far more often than it is a playlist;
//! - every page's CRC checked. A damaged page refuses the file rather than being skipped,
//!   because a file in a package is not a broadcast;
//! - pages in sequence, the continuation flag agreeing with the packet it continues, the first
//!   page beginning the stream and the last one ending it, and nothing after it;
//! - granule positions that never go backwards, so the final one is the stream's length.
//!
//! `scan` reads the whole file once and allocates nothing, so a decoder learns the length and
//! the codec before it allocates from either (`audio.md` §6's rule for WAV). `Packets` then
//! walks the packets, borrowing each from the file unless it spans pages.
//!
//! Design: `docs/design/music.md` §3.2.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.asset);

pub const Error = error{
    /// Not Ogg, or Ogg that violates the format: a bad capture pattern or CRC, truncation, a
    /// missing page, a continuation that continues nothing, a stream that never ends.
    InvalidSound,
    /// Valid Ogg this reader does not handle: a second logical stream, or a codec that is
    /// not Vorbis. The file is fine and the answer for the author is different: re-export.
    UnsupportedSound,
};

/// The fixed part of a page header, before its lacing values.
pub const header_size = 27;

/// The largest page the format can describe: the header, 255 lacing values of 255 each.
pub const max_page_size = header_size + 255 + 255 * 255;

pub const Flags = packed struct(u8) {
    /// The page's first segment continues a packet from the page before.
    continued: bool,
    /// The first page of a logical stream.
    first: bool,
    /// The last page of a logical stream.
    last: bool,
    /// No meaning in version 0, so a page that sets one is refused.
    reserved: u5,
};

pub const Page = struct {
    flags: Flags,
    /// The stream position after the last packet that completes on this page, or
    /// `no_granule` when none does.
    granule: u64,
    serial: u32,
    sequence: u32,
    lacing: []const u8,
    body: []const u8,
    /// The whole page, header included.
    size: usize,

    pub const no_granule = std.math.maxInt(u64);

    /// Whether any packet completes on this page: a lacing value below 255 ends one.
    pub fn completesPacket(self: Page) bool {
        for (self.lacing) |v| if (v < 255) return true;
        return false;
    }
};

/// The CRC Ogg uses: polynomial `0x04c11db7`, initial value 0, unreflected, no final XOR,
/// computed over the page with its own CRC field taken as zero (RFC 3533 §6).
pub fn crc32(bytes: []const u8) u32 {
    return crcUpdate(0, bytes);
}

fn crcUpdate(start: u32, bytes: []const u8) u32 {
    var c = start;
    for (bytes) |b| c = (c << 8) ^ crc_table[(c >> 24) ^ b];
    return c;
}

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @as(u32, i) << 24;
        for (0..8) |_| c = if (c & 0x8000_0000 != 0) (c << 1) ^ 0x04c1_1db7 else c << 1;
        e.* = c;
    }
    break :blk t;
};

/// One page at the start of `bytes`, checked: capture pattern, version, flags, length and CRC.
pub fn parsePage(bytes: []const u8) Error!Page {
    if (bytes.len < header_size) {
        log.warn("ogg: a page header is cut short ({d} bytes of {d})", .{ bytes.len, header_size });
        return error.InvalidSound;
    }
    if (!std.mem.eql(u8, bytes[0..4], "OggS")) {
        log.warn("ogg: no page begins here (the capture pattern is not 'OggS')", .{});
        return error.InvalidSound;
    }
    if (bytes[4] != 0) {
        log.warn("ogg: page version {d}; only version 0 exists", .{bytes[4]});
        return error.InvalidSound;
    }
    const flags: Flags = @bitCast(bytes[5]);
    if (flags.reserved != 0) {
        log.warn("ogg: a page sets header flags 0x{x:0>2} that have no meaning", .{bytes[5]});
        return error.InvalidSound;
    }
    const segments: usize = bytes[26];
    if (bytes.len < header_size + segments) {
        log.warn("ogg: a page's lacing values are cut short", .{});
        return error.InvalidSound;
    }
    const lacing = bytes[header_size..][0..segments];
    var body_len: usize = 0;
    for (lacing) |v| body_len += v;
    const size = header_size + segments + body_len;
    if (bytes.len < size) {
        log.warn("ogg: a page's body is cut short ({d} bytes of {d})", .{ bytes.len - header_size - segments, body_len });
        return error.InvalidSound;
    }
    const stored = std.mem.readInt(u32, bytes[22..26], .little);
    var c = crcUpdate(0, bytes[0..22]);
    c = crcUpdate(c, &.{ 0, 0, 0, 0 });
    c = crcUpdate(c, bytes[26..size]);
    if (c != stored) {
        log.warn("ogg: page {d}'s CRC is 0x{x:0>8}, and its contents give 0x{x:0>8}", .{ std.mem.readInt(u32, bytes[18..22], .little), stored, c });
        return error.InvalidSound;
    }
    return .{
        .flags = flags,
        .granule = std.mem.readInt(u64, bytes[6..14], .little),
        .serial = std.mem.readInt(u32, bytes[14..18], .little),
        .sequence = std.mem.readInt(u32, bytes[18..22], .little),
        .lacing = lacing,
        .body = bytes[header_size + segments .. size],
        .size = size,
    };
}

/// What the stream's first packet says it is. Named so a refusal can say what a file *is*
/// rather than only that it is not Vorbis (`music.md` §3.4).
pub const Codec = enum {
    vorbis,
    opus,
    flac,
    speex,
    theora,
    unknown,

    pub fn name(self: Codec) []const u8 {
        return switch (self) {
            .vorbis => "Vorbis",
            .opus => "Opus",
            .flac => "FLAC",
            .speex => "Speex",
            .theora => "Theora",
            .unknown => "an unrecognised codec",
        };
    }
};

pub fn identify(first_packet: []const u8) Codec {
    const signatures = [_]struct { []const u8, Codec }{
        .{ "\x01vorbis", .vorbis },
        .{ "OpusHead", .opus },
        .{ "\x7fFLAC", .flac },
        .{ "Speex   ", .speex },
        .{ "\x80theora", .theora },
    };
    for (signatures) |s| if (std.mem.startsWith(u8, first_packet, s[0])) return s[1];
    return .unknown;
}

pub const Info = struct {
    serial: u32,
    pages: u32,
    codec: Codec,
    /// The last page's granule position: for Vorbis, the stream's length in frames.
    granule: u64,
};

/// Reads every page once, checking each and the stream they make, and allocates nothing.
/// A codec checks `Info.codec` and the length before it allocates from either.
pub fn scan(bytes: []const u8) Error!Info {
    var walk: Walk = .{};
    var pos: usize = 0;
    var codec: Codec = .unknown;
    while (true) {
        const page = try walk.next(bytes, &pos) orelse break;
        if (walk.pages == 1) {
            // The first packet must end on the first page, as every Ogg mapping requires.
            if (page.lacing.len == 0 or !page.completesPacket()) {
                log.warn("ogg: the stream's first packet does not end on its first page", .{});
                return error.InvalidSound;
            }
            var len: usize = 0;
            for (page.lacing) |v| {
                len += v;
                if (v < 255) break;
            }
            codec = identify(page.body[0..len]);
        }
    }
    return .{ .serial = walk.serial, .pages = walk.pages, .codec = codec, .granule = walk.granule };
}

/// The checks that hold between pages, shared by `scan` and `Packets` so the two can never
/// disagree about what a valid stream is.
const Walk = struct {
    serial: u32 = 0,
    pages: u32 = 0,
    granule: u64 = 0,
    /// A packet is open across the page boundary.
    open: bool = false,
    ended: bool = false,

    /// The next page at `pos.*`, or null at a valid end of the stream.
    fn next(self: *Walk, bytes: []const u8, pos: *usize) Error!?Page {
        if (pos.* == bytes.len) {
            if (self.ended) return null;
            log.warn("ogg: the stream stops after page {d} without its last page", .{self.pages});
            return error.InvalidSound;
        }
        if (self.ended) {
            // A second stream after the first is a chained file; anything else is debris.
            if (parsePage(bytes[pos.*..])) |page| {
                if (page.flags.first) {
                    log.warn("ogg: a second logical stream follows the first (a chained file); one stream per sound", .{});
                    return error.UnsupportedSound;
                }
            } else |_| {}
            log.warn("ogg: {d} bytes follow the stream's last page", .{bytes.len - pos.*});
            return error.InvalidSound;
        }
        const page = try parsePage(bytes[pos.*..]);
        if (self.pages == 0) {
            if (!page.flags.first or page.flags.continued) {
                log.warn("ogg: the first page does not begin a stream", .{});
                return error.InvalidSound;
            }
            self.serial = page.serial;
        } else {
            if (page.serial != self.serial) {
                log.warn("ogg: pages of a second logical stream ({x:0>8} beside {x:0>8}); one stream per sound", .{ page.serial, self.serial });
                return error.UnsupportedSound;
            }
            if (page.flags.first) {
                log.warn("ogg: page {d} begins the stream again", .{page.sequence});
                return error.InvalidSound;
            }
        }
        if (page.sequence != self.pages) {
            log.warn("ogg: page {d} follows page {d}; a page is missing or out of order", .{ page.sequence, self.pages -% 1 });
            return error.InvalidSound;
        }
        if (page.flags.continued != self.open) {
            if (self.open) {
                log.warn("ogg: page {d} does not continue the packet the page before left open", .{page.sequence});
            } else {
                log.warn("ogg: page {d} claims to continue a packet, and none is open", .{page.sequence});
            }
            return error.InvalidSound;
        }
        if (page.granule != Page.no_granule) {
            if (page.granule < self.granule) {
                log.warn("ogg: page {d}'s granule {d} is before the previous page's {d}", .{ page.sequence, page.granule, self.granule });
                return error.InvalidSound;
            }
            self.granule = page.granule;
        }
        if (page.lacing.len > 0) self.open = page.lacing[page.lacing.len - 1] == 255;
        if (page.flags.last) {
            if (self.open) {
                log.warn("ogg: the last page leaves a packet unfinished", .{});
                return error.InvalidSound;
            }
            if (page.granule == Page.no_granule) {
                log.warn("ogg: the last page has no granule position, so the stream has no length", .{});
                return error.InvalidSound;
            }
            self.ended = true;
        }
        self.pages += 1;
        pos.* += page.size;
        return page;
    }
};

pub const Packet = struct {
    /// Borrowed from the file when the packet lies within one page, otherwise from the
    /// reader's own buffer. Valid until the next call to `next`.
    data: []const u8,
    /// The page's granule when this is the last packet that completes on its page; that is
    /// the only packet the format gives a position for.
    granule: ?u64,
    /// The stream's final packet.
    last: bool,
};

/// The packets of one checked stream, in order.
pub const Packets = struct {
    bytes: []const u8,
    pos: usize = 0,
    walk: Walk = .{},
    page: ?Page = null,
    segment: usize = 0,
    offset: usize = 0,
    /// The index of the page's last lacing value below 255, the packet its granule belongs to.
    last_end: ?usize = null,
    /// A packet spanning pages, gathered here. Owned; `deinit` frees it.
    spanning: std.ArrayList(u8) = .empty,
    /// `spanning` holds the start of a packet a later page finishes.
    span_open: bool = false,

    pub fn init(bytes: []const u8) Packets {
        return .{ .bytes = bytes };
    }

    pub fn deinit(self: *Packets, gpa: Allocator) void {
        self.spanning.deinit(gpa);
        self.* = undefined;
    }

    /// Starts reading again at the page beginning at byte `offset`, which must be page number
    /// `sequence` of stream `serial` and must not continue a packet: a seek's checkpoint
    /// (`mixing.md` §6.1). Keeps the spanning buffer's capacity, so a reserved reader still
    /// never allocates. A wrong offset or number is refused by the walk, as any damaged page is.
    pub fn resumeAt(self: *Packets, offset: usize, serial: u32, sequence: u32) void {
        var spanning = self.spanning;
        spanning.clearRetainingCapacity();
        self.* = .init(self.bytes);
        self.spanning = spanning;
        self.pos = @min(offset, self.bytes.len);
        self.walk.serial = serial;
        self.walk.pages = sequence;
    }

    /// Whether the next packet begins a page: none is open, and the page read last is used
    /// up. A seek can start only there.
    pub fn atPageStart(self: *const Packets) bool {
        if (self.span_open) return false;
        const page = self.page orelse return true;
        return self.segment == page.lacing.len;
    }

    /// The next packet, or null after the last. Allocates only for a packet that spans pages,
    /// and then never more than the file's own size.
    pub fn next(self: *Packets, gpa: Allocator) (Error || Allocator.Error)!?Packet {
        if (!self.span_open) self.spanning.clearRetainingCapacity();
        while (true) {
            if (self.page) |page| {
                const start = self.offset;
                while (self.segment < page.lacing.len) {
                    const v = page.lacing[self.segment];
                    self.segment += 1;
                    self.offset += v;
                    if (v < 255) {
                        const ends_here = self.segment - 1 == self.last_end.?;
                        const piece = page.body[start..self.offset];
                        const data = if (self.span_open) blk: {
                            try self.spanning.appendSlice(gpa, piece);
                            self.span_open = false;
                            break :blk self.spanning.items;
                        } else piece;
                        return .{
                            .data = data,
                            // A page's granule of -1 says no packet ends on it. One that
                            // ends a packet anyway gives that packet no position, as
                            // libvorbis reads it, rather than a position at the end of time.
                            .granule = if (ends_here and page.granule != Page.no_granule) page.granule else null,
                            .last = ends_here and page.flags.last,
                        };
                    }
                }
                // The page ended inside a packet: keep what it carried and read on.
                if (self.offset > start) {
                    try self.spanning.appendSlice(gpa, page.body[start..self.offset]);
                    self.span_open = true;
                }
            }
            const page = try self.walk.next(self.bytes, &self.pos) orelse return null;
            self.page = page;
            self.segment = 0;
            self.offset = 0;
            self.last_end = null;
            for (page.lacing, 0..) |v, i| if (v < 255) {
                self.last_end = i;
            };
        }
    }
};

// -- tests ----------------------------------------------------------------------------------

const testing = std.testing;

pub const Fixture = struct { name: []const u8, ogg: []const u8, reference: []const u8 };

fn fixture(comptime name: []const u8) Fixture {
    return .{
        .name = name,
        .ogg = @embedFile("testdata/vorbis/" ++ name ++ ".ogg"),
        .reference = @embedFile("testdata/vorbis/" ++ name ++ ".ref.wav"),
    };
}

/// The reference fixtures (`music.md` §3.5), for this file's tests and the decoder's.
pub const fixtures = [_]Fixture{
    fixture("mono44_q0"),
    fixture("mono44_q10"),
    fixture("stereo48_q4"),
    fixture("stereo22_qm1"),
    fixture("short"),
    fixture("long3s"),
    fixture("coupled"),
};

/// A hand-built page, CRC and all, for the cases no encoder writes.
fn buildPage(gpa: Allocator, flags: u8, granule: u64, serial: u32, sequence: u32, lacing: []const u8, fill: u8) ![]u8 {
    var body_len: usize = 0;
    for (lacing) |v| body_len += v;
    const page = try gpa.alloc(u8, header_size + lacing.len + body_len);
    @memcpy(page[0..4], "OggS");
    page[4] = 0;
    page[5] = flags;
    std.mem.writeInt(u64, page[6..14], granule, .little);
    std.mem.writeInt(u32, page[14..18], serial, .little);
    std.mem.writeInt(u32, page[18..22], sequence, .little);
    @memset(page[22..26], 0);
    page[26] = @intCast(lacing.len);
    @memcpy(page[header_size..][0..lacing.len], lacing);
    for (page[header_size + lacing.len ..], 0..) |*b, i| b.* = fill +% @as(u8, @truncate(i));
    std.mem.writeInt(u32, page[22..26], crc32(page), .little);
    return page;
}

fn concat(gpa: Allocator, pages: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pages) |p| try out.appendSlice(gpa, p);
    return out.toOwnedSlice(gpa);
}

const first_flag = 0x02;
const last_flag = 0x04;
const continued_flag = 0x01;

test "the CRC is Ogg's: unreflected 0x04c11db7 from zero, no final XOR" {
    try testing.expectEqual(@as(u32, 0x89a1_897f), crc32("123456789"));
    try testing.expectEqual(@as(u32, 0), crc32(""));
    try testing.expectEqual(@as(u32, 0x5fb0_a94f), crc32("OggS"));
}

test "every fixture scans as one Vorbis stream whose final granule is the reference's length" {
    const wav = @import("wav.zig");
    for (fixtures) |f| {
        const info = try scan(f.ogg);
        try testing.expectEqual(Codec.vorbis, info.codec);
        try testing.expect(info.pages >= 3);
        var reference = try wav.decode(testing.allocator, f.reference, .{});
        defer reference.deinit(testing.allocator);
        testing.expectEqual(@as(u64, reference.frameCount()), info.granule) catch |err| {
            std.debug.print("fixture {s}\n", .{f.name});
            return err;
        };
    }
}

test "every fixture's packets read in order: three headers, then audio to the last page's granule" {
    for (fixtures) |f| {
        var packets: Packets = .init(f.ogg);
        defer packets.deinit(testing.allocator);
        const headers = [_][]const u8{ "\x01vorbis", "\x03vorbis", "\x05vorbis" };
        var count: usize = 0;
        var bytes: usize = 0;
        var granule: ?u64 = null;
        var last = false;
        while (try packets.next(testing.allocator)) |p| {
            try testing.expect(!last);
            if (count < headers.len) try testing.expect(std.mem.startsWith(u8, p.data, headers[count]));
            if (count >= headers.len) try testing.expect(p.data.len > 0 and p.data[0] & 1 == 0);
            if (p.granule) |g| granule = g;
            last = p.last;
            count += 1;
            bytes += p.data.len;
        }
        try testing.expect(last);
        try testing.expect(count > headers.len);
        try testing.expectEqual((try scan(f.ogg)).granule, granule.?);
        // Every byte of every body is in exactly one packet.
        var body: usize = 0;
        var pos: usize = 0;
        while (pos < f.ogg.len) {
            const page = try parsePage(f.ogg[pos..]);
            body += page.body.len;
            pos += page.size;
        }
        try testing.expectEqual(body, bytes);
    }
}

test "a packet spanning pages is gathered, and one of exactly 255 bytes ends on a zero" {
    const gpa = testing.allocator;
    // Page 0: a 10-byte packet, then 255 + 255 bytes of a packet left open.
    const p0 = try buildPage(gpa, first_flag, 100, 9, 0, &.{ 10, 255, 255 }, 0);
    defer gpa.free(p0);
    // Page 1 continues it with 100 bytes, then a packet of exactly 255 bytes (255, 0).
    const p1 = try buildPage(gpa, continued_flag | last_flag, 500, 9, 1, &.{ 100, 255, 0 }, 7);
    defer gpa.free(p1);
    const file = try concat(gpa, &.{ p0, p1 });
    defer gpa.free(file);

    var packets: Packets = .init(file);
    defer packets.deinit(gpa);
    const a = (try packets.next(gpa)).?;
    try testing.expectEqual(@as(usize, 10), a.data.len);
    try testing.expectEqual(@as(?u64, 100), a.granule);
    const b = (try packets.next(gpa)).?;
    try testing.expectEqual(@as(usize, 610), b.data.len);
    try testing.expectEqualSlices(u8, p0[header_size + 3 + 10 ..], b.data[0..510]);
    try testing.expectEqualSlices(u8, p1[header_size + 3 ..][0..100], b.data[510..]);
    try testing.expectEqual(@as(?u64, null), b.granule);
    const c = (try packets.next(gpa)).?;
    try testing.expectEqual(@as(usize, 255), c.data.len);
    try testing.expectEqual(@as(?u64, 500), c.granule);
    try testing.expect(c.last);
    try testing.expectEqual(@as(?Packet, null), try packets.next(gpa));
    try testing.expectEqual(@as(u64, 500), (try scan(file)).granule);
}

test "a page of 255 segments, the most the format allows, carries one packet" {
    const gpa = testing.allocator;
    var lacing: [255]u8 = @splat(255);
    lacing[254] = 3;
    const page = try buildPage(gpa, first_flag | last_flag, 7, 1, 0, &lacing, 0);
    defer gpa.free(page);
    var packets: Packets = .init(page);
    defer packets.deinit(gpa);
    try testing.expectEqual(@as(usize, 254 * 255 + 3), (try packets.next(gpa)).?.data.len);
    try testing.expectEqual(@as(?Packet, null), try packets.next(gpa));
}

fn expectRefused(expected: Error, file: []const u8) !void {
    try testing.expectError(expected, scan(file));
    var packets: Packets = .init(file);
    defer packets.deinit(testing.allocator);
    const outcome = while (true) {
        const p = packets.next(testing.allocator) catch |err| break err;
        if (p == null) break error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(anyerror, expected), outcome);
}

test "each malformed page is refused as invalid, by both readers" {
    const gpa = testing.allocator;
    const good = fixtures[0].ogg;
    const copy = try gpa.dupe(u8, good);
    defer gpa.free(copy);

    // Not Ogg at all.
    try expectRefused(error.InvalidSound, "RIFF....WAVEfmt ");
    // Cut inside the first header, inside its lacing, inside its body, and at a page boundary.
    const first = try parsePage(good);
    try expectRefused(error.InvalidSound, good[0..20]);
    try expectRefused(error.InvalidSound, good[0 .. header_size + 0]);
    try expectRefused(error.InvalidSound, good[0 .. first.size - 1]);
    try expectRefused(error.InvalidSound, good[0..first.size]);
    // One flipped byte in the body: the CRC says so.
    copy[first.size - 1] ^= 0x40;
    try expectRefused(error.InvalidSound, copy);
    copy[first.size - 1] ^= 0x40;
    // A version other than 0, and a reserved flag, each with a correct CRC.
    for ([_]struct { usize, u8 }{ .{ 4, 1 }, .{ 5, 0x08 | first_flag } }) |edit| {
        const saved = copy[edit[0]];
        copy[edit[0]] = edit[1];
        std.mem.writeInt(u32, copy[22..26], 0, .little);
        std.mem.writeInt(u32, copy[22..26], crc32(copy[0..first.size]), .little);
        try expectRefused(error.InvalidSound, copy);
        copy[edit[0]] = saved;
        std.mem.writeInt(u32, copy[22..26], 0, .little);
        std.mem.writeInt(u32, copy[22..26], crc32(copy[0..first.size]), .little);
    }
    try testing.expectEqualSlices(u8, good, copy);
    // Something after the last page.
    const trailing = try concat(gpa, &.{ good, "junk" });
    defer gpa.free(trailing);
    try expectRefused(error.InvalidSound, trailing);
}

test "the stream's own rules: begin, sequence, continuation, granule order, end" {
    const gpa = testing.allocator;
    const Case = struct { []const u8, []const []const u8 };
    var built: std.ArrayList([]u8) = .empty;
    defer {
        for (built.items) |p| gpa.free(p);
        built.deinit(gpa);
    }
    const page = struct {
        fn make(list: *std.ArrayList([]u8), flags: u8, granule: u64, serial: u32, seq: u32, lacing: []const u8) ![]const u8 {
            const p = try buildPage(testing.allocator, flags, granule, serial, seq, lacing, 1);
            try list.append(testing.allocator, p);
            return p;
        }
    }.make;
    const begin = try page(&built, first_flag, 0, 5, 0, &.{30});
    const cases = [_]Case{
        .{ "no first-page flag", &.{try page(&built, last_flag, 10, 5, 0, &.{30})} },
        .{ "a missing page", &.{ begin, try page(&built, last_flag, 10, 5, 2, &.{30}) } },
        .{ "a continuation of nothing", &.{ begin, try page(&built, continued_flag | last_flag, 10, 5, 1, &.{30}) } },
        .{ "an open packet not continued", &.{ try page(&built, first_flag, 0, 5, 0, &.{ 30, 255 }), try page(&built, last_flag, 10, 5, 1, &.{30}) } },
        .{ "a granule going backwards", &.{ try page(&built, first_flag, 50, 5, 0, &.{30}), try page(&built, last_flag, 10, 5, 1, &.{30}) } },
        .{ "a last page with no granule", &.{ begin, try page(&built, last_flag, Page.no_granule, 5, 1, &.{30}) } },
        .{ "a last page leaving a packet open", &.{ begin, try page(&built, last_flag, 10, 5, 1, &.{ 30, 255 }) } },
        .{ "the stream beginning twice", &.{ begin, try page(&built, first_flag | last_flag, 10, 5, 1, &.{30}) } },
        .{ "a first packet that does not end on the first page", &.{ try page(&built, first_flag, Page.no_granule, 5, 0, &.{255}), try page(&built, continued_flag | last_flag, 10, 5, 1, &.{30}) } },
    };
    for (cases) |case| {
        const file = try concat(gpa, case[1]);
        defer gpa.free(file);
        testing.expectError(error.InvalidSound, scan(file)) catch |err| {
            std.debug.print("case: {s}\n", .{case[0]});
            return err;
        };
    }
}

test "a second logical stream, multiplexed or chained, is unsupported rather than invalid" {
    const gpa = testing.allocator;
    const a0 = try buildPage(gpa, first_flag, 0, 5, 0, &.{30}, 0);
    defer gpa.free(a0);
    const b0 = try buildPage(gpa, first_flag, 0, 6, 0, &.{30}, 0);
    defer gpa.free(b0);
    const a1 = try buildPage(gpa, last_flag, 10, 5, 1, &.{30}, 0);
    defer gpa.free(a1);
    const b1 = try buildPage(gpa, last_flag, 10, 6, 1, &.{30}, 0);
    defer gpa.free(b1);
    const multiplexed = try concat(gpa, &.{ a0, b0, a1, b1 });
    defer gpa.free(multiplexed);
    try expectRefused(error.UnsupportedSound, multiplexed);
    const chained = try concat(gpa, &.{ a0, a1, b0, b1 });
    defer gpa.free(chained);
    try expectRefused(error.UnsupportedSound, chained);
    // Two of the real fixtures, end to end, are what a chained export looks like.
    const two = try concat(gpa, &.{ fixtures[0].ogg, fixtures[1].ogg });
    defer gpa.free(two);
    try testing.expectError(error.UnsupportedSound, scan(two));
}

test "the first packet names its codec" {
    try testing.expectEqual(Codec.vorbis, identify("\x01vorbis\x00\x00"));
    try testing.expectEqual(Codec.opus, identify("OpusHead\x01\x02"));
    try testing.expectEqual(Codec.flac, identify("\x7fFLAC\x01\x00"));
    try testing.expectEqual(Codec.speex, identify("Speex   1.2"));
    try testing.expectEqual(Codec.theora, identify("\x80theora"));
    try testing.expectEqual(Codec.unknown, identify("\x01vorbiz"));
    try testing.expectEqual(Codec.unknown, identify(""));

    const gpa = testing.allocator;
    var page = try buildPage(gpa, first_flag | last_flag, 0, 3, 0, &.{19}, 0);
    defer gpa.free(page);
    @memcpy(page[header_size + 1 ..][0..8], "OpusHead");
    std.mem.writeInt(u32, page[22..26], 0, .little);
    std.mem.writeInt(u32, page[22..26], crc32(page), .little);
    try testing.expectEqual(Codec.opus, (try scan(page)).codec);
}

test "a page that ends a packet but carries granule -1 gives that packet no position" {
    const gpa = testing.allocator;
    const p0 = try buildPage(gpa, first_flag, Page.no_granule, 9, 0, &.{10}, 0);
    defer gpa.free(p0);
    const p1 = try buildPage(gpa, last_flag, 300, 9, 1, &.{20}, 0);
    defer gpa.free(p1);
    const file = try concat(gpa, &.{ p0, p1 });
    defer gpa.free(file);

    var packets: Packets = .init(file);
    defer packets.deinit(gpa);
    try testing.expectEqual(@as(?u64, null), (try packets.next(gpa)).?.granule);
    try testing.expectEqual(@as(?u64, 300), (try packets.next(gpa)).?.granule);
}
