//! Colour, font metrics and the style value the kernel reads and never writes.
//!
//! ADR-0024 asks one thing of the kernel so that the content-driven game widget layer can
//! arrive later without a rewrite: **no colour, font, metric or string in it is a literal.**
//! Everything a widget needs to decide how big it is or what colour it draws comes from a
//! `Style` the caller supplies. The debug widget set ships a value; the game layer will
//! build one from content. Neither is the kernel's business.
//!
//! Design: `docs/design/ui.md` §7.

const std = @import("std");
const core = @import("core");

const Vec2 = core.math.Vec2;

/// A colour in **linear** light, not sRGB — the same convention and the same field layout
/// as `render2d.Color`, so the walker converts field for field.
///
/// It is a separate type because `ui` cannot see `render2d` (ADR-0024), and that is the
/// seam's smallest and most irritating cost. It is stated here so nobody spends an
/// afternoon looking for a way to share the declaration that does not break the layering.
///
/// **There is deliberately no `srgb8` here.** Duplicating the transfer function would be a
/// second thing that can silently disagree with the renderer, and the kernel has no need
/// for one: whoever builds a `Style` is above the seam and can convert there.
pub const Color = extern struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn linear(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// The same colour at a different opacity. The one operation a widget genuinely needs
    /// — a disabled control is its enabled colour, dimmed — and doing it by hand at call
    /// sites is how a style stops being one value.
    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }
};

/// Everything the kernel needs to know about a font in order to lay text out.
///
/// **This is the piece that decided ADR-0024's module edge.** `render2d.BitmapFont` has six
/// fields and exactly one of them — `glyphs: Region` — is a renderer thing; the rest is the
/// arithmetic below. So the kernel can measure without seeing a renderer, and the walker
/// draws. The one hazard that creates is the two disagreeing, and `ui.md` §8 answers it
/// with a single sanctioned conversion and a test that measures a corpus both ways.
///
/// There is no default: a metric invented here would be exactly the literal ADR-0024 asked
/// the kernel not to contain.
pub const FontMetrics = struct {
    /// One glyph cell in pixels, before `scale`. Glyphs advance by this, including
    /// whatever blank margin the cell has, which is how a fixed grid needs no metrics file.
    cell: Vec2,
    /// Extra units between cells and between lines. Zero means the cells touch.
    letter_spacing: f32 = 0,
    line_spacing: f32 = 0,

    /// The bounding box `text` would occupy at `scale`.
    ///
    /// **This mirrors `render2d.text.Layout` exactly and deliberately**, including the
    /// parts that look like details: `\r` is skipped without advancing a column so a CRLF
    /// file does not measure a trailing glyph on every line; a `\n` starts a line even at
    /// the very end, because a caller stacking blocks wants the space it asked for; and an
    /// invalid byte advances one byte and counts as one glyph, because that is what the
    /// renderer will draw a substitute for. Empty text measures zero.
    pub fn measure(self: FontMetrics, text: []const u8, scale: f32) Vec2 {
        const size = self.cell.scale(scale);

        var byte: usize = 0;
        var column: u32 = 0;
        var lines: u32 = 0;
        var max_right: f32 = 0;

        while (byte < text.len) {
            const first = text[byte];
            if (first == '\n') {
                byte += 1;
                column = 0;
                lines = @max(lines, 1) + 1;
                continue;
            }
            if (first == '\r') {
                byte += 1;
                continue;
            }
            byte += glyphLength(text, byte);

            const x = @as(f32, @floatFromInt(column)) * (size.x + self.letter_spacing);
            column += 1;
            if (lines == 0) lines = 1;
            max_right = @max(max_right, x + size.x);
        }

        if (lines == 0) return .zero;
        return .init(
            max_right,
            @as(f32, @floatFromInt(lines)) * size.y +
                @as(f32, @floatFromInt(lines - 1)) * self.line_spacing,
        );
    }

    /// How many bytes one glyph consumes. A malformed sequence consumes exactly one, so a
    /// stray lead byte cannot swallow what follows it — the renderer's rule, restated
    /// because the two must agree.
    fn glyphLength(text: []const u8, at: usize) usize {
        const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return 1;
        if (at + len > text.len) return 1;
        _ = std.unicode.utf8Decode(text[at..][0..len]) catch return 1;
        return len;
    }
};

/// What a widget is allowed to know about how it looks.
///
/// Held on the `Context`, replaceable between frames, **read and never written** by the
/// kernel. That last property is what makes the content-driven theme a new producer later
/// rather than a rewrite.
pub const Style = struct {
    font: FontMetrics,
    /// World units per font pixel, for every string the kernel draws.
    text_scale: f32 = 1,
    /// The height of one row of controls.
    line_height: f32,
    /// Inset from a container's edge to its contents.
    padding: Vec2,
    /// Between one widget and the next.
    spacing: f32,
    /// How thick a separator's line is. A metric rather than a literal in `separator`,
    /// because ADR-0024 asks the kernel to contain neither, and because a HUD's divider and
    /// a debug panel's are not the same weight.
    separator_thickness: f32 = 1,
    /// How wide a scroll region's bar is, and therefore how much width its contents lose.
    scrollbar: f32 = 12,
    /// How many frames a text field's caret spends visible, and then hidden.
    ///
    /// **Frames, not milliseconds.** The kernel reads no clock (I9), so anything that has
    /// to animate counts the frame number the caller passes in — which is what makes a
    /// hundred frames of a test blink the same way on every machine.
    caret_blink_frames: u32 = 30,

    text: Color,
    text_dim: Color,
    surface: Color,
    control: Color,
    control_hot: Color,
    control_active: Color,
    accent: Color,
};

const testing = std.testing;

fn testMetrics() FontMetrics {
    return .{ .cell = .init(8, 8) };
}

test "empty text measures zero" {
    try testing.expectEqual(Vec2.zero, testMetrics().measure("", 1));
}

test "one line is glyphs wide and one cell tall" {
    const m = testMetrics();
    try testing.expectEqual(Vec2.init(24, 8), m.measure("abc", 1));
    try testing.expectEqual(Vec2.init(48, 16), m.measure("abc", 2));
}

test "spacing falls between cells, not after the last one" {
    const m: FontMetrics = .{ .cell = .init(8, 8), .letter_spacing = 2 };
    // Three cells and two gaps: 8 + 2 + 8 + 2 + 8.
    try testing.expectEqual(@as(f32, 28), m.measure("abc", 1).x);
    // One cell and no gap.
    try testing.expectEqual(@as(f32, 8), m.measure("a", 1).x);
}

test "lines stack, and the widest one sets the width" {
    const m: FontMetrics = .{ .cell = .init(8, 8), .line_spacing = 4 };
    const size = m.measure("ab\nlonger", 1);
    try testing.expectEqual(@as(f32, 48), size.x);
    // Two lines and one gap: 8 + 4 + 8.
    try testing.expectEqual(@as(f32, 20), size.y);
}

test "a trailing newline is a line, because a caller stacking blocks wants the space" {
    const m = testMetrics();
    try testing.expectEqual(@as(f32, 16), m.measure("a\n", 1).y);
}

test "carriage returns do not occupy a column" {
    const m = testMetrics();
    try testing.expectEqual(m.measure("ab\ncd", 1), m.measure("ab\r\ncd", 1));
}

test "a multi-byte codepoint is one glyph, and an invalid byte is one glyph" {
    const m = testMetrics();
    // Three bytes, one cell.
    try testing.expectEqual(@as(f32, 8), m.measure("\u{4e00}", 1).x);
    // A lone continuation byte is one substitute, and does not eat its neighbour.
    try testing.expectEqual(@as(f32, 16), m.measure("\x80a", 1).x);
    // A truncated sequence substitutes **per byte** rather than swallowing what follows a
    // stray lead byte — two glyphs here, not one. The renderer decodes it the same way, and
    // that agreement is the point: this is the arithmetic `ui.md` §8's drift test pins.
    try testing.expectEqual(@as(f32, 16), m.measure("\xe4\xb8", 1).x);
}
