//! A headless engine, a world and an overlay, for a handful of frames.
//!
//! Every panel is unit-tested where it lives, against a `Frame` a test built by hand. What
//! is only testable from here is that the parts are **wired to each other**: that
//! `Overlay.describe` reads a real engine into a real `Frame`, that the engine's spans and
//! the overlay's own span end up in one profile, and that the log ring a running engine
//! filled is the ring the console reads. It is the shape of `sound_pipeline.zig`, for the
//! same reason.
//!
//! It stands where a game stands — above everything, composing it — and it opens no window
//! and touches no device: the null platform and the null RHI, so the clock is synthetic and
//! the run is the same on every machine.

const std = @import("std");

const app = @import("app");
const core = @import("core");
const debug = @import("debug");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const scene = @import("scene");
const ui = @import("ui");

const testing = std.testing;

const Engine = app.EngineOf(platform.null_backend.Platform, rhi.null_backend.Device);

/// A component with a serializer, so the inspector has something to read.
const Position = struct {
    pub const component = "overlaytest:position";
    x: f32 = 0,
    y: f32 = 0,
};

fn style() ui.Style {
    return .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 14,
        .padding = .init(4, 2),
        .spacing = 2,
        .text = .white,
        .text_dim = .{ .r = 0.5, .g = 0.5, .b = 0.5 },
        .surface = .{ .r = 0.06, .g = 0.06, .b = 0.06, .a = 0.9 },
        .control = .{ .r = 0.2, .g = 0.2, .b = 0.2 },
        .control_hot = .{ .r = 0.3, .g = 0.3, .b = 0.3 },
        .control_active = .{ .r = 0.4, .g = 0.4, .b = 0.4 },
        .accent = .{ .r = 0.35, .g = 0.62, .b = 1 },
    };
}

test "an overlay over a running engine describes every panel and lands in its own profile" {
    const gpa = testing.allocator;

    app.log_sink.setLevel(.err);
    defer app.log_sink.setLevel(.info);

    const engine = try Engine.init(gpa, .{
        .headless = true,
        .profiler = true,
        .log_capture = .info,
        .hot_reload = false,
    });
    defer engine.deinit();
    engine.platform.setClockStep(.fromMillis(1));

    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    var world: scene.World = .init(gpa, &schemas, .default);
    defer world.deinit();

    const position = try world.registerComponent(scene.componentType(Position));
    const entity = try world.create();
    var value: Position = .{ .x = 12, .y = 34 };
    _ = try world.addComponent(entity, position, std.mem.asBytes(&value));

    const overlay = try debug.Overlay.init(gpa, .{});
    defer overlay.deinit();
    // All five open at once, which is also the arrangement that costs the most: what this
    // asserts is that every panel describes without error against a live engine.
    for (overlay.panels.items) |*panel| panel.open = true;

    var ctx = ui.Context.init(gpa, style());
    defer ctx.deinit();

    // A line the console must find later, written through the sink's own entry point — the
    // same call `std_options` installs.
    app.log_sink.logFn(.info, .overlay_test, "the torch was lit", .{});

    var frames: usize = 0;
    while (frames < 4) : (frames += 1) {
        engine.beginFrame();
        {
            var scope = engine.beginScope("simulate");
            defer scope.end();
            world.update(.{ .tick = frames, .delta = engine.frameDelta() });
        }
        ctx.begin(.{ .frame = engine.frame_index }, .init(0, 0, 1280, 720));
        // The selection is made the way a click would make it, because a test cannot click:
        // what is being checked is that a selected entity's fields are read and shown.
        overlay.entities.selected = entity;
        // The header's id is seeded by the panel's region, which `beginPanel` sets to the
        // panel's own id — so a caller reaching for it has to spell the same path the
        // widget will.
        ctx.stateOf(debug.overlay.root_id.child("entities").child("overlaytest:position")).open = true;
        try overlay.describe(&ctx, engine, .{ .world = &world });
        ctx.end();
        engine.endFrame();
    }

    // **The overlay's own cost is inside the profile it is drawing**, which is §10.3's
    // whole point: a tool whose cost is invisible in its own numbers lies about the thing
    // it exists to measure.
    const recorder = engine.profiler().?;
    const frame = recorder.latest().?;
    try testing.expectEqual(@as(u16, 0), frame.dropped);
    try testing.expectEqual(@as(u16, 0), frame.unbalanced);

    var saw_overlay = false;
    var saw_simulate = false;
    var top_level: i64 = 0;
    for (frame.spans) |span| {
        const name = recorder.nameOf(span.name);
        if (std.mem.eql(u8, name, debug.span.overlay)) saw_overlay = true;
        if (std.mem.eql(u8, name, "simulate")) saw_simulate = true;
        if (span.depth == 0) top_level += span.durationNs();
    }
    try testing.expect(saw_overlay);
    try testing.expect(saw_simulate);
    // The spans are inside the frame, not beside it. Nesting means a deeper span's time is
    // already in its parent's, so only depth 0 is summed.
    try testing.expect(top_level <= frame.total_ns);

    // The panels described what the engine actually holds.
    try testing.expect(debug.overlay.findText(&ctx, "1 entities"));
    try testing.expect(debug.overlay.findText(&ctx, "x = 12"));
    try testing.expect(debug.overlay.findText(&ctx, "y = 34"));
    try testing.expect(debug.overlay.findText(&ctx, "the torch was lit"));
    // No counters were registered, and saying so is the answer: there is no global
    // allocator to enumerate.
    try testing.expect(debug.overlay.findText(&ctx, "no allocators registered"));
    // The engine's own content store, which is empty here and still a store.
    try testing.expect(debug.overlay.findText(&ctx, "0 records  0 packages"));
}

test "a counter the game registered appears in the overlay's memory panel" {
    const gpa = testing.allocator;

    app.log_sink.setLevel(.err);
    defer app.log_sink.setLevel(.info);

    var counted: core.mem.Counted = .init("game", gpa);
    const engine = try Engine.init(counted.allocator(), .{
        .headless = true,
        .profiler = false,
        .log_capture = null,
        .hot_reload = false,
    });
    defer engine.deinit();
    _ = try engine.registerMemory(&counted);

    const overlay = try debug.Overlay.init(gpa, .{});
    defer overlay.deinit();
    for (overlay.panels.items) |*panel| panel.open = true;

    var ctx = ui.Context.init(gpa, style());
    defer ctx.deinit();

    engine.beginFrame();
    ctx.begin(.{ .frame = engine.frame_index }, .init(0, 0, 1280, 720));
    try overlay.describe(&ctx, engine, .{});
    ctx.end();
    engine.endFrame();

    // The engine's owner is the only one who can answer for its allocator, which is why
    // registering one is a call the owner makes rather than something the engine does to
    // itself (`debug-overlay.md` §5).
    try testing.expect(debug.overlay.findText(&ctx, "game  "));
    // And the profiler being off is an answer rather than an empty plot.
    try testing.expect(debug.overlay.findText(&ctx, "profiler off"));
}
