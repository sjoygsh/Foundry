//! The sample's independent, bounded walk record (`collision3d.md` §10.1).
const std = @import("std");
const core = @import("core");
const data = @import("data");
const physics = @import("physics3d");
const Vec3 = core.math.Vec3;
const Fields = data.fpk.Fields;
const Invalid = error{InvalidWalk};

pub const Settings = struct {
    spawn: Vec3,
    spawn_yaw: f32,
    character: physics.CharacterConfig,
    eye_height: f32,
    walk_speed: f32,
    gravity: f32,
    jump_speed: f32,
    turn_rate: f32,
    look_rate: f32,
    collision: [max_collision]core.ContentId = @splat(.none),
    len: usize = 0,
    reach: f32,
    catch_distance: f32,
    pit_height: f32,
    exit_min: Vec3,
    exit_max: Vec3,
    pub const max_collision = 8;

    pub fn read(fields: Fields, dt: f32) Invalid!Settings {
        const spawn_fields = (fields.nestedAt(try index(fields, "spawn")) catch return error.InvalidWalk) orelse return error.InvalidWalk;
        const min_fields = (fields.nestedAt(try index(fields, "exit_min")) catch return error.InvalidWalk) orelse return error.InvalidWalk;
        const max_fields = (fields.nestedAt(try index(fields, "exit_max")) catch return error.InvalidWalk) orelse return error.InvalidWalk;
        const speed = try bounded(fields, "walk_speed", 0.01, 30);
        if (!std.math.isFinite(dt) or dt <= 0 or dt > 1) return error.InvalidWalk;
        var out: Settings = .{
            .spawn = .init(try number(spawn_fields, "x"), try number(spawn_fields, "y"), try number(spawn_fields, "z")),
            .spawn_yaw = try bounded(fields, "spawn_yaw", -2 * std.math.pi, 2 * std.math.pi),
            .character = .{
                .radius = try bounded(fields, "radius", 0.01, 10),
                .height = try bounded(fields, "height", 0.02, 20),
                .max_slope = try number(fields, "max_slope"),
                .step_height = try number(fields, "step_height"),
                .snap_distance = try number(fields, "snap_distance"),
                .max_move = @max(1, speed * dt * 4),
            },
            .eye_height = try number(fields, "eye_height"),
            .walk_speed = speed,
            .gravity = try bounded(fields, "gravity", 0.01, 100),
            .jump_speed = try bounded(fields, "jump_speed", 0.01, 30),
            .turn_rate = try bounded(fields, "turn_rate", 0.001, 20),
            .look_rate = try bounded(fields, "look_rate", 0.00001, 1),
            .reach = try bounded(fields, "reach", 0.1, 20),
            .catch_distance = try bounded(fields, "catch_distance", 0.1, 10),
            .pit_height = try bounded(fields, "pit_height", -100, 100),
            .exit_min = .init(try number(min_fields, "x"), try number(min_fields, "y"), try number(min_fields, "z")),
            .exit_max = .init(try number(max_fields, "x"), try number(max_fields, "y"), try number(max_fields, "z")),
        };
        if (!out.valid()) return error.InvalidWalk;
        const list = (fields.listAt(try index(fields, "collision")) catch return error.InvalidWalk) orelse return error.InvalidWalk;
        if (list.len == 0 or list.len > max_collision) return error.InvalidWalk;
        for (0..list.len) |n| {
            const value = (list.idAt(@intCast(n)) catch return error.InvalidWalk) orelse return error.InvalidWalk;
            if (value.isNone()) return error.InvalidWalk;
            for (out.collision[0..n]) |previous| if (previous.eql(value)) return error.InvalidWalk;
            out.collision[n] = value;
        }
        out.len = list.len;
        return out;
    }

    pub fn valid(s: Settings) bool {
        return s.character.valid() and physics.shape.positionValid(s.spawn) and
            physics.shape.positionValid(s.spawn.add(.init(0, s.character.height / 2, 0))) and
            s.eye_height > 0 and s.eye_height <= s.character.height and
            s.reach > 0 and s.catch_distance > 0 and std.math.isFinite(s.pit_height) and
            physics.shape.positionValid(s.exit_min) and physics.shape.positionValid(s.exit_max) and
            s.exit_min.x <= s.exit_max.x and s.exit_min.y <= s.exit_max.y and s.exit_min.z <= s.exit_max.z;
    }
};

fn index(fields: Fields, name: []const u8) Invalid!u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidWalk;
}
fn number(fields: Fields, name: []const u8) Invalid!f32 {
    const value = (fields.floatAt(try index(fields, name)) catch return error.InvalidWalk) orelse return error.InvalidWalk;
    const v: f32 = @floatCast(value);
    if (!std.math.isFinite(v)) return error.InvalidWalk;
    return v;
}
fn bounded(fields: Fields, name: []const u8, min: f32, max: f32) Invalid!f32 {
    const value = try number(fields, name);
    if (value < min or value > max) return error.InvalidWalk;
    return value;
}
