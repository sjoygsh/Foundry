//! `Map`: every action and context in the merged store, validated (`docs/design/input.md` §6.5).
//!
//! Built from the store, not from a package, so the answer is the one the load order gives: a
//! mod's record replaces the game's whole, and an action a mod adds to the game's context is in
//! it with no override of the context.
//!
//! **Content is untrusted, and nothing here fails the load.** Each problem is a warning:
//! - a record wrong in a way this engine understands is refused whole, naming the field, and the
//!   map is built without it, which is `ui_theme`'s rule;
//! - a binding naming a source this build does not know is skipped and the rest kept, so content
//!   written for a later engine still runs;
//! - past a bound, the records last in content-ID order are left out, so which ones is decided
//!   by their IDs and never by the load order or the store's layout (I9).
//!
//! Actions and contexts are kept in **content-ID order** (ascending hash, I9's documented order),
//! and found by a sorted search.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const schemas = @import("schemas.zig");
const source_mod = @import("source.zig");
const rebind = @import("rebind.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Binding = schemas.Binding;
const Kind = schemas.Kind;
const Source = source_mod.Source;

const log = core.log.scoped(.input);

/// Bounds (§6.5).
pub const max_actions: usize = 256;
pub const max_contexts: usize = 64;
/// Warnings kept for a caller to read. More are counted, not kept or logged, so hostile content
/// cannot make a load print without end.
pub const max_warnings: usize = 64;

pub const Context = struct {
    id: ContentId,
    /// Higher is read first; ties by content ID (§7).
    priority: i32,
    /// Sources bound here are hidden from lower contexts.
    blocks: bool,
};

pub const Action = struct {
    id: ContentId,
    kind: Kind,
    rebindable: bool,
    /// Indices into `Map.contexts`, in the record's order.
    context_buffer: [schemas.max_action_contexts]u8 = undefined,
    context_count: u8 = 0,
    binding_buffer: [schemas.max_bindings]Binding = undefined,
    binding_count: u8 = 0,

    pub fn contexts(self: *const Action) []const u8 {
        return self.context_buffer[0..self.context_count];
    }

    pub fn bindings(self: *const Action) []const Binding {
        return self.binding_buffer[0..self.binding_count];
    }
};

/// Why a record, or one binding, is not in the map as written.
pub const Problem = schemas.DecodeError || error{
    /// A binding names a source this build does not know; it was skipped, the record kept.
    UnknownSource,
    /// An action names a context that is not a `foundry:input_context` in the map.
    NotAContext,
    /// The map already holds 256 actions earlier in content-ID order.
    ActionsFull,
    /// The map already holds 64 contexts earlier in content-ID order.
    ContextsFull,
    /// A player's override for an action marked `rebindable false`; its defaults stand.
    NotRebindable,
};

pub const Warning = struct {
    record: ContentId,
    problem: Problem,
    /// The binding's index in the record, when the problem is one binding's.
    binding: ?u8 = null,

    /// Whether the record was left out of the map, rather than kept without one binding.
    pub fn refused(self: Warning) bool {
        return self.problem != error.UnknownSource;
    }
};

/// A phrase for a log line or a diagnostic: "input action '<id>' <phrase>".
pub fn describe(problem: Problem) []const u8 {
    return switch (problem) {
        error.UnknownSource => "has a binding whose source this build does not know; it is skipped",
        error.NotAContext => "names a context that is not a foundry:input_context",
        error.ActionsFull => "is past the 256 actions a map holds",
        error.ContextsFull => "is past the 64 contexts a map holds",
        error.NotRebindable => "is not rebindable; the player's override is ignored",
        else => |err| schemas.describe(@errorCast(err)),
    };
}

pub const Map = struct {
    /// In content-ID order.
    actions: []Action = &.{},
    /// In content-ID order.
    contexts: []Context = &.{},
    warnings: []Warning = &.{},
    /// Warnings past `max_warnings`, counted only.
    warnings_dropped: u32 = 0,

    pub const empty: Map = .{};

    /// Builds the map from every `foundry:input_action` and `foundry:input_context` in `store`.
    /// Fails only for memory; every problem with the content is a warning.
    pub fn build(gpa: Allocator, store: *const data.Store) Allocator.Error!Map {
        var notes: Notes = .{};
        errdefer notes.list.deinit(gpa);

        // Contexts first, since an action is checked against them.
        var contexts: std.ArrayList(Named(Context)) = .empty;
        defer contexts.deinit(gpa);
        var it = store.iterate(schemas.context.id);
        while (it.next()) |record| {
            const value = schemas.decodeContext(record.fields) catch |err| {
                try notes.add(gpa, "input context", record.name, .{ .record = record.id, .problem = err });
                continue;
            };
            try contexts.append(gpa, .{ .name = record.name, .value = .{ .id = record.id, .priority = value.priority, .blocks = value.blocks } });
        }
        sortById(Context, contexts.items);
        if (contexts.items.len > max_contexts) {
            for (contexts.items[max_contexts..]) |late| try notes.add(gpa, "input context", late.name, .{ .record = late.value.id, .problem = error.ContextsFull });
            contexts.shrinkRetainingCapacity(max_contexts);
        }

        var actions: std.ArrayList(Named(Action)) = .empty;
        defer actions.deinit(gpa);
        it = store.iterate(schemas.action.id);
        while (it.next()) |record| {
            var fault: schemas.Fault = .{};
            const value = schemas.decodeAction(record.fields, &fault) catch |err| {
                try notes.add(gpa, "input action", record.name, .{ .record = record.id, .problem = err, .binding = fault.binding });
                continue;
            };
            var out: Action = .{ .id = record.id, .kind = value.kind, .rebindable = value.rebindable };
            const resolved = for (value.contexts()) |id| {
                const index = indexById(Context, contexts.items, id) orelse break false;
                out.context_buffer[out.context_count] = @intCast(index);
                out.context_count += 1;
            } else true;
            if (!resolved) {
                try notes.add(gpa, "input action", record.name, .{ .record = record.id, .problem = error.NotAContext });
                continue;
            }
            @memcpy(out.binding_buffer[0..value.binding_count], value.bindings());
            out.binding_count = value.binding_count;
            for (0..schemas.max_bindings) |b| {
                if (value.unknown_sources & (@as(u8, 1) << @intCast(b)) == 0) continue;
                try notes.add(gpa, "input action", record.name, .{ .record = record.id, .problem = error.UnknownSource, .binding = @intCast(b) });
            }
            try actions.append(gpa, .{ .name = record.name, .value = out });
        }
        sortById(Action, actions.items);
        if (actions.items.len > max_actions) {
            for (actions.items[max_actions..]) |late| try notes.add(gpa, "input action", late.name, .{ .record = late.value.id, .problem = error.ActionsFull });
            actions.shrinkRetainingCapacity(max_actions);
        }

        const out_contexts = try gpa.alloc(Context, contexts.items.len);
        errdefer gpa.free(out_contexts);
        for (contexts.items, out_contexts) |named, *slot| slot.* = named.value;
        const out_actions = try gpa.alloc(Action, actions.items.len);
        errdefer gpa.free(out_actions);
        for (actions.items, out_actions) |named, *slot| slot.* = named.value;
        const warnings = try notes.list.toOwnedSlice(gpa);
        return .{ .actions = out_actions, .contexts = out_contexts, .warnings = warnings, .warnings_dropped = notes.dropped };
    }

    /// The effective map: this one with a player's overrides laid over it (§8, ADR-0088).
    ///
    /// An override replaces its action's bindings whole. One for an action marked `rebindable
    /// false` is ignored, and one whose binding cannot feed its action's kind or has a number
    /// out of range is refused for that action alone; either way the defaults stand and a
    /// warning says so, once for each `apply`. An override for an action this map does not hold
    /// is ignored without a word: it belongs to content that is not loaded, and the bindings
    /// file keeps it for when it is. The answer's `warnings` are the overrides' alone; this
    /// map's stay this map's. Fails only for memory.
    pub fn apply(self: *const Map, gpa: Allocator, overrides: *const rebind.Overrides) Allocator.Error!Map {
        var notes: Notes = .{};
        errdefer notes.list.deinit(gpa);
        const out_contexts = try gpa.dupe(Context, self.contexts);
        errdefer gpa.free(out_contexts);
        const out_actions = try gpa.dupe(Action, self.actions);
        errdefer gpa.free(out_actions);
        for (out_actions) |*a| {
            const o = overrides.get(a.id) orelse continue;
            if (!a.rebindable) {
                try notes.addId(gpa, .{ .record = a.id, .problem = error.NotRebindable });
                continue;
            }
            const refusal: ?Warning = for (o.bindings(), 0..) |b, i| {
                b.validate() catch |err| break .{ .record = a.id, .problem = err, .binding = @intCast(i) };
                if (!a.kind.accepts(b.source.class())) break .{ .record = a.id, .problem = error.SourceCannotFeedKind, .binding = @intCast(i) };
            } else null;
            if (refusal) |w| {
                try notes.addId(gpa, w);
                continue;
            }
            @memcpy(a.binding_buffer[0..o.binding_count], o.bindings());
            a.binding_count = o.binding_count;
        }
        const warnings = try notes.list.toOwnedSlice(gpa);
        return .{ .actions = out_actions, .contexts = out_contexts, .warnings = warnings, .warnings_dropped = notes.dropped };
    }

    /// The other actions that would read `source` while `action_id` does (§8): those binding a
    /// source that shares a physical input with it, in a context that can be enabled with one
    /// of `action_id`'s, where neither hides it from the other. Two actions in one context
    /// always conflict. Two in different contexts conflict unless the one read first blocks,
    /// since a blocking context hides what it binds from the other, and `source` is bound in
    /// both.
    ///
    /// Written into `out` in content-ID order, as many as fit. The engine decides nothing more:
    /// whether a conflict swaps, refuses or stands is the game's call.
    pub fn conflicts(self: *const Map, source: Source, action_id: ContentId, out: []ContentId) []ContentId {
        const mine = self.action(action_id) orelse return out[0..0];
        const wanted = source_mod.physicalOf(source);
        var n: usize = 0;
        for (self.actions) |*other| {
            if (n == out.len) break;
            if (other.id.eql(action_id)) continue;
            const binds = for (other.bindings()) |b| {
                if (source_mod.physicalOf(b.source).intersectWith(wanted).count() != 0) break true;
            } else false;
            if (!binds) continue;
            const together = outer: for (mine.contexts()) |ca| {
                for (other.contexts()) |cb| {
                    if (ca == cb) break :outer true;
                    const first = if (self.readsFirst(ca, cb)) ca else cb;
                    if (!self.contexts[first].blocks) break :outer true;
                }
            } else false;
            if (!together) continue;
            out[n] = other.id;
            n += 1;
        }
        return out[0..n];
    }

    /// Whether context `a` is read before context `b` when both are enabled: higher priority
    /// first, ties by content ID ascending (§7).
    pub fn readsFirst(self: *const Map, a: u8, b: u8) bool {
        const ca = self.contexts[a];
        const cb = self.contexts[b];
        if (ca.priority != cb.priority) return ca.priority > cb.priority;
        return ca.id.hash < cb.id.hash;
    }

    pub fn deinit(self: *Map, gpa: Allocator) void {
        gpa.free(self.actions);
        gpa.free(self.contexts);
        gpa.free(self.warnings);
        self.* = .empty;
    }

    /// The action's index in `actions`, or null.
    pub fn find(self: *const Map, id: ContentId) ?u16 {
        return @intCast(indexById(Action, self.actions, id) orelse return null);
    }

    pub fn action(self: *const Map, id: ContentId) ?*const Action {
        return &self.actions[self.find(id) orelse return null];
    }

    /// The context's index in `contexts`, or null.
    pub fn findContext(self: *const Map, id: ContentId) ?u8 {
        return @intCast(indexById(Context, self.contexts, id) orelse return null);
    }

    pub fn context(self: *const Map, id: ContentId) ?*const Context {
        return &self.contexts[self.findContext(id) orelse return null];
    }
};

/// A value with its record's spelling, borrowed from the store for the build alone.
fn Named(comptime T: type) type {
    return struct { name: []const u8, value: T };
}

fn sortById(comptime T: type, items: []Named(T)) void {
    std.mem.sort(Named(T), items, {}, struct {
        fn less(_: void, a: Named(T), b: Named(T)) bool {
            return a.value.id.hash < b.value.id.hash;
        }
    }.less);
}

/// A binary search over values sorted by `sortById` or kept in that order.
fn indexById(comptime T: type, items: anytype, id: ContentId) ?usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = idOf(T, items[mid]).hash;
        if (at == id.hash) return mid;
        if (at < id.hash) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn idOf(comptime T: type, item: anytype) ContentId {
    return if (@TypeOf(item) == T) item.id else item.value.id;
}

const Notes = struct {
    list: std.ArrayList(Warning) = .empty,
    dropped: u32 = 0,

    fn add(self: *Notes, gpa: Allocator, what: []const u8, name: []const u8, warning: Warning) Allocator.Error!void {
        if (self.list.items.len == max_warnings) {
            self.dropped +|= 1;
            return;
        }
        try self.list.append(gpa, warning);
        if (warning.binding) |b| {
            log.warn("{s} '{s}' {s} (binding {d})", .{ what, name, describe(warning.problem), b });
        } else {
            log.warn("{s} '{s}' {s}", .{ what, name, describe(warning.problem) });
        }
    }

    /// For an override, which has only the action's ID: the spelling stays in the store.
    fn addId(self: *Notes, gpa: Allocator, warning: Warning) Allocator.Error!void {
        if (self.list.items.len == max_warnings) {
            self.dropped +|= 1;
            return;
        }
        try self.list.append(gpa, warning);
        if (warning.binding) |b| {
            log.warn("input action {f}: the player's override {s} (binding {d})", .{ warning.record, describe(warning.problem), b });
        } else {
            log.warn("input action {f} {s}", .{ warning.record, describe(warning.problem) });
        }
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const t_gpa = testing.allocator;

/// Packages compiled from text, merged into one store in the order given. Tests only, here and
/// in `tests.zig`.
pub const Fixture = struct {
    registry: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: [4]std.ArrayList(u8) = @splat(.empty),
    count: usize = 0,

    pub fn init() Fixture {
        var f: Fixture = .{ .registry = .init(t_gpa, .default), .diags = .init(t_gpa, .default), .store = .init(t_gpa, .default) };
        schemas.registerAll(t_gpa, &f.registry) catch unreachable;
        return f;
    }

    pub fn deinit(self: *Fixture) void {
        self.store.deinit(t_gpa);
        for (&self.bytes) |*b| b.deinit(t_gpa);
        self.diags.deinit(t_gpa);
        self.registry.deinit(t_gpa);
    }

    /// Adds package `<namespace>:content` with `text`'s records.
    pub fn add(self: *Fixture, namespace: []const u8, text: []const u8) !void {
        var doc = try data.parser.parse(t_gpa, "input.fdt", text, .{ .namespace = namespace }, &self.diags);
        defer doc.deinit(t_gpa);
        var name_buf: [64]u8 = undefined;
        var package = try data.check.Package.init(t_gpa, try std.fmt.bufPrint(&name_buf, "{s}:content", .{namespace}), 1, .default);
        defer package.deinit(t_gpa);
        try package.addDocument(t_gpa, &doc, &self.registry, &self.diags);
        const out = &self.bytes[self.count];
        self.count += 1;
        try data.fpk.write(t_gpa, &package, &self.registry, out);
        _ = try self.store.add(t_gpa, "input.fpk", out.items, &self.registry, &self.diags);
    }

    pub fn build(self: *Fixture) !Map {
        return Map.build(t_gpa, &self.store);
    }
};

fn cid(text: []const u8) ContentId {
    return ContentId.fromString(text);
}

fn expectWarning(map: *const Map, record: []const u8, problem: Problem, binding: ?u8) !void {
    for (map.warnings) |w| {
        if (w.record.eql(cid(record)) and w.problem == problem and std.meta.eql(w.binding, binding)) return;
    }
    return error.TestExpectedWarning;
}

const court =
    \\foundry:input_context court:context.walk { priority 10 }
    \\foundry:input_context court:context.menu { priority 20 blocks true }
    \\foundry:input_action court:action.move {
    \\    kind "vector"
    \\    contexts [ court:context.walk ]
    \\    bindings [
    \\        { source "key.w" axis "y" scale 1 }
    \\        { source "key.s" axis "y" scale -1 }
    \\        { source "pad.left_stick" deadzone 0.2 }
    \\    ]
    \\}
    \\foundry:input_action court:action.jump {
    \\    kind "button"
    \\    contexts [ court:context.walk ]
    \\    bindings [ { source "key.space" } { source "pad.south" } ]
    \\}
    \\foundry:input_action court:action.pause {
    \\    kind "button"
    \\    contexts [ court:context.walk court:context.menu ]
    \\    bindings [ { source "key.escape" } { source "pad.start" } ]
    \\    rebindable false
    \\}
;

test "a map holds every action and context, in content-ID order, found by ID" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("court", court);
    var map = try f.build();
    defer map.deinit(t_gpa);

    try testing.expectEqual(@as(usize, 0), map.warnings.len);
    try testing.expectEqual(@as(usize, 3), map.actions.len);
    try testing.expectEqual(@as(usize, 2), map.contexts.len);
    for (map.actions[1..], map.actions[0 .. map.actions.len - 1]) |b, a| try testing.expect(a.id.hash < b.id.hash);
    try testing.expect(map.contexts[0].id.hash < map.contexts[1].id.hash);

    const pause = map.action(cid("court:action.pause")).?;
    try testing.expectEqual(Kind.button, pause.kind);
    try testing.expect(!pause.rebindable);
    try testing.expectEqual(@as(usize, 2), pause.contexts().len);
    try testing.expect(map.contexts[pause.contexts()[0]].id.eql(cid("court:context.walk")));
    try testing.expect(map.contexts[pause.contexts()[1]].id.eql(cid("court:context.menu")));
    const menu = map.context(cid("court:context.menu")).?;
    try testing.expectEqual(@as(i32, 20), menu.priority);
    try testing.expect(menu.blocks);
    try testing.expectEqual(@as(usize, 3), map.action(cid("court:action.move")).?.bindings().len);
    try testing.expect(map.find(cid("court:action.fly")) == null);
    try testing.expect(map.findContext(cid("court:action.move")) == null);
}

test "an empty store gives an empty map, and an empty map frees" {
    var f = Fixture.init();
    defer f.deinit();
    var map = try f.build();
    defer map.deinit(t_gpa);
    try testing.expectEqual(@as(usize, 0), map.actions.len);
    var none: Map = .empty;
    none.deinit(t_gpa);
}

test "a mod's record replaces the game's whole, and a mod adds an action to the game's context" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("court", court);
    try f.add("southpaw",
        \\foundry:input_action court:action.jump {
        \\    kind "button"
        \\    contexts [ court:context.walk ]
        \\    bindings [ { source "pad.east" } ]
        \\}
        \\foundry:input_action southpaw:action.wave {
        \\    kind "button"
        \\    contexts [ court:context.walk ]
        \\    bindings [ { source "key.q" } ]
        \\}
    );
    var map = try f.build();
    defer map.deinit(t_gpa);
    try testing.expectEqual(@as(usize, 0), map.warnings.len);
    try testing.expectEqual(@as(usize, 4), map.actions.len);
    const jump = map.action(cid("court:action.jump")).?;
    try testing.expectEqual(@as(usize, 1), jump.bindings().len);
    try testing.expect(jump.bindings()[0].source.eql(.{ .pad_button = .east }));
    const wave = map.action(cid("southpaw:action.wave")).?;
    try testing.expect(map.contexts[wave.contexts()[0]].id.eql(cid("court:context.walk")));
    // The game's context was not overridden to get there.
    try testing.expectEqual(@as(u32, 0), f.store.package(f.store.provenance(f.store.find(cid("court:context.walk")).?).?).?.order);
}

test "a malformed record is refused by name, and the map is built without it" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("court", court);
    try f.add("broken",
        \\foundry:input_action broken:action.spin { kind "rotate" contexts [ court:context.walk ] }
        \\foundry:input_action broken:action.look { kind "button" contexts [ court:context.walk ] bindings [ { source "key.a" } { source "pad.right_stick" } ] }
        \\foundry:input_action broken:action.dead { kind "axis" contexts [ court:context.walk ] bindings [ { source "pad.left_x" deadzone 2 } ] }
        \\foundry:input_action broken:action.lost { kind "button" contexts [ court:context.walk broken:context.nowhere ] }
        \\foundry:input_action broken:action.odd { kind "button" contexts [ court:action.move ] }
    );
    var map = try f.build();
    defer map.deinit(t_gpa);
    try testing.expectEqual(@as(usize, 3), map.actions.len);
    for ([_][]const u8{ "broken:action.spin", "broken:action.look", "broken:action.dead", "broken:action.lost", "broken:action.odd" }) |name| {
        try testing.expect(map.find(cid(name)) == null);
    }
    try expectWarning(&map, "broken:action.spin", error.UnknownKind, null);
    try expectWarning(&map, "broken:action.look", error.SourceCannotFeedKind, 1);
    try expectWarning(&map, "broken:action.dead", error.InvalidDeadzone, 0);
    try expectWarning(&map, "broken:action.lost", error.NotAContext, null);
    // A record that exists and is not a context is not one.
    try expectWarning(&map, "broken:action.odd", error.NotAContext, null);
    for (map.warnings) |w| try testing.expect(w.refused());
    try testing.expectEqualStrings("names a context that is not a foundry:input_context", describe(error.NotAContext));
    try testing.expectEqualStrings("has a kind that is not button, axis, vector or delta", describe(error.UnknownKind));
}

test "an unknown source is skipped with a warning, and the action kept" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("court", court);
    try f.add("later",
        \\foundry:input_action later:action.aim { kind "vector" contexts [ court:context.walk ] bindings [
        \\    { source "pad.gyro" }
        \\    { source "pad.right_stick" }
        \\] }
    );
    var map = try f.build();
    defer map.deinit(t_gpa);
    const aim = map.action(cid("later:action.aim")).?;
    try testing.expectEqual(@as(usize, 1), aim.bindings().len);
    try testing.expect(aim.bindings()[0].source.eql(.{ .pad_stick = .right }));
    try testing.expectEqual(@as(usize, 1), map.warnings.len);
    try expectWarning(&map, "later:action.aim", error.UnknownSource, 0);
    try testing.expect(!map.warnings[0].refused());
}

/// Builds `count` records of `line` (with `{d}` for the index) twice, written in ascending
/// and in descending order, and checks both maps left out the same `excess` records by ID.
fn expectBound(comptime line: []const u8, count: usize, prefix: []const u8, bound: usize, problem: Problem, comptime field: []const u8) !void {
    var forward: std.ArrayList(u8) = .empty;
    defer forward.deinit(t_gpa);
    var backward: std.ArrayList(u8) = .empty;
    defer backward.deinit(t_gpa);
    try forward.appendSlice(t_gpa, prefix);
    try backward.appendSlice(t_gpa, prefix);
    for (0..count) |i| try forward.print(t_gpa, line, .{i});
    for (0..count) |i| try backward.print(t_gpa, line, .{count - 1 - i});

    var maps: [2]Map = undefined;
    var built: usize = 0;
    defer for (maps[0..built]) |*map| map.deinit(t_gpa);
    for ([_][]const u8{ forward.items, backward.items }) |source| {
        var f = Fixture.init();
        defer f.deinit();
        try f.add("t", source);
        maps[built] = try f.build();
        built += 1;
    }
    for (&maps) |*map| {
        const kept = @field(map, field);
        try testing.expectEqual(bound, kept.len);
        try testing.expectEqual(count - bound, map.warnings.len);
        for (map.warnings) |w| {
            try testing.expectEqual(problem, w.problem);
            // Every one left out sorts after every one kept.
            try testing.expect(w.record.hash > kept[kept.len - 1].id.hash);
        }
    }
    // Which are left out is decided by ID, not by where a record sits in its package.
    for (@field(maps[0], field), @field(maps[1], field)) |a, b| try testing.expect(a.id.eql(b.id));
}

test "past 64 contexts and 256 actions, the last in content-ID order are left out and named" {
    try expectBound("foundry:input_context t:context.c{d} {{}}\n", max_contexts + 2, "", max_contexts, error.ContextsFull, "contexts");
    try expectBound(
        "foundry:input_action t:action.a{d} {{ kind \"button\" contexts [ t:walk ] }}\n",
        max_actions + 3,
        "foundry:input_context t:walk {}\n",
        max_actions,
        error.ActionsFull,
        "actions",
    );
}

test "warnings past 64 are counted, not kept" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(t_gpa);
    for (0..max_warnings + 5) |i| try text.print(t_gpa, "foundry:input_action t:action.a{d} {{ kind \"none\" contexts [ t:c ] }}\n", .{i});
    var f = Fixture.init();
    defer f.deinit();
    try f.add("t", text.items);
    var map = try f.build();
    defer map.deinit(t_gpa);
    try testing.expectEqual(max_warnings, map.warnings.len);
    try testing.expectEqual(@as(u32, 5), map.warnings_dropped);
    try testing.expectEqual(@as(usize, 0), map.actions.len);
}
