//! The canonical layout of `.fdt` source (`content-schemas.md` §10, question 4; M26 Step 10).
//!
//! **Only layout is decided here, and only the layout nobody chose on purpose.** Each line is
//! indented four spaces deeper than the line that opened the innermost `{`, `[` or `(` still
//! open, so `lights [{` indents what follows once; a line that begins by closing brackets sits
//! at the line that opened the last of them. Trailing spaces and tabs go, a run of blank lines becomes one, there
//! are none at the start or end, and the file ends in exactly one line ending, in the style of
//! its first (`\r\n` or `\n`). A UTF-8 byte-order mark stays where it is.
//!
//! **Everything inside a line is kept byte for byte**, comments and spacing included. Authors
//! align values in columns and use a double space to group fields on one line, and both carry
//! meaning a formatter cannot see, so the canonical form is the one that leaves them alone.
//!
//! **A file it cannot keep exactly is refused, never repaired**: a token the lexer cannot read
//! (an unterminated string, a malformed number, a stray byte) or brackets that do not balance.
//! The result is checked before it is returned: its tokens are the source's tokens, in order
//! and byte for byte. So formatting changes whitespace and nothing else, and doing it twice
//! changes nothing the second time.

const std = @import("std");

const lexer = @import("lexer.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    /// A token the lexer cannot read; formatting around it could move what it meant.
    UnreadableToken,
    /// A closing bracket with nothing open, or a bracket still open at the end.
    Unbalanced,
};

pub const indent_width = 4;

/// The canonical layout of `source`, caller-owned. See the file comment for the rules.
pub fn format(gpa: Allocator, source: []const u8) Error![]u8 {
    const bom = "\xEF\xBB\xBF";
    const has_bom = std.mem.startsWith(u8, source, bom);
    const body = source[if (has_bom) bom.len else 0..];
    const line_end: []const u8 = if (std.mem.indexOfScalar(u8, body, '\n')) |at|
        (if (at > 0 and body[at - 1] == '\r') "\r\n" else "\n")
    else
        "\n";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (has_bom) try out.appendSlice(gpa, bom);

    // The open brackets, innermost last, each with the level of the line that opened it: a
    // `]` must close a `[`, and a line opening two (`lights [{`) indents what follows once.
    const Open = struct { tag: lexer.Token.Tag, level: usize };
    var open: std.ArrayList(Open) = .empty;
    defer open.deinit(gpa);
    var wrote_line = false;
    var pending_blank = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t\r");
        if (text.len == 0) {
            // Held until the next line with text, so blank lines never lead or trail.
            pending_blank = wrote_line;
            continue;
        }

        // One level inside the innermost open bracket's line, unless the line begins by
        // closing brackets: then it sits at the line that opened the last of them.
        var level: usize = if (open.items.len == 0) 0 else open.items[open.items.len - 1].level + 1;
        var leading = true;
        var lex = lexer.Lexer.init(text);
        while (true) {
            const token = lex.next();
            switch (token.tag) {
                .eof => break,
                .invalid, .invalid_directive, .malformed_number, .unterminated_string => return error.UnreadableToken,
                .lbrace, .lbracket, .lparen => {
                    leading = false;
                    try open.append(gpa, .{ .tag = token.tag, .level = level });
                },
                .rbrace, .rbracket, .rparen => {
                    const opener: lexer.Token.Tag = switch (token.tag) {
                        .rbrace => .lbrace,
                        .rbracket => .lbracket,
                        else => .lparen,
                    };
                    if (open.items.len == 0 or open.items[open.items.len - 1].tag != opener) return error.Unbalanced;
                    const closed = open.pop().?;
                    if (leading) level = closed.level;
                },
                else => leading = false,
            }
        }

        if (wrote_line) try out.appendSlice(gpa, line_end);
        if (pending_blank) try out.appendSlice(gpa, line_end);
        pending_blank = false;
        try out.appendNTimes(gpa, ' ', level * indent_width);
        try out.appendSlice(gpa, text);
        wrote_line = true;
    }
    if (open.items.len != 0) return error.Unbalanced;
    if (wrote_line) try out.appendSlice(gpa, line_end);

    const result = try out.toOwnedSlice(gpa);
    errdefer gpa.free(result);
    // Whitespace is all that may have changed. Anything else is this file's bug, and an
    // assertion rather than a refusal, because no input should be able to reach it.
    std.debug.assert(sameTokens(source, result));
    return result;
}

/// Whether `a` and `b` lex to the same tokens, with the same bytes, in the same order.
pub fn sameTokens(a: []const u8, b: []const u8) bool {
    var la = lexer.Lexer.init(a);
    var lb = lexer.Lexer.init(b);
    while (true) {
        const ta = la.next();
        const tb = lb.next();
        if (ta.tag != tb.tag or !std.mem.eql(u8, ta.text(a), tb.text(b))) return false;
        if (ta.tag == .eof) return comments(a).eql(comments(b));
    }
}

/// A count and checksum of a file's comment text, so a comment lost or altered is noticed
/// even though the lexer treats comments as trivia.
const Comments = struct {
    count: usize = 0,
    hash: u64 = 0,
    fn eql(x: Comments, y: Comments) bool {
        return x.count == y.count and x.hash == y.hash;
    }
};

fn comments(source: []const u8) Comments {
    var result: Comments = .{};
    var hasher = std.hash.Wyhash.init(0);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        // A `#` inside a string is not a comment; the lexer knows where strings are.
        var lex = lexer.Lexer.init(line);
        var code_end: usize = 0;
        while (true) {
            const token = lex.next();
            if (token.tag == .eof) break;
            code_end = token.end;
        }
        const rest = line[code_end..];
        if (std.mem.indexOfScalar(u8, rest, '#')) |at| {
            const comment = std.mem.trimEnd(u8, rest[at..], " \t\r");
            hasher.update(comment);
            hasher.update("\n");
            result.count += 1;
        }
    }
    result.hash = hasher.final();
    return result;
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFormats(source: []const u8, expected: []const u8) !void {
    const once = try format(testing.allocator, source);
    defer testing.allocator.free(once);
    try testing.expectEqualStrings(expected, once);
    const twice = try format(testing.allocator, once);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "format indents by depth and keeps everything inside a line" {
    try expectFormats(
        "@schema foundry:item {\n  name    string   # aligned\n\tweight f32  tags [string]\n      }\n",
        "@schema foundry:item {\n    name    string   # aligned\n    weight f32  tags [string]\n}\n",
    );
    try expectFormats(
        "a:b {\nlights [{\nintensity f32\n}]\n}\n",
        "a:b {\n    lights [{\n        intensity f32\n    }]\n}\n",
    );
    // A line that closes several brackets sits at the depth it closes to.
    try expectFormats("x:y {\nv [(\n1\n)]\n}", "x:y {\n    v [(\n        1\n    )]\n}\n");
}

test "format trims, collapses blank lines and ends with one line ending in the file's style" {
    try expectFormats("\n\n# top   \n\n\n\na:b {   \n}\n\n\n", "# top\n\na:b {\n}\n");
    try expectFormats("a:b {\r\n\r\n\r\n  x 1\r\n}", "a:b {\r\n\r\n    x 1\r\n}\r\n");
    try expectFormats("\xEF\xBB\xBF a:b { }\n", "\xEF\xBB\xBFa:b { }\n");
    try expectFormats("", "");
    try expectFormats("\n \t\n", "");
}

test "format leaves a # inside a string and a brace inside a comment alone" {
    try expectFormats("a:b {\n  s \"# not a comment {\"  # but { this is\n}\n", "a:b {\n    s \"# not a comment {\"  # but { this is\n}\n");
}

test "format refuses what it cannot keep exactly" {
    const Case = struct { source: []const u8, err: Error };
    for ([_]Case{
        .{ .source = "a:b {\n", .err = error.Unbalanced },
        .{ .source = "}\n", .err = error.Unbalanced },
        .{ .source = "a:b { ]\n", .err = error.Unbalanced },
        .{ .source = "a:b [ ( ] )\n", .err = error.Unbalanced },
        .{ .source = "a:b { s \"open\n}\n", .err = error.UnreadableToken },
        .{ .source = "a:b { x 1e }\n", .err = error.UnreadableToken },
        .{ .source = "a:b { ` }\n", .err = error.UnreadableToken },
        .{ .source = "@ x\n", .err = error.UnreadableToken },
    }) |case| try testing.expectError(case.err, format(testing.allocator, case.source));
}

test "sameTokens notices a changed token, a lost comment and an altered comment" {
    try testing.expect(sameTokens("a:b { x 1 } # c", "a:b {\n    x 1\n} # c\n"));
    try testing.expect(!sameTokens("a:b { x 1 }", "a:b { x 2 }"));
    try testing.expect(!sameTokens("a:b { x 1 } # c", "a:b { x 1 }"));
    try testing.expect(!sameTokens("a:b { x 1 } # c", "a:b { x 1 } # d"));
    try testing.expect(sameTokens("s \"#\"", "s  \"#\""));
}
