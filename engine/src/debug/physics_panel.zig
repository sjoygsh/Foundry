//! Collision, as a game reports it (`collision-scale.md` §10).
//!
//! **Only what a game hands over.** `app` owns no collision world, so the overlay has none to ask:
//! `Sources.physics` is a `physics3d.Report`, a value the game fills from its world and its own
//! timing. A panel with no report says so, as the navigation panel does. It is numbers and has no
//! write path: it draws no shape, and it reads nothing a mod could not be handed (ADR-0025).

const std = @import("std");

const physics3d = @import("physics3d");
const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

pub const State = struct {
    pub fn describe(_: ?*anyopaque, view: *View) anyerror!void {
        const r = view.sources.physics orelse {
            try view.line("no physics reported (debug.Sources.physics)", .{});
            return;
        };
        try view.line("{d} static  {d} kinematic  {d} character(s)", .{ r.bodies_static, r.bodies_kinematic, r.characters });
        try view.line("{d} mesh(es)  {d} triangles  {d} baked", .{ r.meshes, r.triangles, r.meshes_baked });
        try view.line("{d} hull(s)  {d} faces", .{ r.hulls, r.hull_faces });
        try view.line("broadphase: {d} nodes  height {d}", .{ r.tree_nodes, r.tree_height });

        var asked: u64 = 0;
        for (r.queries) |count| asked += count;
        if (asked == 0) {
            try view.line("no queries", .{});
        } else {
            // By `QueryKind`'s own names, in its order, so the panel cannot drift from it.
            for (r.queries, 0..) |count, kind| {
                if (count != 0) try view.line("  {s}: {d}", .{ @tagName(@as(physics3d.QueryKind, @enumFromInt(kind))), count });
            }
            try view.line("{d} nodes walked  {d} bodies tested  {d} triangles tested", .{ r.bodies_visited, r.bodies_tested, r.triangles_tested });
            try view.line("pairs: {d} closed form  {d} GJK", .{ r.pairs_closed, r.pairs_gjk });
        }
        if (r.refits != 0) try view.line("{d} refit(s)", .{r.refits});
        if (r.move_p95_ms > 0) try view.line("move p95 {d:.4} ms", .{r.move_p95_ms});
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    ctx: ui.Context,

    fn init(self: *Harness) void {
        self.arena = .init(testing.allocator);
        self.ctx = ui.Context.init(testing.allocator, overlay.testStyle());
        self.ctx.begin(.{}, .init(0, 0, 500, 400));
    }

    fn deinit(self: *Harness) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    fn describe(self: *Harness, report: ?*const physics3d.Report) !void {
        var view: View = .{ .ui = &self.ctx, .arena = self.arena.allocator(), .frame = .{}, .sources = .{ .physics = report } };
        try State.describe(null, &view);
        self.ctx.end();
    }
};

test "a game with no physics is told so" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.describe(null);
    try testing.expect(overlay.findText(&h.ctx, "no physics reported"));
}

test "an empty world's report says it holds nothing and was asked nothing" {
    var world: physics3d.World = .empty;
    defer world.deinit(testing.allocator);
    const report = world.report();
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.describe(&report);
    for ([_][]const u8{
        "0 static  0 kinematic  0 character(s)",
        "0 mesh(es)  0 triangles  0 baked",
        "0 hull(s)  0 faces",
        "broadphase: 0 nodes  height 0",
        "no queries",
    }) |text| try testing.expect(overlay.findText(&h.ctx, text));
    try testing.expect(!overlay.findText(&h.ctx, "refit"));
    try testing.expect(!overlay.findText(&h.ctx, "move p95"));
}

test "a world's report prints what it holds, the queries asked and the work they did" {
    var world: physics3d.World = .empty;
    defer world.deinit(testing.allocator);
    _ = try world.addBody(testing.allocator, .{ .shape = .{ .box = .{ .half_extents = .init(5, 0.5, 5) } } });
    _ = try world.addBody(testing.allocator, .{ .shape = .{ .sphere = .{ .radius = 0.5 } }, .pose = .{ .position = .init(0, 2, 0) } });
    _ = try world.raycast(.init(0, 10, 0), .init(0, -1, 0), 20, .{});
    var report = world.report();
    report.move_p95_ms = 0.0123;
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.describe(&report);
    for ([_][]const u8{
        "2 static  0 kinematic  0 character(s)",
        "  ray: 1",
        "move p95 0.0123 ms",
    }) |text| try testing.expect(overlay.findText(&h.ctx, text));
    try testing.expect(!overlay.findText(&h.ctx, "no queries"));
    try testing.expect(!overlay.findText(&h.ctx, "cast:"));
}

test "every line of a full report is printed" {
    var report: physics3d.Report = .{
        .bodies_static = 2048,
        .bodies_kinematic = 64,
        .characters = 1,
        .meshes = 3,
        .triangles = 32_900,
        .meshes_baked = 1,
        .hulls = 2,
        .hull_faces = 14,
        .tree_nodes = 4223,
        .tree_height = 14,
        .bodies_visited = 120,
        .bodies_tested = 30,
        .triangles_tested = 48,
        .pairs_closed = 40,
        .pairs_gjk = 9,
        .refits = 5,
    };
    report.queries = .{ 1, 2, 3, 4, 5, 6 };
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.describe(&report);
    for ([_][]const u8{
        "2048 static  64 kinematic  1 character(s)",
        "3 mesh(es)  32900 triangles  1 baked",
        "2 hull(s)  14 faces",
        "broadphase: 4223 nodes  height 14",
        "  ray: 1",
        "  cast: 2",
        "  sweep: 3",
        "  overlap: 4",
        "  contacts: 5",
        "  move: 6",
        "120 nodes walked  30 bodies tested  48 triangles tested",
        "pairs: 40 closed form  9 GJK",
        "5 refit(s)",
    }) |text| try testing.expect(overlay.findText(&h.ctx, text));
}
