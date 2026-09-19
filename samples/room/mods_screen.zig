//! The room's mod screen (`mod-management.md` §11), described through `FoundryApi_v3` alone.
//!
//! **Nothing here reaches past the public table** (I4). Every package, conflict, profile,
//! string, style, theme and widget comes through the calls a native mod receives, so this
//! file is also the evidence that a mod could build the same screen. The room lends the host
//! its mod set, its write grant and a UI context of the screen's own; it never hands this
//! file an engine type.
//!
//! **Changes are made after the frame that asked for them.** A click is recorded while the
//! screen is described and carried out once `ui_end` has returned, because a change ends
//! every walk and every borrowed string the description is still reading (`foundry.h`,
//! mod management). The next frame reads the set again.
//!
//! **Every word on it is content**, in `room:screen.mods`, read through `content_find` and
//! copied whenever `content_generation` moves. The screen supplies only the shapes, such as
//! "3 installed" or "needs a package that cannot load: lamps:kit", so a package cannot crash it
//! with a format string.

const std = @import("std");
const abi = @import("abi");

const Allocator = std.mem.Allocator;
const Api = abi.Api_v3;
const Bool = abi.Bool;
const ContentId = abi.ContentId;
const Rect = abi.UiRect;
const Str = abi.Str;
const UiId = abi.UiId;

const log = std.log.scoped(.room);

/// The screen's strings: one field each of `room:screen.mods`.
pub const Text = enum {
    title,
    profile,
    profile_name,
    new,
    copy,
    rename,
    delete,
    close,
    filter,
    installed,
    enabled,
    problems,
    tab_details,
    tab_conflicts,
    tab_records,
    tab_problems,
    origin_installed,
    origin_user,
    environment,
    not_installed,
    version,
    requires,
    requirement_met,
    requirement_unmet,
    provides,
    records,
    wins,
    loses,
    loaded_now,
    yes,
    no,
    no_native,
    select_prompt,
    conflicts_none,
    conflict_won,
    conflict_lost,
    record_prompt,
    record_invalid,
    record_none,
    record_winner,
    problems_none,
    skip_not_installed,
    skip_missing_dependency,
    skip_dependency_version,
    skip_dependency_skipped,
    skip_cycle,
    skip_duplicate,
    skip_shadows_installed,
    unsaved,
    next_start,
    apply,
    revert,
    drop_into,
    up,
    down,
    top,
    bottom,
    profile_unusable,
};

pub const record_id = "room:screen.mods";
pub const theme_id = "room:ui.theme";

/// Where the room's script aims, recorded as the screen is described and read on a later
/// frame, as the card's rectangles are.
pub const Targets = struct {
    /// The first package that is a choice, if there is one: its row, and its box.
    choice_row: ?Rect = null,
    choice_toggle: ?Rect = null,
    /// Where each tab begins.
    tabs: [4]?Rect = @splat(null),
    revert: ?Rect = null,
    close: ?Rect = null,
};

const Tab = enum(u32) { details, conflicts, records, problems };

const Relation = struct { beats: bool = false, loses: bool = false };

/// What one click asked for, done after the frame.
const Action = union(enum) {
    none,
    set_enabled: struct { id: ContentId, on: bool },
    move: struct { id: ContentId, to: u32 },
    revert,
    apply,
    select: u32,
    create,
    copy: u32,
    rename: u32,
    delete: u32,
};

/// A row's identity across frames: a package and where it was found. Two copies in the
/// player's folder share both, and select together, which is the honest answer when
/// nothing but a path could tell them apart.
const Key = struct {
    id: ContentId,
    origin: abi.ModOrigin,

    fn of(info: *const abi.ModInfo) Key {
        return .{ .id = info.id, .origin = info.origin };
    }

    fn eql(a: Key, b: Key) bool {
        return a.id.eql(b.id) and a.origin == b.origin;
    }
};

pub const Screen = struct {
    gpa: Allocator,
    api: *const Api,

    /// The generation the strings and the theme were read at; zero before the first read.
    generation: u64 = 0,
    strings: std.heap.ArenaAllocator,
    text: std.EnumArray(Text, []const u8) = .initFill(""),
    /// Resolved once per content generation. A theme that fails is not asked for again
    /// until content changes, so a broken one is one warning rather than one a frame.
    theme: ?abi.Theme = null,

    tab: Tab = .details,
    selected: ?Key = null,
    filter: [48]u8 = undefined,
    filter_len: u64 = 0,
    query: [96]u8 = undefined,
    query_len: u64 = 0,
    name: [64]u8 = undefined,
    name_len: u64 = 0,

    action: Action = .none,
    /// What this screen changed and took back, for the room's closing report.
    changes: u64 = 0,
    reverts: u64 = 0,
    /// Set by Close and read by the room after the frame, like the card's.
    close_requested: bool = false,
    targets: Targets = .{},

    // -- this frame's reading of the set; strings borrowed until the next change ---------
    rows: std.ArrayList(abi.ModInfo) = .empty,
    pending: std.ArrayList(abi.ModPending) = .empty,
    profiles: std.ArrayList(abi.ModProfile) = .empty,
    state: abi.ModProfileState = .{},
    /// How each package stands against the selected one, from their shared records: it beats
    /// the selection on some, loses to it on some, or both.
    relations: std.AutoHashMapUnmanaged(u64, Relation) = .empty,
    /// Lines for the right pane, and the bytes they are printed into.
    lines: std.ArrayList([]const u8) = .empty,
    scratch: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, api: *const Api) Screen {
        return .{
            .gpa = gpa,
            .api = api,
            .strings = .init(gpa),
            .scratch = .init(gpa),
        };
    }

    pub fn deinit(self: *Screen) void {
        self.rows.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.profiles.deinit(self.gpa);
        self.relations.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        self.scratch.deinit();
        self.strings.deinit();
        self.* = undefined;
    }

    /// Forgets what the player was pointing at, for a screen being closed.
    pub fn close(self: *Screen) void {
        self.action = .none;
        self.close_requested = false;
    }

    /// One frame of the screen: read, describe, then act. `drop_path` is where the host
    /// says mods go, as text only it can know; the table never gives out a path.
    pub fn frame(self: *Screen, viewport: Rect, drop_path: []const u8) void {
        _ = self.scratch.reset(.retain_capacity);
        self.readContent();
        self.read() catch |err| log.warn("mod screen: reading the mod set failed ({t})", .{err});

        const pushed = if (self.theme) |theme| self.api.ui_theme_push(theme) == .ok else false;
        if (self.theme != null and !pushed) self.theme = null;
        defer if (pushed) {
            _ = self.api.ui_theme_pop();
        };

        self.targets = .{};
        if (self.api.ui_begin(&viewport) != .ok) return;
        self.describe(viewport, drop_path, pushed) catch |err| {
            log.warn("mod screen: describing failed ({t})", .{err});
        };
        const ended = self.api.ui_end();
        if (ended != .ok) log.warn("mod screen: the frame ended unbalanced ({s})", .{ended.name()});

        self.act();
    }

    // -- reading ------------------------------------------------------------------------

    /// The strings and the theme, again whenever content has moved.
    fn readContent(self: *Screen) void {
        var generation: u64 = 0;
        if (self.api.content_generation(&generation) != .ok or generation == self.generation) return;
        self.generation = generation;

        _ = self.strings.reset(.retain_capacity);
        self.text = .initFill("");
        var record: abi.Record = .none;
        if (self.api.content_find(ContentId.fromString(record_id), &record) == .ok) {
            for (std.enums.values(Text)) |key| self.text.set(key, self.copyString(record, @tagName(key)));
        } else {
            log.warn("mod screen: '{s}' is not in any loaded package; its words are blank", .{record_id});
        }

        var theme: abi.Theme = .none;
        const resolved = self.api.ui_theme_resolve(ContentId.fromString(theme_id), &theme);
        self.theme = if (resolved == .ok) theme else null;
        if (resolved != .ok) log.warn("mod screen: '{s}' cannot be used ({s}); the room's own look stands", .{ theme_id, resolved.name() });
    }

    fn copyString(self: *Screen, record: abi.Record, field_name: []const u8) []const u8 {
        var field: u32 = 0;
        if (self.api.record_field_index(record, .from(field_name), &field) != .ok) return "";
        var needed: u64 = 0;
        if (self.api.record_copy_string(record, field, null, 0, &needed) != .ok and needed == 0) return "";
        const bytes = self.strings.allocator().alloc(u8, needed) catch return "";
        if (self.api.record_copy_string(record, field, bytes.ptr, bytes.len, &needed) != .ok) return "";
        return bytes;
    }

    fn read(self: *Screen) Allocator.Error!void {
        self.rows.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
        self.profiles.clearRetainingCapacity();
        self.state = .{};

        var cursor: abi.Cursor = .begin;
        var info: abi.ModInfo = .{};
        while (self.api.mods_installed_next(&cursor, &info) == .ok) try self.rows.append(self.gpa, info);
        cursor = .begin;
        var entry: abi.ModPending = .{};
        while (self.api.mods_pending_next(&cursor, &entry) == .ok) try self.pending.append(self.gpa, entry);
        cursor = .begin;
        var profile: abi.ModProfile = .{};
        while (self.api.mods_profile_next(&cursor, &profile) == .ok) try self.profiles.append(self.gpa, profile);
        _ = self.api.mods_profile_active(&self.state);

        // A selection whose package has gone is no selection.
        if (self.selected) |key| {
            if (self.find(key) == null) self.selected = null;
        }
        try self.relate();
    }

    /// Who the selected package beats and who beats it: along each record it shares, the
    /// providers before it in load order lose to it, and those after it win.
    fn relate(self: *Screen) Allocator.Error!void {
        self.relations.clearRetainingCapacity();
        const key = self.selected orelse return;
        const info = self.find(key) orelse return;
        if (info.pending_position == abi.mod_no_position) return;

        var records: abi.Cursor = .begin;
        var conflict: abi.ModConflict = .{};
        while (self.api.mods_conflict_next(info.id, &records, &conflict) == .ok) {
            var chain: abi.Cursor = .begin;
            var provider: abi.ModProvider = .{};
            while (self.api.mods_provider_next(conflict.record, &chain, &provider) == .ok) {
                if (provider.package.eql(info.id)) continue;
                const entry = try self.relations.getOrPut(self.gpa, provider.package.hash);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                if (provider.position > info.pending_position) entry.value_ptr.beats = true else entry.value_ptr.loses = true;
            }
        }
    }

    /// The relation column's icon for a row: how it fares against the selected package.
    fn relationIcon(self: *const Screen, info: *const abi.ModInfo) []const u8 {
        if (info.pending_position == abi.mod_no_position) return "";
        const relation = self.relations.get(info.id.hash) orelse return "";
        if (relation.beats and relation.loses) return "both";
        if (relation.beats) return "win";
        if (relation.loses) return "lose";
        return "";
    }

    fn find(self: *const Screen, key: Key) ?*const abi.ModInfo {
        for (self.rows.items) |*info| if (Key.of(info).eql(key)) return info;
        return null;
    }

    /// The copy a player's-list entry means: the one that loads, else the first found.
    fn copyFor(self: *const Screen, id: ContentId) ?*const abi.ModInfo {
        var first: ?*const abi.ModInfo = null;
        for (self.rows.items) |*info| {
            if (!info.id.eql(id)) continue;
            if (info.pending_position != abi.mod_no_position) return info;
            if (first == null) first = info;
        }
        return first;
    }

    /// A package's name for a line of text: its display name, its spelling, or nothing.
    fn nameOf(self: *const Screen, id: ContentId) []const u8 {
        if (self.copyFor(id)) |info| return info.name.bytes() orelse "";
        for (self.pending.items) |entry| if (entry.id.eql(id)) return entry.name.bytes() orelse "";
        return "";
    }

    // -- describing ---------------------------------------------------------------------

    fn describe(self: *Screen, viewport: Rect, drop_path: []const u8, themed: bool) !void {
        const a = self.api;
        var style: abi.UiStyle = .{};
        _ = a.ui_style_get(&style);
        const line = style.line_height;
        const step = line + style.spacing;

        const margin: f32 = 24;
        const outer: Rect = .{ .x = margin, .y = margin, .w = @max(0, viewport.w - margin * 2), .h = @max(0, viewport.h - margin * 2) };
        try check(a.ui_begin_panel(uid(1), &outer));

        try self.header(style);
        try self.nameRow();
        try self.filterRow();

        // Two columns under the three rows, and two rows under them.
        var left: Rect = .{};
        try check(a.ui_region_remaining(&left));
        const below = 2 * step;
        const height = @max(line, left.h - below);
        const gap = style.spacing * 2;
        const list_w = @round((left.w - gap) * 0.58);
        const list: Rect = .{ .x = left.x, .y = left.y, .w = list_w, .h = height };
        const pane: Rect = .{ .x = left.x + list_w + gap, .y = left.y, .w = @max(0, left.w - list_w - gap), .h = height };
        try self.modList(list, style, themed);
        try self.rightPane(pane, style);
        try check(a.ui_spacer(height));

        try self.reorderRow();
        try self.pendingRow(drop_path);
        try check(a.ui_end_panel());
    }

    /// Title, the profile strip, and Close.
    fn header(self: *Screen, style: abi.UiStyle) !void {
        const a = self.api;
        try check(a.ui_begin_row(uid(10), style.line_height));
        defer _ = a.ui_end_row();
        try check(a.ui_label(.from(self.text.get(.title))));
        try check(a.ui_spacer(style.spacing * 4));
        try check(a.ui_label(.from(self.text.get(.profile))));

        const at = self.pendingProfileIndex();
        const count = self.profiles.items.len;
        try self.disabledIf(at == null or at.? == 0);
        if (try button(a, uid(11), "<")) self.action = .{ .select = self.profiles.items[at.? - 1].key };
        try self.endDisabledIf(at == null or at.? == 0);

        var buffer: [128]u8 = undefined;
        const shown: []const u8 = if (at) |i| blk: {
            const profile = self.profiles.items[i];
            const name = profile.name.bytes() orelse "";
            break :blk if (profile.problem == .none) name else std.fmt.bufPrint(&buffer, "{s} {s}", .{ name, self.text.get(.profile_unusable) }) catch name;
        } else "-";
        try check(a.ui_label(.from(shown)));

        try self.disabledIf(at == null or at.? + 1 >= count);
        if (try button(a, uid(12), ">")) self.action = .{ .select = self.profiles.items[at.? + 1].key };
        try self.endDisabledIf(at == null or at.? + 1 >= count);

        try check(a.ui_spacer(style.spacing * 4));
        self.targets.close = try remaining(a);
        if (try button(a, uid(13), self.text.get(.close))) self.close_requested = true;
    }

    /// A name, and what can be done with it.
    fn nameRow(self: *Screen) !void {
        const a = self.api;
        try check(a.ui_begin_row(uid(20), self.lineHeight()));
        defer _ = a.ui_end_row();
        try check(a.ui_label(.from(self.text.get(.profile_name))));
        var changed: Bool = 0;
        try check(a.ui_text_field(uid(21), &self.name, self.name.len, &self.name_len, &changed));

        const no_name = self.name_len == 0;
        const pending = self.state.pending;
        const have = self.state.has_pending != 0;
        try self.disabledIf(no_name);
        if (try button(a, uid(22), self.text.get(.new))) self.action = .create;
        if (have and try button(a, uid(23), self.text.get(.copy))) self.action = .{ .copy = pending };
        if (have and try button(a, uid(24), self.text.get(.rename))) self.action = .{ .rename = pending };
        try self.endDisabledIf(no_name);

        // The profile being browsed, when it is not the one the next start uses: switching
        // back first is what "delete this one" means, since the saved one is never deleted.
        const deletable = have and self.state.has_saved != 0 and pending != self.state.saved;
        try self.disabledIf(!deletable);
        if (try button(a, uid(25), self.text.get(.delete))) self.action = .{ .delete = pending };
        try self.endDisabledIf(!deletable);
    }

    fn filterRow(self: *Screen) !void {
        const a = self.api;
        try check(a.ui_begin_row(uid(30), self.lineHeight()));
        defer _ = a.ui_end_row();
        try check(a.ui_label(.from(self.text.get(.filter))));
        var changed: Bool = 0;
        try check(a.ui_text_field(uid(31), &self.filter, self.filter.len, &self.filter_len, &changed));

        var on: usize = 0;
        for (self.rows.items) |info| {
            if (info.pending_position != abi.mod_no_position) on += 1;
        }
        var buffer: [160]u8 = undefined;
        const counts = std.fmt.bufPrint(&buffer, "{d} {s}, {d} {s}, {d} {s}", .{
            self.rows.items.len, self.text.get(.installed),
            on,                  self.text.get(.enabled),
            self.problemCount(), self.text.get(.problems),
        }) catch "";
        try check(a.ui_label(.from(counts)));
    }

    // -- the list ---------------------------------------------------------------------

    /// Required packages, locked; then the player's list, in the player's order, under the
    /// reorder grips; then everything installed that is not on it.
    fn modList(self: *Screen, bounds: Rect, style: abi.UiStyle, themed: bool) !void {
        const a = self.api;
        const step = style.line_height + style.spacing;

        var shown: usize = 0;
        for (self.rows.items) |*info| {
            if (self.inPlayerList(info) != null) continue;
            if (self.passes(info.name.bytes() orelse "", info.id_name.bytes() orelse "")) shown += 1;
        }
        for (self.pending.items) |entry| {
            if (self.passesPending(entry)) shown += 1;
        }
        const content = @as(f32, @floatFromInt(shown)) * step;
        // A surface of its own, as the right pane has, so the rows read over the hall.
        try check(a.ui_begin_panel(uid(39), &bounds));
        defer _ = a.ui_end_panel();
        const inside = try remaining(a);
        try check(a.ui_begin_scroll(uid(40), &inside, content));

        const layout = Layout.of(style, inside.w, themed);
        var n: u64 = 0;
        for (self.rows.items) |*info| {
            if ((info.flags & abi.mod_flag_required) == 0) continue;
            if (!self.passes(info.name.bytes() orelse "", info.id_name.bytes() orelse "")) continue;
            try self.row(&n, .{ .info = info }, layout);
        }

        // The player's list, whole or not at all: grips over a filtered list would move
        // rows the player cannot see.
        const filtering = self.filter_len != 0;
        var grips: Rect = .{};
        try check(a.ui_region_remaining(&grips));
        var listed: u32 = 0;
        for (self.pending.items) |*entry| {
            if (!self.passesPending(entry.*)) continue;
            const info = self.copyFor(entry.id);
            try self.row(&n, if (info) |i| .{ .info = i } else .{ .missing = entry }, layout);
            listed += 1;
        }
        if (!filtering and listed > 0) {
            grips.h = @as(f32, @floatFromInt(listed)) * step - style.spacing;
            var move: abi.UiReorderMove = .{};
            try check(a.ui_reorder_list(uid(41), &grips, listed, &move));
            if (move.moved != 0) self.action = .{ .move = .{ .id = self.pending.items[move.from].id, .to = move.to } };
        }

        for (self.rows.items) |*info| {
            if ((info.flags & abi.mod_flag_required) != 0) continue;
            if (self.inPlayerList(info) != null) continue;
            if (!self.passes(info.name.bytes() orelse "", info.id_name.bytes() orelse "")) continue;
            try self.row(&n, .{ .info = info }, layout);
        }
        try check(a.ui_end_scroll());
    }

    /// The column widths a row is drawn with, worked out once a frame from the style the
    /// table reports: the font is a grid, so columns are characters.
    const Layout = struct {
        grip: f32,
        icon: f32,
        themed: bool,
        name_chars: usize,

        fn of(style: abi.UiStyle, width: f32, themed: bool) Layout {
            const cell = style.font.cell.x * style.text_scale + style.font.letter_spacing;
            const grip = style.padding.x * 2 + @max(0, style.line_height - style.padding.y * 2);
            const icon_side = style.line_height - 4;
            const check_w = style.padding.x * 2 + @max(0, style.line_height - style.padding.y * 2) + style.spacing;
            const fixed = grip + check_w + 4 * (icon_side + style.spacing) + style.padding.x * 2 + style.scrollbar;
            const chars: usize = if (cell > 0) @intFromFloat(@max(0, (width - fixed) / cell)) else 0;
            // "#", the version and the origin take their own columns; the name has the rest.
            return .{ .grip = grip, .icon = icon_side, .themed = themed, .name_chars = @max(8, chars -| 22) };
        }
    };

    const RowOf = union(enum) {
        info: *const abi.ModInfo,
        missing: *const abi.ModPending,
    };

    fn row(self: *Screen, n: *u64, of: RowOf, layout: Layout) !void {
        const a = self.api;
        n.* += 1;
        try check(a.ui_push_id(uid(1000 + n.*)));
        defer _ = a.ui_pop_id();
        try check(a.ui_begin_row(uid(1), self.lineHeight()));
        defer _ = a.ui_end_row();
        try check(a.ui_spacer(layout.grip));

        switch (of) {
            .missing => |entry| {
                // Still a choice: a player takes it off their list here.
                const first_choice = self.targets.choice_row == null;
                if (first_choice) self.targets.choice_toggle = try remaining(a);
                var on: Bool = 1;
                var changed: Bool = 0;
                try check(a.ui_checkbox(uid(2), .from(""), &on, &changed));
                if (changed != 0) self.action = .{ .set_enabled = .{ .id = entry.id, .on = false } };
                try self.icon(layout, "");
                try self.icon(layout, "warning");
                try self.icon(layout, "");
                try self.icon(layout, "");
                var buffer: [160]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "  -  {s}  {s}", .{ entry.name.bytes() orelse "?", self.text.get(.not_installed) }) catch "";
                if (first_choice) self.targets.choice_row = try remaining(a);
                var clicked: Bool = 0;
                try check(a.ui_selectable(uid(3), .from(text), 0, &clicked));
            },
            .info => |info| {
                const key = Key.of(info);
                const required = (info.flags & abi.mod_flag_required) != 0;
                var on: Bool = info.pending_enabled;
                var changed: Bool = 0;
                const first_choice = !required and self.targets.choice_row == null;
                if (required) try check(a.ui_begin_disabled());
                if (first_choice) self.targets.choice_toggle = try remaining(a);
                try check(a.ui_checkbox(uid(2), .from(""), &on, &changed));
                if (required) try check(a.ui_end_disabled());
                if (changed != 0 and !required) self.action = .{ .set_enabled = .{ .id = info.id, .on = on != 0 } };

                const problem = info.skip_reason != .none or (info.flags & abi.mod_flag_unreadable) != 0;
                // How this row fares against the selected one, then its own state, its own
                // conflicts, and whether it carries code.
                try self.icon(layout, self.relationIcon(info));
                try self.icon(layout, if (required) "lock" else if (problem) "warning" else "");
                try self.icon(layout, conflictIcon(info));
                try self.icon(layout, if ((info.flags & abi.mod_flag_native) != 0) "native" else if ((info.flags & abi.mod_flag_script) != 0) "script" else "");

                var position: [8]u8 = undefined;
                const pos = if (info.pending_position == abi.mod_no_position) "-" else std.fmt.bufPrint(&position, "{d}", .{info.pending_position + 1}) catch "?";
                var name_buffer: [96]u8 = undefined;
                const name = padded(&name_buffer, info.name.bytes() orelse "", layout.name_chars);
                var buffer: [192]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{s: >3}  {s}  {d: >4}  {s}", .{
                    pos,
                    name,
                    info.version,
                    self.text.get(if (info.origin == .user) .origin_user else .origin_installed),
                }) catch "";

                const selected = if (self.selected) |s| s.eql(key) else false;
                if (first_choice) self.targets.choice_row = try remaining(a);
                var clicked: Bool = 0;
                try check(a.ui_selectable(uid(3), .from(text), abi.boolOut(selected), &clicked));
                if (clicked != 0) self.selected = key;
            },
        }
    }

    /// One icon column: the theme's icon, or the same space without one, so columns line up
    /// whether or not a theme could be used.
    fn icon(self: *Screen, layout: Layout, name: []const u8) !void {
        const a = self.api;
        if (!layout.themed) return check(a.ui_spacer(layout.icon));
        var found: Bool = 0;
        try check(a.ui_icon(.from(name), .{ .x = layout.icon, .y = layout.icon }, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, &found));
    }

    fn conflictIcon(info: *const abi.ModInfo) []const u8 {
        if (info.provides > 0 and info.loses == info.provides) return "redundant";
        if (info.wins > 0 and info.loses > 0) return "both";
        if (info.wins > 0) return "win";
        if (info.loses > 0) return "lose";
        return "";
    }

    // -- the right pane ---------------------------------------------------------------

    fn rightPane(self: *Screen, bounds: Rect, style: abi.UiStyle) !void {
        const a = self.api;
        try check(a.ui_begin_panel(uid(50), &bounds));

        var problems_label: [64]u8 = undefined;
        const labels = [_]Str{
            .from(self.text.get(.tab_details)),
            .from(self.text.get(.tab_conflicts)),
            .from(self.text.get(.tab_records)),
            .from(std.fmt.bufPrint(&problems_label, "{s} {d}", .{ self.text.get(.tab_problems), self.problemCount() }) catch ""),
        };
        var tab: u32 = @intFromEnum(self.tab);
        {
            try check(a.ui_begin_row(uid(51), style.line_height));
            defer _ = a.ui_end_row();
            // Each tab's left edge, by the arithmetic the strip lays itself out with: a label's
            // width and the padding either side, then the spacing.
            var x = (try remaining(a)).x;
            for (labels, 0..) |label, i| {
                const width = measure(style, label.bytes() orelse "") + style.padding.x * 2;
                self.targets.tabs[i] = .{ .x = x, .y = (try remaining(a)).y, .w = width, .h = style.line_height };
                x += width + style.spacing;
            }
            try check(a.ui_tabs(uid(52), &labels, labels.len, &tab));
        }
        self.tab = @enumFromInt(tab);

        if (self.tab == .records) {
            try check(a.ui_begin_row(uid(53), style.line_height));
            defer _ = a.ui_end_row();
            try check(a.ui_label(.from(self.text.get(.record_prompt))));
            var changed: Bool = 0;
            try check(a.ui_text_field(uid(54), &self.query, self.query.len, &self.query_len, &changed));
        }

        try self.buildLines();
        var rest: Rect = .{};
        try check(a.ui_region_remaining(&rest));
        const step = style.line_height + style.spacing;
        try check(a.ui_begin_scroll(uid(55), &rest, @as(f32, @floatFromInt(self.lines.items.len)) * step));
        for (self.lines.items) |text| try check(a.ui_label(.from(text)));
        try check(a.ui_end_scroll());
        try check(a.ui_end_panel());
    }

    fn say(self: *Screen, comptime format: []const u8, args: anytype) !void {
        const text = std.fmt.allocPrint(self.scratch.allocator(), format, args) catch return;
        try self.lines.append(self.gpa, text);
    }

    fn buildLines(self: *Screen) !void {
        self.lines.clearRetainingCapacity();
        switch (self.tab) {
            .details => try self.details(),
            .conflicts => try self.conflicts(),
            .records => try self.recordChain(),
            .problems => try self.problemLines(),
        }
    }

    fn details(self: *Screen) !void {
        const key = self.selected orelse return self.say("{s}", .{self.text.get(.select_prompt)});
        const info = self.find(key) orelse return;
        const t = &self.text;
        try self.say("{s}", .{info.name.bytes() orelse ""});
        try self.say("{s}, {s} {d}, {s}", .{ info.id_name.bytes() orelse "", t.get(.version), info.version, info.license.bytes() orelse "" });
        try self.say("{s}", .{t.get(if (info.origin == .user) .origin_user else .origin_installed)});
        if ((info.flags & abi.mod_flag_environment) != 0) try self.say("{s}", .{t.get(.environment)});

        var cursor: abi.Cursor = .begin;
        var requirement: abi.ModRequirement = .{};
        while (self.api.mods_requirement_next(info.id, &cursor, &requirement) == .ok) {
            const name = requirement.name.bytes() orelse "";
            if (requirement.max_version == abi.mod_no_position) {
                try self.say("{s} {s} >= {d}  {s}", .{ t.get(.requires), name, requirement.min_version, t.get(if (requirement.satisfied != 0) .requirement_met else .requirement_unmet) });
            } else {
                try self.say("{s} {s} {d}..{d}  {s}", .{ t.get(.requires), name, requirement.min_version, requirement.max_version, t.get(if (requirement.satisfied != 0) .requirement_met else .requirement_unmet) });
            }
        }
        try self.say("{s} {d} {s}, {s} {d}, {s} {d}", .{ t.get(.provides), info.provides, t.get(.records), t.get(.wins), info.wins, t.get(.loses), info.loses });
        try self.say("{s} {s}", .{ t.get(.loaded_now), t.get(if (info.loaded != 0) .yes else .no) });
        if ((info.flags & abi.mod_flag_native) != 0) try self.say("{s}", .{t.get(.no_native)});
        if (info.skip_reason != .none) try self.say("{s}", .{try self.skipText(info)});
    }

    fn conflicts(self: *Screen) !void {
        const key = self.selected orelse return self.say("{s}", .{self.text.get(.select_prompt)});
        const info = self.find(key) orelse return;
        var cursor: abi.Cursor = .begin;
        var conflict: abi.ModConflict = .{};
        var any = false;
        while (self.api.mods_conflict_next(info.id, &cursor, &conflict) == .ok) {
            any = true;
            if (conflict.winner.eql(info.id)) {
                try self.say("{s}: {s}", .{ conflict.name.bytes() orelse "", self.text.get(.conflict_won) });
            } else {
                try self.say("{s}: {s} {s}", .{ conflict.name.bytes() orelse "", self.text.get(.conflict_lost), self.nameOf(conflict.winner) });
            }
        }
        if (!any) try self.say("{s}", .{self.text.get(.conflicts_none)});
    }

    fn recordChain(self: *Screen) !void {
        if (self.query_len == 0) return;
        var id: ContentId = .none;
        if (self.api.id_from_string(.from(self.query[0..self.query_len]), &id) != .ok) {
            return self.say("{s}", .{self.text.get(.record_invalid)});
        }
        var cursor: abi.Cursor = .begin;
        var provider: abi.ModProvider = .{};
        var any = false;
        while (self.api.mods_provider_next(id, &cursor, &provider) == .ok) {
            any = true;
            if (provider.winner != 0) {
                try self.say("{d}. {s}  {s}", .{ provider.position + 1, self.nameOf(provider.package), self.text.get(.record_winner) });
            } else {
                try self.say("{d}. {s}", .{ provider.position + 1, self.nameOf(provider.package) });
            }
        }
        if (!any) try self.say("{s}", .{self.text.get(.record_none)});
    }

    fn problemLines(self: *Screen) !void {
        for (self.rows.items) |*info| {
            if (info.skip_reason == .none) continue;
            try self.say("{s}: {s}", .{ info.name.bytes() orelse "", try self.skipText(info) });
        }
        for (self.pending.items) |entry| {
            if (entry.installed != 0) continue;
            try self.say("{s}: {s}", .{ entry.name.bytes() orelse "?", self.text.get(.skip_not_installed) });
        }
        if (self.lines.items.len == 0) try self.say("{s}", .{self.text.get(.problems_none)});
    }

    /// Why a copy will not load, with the package the reason is about when there is one.
    fn skipText(self: *Screen, info: *const abi.ModInfo) ![]const u8 {
        const reason: Text = switch (info.skip_reason) {
            .none => return "",
            .not_installed => .skip_not_installed,
            .missing_dependency => .skip_missing_dependency,
            .dependency_version => .skip_dependency_version,
            .dependency_skipped => .skip_dependency_skipped,
            .cycle => .skip_cycle,
            .duplicate => .skip_duplicate,
            .shadows_installed => .skip_shadows_installed,
        };
        // A dependency nothing installed has is a hash nobody can spell, so it is named only
        // when a name exists.
        const other = info.skip_other_name.bytes() orelse "";
        if (other.len == 0) return self.text.get(reason);
        return std.fmt.allocPrint(self.scratch.allocator(), "{s}: {s}", .{ self.text.get(reason), other });
    }

    // -- the rows under the columns ---------------------------------------------------

    /// Up, Down, Top and Bottom, for the selected package when it is on the player's list.
    fn reorderRow(self: *Screen) !void {
        const a = self.api;
        try check(a.ui_begin_row(uid(60), self.lineHeight()));
        defer _ = a.ui_end_row();
        const buttons = [_]struct { Text, abi.UiReorderDirection }{
            .{ .up, .up }, .{ .down, .down }, .{ .top, .top }, .{ .bottom, .bottom },
        };
        const index = if (self.selected) |key| if (self.find(key)) |info| self.inPlayerList(info) else null else null;
        const count: u32 = @intCast(self.pending.items.len);
        for (buttons, 0..) |b, i| {
            if (index) |at| {
                var move: abi.UiReorderMove = .{};
                try check(a.ui_reorder_button(uid(61 + i), .from(self.text.get(b[0])), at, count, @intFromEnum(b[1]), &move));
                if (move.moved != 0) self.action = .{ .move = .{ .id = self.pending.items[move.from].id, .to = move.to } };
            } else {
                try check(a.ui_begin_disabled());
                _ = try button(a, uid(61 + i), self.text.get(b[0]));
                try check(a.ui_end_disabled());
            }
        }
    }

    /// What waits for the next start, Apply and Revert, and where mods go.
    fn pendingRow(self: *Screen, drop_path: []const u8) !void {
        const a = self.api;
        try check(a.ui_begin_row(uid(70), self.lineHeight()));
        defer _ = a.ui_end_row();

        const changed = self.state.changed != 0;
        var waiting: usize = 0;
        for (self.rows.items) |info| {
            if ((info.flags & abi.mod_flag_required) != 0) continue;
            if ((info.loaded != 0) != (info.pending_position != abi.mod_no_position)) waiting += 1;
        }
        var buffer: [192]u8 = undefined;
        const status: []const u8 = if (changed)
            self.text.get(.unsaved)
        else if (waiting > 0)
            std.fmt.bufPrint(&buffer, "{d} {s}", .{ waiting, self.text.get(.next_start) }) catch ""
        else
            "";
        if (status.len > 0) try check(a.ui_label(.from(status)));

        try self.disabledIf(!changed);
        if (try button(a, uid(71), self.text.get(.apply))) self.action = .apply;
        self.targets.revert = try remaining(a);
        if (try button(a, uid(72), self.text.get(.revert))) self.action = .revert;
        try self.endDisabledIf(!changed);

        var path: [256]u8 = undefined;
        const where = std.fmt.bufPrint(&path, "{s} {s}", .{ self.text.get(.drop_into), drop_path }) catch "";
        try check(a.ui_label(.from(where)));
    }

    // -- acting -----------------------------------------------------------------------

    fn act(self: *Screen) void {
        const a = self.api;
        const action = self.action;
        self.action = .none;
        const result: abi.Result = switch (action) {
            .none => return,
            .set_enabled => |e| a.mods_set_enabled(e.id, abi.boolOut(e.on)),
            .move => |m| a.mods_move(m.id, m.to),
            .revert => a.mods_revert(),
            .apply => a.mods_apply(),
            .select => |key| a.mods_profile_select(key),
            .create => blk: {
                var key: u32 = 0;
                break :blk a.mods_profile_create(.from(self.name[0..self.name_len]), &key);
            },
            .copy => |source| blk: {
                var key: u32 = 0;
                break :blk a.mods_profile_copy(source, .from(self.name[0..self.name_len]), &key);
            },
            .rename => |key| a.mods_profile_rename(key, .from(self.name[0..self.name_len])),
            .delete => |key| blk: {
                const reverted = a.mods_revert();
                break :blk if (reverted != .ok) reverted else a.mods_profile_delete(key);
            },
        };
        if (result != .ok) {
            log.warn("mod screen: {t} was refused ({s})", .{ std.meta.activeTag(action), result.name() });
            return;
        }
        log.info("mod screen: {t}", .{std.meta.activeTag(action)});
        switch (action) {
            .set_enabled, .move => self.changes += 1,
            .revert => self.reverts += 1,
            else => {},
        }
        switch (action) {
            .create, .copy, .rename => self.name_len = 0,
            else => {},
        }
    }

    // -- small things -----------------------------------------------------------------

    fn lineHeight(self: *const Screen) f32 {
        var style: abi.UiStyle = .{};
        _ = self.api.ui_style_get(&style);
        return style.line_height;
    }

    /// The index of this copy in the player's list, when it is the copy that list means.
    fn inPlayerList(self: *const Screen, info: *const abi.ModInfo) ?u32 {
        if (info.pending_index == abi.mod_no_position) return null;
        const copy = self.copyFor(info.id) orelse return null;
        return if (copy == info) info.pending_index else null;
    }

    fn pendingProfileIndex(self: *const Screen) ?usize {
        if (self.state.has_pending == 0) return null;
        for (self.profiles.items, 0..) |p, i| if (p.key == self.state.pending) return i;
        return null;
    }

    fn problemCount(self: *const Screen) usize {
        var count: usize = 0;
        for (self.rows.items) |info| {
            if (info.skip_reason != .none) count += 1;
        }
        for (self.pending.items) |entry| {
            if (entry.installed == 0) count += 1;
        }
        return count;
    }

    fn passes(self: *const Screen, name: []const u8, id_name: []const u8) bool {
        if (self.filter_len == 0) return true;
        const needle = self.filter[0..self.filter_len];
        return std.ascii.indexOfIgnoreCase(name, needle) != null or std.ascii.indexOfIgnoreCase(id_name, needle) != null;
    }

    fn passesPending(self: *const Screen, entry: abi.ModPending) bool {
        const info = self.copyFor(entry.id) orelse return self.passes(entry.name.bytes() orelse "", entry.name.bytes() orelse "");
        return self.passes(info.name.bytes() orelse "", info.id_name.bytes() orelse "");
    }

    fn disabledIf(self: *const Screen, condition: bool) !void {
        if (condition) try check(self.api.ui_begin_disabled());
    }

    fn endDisabledIf(self: *const Screen, condition: bool) !void {
        if (condition) try check(self.api.ui_end_disabled());
    }
};

fn uid(n: u64) UiId {
    return .{ .bits = n };
}

/// A failed describing call is a bug in this file, not in the player's mods: stop describing
/// and let `ui_end` report the frame.
fn check(result: abi.Result) error{Refused}!void {
    if (result != .ok) {
        log.warn("mod screen: a call answered {s}", .{result.name()});
        return error.Refused;
    }
}

fn button(a: *const Api, id: UiId, text: []const u8) !bool {
    var clicked: Bool = 0;
    try check(a.ui_button(id, .from(text), &clicked));
    return clicked != 0;
}

/// How wide `text` is drawn, from the metrics the table reports: every character one cell of
/// the grid, and the letter spacing between them (`FoundryUiFontMetrics`).
fn measure(style: abi.UiStyle, text: []const u8) f32 {
    const count = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (count == 0) return 0;
    const cell = style.font.cell.x * style.text_scale;
    return @as(f32, @floatFromInt(count)) * (cell + style.font.letter_spacing) - style.font.letter_spacing;
}

fn remaining(a: *const Api) !Rect {
    var rect: Rect = .{};
    try check(a.ui_region_remaining(&rect));
    return rect;
}

/// `text` cut or padded with spaces to `width` characters. The font is a grid, so
/// characters are columns; a cut name ends in `~`.
fn padded(buffer: []u8, text: []const u8, width: usize) []const u8 {
    const target = @min(width, buffer.len);
    var used: usize = 0;
    var chars: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch return text[0..@min(text.len, target)];
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        if (chars + 1 == target and it.peek(1).len != 0) {
            if (used < buffer.len) buffer[used] = '~';
            used += 1;
            chars += 1;
            break;
        }
        if (used + slice.len > buffer.len) break;
        @memcpy(buffer[used..][0..slice.len], slice);
        used += slice.len;
        chars += 1;
    }
    while (chars < target and used < buffer.len) : (chars += 1) {
        buffer[used] = ' ';
        used += 1;
    }
    return buffer[0..used];
}
