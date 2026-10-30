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
const crowd_mod = @import("crowd.zig");
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
        var features: nav_mod.Features = .{};
        const config = try nav_mod.gather(gpa, &self.engine.store, &self.engine.assets, &self.props, &sources, &held, &features);
        return nav.buildWith(gpa, config, sources.items, features.view());
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
    const store = &f.engine.store;
    const assets = &f.engine.assets;
    navigation.request(manual.tasks(), store, assets, &f.props, null, 1, 0);
    navigation.pump(2, 0);
    try testing.expect(navigation.mesh() == null);
    // A reload before the first has run: it waits, and nothing is thrown away.
    navigation.request(manual.tasks(), store, assets, &f.props, null, 3, 0);
    try testing.expectEqual(@as(u32, 1), manual.pending());
    manual.runNext();
    navigation.pump(4, 0);
    try testing.expect(navigation.mesh() != null);
    try testing.expectEqual(@as(u32, 1), navigation.arrivals);
    try testing.expect(navigation.takeAdoption() != null);
    try testing.expect(navigation.takeAdoption() == null);
    // Now the reload's own build starts, from the content as it is by then.
    navigation.service(manual.tasks(), store, assets, &f.props, null, 5, 0);
    try testing.expectEqual(@as(u32, 1), manual.pending());
    manual.runAll();
    navigation.pump(6, 0);
    try testing.expectEqual(@as(u32, 2), navigation.arrivals);
    try testing.expect(navigation.takeAdoption() != null);
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

// -- M33: the crowd (`docs/design/agents.md` §11.1) -----------------------------------------------

const crowd_dt = dt;
const north_east: Vec3 = .init(2.2, 0, 2.2);
const north_west: Vec3 = .init(-2.2, 0, 2.2);

/// The length of a path between the room's two south corners, straightened.
fn walked(m: *const nav.Mesh) !f32 {
    var query = try nav.Query.init(testing.allocator, 1024);
    defer query.deinit();
    var steps: [256]nav.Step = undefined;
    var corners: [32]nav.Corner = undefined;
    const filter: nav.Filter = .{};
    const a = m.locate(north_east, .init(0.2, 0.3, 0.2)) orelse return error.OffMesh;
    const b = m.locate(north_west, .init(0.2, 0.3, 0.2)) orelse return error.OffMesh;
    const path = query.find(m, &filter, a, b, &steps);
    try testing.expect(path.complete);
    var total: f32 = 0;
    var last = a.point;
    for (nav.corners(m, steps[0..path.count], a.point, path.end, &corners)) |c| {
        total += c.point.sub(last).length();
        last = c.point;
    }
    return total;
}

/// Whether a path between the room's two south corners crosses `area`.
fn crosses(m: *const nav.Mesh, area: u8) !bool {
    var query = try nav.Query.init(testing.allocator, 1024);
    defer query.deinit();
    var steps: [256]nav.Step = undefined;
    const filter: nav.Filter = .{};
    const a = m.locate(north_east, .init(0.2, 0.3, 0.2)) orelse return error.OffMesh;
    const b = m.locate(north_west, .init(0.2, 0.3, 0.2)) orelse return error.OffMesh;
    const path = query.find(m, &filter, a, b, &steps);
    try testing.expect(path.complete);
    for (steps[0..path.count]) |s| {
        if (m.polygons[s.polygon].area == area) return true;
    }
    return false;
}

fn kindCrossed(m: *const nav.Mesh, steps: []const nav.Step) ?nav.LinkKind {
    for (steps) |s| {
        if (s.link != nav.none_link) return m.links[s.link].kind;
    }
    return null;
}

test "crowd: the recipe's area and links land, and a path takes the short cuts" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var m = try f.build();
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), m.links.len);
    try testing.expectEqual(@as(u32, 0), m.links_unattached);
    try testing.expectEqualSlices(f32, &.{ 1, 4 }, m.costs);
    const pocket = on(&m, -2.35, 0, -2.1) orelse return error.PocketNotOnMesh;
    const platform = on(&m, platform_point.x, platform_point.y, platform_point.z) orelse return error.PlatformNotOnMesh;
    // A strip past the steep ramp joins the pocket to the floor, so the links are short cuts:
    // down by the drop and up by the ladder, each much shorter than the steps.
    var query = try nav.Query.init(testing.allocator, 1024);
    defer query.deinit();
    var steps: [256]nav.Step = undefined;
    const filter: nav.Filter = .{};
    const down = query.find(&m, &filter, platform, pocket, &steps);
    try testing.expect(down.complete);
    try testing.expectEqual(nav.LinkKind.drop, kindCrossed(&m, steps[0..down.count]).?);
    const up = query.find(&m, &filter, pocket, platform, &steps);
    try testing.expect(up.complete);
    try testing.expectEqual(nav.LinkKind.ladder, kindCrossed(&m, steps[0..up.count]).?);
    // The straight way is mud, so a path takes the gap by the glass.
    try testing.expect(!try crosses(&m, 1));
}

test "crowd: the crate in the dry lane cuts it, and a path still gets there another way" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var demo = crowd_mod.CrowdDemo.init(gpa);
    defer demo.deinit(null);
    demo.refresh(&f.engine.store, null);
    const settings = demo.settings.?;
    var sources: std.ArrayList(nav.Source) = .empty;
    defer sources.deinit(gpa);
    var held: std.ArrayList(asset.AssetHandle) = .empty;
    defer {
        for (held.items) |h| f.engine.assets.release(h);
        held.deinit(gpa);
    }
    var features: nav_mod.Features = .{};
    const config = try nav_mod.gather(gpa, &f.engine.store, &f.engine.assets, &f.props, &sources, &held, &features);
    var box: nav.BoxGeometry = undefined;
    try sources.append(gpa, nav.boxSource(settings.crate_half, .{ .position = settings.crate_to, .rotation = .identity }, &box));
    var shut = try nav.buildWith(gpa, config, sources.items, features.view());
    defer shut.deinit(gpa);
    var open_mesh = try f.build();
    defer open_mesh.deinit(gpa);
    try testing.expect(on(&open_mesh, 0, 0, 2.4) != null);
    try testing.expect(on(&shut, 0, 0, 2.4) == null);
    // Longer, and still complete: `walked` asserts that it is.
    try testing.expect(try walked(&shut) > try walked(&open_mesh));
}

test "crowd: marsh makes the lane and the gap dearer than the mud and takes the drop away, with no code" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.addMod("marsh:content", options.marsh_package, null);
    var m = try f.build();
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), m.links.len);
    try testing.expectEqual(nav.LinkKind.ladder, m.links[0].kind);
    try testing.expectEqualSlices(f32, &.{ 1, 4, 30 }, m.costs);
    // The lane is bog now, so the path leaves it, and is longer than the base's.
    try testing.expect(!try crosses(&m, 2));
    var base: Fixture = undefined;
    try base.init();
    defer base.deinit();
    var plain = try base.build();
    defer plain.deinit(testing.allocator);
    try testing.expect(try walked(&m) > try walked(&plain));
}

test "crowd: no region fails anywhere along the crate's slide" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var demo = crowd_mod.CrowdDemo.init(gpa);
    defer demo.deinit(null);
    demo.refresh(&f.engine.store, null);
    const settings = demo.settings.?;
    var sources: std.ArrayList(nav.Source) = .empty;
    defer sources.deinit(gpa);
    var held: std.ArrayList(asset.AssetHandle) = .empty;
    defer {
        for (held.items) |h| f.engine.assets.release(h);
        held.deinit(gpa);
    }
    var features: nav_mod.Features = .{};
    const config = try nav_mod.gather(gpa, &f.engine.store, &f.engine.assets, &f.props, &sources, &held, &features);
    const crate = sources.items.len;
    try sources.append(gpa, undefined);
    var box: nav.BoxGeometry = undefined;
    var slivers: u32 = 0;
    for (0..91) |i| {
        const t = @as(f32, @floatFromInt(i)) / 90;
        const at = settings.crate_from.lerp(settings.crate_to, t);
        sources.items[crate] = nav.boxSource(settings.crate_half, .{ .position = at, .rotation = .identity }, &box);
        var m = try nav.buildWith(gpa, config, sources.items, features.view());
        defer m.deinit(gpa);
        try testing.expectEqual(@as(u32, 0), m.skipped);
        slivers += m.collapsed;
    }
    // Where the crate shuts off a strip of one cell: thinner than `edge_max_error`, and simplified
    // away, which is not a region lost to a fault.
    try testing.expect(slivers >= 1);
}

test "crowd: sixteen pawns go round, one by the drop and the ladder, keeping apart" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var m = try f.build();
    defer m.deinit(gpa);
    var demo = crowd_mod.CrowdDemo.init(gpa);
    defer demo.deinit(null);
    demo.refresh(&f.engine.store, null);
    const s = demo.settings.?;
    try testing.expectEqual(@as(u32, 16), s.count);
    demo.adopt(&m);
    const crowd = &demo.crowd.?;
    var closest = std.math.inf(f32);
    var pressed: u32 = 0;
    for (0..7200) |_| {
        _ = demo.step(crowd_dt);
        for (demo.pawns[0..s.count], 0..) |a, i| {
            const va = crowd.agent(a.handle).?;
            try testing.expect(va.state != .off_mesh);
            if (va.state == .on_link) continue;
            for (demo.pawns[i + 1 .. s.count]) |b| {
                const vb = crowd.agent(b.handle).?;
                if (vb.state == .on_link) continue;
                const d = va.position.sub(vb.position);
                if (@abs(d.y) > s.height) continue;
                const apart = @sqrt(d.x * d.x + d.z * d.z);
                closest = @min(closest, apart);
                pressed += @intFromBool(apart < 2 * s.radius - 0.05);
            }
        }
    }
    try testing.expect(pressed <= 40);
    // Some pawn found itself stuck and moved on, which is the policy this sample shows.
    try testing.expect(demo.gave_up >= 1 and demo.gave_up <= demo.corners_reached);
    try testing.expect(demo.corners_reached >= 16 * 8);
    try testing.expect(demo.crossed[@intFromEnum(nav.LinkKind.drop)] >= 3);
    try testing.expect(demo.crossed[@intFromEnum(nav.LinkKind.ladder)] >= 3);
    // Open floor keeps Step 5's bound. The 0.3 m strip between the table and the crate is narrower
    // than two pawns, so walls press a pair together there, for a few ticks in two minutes.
    try testing.expect(closest >= 0.75 * 2 * s.radius);
}

test "crowd: a run replays exactly from its recorded adoptions, however late a build arrived" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var manual = try core.tasks.Manual.init(gpa, 4);
    defer manual.deinit();
    var navigation = nav_mod.Navigation.init(gpa);
    // Keeps them all for the replay, as a game that replays would.
    navigation.meshes.options.keep = 0;
    const store = &f.engine.store;
    const assets = &f.engine.assets;
    var demo = crowd_mod.CrowdDemo.init(gpa);
    defer demo.deinit(null);
    demo.refresh(store, null);
    const Adoption = struct { tick: u32, generation: u32 };
    var adoptions: std.ArrayList(Adoption) = .empty;
    defer adoptions.deinit(gpa);
    const ticks = 900;
    const hashes = try gpa.alloc(u64, ticks);
    defer gpa.free(hashes);

    const obstacle = struct {
        fn of(d: *const crowd_mod.CrowdDemo) ?nav_mod.Obstacle {
            return .{ .half_extents = d.settings.?.crate_half, .position = d.cratePosition().? };
        }
    }.of;
    navigation.request(manual.tasks(), store, assets, &f.props, obstacle(&demo), 0, 0);
    manual.runAll();
    navigation.pump(0, 0);
    if (navigation.takeAdoption()) |mesh| {
        demo.adopt(mesh);
        try adoptions.append(gpa, .{ .tick = 0, .generation = navigation.current });
    }
    for (0..ticks) |t| {
        if (t == 200) demo.moveCrate();
        // The pool finishes a build every 25 frames.
        if (t % 25 == 24 and manual.pending() > 0) manual.runNext();
        navigation.pump(t, 0);
        if (navigation.takeAdoption()) |mesh| {
            demo.adopt(mesh);
            try adoptions.append(gpa, .{ .tick = @intCast(t), .generation = navigation.current });
        }
        navigation.service(manual.tasks(), store, assets, &f.props, obstacle(&demo), t, 0);
        if (demo.step(crowd_dt)) navigation.meshes.markDirty();
        hashes[t] = demo.crowd.?.hash();
    }
    try testing.expectEqual(@as(usize, 2), adoptions.items.len);
    // One at load and one when the crate came to rest, however long it took to slide, and the
    // second has the crate in it.
    try testing.expectEqual(@as(u32, 2), navigation.meshes.rebuilds);
    const lane = demo.settings.?.crate_to;
    try testing.expect(on(navigation.meshes.get(1).?, lane.x, 0, lane.z) != null);
    try testing.expect(on(navigation.meshes.get(2).?, lane.x, 0, lane.z) == null);

    var again = crowd_mod.CrowdDemo.init(gpa);
    defer again.deinit(null);
    again.refresh(store, null);
    var next: usize = 0;
    for (0..ticks) |t| {
        if (t == 200) again.moveCrate();
        while (next < adoptions.items.len and adoptions.items[next].tick == t) : (next += 1) {
            again.adopt(navigation.meshes.get(adoptions.items[next].generation).?);
        }
        _ = again.step(crowd_dt);
        try testing.expectEqual(hashes[t], again.crowd.?.hash());
    }
    // Waits for anything still queued, on the executor it was started on.
    manual.runAll();
    navigation.deinit(manual.tasks(), null, null);
}
