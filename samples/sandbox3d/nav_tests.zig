//! M32 Step 6 (`docs/design/navigation.md` §9.1): the walker's navigation mesh from the compiled
//! room, course and props, and what `plinth` and `stout` do to it.

const std = @import("std");
const builtin = @import("builtin");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const nav = @import("nav");
const render3d = @import("render3d");
const Props = @import("props.zig").Props;
const Walk = @import("walk.zig").Walk;
const nav_mod = @import("nav.zig");
const options = @import("walk_test_options");
const testing = std.testing;
const Vec3 = core.math.Vec3;
const dt = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

const Fixture = struct {
    engine: *app.Engine,
    renderer: render3d.Renderer,
    content: render3d.Content,
    walk: Walk,
    props: Props = .{},
    mods: std.ArrayList([]u8) = .empty,

    fn init(self: *Fixture) !void {
        const gpa = testing.allocator;
        self.engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
            .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
            .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
        } });
        errdefer self.engine.deinit();
        try self.engine.assets.registerLoader(gpa, asset.collisionMeshLoader());
        self.renderer = try render3d.Renderer.init(gpa, self.engine.gpu, .{ .cull = false });
        self.content = render3d.Content.init(gpa, &self.renderer, &self.engine.assets, .default);
        self.walk = Walk.init(gpa);
        self.props = .{};
        self.mods = .empty;
        self.refresh();
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.props.deinit(gpa, &self.walk.world, &self.content, &self.engine.assets);
        self.walk.deinit(&self.engine.assets);
        self.content.deinit();
        self.renderer.deinit();
        self.engine.deinit();
        for (self.mods.items) |m| gpa.free(m);
        self.mods.deinit(gpa);
    }

    fn refresh(self: *Fixture) void {
        self.walk.refresh(&self.engine.store, &self.engine.assets, dt);
        self.props.refresh(testing.allocator, &self.engine.store, &self.walk.world, &self.content, &self.engine.assets) catch unreachable;
    }

    /// Adds a compiled mod after the base package, as a player's selection would be applied.
    fn addMod(self: *Fixture, name: []const u8, path: []const u8, generated: ?[]const u8) !void {
        const gpa = testing.allocator;
        const bytes = try self.engine.os.readFile(gpa, path, 16 * 1024 * 1024);
        errdefer gpa.free(bytes);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);
        const handle = try self.engine.store.add(gpa, name, bytes, &self.engine.schemas, &diags);
        if (generated) |dir| try self.engine.assets.mount(gpa, handle, dir);
        try self.mods.append(gpa, bytes);
        self.refresh();
    }

    /// The mesh as the sample builds it, synchronously.
    fn build(self: *Fixture) !nav.Mesh {
        const gpa = testing.allocator;
        var sources: std.ArrayList(nav.Source) = .empty;
        defer sources.deinit(gpa);
        var held: std.ArrayList(asset.AssetHandle) = .empty;
        defer {
            for (held.items) |h| self.engine.assets.release(h);
            held.deinit(gpa);
        }
        const config = try nav_mod.gather(gpa, &self.engine.store, &self.engine.assets, &self.props, &sources, &held);
        return nav.build(gpa, config, sources.items);
    }
};

/// Polygons connected to `start` by links.
fn reach(m: *const nav.Mesh, start: u32, seen: []bool) void {
    @memset(seen, false);
    var stack: [4096]u32 = undefined;
    var n: usize = 1;
    stack[0] = start;
    seen[start] = true;
    while (n > 0) {
        n -= 1;
        const p = stack[n];
        for (m.polygons[p].neighbours[0..m.polygons[p].count]) |q| {
            if (q == nav.none_polygon or seen[q]) continue;
            seen[q] = true;
            stack[n] = q;
            n += 1;
        }
    }
}

/// On the mesh at `(x, z)` near height `y`: within a cell sideways and 0.15 m in height.
fn on(m: *const nav.Mesh, x: f32, y: f32, z: f32) ?nav.Located {
    return m.locate(.init(x, y, z), .init(0.05, 0.15, 0.05));
}

// The course, pinned by `collision3d.md` Step 5's Resolution: steps over x −1.8 to −0.8 rising
// toward −Z, the platform 0.6 m up over z −1.6 to −2.6, the 25° ramp from its east edge to the
// floor at x ≈ 0.49 about z −2.1, the 55° ramp about z −0.7 rising west to the wall at x −3.
// The open floor between the table and the course, clear of every wall by more than 0.6 m.
const floor_point: Vec3 = .init(1.8, 0, 1.0);
const step_point: Vec3 = .init(-1.3, 0.3, -0.85);
const platform_point: Vec3 = .init(-1.3, 0.6, -2.1);
const ramp_point: Vec3 = .init(-0.15, 0.3, -2.1);
const steep_point: Vec3 = .init(-2.7, 0.3, -0.7);

test "navigation: the walker's mesh joins the floor to the platform by the steps and the ramp, and leaves out the steep ramp" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var m = try f.build();
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), m.skipped);

    const floor = on(&m, floor_point.x, floor_point.y, floor_point.z) orelse return error.FloorNotOnMesh;
    const step = on(&m, step_point.x, step_point.y, step_point.z) orelse return error.StepNotOnMesh;
    const platform = on(&m, platform_point.x, platform_point.y, platform_point.z) orelse return error.PlatformNotOnMesh;
    const ramp = on(&m, ramp_point.x, ramp_point.y, ramp_point.z) orelse return error.RampNotOnMesh;
    try testing.expectApproxEqAbs(@as(f32, 0.6), platform.point.y, 0.1);

    const seen = try testing.allocator.alloc(bool, m.polygons.len);
    defer testing.allocator.free(seen);
    reach(&m, floor.polygon, seen);
    try testing.expect(seen[step.polygon] and seen[platform.polygon] and seen[ramp.polygon]);

    // Too steep: nothing at its middle's height.
    try testing.expect(on(&m, steep_point.x, steep_point.y, steep_point.z) == null);
    // Under the table's top the clearance is less than the walker's height: no floor at its
    // centre, where the orrery stands.
    try testing.expect(on(&m, 0, 0, 0) == null);
}

test "navigation: plinth's prop cuts the mesh, and stout's wider walker loses the steps, with no code" {
    if (comptime !options.available) return error.SkipZigTest;
    var base: Fixture = undefined;
    try base.init();
    defer base.deinit();
    var before = try base.build();
    defer before.deinit(testing.allocator);
    const plinth_at: Vec3 = .init(-2.2, 0, 1.6);
    try testing.expect(on(&before, plinth_at.x, plinth_at.y, plinth_at.z) != null);

    var with_plinth: Fixture = undefined;
    try with_plinth.init();
    defer with_plinth.deinit();
    try with_plinth.addMod("plinth:content", options.plinth_package, options.plinth_generated);
    try testing.expectEqual(@as(usize, 1), with_plinth.props.len);
    var cut = try with_plinth.build();
    defer cut.deinit(testing.allocator);
    try testing.expect(on(&cut, plinth_at.x, plinth_at.y, plinth_at.z) == null);
    try testing.expect(on(&cut, floor_point.x, floor_point.y, floor_point.z) != null);
    try testing.expect(cut.area() < before.area());

    var stout: Fixture = undefined;
    try stout.init();
    defer stout.deinit();
    try stout.addMod("stout:content", options.stout_package, null);
    var wide = try stout.build();
    defer wide.deinit(testing.allocator);
    // The 1 m steps and platform close for a 0.6 m radius; the floor is still there, smaller.
    try testing.expect(on(&wide, platform_point.x, platform_point.y, platform_point.z) == null);
    try testing.expect(on(&wide, step_point.x, step_point.y, step_point.z) == null);
    try testing.expect(on(&wide, floor_point.x, floor_point.y, floor_point.z) != null);
    try testing.expect(wide.area() < before.area());
}

test "navigation: a request arrives when its task has run, and a superseded one is discarded" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var manual = try core.tasks.Manual.init(gpa, 4);
    defer manual.deinit();
    var navigation = nav_mod.Navigation.init(gpa);
    navigation.request(manual.tasks(), &f.engine.store, &f.engine.assets, &f.props, 1, 0);
    navigation.pump(2, 0);
    try testing.expect(navigation.mesh == null);
    // A reload before the first has run: the first is superseded.
    navigation.request(manual.tasks(), &f.engine.store, &f.engine.assets, &f.props, 3, 0);
    try testing.expectEqual(@as(usize, 1), navigation.stale.items.len);
    manual.runNext();
    navigation.pump(4, 0);
    // The stale one finished and went; the pending one has not run.
    try testing.expectEqual(@as(usize, 0), navigation.stale.items.len);
    try testing.expect(navigation.mesh == null);
    manual.runAll();
    navigation.pump(5, 0);
    try testing.expect(navigation.mesh != null);
    try testing.expectEqual(@as(u32, 1), navigation.arrivals);
    navigation.deinit(manual.tasks(), null, null);
}

test "navigation: the walker's real level builds within criterion 5, single-threaded, printed" {
    if (comptime !options.available) return error.SkipZigTest;
    if (builtin.mode == .Debug) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var best: u64 = std.math.maxInt(u64);
    var polygons: usize = 0;
    for (0..5) |_| {
        const start = std.Io.Clock.awake.now(testing.io);
        var m = try f.build();
        const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
        polygons = m.polygons.len;
        m.deinit(testing.allocator);
        best = @min(best, ns);
    }
    const ms = @as(f64, @floatFromInt(best)) / 1e6;
    std.debug.print("sandbox3d navigation build ({t}): {d:.2} ms, {d} polygons, room and course\n", .{ builtin.mode, ms, polygons });
    try testing.expect(ms <= 50);
}
