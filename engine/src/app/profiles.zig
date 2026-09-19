//! Profiles on disk: a player's named, ordered selections, one file each.
//!
//! **A profile is a selection and nothing else** (ADR-0040): a display name, the packages
//! enabled in the player's order, and the native consents given per package version.
//! Settings stay global, and saves are the game's.
//!
//! **One file per profile**, at `<user data>/profiles/<key>.fset`, in the settings envelope
//! under the engine's `foundry:profile` schema. It is the same format, validation and atomic
//! write as `settings.fset`, not a second one. Separate files keep a long mod list within its
//! own bounds, and let two instances edit different profiles without touching each other.
//!
//! **The key is a number, and the name is data.** A key is the smallest unused number from
//! 1, and it is the only thing that becomes a path. A name a player typed never does: that
//! would be a path-traversal bug waiting for its first creative player.
//!
//! **The order is kept as given**, never sorted. `app.settings.IdSet` sorts, and that
//! threw the player's order away at the first save (`distribution.md` §5, ADR-0040).
//!
//! Everything read here is untrusted, as every settings file is. A profile past its bounds,
//! or disagreeing with itself, is refused whole with a warning and left untouched: a
//! selection that is partly understood is worse than none.
//!
//! **Writes merge by field**, as settings do (`mod-management.md` §6): name, enabled list
//! and consents are separate fields, so an instance renaming a profile and another applying
//! its selection keep both changes. A write never replaces a file another build wrote.
//!
//! Design: `docs/design/mod-management.md` §5.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const settings = @import("settings.zig");

const Allocator = std.mem.Allocator;
const Os = platform.os.Os;

const log = core.log.scoped(.mods);

/// The directory under an application's user data that holds its profiles.
pub const dir_name = "profiles";
pub const extension = ".fset";

/// ADR-0040's bounds, and `mod-management.md` §5's.
pub const max_profiles = 64;
pub const max_enabled = 1024;
pub const max_consents = 256;
pub const max_name_bytes = 64;

/// What a profile file may hold. The list bound is the longer of the two lists; consents
/// are held to theirs when a profile is validated.
pub const limits: settings.Limits = .{
    .max_file_bytes = 256 << 10,
    .max_fields = 8,
    .max_depth = 4,
    .max_list_elements = max_enabled,
    .max_string_bytes = data.id.max_bytes,
};

const consent_fields = [_]data.Field{
    .{ .name = "id", .type = .string },
    .{ .name = "version", .type = .u32 },
};
const consent_type: data.FieldType = .{ .nested = &consent_fields };

/// `foundry:profile`, the engine's own. Its field names are on players' disks, so they are
/// kept as carefully as a manifest's (`CLAUDE.md` §7).
pub const schema: data.Schema = .{
    .id = data.SchemaId.parse("foundry:profile") catch unreachable,
    .version = 1,
    .fields = &.{
        .{ .name = "name", .type = .string, .presence = .optional },
        .{ .name = "enabled", .type = .{ .list = &.string }, .presence = .optional },
        .{ .name = "consents", .type = .{ .list = &consent_type }, .presence = .optional },
    },
};

const name_field = 0;
const enabled_field = 1;
const consents_field = 2;

/// Permission to load one package's native library, given for one version of it.
pub const Consent = struct {
    /// The package's content id, spelled.
    id: []const u8,
    version: u32,

    pub fn eql(a: Consent, b: Consent) bool {
        return a.version == b.version and std.mem.eql(u8, a.id, b.id);
    }
};

/// A profile's contents, borrowed.
pub const Contents = struct {
    name: []const u8,
    /// Content-id spellings in the player's order, each once.
    enabled: []const []const u8 = &.{},
    consents: []const Consent = &.{},
};

/// A profile read from disk, owning its strings.
pub const Profile = struct {
    arena: core.Arena,
    key: u32,
    contents: Contents,

    pub fn deinit(self: *Profile) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Why a profile file could not be used. The file is left as it is in every case.
pub const Problem = enum {
    /// This build's format, and unreadable.
    damaged,
    /// Written by another build, or against another schema: never read or replaced here.
    other_build,
    /// Readable, and past a bound or disagreeing with itself.
    refused,
    /// The file could not be read at all.
    unavailable,
};

/// One profile file, as a listing found it.
pub const Entry = struct {
    key: u32,
    /// Empty when `problem` is set.
    name: []const u8 = "",
    problem: ?Problem = null,
};

pub const Listing = struct {
    arena: core.Arena,
    /// By key, ascending.
    entries: []const Entry = &.{},

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Listing, key: u32) ?*const Entry {
        for (self.entries) |*e| if (e.key == key) return e;
        return null;
    }

    /// The smallest key no file has, or null when all `max_profiles` are taken.
    pub fn freeKey(self: *const Listing) ?u32 {
        var key: u32 = 1;
        while (key <= max_profiles) : (key += 1) {
            if (self.find(key) == null) return key;
        }
        return null;
    }
};

pub const ReadError = error{
    /// No file has this key.
    Absent,
    Damaged,
    OtherBuild,
    Refused,
    Unavailable,
} || Allocator.Error;

pub const WriteError = error{
    /// This run may not write, or the key is not one a profile may have.
    ReadOnly,
    /// The contents are past a bound or disagree with themselves. Nothing was written.
    Refused,
    /// The stored file was written by another build, and is kept.
    OtherBuild,
    /// The encoded profile is larger than a profile file may be.
    TooLarge,
    /// The filesystem refused. Said once, in the log.
    WriteFailed,
} || Allocator.Error;

/// A profile's key as a file name, or null when it is not one a profile may have.
pub fn leafOf(buf: *[16]u8, key: u32) ?[]const u8 {
    if (key == 0 or key > max_profiles) return null;
    return std.fmt.bufPrint(buf, "{d}{s}", .{ key, extension }) catch unreachable;
}

/// The key a file name spells, or null. Only the canonical spelling counts: `007.fset`,
/// `65.fset` and `3.fset.bak` are not profiles, whatever they hold.
pub fn keyOf(leaf: []const u8) ?u32 {
    if (!std.mem.endsWith(u8, leaf, extension)) return null;
    const stem = leaf[0 .. leaf.len - extension.len];
    if (stem.len == 0 or stem[0] == '0') return null;
    for (stem) |c| if (!std.ascii.isDigit(c)) return null;
    const key = std.fmt.parseInt(u32, stem, 10) catch return null;
    if (key > max_profiles) return null;
    return key;
}

/// A display name a player may give a profile: 1 to 64 bytes of UTF-8 with no control
/// characters. It is shown, never used as a path.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Whether `contents` is a profile this build would write and read back.
pub fn validate(gpa: Allocator, contents: Contents) Allocator.Error!?[]const u8 {
    if (!validName(contents.name)) return "has a name that is empty, too long, not UTF-8, or holds control characters";
    if (contents.enabled.len > max_enabled) return "enables more packages than a profile may";
    if (contents.consents.len > max_consents) return "holds more consents than a profile may";

    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    for (contents.enabled) |spelling| {
        const id = data.contentId(spelling) catch return "enables something that is not a content id";
        if ((try seen.getOrPut(gpa, id.hash)).found_existing) return "enables one package twice";
    }
    for (contents.consents, 0..) |consent, i| {
        _ = data.contentId(consent.id) catch return "consents to something that is not a content id";
        for (contents.consents[0..i]) |earlier| {
            if (earlier.eql(consent)) return "holds one consent twice";
        }
    }
    return null;
}

/// An application's profiles directory.
pub const Store = struct {
    os: *Os,
    /// `<user data>/profiles`, absolute and owned. Every file below is confined to it.
    dir: []u8,
    /// False for a run that must leave a player's files as it found them.
    persist: bool,

    /// `root` is the application's user-data directory, which must be absolute.
    pub fn open(gpa: Allocator, os: *Os, root: []const u8, persist: bool) (Allocator.Error || error{RootNotAbsolute})!Store {
        if (!platform.os.isAbsolute(root)) return error.RootNotAbsolute;
        const dir = platform.os.joinPath(gpa, &.{ root, dir_name }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RootNotAbsolute,
        };
        return .{ .os = os, .dir = dir, .persist = persist };
    }

    pub fn deinit(self: *Store, gpa: Allocator) void {
        gpa.free(self.dir);
        self.* = undefined;
    }

    /// Every profile file, readable or not, by key. A missing directory is the ordinary
    /// first run and lists nothing.
    pub fn list(self: *Store, gpa: Allocator) Allocator.Error!Listing {
        var out: Listing = .{ .arena = .init(gpa) };
        errdefer out.arena.deinit();
        const arena = out.arena.allocator();

        var listing = self.os.listDir(gpa, self.dir) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err != error.FileNotFound) log.warn("profiles could not be listed ({t})", .{err});
            return out;
        };
        defer listing.deinit();

        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        for (listing.entries) |file| {
            if (file.kind != .file) continue;
            const key = keyOf(file.name) orelse continue;
            var profile = self.read(gpa, key) catch |err| {
                const problem: Problem = switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Gone between listing and reading; not a profile any more.
                    error.Absent => continue,
                    error.Damaged => .damaged,
                    error.OtherBuild => .other_build,
                    error.Refused => .refused,
                    error.Unavailable => .unavailable,
                };
                try entries.append(gpa, .{ .key = key, .problem = problem });
                continue;
            };
            defer profile.deinit();
            try entries.append(gpa, .{ .key = key, .name = try arena.dupe(u8, profile.contents.name) });
        }
        std.mem.sort(Entry, entries.items, {}, lessByKey);
        out.entries = try arena.dupe(Entry, entries.items);
        return out;
    }

    /// Reads and validates one profile.
    pub fn read(self: *Store, gpa: Allocator, key: u32) ReadError!Profile {
        var buf: [16]u8 = undefined;
        const leaf = leafOf(&buf, key) orelse return error.Absent;
        var storage = settings.Storage.open(self.os, self.dir, leaf) catch return error.Unavailable;
        storage.limits = limits;

        var loaded = try storage.load(gpa, schema);
        defer loaded.deinit(gpa);
        const fields = switch (loaded.state) {
            .loaded => loaded.fields.?,
            .absent => return error.Absent,
            .damaged => return error.Damaged,
            .preserved => return error.OtherBuild,
            .unavailable => return error.Unavailable,
        };

        var profile: Profile = .{ .arena = .init(gpa), .key = key, .contents = .{ .name = "" } };
        errdefer profile.arena.deinit();
        const why = (try decodeContents(profile.arena.allocator(), fields, &profile.contents)) orelse
            (try validate(gpa, profile.contents));
        if (why) |reason| {
            log.warn("profiles: '{s}' {s}; leaving it as it is", .{ leaf, reason });
            return error.Refused;
        }
        return profile;
    }

    /// Writes profile `key`, atomically, merged over the file as it is now: a field whose
    /// value in `contents` equals its value in `baseline`, what this process read, keeps
    /// the file's current value. With no `baseline`, the file becomes `contents`. Never
    /// over a file another build wrote; a damaged one is copied aside first, as a settings
    /// file is.
    pub fn write(self: *Store, gpa: Allocator, key: u32, contents: Contents, baseline: ?Contents) WriteError!void {
        if (!self.persist) return error.ReadOnly;
        var buf: [16]u8 = undefined;
        const leaf = leafOf(&buf, key) orelse return error.ReadOnly;
        if (try validate(gpa, contents)) |reason| {
            log.warn("profiles: not writing '{s}': it {s}", .{ leaf, reason });
            return error.Refused;
        }

        var storage = settings.Storage.open(self.os, self.dir, leaf) catch return error.WriteFailed;
        storage.limits = limits;

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const values = try encodeContents(arena.allocator(), contents);
        const base = if (baseline) |b| try encodeContents(arena.allocator(), b) else null;
        storage.save(gpa, schema, &values, if (base) |*b| b else null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.TooLarge,
            error.Preserved => return error.OtherBuild,
            else => {
                log.warn("profiles: '{s}' could not be written ({t})", .{ leaf, err });
                return error.WriteFailed;
            },
        };
    }

    /// Deletes profile `key`'s file, whatever it holds. Deleting nothing is not an error.
    pub fn remove(self: *Store, key: u32) error{ ReadOnly, WriteFailed }!void {
        if (!self.persist) return error.ReadOnly;
        var buf: [16]u8 = undefined;
        const leaf = leafOf(&buf, key) orelse return error.ReadOnly;
        self.os.deleteFileConfined(self.dir, leaf) catch |err| {
            log.warn("profiles: '{s}' could not be deleted ({t})", .{ leaf, err });
            return error.WriteFailed;
        };
    }
};

fn lessByKey(_: void, a: Entry, b: Entry) bool {
    return a.key < b.key;
}

/// Copies a decoded block's values into `arena`, or says why they cannot be a profile.
fn decodeContents(arena: Allocator, fields: data.fpk.Fields, out: *Contents) Allocator.Error!?[]const u8 {
    const name = (fields.stringAt(name_field) catch return "has an unreadable name") orelse return "has no name";
    out.name = try arena.dupe(u8, name);

    if (fields.listAt(enabled_field) catch return "has an unreadable package list") |list| {
        if (list.len > max_enabled) return "enables more packages than a profile may";
        const enabled = try arena.alloc([]const u8, list.len);
        for (enabled, 0..) |*slot, i| {
            const value = (list.valueAt(arena, @intCast(i)) catch return "has an unreadable package list") orelse
                return "has an unreadable package list";
            if (value != .string) return "has an unreadable package list";
            slot.* = try arena.dupe(u8, value.string);
        }
        out.enabled = enabled;
    }

    if (fields.listAt(consents_field) catch return "has unreadable consents") |list| {
        if (list.len > max_consents) return "holds more consents than a profile may";
        const consents = try arena.alloc(Consent, list.len);
        for (consents, 0..) |*slot, i| {
            const entry = (list.nestedAt(@intCast(i)) catch return "has unreadable consents") orelse
                return "has unreadable consents";
            const id = (entry.stringAt(0) catch return "has unreadable consents") orelse return "has unreadable consents";
            const version = (entry.intAt(1) catch return "has unreadable consents") orelse return "has unreadable consents";
            slot.* = .{
                .id = try arena.dupe(u8, id),
                .version = std.math.cast(u32, version) orelse return "has unreadable consents",
            };
        }
        out.consents = consents;
    }
    return null;
}

/// One slot per schema field, borrowing `contents` and allocating only the list shells.
fn encodeContents(arena: Allocator, contents: Contents) Allocator.Error![schema.fields.len]?data.Value {
    const enabled = try arena.alloc(data.Value, contents.enabled.len);
    for (enabled, contents.enabled) |*v, spelling| v.* = .{ .string = spelling };
    const consents = try arena.alloc(data.Value, contents.consents.len);
    for (consents, contents.consents) |*v, consent| {
        const named = try arena.alloc(data.NamedValue, 2);
        named[0] = .{ .name = "id", .value = .{ .string = consent.id } };
        named[1] = .{ .name = "version", .value = .{ .int = consent.version } };
        v.* = .{ .nested = named };
    }
    return .{
        .{ .string = contents.name },
        if (enabled.len == 0) null else .{ .list = enabled },
        if (consents.len == 0) null else .{ .list = consents },
    };
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    os: *Os,
    store: Store,

    fn init(persist: bool) !Fixture {
        const gpa = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &path_buf);
        const root = try gpa.dupe(u8, path_buf[0..len]);
        errdefer gpa.free(root);
        const os = try Os.init(gpa, .{});
        errdefer os.deinit();
        return .{ .tmp = tmp, .root = root, .os = os, .store = try Store.open(gpa, os, root, persist) };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit(testing.allocator);
        self.os.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Writes raw bytes as a file in the profiles directory.
    fn raw(self: *Fixture, leaf: []const u8, bytes: []const u8) !void {
        try self.os.createDirPath(self.store.dir);
        const path = try platform.os.joinPath(testing.allocator, &.{ self.store.dir, leaf });
        defer testing.allocator.free(path);
        try self.os.writeFile(path, bytes);
    }

    fn bytesOf(self: *Fixture, leaf: []const u8) ![]u8 {
        const path = try platform.os.joinPath(testing.allocator, &.{ self.store.dir, leaf });
        defer testing.allocator.free(path);
        return self.os.readFile(testing.allocator, path, 1 << 20);
    }

    /// Encodes values straight through the settings codec, so a test can write what
    /// `Store.write` would refuse to.
    fn forge(self: *Fixture, leaf: []const u8, values: []const ?data.Value) !void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);
        try settings.encode(testing.allocator, schema, values, limits, &bytes);
        try self.raw(leaf, bytes.items);
    }
};

test "a profile round trips with its order and its consents, and the name never becomes a path" {
    var f = try Fixture.init(true);
    defer f.deinit();

    // Not sorted, and a name full of separators: the file is still `1.fset`.
    const contents: Contents = .{
        .name = "../../Night run ✨",
        .enabled = &.{ "z:last", "a:first", "m:middle" },
        .consents = &.{ .{ .id = "n:native", .version = 3 }, .{ .id = "n:native", .version = 2 } },
    };
    try f.store.write(testing.allocator, 1, contents, null);

    var profile = try f.store.read(testing.allocator, 1);
    defer profile.deinit();
    try testing.expectEqualStrings(contents.name, profile.contents.name);
    try testing.expectEqual(@as(usize, 3), profile.contents.enabled.len);
    for (contents.enabled, profile.contents.enabled) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, 2), profile.contents.consents.len);
    for (contents.consents, profile.contents.consents) |want, got| try testing.expect(want.eql(got));

    const bytes = try f.bytesOf("1.fset");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("FSET", bytes[0..4]);

    // An empty profile is a profile, and absent lists read back as empty.
    try f.store.write(testing.allocator, 2, .{ .name = "Empty" }, null);
    var empty = try f.store.read(testing.allocator, 2);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.contents.enabled.len);
    try testing.expectEqual(@as(usize, 0), empty.contents.consents.len);
}

test "keys are the smallest unused number, and only canonical names are profiles" {
    var f = try Fixture.init(true);
    defer f.deinit();

    var none = try f.store.list(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.entries.len);
    try testing.expectEqual(@as(?u32, 1), none.freeKey());
    none.deinit();

    for ([_]u32{ 4, 1, 2 }) |key| try f.store.write(testing.allocator, key, .{ .name = "P" }, null);
    for ([_][]const u8{ "007.fset", "65.fset", "0.fset", "3.fset.bak", "notes.txt", "x.fset" }) |leaf| {
        try f.raw(leaf, "not a profile");
    }

    var listing = try f.store.list(testing.allocator);
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 3), listing.entries.len);
    for (listing.entries, [_]u32{ 1, 2, 4 }) |e, key| {
        try testing.expectEqual(key, e.key);
        try testing.expectEqual(@as(?Problem, null), e.problem);
    }
    try testing.expectEqual(@as(?u32, 3), listing.freeKey());

    // Keys outside 1..64 are not writable at all.
    try testing.expectError(error.ReadOnly, f.store.write(testing.allocator, 0, .{ .name = "P" }, null));
    try testing.expectError(error.ReadOnly, f.store.write(testing.allocator, max_profiles + 1, .{ .name = "P" }, null));

    try f.store.remove(2);
    try f.store.remove(2);
    var after = try f.store.list(testing.allocator);
    defer after.deinit();
    try testing.expectEqual(@as(?u32, 2), after.freeKey());
}

test "hostile profiles are refused whole and left exactly as they were" {
    var f = try Fixture.init(true);
    defer f.deinit();

    var too_many: [max_consents + 1]data.Value = undefined;
    var named: [max_consents + 1][2]data.NamedValue = undefined;
    for (&too_many, &named, 0..) |*v, *pair, i| {
        pair.* = .{ .{ .name = "id", .value = .{ .string = "n:native" } }, .{ .name = "version", .value = .{ .int = @intCast(i + 1) } } };
        v.* = .{ .nested = pair };
    }
    const cases = [_]struct { leaf: []const u8, values: [3]?data.Value, problem: Problem }{
        .{ .leaf = "1.fset", .values = .{ null, null, null }, .problem = .refused },
        .{ .leaf = "2.fset", .values = .{ .{ .string = "" }, null, null }, .problem = .refused },
        .{ .leaf = "3.fset", .values = .{ .{ .string = "\xff\xfe" }, null, null }, .problem = .refused },
        .{ .leaf = "4.fset", .values = .{ .{ .string = "a\x07bell" }, null, null }, .problem = .refused },
        .{ .leaf = "5.fset", .values = .{ .{ .string = "x" ** (max_name_bytes + 1) }, null, null }, .problem = .refused },
        .{ .leaf = "6.fset", .values = .{ .{ .string = "P" }, .{ .list = &.{ .{ .string = "a:one" }, .{ .string = "a:one" } } }, null }, .problem = .refused },
        .{ .leaf = "7.fset", .values = .{ .{ .string = "P" }, .{ .list = &.{.{ .string = "Not An Id" }} }, null }, .problem = .refused },
        .{ .leaf = "8.fset", .values = .{ .{ .string = "P" }, null, .{ .list = &too_many } }, .problem = .refused },
    };
    for (cases) |case| try f.forge(case.leaf, &case.values);

    // A truncated file, a future version of the schema, and one past the size bound.
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(testing.allocator);
    try settings.encode(testing.allocator, schema, &.{ .{ .string = "P" }, null, null }, limits, &good);
    try f.raw("9.fset", good.items[0 .. good.items.len - 3]);
    var future = try testing.allocator.dupe(u8, good.items);
    defer testing.allocator.free(future);
    std.mem.writeInt(u32, future[16..20], schema.version + 1, .little);
    try f.raw("10.fset", future);
    const huge = try testing.allocator.alloc(u8, limits.max_file_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 0);
    @memcpy(huge[0..good.items.len], good.items);
    try f.raw("11.fset", huge);

    var before: [11][]u8 = undefined;
    for (&before, 1..) |*b, key| {
        var buf: [16]u8 = undefined;
        b.* = try f.bytesOf(leafOf(&buf, @intCast(key)).?);
    }
    defer for (before) |b| testing.allocator.free(b);

    var listing = try f.store.list(testing.allocator);
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 11), listing.entries.len);
    for (cases, 0..) |case, i| try testing.expectEqual(@as(?Problem, case.problem), listing.entries[i].problem);
    try testing.expectEqual(@as(?Problem, .damaged), listing.entries[8].problem);
    try testing.expectEqual(@as(?Problem, .other_build), listing.entries[9].problem);
    try testing.expectEqual(@as(?Problem, .other_build), listing.entries[10].problem);

    // A future file is never replaced, and nothing was touched by reading.
    try testing.expectError(error.OtherBuild, f.store.write(testing.allocator, 10, .{ .name = "Mine" }, null));
    for (before, 1..) |b, key| {
        var buf: [16]u8 = undefined;
        const now = try f.bytesOf(leafOf(&buf, @intCast(key)).?);
        defer testing.allocator.free(now);
        try testing.expectEqualSlices(u8, b, now);
    }

    // And the store will not write what it would refuse to read.
    try testing.expectError(error.Refused, f.store.write(testing.allocator, 12, .{ .name = "" }, null));
    try testing.expectError(error.Refused, f.store.write(testing.allocator, 12, .{ .name = "P", .enabled = &.{ "a:one", "a:one" } }, null));
}

test "a run that may not write leaves the directory as it found it" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try testing.expectError(error.ReadOnly, f.store.write(testing.allocator, 1, .{ .name = "P" }, null));
    try testing.expectError(error.ReadOnly, f.store.remove(1));
    var listing = try f.store.list(testing.allocator);
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 0), listing.entries.len);
    try testing.expect(!f.os.exists(f.store.dir));
}
