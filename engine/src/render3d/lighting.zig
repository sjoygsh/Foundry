//! Pure light packing and display maths. `docs/design/light.md` §3 and §7.
const std = @import("std");
const core = @import("core");
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;

pub const max_lights = 16;
pub const Light = struct {
    kind: enum(u32) { directional, point, spot },
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32,
    range: f32 = 0,
    inner_cone: f32 = 0,
    outer_cone: f32 = std.math.pi / 4.0,
    casts_shadow: bool = false,
    world: Mat4,
};

/// All members occupy a vec4, so std140 and Metal have the same stride.
pub const PackedLight = extern struct {
    position_kind: [4]f32,
    direction_range: [4]f32,
    color_intensity: [4]f32,
    cone_shadow: [4]f32,
};

pub const FrameUniform = extern struct {
    view_projection: Mat4,
    camera_exposure: [4]f32,
    ambient: [4]f32,
    counts: [4]u32,
    shadow_matrix: Mat4,
    shadow_parameters: [4]f32,
    lights: [max_lights]PackedLight,
};

/// Validate before packing. Scale the axis first to avoid overflow/underflow in length.
pub fn direction(world: Mat4) Vec3 {
    const axis = Vec3.init(-world.cols[2][0], -world.cols[2][1], -world.cols[2][2]);
    const scale = @max(@abs(axis.x), @max(@abs(axis.y), @abs(axis.z)));
    if (scale == 0) return .zero;
    return Vec3.init(axis.x / scale, axis.y / scale, axis.z / scale).normalize();
}

pub fn valid(light: Light) bool {
    for (light.world.cols) |column| for (column) |v| {
        if (!std.math.isFinite(v)) return false;
    };
    for (light.color) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return false;
    return std.math.isFinite(light.intensity) and light.intensity >= 0 and
        std.math.isFinite(light.range) and light.range >= 0 and
        std.math.isFinite(light.inner_cone) and std.math.isFinite(light.outer_cone) and
        light.inner_cone >= 0 and light.inner_cone < light.outer_cone and
        light.outer_cone <= std.math.pi / 2.0 and !direction(light.world).eql(.zero);
}

pub fn packLight(light: Light) PackedLight {
    const axis = direction(light.world);
    return .{
        .position_kind = .{ light.world.cols[3][0], light.world.cols[3][1], light.world.cols[3][2], @floatFromInt(@intFromEnum(light.kind)) },
        .direction_range = .{ axis.x, axis.y, axis.z, light.range },
        .color_intensity = .{ light.color[0], light.color[1], light.color[2], light.intensity },
        .cone_shadow = .{ @cos(light.inner_cone), @cos(light.outer_cone), @floatFromInt(@intFromBool(light.casts_shadow)), 0 },
    };
}

pub fn packFrame(view_projection: Mat4, camera: Vec3, exposure: ?f32, ambient_radiance: [3]f32, lights: []const Light) FrameUniform {
    var uniform = std.mem.zeroes(FrameUniform);
    uniform.view_projection = view_projection;
    uniform.camera_exposure = .{ camera.x, camera.y, camera.z, exposureScale(exposure) };
    uniform.ambient = .{ ambient_radiance[0], ambient_radiance[1], ambient_radiance[2], 0 };
    uniform.counts[0] = @intCast(lights.len);
    // Shadow rendering arrives in Step 5. The lookup flag stays off until then.
    uniform.shadow_matrix = .identity;
    for (lights, 0..) |light, i| uniform.lights[i] = packLight(light);
    return uniform;
}

pub fn exposureScale(ev100: ?f32) f32 {
    return if (ev100) |ev| @exp2(-ev) / 1.2 else 1;
}

pub fn attenuation(distance: f32, range: f32) f32 {
    const d2 = @max(distance * distance, 1e-6);
    if (range == 0) return 1 / d2;
    const ratio = distance / range;
    const r2 = ratio * ratio;
    return @max(1 - r2 * r2, 0) / d2;
}

pub fn spotCone(cos_angle: f32, inner: f32, outer: f32) f32 {
    const t = std.math.clamp((cos_angle - @cos(outer)) / (@cos(inner) - @cos(outer)), 0, 1);
    return t * t;
}

/// Effective texel-times-factor values, all in linear space. §8's CPU oracle
/// is independent of shader code and resource packing.
pub const Surface = struct {
    base: [3]f32 = .{ 1, 1, 1 },
    metallic: f32 = 0,
    roughness: f32 = 1,
    occlusion: f32 = 1,
    emissive: [3]f32 = .{ 0, 0, 0 },
};

fn pow5(x: f32) f32 {
    const x2 = x * x;
    return x2 * x2 * x;
}

/// glTF 2.0 Appendix B, including cosine. Diffuse is attenuated by the
/// dielectric Fresnel before mixing with the metal, not by mixed F0 twice.
pub fn brdf(surface: Surface, n: Vec3, v: Vec3, l: Vec3) [3]f32 {
    const nv = @max(Vec3.dot(n, v), 0);
    const nl = @max(Vec3.dot(n, l), 0);
    if (nv == 0 or nl == 0) return .{ 0, 0, 0 };
    const h = Vec3.add(v, l).normalize();
    const nh = @max(Vec3.dot(n, h), 0);
    const vh = @max(Vec3.dot(v, h), 0);
    const rough = std.math.clamp(surface.roughness, 0.045, 1);
    const alpha = rough * rough;
    const a2 = alpha * alpha;
    const denominator = nh * nh * (a2 - 1) + 1;
    const distribution = a2 / (std.math.pi * denominator * denominator);
    const visibility = 0.5 / @max(nl * @sqrt(nv * nv * (1 - a2) + a2) + nv * @sqrt(nl * nl * (1 - a2) + a2), 1e-7);
    const f = pow5(1 - vh);
    var result: [3]f32 = undefined;
    for (surface.base, &result) |base, *value| {
        const f0 = 0.04 * (1 - surface.metallic) + base * surface.metallic;
        const fresnel = f0 + (1 - f0) * f;
        value.* = ((1 - (0.04 + 0.96 * f)) * base * (1 - surface.metallic) / std.math.pi +
            distribution * visibility * fresnel) * nl;
    }
    return result;
}

/// Constant radiance split-sum: analytic DFG fit, Karis (2014),
/// Physically Based Shading on Mobile, unrealengine.com. No environment map.
pub fn ambient(surface: Surface, nv: f32, radiance: [3]f32) [3]f32 {
    const rough = std.math.clamp(surface.roughness, 0.045, 1);
    const rx = 1 - rough;
    const ry = 0.0425 - 0.0275 * rough;
    const rz = 1.04 - 0.572 * rough;
    const rw = -0.04 + 0.022 * rough;
    const a = @min(rx * rx, @exp2(-9.28 * @max(nv, 0))) * rx + ry;
    const ab = [2]f32{ -1.04 * a + rz, 1.04 * a + rw };
    const dielectric = 0.04 * ab[0] + ab[1];
    var result: [3]f32 = undefined;
    for (surface.base, radiance, &result) |base, light, *value| {
        const f0 = 0.04 * (1 - surface.metallic) + base * surface.metallic;
        // The fit slightly undershoots zero for an absorbing (black) metal.
        const specular = @max(f0 * ab[0] + ab[1], 0);
        value.* = light * ((1 - dielectric) * base * (1 - surface.metallic) + specular) * surface.occlusion;
    }
    return result;
}

pub fn shade(surface: Surface, position: Vec3, normal: Vec3, camera: Vec3, lights: []const Light, ambient_radiance: [3]f32, exposure: ?f32) [3]f32 {
    const n = normal.normalize();
    const v = Vec3.sub(camera, position).normalize();
    var result = ambient(surface, @max(Vec3.dot(n, v), 0), ambient_radiance);
    for (lights) |light| {
        var l = Vec3.scale(direction(light.world), -1);
        var falloff: f32 = 1;
        if (light.kind != .directional) {
            const p = Vec3.init(light.world.cols[3][0], light.world.cols[3][1], light.world.cols[3][2]);
            const delta = Vec3.sub(p, position);
            const distance = delta.length();
            l = if (distance == 0) n else delta.normalize();
            falloff = attenuation(distance, light.range);
            if (light.kind == .spot) falloff *= spotCone(Vec3.dot(Vec3.scale(l, -1), direction(light.world)), light.inner_cone, light.outer_cone);
        }
        const reflected = brdf(surface, n, v, l);
        for (&result, reflected, light.color) |*value, channel, color|
            value.* += channel * color * light.intensity * falloff;
    }
    for (&result, surface.emissive) |*value, emission| value.* = (value.* + emission) * exposureScale(exposure);
    return result;
}

test "BRDF pins normal incidence dielectric metal grazing and roughness floor" {
    const n = Vec3.init(0, 0, 1);
    const dielectric = brdf(.{ .base = .{ 0.5, 0.5, 0.5 } }, n, n, n);
    try std.testing.expectApproxEqAbs(@as(f32, (0.96 * 0.5 + 0.01) / std.math.pi), dielectric[0], 1e-6);
    const metal = brdf(.{ .base = .{ 0.5, 0.5, 0.5 }, .metallic = 1 }, n, n, n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125 / std.math.pi), metal[0], 1e-6);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, brdf(.{}, n, n, .init(1, 0, 0)));
    try std.testing.expectEqual(brdf(.{ .roughness = 0.045 }, n, n, n), brdf(.{ .roughness = 0 }, n, n, n));
}

test "occlusion scales ambient alone while emission and direct light survive" {
    const n = Vec3.init(0, 0, 1);
    const light = Light{ .kind = .directional, .intensity = 1, .world = .identity };
    const surface = Surface{ .occlusion = 0, .emissive = .{ 1, 0, 0 } };
    const result = shade(surface, .zero, n, n, &.{light}, .{ 3, 3, 3 }, null);
    const direct = brdf(surface, n, n, n);
    try std.testing.expectApproxEqAbs(direct[0] + 1, result[0], 1e-6);
    try std.testing.expectApproxEqAbs(direct[1], result[1], 1e-6);
    const shaded_metal = ambient(.{ .metallic = 1 }, 1, .{ 1, 1, 1 });
    try std.testing.expect(shaded_metal[0] > 0);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, ambient(.{ .metallic = 1, .base = .{ 0, 0, 0 } }, 1, .{ 1, 1, 1 }));
}

/// Khronos PBR Neutral curve, evaluated in non-negative linear Rec.709.
/// Reference: github.com/KhronosGroup/ToneMapping/PBR_Neutral.
pub fn toneMap(input: [3]f32) [3]f32 {
    var color = input;
    const minimum = @min(color[0], @min(color[1], color[2]));
    const toe = if (minimum < 0.08) minimum - 6.25 * minimum * minimum else 0.04;
    for (&color) |*v| v.* -= toe;
    const peak = @max(color[0], @max(color[1], color[2]));
    if (peak < 0.76) return color;
    const compressed = 1 - 0.24 * 0.24 / (peak - 0.52);
    const blend = 1 - 1 / (0.15 * (peak - compressed) + 1);
    for (&color) |*v| v.* = v.* * (compressed / peak) * (1 - blend) + compressed * blend;
    return color;
}

test "frame packing pins every uniform offset and light stride" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 64), @sizeOf(PackedLight));
    try t.expectEqual(@as(usize, 1216), @sizeOf(FrameUniform));
    inline for (.{ .{ "view_projection", 0 }, .{ "camera_exposure", 64 }, .{ "ambient", 80 }, .{ "counts", 96 }, .{ "shadow_matrix", 112 }, .{ "shadow_parameters", 176 }, .{ "lights", 192 } }) |field|
        try t.expectEqual(@as(usize, field[1]), @offsetOf(FrameUniform, field[0]));
    const light: Light = .{ .kind = .spot, .intensity = 70, .range = 9, .world = Mat4.translation(.init(3, 4, 5)) };
    const frame = packFrame(.identity, .init(1, 2, 3), null, .{ 4, 5, 6 }, &.{light});
    try t.expectEqual([4]f32{ 1, 2, 3, 1 }, frame.camera_exposure);
    try t.expectEqual(@as(u32, 1), frame.counts[0]);
    try t.expectEqual(@as(u32, 0), frame.counts[1]);
    try t.expectEqual([4]f32{ 3, 4, 5, 2 }, frame.lights[0].position_kind);
    try t.expectEqual([4]f32{ 0, 0, -1, 9 }, frame.lights[0].direction_range);
    try t.expectEqual(std.mem.zeroes(PackedLight), frame.lights[1]);
}

test "photometric exposure attenuation and cone have pinned endpoints" {
    const t = std.testing;
    try t.expectEqual(@as(f32, 1), exposureScale(null));
    try t.expectApproxEqAbs(@as(f32, 1.0 / 1.2), exposureScale(0), 1e-7);
    try t.expectApproxEqAbs(@as(f32, 1.0 / (1.2 * 32768)), exposureScale(15), 1e-10);
    try t.expectEqual(@as(f32, 0.25), attenuation(2, 0));
    try t.expectEqual(@as(f32, 0), attenuation(10, 10));
    try t.expectEqual(@as(f32, 0), attenuation(12, 10));
    try t.expectEqual(@as(f32, 1), spotCone(@cos(@as(f32, 0.2)), 0.2, 0.6));
    try t.expectEqual(@as(f32, 0), spotCone(@cos(@as(f32, 0.6)), 0.2, 0.6));
}

test "Neutral toe compression and desaturation match reference values" {
    const t = std.testing;
    const cases = [_]struct { input: [3]f32, output: [3]f32 }{
        .{ .input = .{ 0, 0, 0 }, .output = .{ 0, 0, 0 } },
        .{ .input = .{ 0.04, 0.04, 0.04 }, .output = .{ 0.01, 0.01, 0.01 } },
        .{ .input = .{ 0.5, 0.5, 0.5 }, .output = .{ 0.46, 0.46, 0.46 } },
        .{ .input = .{ 1, 0, 0 }, .output = .{ 0.88, 0.01555993, 0.01555993 } },
        .{ .input = .{ 1, 1, 1 }, .output = .{ 0.8690909, 0.8690909, 0.8690909 } },
    };
    for (cases) |case| for (toneMap(case.input), case.output) |actual, expected|
        try t.expectApproxEqAbs(expected, actual, 1e-6);
}
