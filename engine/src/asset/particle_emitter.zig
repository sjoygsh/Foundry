//! `foundry:particle_emitter` — what a particle effect spawns and how it looks, as content
//! (`docs/design/particles.md` §4, ADR-0064).
//!
//! ```fdt
//! foundry:particle_emitter sandbox3d:effects.torch_flame {
//!     material        sandbox3d:materials.flame      # a foundry:material
//!     capacity        256
//!     rate            90
//!     bursts          [ { time 0  count 12 } ]
//!     lifetime        { min 0.5  max 0.8 }
//!     shape           { kind "cone"  radius 0.05  angle 0.3 }
//!     speed           { min 0.4  max 0.7 }
//!     acceleration    { x 0  y 1.2  z 0 }
//!     size_over_life  [ { t 0  value 0.6 } { t 1  value 0.2 } ]
//!     color_over_life [ { t 0  color { r 1 g 0.7 b 0.3 a 0 } } { t 1  color { r 0.6 g 0.1 b 0 a 0 } } ]
//!     additive        1
//!     sheet           { columns 4  rows 4  frames 16 }
//! }
//! ```
//!
//! **A mechanism, not content** (I5). The record type is the engine's, registered through the
//! call a mod's `@schema` uses (I6); a game ships its emitters in its own package, and any later
//! package may override one whole.
//!
//! **It lives here, not beside the simulation**, for `asset.ui_theme`'s reason: `fpack` checks
//! a record with no renderer linked, and `particles` at L1 holds no schema. This module decodes
//! a record into `ParticleEmitter`, a value of its own, and `render3d` converts that into
//! `particles.Emitter` field for field. Neither module names the other's types (ADR-0064).
//!
//! **The refusals are `particles.Emitter.validate`'s, said again here**, because a record is
//! untrusted and is refused where it is compiled, by `fpack` and the editor alike, and again
//! where it is loaded. The two rule sets cannot see each other; `engine/tests/particle_emitter.zig`
//! stands above both and fails if they disagree on a limit, a default or a refusal.
//!
//! **Every name here is on authors' disks** (CLAUDE.md §7). Adding a field later is additive;
//! renaming one is a break.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Field = data.Field;
const FieldType = data.FieldType;
const Fields = data.fpk.Fields;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

pub const name = "foundry:particle_emitter";

// The simulation's limits (`particles.emitter`), restated; the integration test holds them equal.
pub const max_capacity: u32 = 16_384;
pub const max_curve_keys: usize = 8;
pub const max_bursts: usize = 8;
pub const max_sheet_side: u32 = 64;
pub const max_sheet_frames: u32 = 4096;
pub const max_rate: f32 = 100_000;
pub const max_seconds: f32 = 3600;
pub const min_duration: f32 = 0.001;
pub const max_distance: f32 = 10_000;
pub const max_speed: f32 = 10_000;
pub const max_acceleration: f32 = 10_000;
pub const max_drag: f32 = 1000;
pub const max_angle: f32 = 10_000;
pub const max_spin: f32 = 1000;
pub const max_factor: f32 = 10_000;
pub const max_stretch: f32 = 1000;
pub const max_fps: f32 = 1000;

const range_type: FieldType = .{ .nested = &.{
    .{ .name = "min", .type = .f32 },
    .{ .name = "max", .type = .f32 },
} };
const vector_type: FieldType = .{ .nested = &.{
    .{ .name = "x", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "y", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "z", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
} };
const color_type: FieldType = .{ .nested = &.{
    .{ .name = "r", .type = .f32 },
    .{ .name = "g", .type = .f32 },
    .{ .name = "b", .type = .f32 },
    .{ .name = "a", .type = .f32 },
} };
const burst_type: FieldType = .{ .nested = &.{
    .{ .name = "time", .type = .f32 },
    .{ .name = "count", .type = .u32 },
} };
const key_type: FieldType = .{ .nested = &.{
    .{ .name = "t", .type = .f32 },
    .{ .name = "value", .type = .f32 },
} };
const color_key_type: FieldType = .{ .nested = &.{
    .{ .name = "t", .type = .f32 },
    .{ .name = "color", .type = color_type },
} };
const shape_type: FieldType = .{ .nested = &.{
    .{ .name = "kind", .type = .string, .presence = .{ .default = .{ .string = "point" } } },
    .{ .name = "radius", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "angle", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "extent", .type = vector_type, .presence = .optional },
    .{ .name = "surface", .type = .bool, .presence = .{ .default = .{ .bool = false } } },
} };
const sheet_type: FieldType = .{ .nested = &.{
    .{ .name = "columns", .type = .u32, .presence = .{ .default = .{ .int = 1 } } },
    .{ .name = "rows", .type = .u32, .presence = .{ .default = .{ .int = 1 } } },
    .{ .name = "frames", .type = .u32, .presence = .{ .default = .{ .int = 1 } } },
    .{ .name = "fps", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
} };

/// Version 1. An absent nested field takes `ParticleEmitter`'s default, which is the
/// simulation's.
pub const particle_emitter: Schema = .{
    .id = SchemaId.fromStringUnchecked(name),
    .version = 1,
    .fields = &.{
        .{ .name = "material", .type = .id },
        .{ .name = "capacity", .type = .u32, .presence = .{ .default = .{ .int = 64 } } },
        .{ .name = "rate", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
        .{ .name = "bursts", .type = .{ .list = &burst_type }, .presence = .optional },
        .{ .name = "duration", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "loop", .type = .bool, .presence = .{ .default = .{ .bool = true } } },
        .{ .name = "lifetime", .type = range_type, .presence = .optional },
        .{ .name = "shape", .type = shape_type, .presence = .optional },
        .{ .name = "speed", .type = range_type, .presence = .optional },
        .{ .name = "acceleration", .type = vector_type, .presence = .optional },
        .{ .name = "drag", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
        .{ .name = "size", .type = range_type, .presence = .optional },
        .{ .name = "size_over_life", .type = .{ .list = &key_type }, .presence = .optional },
        .{ .name = "rotation", .type = range_type, .presence = .optional },
        .{ .name = "spin", .type = range_type, .presence = .optional },
        .{ .name = "color_over_life", .type = .{ .list = &color_key_type }, .presence = .optional },
        .{ .name = "additive", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
        .{ .name = "facing", .type = .string, .presence = .{ .default = .{ .string = "camera" } } },
        .{ .name = "stretch", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
        .{ .name = "space", .type = .string, .presence = .{ .default = .{ .string = "world" } } },
        .{ .name = "sheet", .type = sheet_type, .presence = .optional },
        .{ .name = "seed", .type = .u64, .presence = .{ .default = .{ .int = 0 } } },
    },
};

pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(gpa, particle_emitter);
}

pub const Range = struct { min: f32, max: f32 };
pub const Burst = struct { time: f32, count: u32 };
pub const Key = struct { t: f32, value: f32 };
pub const ColorKey = struct { t: f32, color: [4]f32 };
pub const ShapeKind = enum { point, sphere, box, cone };
pub const Facing = enum { camera, velocity, up };
pub const Space = enum { world, local };

pub const Shape = struct {
    kind: ShapeKind = .point,
    radius: f32 = 0,
    angle: f32 = 0,
    extent: [3]f32 = .{ 0, 0, 0 },
    surface: bool = false,
};

pub const Sheet = struct {
    columns: u32 = 1,
    rows: u32 = 1,
    frames: u32 = 1,
    fps: f32 = 0,
};

/// A decoded record. Fixed arrays rather than slices, so a value owns everything it says and
/// can be copied, kept and compared with no allocator.
pub const ParticleEmitter = struct {
    material: ContentId,
    capacity: u32 = 64,
    rate: f32 = 0,
    burst_buffer: [max_bursts]Burst = undefined,
    burst_count: u8 = 0,
    duration: f32 = 1,
    loop: bool = true,
    lifetime: Range = .{ .min = 1, .max = 1 },
    shape: Shape = .{},
    speed: Range = .{ .min = 1, .max = 1 },
    acceleration: [3]f32 = .{ 0, 0, 0 },
    drag: f32 = 0,
    size: Range = .{ .min = 0.1, .max = 0.1 },
    size_key_buffer: [max_curve_keys]Key = undefined,
    size_key_count: u8 = 0,
    rotation: Range = .{ .min = 0, .max = 0 },
    spin: Range = .{ .min = 0, .max = 0 },
    color_key_buffer: [max_curve_keys]ColorKey = undefined,
    color_key_count: u8 = 0,
    additive: f32 = 0,
    facing: Facing = .camera,
    stretch: f32 = 0,
    space: Space = .world,
    sheet: Sheet = .{},
    seed: u64 = 0,

    pub fn bursts(self: *const ParticleEmitter) []const Burst {
        return self.burst_buffer[0..self.burst_count];
    }

    pub fn sizeOverLife(self: *const ParticleEmitter) []const Key {
        return self.size_key_buffer[0..self.size_key_count];
    }

    pub fn colorOverLife(self: *const ParticleEmitter) []const ColorKey {
        return self.color_key_buffer[0..self.color_key_count];
    }

    /// `particles.Emitter.validate`'s rules, in its order.
    pub fn validate(self: *const ParticleEmitter) Refusal!void {
        if (self.capacity == 0 or self.capacity > max_capacity) return error.InvalidCapacity;
        if (!within(self.rate, 0, max_rate)) return error.InvalidRate;
        if (!within(self.duration, min_duration, max_seconds)) return error.InvalidDuration;
        for (self.bursts()) |burst| {
            if (!within(burst.time, 0, max_seconds) or burst.time >= self.duration) return error.InvalidBurst;
            if (burst.count == 0 or burst.count > max_capacity) return error.InvalidBurst;
        }
        if (!range(self.lifetime, 0, max_seconds) or self.lifetime.min == 0) return error.InvalidLifetime;
        const shape = self.shape;
        if (!within(shape.radius, 0, max_distance) or !within(shape.angle, 0, std.math.pi)) return error.InvalidShape;
        for (shape.extent) |e| if (!within(e, 0, max_distance)) return error.InvalidShape;
        if (!range(self.speed, 0, max_speed)) return error.InvalidSpeed;
        for (self.acceleration) |a| if (!within(a, -max_acceleration, max_acceleration)) return error.InvalidAcceleration;
        if (!within(self.drag, 0, max_drag)) return error.InvalidDrag;
        if (!range(self.size, 0, max_distance)) return error.InvalidSize;
        try validateKeys(Key, self.sizeOverLife());
        for (self.sizeOverLife()) |key| if (!within(key.value, 0, max_factor)) return error.InvalidCurve;
        if (!range(self.rotation, -max_angle, max_angle)) return error.InvalidRotation;
        if (!range(self.spin, -max_spin, max_spin)) return error.InvalidSpin;
        try validateKeys(ColorKey, self.colorOverLife());
        for (self.colorOverLife()) |key| {
            for (key.color[0..3]) |c| if (!within(c, 0, max_factor)) return error.InvalidColor;
            if (!within(key.color[3], 0, 1)) return error.InvalidColor;
        }
        if (!within(self.additive, 0, 1)) return error.InvalidAdditive;
        if (!within(self.stretch, 0, max_stretch)) return error.InvalidStretch;
        const sheet = self.sheet;
        if (sheet.columns == 0 or sheet.columns > max_sheet_side or sheet.rows == 0 or sheet.rows > max_sheet_side) return error.InvalidSheet;
        if (sheet.frames == 0 or sheet.frames > sheet.columns * sheet.rows or sheet.frames > max_sheet_frames) return error.InvalidSheet;
        if (!within(sheet.fps, 0, max_fps)) return error.InvalidSheet;
    }
};

/// The simulation's refusals, by the same names (`particles.Error`).
pub const Refusal = error{
    InvalidCapacity,
    InvalidRate,
    InvalidBurst,
    TooManyBursts,
    InvalidDuration,
    InvalidLifetime,
    InvalidShape,
    InvalidSpeed,
    InvalidAcceleration,
    InvalidDrag,
    InvalidSize,
    InvalidRotation,
    InvalidSpin,
    InvalidCurve,
    TooManyKeys,
    InvalidColor,
    InvalidAdditive,
    InvalidStretch,
    InvalidSheet,
};

/// What only a record can get wrong, besides the simulation's refusals.
pub const DecodeError = Refusal || error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    UnknownShape,
    UnknownFacing,
    UnknownSpace,
};

/// A sentence naming the field, for a diagnostic or a log line: "its <...>".
pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.Unreadable => "cannot be read against its schema",
        error.UnknownShape => "has a shape kind that is not point, sphere, box or cone",
        error.UnknownFacing => "has a facing that is not camera, velocity or up",
        error.UnknownSpace => "has a space that is not world or local",
        error.InvalidCapacity => "has a capacity that is not between 1 and 16384",
        error.InvalidRate => "has a rate that is negative, not finite or above 100000",
        error.InvalidBurst => "has a burst whose time is outside its loop or whose count is not between 1 and 16384",
        error.TooManyBursts => "has more than 8 bursts",
        error.InvalidDuration => "has a duration that is not between 0.001 and 3600 seconds",
        error.InvalidLifetime => "has a lifetime that is not positive, not finite or whose min is above its max",
        error.InvalidShape => "has a shape whose radius, angle or extent is negative, not finite or out of range",
        error.InvalidSpeed => "has a speed that is negative, not finite or whose min is above its max",
        error.InvalidAcceleration => "has an acceleration that is not finite or out of range",
        error.InvalidDrag => "has a drag that is negative, not finite or above 1000",
        error.InvalidSize => "has a size that is negative, not finite or whose min is above its max",
        error.InvalidRotation => "has a rotation that is not finite or whose min is above its max",
        error.InvalidSpin => "has a spin that is not finite or whose min is above its max",
        error.InvalidCurve => "has a curve whose keys do not run from t 0 to t 1 in increasing order, or whose value is out of range",
        error.TooManyKeys => "has a curve with more than 8 keys",
        error.InvalidColor => "has a colour that is negative or not finite, or whose a is outside 0 to 1",
        error.InvalidAdditive => "has an additive weight outside 0 to 1",
        error.InvalidStretch => "has a stretch that is negative, not finite or above 1000",
        error.InvalidSheet => "has a sheet whose columns or rows are not between 1 and 64, whose frames exceed them, or whose fps is out of range",
    };
}

/// Reads and validates a record laid out against this schema (any version of it this build
/// knows; there is one).
pub fn decode(fields: Fields) DecodeError!ParticleEmitter {
    var out: ParticleEmitter = .{ .material = try idOf(fields, "material") orelse return error.Unreadable };
    if (try uintOf(fields, "capacity")) |v| out.capacity = v;
    if (try floatOf(fields, "rate")) |v| out.rate = v;
    if (try listOf(fields, "bursts")) |list| {
        if (list.len > max_bursts) return error.TooManyBursts;
        for (0..list.len) |i| {
            const b = (list.nestedAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
            out.burst_buffer[i] = .{ .time = try floatOf(b, "time") orelse return error.Unreadable, .count = try uintOf(b, "count") orelse return error.Unreadable };
        }
        out.burst_count = @intCast(list.len);
    }
    if (try floatOf(fields, "duration")) |v| out.duration = v;
    if (try boolOf(fields, "loop")) |v| out.loop = v;
    if (try rangeOf(fields, "lifetime")) |v| out.lifetime = v;
    if (try nestedOf(fields, "shape")) |s| {
        if (try stringOf(s, "kind")) |text| out.shape.kind = std.meta.stringToEnum(ShapeKind, text) orelse return error.UnknownShape;
        if (try floatOf(s, "radius")) |v| out.shape.radius = v;
        if (try floatOf(s, "angle")) |v| out.shape.angle = v;
        if (try vectorOf(s, "extent")) |v| out.shape.extent = v;
        if (try boolOf(s, "surface")) |v| out.shape.surface = v;
    }
    if (try rangeOf(fields, "speed")) |v| out.speed = v;
    if (try vectorOf(fields, "acceleration")) |v| out.acceleration = v;
    if (try floatOf(fields, "drag")) |v| out.drag = v;
    if (try rangeOf(fields, "size")) |v| out.size = v;
    if (try listOf(fields, "size_over_life")) |list| {
        if (list.len > max_curve_keys) return error.TooManyKeys;
        for (0..list.len) |i| {
            const k = (list.nestedAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
            out.size_key_buffer[i] = .{ .t = try floatOf(k, "t") orelse return error.Unreadable, .value = try floatOf(k, "value") orelse return error.Unreadable };
        }
        out.size_key_count = @intCast(list.len);
    }
    if (try rangeOf(fields, "rotation")) |v| out.rotation = v;
    if (try rangeOf(fields, "spin")) |v| out.spin = v;
    if (try listOf(fields, "color_over_life")) |list| {
        if (list.len > max_curve_keys) return error.TooManyKeys;
        for (0..list.len) |i| {
            const k = (list.nestedAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
            const c = try nestedOf(k, "color") orelse return error.Unreadable;
            out.color_key_buffer[i] = .{ .t = try floatOf(k, "t") orelse return error.Unreadable, .color = .{
                try floatOf(c, "r") orelse return error.Unreadable,
                try floatOf(c, "g") orelse return error.Unreadable,
                try floatOf(c, "b") orelse return error.Unreadable,
                try floatOf(c, "a") orelse return error.Unreadable,
            } };
        }
        out.color_key_count = @intCast(list.len);
    }
    if (try floatOf(fields, "additive")) |v| out.additive = v;
    if (try stringOf(fields, "facing")) |text| out.facing = std.meta.stringToEnum(Facing, text) orelse return error.UnknownFacing;
    if (try floatOf(fields, "stretch")) |v| out.stretch = v;
    if (try stringOf(fields, "space")) |text| out.space = std.meta.stringToEnum(Space, text) orelse return error.UnknownSpace;
    if (try nestedOf(fields, "sheet")) |s| {
        if (try uintOf(s, "columns")) |v| out.sheet.columns = v;
        if (try uintOf(s, "rows")) |v| out.sheet.rows = v;
        if (try uintOf(s, "frames")) |v| out.sheet.frames = v;
        if (try floatOf(s, "fps")) |v| out.sheet.fps = v;
    }
    if (try intOf(fields, "seed")) |v| out.seed = std.math.cast(u64, v) orelse return error.Unreadable;
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

fn intOf(fields: Fields, field: []const u8) DecodeError!?i128 {
    const i = indexOf(fields, field) orelse return null;
    return fields.intAt(i) catch return error.Unreadable;
}

fn uintOf(fields: Fields, field: []const u8) DecodeError!?u32 {
    const value = try intOf(fields, field) orelse return null;
    return std.math.cast(u32, value) orelse error.Unreadable;
}

fn boolOf(fields: Fields, field: []const u8) DecodeError!?bool {
    const i = indexOf(fields, field) orelse return null;
    return fields.boolAt(i) catch return error.Unreadable;
}

fn stringOf(fields: Fields, field: []const u8) DecodeError!?[]const u8 {
    const i = indexOf(fields, field) orelse return null;
    return fields.stringAt(i) catch return error.Unreadable;
}

fn idOf(fields: Fields, field: []const u8) DecodeError!?ContentId {
    const i = indexOf(fields, field) orelse return null;
    return fields.idAt(i) catch return error.Unreadable;
}

fn nestedOf(fields: Fields, field: []const u8) DecodeError!?Fields {
    const i = indexOf(fields, field) orelse return null;
    return fields.nestedAt(i) catch return error.Unreadable;
}

fn listOf(fields: Fields, field: []const u8) DecodeError!?data.fpk.List {
    const i = indexOf(fields, field) orelse return null;
    return fields.listAt(i) catch return error.Unreadable;
}

fn rangeOf(fields: Fields, field: []const u8) DecodeError!?Range {
    const r = try nestedOf(fields, field) orelse return null;
    return .{ .min = try floatOf(r, "min") orelse return error.Unreadable, .max = try floatOf(r, "max") orelse return error.Unreadable };
}

fn vectorOf(fields: Fields, field: []const u8) DecodeError!?[3]f32 {
    const v = try nestedOf(fields, field) orelse return null;
    return .{ try floatOf(v, "x") orelse 0, try floatOf(v, "y") orelse 0, try floatOf(v, "z") orelse 0 };
}

fn validateKeys(comptime K: type, keys: []const K) Refusal!void {
    if (keys.len == 0) return;
    if (keys.len > max_curve_keys) return error.TooManyKeys;
    if (keys.len < 2 or keys[0].t != 0 or keys[keys.len - 1].t != 1) return error.InvalidCurve;
    for (keys[1..], keys[0 .. keys.len - 1]) |key, previous| {
        if (!std.math.isFinite(key.t) or key.t <= previous.t) return error.InvalidCurve;
    }
}

fn within(value: f32, lo: f32, hi: f32) bool {
    return std.math.isFinite(value) and value >= lo and value <= hi;
}

fn range(r: Range, lo: f32, hi: f32) bool {
    return within(r.min, lo, hi) and within(r.max, lo, hi) and r.min <= r.max;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// Compiles `source` as package `t:content` and decodes its one emitter.
fn decodeText(source: []const u8) !DecodeError!ParticleEmitter {
    const gpa = testing.allocator;
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    try registerAll(gpa, &registry);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "fx.fdt", source, .{ .namespace = "t" }, &diags);
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
    const emitter = try (try decodeText(
        \\foundry:particle_emitter t:flame {
        \\    material t:materials.flame
        \\    capacity 256
        \\    rate 90
        \\    bursts [ { time 0  count 12 } ]
        \\    duration 1.0
        \\    loop true
        \\    lifetime { min 0.5  max 0.8 }
        \\    shape { kind "cone"  radius 0.05  angle 0.3 }
        \\    speed { min 0.4  max 0.7 }
        \\    acceleration { x 0  y 1.2  z 0 }
        \\    drag 1.5
        \\    size { min 0.16  max 0.24 }
        \\    size_over_life [ { t 0  value 0.6 } { t 0.3  value 1 } { t 1  value 0.2 } ]
        \\    rotation { min 0  max 6.2832 }
        \\    spin { min -1  max 1 }
        \\    color_over_life [ { t 0  color { r 1  g 0.7  b 0.3  a 0 } } { t 0.15  color { r 1  g 0.6  b 0.2  a 1 } } { t 1  color { r 0.6  g 0.1  b 0.0  a 0 } } ]
        \\    additive 1
        \\    facing "camera"
        \\    stretch 0
        \\    space "world"
        \\    sheet { columns 4  rows 4  frames 16  fps 0 }
        \\    seed 7
        \\}
    ));
    try testing.expect(emitter.material.eql(ContentId.fromString("t:materials.flame")));
    try testing.expectEqual(@as(u32, 256), emitter.capacity);
    try testing.expectEqual(@as(f32, 90), emitter.rate);
    try testing.expectEqualSlices(Burst, &.{.{ .time = 0, .count = 12 }}, emitter.bursts());
    try testing.expectEqual(Range{ .min = 0.5, .max = 0.8 }, emitter.lifetime);
    try testing.expectEqual(Shape{ .kind = .cone, .radius = 0.05, .angle = 0.3 }, emitter.shape);
    try testing.expectEqual([3]f32{ 0, 1.2, 0 }, emitter.acceleration);
    try testing.expectEqual(@as(usize, 3), emitter.sizeOverLife().len);
    try testing.expectEqual(ColorKey{ .t = 0.15, .color = .{ 1, 0.6, 0.2, 1 } }, emitter.colorOverLife()[1]);
    try testing.expectEqual(@as(f32, 1), emitter.additive);
    try testing.expectEqual(Sheet{ .columns = 4, .rows = 4, .frames = 16 }, emitter.sheet);
    try testing.expectEqual(@as(u64, 7), emitter.seed);
}

test "a record naming only its material takes every default" {
    const emitter = try (try decodeText("foundry:particle_emitter t:plain { material t:m }"));
    const expected: ParticleEmitter = .{ .material = ContentId.fromString("t:m") };
    inline for (.{ "capacity", "rate", "duration", "loop", "lifetime", "shape", "speed", "acceleration", "drag", "size", "rotation", "spin", "additive", "facing", "stretch", "space", "sheet", "seed" }) |field| {
        try testing.expectEqual(@field(expected, field), @field(emitter, field));
    }
    try testing.expectEqual(@as(usize, 0), emitter.bursts().len + emitter.sizeOverLife().len + emitter.colorOverLife().len);
    // A shape with only a kind keeps the rest of its defaults.
    const cone = try (try decodeText("foundry:particle_emitter t:c { material t:m  shape { kind \"sphere\" } }"));
    try testing.expectEqual(Shape{ .kind = .sphere }, cone.shape);
}

test "a record without a material does not compile" {
    const gpa = testing.allocator;
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    try registerAll(gpa, &registry);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "fx.fdt", "foundry:particle_emitter t:x { rate 4 }", .{ .namespace = "t" }, &diags);
    defer doc.deinit(gpa);
    var package = try data.check.Package.init(gpa, "t:content", 1, .default);
    defer package.deinit(gpa);
    try testing.expectError(error.ContentInvalid, package.addDocument(gpa, &doc, &registry, &diags));
}

test "every refusal names its field" {
    const cases = [_]struct { body: []const u8, err: DecodeError }{
        .{ .body = "capacity 0", .err = error.InvalidCapacity },
        .{ .body = "capacity 16385", .err = error.InvalidCapacity },
        .{ .body = "rate -1", .err = error.InvalidRate },
        .{ .body = "rate 200000", .err = error.InvalidRate },
        .{ .body = "duration 0", .err = error.InvalidDuration },
        .{ .body = "duration 0.0005", .err = error.InvalidDuration },
        .{ .body = "bursts [ { time 1 count 1 } ]", .err = error.InvalidBurst },
        .{ .body = "bursts [ { time 0 count 0 } ]", .err = error.InvalidBurst },
        .{ .body = "bursts [ { time 0 count 1 } { time 0 count 1 } { time 0 count 1 } { time 0 count 1 } { time 0 count 1 } { time 0 count 1 } { time 0 count 1 } { time 0 count 1 } { time 0 count 1 } ]", .err = error.TooManyBursts },
        .{ .body = "lifetime { min 0 max 1 }", .err = error.InvalidLifetime },
        .{ .body = "lifetime { min 2 max 1 }", .err = error.InvalidLifetime },
        .{ .body = "shape { kind \"torus\" }", .err = error.UnknownShape },
        .{ .body = "shape { kind \"cone\" angle 4 }", .err = error.InvalidShape },
        .{ .body = "shape { kind \"box\" extent { x -1 } }", .err = error.InvalidShape },
        .{ .body = "speed { min -1 max 1 }", .err = error.InvalidSpeed },
        .{ .body = "acceleration { y -20000 }", .err = error.InvalidAcceleration },
        .{ .body = "drag -1", .err = error.InvalidDrag },
        .{ .body = "size { min 0.2 max 0.1 }", .err = error.InvalidSize },
        .{ .body = "size_over_life [ { t 0 value 1 } ]", .err = error.InvalidCurve },
        .{ .body = "size_over_life [ { t 0 value 1 } { t 0.5 value 1 } ]", .err = error.InvalidCurve },
        .{ .body = "size_over_life [ { t 0 value -1 } { t 1 value 1 } ]", .err = error.InvalidCurve },
        .{ .body = "size_over_life [ { t 0 value 1 } { t 0.1 value 1 } { t 0.2 value 1 } { t 0.3 value 1 } { t 0.4 value 1 } { t 0.5 value 1 } { t 0.6 value 1 } { t 0.7 value 1 } { t 1 value 1 } ]", .err = error.TooManyKeys },
        .{ .body = "rotation { min 1 max 0 }", .err = error.InvalidRotation },
        .{ .body = "spin { min -2000 max 0 }", .err = error.InvalidSpin },
        .{ .body = "color_over_life [ { t 0 color { r 1 g 1 b 1 a 2 } } { t 1 color { r 1 g 1 b 1 a 1 } } ]", .err = error.InvalidColor },
        .{ .body = "color_over_life [ { t 1 color { r 1 g 1 b 1 a 1 } } { t 0 color { r 1 g 1 b 1 a 1 } } ]", .err = error.InvalidCurve },
        .{ .body = "additive 2", .err = error.InvalidAdditive },
        .{ .body = "facing \"sideways\"", .err = error.UnknownFacing },
        .{ .body = "stretch -1", .err = error.InvalidStretch },
        .{ .body = "space \"screen\"", .err = error.UnknownSpace },
        .{ .body = "sheet { columns 0 }", .err = error.InvalidSheet },
        .{ .body = "sheet { columns 2 rows 2 frames 5 }", .err = error.InvalidSheet },
        .{ .body = "sheet { columns 65 }", .err = error.InvalidSheet },
        .{ .body = "sheet { fps -1 }", .err = error.InvalidSheet },
    };
    var buffer: [1024]u8 = undefined;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&buffer, "foundry:particle_emitter t:bad {{ material t:m  {s} }}", .{case.body});
        try testing.expectError(case.err, try decodeText(source));
        try testing.expect(describe(case.err).len > 0);
    }
}

test "the schema registers, twice without complaint" {
    var registry: Registry = .init(testing.allocator, .default);
    defer registry.deinit(testing.allocator);
    try registerAll(testing.allocator, &registry);
    try registerAll(testing.allocator, &registry);
    try testing.expect(registry.lookup(particle_emitter.id) != null);
}
