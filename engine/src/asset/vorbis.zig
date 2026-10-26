//! Vorbis I, decoded by Foundry (ADR-0065).
//!
//! Beside `wav.zig` and `ogg.zig`, and for their reasons: **a sound is a stranger's file**, so
//! the untrusted path is Zig, where a bad index is a checked panic in the builds Foundry ships
//! rather than an exploit. Correctness is measured against the reference libvorbis on the
//! fixtures `scripts/m30/make_fixtures.py` wrote (`music.md` §3.5).
//!
//! This file follows the Vorbis I specification (Xiph.Org, 2020) section by section. M30
//! Step 2 reads the three headers: the identification header's format, the comment header's
//! framing, and the setup header's codebooks, floors, residues, mappings and modes, each index
//! checked against the count it indexes. Step 3 decodes audio packets with what they hold.
//!
//! **The subset is stated, and everything outside it is refused by name** (`music.md` §3.4):
//! version 0, one or two channels, a rate up to 192 kHz, block sizes 64 to 8192, floor type 1
//! only (floor 0 is `UnsupportedSound`; libvorbis has not written it since before 1.0), lookup
//! types 0 to 2, Huffman trees that are complete or hold a single entry, and codebook values
//! that are finite.
//!
//! Design: `docs/design/music.md` §3.3–3.4.

const std = @import("std");
const core = @import("core");
const ogg = @import("ogg.zig");
const wav = @import("wav.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.asset);

/// The same set as WAV's, so the loader maps both decoders' refusals the same way.
pub const DecodeError = wav.DecodeError;

pub const Limits = struct {
    /// Frames, as WAV's limit is, checked from the final granule before anything is allocated.
    max_frames: u64 = 1 << 24,
    /// Bytes the setup header may make the decoder allocate: codebook lengths, codewords and
    /// value tables. A real file needs a few hundred kilobytes; a hostile one can declare
    /// sixteen million entries in a handful of bits, and this is what refuses it.
    max_setup_bytes: usize = 32 << 20,
};

pub const max_channels = 2;
pub const max_sample_rate = 192_000;
pub const min_blocksize = 64;
pub const max_blocksize = 8192;
/// The most points a floor 1 curve may have (Vorbis I §7.2.2).
pub const max_floor1_values = 65;

// -- bits -------------------------------------------------------------------------------------

/// Vorbis packs fields least significant bit first (Vorbis I §2.1).
pub const Bits = struct {
    bytes: []const u8,
    /// In bits.
    pos: usize = 0,

    pub const Error = error{EndOfPacket};

    /// The next `n` bits, `n` from 0 to 32. Past the end the packet is exhausted for good.
    pub fn read(self: *Bits, n: u6) Error!u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        const total = self.bytes.len * 8;
        if (self.pos + n > total) {
            self.pos = total;
            return error.EndOfPacket;
        }
        var value: u64 = 0;
        var got: u6 = 0;
        while (got < n) {
            const bit: u3 = @intCast(self.pos % 8);
            const take: u6 = @min(8 - @as(u6, bit), n - got);
            const piece = (@as(u64, self.bytes[self.pos / 8]) >> bit) & ((@as(u64, 1) << take) - 1);
            value |= piece << got;
            got += take;
            self.pos += take;
        }
        return @intCast(value);
    }

    pub fn flag(self: *Bits) Error!bool {
        return try self.read(1) == 1;
    }
};

/// The bits needed to hold `x`: `ilog(0)` is 0, `ilog(1)` is 1, `ilog(4)` is 3 (Vorbis I §9.2.1).
pub fn ilog(x: u32) u6 {
    return @intCast(32 - @clz(x));
}

/// A codebook's 32-bit float encoding: 21 bits of mantissa, a 10-bit exponent biased by 788,
/// and a sign (Vorbis I §9.2.2). Exact in `f64`; the cast to `f32` can overflow to infinity,
/// which the value table's check refuses.
pub fn float32Unpack(x: u32) f32 {
    const mantissa: f64 = @floatFromInt(x & 0x1f_ffff);
    const exponent: i32 = @intCast((x & 0x7fe0_0000) >> 21);
    const value = std.math.ldexp(mantissa, exponent - 788);
    return @floatCast(if (x & 0x8000_0000 != 0) -value else value);
}

/// The largest `r` with `r^dimensions ≤ entries` (Vorbis I §9.2.3), by integers alone.
pub fn lookup1Values(entries: u32, dimensions: u16) u32 {
    std.debug.assert(dimensions > 0);
    var r: u32 = 0;
    while (true) {
        const next = r + 1;
        var power: u64 = 1;
        var over = false;
        for (0..dimensions) |_| {
            power *= next;
            if (power > entries) {
                over = true;
                break;
            }
        }
        if (over) return r;
        r = next;
    }
}

// -- what the headers hold --------------------------------------------------------------------

pub const Info = struct {
    channels: u8,
    sample_rate: u32,
    /// The short and the long block, in frames.
    blocksize: [2]u16,
};

pub const Codebook = struct {
    dimensions: u16,
    entries: u32,
    /// Each entry's codeword length in bits; 0 for an entry the book never codes.
    lengths: []const u8,
    /// Each used entry's codeword, **bit-reversed**, so it compares directly with bits read
    /// least significant first. The specification's codewords are written most significant
    /// first, and the first bit read is the most significant (Vorbis I §3.2.1).
    codewords: []const u32,
    used: u32,
    /// `entries × dimensions` values, entry-major, for lookup types 1 and 2; null for type 0,
    /// which only a scalar context (a floor, a residue's classbook) may use.
    values: ?[]const f32,
};

pub const Floor1 = struct {
    partition_class: []const u8,
    class_dimensions: [16]u8 = @splat(0),
    class_subclasses: [16]u8 = @splat(0),
    class_masterbook: [16]u8 = @splat(0),
    /// A subclass's book, or -1 for none.
    subclass_books: [16][8]i16 = @splat(@splat(-1)),
    multiplier: u8,
    range_bits: u4,
    /// The curve's points, in the order the packet codes them; `x[1]` is `1 << range_bits`.
    x: []const u16,
    /// Indices into `x`, ascending by value.
    sorted: []const u8,
    /// For each point from the third: the nearest earlier point below it and above it
    /// (Vorbis I §9.2.4 and §9.2.5). Entries 0 and 1 are unused.
    low_neighbor: []const u8,
    high_neighbor: []const u8,
};

pub const Residue = struct {
    kind: u2,
    begin: u32,
    end: u32,
    partition_size: u32,
    classifications: u8,
    classbook: u8,
    /// For each classification, the book of each of its eight passes, or -1 for none.
    books: []const [8]i16,
};

pub const Mapping = struct {
    submaps: u8,
    coupling: []const Coupling,
    /// Each channel's submap.
    mux: [max_channels]u8 = @splat(0),
    submap_floor: [16]u8 = @splat(0),
    submap_residue: [16]u8 = @splat(0),

    pub const Coupling = struct { magnitude: u8, angle: u8 };
};

pub const Mode = struct {
    long_block: bool,
    mapping: u8,
};

/// Everything the setup header declares, parsed once per sound and shared read-only by every
/// stream of it (`music.md` §6.1). It owns its memory.
pub const Setup = struct {
    arena: std.heap.ArenaAllocator,
    codebooks: []const Codebook,
    floors: []const Floor1,
    residues: []const Residue,
    mappings: []const Mapping,
    modes: []const Mode,

    pub fn deinit(self: *Setup) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The three headers of a checked stream, and its length.
pub const Headers = struct {
    info: Info,
    setup: Setup,
    /// The stream's length, from its final granule.
    frames: u64,

    pub fn deinit(self: *Headers) void {
        self.setup.deinit();
        self.* = undefined;
    }
};

// -- reading them -----------------------------------------------------------------------------

fn invalid(comptime fmt: []const u8, args: anytype) DecodeError {
    log.warn("vorbis: " ++ fmt, args);
    return error.InvalidSound;
}

fn unsupported(comptime fmt: []const u8, args: anytype) DecodeError {
    log.warn("vorbis: " ++ fmt, args);
    return error.UnsupportedSound;
}

/// A header's field, where running out of packet is a malformed header.
fn field(bits: *Bits, n: u6) DecodeError!u32 {
    return bits.read(n) catch invalid("a header ends before its last field", .{});
}

fn checkPreamble(packet: []const u8, kind: u8, name: []const u8) DecodeError!Bits {
    if (packet.len < 7 or packet[0] != kind or !std.mem.eql(u8, packet[1..7], "vorbis")) {
        return invalid("the {s} header is missing or out of place", .{name});
    }
    return .{ .bytes = packet, .pos = 7 * 8 };
}

/// Every header of `bytes`, checked: the container, the codec, the length, then the three
/// header packets in order. Allocates only for the setup, and only after the length and the
/// identification header have been checked.
pub fn readHeaders(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Headers {
    const stream = try ogg.scan(bytes);
    if (stream.codec != .vorbis) {
        return unsupported("the stream is {s}, not Vorbis; re-export as Ogg Vorbis", .{stream.codec.name()});
    }
    if (stream.granule == 0) return invalid("the stream has no frames", .{});
    if (stream.granule > limits.max_frames) {
        log.warn("vorbis: {d} frames exceeds the {d}-frame limit", .{ stream.granule, limits.max_frames });
        return error.SoundTooLarge;
    }

    var packets: ogg.Packets = .init(bytes);
    defer packets.deinit(gpa);
    const next = struct {
        fn f(p: *ogg.Packets, a: Allocator) DecodeError![]const u8 {
            const packet = try p.next(a) orelse return invalid("the stream ends inside its headers", .{});
            return packet.data;
        }
    }.f;

    const info = try parseIdentification(try next(&packets, gpa));
    try parseComment(try next(&packets, gpa));
    const setup = try parseSetup(gpa, try next(&packets, gpa), info, limits);
    return .{ .info = info, .setup = setup, .frames = stream.granule };
}

/// Vorbis I §4.2.2.
pub fn parseIdentification(packet: []const u8) DecodeError!Info {
    var bits = try checkPreamble(packet, 1, "identification");
    const version = try field(&bits, 32);
    if (version != 0) return unsupported("Vorbis version {d}; only version 0 exists", .{version});
    const channels = try field(&bits, 8);
    if (channels == 0) return invalid("the stream declares no channels", .{});
    if (channels > max_channels) return unsupported("{d} channels is not supported; mono and stereo are", .{channels});
    const rate = try field(&bits, 32);
    if (rate == 0) return invalid("the stream's sample rate is zero", .{});
    if (rate > max_sample_rate) return unsupported("a sample rate of {d} Hz is above the {d} Hz this decoder takes", .{ rate, max_sample_rate });
    // Maximum, nominal and minimum bitrates: hints nothing here needs.
    _ = try field(&bits, 32);
    _ = try field(&bits, 32);
    _ = try field(&bits, 32);
    const exponents = [2]u32{ try field(&bits, 4), try field(&bits, 4) };
    for (exponents) |e| if (e < 6 or e > 13) {
        return invalid("a block size of 2^{d} is outside 64 to 8192", .{e});
    };
    if (exponents[0] > exponents[1]) return invalid("the short block is longer than the long one", .{});
    if (!try framing(&bits)) return invalid("the identification header's framing bit is not set", .{});
    return .{
        .channels = @intCast(channels),
        .sample_rate = rate,
        .blocksize = .{ @as(u16, 1) << @intCast(exponents[0]), @as(u16, 1) << @intCast(exponents[1]) },
    };
}

fn framing(bits: *Bits) DecodeError!bool {
    return try field(bits, 1) == 1;
}

/// Vorbis I §5.2.1. Checked for its framing and skipped: no tag is read, because nothing in
/// Foundry asks for one.
pub fn parseComment(packet: []const u8) DecodeError!void {
    var bits = try checkPreamble(packet, 3, "comment");
    const vendor = try field(&bits, 32);
    try skipBytes(&bits, vendor);
    const count = try field(&bits, 32);
    for (0..count) |_| try skipBytes(&bits, try field(&bits, 32));
    if (!try framing(&bits)) return invalid("the comment header's framing bit is not set", .{});
}

fn skipBytes(bits: *Bits, n: u32) DecodeError!void {
    // The header is byte-aligned up to here, so a length is a whole number of bytes.
    const remaining = bits.bytes.len * 8 - bits.pos;
    if (@as(u64, n) * 8 > remaining) return invalid("a comment runs past the end of its header", .{});
    bits.pos += @as(usize, n) * 8;
}

/// Allocation from the setup's arena, counted against `Limits.max_setup_bytes` first.
const Budget = struct {
    arena: Allocator,
    left: usize,

    fn alloc(self: *Budget, comptime T: type, n: u64) DecodeError![]T {
        const bytes = std.math.mul(u64, n, @sizeOf(T)) catch return tooLarge();
        if (bytes > self.left) return tooLarge();
        self.left -= @intCast(bytes);
        return self.arena.alloc(T, @intCast(n));
    }

    fn tooLarge() DecodeError {
        log.warn("vorbis: the setup header asks for more memory than a sound may use", .{});
        return error.SoundTooLarge;
    }
};

/// Vorbis I §4.2.4.
pub fn parseSetup(gpa: Allocator, packet: []const u8, info: Info, limits: Limits) DecodeError!Setup {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var budget: Budget = .{ .arena = arena.allocator(), .left = limits.max_setup_bytes };
    var bits = try checkPreamble(packet, 5, "setup");

    const codebooks = try budget.alloc(Codebook, try field(&bits, 8) + 1);
    for (codebooks, 0..) |*book, i| book.* = try parseCodebook(&bits, &budget, i);

    // Time-domain transforms: placeholders in Vorbis I, each of which must be zero.
    const times = try field(&bits, 6) + 1;
    for (0..times) |_| if (try field(&bits, 16) != 0) {
        return invalid("a time-domain transform is not the placeholder 0", .{});
    };

    const floors = try budget.alloc(Floor1, try field(&bits, 6) + 1);
    for (floors, 0..) |*floor, i| floor.* = try parseFloor(&bits, &budget, codebooks, i);

    const residues = try budget.alloc(Residue, try field(&bits, 6) + 1);
    for (residues, 0..) |*residue, i| residue.* = try parseResidue(&bits, &budget, codebooks, i);

    const mappings = try budget.alloc(Mapping, try field(&bits, 6) + 1);
    for (mappings, 0..) |*mapping, i| mapping.* = try parseMapping(&bits, &budget, info, floors.len, residues.len, i);

    const modes = try budget.alloc(Mode, try field(&bits, 6) + 1);
    for (modes, 0..) |*mode, i| {
        mode.long_block = try field(&bits, 1) == 1;
        const window = try field(&bits, 16);
        const transform = try field(&bits, 16);
        if (window != 0 or transform != 0) return invalid("mode {d}'s window or transform type is not 0", .{i});
        const mapping = try field(&bits, 8);
        if (mapping >= mappings.len) return invalid("mode {d} names mapping {d} of {d}", .{ i, mapping, mappings.len });
        mode.mapping = @intCast(mapping);
    }
    if (!try framing(&bits)) return invalid("the setup header's framing bit is not set", .{});

    return .{
        .arena = arena,
        .codebooks = codebooks,
        .floors = floors,
        .residues = residues,
        .mappings = mappings,
        .modes = modes,
    };
}

/// Vorbis I §3.2.1.
fn parseCodebook(bits: *Bits, budget: *Budget, index: usize) DecodeError!Codebook {
    if (try field(bits, 24) != 0x564342) return invalid("codebook {d} does not begin with its sync pattern", .{index});
    const dimensions: u16 = @intCast(try field(bits, 16));
    const entries = try field(bits, 24);
    if (dimensions == 0) return invalid("codebook {d} has no dimensions", .{index});
    if (entries == 0) return invalid("codebook {d} has no entries", .{index});

    const lengths = try budget.alloc(u8, entries);
    if (try field(bits, 1) == 1) {
        // Ordered: runs of entries at each length, ascending.
        var current: u32 = 0;
        var length = try field(bits, 5) + 1;
        while (current < entries) {
            if (length > 32) return invalid("codebook {d} has a codeword longer than 32 bits", .{index});
            const number = try field(bits, ilog(entries - current));
            if (number > entries - current) return invalid("codebook {d}'s lengths run past its entries", .{index});
            @memset(lengths[current..][0..number], @intCast(length));
            current += number;
            length += 1;
        }
    } else {
        const sparse = try field(bits, 1) == 1;
        for (lengths) |*l| {
            l.* = if (!sparse or try field(bits, 1) == 1) @intCast(try field(bits, 5) + 1) else 0;
        }
    }

    const codewords = try budget.alloc(u32, entries);
    const used = try assignCodewords(lengths, codewords, index);

    const lookup = try field(bits, 4);
    const values: ?[]f32 = switch (lookup) {
        0 => null,
        1, 2 => try parseValues(bits, budget, lookup, entries, dimensions, index),
        else => return invalid("codebook {d} has lookup type {d}; Vorbis I defines 0 to 2", .{ index, lookup }),
    };
    return .{
        .dimensions = dimensions,
        .entries = entries,
        .lengths = lengths,
        .codewords = codewords,
        .used = used,
        .values = values,
    };
}

/// Assigns each used entry the lowest free codeword of its length, in entry order, as
/// Vorbis I §3.2.1 does, and refuses a tree that is overspecified (a codeword with no room
/// left) or underspecified (a codeword nobody holds), except a book with one used entry,
/// whose single codeword libvorbis also accepts. Returns the number of used entries.
pub fn assignCodewords(lengths: []const u8, codewords: []u32, index: usize) DecodeError!u32 {
    // `available[l]`: the lowest free codeword of length `l`, aligned to the top of 32 bits,
    // or 0 for none.
    var available: [33]u32 = @splat(0);
    var used: u32 = 0;
    for (lengths, codewords) |length, *codeword| {
        if (length == 0) continue;
        if (used == 0) {
            codeword.* = 0;
            for (1..length + 1) |l| available[l] = @as(u32, 1) << @intCast(32 - l);
        } else {
            var y: usize = length;
            while (y > 0 and available[y] == 0) y -= 1;
            if (y == 0) return invalid("codebook {d}'s Huffman tree is overspecified", .{index});
            const res = available[y];
            available[y] = 0;
            codeword.* = @intCast(@as(u64, res) >> @intCast(32 - @as(u6, @intCast(length))));
            for (y + 1..length + 1) |l| available[l] = res + (@as(u32, 1) << @intCast(32 - l));
        }
        used += 1;
    }
    if (used > 1) for (available[1..]) |a| if (a != 0) {
        return invalid("codebook {d}'s Huffman tree is underspecified", .{index});
    };
    // Bit-reverse every codeword, so decoding compares with bits read least significant first.
    for (lengths, codewords) |length, *codeword| {
        if (length == 0) continue;
        const l: u6 = @intCast(length);
        codeword.* = @bitReverse(codeword.*) >> @intCast(32 - l);
    }
    return used;
}

/// The vector values of lookup types 1 and 2 (Vorbis I §3.2.1, "VQ lookup table vector
/// representation"), expanded per entry in `f32`, as libvorbis computes them. A value that is
/// not finite refuses the file: it would reach the mixer as a non-finite sample.
fn parseValues(bits: *Bits, budget: *Budget, lookup: u32, entries: u32, dimensions: u16, index: usize) DecodeError![]f32 {
    const minimum = float32Unpack(try field(bits, 32));
    const delta = float32Unpack(try field(bits, 32));
    const value_bits: u6 = @intCast(try field(bits, 4) + 1);
    const sequence = try field(bits, 1) == 1;
    const lookup_values: u64 = if (lookup == 1) lookup1Values(entries, dimensions) else @as(u64, entries) * dimensions;
    if (lookup_values == 0) return invalid("codebook {d} has no lookup values", .{index});
    // The multiplicands are in the packet, so a count past its remaining bits is a lie.
    if (lookup_values * value_bits > bits.bytes.len * 8 - bits.pos) {
        return invalid("codebook {d}'s lookup values run past the end of the setup header", .{index});
    }
    const multiplicands = try budget.alloc(u32, lookup_values);
    for (multiplicands) |*m| m.* = try field(bits, value_bits);

    const values = try budget.alloc(f32, @as(u64, entries) * dimensions);
    for (0..entries) |entry| {
        var last: f32 = 0;
        var divisor: u64 = 1;
        for (0..dimensions) |d| {
            const offset = if (lookup == 1) (entry / divisor) % lookup_values else entry * dimensions + d;
            const v = @as(f32, @floatFromInt(multiplicands[@intCast(offset)])) * delta + minimum + last;
            if (!std.math.isFinite(v)) return invalid("codebook {d} has a value that is not finite", .{index});
            values[entry * dimensions + d] = v;
            if (sequence) last = v;
            if (lookup == 1) divisor *= lookup_values;
        }
    }
    return values;
}

/// Vorbis I §6 (refused) and §7.2.2.
fn parseFloor(bits: *Bits, budget: *Budget, codebooks: []const Codebook, index: usize) DecodeError!Floor1 {
    const kind = try field(bits, 16);
    switch (kind) {
        0 => return unsupported("floor {d} is Vorbis floor 0, which this decoder does not take; re-export with a current encoder", .{index}),
        1 => {},
        else => return invalid("floor {d} has type {d}; Vorbis I defines 0 and 1", .{ index, kind }),
    }
    const partitions = try field(bits, 5);
    const partition_class = try budget.alloc(u8, partitions);
    var classes: usize = 0;
    for (partition_class) |*c| {
        c.* = @intCast(try field(bits, 4));
        classes = @max(classes, @as(usize, c.*) + 1);
    }
    var floor: Floor1 = .{
        .partition_class = partition_class,
        .multiplier = 0,
        .range_bits = 0,
        .x = &.{},
        .sorted = &.{},
        .low_neighbor = &.{},
        .high_neighbor = &.{},
    };
    for (0..classes) |c| {
        floor.class_dimensions[c] = @intCast(try field(bits, 3) + 1);
        floor.class_subclasses[c] = @intCast(try field(bits, 2));
        if (floor.class_subclasses[c] > 0) {
            const book = try field(bits, 8);
            if (book >= codebooks.len) return invalid("floor {d} names codebook {d} of {d}", .{ index, book, codebooks.len });
            floor.class_masterbook[c] = @intCast(book);
        }
        for (0..@as(usize, 1) << @intCast(floor.class_subclasses[c])) |j| {
            const book = @as(i32, @intCast(try field(bits, 8))) - 1;
            if (book >= codebooks.len) return invalid("floor {d} names codebook {d} of {d}", .{ index, book, codebooks.len });
            floor.subclass_books[c][j] = @intCast(book);
        }
    }
    floor.multiplier = @intCast(try field(bits, 2) + 1);
    floor.range_bits = @intCast(try field(bits, 4));

    var count: usize = 2;
    for (partition_class) |c| count += floor.class_dimensions[c];
    if (count > max_floor1_values) return invalid("floor {d} has {d} points; Vorbis I allows {d}", .{ index, count, max_floor1_values });
    const x = try budget.alloc(u16, count);
    x[0] = 0;
    x[1] = @as(u16, 1) << floor.range_bits;
    var n: usize = 2;
    for (partition_class) |c| for (0..floor.class_dimensions[c]) |_| {
        x[n] = @intCast(try field(bits, floor.range_bits));
        n += 1;
    };

    const sorted = try budget.alloc(u8, count);
    for (sorted, 0..) |*s, i| s.* = @intCast(i);
    std.mem.sort(u8, sorted, x, struct {
        fn less(xs: []const u16, a: u8, b: u8) bool {
            return xs[a] < xs[b];
        }
    }.less);
    for (sorted[1..], sorted[0 .. count - 1]) |a, b| if (x[a] == x[b]) {
        return invalid("floor {d} has two points at x = {d}", .{ index, x[a] });
    };

    const low = try budget.alloc(u8, count);
    const high = try budget.alloc(u8, count);
    low[0] = 0;
    low[1] = 0;
    high[0] = 0;
    high[1] = 0;
    for (2..count) |i| {
        var lo: usize = 0;
        var hi: usize = 1;
        for (0..i) |j| {
            if (x[j] < x[i] and x[j] > x[lo]) lo = j;
            if (x[j] > x[i] and x[j] < x[hi]) hi = j;
        }
        low[i] = @intCast(lo);
        high[i] = @intCast(hi);
    }
    floor.x = x;
    floor.sorted = sorted;
    floor.low_neighbor = low;
    floor.high_neighbor = high;
    return floor;
}

/// Vorbis I §8.6.1.
fn parseResidue(bits: *Bits, budget: *Budget, codebooks: []const Codebook, index: usize) DecodeError!Residue {
    const kind = try field(bits, 16);
    if (kind > 2) return invalid("residue {d} has type {d}; Vorbis I defines 0 to 2", .{ index, kind });
    var residue: Residue = .{
        .kind = @intCast(kind),
        .begin = try field(bits, 24),
        .end = try field(bits, 24),
        .partition_size = try field(bits, 24) + 1,
        .classifications = @intCast(try field(bits, 6) + 1),
        .classbook = undefined,
        .books = &.{},
    };
    const classbook = try field(bits, 8);
    if (classbook >= codebooks.len) return invalid("residue {d} names codebook {d} of {d}", .{ index, classbook, codebooks.len });
    residue.classbook = @intCast(classbook);

    var cascade: [64]u8 = undefined;
    for (cascade[0..residue.classifications]) |*c| {
        const low = try field(bits, 3);
        const high = if (try field(bits, 1) == 1) try field(bits, 5) else 0;
        c.* = @intCast(high * 8 + low);
    }
    const books = try budget.alloc([8]i16, residue.classifications);
    for (books, cascade[0..residue.classifications]) |*row, c| {
        for (row, 0..) |*book, pass| {
            book.* = -1;
            if (c & (@as(u8, 1) << @intCast(pass)) == 0) continue;
            const b = try field(bits, 8);
            if (b >= codebooks.len) return invalid("residue {d} names codebook {d} of {d}", .{ index, b, codebooks.len });
            if (codebooks[b].values == null) return invalid("residue {d} decodes vectors from codebook {d}, which has none", .{ index, b });
            book.* = @intCast(b);
        }
    }
    residue.books = books;
    return residue;
}

/// Vorbis I §4.2.4, "mappings".
fn parseMapping(bits: *Bits, budget: *Budget, info: Info, floors: usize, residues: usize, index: usize) DecodeError!Mapping {
    const kind = try field(bits, 16);
    if (kind != 0) return invalid("mapping {d} has type {d}; Vorbis I defines only 0", .{ index, kind });
    var mapping: Mapping = .{ .submaps = 1, .coupling = &.{} };
    if (try field(bits, 1) == 1) mapping.submaps = @intCast(try field(bits, 4) + 1);
    if (try field(bits, 1) == 1) {
        const steps = try field(bits, 8) + 1;
        const coupling = try budget.alloc(Mapping.Coupling, steps);
        const width = ilog(info.channels - 1);
        for (coupling) |*step| {
            const magnitude = try field(bits, width);
            const angle = try field(bits, width);
            if (magnitude == angle or magnitude >= info.channels or angle >= info.channels) {
                return invalid("mapping {d} couples channel {d} with channel {d}", .{ index, magnitude, angle });
            }
            step.* = .{ .magnitude = @intCast(magnitude), .angle = @intCast(angle) };
        }
        mapping.coupling = coupling;
    }
    if (try field(bits, 2) != 0) return invalid("mapping {d}'s reserved field is not zero", .{index});
    if (mapping.submaps > 1) for (mapping.mux[0..info.channels]) |*m| {
        const submap = try field(bits, 4);
        if (submap >= mapping.submaps) return invalid("mapping {d} puts a channel in submap {d} of {d}", .{ index, submap, mapping.submaps });
        m.* = @intCast(submap);
    };
    for (0..mapping.submaps) |s| {
        _ = try field(bits, 8); // Unused time configuration.
        const floor = try field(bits, 8);
        if (floor >= floors) return invalid("mapping {d} names floor {d} of {d}", .{ index, floor, floors });
        const residue = try field(bits, 8);
        if (residue >= residues) return invalid("mapping {d} names residue {d} of {d}", .{ index, residue, residues });
        mapping.submap_floor[s] = @intCast(floor);
        mapping.submap_residue[s] = @intCast(residue);
    }
    return mapping;
}

// -- tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// Writes fields least significant bit first, as an encoder does, for hand-made headers.
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit: u3 = 0,

    fn write(self: *BitWriter, value: u64, n: u7) !void {
        var i: u7 = 0;
        while (i < n) : (i += 1) {
            if (self.bit == 0) try self.bytes.append(testing.allocator, 0);
            if ((value >> @intCast(i)) & 1 == 1) self.bytes.items[self.bytes.items.len - 1] |= @as(u8, 1) << self.bit;
            self.bit +%= 1;
        }
    }

    fn deinit(self: *BitWriter) void {
        self.bytes.deinit(testing.allocator);
    }
};

/// A minimal valid setup, with each field a test may set out of range.
const Sketch = struct {
    sync: u32 = 0x564342,
    dimensions: u16 = 1,
    lengths: []const u8 = &.{ 1, 1 },
    lookup: u4 = 1,
    minimum: u32 = 0,
    value_bits: u4 = 0,
    time: u16 = 0,
    floor_kind: u16 = 1,
    floor_x: []const u16 = &.{ 5, 9 },
    floor_book: u8 = 1, // a subclass book number plus one
    residue_kind: u16 = 0,
    residue_book: u8 = 1,
    mapping_kind: u16 = 0,
    coupling: ?[2]u8 = null,
    reserved: u2 = 0,
    mapping_floor: u8 = 0,
    mapping_residue: u8 = 0,
    window: u16 = 0,
    mode_mapping: u8 = 0,
    framing: u1 = 1,

    fn write(self: Sketch, w: *BitWriter, channels: u8) !void {
        for ("\x05vorbis") |c| try w.write(c, 8);
        try w.write(2 - 1, 8); // Two codebooks: book 0 scalar, book 1 with values.
        for (0..2) |b| {
            try w.write(self.sync, 24);
            try w.write(self.dimensions, 16);
            try w.write(self.lengths.len, 24);
            try w.write(0, 1); // Not ordered.
            try w.write(1, 1); // Sparse.
            for (self.lengths) |l| {
                try w.write(@intFromBool(l > 0), 1);
                if (l > 0) try w.write(l - 1, 5);
            }
            if (b == 0) {
                try w.write(0, 4);
            } else {
                try w.write(self.lookup, 4);
                if (self.lookup == 1 or self.lookup == 2) {
                    try w.write(self.minimum, 32);
                    try w.write((768 << 21) | (1 << 20), 32); // Delta 1.0.
                    try w.write(self.value_bits, 4);
                    try w.write(0, 1);
                    const count = if (self.dimensions == 0) 0 else if (self.lookup == 1) lookup1Values(@intCast(self.lengths.len), self.dimensions) else self.lengths.len * self.dimensions;
                    for (0..count) |i| try w.write(i, @as(u7, self.value_bits) + 1);
                }
            }
        }
        try w.write(0, 6);
        try w.write(self.time, 16);

        try w.write(0, 6); // One floor.
        try w.write(self.floor_kind, 16);
        if (self.floor_kind == 1) {
            try w.write(1, 5); // One partition, of class 0.
            try w.write(0, 4);
            try w.write(self.floor_x.len - 1, 3);
            try w.write(0, 2); // No subclasses, so no masterbook.
            try w.write(self.floor_book, 8);
            try w.write(0, 2); // Multiplier 1.
            try w.write(4, 4); // Range bits 4: x[1] = 16.
            for (self.floor_x) |x| try w.write(x, 4);
        }

        try w.write(0, 6); // One residue.
        try w.write(self.residue_kind, 16);
        try w.write(0, 24);
        try w.write(16, 24);
        try w.write(7, 24);
        try w.write(0, 6); // One classification.
        try w.write(0, 8); // Classbook 0.
        try w.write(1, 3); // Its cascade: pass 0 only.
        try w.write(0, 1);
        try w.write(self.residue_book, 8);

        try w.write(0, 6); // One mapping.
        try w.write(self.mapping_kind, 16);
        try w.write(0, 1); // One submap.
        if (self.coupling) |c| {
            try w.write(1, 1);
            try w.write(0, 8);
            const width = ilog(channels - 1);
            try w.write(c[0], width);
            try w.write(c[1], width);
        } else try w.write(0, 1);
        try w.write(self.reserved, 2);
        try w.write(0, 8);
        try w.write(self.mapping_floor, 8);
        try w.write(self.mapping_residue, 8);

        try w.write(0, 6); // One mode.
        try w.write(0, 1);
        try w.write(self.window, 16);
        try w.write(0, 16);
        try w.write(self.mode_mapping, 8);
        try w.write(self.framing, 1);
    }

    fn parse(self: Sketch, channels: u8) DecodeError!Setup {
        var w: BitWriter = .{};
        defer w.deinit();
        self.write(&w, channels) catch return error.OutOfMemory;
        const info: Info = .{ .channels = channels, .sample_rate = 44100, .blocksize = .{ 256, 2048 } };
        return parseSetup(testing.allocator, w.bytes.items, info, .{});
    }
};

test "bits are read least significant first, across bytes, and running out is final" {
    var bits: Bits = .{ .bytes = &.{ 0b1010_1101, 0b0000_0011 } };
    try testing.expectEqual(@as(u32, 0b101), try bits.read(3));
    try testing.expectEqual(@as(u32, 0b1_10101), try bits.read(6));
    try testing.expectEqual(@as(u32, 0b1), try bits.read(1));
    try testing.expectError(error.EndOfPacket, bits.read(7));
    try testing.expectError(error.EndOfPacket, bits.read(1));
    var all: Bits = .{ .bytes = &.{ 0x78, 0x56, 0x34, 0x12 } };
    try testing.expectEqual(@as(u32, 0x1234_5678), try all.read(32));
}

test "ilog, float32_unpack and lookup1_values follow the specification" {
    try testing.expectEqual(@as(u6, 0), ilog(0));
    try testing.expectEqual(@as(u6, 1), ilog(1));
    try testing.expectEqual(@as(u6, 2), ilog(2));
    try testing.expectEqual(@as(u6, 2), ilog(3));
    try testing.expectEqual(@as(u6, 3), ilog(4));
    try testing.expectEqual(@as(u6, 32), ilog(0xffff_ffff));
    // 1.0 is a mantissa of 2^20 at exponent 788 − 20.
    try testing.expectEqual(@as(f32, 1.0), float32Unpack((768 << 21) | (1 << 20)));
    try testing.expectEqual(@as(f32, -0.5), float32Unpack(0x8000_0000 | (767 << 21) | (1 << 20)));
    try testing.expectEqual(@as(f32, 0), float32Unpack(0));
    try testing.expect(std.math.isInf(float32Unpack((1023 << 21) | 0x1f_ffff)));
    try testing.expectEqual(@as(u32, 2), lookup1Values(2, 1));
    try testing.expectEqual(@as(u32, 9), lookup1Values(81, 2));
    try testing.expectEqual(@as(u32, 8), lookup1Values(80, 2));
    try testing.expectEqual(@as(u32, 3), lookup1Values(81, 4));
    try testing.expectEqual(@as(u32, 1), lookup1Values(1, 8));
}

test "codewords are assigned lowest-first by the specification's example, and stored reversed" {
    // Vorbis I §3.2.1's worked example: lengths 2 4 4 4 4 2 3 3.
    const lengths = [_]u8{ 2, 4, 4, 4, 4, 2, 3, 3 };
    var codewords: [8]u32 = undefined;
    try testing.expectEqual(@as(u32, 8), try assignCodewords(&lengths, &codewords, 0));
    const expected = [_]u32{ 0b00, 0b0100, 0b0101, 0b0110, 0b0111, 0b10, 0b110, 0b111 };
    for (expected, lengths, codewords) |e, l, c| {
        try testing.expectEqual(@bitReverse(e) >> @intCast(32 - @as(u6, @intCast(l))), c);
    }
}

test "an overspecified or underspecified tree is refused; a single entry is not" {
    var codewords: [4]u32 = undefined;
    try testing.expectError(error.InvalidSound, assignCodewords(&.{ 1, 1, 1 }, codewords[0..3], 0));
    try testing.expectError(error.InvalidSound, assignCodewords(&.{ 1, 2 }, codewords[0..2], 0));
    try testing.expectEqual(@as(u32, 1), try assignCodewords(&.{ 0, 3, 0 }, codewords[0..3], 0));
    try testing.expectEqual(@as(u32, 3), try assignCodewords(&.{ 2, 1, 2 }, codewords[0..3], 0));
}

test "every fixture's headers parse, and say what the reference says" {
    for (ogg.fixtures) |f| {
        var headers = try readHeaders(testing.allocator, f.ogg, .{});
        defer headers.deinit();
        var reference = try wav.decode(testing.allocator, f.reference, .{});
        defer reference.deinit(testing.allocator);
        try testing.expectEqual(reference.channels, headers.info.channels);
        try testing.expectEqual(reference.sample_rate, headers.info.sample_rate);
        try testing.expectEqual(@as(u64, reference.frameCount()), headers.frames);
        try testing.expect(headers.info.blocksize[0] <= headers.info.blocksize[1]);
        const s = headers.setup;
        try testing.expect(s.codebooks.len > 0 and s.floors.len > 0 and s.residues.len > 0);
        // libvorbis writes a short-block mode, and a long-block one when the sizes differ.
        try testing.expect(s.modes.len >= 1 and !s.modes[0].long_block);
        if (headers.info.blocksize[0] != headers.info.blocksize[1]) try testing.expect(s.modes[s.modes.len - 1].long_block);
        for (s.codebooks) |book| try testing.expect(book.used > 0);
        if (headers.info.channels == 2) {
            try testing.expect(s.mappings[0].coupling.len == 1);
        }
    }
}

test "the minimal sketch parses, so each refusal below is its one field" {
    var setup = try (Sketch{}).parse(1);
    defer setup.deinit();
    try testing.expectEqual(@as(usize, 2), setup.codebooks.len);
    try testing.expectEqualSlices(f32, &.{ 0, 1 }, setup.codebooks[1].values.?);
    try testing.expectEqualSlices(u16, &.{ 0, 16, 5, 9 }, setup.floors[0].x);
    try testing.expectEqualSlices(u8, &.{ 0, 2, 3, 1 }, setup.floors[0].sorted);
    try testing.expectEqual(@as(u8, 0), setup.floors[0].low_neighbor[2]);
    try testing.expectEqual(@as(u8, 1), setup.floors[0].high_neighbor[2]);
    try testing.expectEqual(@as(u8, 2), setup.floors[0].low_neighbor[3]);
    try testing.expectEqual(@as(u8, 1), setup.floors[0].high_neighbor[3]);
    var stereo = try (Sketch{ .coupling = .{ 0, 1 } }).parse(2);
    defer stereo.deinit();
    try testing.expectEqual(@as(u8, 1), stereo.mappings[0].coupling[0].angle);
}

test "each setup field out of range is refused by name" {
    const Case = struct { []const u8, Sketch, u8, DecodeError };
    const cases = [_]Case{
        .{ "a broken sync pattern", .{ .sync = 0x564343 }, 1, error.InvalidSound },
        .{ "no dimensions", .{ .dimensions = 0 }, 1, error.InvalidSound },
        .{ "an overspecified tree", .{ .lengths = &.{ 1, 1, 1 } }, 1, error.InvalidSound },
        .{ "an underspecified tree", .{ .lengths = &.{ 1, 2 } }, 1, error.InvalidSound },
        .{ "lookup type 3", .{ .lookup = 3 }, 1, error.InvalidSound },
        .{ "an infinite value", .{ .minimum = (1023 << 21) | 0x1f_ffff }, 1, error.InvalidSound },
        .{ "a time transform", .{ .time = 1 }, 1, error.InvalidSound },
        .{ "floor 0", .{ .floor_kind = 0 }, 1, error.UnsupportedSound },
        .{ "floor type 2", .{ .floor_kind = 2 }, 1, error.InvalidSound },
        .{ "two floor points at one x", .{ .floor_x = &.{ 9, 9 } }, 1, error.InvalidSound },
        .{ "a floor point at x[0]", .{ .floor_x = &.{ 0, 9 } }, 1, error.InvalidSound },
        .{ "a floor book past the count", .{ .floor_book = 3 }, 1, error.InvalidSound },
        .{ "residue type 3", .{ .residue_kind = 3 }, 1, error.InvalidSound },
        .{ "a residue book past the count", .{ .residue_book = 2 }, 1, error.InvalidSound },
        .{ "a residue book with no values", .{ .residue_book = 0 }, 1, error.InvalidSound },
        .{ "mapping type 1", .{ .mapping_kind = 1 }, 1, error.InvalidSound },
        .{ "a channel coupled with itself", .{ .coupling = .{ 1, 1 } }, 2, error.InvalidSound },
        .{ "mono coupling", .{ .coupling = .{ 0, 0 } }, 1, error.InvalidSound },
        .{ "a reserved field set", .{ .reserved = 1 }, 1, error.InvalidSound },
        .{ "a mapping floor past the count", .{ .mapping_floor = 1 }, 1, error.InvalidSound },
        .{ "a mapping residue past the count", .{ .mapping_residue = 1 }, 1, error.InvalidSound },
        .{ "a window type", .{ .window = 1 }, 1, error.InvalidSound },
        .{ "a mode mapping past the count", .{ .mode_mapping = 1 }, 1, error.InvalidSound },
        .{ "no framing bit", .{ .framing = 0 }, 1, error.InvalidSound },
    };
    for (cases) |case| {
        const outcome = case[1].parse(case[2]);
        if (outcome) |ok| {
            var s = ok;
            s.deinit();
            std.debug.print("case: {s} parsed\n", .{case[0]});
            return error.TestUnexpectedResult;
        } else |err| testing.expectEqual(case[3], err) catch |e| {
            std.debug.print("case: {s}\n", .{case[0]});
            return e;
        };
    }
}

test "a setup cut short is refused at every length" {
    var w: BitWriter = .{};
    defer w.deinit();
    try (Sketch{}).write(&w, 1);
    const info: Info = .{ .channels = 1, .sample_rate = 44100, .blocksize = .{ 256, 2048 } };
    for (0..w.bytes.items.len) |n| {
        try testing.expectError(error.InvalidSound, parseSetup(testing.allocator, w.bytes.items[0..n], info, .{}));
    }
    // And every real setup, cut short.
    var packets: ogg.Packets = .init(ogg.fixtures[2].ogg);
    defer packets.deinit(testing.allocator);
    const real_info = try parseIdentification((try packets.next(testing.allocator)).?.data);
    _ = try packets.next(testing.allocator);
    const setup = (try packets.next(testing.allocator)).?.data;
    var n: usize = 0;
    while (n < setup.len) : (n += 97) {
        try testing.expectError(error.InvalidSound, parseSetup(testing.allocator, setup[0..n], real_info, .{}));
    }
}

test "the setup's memory is bounded before it is allocated" {
    // Codebook 0 of a real setup asks for far more than eight bytes.
    var packets: ogg.Packets = .init(ogg.fixtures[0].ogg);
    defer packets.deinit(testing.allocator);
    const info = try parseIdentification((try packets.next(testing.allocator)).?.data);
    _ = try packets.next(testing.allocator);
    const setup = (try packets.next(testing.allocator)).?.data;
    try testing.expectError(error.SoundTooLarge, parseSetup(testing.failing_allocator, setup, info, .{ .max_setup_bytes = 8 }));
}

fn identification(version: u32, channels: u8, rate: u32, b0: u4, b1: u4, framing_bit: u1) ![]u8 {
    var w: BitWriter = .{};
    errdefer w.deinit();
    for ("\x01vorbis") |c| try w.write(c, 8);
    try w.write(version, 32);
    try w.write(channels, 8);
    try w.write(rate, 32);
    for (0..3) |_| try w.write(0, 32); // Three bitrates.
    try w.write(b0, 4);
    try w.write(b1, 4);
    try w.write(framing_bit, 1);
    return w.bytes.toOwnedSlice(testing.allocator);
}

test "the identification header's refusals" {
    const Case = struct { u32, u8, u32, u4, u4, u1, ?DecodeError };
    const cases = [_]Case{
        .{ 0, 2, 48000, 8, 11, 1, null },
        .{ 1, 2, 48000, 8, 11, 1, error.UnsupportedSound },
        .{ 0, 0, 48000, 8, 11, 1, error.InvalidSound },
        .{ 0, 3, 48000, 8, 11, 1, error.UnsupportedSound },
        .{ 0, 2, 0, 8, 11, 1, error.InvalidSound },
        .{ 0, 2, 192_001, 8, 11, 1, error.UnsupportedSound },
        .{ 0, 2, 48000, 5, 11, 1, error.InvalidSound },
        .{ 0, 2, 48000, 8, 14, 1, error.InvalidSound },
        .{ 0, 2, 48000, 11, 8, 1, error.InvalidSound },
        .{ 0, 2, 48000, 8, 11, 0, error.InvalidSound },
    };
    for (cases) |c| {
        const packet = try identification(c[0], c[1], c[2], c[3], c[4], c[5]);
        defer testing.allocator.free(packet);
        if (c[6]) |expected| {
            try testing.expectError(expected, parseIdentification(packet));
        } else {
            const info = try parseIdentification(packet);
            try testing.expectEqual([2]u16{ 256, 2048 }, info.blocksize);
        }
    }
    try testing.expectError(error.InvalidSound, parseIdentification("\x03vorbis"));
}

test "the comment header is checked for framing and its lengths, and nothing else" {
    var w: BitWriter = .{};
    defer w.deinit();
    for ("\x03vorbis") |c| try w.write(c, 8);
    try w.write(3, 32);
    for ("abc") |c| try w.write(c, 8);
    try w.write(1, 32);
    try w.write(5, 32);
    for ("A=b c") |c| try w.write(c, 8);
    try w.write(1, 1);
    try parseComment(w.bytes.items);
    // A comment longer than the header, and a missing framing bit.
    var long = try testing.allocator.dupe(u8, w.bytes.items);
    defer testing.allocator.free(long);
    long[18] = 200;
    try testing.expectError(error.InvalidSound, parseComment(long));
    try testing.expectError(error.InvalidSound, parseComment(w.bytes.items[0 .. w.bytes.items.len - 1]));
}

test "another codec, no frames and too many frames are refused before any header is read" {
    const gpa = testing.allocator;
    // The last page's granule, rewritten with its CRC.
    const f = ogg.fixtures[2].ogg;
    var copy = try gpa.dupe(u8, f);
    defer gpa.free(copy);
    var pos: usize = 0;
    var last: usize = 0;
    while (pos < copy.len) {
        last = pos;
        pos += (try ogg.parsePage(copy[pos..])).size;
    }
    const page = copy[last..];
    for ([_]struct { u64, DecodeError }{ .{ 0, error.InvalidSound }, .{ (1 << 24) + 1, error.SoundTooLarge } }) |c| {
        std.mem.writeInt(u64, page[6..14], c[0], .little);
        std.mem.writeInt(u32, page[22..26], 0, .little);
        std.mem.writeInt(u32, page[22..26], ogg.crc32(page), .little);
        // A granule of 0 on the last page goes backwards from the pages before it.
        try testing.expectError(if (c[0] == 0) error.InvalidSound else c[1], readHeaders(testing.failing_allocator, copy, .{}));
    }
    // An Opus stream's first page is named, and nothing is allocated.
    var opus = try gpa.dupe(u8, f[0..58]);
    defer gpa.free(opus);
    @memcpy(opus[28..36], "OpusHead");
    opus[5] |= 0x04;
    std.mem.writeInt(u32, opus[22..26], 0, .little);
    std.mem.writeInt(u32, opus[22..26], ogg.crc32(opus), .little);
    try testing.expectError(error.UnsupportedSound, readHeaders(testing.failing_allocator, opus, .{}));
}
