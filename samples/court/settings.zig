//! Bounded copies of the court's ordinary config record. No settings file until Step 4.
const std = @import("std");
const core = @import("core");
const data = @import("data");
pub const LightSettings = @import("light_settings.zig").LightSettings;
const Fields = data.fpk.Fields;
const Invalid = error{InvalidConfig};

pub const Settings = struct {
    title: []const u8,
    width: u32,
    height: u32,
    clear: [4]f32,
    level: core.ContentId,
    lighting: LightSettings,

    pub fn read(record: data.store.Record) !Settings {
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:config"))) return error.InvalidConfig;
        const f = record.fields;
        const title = (try f.stringAt(try index(f, "title"))) orelse return error.InvalidConfig;
        if (title.len == 0 or title.len > 256) return error.InvalidConfig;
        const width = try size(f, "width");
        const height = try size(f, "height");
        const level = (try f.idAt(try index(f, "level"))) orelse return error.InvalidConfig;
        if (level.isNone()) return error.InvalidConfig;
        const list = (try f.listAt(try index(f, "clear_linear"))) orelse return error.InvalidConfig;
        if (list.len != 4) return error.InvalidConfig;
        var clear: [4]f32 = undefined;
        for (&clear, 0..) |*v, i| {
            const value = (try list.floatAt(@intCast(i))) orelse return error.InvalidConfig;
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidConfig;
            v.* = @floatCast(value);
        }
        return .{ .title = title, .width = width, .height = height, .clear = clear, .level = level, .lighting = try LightSettings.read(f) };
    }
};

fn index(f: Fields, name: []const u8) Invalid!u32 {
    for (f.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidConfig;
}
fn size(f: Fields, name: []const u8) !u32 {
    const v = (try f.intAt(try index(f, name))) orelse return error.InvalidConfig;
    if (v < 320 or v > 8192) return error.InvalidConfig;
    return @intCast(v);
}
