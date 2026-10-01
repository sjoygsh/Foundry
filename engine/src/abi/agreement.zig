//! The engine's half of the agreement with `foundry.h`.
//!
//! `agreement.c` states every size and offset the specification claims and fails to compile
//! if C disagrees. This states the same numbers and fails the test if Zig disagrees. Neither
//! file describes the other: both describe the contract, which is what makes a disagreement
//! land on whoever changed one side rather than on a mod author six months later.
//!
//! It also does the part no static assertion can. Matching numbers prove two layouts are the
//! same shape; pushing a value through the boundary and reading it back proves they are the
//! same *layout*. Four values make that crossing here — a string, a handle in each
//! direction, and a cursor — and the header's own hash function is called from Zig and
//! compared against the one the content compiler uses, because those are two independent
//! implementations of FNV-1a and nothing else would stop them drifting.
//!
//! Design: `docs/design/public-abi.md` §5 and §16.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const api = @import("api.zig");
const author_types = @import("author_types.zig");
const mod_types = @import("mod_types.zig");
const net_types = @import("net_types.zig");
const types = @import("types.zig");
const ui_types = @import("ui_types.zig");

const testing = std.testing;

const d3 = @import("public3d_types.zig");
comptime {
    if (@sizeOf(d3.Vec3) != 12) @compileError("v6 Vec3 size");
}
comptime {
    if (@offsetOf(d3.Vec3, "x") != 0 or @sizeOf(@FieldType(d3.Vec3, "x")) != 4) @compileError("v6 Vec3.x layout");
}
comptime {
    if (@offsetOf(d3.Vec3, "y") != 4 or @sizeOf(@FieldType(d3.Vec3, "y")) != 4) @compileError("v6 Vec3.y layout");
}
comptime {
    if (@offsetOf(d3.Vec3, "z") != 8 or @sizeOf(@FieldType(d3.Vec3, "z")) != 4) @compileError("v6 Vec3.z layout");
}
comptime {
    if (@sizeOf(d3.Quat) != 16) @compileError("v6 Quat size");
}
comptime {
    if (@offsetOf(d3.Quat, "x") != 0 or @sizeOf(@FieldType(d3.Quat, "x")) != 4) @compileError("v6 Quat.x layout");
}
comptime {
    if (@offsetOf(d3.Quat, "y") != 4 or @sizeOf(@FieldType(d3.Quat, "y")) != 4) @compileError("v6 Quat.y layout");
}
comptime {
    if (@offsetOf(d3.Quat, "z") != 8 or @sizeOf(@FieldType(d3.Quat, "z")) != 4) @compileError("v6 Quat.z layout");
}
comptime {
    if (@offsetOf(d3.Quat, "w") != 12 or @sizeOf(@FieldType(d3.Quat, "w")) != 4) @compileError("v6 Quat.w layout");
}
comptime {
    if (@sizeOf(d3.Mat4) != 64) @compileError("v6 Mat4 size");
}
comptime {
    if (@offsetOf(d3.Mat4, "elements") != 0 or @sizeOf(@FieldType(d3.Mat4, "elements")) != 64) @compileError("v6 Mat4.elements layout");
}
comptime {
    if (@sizeOf(d3.Transform) != 40) @compileError("v6 Transform size");
}
comptime {
    if (@offsetOf(d3.Transform, "translation") != 0 or @sizeOf(@FieldType(d3.Transform, "translation")) != 12) @compileError("v6 Transform.translation layout");
}
comptime {
    if (@offsetOf(d3.Transform, "rotation") != 12 or @sizeOf(@FieldType(d3.Transform, "rotation")) != 16) @compileError("v6 Transform.rotation layout");
}
comptime {
    if (@offsetOf(d3.Transform, "scale") != 28 or @sizeOf(@FieldType(d3.Transform, "scale")) != 12) @compileError("v6 Transform.scale layout");
}
comptime {
    if (@sizeOf(d3.Pose3D) != 28) @compileError("v6 Pose3D size");
}
comptime {
    if (@offsetOf(d3.Pose3D, "position") != 0 or @sizeOf(@FieldType(d3.Pose3D, "position")) != 12) @compileError("v6 Pose3D.position layout");
}
comptime {
    if (@offsetOf(d3.Pose3D, "rotation") != 12 or @sizeOf(@FieldType(d3.Pose3D, "rotation")) != 16) @compileError("v6 Pose3D.rotation layout");
}
comptime {
    if (@sizeOf(d3.Camera3D) != 48) @compileError("v6 Camera3D size");
}
comptime {
    if (@offsetOf(d3.Camera3D, "position") != 0 or @sizeOf(@FieldType(d3.Camera3D, "position")) != 12) @compileError("v6 Camera3D.position layout");
}
comptime {
    if (@offsetOf(d3.Camera3D, "rotation") != 12 or @sizeOf(@FieldType(d3.Camera3D, "rotation")) != 16) @compileError("v6 Camera3D.rotation layout");
}
comptime {
    if (@offsetOf(d3.Camera3D, "fov_y") != 28 or @sizeOf(@FieldType(d3.Camera3D, "fov_y")) != 4) @compileError("v6 Camera3D.fov_y layout");
}
comptime {
    if (@offsetOf(d3.Camera3D, "near") != 32 or @sizeOf(@FieldType(d3.Camera3D, "near")) != 4) @compileError("v6 Camera3D.near layout");
}
comptime {
    if (@offsetOf(d3.Camera3D, "far") != 36 or @sizeOf(@FieldType(d3.Camera3D, "far")) != 4) @compileError("v6 Camera3D.far layout");
}
comptime {
    if (@offsetOf(d3.Camera3D, "width") != 40 or @sizeOf(@FieldType(d3.Camera3D, "width")) != 4) @compileError("v6 Camera3D.width layout");
}
comptime {
    if (@offsetOf(d3.Camera3D, "height") != 44 or @sizeOf(@FieldType(d3.Camera3D, "height")) != 4) @compileError("v6 Camera3D.height layout");
}
comptime {
    if (@sizeOf(d3.Light3D) != 64) @compileError("v6 Light3D size");
}
comptime {
    if (@offsetOf(d3.Light3D, "kind") != 0 or @sizeOf(@FieldType(d3.Light3D, "kind")) != 4) @compileError("v6 Light3D.kind layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "color") != 4 or @sizeOf(@FieldType(d3.Light3D, "color")) != 12) @compileError("v6 Light3D.color layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "intensity") != 16 or @sizeOf(@FieldType(d3.Light3D, "intensity")) != 4) @compileError("v6 Light3D.intensity layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "range") != 20 or @sizeOf(@FieldType(d3.Light3D, "range")) != 4) @compileError("v6 Light3D.range layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "inner_cone") != 24 or @sizeOf(@FieldType(d3.Light3D, "inner_cone")) != 4) @compileError("v6 Light3D.inner_cone layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "outer_cone") != 28 or @sizeOf(@FieldType(d3.Light3D, "outer_cone")) != 4) @compileError("v6 Light3D.outer_cone layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "position") != 32 or @sizeOf(@FieldType(d3.Light3D, "position")) != 12) @compileError("v6 Light3D.position layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "rotation") != 44 or @sizeOf(@FieldType(d3.Light3D, "rotation")) != 16) @compileError("v6 Light3D.rotation layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "casts_shadow") != 60 or @sizeOf(@FieldType(d3.Light3D, "casts_shadow")) != 1) @compileError("v6 Light3D.casts_shadow layout");
}
comptime {
    if (@offsetOf(d3.Light3D, "reserved") != 61 or @sizeOf(@FieldType(d3.Light3D, "reserved")) != 3) @compileError("v6 Light3D.reserved layout");
}
comptime {
    if (@sizeOf(d3.Shape3D) != 24) @compileError("v6 Shape3D size");
}
comptime {
    if (@offsetOf(d3.Shape3D, "kind") != 0 or @sizeOf(@FieldType(d3.Shape3D, "kind")) != 4) @compileError("v6 Shape3D.kind layout");
}
comptime {
    if (@offsetOf(d3.Shape3D, "radius") != 4 or @sizeOf(@FieldType(d3.Shape3D, "radius")) != 4) @compileError("v6 Shape3D.radius layout");
}
comptime {
    if (@offsetOf(d3.Shape3D, "half_height") != 8 or @sizeOf(@FieldType(d3.Shape3D, "half_height")) != 4) @compileError("v6 Shape3D.half_height layout");
}
comptime {
    if (@offsetOf(d3.Shape3D, "half_extents") != 12 or @sizeOf(@FieldType(d3.Shape3D, "half_extents")) != 12) @compileError("v6 Shape3D.half_extents layout");
}
comptime {
    if (@sizeOf(d3.Filter3D) != 16) @compileError("v6 Filter3D size");
}
comptime {
    if (@offsetOf(d3.Filter3D, "mask") != 0 or @sizeOf(@FieldType(d3.Filter3D, "mask")) != 4) @compileError("v6 Filter3D.mask layout");
}
comptime {
    if (@offsetOf(d3.Filter3D, "reserved") != 4 or @sizeOf(@FieldType(d3.Filter3D, "reserved")) != 4) @compileError("v6 Filter3D.reserved layout");
}
comptime {
    if (@offsetOf(d3.Filter3D, "ignore") != 8 or @sizeOf(@FieldType(d3.Filter3D, "ignore")) != 8) @compileError("v6 Filter3D.ignore layout");
}
comptime {
    if (@sizeOf(d3.Body3DDesc) != 72) @compileError("v6 Body3DDesc size");
}
comptime {
    if (@offsetOf(d3.Body3DDesc, "shape") != 0 or @sizeOf(@FieldType(d3.Body3DDesc, "shape")) != 24) @compileError("v6 Body3DDesc.shape layout");
}
comptime {
    if (@offsetOf(d3.Body3DDesc, "pose") != 24 or @sizeOf(@FieldType(d3.Body3DDesc, "pose")) != 28) @compileError("v6 Body3DDesc.pose layout");
}
comptime {
    if (@offsetOf(d3.Body3DDesc, "kind") != 52 or @sizeOf(@FieldType(d3.Body3DDesc, "kind")) != 4) @compileError("v6 Body3DDesc.kind layout");
}
comptime {
    if (@offsetOf(d3.Body3DDesc, "layer") != 56 or @sizeOf(@FieldType(d3.Body3DDesc, "layer")) != 4) @compileError("v6 Body3DDesc.layer layout");
}
comptime {
    if (@offsetOf(d3.Body3DDesc, "mask") != 60 or @sizeOf(@FieldType(d3.Body3DDesc, "mask")) != 4) @compileError("v6 Body3DDesc.mask layout");
}
comptime {
    if (@offsetOf(d3.Body3DDesc, "user") != 64 or @sizeOf(@FieldType(d3.Body3DDesc, "user")) != 8) @compileError("v6 Body3DDesc.user layout");
}
comptime {
    if (@sizeOf(d3.RayHit3D) != 64) @compileError("v6 RayHit3D size");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "distance") != 0 or @sizeOf(@FieldType(d3.RayHit3D, "distance")) != 4) @compileError("v6 RayHit3D.distance layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "point") != 4 or @sizeOf(@FieldType(d3.RayHit3D, "point")) != 12) @compileError("v6 RayHit3D.point layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "normal") != 16 or @sizeOf(@FieldType(d3.RayHit3D, "normal")) != 12) @compileError("v6 RayHit3D.normal layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "surface_normal") != 28 or @sizeOf(@FieldType(d3.RayHit3D, "surface_normal")) != 12) @compileError("v6 RayHit3D.surface_normal layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "body") != 40 or @sizeOf(@FieldType(d3.RayHit3D, "body")) != 8) @compileError("v6 RayHit3D.body layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "user") != 48 or @sizeOf(@FieldType(d3.RayHit3D, "user")) != 8) @compileError("v6 RayHit3D.user layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "triangle") != 56 or @sizeOf(@FieldType(d3.RayHit3D, "triangle")) != 4) @compileError("v6 RayHit3D.triangle layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "started_inside") != 60 or @sizeOf(@FieldType(d3.RayHit3D, "started_inside")) != 1) @compileError("v6 RayHit3D.started_inside layout");
}
comptime {
    if (@offsetOf(d3.RayHit3D, "reserved") != 61 or @sizeOf(@FieldType(d3.RayHit3D, "reserved")) != 3) @compileError("v6 RayHit3D.reserved layout");
}
comptime {
    if (@sizeOf(d3.Hit3D) != 64) @compileError("v6 Hit3D size");
}
comptime {
    if (@offsetOf(d3.Hit3D, "fraction") != 0 or @sizeOf(@FieldType(d3.Hit3D, "fraction")) != 4) @compileError("v6 Hit3D.fraction layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "point") != 4 or @sizeOf(@FieldType(d3.Hit3D, "point")) != 12) @compileError("v6 Hit3D.point layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "normal") != 16 or @sizeOf(@FieldType(d3.Hit3D, "normal")) != 12) @compileError("v6 Hit3D.normal layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "surface_normal") != 28 or @sizeOf(@FieldType(d3.Hit3D, "surface_normal")) != 12) @compileError("v6 Hit3D.surface_normal layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "body") != 40 or @sizeOf(@FieldType(d3.Hit3D, "body")) != 8) @compileError("v6 Hit3D.body layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "user") != 48 or @sizeOf(@FieldType(d3.Hit3D, "user")) != 8) @compileError("v6 Hit3D.user layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "triangle") != 56 or @sizeOf(@FieldType(d3.Hit3D, "triangle")) != 4) @compileError("v6 Hit3D.triangle layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "started_inside") != 60 or @sizeOf(@FieldType(d3.Hit3D, "started_inside")) != 1) @compileError("v6 Hit3D.started_inside layout");
}
comptime {
    if (@offsetOf(d3.Hit3D, "reserved") != 61 or @sizeOf(@FieldType(d3.Hit3D, "reserved")) != 3) @compileError("v6 Hit3D.reserved layout");
}
comptime {
    if (@sizeOf(d3.Overlap3D) != 24) @compileError("v6 Overlap3D size");
}
comptime {
    if (@offsetOf(d3.Overlap3D, "body") != 0 or @sizeOf(@FieldType(d3.Overlap3D, "body")) != 8) @compileError("v6 Overlap3D.body layout");
}
comptime {
    if (@offsetOf(d3.Overlap3D, "user") != 8 or @sizeOf(@FieldType(d3.Overlap3D, "user")) != 8) @compileError("v6 Overlap3D.user layout");
}
comptime {
    if (@offsetOf(d3.Overlap3D, "triangle") != 16 or @sizeOf(@FieldType(d3.Overlap3D, "triangle")) != 4) @compileError("v6 Overlap3D.triangle layout");
}
comptime {
    if (@offsetOf(d3.Overlap3D, "reserved") != 20 or @sizeOf(@FieldType(d3.Overlap3D, "reserved")) != 4) @compileError("v6 Overlap3D.reserved layout");
}
comptime {
    if (@sizeOf(d3.CharacterConfig) != 32) @compileError("v6 CharacterConfig size");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "radius") != 0 or @sizeOf(@FieldType(d3.CharacterConfig, "radius")) != 4) @compileError("v6 CharacterConfig.radius layout");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "height") != 4 or @sizeOf(@FieldType(d3.CharacterConfig, "height")) != 4) @compileError("v6 CharacterConfig.height layout");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "max_slope") != 8 or @sizeOf(@FieldType(d3.CharacterConfig, "max_slope")) != 4) @compileError("v6 CharacterConfig.max_slope layout");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "step_height") != 12 or @sizeOf(@FieldType(d3.CharacterConfig, "step_height")) != 4) @compileError("v6 CharacterConfig.step_height layout");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "snap_distance") != 16 or @sizeOf(@FieldType(d3.CharacterConfig, "snap_distance")) != 4) @compileError("v6 CharacterConfig.snap_distance layout");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "max_move") != 20 or @sizeOf(@FieldType(d3.CharacterConfig, "max_move")) != 4) @compileError("v6 CharacterConfig.max_move layout");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "layer") != 24 or @sizeOf(@FieldType(d3.CharacterConfig, "layer")) != 4) @compileError("v6 CharacterConfig.layer layout");
}
comptime {
    if (@offsetOf(d3.CharacterConfig, "mask") != 28 or @sizeOf(@FieldType(d3.CharacterConfig, "mask")) != 4) @compileError("v6 CharacterConfig.mask layout");
}
comptime {
    if (@sizeOf(d3.CharacterMove) != 64) @compileError("v6 CharacterMove size");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "feet") != 0 or @sizeOf(@FieldType(d3.CharacterMove, "feet")) != 12) @compileError("v6 CharacterMove.feet layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "ground_normal") != 12 or @sizeOf(@FieldType(d3.CharacterMove, "ground_normal")) != 12) @compileError("v6 CharacterMove.ground_normal layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "ground_body") != 24 or @sizeOf(@FieldType(d3.CharacterMove, "ground_body")) != 8) @compileError("v6 CharacterMove.ground_body layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "ground_user") != 32 or @sizeOf(@FieldType(d3.CharacterMove, "ground_user")) != 8) @compileError("v6 CharacterMove.ground_user layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "ground_triangle") != 40 or @sizeOf(@FieldType(d3.CharacterMove, "ground_triangle")) != 4) @compileError("v6 CharacterMove.ground_triangle layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "walls") != 44 or @sizeOf(@FieldType(d3.CharacterMove, "walls")) != 4) @compileError("v6 CharacterMove.walls layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "stepped") != 48 or @sizeOf(@FieldType(d3.CharacterMove, "stepped")) != 4) @compileError("v6 CharacterMove.stepped layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "grounded") != 52 or @sizeOf(@FieldType(d3.CharacterMove, "grounded")) != 1) @compileError("v6 CharacterMove.grounded layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "ceiling") != 53 or @sizeOf(@FieldType(d3.CharacterMove, "ceiling")) != 1) @compileError("v6 CharacterMove.ceiling layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "snapped") != 54 or @sizeOf(@FieldType(d3.CharacterMove, "snapped")) != 1) @compileError("v6 CharacterMove.snapped layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "depenetrated") != 55 or @sizeOf(@FieldType(d3.CharacterMove, "depenetrated")) != 1) @compileError("v6 CharacterMove.depenetrated layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "stuck") != 56 or @sizeOf(@FieldType(d3.CharacterMove, "stuck")) != 1) @compileError("v6 CharacterMove.stuck layout");
}
comptime {
    if (@offsetOf(d3.CharacterMove, "reserved") != 57 or @sizeOf(@FieldType(d3.CharacterMove, "reserved")) != 7) @compileError("v6 CharacterMove.reserved layout");
}
comptime {
    if (@sizeOf(d3.Instance) != 8 or @offsetOf(d3.Instance, "bits") != 0) @compileError("v6 handle layout");
}
comptime {
    if (@sizeOf(d3.Light) != 8 or @offsetOf(d3.Light, "bits") != 0) @compileError("v6 handle layout");
}
comptime {
    if (@sizeOf(d3.Body3D) != 8 or @offsetOf(d3.Body3D, "bits") != 0) @compileError("v6 handle layout");
}
comptime {
    if (@sizeOf(d3.Character) != 8 or @offsetOf(d3.Character, "bits") != 0) @compileError("v6 handle layout");
}
extern fn foundry_agreement_api_v6_size() u64;
extern fn foundry_agreement_api_v6_offset(u64) u64;
test "v6 header and Zig tails agree; every previous offset is unchanged" {
    @setEvalBranchQuota(30000);
    try testing.expectEqual(@as(u64, @sizeOf(api.Api_v6)), foundry_agreement_api_v6_size());
    inline for (@typeInfo(api.Api_v5).@"struct".fields) |f| {
        try testing.expectEqual(@offsetOf(api.Api_v5, f.name), @offsetOf(api.Api_v6, f.name));
    }
    const tail = @typeInfo(api.Api_v6).@"struct".fields[@typeInfo(api.Api_v5).@"struct".fields.len..];
    try testing.expectEqual(@as(usize, 28), tail.len);
    var at = std.mem.indexOf(u8, header, "typedef struct FoundryApi_v6 {").?;
    inline for (@typeInfo(api.Api_v6).@"struct".fields) |f| {
        if (comptime @typeInfo(f.type) == .pointer) {
            at = std.mem.indexOfPos(u8, header, at, "*" ++ f.name ++ ")") orelse return error.TestUnexpectedResult;
        }
    }
    inline for (tail, 0..) |f, i| {
        try testing.expectEqual(@as(u64, @offsetOf(api.Api_v6, f.name)), foundry_agreement_api_v6_offset(i));
    }
}

/// **The header, as a build input.**
///
/// Not decoration: `agreement.c`'s object is cached against the C file, and a change to
/// `foundry.h` *alone* left that cache warm — so the one edit the agreement exists to catch
/// was the one edit that did not re-run it. Embedding the header here makes it an input of
/// this Zig module, whose recompilation does re-run the C half.
///
/// The two assertions below are what stop this from being an unexplained `@embedFile`: they
/// read the numbers out of the text and check them against the ones the engine publishes.
const header = @embedFile("foundry.h");

test "the header declares the version and the entry points this build publishes" {
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION_1 1u") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION_2 2u") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION_3 3u") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION_4 4u") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION_5 5u") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION_6 6u") != null);
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION FOUNDRY_API_VERSION_6") != null);
    try testing.expect(std.mem.indexOf(u8, header, types.init_symbol) != null);
    try testing.expect(std.mem.indexOf(u8, header, types.shutdown_symbol) != null);
}

test "no parameter in the header is a name C++ cannot compile" {
    // A parameter name is documentation rather than ABI, which is what makes this cheap to
    // obey and easy to break: `world_spawn(FoundryContentId template, ...)` compiled as C
    // for as long as nobody tried it from C++, and mods get written in C++.
    //
    // Only the keywords C++ has and C does not — a C keyword here would already have failed
    // `agreement.c`. Names are checked where they appear as parameters, so a keyword inside
    // a comment or a type is not a false alarm.
    const cxx_only = [_][]const u8{
        "and",       "and_eq",       "asm",       "bitand",     "bitor",
        "bool",      "catch",        "class",     "compl",      "concept",
        "consteval", "constexpr",    "constinit", "const_cast", "decltype",
        "delete",    "dynamic_cast", "explicit",  "export",     "false",
        "friend",    "mutable",      "namespace", "new",        "noexcept",
        "not",       "not_eq",       "nullptr",   "operator",   "or",
        "or_eq",     "private",      "protected", "public",     "reinterpret_cast",
        "requires",  "static_cast",  "template",  "this",       "throw",
        "true",      "try",          "typeid",    "typename",   "using",
        "virtual",   "wchar_t",      "xor",       "xor_eq",
    };

    for (cxx_only) |word| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, header, at, word)) |found| {
            at = found + word.len;
            // A parameter is preceded by a space and followed by `,` or `)`.
            if (found == 0 or at >= header.len) continue;
            if (header[found - 1] != ' ') continue;
            if (header[at] != ',' and header[at] != ')') continue;
            std.debug.print(
                "the header uses '{s}' as a parameter name, which C++ cannot compile\n",
                .{word},
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "the header names every table entry, in the table's own order" {
    @setEvalBranchQuota(64 * @typeInfo(api.Api_v1).@"struct".fields.len);

    // A weaker check than `agreement.c`'s offsets and a differently-shaped one: that walks
    // the compiled struct, this walks the text a mod author actually reads. A member added
    // to one and not the other fails here first, and says which name is missing.
    var at: usize = std.mem.indexOf(u8, header, "typedef struct FoundryApi_v1 {").?;
    inline for (@typeInfo(api.Api_v1).@"struct".fields) |field| {
        // `version` and `size` are plain integers; every other member is a call, and a call
        // is spelled `(*name)` in C.
        if (comptime @typeInfo(field.type) == .pointer) {
            const spelled = "*" ++ field.name ++ ")";
            const found = std.mem.indexOfPos(u8, header, at, spelled) orelse {
                std.debug.print(
                    "the header does not declare '{s}' after the entry before it\n",
                    .{field.name},
                );
                return error.TestUnexpectedResult;
            };
            at = found;
        }
    }

    @setEvalBranchQuota(64 * @typeInfo(api.Api_v2).@"struct".fields.len);
    at = std.mem.indexOf(u8, header, "typedef struct FoundryApi_v2 {").?;
    inline for (@typeInfo(api.Api_v2).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .pointer) {
            const spelled = "*" ++ field.name ++ ")";
            const found = std.mem.indexOfPos(u8, header, at, spelled) orelse {
                std.debug.print(
                    "the v2 header does not declare '{s}' after the entry before it\n",
                    .{field.name},
                );
                return error.TestUnexpectedResult;
            };
            at = found;
        }
    }

    @setEvalBranchQuota(64 * @typeInfo(api.Api_v3).@"struct".fields.len);
    at = std.mem.indexOf(u8, header, "typedef struct FoundryApi_v3 {").?;
    inline for (@typeInfo(api.Api_v3).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .pointer) {
            const spelled = "*" ++ field.name ++ ")";
            const found = std.mem.indexOfPos(u8, header, at, spelled) orelse {
                std.debug.print(
                    "the v3 header does not declare '{s}' after the entry before it\n",
                    .{field.name},
                );
                return error.TestUnexpectedResult;
            };
            at = found;
        }
    }

    @setEvalBranchQuota(64 * @typeInfo(api.Api_v4).@"struct".fields.len);
    at = std.mem.indexOf(u8, header, "typedef struct FoundryApi_v4 {").?;
    inline for (@typeInfo(api.Api_v4).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .pointer) {
            const spelled = "*" ++ field.name ++ ")";
            const found = std.mem.indexOfPos(u8, header, at, spelled) orelse {
                std.debug.print(
                    "the v4 header does not declare '{s}' after the entry before it\n",
                    .{field.name},
                );
                return error.TestUnexpectedResult;
            };
            at = found;
        }
    }

    @setEvalBranchQuota(64 * @typeInfo(api.Api_v5).@"struct".fields.len);
    at = std.mem.indexOf(u8, header, "typedef struct FoundryApi_v5 {").?;
    inline for (@typeInfo(api.Api_v5).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .pointer) {
            const spelled = "*" ++ field.name ++ ")";
            const found = std.mem.indexOfPos(u8, header, at, spelled) orelse {
                std.debug.print(
                    "the v5 header does not declare '{s}' after the entry before it\n",
                    .{field.name},
                );
                return error.TestUnexpectedResult;
            };
            at = found;
        }
    }
}

// `agreement.c`, which the build attaches to this module. Referenced only from tests, so a
// build of `abi` that is not a test never needs the object at all.
extern fn foundry_agreement_content_id(bytes: ?*const anyopaque, len: usize) u64;
extern fn foundry_agreement_schema_id(bytes: ?*const anyopaque, len: usize) u64;
extern fn foundry_agreement_str_len(s: types.Str) u64;
extern fn foundry_agreement_str_byte(s: types.Str, index: u64) u8;
extern fn foundry_agreement_entity_bits(entity: types.Entity) u64;
extern fn foundry_agreement_entity_from_bits(bits: u64) types.Entity;
extern fn foundry_agreement_cursor_begin() types.Cursor;
extern fn foundry_agreement_api_v1_size() u64;
extern fn foundry_agreement_api_v1_count() u64;
extern fn foundry_agreement_api_v1_offset(index: u64) u64;
extern fn foundry_agreement_api_v1_name(index: u64) ?[*:0]const u8;
extern fn foundry_agreement_api_v2_size() u64;
extern fn foundry_agreement_api_v2_count() u64;
extern fn foundry_agreement_api_v2_offset(index: u64) u64;
extern fn foundry_agreement_api_v2_name(index: u64) ?[*:0]const u8;
extern fn foundry_agreement_api_v3_size() u64;
extern fn foundry_agreement_api_v3_count() u64;
extern fn foundry_agreement_api_v3_offset(index: u64) u64;
extern fn foundry_agreement_api_v3_name(index: u64) ?[*:0]const u8;
extern fn foundry_agreement_api_v4_size() u64;
extern fn foundry_agreement_api_v4_count() u64;
extern fn foundry_agreement_api_v4_offset(index: u64) u64;
extern fn foundry_agreement_api_v4_name(index: u64) ?[*:0]const u8;
extern fn foundry_agreement_api_v5_size() u64;
extern fn foundry_agreement_api_v5_count() u64;
extern fn foundry_agreement_api_v5_offset(index: u64) u64;
extern fn foundry_agreement_api_v5_name(index: u64) ?[*:0]const u8;

test "the scalars are the widths the header states" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(types.Result));
    try testing.expectEqual(@as(usize, 1), @sizeOf(types.Bool));
    try testing.expectEqual(i32, @typeInfo(types.Result).@"enum".tag_type);
}

test "FoundryStr is sixteen bytes, pointer first" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(types.Str));
    try testing.expectEqual(@as(usize, 8), @alignOf(types.Str));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.Str, "ptr"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.Str, "len"));
}

test "FoundryContentId is eight bytes of hash" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.ContentId));
    try testing.expectEqual(@as(usize, 8), @alignOf(types.ContentId));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.ContentId, "hash"));
}

test "every handle kind is eight opaque bytes" {
    inline for (.{
        types.Mod,        types.Package,   types.Schema,        types.Record,
        types.Asset,      types.Entity,    types.ComponentType, types.Texture,
        types.View,       types.Voice,     types.Body,          types.Grid,
        types.Theme,      types.Workspace, types.Document,      types.SourceNode,
        types.SchemaNode, types.Build,
    }) |Handle| {
        try testing.expectEqual(@as(usize, 8), @sizeOf(Handle));
        try testing.expectEqual(@as(usize, 8), @alignOf(Handle));
        try testing.expectEqual(@as(usize, 0), @offsetOf(Handle, "bits"));
    }
}

test "FoundryCursor is eight bytes of position" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.Cursor));
    try testing.expectEqual(@as(usize, 8), @alignOf(types.Cursor));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.Cursor, "bits"));
}

test "the header's hash is the engine's hash" {
    // The vectors `core` pins, asked of the header instead. If these ever disagree, every
    // compiled package and every save written by a tool that used the header is wrong, and
    // it would be wrong invisibly — the ids would merely fail to match.
    const vectors = [_][]const u8{
        "",
        "a",
        "foobar",
        "foundry:item.torch",
        "foundry:core",
        "sandbox:content",
        // Non-ASCII, because the specification says "the exact UTF-8 bytes" and a hash that
        // treated a byte as signed would agree on everything above and nothing here.
        "foundry:café.münze",
    };

    for (vectors) |v| {
        const from_header = foundry_agreement_content_id(v.ptr, v.len);
        try testing.expectEqual(core.ContentId.fromString(v).hash, from_header);

        // The other identifier space, which is the same algorithm over the same bytes into
        // a different C type. A mod naming its own schema has no other way to compute one,
        // so this drifting would break registration and nothing else would say why.
        const schema_from_header = foundry_agreement_schema_id(v.ptr, v.len);
        try testing.expectEqual(data.SchemaId.fromStringUnchecked(v).hash, schema_from_header);
    }

    // And the empty case, where a mod may legitimately pass a null pointer.
    try testing.expectEqual(core.ContentId.fromString("").hash, foundry_agreement_content_id(null, 0));
}

test "a string built in Zig is the same bytes in C" {
    const message = "the crossing is a cast";
    const s = types.Str.from(message);

    try testing.expectEqual(@as(u64, message.len), foundry_agreement_str_len(s));
    for (message, 0..) |byte, i| {
        try testing.expectEqual(byte, foundry_agreement_str_byte(s, i));
    }
}

test "a handle survives being passed by value in both directions" {
    const Thing = struct {};
    const handle: core.Handle(Thing) = .{ .index = 12345, .generation = 678 };

    const out = types.Entity.wrap(handle);
    try testing.expectEqual(out.bits, foundry_agreement_entity_bits(out));

    const back = foundry_agreement_entity_from_bits(out.bits);
    try testing.expect(handle.eql(back.unwrap(core.Handle(Thing))));

    try testing.expect(foundry_agreement_entity_from_bits(0).isNone());
}

test "the header's cursor initialiser is the engine's begin" {
    try testing.expectEqual(types.Cursor.begin.bits, foundry_agreement_cursor_begin().bits);
    try testing.expect(foundry_agreement_cursor_begin().isBegin());
}

test "the enumerations are the numbers the header states" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(types.LogLevel));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(types.LogLevel.err));
    try testing.expectEqual(@as(i32, 4), @intFromEnum(types.LogLevel.trace));

    try testing.expectEqual(@as(usize, 4), @sizeOf(types.FieldType));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(types.FieldType.bool));
    try testing.expectEqual(@as(i32, 7), @intFromEnum(types.FieldType.string));
    try testing.expectEqual(@as(i32, 8), @intFromEnum(types.FieldType.id));
    try testing.expectEqual(@as(i32, 10), @intFromEnum(types.FieldType.nested));

    // Every field type `data` can describe has a number here. Adding one to the union
    // without publishing it would otherwise be discovered by a mod.
    inline for (@typeInfo(@import("data").FieldType).@"union".fields) |f| {
        _ = std.meta.stringToEnum(types.FieldType, f.name) orelse {
            std.debug.print("data.FieldType.{s} has no number at the boundary\n", .{f.name});
            return error.TestUnexpectedResult;
        };
    }
}

test "FoundryLogRecord and FoundryMemoryStats are the shapes the header states" {
    try testing.expectEqual(@as(usize, 56), @sizeOf(types.LogRecord));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.LogRecord, "level"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(types.LogRecord, "reserved"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.LogRecord, "frame"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(types.LogRecord, "sequence"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(types.LogRecord, "scope"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(types.LogRecord, "text"));

    try testing.expectEqual(@as(usize, 40), @sizeOf(types.MemoryStats));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.MemoryStats, "live_bytes"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(types.MemoryStats, "failures"));

    try testing.expectEqual(@as(usize, 8), @sizeOf(types.MemoryCounter));
}

test "the v3 mod and UI values are the shapes the header states" {
    try testing.expectEqual(@as(usize, 120), @sizeOf(mod_types.Info));
    try testing.expectEqual(@as(usize, 8), @offsetOf(mod_types.Info, "id_name"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(mod_types.Info, "license"));
    try testing.expectEqual(@as(usize, 60), @offsetOf(mod_types.Info, "origin"));
    try testing.expectEqual(@as(usize, 68), @offsetOf(mod_types.Info, "pending_index"));
    try testing.expectEqual(@as(usize, 80), @offsetOf(mod_types.Info, "skip_other"));
    try testing.expectEqual(@as(usize, 104), @offsetOf(mod_types.Info, "provides"));
    try testing.expectEqual(@as(usize, 116), @offsetOf(mod_types.Info, "loaded"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(mod_types.Pending));
    try testing.expectEqual(@as(usize, 24), @offsetOf(mod_types.Pending, "installed"));
    try testing.expectEqual(@as(usize, 40), @sizeOf(mod_types.Requirement));
    try testing.expectEqual(@as(usize, 28), @offsetOf(mod_types.Requirement, "max_version"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(mod_types.Requirement, "satisfied"));
    try testing.expectEqual(@as(usize, 40), @sizeOf(mod_types.Conflict));
    try testing.expectEqual(@as(usize, 24), @offsetOf(mod_types.Conflict, "winner"));
    try testing.expectEqual(@as(usize, 16), @sizeOf(mod_types.Provider));
    try testing.expectEqual(@as(usize, 32), @sizeOf(mod_types.Profile));
    try testing.expectEqual(@as(usize, 12), @sizeOf(mod_types.ProfileState));
    try testing.expectEqual(@as(usize, 16), @sizeOf(ui_types.ImageSource));
    try testing.expectEqual(@as(usize, 12), @sizeOf(ui_types.ReorderMove));
}

test "the scene descriptors are the shapes the header states" {
    // Widths beside offsets, for step 2's reason: `alignment` narrowing to `u16` moves no
    // offset around it, because `ctx` is eight-aligned and the padding absorbs the change.
    try testing.expectEqual(@as(usize, 16), @sizeOf(types.Step));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.Step, "tick"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.Step, "delta_ns"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.Step, "tick")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.Step, "delta_ns")));

    try testing.expectEqual(@as(usize, 56), @sizeOf(types.ComponentDesc));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.ComponentDesc, "schema"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.ComponentDesc, "name"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(types.ComponentDesc, "size"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(types.ComponentDesc, "alignment"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(types.ComponentDesc, "ctx"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(types.ComponentDesc, "construct"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(types.ComponentDesc, "destruct"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "schema")));
    try testing.expectEqual(@as(usize, 16), @sizeOf(@FieldType(types.ComponentDesc, "name")));
    try testing.expectEqual(@as(usize, 4), @sizeOf(@FieldType(types.ComponentDesc, "size")));
    try testing.expectEqual(@as(usize, 4), @sizeOf(@FieldType(types.ComponentDesc, "alignment")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "ctx")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "construct")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "destruct")));

    try testing.expectEqual(@as(usize, 40), @sizeOf(types.SystemDesc));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.SystemDesc, "id"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.SystemDesc, "name"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(types.SystemDesc, "ctx"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(types.SystemDesc, "update"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.SystemDesc, "id")));
    try testing.expectEqual(@as(usize, 16), @sizeOf(@FieldType(types.SystemDesc, "name")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.SystemDesc, "ctx")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.SystemDesc, "update")));
}

test "the table has the same members, in the same places, in both languages" {
    const fields = @typeInfo(api.Api_v1).@"struct".fields;

    // A capability in one and not the other is a different count, which is the cheap half.
    try testing.expectEqual(@as(u64, fields.len), foundry_agreement_api_v1_count());
    try testing.expectEqual(@as(u64, @sizeOf(api.Api_v1)), foundry_agreement_api_v1_size());

    // The expensive half: every member is where the other language thinks it is. Every entry
    // is eight bytes wide, so two swapped in the header keep the same *set* of offsets —
    // comparing them position by position is what makes a reordering fail rather than pass.
    inline for (fields, 0..) |field, i| {
        const from_header = foundry_agreement_api_v1_offset(i);
        testing.expectEqual(@as(u64, @offsetOf(api.Api_v1, field.name)), from_header) catch |err| {
            std.debug.print(
                "the table disagrees about '{s}': Zig puts it at {d}, the header at {d}\n",
                .{ field.name, @offsetOf(api.Api_v1, field.name), from_header },
            );
            return err;
        };

        const spelled = foundry_agreement_api_v1_name(i) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(field.name, std.mem.span(spelled));
    }

    // Out of range is answered rather than read past, in the file whose whole subject is
    // what happens when two sides disagree about a length.
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), foundry_agreement_api_v1_offset(fields.len));
    try testing.expectEqual(@as(?[*:0]const u8, null), foundry_agreement_api_v1_name(fields.len));
}

test "the additive v2 table has the same members, in the same places, in both languages" {
    const fields = @typeInfo(api.Api_v2).@"struct".fields;

    try testing.expectEqual(@as(u64, fields.len), foundry_agreement_api_v2_count());
    try testing.expectEqual(@as(u64, @sizeOf(api.Api_v2)), foundry_agreement_api_v2_size());

    inline for (fields, 0..) |field, i| {
        const from_header = foundry_agreement_api_v2_offset(i);
        testing.expectEqual(@as(u64, @offsetOf(api.Api_v2, field.name)), from_header) catch |err| {
            std.debug.print(
                "the v2 table disagrees about '{s}': Zig puts it at {d}, the header at {d}\n",
                .{ field.name, @offsetOf(api.Api_v2, field.name), from_header },
            );
            return err;
        };

        const spelled = foundry_agreement_api_v2_name(i) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(field.name, std.mem.span(spelled));
    }

    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), foundry_agreement_api_v2_offset(fields.len));
    try testing.expectEqual(@as(?[*:0]const u8, null), foundry_agreement_api_v2_name(fields.len));
}

test "the additive v3 table has the same members, in the same places, in both languages" {
    const fields = @typeInfo(api.Api_v3).@"struct".fields;

    try testing.expectEqual(@as(u64, fields.len), foundry_agreement_api_v3_count());
    try testing.expectEqual(@as(u64, @sizeOf(api.Api_v3)), foundry_agreement_api_v3_size());

    inline for (fields, 0..) |field, i| {
        const from_header = foundry_agreement_api_v3_offset(i);
        testing.expectEqual(@as(u64, @offsetOf(api.Api_v3, field.name)), from_header) catch |err| {
            std.debug.print(
                "the v3 table disagrees about '{s}': Zig puts it at {d}, the header at {d}\n",
                .{ field.name, @offsetOf(api.Api_v3, field.name), from_header },
            );
            return err;
        };

        const spelled = foundry_agreement_api_v3_name(i) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(field.name, std.mem.span(spelled));
    }

    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), foundry_agreement_api_v3_offset(fields.len));
    try testing.expectEqual(@as(?[*:0]const u8, null), foundry_agreement_api_v3_name(fields.len));
}

test "the additive v4 table has the same members, in the same places, in both languages" {
    const fields = @typeInfo(api.Api_v4).@"struct".fields;

    try testing.expectEqual(@as(u64, fields.len), foundry_agreement_api_v4_count());
    try testing.expectEqual(@as(u64, @sizeOf(api.Api_v4)), foundry_agreement_api_v4_size());

    inline for (fields, 0..) |field, i| {
        const from_header = foundry_agreement_api_v4_offset(i);
        testing.expectEqual(@as(u64, @offsetOf(api.Api_v4, field.name)), from_header) catch |err| {
            std.debug.print(
                "the v4 table disagrees about '{s}': Zig puts it at {d}, the header at {d}\n",
                .{ field.name, @offsetOf(api.Api_v4, field.name), from_header },
            );
            return err;
        };

        const spelled = foundry_agreement_api_v4_name(i) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(field.name, std.mem.span(spelled));
    }

    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), foundry_agreement_api_v4_offset(fields.len));
    try testing.expectEqual(@as(?[*:0]const u8, null), foundry_agreement_api_v4_name(fields.len));
}

test "the v4 authoring values are the shapes the header states" {
    // `author_types.zig` states the sizes as well, and `agreement.c` states them a third
    // time in C. Three statements of one contract is not redundancy here: it is what makes
    // a change land on whoever made it rather than on an editor six months later.
    try testing.expectEqual(@as(usize, 72), @sizeOf(author_types.WorkspaceInfo));
    try testing.expectEqual(@as(usize, 8), @offsetOf(author_types.WorkspaceInfo, "package_name"));
    try testing.expectEqual(@as(usize, 52), @offsetOf(author_types.WorkspaceInfo, "can_edit"));

    try testing.expectEqual(@as(usize, 64), @sizeOf(author_types.Limits));
    try testing.expectEqual(@as(usize, 40), @offsetOf(author_types.Limits, "max_history_commands"));

    try testing.expectEqual(@as(usize, 40), @sizeOf(author_types.DocumentInfo));
    try testing.expectEqual(@as(usize, 32), @offsetOf(author_types.DocumentInfo, "dirty"));

    try testing.expectEqual(@as(usize, 64), @sizeOf(author_types.NodeInfo));
    try testing.expectEqual(@as(usize, 16), @offsetOf(author_types.NodeInfo, "id"));
    try testing.expectEqual(@as(usize, 60), @offsetOf(author_types.NodeInfo, "depth"));

    try testing.expectEqual(@as(usize, 56), @sizeOf(author_types.SchemaNodeInfo));
    try testing.expectEqual(@as(usize, 48), @offsetOf(author_types.SchemaNodeInfo, "is_root"));

    try testing.expectEqual(@as(usize, 32), @sizeOf(author_types.Value));
    try testing.expectEqual(@as(usize, 8), @offsetOf(author_types.Value, "id"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(author_types.Value, "text"));

    try testing.expectEqual(@as(usize, 56), @sizeOf(author_types.PackageInfo));
    try testing.expectEqual(@as(usize, 40), @sizeOf(author_types.Edit));
    try testing.expectEqual(@as(usize, 32), @sizeOf(author_types.SaveResult));
    try testing.expectEqual(@as(usize, 24), @sizeOf(author_types.SaveAll));
    try testing.expectEqual(@as(usize, 40), @sizeOf(author_types.SaveEntry));
    try testing.expectEqual(@as(usize, 120), @sizeOf(author_types.Diagnostic));
    try testing.expectEqual(@as(usize, 112), @offsetOf(author_types.Diagnostic, "suppressed"));
    try testing.expectEqual(@as(usize, 40), @sizeOf(author_types.BuildInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(author_types.PreviewInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(author_types.ExportInfo));
}

test "the header names every authoring enumerator the engine publishes" {
    // The numbers are the contract, and the header is where a C author reads them. A
    // value added on one side and not the other is the kind of drift that compiles.
    const spellings = [_]struct { []const u8, i32 }{
        .{ "FOUNDRY_AUTHOR_REQUIRED = 0", @intFromEnum(author_types.Presence.required) },
        .{ "FOUNDRY_AUTHOR_ELEMENT = 3", @intFromEnum(author_types.Presence.element) },
        .{ "FOUNDRY_AUTHOR_ERROR = 0", @intFromEnum(author_types.Severity.err) },
        .{ "FOUNDRY_AUTHOR_NOTE = 2", @intFromEnum(author_types.Severity.note) },
        .{ "FOUNDRY_AUTHOR_ROOT_SOURCE = 0", @intFromEnum(author_types.NodeRoot.source) },
        .{ "FOUNDRY_AUTHOR_ROOT_DEFAULT = 3", @intFromEnum(author_types.NodeRoot.default) },
        .{ "FOUNDRY_AUTHOR_PREVIEW_NONE = 0", @intFromEnum(author_types.PreviewOutcome.none) },
        .{ "FOUNDRY_AUTHOR_PREVIEW_FAILED = 2", @intFromEnum(author_types.PreviewOutcome.failed) },
        .{ "FOUNDRY_AUTHOR_SAVE_UNCHANGED = 0", @intFromEnum(author_types.SaveOutcome.unchanged) },
        .{ "FOUNDRY_AUTHOR_SAVE_FAILED = 2", @intFromEnum(author_types.SaveOutcome.failed) },
        .{ "FOUNDRY_AUTHOR_SAVE_OK = 0", @intFromEnum(author_types.SaveFailure.none) },
        .{ "FOUNDRY_AUTHOR_SAVE_OUT_OF_MEMORY = 4", @intFromEnum(author_types.SaveFailure.out_of_memory) },
        .{ "FOUNDRY_AUTHOR_EXPORT_COMPILED = 0", @intFromEnum(author_types.ExportKind.compiled) },
        .{ "FOUNDRY_AUTHOR_EXPORT_RUNTIME = 1", @intFromEnum(author_types.ExportKind.runtime) },
    };
    for (spellings) |pair| {
        _ = pair[1];
        testing.expect(std.mem.indexOf(u8, header, pair[0]) != null) catch |err| {
            std.debug.print("the header does not state '{s}'\n", .{pair[0]});
            return err;
        };
    }
}

test "the additive v5 table has the same members, in the same places, in both languages" {
    const fields = @typeInfo(api.Api_v5).@"struct".fields;

    // The Step 5 Resolution froze 235 members before any was written.
    try testing.expectEqual(@as(usize, 235), fields.len);
    try testing.expectEqual(@as(u64, fields.len), foundry_agreement_api_v5_count());
    try testing.expectEqual(@as(u64, @sizeOf(api.Api_v5)), foundry_agreement_api_v5_size());

    inline for (fields, 0..) |field, i| {
        const from_header = foundry_agreement_api_v5_offset(i);
        testing.expectEqual(@as(u64, @offsetOf(api.Api_v5, field.name)), from_header) catch |err| {
            std.debug.print(
                "the v5 table disagrees about '{s}': Zig puts it at {d}, the header at {d}\n",
                .{ field.name, @offsetOf(api.Api_v5, field.name), from_header },
            );
            return err;
        };

        const spelled = foundry_agreement_api_v5_name(i) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(field.name, std.mem.span(spelled));
    }

    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), foundry_agreement_api_v5_offset(fields.len));
    try testing.expectEqual(@as(?[*:0]const u8, null), foundry_agreement_api_v5_name(fields.len));
}

test "the v5 networking values are the shapes and numbers the header states" {
    // `net_types.zig` states the sizes as well, and `agreement.c` states them a third time.
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.NetSession));
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.NetPeer));
    try testing.expectEqual(@as(usize, 4), @offsetOf(net_types.Endpoint, "port"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(net_types.GrantInfo, "endpoint"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(net_types.ChannelDesc, "delivery"));
    try testing.expectEqual(@as(usize, 30), @offsetOf(net_types.SessionInfo, "listening"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(net_types.SessionInfo, "listen_endpoint"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(net_types.PeerInfo, "epoch"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(net_types.Ending, "index"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(net_types.Event, "ending"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(net_types.Delivery, "sequence"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(net_types.Command, "number"));
    try testing.expectEqual(@as(usize, 176), @offsetOf(net_types.Stats, "bytes_sent"));

    // Every number the header defines is the one the boundary produces or accepts.
    const numbers = [_]struct { []const u8, i64 }{
        .{ "FOUNDRY_NET_SERVER", net_types.role_server },
        .{ "FOUNDRY_NET_CLIENT", net_types.role_client },
        .{ "FOUNDRY_NET_BIDIRECTIONAL", net_types.direction_bidirectional },
        .{ "FOUNDRY_NET_LATEST_STATE", net_types.delivery_latest_state },
        .{ "FOUNDRY_NET_PEER_ACTIVE", 5 },
        .{ "FOUNDRY_NET_EVENT_ENDED", net_types.event_ended },
        .{ "FOUNDRY_NET_DELIVERY_MESSAGE", net_types.delivery_kind_message },
        .{ "FOUNDRY_NET_ENDING_OVERLOADED", net_types.ending_overloaded },
        .{ "FOUNDRY_NET_DISCONNECT_APPLICATION", 6 },
        .{ "FOUNDRY_NET_REFUSAL_TIMEOUT", 9 },
        .{ "FOUNDRY_NET_DEADLINE_WRITE_STALL", 4 },
        .{ "FOUNDRY_NET_FAULT_MISMATCH", 5 },
        .{ "FOUNDRY_NET_FAILURE_CERTIFICATE_EXPIRED", 11 },
        .{ "FOUNDRY_NET_FAILURE_INTERNAL", 23 },
    };
    for (numbers) |entry| {
        var buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "#define {s} {d}\n", .{ entry[0], entry[1] });
        if (std.mem.indexOf(u8, header, line) == null) {
            std.debug.print("the header does not say '{s}'\n", .{line});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(i32, 5), net_types.peerState(.active));
    try testing.expectEqual(@as(i32, 11), net_types.failure(.certificate_expired));
    try testing.expectEqual(@as(i32, 23), net_types.failure(.internal));
}
