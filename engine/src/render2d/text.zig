//! Bitmap text: where each glyph goes, and which part of the font it comes from.
//!
//! **Text is not a separate pipeline.** A glyph is a sprite cut from the font's texture,
//! so it goes through the same batcher, the same sort key and the same draw call as
//! everything else (`docs/design/render2d.md` §10). Text and sprites in the same layer
//! drawn from the same atlas are one draw call, and that is not a special case — it falls
//! out of a glyph being a sprite.
//!
//! **M2 supports fixed-grid fonts only.** A fixed grid needs no metrics file, and that is
//! the whole reason it was chosen: the authoring text syntax is a decision deliberately
//! postponed to M3 (CLAUDE.md §9), and inventing a font-metrics format here would resolve
//! part of it by accident. Variable-width fonts, kerning and fonts as real content-system
//! assets arrive in M3 alongside the format that can describe them.
//!
//! **The font is an asset the game supplies.** `render2d` ships no glyphs (I5). The M6
//! debug overlay will need to say where its font comes from, and the answer has to be
//! "the same place a game's font comes from", not "a private one" (I3, I4).

const std = @import("std");
const core = @import("core");

const atlas_mod = @import("atlas.zig");
const color_mod = @import("color.zig");
const texture_mod = @import("texture.zig");
const view_mod = @import("view.zig");

const BlendMode = color_mod.BlendMode;
const Color = color_mod.Color;
const Extent2D = texture_mod.Extent2D;
const Region = atlas_mod.Region;
const Vec2 = core.math.Vec2;
const YAxis = view_mod.YAxis;

/// A font whose glyphs sit on a fixed grid, in codepoint order.
pub const BitmapFont = struct {
    /// Where the grid lives.
    ///
    /// A `Region` rather than a `TextureHandle`, so a font packed into a shared atlas and
    /// a font on a texture of its own are the same thing to everything downstream. That is
    /// what makes "text and sprites in one draw call" reachable rather than aspirational.
    glyphs: Region,
    /// One cell, in pixels. Glyphs are drawn at this size times `TextOptions.scale`,
    /// including whatever blank margin the cell has — a 5x7 glyph in an 8x8 cell spaces
    /// itself, which is how a fixed grid gets away with having no metrics.
    cell: Extent2D,
    /// Cells per row of the grid.
    columns: u32,
    /// The codepoint of cell zero. 32 (space) for an ASCII font, which is the usual
    /// arrangement and therefore the default.
    first_codepoint: u21 = ' ',
    /// How many cells actually hold glyphs. Separate from `columns` because the last row
    /// is usually partial.
    glyph_count: u32,
    /// Drawn in place of a codepoint the font does not have, and in place of a byte that
    /// is not valid UTF-8.
    ///
    /// Null draws nothing and still advances, so a missing glyph leaves a gap rather than
    /// shifting the rest of the line. Either behaviour is defensible; silently dropping
    /// the character *and* its space is not, because it makes a translation file look
    /// subtly mis-typed rather than obviously missing a glyph.
    substitute: ?u21 = '?',

    /// The region for one codepoint, or null if the font has neither it nor a substitute.
    ///
    /// **Never recurses.** A substitute the font does not have yields null rather than a
    /// second lookup, because a font whose substitute is itself missing is a font that
    /// would otherwise loop.
    pub fn glyph(self: BitmapFont, codepoint: u21) ?Region {
        return self.cellRegion(codepoint) orelse
            if (self.substitute) |sub| self.cellRegion(sub) else null;
    }

    fn cellRegion(self: BitmapFont, codepoint: u21) ?Region {
        // A font is a struct a game fills in, and at M3 it will be a struct a *file* fills
        // in. Zero columns is a divide by zero and an empty cell is an empty draw, so both
        // are refused here rather than asserted.
        if (self.columns == 0 or self.cell.isEmpty() or self.glyph_count == 0) return null;
        if (codepoint < self.first_codepoint) return null;

        const index = @as(u32, codepoint) - @as(u32, self.first_codepoint);
        if (index >= self.glyph_count) return null;

        const col = index % self.columns;
        const row = index / self.columns;
        return self.glyphs.sub(
            col * self.cell.width,
            row * self.cell.height,
            self.cell.width,
            self.cell.height,
        );
    }

    /// One cell's size in world units at `scale`. The advance between glyphs, and the
    /// size each glyph is drawn at.
    pub fn cellSize(self: BitmapFont, scale: f32) Vec2 {
        return .init(
            @as(f32, @floatFromInt(self.cell.width)) * scale,
            @as(f32, @floatFromInt(self.cell.height)) * scale,
        );
    }
};

pub const TextOptions = struct {
    /// The **top-left** of the first glyph's cell, in world units.
    ///
    /// Top-left rather than the centre or the baseline: text reads from there, a fixed
    /// grid has no baseline to speak of, and a caller placing a line of statistics in a
    /// corner knows where the corner is and not where the baseline would be.
    position: Vec2,
    /// World units per font pixel.
    scale: f32 = 1,
    tint: Color = .white,
    layer: i16 = 0,
    blend: BlendMode = .alpha,
    /// Extra world units between cells, and between lines. Zero means the cells touch,
    /// which is what a font with built-in margin wants.
    letter_spacing: f32 = 0,
    line_spacing: f32 = 0,
};

/// One glyph, placed.
pub const Placement = struct {
    codepoint: u21,
    /// Top-left of the cell, in world units.
    position: Vec2,
    /// Cell size in world units.
    size: Vec2,
    /// Null when the font has no glyph and no substitute: advance, draw nothing.
    region: ?Region,
};

/// Walks a string and says where each glyph goes.
///
/// **Drawing and measuring share this**, for the same reason `writeQuad` and
/// `containsPoint` share `localExtents`: a measurement that disagreed with the drawing
/// would be a bug you could only find by looking at a screenshot.
///
/// The bytes are untrusted — a mod's translation file is text from a stranger — so invalid
/// UTF-8 produces a substitution glyph and advances by one byte, and iteration stops at the
/// slice's end rather than at any terminator.
pub const Layout = struct {
    font: BitmapFont,
    text: []const u8,
    options: TextOptions,
    /// Which way the space this is laid out in grows. Successive lines go *down* in both,
    /// which means subtracting in a Y-up world and adding on a Y-down screen. Set by the
    /// renderer from the current view; `measure` does not care, because a bounding box is
    /// two magnitudes and has no direction.
    y_axis: YAxis = .up,

    byte: usize = 0,
    column: u32 = 0,
    line: u32 = 0,

    /// The furthest right any cell has reached, relative to `position`. Grows as the
    /// layout is walked, so it is final only once `next` has returned null.
    max_right: f32 = 0,
    /// Newlines consumed so far, plus one, or zero before anything has been laid out.
    lines: u32 = 0,

    /// U+FFFD REPLACEMENT CHARACTER. Fed to `glyph`, which will not have it and will
    /// return the font's substitute — so malformed input and a missing glyph take the same
    /// path, and there is one behaviour to reason about instead of two.
    const replacement: u21 = 0xFFFD;

    pub fn init(font: BitmapFont, text: []const u8, options: TextOptions) Layout {
        return .{ .font = font, .text = text, .options = options };
    }

    pub fn initIn(font: BitmapFont, text: []const u8, options: TextOptions, y_axis: YAxis) Layout {
        return .{ .font = font, .text = text, .options = options, .y_axis = y_axis };
    }

    pub fn next(self: *Layout) ?Placement {
        const size = self.font.cellSize(self.options.scale);

        while (self.byte < self.text.len) {
            const codepoint = self.decode() orelse continue;

            const x = @as(f32, @floatFromInt(self.column)) *
                (size.x + self.options.letter_spacing);
            const y = @as(f32, @floatFromInt(self.line)) *
                (size.y + self.options.line_spacing);
            self.column += 1;
            if (self.lines == 0) self.lines = 1;
            self.max_right = @max(self.max_right, x + size.x);

            return .{
                .codepoint = codepoint,
                // The second line is *below* the first in both spaces, which is a
                // subtraction in one and an addition in the other.
                .position = .init(
                    self.options.position.x + x,
                    switch (self.y_axis) {
                        .up => self.options.position.y - y,
                        .down => self.options.position.y + y,
                    },
                ),
                .size = size,
                .region = self.font.glyph(codepoint),
            };
        }
        return null;
    }

    /// One codepoint, or null for a byte that produced no glyph — a line break, which has
    /// already moved the cursor, or a carriage return, which is ignored so that a file
    /// with CRLF endings does not draw a substitute at the end of every line.
    fn decode(self: *Layout) ?u21 {
        const first = self.text[self.byte];
        if (first == '\n') {
            self.byte += 1;
            self.column = 0;
            self.line += 1;
            self.lines = @max(self.lines, 1) + 1;
            return null;
        }
        if (first == '\r') {
            self.byte += 1;
            return null;
        }

        const len = std.unicode.utf8ByteSequenceLength(first) catch {
            self.byte += 1;
            return replacement;
        };
        if (self.byte + len > self.text.len) {
            // Truncated at the end of the slice. One byte, so that a stray lead byte does
            // not swallow whatever follows it.
            self.byte += 1;
            return replacement;
        }
        const decoded = std.unicode.utf8Decode(self.text[self.byte..][0..len]) catch {
            self.byte += 1;
            return replacement;
        };
        self.byte += len;
        return decoded;
    }
};

/// The bounding box of the text, in world units.
///
/// Runs the same `Layout` the drawing does, so the two cannot disagree. Empty text
/// measures zero; a trailing newline counts as a line, because a caller stacking blocks of
/// text wants the space it asked for.
pub fn measure(font: BitmapFont, text: []const u8, options: TextOptions) Vec2 {
    var layout: Layout = .init(font, text, options);
    while (layout.next()) |_| {}

    if (layout.lines == 0) return .zero;
    const size = font.cellSize(options.scale);
    const height = @as(f32, @floatFromInt(layout.lines)) * size.y +
        @as(f32, @floatFromInt(layout.lines - 1)) * options.line_spacing;
    return .init(layout.max_right, height);
}

const testing = std.testing;

/// A 16-column ASCII font on a texture of its own: 96 cells of 8x8, starting at space.
fn testFont() BitmapFont {
    return .{
        .glyphs = .whole(.none, .{ .width = 128, .height = 48 }),
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .first_codepoint = ' ',
        .glyph_count = 96,
    };
}

test "a codepoint maps to its cell in the grid" {
    const font = testFont();

    // Space is cell zero: the top-left of the grid.
    const space = font.glyph(' ').?;
    try testing.expectApproxEqAbs(@as(f32, 0), space.uv.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), space.uv.y, 1e-6);

    // 'A' is 65 - 32 = 33: row 2, column 1.
    const a = font.glyph('A').?;
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 128.0), a.uv.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 48.0), a.uv.y, 1e-6);
    try testing.expectEqual(@as(u32, 8), a.size_px.width);
}

test "a codepoint the font does not have draws the substitute" {
    const font = testFont();

    // Below the range and above it both fall back.
    try testing.expectEqual(font.glyph('?').?.uv.x, font.glyph(0x2603).?.uv.x);
    try testing.expectEqual(font.glyph('?').?.uv.y, font.glyph(0x0001).?.uv.y);
}

test "a font whose substitute is missing yields nothing rather than looping" {
    var font = testFont();
    font.substitute = 0x2603; // Not in the font either.
    try testing.expect(font.glyph(0x2604) == null);

    font.substitute = null;
    try testing.expect(font.glyph(0x2604) == null);
    // The glyphs it does have are unaffected.
    try testing.expect(font.glyph('A') != null);
}

test "a malformed font is refused rather than dividing by zero" {
    var font = testFont();
    font.columns = 0;
    try testing.expect(font.glyph('A') == null);

    font = testFont();
    font.cell = .{};
    try testing.expect(font.glyph('A') == null);

    font = testFont();
    font.glyph_count = 0;
    try testing.expect(font.glyph('A') == null);
}

test "glyphs advance across and lines advance down" {
    const font = testFont();
    var layout: Layout = .init(font, "ab\ncd", .{ .position = .init(100, 200), .scale = 2 });

    const a = layout.next().?;
    try testing.expectEqual(@as(u21, 'a'), a.codepoint);
    try testing.expectApproxEqAbs(@as(f32, 100), a.position.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 200), a.position.y, 1e-6);

    const b = layout.next().?;
    try testing.expectApproxEqAbs(@as(f32, 116), b.position.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 200), b.position.y, 1e-6);

    // The world is Y-up, so the second line is *below* the first: y decreases.
    const c = layout.next().?;
    try testing.expectEqual(@as(u21, 'c'), c.codepoint);
    try testing.expectApproxEqAbs(@as(f32, 100), c.position.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 184), c.position.y, 1e-6);
}

test "measuring runs the same layout the drawing does" {
    const font = testFont();
    const options: TextOptions = .{ .position = .zero, .scale = 1 };

    // Two lines, the longer being five cells.
    const size = measure(font, "hello\nhi", options);
    try testing.expectApproxEqAbs(@as(f32, 40), size.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 16), size.y, 1e-6);

    try testing.expectEqual(Vec2.zero, measure(font, "", options));

    // Spacing lands in the measurement too, and not on the trailing edge.
    const spaced = measure(font, "ab", .{ .position = .zero, .letter_spacing = 4 });
    try testing.expectApproxEqAbs(@as(f32, 20), spaced.x, 1e-6);
}

test "invalid utf-8 draws a substitute and never runs off the end" {
    const font = testFont();

    // A lone continuation byte, a truncated three-byte sequence, and an overlong lead
    // byte at the very end of the slice. None of these may read past `text.len`.
    const nasty = [_]u8{ 'a', 0x80, 0xE2, 0x82, 'b', 0xF0 };
    var layout: Layout = .init(font, &nasty, .{ .position = .zero });

    var seen: usize = 0;
    var substitutes: usize = 0;
    while (layout.next()) |p| {
        seen += 1;
        if (p.codepoint == 0xFFFD) substitutes += 1;
        try testing.expect(p.region != null);
    }
    // Six bytes in, six glyphs out: nothing was swallowed and nothing was invented.
    try testing.expectEqual(@as(usize, 6), seen);
    try testing.expectEqual(@as(usize, 4), substitutes);
}

test "text stops at the slice's end, not at a terminator" {
    const font = testFont();
    // An embedded NUL is a codepoint like any other: it draws a substitute, and the 'b'
    // after it is still drawn. A C-style loop would have stopped.
    var layout: Layout = .init(font, "a\x00b", .{ .position = .zero });
    var count: usize = 0;
    while (layout.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 3), count);
}

test "a multi-byte codepoint advances one cell, not one per byte" {
    const font = testFont();
    // 'é' is two bytes and one glyph. Getting this wrong shifts every subsequent
    // character on the line, which is the classic way text layout goes wrong.
    var layout: Layout = .init(font, "é!", .{ .position = .zero });
    _ = layout.next().?;
    const bang = layout.next().?;
    try testing.expectEqual(@as(u21, '!'), bang.codepoint);
    try testing.expectApproxEqAbs(@as(f32, 8), bang.position.x, 1e-6);
}

test "carriage returns are ignored so CRLF text does not gain a glyph per line" {
    const font = testFont();
    var layout: Layout = .init(font, "a\r\nb", .{ .position = .zero });
    const a = layout.next().?;
    const b = layout.next().?;
    try testing.expectEqual(@as(u21, 'a'), a.codepoint);
    try testing.expectEqual(@as(u21, 'b'), b.codepoint);
    try testing.expectApproxEqAbs(@as(f32, 0), b.position.x, 1e-6);
    try testing.expect(layout.next() == null);
}

test "lines stack downward in both spaces" {
    const font = testFont();
    const options: TextOptions = .{ .position = .init(0, 0) };

    var up: Layout = .initIn(font, "a\nb", options, .up);
    _ = up.next().?;
    // Y-up world: the second line is below, so y decreases.
    try testing.expectApproxEqAbs(@as(f32, -8), up.next().?.position.y, 1e-6);

    var down: Layout = .initIn(font, "a\nb", options, .down);
    _ = down.next().?;
    // Y-down screen: below is a larger y. Getting this backwards puts the second line of
    // a HUD above the first, which reads as the whole readout being upside down.
    try testing.expectApproxEqAbs(@as(f32, 8), down.next().?.position.y, 1e-6);
}

test "measuring is the same in both spaces" {
    // A bounding box is two magnitudes and has no direction, so `measure` needs no axis —
    // which is why right-aligning a HUD works with the same call that centres a label.
    const font = testFont();
    const options: TextOptions = .{ .position = .zero };
    const size = measure(font, "hello\\nhi", options);

    var down: Layout = .initIn(font, "hello\\nhi", options, .down);
    while (down.next()) |_| {}
    try testing.expectApproxEqAbs(size.x, down.max_right, 1e-6);
}
