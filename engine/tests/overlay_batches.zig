//! **M6's exit criterion, executed:** the overlay's own batch cost, diagnosed.
//!
//! `ui.md` recorded the number twice while the widget set was being built — six batches for
//! the hand-drawn HUD, ten once the overlay existed, fifteen by the end of its step 5 — with
//! the same suspected cause each time and no measurement behind it: *panel rectangles come
//! from the renderer's blank texture and glyphs come from the font atlas, so every
//! alternation between them is a texture break and a new batch.*
//!
//! This stands where the diagnosis has to stand. `ui` describes, `app.drawUi` walks, and
//! `render2d` batches; no one of the three can see the other two, and the number in question
//! is produced by all of them together. It runs on the null device, so the batch counts are
//! the same on every machine and in CI.
//!
//! **What it measures, and why that is the whole trick.** The batcher breaks a batch on a
//! change of buffer, view, texture, blend **or clip** (`render2d/batch.zig`), and texture is
//! deliberately *not* part of the sort key — sorting by it would reorder overlapping
//! translucent sprites. So a described frame has two independent reasons to break, and the
//! recorded suspicion names only one of them. Each case below isolates one.

const std = @import("std");

const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const debug = @import("debug");
const render2d = @import("render2d");
const rhi = @import("rhi");
const ui = @import("ui");

const testing = std.testing;

/// A renderer on the null device, with a font on a texture of its own — which is how every
/// Foundry game has one today, and therefore the configuration the number was measured in.
const Fixture = struct {
    device: *rhi.Device,
    renderer: render2d.Renderer,
    font: app.UiFont,

    fn init() !Fixture {
        const gpa = testing.allocator;
        const device = try rhi.Device.init(gpa, .{});
        errdefer device.deinit();

        var renderer = try render2d.Renderer.init(gpa, device, .{});
        errdefer renderer.deinit();

        var glyphs = try asset.Image.alloc(gpa, 128, 48);
        defer glyphs.deinit(gpa);
        @memset(glyphs.pixels, 0xFF);
        const texture = try renderer.createTexture(glyphs, .{ .label = "font" });

        return .{
            .device = device,
            .renderer = renderer,
            .font = .{
                .font = .{
                    .glyphs = renderer.textureRegion(texture).?,
                    .cell = .{ .width = 8, .height = 8 },
                    .columns = 16,
                    .glyph_count = 95,
                },
            },
        };
    }

    fn deinit(self: *Fixture) void {
        self.renderer.deinit();
        self.device.deinit();
    }

    /// Walks a described frame into the renderer and completes it, exactly as a game does.
    fn walk(self: *Fixture, list: *const ui.DrawList) !render2d.Stats {
        try self.renderer.begin(.{ .camera = .{ .viewport = .init(0, 0, 1280, 720) } });
        try app.drawUi(list, &self.renderer, self.font, .screen, .{});

        const ctx = try self.device.beginFrame();
        const cmd = try self.device.beginCommandBuffer();
        try self.renderer.prepare(cmd, ctx);
        const pass = try cmd.beginRenderPass(.{
            .label = "overlay batches",
            .color = &.{.{
                .texture = ctx.surface_texture,
                .load = .{ .clear = .{ .color = .{ 0, 0, 0, 1 } } },
                .store = .store,
                .initial_state = .undefined,
                .final_state = .present,
            }},
        });
        try self.renderer.record(pass);
        pass.end();
        try cmd.submit();
        try self.device.endFrame();

        return self.renderer.frameStats();
    }
};

fn style(font: app.UiFont) ui.Style {
    return .{
        .font = font.metrics(),
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

/// What the draw list would cost, worked out from the list alone.
///
/// **This is a model of the batcher, and the test's job is to prove it is the right one.**
/// The batcher starts a new batch whenever the `(texture, clip)` pair changes between two
/// consecutive items in submission order — texture is deliberately not part of the sort key,
/// because sorting by it would reorder overlapping translucent sprites — so walking the list
/// the way `app.drawUi` walks it and counting the runs must produce exactly the number
/// `frameStats` reports. When it does, every break has been *attributed*, which is what
/// turns a batch count into a diagnosis.
const Attribution = struct {
    /// Runs of identical `(texture, clip)`, which is what a batch is.
    batches: usize = 0,
    /// Breaks caused by a rectangle following a glyph or the reverse: the blank patch and
    /// the font atlas are two textures. **The cause `ui.md` suspected.**
    texture_breaks: usize = 0,
    /// Breaks caused by entering or leaving a clipped region with no texture change. **The
    /// cause `ui.md` never named**, and the one a panel pays whatever it contains.
    clip_breaks: usize = 0,
    /// Breaks where both changed at once. Charged to neither, because removing either cause
    /// alone would not remove the break.
    both: usize = 0,
    /// **The counterfactual, and the number that makes this actionable**: what the batch
    /// count would be if rectangles and glyphs came from one texture — which is what packing
    /// the renderer's blank patch into the font's atlas would do. Only clip changes are left,
    /// and those are irreducible without a different clipping strategy.
    single_texture_batches: usize = 0,

    rects: usize = 0,
    texts: usize = 0,
    clips: usize = 0,

    fn of(list: *const ui.DrawList) Attribution {
        var out: Attribution = .{};

        // The walker's own clip handling, reproduced: the kernel already intersected each
        // pushed rectangle with everything outside it, so this stack only has to remember
        // what to restore. Sixteen is the walker's limit and the overlay nests three deep.
        var open: [16]?core.math.Rect = undefined;
        var depth: usize = 0;
        var clip: ?core.math.Rect = null;

        var previous: ?struct { blank: bool, clip: ?core.math.Rect } = null;

        for (list.items()) |command| switch (command) {
            .rect, .text => {
                const blank = command == .rect;
                if (blank) out.rects += 1 else out.texts += 1;

                if (previous) |p| {
                    const texture_changed = p.blank != blank;
                    const clip_changed = !render2d.batch.clipEql(p.clip, clip);
                    if (texture_changed and clip_changed) {
                        out.both += 1;
                        out.batches += 1;
                    } else if (texture_changed) {
                        out.texture_breaks += 1;
                        out.batches += 1;
                    } else if (clip_changed) {
                        out.clip_breaks += 1;
                        out.batches += 1;
                    }
                } else {
                    out.batches += 1;
                }

                if (previous) |p| {
                    if (!render2d.batch.clipEql(p.clip, clip)) out.single_texture_batches += 1;
                } else {
                    out.single_texture_batches += 1;
                }

                previous = .{ .blank = blank, .clip = clip };
            },
            .clip_push => |bounds| {
                out.clips += 1;
                if (depth < open.len) open[depth] = clip;
                depth += 1;
                clip = bounds;
            },
            .clip_pop => {
                if (depth == 0) continue;
                depth -= 1;
                if (depth < open.len) clip = open[depth];
            },
        };

        return out;
    }
};

// -- the two causes, separated -----------------------------------------------------------

test "rectangles alone are one batch, however many there are" {
    var fx = try Fixture.init();
    defer fx.deinit();

    var ctx = ui.Context.init(testing.allocator, style(fx.font));
    defer ctx.deinit();

    ctx.begin(.{}, .init(0, 0, 1280, 720));
    for (0..64) |i| {
        const y: f32 = @floatFromInt(i * 10);
        try ctx.list.addRect(ctx.gpa, .init(0, y, 100, 8), ctx.style.control);
    }
    ctx.end();

    const stats = try fx.walk(&ctx.list);
    try testing.expectEqual(@as(u32, 64), stats.sprites);
    try testing.expectEqual(@as(u32, 1), stats.batches);
}

test "text alone is one batch, however many glyphs" {
    var fx = try Fixture.init();
    defer fx.deinit();

    var ctx = ui.Context.init(testing.allocator, style(fx.font));
    defer ctx.deinit();

    ctx.begin(.{}, .init(0, 0, 1280, 720));
    for (0..64) |i| {
        const y: f32 = @floatFromInt(i * 10);
        try ctx.list.addText(ctx.gpa, .init(0, y), "a line of text", ctx.style.text, 1);
    }
    ctx.end();

    const stats = try fx.walk(&ctx.list);
    try testing.expect(stats.glyphs > 0);
    try testing.expectEqual(@as(u32, 1), stats.batches);
}

test "every alternation between a rectangle and a glyph costs exactly one batch" {
    var fx = try Fixture.init();
    defer fx.deinit();

    var ctx = ui.Context.init(testing.allocator, style(fx.font));
    defer ctx.deinit();

    const rows = 16;
    ctx.begin(.{}, .init(0, 0, 1280, 720));
    for (0..rows) |i| {
        const y: f32 = @floatFromInt(i * 20);
        try ctx.list.addRect(ctx.gpa, .init(0, y, 100, 8), ctx.style.control);
        try ctx.list.addText(ctx.gpa, .init(0, y), "x", ctx.style.text, 1);
    }
    ctx.end();

    const shape = Attribution.of(&ctx.list);
    const stats = try fx.walk(&ctx.list);

    // **The suspicion, isolated and confirmed at this scale.** One batch to start, and one
    // more per change of texture, because the batcher preserves submission order within a
    // layer rather than sorting by texture.
    try testing.expectEqual(@as(usize, rows * 2 - 1), shape.texture_breaks);
    try testing.expectEqual(@as(usize, 0), shape.clips);
    try testing.expectEqual(@as(usize, 0), shape.clip_breaks);
    try testing.expectEqual(@as(u32, @intCast(shape.texture_breaks + 1)), stats.batches);
}

test "a clip breaks a batch on its own, with no texture change anywhere" {
    var fx = try Fixture.init();
    defer fx.deinit();

    var ctx = ui.Context.init(testing.allocator, style(fx.font));
    defer ctx.deinit();

    // Eight clipped regions, each containing rectangles and nothing else, so the texture
    // never changes and the only thing that does is the scissor.
    ctx.begin(.{}, .init(0, 0, 1280, 720));
    for (0..8) |i| {
        const y: f32 = @floatFromInt(i * 40);
        try ctx.pushClip(.init(0, y, 200, 30));
        for (0..4) |j| {
            const dy: f32 = @floatFromInt(j * 6);
            try ctx.list.addRect(ctx.gpa, .init(0, y + dy, 100, 4), ctx.style.control);
        }
        try ctx.popClip();
    }
    ctx.end();

    const shape = Attribution.of(&ctx.list);
    const stats = try fx.walk(&ctx.list);

    try testing.expectEqual(@as(usize, 0), shape.texture_breaks);
    try testing.expectEqual(@as(usize, 8), shape.clips);
    // **The cause `ui.md` never named.** Seven breaks between eight clipped runs, from one
    // texture and nothing else — one batch per region.
    try testing.expectEqual(@as(usize, 7), shape.clip_breaks);
    try testing.expectEqual(@as(u32, 8), stats.batches);
}

// -- the overlay itself ------------------------------------------------------------------

/// Describes the overlay with `open` of its panels open, and reports what it cost.
fn measure(fx: *Fixture, open: usize) !struct { shape: Attribution, stats: render2d.Stats } {
    const overlay = try debug.Overlay.init(testing.allocator, .{});
    defer overlay.deinit();
    for (overlay.panels.items, 0..) |*panel, i| panel.open = i < open;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var ctx = ui.Context.init(testing.allocator, style(fx.font));
    defer ctx.deinit();

    ctx.begin(.{}, .init(0, 0, 1280, 720));
    try overlay.describeIn(&ctx, .{}, arena.allocator(), .{});
    ctx.end();

    return .{ .shape = Attribution.of(&ctx.list), .stats = try fx.walk(&ctx.list) };
}

test "the overlay's batch count is exactly its texture and clip breaks, and texture dominates" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const none = try measure(&fx, 0);
    const one = try measure(&fx, 1);
    const all = try measure(&fx, 5);

    // **The model is the mechanism.** If walking the list and counting runs of identical
    // `(texture, clip)` reproduces `frameStats().batches` exactly, then every break has been
    // attributed and there is no third cause hiding in the number. This is what makes the
    // split below a diagnosis rather than a plausible story.
    for ([_]@TypeOf(none){ none, one, all }) |m| {
        try testing.expectEqual(@as(u32, @intCast(m.shape.batches)), m.stats.batches);
    }

    // **The answer to `ui.md` §14 and §10.3: the suspicion was right.** Alternating between
    // the blank patch and the font atlas is what inflates the count; the clips a panel pushes
    // are real and are a small minority.
    try testing.expect(all.shape.texture_breaks > all.shape.clip_breaks * 4);
    try testing.expect(all.shape.clips <= 8);

    // Opening panels costs more of both, and the bar alone already costs some.
    try testing.expect(none.stats.batches > 1);
    try testing.expect(one.stats.batches > none.stats.batches);
    try testing.expect(all.stats.batches > one.stats.batches);

    // **And what the fix is worth, before anybody writes it.** One texture behind both
    // rectangles and glyphs would leave only the clip changes, which is less than half of
    // what the overlay costs today — the size of the prize, measured rather than hoped for.
    try testing.expect(all.shape.single_texture_batches * 2 < all.stats.batches);
}
