//! Options → Audio → Output (`input.md` §11, §5): "System default" and each output the machine
//! lists, chosen by name and kept by name in the player's preferences.
//!
//! An output's ID is good for this session only, so the choice is a name, found again at start
//! and whenever the list changes. A chosen output that goes away is followed by the system
//! default (the platform does that itself, and says so), the row shows "System default", and
//! the name is kept, so the headphones are chosen again when they come back. An output's name
//! often carries a person's, so it is shown, never logged (§5).
const std = @import("std");
const core = @import("core");
const audio = @import("audio");
const platform = @import("platform");
const log = core.log.scoped(.court);

pub const max_name = platform.audio.max_output_name;

pub const Outputs = struct {
    list: [platform.audio.max_outputs]platform.OutputInfo = undefined,
    len: usize = 0,
    /// The player's choice by name; empty follows the system default.
    wanted: [max_name]u8 = undefined,
    wanted_len: usize = 0,

    pub fn wantedName(self: *const Outputs) []const u8 {
        return self.wanted[0..self.wanted_len];
    }

    pub fn setWanted(self: *Outputs, name: []const u8) void {
        const n = @min(name.len, max_name);
        @memcpy(self.wanted[0..n], name[0..n]);
        self.wanted_len = n;
    }

    /// Lists the outputs again, then follows the wanted one if it is present and not followed
    /// already: at start, and on `audio_outputs_changed`.
    pub fn refresh(self: *Outputs, p: *platform.Platform, mixer: ?*audio.Mixer) void {
        self.len = p.audioOutputs(&self.list);
        const m = mixer orelse return;
        if (self.wanted_len == 0) return;
        const id = self.find(self.wantedName()) orelse return;
        if (m.output() == id) return;
        m.selectOutput(id) catch |err| {
            log.info("the chosen output could not be opened ({t}); following the system default", .{err});
            return;
        };
        log.info("audio: the chosen output is back, {d} of {d}", .{ self.indexOf(id).? + 1, self.len });
    }

    fn find(self: *const Outputs, name: []const u8) ?platform.OutputId {
        for (self.list[0..self.len]) |*o| if (std.mem.eql(u8, o.name(), name)) return o.id;
        return null;
    }

    fn indexOf(self: *const Outputs, id: platform.OutputId) ?usize {
        for (self.list[0..self.len], 0..) |o, i| if (o.id == id) return i;
        return null;
    }

    /// What the row shows: the output the mixer plays to now, or null for the system default.
    pub fn shown(self: *const Outputs, mixer: ?*const audio.Mixer) ?[]const u8 {
        const m = mixer orelse return null;
        const id = m.output() orelse return null;
        const i = self.indexOf(id) orelse return null;
        return self.list[i].name();
    }

    /// One step left or right through "System default" and the list, from what plays now.
    /// Answers whether the choice changed; the caller keeps `wantedName` in the preferences.
    pub fn step(self: *Outputs, mixer: ?*audio.Mixer, sign: i2) bool {
        const m = mixer orelse return false;
        if (self.len == 0) return false;
        // Position 0 is the system default, and output i is position i + 1.
        const count = self.len + 1;
        const at: usize = if (m.output()) |id| (self.indexOf(id) orelse return false) + 1 else 0;
        const next = if (sign > 0) (at + 1) % count else (at + count - 1) % count;
        const choice: ?platform.OutputId = if (next == 0) null else self.list[next - 1].id;
        m.selectOutput(choice) catch |err| {
            log.info("that output could not be opened ({t})", .{err});
            return false;
        };
        if (choice) |_| self.setWanted(self.list[next - 1].name()) else self.wanted_len = 0;
        log.info("audio: output {d} of {d} chosen (0 follows the system default)", .{ next, self.len });
        return true;
    }
};
