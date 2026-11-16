//! The player's preferences: `settings.fset` under `foundry-court` (playable3d.md §8,
//! ADR-0031). Window size, the master, music and effects volumes, look sensitivity and
//! invert, and the audio output by name (M45), each bounded and validated on read. Content supplies the defaults; a missing, damaged or newer file
//! leaves them standing. Only what the player chose is written back.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const menus = @import("menus.zig");

const settings = app.settings;
const log = core.log.scoped(.court);

pub const Preferences = struct {
    file: settings.File = .{},
    width: settings.Resolved(u32) = .{ .value = fallback_width, .origin = .fallback },
    height: settings.Resolved(u32) = .{ .value = fallback_height, .origin = .fallback },
    volume: settings.Resolved(f32) = .{ .value = fallback_volume, .origin = .fallback },
    music: settings.Resolved(f32) = .{ .value = fallback_volume, .origin = .fallback },
    effects: settings.Resolved(f32) = .{ .value = fallback_volume, .origin = .fallback },
    sensitivity: settings.Resolved(f32) = .{ .value = fallback_sensitivity, .origin = .fallback },
    invert: settings.Resolved(bool) = .{ .value = false, .origin = .fallback },
    /// The chosen audio output's name, or empty for the system default (`outputs.zig`). Only
    /// ever the player's, so it has no content layer: the file's, or nothing.
    output_buffer: [max_output]u8 = undefined,
    output_len: usize = 0,
    output_chosen: bool = false,

    /// The file's own schema. Not content: it carries no manifest and is never merged.
    /// Version 2 (M31) adds the music and effects volumes after the first five, and version 3
    /// (M45) the audio output after those (I8).
    pub const schema: data.Schema = .{
        .id = data.SchemaId.parse("court:preferences") catch unreachable,
        .version = 3,
        .fields = &.{
            .{ .name = "window_width", .type = .u32, .presence = .optional },
            .{ .name = "window_height", .type = .u32, .presence = .optional },
            .{ .name = "master_volume", .type = .f32, .presence = .optional },
            .{ .name = "look_sensitivity", .type = .f32, .presence = .optional },
            .{ .name = "invert_look", .type = .bool, .presence = .optional },
            .{ .name = "music_volume", .type = .f32, .presence = .optional },
            .{ .name = "effects_volume", .type = .f32, .presence = .optional },
            .{ .name = "audio_output", .type = .string, .presence = .optional },
        },
    };

    pub const max_output = @import("outputs.zig").max_name;

    /// Version 2, as M31 to M44 wrote it: the first seven fields.
    pub const schema_v2: data.Schema = .{
        .id = schema.id,
        .version = 2,
        .fields = schema.fields[0..7],
    };

    /// Version 1, as M26 to M30 wrote it: the first five fields.
    pub const schema_v1: data.Schema = .{
        .id = schema.id,
        .version = 1,
        .fields = schema.fields[0..5],
    };

    /// A version 1 file keeps its five values, and the new two are the content's until
    /// the player moves them.
    fn fromV1(_: std.mem.Allocator, old: []const ?data.Value, new: []?data.Value) std.mem.Allocator.Error!void {
        @memcpy(new[0..5], old[0..5]);
    }

    /// A version 2 file keeps its seven, and follows the system default.
    fn fromV2(_: std.mem.Allocator, old: []const ?data.Value, new: []?data.Value) std.mem.Allocator.Error!void {
        @memcpy(new[0..7], old[0..7]);
    }

    pub const migrations = [_]settings.Migration{
        .{ .from = schema_v1, .convert = fromV1 },
        .{ .from = schema_v2, .convert = fromV2 },
    };

    /// The package's defaults, in an ordinary record a mod can override.
    pub const record_id = "court:config.main";

    /// What the sample knows with no content at all.
    pub const fallback_width: u32 = 1280;
    pub const fallback_height: u32 = 720;
    pub const fallback_volume: f32 = 1;
    pub const fallback_sensitivity: f32 = 1;
    pub const min_size: u32 = 320;
    pub const max_size: u32 = 8192;

    /// Headless runs read and write nothing; a frame-budgeted run reads and does not write
    /// (the rule the other samples follow). `dir` replaces the user data directory, for a
    /// disposable root (`FOUNDRY_COURT_SAVE_DIR`).
    pub fn open(gpa: std.mem.Allocator, os: *platform.os.Os, headless: bool, budgeted: bool, dir: ?[]const u8) std.mem.Allocator.Error!Preferences {
        if (headless) return .{};
        const override = dir orelse return .{ .file = try settings.File.open(gpa, os, schema, .{ .persist = !budgeted, .migrations = &migrations }) };
        return .{ .file = try openIn(gpa, os, override, !budgeted) };
    }

    /// `settings.File.open` over a named directory instead of the user's.
    pub fn openIn(gpa: std.mem.Allocator, os: *platform.os.Os, dir: []const u8, persist: bool) std.mem.Allocator.Error!settings.File {
        const owned = try gpa.dupe(u8, dir);
        errdefer gpa.free(owned);
        var storage = settings.Storage.open(os, owned, settings.default_leaf) catch |err| {
            log.warn("preferences: '{s}' cannot hold them ({t})", .{ dir, err });
            gpa.free(owned);
            return .{};
        };
        storage.migrations = &migrations;
        const loaded = try storage.load(gpa, schema);
        // No baseline: every chosen value is written, which is the safe answer.
        return .{ .dir = owned, .storage = storage, .loaded = loaded, .persist = persist and storage.writable };
    }

    pub fn deinit(self: *Preferences, gpa: std.mem.Allocator) void {
        self.file.deinit(gpa);
        self.* = .{};
    }

    /// Resolves every value the player has not chosen in this session: the file over the
    /// content record over the fallback. Called after content loads and after it reloads.
    pub fn resolve(self: *Preferences, store: *const data.Store) void {
        const record = store.lookup(core.ContentId.fromString(record_id));
        const content: ?settings.Layer = if (record) |r| .{ .schema = r.schema, .fields = r.fields, .origin = .content } else null;
        self.resolveFrom(content);
    }

    pub fn resolveFrom(self: *Preferences, content: ?settings.Layer) void {
        const layers = [_]?settings.Layer{ content, self.file.layer(schema) };
        if (!self.width.isUser())
            self.width = settings.resolveInt(u32, "window_width", fallback_width, min_size, max_size, &layers);
        if (!self.height.isUser())
            self.height = settings.resolveInt(u32, "window_height", fallback_height, min_size, max_size, &layers);
        if (!self.volume.isUser())
            self.volume = settings.resolveFloat(f32, "master_volume", fallback_volume, menus.Options.volume_min, menus.Options.volume_max, &layers);
        if (!self.music.isUser())
            self.music = settings.resolveFloat(f32, "music_volume", fallback_volume, menus.Options.volume_min, menus.Options.volume_max, &layers);
        if (!self.effects.isUser())
            self.effects = settings.resolveFloat(f32, "effects_volume", fallback_volume, menus.Options.volume_min, menus.Options.volume_max, &layers);
        if (!self.sensitivity.isUser())
            self.sensitivity = settings.resolveFloat(f32, "look_sensitivity", fallback_sensitivity, menus.Options.sensitivity_min, menus.Options.sensitivity_max, &layers);
        if (!self.invert.isUser()) self.invert = resolveBool("invert_look", false, &layers);
        if (!self.output_chosen) self.readOutput(self.file.layer(schema));
    }

    fn readOutput(self: *Preferences, layer: ?settings.Layer) void {
        self.output_len = 0;
        const l = layer orelse return;
        const index = l.schema.fieldIndex("audio_output") orelse return;
        const value = (l.fields.stringAt(index) catch null) orelse return;
        // A name this build could not have written is no output's: the default stands.
        if (value.len > max_output or !std.unicode.utf8ValidateSlice(value)) return;
        @memcpy(self.output_buffer[0..value.len], value);
        self.output_len = value.len;
    }

    /// The chosen output's name, or empty for the system default.
    pub fn output(self: *const Preferences) []const u8 {
        return self.output_buffer[0..self.output_len];
    }

    /// The player chose an output on the Output row. A lost output is not a choice: the name
    /// stays until the player picks another.
    pub fn noteOutput(self: *Preferences, name: []const u8) void {
        if (self.output_chosen and std.mem.eql(u8, name, self.output())) return;
        const n = @min(name.len, max_output);
        @memcpy(self.output_buffer[0..n], name[0..n]);
        self.output_len = n;
        self.output_chosen = true;
        self.file.touch();
    }

    /// The values the options screen edits.
    pub fn options(self: *const Preferences) menus.Options {
        return .{ .volume = self.volume.value, .music = self.music.value, .effects = self.effects.value, .sensitivity = self.sensitivity.value, .invert = self.invert.value };
    }

    /// What the options screen changed. A value the player did not move stays the
    /// content's, so a package can still change its default later.
    pub fn noteOptions(self: *Preferences, chosen: menus.Options) void {
        var changed = false;
        inline for (.{ "volume", "music", "effects" }) |name| {
            const chosen_value = @field(chosen, name);
            if (std.math.isFinite(chosen_value)) {
                const value = std.math.clamp(chosen_value, menus.Options.volume_min, menus.Options.volume_max);
                if (value != @field(self, name).value) {
                    @field(self, name) = .{ .value = value, .origin = .user };
                    changed = true;
                }
            }
        }
        if (std.math.isFinite(chosen.sensitivity)) {
            const value = std.math.clamp(chosen.sensitivity, menus.Options.sensitivity_min, menus.Options.sensitivity_max);
            if (value != self.sensitivity.value) {
                self.sensitivity = .{ .value = value, .origin = .user };
                changed = true;
            }
        }
        if (chosen.invert != self.invert.value) {
            self.invert = .{ .value = chosen.invert, .origin = .user };
            changed = true;
        }
        if (changed) self.file.touch();
    }

    /// A resize the user performed. The echo of the sample's own resize changes nothing.
    pub fn noteResize(self: *Preferences, size: platform.Size) void {
        const width = std.math.cast(u32, size.width) orelse return;
        const height = std.math.cast(u32, size.height) orelse return;
        if (width == self.width.value and height == self.height.value) return;
        if (width < min_size or width > max_size or height < min_size or height > max_size) return;
        self.width = .{ .value = width, .origin = .user };
        self.height = .{ .value = height, .origin = .user };
        self.file.touch();
    }

    /// The player's own choices and nothing else.
    pub fn values(self: *const Preferences) [8]?data.Value {
        return .{
            if (self.width.isUser()) data.Value{ .int = self.width.value } else null,
            if (self.height.isUser()) data.Value{ .int = self.height.value } else null,
            if (self.volume.isUser()) data.Value{ .float = self.volume.value } else null,
            if (self.sensitivity.isUser()) data.Value{ .float = self.sensitivity.value } else null,
            if (self.invert.isUser()) data.Value{ .bool = self.invert.value } else null,
            if (self.music.isUser()) data.Value{ .float = self.music.value } else null,
            if (self.effects.isUser()) data.Value{ .float = self.effects.value } else null,
            if (self.output_chosen) data.Value{ .string = self.output() } else null,
        };
    }

    /// Once per frame: writes after the changes have settled.
    pub fn tick(self: *Preferences, gpa: std.mem.Allocator) void {
        const chosen = self.values();
        self.file.tick(gpa, schema, &chosen);
    }

    pub fn flush(self: *Preferences, gpa: std.mem.Allocator) void {
        const chosen = self.values();
        self.file.flush(gpa, schema, &chosen);
    }
};

/// `settings.resolveInt`'s rule for a flag: the last layer that states it wins.
fn resolveBool(name: []const u8, fallback: bool, layers: []const ?settings.Layer) settings.Resolved(bool) {
    var i = layers.len;
    while (i > 0) {
        i -= 1;
        const layer = layers[i] orelse continue;
        const index = layer.schema.fieldIndex(name) orelse continue;
        const value = (layer.fields.boolAt(index) catch null) orelse continue;
        return .{ .value = value, .origin = layer.origin };
    }
    return .{ .value = fallback, .origin = .fallback };
}
