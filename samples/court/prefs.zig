//! The player's preferences: `settings.fset` under `foundry-court` (playable3d.md §8,
//! ADR-0031). Window size, master volume, look sensitivity and invert, each bounded and
//! validated on read. Content supplies the defaults; a missing, damaged or newer file
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
    sensitivity: settings.Resolved(f32) = .{ .value = fallback_sensitivity, .origin = .fallback },
    invert: settings.Resolved(bool) = .{ .value = false, .origin = .fallback },

    /// The file's own schema. Not content: it carries no manifest and is never merged.
    pub const schema: data.Schema = .{
        .id = data.SchemaId.parse("court:preferences") catch unreachable,
        .version = 1,
        .fields = &.{
            .{ .name = "window_width", .type = .u32, .presence = .optional },
            .{ .name = "window_height", .type = .u32, .presence = .optional },
            .{ .name = "master_volume", .type = .f32, .presence = .optional },
            .{ .name = "look_sensitivity", .type = .f32, .presence = .optional },
            .{ .name = "invert_look", .type = .bool, .presence = .optional },
        },
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
        const override = dir orelse return .{ .file = try settings.File.open(gpa, os, schema, .{ .persist = !budgeted }) };
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
        if (!self.sensitivity.isUser())
            self.sensitivity = settings.resolveFloat(f32, "look_sensitivity", fallback_sensitivity, menus.Options.sensitivity_min, menus.Options.sensitivity_max, &layers);
        if (!self.invert.isUser()) self.invert = resolveBool("invert_look", false, &layers);
    }

    /// The values the options screen edits.
    pub fn options(self: *const Preferences) menus.Options {
        return .{ .volume = self.volume.value, .sensitivity = self.sensitivity.value, .invert = self.invert.value };
    }

    /// What the options screen changed. A value the player did not move stays the
    /// content's, so a package can still change its default later.
    pub fn noteOptions(self: *Preferences, chosen: menus.Options) void {
        var changed = false;
        if (std.math.isFinite(chosen.volume)) {
            const value = std.math.clamp(chosen.volume, menus.Options.volume_min, menus.Options.volume_max);
            if (value != self.volume.value) {
                self.volume = .{ .value = value, .origin = .user };
                changed = true;
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
    pub fn values(self: *const Preferences) [5]?data.Value {
        return .{
            if (self.width.isUser()) data.Value{ .int = self.width.value } else null,
            if (self.height.isUser()) data.Value{ .int = self.height.value } else null,
            if (self.volume.isUser()) data.Value{ .float = self.volume.value } else null,
            if (self.sensitivity.isUser()) data.Value{ .float = self.sensitivity.value } else null,
            if (self.invert.isUser()) data.Value{ .bool = self.invert.value } else null,
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
