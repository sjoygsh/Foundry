//! What the content pipeline says when something is wrong.
//!
//! ADR-0020 records that owning the parser is bought principally for this, and ADR-0006
//! says why it matters: **a mod author cannot debug a crash.** So a diagnostic is not a
//! string with an error code attached — it carries the file, the line, the column, the run
//! of source it points at, and the text of that line, so the message can be shown against
//! the code that caused it.
//!
//! Diagnostics are collected rather than returned. A parser that stops at the first error
//! turns fixing twenty mistakes into a twenty-build afternoon.
//!
//! See `docs/design/content-schemas.md` §4.5.

const std = @import("std");
const core = @import("core");
const limits_mod = @import("limits.zig");

const Allocator = std.mem.Allocator;
const Limits = limits_mod.Limits;

pub const Severity = enum {
    err,
    warning,
    note,

    pub fn text(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

/// A place in a file, resolved at the moment the diagnostic is made.
///
/// Line and column are 1-based, and **column is counted in bytes**, not in codepoints or
/// display cells. That is what makes the caret line up under the source line as printed;
/// it is also why a tab in the offending line will look wrong, which is a trade the
/// alternative — carrying an encoding-aware renderer into L1 — does not justify.
pub const Location = struct {
    file: []const u8,
    /// Zero for a place inside a file that has no lines — a compiled `.fpk`, which is
    /// where every complaint the store makes comes from. Such a diagnostic names the file
    /// and stops, because `torch.fpk:0:0` is worse than `torch.fpk` at pointing anywhere.
    line: u32,
    column: u32,

    /// A whole-file location, for something that went wrong in a file with no text.
    pub fn whole(file: []const u8) Location {
        return .{ .file = file, .line = 0, .column = 0 };
    }

    pub fn format(self: Location, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.line == 0) return writer.print("{s}", .{self.file});
        try writer.print("{s}:{d}:{d}", .{ self.file, self.line, self.column });
    }
};

/// A secondary location that explains the first — "the schema is declared over here".
pub const Note = struct {
    location: Location,
    message: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    location: Location,
    /// How many bytes the caret run covers. At least 1.
    length: u32,
    /// The text of `location.line`, without its newline. Captured now so that rendering
    /// needs no access to the source, which matters because a document may span many
    /// files through `@import` and the parser is the only thing holding all of them.
    source_line: []const u8,
    message: []const u8,
    note: ?Note = null,
};

/// A collected list, with an arena for the strings it owns.
///
/// The cap exists because a binary file handed to the parser by accident should produce
/// twenty errors and a note, not a hundred thousand lines. Everything past it is counted
/// rather than dropped silently.
pub const Diagnostics = struct {
    arena: core.Arena,
    items: std.ArrayList(Diagnostic) = .empty,
    limits: Limits,
    /// How many diagnostics were not recorded because the cap was reached.
    suppressed: u32 = 0,
    /// Set once anything of severity `err` has been recorded, so a caller can ask whether
    /// the run failed without walking the list.
    failed: bool = false,

    pub fn init(gpa: Allocator, limits: Limits) Diagnostics {
        return .{ .arena = .init(gpa), .limits = limits };
    }

    pub fn deinit(self: *Diagnostics, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.items.items.len;
    }

    /// Records a diagnostic, copying every string into the arena.
    ///
    /// Reaching the cap is not an error and does not stop the caller: it stops *recording*.
    /// A parser that failed because it could not allocate a message would be reporting the
    /// wrong problem.
    pub fn add(self: *Diagnostics, gpa: Allocator, d: Diagnostic) Allocator.Error!void {
        if (d.severity == .err) self.failed = true;
        if (self.items.items.len >= self.limits.max_diagnostics) {
            self.suppressed +|= 1;
            return;
        }
        const a = self.arena.allocator();
        try self.items.append(gpa, .{
            .severity = d.severity,
            .location = .{
                .file = try a.dupe(u8, d.location.file),
                .line = d.location.line,
                .column = d.location.column,
            },
            .length = @max(1, d.length),
            .source_line = try a.dupe(u8, d.source_line),
            .message = try a.dupe(u8, d.message),
            .note = if (d.note) |n| .{
                .location = .{
                    .file = try a.dupe(u8, n.location.file),
                    .line = n.location.line,
                    .column = n.location.column,
                },
                .message = try a.dupe(u8, n.message),
            } else null,
        });
    }

    /// Formats a message into the arena and records it. The common path.
    pub fn addFmt(
        self: *Diagnostics,
        gpa: Allocator,
        severity: Severity,
        location: Location,
        length: u32,
        source_line: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        // Formatted before the cap check so that the message is not built when it will be
        // thrown away... and after, because the cap check is cheap and the format is not.
        if (self.items.items.len >= self.limits.max_diagnostics) {
            if (severity == .err) self.failed = true;
            self.suppressed +|= 1;
            return;
        }
        const message = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.add(gpa, .{
            .severity = severity,
            .location = location,
            .length = length,
            .source_line = source_line,
            .message = message,
        });
    }

    /// Writes every diagnostic in the shape `content-schemas.md` §4.5 specifies.
    pub fn render(self: *const Diagnostics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.items.items) |d| {
            try writer.print("{f}: {s}: {s}\n", .{ d.location, d.severity.text(), d.message });
            if (d.source_line.len > 0) {
                try writer.print("{s}\n", .{d.source_line});
                try writeCaret(writer, d.source_line, d.location.column, d.length);
            }
            if (d.note) |n| {
                try writer.print("note: {s} at {f}\n", .{ n.message, n.location });
            }
        }
        if (self.suppressed > 0) {
            try writer.print(
                "note: {d} further diagnostics not shown\n",
                .{self.suppressed},
            );
        }
    }

    /// Indents the caret with the source line's own leading whitespace, so that a line
    /// indented with tabs still gets its caret under the right token.
    fn writeCaret(
        writer: *std.Io.Writer,
        source_line: []const u8,
        column: u32,
        length: u32,
    ) std.Io.Writer.Error!void {
        const start = column - 1;
        for (0..start) |i| {
            const c = if (i < source_line.len) source_line[i] else ' ';
            try writer.writeByte(if (c == '\t') '\t' else ' ');
        }
        try writer.writeByte('^');
        for (1..length) |_| try writer.writeByte('~');
        try writer.writeByte('\n');
    }
};

/// A named blob of source, and the arithmetic for turning a byte offset into a place a
/// human can find.
///
/// Line and column are computed on demand rather than tracked per token, because a token
/// stream is long and a diagnostic list is short: paying at the point of failure costs a
/// scan of one file, and paying per token costs two fields on every token in the project.
pub const Source = struct {
    name: []const u8,
    bytes: []const u8,

    pub fn location(self: Source, offset: usize) Location {
        const clamped = @min(offset, self.bytes.len);
        var line: u32 = 1;
        var line_start: usize = 0;
        for (self.bytes[0..clamped], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{
            .file = self.name,
            .line = line,
            .column = @intCast(clamped - line_start + 1),
        };
    }

    /// The text of the line containing `offset`, without its newline.
    pub fn lineText(self: Source, offset: usize) []const u8 {
        const clamped = @min(offset, self.bytes.len);
        const start = if (std.mem.lastIndexOfScalar(u8, self.bytes[0..clamped], '\n')) |i| i + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, clamped, '\n') orelse self.bytes.len;
        return std.mem.trimEnd(u8, self.bytes[start..end], "\r");
    }
};

const testing = std.testing;

test "a byte offset becomes a place a human can find" {
    const src: Source = .{ .name = "items.fdt", .bytes = "item foundry:x {\n    weight 0.5\n}\n" };

    try testing.expectEqual(@as(u32, 1), src.location(0).line);
    try testing.expectEqual(@as(u32, 1), src.location(0).column);

    const weight = std.mem.indexOf(u8, src.bytes, "weight").?;
    const loc = src.location(weight);
    try testing.expectEqual(@as(u32, 2), loc.line);
    try testing.expectEqual(@as(u32, 5), loc.column);
    try testing.expectEqualStrings("    weight 0.5", src.lineText(weight));

    // Past the end resolves to the end rather than trapping: a diagnostic about an
    // unexpected end of file has to point somewhere.
    const end = src.location(src.bytes.len + 100);
    try testing.expectEqual(@as(u32, 4), end.line);
}

test "a line without a trailing newline still has text" {
    const src: Source = .{ .name = "a.fdt", .bytes = "one\ntwo" };
    try testing.expectEqualStrings("two", src.lineText(5));
    try testing.expectEqualStrings("one", src.lineText(0));
    // CRLF files are read on Windows too; the caret should not point past a stray \r.
    const crlf: Source = .{ .name = "b.fdt", .bytes = "one\r\ntwo\r\n" };
    try testing.expectEqualStrings("one", crlf.lineText(0));
}

test "diagnostics render with the source line and a caret under the span" {
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);

    try diags.add(testing.allocator, .{
        .severity = .err,
        .location = .{ .file = "light.fdt", .line = 7, .column = 13 },
        .length = 5,
        .source_line = "    weight  \"0.5\"",
        .message = "field 'weight' of schema 'foundry:item' expects f32, found string",
        .note = .{
            .location = .{ .file = "item.fdt", .line = 3, .column = 1 },
            .message = "schema 'foundry:item' declared",
        },
    });

    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try diags.render(&writer);

    try testing.expectEqualStrings(
        \\light.fdt:7:13: error: field 'weight' of schema 'foundry:item' expects f32, found string
        \\    weight  "0.5"
        \\            ^~~~~
        \\note: schema 'foundry:item' declared at item.fdt:3:1
        \\
    , writer.buffered());
}

test "a diagnostic owns its strings, so the source may go away" {
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);

    var message: [5]u8 = "boom!".*;
    var line: [3]u8 = "abc".*;
    try diags.add(testing.allocator, .{
        .severity = .err,
        .location = .{ .file = "x.fdt", .line = 1, .column = 1 },
        .length = 1,
        .source_line = &line,
        .message = &message,
    });
    @memset(&message, 'z');
    @memset(&line, 'z');

    try testing.expectEqualStrings("boom!", diags.items.items[0].message);
    try testing.expectEqualStrings("abc", diags.items.items[0].source_line);
    try testing.expect(diags.failed);
}

test "the cap stops recording, not parsing, and says how many it swallowed" {
    var diags: Diagnostics = .init(testing.allocator, .{ .max_diagnostics = 2 });
    defer diags.deinit(testing.allocator);

    for (0..5) |i| {
        try diags.addFmt(testing.allocator, .err, .{
            .file = "x.fdt",
            .line = @intCast(i + 1),
            .column = 1,
        }, 1, "", "problem {d}", .{i});
    }

    try testing.expectEqual(@as(usize, 2), diags.count());
    try testing.expectEqual(@as(u32, 3), diags.suppressed);
    try testing.expect(diags.failed);

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try diags.render(&writer);
    try testing.expect(std.mem.containsAtLeast(u8, writer.buffered(), 1, "3 further diagnostics not shown"));
}

test "warnings do not make a run fail" {
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);

    try diags.addFmt(testing.allocator, .warning, .{ .file = "x", .line = 1, .column = 1 }, 1, "", "careful", .{});
    try testing.expect(!diags.failed);
    try testing.expectEqual(@as(usize, 1), diags.count());
}
