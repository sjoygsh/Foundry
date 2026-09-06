//! The walker: one `ui.DrawList`, turned into `render2d` calls.
//!
//! `ui` is L1 and cannot see a renderer; `render2d` is L3 and has never heard of a widget
//! (ADR-0024). `app` is the only layer that can see both, so this is where the two
//! vocabularies meet — and it is deliberately the *only* place, because a second translator
//! is a second thing that can disagree with the kernel about where a rectangle goes.
//!
//! It is small on purpose: a switch over four commands, a clip stack and a colour
//! conversion. That smallness is the argument for the seam. What the seam costs is named
//! below and answered with `Font`.
//!
//! **The hazard is measurement drift** (`ui.md` §8). The kernel lays text out with
//! `ui.FontMetrics.measure`; the renderer draws it with `render2d.measureText`. Neither can
//! see the other, so nothing in the type system stops them disagreeing about how wide a
//! string is — and when they do, the UI clips text it thought would fit and the symptom
//! appears nowhere near the cause. `Font` is the answer: it holds the renderer's font and
//! the spacing *once*, produces the kernel's metrics from them, and is what the walker
//! draws with, so the measuring and the drawing cannot be given different numbers. The
//! arithmetic underneath is still two implementations, and that is what
//! `engine/tests/ui_text.zig` pins across a fixed corpus.
//!
//! Design: `docs/design/ui.md` §8.

const std = @import("std");
const core = @import("core");
const render2d = @import("render2d");
const ui = @import("ui");

const Rect = core.math.Rect;
const log = core.log.scoped(.app);

/// How deep clipping may nest before the walker stops narrowing it.
///
/// A UI three panels deep with a scrolling list in each is nowhere near this. Past it the
/// walker keeps *counting* depth so that pops stay balanced, and simply leaves the clip
/// where it was — too little clipping is a cosmetic bug, while losing the balance would
/// leave the rest of the frame clipped to a panel.
const max_clip_depth = 16;

/// A `render2d` font and the spacing it is laid out with, in one value.
///
/// **This is the only sanctioned way to build a `ui.FontMetrics`.** The kernel needs cell
/// size and spacing to measure; the renderer needs the same spacing on every
/// `TextOptions` to draw. Deriving both from one value is what makes them agree by
/// construction rather than by everyone remembering to pass the same two numbers twice.
///
/// The pairing exists because `render2d.BitmapFont` has no spacing fields: spacing is a
/// property of how a font is *used*, so it lives with the style, and this is the value the
/// style is built from.
pub const Font = struct {
    font: render2d.BitmapFont,
    /// Extra units between cells and between lines, exactly as `render2d.TextOptions`
    /// means them: not scaled, so a bigger `text_scale` does not spread the letters.
    letter_spacing: f32 = 0,
    line_spacing: f32 = 0,

    /// What `ui.Style.font` should be set to. `BitmapFont.cell` is in pixels and
    /// `FontMetrics.cell` is in pixels before scale, so this is a widening and nothing
    /// more — which is the point: a conversion with arithmetic in it is a conversion that
    /// can be wrong.
    pub fn metrics(self: Font) ui.FontMetrics {
        return .{
            .cell = .init(
                @floatFromInt(self.font.cell.width),
                @floatFromInt(self.font.cell.height),
            ),
            .letter_spacing = self.letter_spacing,
            .line_spacing = self.line_spacing,
        };
    }
};

pub const Options = struct {
    /// The sort layer every command in the list is submitted at.
    ///
    /// **One layer for the whole list, deliberately.** The kernel's order *is* paint
    /// order (`ui.draw`), and the batcher breaks ties on submission order within a layer,
    /// so walking the list in order reproduces it exactly. Spreading commands across
    /// layers would sort the UI against itself.
    ///
    /// It is a parameter because the UI shares a view with whatever else the caller draws
    /// in screen space; this is how the caller says which is on top.
    layer: i16 = 0,
};

/// Draws `list` into `view`.
///
/// `view` must be a **screen-space, +Y down** space — `render2d.ViewId.screen` is the one
/// every caller already has. The kernel's rectangles are in the points the pointer is
/// reported in, with the origin at the top-left, and drawing them through a Y-up camera
/// would mirror the whole UI vertically. That is left as a documented precondition rather
/// than a check: the renderer does not expose a view's axis, and the failure is a UI that
/// is visibly upside down rather than one that is subtly wrong.
///
/// The renderer's view and clip are **restored on the way out**, so this composes with a
/// caller that was in the middle of its own frame.
pub fn draw(
    list: *const ui.DrawList,
    r: *render2d.Renderer,
    font: Font,
    view: render2d.ViewId,
    options: Options,
) render2d.RendererError!void {
    const previous_view = r.currentView();
    const previous_clip = r.currentClip();
    try r.setView(view);
    defer {
        // Both can only fail with `NotRecording`, and a frame that ended underneath the
        // walker has nothing left to restore.
        r.setClip(previous_clip) catch {};
        r.setView(previous_view) catch {};
    }

    // Step 3 put this on the renderer precisely so that every UI does not grow its own.
    const blank = r.blankRegion();

    // What to restore to when each open clip is popped.
    var open: [max_clip_depth]?Rect = undefined;
    var depth: usize = 0;

    for (list.items()) |command| switch (command) {
        .rect => |c| try r.drawSprite(.{
            .texture = blank.texture,
            .uv = blank.uv,
            // The kernel's rectangles are top-left anchored, which is `origin` zero in a
            // Y-down space — the same convention `drawText` uses for its own positions.
            .position = .init(c.bounds.x, c.bounds.y),
            .size = .init(c.bounds.w, c.bounds.h),
            .origin = .init(0, 0),
            .tint = tintOf(c.color),
            .layer = options.layer,
        }),
        .text => |c| try r.drawText(font.font, list.textOf(c.text), .{
            .position = c.at,
            .scale = c.scale,
            .tint = tintOf(c.color),
            .layer = options.layer,
            .letter_spacing = font.letter_spacing,
            .line_spacing = font.line_spacing,
        }),
        // Already intersected with everything outside it by the kernel, so the walker
        // applies the rectangle it is given rather than doing the arithmetic twice.
        .clip_push => |bounds| {
            if (depth < max_clip_depth) {
                open[depth] = r.currentClip();
                try r.setClip(bounds);
            } else if (depth == max_clip_depth) {
                log.warn("ui clip nesting deeper than {d}; not narrowing further", .{max_clip_depth});
            }
            depth += 1;
        },
        .clip_pop => {
            // A list is data, and from M7 a list a mod described, so an unbalanced one is
            // reported rather than asserted (CLAUDE.md §7).
            if (depth == 0) {
                log.warn("ui draw list popped a clip it never pushed", .{});
            } else {
                depth -= 1;
                if (depth < max_clip_depth) try r.setClip(open[depth]);
            }
        },
    };
}

/// `ui.Color` and `render2d.Color` are the same four linear components in the same order,
/// declared twice because `ui` cannot see `render2d`. This function is the whole of what
/// that costs, and it is here rather than on either type because neither may name the
/// other (`ui/style.zig`).
fn tintOf(c: ui.Color) render2d.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;
const rhi = @import("rhi");
const asset = @import("asset");

/// A renderer on the current backend, plus a font whose texture actually exists.
const Fixture = struct {
    device: *rhi.Device,
    renderer: render2d.Renderer,
    font: Font,
    ctx: ui.Context,

    fn init() !Fixture {
        const gpa = testing.allocator;

        const device = try rhi.Device.init(gpa, .{});
        errdefer device.deinit();

        var renderer = try render2d.Renderer.init(gpa, device, .{ .quads_per_buffer = 256 });
        errdefer renderer.deinit();

        // A 128x48 sheet of 8x8 cells, which is the shape both samples' fonts have.
        var image = try asset.Image.alloc(gpa, 128, 48);
        defer image.deinit(gpa);
        @memset(image.pixels, 0xFF);
        const texture = try renderer.createTexture(image, .{ .label = "walker font" });

        const font: Font = .{
            .font = .{
                .glyphs = .whole(texture, .{ .width = 128, .height = 48 }),
                .cell = .{ .width = 8, .height = 8 },
                .columns = 16,
                .glyph_count = 96,
            },
            .line_spacing = 4,
        };

        return .{
            .device = device,
            .renderer = renderer,
            .font = font,
            .ctx = .init(gpa, testStyle(font)),
        };
    }

    fn deinit(self: *Fixture) void {
        self.ctx.deinit();
        self.renderer.deinit();
        self.device.deinit();
    }

    fn beginFrame(self: *Fixture) !void {
        try self.renderer.begin(.{ .camera = .{ .viewport = .init(0, 0, 800, 600) } });
    }

    /// Everything after the game has submitted, which is where the batches are counted.
    fn endFrame(self: *Fixture) !void {
        const frame = try self.device.beginFrame();
        const cmd = try self.device.beginCommandBuffer();
        try self.renderer.prepare(cmd, frame);

        const pass = try cmd.beginRenderPass(.{
            .label = "walker",
            .color = &.{.{
                .texture = frame.surface_texture,
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
    }
};

fn testStyle(font: Font) ui.Style {
    return .{
        .font = font.metrics(),
        .text_scale = 2,
        .line_height = 20,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 },
        .surface = .{ .r = 0, .g = 0, .b = 0, .a = 0.6 },
        .control = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1 },
        .control_hot = .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1 },
        .control_active = .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1 },
        .accent = .{ .r = 0.2, .g = 0.5, .b = 0.9, .a = 1 },
    };
}

test "the metrics a font produces are the font's own numbers" {
    const font: Font = .{
        .font = .{
            .glyphs = .whole(.none, .{ .width = 128, .height = 48 }),
            .cell = .{ .width = 6, .height = 11 },
            .columns = 16,
            .glyph_count = 96,
        },
        .letter_spacing = 1.5,
        .line_spacing = 3,
    };

    const metrics = font.metrics();
    try testing.expectEqual(core.math.Vec2.init(6, 11), metrics.cell);
    try testing.expectEqual(@as(f32, 1.5), metrics.letter_spacing);
    try testing.expectEqual(@as(f32, 3), metrics.line_spacing);
}

test "an empty list draws nothing and disturbs nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.beginFrame();
    fx.ctx.begin(.at(.init(-1, -1), .up), .init(0, 0, 800, 600));
    fx.ctx.end();

    try draw(&fx.ctx.list, &fx.renderer, fx.font, .screen, .{});
    // The walker put the renderer back where it found it, which is what makes it safe to
    // call halfway through a frame the game is still submitting.
    try testing.expectEqual(render2d.ViewId.world, fx.renderer.currentView());
    try testing.expectEqual(@as(?Rect, null), fx.renderer.currentClip());

    try fx.endFrame();
    try testing.expectEqual(@as(u32, 0), fx.renderer.frameStats().sprites);
}

test "a rectangle becomes one sprite and a label becomes its glyphs" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.beginFrame();
    fx.ctx.begin(.at(.init(-1, -1), .up), .init(0, 0, 800, 600));
    _ = try ui.widget.buttonIn(&fx.ctx, ui.Id.root.child("ok"), "Save", .init(10, 10, 100, 20));
    fx.ctx.end();

    try draw(&fx.ctx.list, &fx.renderer, fx.font, .screen, .{});
    try fx.endFrame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 4), stats.glyphs);
    // The fill, plus one sprite per glyph: a glyph is a sprite, here as everywhere.
    try testing.expectEqual(@as(u32, 5), stats.sprites);
}

test "a clip in the list becomes a batch break" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    // Three rectangles, all from the blank texture at one layer. Nothing else about them
    // differs, so whether that is one batch or three is entirely the clip's doing — which
    // is what makes this a test of step 3's batch break rather than of texture changes.
    var plain: ui.DrawList = .{};
    defer plain.deinit(gpa);
    try plain.addRect(gpa, .init(0, 0, 10, 10), .white);
    try plain.addRect(gpa, .init(5, 5, 10, 10), .white);
    try plain.addRect(gpa, .init(20, 20, 10, 10), .white);

    var clipped: ui.DrawList = .{};
    defer clipped.deinit(gpa);
    try clipped.addRect(gpa, .init(0, 0, 10, 10), .white);
    try clipped.pushClip(gpa, .init(0, 0, 50, 50));
    try clipped.addRect(gpa, .init(5, 5, 10, 10), .white);
    _ = try clipped.popClip(gpa);
    try clipped.addRect(gpa, .init(20, 20, 10, 10), .white);

    try fx.beginFrame();
    try draw(&plain, &fx.renderer, fx.font, .screen, .{});
    try fx.endFrame();
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().batches);

    try fx.beginFrame();
    try draw(&clipped, &fx.renderer, fx.font, .screen, .{});
    try fx.endFrame();
    try testing.expectEqual(@as(u32, 3), fx.renderer.frameStats().batches);
}

test "a panel clips the widgets described inside it" {
    var fx = try Fixture.init();
    defer fx.deinit();

    // Straight through the widget set this time: what the walker sees is whatever
    // `beginPanel` decided, and the clip it applies is the panel's own rectangle.
    try fx.beginFrame();
    fx.ctx.begin(.at(.init(-1, -1), .up), .init(0, 0, 800, 600));
    try ui.widget.beginPanel(&fx.ctx, fx.ctx.childId("stats"), .init(10, 10, 200, 100));
    try ui.widget.label(&fx.ctx, "hello");
    try ui.widget.endPanel(&fx.ctx);
    fx.ctx.end();

    try draw(&fx.ctx.list, &fx.renderer, fx.font, .screen, .{});
    try fx.endFrame();

    const stats = fx.renderer.frameStats();
    // The surface, then five glyphs; the surface is drawn before the clip is pushed and
    // the glyphs after it, so they cannot share a batch.
    try testing.expectEqual(@as(u32, 5), stats.glyphs);
    try testing.expectEqual(@as(u32, 6), stats.sprites);
    try testing.expectEqual(@as(u32, 2), stats.batches);
}

test "an unbalanced list is walked anyway, and leaves no clip behind" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    // Not something the widget set can produce — `endPanel` always pops — but a list is
    // data, and from M7 it is data a mod described.
    var list: ui.DrawList = .{};
    defer list.deinit(gpa);
    try list.pushClip(gpa, .init(0, 0, 50, 50));
    try list.addRect(gpa, .init(0, 0, 10, 10), .white);
    // A pop with nothing open. The kernel refuses to record one, so it is appended here.
    try list.commands.append(gpa, .clip_pop);
    try list.commands.append(gpa, .clip_pop);

    try fx.beginFrame();
    try fx.renderer.setClip(Rect.init(1, 2, 3, 4));
    try draw(&list, &fx.renderer, fx.font, .screen, .{});

    // The clip the caller had is back, unpushed rectangles and stray pops notwithstanding.
    try testing.expectEqual(Rect.init(1, 2, 3, 4), fx.renderer.currentClip().?);
    try fx.endFrame();
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().sprites);
}

test "clipping deeper than the walker tracks still balances" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gpa = testing.allocator;

    var list: ui.DrawList = .{};
    defer list.deinit(gpa);
    for (0..max_clip_depth + 4) |i| {
        const edge: f32 = @floatFromInt(i);
        try list.pushClip(gpa, .init(edge, edge, 400, 400));
    }
    for (0..max_clip_depth + 4) |_| _ = try list.popClip(gpa);

    try fx.beginFrame();
    try draw(&list, &fx.renderer, fx.font, .screen, .{});
    try testing.expectEqual(@as(?Rect, null), fx.renderer.currentClip());
    try fx.endFrame();
}
