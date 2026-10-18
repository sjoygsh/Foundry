//! M27's gallery (`docs/design/background.md` §11): eight framed panels whose 2048×2048
//! textures are the load background work exists to move off the frame.
//!
//! Nothing draws it until it is asked for: on `request_tick` when `FOUNDRY_SANDBOX3D_LOAD`
//! names a path, or when a person presses G. Asking is a fixed tick or an input, so it is the
//! same in every run (I9). Only what is drawn depends on when the load finishes; the gallery
//! has no body, no collision and no rule.
//!
//! **Step 3 has the synchronous path only**: `acquireModel` on the tick, which stalls that
//! frame. That is the baseline §12 measures, and what the window below records is the
//! evidence. Step 6 adds `background`, and makes it the default.
const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const render3d = @import("render3d");

const log = core.log.scoped(.sandbox3d);

pub const model_id = "sandbox3d:models.gallery";
/// Two seconds in: after the first frames' own loading has settled, and early enough that a
/// bounded run reaches it.
pub const request_tick: u64 = 120;
/// Frames recorded after the gallery is ready, as §12 asks.
pub const after_ready_frames: u64 = 60;

/// How the gallery is loaded on its tick. `off` waits for G.
pub const Mode = enum {
    off,
    sync,

    /// `FOUNDRY_SANDBOX3D_LOAD`. Anything else is said and ignored, as the sample's other
    /// switches are: a measurement run that silently measured the wrong path is worse than
    /// one that measured nothing.
    pub fn parse(text: ?[]const u8) Mode {
        const value = std.mem.trim(u8, text orelse return .off, " ");
        if (std.mem.eql(u8, value, "sync")) return .sync;
        if (std.mem.eql(u8, value, "background")) {
            log.warn("FOUNDRY_SANDBOX3D_LOAD=background does not exist until M27 Step 6; the gallery waits for G", .{});
        } else log.warn("FOUNDRY_SANDBOX3D_LOAD='{s}' is not sync; the gallery waits for G", .{value});
        return .off;
    }
};

pub const Gallery = struct {
    mode: Mode = .off,
    model: render3d.ModelHandle = .none,
    window: Window = .{},

    /// Loads the gallery now, on the calling thread. Measured, never simulated: the reading
    /// only goes into the window.
    pub fn request(self: *Gallery, content: *render3d.Content, frame: u64, os: *platform.Os) void {
        if (!self.model.isNone()) return;
        const started = os.monotonicNanos();
        const handle = content.acquireModel(core.ContentId.fromString(model_id)) catch |err| {
            log.warn("the gallery is not drawn ({t})", .{err});
            return;
        };
        const took: i64 = @intCast(os.monotonicNanos() - started);
        self.model = handle;
        self.window.start(frame, took);
        log.info("gallery: loaded synchronously in {d:.3}ms on frame {d}", .{ ms(took), frame });
    }

    pub fn release(self: *Gallery, content: *render3d.Content) void {
        if (self.model.isNone()) return;
        content.releaseModel(self.model);
        self.model = .none;
        log.info("gallery: released", .{});
    }
};

/// The frames from a request to `after_ready_frames` after it is ready (§12). A synchronous
/// load is ready on the frame that asked for it.
pub const Window = struct {
    const capacity = 512;

    requested: ?u64 = null,
    ready: ?u64 = null,
    load_ns: i64 = 0,
    work: [capacity]i64 = undefined,
    pump: [capacity]i64 = undefined,
    len: usize = 0,
    pump_len: usize = 0,
    reported: bool = false,

    pub fn start(self: *Window, frame: u64, load_ns: i64) void {
        self.* = .{ .requested = frame, .ready = frame, .load_ns = load_ns };
    }

    /// The frame the recorder last finished, less the time it spent waiting rather than
    /// working: acquiring and presenting the image, as the court counts them, and the pacing
    /// sleep, which this sample takes inside its frame.
    pub fn add(self: *Window, recorder: *const core.profile.Recorder, paced_ns: i64) void {
        const requested = self.requested orelse return;
        if (self.reported) return;
        const frame = recorder.latest() orelse return;
        if (frame.index < requested) return;
        var waiting: i64 = paced_ns;
        var pump: ?i64 = null;
        for (frame.spans) |span| {
            const name = recorder.nameOf(span.name);
            if (std.mem.eql(u8, name, "render.acquire") or std.mem.eql(u8, name, "render.present")) waiting += span.durationNs();
            if (std.mem.eql(u8, name, "assets.pump")) pump = (pump orelse 0) + span.durationNs();
        }
        if (self.len < capacity) {
            self.work[self.len] = frame.total_ns - waiting;
            self.len += 1;
        }
        if (pump) |p| if (self.pump_len < capacity) {
            self.pump[self.pump_len] = p;
            self.pump_len += 1;
        };
        if (self.ready) |ready| if (frame.index >= ready + after_ready_frames) self.report();
    }

    /// Said once, when the window closes or the run ends inside it.
    pub fn report(self: *Window) void {
        if (self.requested == null or self.reported) return;
        self.reported = true;
        var scratch: [capacity]i64 = undefined;
        const work = core.profile.summarise(self.work[0..self.len], &scratch);
        log.info("gallery: frame work (no pacing sleep, image acquire or present) over {d} frames from the request: median {d:.3}ms p95 {d:.3}ms max {d:.3}ms; budget 16.67ms", .{
            work.count, ms(work.median_ns), ms(work.p95_ns), ms(work.max_ns),
        });
        const pump = core.profile.summarise(self.pump[0..self.pump_len], &scratch);
        log.info("gallery: assets.pump over {d} frames: median {d:.3}ms p95 {d:.3}ms max {d:.3}ms; budget p95 2.0ms", .{
            pump.count, ms(pump.median_ns), ms(pump.p95_ns), ms(pump.max_ns),
        });
        log.info("gallery: request to ready {d:.3}ms (sync)", .{ms(self.load_ns)});
    }
};

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / core.time.ns_per_ms;
}

test "the load switch names the synchronous path, and anything else waits for G" {
    const t = std.testing;
    try t.expectEqual(Mode.off, Mode.parse(null));
    try t.expectEqual(Mode.sync, Mode.parse("sync"));
    try t.expectEqual(Mode.sync, Mode.parse(" sync "));
    for ([_][]const u8{ "", "SYNC", "background", "async" }) |bad| try t.expectEqual(Mode.off, Mode.parse(bad));
}

test "the window counts frame work from the request to sixty frames after ready, less waiting" {
    const t = std.testing;
    var recorder = try core.profile.Recorder.init(t.allocator, .{ .history = 4 });
    defer recorder.deinit(t.allocator);
    var window: Window = .{};

    const Frame = struct {
        fn record(r: *core.profile.Recorder, index: u64) void {
            const base: i64 = @intCast(index * 1000);
            r.beginFrame(index, .{ .ns = base });
            r.open("input", .{ .ns = base + 1 });
            r.close(.{ .ns = base + 2 });
            r.open("assets.pump", .{ .ns = base + 2 });
            r.close(.{ .ns = base + 5 });
            r.open("render.acquire", .{ .ns = base + 10 });
            r.close(.{ .ns = base + 30 });
            r.open("render.present", .{ .ns = base + 40 });
            r.close(.{ .ns = base + 47 });
            r.endFrame(.{ .ns = base + 100 });
        }
    };

    // Nothing is counted before a request.
    Frame.record(&recorder, 9);
    window.add(&recorder, 0);
    try t.expectEqual(@as(usize, 0), window.len);

    window.start(10, 250);
    Frame.record(&recorder, 9);
    window.add(&recorder, 0);
    try t.expectEqual(@as(usize, 0), window.len); // an earlier frame than the request

    for (10..10 + after_ready_frames + 5) |i| {
        Frame.record(&recorder, i);
        window.add(&recorder, 13);
    }
    // The request's frame, and sixty after it; then closed.
    try t.expectEqual(@as(usize, after_ready_frames + 1), window.len);
    try t.expect(window.reported);
    // 100, less 20 acquiring, 7 presenting and 13 pacing.
    try t.expectEqual(@as(i64, 60), window.work[0]);
    try t.expectEqual(@as(i64, 3), window.pump[0]);
    try t.expectEqual(window.len, window.pump_len);
}
