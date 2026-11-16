//! Bounded copies of the court's ordinary config record. The window size and the options'
//! defaults in it are read by `prefs.zig`, under the player's own file.
const std = @import("std");
const core = @import("core");
const data = @import("data");
pub const LightSettings = @import("light_settings.zig").LightSettings;
const Fields = data.fpk.Fields;
const Invalid = error{InvalidConfig};

pub const Settings = struct {
    title: []const u8,
    /// How long the goal line stays up at the start of each game.
    goal_seconds: f32,
    clear: [4]f32,
    level: core.ContentId,
    lighting: LightSettings,
    /// The frame's environment, its sky and indirect light (M41, `environment.md` §11), or none:
    /// a config that names none draws the clear colour, as before M41.
    environment: core.ContentId = .none,

    /// `store` holds the light records the config's list names.
    pub fn read(store: *const data.Store, record: data.store.Record) !Settings {
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:config"))) return error.InvalidConfig;
        const f = record.fields;
        const title = (try f.stringAt(try index(f, "title"))) orelse return error.InvalidConfig;
        if (title.len == 0 or title.len > 256) return error.InvalidConfig;
        _ = try size(f, "window_width");
        _ = try size(f, "window_height");
        const goal = (try f.floatAt(try index(f, "goal_seconds"))) orelse return error.InvalidConfig;
        if (!std.math.isFinite(goal) or goal < 0 or goal > 120) return error.InvalidConfig;
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
        // Optional, so a config written before M41 still reads; whether it names an environment
        // that loads is the renderer content's to say, as for the level.
        const environment = if (indexOf(f, "environment")) |i| (try f.idAt(i)) orelse core.ContentId.none else core.ContentId.none;
        return .{
            .title = title,
            .goal_seconds = @floatCast(goal),
            .clear = clear,
            .level = level,
            .lighting = try LightSettings.read(store, f),
            .environment = environment,
        };
    }
};

fn index(f: Fields, name: []const u8) Invalid!u32 {
    return indexOf(f, name) orelse error.InvalidConfig;
}
fn indexOf(f: Fields, name: []const u8) ?u32 {
    for (f.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return null;
}
fn size(f: Fields, name: []const u8) !u32 {
    const v = (try f.intAt(try index(f, name))) orelse return error.InvalidConfig;
    if (v < 320 or v > 8192) return error.InvalidConfig;
    return @intCast(v);
}
