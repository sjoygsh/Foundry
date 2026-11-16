//! What the public table publishes input from (`docs/design/input.md` §10, ADR-0090).
//!
//! **The host supplies it** (ADR-0026): `abi`'s host holds `?*const InputSources`, and without
//! one every input call answers `FOUNDRY_ERR_UNAVAILABLE`. It is a set of borrows, never a copy:
//! the engine's frame and tick views, its map and enabled contexts, and the player's overrides,
//! each at the address it keeps for its life. `Engine.inputSources` fills one; a test fills one by
//! hand from values of its own, with no window and no engine.
//!
//! **Two views.** `frame` is what the frame saw, every edge it had, whether or not a step ran.
//! `tick` is what the step being simulated sees (§7): an edge or a delta reaches one step, the
//! first after it happened. The table answers `tick` inside a system's callback and `frame`
//! anywhere else, so a mod's simulation reads input exactly as the game's does.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const input = @import("input");

pub const InputSources = struct {
    frame: View,
    tick: View,
    /// The effective map: the content's actions with the player's overrides applied. Its
    /// `warnings` are the overrides' alone (`Map.apply`).
    map: *const input.Map,
    /// Which contexts are enabled.
    actions: *const input.Actions,
    /// The player's overrides, including those the map refused or does not hold.
    overrides: *const input.Overrides,
    /// The layout's label for a key (`input.md` §3). Null answers the key's own name, as the
    /// null platform does.
    labels: ?Labels = null,

    pub const View = struct {
        input: *const platform.InputSnapshot,
        actions: *const input.Frame,
    };

    pub const Labels = struct {
        ctx: *anyopaque,
        label: *const fn (ctx: *anyopaque, key: platform.Key, buf: *[platform.key.label_capacity]u8) []const u8,
    };

    pub fn keyLabel(self: *const InputSources, key: platform.Key, buf: *[platform.key.label_capacity]u8) []const u8 {
        if (key == .unknown) return buf[0..0];
        if (self.labels) |l| return l.label(l.ctx, key, buf);
        return platform.key.boundedLabel(key.name(), buf);
    }

    /// Whether the player's override for `action` is in force: one exists, and the map neither
    /// ignored it (`rebindable false`) nor refused it.
    pub fn overridden(self: *const InputSources, action: core.ContentId) bool {
        if (self.overrides.get(action) == null) return false;
        for (self.map.warnings) |w| if (w.record.eql(action)) return false;
        return true;
    }
};

test "a hand-made source labels a key by its name, and an unknown key not at all" {
    const map: input.Map = .empty;
    var actions: input.Actions = .init(&map);
    const overrides: input.Overrides = .empty;
    const snapshot: platform.InputSnapshot = .{};
    const frame: input.Frame = .empty;
    _ = &actions;
    const sources: InputSources = .{
        .frame = .{ .input = &snapshot, .actions = &frame },
        .tick = .{ .input = &snapshot, .actions = &frame },
        .map = &map,
        .actions = &actions,
        .overrides = &overrides,
    };
    var buf: [platform.key.label_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("left_shift", sources.keyLabel(.left_shift, &buf));
    try std.testing.expectEqualStrings("", sources.keyLabel(.unknown, &buf));
    try std.testing.expect(!sources.overridden(core.ContentId.fromString("t:action.jump")));
}
