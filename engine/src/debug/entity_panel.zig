//! The entity inspector (`debug-overlay.md` §7).
//!
//! Three questions, in the order a person asks them: what entities are there, what does this
//! one have, and what is in it. The first two are enumeration; the third is the interesting
//! one, and it is answered **the way a save answers it**.
//!
//! A component's bytes are a Zig struct's layout and only its *schema* is public. Casting
//! them would work for a type the overlay was compiled against and produce garbage for a
//! mod's — an answer that looks right for the whole of M6 and starts lying at M7 — so this
//! reads a component by serializing it through the type's own function, exactly as
//! `scene.save` does. It costs a copy of one entity's components into the frame arena and it
//! cannot disagree with what a reload would restore.
//!
//! **With the hierarchy** (`hierarchy.md` §7), the list is a tree: roots by slot index, each
//! followed by its subtree the same way and indented by depth, and then the entities without
//! a transform. The selection shows its parent, depth, children and world pose, and says
//! when that pose is sheared and so no transform at all. Everything it reads is one of
//! `scene.hierarchy`'s read calls, which the ABI could publish as they are.
//!
//! **Read-only, deliberately** (§7.4). The write path exists and is not used here: whether an
//! edit is a change to state or to content, what undo means, and what happens when a value is
//! refused are the editor's questions, and the mechanism will still be there when it asks
//! them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core");
const data = @import("data");
const scene = @import("scene");
const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

/// The most entity rows formatted in one frame. A bound on the work, not on the world.
pub const max_rows = 64;

/// Which component field, if any, names an entity in the list.
///
/// **The game supplies this; the engine does not invent a name component.** An entity is not
/// content and has no content id — `scene.save`'s header warns off exactly the load-order
/// identity I2 forbids — so the list is `#index.generation` unless a game has somewhere to
/// read a nicer label from. Adding a `foundry:name` component to make a debug list read
/// prettily would be a name every mod is stuck with from M7, which is the reasoning M5 used
/// to refuse `foundry:collider`.
pub const Label = struct {
    type: scene.ComponentType,
    field: u32,
};

/// The deepest indentation drawn, in levels of two glyphs. Deeper rows still sit in tree
/// order; only their offset stops growing, so a 64-deep chain does not push its names off
/// the panel.
pub const max_indent = 12;

/// One row of the list: an entity, and how far down its tree it is.
pub const Row = struct { entity: scene.Entity, depth: u32 };

/// The list, in the order it is drawn, and each entity's child count by slot index.
pub const Tree = struct {
    rows: []Row,
    children: []u32,

    pub fn childCount(self: Tree, entity: scene.Entity) u32 {
        return if (entity.index < self.children.len) self.children[entity.index] else 0;
    }
};

/// §7's order. Without the hierarchy it is slot order, as it always was. With it, the roots
/// in ascending slot index, each followed by its children the same way, then everything
/// without a transform in slot order. "Root" and "child" are the propagation's: an entity
/// §6 set aside (an orphan, a cycle member, one cut too deep) is a root here too, because
/// that is how it is being drawn.
pub fn treeOrder(arena: Allocator, world: *const scene.World) Allocator.Error!Tree {
    var all: std.ArrayList(scene.Entity) = .empty;
    var slots: usize = 0;
    var it = world.liveEntities();
    while (it.next()) |e| {
        try all.append(arena, e);
        slots = @max(slots, @as(usize, e.index) + 1);
    }
    const rows = try arena.alloc(Row, all.items.len);
    const children = try arena.alloc(u32, slots);
    @memset(children, 0);
    if (!scene.hierarchy.enabled(world)) {
        for (rows, all.items) |*r, e| r.* = .{ .entity = e, .depth = 0 };
        return .{ .rows = rows, .children = children };
    }

    // Each entity's drawn parent: the stored one when the propagation followed it, which is
    // exactly when its depth is not zero.
    const parent = try arena.alloc(?u32, slots);
    const depth = try arena.alloc(u32, slots);
    const handle = try arena.alloc(scene.Entity, slots);
    for (all.items) |e| {
        handle[e.index] = e;
        depth[e.index] = scene.hierarchy.depthOf(world, e) orelse 0;
        parent[e.index] = null;
        if (depth[e.index] == 0) continue;
        const p = scene.hierarchy.parentOf(world, e) orelse continue;
        parent[e.index] = p.index;
        children[p.index] += 1;
    }
    // Children grouped by parent, in slot order within each group.
    const start = try arena.alloc(u32, slots + 1);
    start[0] = 0;
    for (0..slots) |i| start[i + 1] = start[i] + children[i];
    const fill = try arena.dupe(u32, start[0..slots]);
    const grouped = try arena.alloc(u32, start[slots]);
    for (all.items) |e| {
        const p = parent[e.index] orelse continue;
        grouped[fill[p]] = e.index;
        fill[p] += 1;
    }

    var out: usize = 0;
    var stack: std.ArrayList(u32) = .empty;
    for (all.items) |root| {
        if (parent[root.index] != null) continue;
        if (scene.hierarchy.depthOf(world, root) == null) continue;
        try stack.append(arena, root.index);
        while (stack.pop()) |index| {
            rows[out] = .{ .entity = handle[index], .depth = depth[index] };
            out += 1;
            // Pushed last-first, so they come off in ascending slot order.
            const mine = grouped[start[index]..start[index + 1]];
            var i = mine.len;
            while (i > 0) {
                i -= 1;
                try stack.append(arena, mine[i]);
            }
        }
    }
    for (all.items) |e| {
        if (scene.hierarchy.depthOf(world, e) != null) continue;
        rows[out] = .{ .entity = e, .depth = 0 };
        out += 1;
    }
    std.debug.assert(out == rows.len);
    return .{ .rows = rows, .children = children };
}

pub const State = struct {
    selected: ?scene.Entity = null,
    label: ?Label = null,

    pub fn describe(ctx: ?*anyopaque, view: *View) anyerror!void {
        const self: *State = @ptrCast(@alignCast(ctx.?));

        const world = view.sources.world orelse {
            // A panel that vanished would be indistinguishable from a panel nobody wrote.
            try view.line("no world (Sources.world)", .{});
            return;
        };

        var live: usize = 0;
        var counting = world.liveEntities();
        while (counting.next()) |_| live += 1;

        var types: usize = 0;
        var counting_types = world.componentTypes();
        while (counting_types.next()) |_| types += 1;

        try view.line("{d} entities  {d} component types", .{ live, types });
        if (scene.hierarchy.enabled(world)) try describePropagation(view, world);
        const tree = try treeOrder(view.arena, world);

        const row = view.row();
        // Half the room for the list and half for what is in the selection, which is the
        // split that keeps both usable when the panel is one of five sharing a column.
        const list_height = @max(row, view.ui.region().remaining().h / 2);

        const list_id = view.ui.childId("entities");
        const window = overlay.windowOf(
            view.ui,
            list_id,
            live,
            @min(max_rows, overlay.rowsIn(list_height, row)),
            row,
        );

        // Reserved from the enclosing region, so the selection's fields land under the list
        // rather than on top of it: `beginScroll` draws where it is told and never moves the
        // cursor.
        const area = view.ui.region().take(list_height);
        try ui.beginScroll(view.ui, list_id, area, window.contentHeight());
        ui.spacer(view.ui, window.before());

        // A level is two glyphs of offset. The row is moved, not its label padded, because a
        // button centres its label and leading spaces would only nudge it.
        const level = view.ui.style.font.measure("  ", view.ui.style.text_scale).x;
        for (tree.rows, 0..) |r, index| {
            if (index < window.first) continue;
            if (index >= window.first + window.count) break;
            const entity = r.entity;
            // Seeded by the row's absolute index rather than its position on screen, so a
            // row keeps its identity while the list scrolls under it.
            const id = view.ui.childIndex(index);
            const selected = if (self.selected) |s| s.eql(entity) else false;
            const text = view.text("{s}#{d}.{d}{s}", .{
                if (selected) "> " else "  ",
                entity.index,
                entity.generation,
                self.labelOf(view, world, entity),
            });
            try ui.beginRow(view.ui, .none, view.ui.style.line_height);
            defer ui.endRow(view.ui);
            ui.spacer(view.ui, level * @as(f32, @floatFromInt(@min(r.depth, max_indent))));
            if (try ui.button(view.ui, id, text)) self.selected = entity;
        }

        ui.spacer(view.ui, window.after());
        try ui.endScroll(view.ui);

        try self.describeSelection(view, world, tree);
    }

    /// The label the game asked for, or nothing. Errors are nothing too: a label that cannot
    /// be read is a row that reads `#3.1`, which is still a row.
    fn labelOf(self: *State, view: *View, world: *const scene.World, entity: scene.Entity) []const u8 {
        const label = self.label orelse return "";
        const fields = (world.describeComponent(view.arena, entity, label.type) catch return "") orelse return "";
        const value = (fields.valueAt(view.arena, label.field) catch return "") orelse return "";
        return view.text("  {s}", .{overlay.valueText(view.arena, view.frame.store, value)});
    }

    fn describeSelection(self: *State, view: *View, world: *const scene.World, tree: Tree) anyerror!void {
        try ui.separator(view.ui);

        const entity = self.selected orelse {
            try view.line("select an entity", .{});
            return;
        };

        // **A stale handle is `null`, never a crash** (§12). The selected entity can be
        // destroyed by a system the frame after it was selected, and re-resolving it every
        // frame is the whole of the defence.
        if (!world.contains(entity)) {
            try view.line("#{d}.{d} is gone", .{ entity.index, entity.generation });
            return;
        }

        try view.line("#{d}.{d}", .{ entity.index, entity.generation });
        try describePlace(view, world, tree, entity);

        var types = world.componentTypes();
        while (types.next()) |info| {
            if (!world.hasComponent(entity, info.type)) continue;

            const header = view.ui.childId(info.name);
            if (!try ui.collapsingHeader(view.ui, header, info.name)) continue;

            if (!info.savable) {
                // The condition `Registration.savable` already names: a type a save leaves
                // out is a type an inspector cannot show, and saying so beside its name and
                // size is better than an empty row somebody reads as "no fields".
                try view.line("    not saved, so not shown ({d} bytes)", .{info.size});
                continue;
            }

            const fields = world.describeComponent(view.arena, entity, info.type) catch |err| {
                // A serializer that refuses is a line of text: it may be a mod's, and a tool
                // that dies on the broken thing is useless at precisely the moment it is
                // needed.
                try view.line("    {t}", .{err});
                continue;
            } orelse {
                try view.line("    gone", .{});
                continue;
            };

            for (fields.fields, 0..) |field, i| {
                const value = fields.valueAt(view.arena, @intCast(i)) catch |err| {
                    try view.line("    {s} = {t}", .{ field.name, err });
                    continue;
                } orelse {
                    try view.line("    {s} = absent", .{field.name});
                    continue;
                };
                try view.line("    {s} = {s}", .{
                    field.name,
                    overlay.valueText(view.arena, view.frame.store, value),
                });
            }
        }
    }
};

/// The last propagation's counts, which head the panel (§7).
fn describePropagation(view: *View, world: *const scene.World) Allocator.Error!void {
    const stats = scene.hierarchy.lastPropagation(world) orelse {
        try view.line("hierarchy: not propagated yet", .{});
        return;
    };
    try view.line("hierarchy: {d} transforms  {d} roots  depth {d}", .{ stats.entities, stats.roots, stats.max_depth });
    try view.line("repaired: {d} orphans  {d} cycles  {d} too deep  {d} invalid", .{
        stats.orphans, stats.cycles, stats.too_deep, stats.invalid,
    });
}

/// Where the selection is: parent, depth, children, and the world pose as the last
/// propagation left it. A sheared pose is not a transform, and says so (`3d.md` §7.1).
fn describePlace(view: *View, world: *const scene.World, tree: Tree, entity: scene.Entity) Allocator.Error!void {
    const depth = scene.hierarchy.depthOf(world, entity) orelse return;
    if (scene.hierarchy.parentOf(world, entity)) |p| {
        try view.line("parent #{d}.{d}  depth {d}  {d} children", .{ p.index, p.generation, depth, tree.childCount(entity) });
    } else {
        try view.line("no parent  depth {d}  {d} children", .{ depth, tree.childCount(entity) });
    }
    const matrix = scene.hierarchy.worldTransform(world, entity) orelse {
        try view.line("world: not propagated yet", .{});
        return;
    };
    const t = matrix.cols[3];
    try view.line("world translation {d:.3} {d:.3} {d:.3}", .{ t[0], t[1], t[2] });
    const pose = core.math.Transform.fromMat4Exact(matrix) catch {
        try view.line("sheared: not a transform", .{});
        return;
    };
    const r = pose.rotation;
    try view.line("world rotation {d:.3} {d:.3} {d:.3} {d:.3}", .{ r.x, r.y, r.z, r.w });
    try view.line("world scale {d:.3} {d:.3} {d:.3}", .{ pose.scale.x, pose.scale.y, pose.scale.z });
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

/// A component with a serializer, derived the way a game's is.
const Position = struct {
    pub const component = "debugtest:position";
    x: f32 = 0,
    y: f32 = 0,
    tag: u32 = 0,
};

/// One without: a marker, which `Registration.savable` refuses and the panel says so about.
const marker_info: scene.ComponentTypeInfo = .{
    .schema = .{
        .id = data.SchemaId.fromStringUnchecked("debugtest:marker"),
        .version = 1,
        .fields = &.{},
    },
    .name = "debugtest:marker",
    .size = 0,
    .alignment = 1,
};

const Fixture = struct {
    schemas: data.Registry,
    world: scene.World,
    arena: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{
            .schemas = .init(testing.allocator, .default),
            .world = undefined,
            .arena = .init(testing.allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.schemas.deinit(testing.allocator);
        self.arena.deinit();
    }
};

test "the panel lists a world's entities and shows the values that were set" {
    var f = Fixture.init();
    f.world = .init(testing.allocator, &f.schemas, .default);
    defer f.deinit();

    const position = try f.world.registerComponent(scene.componentType(Position));

    const first = try f.world.create();
    var value: Position = .{ .x = 3, .y = 4, .tag = 11 };
    _ = try f.world.addComponent(first, position, std.mem.asBytes(&value));
    _ = try f.world.create();

    var state: State = .{ .selected = first };
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 400));
    // Opened, or the fields sit behind a header nobody clicked. The id is the one the
    // header will ask for: seeded by the region, which at the top level is the root.
    ctx.stateOf(ui.Id.root.child("debugtest:position")).open = true;
    var view: View = .{
        .ui = &ctx,
        .arena = f.arena.allocator(),
        .frame = .{},
        .sources = .{ .world = &f.world },
    };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "2 entities  1 component types"));
    try testing.expect(overlay.findText(&ctx, "#0.1"));
    try testing.expect(overlay.findText(&ctx, "#1.1"));
    try testing.expect(overlay.findText(&ctx, "x = 3"));
    try testing.expect(overlay.findText(&ctx, "y = 4"));
    try testing.expect(overlay.findText(&ctx, "tag = 11"));
}

test "a type with no serializer says why rather than showing nothing" {
    var f = Fixture.init();
    f.world = .init(testing.allocator, &f.schemas, .default);
    defer f.deinit();

    const marker = try f.world.registerComponent(marker_info);
    const entity = try f.world.create();
    _ = try f.world.addComponent(entity, marker, null);

    var state: State = .{ .selected = entity };
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 400));
    ctx.stateOf(ui.Id.root.child("debugtest:marker")).open = true;
    var view: View = .{
        .ui = &ctx,
        .arena = f.arena.allocator(),
        .frame = .{},
        .sources = .{ .world = &f.world },
    };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "not saved, so not shown"));
}

test "a destroyed selection reads as gone rather than crashing" {
    var f = Fixture.init();
    f.world = .init(testing.allocator, &f.schemas, .default);
    defer f.deinit();

    const entity = try f.world.create();
    _ = f.world.destroy(entity);

    var state: State = .{ .selected = entity };
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 400));
    var view: View = .{
        .ui = &ctx,
        .arena = f.arena.allocator(),
        .frame = .{},
        .sources = .{ .world = &f.world },
    };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "is gone"));
    try testing.expect(overlay.findText(&ctx, "0 entities"));
}

test "an entity is labelled by the component field the game named" {
    var f = Fixture.init();
    f.world = .init(testing.allocator, &f.schemas, .default);
    defer f.deinit();

    const position = try f.world.registerComponent(scene.componentType(Position));
    const entity = try f.world.create();
    var value: Position = .{ .x = 1, .y = 2, .tag = 77 };
    _ = try f.world.addComponent(entity, position, std.mem.asBytes(&value));

    // Field 2 is `tag`. The engine invents no name component; a game that has somewhere to
    // read a label from says where (§7.3).
    var state: State = .{ .label = .{ .type = position, .field = 2 } };
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 400));
    var view: View = .{
        .ui = &ctx,
        .arena = f.arena.allocator(),
        .frame = .{},
        .sources = .{ .world = &f.world },
    };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "#0.1  77"));
}

test "no world is an answer rather than an absent panel" {
    var test_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer test_arena.deinit();
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 400));
    var state: State = .{};
    var view: View = .{ .ui = &ctx, .arena = test_arena.allocator(), .frame = .{}, .sources = .{} };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "no world"));
}

// -- the hierarchy (`hierarchy.md` §7) -----------------------------------------------

fn hierarchyNode(world: *scene.World, types: scene.hierarchy.Types, local: core.math.Transform) !scene.Entity {
    const e = try world.create();
    const t: scene.hierarchy.Transform = .fromCore(local);
    _ = try world.addComponent(e, types.transform, std.mem.asBytes(&t));
    return e;
}

test "with the hierarchy the list is a tree: roots by slot, each followed by its subtree" {
    var f = Fixture.init();
    f.world = .init(testing.allocator, &f.schemas, .default);
    defer f.deinit();
    const types = try f.world.enableHierarchy();
    const unit = core.math.Transform.identity;
    // Slots: B0 N1 R2 C3 A4 S5, where N has no transform.
    const b = try hierarchyNode(&f.world, types, unit);
    const n = try f.world.create();
    const r = try hierarchyNode(&f.world, types, unit);
    const c = try hierarchyNode(&f.world, types, unit);
    const a = try hierarchyNode(&f.world, types, unit);
    const s = try hierarchyNode(&f.world, types, unit);
    try scene.hierarchy.setParent(&f.world, a, r);
    try scene.hierarchy.setParent(&f.world, b, r);
    try scene.hierarchy.setParent(&f.world, c, a);

    const tree = try treeOrder(f.arena.allocator(), &f.world);
    const expected = [_]Row{
        .{ .entity = r, .depth = 0 }, .{ .entity = b, .depth = 1 }, .{ .entity = a, .depth = 1 },
        .{ .entity = c, .depth = 2 }, .{ .entity = s, .depth = 0 }, .{ .entity = n, .depth = 0 },
    };
    try testing.expectEqualSlices(Row, &expected, tree.rows);
    try testing.expectEqual(@as(u32, 2), tree.childCount(r));
    try testing.expectEqual(@as(u32, 1), tree.childCount(a));
    try testing.expectEqual(@as(u32, 0), tree.childCount(n));
}

test "the inspector shows a sheared child as sheared, indented under its parent" {
    var f = Fixture.init();
    f.world = .init(testing.allocator, &f.schemas, .default);
    defer f.deinit();
    const types = try f.world.enableHierarchy();
    // `3d.md` §7.1's example: a parent scaled (2, 1, 1), a child turned 45° about Z.
    const parent = try hierarchyNode(&f.world, types, .{ .translation = .init(1, 2, 3), .scale = .init(2, 1, 1) });
    const child = try hierarchyNode(&f.world, types, .{
        .translation = .init(1, 0, 0),
        .rotation = core.math.Quat.fromAxisAngle(.init(0, 0, 1), std.math.pi / 4.0),
    });
    try scene.hierarchy.setParent(&f.world, child, parent);

    // Before any propagation, it says so rather than showing identities.
    {
        var state: State = .{ .selected = child };
        var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
        defer ctx.deinit();
        ctx.begin(.{}, .init(0, 0, 600, 600));
        var view: View = .{ .ui = &ctx, .arena = f.arena.allocator(), .frame = .{}, .sources = .{ .world = &f.world } };
        try State.describe(&state, &view);
        ctx.end();
        try testing.expect(overlay.findText(&ctx, "hierarchy: not propagated yet"));
        try testing.expect(overlay.findText(&ctx, "world: not propagated yet"));
    }

    _ = try scene.hierarchy.propagate(&f.world);
    var state: State = .{ .selected = child };
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 600));
    var view: View = .{ .ui = &ctx, .arena = f.arena.allocator(), .frame = .{}, .sources = .{ .world = &f.world } };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "hierarchy: 2 transforms  1 roots  depth 1"));
    try testing.expect(overlay.findText(&ctx, "repaired: 0 orphans  0 cycles  0 too deep  0 invalid"));
    // The parent at the left, the child selected and indented under it by one level.
    const level = ctx.style.font.measure("  ", ctx.style.text_scale).x;
    try testing.expectEqual(textX(&ctx, "  #0.1").? + level, textX(&ctx, "> #1.1").?);
    try testing.expect(overlay.findText(&ctx, "parent #0.1  depth 1  0 children"));
    try testing.expect(overlay.findText(&ctx, "world translation 3.000 2.000 3.000"));
    try testing.expect(overlay.findText(&ctx, "sheared: not a transform"));

    // The parent's own pose is a transform, and decomposes.
    var parent_state: State = .{ .selected = parent };
    var parent_ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer parent_ctx.deinit();
    parent_ctx.begin(.{}, .init(0, 0, 600, 600));
    view = .{ .ui = &parent_ctx, .arena = f.arena.allocator(), .frame = .{}, .sources = .{ .world = &f.world } };
    try State.describe(&parent_state, &view);
    parent_ctx.end();
    try testing.expect(overlay.findText(&parent_ctx, "no parent  depth 0  1 children"));
    try testing.expect(overlay.findText(&parent_ctx, "world rotation 0.000 0.000 0.000 1.000"));
    try testing.expect(overlay.findText(&parent_ctx, "world scale 2.000 1.000 1.000"));
    try testing.expect(!overlay.findText(&parent_ctx, "sheared"));
}

/// Where a text command containing `needle` starts, for a test that checks placement.
fn textX(ctx: *const ui.Context, needle: []const u8) ?f32 {
    for (ctx.list.commands.items) |command| {
        const t = switch (command) {
            .text => |t| t,
            else => continue,
        };
        const text = ctx.list.text_bytes.items[t.text.offset..][0..t.text.len];
        if (std.mem.indexOf(u8, text, needle) != null) return t.at.x;
    }
    return null;
}
