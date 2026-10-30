//! Navigation, as a game reports it (`agents.md` §10).
//!
//! **Only what a game hands over.** `app` owns no mesh and no crowd, so the overlay has none to
//! ask: `Sources.navigation` is a `nav.Report`, a value the game fills. A panel with no report says
//! so, because a panel that vanishes is indistinguishable from a panel nobody wrote. It has no
//! write path.

const std = @import("std");

const nav = @import("nav");
const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

pub const State = struct {
    pub fn describe(_: ?*anyopaque, view: *View) anyerror!void {
        const r = view.sources.navigation orelse {
            try view.line("no navigation reported (debug.Sources.navigation)", .{});
            return;
        };
        if (!r.has_mesh) {
            try view.line("no mesh yet", .{});
        } else {
            try view.line("{d} polygons  {d} detail triangles  {d} island(s)", .{ r.polygons, r.detail_triangles, r.islands });
            try view.line("{d} link(s)  {d} unattached", .{ r.links, r.links_unattached });
            for (r.area_m2[0..@min(r.area_count, r.area_m2.len)], 0..) |m2, i| {
                try view.line("area {d}: {d:.1} m2", .{ i, m2 });
            }
            if (r.skipped != 0) try view.line("WARNING: {d} region(s) left out of the mesh", .{r.skipped});
        }
        try view.line("generation {d}  {d} rebuild(s)  {d} failed{s}", .{ r.generation, r.rebuilds, r.failed_builds, if (r.building) "  building" else "" });
        if (r.build_ms > 0) try view.line("last build {d:.2} ms", .{r.build_ms});

        if (r.agents == 0) {
            try view.line("no agents", .{});
            return;
        }
        try view.line("{d} agent(s)", .{r.agents});
        for (r.agents_in, 0..) |count, state| {
            if (count == 0) continue;
            const name = @tagName(@as(nav.AgentState, @enumFromInt(state)));
            try view.line("  {s}: {d}", .{ name, count });
        }
        try view.line("searches: {d} this tick  {d} at most  {d} in all", .{ r.searches_this_tick, r.searches_most, r.searches_total });
        if (r.step_p95_ms > 0) try view.line("crowd step p95 {d:.3} ms", .{r.step_p95_ms});
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

    fn describe(self: *Harness, report: ?*const nav.Report) !void {
        var view: View = .{ .ui = &self.ctx, .arena = self.arena.allocator(), .frame = .{}, .sources = .{ .navigation = report } };
        try State.describe(null, &view);
        self.ctx.end();
    }
};

test "a game with no navigation is told so" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.describe(null);
    try testing.expect(overlay.findText(&h.ctx, "no navigation reported"));
}

test "an empty report says there is no mesh and no agents" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const report: nav.Report = .{};
    try h.describe(&report);
    try testing.expect(overlay.findText(&h.ctx, "no mesh yet"));
    try testing.expect(overlay.findText(&h.ctx, "no agents"));
}

test "a report's mesh, areas, rebuilds and agents are printed" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: nav.Report = .{
        .has_mesh = true,
        .polygons = 25,
        .detail_triangles = 60,
        .islands = 3,
        .links = 2,
        .links_unattached = 1,
        .skipped = 4,
        .area_count = 2,
        .generation = 7,
        .rebuilds = 6,
        .failed_builds = 1,
        .building = true,
        .build_ms = 2.5,
        .agents = 16,
        .searches_this_tick = 3,
        .searches_most = 8,
        .searches_total = 900,
        .step_p95_ms = 0.25,
    };
    report.area_m2[0] = 40.5;
    report.area_m2[1] = 4;
    report.agents_in[@intFromEnum(nav.AgentState.walking)] = 15;
    report.agents_in[@intFromEnum(nav.AgentState.blocked)] = 1;
    try h.describe(&report);
    for ([_][]const u8{
        "25 polygons  60 detail triangles  3 island(s)",
        "2 link(s)  1 unattached",
        "area 0: 40.5 m2",
        "area 1: 4.0 m2",
        "WARNING: 4 region(s) left out of the mesh",
        "generation 7  6 rebuild(s)  1 failed  building",
        "last build 2.50 ms",
        "16 agent(s)",
        "  walking: 15",
        "  blocked: 1",
        "searches: 3 this tick  8 at most  900 in all",
        "crowd step p95 0.250 ms",
    }) |text| try testing.expect(overlay.findText(&h.ctx, text));
    try testing.expect(!overlay.findText(&h.ctx, "arrived"));
}
