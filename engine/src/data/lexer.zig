//! Tokens of the `.fdt` authoring format (ADR-0020).
//!
//! The lexer classifies **shape** and validates nothing. A run of word characters becomes
//! an identifier or a content ID depending on whether it contains a colon; whether it is a
//! *valid* one is `id.zig`'s question, asked by the parser. That split is deliberate: it
//! means every message about a malformed identifier comes from the one place that knows
//! the rules, and `Foundry:torch` produces "uppercase is not allowed" rather than a stray
//! character error pointing at the `F`.
//!
//! See `docs/design/content-schemas.md` §4.3.

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    /// Byte offsets into the source. Half-open.
    start: u32,
    end: u32,

    pub const Tag = enum {
        eof,
        /// A byte that cannot begin any token.
        invalid,
        /// A word starting with a letter or digit and containing no colon.
        identifier,
        /// A word containing at least one colon.
        content_id,
        /// `@` followed by a word. The text excludes the `@`.
        directive,
        /// `@` with nothing usable after it.
        invalid_directive,
        integer,
        float,
        /// A number that is neither: `1e`, `0x`, `1.`.
        malformed_number,
        string,
        /// A string closed by a newline or by the end of the file. Reported where it
        /// opened, because that is where the missing quote is.
        unterminated_string,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        lparen,
        rparen,

        /// What to print when a token appears in a message.
        pub fn describe(self: Tag) []const u8 {
            return switch (self) {
                .eof => "end of file",
                .invalid => "an unexpected character",
                .identifier => "a name",
                .content_id => "a content id",
                .directive => "a directive",
                .invalid_directive => "an incomplete directive",
                .integer => "an integer",
                .float => "a number",
                .malformed_number => "a malformed number",
                .string => "a string",
                .unterminated_string => "an unterminated string",
                .lbrace => "'{'",
                .rbrace => "'}'",
                .lbracket => "'['",
                .rbracket => "']'",
                .lparen => "'('",
                .rparen => "')'",
            };
        }
    };

    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn len(self: Token) u32 {
        return self.end - self.start;
    }
};

pub const Lexer = struct {
    source: []const u8,
    index: u32 = 0,

    pub fn init(source: []const u8) Lexer {
        // A UTF-8 BOM is what a Windows editor leaves behind, and the resulting error —
        // "an unexpected character" on line 1 column 1 of a file that looks fine — is one
        // of the least helpful diagnostics a format can produce. Skip it silently.
        const bom = "\xEF\xBB\xBF";
        const start: u32 = if (std.mem.startsWith(u8, source, bom)) bom.len else 0;
        return .{ .source = source, .index = start };
    }

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.index;
        if (self.index >= self.source.len) return .{ .tag = .eof, .start = start, .end = start };

        const c = self.source[self.index];
        return switch (c) {
            '{' => self.single(.lbrace),
            '}' => self.single(.rbrace),
            '[' => self.single(.lbracket),
            ']' => self.single(.rbracket),
            '(' => self.single(.lparen),
            ')' => self.single(.rparen),
            '"' => self.string(),
            '@' => self.directive(),
            '-', '0'...'9' => self.number(),
            else => if (isWordByte(c)) self.word() else self.single(.invalid),
        };
    }

    /// Every token in the source, for tests and for anything that wants a slice.
    pub fn tokenize(self: *Lexer, buffer: []Token) []Token {
        var n: usize = 0;
        while (n < buffer.len) {
            buffer[n] = self.next();
            n += 1;
            if (buffer[n - 1].tag == .eof) break;
        }
        return buffer[0..n];
    }

    fn single(self: *Lexer, tag: Token.Tag) Token {
        const start = self.index;
        self.index += 1;
        return .{ .tag = tag, .start = start, .end = self.index };
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                ' ', '\t', '\r', '\n' => self.index += 1,
                // One comment syntax, so there is never a question of which.
                '#' => while (self.index < self.source.len and self.source[self.index] != '\n') {
                    self.index += 1;
                },
                else => return,
            }
        }
    }

    fn word(self: *Lexer) Token {
        const start = self.index;
        var has_colon = false;
        while (self.index < self.source.len and isWordByte(self.source[self.index])) {
            if (self.source[self.index] == ':') has_colon = true;
            self.index += 1;
        }
        return .{
            .tag = if (has_colon) .content_id else .identifier,
            .start = start,
            .end = self.index,
        };
    }

    fn directive(self: *Lexer) Token {
        const start = self.index;
        self.index += 1; // '@'
        const name_start = self.index;
        while (self.index < self.source.len and isWordByte(self.source[self.index])) {
            self.index += 1;
        }
        return .{
            .tag = if (self.index == name_start) .invalid_directive else .directive,
            .start = start,
            .end = self.index,
        };
    }

    fn string(self: *Lexer) Token {
        const start = self.index;
        self.index += 1; // opening quote
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '"' => {
                    self.index += 1;
                    return .{ .tag = .string, .start = start, .end = self.index };
                },
                // A literal newline inside a string ends it, unterminated. This turns a
                // missing closing quote into a diagnostic on the line that is missing it,
                // rather than a parse failure a hundred lines further down where the next
                // quote happens to be.
                '\n' => break,
                '\\' => self.index += if (self.index + 1 < self.source.len) 2 else 1,
                else => self.index += 1,
            }
        }
        return .{ .tag = .unterminated_string, .start = start, .end = self.index };
    }

    fn number(self: *Lexer) Token {
        const start = self.index;
        if (self.source[self.index] == '-') self.index += 1;

        var is_float = false;
        var malformed = self.index >= self.source.len or !isDigit(self.source[self.index]);

        if (!malformed and self.source[self.index] == '0' and self.peekIs(1, 'x')) {
            self.index += 2;
            const digits_start = self.index;
            while (self.index < self.source.len and (isHexDigit(self.source[self.index]) or self.source[self.index] == '_')) {
                self.index += 1;
            }
            if (self.index == digits_start) malformed = true;
        } else {
            self.skipDigits();
            // A fraction, but only when a digit follows the dot: `1.` is a malformed
            // number and `foundry:a.b` never reaches here, because it starts with a letter.
            if (self.peekIs(0, '.')) {
                is_float = true;
                self.index += 1;
                const frac_start = self.index;
                self.skipDigits();
                if (self.index == frac_start) malformed = true;
            }
            if (self.peekIs(0, 'e') or self.peekIs(0, 'E')) {
                is_float = true;
                self.index += 1;
                if (self.peekIs(0, '+') or self.peekIs(0, '-')) self.index += 1;
                const exp_start = self.index;
                self.skipDigits();
                if (self.index == exp_start) malformed = true;
            }
        }

        // A number butted straight against a word — `2torch`, `0xzz` — is one mistake, not
        // two tokens. Swallowing the rest of the word means the parser can report it as a
        // malformed identifier and say which rule it broke.
        if (self.index < self.source.len and isWordByte(self.source[self.index])) {
            return self.wordFrom(start);
        }

        return .{
            .tag = if (malformed) .malformed_number else if (is_float) .float else .integer,
            .start = start,
            .end = self.index,
        };
    }

    fn wordFrom(self: *Lexer, start: u32) Token {
        var has_colon = std.mem.indexOfScalar(u8, self.source[start..self.index], ':') != null;
        while (self.index < self.source.len and isWordByte(self.source[self.index])) {
            if (self.source[self.index] == ':') has_colon = true;
            self.index += 1;
        }
        return .{
            .tag = if (has_colon) .content_id else .identifier,
            .start = start,
            .end = self.index,
        };
    }

    fn skipDigits(self: *Lexer) void {
        while (self.index < self.source.len and (isDigit(self.source[self.index]) or self.source[self.index] == '_')) {
            self.index += 1;
        }
    }

    fn peekIs(self: *const Lexer, ahead: u32, c: u8) bool {
        const i = self.index + ahead;
        return i < self.source.len and self.source[i] == c;
    }
};

/// The permissive character set a word may contain.
///
/// Wider than what `id.zig` accepts, on purpose. Uppercase, `.` and `:` are lexed into the
/// word so that the parser can hand the whole thing to the validator and get back a reason
/// naming the actual rule. `-` is included for the same reason: `item-torch` is one
/// mistake to report, not an identifier followed by a stray minus.
fn isWordByte(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', ':', '-' => true,
        else => false,
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

const testing = std.testing;

fn tagsOf(source: []const u8, buffer: []Token) []Token {
    var lexer: Lexer = .init(source);
    return lexer.tokenize(buffer);
}

fn expectTags(source: []const u8, expected: []const Token.Tag) !void {
    var buf: [64]Token = undefined;
    const tokens = tagsOf(source, &buf);
    try testing.expectEqual(expected.len + 1, tokens.len); // plus eof
    for (expected, tokens[0..expected.len]) |want, got| {
        try testing.expectEqual(want, got.tag);
    }
    try testing.expectEqual(Token.Tag.eof, tokens[tokens.len - 1].tag);
}

test "a record lexes into the shape the grammar expects" {
    try expectTags(
        \\item foundry:item.torch {
        \\    name    "Torch"
        \\    weight  0.5
        \\    stack   20
        \\    tags    ["light" "fuel"]
        \\    drops   foundry:item.ash
        \\}
    , &.{
        .identifier, .content_id, .lbrace,
        .identifier, .string,     .identifier,
        .float,      .identifier, .integer,
        .identifier, .lbracket,   .string,
        .string,     .rbracket,   .identifier,
        .content_id, .rbrace,
    });
}

test "comments and whitespace are trivia, and a comment runs to end of line" {
    try expectTags("# everything here is a comment { } \n item # trailing\n x", &.{ .identifier, .identifier });
    try expectTags("#no newline at the end", &.{});
    try expectTags("  \t\r\n  ", &.{});
}

test "a word is classified by shape, never by validity" {
    // All of these lex cleanly. Whether they are *valid* identifiers is `id.zig`'s
    // question, and asking it here would put the rules in two places.
    var buf: [8]Token = undefined;
    const tokens = tagsOf("Foundry:Torch item-torch 2torch foundry:a..b", &buf);
    try testing.expectEqual(Token.Tag.content_id, tokens[0].tag);
    try testing.expectEqual(Token.Tag.identifier, tokens[1].tag);
    try testing.expectEqual(Token.Tag.identifier, tokens[2].tag);
    try testing.expectEqual(Token.Tag.content_id, tokens[3].tag);

    const source = "Foundry:Torch item-torch 2torch foundry:a..b";
    try testing.expectEqualStrings("Foundry:Torch", tokens[0].text(source));
    // A number butted against a word is one mistake, not two tokens.
    try testing.expectEqualStrings("2torch", tokens[2].text(source));
}

test "integers and floats are different tokens, which is the point" {
    var buf: [16]Token = undefined;
    const source = "1 1.0 -3 -3.5 1e-3 1E6 0xff 1_000 1_000.5";
    const tokens = tagsOf(source, &buf);
    const want = [_]Token.Tag{
        .integer, .float, .integer, .float, .float, .float, .integer, .integer, .float,
    };
    for (want, tokens[0..want.len]) |expected, got| {
        try testing.expectEqual(expected, got.tag);
    }
}

test "a number that is not a number says so rather than lexing as something else" {
    try expectTags("1.", &.{.malformed_number});
    try expectTags("1e", &.{.malformed_number});
    try expectTags("1e+", &.{.malformed_number});
    try expectTags("-", &.{.malformed_number});
    try expectTags("0x", &.{.malformed_number});
    // `0xzz` is a word after the number, so it comes back as one malformed identifier.
    try expectTags("0xzz", &.{.identifier});
}

test "a string ends at its quote, and an unterminated one is reported where it opened" {
    var buf: [8]Token = undefined;
    const source =
        \\"ok" "escaped \" quote" "runs off
        \\next
    ;
    const tokens = tagsOf(source, &buf);
    try testing.expectEqual(Token.Tag.string, tokens[0].tag);
    try testing.expectEqual(Token.Tag.string, tokens[1].tag);
    try testing.expectEqualStrings("\"escaped \\\" quote\"", tokens[1].text(source));

    // The third opens and never closes. It stops at the newline rather than swallowing
    // the rest of the file looking for a quote.
    try testing.expectEqual(Token.Tag.unterminated_string, tokens[2].tag);
    try testing.expectEqualStrings("\"runs off", tokens[2].text(source));
    try testing.expectEqual(Token.Tag.identifier, tokens[3].tag);
}

test "a string that reaches the end of the file is unterminated, not eof" {
    try expectTags("\"no closing quote", &.{.unterminated_string});
    // A trailing backslash must not read past the end.
    try expectTags("\"trailing escape \\", &.{.unterminated_string});
}

test "directives are lexed as one token, and a bare @ is its own complaint" {
    var buf: [8]Token = undefined;
    const source = "@import @schema @ @123";
    const tokens = tagsOf(source, &buf);
    try testing.expectEqual(Token.Tag.directive, tokens[0].tag);
    try testing.expectEqualStrings("@import", tokens[0].text(source));
    try testing.expectEqual(Token.Tag.directive, tokens[1].tag);
    try testing.expectEqual(Token.Tag.invalid_directive, tokens[2].tag);
    // `@123` is shaped like a directive even though no directive is named that; the
    // parser is what knows the list.
    try testing.expectEqual(Token.Tag.directive, tokens[3].tag);
}

test "characters that begin nothing are single invalid tokens, not a swallowed line" {
    // Commas and equals signs are the two a person will type out of habit, and the parser
    // has a dedicated message for each. Both have to survive lexing to get there.
    try expectTags(",", &.{.invalid});
    try expectTags("=", &.{.invalid});
    try expectTags("a , b", &.{ .identifier, .invalid, .identifier });
    try expectTags("a = 1", &.{ .identifier, .invalid, .integer });
    try expectTags("%$", &.{ .invalid, .invalid });
}

test "a byte-order mark is skipped, because an editor put it there" {
    try expectTags("\xEF\xBB\xBFitem", &.{.identifier});
    var lexer: Lexer = .init("\xEF\xBB\xBFitem");
    const first = lexer.next();
    try testing.expectEqualStrings("item", first.text(lexer.source));
}

test "lexing terminates on every prefix of a plausible file" {
    // Cheap stand-in for a fuzzer, and it has caught real infinite loops in this shape of
    // code before: every truncation must reach eof rather than spin.
    const source =
        \\@import "a.fdt"
        \\@schema foundry:item { weight f32 (default 0.5) }
        \\item foundry:item.torch { name "Torch" tags ["a" "b"] drops foundry:item.ash }
    ;
    for (0..source.len + 1) |cut| {
        var lexer: Lexer = .init(source[0..cut]);
        var seen: usize = 0;
        while (true) {
            const token = lexer.next();
            if (token.tag == .eof) break;
            seen += 1;
            try testing.expect(seen <= source.len + 1);
        }
    }
}

test "every byte value is lexable without a panic" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    var lexer: Lexer = .init(&all);
    var seen: usize = 0;
    while (lexer.next().tag != .eof) : (seen += 1) {
        try testing.expect(seen <= all.len);
    }
}
