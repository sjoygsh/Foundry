//! `foundry:light` — a light as content, with no position (`docs/design/environment.md` §6.1,
//! ADR-0085).
//!
//! ```fdt
//! foundry:light court:lights.beacon {
//!     kind          "point"
//!     color         { r 1  g 0.72  b 0.4 }
//!     intensity     120          # candela; lux for a directional light
//!     range         9
//!     casts_shadow  true
//!     source_radius 0.05
//! }
//! ```
//!
//! **A mechanism, not content** (I5). The record type is the engine's, registered with the
//! other engine records (`schemas.records`), and a mod overrides a light by its ID (I2, I3).
//! The fields are `render3d.Light`'s except its world matrix, and their meaning is
//! `KHR_lights_punctual`'s with ADR-0056's units, so glTF import copies them field for field.
//!
//! **A record has no position.** It describes a light, not where one is: `foundry:model` v4
//! places lights, and a game submits them where it likes.
//!
//! **The refusals are `render3d.lighting.valid`'s, said again here**, without the world matrix,
//! because a record is untrusted and is refused where it is compiled, by `fpack` and the editor
//! alike, and where it is loaded. `render3d` is above this module and cannot be seen from it;
//! `engine/tests/model_content.zig` sees both and fails if they disagree on a light.
//!
//! **Every name here is on authors' disks** (CLAUDE.md §7).

const std = @import("std");
const core = @import("core");
const data = @import("data");

const Fields = data.fpk.Fields;
const FieldType = data.FieldType;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

pub const name = "foundry:light";

pub const Kind = enum { directional, point, spot };

const color_type: FieldType = .{ .nested = &.{
    .{ .name = "r", .type = .f32 },
    .{ .name = "g", .type = .f32 },
    .{ .name = "b", .type = .f32 },
} };

/// Version 1. The defaults are `render3d.Light`'s and glTF's: unbounded, a quarter-π outer cone,
/// no shadow, a point emitter.
pub const schema: Schema = .{
    .id = SchemaId.fromStringUnchecked(name),
    .version = 1,
    .fields = &.{
        .{ .name = "kind", .type = .string },
        .{ .name = "color", .type = color_type },
        .{ .name = "intensity", .type = .f32 },
        .{ .name = "range", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
        .{ .name = "inner_cone", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
        .{ .name = "outer_cone", .type = .f32, .presence = .{ .default = .{ .float = std.math.pi / 4.0 } } },
        .{ .name = "casts_shadow", .type = .bool, .presence = .{ .default = .{ .bool = false } } },
        .{ .name = "source_radius", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    },
};

/// A decoded record: `render3d.Light` without its world matrix.
pub const Light = struct {
    kind: Kind,
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32,
    range: f32 = 0,
    inner_cone: f32 = 0,
    outer_cone: f32 = std.math.pi / 4.0,
    casts_shadow: bool = false,
    source_radius: f32 = 0,

    /// `render3d.lighting.valid`'s rules, but for the world matrix it does not have.
    pub fn validate(self: Light) Refusal!void {
        for (self.color) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidColor;
        if (!std.math.isFinite(self.intensity) or self.intensity < 0) return error.InvalidIntensity;
        if (!std.math.isFinite(self.range) or self.range < 0) return error.InvalidRange;
        if (!std.math.isFinite(self.inner_cone) or !std.math.isFinite(self.outer_cone) or
            self.inner_cone < 0 or self.inner_cone >= self.outer_cone or self.outer_cone > std.math.pi / 2.0)
            return error.InvalidCone;
        if (!std.math.isFinite(self.source_radius) or self.source_radius < 0) return error.InvalidSourceRadius;
        if (self.kind == .directional) {
            if (self.source_radius > std.math.pi / 8.0) return error.InvalidSourceRadius;
        } else if (self.range != 0 and self.source_radius >= self.range) return error.InvalidSourceRadius;
    }
};

pub const Refusal = error{
    InvalidColor,
    InvalidIntensity,
    InvalidRange,
    InvalidCone,
    InvalidSourceRadius,
};

pub const DecodeError = Refusal || error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    UnknownKind,
};

/// A phrase naming the field, for a diagnostic or a log line: "light '<id>' <...>".
pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.Unreadable => "cannot be read against its schema",
        error.UnknownKind => "has a kind that is not directional, point or spot",
        error.InvalidColor => "has a colour component that is not between 0 and 1",
        error.InvalidIntensity => "has an intensity that is negative or not finite",
        error.InvalidRange => "has a range that is negative or not finite",
        error.InvalidCone => "has cones that are not 0 <= inner_cone < outer_cone <= pi/2",
        error.InvalidSourceRadius => "has a source_radius that is negative, not finite, above pi/8 for a directional light, or not inside its range",
    };
}

/// Reads and validates a record laid out against this schema.
pub fn decode(fields: Fields) DecodeError!Light {
    const kind_text = try stringOf(fields, "kind") orelse return error.Unreadable;
    var out: Light = .{
        .kind = std.meta.stringToEnum(Kind, kind_text) orelse return error.UnknownKind,
        .intensity = try floatOf(fields, "intensity") orelse return error.Unreadable,
    };
    const color = try nestedOf(fields, "color") orelse return error.Unreadable;
    out.color = .{
        try floatOf(color, "r") orelse return error.Unreadable,
        try floatOf(color, "g") orelse return error.Unreadable,
        try floatOf(color, "b") orelse return error.Unreadable,
    };
    if (try floatOf(fields, "range")) |v| out.range = v;
    if (try floatOf(fields, "inner_cone")) |v| out.inner_cone = v;
    if (try floatOf(fields, "outer_cone")) |v| out.outer_cone = v;
    if (try boolOf(fields, "casts_shadow")) |v| out.casts_shadow = v;
    if (try floatOf(fields, "source_radius")) |v| out.source_radius = v;
    try out.validate();
    return out;
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

fn boolOf(fields: Fields, field: []const u8) DecodeError!?bool {
    const i = indexOf(fields, field) orelse return null;
    return fields.boolAt(i) catch return error.Unreadable;
}

fn stringOf(fields: Fields, field: []const u8) DecodeError!?[]const u8 {
    const i = indexOf(fields, field) orelse return null;
    return fields.stringAt(i) catch return error.Unreadable;
}

fn nestedOf(fields: Fields, field: []const u8) DecodeError!?Fields {
    const i = indexOf(fields, field) orelse return null;
    return fields.nestedAt(i) catch return error.Unreadable;
}

const testing = std.testing;
const Registry = data.Registry;

fn decodeText(source: []const u8) !DecodeError!Light {
    const gpa = testing.allocator;
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    _ = try registry.register(gpa, schema);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "lights.fdt", source, .{ .namespace = "t" }, &diags);
    defer doc.deinit(gpa);
    var package = try data.check.Package.init(gpa, "t:content", 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, &registry, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &registry, &bytes);
    var reader = try data.fpk.Reader.open(gpa, bytes.items, .default);
    defer reader.deinit();
    const view = reader.record(0).?;
    return decode(reader.fieldsOf(view, reader.schemaFor(view.schema_id).?.*));
}

test "the design's example decodes to the values it says" {
    const light = try (try decodeText(
        \\foundry:light t:beacon {
        \\    kind "spot"  color { r 1  g 0.72  b 0.4 }  intensity 120  range 9
        \\    inner_cone 0.2  outer_cone 0.6  casts_shadow true  source_radius 0.05
        \\}
    ));
    try testing.expectEqual(Light{
        .kind = .spot,
        .color = .{ 1, 0.72, 0.4 },
        .intensity = 120,
        .range = 9,
        .inner_cone = 0.2,
        .outer_cone = 0.6,
        .casts_shadow = true,
        .source_radius = 0.05,
    }, light);
}

test "a record naming only kind, colour and intensity takes render3d.Light's defaults" {
    const light = try (try decodeText("foundry:light t:sun { kind \"directional\" color { r 1 g 1 b 1 } intensity 100000 }"));
    try testing.expectEqual(Light{ .kind = .directional, .intensity = 100000 }, light);
}

test "every refusal names its field" {
    const cases = [_]struct { text: []const u8, err: DecodeError }{
        .{ .text = "kind \"area\" color { r 1 g 1 b 1 } intensity 1", .err = error.UnknownKind },
        .{ .text = "kind \"point\" color { r 1.5 g 1 b 1 } intensity 1", .err = error.InvalidColor },
        .{ .text = "kind \"point\" color { r 1 g -0.1 b 1 } intensity 1", .err = error.InvalidColor },
        .{ .text = "kind \"point\" color { r 1 g 1 b 1 } intensity -1", .err = error.InvalidIntensity },
        .{ .text = "kind \"point\" color { r 1 g 1 b 1 } intensity 1 range -2", .err = error.InvalidRange },
        .{ .text = "kind \"spot\" color { r 1 g 1 b 1 } intensity 1 outer_cone 1.6", .err = error.InvalidCone },
        .{ .text = "kind \"spot\" color { r 1 g 1 b 1 } intensity 1 inner_cone 0.5 outer_cone 0.5", .err = error.InvalidCone },
        .{ .text = "kind \"spot\" color { r 1 g 1 b 1 } intensity 1 inner_cone -0.1", .err = error.InvalidCone },
        .{ .text = "kind \"point\" color { r 1 g 1 b 1 } intensity 1 source_radius -1", .err = error.InvalidSourceRadius },
        .{ .text = "kind \"point\" color { r 1 g 1 b 1 } intensity 1 range 2 source_radius 2", .err = error.InvalidSourceRadius },
        .{ .text = "kind \"directional\" color { r 1 g 1 b 1 } intensity 1 source_radius 0.5", .err = error.InvalidSourceRadius },
    };
    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "foundry:light t:bad {{ {s} }}", .{case.text});
        try testing.expectError(case.err, try decodeText(source));
        try testing.expect(describe(case.err).len != 0);
    }
}

test "an unbounded light's source radius is not limited by its range" {
    _ = try (try decodeText("foundry:light t:bulb { kind \"point\" color { r 1 g 1 b 1 } intensity 10 source_radius 3 }"));
}
