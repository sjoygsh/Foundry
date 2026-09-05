//! The engine's own content types for describing tilemaps.
//!
//! Three record types over one asset kind, and the split is the point: a **tileset** says how
//! to read a texture as tiles and which ids block, a **layer** pairs a tileset with a grid
//! asset and says how to draw it, and a **tilemap** is an ordered list of layers over one
//! coordinate system.
//!
//! ```fdt
//! foundry:tileset sandbox:tiles.overworld {
//!     texture   sandbox:textures.overworld    # a foundry:texture, by content id
//!     tile      [ 16 16 ]                     # pixels per tile in the source image
//!     columns   16
//!     solid     [ 1 2 3 17 18 ]               # which tile ids block; everything else is empty
//! }
//!
//! foundry:tilemap.layer sandbox:map.town.ground {
//!     tileset   sandbox:tiles.overworld
//!     grid      sandbox:grids.town.ground     # a foundry:tilegrid asset
//!     order     0                             # render2d sort layer
//!     collides  false
//! }
//!
//! foundry:tilemap.layer sandbox:map.town.walls {
//!     tileset   sandbox:tiles.overworld
//!     grid      sandbox:grids.town.walls
//!     order     1
//!     collides  true
//!     empty     0                             # this id draws nothing, so the ground shows
//! }
//!
//! foundry:tilemap sandbox:map.town {
//!     size      [ 64 48 ]
//!     cell      [ 16 16 ]                     # world units per cell
//!     layers    [ sandbox:map.town.ground  sandbox:map.town.walls ]
//! }
//! ```
//!
//! **Why three records and not one.** `content-schemas.md` §7's rule: anything a mod might
//! want to override on its own is a record with a content id. A mod that makes water solid
//! overrides one `foundry:tileset` and never mentions any map; a mod that adds a floor to one
//! town overrides one `foundry:tilemap`'s layer list. With this inlined into a single record
//! either change would mean restating a whole map.
//!
//! **Why they live in `asset` rather than in `render2d`.** They are content vocabulary, not
//! GPU concepts, and `fpack` has to register them before it can check a package — without
//! linking a renderer. That is the same reasoning `schemas.zig` gives for the texture record,
//! and it is the design's §13 open question 1 answered by its own stated trigger arriving
//! early: `fpack` is a consumer that wants map data and not a GPU.
//!
//! **`physics2d` never appears here.** A layer that collides names a tileset whose `solid`
//! list becomes the bitset `physics2d.Grid` wants, built once at load by `solidBitset`. The
//! collision module is L1 and has never heard of a content id.
//!
//! Design: `docs/design/tilemaps-and-collision.md` §9 and §11.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Record = data.store.Record;
const Schema = data.Schema;
const SchemaId = data.SchemaId;
const log = core.log.scoped(.asset);

pub const tileset_name = "foundry:tileset";
pub const layer_name = "foundry:tilemap.layer";
pub const tilemap_name = "foundry:tilemap";

/// How to read a texture as a grid of tiles, and which of them block.
///
/// `solid` is a list of tile **ids**, not of cells, which is why a tileset is shared by every
/// map that uses it and why making a tile type solid is a one-line content change.
pub const tileset: Schema = .{
    .id = SchemaId.fromStringUnchecked(tileset_name),
    .version = 1,
    .fields = &.{
        .{ .name = "texture", .type = .id },
        .{ .name = "tile", .type = .{ .list = &.u32 } },
        .{ .name = "columns", .type = .u32 },
        .{ .name = "solid", .type = .{ .list = &.u32 }, .presence = .optional },
    },
};

/// One drawable, optionally collidable, plane of a map.
///
/// **Version 2 appends `empty`.** A map's `layers` list has always allowed several planes,
/// and a plane drawn over another one needs a way to say "nothing here" or it paints an
/// opaque rectangle over everything below it. Saying it in content rather than in code is
/// what keeps a decoration layer a Tier 1 content mod instead of a Zig program (I5). Content
/// written against version 1 omits the field and reads exactly as it did, which is what
/// additive-only versioning is for (I8).
pub const layer: Schema = .{
    .id = SchemaId.fromStringUnchecked(layer_name),
    .version = 2,
    .fields = &.{
        .{ .name = "tileset", .type = .id },
        .{ .name = "grid", .type = .id },
        .{ .name = "order", .type = .i32, .presence = .{ .default = .{ .int = 0 } } },
        .{ .name = "collides", .type = .bool, .presence = .{ .default = .{ .bool = false } } },
        .{ .name = "empty", .type = .u32, .presence = .optional, .since = 2 },
    },
};

/// A map: one coordinate system, and the layers over it in draw order.
pub const tilemap: Schema = .{
    .id = SchemaId.fromStringUnchecked(tilemap_name),
    .version = 1,
    .fields = &.{
        .{ .name = "size", .type = .{ .list = &.u32 } },
        .{ .name = "cell", .type = .{ .list = &.f32 } },
        .{ .name = "layers", .type = .{ .list = &.id }, .presence = .optional },
    },
};

pub const all = [_]Schema{ tileset, layer, tilemap };

/// Registers all three, so content can use them without declaring them.
///
/// Called by `fpack` before it compiles a package and by a game before it loads one, exactly
/// as `schemas.registerAll` and `scene.schemas.registerAll` are. Re-registering an identical
/// schema is not an error.
pub fn registerAll(gpa: Allocator, registry: *data.Registry) (data.schema.RegisterError || Allocator.Error)!void {
    for (&all) |s| _ = try registry.register(gpa, s);
}

pub const ReadError = error{
    /// A required field is absent, or a list is not the length its meaning requires.
    ///
    /// Content arrives from files and from M7 from mods, so this is reported and never
    /// asserted (CLAUDE.md §7). The checker has already agreed the record's *shape*; what it
    /// cannot check is that `tile` has exactly two numbers, because the type list has no
    /// fixed-length list and adding one for this would cost a text form, a binary form and a
    /// validator (`content-schemas.md` §3).
    InvalidRecord,
};

/// A tileset, read.
pub const Tileset = struct {
    texture: ContentId,
    /// Pixels per tile in the source image.
    tile_width: u32,
    tile_height: u32,
    /// Tiles per row in the source image.
    columns: u32,
};

/// A layer, read.
pub const Layer = struct {
    tileset: ContentId,
    grid: ContentId,
    /// The `render2d` sort layer. Narrowed here, because that is the type the renderer's
    /// sort key uses and a map claiming layer 900,000 should be told so at load rather than
    /// silently wrapped at draw.
    order: i16,
    collides: bool,
    /// The tile id that means "nothing here", or null when the layer draws every id.
    ///
    /// Absent is *not* zero: on the bottom layer of a map, tile zero is usually the ground
    /// and must draw. `Presence.optional` is what keeps "draws nothing here" and "was never
    /// specified" different answers.
    empty: ?u16,
};

/// A map, read. Its layers are a list and come back from `layerIds`.
pub const Tilemap = struct {
    /// Cells.
    width: u32,
    height: u32,
    /// World units per cell.
    cell_width: f32,
    cell_height: f32,
};

pub fn readTileset(record: Record) ReadError!Tileset {
    const texture = idField(record, 0) orelse return error.InvalidRecord;
    const tile = pairOfU32(record, 1) orelse return error.InvalidRecord;
    const columns = u32Field(record, 2) orelse return error.InvalidRecord;
    if (tile[0] == 0 or tile[1] == 0 or columns == 0) return error.InvalidRecord;
    return .{
        .texture = texture,
        .tile_width = tile[0],
        .tile_height = tile[1],
        .columns = columns,
    };
}

pub fn readLayer(record: Record) ReadError!Layer {
    const set = idField(record, 0) orelse return error.InvalidRecord;
    const grid = idField(record, 1) orelse return error.InvalidRecord;
    const order = intField(record, layer, 2) orelse 0;
    if (order < std.math.minInt(i16) or order > std.math.maxInt(i16)) return error.InvalidRecord;
    const collides = boolField(record, layer, 3) orelse false;
    var empty: ?u16 = null;
    if (u32Field(record, 4)) |id| {
        // A tile id is a `u16` in the grid, so an `empty` above that could never match a
        // cell. Refused rather than quietly never firing, which is the sort of content bug
        // that looks like a renderer bug.
        if (id > std.math.maxInt(u16)) return error.InvalidRecord;
        empty = @intCast(id);
    }
    return .{
        .tileset = set,
        .grid = grid,
        .order = @intCast(order),
        .collides = collides,
        .empty = empty,
    };
}

pub fn readTilemap(record: Record) ReadError!Tilemap {
    const size = pairOfU32(record, 0) orelse return error.InvalidRecord;
    const cell = pairOfF32(record, 1) orelse return error.InvalidRecord;
    if (size[0] == 0 or size[1] == 0) return error.InvalidRecord;
    if (!(cell[0] > 0) or !(cell[1] > 0)) return error.InvalidRecord;
    if (!std.math.isFinite(cell[0]) or !std.math.isFinite(cell[1])) return error.InvalidRecord;
    return .{
        .width = size[0],
        .height = size[1],
        .cell_width = cell[0],
        .cell_height = cell[1],
    };
}

/// A map's layers, in draw order. The caller owns the slice.
///
/// A slice rather than the `data` list type, because the modules that read one are granted
/// `asset` and not `data` (ADR-0007) and cannot name it. An empty map is a map with no
/// layers, which is legal and draws nothing.
pub fn layerIds(gpa: Allocator, record: Record) (ReadError || Allocator.Error)![]ContentId {
    const list = (record.fields.listAt(2) catch return error.InvalidRecord) orelse return gpa.alloc(ContentId, 0);
    const ids = try gpa.alloc(ContentId, list.len);
    errdefer gpa.free(ids);
    for (ids, 0..) |*slot, i| {
        slot.* = (list.idAt(@intCast(i)) catch return error.InvalidRecord) orelse return error.InvalidRecord;
    }
    return ids;
}

/// The bitset `physics2d.Grid.solid` wants, built from a tileset's `solid` list.
///
/// The caller owns it. It is sized to the largest solid id and no larger, because
/// `physics2d` reads a short bitset as "everything past the end is passable" — which is what
/// lets a tileset that predates a tile still load.
///
/// **An id a `u16` tile could never hold is warned about and skipped, not refused.** A grid's
/// tiles are `u16`, so `solid [ 70000 ]` cannot match anything; refusing the whole tileset
/// for it would lose a map over a typo, and `assets.md` §4 already chose diagnosable over
/// absent for exactly this shape of mistake.
pub fn solidBitset(gpa: Allocator, record: Record) (ReadError || Allocator.Error)![]u32 {
    const list = (record.fields.listAt(3) catch return error.InvalidRecord) orelse return gpa.alloc(u32, 0);

    var highest: ?u32 = null;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const id = solidIdAt(list, i, record.name) orelse continue;
        if (highest == null or id > highest.?) highest = id;
    }

    const top = highest orelse return gpa.alloc(u32, 0);
    const words = try gpa.alloc(u32, top / 32 + 1);
    errdefer gpa.free(words);
    @memset(words, 0);

    i = 0;
    while (i < list.len) : (i += 1) {
        const id = solidIdAt(list, i, record.name) orelse continue;
        words[id / 32] |= @as(u32, 1) << @intCast(id % 32);
    }
    return words;
}

fn solidIdAt(list: data.fpk.List, index: u32, name: []const u8) ?u32 {
    const value = (list.intAt(index) catch return null) orelse return null;
    if (value < 0) return null;
    if (value > std.math.maxInt(u16)) {
        log.warn("tileset '{s}': solid tile id {d} is above the {d} a tile can hold; ignoring it", .{
            name,
            value,
            std.math.maxInt(u16),
        });
        return null;
    }
    return @intCast(value);
}

// -- reading one field ------------------------------------------------------------------
//
// Every one of these answers *absent* rather than raising, and the caller decides whether
// absence is fatal. A malformed block is the package's problem and reads as absence too, so
// one refusal at the top of each `read` is the whole of the error handling. None of them
// takes an allocator, because none of them reads anything that is not a scalar.

fn idField(record: Record, index: u32) ?ContentId {
    const id = (record.fields.idAt(index) catch return null) orelse return null;
    if (id.isNone()) return null;
    return id;
}

fn u32Field(record: Record, index: u32) ?u32 {
    const value = (record.fields.intAt(index) catch return null) orelse return null;
    if (value < 0 or value > std.math.maxInt(u32)) return null;
    return @intCast(value);
}

fn intField(record: Record, newest: Schema, index: u32) ?i128 {
    if (record.fields.intAt(index) catch null) |present| return present;
    return switch (record.missingDefault(newest, index) orelse return null) {
        .int => |v| v,
        else => null,
    };
}

fn boolField(record: Record, newest: Schema, index: u32) ?bool {
    if (record.fields.boolAt(index) catch null) |present| return present;
    return switch (record.missingDefault(newest, index) orelse return null) {
        .bool => |v| v,
        else => null,
    };
}

fn pairOfU32(record: Record, index: u32) ?[2]u32 {
    const list = (record.fields.listAt(index) catch return null) orelse return null;
    if (list.len != 2) return null;
    var out: [2]u32 = undefined;
    for (&out, 0..) |*slot, i| {
        const value = (list.intAt(@intCast(i)) catch return null) orelse return null;
        if (value < 0 or value > std.math.maxInt(u32)) return null;
        slot.* = @intCast(value);
    }
    return out;
}

fn pairOfF32(record: Record, index: u32) ?[2]f32 {
    const list = (record.fields.listAt(index) catch return null) orelse return null;
    if (list.len != 2) return null;
    var out: [2]f32 = undefined;
    for (&out, 0..) |*slot, i| {
        const value = (list.floatAt(@intCast(i)) catch return null) orelse return null;
        slot.* = @floatCast(value);
    }
    return out;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// Text in, a loaded store out — the whole content pipeline as `fpack` plus the engine run
/// it, so that these readers are tested against records that were really compiled rather
/// than against a struct a test filled in.
const Compiled = struct {
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,

    fn init(gpa: Allocator, source: []const u8) !Compiled {
        var self: Compiled = .{
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
        };
        errdefer self.deinit(gpa);

        try registerAll(gpa, &self.schemas);

        var doc = try data.parser.parse(gpa, "map.fdt", source, .{ .namespace = "sandbox" }, &self.diags);
        defer doc.deinit(gpa);

        var pkg = try data.check.Package.init(gpa, "sandbox:content", 1, .default);
        defer pkg.deinit(gpa);
        try pkg.addDocument(gpa, &doc, &self.schemas, &self.diags);
        try data.fpk.write(gpa, &pkg, &self.schemas, &self.bytes);

        _ = try self.store.add(gpa, "sandbox:content", self.bytes.items, &self.schemas, &self.diags);
        return self;
    }

    fn deinit(self: *Compiled, gpa: Allocator) void {
        self.store.deinit(gpa);
        self.bytes.deinit(gpa);
        self.diags.deinit(gpa);
        self.schemas.deinit(gpa);
    }

    fn record(self: *const Compiled, id: []const u8) Record {
        return self.store.lookup(.fromString(id)).?;
    }
};

const example =
    \\foundry:tileset sandbox:tiles.overworld {
    \\    texture   sandbox:textures.overworld
    \\    tile      [ 16 16 ]
    \\    columns   16
    \\    solid     [ 1 2 3 17 ]
    \\}
    \\
    \\foundry:tilemap.layer sandbox:map.town.ground {
    \\    tileset   sandbox:tiles.overworld
    \\    grid      sandbox:grids.town.ground
    \\}
    \\
    \\foundry:tilemap.layer sandbox:map.town.walls {
    \\    tileset   sandbox:tiles.overworld
    \\    grid      sandbox:grids.town.walls
    \\    order     1
    \\    collides  true
    \\    empty     0
    \\}
    \\
    \\foundry:tilemap sandbox:map.town {
    \\    size    [ 64 48 ]
    \\    cell    [ 16 16 ]
    \\    layers  [ sandbox:map.town.ground  sandbox:map.town.walls ]
    \\}
;

test "the engine's tilemap schemas register, and register twice without complaint" {
    const gpa = testing.allocator;
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);

    try registerAll(gpa, &registry);
    try testing.expectEqual(@as(u32, all.len), registry.count());
    try registerAll(gpa, &registry);
    try testing.expectEqual(@as(u32, all.len), registry.count());

    for (&all) |s| try testing.expect(registry.lookup(s.id) != null);
}

test "a map written the way the design documents it compiles and reads back" {
    const gpa = testing.allocator;
    var compiled = try Compiled.init(gpa, example);
    defer compiled.deinit(gpa);

    const set = try readTileset(compiled.record("sandbox:tiles.overworld"));
    try testing.expect(set.texture.eql(.fromString("sandbox:textures.overworld")));
    try testing.expectEqual(@as(u32, 16), set.tile_width);
    try testing.expectEqual(@as(u32, 16), set.tile_height);
    try testing.expectEqual(@as(u32, 16), set.columns);

    // The defaults are the record's, not this reader's: an unwritten `order` is 0 and an
    // unwritten `collides` is false, and both come out of the schema.
    const ground = try readLayer(compiled.record("sandbox:map.town.ground"));
    try testing.expectEqual(@as(i16, 0), ground.order);
    try testing.expect(!ground.collides);
    try testing.expect(ground.grid.eql(.fromString("sandbox:grids.town.ground")));
    // Absent, not zero. The bottom layer covers the ground, and tile zero is usually what
    // it covers it with — a defaulted `empty` would have punched holes in every map.
    try testing.expectEqual(@as(?u16, null), ground.empty);

    const walls = try readLayer(compiled.record("sandbox:map.town.walls"));
    try testing.expectEqual(@as(i16, 1), walls.order);
    try testing.expect(walls.collides);
    try testing.expectEqual(@as(?u16, 0), walls.empty);

    const map = try readTilemap(compiled.record("sandbox:map.town"));
    try testing.expectEqual(@as(u32, 64), map.width);
    try testing.expectEqual(@as(u32, 48), map.height);
    try testing.expectEqual(@as(f32, 16), map.cell_width);
    try testing.expectEqual(@as(f32, 16), map.cell_height);
}

test "a map's layers come back in the order they were written" {
    const gpa = testing.allocator;
    var compiled = try Compiled.init(gpa, example);
    defer compiled.deinit(gpa);

    const ids = try layerIds(gpa, compiled.record("sandbox:map.town"));
    defer gpa.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    // Draw order is what the author wrote, in a file, in order (I9) -- not a hash map's.
    try testing.expect(ids[0].eql(.fromString("sandbox:map.town.ground")));
    try testing.expect(ids[1].eql(.fromString("sandbox:map.town.walls")));
}

test "a tileset's solid list becomes the bitset physics2d wants" {
    const gpa = testing.allocator;
    var compiled = try Compiled.init(gpa, example);
    defer compiled.deinit(gpa);

    const solid = try solidBitset(gpa, compiled.record("sandbox:tiles.overworld"));
    defer gpa.free(solid);

    // Sized to the largest solid id and no larger: 17 needs one word past the first.
    try testing.expectEqual(@as(usize, 1), solid.len);
    const expected: u32 = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 17);
    try testing.expectEqual(expected, solid[0]);
}

test "a solid id no tile could hold is warned about, not fatal" {
    const gpa = testing.allocator;
    var compiled = try Compiled.init(gpa,
        \\foundry:tileset sandbox:tiles.broken {
        \\    texture sandbox:textures.x
        \\    tile    [ 8 8 ]
        \\    columns 4
        \\    solid   [ 2 70000 ]
        \\}
    );
    defer compiled.deinit(gpa);

    const solid = try solidBitset(gpa, compiled.record("sandbox:tiles.broken"));
    defer gpa.free(solid);
    // Sized by the ids that can matter, so one typo does not allocate 8 KiB either.
    try testing.expectEqual(@as(usize, 1), solid.len);
    try testing.expectEqual(@as(u32, 0b100), solid[0]);
}

test "a tileset with no solid tiles is legal and leaves everything passable" {
    const gpa = testing.allocator;
    var compiled = try Compiled.init(gpa,
        \\foundry:tileset sandbox:tiles.decor {
        \\    texture sandbox:textures.x
        \\    tile    [ 8 8 ]
        \\    columns 4
        \\}
    );
    defer compiled.deinit(gpa);

    const solid = try solidBitset(gpa, compiled.record("sandbox:tiles.decor"));
    defer gpa.free(solid);
    try testing.expectEqual(@as(usize, 0), solid.len);

    // And an empty bitset is exactly what `physics2d` reads as "nothing blocks".
    const map = try readTileset(compiled.record("sandbox:tiles.decor"));
    try testing.expectEqual(@as(u32, 8), map.tile_width);
}

test "a record whose numbers do not mean anything is refused rather than trusted" {
    const gpa = testing.allocator;
    var compiled = try Compiled.init(gpa,
        \\foundry:tileset sandbox:tiles.zero {
        \\    texture sandbox:textures.x
        \\    tile    [ 0 8 ]
        \\    columns 4
        \\}
        \\
        \\foundry:tileset sandbox:tiles.triple {
        \\    texture sandbox:textures.x
        \\    tile    [ 8 8 8 ]
        \\    columns 4
        \\}
        \\
        \\foundry:tilemap sandbox:map.bad {
        \\    size [ 4 0 ]
        \\    cell [ 1 1 ]
        \\}
        \\
        \\foundry:tilemap.layer sandbox:layer.loud {
        \\    tileset sandbox:tiles.zero
        \\    grid    sandbox:grids.x
        \\    order   900000
        \\}
        \\
        \\foundry:tilemap.layer sandbox:layer.nohole {
        \\    tileset sandbox:tiles.zero
        \\    grid    sandbox:grids.x
        \\    empty   70000
        \\}
    );
    defer compiled.deinit(gpa);

    // A zero tile size is not a tileset, and the checker cannot say so: the type list has
    // no "positive u32" and no fixed-length list, so the domain is the reader's to hold.
    try testing.expectError(error.InvalidRecord, readTileset(compiled.record("sandbox:tiles.zero")));
    try testing.expectError(error.InvalidRecord, readTileset(compiled.record("sandbox:tiles.triple")));
    try testing.expectError(error.InvalidRecord, readTilemap(compiled.record("sandbox:map.bad")));
    // A sort layer that does not fit the renderer's key is told so at load, rather than
    // wrapping silently at draw.
    try testing.expectError(error.InvalidRecord, readLayer(compiled.record("sandbox:layer.loud")));
    // And an `empty` no tile id could ever equal, which would otherwise be a hole that
    // never appears and a content bug that reads as a renderer bug.
    try testing.expectError(error.InvalidRecord, readLayer(compiled.record("sandbox:layer.nohole")));
}

test "a map with no layers is a map that draws nothing, not an error" {
    const gpa = testing.allocator;
    var compiled = try Compiled.init(gpa,
        \\foundry:tilemap sandbox:map.empty {
        \\    size [ 4 4 ]
        \\    cell [ 1 1 ]
        \\}
    );
    defer compiled.deinit(gpa);

    const ids = try layerIds(gpa, compiled.record("sandbox:map.empty"));
    defer gpa.free(ids);
    try testing.expectEqual(@as(usize, 0), ids.len);
}
