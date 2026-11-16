//! Every string the court shows, from `court:text.main` (playable3d.md §5.5). The source
//! holds none: a string the record does not supply is shown as its field's name, which is
//! legible, obviously a placeholder, and not content.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const log = core.log.scoped(.court);

pub const max_len = 160;

pub const Text = struct {
    title: []const u8 = "title",
    goal: []const u8 = "goal",
    goal_detail: []const u8 = "goal_detail",
    controls: []const u8 = "controls",
    play: []const u8 = "play",
    options: []const u8 = "options",
    quit: []const u8 = "quit",
    paused: []const u8 = "paused",
    @"resume": []const u8 = "resume",
    restart: []const u8 = "restart",
    to_title: []const u8 = "to_title",
    pointer_released: []const u8 = "pointer_released",
    won: []const u8 = "won",
    won_detail: []const u8 = "won_detail",
    caught: []const u8 = "caught",
    caught_detail: []const u8 = "caught_detail",
    fell: []const u8 = "fell",
    fell_detail: []const u8 = "fell_detail",
    beacons_lit: []const u8 = "beacons_lit",
    objective: []const u8 = "objective",
    objective_gate: []const u8 = "objective_gate",
    pause_hint: []const u8 = "pause_hint",
    use_prompt: []const u8 = "use_prompt",
    menu_hints: []const u8 = "menu_hints",
    options_hints: []const u8 = "options_hints",
    audio: []const u8 = "audio",
    master_volume: []const u8 = "master_volume",
    music_volume: []const u8 = "music_volume",
    effects_volume: []const u8 = "effects_volume",
    controls_section: []const u8 = "controls_section",
    look_sensitivity: []const u8 = "look_sensitivity",
    invert_look: []const u8 = "invert_look",
    on: []const u8 = "on",
    off: []const u8 = "off",
    applies_at_once: []const u8 = "applies_at_once",
    back: []const u8 = "back",
    no_gate: []const u8 = "no_gate",

    pub const record_id = "court:text.main";

    /// The strings borrow the store's bytes: read again after every content change.
    /// A missing or wrong-schema record leaves every placeholder and says so once.
    pub fn read(store: *const data.Store) Text {
        return readStrings(Text, store, record_id, "court:text");
    }
};

/// The Controls and Output rows' words (M45, `input.md` §11), in a record of their own beside
/// `court:text.main`, read by the same rule.
pub const ControlsText = struct {
    controls_screen: []const u8 = "controls_screen",
    output: []const u8 = "output",
    system_default: []const u8 = "system_default",
    action_move: []const u8 = "action_move",
    action_jump: []const u8 = "action_jump",
    action_use: []const u8 = "action_use",
    action_look_stick: []const u8 = "action_look_stick",
    action_menu_up: []const u8 = "action_menu_up",
    action_menu_down: []const u8 = "action_menu_down",
    action_menu_left: []const u8 = "action_menu_left",
    action_menu_right: []const u8 = "action_menu_right",
    action_menu_accept: []const u8 = "action_menu_accept",
    action_menu_back: []const u8 = "action_menu_back",
    action_panels: []const u8 = "action_panels",
    keyboard: []const u8 = "keyboard",
    pad: []const u8 = "pad",
    unbound: []const u8 = "unbound",
    reset: []const u8 = "reset",
    press_key: []const u8 = "press_key",
    press_pad: []const u8 = "press_pad",
    press_cancel: []const u8 = "press_cancel",
    sequence_up: []const u8 = "sequence_up",
    sequence_down: []const u8 = "sequence_down",
    sequence_left: []const u8 = "sequence_left",
    sequence_right: []const u8 = "sequence_right",
    conflict: []const u8 = "conflict",
    another_action: []const u8 = "another_action",
    conflict_hint: []const u8 = "conflict_hint",
    controls_hints: []const u8 = "controls_hints",

    pub const record_id = "court:text.controls";

    pub fn read(store: *const data.Store) ControlsText {
        return readStrings(ControlsText, store, record_id, "court:controls_text");
    }
};

/// What a binding's source is called on screen, from `court:text.sources`: a name per source
/// and a word per face label. Borrowed from the store, like the text.
pub const SourceNames = struct {
    sources: ?data.fpk.List = null,
    faces: ?data.fpk.List = null,

    pub const record_id = "court:text.sources";

    pub fn read(store: *const data.Store) SourceNames {
        const record = store.lookup(core.ContentId.fromString(record_id)) orelse {
            log.warn("missing '{s}'; bindings are shown by their source names", .{record_id});
            return .{};
        };
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:source_names"))) {
            log.warn("'{s}' is not a 'court:source_names'; bindings are shown by their source names", .{record_id});
            return .{};
        }
        return .{ .sources = listOf(record.fields, "sources"), .faces = listOf(record.fields, "faces") };
    }

    /// The name of a source (`pad.start`), or null when none is listed.
    pub fn source(self: SourceNames, name: []const u8) ?[]const u8 {
        return lookup(self.sources, "source", name);
    }

    /// The word for a face label (`a`, `cross`, ...), or null.
    pub fn face(self: SourceNames, label: []const u8) ?[]const u8 {
        return lookup(self.faces, "label", label);
    }
};

fn listOf(fields: data.fpk.Fields, name: []const u8) ?data.fpk.List {
    for (fields.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return fields.listAt(@intCast(i)) catch null;
    }
    return null;
}

/// The `text` of the first list entry whose `key` is `wanted`.
fn lookup(list: ?data.fpk.List, key: []const u8, wanted: []const u8) ?[]const u8 {
    const l = list orelse return null;
    for (0..l.len) |n| {
        const entry = (l.nestedAt(@intCast(n)) catch continue) orelse continue;
        const k = usable(entry, key) orelse continue;
        if (std.mem.eql(u8, k, wanted)) return usable(entry, "text");
    }
    return null;
}

/// Every string field of `T` from one record, each its field's name when the record does not
/// supply it usably.
fn readStrings(comptime T: type, store: *const data.Store, record_id: []const u8, schema: []const u8) T {
    var out: T = .{};
    const record = store.lookup(core.ContentId.fromString(record_id)) orelse {
        log.warn("missing '{s}'; the screens show field names", .{record_id});
        return out;
    };
    if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked(schema))) {
        log.warn("'{s}' is not a '{s}'; the screens show field names", .{ record_id, schema });
        return out;
    }
    var refused: u32 = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (usable(record.fields, field.name)) |value| {
            @field(out, field.name) = value;
        } else refused += 1;
    }
    if (refused != 0) log.warn("'{s}': {d} string(s) are missing, empty, too long or not text; their field names are shown", .{ record_id, refused });
    return out;
}

/// A string a screen can show: present, valid UTF-8, not empty and within `max_len`.
fn usable(fields: data.fpk.Fields, name: []const u8) ?[]const u8 {
    const index: u32 = for (fields.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) break @intCast(i);
    } else return null;
    const value = (fields.stringAt(index) catch return null) orelse return null;
    if (value.len == 0 or value.len > max_len) return null;
    if (!std.unicode.utf8ValidateSlice(value)) return null;
    return value;
}
