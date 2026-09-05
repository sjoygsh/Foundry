//! A map from authored text to a body colliding with it.
//!
//! The seam no module can test on its own. `asset` holds the record types and the grid
//! format, `physics2d` holds the collision and has never heard of a content id, and neither
//! can see the other — `physics2d` is L1 on `core` alone. So the wiring between them is only
//! reachable from where a game stands, which is here (`tilemaps-and-collision.md` §11).
//!
//! What this proves end to end: a `.fgrid` written by the same code `fpack` will call, an
//! authored `.fdt` compiled and loaded, the grid acquired **by content id and never by
//! path** (ADR-0021), the tileset's `solid` list turned into the bitset `physics2d` wants,
//! and a body stopped by a tile that a file said was solid.

const std = @import("std");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const physics2d = @import("physics2d");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The stack a game stands on for maps: content, assets, and a collision world.
///
/// No renderer. That is the point of the placement decision this exercises — a consumer
/// that wants map data and not a GPU is not obliged to link one.
const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    dir: []const u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,
    assets: asset.Registry,
    world: physics2d.World = .empty,
    /// The solid bitset the world borrows. A game owns this for as long as it owns the map,
    /// because `physics2d` borrows a grid's arrays and never copies them.
    solid: []u32 = &.{},

    fn init() !*Stack {
        const gpa = testing.allocator;

        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-integration", .env = &.{} });
        errdefer os.deinit();

        const temp = try os.tempDirAlloc(gpa);
        defer gpa.free(temp);
        const dir = try platform.os.joinPath(gpa, &.{ temp, "foundry-tilemap-pipeline" });
        errdefer gpa.free(dir);

        const self = try gpa.create(Stack);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .dir = dir,
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .assets = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});

        // The three runtime registrations a game makes, every one of them a call a mod
        // could make too (I6): the asset record types, the tilemap record types, and the
        // loader that turns one of them into tiles.
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.tilemap.registerAll(gpa, &self.schemas);
        try self.assets.registerLoader(gpa, asset.tilegridLoader());
        return self;
    }

    fn deinit(self: *Stack) void {
        self.world.deinit(self.gpa);
        self.gpa.free(self.solid);
        self.assets.deinit(self.gpa);
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.os.deinit();
        self.gpa.destroy(self);
    }

    fn writeFile(self: *Stack, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    /// Writes a grid asset the way `fpack` will: through `asset.tilegrid.write`, so the
    /// bytes on disk are the bytes the format says and not a test's idea of them.
    fn writeGrid(self: *Stack, rel: []const u8, width: u32, height: u32, tiles: []const u16) !void {
        const bytes = try asset.tilegrid.write(self.gpa, width, height, tiles);
        defer self.gpa.free(bytes);
        try self.writeFile(rel, bytes);
    }

    fn loadPackage(self: *Stack, name: []const u8, source: []const u8) !void {
        var doc = try data.parser.parse(self.gpa, "content.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &self.diags);
        defer doc.deinit(self.gpa);

        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &self.bytes);

        const handle = try self.store.add(self.gpa, name, self.bytes.items, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.dir);
    }

    /// The wiring §11 says the game does, written once here so the test can read as the
    /// thing it is testing: a layer's content becomes a grid in a collision world.
    fn addLayer(self: *Stack, layer_id: []const u8, map: asset.tilemap.Tilemap) !physics2d.GridHandle {
        const layer = try asset.tilemap.readLayer(self.store.lookup(.fromString(layer_id)).?);
        const set = self.store.lookup(layer.tileset).?;

        const solid = try asset.tilemap.solidBitset(self.gpa, set);
        // Borrowed by the world, so it outlives this call by living on the stack struct.
        // A game owns these two arrays exactly as long as it owns the map.
        self.solid = solid;

        const handle = try self.assets.acquire(self.gpa, layer.grid);
        const grid = asset.tilegrid.fromPayload(self.assets.payloadOf(handle).?);

        return try self.world.addGrid(self.gpa, .{
            .origin = .zero,
            .cell = .{ .x = map.cell_width, .y = map.cell_height },
            .width = grid.width,
            .height = grid.height,
            .tiles = grid.tiles,
            .solid = solid,
        });
    }
};

const content =
    \\# The grid's record, written out rather than derived. `fpack` mints exactly this from
    \\# the file's path, and an author may write it instead to give the id explicitly
    \\# (ADR-0021); derivation is the compiler's business and is tested there.
    \\foundry:tilegrid sandbox:grids.town.walls { source "grids/town/walls.fgrid" }
    \\
    \\foundry:tileset sandbox:tiles.overworld {
    \\    texture   sandbox:textures.overworld
    \\    tile      [ 16 16 ]
    \\    columns   16
    \\    solid     [ 1 ]
    \\}
    \\
    \\foundry:tilemap.layer sandbox:map.town.walls {
    \\    tileset   sandbox:tiles.overworld
    \\    grid      sandbox:grids.town.walls
    \\    order     1
    \\    collides  true
    \\}
    \\
    \\foundry:tilemap sandbox:map.town {
    \\    size    [ 4 4 ]
    \\    cell    [ 1 1 ]
    \\    layers  [ sandbox:map.town.walls ]
    \\}
;

test "a map goes from authored text to a body that cannot walk through a wall" {
    const stack = try Stack.init();
    defer stack.deinit();

    // A 4x4 map with a wall down its right-hand column. Row 0 is the bottom row.
    try stack.writeGrid("grids/town/walls.fgrid", 4, 4, &.{
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
    });
    try stack.loadPackage("sandbox:content", content);

    const map = try asset.tilemap.readTilemap(stack.store.lookup(.fromString("sandbox:map.town")).?);
    _ = try stack.addLayer("sandbox:map.town.walls", map);

    const mover = try stack.world.addBody(stack.gpa, .{
        .shape = .{ .box = .{ .x = 0.5, .y = 0.5 } },
        .position = .{ .x = 0.5, .y = 2.5 },
        .kind = .movable,
    });

    var hits: [4]physics2d.Hit = undefined;
    const result = (try stack.world.moveAndSlide(stack.gpa, mover, .{ .x = 5, .y = 0 }, &hits)).?;

    try testing.expectEqual(@as(u32, 1), result.total_hits);
    try testing.expect(hits[0].isGrid());
    try testing.expectEqual([2]u32{ 3, 2 }, hits[0].cell);
    // The wall's left face is at x = 3 and the body is 0.5 wide, so it stops at 2.5.
    try testing.expectApproxEqAbs(@as(f32, 2.5), result.position.x, 2 * physics2d.contact_skin);
}

test "the grid is reached by content id, and its path is never asked for" {
    const stack = try Stack.init();
    defer stack.deinit();

    // The file is at `grids/town/walls.fgrid`, so the id it derives is
    // `sandbox:grids.town.walls` -- and the id is what everything downstream uses. There is
    // no call anywhere that takes the path (ADR-0021).
    try stack.writeGrid("grids/town/walls.fgrid", 2, 1, &.{ 0, 1 });
    try stack.loadPackage("sandbox:content",
        \\foundry:tilegrid sandbox:grids.town.walls { source "grids/town/walls.fgrid" }
    );

    const handle = try stack.assets.acquire(stack.gpa, .fromString("sandbox:grids.town.walls"));
    const grid = asset.tilegrid.fromPayload(stack.assets.payloadOf(handle).?);
    try testing.expectEqual(@as(u32, 2), grid.width);
    try testing.expectEqual(@as(u32, 1), grid.height);
    try testing.expectEqual(@as(?u16, 1), grid.tileAt(1, 0));

    // Acquired twice is one load, and released twice is one unload -- the reference
    // counting the registry already had, applying to a kind it had never heard of.
    const again = try stack.assets.acquire(stack.gpa, .fromString("sandbox:grids.town.walls"));
    try testing.expectEqual(@as(?u32, 2), stack.assets.refCount(handle));
    stack.assets.release(again);
    stack.assets.release(handle);
}

test "a grid file that is not a grid fails the load and says which kind of wrong it is" {
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeFile("grids/broken.fgrid", "this is not a grid");
    try stack.loadPackage("sandbox:content",
        \\foundry:tilegrid sandbox:grids.broken { source "grids/broken.fgrid" }
    );

    try testing.expectError(
        error.InvalidAsset,
        stack.assets.acquire(stack.gpa, .fromString("sandbox:grids.broken")),
    );
}
