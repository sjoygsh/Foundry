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
//! checked against the count it indexes. Step 3 decodes the audio packets: floor curves,
//! residues, inverse coupling, the inverse MDCT, overlap-add and granule trimming.
//!
//! **Where the specification leaves room, this follows libvorbis 1.3.7**, the oracle the tests
//! compare against: how a packet that ends early is treated, how a single-entry codebook
//! decodes, how floor values are masked and clamped, and how type 2 residue de-interleaves.
//! Each place says so.
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
const Sound = @import("sound.zig").Sound;

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
    /// Indexed by the next `table_bits` bits of a packet, least significant first: an entry and
    /// its length, a node of `tree` to continue from, or `no_code` (`decodeEntry`).
    table: []const u32,
    table_bits: u6,
    /// The Huffman tree, for codewords longer than `table_bits`. Node 0 is the root; a child is
    /// a node index above 0, `missing`, or an entry `e` stored as `-(e + 2)`.
    tree: []const [2]i32,

    pub const no_code = 0xffff_ffff;
    pub const long_code = 0x8000_0000;
    pub const missing = -1;
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
    /// `classifications ^ classbook dimensions`: the classbook entries that name a
    /// classification for each partition of a word. A larger entry ends the residue, as it
    /// does in libvorbis.
    partvals: u32,
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

/// What the inverse MDCT and the window need for one block size, computed once at setup with
/// `core.math.trig`, so a decode is the same bytes in every optimization mode (`music.md` §3.3).
pub const Block = struct {
    /// The block size `n`, in frames.
    n: u16,
    /// `e^(−iπ(k + 1/8)/(n/2))` for `k < n/4`, as `{cos, sin}`: the twiddle applied before
    /// and after the FFT.
    twiddle: []const [2]f32,
    /// `e^(−2πik/(n/4))` for `k < n/8`: the FFT's roots.
    roots: []const [2]f32,
    /// The bit-reversal permutation of `n/4` indices.
    bitrev: []const u16,
    /// The rising slope of the window over `n/2` frames: `sin(π/2 · sin²((i + ½)/(n/2) · π/2))`.
    /// The falling slope is the same table read backwards.
    window: []const f32,
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
    /// The short block's tables and the long block's.
    blocks: [2]Block,

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
    // Before the arena is copied out below, so it holds these allocations too.
    const blocks: [2]Block = .{ try buildBlock(&budget, info.blocksize[0]), try buildBlock(&budget, info.blocksize[1]) };

    return .{
        .arena = arena,
        .codebooks = codebooks,
        .floors = floors,
        .residues = residues,
        .mappings = mappings,
        .modes = modes,
        .blocks = blocks,
    };
}

fn buildBlock(budget: *Budget, n: u16) DecodeError!Block {
    const quarter = n / 4;
    const twiddle = try budget.alloc([2]f32, quarter);
    for (twiddle, 0..) |*t, k| t.* = turns(-(@as(f64, @floatFromInt(k)) + 0.125) / @as(f64, @floatFromInt(n)));
    const roots = try budget.alloc([2]f32, quarter / 2);
    for (roots, 0..) |*r, k| r.* = turns(-@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(quarter)));
    const bitrev = try budget.alloc(u16, quarter);
    const width = ilog(quarter) - 1;
    for (bitrev, 0..) |*b, k| b.* = @intCast(@bitReverse(@as(u16, @intCast(k))) >> @intCast(16 - @as(u6, width)));
    const window = try budget.alloc(f32, n / 2);
    for (window, 0..) |*w, i| {
        const s = core.math.trig.sinCosTurns((@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(2 * n)))[0];
        w.* = @floatCast(core.math.trig.sinCosTurns(s * s / 4)[0]);
    }
    return .{ .n = n, .twiddle = twiddle, .roots = roots, .bitrev = bitrev, .window = window };
}

/// `{cos, sin}` of a fraction of a turn, in `f32`.
fn turns(t: f64) [2]f32 {
    const sc = core.math.trig.sinCosTurns(t);
    return .{ @floatCast(sc[1]), @floatCast(sc[0]) };
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
    var book: Codebook = .{
        .dimensions = dimensions,
        .entries = entries,
        .lengths = lengths,
        .codewords = codewords,
        .used = used,
        .values = values,
        .table = &.{},
        .table_bits = 0,
        .tree = &.{},
    };
    try buildDecoder(&book, budget, index);
    return book;
}

/// The longest codeword the first-stage table resolves directly.
const max_table_bits = 10;

/// Builds a checked tree's decoding table and tree. The tree is complete or a single entry
/// (`assignCodewords`), so it has exactly `used − 1` internal nodes.
fn buildDecoder(book: *Codebook, budget: *Budget, index: usize) DecodeError!void {
    if (book.used == 0) return;
    if (book.used == 1) {
        // libvorbis reads one bit for a single-entry book and returns the entry whatever the
        // bit was: both halves of a one-bit table name it.
        const entry: u32 = @intCast(std.mem.indexOfNone(u8, book.lengths, &.{0}).?);
        const table = try budget.alloc(u32, 2);
        @memset(table, entry | (1 << 24));
        book.table = table;
        book.table_bits = 1;
        return;
    }
    const tree = try budget.alloc([2]i32, book.used - 1);
    tree[0] = .{ Codebook.missing, Codebook.missing };
    var nodes: usize = 1;
    var longest: u8 = 0;
    for (book.lengths, book.codewords, 0..) |length, codeword, entry| {
        if (length == 0) continue;
        longest = @max(longest, length);
        var node: usize = 0;
        for (0..length) |k| {
            const bit = (codeword >> @intCast(k)) & 1;
            const child = tree[node][bit];
            if (k + 1 == length) {
                if (child != Codebook.missing) return invalid("codebook {d}'s codewords collide", .{index});
                tree[node][bit] = -@as(i32, @intCast(entry)) - 2;
            } else if (child == Codebook.missing) {
                if (nodes == tree.len) return invalid("codebook {d}'s codewords collide", .{index});
                tree[nodes] = .{ Codebook.missing, Codebook.missing };
                tree[node][bit] = @intCast(nodes);
                node = nodes;
                nodes += 1;
            } else if (child < 0) {
                return invalid("codebook {d}'s codewords collide", .{index});
            } else node = @intCast(child);
        }
    }
    const bits_: u6 = @intCast(@min(longest, max_table_bits));
    const table = try budget.alloc(u32, @as(u64, 1) << bits_);
    for (table, 0..) |*slot, i| {
        var node: usize = 0;
        slot.* = for (0..bits_) |k| {
            const child = tree[node][(i >> @intCast(k)) & 1];
            if (child == Codebook.missing) break Codebook.no_code;
            if (child < 0) break @as(u32, @intCast(-child - 2)) | (@as(u32, @intCast(k + 1)) << 24);
            node = @intCast(child);
        } else Codebook.long_code | @as(u32, @intCast(node));
    }
    book.table = table;
    book.table_bits = bits_;
    book.tree = tree;
}

/// Assigns each used entry the lowest free codeword of its length, in entry order, as
/// Vorbis I §3.2.1 does, and refuses a tree that is overspecified (a codeword with no room
/// left) or underspecified (a codeword nobody holds), except a book whose one used entry has
/// a one-bit codeword, the only single-entry book libvorbis accepts. Returns the number of
/// used entries.
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
    const single = used == 1 and available[1] != 0 and available[2] == 0;
    if (!single) for (available[1..]) |a| if (a != 0) {
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
        .partvals = 0,
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

    // libvorbis refuses a classbook too small to name every classification of a word.
    const entries = codebooks[classbook].entries;
    var partvals: u64 = 1;
    for (0..codebooks[classbook].dimensions) |_| {
        partvals *= residue.classifications;
        if (partvals > entries) return invalid("residue {d}'s classbook cannot name its classifications", .{index});
    }
    residue.partvals = @intCast(partvals);
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

// -- audio packets ----------------------------------------------------------------------------

/// An audio packet's bits, least significant first, read through a 64-bit window. Running out
/// is final, and in an audio packet it is not an error: Vorbis I §4.3 and libvorbis both stop
/// the floor or the residue being read and keep what was decoded.
const Reader = struct {
    bytes: []const u8,
    next: usize = 0,
    window: u64 = 0,
    count: u7 = 0,

    fn refill(self: *Reader) void {
        while (self.count <= 56 and self.next < self.bytes.len) {
            self.window |= @as(u64, self.bytes[self.next]) << @intCast(self.count);
            self.count += 8;
            self.next += 1;
        }
    }

    fn available(self: *const Reader) usize {
        return self.count + (self.bytes.len - self.next) * 8;
    }

    fn read(self: *Reader, n: u6) Bits.Error!u32 {
        if (n == 0) return 0;
        self.refill();
        if (self.count < n) {
            self.next = self.bytes.len;
            self.count = 0;
            return error.EndOfPacket;
        }
        const value = self.window & ((@as(u64, 1) << n) - 1);
        self.window >>= n;
        self.count -= n;
        return @intCast(value);
    }

    /// The next `n` bits without consuming them, zero past the end.
    fn peek(self: *Reader, n: u6) u32 {
        self.refill();
        return @intCast(self.window & ((@as(u64, 1) << n) - 1));
    }

    fn consume(self: *Reader, n: u6) void {
        std.debug.assert(n <= self.count);
        self.window >>= n;
        self.count -= n;
    }
};

/// The next entry a codebook decodes, or null where libvorbis returns −1: the packet ran out,
/// or the bits name no codeword. A codeword is resolved by the first-stage table when it is
/// short, and by walking the tree from the table's node when it is not.
fn decodeEntry(book: *const Codebook, r: *Reader) ?u32 {
    if (book.used == 0) return null;
    const avail = r.available();
    const slot = book.table[r.peek(book.table_bits)];
    if (slot == Codebook.no_code) return null;
    if (slot & Codebook.long_code == 0) {
        const length: u6 = @intCast(slot >> 24);
        if (length > avail) return null;
        r.consume(length);
        return slot & 0xff_ffff;
    }
    if (avail < book.table_bits) return null;
    r.consume(book.table_bits);
    var node: usize = slot & ~@as(u32, Codebook.long_code);
    while (true) {
        const child = book.tree[node][r.read(1) catch return null];
        if (child == Codebook.missing) return null;
        if (child < 0) return @intCast(-child - 2);
        node = @intCast(child);
    }
}

/// libvorbis's `FLOOR1_fromdB_LOOKUP`, the specification's `floor1_inverse_dB_table`
/// (Vorbis I §10.1), as the reference writes its 256 constants.
const inverse_db = [256]f32{
    1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07,
    1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
    1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.128753e-07,
    2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
    2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07,
    3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
    4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07,
    6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
    7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07,
    1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
    1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06,
    1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
    2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06,
    2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
    3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06,
    4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
    5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06,
    7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
    9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05,
    1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
    1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05,
    2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
    2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05,
    3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
    4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05,
    5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
    7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05,
    9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
    0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085,
    0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
    0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449,
    0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
    0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456,
    0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
    0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058,
    0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
    0.00092223983, 0.00098217216, 0.0010459992,  0.0011139742,
    0.0011863665,  0.0012634633,  0.0013455702,  0.0014330129,
    0.0015261382,  0.0016253153,  0.0017309374,  0.0018434235,
    0.0019632195,  0.0020908006,  0.0022266726,  0.0023713743,
    0.0025254795,  0.0026895994,  0.0028643847,  0.0030505286,
    0.0032487691,  0.0034598925,  0.0036847358,  0.0039241906,
    0.0041792066,  0.0044507950,  0.0047400328,  0.0050480668,
    0.0053761186,  0.0057254891,  0.0060975636,  0.0064938176,
    0.0069158225,  0.0073652516,  0.0078438871,  0.0083536271,
    0.0088964928,  0.009474637,   0.010090352,   0.010746080,
    0.011444421,   0.012188144,   0.012980198,   0.013823725,
    0.014722068,   0.015678791,   0.016697687,   0.017782797,
    0.018938423,   0.020169149,   0.021479854,   0.022875735,
    0.024362330,   0.025945531,   0.027631618,   0.029427276,
    0.031339626,   0.033376252,   0.035545228,   0.037855157,
    0.040315199,   0.042935108,   0.045725273,   0.048696758,
    0.051861348,   0.055231591,   0.058820850,   0.062643361,
    0.066714279,   0.071049749,   0.075666962,   0.080584227,
    0.085821044,   0.091398179,   0.097337747,   0.10366330,
    0.11039993,    0.11757434,    0.12521498,    0.13335215,
    0.14201813,    0.15124727,    0.16107617,    0.17154380,
    0.18269168,    0.19456402,    0.20720788,    0.22067342,
    0.23501402,    0.25028656,    0.26655159,    0.28387361,
    0.30232132,    0.32196786,    0.34289114,    0.36517414,
    0.38890521,    0.41417847,    0.44109412,    0.46975890,
    0.50028648,    0.53279791,    0.56742212,    0.60429640,
    0.64356699,    0.68538959,    0.72993007,    0.77736504,
    0.82788260,    0.88168307,    0.9389798,     1.0,
};

/// Floor 1's packet decode and amplitude synthesis (Vorbis I §7.2.3, §7.2.4 step 1), as
/// libvorbis's `floor1_inverse1` computes it: values masked to 15 bits, and bit 15 marking a
/// point the curve does not pass through. False when the floor is unused, or the packet ran
/// out inside it.
fn decodeFloor(floor: *const Floor1, books: []const Codebook, r: *Reader, fit: []i32) bool {
    if ((r.read(1) catch return false) == 0) return false;
    const range: i32 = ([4]i32{ 256, 128, 86, 64 })[floor.multiplier - 1];
    const ybits = ilog(@intCast(range - 1));
    fit[0] = @intCast(r.read(ybits) catch return false);
    fit[1] = @intCast(r.read(ybits) catch return false);
    var j: usize = 2;
    for (floor.partition_class) |class| {
        const cdim = floor.class_dimensions[class];
        const cbits: u5 = @intCast(floor.class_subclasses[class]);
        var cval: u32 = 0;
        if (cbits > 0) cval = decodeEntry(&books[floor.class_masterbook[class]], r) orelse return false;
        for (0..cdim) |k| {
            const book = floor.subclass_books[class][cval & ((@as(u32, 1) << cbits) - 1)];
            cval >>= cbits;
            fit[j + k] = if (book >= 0) @intCast(decodeEntry(&books[@intCast(book)], r) orelse return false) else 0;
        }
        j += cdim;
    }
    for (2..floor.x.len) |i| {
        const lo = floor.low_neighbor[i];
        const hi = floor.high_neighbor[i];
        const predicted = renderPoint(floor.x[lo], floor.x[hi], fit[lo], fit[hi], floor.x[i]);
        const hiroom = range - predicted;
        const loroom = predicted;
        const room = @min(hiroom, loroom) * 2;
        var val = fit[i];
        if (val != 0) {
            if (val >= room) {
                val = if (hiroom > loroom) val - loroom else -1 - (val - hiroom);
            } else {
                val = if (val & 1 != 0) -((val + 1) >> 1) else val >> 1;
            }
            fit[i] = (val + predicted) & 0x7fff;
            fit[lo] &= 0x7fff;
            fit[hi] &= 0x7fff;
        } else fit[i] = predicted | 0x8000;
    }
    return true;
}

fn renderPoint(x0: u16, x1: u16, y0_: i32, y1_: i32, x: u16) i32 {
    const y0 = y0_ & 0x7fff;
    const y1 = y1_ & 0x7fff;
    const dy = y1 - y0;
    const adx = @as(i32, x1) - x0;
    const err = @as(i32, @intCast(@abs(dy))) * (@as(i32, x) - x0);
    const off = @divTrunc(err, adx);
    return if (dy < 0) y0 - off else y0 + off;
}

/// Multiplies a spectrum by the floor's curve (Vorbis I §7.2.4 step 2), as libvorbis's
/// `floor1_inverse2` does, with each value clamped to the table before it is looked up.
fn applyFloor(floor: *const Floor1, fit: []const i32, spectrum: []f32) void {
    const mult: i32 = floor.multiplier;
    var hx: usize = 0;
    var lx: usize = 0;
    var ly = std.math.clamp(fit[0] * mult, 0, 255);
    for (floor.sorted[1..]) |current| {
        var hy = fit[current] & 0x7fff;
        if (hy != fit[current]) continue;
        hx = floor.x[current];
        hy = std.math.clamp(hy * mult, 0, 255);
        renderLine(spectrum, lx, hx, ly, hy);
        lx = hx;
        ly = hy;
    }
    if (hx < spectrum.len) for (spectrum[hx..]) |*s| {
        s.* *= inverse_db[@intCast(ly)];
    };
}

fn renderLine(d: []f32, x0: usize, x1: usize, y0: i32, y1: i32) void {
    const dy = y1 - y0;
    const adx: i32 = @intCast(x1 - x0);
    const base = @divTrunc(dy, adx);
    const sy = if (dy < 0) base - 1 else base + 1;
    const ady = @as(i32, @intCast(@abs(dy))) - @as(i32, @intCast(@abs(base * adx)));
    const n = @min(d.len, x1);
    var x = x0;
    var y = y0;
    var err: i32 = 0;
    if (x < n) d[x] *= inverse_db[@intCast(y)];
    x += 1;
    while (x < n) : (x += 1) {
        err += ady;
        if (err >= adx) {
            err -= adx;
            y += sy;
        } else y += base;
        d[x] *= inverse_db[@intCast(y)];
    }
}

/// One partition of a residue's vectors (Vorbis I §8.6.3–8.6.5), bounded as libvorbis
/// bounds it. False when the packet ran out. A book with no used entries reads nothing and
/// adds nothing, as libvorbis's does.
fn decodePartition(kind: u2, book: *const Codebook, r: *Reader, vectors: []const []f32, offset: usize, n: usize, entries: []u32) bool {
    if (book.used == 0) return true;
    const dims: usize = book.dimensions;
    const values = book.values.?;
    switch (kind) {
        0 => {
            const v = vectors[0][offset..][0..n];
            const step = n / dims;
            for (entries[0..step]) |*e| e.* = decodeEntry(book, r) orelse return false;
            for (0..dims) |i| {
                const o = i * step;
                for (entries[0..step], 0..) |e, j| {
                    if (o + j >= n) break;
                    v[o + j] += values[e * dims + i];
                }
            }
        },
        1 => {
            const v = vectors[0][offset..][0..n];
            var i: usize = 0;
            while (i < n) {
                const e = decodeEntry(book, r) orelse return false;
                for (values[e * dims ..][0..dims]) |t| {
                    if (i == n) break;
                    v[i] += t;
                    i += 1;
                }
            }
        },
        2 => {
            // libvorbis de-interleaves from frame `offset / channels`, starting at channel 0.
            const ch = vectors.len;
            var i = offset / ch;
            const m = (offset + n) / ch;
            var c: usize = 0;
            while (i < m) {
                const e = decodeEntry(book, r) orelse return false;
                for (values[e * dims ..][0..dims]) |t| {
                    if (i == m) break;
                    vectors[c][i] += t;
                    c += 1;
                    if (c == ch) {
                        c = 0;
                        i += 1;
                    }
                }
            }
        },
        3 => unreachable,
    }
    return true;
}

/// A residue's vectors (Vorbis I §8.6.2), as libvorbis's `_01inverse` and `res2_inverse`
/// decode them. `vectors` are the submap's channels, each `half` long and zeroed, and
/// `nonzero` marks which to decode. Running out of packet stops the residue, keeping what
/// was decoded.
fn decodeResidue(residue: *const Residue, books: []const Codebook, r: *Reader, vectors: []const []f32, nonzero: []const bool, half: usize, scratch: *Scratch) void {
    var used_buf: [max_channels][]f32 = undefined;
    var used: []const []f32 = undefined;
    var max = half;
    if (residue.kind == 2) {
        if (std.mem.indexOfScalar(bool, nonzero, true) == null) return;
        used = vectors;
        max = half * vectors.len;
    } else {
        var count: usize = 0;
        for (vectors, nonzero) |v, z| if (z) {
            used_buf[count] = v;
            count += 1;
        };
        if (count == 0) return;
        used = used_buf[0..count];
    }
    const end = @min(residue.end, max);
    if (end <= residue.begin) return;
    const n = end - residue.begin;
    const psize = residue.partition_size;
    const partvals = n / psize;
    const classbook = &books[residue.classbook];
    const per_word: usize = classbook.dimensions;
    const rows: usize = if (residue.kind == 2) 1 else used.len;
    const classes = scratch.classes;

    for (0..8) |stage| {
        var i: usize = 0;
        while (i < partvals) {
            if (stage == 0) for (0..rows) |j| {
                var temp = decodeEntry(classbook, r) orelse return;
                if (temp >= residue.partvals) return;
                // The word's classifications, most significant first.
                var k = per_word;
                while (k > 0) {
                    k -= 1;
                    const digit: u8 = @intCast(temp % residue.classifications);
                    temp /= residue.classifications;
                    if (i + k < partvals) classes[j][i + k] = digit;
                }
            };
            var k: usize = 0;
            while (k < per_word and i < partvals) : ({
                k += 1;
                i += 1;
            }) {
                const offset = residue.begin + i * psize;
                for (0..rows) |j| {
                    const book = residue.books[classes[j][i]][stage];
                    if (book < 0) continue;
                    const targets = if (residue.kind == 2) used else used[j..][0..1];
                    if (!decodePartition(residue.kind, &books[@intCast(book)], r, targets, offset, psize, scratch.entries)) return;
                }
            }
        }
    }
}

/// An in-place radix-2 FFT of `n/4` points, forward (`e^(−2πijk/N)`).
fn fft(block: *const Block, re: []f32, im: []f32) void {
    const len = re.len;
    for (block.bitrev, 0..) |j, i| if (j > i) {
        std.mem.swap(f32, &re[i], &re[j]);
        std.mem.swap(f32, &im[i], &im[j]);
    };
    var size: usize = 2;
    while (size <= len) : (size *= 2) {
        const half = size / 2;
        const step = len / size;
        var start: usize = 0;
        while (start < len) : (start += size) {
            for (0..half) |k| {
                const w = block.roots[k * step];
                const a = start + k;
                const b = a + half;
                const tr = re[b] * w[0] - im[b] * w[1];
                const ti = re[b] * w[1] + im[b] * w[0];
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
    }
}

/// The inverse MDCT of `n/2` coefficients into `n` samples, unscaled as libvorbis's
/// `mdct_backward` is: `y[i] = Σ X[k]·cos(2π/n · (i + ½ + n/4)(k + ½))`. It is a DCT-IV of
/// size `n/2`, computed with an `n/4`-point complex FFT between two twiddles, then unfolded
/// by the DCT-IV's symmetries.
fn imdct(block: *const Block, x: []const f32, y: []f32, scratch: *Scratch) void {
    const n: usize = block.n;
    const half = n / 2;
    const quarter = n / 4;
    const re = scratch.re[0..quarter];
    const im = scratch.im[0..quarter];
    const u = scratch.u[0..half];
    for (block.twiddle, 0..) |t, k| {
        const a = x[2 * k];
        const b = x[half - 1 - 2 * k];
        re[k] = a * t[0] - b * t[1];
        im[k] = a * t[1] + b * t[0];
    }
    fft(block, re, im);
    for (block.twiddle, 0..) |t, p| {
        u[2 * p] = re[p] * t[0] - im[p] * t[1];
        u[half - 1 - 2 * p] = -(re[p] * t[1] + im[p] * t[0]);
    }
    for (0..quarter) |i| y[i] = u[i + quarter];
    for (quarter..3 * quarter) |i| y[i] = -u[3 * quarter - 1 - i];
    for (3 * quarter..n) |i| y[i] = -u[i - 3 * quarter];
}

/// Working memory for one stream's decode, sized once from the long block.
const Scratch = struct {
    /// Residue classifications, a row per channel, one per partition.
    classes: [max_channels][]u8,
    /// A type 0 partition's entries, read before any is added, as libvorbis reads them.
    entries: []u32,
    re: []f32,
    im: []f32,
    u: []f32,
};

/// Decodes a checked stream's audio into frames, packet by packet: Vorbis I §4.3, and
/// libvorbis's `vorbis_synthesis_blockin` for the overlap and the granule's trims. It borrows
/// the bytes and the headers, and owns a few long blocks of memory per channel.
///
/// It produces exactly `Headers.frames` frames or refuses the stream: a stream whose packets
/// hold fewer frames than its last granule claims, or more, is `InvalidSound`, and so is a
/// sample that is not finite.
pub const Decoder = struct {
    gpa: Allocator,
    headers: *const Headers,
    packets: ogg.Packets,
    buffer: []f32,
    classes: []u8,
    entries: []u32,
    /// Per channel: the spectrum, the inverse MDCT's output, and the previous block's second
    /// half, still to be overlapped.
    spectrum: [max_channels][]f32,
    pcm: [max_channels][]f32,
    previous: [max_channels][]f32,
    /// Frames ready to be read, interleaved, and how far reading has got through them.
    ready: []f32,
    ready_frames: usize = 0,
    ready_read: usize = 0,
    scratch: Scratch,
    /// The previous block's size, or 0 before the first audio packet.
    previous_n: u16 = 0,
    /// libvorbis's `sample_count` and `granulepos`: frames the packets have made so far, and
    /// the stream position once a granule has given one.
    made: ?u64 = null,
    position: ?u64 = null,
    emitted: u64 = 0,
    done: bool = false,

    pub fn init(gpa: Allocator, bytes: []const u8, headers: *const Headers) DecodeError!Decoder {
        const ch = headers.info.channels;
        const long: usize = headers.info.blocksize[1];
        // spectrum, pcm, previous, ready, then u, re, im.
        const per_channel = long / 2 + long + long / 2 + long / 2;
        const buffer = try gpa.alloc(f32, per_channel * ch + long / 2 + long / 2);
        errdefer gpa.free(buffer);
        @memset(buffer, 0);
        const classes = try gpa.alloc(u8, long * max_channels);
        errdefer gpa.free(classes);
        const entries = try gpa.alloc(u32, long / 2);
        errdefer gpa.free(entries);

        var self: Decoder = .{
            .gpa = gpa,
            .headers = headers,
            .packets = .init(bytes),
            .buffer = buffer,
            .classes = classes,
            .entries = entries,
            .spectrum = undefined,
            .pcm = undefined,
            .previous = undefined,
            .ready = undefined,
            .scratch = undefined,
        };
        var rest = buffer;
        for (0..ch) |c| {
            self.spectrum[c] = take(&rest, long / 2);
            self.pcm[c] = take(&rest, long);
            self.previous[c] = take(&rest, long / 2);
        }
        self.ready = take(&rest, long / 2 * ch);
        self.scratch.u = take(&rest, long / 2);
        self.scratch.re = take(&rest, long / 4);
        self.scratch.im = take(&rest, long / 4);
        self.scratch.classes = .{ classes[0..long], classes[long..] };
        self.scratch.entries = entries;
        errdefer self.packets.deinit(gpa);
        // The three headers, already checked by `readHeaders`.
        for (0..3) |_| _ = try self.packets.next(gpa) orelse return invalid("the stream ends inside its headers", .{});
        return self;
    }

    /// Makes sure no later packet needs memory: `bytes` is the most a packet spanning pages
    /// has needed, which `prove` measured. A stream's decode task then never allocates, and so
    /// never fails for memory (`music.md` §6.1).
    pub fn reserve(self: *Decoder, bytes: usize) Allocator.Error!void {
        try self.packets.spanning.ensureTotalCapacity(self.gpa, bytes);
    }

    /// Starts again at the first audio packet, as a loop does (`music.md` §6.4). The new pass
    /// overlaps from silence as the file's own start does, so it is exactly the stream's
    /// length again. Allocates nothing once `reserve` has been called.
    pub fn rewind(self: *Decoder) DecodeError!void {
        var spanning = self.packets.spanning;
        spanning.clearRetainingCapacity();
        self.packets = .init(self.packets.bytes);
        self.packets.spanning = spanning;
        self.ready_frames = 0;
        self.ready_read = 0;
        self.previous_n = 0;
        self.made = null;
        self.position = null;
        self.emitted = 0;
        self.done = false;
        for (0..3) |_| _ = try self.packets.next(self.gpa) orelse return invalid("the stream ends inside its headers", .{});
    }

    fn take(rest: *[]f32, n: usize) []f32 {
        const out = rest.*[0..n];
        rest.* = rest.*[n..];
        return out;
    }

    pub fn deinit(self: *Decoder) void {
        self.packets.deinit(self.gpa);
        self.gpa.free(self.buffer);
        self.gpa.free(self.classes);
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    /// Up to `out.len / channels` frames, interleaved, into `out`; 0 once every frame has been
    /// read, which is checked against the stream's length then.
    pub fn read(self: *Decoder, out: []f32) DecodeError!usize {
        const ch = self.headers.info.channels;
        std.debug.assert(out.len % ch == 0);
        while (self.ready_read == self.ready_frames) {
            if (self.done) return 0;
            self.ready_frames = 0;
            self.ready_read = 0;
            const packet = try self.packets.next(self.gpa) orelse {
                self.done = true;
                if (self.emitted != self.headers.frames) {
                    return invalid("the stream's packets hold {d} frames, and its last granule claims {d}", .{ self.emitted, self.headers.frames });
                }
                return 0;
            };
            try self.decodePacket(packet);
            if (self.emitted + (self.ready_frames - self.ready_read) > self.headers.frames) {
                return invalid("the stream's packets hold more frames than its last granule claims", .{});
            }
        }
        const frames = @min(self.ready_frames - self.ready_read, out.len / ch);
        const from = self.ready[self.ready_read * ch ..][0 .. frames * ch];
        for (from) |s| if (!std.math.isFinite(s)) return invalid("a decoded sample is not finite", .{});
        @memcpy(out[0 .. frames * ch], from);
        self.ready_read += frames;
        self.emitted += frames;
        return frames;
    }

    fn decodePacket(self: *Decoder, packet: ogg.Packet) DecodeError!void {
        // An empty packet is dropped, as libvorbis drops one: it is not audio.
        if (packet.data.len == 0) return;
        const info = self.headers.info;
        const setup = &self.headers.setup;
        const ch = info.channels;
        var r: Reader = .{ .bytes = packet.data };
        if ((r.read(1) catch 1) != 0) return invalid("a header packet sits among the audio packets", .{});
        const mode_index = r.read(ilog(@intCast(setup.modes.len - 1))) catch return invalid("an audio packet ends inside its mode", .{});
        if (mode_index >= setup.modes.len) return invalid("an audio packet names mode {d} of {d}", .{ mode_index, setup.modes.len });
        const mode = setup.modes[mode_index];
        const block = &setup.blocks[@intFromBool(mode.long_block)];
        const n: usize = block.n;
        const half = n / 2;
        if (mode.long_block) {
            // The neighbours' window flags. libvorbis shapes the overlap from the blocks'
            // actual sizes instead, and so does this.
            _ = r.read(2) catch return invalid("an audio packet ends inside its window flags", .{});
        }
        const mapping = &setup.mappings[mode.mapping];

        var fit: [max_channels][max_floor1_values]i32 = undefined;
        var floor_used: [max_channels]bool = undefined;
        var nonzero: [max_channels]bool = undefined;
        for (0..ch) |c| {
            const floor = &setup.floors[mapping.submap_floor[mapping.mux[c]]];
            floor_used[c] = decodeFloor(floor, setup.codebooks, &r, &fit[c]);
            nonzero[c] = floor_used[c];
            @memset(self.spectrum[c][0..half], 0);
        }
        for (mapping.coupling) |step| if (nonzero[step.magnitude] or nonzero[step.angle]) {
            nonzero[step.magnitude] = true;
            nonzero[step.angle] = true;
        };
        for (0..mapping.submaps) |s| {
            var vectors: [max_channels][]f32 = undefined;
            var flags: [max_channels]bool = undefined;
            var count: usize = 0;
            for (0..ch) |c| if (mapping.mux[c] == s) {
                vectors[count] = self.spectrum[c][0..half];
                flags[count] = nonzero[c];
                count += 1;
            };
            if (count == 0) continue;
            decodeResidue(&setup.residues[mapping.submap_residue[s]], setup.codebooks, &r, vectors[0..count], flags[0..count], half, &self.scratch);
        }
        var step_index = mapping.coupling.len;
        while (step_index > 0) {
            step_index -= 1;
            const step = mapping.coupling[step_index];
            const magnitudes = self.spectrum[step.magnitude][0..half];
            const angles = self.spectrum[step.angle][0..half];
            for (magnitudes, angles) |*m, *a| {
                const mag = m.*;
                const ang = a.*;
                if (mag > 0) {
                    if (ang > 0) {
                        a.* = mag - ang;
                    } else {
                        a.* = mag;
                        m.* = mag + ang;
                    }
                } else {
                    if (ang > 0) {
                        a.* = mag + ang;
                    } else {
                        a.* = mag;
                        m.* = mag - ang;
                    }
                }
            }
        }
        for (0..ch) |c| {
            const spectrum = self.spectrum[c][0..half];
            if (floor_used[c]) {
                applyFloor(&setup.floors[mapping.submap_floor[mapping.mux[c]]], &fit[c], spectrum);
            } else @memset(spectrum, 0);
            imdct(block, spectrum, self.pcm[c][0..n], &self.scratch);
        }
        self.overlap(@intCast(n));
        self.trim(packet, @intCast(n));
        self.previous_n = @intCast(n);
    }

    /// Overlaps this block's first half with the previous block's second half, as
    /// libvorbis's `vorbis_synthesis_blockin` does, and keeps this block's second half.
    fn overlap(self: *Decoder, n: u16) void {
        const ch = self.headers.info.channels;
        const cn: usize = n / 2;
        defer for (0..ch) |c| @memcpy(self.previous[c][0..cn], self.pcm[c][cn..n]);
        if (self.previous_n == 0) return;
        const pn: usize = self.previous_n / 2;
        const m = @min(pn, cn);
        const window = self.headers.setup.blocks[if (m == self.headers.info.blocksize[0] / 2) 0 else 1].window;
        const po = pn / 2 - m / 2;
        const co = cn / 2 - m / 2;
        const count = pn / 2 + cn / 2;
        for (0..ch) |c| {
            const prev = self.previous[c];
            const cur = self.pcm[c];
            for (0..count) |t| {
                const v = if (t < po)
                    prev[t]
                else if (t < po + m)
                    prev[t] * window[m - 1 - (t - po)] + cur[co + t - po] * window[t - po]
                else
                    cur[co + t - po];
                self.ready[t * ch + c] = v;
            }
        }
        self.ready_frames = count;
    }

    /// libvorbis's granule bookkeeping: the first granule may trim the stream's start (or,
    /// on its last page, its end), and the last granule trims the end. Neither trims more than
    /// this packet made.
    fn trim(self: *Decoder, packet: ogg.Packet, n: u16) void {
        const step: u64 = if (self.previous_n == 0) 0 else self.previous_n / 4 + n / 4;
        const made = if (self.made) |m| m + step else 0;
        self.made = made;
        const have: u64 = self.ready_frames - self.ready_read;
        if (self.position) |p| {
            // Saturating: a granule is the file's word, and one near the top of the range
            // must not overflow the count it is added to.
            const position = p +| step;
            self.position = position;
            const granule = packet.granule orelse return;
            if (position > granule and packet.last) self.ready_frames -= @intCast(@min(position - granule, have));
            self.position = granule;
        } else {
            const granule = packet.granule orelse return;
            self.position = granule;
            if (made <= granule) return;
            const extra: usize = @intCast(@min(made - granule, have));
            if (packet.last) self.ready_frames -= extra else self.ready_read += extra;
        }
    }
};

/// Decodes a whole Ogg Vorbis file into a `Sound` of exactly the length its last granule
/// claims, checking every sample is finite.
pub fn decode(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Sound {
    var headers = try readHeaders(gpa, bytes, limits);
    defer headers.deinit();
    var sound = try Sound.alloc(gpa, @intCast(headers.frames), headers.info.channels, headers.info.sample_rate);
    errdefer sound.deinit(gpa);
    var decoder = try Decoder.init(gpa, bytes, &headers);
    defer decoder.deinit();
    var filled: usize = 0;
    while (filled < sound.samples.len) {
        const frames = try decoder.read(sound.samples[filled..]);
        // `read` refuses a stream that ends short, so this is only a guard.
        if (frames == 0) return invalid("the stream ends short of its length", .{});
        filled += frames * sound.channels;
    }
    // And one that runs long.
    var extra: [max_channels]f32 = undefined;
    if (try decoder.read(extra[0..sound.channels]) != 0) return invalid("the stream runs past its length", .{});
    return sound;
}

/// A streamed sound's headers, once the whole file has been decoded and found sound.
pub const Proven = struct {
    headers: Headers,
    /// The most memory a packet spanning pages needed, for `Decoder.reserve`.
    spanning: usize,
};

/// Decodes the whole file and keeps none of it: the proving pass a streamed sound gets at load
/// (`music.md` §4). The same bytes through the same decoder give the same result, so a file
/// that decodes here decodes again while it plays, and a broken one is refused by name now
/// rather than heard as silence halfway through. Decodes in pieces, so a long track costs a
/// buffer, not its whole length in samples.
pub fn prove(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Proven {
    var headers = try readHeaders(gpa, bytes, limits);
    errdefer headers.deinit();
    var decoder = try Decoder.init(gpa, bytes, &headers);
    defer decoder.deinit();
    var piece: [1024 * max_channels]f32 = undefined;
    const ch = headers.info.channels;
    // `read` refuses a stream that ends short or runs long, and a sample that is not finite.
    while (try decoder.read(piece[0 .. piece.len / ch * ch]) != 0) {}
    return .{ .headers = headers, .spanning = decoder.packets.spanning.capacity };
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
    residue_classes: u8 = 1,
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
        try w.write(self.residue_classes - 1, 6);
        try w.write(0, 8); // Classbook 0.
        for (0..self.residue_classes) |_| {
            try w.write(1, 3); // Each cascade: pass 0 only.
            try w.write(0, 1);
        }
        for (0..self.residue_classes) |_| try w.write(self.residue_book, 8);

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

test "an overspecified or underspecified tree is refused; a one-bit single entry is not" {
    var codewords: [4]u32 = undefined;
    try testing.expectError(error.InvalidSound, assignCodewords(&.{ 1, 1, 1 }, codewords[0..3], 0));
    try testing.expectError(error.InvalidSound, assignCodewords(&.{ 1, 2 }, codewords[0..2], 0));
    try testing.expectEqual(@as(u32, 1), try assignCodewords(&.{ 0, 1, 0 }, codewords[0..3], 0));
    // libvorbis takes a single entry only with a one-bit codeword (M30 Step 3).
    try testing.expectError(error.InvalidSound, assignCodewords(&.{ 0, 3, 0 }, codewords[0..3], 0));
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
        .{ "a classbook too small for its classifications", .{ .residue_classes = 3 }, 1, error.InvalidSound },
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

test "every fixture decodes within 2^-14 of the reference, to its exact length" {
    for (ogg.fixtures) |f| {
        var sound = try decode(testing.allocator, f.ogg, .{});
        defer sound.deinit(testing.allocator);
        var reference = try wav.decode(testing.allocator, f.reference, .{});
        defer reference.deinit(testing.allocator);
        try testing.expectEqual(reference.channels, sound.channels);
        try testing.expectEqual(reference.sample_rate, sound.sample_rate);
        try testing.expectEqual(reference.samples.len, sound.samples.len);
        var worst: f32 = 0;
        var sum: f64 = 0;
        for (sound.samples, reference.samples) |a, b| {
            // The reference is clamped to 16 bits, so the decoder's value is compared clamped.
            const d = @abs(std.math.clamp(a, -1, 32767.0 / 32768.0) - b);
            worst = @max(worst, d);
            sum += d * d;
        }
        const rms = @sqrt(sum / @as(f64, @floatFromInt(sound.samples.len)));
        testing.expect(worst <= 1.0 / 16384.0) catch |e| {
            std.debug.print("{s}: max {e:.3} rms {e:.3}\n", .{ f.name, worst, rms });
            return e;
        };
    }
}

test "each fixture's decode is pinned by hash" {
    const pins = [_]u64{ 0x0b31aa60397bd12b, 0x2c12133785672371, 0x43cdf370d93d80a9, 0xd9cfbfe0fb3ce17a, 0x5839efa01e2be407, 0x7f8840f454874233, 0xb87e2bada948c812 };
    var wrong = false;
    for (ogg.fixtures, pins) |f, pin| {
        var sound = try decode(testing.allocator, f.ogg, .{});
        defer sound.deinit(testing.allocator);
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(sound.samples));
        if (hash != pin) {
            std.debug.print("{s}: 0x{x:0>16}\n", .{ f.name, hash });
            wrong = true;
        }
    }
    try testing.expect(!wrong);
}

test "a decoder read in small pieces gives the whole decode" {
    for ([_]usize{ 0, 2, 4 }) |i| {
        const f = ogg.fixtures[i];
        var whole = try decode(testing.allocator, f.ogg, .{});
        defer whole.deinit(testing.allocator);
        var headers = try readHeaders(testing.allocator, f.ogg, .{});
        defer headers.deinit();
        var decoder = try Decoder.init(testing.allocator, f.ogg, &headers);
        defer decoder.deinit();
        const ch = headers.info.channels;
        var piece: [97 * max_channels]f32 = undefined;
        var at: usize = 0;
        var size: usize = 1;
        while (true) : (size = size % 97 + 1) {
            const frames = try decoder.read(piece[0 .. size * ch]);
            if (frames == 0) break;
            try testing.expectEqualSlices(f32, whole.samples[at..][0 .. frames * ch], piece[0 .. frames * ch]);
            at += frames * ch;
        }
        try testing.expectEqual(whole.samples.len, at);
    }
}

test "the inverse MDCT agrees with its definition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var budget: Budget = .{ .arena = arena.allocator(), .left = 1 << 24 };
    var rng = core.rng.Pcg32.init(0x4d44_4354, 0);
    for ([_]u16{ 64, 256, 2048 }) |n| {
        const block = try buildBlock(&budget, n);
        const x = try arena.allocator().alloc(f32, n / 2);
        for (x) |*v| v.* = rng.float01() * 2 - 1;
        const y = try arena.allocator().alloc(f32, n);
        var scratch: Scratch = .{
            .classes = undefined,
            .entries = undefined,
            .re = try arena.allocator().alloc(f32, n / 4),
            .im = try arena.allocator().alloc(f32, n / 4),
            .u = try arena.allocator().alloc(f32, n / 2),
        };
        imdct(&block, x, y, &scratch);
        const nf: f64 = @floatFromInt(n);
        for (y, 0..) |got, i| {
            var sum: f64 = 0;
            for (x, 0..) |xk, k| {
                const phase = (@as(f64, @floatFromInt(i)) + 0.5 + nf / 4) * (@as(f64, @floatFromInt(k)) + 0.5) / nf;
                sum += xk * core.math.trig.sinCosTurns(phase)[1];
            }
            try testing.expectApproxEqAbs(sum, got, 1e-3 * @sqrt(nf));
        }
    }
}

/// A codebook for hand-made packets, built as the setup builds one.
fn testBook(budget: *Budget, lengths: []const u8, dimensions: u16, values: ?[]const f32) !Codebook {
    const codewords = try budget.alloc(u32, lengths.len);
    var book: Codebook = .{
        .dimensions = dimensions,
        .entries = @intCast(lengths.len),
        .lengths = lengths,
        .codewords = codewords,
        .used = try assignCodewords(lengths, codewords, 0),
        .values = values,
        .table = &.{},
        .table_bits = 0,
        .tree = &.{},
    };
    try buildDecoder(&book, budget, 0);
    return book;
}

/// Writes entry `e`'s codeword as a packet carries it: its first bit first.
fn writeEntry(w: *BitWriter, book: *const Codebook, e: u32) !void {
    try w.write(book.codewords[e], @intCast(book.lengths[e]));
}

test "residue type 0 and a single-entry classbook decode as the specification says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var budget: Budget = .{ .arena = arena.allocator(), .left = 1 << 20 };
    // Book 0: one entry with a one-bit codeword, the classbook. Book 1: four 2-D vectors.
    const vq_values = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const books = [_]Codebook{
        try testBook(&budget, &.{1}, 1, null),
        try testBook(&budget, &.{ 2, 2, 2, 2 }, 2, &vq_values),
    };
    const residue: Residue = .{
        .kind = 0,
        .begin = 0,
        .end = 8,
        .partition_size = 4,
        .classifications = 1,
        .classbook = 0,
        .books = &.{.{ 1, -1, -1, -1, -1, -1, -1, -1 }},
        .partvals = 1,
    };
    var w: BitWriter = .{};
    defer w.deinit();
    // Partition 0: the class (whose bit is ignored), then entries 2 and 1. Partition 1: 3, 0.
    try w.write(1, 1);
    try writeEntry(&w, &books[1], 2);
    try writeEntry(&w, &books[1], 1);
    try w.write(0, 1);
    try writeEntry(&w, &books[1], 3);
    try writeEntry(&w, &books[1], 0);

    var spectrum: [8]f32 = @splat(0);
    var classes: [2][8]u8 = undefined;
    var entries: [8]u32 = undefined;
    var scratch: Scratch = .{ .classes = .{ &classes[0], &classes[1] }, .entries = &entries, .re = &.{}, .im = &.{}, .u = &.{} };
    var r: Reader = .{ .bytes = w.bytes.items };
    decodeResidue(&residue, &books, &r, &.{&spectrum}, &.{true}, 8, &scratch);
    // Type 0 interleaves a partition's vectors by step: entry 2 = (5, 6) and entry 1 = (3, 4)
    // give 5 3 6 4 (Vorbis I §8.6.3).
    try testing.expectEqualSlices(f32, &.{ 5, 3, 6, 4, 7, 1, 8, 2 }, &spectrum);

    // Cut inside partition 1: partition 0 stays, and nothing of partition 1 is added.
    @memset(&spectrum, 0);
    r = .{ .bytes = w.bytes.items[0..1] };
    decodeResidue(&residue, &books, &r, &.{&spectrum}, &.{true}, 8, &scratch);
    try testing.expectEqualSlices(f32, &.{ 5, 3, 6, 4, 0, 0, 0, 0 }, &spectrum);

    // A single-entry book reads one bit whatever it is, and nothing past the end.
    r = .{ .bytes = &.{0b10} };
    try testing.expectEqual(@as(?u32, 0), decodeEntry(&books[0], &r));
    try testing.expectEqual(@as(?u32, 0), decodeEntry(&books[0], &r));
    for (0..6) |_| _ = decodeEntry(&books[0], &r);
    try testing.expectEqual(@as(?u32, null), decodeEntry(&books[0], &r));
}

test "long codewords decode through the tree past the first-stage table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var budget: Budget = .{ .arena = arena.allocator(), .left = 1 << 20 };
    // Lengths 1, 2, …, 13, 13: a complete tree deeper than the ten-bit table.
    var lengths: [14]u8 = undefined;
    for (0..13) |i| lengths[i] = @intCast(i + 1);
    lengths[13] = 13;
    const book = try testBook(&budget, &lengths, 1, null);
    try testing.expectEqual(@as(u6, max_table_bits), book.table_bits);
    var w: BitWriter = .{};
    defer w.deinit();
    const order = [_]u32{ 13, 0, 12, 5, 10, 11, 1 };
    for (order) |e| try writeEntry(&w, &book, e);
    var r: Reader = .{ .bytes = w.bytes.items };
    for (order) |e| try testing.expectEqual(@as(?u32, e), decodeEntry(&book, &r));
}

/// A copy of a fixture with one page's granule rewritten, and its CRC.
fn withGranule(f: []const u8, page_from_end: usize, granule: u64) ![]u8 {
    const copy = try testing.allocator.dupe(u8, f);
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(testing.allocator);
    var pos: usize = 0;
    while (pos < copy.len) {
        try starts.append(testing.allocator, pos);
        pos += (try ogg.parsePage(copy[pos..])).size;
    }
    const at = starts.items[starts.items.len - 1 - page_from_end];
    const page = copy[at..][0..(try ogg.parsePage(copy[at..])).size];
    std.mem.writeInt(u64, page[6..14], granule, .little);
    resealPage(page);
    return copy;
}

fn resealPage(page: []u8) void {
    std.mem.writeInt(u32, page[22..26], 0, .little);
    std.mem.writeInt(u32, page[22..26], ogg.crc32(page), .little);
}

fn granuleOf(f: []const u8, page_from_end: usize) !u64 {
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(testing.allocator);
    var pos: usize = 0;
    while (pos < f.len) {
        try starts.append(testing.allocator, pos);
        pos += (try ogg.parsePage(f[pos..])).size;
    }
    return (try ogg.parsePage(f[starts.items[starts.items.len - 1 - page_from_end]..])).granule;
}

test "the last granule trims the end, and a length the packets cannot meet is refused" {
    const f = ogg.fixtures[2].ogg;
    var whole = try decode(testing.allocator, f, .{});
    defer whole.deinit(testing.allocator);
    const frames: u64 = whole.frameCount();

    // Ten frames shorter: the last packet gives ten fewer, and the rest is unchanged.
    const shorter = try withGranule(f, 0, frames - 10);
    defer testing.allocator.free(shorter);
    var trimmed = try decode(testing.allocator, shorter, .{});
    defer trimmed.deinit(testing.allocator);
    try testing.expectEqualSlices(f32, whole.samples[0..trimmed.samples.len], trimmed.samples);
    try testing.expectEqual(frames - 10, trimmed.frameCount());

    // Claiming more than the packets hold.
    const longer = try withGranule(f, 0, frames + 5000);
    defer testing.allocator.free(longer);
    try testing.expectError(error.InvalidSound, decode(testing.allocator, longer, .{}));

    // Holding more than the last granule claims: an earlier granule set back, which libvorbis
    // believes, leaves the last packet nothing to trim, so the packets overrun the length.
    const g1 = try granuleOf(f, 1);
    const g2 = try granuleOf(f, 2);
    const back = g2 + (g1 - g2) / 4;
    try testing.expect(g1 - back > 2048);
    const overrun = try withGranule(f, 1, back);
    defer testing.allocator.free(overrun);
    try testing.expectError(error.InvalidSound, decode(testing.allocator, overrun, .{}));

    // A stream (Step 5) reads the decoder directly, so its own checks are what hold there:
    // it never hands out a frame past the length, and it refuses a length it cannot meet.
    for ([_][]const u8{ longer, overrun }) |bytes| {
        var headers = try readHeaders(testing.allocator, bytes, .{});
        defer headers.deinit();
        var decoder = try Decoder.init(testing.allocator, bytes, &headers);
        defer decoder.deinit();
        var out: [4096]f32 = undefined;
        var delivered: u64 = 0;
        const outcome = while (true) {
            const got = decoder.read(&out) catch |err| break err;
            if (got == 0) break error.TestUnexpectedResult;
            delivered += got;
        };
        try testing.expectEqual(error.InvalidSound, outcome);
        try testing.expect(delivered <= headers.frames);
    }
}

test "a header among the audio packets, and a non-finite sample, are refused" {
    const gpa = testing.allocator;
    const f = ogg.fixtures[0].ogg;
    // The first audio packet begins the third page; setting its first bit makes it a header.
    var copy = try gpa.dupe(u8, f);
    defer gpa.free(copy);
    var pos: usize = 0;
    for (0..2) |_| pos += (try ogg.parsePage(copy[pos..])).size;
    const page = try ogg.parsePage(copy[pos..]);
    copy[pos + page.size - page.body.len] |= 1;
    resealPage(copy[pos..][0..page.size]);
    try testing.expectError(error.InvalidSound, decode(gpa, copy, .{}));

    var headers = try readHeaders(gpa, f, .{});
    defer headers.deinit();
    var decoder = try Decoder.init(gpa, f, &headers);
    defer decoder.deinit();
    var out: [64]f32 = undefined;
    _ = try decoder.read(out[0..1]);
    decoder.ready[decoder.ready_read] = std.math.nan(f32);
    try testing.expectError(error.InvalidSound, decoder.read(&out));
}

/// Decodes `bytes`, which may be anything: a refusal is fine, a panic fails the test.
fn decodeOrRefuse(bytes: []const u8) !void {
    var sound = decode(testing.allocator, bytes, .{}) catch |err| switch (err) {
        error.InvalidSound, error.UnsupportedSound, error.SoundTooLarge => return,
        error.OutOfMemory => return err,
    };
    sound.deinit(testing.allocator);
}

test "every truncation of the short fixture decodes or is refused" {
    const f = ogg.fixtures[4].ogg;
    for (0..f.len) |n| try decodeOrRefuse(f[0..n]);
}

test "seeded single-bit flips, each page resealed, decode or are refused" {
    const f = ogg.fixtures[2].ogg;
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(testing.allocator);
    var pos: usize = 0;
    while (pos < f.len) {
        try starts.append(testing.allocator, pos);
        pos += (try ogg.parsePage(f[pos..])).size;
    }
    try starts.append(testing.allocator, f.len);
    const copy = try testing.allocator.dupe(u8, f);
    defer testing.allocator.free(copy);
    var rng = core.rng.Pcg32.init(0x464c_4950, 0);
    for (0..flips) |_| {
        const bit = rng.below(@intCast(f.len * 8));
        const byte = bit / 8;
        copy[byte] ^= @as(u8, 1) << @intCast(bit % 8);
        // Reseal the page the flip landed in, so it reaches the decoder past the CRC.
        var page: usize = 0;
        while (starts.items[page + 1] <= byte) page += 1;
        const range = copy[starts.items[page]..starts.items[page + 1]];
        if (range.len >= ogg.header_size) resealPage(range);
        try decodeOrRefuse(copy);
        @memcpy(copy, f);
    }
}

/// `music.md` §12's 2,000 flips. Debug decodes slowly, so a Debug run sweeps a tenth of them;
/// `zig build asset-test -Doptimize=ReleaseSafe` runs the full count.
const flips = if (@import("builtin").mode == .Debug) 200 else 2000;

test "vorbis speed: frames per second, single-threaded, printed" {
    const f = ogg.fixtures[2];
    const runs = if (@import("builtin").mode == .Debug) 1 else 20;
    const start = std.Io.Clock.awake.now(testing.io);
    var frames: u64 = 0;
    var rate: u32 = 0;
    for (0..runs) |_| {
        var sound = try decode(testing.allocator, f.ogg, .{});
        defer sound.deinit(testing.allocator);
        frames += sound.frameCount();
        rate = sound.sample_rate;
    }
    const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
    const per_second = @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(@max(ns, 1)));
    std.debug.print("vorbis speed ({t}): {d:.0} frames/s, {d:.0}x real time ({s}, {d} runs)\n", .{
        @import("builtin").mode, per_second, per_second / @as(f64, @floatFromInt(rate)), f.name, runs,
    });
}

/// The same stream laid out with each audio packet ending its own page, with the granule it had,
/// in pages of one segment: every audio packet longer than 255 bytes then spans pages, which no
/// encoder's fixture does, and decodes to exactly the same frames. The three headers keep a page
/// each, whole, so the decoder's first spanning packet is an audio one.
fn repage(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var packets: ogg.Packets = .init(bytes);
    defer packets.deinit(gpa);
    const serial = std.mem.readInt(u32, bytes[14..18], .little);
    var sequence: u32 = 0;
    var index: usize = 0;
    while (try packets.next(gpa)) |packet| : (index += 1) {
        var rest = packet.data;
        const whole = index < 3;
        var continued = false;
        while (true) {
            const ends = whole or rest.len <= 255;
            const take = if (whole) rest.len else @min(rest.len, 255);
            var lacing: [255]u8 = undefined;
            var segments: usize = 0;
            var left = take;
            while (left >= 255) : (left -= 255) {
                lacing[segments] = 255;
                segments += 1;
            }
            // A packet that ends here closes with a value below 255, zero if need be.
            if (ends or left > 0) {
                lacing[segments] = @intCast(left);
                segments += 1;
            }
            var flags: u8 = if (continued) 0x01 else 0;
            if (sequence == 0) flags |= 0x02;
            if (ends and packet.last) flags |= 0x04;
            const granule = if (ends) packet.granule orelse ogg.Page.no_granule else ogg.Page.no_granule;
            const start = out.items.len;
            try out.appendSlice(gpa, "OggS");
            try out.appendSlice(gpa, &.{ 0, flags });
            var word: [8]u8 = undefined;
            std.mem.writeInt(u64, &word, granule, .little);
            try out.appendSlice(gpa, &word);
            std.mem.writeInt(u32, word[0..4], serial, .little);
            try out.appendSlice(gpa, word[0..4]);
            std.mem.writeInt(u32, word[0..4], sequence, .little);
            try out.appendSlice(gpa, word[0..4]);
            try out.appendSlice(gpa, &.{ 0, 0, 0, 0, @intCast(segments) });
            try out.appendSlice(gpa, lacing[0..segments]);
            try out.appendSlice(gpa, rest[0..take]);
            const page = out.items[start..];
            std.mem.writeInt(u32, page[22..26], ogg.crc32(page), .little);
            sequence += 1;
            rest = rest[take..];
            continued = true;
            if (ends) break;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "a proven stream rewinds to the same frames, and after its reserve never allocates" {
    var spanned: usize = 0;
    for (ogg.fixtures) |fixture| for ([_]bool{ false, true }) |spanning| {
        const bytes = if (spanning) try repage(testing.allocator, fixture.ogg) else fixture.ogg;
        defer if (spanning) testing.allocator.free(bytes);
        const f: ogg.Fixture = .{ .name = fixture.name, .ogg = bytes, .reference = fixture.reference };
        var expected = try decode(testing.allocator, fixture.ogg, .{});
        defer expected.deinit(testing.allocator);
        var proven = try prove(testing.allocator, f.ogg, .{});
        defer proven.headers.deinit();
        try testing.expectEqual(@as(u64, expected.frameCount()), proven.headers.frames);
        // A repaged stream's audio packets over 255 bytes span pages, so its reserve is real.
        if (spanning and proven.spanning > 255) spanned += 1;

        // Every allocation the decoder will ever make, made here; then none is allowed.
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var decoder = try Decoder.init(failing.allocator(), f.ogg, &proven.headers);
        defer decoder.deinit();
        try decoder.reserve(proven.spanning);
        failing.fail_index = failing.alloc_index;

        const pass = try testing.allocator.alloc(f32, expected.samples.len);
        defer testing.allocator.free(pass);
        for (0..3) |round| {
            if (round > 0) try decoder.rewind();
            var filled: usize = 0;
            // Pieces of an odd size, so a pass ends partway through one.
            while (filled < pass.len) {
                const want = @min(pass.len - filled, 777 * @as(usize, expected.channels));
                const got = try decoder.read(pass[filled..][0..want]);
                try testing.expect(got > 0);
                filled += got * expected.channels;
            }
            try testing.expectEqual(@as(usize, 0), try decoder.read(pass[0..expected.channels]));
            try testing.expectEqualSlices(f32, expected.samples, pass);
        }
    };
    // `mono44_q10` and `coupled` have audio packets over 255 bytes; the others' all fit one
    // segment, so these two are where the reserve is what keeps a decode from allocating.
    try testing.expectEqual(@as(usize, 2), spanned);
}
