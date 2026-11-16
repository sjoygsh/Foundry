//! `FOUNDRY_SANDBOX3D_SPIN=<from>-<to>`: holds a gamepad's north button over those frames, so a
//! run nobody watches proves `orbiter` spinning on its own action (`input.md` §10, M45 Step 7).
//!
//! The pad is real to everything above `platform`: on SDL3 it is SDL's virtual joystick, found,
//! mapped and reported through the same path a plugged-in pad takes, and headless it is the null
//! backend's scripted pad. Either way the press reaches the snapshot, the actions, the tick view,
//! `FoundryApi_v8` and the mod, and nothing is handed to the mod around them. A sample's evidence
//! affordance, as `FOUNDRY_SANDBOX3D_KEYS` is; never a control.

const std = @import("std");
const core = @import("core");
const app = @import("app");
const platform = @import("platform");
const log = core.log.scoped(.sandbox3d);

const sdl = platform.backend == .sdl3;
const Pad = if (sdl) platform.selected_backend.VirtualGamepad else struct {};
/// The null backend's device number for the scripted pad.
const null_device: platform.gamepad.DeviceId = 45;

pub const Spin = struct {
    from: u64 = 0,
    to: u64 = 0,
    active: bool = false,
    attached: bool = false,
    held: bool = false,
    pad: Pad = .{},

    pub fn parse(text: []const u8) ?Spin {
        const dash = std.mem.indexOfScalar(u8, text, '-') orelse return null;
        const from = std.fmt.parseInt(u64, std.mem.trim(u8, text[0..dash], " "), 10) catch return null;
        const to = std.fmt.parseInt(u64, std.mem.trim(u8, text[dash + 1 ..], " "), 10) catch return null;
        if (from == 0 or to <= from) return null;
        return .{ .from = from, .to = to, .active = true };
    }

    pub fn fromEnv(engine: *app.Engine) Spin {
        const text = engine.os.envVar("FOUNDRY_SANDBOX3D_SPIN") orelse return .{};
        return parse(text) orelse {
            log.warn("FOUNDRY_SANDBOX3D_SPIN is not <from>-<to> frames; ignoring it", .{});
            return .{};
        };
    }

    /// Before `beginFrame`, so what it sets is pumped into this frame's snapshot. The pad is
    /// attached on the first frame, so SDL has seated it before `from`.
    pub fn frame(self: *Spin, engine: *app.Engine) void {
        if (!self.active) return;
        const at = engine.frame_index;
        if (!self.attached) {
            self.attach(engine) catch |err| {
                log.warn("spin: no virtual pad ({t}); nothing is pressed", .{err});
                self.active = false;
                return;
            };
            self.attached = true;
            log.info("spin: a virtual pad holds north over frames {d} to {d}", .{ self.from, self.to });
        }
        const want = at >= self.from and at < self.to;
        if (want == self.held) return;
        self.held = want;
        self.press(engine, want);
        // What the last snapshot said, so a run shows why a press did not arrive: SDL drops a
        // pad's events while no window of the process has focus.
        const seated = for (engine.input.gamepads) |pad| {
            if (pad.connected) break true;
        } else false;
        log.info("spin: north {s} at frame {d} (window {s}, pad {s})", .{ if (want) "down" else "up", at, if (engine.input.focused) "focused" else "not focused", if (seated) "seated" else "not seated" });
    }

    pub fn deinit(self: *Spin, engine: *app.Engine) void {
        if (!self.attached) return;
        if (sdl) engine.platform.detachVirtualGamepad(&self.pad) else engine.platform.disconnectGamepad(null_device) catch {};
        self.attached = false;
    }

    fn attach(self: *Spin, engine: *app.Engine) !void {
        if (sdl) return engine.platform.attachVirtualGamepad(&self.pad, .xbox);
        _ = (try engine.platform.connectGamepad(null_device, .{})) orelse return error.Unsupported;
    }

    fn press(self: *Spin, engine: *app.Engine, down: bool) void {
        if (sdl) {
            if (!engine.platform.setVirtualGamepadButton(&self.pad, .north, down)) log.warn("spin: SDL refused the button", .{});
        } else {
            engine.platform.setGamepadButton(null_device, .north, down) catch |err| log.warn("spin: {t}", .{err});
        }
    }
};

test "a spin is <from>-<to> frames, and anything else is refused" {
    const s = Spin.parse("60-180").?;
    try std.testing.expectEqual(@as(u64, 60), s.from);
    try std.testing.expectEqual(@as(u64, 180), s.to);
    for ([_][]const u8{ "", "60", "0-10", "10-10", "x-20", "20-x" }) |bad| try std.testing.expect(Spin.parse(bad) == null);
}
