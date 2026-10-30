//! M27's gallery (`docs/design/background.md` §11): eight framed panels whose 2048×2048
//! textures are the load background work exists to move off the frame.
//!
//! Nothing draws it until it is asked for: on `request_tick`, unless `FOUNDRY_SANDBOX3D_LOAD`
//! is `off`, or when a person presses G. Asking is a fixed tick or an input, so it is the
//! same in every run (I9). Only what is drawn depends on when the load finishes; the gallery
//! has no body, no collision and no rule.
//!
//! **Two paths** (§11). `background`, the default, is `requestModel`: the room keeps drawing
//! and the gallery appears on the first frame its last part has finished. `sync` is
//! `acquireModel` on the tick, which stalls that frame, and is the baseline §12 measures it
//! against. The window below records the frames either way.
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

/// How a load is made.
pub const Path = enum { sync, background };

/// How the gallery is loaded on its tick. `off` waits for G.
pub const Mode = enum {
    off,
    sync,
    background,

    /// `FOUNDRY_SANDBOX3D_LOAD`, `background` when unset. Anything else is said and waits
    /// for G, as the sample's other switches are: a measurement run that silently measured
    /// the wrong path is worse than one that measured nothing.
    pub fn parse(text: ?[]const u8) Mode {
        const value = std.mem.trim(u8, text orelse return .background, " ");
        if (std.meta.stringToEnum(Mode, value)) |mode| return mode;
        log.warn("FOUNDRY_SANDBOX3D_LOAD='{s}' is not sync, background or off; the gallery waits for G", .{value});
        return .off;
    }

    /// The path the tick takes, if it takes one.
    pub fn onTick(self: Mode) ?Path {
        return switch (self) {
            .off => null,
            .sync => .sync,
            .background => .background,
        };
    }

    /// The path G takes: the default's, unless the run asked for the baseline.
    pub fn onKey(self: Mode) Path {
        return if (self == .sync) .sync else .background;
    }
};

pub const Gallery = struct {
    mode: Mode = .off,
    model: render3d.ModelHandle = .none,
    window: Window = .{},
    started_ns: u64 = 0,

    /// `sync` loads the gallery now, on the calling thread; `background` asks for it and
    /// returns. Measured, never simulated: the readings only go into the window.
    pub fn request(self: *Gallery, content: *render3d.Content, path: Path, frame: u64, os: *platform.Os) void {
        if (!self.model.isNone()) return;
        const id = core.ContentId.fromString(model_id);
        const started = os.monotonicNanos();
        const handle = switch (path) {
            .sync => content.acquireModel(id),
            .background => content.requestModel(id),
        } catch |err| {
            log.warn("the gallery is not drawn ({t})", .{err});
            return;
        };
        self.model = handle;
        self.started_ns = started;
        self.window.start(frame, path);
        switch (path) {
            .sync => self.ready(frame, os),
            .background => log.info("gallery: requested on frame {d}", .{frame}),
        }
    }

    /// Once a frame, before it is drawn: notes the frame a requested gallery became ready.
    pub fn poll(self: *Gallery, content: *render3d.Content, frame: u64, os: *platform.Os) void {
        if (self.model.isNone() or self.window.ready != null or self.window.requested == null) return;
        const state = (content.modelState(self.model) catch |err| {
            log.warn("the gallery's state could not be read ({t})", .{err});
            return;
        }) orelse return;
        switch (state) {
            .pending => {},
            .ready => self.ready(frame, os),
            .failed => {
                log.warn("gallery: failed to load; it is not drawn", .{});
                self.window.requested = null;
            },
        }
    }

    fn ready(self: *Gallery, frame: u64, os: *platform.Os) void {
        const took: i64 = @intCast(os.monotonicNanos() - self.started_ns);
        self.window.markReady(frame, took);
        log.info("gallery: ready {s} in {d:.3}ms on frame {d}", .{
            if (self.window.path == .sync) "synchronously" else "in the background", ms(took), frame,
        });
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

    /// What the summary lines are said as, and the span counted as the pump: the gallery's,
    /// or M28's landmark's (`generated.zig`).
    label: []const u8 = "gallery",
    pump_span: []const u8 = "assets.pump",
    requested: ?u64 = null,
    ready: ?u64 = null,
    path: Path = .sync,
    load_ns: i64 = 0,
    work: [capacity]i64 = undefined,
    pump: [capacity]i64 = undefined,
    len: usize = 0,
    pump_len: usize = 0,
    // The window's worst frame: how far in it fell and what it spent over a millisecond on, so
    // a load frame can be told from the frame a build arrived in.
    worst_ns: i64 = 0,
    worst_at: usize = 0,
    worst_spans: [256]u8 = undefined,
    worst_spans_len: usize = 0,
    reported: bool = false,

    pub fn start(self: *Window, frame: u64, path: Path) void {
        self.* = .{ .label = self.label, .pump_span = self.pump_span, .requested = frame, .path = path };
    }

    /// The window closes `after_ready_frames` after this frame.
    pub fn markReady(self: *Window, frame: u64, load_ns: i64) void {
        self.ready = frame;
        self.load_ns = load_ns;
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
            if (std.mem.eql(u8, name, self.pump_span)) pump = (pump orelse 0) + span.durationNs();
        }
        const work = frame.total_ns - waiting;
        if (work > self.worst_ns) {
            self.worst_ns = work;
            self.worst_at = @intCast(frame.index - requested);
            var text: std.Io.Writer = .fixed(&self.worst_spans);
            for (frame.spans) |span| {
                if (span.durationNs() < core.time.ns_per_ms) continue;
                text.print("{s} {d:.1}, ", .{ recorder.nameOf(span.name), ms(span.durationNs()) }) catch break;
            }
            self.worst_spans_len = text.end;
        }
        if (self.len < capacity) {
            self.work[self.len] = work;
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
        log.info("{s}: frame work (no pacing sleep, image acquire or present) over {d} frames from the request: median {d:.3}ms p95 {d:.3}ms max {d:.3}ms; budget 16.67ms", .{
            self.label, work.count, ms(work.median_ns), ms(work.p95_ns), ms(work.max_ns),
        });
        log.info("{s}: worst frame {d} after the request, ready at {d}; spans over 1ms: {s}", .{
            self.label, self.worst_at, (self.ready orelse self.requested.?) - self.requested.?, self.worst_spans[0..self.worst_spans_len],
        });
        const pump = core.profile.summarise(self.pump[0..self.pump_len], &scratch);
        log.info("{s}: {s} over {d} frames: median {d:.3}ms p95 {d:.3}ms max {d:.3}ms; budget p95 2.0ms", .{
            self.label, self.pump_span, pump.count, ms(pump.median_ns), ms(pump.p95_ns), ms(pump.max_ns),
        });
        if (self.ready == null) {
            log.info("{s}: not ready by the end of the run ({t})", .{ self.label, self.path });
        } else log.info("{s}: request to ready {d:.3}ms ({t})", .{ self.label, ms(self.load_ns), self.path });
    }
};

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / core.time.ns_per_ms;
}

test "the load switch is background unless it names sync or off, and anything else waits for G" {
    const t = std.testing;
    try t.expectEqual(Mode.background, Mode.parse(null));
    try t.expectEqual(Mode.background, Mode.parse("background"));
    try t.expectEqual(Mode.sync, Mode.parse("sync"));
    try t.expectEqual(Mode.sync, Mode.parse(" sync "));
    try t.expectEqual(Mode.off, Mode.parse("off"));
    for ([_][]const u8{ "", "SYNC", "async" }) |bad| try t.expectEqual(Mode.off, Mode.parse(bad));
    try t.expectEqual(@as(?Path, null), Mode.off.onTick());
    try t.expectEqual(@as(?Path, .background), Mode.background.onTick());
    try t.expectEqual(Path.background, Mode.off.onKey());
    try t.expectEqual(Path.sync, Mode.sync.onKey());
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

    window.start(10, .sync);
    window.markReady(10, 250);
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

test "a background window counts from the request, through the pending frames, to sixty after ready" {
    const t = std.testing;
    var recorder = try core.profile.Recorder.init(t.allocator, .{ .history = 4 });
    defer recorder.deinit(t.allocator);
    var window: Window = .{};
    window.start(10, .background);
    for (10..20) |i| {
        recorder.beginFrame(i, .{ .ns = @intCast(i * 1000) });
        recorder.endFrame(.{ .ns = @intCast(i * 1000 + 100) });
        window.add(&recorder, 0);
    }
    // Not ready yet: nothing closes the window.
    try t.expectEqual(@as(usize, 10), window.len);
    try t.expect(!window.reported);
    window.markReady(20, 5);
    for (20..20 + after_ready_frames + 3) |i| {
        recorder.beginFrame(i, .{ .ns = @intCast(i * 1000) });
        recorder.endFrame(.{ .ns = @intCast(i * 1000 + 100) });
        window.add(&recorder, 0);
    }
    try t.expectEqual(@as(usize, 10 + after_ready_frames + 1), window.len);
    try t.expect(window.reported);
}
