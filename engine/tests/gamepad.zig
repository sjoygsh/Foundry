//! Gamepads through SDL3 on this machine, driven by SDL's virtual joysticks (M45 Step 2,
//! `docs/design/input.md` §4.3).
//!
//! **Not part of `zig build test`.** These start SDL's real gamepad subsystem, its HID and
//! platform drivers included, which a headless build machine may refuse, so `zig build
//! gamepad-test` runs them on a desktop and `check` compiles them so they cannot rot between
//! runs. They open no window and take no focus: SDL delivers pad events to a process with no
//! window. A virtual pad goes through SDL's discovery, mapping and event path, so this proves the
//! backend's translation, the slots and removal; a person with a physical pad proves the drivers
//! beneath (§12).

const std = @import("std");
const platform = @import("platform");

const testing = std.testing;
const Platform = platform.Platform;
const VirtualGamepad = platform.selected_backend.VirtualGamepad;

/// Pumps until `done` holds of the platform's snapshot, at most a bounded number of frames. SDL
/// updates a virtual pad's state at the pump, and hotplug is delivered over one or two, so a
/// single pump is not always enough.
fn pumpUntil(p: *Platform, comptime done: fn (*const platform.InputSnapshot) bool) !platform.InputSnapshot {
    var snap: platform.InputSnapshot = undefined;
    for (0..200) |_| {
        p.pumpEvents();
        snap = p.captureInput();
        if (done(&snap)) return snap;
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

fn firstConnected(snap: *const platform.InputSnapshot) bool {
    return snap.gamepads[0].connected;
}

fn countConnected(snap: *const platform.InputSnapshot) usize {
    var n: usize = 0;
    for (snap.gamepads) |pad| n += @intFromBool(pad.connected);
    return n;
}

/// This machine may already have pads attached, which would take slots first. The test runs
/// only on a machine with none, and says so.
fn requireNoPads(p: *Platform) !void {
    for (0..10) |_| {
        p.pumpEvents();
        const snap = p.captureInput();
        if (countConnected(&snap) != 0) {
            std.debug.print("gamepad-test: a physical pad is connected; unplug it for this test\n", .{});
            return error.SkipZigTest;
        }
    }
}

test "a virtual pad is seated, labelled, and drives buttons and axes" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    try requireNoPads(p);

    var xbox: VirtualGamepad = .{};
    try p.attachVirtualGamepad(&xbox, .xbox);
    defer p.detachVirtualGamepad(&xbox);
    const seated = try pumpUntil(p, firstConnected);
    const pad = seated.gamepads[0];
    try testing.expectEqual(@as(u32, 0), pad.handle.index);
    try testing.expectEqual(platform.GamepadKind.xbox, pad.kind);
    try testing.expectEqual(platform.ButtonLabel.a, pad.labelOf(.south));
    try testing.expectEqual(platform.ButtonLabel.y, pad.labelOf(.north));

    try testing.expect(p.setVirtualGamepadButton(&xbox, .south, true));
    try testing.expect(p.setVirtualGamepadButton(&xbox, .left_paddle1, true));
    // Pushed away from the player: SDL's negative, Foundry's +y.
    try testing.expect(p.setVirtualGamepadAxis(&xbox, .left_y, -32768));
    try testing.expect(p.setVirtualGamepadAxis(&xbox, .right_x, 16384));
    try testing.expect(p.setVirtualGamepadAxis(&xbox, .right_trigger, 32767));
    const pressed = try pumpUntil(p, struct {
        fn f(snap: *const platform.InputSnapshot) bool {
            const s = snap.gamepads[0];
            return s.isHeld(.south) and s.isHeld(.left_paddle1) and s.axis(.left_y) != 0 and s.axis(.right_trigger) != 0 and s.axis(.right_x) != 0;
        }
    }.f);
    const held = pressed.gamepadState(pad.handle).?;
    try testing.expect(held.wasPressed(.south));
    try testing.expect(!held.isHeld(.right_paddle1));
    try testing.expectEqual(@as(f32, 1), held.axis(.left_y));
    try testing.expectApproxEqAbs(@as(f32, 0.5), held.axis(.right_x), 1e-4);
    try testing.expectEqual(@as(f32, 1), held.axis(.right_trigger));

    try testing.expect(p.setVirtualGamepadButton(&xbox, .south, false));
    const released = try pumpUntil(p, struct {
        fn f(snap: *const platform.InputSnapshot) bool {
            return !snap.gamepads[0].isHeld(.south);
        }
    }.f);
    try testing.expect(released.gamepads[0].wasReleased(.south));

    // Rumble reaches the pad's driver as 16-bit motor levels, and a refusal reaches no driver.
    try p.setGamepadRumble(pad.handle, 1, 0.5, 200);
    try testing.expectEqual(@as(u16, 65535), xbox.low);
    try testing.expectEqual(@as(u16, 32768), xbox.high);
    const rumbles = xbox.rumbles;
    try testing.expectError(error.InvalidRumble, p.setGamepadRumble(pad.handle, 2, 0, 200));
    try testing.expectEqual(rumbles, xbox.rumbles);
}

test "pads take slots in order, a fifth waits, and removal frees a slot for it" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    try requireNoPads(p);

    var pads: [5]VirtualGamepad = @splat(.{});
    var attached: usize = 0;
    defer for (pads[0..attached]) |*v| p.detachVirtualGamepad(v);
    for (&pads, 0..) |*v, i| {
        // One at a time, so the connection order is the order attached.
        try p.attachVirtualGamepad(v, if (i == 1) .playstation else .xbox);
        attached += 1;
        if (i < 4) {
            const want = i + 1;
            var snap: platform.InputSnapshot = undefined;
            for (0..200) |_| {
                p.pumpEvents();
                snap = p.captureInput();
                if (countConnected(&snap) == want) break;
            } else return error.Timeout;
        }
    }
    // Let the fifth arrive; it takes no slot.
    for (0..20) |_| p.pumpEvents();
    const full = p.captureInput();
    try testing.expectEqual(@as(usize, 4), countConnected(&full));
    try testing.expectEqual(platform.GamepadKind.playstation, full.gamepads[1].kind);
    try testing.expectEqual(platform.ButtonLabel.cross, full.gamepads[1].labelOf(.south));
    const second = full.gamepads[1].handle;

    // The fifth's buttons go nowhere while it waits.
    try testing.expect(p.setVirtualGamepadButton(&pads[4], .north, true));
    try testing.expect(p.setVirtualGamepadButton(&pads[1], .east, true));
    for (0..5) |_| p.pumpEvents();
    var waiting = p.captureInput();
    for (waiting.gamepads) |pad| try testing.expect(!pad.isHeld(.north));

    // Player two unplugs: the waiting pad takes slot 1 under a new handle.
    p.detachVirtualGamepad(&pads[1]);
    waiting = try pumpUntil(p, struct {
        fn f(snap: *const platform.InputSnapshot) bool {
            return snap.gamepads[1].connected and snap.gamepads[1].kind == .xbox;
        }
    }.f);
    try testing.expectEqual(@as(?*const platform.GamepadState, null), waiting.gamepadState(second));
    try testing.expect(!waiting.gamepads[1].handle.eql(second));
    try testing.expectEqual(second.index, waiting.gamepads[1].handle.index);
    try testing.expectError(error.InvalidGamepad, p.setGamepadRumble(second, 0.5, 0.5, 100));
    try testing.expectEqual(@as(usize, 4), countConnected(&waiting));
}

test "with gamepads off, a virtual pad cannot even be attached" {
    const p = try Platform.init(testing.allocator, .{ .gamepads = false });
    defer p.deinit();
    var v: VirtualGamepad = .{};
    try testing.expectError(error.Unsupported, p.attachVirtualGamepad(&v, .xbox));
}
