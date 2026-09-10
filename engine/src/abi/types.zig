//! The types that cross, and nothing that uses them.
//!
//! The rule this file exists to serve: **nothing crosses whose layout Foundry does not
//! state** (`public-abi.md` §5). Every type here is `extern`, every width is deliberate, and
//! every one of them is asserted against `foundry.h` by `agreement.zig` on every target the
//! engine builds for.
//!
//! Two of them are not defined here at all, and that is the interesting part.
//! `ContentId` is `core`'s, unchanged: it was made an `extern struct` at M0 *because* it
//! would cross this boundary one day, and re-declaring it here would create a second
//! definition that could drift from the one the content compiler hashes with. A handle's
//! packing is `core.Handle`'s `bits()`, written down once in M0 for the same reason.
//!
//! Design: `docs/design/public-abi.md` §5, §6 and §7.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const log = core.log.scoped(.abi);

// Foundry's targets are all 64-bit (ADR-0008), and `foundry.h` refuses to compile anywhere
// else. `Str` is only byte-identical to a Zig slice while that holds, so it is stated here
// as well: two halves of one claim, each failing on its own side.
comptime {
    if (@sizeOf(usize) != 8) @compileError("the public ABI describes a 64-bit target");
}

/// The version of the table this build publishes. A version numbers the *table*: `_v2` is a
/// struct added alongside `_v1` rather than a replacement for it (ADR-0004), so this grows
/// by gaining a sibling and never by being incremented in place.
pub const api_version_1: u32 = 1;
pub const api_version_2: u32 = 2;

// == Booleans ==========================================================================

/// `u8`, because C's `bool` has a width the platform decides.
pub const Bool = u8;

/// Any nonzero is true on the way in. This is the only place that rule is implemented, so
/// that no entry point can accidentally implement a stricter one.
pub fn boolIn(value: Bool) bool {
    return value != 0;
}

/// Exactly 0 or 1 on the way out.
pub fn boolOut(value: bool) Bool {
    return @intFromBool(value);
}

// == Results ===========================================================================

/// What every call returns.
///
/// Zero is success, positive is a terminal condition that is not an error, negative is an
/// error — the split that makes `while (next(...) == FOUNDRY_OK)` correct without
/// special-casing the end of a walk.
///
/// The numbers are the contract. They are never renumbered, and a code added later takes
/// the next unused value rather than a tidy one.
pub const Result = enum(i32) {
    ok = 0,

    /// Iteration is finished. Not an error.
    end = 1,

    /// A pointer, length, range or enum value the API refuses.
    invalid_argument = -1,
    /// Well-formed and stale, or never issued.
    invalid_handle = -2,
    /// The thing asked for does not exist. Distinct from a bad handle: `not_found` means
    /// the question was well-formed and the answer is no.
    not_found = -3,
    /// The host supplied no subsystem for this capability (ADR-0026). Never a null function
    /// pointer — the table for a version is one shape, always.
    unavailable = -4,
    /// A version, format or feature this build does not have.
    unsupported = -5,
    /// Registering a name or id twice, incompatibly.
    already_exists = -6,
    /// A bound was hit: a buffer, a pool, a configured maximum.
    limit = -7,
    /// Well-formed, permitted in general, not permitted *now* — a structural mutation
    /// during a walk, or a write in a phase that forbids one.
    refused = -8,
    out_of_memory = -9,
    /// An engine error with no mapping. Always logged with the underlying error's name.
    internal = -10,

    /// The C spelling, which is what a mod author greps for and what `result_name`
    /// publishes so that a mod need not ship its own copy of this table and let it go
    /// stale.
    pub fn name(self: Result) []const u8 {
        return switch (self) {
            .ok => "FOUNDRY_OK",
            .end => "FOUNDRY_END",
            .invalid_argument => "FOUNDRY_ERR_INVALID_ARGUMENT",
            .invalid_handle => "FOUNDRY_ERR_INVALID_HANDLE",
            .not_found => "FOUNDRY_ERR_NOT_FOUND",
            .unavailable => "FOUNDRY_ERR_UNAVAILABLE",
            .unsupported => "FOUNDRY_ERR_UNSUPPORTED",
            .already_exists => "FOUNDRY_ERR_ALREADY_EXISTS",
            .limit => "FOUNDRY_ERR_LIMIT",
            .refused => "FOUNDRY_ERR_REFUSED",
            .out_of_memory => "FOUNDRY_ERR_OUT_OF_MEMORY",
            .internal => "FOUNDRY_ERR_INTERNAL",
        };
    }

    pub fn isError(self: Result) bool {
        return @intFromEnum(self) < 0;
    }

    /// A code arriving *from* the other side, which is untrusted like everything else that
    /// does: null rather than an illegal enum value for a number this build has never
    /// issued. `result_name` is the one call that takes a result rather than returning one,
    /// and a mod is free to pass it anything at all.
    pub fn fromCode(code: i32) ?Result {
        inline for (@typeInfo(Result).@"enum".fields) |field| {
            if (field.value == code) return @enumFromInt(field.value);
        }
        return null;
    }

    /// The last resort of a `catch`, never the first.
    ///
    /// An entry point maps the errors it knows how to explain — a stale handle, a name
    /// already taken — because those carry information this cannot. What is left is an
    /// engine error the boundary has no vocabulary for, and it becomes `internal` *and is
    /// logged with its name*, so the one thing lost at the boundary survives in the log
    /// (`public-abi.md` §6).
    pub fn fromError(err: anyerror) Result {
        const result = mapError(err);
        if (result == .internal) {
            log.err("unmapped engine error at the ABI boundary: {s}", .{@errorName(err)});
        }
        return result;
    }
};

/// The mapping without the log, which is the only part a test can call: Zig's test runner
/// fails a test that logs at `err` level, and that rule is correct and not worth opting out
/// of to prove a `switch` works.
fn mapError(err: anyerror) Result {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => .internal,
    };
}

// == Strings ===========================================================================

/// A borrowed span of UTF-8 bytes, byte-identical to a Zig `[]const u8`.
///
/// **Not NUL-terminated**, because content strings are spans into a mapped package and
/// terminating them would mean copying every one at the boundary.
///
/// **Borrowed**, like every pointer this API hands out: valid only until the mod returns
/// control to the engine. A mod that wants to keep one copies it.
pub const Str = extern struct {
    ptr: ?[*]const u8 = null,
    len: u64 = 0,

    pub const empty: Str = .{};

    /// Engine to mod. The lifetime rule is the caller's to honour: what goes in here lives
    /// in a package, a frame arena or static storage, and never on a stack that is about to
    /// unwind.
    pub fn from(slice: []const u8) Str {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    /// No string that legitimately crosses this boundary is a gibibyte long, and refusing
    /// the ones that claim to be turns a large class of garbage — an uninitialised field, a
    /// length where a pointer belonged — into a refusal instead of a fault. It is not a
    /// security boundary; nothing here can validate that memory a mod described is memory a
    /// mod owns.
    pub const max_bytes: u64 = 1 << 30;

    /// Mod to engine. Null for anything this build will not read: a length it cannot
    /// address, an absurd length, or a null pointer with a nonzero length. A null pointer
    /// with a zero length is the empty string and is perfectly legal — a mod that builds a
    /// `FoundryStr` by zeroing a struct means "".
    pub fn bytes(self: Str) ?[]const u8 {
        if (self.len == 0) return &.{};
        if (self.len > max_bytes) return null;
        const ptr = self.ptr orelse return null;
        return ptr[0..@intCast(self.len)];
    }

    /// The same, and valid UTF-8. Every string the engine stores is UTF-8 — content ids are
    /// hashed from exact bytes, and the text renderer decodes them — so a mod handing over
    /// something else has to be refused here rather than three layers down.
    pub fn utf8(self: Str) ?[]const u8 {
        const raw = self.bytes() orelse return null;
        if (!std.unicode.utf8ValidateSlice(raw)) return null;
        return raw;
    }
};

// == Content identity ==================================================================

/// `core`'s, unchanged. It was made an `extern struct` at M0 because it would cross this
/// boundary one day; this is that day, and there is nothing to convert.
pub const ContentId = core.ContentId;

/// `data`'s, unchanged, and **a different type from `ContentId` on purpose**.
///
/// Schemas and content occupy separate identifier spaces, so the schema `foundry:item` and a
/// record named `foundry:item` coexist without either shadowing the other. `data` made that
/// a type difference rather than a convention specifically so the most confusable pair of
/// values in the content system could not be swapped by accident — and said, in 2026-09, that
/// it was `extern struct` "which is why", meaning here. Collapsing them at the boundary would
/// have thrown away the one place the distinction is hardest to keep by eye.
pub const SchemaId = data.SchemaId;

// == Handles ===========================================================================

/// Sixty-four opaque bits, one distinct type per kind.
///
/// The distinctness is the whole reason this is a struct rather than a `u64` typedef: it
/// keeps, in C's type system, the separation `core.Handle`'s phantom tag keeps in Zig, so a
/// texture passed where a voice belongs is a compile error on both sides of the boundary.
///
/// The *packing* is not published and may change. The width and the opacity are the
/// contract, and zero is always the null handle.
fn Opaque(comptime kind: []const u8) type {
    return extern struct {
        const Self = @This();

        /// What this handle refers to, for diagnostics. Never stored in an instance.
        pub const abi_kind = kind;

        bits: u64 = 0,

        pub const none: Self = .{ .bits = 0 };

        pub fn isNone(self: Self) bool {
            return self.bits == 0;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.bits == b.bits;
        }

        /// Engine to mod. Takes any `core.Handle(T)`, and `Handle.none` packs to zero, so
        /// the null handle needs no special case at any call site.
        pub fn wrap(handle: anytype) Self {
            return .{ .bits = handle.bits() };
        }

        /// Mod to engine. **This does not validate anything** — it unpacks bits a mod
        /// supplied into a handle shaped like one. What makes it safe is that the very next
        /// thing done with the result is a pool lookup, which resolves the generation and
        /// fails cleanly on a stale or invented handle (I1). Anything that unwraps and does
        /// not immediately resolve is a bug.
        pub fn unwrap(self: Self, comptime Handle: type) Handle {
            return Handle.fromBits(self.bits);
        }
    };
}

/// The loaded mod itself. Scopes everything that is per-mod: which package it came from,
/// what name its log lines carry, and what would be unregistered if a mod ever became
/// unloadable.
pub const Mod = Opaque("mod");

/// `data` — content, as loaded and merged.
pub const Package = Opaque("package");
pub const Schema = Opaque("schema");
pub const Record = Opaque("record");

/// `asset` — a loaded asset, and the one refcount a mod owns and must own.
pub const Asset = Opaque("asset");

/// `scene` — entities, and the component types they carry.
pub const Entity = Opaque("entity");
pub const ComponentType = Opaque("component type");

/// `render2d` — the game-facing renderer. The RHI under it is never exposed (§4.2).
pub const Texture = Opaque("texture");
pub const View = Opaque("view");

/// `audio` — a playing voice.
pub const Voice = Opaque("voice");

/// `physics2d` — a collision body.
pub const Body = Opaque("body");
pub const Grid = Opaque("grid");

/// A memory counter a mod reports its own numbers into. The boundary's own handle rather
/// than a subsystem's: the engine issues an `app.MemoryHandle` for the counter it was
/// handed, and this names the counter `abi` holds on the mod's behalf, because a mod has no
/// place to keep a `core.mem.Counted` of its own.
pub const MemoryCounter = Opaque("memory counter");

// == Enumerations ======================================================================

/// How severe a log line is, as it crosses.
///
/// **Not `@intFromEnum(core.log.Level)`.** The numbers here are written down because they
/// are what a compiled mod holds; `core.log.Level` is free to be reordered, and the mapping
/// below is what makes that true rather than a hope.
pub const LogLevel = enum(i32) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn toCore(self: LogLevel) core.log.Level {
        return switch (self) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
            .trace => .trace,
        };
    }

    pub fn fromCore(level: core.log.Level) LogLevel {
        return switch (level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
            .trace => .trace,
        };
    }

    /// From the other side, and therefore untrusted: null for a number this build has never
    /// published rather than an illegal enum value.
    pub fn fromCode(code: i32) ?LogLevel {
        return switch (code) {
            0 => .err,
            1 => .warn,
            2 => .info,
            3 => .debug,
            4 => .trace,
            else => null,
        };
    }
};

/// What a schema says a field is. Written down for the same reason as `LogLevel`, and with
/// more at stake: `data.FieldType` is a union whose tag order is an implementation detail,
/// and a mod reading a record type it has never heard of branches on these numbers.
pub const FieldType = enum(i32) {
    bool = 0,
    i32 = 1,
    i64 = 2,
    u32 = 3,
    u64 = 4,
    f32 = 5,
    f64 = 6,
    string = 7,
    id = 8,
    list = 9,
    nested = 10,

    pub fn fromData(t: data.FieldType) FieldType {
        return switch (t) {
            .bool => .bool,
            .i32 => .i32,
            .i64 => .i64,
            .u32 => .u32,
            .u64 => .u64,
            .f32 => .f32,
            .f64 => .f64,
            .string => .string,
            .id => .id,
            .list => .list,
            .nested => .nested,
        };
    }
};

// == Structs that cross ================================================================

/// One line from the engine's log ring.
pub const LogRecord = extern struct {
    level: LogLevel = .info,
    /// Explicit, so the padding is part of the specification rather than the compiler's
    /// opinion.
    reserved: u32 = 0,
    frame: u64 = 0,
    sequence: u64 = 0,
    scope: Str = .empty,
    text: Str = .empty,
};

/// What a mod reports about its own allocations. The engine cannot wrap a mod's allocator,
/// so a mod that wants to be visible in the memory panel writes its own numbers.
pub const MemoryStats = extern struct {
    live_bytes: u64 = 0,
    peak_bytes: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
    failures: u64 = 0,
};

/// A fixed simulation step, as a native system sees it.
pub const Step = extern struct {
    tick: u64 = 0,
    delta_ns: u64 = 0,
};

/// Native lifecycle hooks for a component's raw storage.
pub const ComponentConstruct = *const fn (ctx: ?*anyopaque, out: ?*anyopaque) callconv(.c) void;
pub const ComponentDestruct = *const fn (ctx: ?*anyopaque, component: ?*anyopaque) callconv(.c) void;

/// What a native mod supplies when it registers a component type.
///
/// The schema is already content data: the mod's package declared it with `@schema`, and
/// this descriptor supplies the in-memory half `scene` cannot know. `name` repeats the
/// schema spelling for diagnostics and is checked against `schema` before it is kept.
pub const ComponentDesc = extern struct {
    schema: SchemaId = .none,
    name: Str = .empty,
    size: u32 = 0,
    alignment: u32 = 0,
    ctx: ?*anyopaque = null,
    construct: ?ComponentConstruct = null,
    destruct: ?ComponentDestruct = null,
};

/// A native system callback. It reaches its world through the ambient host, as every API
/// call does; the step is the only per-update data it is handed directly.
pub const SystemUpdate = *const fn (ctx: ?*anyopaque, step: ?*const Step) callconv(.c) void;

pub const SystemDesc = extern struct {
    id: ContentId = .none,
    name: Str = .empty,
    ctx: ?*anyopaque = null,
    update: ?SystemUpdate = null,
};

// == Cursors ===========================================================================

/// A position in a walk, and the generation of the container it is walking.
///
/// **Not an index.** An index invites being stored and reused as an identity, which is what
/// content ids exist to stop one level up. Carrying the container's generation is what makes
/// a walk over something that was structurally mutated underneath it *detectable*: the
/// enumeration compares this against its own generation and answers `invalid_argument`
/// rather than silently resynchronising onto whatever now sits at that position.
///
/// This is the boundary's form of the mutation guard `entity-storage.md` §5 already keeps
/// internally — a return rather than an assertion, because the caller is untrusted.
pub const Cursor = extern struct {
    bits: u64 = 0,

    /// Where every walk starts, and the value a zeroed struct has. Generation 0 is
    /// therefore reserved: an enumeration issues generations from 1, so `begin` can never
    /// be mistaken for a position inside a container.
    pub const begin: Cursor = .{ .bits = 0 };

    pub fn isBegin(self: Cursor) bool {
        return self.bits == 0;
    }

    /// The same packing as a handle, for the same reason: written down once.
    pub fn at(walk_generation: u32, position: u32) Cursor {
        std.debug.assert(walk_generation != 0);
        return .{ .bits = @as(u64, position) | (@as(u64, walk_generation) << 32) };
    }

    pub fn generation(self: Cursor) u32 {
        return @truncate(self.bits >> 32);
    }

    pub fn index(self: Cursor) u32 {
        return @truncate(self.bits);
    }
};

// == The entry point ===================================================================

/// What a native mod exports, in Zig's spelling of it. **These signatures can never
/// change**: every mod ever compiled is baked against them, so the versioning problem has to
/// be solvable without touching them, and `GetApi` is how it is.
pub const GetApi = *const fn (version: u32) callconv(.c) ?*const anyopaque;

/// Raw `i32`, not `Result`: a native library is untrusted and may return a value the
/// enum does not contain. The loader validates it with `Result.fromCode` after crossing.
pub const ModInit = *const fn (get_api: GetApi, self: Mod) callconv(.c) i32;
pub const ModShutdown = *const fn (self: Mod) callconv(.c) void;

/// The symbol names looked up in a mod's library. Written here rather than at the lookup so
/// that the two spellings — this one and the header's — sit next to their contract.
pub const init_symbol = "foundry_mod_init";
pub const shutdown_symbol = "foundry_mod_shutdown";

// == Tests =============================================================================

const testing = std.testing;

test "result codes are the numbers the header states" {
    try testing.expectEqual(@as(i32, 0), @intFromEnum(Result.ok));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(Result.end));
    try testing.expectEqual(@as(i32, -1), @intFromEnum(Result.invalid_argument));
    try testing.expectEqual(@as(i32, -10), @intFromEnum(Result.internal));

    try testing.expect(!Result.ok.isError());
    try testing.expect(!Result.end.isError());
    try testing.expect(Result.not_found.isError());
}

test "every result names itself, and no two share a name" {
    const fields = @typeInfo(Result).@"enum".fields;
    inline for (fields, 0..) |a, i| {
        const a_name = (@as(Result, @enumFromInt(a.value))).name();
        try testing.expect(std.mem.startsWith(u8, a_name, "FOUNDRY_"));
        inline for (fields, 0..) |b, j| {
            if (i == j) continue;
            const b_name = (@as(Result, @enumFromInt(b.value))).name();
            try testing.expect(!std.mem.eql(u8, a_name, b_name));
        }
    }
}

test "a code from the other side is looked up, never trusted" {
    try testing.expectEqual(Result.not_found, Result.fromCode(-3).?);
    try testing.expectEqual(Result.ok, Result.fromCode(0).?);
    try testing.expectEqual(@as(?Result, null), Result.fromCode(2));
    try testing.expectEqual(@as(?Result, null), Result.fromCode(-11));
    try testing.expectEqual(@as(?Result, null), Result.fromCode(std.math.minInt(i32)));
}

test "an allocation failure keeps its name; anything else becomes internal" {
    try testing.expectEqual(Result.out_of_memory, Result.fromError(error.OutOfMemory));
    try testing.expectEqual(Result.out_of_memory, mapError(error.OutOfMemory));

    // Through `mapError`, because `fromError` logs this case at `err` level by design and
    // the test runner treats that as a failure.
    try testing.expectEqual(Result.internal, mapError(error.Overflow));
    try testing.expectEqual(Result.internal, mapError(error.FileNotFound));
}

test "a Str is a Zig slice with a different name" {
    try testing.expectEqual(@sizeOf([]const u8), @sizeOf(Str));
    try testing.expectEqual(@alignOf([]const u8), @alignOf(Str));

    const hello = "hello";
    const s = Str.from(hello);
    try testing.expectEqual(@as(u64, 5), s.len);
    try testing.expectEqualStrings(hello, s.bytes().?);
    try testing.expectEqualStrings(hello, s.utf8().?);
}

test "a Str the engine will not read is refused rather than dereferenced" {
    // A zeroed struct is the empty string, which is legal.
    try testing.expectEqualStrings("", (Str{}).bytes().?);
    try testing.expectEqualStrings("", Str.empty.bytes().?);

    // A length with no pointer is not.
    try testing.expectEqual(@as(?[]const u8, null), (Str{ .ptr = null, .len = 12 }).bytes());

    // Nor is a length nothing could own. The pointer is never dereferenced to find out.
    const bogus: Str = .{ .ptr = @ptrFromInt(0x1000), .len = Str.max_bytes + 1 };
    try testing.expectEqual(@as(?[]const u8, null), bogus.bytes());
    try testing.expectEqual(@as(?[]const u8, null), (Str{ .ptr = @ptrFromInt(0x1000), .len = std.math.maxInt(u64) }).bytes());
}

test "a Str that is not UTF-8 is refused, and the bytes are still readable" {
    const invalid = [_]u8{ 'a', 0xff, 'b' };
    const s = Str.from(&invalid);
    try testing.expectEqual(@as(usize, 3), s.bytes().?.len);
    try testing.expectEqual(@as(?[]const u8, null), s.utf8());
}

test "handles are one width, distinct types, and zero is none" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Entity));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Voice));
    try testing.expect(Entity != Voice);
    try testing.expect(Entity.none.isNone());
    try testing.expect(!(Entity{ .bits = 1 }).isNone());
}

test "a handle survives the round trip through its bits" {
    const Thing = struct {};
    const Handle = core.Handle(Thing);

    const original: Handle = .{ .index = 7, .generation = 3 };
    const crossed = Entity.wrap(original);
    try testing.expect(!crossed.isNone());
    try testing.expect(original.eql(crossed.unwrap(Handle)));

    // And the null handle needs no special case in either direction.
    try testing.expect(Entity.wrap(Handle.none).isNone());
    try testing.expect(Entity.none.unwrap(Handle).isNone());
}

test "a cursor begins at zero and remembers which container it is walking" {
    try testing.expect(Cursor.begin.isBegin());
    try testing.expectEqual(@as(u64, 0), (Cursor{}).bits);

    const c = Cursor.at(2, 41);
    try testing.expect(!c.isBegin());
    try testing.expectEqual(@as(u32, 2), c.generation());
    try testing.expectEqual(@as(u32, 41), c.index());

    // Index 0 of a live container is still not `begin`, which is why generations start at 1.
    try testing.expect(!Cursor.at(1, 0).isBegin());
}

test "booleans are permissive in and exact out" {
    try testing.expect(boolIn(1));
    try testing.expect(boolIn(255));
    try testing.expect(!boolIn(0));
    try testing.expectEqual(@as(Bool, 1), boolOut(true));
    try testing.expectEqual(@as(Bool, 0), boolOut(false));
}
