//! `FOUNDRY_COURT_PAD=xbox|playstation`: seats one virtual gamepad for the whole run, so a run
//! nobody plays still has a pad the court's actions read, a prompt can name, and the warden's
//! catch rumbles (`input.md` §11, M45 Step 8). At exit it says what rumble reached the pad.
//!
//! On SDL3 the pad is SDL's virtual joystick, found and mapped through the path a plugged-in pad
//! takes, so the rumble it reports is what a real pad's driver would have been handed. Headless it
//! is the null backend's scripted pad, whose last rumble the platform records. A sample's evidence
//! affordance, as `FOUNDRY_SANDBOX3D_SPIN` is; never a control. SDL drops a pad's events while no
//! window of the process is focused: a run from a shell sets
//! `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` for that process (Step 7's Resolution).
const std = @import("std");
const core = @import("core");
const app = @import("app");
const platform = @import("platform");
const log = core.log.scoped(.court);

const sdl = platform.backend == .sdl3;
const Virtual = if (sdl) platform.selected_backend.VirtualGamepad else struct {};
const Family = enum { xbox, playstation };
/// The null backend's device number for the scripted pad.
const null_device: platform.gamepad.DeviceId = 46;

pub const Pad = struct {
    family: ?Family = null,
    attached: bool = false,
    virtual: Virtual = .{},

    pub fn fromEnv(engine: *app.Engine) Pad {
        const text = engine.os.envVar("FOUNDRY_COURT_PAD") orelse return .{};
        const family = std.meta.stringToEnum(Family, text) orelse {
            log.warn("FOUNDRY_COURT_PAD is neither xbox nor playstation; no pad is seated", .{});
            return .{};
        };
        return .{ .family = family };
    }

    /// At an address that lasts until `deinit`, since SDL calls back into it for rumble.
    pub fn attach(self: *Pad, engine: *app.Engine) void {
        const family = self.family orelse return;
        self.seat(engine, family) catch |err| {
            log.warn("pad: no virtual pad ({t})", .{err});
            return;
        };
        self.attached = true;
        log.info("pad: a virtual {t} pad is attached", .{family});
    }

    fn seat(self: *Pad, engine: *app.Engine, family: Family) !void {
        if (sdl) return engine.platform.attachVirtualGamepad(&self.virtual, switch (family) {
            .xbox => .xbox,
            .playstation => .playstation,
        });
        const description: platform.selected_backend.PadDescription = switch (family) {
            .xbox => .{},
            .playstation => .{ .kind = .playstation, .face = .{ .cross, .circle, .square, .triangle } },
        };
        _ = (try engine.platform.connectGamepad(null_device, description)) orelse return error.Unsupported;
    }

    pub fn deinit(self: *Pad, engine: *app.Engine) void {
        if (!self.attached) return;
        if (sdl) {
            log.info("pad: {d} rumble(s) reached the pad, the last at {d} and {d} of 65535", .{ self.virtual.rumbles, self.virtual.low, self.virtual.high });
            engine.platform.detachVirtualGamepad(&self.virtual);
        } else {
            engine.platform.disconnectGamepad(null_device) catch {};
        }
        self.attached = false;
    }
};
