//! Beacon prop and static collision for player Use raycasts.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const physics = @import("physics3d");
const render3d = @import("render3d");
const light_settings = @import("light_settings.zig");
const Vec3 = core.math.Vec3;
const Fields = data.fpk.Fields;

pub const beacon_layer: u32 = 1 << 1;

pub const BeaconSettings = struct {
    model: core.ContentId,
    /// Played once when the beacon lights.
    sound: core.ContentId,
    position: Vec3,
    /// The lit beacon's light, a point `foundry:light` record's (M41, ADR-0085), at the origin;
    /// whether it casts point shadows is the record's (`shadows-local.md` §12).
    light: render3d.Light,
    /// Metres above `position` at which the lit beacon's light stands.
    light_height: f32,
    /// The Use ray's target: a box of these half extents standing on `position`.
    use_half: Vec3,

    /// `store` holds the light record the beacon names.
    pub fn read(store: *const data.Store, fields: Fields) !BeaconSettings {
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
        const light_id = (try fields.idAt(try index(fields, "light"))) orelse return error.InvalidBeacon;
        const light = light_settings.lightRecord(store, light_id) catch return error.InvalidBeacon;
        // A beacon is a point of light: a sun or a cone has a direction its record cannot give.
        if (light.kind != .point) return error.InvalidBeacon;
        const height = try bounded(fields, "light_height", 0, 10);
        return .{
            .model = model,
            .sound = sound,
            .position = pos,
            .light = light,
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

    /// The lit beacon's light, where it stands.
    pub fn light(self: *const Beacon) render3d.Light {
        var out = self.settings.light;
        out.world = core.math.Mat4.translation(self.lightPosition());
        return out;
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
