//! `input` as `FoundryApi_v8` publishes it (`docs/design/input.md` §10, ADR-0090).
//!
//! **Read-only, and as the tick sees it.** Inside a native system's callback every call answers
//! that step's tick view, so an edge or a delta reaches one step whatever the frame rate; anywhere
//! else it answers the frame's view. A mod's simulation therefore reads input exactly as the
//! game's does. Enabling contexts, writing bindings, capture, rumble and audio outputs are M48's,
//! by host grant: each changes what a player experiences or reveals the host.
//!
//! **The host supplies the input** (ADR-0026): without `Host.input` every call answers
//! `unavailable`. A null out-pointer is `invalid_argument` before the host is asked, as every
//! call in the table does (`sweep.zig`); a value is checked after.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const input = @import("input");

const types = @import("types.zig");
const input_types = @import("input_types.zig");

const ContentId = types.ContentId;
const Result = types.Result;
const Str = types.Str;
const Bool = types.Bool;

pub fn Of(comptime H: type) type {
    return struct {
        fn sources() ?*const @import("app").InputSources {
            const h = H.current() orelse return null;
            return h.input;
        }

        fn view(src: *const @import("app").InputSources) @import("app").InputSources.View {
            return if (H.inSystem()) src.tick else src.frame;
        }

        fn keyOf(number: u32) ?platform.Key {
            if (number >= platform.Key.count) return null;
            return @enumFromInt(number);
        }

        pub fn keyboard(out: ?*input_types.KeyboardState) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const src = sources() orelse return .unavailable;
            dst.* = input_types.keyboardOf(view(src).input);
            return .ok;
        }

        pub fn keyFromName(name: Str, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            _ = sources() orelse return .unavailable;
            const text = name.utf8() orelse return .invalid_argument;
            const key = platform.Key.fromName(text) orelse return .not_found;
            dst.* = @intFromEnum(key);
            return .ok;
        }

        pub fn keyName(key: u32, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            _ = sources() orelse return .unavailable;
            const k = keyOf(key) orelse return .invalid_argument;
            // Static storage: a tag name lives as long as the image.
            dst.* = .from(k.name());
            return .ok;
        }

        pub fn keyLabel(key: u32, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const src = h.input orelse return .unavailable;
            const k = keyOf(key) orelse return .invalid_argument;
            // Copied into the host, so a label borrowed by a mod never points into a platform
            // buffer the next pump may rewrite. Valid until the next `input_key_label`.
            var buf: [platform.key.label_capacity]u8 = undefined;
            const label = src.keyLabel(k, &buf);
            @memcpy(h.input_label[0..label.len], label);
            dst.* = .from(h.input_label[0..label.len]);
            return .ok;
        }

        pub fn mouse(out: ?*input_types.MouseState) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const src = sources() orelse return .unavailable;
            dst.* = input_types.mouseOf(view(src).input);
            return .ok;
        }

        pub fn gamepadSlots(out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            _ = sources() orelse return .unavailable;
            dst.* = input_types.gamepad_slots;
            return .ok;
        }

        pub fn gamepad(slot: u32, out: ?*input_types.GamepadState) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const src = sources() orelse return .unavailable;
            if (slot >= input_types.gamepad_slots) return .invalid_argument;
            dst.* = input_types.gamepadOf(&view(src).input.gamepads[slot]);
            return .ok;
        }

        pub fn action(id: ContentId, out: ?*input_types.ActionState) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const src = sources() orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;
            const frame = view(src).actions;
            const at = frame.find(id) orelse return .not_found;
            dst.* = input_types.actionOf(frame.states[at], frame.kinds[at]);
            return .ok;
        }

        pub fn actionBindingCount(id: ContentId, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const src = sources() orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;
            const a = src.map.action(id) orelse return .not_found;
            dst.* = a.binding_count;
            return .ok;
        }

        pub fn actionBinding(id: ContentId, index: u32, out: ?*input_types.Binding) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const src = h.input orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;
            const a = src.map.action(id) orelse return .not_found;
            if (index >= a.binding_count) return .invalid_argument;
            const b = a.bindings()[index];
            // Copied into the host, as a label is. Valid until the next `input_action_binding`.
            var buf: [input.source.max_name]u8 = undefined;
            const name = b.source.name(&buf);
            @memcpy(h.input_source_text[0..name.len], name);
            dst.* = .{
                .source = .from(h.input_source_text[0..name.len]),
                .axis = switch (b.axis) {
                    .x => input_types.axis_x,
                    .y => input_types.axis_y,
                },
                .scale = b.scale,
                .threshold = b.threshold,
                .deadzone = b.deadzone,
                .overridden = types.boolOut(src.overridden(id)),
            };
            return .ok;
        }

        pub fn contextEnabled(id: ContentId, out: ?*Bool) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const src = sources() orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;
            if (src.map.findContext(id) == null) return .not_found;
            dst.* = types.boolOut(src.actions.isEnabled(id));
            return .ok;
        }
    };
}

// -- tests -------------------------------------------------------------------------------

const app = @import("app");
const scene = @import("scene");
const host_mod = @import("host.zig");
const api = @import("api.zig");
const test_engine = @import("test_engine.zig");
const testing = std.testing;
const gpa = testing.allocator;

const Host = host_mod.HostOf(test_engine.TestEngine);
const table = api.TableOf(Host).v8;

const content =
    \\foundry:input_context t:context.walk { priority 10 }
    \\foundry:input_context t:context.menu { priority 20 blocks true }
    \\foundry:input_action t:action.jump {
    \\    kind "button"
    \\    contexts [ t:context.walk ]
    \\    bindings [ { source "key.space" } { source "pad.south" } ]
    \\}
    \\foundry:input_action t:action.move {
    \\    kind "vector"
    \\    contexts [ t:context.walk ]
    \\    bindings [ { source "key.w" axis "y" } { source "pad.left_stick" deadzone 0.2 } ]
    \\}
    \\foundry:input_action t:action.pause {
    \\    kind "button"
    \\    rebindable false
    \\    contexts [ t:context.walk t:context.menu ]
    \\    bindings [ { source "key.escape" } ]
    \\}
;

fn cid(text: []const u8) ContentId {
    return core.ContentId.fromString(text);
}

/// A map, enabled contexts, overrides and two views made by hand, as a host's would be.
const Fixture = struct {
    store: input.map.Fixture,
    base: input.Map,
    map: input.Map,
    actions: input.Actions,
    overrides: input.Overrides = .empty,
    frame_input: platform.InputSnapshot = .{},
    tick_input: platform.InputSnapshot = .{},
    frame_actions: input.Frame = .empty,
    tick_actions: input.Frame = .empty,
    sources: app.InputSources = undefined,

    fn init(self: *Fixture) !void {
        self.* = .{ .store = .init(), .base = .empty, .map = .empty, .actions = undefined };
        try self.store.add("t", content);
        self.base = try self.store.build();
        // The player rebinds jump to J, and tries to rebind pause, which is not rebindable.
        try self.overrides.set(gpa, cid("t:action.jump"), &.{.{ .source = .{ .key = .j } }});
        try self.overrides.set(gpa, cid("t:action.pause"), &.{.{ .source = .{ .key = .p } }});
        self.map = try self.base.apply(gpa, &self.overrides);
        self.actions = .init(&self.map);
        try self.actions.enable(cid("t:context.walk"));
        // The frame saw J pressed; the step being simulated saw it held, its edge taken earlier.
        platform.key.setKey(&self.frame_input.keys_held, .j, true);
        platform.key.setKey(&self.frame_input.keys_pressed, .j, true);
        self.frame_input.focused = true;
        self.frame_input.mouse.motion = .{ .x = 3, .y = -1 };
        self.frame_input.mouse.motion_unit = .counts;
        self.frame_input.gamepads[1] = .{ .connected = true, .handle = .{ .index = 1, .generation = 2 }, .kind = .playstation, .face = .{ .cross, .circle, .square, .triangle } };
        self.frame_input.gamepads[1].axes[@intFromEnum(platform.GamepadAxis.left_y)] = 0.5;
        platform.key.setKey(&self.tick_input.keys_held, .j, true);
        self.tick_input.focused = true;
        self.frame_actions = self.actions.evaluate(&self.frame_input, .{}).*;
        self.tick_actions = self.actions.evaluate(&self.tick_input, .{}).*;
        self.sources = .{
            .frame = .{ .input = &self.frame_input, .actions = &self.frame_actions },
            .tick = .{ .input = &self.tick_input, .actions = &self.tick_actions },
            .map = &self.map,
            .actions = &self.actions,
            .overrides = &self.overrides,
        };
    }

    fn deinit(self: *Fixture) void {
        self.overrides.deinit(gpa);
        self.map.deinit(gpa);
        self.base.deinit(gpa);
        self.store.deinit();
    }
};

fn bit(words: [4]u64, key: platform.Key) bool {
    const n: usize = @intFromEnum(key);
    return words[n / 64] & (@as(u64, 1) << @intCast(n % 64)) != 0;
}

test "v8 input answers every call from the frame view outside a system" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var host: Host = .{ .input = &f.sources };
    host.bind();
    defer host.unbind();

    var keys: input_types.KeyboardState = undefined;
    try testing.expectEqual(Result.ok, table.input_keyboard(&keys));
    try testing.expect(bit(keys.held, .j) and bit(keys.pressed, .j) and !bit(keys.released, .j));
    try testing.expectEqual(@as(Bool, 1), keys.focused);

    var number: u32 = 0;
    try testing.expectEqual(Result.ok, table.input_key_from_name(.from("left_shift"), &number));
    try testing.expectEqual(@as(u32, @intFromEnum(platform.Key.left_shift)), number);
    var name: Str = .empty;
    try testing.expectEqual(Result.ok, table.input_key_name(number, &name));
    try testing.expectEqualStrings("left_shift", name.bytes().?);
    try testing.expectEqual(Result.ok, table.input_key_label(@intFromEnum(platform.Key.q), &name));
    try testing.expectEqualStrings("q", name.bytes().?);
    try testing.expectEqual(Result.ok, table.input_key_label(0, &name));
    try testing.expectEqual(@as(u64, 0), name.len);

    var m: input_types.MouseState = undefined;
    try testing.expectEqual(Result.ok, table.input_mouse(&m));
    try testing.expectEqual(@as(f32, 3), m.motion_x);
    try testing.expectEqual(input_types.motion_counts, m.motion_unit);

    var slots: u32 = 0;
    try testing.expectEqual(Result.ok, table.input_gamepad_slots(&slots));
    try testing.expectEqual(@as(u32, 4), slots);
    var pad: input_types.GamepadState = undefined;
    try testing.expectEqual(Result.ok, table.input_gamepad(1, &pad));
    try testing.expectEqual(@as(Bool, 1), pad.connected);
    try testing.expectEqual(@as(i32, 2), pad.kind);
    try testing.expectEqual(@as(u32, 2), pad.generation);
    try testing.expectEqual(@as(f32, 0.5), pad.axes[1]);
    try testing.expectEqual(@as(u8, @intFromEnum(platform.ButtonLabel.cross)), pad.face[0]);
    try testing.expectEqual(Result.ok, table.input_gamepad(0, &pad));
    try testing.expectEqual(@as(Bool, 0), pad.connected);

    var state: input_types.ActionState = undefined;
    try testing.expectEqual(Result.ok, table.input_action(cid("t:action.jump"), &state));
    try testing.expect(state.held == 1 and state.pressed == 1 and state.released == 0);
    try testing.expectEqual(@as(i32, 0), state.kind);
    try testing.expectEqual(Result.ok, table.input_action(cid("t:action.move"), &state));
    try testing.expectEqual(@as(i32, 2), state.kind);

    var count: u32 = 0;
    var binding: input_types.Binding = undefined;
    // Jump's effective bindings are the player's J alone, overridden.
    try testing.expectEqual(Result.ok, table.input_action_binding_count(cid("t:action.jump"), &count));
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(Result.ok, table.input_action_binding(cid("t:action.jump"), 0, &binding));
    try testing.expectEqualStrings("key.j", binding.source.bytes().?);
    try testing.expectEqual(@as(Bool, 1), binding.overridden);
    // Pause's override is ignored: its default stands, and it does not say overridden.
    try testing.expectEqual(Result.ok, table.input_action_binding(cid("t:action.pause"), 0, &binding));
    try testing.expectEqualStrings("key.escape", binding.source.bytes().?);
    try testing.expectEqual(@as(Bool, 0), binding.overridden);
    try testing.expectEqual(Result.ok, table.input_action_binding(cid("t:action.move"), 1, &binding));
    try testing.expectEqualStrings("pad.left_stick", binding.source.bytes().?);
    try testing.expectEqual(@as(f32, 0.2), binding.deadzone);
    try testing.expectEqual(Result.ok, table.input_action_binding(cid("t:action.move"), 0, &binding));
    try testing.expectEqual(input_types.axis_y, binding.axis);

    var on: Bool = 9;
    try testing.expectEqual(Result.ok, table.input_context_enabled(cid("t:context.walk"), &on));
    try testing.expectEqual(@as(Bool, 1), on);
    try testing.expectEqual(Result.ok, table.input_context_enabled(cid("t:context.menu"), &on));
    try testing.expectEqual(@as(Bool, 0), on);
}

test "v8 input refuses a bad pointer, slot, key number, name, action or context by name" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var host: Host = .{ .input = &f.sources };
    host.bind();
    defer host.unbind();

    var number: u32 = 77;
    var name: Str = .empty;
    var pad: input_types.GamepadState = .{};
    var state: input_types.ActionState = .{};
    var binding: input_types.Binding = .{};
    var on: Bool = 0;
    // Null out-pointers.
    try testing.expectEqual(Result.invalid_argument, table.input_keyboard(null));
    try testing.expectEqual(Result.invalid_argument, table.input_mouse(null));
    try testing.expectEqual(Result.invalid_argument, table.input_gamepad_slots(null));
    try testing.expectEqual(Result.invalid_argument, table.input_gamepad(0, null));
    try testing.expectEqual(Result.invalid_argument, table.input_key_name(1, null));
    try testing.expectEqual(Result.invalid_argument, table.input_key_label(1, null));
    try testing.expectEqual(Result.invalid_argument, table.input_key_from_name(.from("a"), null));
    try testing.expectEqual(Result.invalid_argument, table.input_action(cid("t:action.jump"), null));
    try testing.expectEqual(Result.invalid_argument, table.input_action_binding_count(cid("t:action.jump"), null));
    try testing.expectEqual(Result.invalid_argument, table.input_action_binding(cid("t:action.jump"), 0, null));
    try testing.expectEqual(Result.invalid_argument, table.input_context_enabled(cid("t:context.walk"), null));
    // A slot past four, a key number past the last, a name that is not UTF-8 or not a key.
    try testing.expectEqual(Result.invalid_argument, table.input_gamepad(4, &pad));
    try testing.expectEqual(Result.invalid_argument, table.input_key_name(platform.Key.count, &name));
    try testing.expectEqual(Result.invalid_argument, table.input_key_label(std.math.maxInt(u32), &name));
    try testing.expectEqual(Result.invalid_argument, table.input_key_from_name(.{ .ptr = "\xff".ptr, .len = 1 }, &number));
    try testing.expectEqual(Result.not_found, table.input_key_from_name(.from("hyper"), &number));
    try testing.expectEqual(@as(u32, 77), number);
    // No id, an unknown action, an index past its bindings, an unknown context.
    try testing.expectEqual(Result.invalid_argument, table.input_action(.none, &state));
    try testing.expectEqual(Result.not_found, table.input_action(cid("t:action.fly"), &state));
    try testing.expectEqual(Result.not_found, table.input_action_binding_count(cid("t:action.fly"), &number));
    try testing.expectEqual(Result.not_found, table.input_action_binding(cid("t:action.fly"), 0, &binding));
    try testing.expectEqual(Result.invalid_argument, table.input_action_binding(cid("t:action.jump"), 1, &binding));
    try testing.expectEqual(Result.not_found, table.input_context_enabled(cid("t:context.swim"), &on));
    // An action is not a context.
    try testing.expectEqual(Result.not_found, table.input_context_enabled(cid("t:action.jump"), &on));
}

test "v8 input with no source answers unavailable to every call" {
    var host: Host = .{};
    host.bind();
    defer host.unbind();
    var number: u32 = 0;
    var name: Str = .empty;
    var keys: input_types.KeyboardState = .{};
    var m: input_types.MouseState = .{};
    var pad: input_types.GamepadState = .{};
    var state: input_types.ActionState = .{};
    var binding: input_types.Binding = .{};
    var on: Bool = 0;
    try testing.expectEqual(Result.unavailable, table.input_keyboard(&keys));
    try testing.expectEqual(Result.unavailable, table.input_key_from_name(.from("a"), &number));
    try testing.expectEqual(Result.unavailable, table.input_key_name(1, &name));
    try testing.expectEqual(Result.unavailable, table.input_key_label(1, &name));
    try testing.expectEqual(Result.unavailable, table.input_mouse(&m));
    try testing.expectEqual(Result.unavailable, table.input_gamepad_slots(&number));
    try testing.expectEqual(Result.unavailable, table.input_gamepad(0, &pad));
    try testing.expectEqual(Result.unavailable, table.input_action(cid("t:action.jump"), &state));
    try testing.expectEqual(Result.unavailable, table.input_action_binding_count(cid("t:action.jump"), &number));
    try testing.expectEqual(Result.unavailable, table.input_action_binding(cid("t:action.jump"), 0, &binding));
    try testing.expectEqual(Result.unavailable, table.input_context_enabled(cid("t:context.walk"), &on));
}

/// What a native system saw, written by its callback.
const Seen = struct {
    key_pressed: bool = false,
    key_held: bool = false,
    jump_pressed: bool = false,
    jump_held: bool = false,
    calls: u32 = 0,
};

fn seeSystem(ctx: ?*anyopaque, _: ?*const types.Step) callconv(.c) void {
    const seen: *Seen = @ptrCast(@alignCast(ctx.?));
    var keys: input_types.KeyboardState = undefined;
    var state: input_types.ActionState = undefined;
    if (table.input_keyboard(&keys) != .ok or table.input_action(cid("t:action.jump"), &state) != .ok) return;
    seen.key_pressed = bit(keys.pressed, .j);
    seen.key_held = bit(keys.held, .j);
    seen.jump_pressed = state.pressed == 1;
    seen.jump_held = state.held == 1;
    seen.calls += 1;
}

test "v8 input answers the tick view inside a system and the frame view outside it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var engine: test_engine.TestEngine = try .init(gpa);
    defer engine.deinit();
    engine.settle();
    var world: scene.World = .init(gpa, &engine.schemas, .default);
    defer world.deinit();
    var host: Host = .{ .engine = &engine, .input = &f.sources, .world = &world };
    host.bind();
    defer host.unbind();
    const owner = try host.issueMod(cid("t:mod"), "t:mod");

    var seen: Seen = .{};
    const desc: types.SystemDesc = .{ .id = cid("t:systems.see"), .name = .from("t:systems.see"), .ctx = &seen, .update = seeSystem };
    try testing.expectEqual(Result.ok, api.TableOf(Host).v1.world_register_system(owner, &desc));
    world.update(.{ .tick = 1, .delta = .fromMillis(16) });
    try testing.expectEqual(@as(u32, 1), seen.calls);
    // The step: J held, its press already taken by an earlier step.
    try testing.expect(seen.key_held and !seen.key_pressed);
    try testing.expect(seen.jump_held and !seen.jump_pressed);
    // Outside, the frame's: the press is there.
    var state: input_types.ActionState = undefined;
    try testing.expectEqual(Result.ok, table.input_action(cid("t:action.jump"), &state));
    try testing.expectEqual(@as(Bool, 1), state.pressed);
    try testing.expect(!Host.inSystem());
}
