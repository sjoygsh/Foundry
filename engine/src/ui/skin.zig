//! What a theme gives the game widget set beyond `Style` (ADR-0041).
//!
//! A `Style` says how big things are and what colour; a `Skin` says which images they are
//! drawn from: a nine-slice patch for each of a fixed list of parts, icons by the game's own
//! names, and the colours only a game screen uses. Images are `ImageRef`s, numbers the
//! caller defines, so the kernel still sees no texture and a skin tests with nothing linked.
//!
//! **A value, read and never written**, like `Style`. `app` builds one from a
//! `foundry:ui_theme` record; an empty one is what a UI without a theme has, and every
//! widget then draws from `Style` alone, as the debug set always has.
//!
//! **The part names are a compatibility decision** (`CLAUDE.md` §7). A theme names a part by
//! its spelling here, so adding a part is additive and renaming one breaks every theme that
//! drew it.
//!
//! Design: `docs/design/mod-management.md` §10.

const std = @import("std");

const draw = @import("draw.zig");
const Color = @import("style.zig").Color;

/// Every part a skinned widget may be drawn from. Fixed by ADR-0041.
pub const Part = enum {
    panel,
    button,
    button_hot,
    button_active,
    button_disabled,
    field,
    check_off,
    check_on,
    row,
    row_selected,
    tab,
    tab_on,
    scroll_track,
    scroll_thumb,
};

/// A rectangle of an image, cut into nine by its insets.
pub const Patch = struct {
    source: draw.Source,
    insets: draw.Insets = .{},
};

/// An image a widget draws whole, by the game's own name for it: "lock", "warning".
pub const Icon = struct {
    name: []const u8,
    source: draw.Source,
};

pub const Skin = struct {
    patches: std.EnumArray(Part, ?Patch) = .initFill(null),
    /// Screen units per image pixel for every patch's borders.
    patch_scale: f32 = 1,
    /// Borrowed from whoever built the skin, which keeps them for as long as it is in use.
    icons: []const Icon = &.{},

    /// Something went well: a mod that loads, a record that wins.
    positive: Color = .white,
    /// Something went badly: a mod skipped, a record lost.
    negative: Color = .white,
    /// Something needs looking at.
    warning: Color = .white,
    /// What the player has picked: a selected row's fill or outline.
    selection: Color = .white,

    pub fn patch(self: *const Skin, part: Part) ?Patch {
        return self.patches.get(part);
    }

    /// The icon with this name, or null. Linear: a skin has tens of icons, not thousands.
    pub fn icon(self: *const Skin, name: []const u8) ?draw.Source {
        for (self.icons) |i| if (std.mem.eql(u8, i.name, name)) return i.source;
        return null;
    }
};

const testing = std.testing;

test "an empty skin has no parts and no icons" {
    const skin: Skin = .{};
    try testing.expect(skin.patch(.button) == null);
    try testing.expect(skin.icon("lock") == null);
}

test "parts and icons are found by name, and a part's spelling is its enum name" {
    var skin: Skin = .{ .icons = &.{.{ .name = "lock", .source = .{ .image = .of(0), .x = 8, .w = 8, .h = 8 } }} };
    skin.patches.set(.button_hot, .{ .source = .{ .image = .of(0), .w = 12, .h = 12 }, .insets = .all(4) });
    try testing.expectEqual(@as(u32, 12), skin.patch(.button_hot).?.source.w);
    try testing.expect(skin.patch(.button) == null);
    try testing.expectEqual(@as(u32, 8), skin.icon("lock").?.x);
    // What a theme writes is what the enum is called.
    try testing.expectEqual(Part.scroll_thumb, std.meta.stringToEnum(Part, "scroll_thumb").?);
}
