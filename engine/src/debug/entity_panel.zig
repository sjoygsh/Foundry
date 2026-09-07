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
//! **Read-only, deliberately** (§7.4). The write path exists and is not used here: whether an
//! edit is a change to state or to content, what undo means, and what happens when a value is
//! refused are the editor's questions, and the mechanism will still be there when it asks
//! them.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

        var index: usize = 0;
        var entities = world.liveEntities();
        while (entities.next()) |entity| : (index += 1) {
            if (index < window.first) continue;
            if (index >= window.first + window.count) break;
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
            if (try ui.button(view.ui, id, text)) self.selected = entity;
        }

        ui.spacer(view.ui, window.after());
        try ui.endScroll(view.ui);

        try self.describeSelection(view, world);
    }

    /// The label the game asked for, or nothing. Errors are nothing too: a label that cannot
    /// be read is a row that reads `#3.1`, which is still a row.
    fn labelOf(self: *State, view: *View, world: *const scene.World, entity: scene.Entity) []const u8 {
        const label = self.label orelse return "";
        const fields = (world.describeComponent(view.arena, entity, label.type) catch return "") orelse return "";
        const value = (fields.valueAt(view.arena, label.field) catch return "") orelse return "";
        return view.text("  {s}", .{overlay.valueText(view.arena, view.frame.store, value)});
    }

    fn describeSelection(self: *State, view: *View, world: *const scene.World) anyerror!void {
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
