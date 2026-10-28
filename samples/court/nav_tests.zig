//! M32 Step 7 (`docs/design/navigation.md` §9.2): the warden's navigation mesh from the compiled
//! court, checked against the level `scripts/m26/make_court.py` builds: the court floor over
//! z −2 to 8, the 1.2 m gap to z −3.2 with the pit floor 4.5 m down, the ledge beyond it, and
//! the 0.65 m low wall over x −5 to −1 at z 1.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const nav = @import("nav");
const platform = @import("platform");
const nav_mod = @import("nav.zig");
const options = @import("court_test_options");
const testing = std.testing;

const Level = struct {
    os: *platform.os.Os,
    schemas: data.Registry,
    store: data.Store,
    assets: asset.Registry,
    base: []u8,
    bytes: []u8,

    fn init(self: *Level) !void {
        const gpa = testing.allocator;
        self.os = try platform.os.Os.init(gpa, .{});
        self.schemas = .init(gpa, .default);
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.nav_mesh.registerAll(gpa, &self.schemas);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);
        self.store = .init(gpa, .default);
        self.base = try self.os.readFile(gpa, options.core_package, 16 * 1024 * 1024);
        _ = try self.store.add(gpa, "foundry:core", self.base, &self.schemas, &diags);
        self.bytes = try self.os.readFile(gpa, options.package, 16 * 1024 * 1024);
        const package = try self.store.add(gpa, "court:content", self.bytes, &self.schemas, &diags);
        self.assets = asset.Registry.init(gpa, self.os, &self.store, .{});
        try self.assets.mount(gpa, package, options.generated);
        try self.assets.registerLoader(gpa, asset.collisionMeshLoader());
    }

    fn deinit(self: *Level) void {
        const gpa = testing.allocator;
        self.assets.deinit(gpa);
        self.store.deinit(gpa);
        self.schemas.deinit(gpa);
        gpa.free(self.bytes);
        gpa.free(self.base);
        self.os.deinit();
    }

    fn build(self: *Level) !nav.Mesh {
        const gpa = testing.allocator;
        var sources: std.ArrayList(nav.Source) = .empty;
        defer sources.deinit(gpa);
        var held: std.ArrayList(asset.AssetHandle) = .empty;
        defer {
            for (held.items) |h| self.assets.release(h);
            held.deinit(gpa);
        }
        const config = try nav_mod.gather(gpa, &self.store, &self.assets, &sources, &held);
        return nav.build(gpa, config, sources.items);
    }
};

fn on(m: *const nav.Mesh, x: f32, y: f32, z: f32) ?nav.Located {
    return m.locate(.init(x, y, z), .init(0.05, 0.15, 0.05));
}

/// Whether polygon `to` is reachable from `from` by links.
fn joined(m: *const nav.Mesh, from: u32, to: u32) !bool {
    const seen = try testing.allocator.alloc(bool, m.polygons.len);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(testing.allocator);
    try stack.append(testing.allocator, from);
    seen[from] = true;
    while (stack.pop()) |p| {
        if (p == to) return true;
        for (m.polygons[p].neighbours[0..m.polygons[p].count]) |q| {
            if (q == nav.none_polygon or seen[q]) continue;
            seen[q] = true;
            try stack.append(testing.allocator, q);
        }
    }
    return false;
}

test "court navigation: the warden's waypoints and the spawn are one island; the gap, the pit and the low wall are not on it" {
    if (comptime !options.available) return error.SkipZigTest;
    var level: Level = undefined;
    try level.init();
    defer level.deinit();
    var m = try level.build();
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), m.skipped);

    // `court:warden.main`'s two waypoints and `court:rules.main`'s spawn.
    const west = on(&m, -2, 0, 2.5) orelse return error.WaypointNotOnMesh;
    const east = on(&m, 2, 0, 2.5) orelse return error.WaypointNotOnMesh;
    const spawn = on(&m, 0, 0, 5) orelse return error.SpawnNotOnMesh;
    try testing.expect(try joined(&m, spawn.polygon, west.polygon));
    try testing.expect(try joined(&m, spawn.polygon, east.polygon));

    // The gap has no floor at the court's height.
    try testing.expect(on(&m, 0, 0, -2.6) == null);
    // The pit's floor is walkable, and an island of its own.
    const pit = on(&m, 0, -4.5, -2.6) orelse return error.PitNotOnMesh;
    try testing.expect(!try joined(&m, spawn.polygon, pit.polygon));
    // The ledge is across the gap: the warden, who cannot jump, cannot reach it.
    const ledge = on(&m, 0, 0, -5) orelse return error.LedgeNotOnMesh;
    try testing.expect(!try joined(&m, spawn.polygon, ledge.polygon));

    // The low wall is higher than the warden's climb and too thin to stand on: nothing at its
    // middle at any height up to its top, though the floor either side is joined round its ends.
    try testing.expect(m.locate(.init(-3, 0.3, 1), .init(0.05, 0.4, 0.05)) == null);
    const south = on(&m, -3, 0, 1.6) orelse return error.FloorNotOnMesh;
    const north = on(&m, -3, 0, 0.4) orelse return error.FloorNotOnMesh;
    try testing.expect(try joined(&m, south.polygon, north.polygon));
}

test "court navigation: the warden's level builds within criterion 5, single-threaded, printed" {
    if (comptime !options.available) return error.SkipZigTest;
    if (builtin.mode == .Debug) return error.SkipZigTest;
    var level: Level = undefined;
    try level.init();
    defer level.deinit();
    var best: u64 = std.math.maxInt(u64);
    var polygons: usize = 0;
    for (0..5) |_| {
        const start = std.Io.Clock.awake.now(testing.io);
        var m = try level.build();
        const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
        polygons = m.polygons.len;
        m.deinit(testing.allocator);
        best = @min(best, ns);
    }
    const ms = @as(f64, @floatFromInt(best)) / 1e6;
    std.debug.print("court navigation build ({t}): {d:.2} ms, {d} polygons\n", .{ builtin.mode, ms, polygons });
    try testing.expect(ms <= 50);
}
