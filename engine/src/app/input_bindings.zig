//! A player's bindings on disk: `<user data>/bindings.fset` (`docs/design/input.md` §8,
//! ADR-0088).
//!
//! **A preference, never content** (ADR-0031). No package can write it, and it survives an
//! update. It holds the player's overrides, each replacing one action's bindings whole, keyed
//! by the action's content ID spelled out (I2), under the engine's own settings schema
//! `foundry:input_bindings` v1:
//!
//!     actions [ { id string  bindings [ { source axis scale threshold deadzone } ] } ]
//!
//! It is `profiles.zig`'s pattern, in the same envelope and through the same `settings.Storage`:
//! - **untrusted**: a file past a bound (256 actions, eight bindings each) or disagreeing with
//!   itself (an ID that is not one, the same action twice) is refused whole, used as no
//!   overrides, and kept exactly as it is: no save replaces it this run;
//! - a damaged file is defaults too, and the next save copies it aside first, as a settings
//!   file is;
//! - **written atomically**, and **merged by action** with the file as it is just before the
//!   write: an action whose entry this process did not change keeps the file's, so two
//!   instances rebinding different actions keep both;
//! - **an entry for an action the loaded content lacks is kept**, so a player who disables a
//!   mod and enables it again keeps their bindings for its actions;
//! - an entry this build cannot use for its action (a source it does not know, an axis that is
//!   not `x` or `y`, a number out of range) is left out of the overrides for that action alone,
//!   with a warning, and the action's defaults stand. Whether a source can feed the action's
//!   kind needs the map, and is `input.Map.apply`'s, which refuses the same way.
//!
//! Entries are kept as text, so what this build cannot read is written back as it was found.
//! **The field names are on players' disks** (CLAUDE.md §7).

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const input = @import("input");

const settings = @import("settings.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Os = platform.os.Os;

const log = core.log.scoped(.input);

pub const leaf = "bindings.fset";

/// ADR-0088's bound, the most actions `input.Overrides` holds.
pub const max_actions: usize = input.rebind.max_overrides;
/// An action's bindings, as many as a record may have.
pub const max_bindings: usize = input.schemas.max_bindings;
/// The longest axis a binding may spell. Only `x` and `y` mean anything; a longer one is kept
/// and not used.
pub const max_axis_bytes: usize = 8;

pub const limits: settings.Limits = .{
    .max_file_bytes = 512 << 10,
    .max_fields = 8,
    // The file's fields, the actions list, an entry, its bindings list and a binding.
    .max_depth = 5,
    // Above ADR-0088's bound, which `decode` holds by name, so a long list is a refused file
    // (kept, defaults this run) and not a damaged one (copied aside at the next save).
    .max_list_elements = 4 * max_actions,
    .max_string_bytes = data.id.max_bytes,
};

const binding_fields = [_]data.Field{
    .{ .name = "source", .type = .string },
    .{ .name = "axis", .type = .string },
    .{ .name = "scale", .type = .f32 },
    .{ .name = "threshold", .type = .f32 },
    .{ .name = "deadzone", .type = .f32 },
};
const binding_type: data.FieldType = .{ .nested = &binding_fields };

const entry_fields = [_]data.Field{
    .{ .name = "id", .type = .string },
    // Absent: the player unbound the action.
    .{ .name = "bindings", .type = .{ .list = &binding_type }, .presence = .optional },
};
const entry_type: data.FieldType = .{ .nested = &entry_fields };

/// `foundry:input_bindings`, the engine's own settings schema.
pub const schema: data.Schema = .{
    .id = data.SchemaId.parse("foundry:input_bindings") catch unreachable,
    .version = 1,
    .fields = &.{
        .{ .name = "actions", .type = .{ .list = &entry_type }, .presence = .optional },
    },
};

/// One binding as the file spells it.
pub const Binding = struct {
    source: []const u8,
    axis: []const u8 = "x",
    scale: f32 = 1,
    threshold: f32 = 0.5,
    deadzone: f32 = 0.15,

    pub fn eql(a: Binding, b: Binding) bool {
        // Bit patterns, so a NaN in a hostile file still compares equal to itself and an
        // untouched entry is never taken for a changed one.
        return std.mem.eql(u8, a.source, b.source) and std.mem.eql(u8, a.axis, b.axis) and
            @as(u32, @bitCast(a.scale)) == @as(u32, @bitCast(b.scale)) and
            @as(u32, @bitCast(a.threshold)) == @as(u32, @bitCast(b.threshold)) and
            @as(u32, @bitCast(a.deadzone)) == @as(u32, @bitCast(b.deadzone));
    }
};

/// One action's override: its ID spelled out, and the bindings that replace its defaults.
pub const Entry = struct {
    action: []const u8,
    bindings: []const Binding = &.{},

    pub fn id(self: Entry) ContentId {
        return ContentId.fromString(self.action);
    }

    pub fn eql(a: Entry, b: Entry) bool {
        if (!std.mem.eql(u8, a.action, b.action) or a.bindings.len != b.bindings.len) return false;
        for (a.bindings, b.bindings) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};

/// A set of entries owning their strings, in content-ID order (ascending hash).
pub const Contents = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry = &.{},

    pub fn init(gpa: Allocator) Contents {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Contents) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Contents, action: ContentId) ?*const Entry {
        return findIn(self.entries, action);
    }
};

/// Why a file could not be used. It is left as it is in every case.
pub const Problem = enum {
    /// This build's format, and unreadable. The next save copies it aside.
    damaged,
    /// Written by another build or against another schema: never read or replaced here.
    other_build,
    /// Readable, and past a bound or disagreeing with itself. Not replaced this run.
    refused,
    /// The file could not be read at all.
    unavailable,
};

pub const Read = struct {
    contents: Contents,
    /// Null when the file was read or there was none.
    problem: ?Problem = null,
};

pub const WriteError = error{
    /// This run may not write.
    ReadOnly,
    /// The stored file was written by another build, or is past a bound; it is kept.
    OtherBuild,
    Refused,
    /// The merged set would be past a bound. Nothing was written.
    TooMany,
    /// The filesystem refused. Said once, in the log.
    WriteFailed,
} || Allocator.Error;

/// The file, under an application's user-data directory.
pub const Store = struct {
    os: *Os,
    /// The user-data directory, absolute and owned.
    dir: []u8,
    /// False for a run that must leave a player's files as it found them.
    persist: bool,
    /// Set when this run found a file it must not replace.
    kept: bool = false,

    pub fn open(gpa: Allocator, os: *Os, root: []const u8, persist: bool) (Allocator.Error || error{RootNotAbsolute})!Store {
        if (!platform.os.isAbsolute(root)) return error.RootNotAbsolute;
        return .{ .os = os, .dir = try gpa.dupe(u8, root), .persist = persist };
    }

    pub fn deinit(self: *Store, gpa: Allocator) void {
        gpa.free(self.dir);
        self.* = undefined;
    }

    /// Reads and validates the file. Never fails but for memory: every problem reads as no
    /// overrides, says so once, and leaves the file as it is.
    pub fn read(self: *Store, gpa: Allocator) Allocator.Error!Read {
        var out: Read = .{ .contents = .init(gpa) };
        errdefer out.contents.deinit();
        const problem = try self.readInto(gpa, &out.contents, true);
        out.problem = problem;
        if (problem) |p| switch (p) {
            .other_build, .refused => self.kept = true,
            .damaged, .unavailable => {},
        };
        return out;
    }

    /// The file's entries into `into`, or why there are none.
    fn readInto(self: *Store, gpa: Allocator, into: *Contents, report: bool) Allocator.Error!?Problem {
        var storage = settings.Storage.open(self.os, self.dir, leaf) catch return .unavailable;
        storage.limits = limits;
        var loaded = try storage.load(gpa, schema);
        defer loaded.deinit(gpa);
        const fields = switch (loaded.state) {
            .loaded => loaded.fields.?,
            .absent => return null,
            .damaged => return .damaged,
            .preserved => return .other_build,
            .unavailable => return .unavailable,
        };
        if (try decode(into.arena.allocator(), fields, &into.entries)) |reason| {
            if (report) log.warn("bindings: '{s}' {s}; using no overrides and leaving it as it is", .{ leaf, reason });
            into.entries = &.{};
            return .refused;
        }
        return null;
    }

    /// Writes `mine`, merged by action over the file as it is now, and answers what was
    /// written. An action whose entry in `mine` equals its entry in `baseline` (what this
    /// process read or last wrote, present or absent alike) keeps the file's current entry;
    /// one that differs takes `mine`'s, or leaves the file when `mine` has none. Every other
    /// entry in the file is kept.
    pub fn write(self: *Store, gpa: Allocator, mine: []const Entry, baseline: []const Entry) WriteError!Contents {
        if (!self.persist) return error.ReadOnly;
        if (self.kept) return error.OtherBuild;

        var current = Contents.init(gpa);
        defer current.deinit();
        if (try self.readInto(gpa, &current, false)) |problem| switch (problem) {
            .other_build => {
                self.kept = true;
                return error.OtherBuild;
            },
            .refused => {
                self.kept = true;
                return error.Refused;
            },
            // Started from nothing; `Storage.save` copies a damaged file aside first.
            .damaged, .unavailable => {},
        };

        var out = Contents.init(gpa);
        errdefer out.deinit();
        out.entries = try merge(out.arena.allocator(), current.entries, mine, baseline);
        if (out.entries.len > max_actions) return error.TooMany;

        var storage = settings.Storage.open(self.os, self.dir, leaf) catch return error.WriteFailed;
        storage.limits = limits;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const values = try encode(arena.allocator(), out.entries);
        storage.save(gpa, schema, &values, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Preserved => {
                self.kept = true;
                return error.OtherBuild;
            },
            else => {
                log.warn("bindings: '{s}' could not be written ({t})", .{ leaf, err });
                return error.WriteFailed;
            },
        };
        return out;
    }
};

/// `current` with every action `mine` changed against `baseline` laid over it, in content-ID
/// order. Strings are copied into `arena`.
pub fn merge(arena: Allocator, current: []const Entry, mine: []const Entry, baseline: []const Entry) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (current) |e| try out.append(arena, try dupeEntry(arena, e));
    for ([2][]const Entry{ mine, baseline }) |side| for (side) |e| {
        const id = e.id();
        const ours = findIn(mine, id);
        const before = findIn(baseline, id);
        const changed = if (ours) |o| (if (before) |b| !o.eql(b.*) else true) else before != null;
        if (!changed) continue;
        const at = lowerBound(out.items, id);
        const here = at < out.items.len and out.items[at].id().eql(id);
        if (ours) |o| {
            const copy = try dupeEntry(arena, o.*);
            if (here) out.items[at] = copy else try out.insert(arena, at, copy);
        } else if (here) {
            _ = out.orderedRemove(at);
        }
    };
    return out.items;
}

/// The overrides `entries` give, for `input.Map.apply`. An entry this build cannot read for
/// its action is left out, with a warning, and the action's defaults stand; an entry for an
/// action the content lacks is kept, and `apply` passes over it. Answers how many were left
/// out.
pub fn toOverrides(gpa: Allocator, entries: []const Entry, out: *input.Overrides) Allocator.Error!u32 {
    var left_out: u32 = 0;
    for (entries) |e| {
        var bindings: [max_bindings]input.Binding = undefined;
        const reason: ?[]const u8 = for (e.bindings, 0..) |b, i| {
            const source = input.Source.parse(b.source) orelse break "names a source this build does not know";
            const axis = std.meta.stringToEnum(input.Component, b.axis) orelse break "names an axis that is not x or y";
            bindings[i] = .{ .source = source, .axis = axis, .scale = b.scale, .threshold = b.threshold, .deadzone = b.deadzone };
        } else null;
        if (reason) |why| {
            log.warn("bindings: the override for '{s}' {s}; its defaults stand", .{ e.action, why });
            left_out += 1;
            continue;
        }
        out.set(gpa, e.id(), bindings[0..e.bindings.len]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("bindings: the override for '{s}' is not usable ({t}); its defaults stand", .{ e.action, err });
                left_out += 1;
            },
        };
    }
    return left_out;
}

/// Spells `overrides` as entries, into `arena`. An action's spelling comes from `names` (the
/// loaded store, whose records carry theirs) or from `known` (the file as read, for an action
/// the content lacks). An override neither can spell cannot be written: `error.Unnamed`.
pub fn fromOverrides(
    arena: Allocator,
    overrides: *const input.Overrides,
    names: ?*const data.Store,
    known: []const Entry,
) (Allocator.Error || error{Unnamed})![]Entry {
    const out = try arena.alloc(Entry, overrides.slice().len);
    for (overrides.slice(), out) |*o, *slot| {
        const spelling: []const u8 = blk: {
            if (names) |store| if (store.lookup(o.action)) |record| break :blk record.name;
            if (findIn(known, o.action)) |e| break :blk e.action;
            return error.Unnamed;
        };
        const bindings = try arena.alloc(Binding, o.binding_count);
        for (o.bindings(), bindings) |b, *t| {
            var buf: [input.source.max_name]u8 = undefined;
            t.* = .{
                .source = try arena.dupe(u8, b.source.name(&buf)),
                .axis = @tagName(b.axis),
                .scale = b.scale,
                .threshold = b.threshold,
                .deadzone = b.deadzone,
            };
        }
        slot.* = .{ .action = try arena.dupe(u8, spelling), .bindings = bindings };
    }
    // `Overrides` keeps content-ID order already, which is the file's.
    return out;
}

fn findIn(entries: []const Entry, action: ContentId) ?*const Entry {
    const at = lowerBound(entries, action);
    if (at < entries.len and entries[at].id().eql(action)) return &entries[at];
    return null;
}

fn lowerBound(entries: []const Entry, action: ContentId) usize {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].id().hash < action.hash) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn dupeEntry(arena: Allocator, e: Entry) Allocator.Error!Entry {
    const bindings = try arena.alloc(Binding, e.bindings.len);
    for (e.bindings, bindings) |b, *slot| {
        slot.* = b;
        slot.source = try arena.dupe(u8, b.source);
        slot.axis = try arena.dupe(u8, b.axis);
    }
    return .{ .action = try arena.dupe(u8, e.action), .bindings = bindings };
}

/// The file's entries into `arena`, sorted, or why it cannot be a bindings file.
fn decode(arena: Allocator, fields: data.fpk.Fields, out: *[]const Entry) Allocator.Error!?[]const u8 {
    const list = (fields.listAt(0) catch return "has an unreadable action list") orelse {
        out.* = &.{};
        return null;
    };
    if (list.len > max_actions) return "overrides more actions than a bindings file may";
    const entries = try arena.alloc(Entry, list.len);
    for (entries, 0..) |*slot, i| {
        const entry = (list.nestedAt(@intCast(i)) catch return "has an unreadable action") orelse return "has an unreadable action";
        const name = (entry.stringAt(0) catch return "has an unreadable action") orelse return "has an action with no id";
        _ = data.contentId(name) catch return "has an action whose id is not a content id";
        slot.* = .{ .action = try arena.dupe(u8, name) };
        const bl = (entry.listAt(1) catch return "has an unreadable binding list") orelse continue;
        if (bl.len > max_bindings) return "gives an action more than 8 bindings";
        const bindings = try arena.alloc(Binding, bl.len);
        for (bindings, 0..) |*b, j| {
            const f = (bl.nestedAt(@intCast(j)) catch return "has an unreadable binding") orelse return "has an unreadable binding";
            const source = (f.stringAt(0) catch return "has an unreadable binding") orelse return "has an unreadable binding";
            const axis = (f.stringAt(1) catch return "has an unreadable binding") orelse return "has an unreadable binding";
            if (source.len == 0 or source.len > input.source.max_name) return "has a binding whose source is empty or longer than 32 bytes";
            if (axis.len > max_axis_bytes) return "has a binding whose axis is longer than 8 bytes";
            b.* = .{
                .source = try arena.dupe(u8, source),
                .axis = try arena.dupe(u8, axis),
                .scale = @floatCast((f.floatAt(2) catch return "has an unreadable binding") orelse return "has an unreadable binding"),
                .threshold = @floatCast((f.floatAt(3) catch return "has an unreadable binding") orelse return "has an unreadable binding"),
                .deadzone = @floatCast((f.floatAt(4) catch return "has an unreadable binding") orelse return "has an unreadable binding"),
            };
        }
        slot.bindings = bindings;
    }
    std.mem.sort(Entry, entries, {}, lessById);
    for (entries[0..entries.len -| 1], 1..) |e, i| {
        if (e.id().eql(entries[i].id())) return "overrides one action twice";
    }
    out.* = entries;
    return null;
}

/// Content-ID order, the file's.
pub fn lessById(_: void, a: Entry, b: Entry) bool {
    return a.id().hash < b.id().hash;
}

fn encode(arena: Allocator, entries: []const Entry) Allocator.Error![schema.fields.len]?data.Value {
    const list = try arena.alloc(data.Value, entries.len);
    for (list, entries) |*v, e| {
        const bindings = try arena.alloc(data.Value, e.bindings.len);
        for (bindings, e.bindings) |*bv, b| {
            const named = try arena.alloc(data.NamedValue, binding_fields.len);
            named[0] = .{ .name = "source", .value = .{ .string = b.source } };
            named[1] = .{ .name = "axis", .value = .{ .string = b.axis } };
            named[2] = .{ .name = "scale", .value = .{ .float = b.scale } };
            named[3] = .{ .name = "threshold", .value = .{ .float = b.threshold } };
            named[4] = .{ .name = "deadzone", .value = .{ .float = b.deadzone } };
            bv.* = .{ .nested = named };
        }
        // An unbound action leaves `bindings` out, which reads back as absent.
        const named = try arena.alloc(data.NamedValue, if (bindings.len == 0) 1 else 2);
        named[0] = .{ .name = "id", .value = .{ .string = e.action } };
        if (bindings.len != 0) named[1] = .{ .name = "bindings", .value = .{ .list = bindings } };
        v.* = .{ .nested = named };
    }
    return .{if (list.len == 0) null else .{ .list = list }};
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

    fn raw(self: *Fixture, bytes: []const u8) !void {
        const path = try platform.os.joinPath(testing.allocator, &.{ self.root, leaf });
        defer testing.allocator.free(path);
        try self.os.writeFile(path, bytes);
    }

    fn fileBytes(self: *Fixture) ![]u8 {
        const path = try platform.os.joinPath(testing.allocator, &.{ self.root, leaf });
        defer testing.allocator.free(path);
        return self.os.readFile(testing.allocator, path, 1 << 20);
    }

    /// Encodes entries straight through the settings codec, so a test can write what
    /// `Store.write` never would.
    fn forge(self: *Fixture, entries: []const Entry) !void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const values = try encode(arena.allocator(), entries);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try settings.encode(testing.allocator, schema, &values, limits, &out);
        try self.raw(out.items);
    }

    fn readBack(self: *Fixture) !Read {
        return self.store.read(testing.allocator);
    }
};

const jump: Entry = .{ .action = "court:action.jump", .bindings = &.{ .{ .source = "key.j" }, .{ .source = "pad.north" } } };
const walk: Entry = .{ .action = "court:action.move", .bindings = &.{.{ .source = "pad.right_stick", .deadzone = 0.3 }} };
const use: Entry = .{ .action = "court:action.use", .bindings = &.{.{ .source = "key.f", .axis = "x", .scale = 1, .threshold = 0.5 }} };
const unbound: Entry = .{ .action = "court:action.taunt" };

fn sorted(comptime entries: []const Entry) [entries.len]Entry {
    var out: [entries.len]Entry = entries[0..entries.len].*;
    std.mem.sort(Entry, &out, {}, lessById);
    return out;
}

fn expectEntries(want: []const Entry, got: []const Entry) !void {
    try testing.expectEqual(want.len, got.len);
    for (want) |w| {
        const g = findIn(got, w.id()) orelse return error.TestExpectedEntry;
        try testing.expect(w.eql(g.*));
    }
}

test "the bindings file round trips, unbound actions and all, in content-ID order" {
    var f = try Fixture.init(true);
    defer f.deinit();

    // No file is the ordinary first run: no overrides and no problem.
    var none = try f.readBack();
    try testing.expectEqual(@as(?Problem, null), none.problem);
    try testing.expectEqual(@as(usize, 0), none.contents.entries.len);
    none.contents.deinit();

    const mine = sorted(&.{ jump, walk, use, unbound });
    var written = try f.store.write(testing.allocator, &mine, &.{});
    defer written.deinit();
    try expectEntries(&mine, written.entries);

    var back = try f.readBack();
    defer back.contents.deinit();
    try testing.expectEqual(@as(?Problem, null), back.problem);
    try expectEntries(&mine, back.contents.entries);
    for (back.contents.entries[1..], 0..) |e, i| try testing.expect(back.contents.entries[i].id().hash < e.id().hash);

    const file = try f.fileBytes();
    defer testing.allocator.free(file);
    try testing.expectEqualStrings("FSET", file[0..4]);

    // And they become overrides, an unbound action as zero bindings.
    var overrides: input.Overrides = .empty;
    defer overrides.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), try toOverrides(testing.allocator, back.contents.entries, &overrides));
    try testing.expectEqual(@as(usize, 4), overrides.slice().len);
    try testing.expectEqual(@as(u8, 0), overrides.get(unbound.id()).?.binding_count);
    const j = overrides.get(jump.id()).?;
    try testing.expectEqual(@as(u8, 2), j.binding_count);
    try testing.expect(j.bindings()[0].source.eql(.{ .key = .j }));
    try testing.expectEqual(@as(f32, 0.3), overrides.get(walk.id()).?.bindings()[0].deadzone);
}

test "past-bound and damaged bindings files are refused and left untouched" {
    var f = try Fixture.init(true);
    defer f.deinit();
    var names: [max_actions + 1][24]u8 = undefined;
    var many: [max_actions + 1]Entry = undefined;
    for (&many, &names, 0..) |*e, *n, i| e.* = .{ .action = try std.fmt.bufPrint(n, "court:action.a{d}", .{i}) };
    const nine = [_]Binding{.{ .source = "key.a" }} ** (max_bindings + 1);
    const long_source = [_]Binding{.{ .source = "key." ++ "a" ** 40 }};
    const cases = [_][]const Entry{
        &many,
        &.{.{ .action = "court:action.jump", .bindings = &nine }},
        &.{.{ .action = "Not An Id" }},
        &.{ jump, jump },
        &.{.{ .action = "court:action.jump", .bindings = &long_source }},
        &.{.{ .action = "court:action.jump", .bindings = &.{.{ .source = "" }} }},
        &.{.{ .action = "court:action.jump", .bindings = &.{.{ .source = "key.j", .axis = "diagonally" }} }},
    };
    for (cases) |entries| {
        try f.forge(entries);
        const before = try f.fileBytes();
        defer testing.allocator.free(before);
        f.store.kept = false;
        var read = try f.readBack();
        defer read.contents.deinit();
        try testing.expectEqual(@as(?Problem, .refused), read.problem);
        try testing.expectEqual(@as(usize, 0), read.contents.entries.len);
        // A refused file is kept for the rest of the run, whatever a save asks.
        var mine = [_]Entry{use};
        try testing.expectError(error.OtherBuild, f.store.write(testing.allocator, &mine, &.{}));
        const after = try f.fileBytes();
        defer testing.allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }

    // A damaged file reads as no overrides and is untouched by reading; a save keeps it aside.
    try f.raw("FSET half a bindings file");
    f.store.kept = false;
    var damaged = try f.readBack();
    defer damaged.contents.deinit();
    try testing.expectEqual(@as(?Problem, .damaged), damaged.problem);
    const still = try f.fileBytes();
    defer testing.allocator.free(still);
    try testing.expectEqualStrings("FSET half a bindings file", still);
    var mine = [_]Entry{use};
    var written = try f.store.write(testing.allocator, &mine, &.{});
    written.deinit();
    const aside_path = try platform.os.joinPath(testing.allocator, &.{ f.root, leaf ++ ".bak" });
    defer testing.allocator.free(aside_path);
    const aside = try f.os.readFile(testing.allocator, aside_path, 1 << 10);
    defer testing.allocator.free(aside);
    try testing.expectEqualStrings("FSET half a bindings file", aside);
}

test "an override for an action the content lacks is kept, and one this build cannot read is left out alone" {
    var f = try Fixture.init(true);
    defer f.deinit();
    const odd: Entry = .{ .action = "mod:action.cast", .bindings = &.{.{ .source = "pad.paddle_9" }} };
    const flat: Entry = .{ .action = "court:action.crouch", .bindings = &.{.{ .source = "key.c", .axis = "z" }} };
    const zero: Entry = .{ .action = "court:action.dash", .bindings = &.{.{ .source = "key.d", .scale = 0 }} };
    try f.forge(&sorted(&.{ jump, odd, flat, zero }));
    var read = try f.readBack();
    defer read.contents.deinit();
    try testing.expectEqual(@as(usize, 4), read.contents.entries.len);

    var overrides: input.Overrides = .empty;
    defer overrides.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), try toOverrides(testing.allocator, read.contents.entries, &overrides));
    try testing.expectEqual(@as(usize, 1), overrides.slice().len);
    try testing.expect(overrides.get(jump.id()) != null);

    // A write that adds `use` to the set it read keeps every one of them as text, the ones
    // this build cannot read included.
    var mine: std.ArrayList(Entry) = .empty;
    defer mine.deinit(testing.allocator);
    try mine.appendSlice(testing.allocator, read.contents.entries);
    try mine.append(testing.allocator, use);
    std.mem.sort(Entry, mine.items, {}, lessById);
    var written = try f.store.write(testing.allocator, mine.items, read.contents.entries);
    defer written.deinit();
    try expectEntries(&.{ jump, odd, flat, zero, use }, written.entries);
    var back = try f.readBack();
    defer back.contents.deinit();
    try expectEntries(&.{ jump, odd, flat, zero, use }, back.contents.entries);
}

test "two writers rebinding different actions keep both, and a reset removes only its own" {
    var f = try Fixture.init(true);
    defer f.deinit();
    // Both instances start from the same file.
    try f.forge(&sorted(&.{ jump, walk }));
    var first = try f.readBack();
    defer first.contents.deinit();
    var second = try f.readBack();
    defer second.contents.deinit();

    // The first rebinds Use; the second resets Jump and changes Move.
    const moved: Entry = .{ .action = walk.action, .bindings = &.{.{ .source = "pad.left_stick" }} };
    var a = try f.store.write(testing.allocator, &sorted(&.{ jump, walk, use }), first.contents.entries);
    defer a.deinit();
    var b = try f.store.write(testing.allocator, &.{moved}, second.contents.entries);
    defer b.deinit();
    try expectEntries(&.{ moved, use }, b.entries);

    var back = try f.readBack();
    defer back.contents.deinit();
    try expectEntries(&.{ moved, use }, back.contents.entries);

    // The same action changed in both is the last writer's: the first, which saw Move as
    // `walk` and Use, now changes Move again.
    const third: Entry = .{ .action = walk.action, .bindings = &.{.{ .source = "key.m" }} };
    var c = try f.store.write(testing.allocator, &sorted(&.{ third, use }), &sorted(&.{ walk, use }));
    defer c.deinit();
    try expectEntries(&.{ third, use }, c.entries);
}

test "a run that may not write leaves the file as it found it" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try testing.expectError(error.ReadOnly, f.store.write(testing.allocator, &.{use}, &.{}));
    const path = try platform.os.joinPath(testing.allocator, &.{ f.root, leaf });
    defer testing.allocator.free(path);
    try testing.expect(!f.os.exists(path));
    var read = try f.readBack();
    defer read.contents.deinit();
    try testing.expectEqual(@as(usize, 0), read.contents.entries.len);
}

test "overrides are spelled from the store or from the file, and never invented" {
    var overrides: input.Overrides = .empty;
    defer overrides.deinit(testing.allocator);
    try overrides.set(testing.allocator, jump.id(), &.{ .{ .source = .{ .key = .j } }, .{ .source = .{ .pad_button = .north } } });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spelled = try fromOverrides(arena.allocator(), &overrides, null, &.{jump});
    try expectEntries(&.{jump}, spelled);
    try overrides.set(testing.allocator, use.id(), &.{});
    try testing.expectError(error.Unnamed, fromOverrides(arena.allocator(), &overrides, null, &.{jump}));
}
