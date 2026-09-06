//! The one hazard the UI seam creates, pinned: two implementations of text measurement
//! that must never disagree.
//!
//! `ui` is L1 and cannot see a renderer; `render2d` is L3 and has never heard of a widget
//! (ADR-0024). So the kernel lays text out with `ui.FontMetrics.measure` and the renderer
//! draws it with `render2d.measureText`, and **nothing in the type system stops the two
//! from disagreeing about how wide a string is**. When they do, the UI clips a label it
//! thought would fit, or centres it a few pixels off, and the symptom appears nowhere near
//! the cause. This is the shape of bug the seam buys everything else at the price of.
//!
//! `ui.md` §8 calls the mitigation not optional. It is here rather than in either module
//! because neither can reach the other, and `app.UiFont` — the single sanctioned way to
//! build a `ui.FontMetrics` from a `render2d.BitmapFont` — is what both sides are asked
//! for through.
//!
//! **The comparison is exact, not approximate.** The two implementations do the same
//! arithmetic in the same order on the same values, so a difference of one ULP is not
//! rounding, it is a structural change — and finding out about it here is the entire point.

const std = @import("std");
const core = @import("core");
const app = @import("app");
const render2d = @import("render2d");
const ui = @import("ui");

const testing = std.testing;
const Vec2 = core.math.Vec2;

/// Everything §8 names, and nothing that is only a longer version of something already
/// here: empty, plain ASCII, multi-byte UTF-8, a codepoint no font in the corpus has, an
/// invalid byte, a truncated sequence, several lines, and the awkward line breaks.
const corpus = [_][]const u8{
    "",
    " ",
    "A",
    "hello world",
    "0.0ms  0 sprites  0 glyphs",
    // Two bytes, one glyph — the classic way a line shifts.
    "\u{e9}!",
    // Three bytes, and outside every test font's range, so it draws the substitute.
    "\u{4e00}",
    // A lone continuation byte, then a truncated three-byte sequence: one glyph each,
    // never swallowing the neighbour.
    "a\x80b",
    "\xe4\xb8",
    "\xff\xfe",
    "line one\nline two",
    "ab\nlonger line\nc",
    // A trailing newline is a line, in both, because a caller stacking blocks wants it.
    "trailing\n",
    // CRLF, which must not measure a phantom glyph at the end of every line.
    "crlf\r\nsecond",
    "\n",
    "\n\n\n",
    // An embedded NUL is a codepoint like any other and does not terminate anything.
    "a\x00b",
};

/// Cell shapes worth separating: square, wider than tall, taller than wide, and one.
const cells = [_]render2d.Extent2D{
    .{ .width = 8, .height = 8 },
    .{ .width = 6, .height = 11 },
    .{ .width = 16, .height = 12 },
    .{ .width = 1, .height = 1 },
};

/// Whole, fractional, below one and large — the range a style may set `text_scale` to.
const scales = [_]f32{ 0.5, 1, 1.5, 2, 3, 0.125 };

/// Zero because that is the default and the common case; the rest because spacing is the
/// part of the arithmetic that is not simply a multiplication.
const spacings = [_]f32{ 0, 1, 2.5, -1 };

fn fontWith(cell: render2d.Extent2D, letter: f32, line: f32) app.UiFont {
    return .{
        .font = .{
            // `.none` is a texture that does not exist, which is fine: measuring never
            // touches one, and that is precisely why the kernel can do it at all.
            .glyphs = .whole(.none, .{ .width = cell.width * 16, .height = cell.height * 6 }),
            .cell = cell,
            .columns = 16,
            .first_codepoint = ' ',
            .glyph_count = 96,
        },
        .letter_spacing = letter,
        .line_spacing = line,
    };
}

test "the kernel and the renderer measure every string identically" {
    var checked: usize = 0;

    for (cells) |cell| {
        for (spacings) |letter| {
            for (spacings) |line| {
                const font = fontWith(cell, letter, line);
                const metrics = font.metrics();

                for (scales) |scale| {
                    for (corpus) |text| {
                        const kernel = metrics.measure(text, scale);
                        const drawn = render2d.measureText(font.font, text, .{
                            .position = .zero,
                            .scale = scale,
                            .letter_spacing = letter,
                            .line_spacing = line,
                        });

                        testing.expectEqual(drawn, kernel) catch |err| {
                            std.debug.print(
                                "drift: cell {d}x{d} scale {d} spacing {d}/{d} text \"{f}\"\n",
                                .{ cell.width, cell.height, scale, letter, line, std.zig.fmtString(text) },
                            );
                            return err;
                        };
                        checked += 1;
                    }
                }
            }
        }
    }

    // Not a coverage metric — a guard against the loops being silently emptied by an
    // edit, which would leave a green test that measures nothing.
    try testing.expect(checked >= 1000);
}

test "a font the kernel cannot see the glyphs of still measures the same" {
    // The kernel has no `glyph_count`, no `columns` and no substitute: it counts cells and
    // that is all. So the interesting case is a font whose *lookups* fail — every one of
    // these strings is outside the range — because the renderer still advances a cell for
    // a glyph it cannot draw, and the two must agree about the space it took.
    var font = fontWith(.{ .width = 8, .height = 8 }, 0, 0);
    font.font.first_codepoint = 'a';
    font.font.glyph_count = 1;
    font.font.substitute = null;

    for (corpus) |text| {
        try testing.expectEqual(
            render2d.measureText(font.font, text, .{ .position = .zero, .scale = 1 }),
            font.metrics().measure(text, 1),
        );
    }
}

test "a style built from a font measures what that font will draw" {
    // The path a caller actually takes: one `UiFont`, its metrics into the style, and a
    // widget's label laid out by the kernel. What this pins is that nothing in between
    // re-derives a metric — the numbers in the style are the font's.
    const font = fontWith(.{ .width = 8, .height = 8 }, 0, 4);
    const scale: f32 = 2;

    var ctx: ui.Context = .init(testing.allocator, .{
        .font = font.metrics(),
        .text_scale = scale,
        .line_height = 24,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .white,
        .surface = .black,
        .control = .black,
        .control_hot = .black,
        .control_active = .black,
        .accent = .white,
    });
    defer ctx.deinit();

    const text = "12.3ms";
    ctx.begin(.{}, .init(0, 0, 400, 300));
    try ui.widget.label(&ctx, text);
    ctx.end();

    const drawn = render2d.measureText(font.font, text, .{
        .position = .zero,
        .scale = scale,
        .letter_spacing = font.letter_spacing,
        .line_spacing = font.line_spacing,
    });

    // The label centred itself vertically in a 24-tall row using the kernel's height, and
    // the renderer will draw exactly that height from the same top-left.
    const at = ctx.list.items()[0].text.at;
    try testing.expectEqual(@as(f32, 4), at.x);
    try testing.expectEqual(@round((24 - drawn.y) / 2), at.y);
}
