//! Where the frame went, and what it drew (`debug-overlay.md` §4, §10.3).

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core");
const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

/// How many frame totals the plot holds. The recorder's default history, so the plot shows
/// everything the recorder kept and nothing it did not.
pub const plot_samples = 240;

/// How many spans are listed. A frame with more than this has a nesting problem the list
/// would not have helped with anyway.
pub const max_spans = 32;

pub const State = struct {
    /// The plot's samples. Fixed and allocated with the overlay, because the panel must not
    /// allocate outside the frame arena while describing (§12) and `ui.plot` draws a
    /// caller's samples rather than keeping its own.
    samples: [plot_samples]f32 = @splat(0),
    /// Set when there is no profiler, so the plot keeps working off `frameDelta` instead.
    head: usize = 0,

    pub fn describe(ctx: ?*anyopaque, view: *View) anyerror!void {
        const self: *State = @ptrCast(@alignCast(ctx.?));

        const recorder = view.frame.profiler orelse {
            // An answer, not an absence: the profiler is a `Config` field and off in release
            // builds by default, and a panel that showed an empty plot instead of saying so
            // would send somebody hunting for a bug in the engine.
            try view.line("profiler off (Config.profiler)", .{});
            try self.plotDelta(view);
            try describeRenderer(view);
            try describeAudio(view);
            return;
        };

        const frame = recorder.latest() orelse {
            try view.line("profiler on, no frame recorded yet", .{});
            return;
        };

        // p95 over the history rather than over the last frame, because the number a person
        // is hunting is the hitch and the last frame is almost never it. `summarise`
        // allocates nothing; the scratch is the frame arena's.
        const totals = try view.arena.alloc(i64, recorder.frameCount());
        const scratch = try view.arena.alloc(i64, totals.len);
        var count: usize = 0;
        var frames = recorder.frames();
        while (frames.next()) |f| : (count += 1) {
            if (count == totals.len) break;
            totals[count] = f.total_ns;
        }
        const summary = core.profile.summarise(totals[0..count], scratch);

        try view.line("frame {d}  {d:.2}ms  p95 {d:.2}ms  max {d:.2}ms", .{
            frame.index,
            millis(frame.total_ns),
            millis(summary.p95_ns),
            millis(summary.max_ns),
        });

        // The recorder's own totals rather than `frameDelta`: a recorded frame is what this
        // program spent, measured by the engine that owns the frame, while `frameDelta` is
        // how long the previous frame took to come round.
        const plotted = recorder.totalsMs(&self.samples);
        try ui.plot(view.ui, plotted, .{ .height = view.ui.style.line_height * 2, .min = 0 });

        if (frame.dropped != 0 or frame.unbalanced != 0) {
            try view.line("{d} span(s) dropped, {d} unbalanced", .{ frame.dropped, frame.unbalanced });
        }

        // **Nothing here is measured by a subsystem timing itself.** `scene` and `physics2d`
        // cannot read a clock at all (§4.1), so every span was opened by a caller that had
        // one — the engine around its own frame, the game around the code it owns.
        var shown: usize = 0;
        for (frame.spans) |s| {
            if (shown == max_spans) break;
            shown += 1;
            const indent = @min(s.depth, 4) * 2;
            try view.line("{s}{s} {d:.2}ms", .{
                "        "[0..indent],
                recorder.nameOf(s.name),
                millis(@intCast(s.durationNs())),
            });
        }

        try describeRenderer(view);
        try describeAudio(view);
    }

    /// The plot, when there is no recorder to plot. A ring written at the head, which is
    /// what `PlotOptions.first` exists for.
    fn plotDelta(self: *State, view: *View) Allocator.Error!void {
        self.samples[self.head] = view.frame.delta.toSecondsF32() * 1000;
        self.head = (self.head + 1) % self.samples.len;
        try ui.plot(view.ui, &self.samples, .{
            .height = view.ui.style.line_height * 2,
            .first = self.head,
            .min = 0,
        });
    }
};

/// The renderer's statistics, and **the batch count in particular**.
///
/// §10.3 asks for this one to be visible whenever the profiler panel is open, because the
/// overlay is known to inflate it and "known to" is not a diagnosis. `render2d.Stats` has
/// carried these numbers since M2 and this is the first thing that reads them out of a
/// panel rather than a log line.
fn describeRenderer(view: *View) Allocator.Error!void {
    const renderer = view.sources.renderer orelse return;
    const stats = renderer.frameStats();
    try view.line("{d} sprites  {d} glyphs  {d} tiles", .{ stats.sprites, stats.glyphs, stats.tiles });
    try view.line("{d} batches  {d} draw calls  {d} views", .{ stats.batches, stats.draw_calls, stats.views });
    try view.line("{d} KiB vertices  {d} buffers  {d} textures", .{
        stats.vertex_bytes / 1024,
        stats.buffers_used,
        stats.textures_resident,
    });
}

fn describeAudio(view: *View) Allocator.Error!void {
    const mixer = view.sources.mixer orelse return;
    try view.line("{d} voices  {d} sounds  {d} commands dropped", .{
        mixer.activeVoices(),
        mixer.soundCount(),
        mixer.commandsDropped(),
    });
}

/// Nanoseconds as milliseconds, for display only. Never fed back into anything (§3).
fn millis(ns: i64) f32 {
    return @as(f32, @floatFromInt(ns)) / @as(f32, @floatFromInt(core.time.ns_per_ms));
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

test "the panel says the profiler is off rather than showing an empty plot" {
    var test_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer test_arena.deinit();
    var state: State = .{};
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 400, 300));
    var view: View = .{ .ui = &ctx, .arena = test_arena.allocator(), .frame = .{}, .sources = .{} };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "profiler off"));
}

test "the spans of a recorded frame are listed, nested ones indented" {
    var recorder: core.profile.Recorder = try .init(testing.allocator, .{});
    defer recorder.deinit(testing.allocator);

    recorder.beginFrame(7, at(0));
    recorder.open("simulate", at(1_000_000));
    recorder.open("step", at(1_200_000));
    recorder.close(at(1_900_000));
    recorder.close(at(2_000_000));
    recorder.endFrame(at(3_000_000));

    var state: State = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 400, 300));
    var view: View = .{
        .ui = &ctx,
        .arena = arena.allocator(),
        .frame = .{ .index = 7, .profiler = &recorder },
        .sources = .{},
    };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "frame 7  3.00ms"));
    try testing.expect(overlay.findText(&ctx, "simulate 1.00ms"));
    // Indented by its depth, which is the only thing on screen that says it is inside.
    try testing.expect(overlay.findText(&ctx, "  step 0.70ms"));
}

fn at(ns: i64) core.time.Instant {
    return .{ .ns = ns };
}
