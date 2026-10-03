//! Beacon prop and static collision for player Use raycasts.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const physics = @import("physics3d");
const render3d = @import("render3d");
const Vec3 = core.math.Vec3;
const Fields = data.fpk.Fields;

pub const beacon_layer: u32 = 1 << 1;

pub const BeaconSettings = struct {
    model: core.ContentId,
    /// Played once when the beacon lights.
    sound: core.ContentId,
    position: Vec3,
    light_color: [3]f32,
    light_intensity: f32,
    light_range: f32,
    /// Metres above `position` at which the lit beacon's light stands.
    light_height: f32,
    /// The Use ray's target: a box of these half extents standing on `position`.
    use_half: Vec3,

    pub fn read(fields: Fields) !BeaconSettings {
        const model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidBeacon;
        if (model.isNone()) return error.InvalidBeacon;
        const sound = (try fields.idAt(try index(fields, "sound"))) orelse return error.InvalidBeacon;
        if (sound.isNone()) return error.InvalidBeacon;
        const pos_fields = (try fields.nestedAt(try index(fields, "position"))) orelse return error.InvalidBeacon;
        const pos: Vec3 = .init(
            try number(pos_fields, "x"),
            try number(pos_fields, "y"),
            try number(pos_fields, "z"),
        );
        if (!physics.shape.positionValid(pos)) return error.InvalidBeacon;
        const half_fields = (try fields.nestedAt(try index(fields, "use_half"))) orelse return error.InvalidBeacon;
        const half: Vec3 = .init(
            try bounded(half_fields, "x", 0.05, 5),
            try bounded(half_fields, "y", 0.05, 5),
            try bounded(half_fields, "z", 0.05, 5),
        );
        const light_fields = (try fields.nestedAt(try index(fields, "light"))) orelse return error.InvalidBeacon;
        const color_fields = (try light_fields.nestedAt(try index(light_fields, "color"))) orelse return error.InvalidBeacon;
        const color: [3]f32 = .{
            try bounded(color_fields, "r", 0, 100),
            try bounded(color_fields, "g", 0, 100),
            try bounded(color_fields, "b", 0, 100),
        };
        const intensity = try bounded(light_fields, "intensity", 0.01, 10000);
        const range = try bounded(light_fields, "range", 0.1, 100);
        const height = try bounded(light_fields, "height", 0, 10);
        return .{
            .model = model,
            .sound = sound,
            .position = pos,
            .light_color = color,
            .light_intensity = intensity,
            .light_range = range,
            .light_height = height,
            .use_half = half,
        };
    }
};

pub const Beacon = struct {
    id: core.ContentId,
    settings: BeaconSettings,
    model: render3d.ModelHandle = .none,
    body: physics.BodyHandle = .none,
    lit: bool = false,

    /// The centre of the box the Use ray is cast against.
    pub fn useCentre(self: *const Beacon) Vec3 {
        return self.settings.position.add(.init(0, self.settings.use_half.y, 0));
    }

    pub fn lightPosition(self: *const Beacon) Vec3 {
        return self.settings.position.add(.init(0, self.settings.light_height, 0));
    }

    pub fn deinit(self: *Beacon, gpa: std.mem.Allocator, world: *physics.World, content: ?*render3d.Content) void {
        if (!self.body.isNone()) _ = world.removeBody(gpa, self.body);
        self.body = .none;
        if (content) |c| {
            if (!self.model.isNone()) c.releaseModel(self.model);
        }
        self.model = .none;
    }
};

fn index(fields: Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidBeacon;
}

fn number(fields: Fields, name: []const u8) !f32 {
    const value = (fields.floatAt(try index(fields, name)) catch return error.InvalidBeacon) orelse return error.InvalidBeacon;
    const v: f32 = @floatCast(value);
    if (!std.math.isFinite(v)) return error.InvalidBeacon;
    return v;
}

fn bounded(fields: Fields, name: []const u8, min: f32, max: f32) !f32 {
    const value = try number(fields, name);
    if (value < min or value > max) return error.InvalidBeacon;
    return value;
}
