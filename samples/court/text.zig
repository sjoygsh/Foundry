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
    use_key: []const u8 = "use_key",
    use_prompt: []const u8 = "use_prompt",
    menu_hints: []const u8 = "menu_hints",
    options_hints: []const u8 = "options_hints",
    audio: []const u8 = "audio",
    master_volume: []const u8 = "master_volume",
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
        var out: Text = .{};
        const record = store.lookup(core.ContentId.fromString(record_id)) orelse {
            log.warn("missing '{s}'; the screens show field names", .{record_id});
            return out;
        };
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:text"))) {
            log.warn("'{s}' is not a 'court:text'; the screens show field names", .{record_id});
            return out;
        }
        var refused: u32 = 0;
        inline for (@typeInfo(Text).@"struct".fields) |field| {
            if (usable(record.fields, field.name)) |value| {
                @field(out, field.name) = value;
            } else refused += 1;
        }
        if (refused != 0) log.warn("'{s}': {d} string(s) are missing, empty, too long or not text; their field names are shown", .{ record_id, refused });
        return out;
    }
};

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
