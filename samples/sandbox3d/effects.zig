//! M29's effects corner (`docs/design/particles.md` §8): particle emitters from this sample's
//! package, run by `render3d.Particles`, beside M28's generated corner at `origin`.
//!
//! - **The torch**: an additive flame played from a 4×4 flipbook, over smoke that covers what
//!   is behind it and takes the room's ambient light.
//! - **The sparks**: velocity-stretched and additive under gravity, a burst every three seconds
//!   (180 ticks) of their own loop, and one more on **B**.
//! - **The fountain**: about 10,400 live particles, blended and sorted far to near, the budget's
//!   load.
//! - **The trail**: a world-space emitter carried on the orrery's moon, which leaves its
//!   particles where they were born.
//!
//! Every effect is a `foundry:particle_emitter` record and every look a `foundry:material`, so a
//! package after this one changes them with no code (`testdata/mods/embers`). **P** stands the
//! player on M28's patch facing them. `FOUNDRY_SANDBOX3D_EFFECTS=on|off` chooses, `on` when
//! unset. What is measured here is reported and never reaches simulation.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const platform = @import("platform");
const render3d = @import("render3d");
const generated = @import("generated.zig");

const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const ContentId = core.ContentId;
const log = core.log.scoped(.sandbox3d);

/// Past the +Z edge of M28's patch (whose half-side is 6.4 m), so P can stand the player on the
/// patch facing the effects, and off the tour's path.
pub const origin: Vec3 = .init(generated.origin.x, 0, 9.5);

pub const Mode = enum {
    off,
    on,

    /// `FOUNDRY_SANDBOX3D_EFFECTS`, `on` when unset. Anything else is said and treated as `off`.
    pub fn parse(text: ?[]const u8) Mode {
        const value = std.mem.trim(u8, text orelse return .on, " ");
        if (std.meta.stringToEnum(Mode, value)) |mode| return mode;
        log.warn("FOUNDRY_SANDBOX3D_EFFECTS='{s}' is not on or off; no effects corner", .{value});
        return .off;
    }
};

/// Each effect's record, where it stands, and its stream: a stable constant per instance, so a
/// run and the pinned test give the same particles (I9).
pub const Effect = enum(u8) {
    torch_flame,
    torch_smoke,
    sparks,
    fountain,
    trail,

    pub fn id(self: Effect) ContentId {
        return switch (self) {
            inline else => |e| comptime ContentId.fromString("sandbox3d:effects." ++ @tagName(e)),
        };
    }

    pub fn stream(self: Effect) u64 {
        return @intFromEnum(self) + 1;
    }

    /// Where it stands; the trail's is the moon's, every tick.
    pub fn transform(self: Effect) Mat4 {
        return Mat4.translation(switch (self) {
            .torch_flame => origin.add(.init(-3, 1.0, 0)),
            .torch_smoke => origin.add(.init(-3, 1.25, 0)),
            .sparks => origin.add(.init(0, 0.6, 0)),
            .fountain => origin.add(.init(3, 0, 0)),
            .trail => .zero,
        });
    }
};

/// The tick the fountain's state is said at, and the test pins (`effects_tests.zig`). `app`'s
/// first step is tick 1, so this is after 600 steps.
pub const pin_tick: u64 = 600;

pub const Effects = struct {
    particles: render3d.Particles,
    handles: [@typeInfo(Effect).@"enum".fields.len]?render3d.ParticleEmitterHandle = @splat(null),
    /// This frame's steps, added to `prepare`'s to make a frame's particle work.
    pending_step_ns: i64 = 0,
    step_times: generated.Timings = .{},
    prepare_times: generated.Timings = .{},
    frame_times: generated.Timings = .{},
    expand_times: generated.Timings = .{},
    upload_times: generated.Timings = .{},
    live_peak: u32 = 0,
    pinned: ?u64 = null,

    pub fn init(self: *Effects, gpa: std.mem.Allocator, renderer: *render3d.Renderer, content: *render3d.Content) !void {
        self.* = .{ .particles = try .init(gpa, renderer, content, .default) };
        self.create();
    }

    pub fn deinit(self: *Effects) void {
        self.particles.deinit();
    }

    /// Every effect whose record and material are there. One that is not is said once and
    /// left out; a later reload does not make it, because only an instance follows a reload.
    fn create(self: *Effects) void {
        for (&self.handles, 0..) |*slot, i| {
            const effect: Effect = @enumFromInt(i);
            slot.* = self.particles.create(.{ .emitter = effect.id(), .transform = effect.transform(), .stream = effect.stream() }) catch |err| blk: {
                log.warn("effects: {t} was not made ({t})", .{ effect, err });
                break :blk null;
            };
        }
    }

    fn handle(self: *const Effects, effect: Effect) ?render3d.ParticleEmitterHandle {
        return self.handles[@intFromEnum(effect)];
    }

    /// On the simulation tick. `moon` is the moon's world transform, which the trail follows.
    pub fn step(self: *Effects, engine: *app.Engine, tick: u64, dt: f32, moon: ?Mat4) void {
        if (moon) |m| if (self.handle(.trail)) |h| self.particles.setTransform(h, m) catch {};
        const started = engine.os.monotonicNanos(); // Measurement only.
        self.particles.step(tick, dt, engine.jobs()) catch |err| log.warn("effects: step failed ({t})", .{err});
        self.pending_step_ns += @intCast(engine.os.monotonicNanos() - started);
        if (tick == pin_tick) if (self.handle(.fountain)) |h| {
            self.pinned = self.particles.stateHash(h);
            log.info("effects: fountain state at tick {d} {x:0>16}", .{ pin_tick, self.pinned.? });
        };
    }

    /// B: the sparks' timeline starts again, so its burst at time 0 fires at the next step.
    pub fn burst(self: *Effects) void {
        const h = self.handle(.sparks) orelse return;
        self.particles.stop(h) catch {};
        self.particles.play(h) catch {};
    }

    /// After the camera is known and before `begin`.
    pub fn prepare(self: *Effects, engine: *app.Engine, view: render3d.FrameView) void {
        const clock: render3d.particles.Particles.Clock = .{ .context = engine.os, .nanos = osNanos };
        const started = engine.os.monotonicNanos(); // Measurement only.
        const timing = self.particles.prepareTimed(view, engine.jobs(), clock) catch |err| {
            log.warn("effects: prepare failed ({t})", .{err});
            return;
        };
        const spent: i64 = @intCast(engine.os.monotonicNanos() - started);
        self.prepare_times.add(spent);
        self.step_times.add(self.pending_step_ns);
        self.frame_times.add(spent + self.pending_step_ns);
        self.expand_times.add(@intCast(timing.expand_ns));
        self.upload_times.add(@intCast(timing.upload_ns));
        self.pending_step_ns = 0;
        var live: u32 = 0;
        for (self.handles) |maybe| if (maybe) |h| {
            live += self.particles.liveCount(h) orelse 0;
        };
        self.live_peak = @max(self.live_peak, live);
    }

    /// Inside the frame's window.
    pub fn draw(self: *Effects) !void {
        try self.particles.draw();
    }

    /// After `Content.contentChanged`.
    pub fn contentChanged(self: *Effects) void {
        self.particles.contentChanged() catch |err| log.warn("effects: could not follow a content change ({t})", .{err});
        if (self.handle(.torch_flame)) |h| log.info("effects: torch flame {f} kept, {d} live", .{ h, self.particles.liveCount(h).? });
    }

    /// The patch, a step in from its +Z edge, facing the effects along +Z.
    pub fn teleportTarget() Vec3 {
        return .init(origin.x, 1, 4.5);
    }

    /// Said once at the end of a run, in the gallery's style, for an evidence run to read.
    pub fn report(self: *const Effects) void {
        const frame = self.frame_times.summary();
        const s = self.step_times.summary();
        const p = self.prepare_times.summary();
        const e = self.expand_times.summary();
        const u = self.upload_times.summary();
        log.info("effects: {d} frames, peak {d} live; step + prepare median {d:.3}ms p95 {d:.3}ms max {d:.3}ms; budget p95 2.0ms", .{
            frame.count, self.live_peak, ms(frame.median_ns), ms(frame.p95_ns), ms(frame.max_ns),
        });
        log.info("effects: step p95 {d:.3}ms, prepare p95 {d:.3}ms (expand and sort {d:.3}ms, upload {d:.3}ms)", .{
            ms(s.p95_ns), ms(p.p95_ns), ms(e.p95_ns), ms(u.p95_ns),
        });
    }
};

fn osNanos(context: *anyopaque) u64 {
    const os: *platform.os.Os = @ptrCast(@alignCast(context));
    return os.monotonicNanos();
}

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
