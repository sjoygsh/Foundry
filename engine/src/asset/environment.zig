//! `foundry:environment` — the light surrounding a scene, and its prefilter (`docs/design/
//! environment.md` §7, ADR-0083).
//!
//! ```fdt
//! foundry:environment sandbox3d:environments.day {
//!     kind      "gradient"
//!     zenith    { r 0.25  g 0.45  b 1     l 6000 }
//!     horizon   { r 0.85  g 0.9   b 1     l 8000 }
//!     ground    { r 0.35  g 0.3   b 0.22  l 2500 }
//!     sharpness 4
//!     size      128
//! }
//! ```
//!
//! **Two kinds, because there are no HDR images until M116.** `faces` names six `foundry:texture`
//! records, +X −X +Y −Y +Z −Z, read in linear light and scaled by `luminance` (cd/m² of a texel
//! of value 1). `gradient` blends three colours by height: each colour's linear `r g b` times its
//! own `l`, in cd/m². The field that chooses between them is `kind`, as `foundry:light`'s is, and
//! not §7.1's `source`: `source` is every asset kind's file path (`schemas.source_field`), and
//! the registry reads any record with one as a file to open.
//!
//! **The prefilter is a pure function of the record and its faces' pixels** (§7.2). It makes:
//! - the source cube, `size` texels a face: the gradient evaluated at each texel's direction, or
//!   the faces box-filtered down to `size` in linear light;
//! - the specular cube, `size` down to 8, level *k* prefiltered for roughness *k* / (levels − 1)
//!   by GGX importance sampling with a fixed 64-point Hammersley set, each sample reading the
//!   source at the mip its solid angle covers (Křivánek and Colbert 2008). Level 0 is the source,
//!   a mirror. The split sum's `n = v = r` is assumed;
//! - nine spherical-harmonic coefficients per channel, the source projected by each texel's solid
//!   angle and convolved with the clamped cosine over π (Ramamoorthi and Hanrahan 2001), so that
//!   `evaluate` gives the radiance a white Lambertian surface reflects.
//!
//! **Deterministic** (I9). Every loop is integer-indexed in a fixed order, the arithmetic is
//! `f32` with no fast-math or contraction, sums that need the range are `f64`, and the only
//! transcendental functions are `core`'s own (`exp2`, `log2`, `sinCosTurns`) and `@sqrt`, which
//! IEEE 754 rounds exactly. The same record and faces make the same bytes on every host, and the
//! shipped environments are pinned by hash.
//!
//! **Faces are sampled without crossing a face's edge.** A bilinear read near an edge clamps to
//! the face it is on, where the GPU's seamless filtering would blend the neighbour. At the levels
//! that matter (a wide lobe reads a coarse mip) the error is a fraction of one texel's weight.
//!
//! Untrusted content: refused with a named error, never asserted (CLAUDE.md §5).

const std = @import("std");
const core = @import("core");
const data = @import("data");

const image_mod = @import("image.zig");
const mips = @import("mips.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Fields = data.fpk.Fields;
const FieldType = data.FieldType;
const Image = image_mod.Image;
const Schema = data.Schema;
const SchemaId = data.SchemaId;
const exp2 = core.math.exp.exp2;
const log2 = core.math.exp.log2;

pub const name = "foundry:environment";

pub const Kind = enum { faces, gradient };

/// The specular cube's face, in texels: a power of two in this range.
pub const min_size: u32 = 16;
pub const max_size: u32 = 512;
/// The smallest level of the specular cube, which is prefiltered for roughness 1.
pub const last_level_size: u32 = 8;
/// GGX samples a texel, one fixed Hammersley set (§7.2).
pub const sample_count: u32 = 64;
/// The largest finite `f16`: the cube is `rgba16_float`, so nothing in it may be brighter.
pub const max_luminance: f32 = 65504;

const colour_type: FieldType = .{ .nested = &.{
    .{ .name = "r", .type = .f32 },
    .{ .name = "g", .type = .f32 },
    .{ .name = "b", .type = .f32 },
    .{ .name = "l", .type = .f32 },
} };
const id_type: FieldType = .id;

/// Version 1. Every name here is on authors' disks (CLAUDE.md §7).
pub const schema: Schema = .{
    .id = SchemaId.fromStringUnchecked(name),
    .version = 1,
    .fields = &.{
        .{ .name = "kind", .type = .string },
        .{ .name = "faces", .type = .{ .list = &id_type }, .presence = .optional },
        .{ .name = "luminance", .type = .f32, .presence = .{ .default = .{ .float = 1000 } } },
        .{ .name = "zenith", .type = colour_type, .presence = .optional },
        .{ .name = "horizon", .type = colour_type, .presence = .optional },
        .{ .name = "ground", .type = colour_type, .presence = .optional },
        .{ .name = "sharpness", .type = .f32, .presence = .{ .default = .{ .float = 4 } } },
        .{ .name = "size", .type = .u32, .presence = .{ .default = .{ .int = 128 } } },
    },
};

/// A linear colour and the luminance of its white, in cd/m²: the radiance is `rgb · l`.
pub const Colour = struct {
    rgb: [3]f32,
    l: f32,

    pub fn radiance(self: Colour) [3]f32 {
        return .{ self.rgb[0] * self.l, self.rgb[1] * self.l, self.rgb[2] * self.l };
    }

    fn validate(self: Colour) Refusal!void {
        for (self.rgb) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidColour;
        if (!std.math.isFinite(self.l) or self.l < 0 or self.l > max_luminance) return error.InvalidLuminance;
    }
};

/// Three colours blended by the height of a direction (its `y`, +Y being up, ADR-0048).
pub const Gradient = struct {
    zenith: Colour,
    horizon: Colour,
    ground: Colour,
    sharpness: f32 = 4,

    /// The radiance toward a unit direction whose height is `y`. At the horizon it is the
    /// horizon's; toward either pole it is `1 − (1 − |y|)^sharpness` of the way to the pole's
    /// colour, so a larger `sharpness` makes a thinner horizon band.
    pub fn at(self: Gradient, y: f32) [3]f32 {
        const pole = if (y >= 0) self.zenith else self.ground;
        const t = 1 - powUnit(1 - @min(@abs(y), 1), self.sharpness);
        const a = self.horizon.radiance();
        const b = pole.radiance();
        return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
    }
};

pub const Source = union(Kind) {
    faces: [6]ContentId,
    gradient: Gradient,
};

/// A decoded record.
pub const Environment = struct {
    source: Source,
    /// cd/m² of a face texel of value 1. Unused by a gradient, whose colours carry their own.
    luminance: f32 = 1000,
    size: u32 = 128,

    pub fn validate(self: Environment) Refusal!void {
        if (!std.math.isFinite(self.luminance) or self.luminance < 0 or self.luminance > max_luminance)
            return error.InvalidLuminance;
        if (self.size < min_size or self.size > max_size or !std.math.isPowerOfTwo(self.size)) return error.InvalidSize;
        switch (self.source) {
            .faces => {},
            .gradient => |g| {
                try g.zenith.validate();
                try g.horizon.validate();
                try g.ground.validate();
                if (!std.math.isFinite(g.sharpness) or g.sharpness <= 0) return error.InvalidSharpness;
            },
        }
    }

    /// The specular cube's levels, `size` down to `last_level_size`.
    pub fn levelCount(self: Environment) u32 {
        return levelsFor(self.size);
    }
};

pub fn levelsFor(size: u32) u32 {
    return @ctz(size) - @ctz(last_level_size) + 1;
}

pub const Refusal = error{
    InvalidColour,
    InvalidLuminance,
    InvalidSharpness,
    InvalidSize,
};

pub const DecodeError = Refusal || error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    UnknownKind,
    /// `faces` is missing, or is not six.
    InvalidFaces,
    /// A gradient without its zenith, horizon or ground.
    MissingGradient,
};

/// What the six images a `faces` record names can be refused for, where they are decoded.
pub const FaceError = error{
    /// A face's texture is `linear` data, not a colour.
    FaceNotColour,
    FaceNotSquare,
    FacesDiffer,
    /// A face is not `size` times a power of two, so it cannot be box-filtered to `size`.
    FaceSizeInvalid,
};

pub const Error = DecodeError || FaceError;

/// A phrase naming the field, for a diagnostic or a log line: "environment '<id>' <...>".
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Unreadable => "cannot be read against its schema",
        error.UnknownKind => "has a kind that is not faces or gradient",
        error.InvalidFaces => "needs exactly six faces, +X -X +Y -Y +Z -Z",
        error.MissingGradient => "is a gradient without its zenith, horizon and ground",
        error.InvalidColour => "has a colour component that is not between 0 and 1",
        error.InvalidLuminance => "has a luminance that is negative, not finite or above 65504",
        error.InvalidSharpness => "has a sharpness that is not a positive number",
        error.InvalidSize => "has a size that is not a power of two from 16 to 512",
        error.FaceNotColour => "names a face texture whose color_space is not srgb",
        error.FaceNotSquare => "names a face texture that is not square",
        error.FacesDiffer => "names face textures of different sizes",
        error.FaceSizeInvalid => "names faces whose size is not its size times a power of two",
    };
}

/// Reads and validates a record laid out against this schema.
pub fn decode(fields: Fields) DecodeError!Environment {
    const kind_text = try stringOf(fields, "kind") orelse return error.Unreadable;
    const kind = std.meta.stringToEnum(Kind, kind_text) orelse return error.UnknownKind;
    var out: Environment = .{ .source = undefined };
    if (try floatOf(fields, "luminance")) |v| out.luminance = v;
    if (try intOf(fields, "size")) |v| out.size = std.math.cast(u32, v) orelse return error.InvalidSize;
    switch (kind) {
        .faces => {
            const i = indexOf(fields, "faces") orelse return error.Unreadable;
            const list = (fields.listAt(i) catch return error.Unreadable) orelse return error.InvalidFaces;
            if (list.len != 6) return error.InvalidFaces;
            var ids: [6]ContentId = undefined;
            for (&ids, 0..) |*id, k| id.* = (list.idAt(@intCast(k)) catch return error.Unreadable) orelse return error.Unreadable;
            out.source = .{ .faces = ids };
        },
        .gradient => {
            var g: Gradient = .{
                .zenith = try colourOf(fields, "zenith") orelse return error.MissingGradient,
                .horizon = try colourOf(fields, "horizon") orelse return error.MissingGradient,
                .ground = try colourOf(fields, "ground") orelse return error.MissingGradient,
            };
            if (try floatOf(fields, "sharpness")) |v| g.sharpness = v;
            out.source = .{ .gradient = g };
        },
    }
    try out.validate();
    return out;
}

/// One face of a `faces` environment: its decoded image and its texture record's colour space.
pub const Face = struct {
    image: Image,
    color_space: mips.ColorSpace,
};

/// Nine coefficients a channel, in the order Y₀₀, Y₁₋₁, Y₁₀, Y₁₁, Y₂₋₂, Y₂₋₁, Y₂₀, Y₂₁, Y₂₂ over a
/// direction's (x, y, z), each already convolved with the clamped cosine and divided by π.
pub const Harmonics = [9][3]f32;

/// The radiance a white Lambertian surface facing unit `n` reflects under `h`.
pub fn evaluate(h: Harmonics, n: [3]f32) [3]f32 {
    const basis = shBasis(n);
    var out: [3]f32 = .{ 0, 0, 0 };
    for (basis, h) |y, c| {
        for (&out, c) |*o, v| o.* += v * y;
    }
    return out;
}

/// What an environment's load hands the renderer: the cube's bytes and the harmonics.
pub const Prefiltered = struct {
    /// Level 0's face, in texels.
    size: u32,
    levels: u32,
    /// `rgba16_float`, little-endian, alpha 1: level by level, largest first; within a level,
    /// face by face, +X −X +Y −Y +Z −Z; within a face, rows top to bottom, as the RHI's copy of
    /// one face of one level reads them (`environment.md` §3.2).
    bytes: []u8,
    harmonics: Harmonics,

    pub const bytes_per_texel: usize = 8;

    pub fn levelSize(self: Prefiltered, level: u32) u32 {
        return self.size >> @intCast(level);
    }

    pub fn faceOffset(self: Prefiltered, level: u32, face: u32) usize {
        var offset: usize = 0;
        for (0..level) |k| offset += 6 * faceBytesAt(self.levelSize(@intCast(k)));
        return offset + face * faceBytesAt(self.levelSize(level));
    }

    pub fn faceBytes(self: Prefiltered, level: u32, face: u32) []const u8 {
        const at = self.faceOffset(level, face);
        return self.bytes[at..][0..faceBytesAt(self.levelSize(level))];
    }

    /// A texel as `f32`, for tests and oracles.
    pub fn texel(self: Prefiltered, level: u32, face: u32, x: u32, y: u32) [3]f32 {
        const s = self.levelSize(level);
        const at = self.faceOffset(level, face) + (@as(usize, y) * s + x) * bytes_per_texel;
        var out: [3]f32 = undefined;
        for (&out, 0..) |*o, c| o.* = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, self.bytes[at + c * 2 ..][0..2], .little))));
        return out;
    }

    /// The cube along `d` (any length but zero) at fractional level `lod`, as the lit shaders
    /// read it (`environment.md` §8's oracle): bilinear within the face `d` meets, clamped at
    /// its edge, and linear between the two levels either side of `lod`, which is clamped to
    /// the cube's levels. Where the GPU's seamless filter blends a neighbouring face at an edge,
    /// this does not, so an oracle compares texels away from face edges.
    pub fn sample(self: Prefiltered, d: [3]f32, lod: f32) [3]f32 {
        const top: f32 = @floatFromInt(self.levels - 1);
        const at = @min(@max(lod, 0), top);
        const m0: u32 = @intFromFloat(@floor(at));
        const t = at - @as(f32, @floatFromInt(m0));
        const where = faceOf(d);
        const a = self.bilinearAt(m0, where);
        if (t == 0) return a;
        const b = self.bilinearAt(m0 + 1, where);
        return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
    }

    fn bilinearAt(self: Prefiltered, level: u32, where: FaceUv) [3]f32 {
        const size = self.levelSize(level);
        const s: f32 = @floatFromInt(size);
        const last = s - 1;
        const fx = @min(@max((where.u + 1) * 0.5 * s - 0.5, 0), last);
        const fy = @min(@max((where.v + 1) * 0.5 * s - 0.5, 0), last);
        const x0: u32 = @intFromFloat(@floor(fx));
        const y0: u32 = @intFromFloat(@floor(fy));
        const x1 = @min(x0 + 1, size - 1);
        const y1 = @min(y0 + 1, size - 1);
        const tx = fx - @as(f32, @floatFromInt(x0));
        const ty = fy - @as(f32, @floatFromInt(y0));
        const a = self.texel(level, where.face, x0, y0);
        const b = self.texel(level, where.face, x1, y0);
        const c = self.texel(level, where.face, x0, y1);
        const e = self.texel(level, where.face, x1, y1);
        var out: [3]f32 = undefined;
        for (&out, 0..) |*o, ch| {
            const upper = a[ch] + (b[ch] - a[ch]) * tx;
            const lower = c[ch] + (e[ch] - c[ch]) * tx;
            o.* = upper + (lower - upper) * ty;
        }
        return out;
    }

    pub fn deinit(self: *Prefiltered, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

fn faceBytesAt(size: u32) usize {
    return @as(usize, size) * size * Prefiltered.bytes_per_texel;
}

/// The whole prefilter (§7.2). `faces` are the six decoded images of a `faces` environment, in
/// its order, and are ignored for a gradient. **Pure**: it reads its arguments and nothing else,
/// on any thread, so it is a background decode's body.
pub fn prefilter(gpa: Allocator, env: Environment, faces: []const Face) (Allocator.Error || Error)!Prefiltered {
    try env.validate();
    var chain = try Chain.init(gpa, env.size);
    defer chain.deinit(gpa);
    switch (env.source) {
        .gradient => |g| fillGradient(chain.levels[0], g),
        .faces => {
            if (faces.len != 6) return error.InvalidFaces;
            try fillFaces(chain.levels[0], faces, env.luminance);
        },
    }
    chain.reduce();

    const levels = env.levelCount();
    var total: usize = 0;
    for (0..levels) |k| total += 6 * faceBytesAt(env.size >> @intCast(k));
    const bytes = try gpa.alloc(u8, total);
    errdefer gpa.free(bytes);
    var out: Prefiltered = .{ .size = env.size, .levels = levels, .bytes = bytes, .harmonics = harmonicsOf(chain.levels[0]) };

    // Level 0 is the source itself.
    const source = chain.levels[0];
    for (0..6) |f| for (0..source.size) |y| for (0..source.size) |x| {
        writeTexel(&out, 0, @intCast(f), @intCast(x), @intCast(y), source.at(@intCast(f), @intCast(x), @intCast(y)));
    };
    for (1..levels) |k| prefilterLevel(&out, &chain, @intCast(k));
    return out;
}

// -- The source cube and its box chain -----------------------------------------------------------

/// One level of the source: six faces of `size²` linear RGB texels, each face's rows top to bottom.
const Level = struct {
    size: u32,
    texels: [][3]f32,

    fn at(self: Level, face: u32, x: u32, y: u32) [3]f32 {
        return self.texels[(@as(usize, face) * self.size + y) * self.size + x];
    }

    fn set(self: Level, face: u32, x: u32, y: u32, v: [3]f32) void {
        self.texels[(@as(usize, face) * self.size + y) * self.size + x] = v;
    }
};

/// The source cube and its levels down to 1×1, each a 2×2 box of the one above. Filtered
/// importance sampling reads from these.
const Chain = struct {
    levels: []Level,

    fn init(gpa: Allocator, size: u32) Allocator.Error!Chain {
        const count = @ctz(size) + 1;
        const levels = try gpa.alloc(Level, count);
        var made: usize = 0;
        errdefer {
            for (levels[0..made]) |l| gpa.free(l.texels);
            gpa.free(levels);
        }
        for (levels, 0..) |*l, k| {
            const s = size >> @intCast(k);
            l.* = .{ .size = s, .texels = try gpa.alloc([3]f32, 6 * @as(usize, s) * s) };
            made += 1;
        }
        return .{ .levels = levels };
    }

    fn deinit(self: *Chain, gpa: Allocator) void {
        for (self.levels) |l| gpa.free(l.texels);
        gpa.free(self.levels);
    }

    /// Each texel the mean of the four below it **weighted by their solid angles**, so a level
    /// keeps the light its texels carry. A plain box average would not: a face's central texels
    /// subtend about twice its corners', and a bright texel at a centre would lose half its
    /// light at a coarse mip (the roughness-1 test's lobe, before this was weighted).
    fn reduce(self: Chain) void {
        for (self.levels[1..], self.levels[0 .. self.levels.len - 1]) |dst, src| {
            for (0..6) |f| for (0..dst.size) |y| for (0..dst.size) |x| {
                var sum: [3]f32 = .{ 0, 0, 0 };
                var weight: f32 = 0;
                for (0..2) |dy| for (0..2) |dx| {
                    const sx: u32 = @intCast(x * 2 + dx);
                    const sy: u32 = @intCast(y * 2 + dy);
                    const w = texelAngleAt(sx, sy, src.size);
                    const c = src.at(@intCast(f), sx, sy);
                    for (&sum, c) |*o, v| o.* += v * w;
                    weight += w;
                };
                dst.set(@intCast(f), @intCast(x), @intCast(y), .{ sum[0] / weight, sum[1] / weight, sum[2] / weight });
            };
        }
    }

    /// Trilinear within a face: bilinear at the two levels around `mip`, mixed.
    fn sample(self: Chain, dir: [3]f32, mip: f32) [3]f32 {
        const where = faceOf(dir);
        const last: f32 = @floatFromInt(self.levels.len - 1);
        const m = @min(@max(mip, 0), last);
        const m0: u32 = @intFromFloat(@floor(m));
        const a = bilinear(self.levels[m0], where);
        if (m0 + 1 >= self.levels.len) return a;
        const t = m - @as(f32, @floatFromInt(m0));
        if (t == 0) return a;
        const b = bilinear(self.levels[m0 + 1], where);
        return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
    }
};

fn bilinear(level: Level, where: FaceUv) [3]f32 {
    const s: f32 = @floatFromInt(level.size);
    const last = s - 1;
    const fx = @min(@max((where.u + 1) * 0.5 * s - 0.5, 0), last);
    const fy = @min(@max((where.v + 1) * 0.5 * s - 0.5, 0), last);
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, level.size - 1);
    const y1 = @min(y0 + 1, level.size - 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));
    const a = level.at(where.face, x0, y0);
    const b = level.at(where.face, x1, y0);
    const c = level.at(where.face, x0, y1);
    const d = level.at(where.face, x1, y1);
    var out: [3]f32 = undefined;
    for (&out, 0..) |*o, ch| {
        const top = a[ch] + (b[ch] - a[ch]) * tx;
        const bottom = c[ch] + (d[ch] - c[ch]) * tx;
        o.* = top + (bottom - top) * ty;
    }
    return out;
}

fn fillGradient(level: Level, g: Gradient) void {
    for (0..6) |f| for (0..level.size) |y| for (0..level.size) |x| {
        const d = texelDirection(@intCast(f), @intCast(x), @intCast(y), level.size);
        level.set(@intCast(f), @intCast(x), @intCast(y), g.at(d[1]));
    };
}

/// The six faces in linear light times `luminance`, each output texel the plain average of the
/// `k × k` block it covers.
fn fillFaces(level: Level, faces: []const Face, luminance: f32) FaceError!void {
    const first = faces[0].image;
    for (faces) |face| {
        if (face.color_space != .srgb) return error.FaceNotColour;
        if (face.image.width != face.image.height) return error.FaceNotSquare;
        if (face.image.width != first.width) return error.FacesDiffer;
    }
    if (first.width < level.size or first.width % level.size != 0 or !std.math.isPowerOfTwo(first.width / level.size))
        return error.FaceSizeInvalid;
    const k = first.width / level.size;
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(k * k));
    for (faces, 0..) |face, f| for (0..level.size) |y| for (0..level.size) |x| {
        var sum: [3]f32 = .{ 0, 0, 0 };
        for (0..k) |by| for (0..k) |bx| {
            const p = face.image.pixel(@intCast(x * k + bx), @intCast(y * k + by));
            for (&sum, 0..) |*s, ch| s.* += mips.srgb_to_linear[p[ch]];
        };
        level.set(@intCast(f), @intCast(x), @intCast(y), .{ sum[0] * inv * luminance, sum[1] * inv * luminance, sum[2] * inv * luminance });
    };
}

// -- Directions ---------------------------------------------------------------------------------

/// The unit direction through the centre of texel (`x`, `y`) of `face`, by the cube convention
/// every GPU API shares and the RHI promises (+X −X +Y −Y +Z −Z, `rhi/resource.zig`).
pub fn texelDirection(face: u32, x: u32, y: u32, size: u32) [3]f32 {
    const s: f32 = @floatFromInt(size);
    const u = 2 * (@as(f32, @floatFromInt(x)) + 0.5) / s - 1;
    const v = 2 * (@as(f32, @floatFromInt(y)) + 0.5) / s - 1;
    const d: [3]f32 = switch (face) {
        0 => .{ 1, -v, -u },
        1 => .{ -1, -v, u },
        2 => .{ u, 1, v },
        3 => .{ u, -1, -v },
        4 => .{ u, -v, 1 },
        else => .{ -u, -v, -1 },
    };
    return normalize(d);
}

const FaceUv = struct { face: u32, u: f32, v: f32 };

/// Which face a direction meets, and where on it, each of `u` and `v` in [−1, 1]. A tie between
/// axes goes to x, then y, which is fixed and so deterministic.
fn faceOf(d: [3]f32) FaceUv {
    const ax = @abs(d[0]);
    const ay = @abs(d[1]);
    const az = @abs(d[2]);
    if (ax >= ay and ax >= az) {
        return if (d[0] >= 0) .{ .face = 0, .u = -d[2] / ax, .v = -d[1] / ax } else .{ .face = 1, .u = d[2] / ax, .v = -d[1] / ax };
    }
    if (ay >= az) {
        return if (d[1] >= 0) .{ .face = 2, .u = d[0] / ay, .v = d[2] / ay } else .{ .face = 3, .u = d[0] / ay, .v = -d[2] / ay };
    }
    return if (d[2] >= 0) .{ .face = 4, .u = d[0] / az, .v = -d[1] / az } else .{ .face = 5, .u = -d[0] / az, .v = -d[1] / az };
}

fn texelAngleAt(x: u32, y: u32, size: u32) f32 {
    const s: f32 = @floatFromInt(size);
    return texelSolidAngle(2 * (@as(f32, @floatFromInt(x)) + 0.5) / s - 1, 2 * (@as(f32, @floatFromInt(y)) + 0.5) / s - 1, size);
}

/// The solid angle a texel of a `size` face subtends at the cube's centre, approximately: its
/// area on the unit cube over the cube of its distance.
fn texelSolidAngle(face_u: f32, face_v: f32, size: u32) f32 {
    const edge = 2 / @as(f32, @floatFromInt(size));
    const r2 = 1 + face_u * face_u + face_v * face_v;
    return edge * edge / (r2 * @sqrt(r2));
}

// -- Harmonics ----------------------------------------------------------------------------------

fn shBasis(n: [3]f32) [9]f32 {
    const x = n[0];
    const y = n[1];
    const z = n[2];
    return .{
        0.282095,
        0.488603 * y,
        0.488603 * z,
        0.488603 * x,
        1.092548 * x * y,
        1.092548 * y * z,
        0.315392 * (3 * z * z - 1),
        1.092548 * x * z,
        0.546274 * (x * x - y * y),
    };
}

/// The clamped cosine's convolution per band, over π: 1, 2/3, 1/4.
const band_weights = [9]f64{ 1, 2.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0, 0.25, 0.25, 0.25, 0.25, 0.25 };

fn harmonicsOf(level: Level) Harmonics {
    var sums: [9][3]f64 = @splat(.{ 0, 0, 0 });
    var total_weight: f64 = 0;
    for (0..6) |f| for (0..level.size) |y| for (0..level.size) |x| {
        const s: f32 = @floatFromInt(level.size);
        const u = 2 * (@as(f32, @floatFromInt(x)) + 0.5) / s - 1;
        const v = 2 * (@as(f32, @floatFromInt(y)) + 0.5) / s - 1;
        const w: f64 = texelSolidAngle(u, v, level.size);
        const d = texelDirection(@intCast(f), @intCast(x), @intCast(y), level.size);
        const basis = shBasis(d);
        const c = level.at(@intCast(f), @intCast(x), @intCast(y));
        for (&sums, basis) |*sum, b| for (sum, c) |*o, ch| {
            o.* += @as(f64, ch) * b * w;
        };
        total_weight += w;
    };
    // The texels' solid angles sum to slightly off 4π; scaling by the difference makes a constant
    // cube's harmonics that constant exactly, rather than to the approximation's error.
    const scale = 4 * std.math.pi / total_weight;
    var out: Harmonics = undefined;
    for (&out, sums, band_weights) |*o, sum, weight| for (o, sum) |*c, v| {
        c.* = @floatCast(v * scale * weight);
    };
    return out;
}

// -- The specular levels ------------------------------------------------------------------------

/// One importance sample in the tangent frame where the normal is +z: the reflected direction,
/// its cosine with the normal, and the source mip its solid angle covers.
const Sample = struct { l: [3]f32, n_dot_l: f32, mip: f32 };

fn samplesFor(roughness: f32, source_size: u32) [sample_count]?Sample {
    const a: f64 = @as(f64, roughness) * roughness;
    const a2 = a * a;
    const texel_angle = 4 * std.math.pi / (6 * @as(f64, @floatFromInt(source_size)) * @as(f64, @floatFromInt(source_size)));
    var out: [sample_count]?Sample = undefined;
    for (&out, 0..) |*s, i| {
        const xi1 = @as(f64, @floatFromInt(i)) / sample_count;
        const xi2 = @as(f64, @floatFromInt(@bitReverse(@as(u32, @intCast(i))))) / 4294967296.0;
        const cos2 = (1 - xi2) / (1 + (a2 - 1) * xi2);
        const cos_t = @sqrt(cos2);
        const sin_t = @sqrt(@max(1 - cos2, 0));
        const sc = core.math.trig.sinCosTurns(xi1);
        // H in the tangent frame; with v = n, l = 2(n·h)h − n.
        const h = [3]f64{ sin_t * sc[1], sin_t * sc[0], cos_t };
        const n_dot_l = 2 * cos2 - 1;
        if (n_dot_l <= 0) {
            s.* = null;
            continue;
        }
        const denom = cos2 * (a2 - 1) + 1;
        const d = a2 / (std.math.pi * denom * denom);
        // pdf(l) = D·(n·h) / (4·(v·h)), and v·h = n·h when v = n.
        const pdf = d / 4;
        const sample_angle = 1 / (@as(f64, sample_count) * pdf);
        const ratio: f32 = @floatCast(sample_angle / texel_angle);
        s.* = .{
            .l = .{ @floatCast(2 * cos_t * h[0]), @floatCast(2 * cos_t * h[1]), @floatCast(n_dot_l) },
            .n_dot_l = @floatCast(n_dot_l),
            .mip = @max(0.5 * log2(ratio) + 1, 0),
        };
    }
    return out;
}

fn prefilterLevel(out: *Prefiltered, chain: *const Chain, level: u32) void {
    const roughness = @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(out.levels - 1));
    const set = samplesFor(roughness, out.size);
    const size = out.levelSize(level);
    for (0..6) |f| for (0..size) |y| for (0..size) |x| {
        const n = texelDirection(@intCast(f), @intCast(x), @intCast(y), size);
        const up: [3]f32 = if (@abs(n[2]) < 0.999) .{ 0, 0, 1 } else .{ 1, 0, 0 };
        const tx = normalize(cross(up, n));
        const ty = cross(n, tx);
        var sum: [3]f32 = .{ 0, 0, 0 };
        var weight: f32 = 0;
        for (set) |maybe| {
            const s = maybe orelse continue;
            const l: [3]f32 = .{
                tx[0] * s.l[0] + ty[0] * s.l[1] + n[0] * s.l[2],
                tx[1] * s.l[0] + ty[1] * s.l[1] + n[1] * s.l[2],
                tx[2] * s.l[0] + ty[2] * s.l[1] + n[2] * s.l[2],
            };
            const c = chain.sample(l, s.mip);
            for (&sum, c) |*o, v| o.* += v * s.n_dot_l;
            weight += s.n_dot_l;
        }
        writeTexel(out, level, @intCast(f), @intCast(x), @intCast(y), .{ sum[0] / weight, sum[1] / weight, sum[2] / weight });
    };
}

fn writeTexel(out: *Prefiltered, level: u32, face: u32, x: u32, y: u32, v: [3]f32) void {
    const s = out.levelSize(level);
    const at = out.faceOffset(level, face) + (@as(usize, y) * s + x) * Prefiltered.bytes_per_texel;
    const rgba = [4]f32{ v[0], v[1], v[2], 1 };
    for (rgba, 0..) |c, ch| {
        const half: f16 = @floatCast(c);
        std.mem.writeInt(u16, out.bytes[at + ch * 2 ..][0..2], @bitCast(half), .little);
    }
}

// -- Small arithmetic ---------------------------------------------------------------------------

/// `x^e` for `x` in [0, 1] and `e` > 0, by `core`'s own `exp2` and `log2`.
fn powUnit(x: f32, e: f32) f32 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    return exp2(e * log2(x));
}

fn normalize(v: [3]f32) [3]f32 {
    const inv = 1 / @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

// -- Field reads --------------------------------------------------------------------------------

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

fn stringOf(fields: Fields, field: []const u8) DecodeError!?[]const u8 {
    const i = indexOf(fields, field) orelse return null;
    return fields.stringAt(i) catch return error.Unreadable;
}

fn colourOf(fields: Fields, field: []const u8) DecodeError!?Colour {
    const i = indexOf(fields, field) orelse return null;
    const nested = (fields.nestedAt(i) catch return error.Unreadable) orelse return null;
    return .{
        .rgb = .{
            try floatOf(nested, "r") orelse return error.Unreadable,
            try floatOf(nested, "g") orelse return error.Unreadable,
            try floatOf(nested, "b") orelse return error.Unreadable,
        },
        .l = try floatOf(nested, "l") orelse return error.Unreadable,
    };
}

// -- Tests --------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = data.Registry;

fn decodeText(source: []const u8) !DecodeError!Environment {
    const gpa = testing.allocator;
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    _ = try registry.register(gpa, schema);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "environments.fdt", source, .{ .namespace = "t" }, &diags);
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

const day_text =
    \\foundry:environment t:day {
    \\    kind "gradient"
    \\    zenith  { r 0.25 g 0.45 b 1    l 6000 }
    \\    horizon { r 0.85 g 0.9  b 1    l 8000 }
    \\    ground  { r 0.35 g 0.3  b 0.22 l 2500 }
    \\    sharpness 4  size 16
    \\}
;

test "the design's gradient decodes to the values it says" {
    const env = try (try decodeText(day_text));
    try testing.expectEqual(@as(u32, 16), env.size);
    try testing.expectEqual(@as(u32, 2), env.levelCount());
    const g = env.source.gradient;
    try testing.expectEqual(Colour{ .rgb = .{ 0.25, 0.45, 1 }, .l = 6000 }, g.zenith);
    try testing.expectEqual(Colour{ .rgb = .{ 0.35, 0.3, 0.22 }, .l = 2500 }, g.ground);
    try testing.expectEqual(@as(f32, 4), g.sharpness);
}

test "a faces record names six textures in order and takes the defaults" {
    const env = try (try decodeText("foundry:environment t:room { kind \"faces\" faces [t:px t:nx t:py t:ny t:pz t:nz] }"));
    try testing.expectEqual(@as(f32, 1000), env.luminance);
    try testing.expectEqual(@as(u32, 128), env.size);
    try testing.expectEqual(@as(u32, 5), env.levelCount());
    try testing.expect(env.source.faces[0].eql(ContentId.fromString("t:px")));
    try testing.expect(env.source.faces[5].eql(ContentId.fromString("t:nz")));
}

test "every refusal names its field" {
    const g = "zenith { r 1 g 1 b 1 l 1 } horizon { r 1 g 1 b 1 l 1 } ground { r 1 g 1 b 1 l 1 }";
    const cases = [_]struct { text: []const u8, err: DecodeError }{
        .{ .text = "kind \"image\" " ++ g, .err = error.UnknownKind },
        .{ .text = "kind \"faces\"", .err = error.InvalidFaces },
        .{ .text = "kind \"faces\" faces [t:a t:b t:c t:d t:e]", .err = error.InvalidFaces },
        .{ .text = "kind \"faces\" faces [t:a t:b t:c t:d t:e t:f t:g]", .err = error.InvalidFaces },
        .{ .text = "kind \"faces\" faces [t:a t:b t:c t:d t:e t:f] luminance -1", .err = error.InvalidLuminance },
        .{ .text = "kind \"faces\" faces [t:a t:b t:c t:d t:e t:f] luminance 70000", .err = error.InvalidLuminance },
        .{ .text = "kind \"gradient\" zenith { r 1 g 1 b 1 l 1 } ground { r 1 g 1 b 1 l 1 }", .err = error.MissingGradient },
        .{ .text = "kind \"gradient\" zenith { r 1.5 g 1 b 1 l 1 } horizon { r 1 g 1 b 1 l 1 } ground { r 1 g 1 b 1 l 1 }", .err = error.InvalidColour },
        .{ .text = "kind \"gradient\" zenith { r 1 g 1 b 1 l 1 } horizon { r 1 g -0.1 b 1 l 1 } ground { r 1 g 1 b 1 l 1 }", .err = error.InvalidColour },
        .{ .text = "kind \"gradient\" zenith { r 1 g 1 b 1 l 1 } horizon { r 1 g 1 b 1 l 1 } ground { r 1 g 1 b 1 l -3 }", .err = error.InvalidLuminance },
        .{ .text = "kind \"gradient\" " ++ g ++ " sharpness 0", .err = error.InvalidSharpness },
        .{ .text = "kind \"gradient\" " ++ g ++ " size 100", .err = error.InvalidSize },
        .{ .text = "kind \"gradient\" " ++ g ++ " size 8", .err = error.InvalidSize },
        .{ .text = "kind \"gradient\" " ++ g ++ " size 1024", .err = error.InvalidSize },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "foundry:environment t:bad {{ {s} }}", .{case.text});
        testing.expectError(case.err, try decodeText(source)) catch |err| {
            std.debug.print("case: {s}\n", .{case.text});
            return err;
        };
        try testing.expect(describe(case.err).len != 0);
    }
}

fn solidFace(gpa: Allocator, size: u32, rgb: [3]u8) !Image {
    var image = try Image.alloc(gpa, size, size);
    for (0..size) |y| for (0..size) |x| {
        image.pixel(@intCast(x), @intCast(y)).* = .{ rgb[0], rgb[1], rgb[2], 255 };
    };
    return image;
}

fn facesEnv(size: u32, luminance: f32) Environment {
    return .{ .source = .{ .faces = @splat(.none) }, .luminance = luminance, .size = size };
}

test "face images are refused when not colour, not square, unequal, or not a power of two times the size" {
    const gpa = testing.allocator;
    var images: [7]Image = undefined;
    images[0] = try solidFace(gpa, 16, .{ 1, 2, 3 });
    images[1] = try Image.alloc(gpa, 16, 8);
    images[2] = try solidFace(gpa, 32, .{ 1, 2, 3 });
    images[3] = try solidFace(gpa, 8, .{ 1, 2, 3 });
    images[4] = try solidFace(gpa, 48, .{ 1, 2, 3 });
    images[5] = try solidFace(gpa, 64, .{ 1, 2, 3 });
    images[6] = try solidFace(gpa, 24, .{ 1, 2, 3 });
    defer for (&images) |*image| image.deinit(gpa);
    const same = [_]Face{.{ .image = images[0], .color_space = .srgb }} ** 6;

    var linear = same;
    linear[3].color_space = .linear;
    try testing.expectError(error.FaceNotColour, prefilter(gpa, facesEnv(16, 1), &linear));
    var oblong = same;
    oblong[2].image = images[1];
    try testing.expectError(error.FaceNotSquare, prefilter(gpa, facesEnv(16, 1), &oblong));
    var mixed = same;
    mixed[5].image = images[2];
    try testing.expectError(error.FacesDiffer, prefilter(gpa, facesEnv(16, 1), &mixed));
    try testing.expectError(error.FaceSizeInvalid, prefilter(gpa, facesEnv(16, 1), &(.{Face{ .image = images[3], .color_space = .srgb }} ** 6)));
    try testing.expectError(error.FaceSizeInvalid, prefilter(gpa, facesEnv(16, 1), &(.{Face{ .image = images[4], .color_space = .srgb }} ** 6)));
    try testing.expectError(error.FaceSizeInvalid, prefilter(gpa, facesEnv(16, 1), &(.{Face{ .image = images[6], .color_space = .srgb }} ** 6)));
    try testing.expectError(error.InvalidFaces, prefilter(gpa, facesEnv(16, 1), same[0..5]));
    // Four times the size is a power of two, and filters down.
    var four = try prefilter(gpa, facesEnv(16, 1), &(.{Face{ .image = images[5], .color_space = .srgb }} ** 6));
    four.deinit(gpa);
}

test "the gradient's level 0 is the closed form at each texel's direction" {
    const gpa = testing.allocator;
    const env = try (try decodeText(day_text));
    var out = try prefilter(gpa, env, &.{});
    defer out.deinit(gpa);
    const g = env.source.gradient;
    for (0..6) |f| for (0..16) |y| for (0..16) |x| {
        const d = texelDirection(@intCast(f), @intCast(x), @intCast(y), 16);
        const h: f64 = d[1];
        const pole = if (h >= 0) g.zenith else g.ground;
        const t = 1 - std.math.pow(f64, 1 - @abs(h), g.sharpness);
        const got = out.texel(0, @intCast(f), @intCast(x), @intCast(y));
        for (0..3) |c| {
            const a = @as(f64, g.horizon.rgb[c]) * g.horizon.l;
            const b = @as(f64, pole.rgb[c]) * pole.l;
            const want = a + (b - a) * t;
            // An f16 holds 11 significant bits.
            try testing.expectApproxEqRel(want, @as(f64, got[c]), 1.0 / 1024.0);
        }
    };
}

test "a constant cube's harmonics and every level are that constant" {
    const gpa = testing.allocator;
    const c: Colour = .{ .rgb = .{ 0.5, 0.25, 1 }, .l = 40 };
    const env: Environment = .{ .source = .{ .gradient = .{ .zenith = c, .horizon = c, .ground = c } }, .size = 32 };
    var out = try prefilter(gpa, env, &.{});
    defer out.deinit(gpa);
    const want = c.radiance();
    for ([_][3]f32{ .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 1, 0, 0 }, normalize(.{ 1, 2, -3 }) }) |n| {
        const e = evaluate(out.harmonics, n);
        for (e, want) |got, w| try testing.expectApproxEqRel(w, got, 1e-5);
    }
    for (1..9) |i| for (out.harmonics[i]) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-3);
    for (0..out.levels) |k| for (0..6) |f| {
        const got = out.texel(@intCast(k), @intCast(f), 1, 2);
        for (got, want) |g, w| try testing.expectApproxEqRel(w, g, 1.0 / 1024.0);
    };
}

test "level 0 is the faces in linear light times the luminance, box-filtered to the size" {
    const gpa = testing.allocator;
    var images: [6]Image = undefined;
    for (&images, 0..) |*image, f| {
        image.* = try Image.alloc(gpa, 32, 32);
        for (0..32) |y| for (0..32) |x| {
            image.pixel(@intCast(x), @intCast(y)).* = .{ @intCast((x * 7 + f * 31) % 256), @intCast((y * 5 + x) % 256), @intCast((f * 40 + y) % 256), 255 };
        };
    }
    defer for (&images) |*image| image.deinit(gpa);
    var faces: [6]Face = undefined;
    for (&faces, images) |*face, image| face.* = .{ .image = image, .color_space = .srgb };

    var exact = try prefilter(gpa, facesEnv(32, 3), &faces);
    defer exact.deinit(gpa);
    var halved = try prefilter(gpa, facesEnv(16, 3), &faces);
    defer halved.deinit(gpa);
    for (0..6) |f| for (0..32) |y| for (0..32) |x| {
        const p = images[f].pixel(@intCast(x), @intCast(y));
        const got = exact.texel(0, @intCast(f), @intCast(x), @intCast(y));
        for (0..3) |c| {
            const want: f16 = @floatCast(mips.srgb_to_linear[p[c]] * 3);
            try testing.expectEqual(@as(f32, want), got[c]);
        }
    };
    for (0..6) |f| for (0..16) |y| for (0..16) |x| {
        const got = halved.texel(0, @intCast(f), @intCast(x), @intCast(y));
        for (0..3) |c| {
            var sum: f32 = 0;
            for (0..2) |by| for (0..2) |bx| {
                sum += mips.srgb_to_linear[images[f].pixel(@intCast(x * 2 + bx), @intCast(y * 2 + by))[c]];
            };
            const want: f16 = @floatCast(sum * 0.25 * 3);
            try testing.expectEqual(@as(f32, want), got[c]);
        }
    };
}

test "the oracle's sampler reads a texel at its centre, its face by direction, and blends levels" {
    const gpa = testing.allocator;
    var images: [6]Image = undefined;
    for (&images, 0..) |*image, f| {
        image.* = try Image.alloc(gpa, 16, 16);
        for (0..16) |y| for (0..16) |x| {
            image.pixel(@intCast(x), @intCast(y)).* = .{ @intCast((x * 13 + f * 37) % 256), @intCast((y * 11 + f * 5) % 256), @intCast((x * y + f) % 256), 255 };
        };
    }
    defer for (&images) |*image| image.deinit(gpa);
    var faces: [6]Face = undefined;
    for (&faces, images) |*face, image| face.* = .{ .image = image, .color_space = .srgb };
    var out = try prefilter(gpa, facesEnv(16, 2), &faces);
    defer out.deinit(gpa);
    // Each texel's own direction, at every level, is that texel, on the face it belongs to.
    for (0..out.levels) |level| for (0..6) |f| {
        const s = out.levelSize(@intCast(level));
        for ([_][2]u32{ .{ 0, 0 }, .{ s / 2, 1 }, .{ s - 1, s - 1 } }) |xy| {
            const d = texelDirection(@intCast(f), xy[0], xy[1], s);
            const want = out.texel(@intCast(level), @intCast(f), xy[0], xy[1]);
            const got = out.sample(d, @floatFromInt(level));
            for (0..3) |c| try testing.expectApproxEqAbs(want[c], got[c], 1e-5 * @max(1, @abs(want[c])));
        }
    };
    // Between two levels, the blend of each; past the last, the last; below 0, level 0.
    const d = texelDirection(4, 3, 5, 16);
    const a = out.sample(d, 0);
    const b = out.sample(d, 1);
    const mid = out.sample(d, 0.25);
    for (0..3) |c| try testing.expectApproxEqAbs(a[c] + (b[c] - a[c]) * 0.25, mid[c], 1e-5 * @max(1, @abs(a[c])));
    try testing.expectEqual(out.sample(d, @floatFromInt(out.levels - 1)), out.sample(d, 99));
    try testing.expectEqual(a, out.sample(d, -3));
}

test "one bright texel spreads at roughness 1 as GGX's cosine lobe predicts" {
    const gpa = testing.allocator;
    // A black cube with one bright texel at the centre of +Z.
    var images: [6]Image = undefined;
    for (&images) |*image| image.* = try solidFace(gpa, 32, .{ 0, 0, 0 });
    defer for (&images) |*image| image.deinit(gpa);
    images[4].pixel(16, 16).* = .{ 255, 255, 255, 255 };
    var faces: [6]Face = undefined;
    for (&faces, images) |*face, image| face.* = .{ .image = image, .color_space = .srgb };
    const brightness: f32 = 1000;
    var out = try prefilter(gpa, facesEnv(32, brightness), &faces);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), out.levels);

    // With v = n and α = 1, GGX's reflected directions are uniform over the sphere, so the
    // NdotL-weighted mean is (1/π)∫L(l)(n·l)dl: a texel of radiance B and solid angle ω at b
    // gives B·ω·max(n·b, 0)/π.
    const omega = texelSolidAngle(-1.0 / 32.0, -1.0 / 32.0, 32);
    const peak = brightness * omega / std.math.pi;
    const last = out.levels - 1;
    const s = out.levelSize(last);
    const b: [3]f32 = .{ 0, 0, 1 };
    var energy: f64 = 0;
    var brightest: f32 = 0;
    for (0..6) |f| for (0..s) |y| for (0..s) |x| {
        const n = texelDirection(@intCast(f), @intCast(x), @intCast(y), s);
        const v = out.texel(last, @intCast(f), @intCast(x), @intCast(y))[0];
        const cos_nb = n[0] * b[0] + n[1] * b[1] + n[2] * b[2];
        // A direction more than 144.7° from +Z (a quarter turn past its face's corner, 54.7°)
        // has no sample on +Z's face, even where a coarse mip has spread the texel over it.
        if (cos_nb < -0.85) try testing.expectEqual(@as(f32, 0), v);
        if (cos_nb > 0.95) try testing.expectApproxEqRel(peak * cos_nb, v, 0.3);
        brightest = @max(brightest, v);
        const su: f32 = @floatFromInt(s);
        const u = 2 * (@as(f32, @floatFromInt(x)) + 0.5) / su - 1;
        const w = 2 * (@as(f32, @floatFromInt(y)) + 0.5) / su - 1;
        energy += @as(f64, v) * texelSolidAngle(u, w, s);
    };
    // ∫ B·ω·max(n·b, 0)/π dn = B·ω.
    // Sixty-four samples leave the lobe noisy texel to texel; its light is all there.
    try testing.expectApproxEqRel(@as(f64, brightness * omega), energy, 0.05);
    try testing.expect(brightest < peak * 1.3);
    // At the roughness between, the lobe is narrower and so brighter at its peak.
    const mid = out.texel(1, 4, out.levelSize(1) / 2, out.levelSize(1) / 2)[0];
    try testing.expect(mid > brightest);
}

test "the same record makes the same bytes, pinned" {
    const gpa = testing.allocator;
    const env = try (try decodeText(day_text));
    var a = try prefilter(gpa, env, &.{});
    defer a.deinit(gpa);
    var b = try prefilter(gpa, env, &.{});
    defer b.deinit(gpa);
    try testing.expectEqualSlices(u8, a.bytes, b.bytes);
    try testing.expectEqual(a.harmonics, b.harmonics);
    try testing.expectEqual(@as(usize, 6 * (16 * 16 + 8 * 8) * 8), a.bytes.len);
    try testing.expectEqual(@as(u64, 0xa7511b59d6b05d1f), core.id.fnv1a64(a.bytes));
}

test "environment prefilter speed: one thread, printed" {
    // §7.2's cost, measured: `zig build asset-test -Doptimize=ReleaseFast` times 128 and 512, and
    // ADR-0083 is revisited if 512 takes over two seconds. Debug prefilters 128 only, once.
    const gpa = testing.allocator;
    const c: Colour = .{ .rgb = .{ 0.5, 0.6, 0.9 }, .l = 5000 };
    const sizes: []const u32 = if (@import("builtin").mode == .Debug) &.{128} else &.{ 128, 512 };
    for (sizes) |size| {
        const env: Environment = .{ .source = .{ .gradient = .{ .zenith = c, .horizon = .{ .rgb = .{ 1, 1, 1 }, .l = 8000 }, .ground = c } }, .size = size };
        const start = std.Io.Clock.awake.now(testing.io);
        var out = try prefilter(gpa, env, &.{});
        const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
        out.deinit(gpa);
        std.debug.print("environment prefilter ({t}): size {d}, {d:.1} ms\n", .{ @import("builtin").mode, size, @as(f64, @floatFromInt(ns)) / 1e6 });
    }
}
