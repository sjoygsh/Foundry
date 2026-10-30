//! `foundry:nav_mesh`: the recipe for one navigation mesh (`docs/design/navigation.md` §4,
//! ADR-0069), and `foundry:nav_area`, a named cost a recipe's volumes mark floors with
//! (`docs/design/agents.md` §3).
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
//! **Version 2 adds `volumes` and `links`, both optional,** so a version 1 record reads unchanged
//! and builds the same bytes. A link's kind is a string because the three motions are engine
//! code: a mod places links and adds no kind.
//!
//! **Every name here is on authors' disks** (CLAUDE.md §7). Adding a field later is additive;
//! renaming one is a break.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Fields = data.fpk.Fields;
const FieldType = data.FieldType;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;
const Vec3 = core.math.Vec3;

pub const nav_mesh_name = "foundry:nav_mesh";
pub const nav_area_name = "foundry:nav_area";

/// A level's collision and what is placed on it, as one game names them.
pub const max_sources: usize = 16;
pub const max_polygon_vertices: u32 = 6;
pub const max_volumes: usize = 32;
pub const max_links: usize = 64;
/// Distinct area types a recipe may name. Unmarked floor is one more, with no record.
pub const max_areas: usize = 8;
/// `nav`'s coordinate envelope, as `physics3d`'s.
pub const max_coordinate: f32 = 8192;
pub const min_link_length: f32 = 0.1;
pub const max_area_cost: f32 = 1000;
pub const max_link_cost: f32 = 1000;

const point_type: FieldType = .{ .nested = &.{
    .{ .name = "x", .type = .f32 },
    .{ .name = "y", .type = .f32 },
    .{ .name = "z", .type = .f32 },
} };

const volume_type: FieldType = .{ .nested = &.{
    .{ .name = "area", .type = .id },
    .{ .name = "min", .type = point_type },
    .{ .name = "max", .type = point_type },
} };

const link_type: FieldType = .{ .nested = &.{
    .{ .name = "kind", .type = .string },
    .{ .name = "from", .type = point_type },
    .{ .name = "to", .type = point_type },
    .{ .name = "two_way", .type = .bool, .presence = .{ .default = .{ .bool = false } } },
    .{ .name = "cost", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "snap", .type = .f32, .presence = .{ .default = .{ .float = 0.5 } } },
    .{ .name = "arc", .type = .f32, .presence = .{ .default = .{ .float = 0.5 } } },
} };

/// Version 2: `volumes` and `links` joined it in M33.
pub const nav_mesh: Schema = .{
    .id = SchemaId.fromStringUnchecked(nav_mesh_name),
    .version = 2,
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
        .{ .name = "volumes", .type = .{ .list = &volume_type }, .presence = .optional, .since = 2 },
        .{ .name = "links", .type = .{ .list = &link_type }, .presence = .optional, .since = 2 },
    },
};

/// The fields version 1 had, for the test that an old record reads under version 2.
pub const version_1_fields = nav_mesh.fields[0..14];

/// Version 1.
pub const nav_area: Schema = .{
    .id = SchemaId.fromStringUnchecked(nav_area_name),
    .version = 1,
    .fields = &.{
        .{ .name = "cost", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
    },
};

pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(gpa, nav_mesh);
    _ = try registry.register(gpa, nav_area);
}

pub const LinkKind = enum { jump, drop, ladder };

/// An axis-aligned box marking the floors inside it with one area.
pub const Volume = struct {
    area: ContentId = .none,
    min: Vec3 = .zero,
    max: Vec3 = .zero,
};

/// An off-mesh link, as a recipe writes it. `nav` attaches its ends to polygons at build.
pub const Link = struct {
    kind: LinkKind = .jump,
    from: Vec3 = .zero,
    to: Vec3 = .zero,
    two_way: bool = false,
    cost: f32 = 0,
    snap: f32 = 0.5,
    arc: f32 = 0.5,
};

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
    volume_buffer: [max_volumes]Volume = @splat(.{}),
    volume_count: u8 = 0,
    link_buffer: [max_links]Link = @splat(.{}),
    link_count: u8 = 0,

    pub fn sources(self: *const Settings) []const ContentId {
        return self.source_buffer[0..self.source_count];
    }

    pub fn volumes(self: *const Settings) []const Volume {
        return self.volume_buffer[0..self.volume_count];
    }

    pub fn links(self: *const Settings) []const Link {
        return self.link_buffer[0..self.link_count];
    }

    /// The distinct areas the volumes name, in order of first use. A mesh's area index is one
    /// more than the area's place here, since 0 is unmarked floor.
    pub fn areas(self: *const Settings, out: *[max_areas]ContentId) []const ContentId {
        var n: usize = 0;
        next: for (self.volumes()) |v| {
            for (out[0..n]) |seen| if (seen.eql(v.area)) continue :next;
            if (n == max_areas) break;
            out[n] = v.area;
            n += 1;
        }
        return out[0..n];
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
        var distinct: [max_areas]ContentId = undefined;
        var named: usize = 0;
        next: for (s.volumes()) |v| {
            if (v.area.isNone()) return error.InvalidVolumeArea;
            if (!boxValid(v.min, v.max)) return error.InvalidVolumeBox;
            for (distinct[0..named]) |seen| if (seen.eql(v.area)) continue :next;
            if (named == max_areas) return error.TooManyAreas;
            distinct[named] = v.area;
            named += 1;
        }
        for (s.links()) |l| {
            if (!pointValid(l.from) or !pointValid(l.to) or l.to.sub(l.from).length() < min_link_length) return error.InvalidLinkEnds;
            if (!within(l.cost, 0, max_link_cost)) return error.InvalidLinkCost;
            if (!within(l.snap, 0.05, 5)) return error.InvalidLinkSnap;
            if (!within(l.arc, 0, 10)) return error.InvalidLinkArc;
        }
    }
};

/// A decoded `foundry:nav_area`.
pub const Area = struct {
    cost: f32 = 1,
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
    InvalidVolumeArea,
    InvalidVolumeBox,
    TooManyAreas,
    InvalidLinkEnds,
    InvalidLinkCost,
    InvalidLinkSnap,
    InvalidLinkArc,
};

/// What only a record can get wrong, besides the value's refusals.
pub const DecodeError = Refusal || error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    TooManySources,
    TooManyVolumes,
    TooManyLinks,
    InvalidLinkKind,
    InvalidAreaCost,
    /// A source names a record that is not a `foundry:collision_mesh`, checked where IDs
    /// resolve, at load.
    NotACollisionMesh,
    /// A volume names a record that is not a `foundry:nav_area`, checked at load likewise.
    NotANavArea,
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
        error.NotANavArea => "has a volume whose area is not a foundry:nav_area",
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
        error.TooManyVolumes => "has more than 32 volumes",
        error.TooManyLinks => "has more than 64 links",
        error.TooManyAreas => "names more than 8 areas",
        error.InvalidVolumeArea => "has a volume whose area is none",
        error.InvalidVolumeBox => "has a volume whose min is not below its max on every axis, or that leaves the 8,192 m envelope",
        error.InvalidLinkKind => "has a link whose kind is not jump, drop or ladder",
        error.InvalidLinkEnds => "has a link whose ends leave the 8,192 m envelope or are less than 0.1 m apart",
        error.InvalidLinkCost => "has a link whose cost is not between 0 and 1,000 m",
        error.InvalidLinkSnap => "has a link whose snap is not between 0.05 and 5 m",
        error.InvalidLinkArc => "has a link whose arc is not between 0 and 10 m",
        error.InvalidAreaCost => "has a cost that is not between 1 and 1,000",
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
    if (try listOf(fields, "volumes")) |volumes| {
        if (volumes.len > max_volumes) return error.TooManyVolumes;
        for (0..volumes.len) |i| {
            const v = (volumes.nestedAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
            const area = indexOf(v, "area") orelse return error.Unreadable;
            out.volume_buffer[i] = .{
                .area = (v.idAt(area) catch return error.Unreadable) orelse .none,
                .min = try pointOf(v, "min"),
                .max = try pointOf(v, "max"),
            };
        }
        out.volume_count = @intCast(volumes.len);
    }
    if (try listOf(fields, "links")) |links| {
        if (links.len > max_links) return error.TooManyLinks;
        for (0..links.len) |i| {
            const l = (links.nestedAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
            const kind = indexOf(l, "kind") orelse return error.Unreadable;
            const name = (l.stringAt(kind) catch return error.Unreadable) orelse return error.Unreadable;
            var link: Link = .{
                .kind = std.meta.stringToEnum(LinkKind, name) orelse return error.InvalidLinkKind,
                .from = try pointOf(l, "from"),
                .to = try pointOf(l, "to"),
            };
            if (indexOf(l, "two_way")) |at| link.two_way = (l.boolAt(at) catch return error.Unreadable) orelse false;
            if (try floatOf(l, "cost")) |v| link.cost = v;
            if (try floatOf(l, "snap")) |v| link.snap = v;
            if (try floatOf(l, "arc")) |v| link.arc = v;
            out.link_buffer[i] = link;
        }
        out.link_count = @intCast(links.len);
    }
    try out.validate();
    return out;
}

/// Reads a `foundry:nav_area`.
pub fn decodeArea(fields: Fields) DecodeError!Area {
    var out: Area = .{};
    if (try floatOf(fields, "cost")) |v| out.cost = v;
    if (!within(out.cost, 1, max_area_cost)) return error.InvalidAreaCost;
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

/// Each area the volumes name, as its cost, at its index in a mesh: `out[0]` is unmarked floor.
/// Answers how many entries it wrote. IDs resolve across packages, so this runs at load, and a
/// mod may supply the record a volume names.
pub fn resolveAreas(value: *const Settings, store: *const data.Store, out: *[max_areas + 1]f32) DecodeError!usize {
    var ids: [max_areas]ContentId = undefined;
    const areas = value.areas(&ids);
    out[0] = 1;
    for (areas, out[1..][0..areas.len]) |id, *cost| {
        const record = store.lookup(id) orelse return error.NotANavArea;
        if (!record.schema_id.eql(nav_area.id)) return error.NotANavArea;
        cost.* = (try decodeArea(record.fields)).cost;
    }
    return areas.len + 1;
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

fn pointOf(fields: Fields, field: []const u8) DecodeError!Vec3 {
    const i = indexOf(fields, field) orelse return error.Unreadable;
    const p = (fields.nestedAt(i) catch return error.Unreadable) orelse return error.Unreadable;
    return .init(
        try floatOf(p, "x") orelse return error.Unreadable,
        try floatOf(p, "y") orelse return error.Unreadable,
        try floatOf(p, "z") orelse return error.Unreadable,
    );
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

fn pointValid(p: Vec3) bool {
    return within(p.x, -max_coordinate, max_coordinate) and within(p.y, -max_coordinate, max_coordinate) and within(p.z, -max_coordinate, max_coordinate);
}

fn boxValid(lo: Vec3, hi: Vec3) bool {
    return pointValid(lo) and pointValid(hi) and lo.x < hi.x and lo.y < hi.y and lo.z < hi.z;
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

const box = "min { x 0 y 0 z 0 } max { x 1 y 1 z 1 }";
const ends = "from { x 0 y 0 z 0 } to { x 1 y 0 z 0 }";

test "volumes and links are read as written, and default" {
    const c = try Compiled.init(
        \\foundry:nav_mesh t:n {
        \\    sources [ t:level ]
        \\    agent_radius 0.3 agent_height 1.8 agent_climb 0.35 agent_slope 0.7
        \\    volumes [
        \\        { area t:mud min { x -3 y -0.5 z 0 } max { x -1 y 0.5 z 2 } }
        \\        { area t:ice min { x 0 y 0 z 0 } max { x 1 y 1 z 1 } }
        \\        { area t:mud min { x 2 y 0 z 0 } max { x 3 y 1 z 1 } }
        \\    ]
        \\    links [
        \\        { kind "ladder" from { x 1 y 0 z -2 } to { x 1 y 0.8 z -2.6 } two_way true cost 2 snap 1 arc 0.25 }
        \\        { kind "drop" from { x 3 y 0.6 z 1 } to { x 3.8 y 0 z 1 } }
        \\    ]
        \\}
    );
    defer c.deinit();
    const s = try decode(c.fields(0));
    try testing.expectEqual(@as(usize, 3), s.volumes().len);
    try testing.expect(s.volumes()[0].area.eql(ContentId.fromString("t:mud")));
    try testing.expectEqual(@as(f32, -3), s.volumes()[0].min.x);
    try testing.expectEqual(@as(f32, 0.5), s.volumes()[0].max.y);
    var ids: [max_areas]ContentId = undefined;
    const areas = s.areas(&ids);
    try testing.expectEqual(@as(usize, 2), areas.len);
    try testing.expect(areas[1].eql(ContentId.fromString("t:ice")));
    try testing.expectEqual(@as(usize, 2), s.links().len);
    const ladder = s.links()[0];
    try testing.expectEqual(LinkKind.ladder, ladder.kind);
    try testing.expect(ladder.two_way);
    try testing.expectEqual(@as(f32, 2), ladder.cost);
    try testing.expectEqual(@as(f32, 1), ladder.snap);
    try testing.expectEqual(@as(f32, 0.25), ladder.arc);
    try testing.expectEqual(@as(f32, -2.6), ladder.to.z);
    const drop = s.links()[1];
    try testing.expectEqual(LinkKind.drop, drop.kind);
    try testing.expect(!drop.two_way);
    try testing.expectEqual(@as(f32, 0), drop.cost);
    try testing.expectEqual(@as(f32, 0.5), drop.snap);
    try testing.expectEqual(@as(f32, 0.5), drop.arc);
}

test "every kind of link and every refusal of version 2 is named" {
    const head = "foundry:nav_mesh t:n { sources [ t:level ] " ++ agent ++ " ";
    const cases = [_]struct { source: []const u8, err: DecodeError }{
        .{ .source = head ++ "volumes [ { area t:a min { x 1 y 0 z 0 } max { x 1 y 1 z 1 } } ] }", .err = error.InvalidVolumeBox },
        .{ .source = head ++ "volumes [ { area t:a min { x 0 y 2 z 0 } max { x 1 y 1 z 1 } } ] }", .err = error.InvalidVolumeBox },
        .{ .source = head ++ "volumes [ { area t:a min { x 0 y 0 z 0 } max { x 1 y 1 z 0 } } ] }", .err = error.InvalidVolumeBox },
        .{ .source = head ++ "volumes [ { area t:a min { x -9000 y 0 z 0 } max { x 1 y 1 z 1 } } ] }", .err = error.InvalidVolumeBox },
        .{ .source = head ++ "links [ { kind \"swim\" " ++ ends ++ " } ] }", .err = error.InvalidLinkKind },
        .{ .source = head ++ "links [ { kind \"jump\" from { x 0 y 0 z 0 } to { x 0.05 y 0 z 0 } } ] }", .err = error.InvalidLinkEnds },
        .{ .source = head ++ "links [ { kind \"jump\" from { x 0 y 9000 z 0 } to { x 1 y 0 z 0 } } ] }", .err = error.InvalidLinkEnds },
        .{ .source = head ++ "links [ { kind \"jump\" " ++ ends ++ " cost -1 } ] }", .err = error.InvalidLinkCost },
        .{ .source = head ++ "links [ { kind \"jump\" " ++ ends ++ " cost 1001 } ] }", .err = error.InvalidLinkCost },
        .{ .source = head ++ "links [ { kind \"jump\" " ++ ends ++ " snap 0.01 } ] }", .err = error.InvalidLinkSnap },
        .{ .source = head ++ "links [ { kind \"jump\" " ++ ends ++ " snap 6 } ] }", .err = error.InvalidLinkSnap },
        .{ .source = head ++ "links [ { kind \"jump\" " ++ ends ++ " arc -1 } ] }", .err = error.InvalidLinkArc },
        .{ .source = head ++ "links [ { kind \"jump\" " ++ ends ++ " arc 11 } ] }", .err = error.InvalidLinkArc },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?DecodeError, case.err), try refusalOf(case.source));
    }
    for ([_][]const u8{ "jump", "drop", "ladder" }) |kind| {
        var buffer: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}links [ {{ kind \"{s}\" {s} }} ] }}", .{ head, kind, ends });
        try testing.expectEqual(@as(?DecodeError, null), try refusalOf(source));
    }
}

test "a volume whose area is none is refused by value, since text cannot write one" {
    var s: Settings = .{ .agent_radius = 0.3, .agent_height = 1.8, .agent_climb = 0.35, .agent_slope = 0.785398 };
    s.source_buffer[0] = ContentId.fromString("t:level");
    s.source_count = 1;
    s.volume_buffer[0] = .{ .min = .zero, .max = .init(1, 1, 1) };
    s.volume_count = 1;
    try testing.expectError(error.InvalidVolumeArea, s.validate());
}

test "the counts are bounded: 32 volumes, 8 areas, 64 links" {
    const gpa = testing.allocator;
    const head = "foundry:nav_mesh t:n { sources [ t:level ] " ++ agent ++ " ";
    const cases = [_]struct { count: u32, areas: u32, link: bool, err: ?DecodeError }{
        .{ .count = max_volumes, .areas = 1, .link = false, .err = null },
        .{ .count = max_volumes + 1, .areas = 1, .link = false, .err = error.TooManyVolumes },
        .{ .count = max_areas, .areas = max_areas, .link = false, .err = null },
        .{ .count = max_areas + 1, .areas = max_areas + 1, .link = false, .err = error.TooManyAreas },
        .{ .count = max_links, .areas = 0, .link = true, .err = null },
        .{ .count = max_links + 1, .areas = 0, .link = true, .err = error.TooManyLinks },
    };
    for (cases) |case| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try text.appendSlice(gpa, head);
        try text.appendSlice(gpa, if (case.link) "links [ " else "volumes [ ");
        for (0..case.count) |i| {
            if (case.link) {
                try text.print(gpa, "{{ kind \"jump\" {s} }} ", .{ends});
            } else {
                try text.print(gpa, "{{ area t:a{d} {s} }} ", .{ i % case.areas, box });
            }
        }
        try text.appendSlice(gpa, "] }");
        try testing.expectEqual(case.err, try refusalOf(text.items));
    }
}

test "a version 1 record reads under version 2 with no volumes and no links" {
    const gpa = testing.allocator;
    var old: Registry = .init(gpa, .default);
    defer old.deinit(gpa);
    _ = try old.register(gpa, .{ .id = nav_mesh.id, .version = 1, .fields = version_1_fields });
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "old.fdt", "foundry:nav_mesh t:n { sources [ t:level ] " ++ agent ++ " cell_size 0.2 }", .{ .namespace = "t" }, &diags);
    defer doc.deinit(gpa);
    var package = try data.check.Package.init(gpa, "t:old", 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, &old, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &old, &bytes);

    var current: Registry = .init(gpa, .default);
    defer current.deinit(gpa);
    try registerAll(gpa, &current);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    _ = try store.add(gpa, "t:old", bytes.items, &current, &diags);
    const s = try decode(store.lookup(ContentId.fromString("t:n")).?.fields);
    try testing.expectEqual(@as(f32, 0.2), s.cell_size);
    try testing.expectEqual(@as(usize, 0), s.volumes().len);
    try testing.expectEqual(@as(usize, 0), s.links().len);
}

test "a nav_area defaults to 1 and refuses a cost out of bounds" {
    const c = try Compiled.init("foundry:nav_area t:a { }\nfoundry:nav_area t:b { cost 1000 }\n");
    defer c.deinit();
    try testing.expectEqual(@as(f32, 1), (try decodeArea(c.fields(0))).cost);
    try testing.expectEqual(@as(f32, 1000), (try decodeArea(c.fields(1))).cost);
    for ([_][]const u8{ "foundry:nav_area t:a { cost 0.99 }", "foundry:nav_area t:a { cost 1001 }", "foundry:nav_area t:a { cost -1 }" }) |source| {
        const bad = try Compiled.init(source);
        defer bad.deinit();
        try testing.expectError(error.InvalidAreaCost, decodeArea(bad.fields(0)));
    }
}

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

test "a volume's area must be a nav_area where IDs resolve, and a mod may supply it" {
    const recipe = "foundry:nav_mesh t:n { sources [ t:level ] " ++ agent ++ " volumes [ { area t:mud " ++ box ++ " } { area t:ice " ++ box ++ " } { area t:mud " ++ box ++ " } ] }";
    const area_ice = "\nfoundry:nav_area t:ice { cost 7 }";
    {
        // The mod supplies one area the base's recipe names.
        const s = try Stored.init(&.{ recipe ++ "\nfoundry:nav_area t:mud { cost 4 }", area_ice });
        defer s.deinit();
        const value = try decode(s.store.lookup(ContentId.fromString("t:n")).?.fields);
        var costs: [max_areas + 1]f32 = undefined;
        try testing.expectEqual(@as(usize, 3), try resolveAreas(&value, &s.store, &costs));
        try testing.expectEqualSlices(f32, &.{ 1, 4, 7 }, costs[0..3]);
    }
    {
        const s = try Stored.init(&.{recipe ++ "\nfoundry:nav_area t:mud { }"});
        defer s.deinit();
        const value = try decode(s.store.lookup(ContentId.fromString("t:n")).?.fields);
        var costs: [max_areas + 1]f32 = undefined;
        try testing.expectError(error.NotANavArea, resolveAreas(&value, &s.store, &costs));
    }
    {
        const s = try Stored.init(&.{recipe ++ "\nfoundry:texture t:mud { source \"a.png\" }" ++ area_ice});
        defer s.deinit();
        const value = try decode(s.store.lookup(ContentId.fromString("t:n")).?.fields);
        var costs: [max_areas + 1]f32 = undefined;
        try testing.expectError(error.NotANavArea, resolveAreas(&value, &s.store, &costs));
    }
    {
        const s = try Stored.init(&.{recipe ++ "\nfoundry:nav_area t:mud { cost 0.5 }" ++ area_ice});
        defer s.deinit();
        const value = try decode(s.store.lookup(ContentId.fromString("t:n")).?.fields);
        var costs: [max_areas + 1]f32 = undefined;
        try testing.expectError(error.InvalidAreaCost, resolveAreas(&value, &s.store, &costs));
    }
}
