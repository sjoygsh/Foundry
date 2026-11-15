//! `foundry:input_action` and `foundry:input_context` — actions and contexts as content
//! (`docs/design/input.md` §6, ADR-0087).
//!
//! ```fdt
//! foundry:input_action court:action.move {
//!     kind      vector                       # button | axis | vector | delta
//!     contexts  [ court:context.walk ]       # foundry:input_context records, 1 to 4
//!     bindings  [
//!         { source "key.w"  axis y  scale  1 }
//!         { source "pad.left_stick"  deadzone 0.2 }
//!     ]
//! }
//! foundry:input_context court:context.menu {
//!     priority  20        # higher is read first, ties by content ID
//!     blocks    true      # sources bound here are hidden from lower contexts
//! }
//! ```
//!
//! **Mechanism, not content** (I5): the record types are the engine's, registered through the
//! call a mod's `@schema` uses (I6), and a game's actions live in its own package, where a later
//! package overrides one action by overriding one record.
//!
//! **The action names its contexts**, not the reverse, so a mod adds an action to a game's
//! context without overriding the context's record (§6.2).
//!
//! **No label field.** What a player reads is text, and text is M46's string tables.
//!
//! What one record can get wrong is decoded here, so `fpack`, the editor and a load refuse
//! alike. What needs the merged store, whether a context is a context and the map's bounds, is
//! `Map.build`'s (`map.zig`).
//!
//! **Every name here is on authors' disks** (CLAUDE.md §7). Adding a field later is additive;
//! renaming one is a break.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const source_mod = @import("source.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Fields = data.fpk.Fields;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;
const Source = source_mod.Source;
const Class = source_mod.Class;

pub const action_name = "foundry:input_action";
pub const context_name = "foundry:input_context";

/// Bounds (§6.5). A record past one is refused whole, never truncated: half an action's
/// bindings is a control nobody designed.
pub const max_bindings: usize = 8;
pub const max_action_contexts: usize = 4;
/// The most a deadzone may be. A deadzone of 1 would make an axis that never moves.
pub const max_deadzone: f32 = 0.95;

pub const binding_fields = [_]data.Field{
    .{ .name = "source", .type = .string },
    .{ .name = "axis", .type = .string, .presence = .{ .default = .{ .string = "x" } } },
    .{ .name = "scale", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
    .{ .name = "threshold", .type = .f32, .presence = .{ .default = .{ .float = 0.5 } } },
    .{ .name = "deadzone", .type = .f32, .presence = .{ .default = .{ .float = 0.15 } } },
};

const binding_type: data.FieldType = .{ .nested = &binding_fields };

/// Version 1.
pub const action: Schema = .{
    .id = SchemaId.fromStringUnchecked(action_name),
    .version = 1,
    .fields = &.{
        .{ .name = "kind", .type = .string },
        .{ .name = "contexts", .type = .{ .list = &.id } },
        // Optional: an action with no defaults is one a player binds.
        .{ .name = "bindings", .type = .{ .list = &binding_type }, .presence = .optional },
        .{ .name = "rebindable", .type = .bool, .presence = .{ .default = .{ .bool = true } } },
    },
};

/// Version 1.
pub const context: Schema = .{
    .id = SchemaId.fromStringUnchecked(context_name),
    .version = 1,
    .fields = &.{
        .{ .name = "priority", .type = .i32, .presence = .{ .default = .{ .int = 0 } } },
        .{ .name = "blocks", .type = .bool, .presence = .{ .default = .{ .bool = false } } },
    },
};

/// Registers both record types. Registering twice agrees, as every engine schema does.
pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(gpa, action);
    _ = try registry.register(gpa, context);
}

/// What an action's value is (§6.5's table).
pub const Kind = enum(u8) {
    /// Held, pressed and released.
    button,
    /// One `f32` in [-1, 1].
    axis,
    /// A `Vec2` of length at most 1.
    vector,
    /// A `Vec2`, unbounded: the mouse's motion or its wheel.
    delta,

    /// Whether a source of `class` may feed an action of this kind (§6.5's table). A pad axis
    /// feeds a button past its threshold; a stick feeds a vector alone; a delta only a delta.
    pub fn accepts(self: Kind, class: Class) bool {
        return switch (self) {
            .button, .axis => class == .button or class == .axis,
            .vector => class != .delta,
            .delta => class == .delta,
        };
    }
};

/// Which component of a vector a one-dimensional binding feeds.
pub const Component = enum(u8) { x, y };

/// One binding whose source this build knows. A binding naming a source it does not know is
/// skipped (§6.5) and recorded in `ActionRecord.unknown_sources`.
pub const Binding = struct {
    source: Source,
    axis: Component = .x,
    scale: f32 = 1,
    threshold: f32 = 0.5,
    deadzone: f32 = 0.15,

    /// The numbers' rules. Each test is written so a NaN fails it, since a package's text
    /// cannot spell one but its bytes can.
    pub fn validate(self: *const Binding) DecodeError!void {
        if (!std.math.isFinite(self.scale) or self.scale == 0) return error.InvalidScale;
        if (!(std.math.isFinite(self.threshold) and self.threshold > 0 and self.threshold <= 1)) return error.InvalidThreshold;
        if (!(std.math.isFinite(self.deadzone) and self.deadzone >= 0 and self.deadzone <= max_deadzone)) return error.InvalidDeadzone;
    }
};

/// A decoded action record, before its contexts are resolved against a store.
pub const ActionRecord = struct {
    kind: Kind,
    context_buffer: [max_action_contexts]ContentId = undefined,
    context_count: u8 = 0,
    binding_buffer: [max_bindings]Binding = undefined,
    binding_count: u8 = 0,
    /// One bit per binding in the record that names a source this build does not know, by its
    /// index in the record. Those bindings are not in `bindings()`.
    unknown_sources: u8 = 0,
    rebindable: bool = true,

    pub fn contexts(self: *const ActionRecord) []const ContentId {
        return self.context_buffer[0..self.context_count];
    }

    pub fn bindings(self: *const ActionRecord) []const Binding {
        return self.binding_buffer[0..self.binding_count];
    }
};

/// A decoded context record.
pub const ContextRecord = struct {
    priority: i32 = 0,
    blocks: bool = false,
};

/// What one record can get wrong. Each names its field.
pub const DecodeError = error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    UnknownKind,
    NoContexts,
    TooManyContexts,
    DuplicateContext,
    TooManyBindings,
    EmptySource,
    SourceTooLong,
    /// A known source that cannot feed this kind, such as a stick on a button.
    SourceCannotFeedKind,
    UnknownAxis,
    InvalidScale,
    InvalidThreshold,
    InvalidDeadzone,
};

/// Where in a record a refusal was found, for a message that points at it.
pub const Fault = struct {
    /// The binding's index in the record, when the refusal is one binding's.
    binding: ?u8 = null,
};

/// A phrase naming the field, for a diagnostic or a log line: "'<id>' <phrase>".
pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.Unreadable => "cannot be read against its schema",
        error.UnknownKind => "has a kind that is not button, axis, vector or delta",
        error.NoContexts => "names no contexts",
        error.TooManyContexts => "names more than 4 contexts",
        error.DuplicateContext => "names one context twice",
        error.TooManyBindings => "has more than 8 bindings",
        error.EmptySource => "has a binding with an empty source",
        error.SourceTooLong => "has a binding whose source is longer than 32 bytes",
        error.SourceCannotFeedKind => "has a binding whose source cannot feed its kind",
        error.UnknownAxis => "has a binding whose axis is not x or y",
        error.InvalidScale => "has a binding whose scale is zero or not finite",
        error.InvalidThreshold => "has a binding whose threshold is not above 0 and at most 1",
        error.InvalidDeadzone => "has a binding whose deadzone is not between 0 and 0.95",
    };
}

/// `describe`, and which binding when the refusal is one binding's: "... (binding 2)".
pub fn describeAt(err: DecodeError, fault: Fault, buf: []u8) []const u8 {
    const phrase = describe(err);
    const b = fault.binding orelse return phrase;
    return std.fmt.bufPrint(buf, "{s} (binding {d})", .{ phrase, b }) catch phrase;
}

/// The record's noun for a message, or null for a schema that is not one of these.
pub fn noun(schema_id: SchemaId) ?[]const u8 {
    if (schema_id.eql(action.id)) return "input action";
    if (schema_id.eql(context.id)) return "input context";
    return null;
}

/// Decodes a record of either schema and discards the value, or null for another schema: the
/// compiler's check, so a package is refused where an engine would refuse it.
pub fn check(schema_id: SchemaId, fields: Fields, fault: *Fault) ?DecodeError!void {
    if (schema_id.eql(action.id)) {
        _ = decodeAction(fields, fault) catch |err| return err;
        return {};
    }
    if (schema_id.eql(context.id)) {
        _ = decodeContext(fields) catch |err| return err;
        return {};
    }
    return null;
}

/// Reads and validates an action laid out against this schema. An absent field is its
/// default, so a package from before a later version still decodes (I8).
pub fn decodeAction(fields: Fields, fault: *Fault) DecodeError!ActionRecord {
    fault.* = .{};
    const kind_text = try stringOf(fields, "kind") orelse return error.Unreadable;
    var out: ActionRecord = .{ .kind = std.meta.stringToEnum(Kind, kind_text) orelse return error.UnknownKind };

    const contexts = try listOf(fields, "contexts") orelse return error.Unreadable;
    if (contexts.len == 0) return error.NoContexts;
    if (contexts.len > max_action_contexts) return error.TooManyContexts;
    for (0..contexts.len) |i| {
        const id = (contexts.idAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
        for (out.contexts()) |seen| if (seen.eql(id)) return error.DuplicateContext;
        out.context_buffer[out.context_count] = id;
        out.context_count += 1;
    }

    if (try listOf(fields, "bindings")) |list| {
        if (list.len > max_bindings) return error.TooManyBindings;
        for (0..list.len) |i| {
            fault.binding = @intCast(i);
            const binding_fields_at = (list.nestedAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
            const decoded = try decodeBinding(binding_fields_at, out.kind);
            if (decoded) |binding| {
                out.binding_buffer[out.binding_count] = binding;
                out.binding_count += 1;
            } else {
                out.unknown_sources |= @as(u8, 1) << @intCast(i);
            }
        }
        fault.binding = null;
    }

    if (try boolOf(fields, "rebindable")) |v| out.rebindable = v;
    return out;
}

/// One binding, or null when its source is a name this build does not know. Its other fields
/// are checked either way: a deadzone of 2 is wrong whatever it reads.
fn decodeBinding(fields: Fields, kind: Kind) DecodeError!?Binding {
    const name = try stringOf(fields, "source") orelse return error.Unreadable;
    if (name.len == 0) return error.EmptySource;
    if (name.len > source_mod.max_name) return error.SourceTooLong;

    var axis: Component = .x;
    if (try stringOf(fields, "axis")) |text| axis = std.meta.stringToEnum(Component, text) orelse return error.UnknownAxis;
    // Validated with a placeholder source first, so an unknown source's numbers are checked too.
    var binding: Binding = .{
        .source = .mouse_motion,
        .axis = axis,
        .scale = try floatOf(fields, "scale") orelse 1,
        .threshold = try floatOf(fields, "threshold") orelse 0.5,
        .deadzone = try floatOf(fields, "deadzone") orelse 0.15,
    };
    try binding.validate();

    binding.source = Source.parse(name) orelse return null;
    if (!kind.accepts(binding.source.class())) return error.SourceCannotFeedKind;
    return binding;
}

/// Reads a context. Its two fields cannot be out of range, so only a damaged block refuses.
pub fn decodeContext(fields: Fields) DecodeError!ContextRecord {
    var out: ContextRecord = .{};
    if (try intOf(fields, "priority")) |v| out.priority = std.math.cast(i32, v) orelse return error.Unreadable;
    if (try boolOf(fields, "blocks")) |v| out.blocks = v;
    return out;
}

fn indexOf(fields: Fields, field: []const u8) ?u32 {
    for (fields.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, field)) return @intCast(i);
    return null;
}

fn floatOf(fields: Fields, field: []const u8) DecodeError!?f32 {
    const i = indexOf(fields, field) orelse return null;
    const value = (fields.floatAt(i) catch return error.Unreadable) orelse return null;
    return @floatCast(value);
}

fn intOf(fields: Fields, field: []const u8) DecodeError!?i128 {
    const i = indexOf(fields, field) orelse return null;
    return fields.intAt(i) catch return error.Unreadable;
}

fn boolOf(fields: Fields, field: []const u8) DecodeError!?bool {
    const i = indexOf(fields, field) orelse return null;
    return fields.boolAt(i) catch return error.Unreadable;
}

fn stringOf(fields: Fields, field: []const u8) DecodeError!?[]const u8 {
    const i = indexOf(fields, field) orelse return null;
    return fields.stringAt(i) catch return error.Unreadable;
}

fn listOf(fields: Fields, field: []const u8) DecodeError!?data.fpk.List {
    const i = indexOf(fields, field) orelse return null;
    return fields.listAt(i) catch return error.Unreadable;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const t_gpa = testing.allocator;

/// Compiles `source` as package `t:content` and decodes its one record.
const Compiled = struct {
    registry: Registry,
    diags: data.Diagnostics,
    bytes: std.ArrayList(u8) = .empty,
    reader: data.fpk.Reader = undefined,

    fn init(self: *Compiled, text: []const u8) !void {
        self.* = .{ .registry = .init(t_gpa, .default), .diags = .init(t_gpa, .default) };
        errdefer self.registry.deinit(t_gpa);
        errdefer self.diags.deinit(t_gpa);
        try registerAll(t_gpa, &self.registry);
        var doc = try data.parser.parse(t_gpa, "input.fdt", text, .{ .namespace = "t" }, &self.diags);
        defer doc.deinit(t_gpa);
        var package = try data.check.Package.init(t_gpa, "t:content", 1, .default);
        defer package.deinit(t_gpa);
        try package.addDocument(t_gpa, &doc, &self.registry, &self.diags);
        try data.fpk.write(t_gpa, &package, &self.registry, &self.bytes);
        self.reader = try data.fpk.Reader.open(t_gpa, self.bytes.items, .default);
    }

    fn deinit(self: *Compiled) void {
        self.reader.deinit();
        self.bytes.deinit(t_gpa);
        self.diags.deinit(t_gpa);
        self.registry.deinit(t_gpa);
    }

    fn fields(self: *Compiled) Fields {
        const view = self.reader.record(0).?;
        return self.reader.fieldsOf(view, self.reader.schemaFor(view.schema_id).?.*);
    }
};

fn actionOf(text: []const u8, fault: *Fault) !DecodeError!ActionRecord {
    var c: Compiled = undefined;
    try c.init(text);
    defer c.deinit();
    return decodeAction(c.fields(), fault);
}

test "both schemas register, twice, and agree" {
    var registry: Registry = .init(t_gpa, .default);
    defer registry.deinit(t_gpa);
    try registerAll(t_gpa, &registry);
    try registerAll(t_gpa, &registry);
    try testing.expect(registry.find(action.id) != null);
    try testing.expect(registry.find(context.id) != null);
}

test "the design's action decodes as it says, with every default in place" {
    var fault: Fault = .{};
    const move = try (try actionOf(
        \\foundry:input_action t:action.move {
        \\    kind      "vector"
        \\    contexts  [ t:context.walk ]
        \\    bindings  [
        \\        { source "key.w"  axis "y"  scale  1 }
        \\        { source "key.s"  axis "y"  scale -1 }
        \\        { source "key.a"  axis "x"  scale -1 }
        \\        { source "key.d"  axis "x"  scale  1 }
        \\        { source "pad.left_stick"  deadzone 0.2 }
        \\    ]
        \\}
    , &fault));
    try testing.expectEqual(Kind.vector, move.kind);
    try testing.expectEqual(@as(usize, 1), move.contexts().len);
    try testing.expect(move.contexts()[0].eql(ContentId.fromString("t:context.walk")));
    try testing.expectEqual(@as(usize, 5), move.bindings().len);
    try testing.expect(move.bindings()[0].source.eql(.{ .key = .w }));
    try testing.expectEqual(Component.y, move.bindings()[1].axis);
    try testing.expectEqual(@as(f32, -1), move.bindings()[1].scale);
    try testing.expect(move.bindings()[4].source.eql(.{ .pad_stick = .left }));
    try testing.expectEqual(@as(f32, 0.2), move.bindings()[4].deadzone);
    // The defaults: axis x, scale 1, threshold 0.5, deadzone 0.15, rebindable.
    try testing.expectEqual(Component.x, move.bindings()[4].axis);
    try testing.expectEqual(@as(f32, 1), move.bindings()[4].scale);
    try testing.expectEqual(@as(f32, 0.5), move.bindings()[0].threshold);
    try testing.expectEqual(@as(f32, 0.15), move.bindings()[0].deadzone);
    try testing.expect(move.rebindable);
    try testing.expectEqual(@as(u8, 0), move.unknown_sources);

    const pause = try (try actionOf("foundry:input_action t:pause { kind \"button\" contexts [ t:a t:b ] rebindable false }", &fault));
    try testing.expectEqual(@as(usize, 0), pause.bindings().len);
    try testing.expectEqual(@as(usize, 2), pause.contexts().len);
    try testing.expect(!pause.rebindable);
}

test "a context decodes, and its defaults are priority 0 and not blocking" {
    var c: Compiled = undefined;
    try c.init("foundry:input_context t:menu { priority -20 blocks true }");
    defer c.deinit();
    const menu = try decodeContext(c.fields());
    try testing.expectEqual(@as(i32, -20), menu.priority);
    try testing.expect(menu.blocks);

    var d: Compiled = undefined;
    try d.init("foundry:input_context t:walk {}");
    defer d.deinit();
    const walk = try decodeContext(d.fields());
    try testing.expectEqual(@as(i32, 0), walk.priority);
    try testing.expect(!walk.blocks);
}

test "an unknown source is skipped and the rest of the record kept" {
    var fault: Fault = .{};
    const jump = try (try actionOf(
        \\foundry:input_action t:jump { kind "button" contexts [ t:walk ] bindings [
        \\    { source "key.space" }
        \\    { source "pad.gyro_flick" }
        \\    { source "pad.south" }
        \\    { source "touch.tap" }
        \\] }
    , &fault));
    try testing.expectEqual(@as(usize, 2), jump.bindings().len);
    try testing.expect(jump.bindings()[0].source.eql(.{ .key = .space }));
    try testing.expect(jump.bindings()[1].source.eql(.{ .pad_button = .south }));
    try testing.expectEqual(@as(u8, 0b1010), jump.unknown_sources);
}

test "every field's refusal is named, with the binding it was found in" {
    const cases = [_]struct { text: []const u8, err: DecodeError, binding: ?u8 = null }{
        .{ .text = "foundry:input_action t:a { kind \"trigger\" contexts [ t:c ] }", .err = error.UnknownKind },
        .{ .text = "foundry:input_action t:a { kind \"Button\" contexts [ t:c ] }", .err = error.UnknownKind },
        .{ .text = "foundry:input_action t:a { kind \"button\" contexts [ ] }", .err = error.NoContexts },
        .{ .text = "foundry:input_action t:a { kind \"button\" contexts [ t:c1 t:c2 t:c3 t:c4 t:c5 ] }", .err = error.TooManyContexts },
        .{ .text = "foundry:input_action t:a { kind \"button\" contexts [ t:c t:d t:c ] }", .err = error.DuplicateContext },
        .{ .text = "foundry:input_action t:a { kind \"button\" contexts [ t:c ] bindings [ { source \"key.a\" } { source \"\" } ] }", .err = error.EmptySource, .binding = 1 },
        .{ .text = "foundry:input_action t:a { kind \"button\" contexts [ t:c ] bindings [ { source \"key.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" } ] }", .err = error.SourceTooLong, .binding = 0 },
        .{ .text = "foundry:input_action t:a { kind \"vector\" contexts [ t:c ] bindings [ { source \"key.a\" axis \"z\" } ] }", .err = error.UnknownAxis, .binding = 0 },
        .{ .text = "foundry:input_action t:a { kind \"axis\" contexts [ t:c ] bindings [ { source \"key.a\" scale 0 } ] }", .err = error.InvalidScale, .binding = 0 },
        .{ .text = "foundry:input_action t:a { kind \"button\" contexts [ t:c ] bindings [ { source \"pad.left_x\" threshold 0 } ] }", .err = error.InvalidThreshold, .binding = 0 },
        .{ .text = "foundry:input_action t:a { kind \"button\" contexts [ t:c ] bindings [ { source \"pad.left_x\" threshold 1.5 } ] }", .err = error.InvalidThreshold, .binding = 0 },
        .{ .text = "foundry:input_action t:a { kind \"axis\" contexts [ t:c ] bindings [ { source \"pad.left_x\" deadzone 2 } ] }", .err = error.InvalidDeadzone, .binding = 0 },
        .{ .text = "foundry:input_action t:a { kind \"axis\" contexts [ t:c ] bindings [ { source \"pad.left_x\" deadzone -0.1 } ] }", .err = error.InvalidDeadzone, .binding = 0 },
        .{ .text = "foundry:input_action t:a { kind \"axis\" contexts [ t:c ] bindings [ { source \"pad.left_x\" deadzone 0.96 } ] }", .err = error.InvalidDeadzone, .binding = 0 },
        // An unknown source's other fields are still checked.
        .{ .text = "foundry:input_action t:a { kind \"axis\" contexts [ t:c ] bindings [ { source \"pad.gyro\" deadzone 2 } ] }", .err = error.InvalidDeadzone, .binding = 0 },
    };
    for (cases) |case| {
        var fault: Fault = .{};
        try testing.expectError(case.err, try actionOf(case.text, &fault));
        try testing.expectEqual(case.binding, fault.binding);
    }

    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(t_gpa);
    try many.appendSlice(t_gpa, "foundry:input_action t:a { kind \"button\" contexts [ t:c ] bindings [");
    for (0..max_bindings + 1) |_| try many.appendSlice(t_gpa, " { source \"key.a\" }");
    try many.appendSlice(t_gpa, " ] }");
    var fault: Fault = .{};
    try testing.expectError(error.TooManyBindings, try actionOf(many.items, &fault));

    // Eight is the bound, not past it, and a deadzone of 0.95 and a threshold of 1 are inside.
    many.clearRetainingCapacity();
    try many.appendSlice(t_gpa, "foundry:input_action t:a { kind \"button\" contexts [ t:c1 t:c2 t:c3 t:c4 ] bindings [");
    for (0..max_bindings) |_| try many.appendSlice(t_gpa, " { source \"pad.left_x\" deadzone 0.95 threshold 1 }");
    try many.appendSlice(t_gpa, " ] }");
    const full = try (try actionOf(many.items, &fault));
    try testing.expectEqual(max_bindings, full.bindings().len);

    // A package's text cannot spell a non-finite number, but its bytes can carry one.
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    try testing.expectError(error.InvalidScale, (Binding{ .source = .mouse_motion, .scale = nan }).validate());
    try testing.expectError(error.InvalidScale, (Binding{ .source = .mouse_motion, .scale = -inf }).validate());
    try testing.expectError(error.InvalidThreshold, (Binding{ .source = .mouse_motion, .threshold = nan }).validate());
    try testing.expectError(error.InvalidDeadzone, (Binding{ .source = .mouse_motion, .deadzone = nan }).validate());
    try (Binding{ .source = .mouse_motion, .scale = -250 }).validate();
}

test "every kind refuses every source class its table does not list, and accepts the rest" {
    const by_class = [_]struct { name: []const u8, class: Class }{
        .{ .name = "key.e", .class = .button },
        .{ .name = "mouse.right", .class = .button },
        .{ .name = "mouse.wheel_down", .class = .button },
        .{ .name = "pad.west", .class = .button },
        .{ .name = "pad.left_trigger", .class = .axis },
        .{ .name = "pad.right_stick", .class = .stick },
        .{ .name = "mouse.motion", .class = .delta },
        .{ .name = "mouse.wheel", .class = .delta },
    };
    const table = [_]struct { kind: Kind, accepts: []const Class }{
        .{ .kind = .button, .accepts = &.{ .button, .axis } },
        .{ .kind = .axis, .accepts = &.{ .button, .axis } },
        .{ .kind = .vector, .accepts = &.{ .button, .axis, .stick } },
        .{ .kind = .delta, .accepts = &.{.delta} },
    };
    for (table) |row| for (by_class) |entry| {
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "foundry:input_action t:a {{ kind \"{t}\" contexts [ t:c ] bindings [ {{ source \"{s}\" }} ] }}", .{ row.kind, entry.name });
        var fault: Fault = .{};
        const result = try actionOf(text, &fault);
        const expected = std.mem.indexOfScalar(Class, row.accepts, entry.class) != null;
        if (expected) {
            const value = try result;
            try testing.expectEqual(@as(usize, 1), value.bindings().len);
        } else {
            try testing.expectError(error.SourceCannotFeedKind, result);
            try testing.expectEqual(@as(?u8, 0), fault.binding);
        }
    };
}

test "check answers for its two schemas and for no other" {
    var c: Compiled = undefined;
    try c.init("foundry:input_action t:a { kind \"delta\" contexts [ t:c ] bindings [ { source \"key.a\" } ] }");
    defer c.deinit();
    var fault: Fault = .{};
    const view = c.reader.record(0).?;
    try testing.expectError(error.SourceCannotFeedKind, check(view.schema_id, c.fields(), &fault).?);
    try testing.expect(check(SchemaId.fromStringUnchecked("foundry:texture"), c.fields(), &fault) == null);
    try testing.expectEqualStrings("input action", noun(action.id).?);
    try testing.expectEqualStrings("input context", noun(context.id).?);
    try testing.expect(noun(SchemaId.fromStringUnchecked("foundry:texture")) == null);
}
