//! Kinematic gate that opens once all beacons are lit.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const physics = @import("physics3d");
const render3d = @import("render3d");
const Vec3 = core.math.Vec3;
const Fields = data.fpk.Fields;

pub const GateSettings = struct {
    model: core.ContentId,
    half_extents: Vec3,
    closed: Vec3,
    open: Vec3,
    travel_time: f32,

    pub fn read(fields: Fields) !GateSettings {
        const model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidGate;
        if (model.isNone()) return error.InvalidGate;
        const half_fields = (try fields.nestedAt(try index(fields, "half_extents"))) orelse return error.InvalidGate;
        const half: Vec3 = .init(
            try bounded(half_fields, "x", 0.01, 20),
            try bounded(half_fields, "y", 0.01, 20),
            try bounded(half_fields, "z", 0.01, 20),
        );
        const closed_fields = (try fields.nestedAt(try index(fields, "closed"))) orelse return error.InvalidGate;
        const open_fields = (try fields.nestedAt(try index(fields, "open"))) orelse return error.InvalidGate;
        const closed: Vec3 = .init(
            try number(closed_fields, "x"),
            try number(closed_fields, "y"),
            try number(closed_fields, "z"),
        );
        const open_pos: Vec3 = .init(
            try number(open_fields, "x"),
            try number(open_fields, "y"),
            try number(open_fields, "z"),
        );
        if (!physics.shape.positionValid(closed) or !physics.shape.positionValid(open_pos)) return error.InvalidGate;
        const travel = try bounded(fields, "travel_time", 0.05, 60);
        return .{
            .model = model,
            .half_extents = half,
            .closed = closed,
            .open = open_pos,
            .travel_time = travel,
        };
    }
};

pub const Gate = struct {
    id: core.ContentId,
    settings: GateSettings,
    model: render3d.ModelHandle = .none,
    body: physics.BodyHandle = .none,
    current_pos: Vec3,
    progress: f32 = 0,
    opening: bool = false,

    pub fn deinit(self: *Gate, gpa: std.mem.Allocator, world: *physics.World, content: ?*render3d.Content) void {
        if (!self.body.isNone()) _ = world.removeBody(gpa, self.body);
        self.body = .none;
        if (content) |c| {
            if (!self.model.isNone()) c.releaseModel(self.model);
        }
        self.model = .none;
    }

    pub fn reset(self: *Gate, gpa: std.mem.Allocator, world: *physics.World) !void {
        self.opening = false;
        self.progress = 0;
        self.current_pos = self.settings.closed;
        if (!self.body.isNone()) {
            _ = try world.setPose(gpa, self.body, .{ .position = self.settings.closed, .rotation = .identity });
        }
    }

    pub fn step(self: *Gate, gpa: std.mem.Allocator, world: *physics.World, dt: f32) !void {
        if (!self.opening or self.progress >= 1.0) return;
        self.progress = @min(1.0, self.progress + dt / self.settings.travel_time);
        self.current_pos = self.settings.closed.lerp(self.settings.open, self.progress);
        if (!self.body.isNone()) {
            _ = try world.setPose(gpa, self.body, .{ .position = self.current_pos, .rotation = .identity });
        }
    }
};

fn index(fields: Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidGate;
}

fn number(fields: Fields, name: []const u8) !f32 {
    const value = (fields.floatAt(try index(fields, name)) catch return error.InvalidGate) orelse return error.InvalidGate;
    const v: f32 = @floatCast(value);
    if (!std.math.isFinite(v)) return error.InvalidGate;
    return v;
}

fn bounded(fields: Fields, name: []const u8, min: f32, max: f32) !f32 {
    const value = try number(fields, name);
    if (value < min or value > max) return error.InvalidGate;
    return value;
}
