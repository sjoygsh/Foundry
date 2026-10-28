//! `foundry:nav_mesh`: the recipe for one navigation mesh (`docs/design/navigation.md` §4,
//! ADR-0069).
//!
//! ```fdt
//! foundry:nav_mesh sandbox3d:nav.walker {
//!     sources [ sandbox3d:models.room.collision sandbox3d:models.course.collision ]
//!     agent_radius 0.3  agent_height 1.8  agent_climb 0.35  agent_slope 0.785398
//! }
//! ```
//!
//! **A recipe, not a product.** The record says what a mesh is built from, for which agent and
//! at what resolution; the mesh itself is built at load from the merged store (§7), so a mod
//! that overrides a source or the agent never meets a stale bake. Nothing here builds one.
//!
//! **The agent's four fields mean what the character controller's do**: `agent_climb` is its
//! `step_height` and `agent_slope` its `max_slope`, in radians, as walk records write it.
//!
//! **It lives here, not beside the builder**, for `particle_emitter`'s reason: `fpack` and the
//! editor check a record with no `nav` linked. The bounds are `nav.Config`'s, and the
//! integration test `nav_mesh.zig` holds the two in step, since neither module can name the
//! other.
//!
//! **Every name here is on authors' disks** (CLAUDE.md §7). Adding a field later is additive;
//! renaming one is a break.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Fields = data.fpk.Fields;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

pub const nav_mesh_name = "foundry:nav_mesh";

/// A level's collision and what is placed on it, as one game names them.
pub const max_sources: usize = 16;
pub const max_polygon_vertices: u32 = 6;

/// Version 1.
pub const nav_mesh: Schema = .{
    .id = SchemaId.fromStringUnchecked(nav_mesh_name),
    .version = 1,
    .fields = &.{
        .{ .name = "sources", .type = .{ .list = &.id } },
        .{ .name = "agent_radius", .type = .f32 },
        .{ .name = "agent_height", .type = .f32 },
        .{ .name = "agent_climb", .type = .f32 },
        .{ .name = "agent_slope", .type = .f32 },
        .{ .name = "cell_size", .type = .f32, .presence = .{ .default = .{ .float = 0.1 } } },
        .{ .name = "cell_height", .type = .f32, .presence = .{ .default = .{ .float = 0.05 } } },
        .{ .name = "region_min_area", .type = .f32, .presence = .{ .default = .{ .float = 0.5 } } },
        .{ .name = "region_merge_area", .type = .f32, .presence = .{ .default = .{ .float = 4 } } },
        .{ .name = "edge_max_length", .type = .f32, .presence = .{ .default = .{ .float = 6 } } },
        .{ .name = "edge_max_error", .type = .f32, .presence = .{ .default = .{ .float = 0.13 } } },
        .{ .name = "polygon_max_vertices", .type = .u32, .presence = .{ .default = .{ .int = 6 } } },
        .{ .name = "detail_sample_distance", .type = .f32, .presence = .{ .default = .{ .float = 0.6 } } },
        .{ .name = "detail_max_error", .type = .f32, .presence = .{ .default = .{ .float = 0.05 } } },
    },
};

pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(gpa, nav_mesh);
}

/// A decoded recipe. The fields after `sources` are `nav.Config`'s, one for one.
pub const Settings = struct {
    source_buffer: [max_sources]ContentId = @splat(.none),
    source_count: u8 = 0,
    agent_radius: f32,
    agent_height: f32,
    agent_climb: f32,
    agent_slope: f32,
    cell_size: f32 = 0.1,
    cell_height: f32 = 0.05,
    region_min_area: f32 = 0.5,
    region_merge_area: f32 = 4,
    edge_max_length: f32 = 6,
    edge_max_error: f32 = 0.13,
    polygon_max_vertices: u32 = max_polygon_vertices,
    detail_sample_distance: f32 = 0.6,
    detail_max_error: f32 = 0.05,

    pub fn sources(self: *const Settings) []const ContentId {
        return self.source_buffer[0..self.source_count];
    }

    /// The value's own bounds, in field order (§4). A field whose bound depends on another is
    /// reported as the dependent one.
    pub fn validate(s: *const Settings) Refusal!void {
        if (s.source_count == 0) return error.NoSources;
        for (s.sources(), 0..) |id, i| {
            if (id.isNone()) return error.InvalidSource;
            for (s.sources()[0..i]) |earlier| if (earlier.eql(id)) return error.DuplicateSource;
        }
        if (!within(s.agent_radius, 0, 5)) return error.InvalidAgentRadius;
        if (!within(s.agent_height, 0.1, 10) or s.agent_height < 2 * s.agent_radius) return error.InvalidAgentHeight;
        if (!within(s.agent_climb, 0, s.agent_height)) return error.InvalidAgentClimb;
        if (!std.math.isFinite(s.agent_slope) or s.agent_slope <= 0 or s.agent_slope >= std.math.pi / 2.0) return error.InvalidAgentSlope;
        if (!within(s.cell_size, 0.01, 1)) return error.InvalidCellSize;
        if (!within(s.cell_height, 0.01, 1)) return error.InvalidCellHeight;
        if (!within(s.region_min_area, 0, 10_000)) return error.InvalidRegionMinArea;
        if (!within(s.region_merge_area, 0, 10_000)) return error.InvalidRegionMergeArea;
        if (!within(s.edge_max_length, 0, 100)) return error.InvalidEdgeMaxLength;
        if (!within(s.edge_max_error, 0.01, 3)) return error.InvalidEdgeMaxError;
        if (s.polygon_max_vertices < 3 or s.polygon_max_vertices > max_polygon_vertices) return error.InvalidPolygonMaxVertices;
        if (!within(s.detail_sample_distance, 0, 10) or
            (s.detail_sample_distance != 0 and s.detail_sample_distance < 0.1)) return error.InvalidDetailSampleDistance;
        if (!within(s.detail_max_error, 0, 1)) return error.InvalidDetailMaxError;
    }
};

/// What a value can get wrong, field by field.
pub const Refusal = error{
    NoSources,
    InvalidSource,
    DuplicateSource,
    InvalidAgentRadius,
    InvalidAgentHeight,
    InvalidAgentClimb,
    InvalidAgentSlope,
    InvalidCellSize,
    InvalidCellHeight,
    InvalidRegionMinArea,
    InvalidRegionMergeArea,
    InvalidEdgeMaxLength,
    InvalidEdgeMaxError,
    InvalidPolygonMaxVertices,
    InvalidDetailSampleDistance,
    InvalidDetailMaxError,
};

/// What only a record can get wrong, besides the value's refusals.
pub const DecodeError = Refusal || error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    TooManySources,
    /// A source names a record that is not a `foundry:collision_mesh`, checked where IDs
    /// resolve, at load.
    NotACollisionMesh,
};

/// A sentence naming the field, for a diagnostic or a log line: "its <...>".
pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.Unreadable => "cannot be read against its schema",
        error.NoSources => "has no sources",
        error.TooManySources => "has more than 16 sources",
        error.InvalidSource => "has a source that is none",
        error.DuplicateSource => "names a source twice",
        error.NotACollisionMesh => "names a source that is not a foundry:collision_mesh",
        error.InvalidAgentRadius => "has an agent_radius that is not between 0 and 5 m",
        error.InvalidAgentHeight => "has an agent_height that is not between 0.1 and 10 m, or is less than twice its agent_radius",
        error.InvalidAgentClimb => "has an agent_climb that is not between 0 and its agent_height",
        error.InvalidAgentSlope => "has an agent_slope that is not between 0 and pi/2 radians, both excluded",
        error.InvalidCellSize => "has a cell_size that is not between 0.01 and 1 m",
        error.InvalidCellHeight => "has a cell_height that is not between 0.01 and 1 m",
        error.InvalidRegionMinArea => "has a region_min_area that is not between 0 and 10,000 m²",
        error.InvalidRegionMergeArea => "has a region_merge_area that is not between 0 and 10,000 m²",
        error.InvalidEdgeMaxLength => "has an edge_max_length that is not between 0 and 100 m",
        error.InvalidEdgeMaxError => "has an edge_max_error that is not between 0.01 and 3 m",
        error.InvalidPolygonMaxVertices => "has a polygon_max_vertices that is not between 3 and 6",
        error.InvalidDetailSampleDistance => "has a detail_sample_distance that is neither 0 nor between 0.1 and 10 m",
        error.InvalidDetailMaxError => "has a detail_max_error that is not between 0 and 1 m",
    };
}

/// Reads a `foundry:nav_mesh`. An absent optional field is its default.
pub fn decode(fields: Fields) DecodeError!Settings {
    var out: Settings = .{
        .agent_radius = try floatOf(fields, "agent_radius") orelse return error.Unreadable,
        .agent_height = try floatOf(fields, "agent_height") orelse return error.Unreadable,
        .agent_climb = try floatOf(fields, "agent_climb") orelse return error.Unreadable,
        .agent_slope = try floatOf(fields, "agent_slope") orelse return error.Unreadable,
    };
    const list = try listOf(fields, "sources") orelse return error.Unreadable;
    if (list.len > max_sources) return error.TooManySources;
    for (0..list.len) |i| {
        out.source_buffer[i] = (list.idAt(@intCast(i)) catch return error.Unreadable) orelse .none;
    }
    out.source_count = @intCast(list.len);
    if (try floatOf(fields, "cell_size")) |v| out.cell_size = v;
    if (try floatOf(fields, "cell_height")) |v| out.cell_height = v;
    if (try floatOf(fields, "region_min_area")) |v| out.region_min_area = v;
    if (try floatOf(fields, "region_merge_area")) |v| out.region_merge_area = v;
    if (try floatOf(fields, "edge_max_length")) |v| out.edge_max_length = v;
    if (try floatOf(fields, "edge_max_error")) |v| out.edge_max_error = v;
    if (try intOf(fields, "polygon_max_vertices")) |v| out.polygon_max_vertices = std.math.cast(u32, v) orelse return error.InvalidPolygonMaxVertices;
    if (try floatOf(fields, "detail_sample_distance")) |v| out.detail_sample_distance = v;
    if (try floatOf(fields, "detail_max_error")) |v| out.detail_max_error = v;
    try out.validate();
    return out;
}

/// Whether every source names a `foundry:collision_mesh` in `store`. IDs resolve across
/// packages, so this runs at load, as a walk record's collision list is checked.
pub fn checkSources(value: *const Settings, store: *const data.Store, collision_mesh: SchemaId) DecodeError!void {
    for (value.sources()) |id| {
        const record = store.lookup(id) orelse return error.NotACollisionMesh;
        if (!record.schema_id.eql(collision_mesh)) return error.NotACollisionMesh;
    }
}

fn indexOf(fields: Fields, field: []const u8) ?u32 {
    for (fields.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, field)) return @intCast(i);
    return null;
}

fn floatOf(fields: Fields, field: []const u8) DecodeError!?f32 {
    const i = indexOf(fields, field) orelse return null;
    const value = (fields.floatAt(i) catch return error.Unreadable) orelse return null;
    return @floatCast(value);
}

fn intOf(fields: Fields, field: []const u8) DecodeError!?i128 {
    const i = indexOf(fields, field) orelse return null;
    return fields.intAt(i) catch return error.Unreadable;
}

fn listOf(fields: Fields, field: []const u8) DecodeError!?data.fpk.List {
    const i = indexOf(fields, field) orelse return null;
    return fields.listAt(i) catch return error.Unreadable;
}

fn within(value: f32, lo: f32, hi: f32) bool {
    return std.math.isFinite(value) and value >= lo and value <= hi;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const schemas_mod = @import("schemas.zig");

/// A package compiled from text, kept open so its records can be decoded.
const Compiled = struct {
    bytes: std.ArrayList(u8),
    reader: data.fpk.Reader,

    fn init(source: []const u8) !*Compiled {
        const gpa = testing.allocator;
        var registry: Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        try registerAll(gpa, &registry);
        try schemas_mod.registerAll(gpa, &registry);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);
        var doc = try data.parser.parse(gpa, "nav.fdt", source, .{ .namespace = "t" }, &diags);
        defer doc.deinit(gpa);
        var package = try data.check.Package.init(gpa, "t:content", 1, .default);
        defer package.deinit(gpa);
        try package.addDocument(gpa, &doc, &registry, &diags);
        const self = try gpa.create(Compiled);
        errdefer gpa.destroy(self);
        self.bytes = .empty;
        errdefer self.bytes.deinit(gpa);
        try data.fpk.write(gpa, &package, &registry, &self.bytes);
        self.reader = try data.fpk.Reader.open(gpa, self.bytes.items, .default);
        return self;
    }

    fn deinit(self: *Compiled) void {
        self.reader.deinit();
        self.bytes.deinit(testing.allocator);
        testing.allocator.destroy(self);
    }

    fn fields(self: *Compiled, i: u32) Fields {
        const view = self.reader.record(i).?;
        return self.reader.fieldsOf(view, self.reader.schemaFor(view.schema_id).?.*);
    }
};

const agent = "agent_radius 0.3 agent_height 1.8 agent_climb 0.35 agent_slope 0.785398";

/// The one record's refusal, or null if it decodes.
fn refusalOf(source: []const u8) !?DecodeError {
    const c = try Compiled.init(source);
    defer c.deinit();
    _ = decode(c.fields(0)) catch |err| return @as(?DecodeError, err);
    return null;
}

test "an absent field is its default" {
    const c = try Compiled.init("foundry:nav_mesh t:n { sources [ t:level ] " ++ agent ++ " }");
    defer c.deinit();
    const s = try decode(c.fields(0));
    try testing.expectEqual(@as(usize, 1), s.sources().len);
    try testing.expect(s.sources()[0].eql(ContentId.fromString("t:level")));
    try testing.expectEqual(@as(f32, 0.3), s.agent_radius);
    try testing.expectEqual(@as(f32, 1.8), s.agent_height);
    try testing.expectEqual(@as(f32, 0.35), s.agent_climb);
    try testing.expectEqual(@as(f32, 0.785398), s.agent_slope);
    var expected: Settings = .{ .agent_radius = 0.3, .agent_height = 1.8, .agent_climb = 0.35, .agent_slope = 0.785398 };
    expected.source_buffer = s.source_buffer;
    expected.source_count = 1;
    try testing.expectEqual(expected, s);
}

test "every field is read as written" {
    const c = try Compiled.init(
        \\foundry:nav_mesh t:n {
        \\    sources [ t:a t:b ]
        \\    agent_radius 0.22 agent_height 1.7 agent_climb 0.25 agent_slope 0.6
        \\    cell_size 0.05 cell_height 0.02 region_min_area 1 region_merge_area 8
        \\    edge_max_length 0 edge_max_error 0.2 polygon_max_vertices 4
        \\    detail_sample_distance 0 detail_max_error 0.1
        \\}
    );
    defer c.deinit();
    const s = try decode(c.fields(0));
    try testing.expectEqual(@as(usize, 2), s.sources().len);
    try testing.expect(s.sources()[1].eql(ContentId.fromString("t:b")));
    try testing.expectEqual(@as(f32, 0.22), s.agent_radius);
    try testing.expectEqual(@as(f32, 0.6), s.agent_slope);
    try testing.expectEqual(@as(f32, 0.05), s.cell_size);
    try testing.expectEqual(@as(f32, 0.02), s.cell_height);
    try testing.expectEqual(@as(f32, 1), s.region_min_area);
    try testing.expectEqual(@as(f32, 8), s.region_merge_area);
    try testing.expectEqual(@as(f32, 0), s.edge_max_length);
    try testing.expectEqual(@as(f32, 0.2), s.edge_max_error);
    try testing.expectEqual(@as(u32, 4), s.polygon_max_vertices);
    try testing.expectEqual(@as(f32, 0), s.detail_sample_distance);
    try testing.expectEqual(@as(f32, 0.1), s.detail_max_error);
}

test "every refusal is named" {
    const head = "foundry:nav_mesh t:n { sources [ t:level ] ";
    const cases = [_]struct { source: []const u8, err: DecodeError }{
        .{ .source = "foundry:nav_mesh t:n { sources [ ] " ++ agent ++ " }", .err = error.NoSources },
        .{ .source = "foundry:nav_mesh t:n { sources [ t:a t:b t:c t:d t:e t:f t:g t:h t:i t:j t:k t:l t:m t:n t:o t:p t:q ] " ++ agent ++ " }", .err = error.TooManySources },
        .{ .source = "foundry:nav_mesh t:n { sources [ t:a t:b t:a ] " ++ agent ++ " }", .err = error.DuplicateSource },
        .{ .source = head ++ "agent_radius -0.1 agent_height 1.8 agent_climb 0.35 agent_slope 0.7 }", .err = error.InvalidAgentRadius },
        .{ .source = head ++ "agent_radius 5.5 agent_height 10 agent_climb 0.35 agent_slope 0.7 }", .err = error.InvalidAgentRadius },
        .{ .source = head ++ "agent_radius 0.3 agent_height 0.05 agent_climb 0 agent_slope 0.7 }", .err = error.InvalidAgentHeight },
        .{ .source = head ++ "agent_radius 0.3 agent_height 11 agent_climb 0.35 agent_slope 0.7 }", .err = error.InvalidAgentHeight },
        .{ .source = head ++ "agent_radius 0.5 agent_height 0.9 agent_climb 0.35 agent_slope 0.7 }", .err = error.InvalidAgentHeight },
        .{ .source = head ++ "agent_radius 0.3 agent_height 1.8 agent_climb -0.1 agent_slope 0.7 }", .err = error.InvalidAgentClimb },
        .{ .source = head ++ "agent_radius 0.3 agent_height 1.8 agent_climb 1.9 agent_slope 0.7 }", .err = error.InvalidAgentClimb },
        .{ .source = head ++ "agent_radius 0.3 agent_height 1.8 agent_climb 0.35 agent_slope 0 }", .err = error.InvalidAgentSlope },
        .{ .source = head ++ "agent_radius 0.3 agent_height 1.8 agent_climb 0.35 agent_slope 1.5708 }", .err = error.InvalidAgentSlope },
        .{ .source = head ++ agent ++ " cell_size 0.005 }", .err = error.InvalidCellSize },
        .{ .source = head ++ agent ++ " cell_size 1.5 }", .err = error.InvalidCellSize },
        .{ .source = head ++ agent ++ " cell_height 0 }", .err = error.InvalidCellHeight },
        .{ .source = head ++ agent ++ " cell_height 2 }", .err = error.InvalidCellHeight },
        .{ .source = head ++ agent ++ " region_min_area -1 }", .err = error.InvalidRegionMinArea },
        .{ .source = head ++ agent ++ " region_min_area 10001 }", .err = error.InvalidRegionMinArea },
        .{ .source = head ++ agent ++ " region_merge_area -1 }", .err = error.InvalidRegionMergeArea },
        .{ .source = head ++ agent ++ " region_merge_area 20000 }", .err = error.InvalidRegionMergeArea },
        .{ .source = head ++ agent ++ " edge_max_length -1 }", .err = error.InvalidEdgeMaxLength },
        .{ .source = head ++ agent ++ " edge_max_length 101 }", .err = error.InvalidEdgeMaxLength },
        .{ .source = head ++ agent ++ " edge_max_error 0.001 }", .err = error.InvalidEdgeMaxError },
        .{ .source = head ++ agent ++ " edge_max_error 4 }", .err = error.InvalidEdgeMaxError },
        .{ .source = head ++ agent ++ " polygon_max_vertices 2 }", .err = error.InvalidPolygonMaxVertices },
        .{ .source = head ++ agent ++ " polygon_max_vertices 7 }", .err = error.InvalidPolygonMaxVertices },
        .{ .source = head ++ agent ++ " detail_sample_distance 0.05 }", .err = error.InvalidDetailSampleDistance },
        .{ .source = head ++ agent ++ " detail_sample_distance 11 }", .err = error.InvalidDetailSampleDistance },
        .{ .source = head ++ agent ++ " detail_max_error -0.1 }", .err = error.InvalidDetailMaxError },
        .{ .source = head ++ agent ++ " detail_max_error 1.5 }", .err = error.InvalidDetailMaxError },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?DecodeError, case.err), try refusalOf(case.source));
    }
    // The bounds themselves are accepted.
    try testing.expectEqual(@as(?DecodeError, null), try refusalOf(head ++ "agent_radius 0 agent_height 0.1 agent_climb 0.1 agent_slope 1.57 cell_size 0.01 cell_height 1 edge_max_length 100 polygon_max_vertices 3 detail_sample_distance 0.1 detail_max_error 1 }"));
}

/// A store of packages added in order, each compiled from its own text. The store borrows a
/// package's bytes, so they live as long as it does.
const Stored = struct {
    registry: Registry,
    store: data.Store,
    diags: data.Diagnostics,
    bytes: [2]std.ArrayList(u8) = .{ .empty, .empty },

    fn init(packages: []const []const u8) !*Stored {
        const gpa = testing.allocator;
        const self = try gpa.create(Stored);
        errdefer gpa.destroy(self);
        self.registry = .init(gpa, .default);
        self.store = .init(gpa, .default);
        self.diags = .init(gpa, .default);
        self.bytes = .{ .empty, .empty };
        errdefer self.deinit();
        try registerAll(gpa, &self.registry);
        try schemas_mod.registerAll(gpa, &self.registry);
        const names = [_][]const u8{ "t:base", "t:mod" };
        for (packages, 0..) |source, i| {
            var doc = try data.parser.parse(gpa, "nav.fdt", source, .{ .namespace = "t" }, &self.diags);
            defer doc.deinit(gpa);
            var package = try data.check.Package.init(gpa, names[i], 1, .default);
            defer package.deinit(gpa);
            try package.addDocument(gpa, &doc, &self.registry, &self.diags);
            try data.fpk.write(gpa, &package, &self.registry, &self.bytes[i]);
            _ = try self.store.add(gpa, names[i], self.bytes[i].items, &self.registry, &self.diags);
        }
        return self;
    }

    fn deinit(self: *Stored) void {
        const gpa = testing.allocator;
        self.store.deinit(gpa);
        for (&self.bytes) |*b| b.deinit(gpa);
        self.diags.deinit(gpa);
        self.registry.deinit(gpa);
        gpa.destroy(self);
    }
};

test "an override replaces a recipe whole" {
    const s = try Stored.init(&.{
        "foundry:nav_mesh t:n { sources [ t:level ] " ++ agent ++ " cell_size 0.2 }",
        "foundry:nav_mesh t:n { sources [ t:level ] agent_radius 0.6 agent_height 1.8 agent_climb 0.35 agent_slope 0.785398 }",
    });
    defer s.deinit();
    const value = try decode(s.store.lookup(ContentId.fromString("t:n")).?.fields);
    try testing.expectEqual(@as(f32, 0.6), value.agent_radius);
    // Whole: the base's cell_size does not survive the override.
    try testing.expectEqual(@as(f32, 0.1), value.cell_size);
}

test "a source must be a collision mesh where IDs resolve" {
    const s = try Stored.init(&.{
        \\foundry:collision_mesh t:level { source "level.fcol" }
        \\foundry:texture t:paving { source "paving.png" }
    });
    defer s.deinit();
    var value: Settings = .{ .agent_radius = 0.3, .agent_height = 1.8, .agent_climb = 0.35, .agent_slope = 0.785398 };
    value.source_buffer[0] = ContentId.fromString("t:level");
    value.source_count = 1;
    try checkSources(&value, &s.store, schemas_mod.collision_mesh.id);
    value.source_buffer[1] = ContentId.fromString("t:paving");
    value.source_count = 2;
    try testing.expectError(error.NotACollisionMesh, checkSources(&value, &s.store, schemas_mod.collision_mesh.id));
    value.source_buffer[1] = ContentId.fromString("t:missing");
    try testing.expectError(error.NotACollisionMesh, checkSources(&value, &s.store, schemas_mod.collision_mesh.id));
}
