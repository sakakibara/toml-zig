//! Streaming token-level lexer.
//!
//! Yields one `Token` at a time from a source slice, without building a
//! `Value` tree. Useful for tooling: syntax highlighters, incremental
//! re-parse, format-preserving editors that need to walk the source
//! token-by-token.
//!
//! ```zig
//! var t: toml.Tokenizer = .init(src);
//! while (t.next()) |tok| switch (tok.kind) {
//!     .key => std.debug.print("key {s}\n", .{src[tok.span.start..tok.span.end]}),
//!     .value_string => ...,
//!     ...
//! }
//! ```
//!
//! The tokenizer does NOT enforce semantic rules (table redefinition,
//! seal sets, etc.). It is purely lexical. For a strict spec-conformant
//! parse use `parse` or `Document.parse`. The token stream classifies
//! the bytes into syntactic categories.

const std = @import("std");
const v = @import("value.zig");

pub const Span = v.Span;

pub const Kind = enum {
    /// A blank or whitespace-only line.
    blank,
    /// A `# ...` comment line.
    comment,
    /// `[name]` table header opener (excluding the closing `]`).
    header_open,
    /// `[[name]]` array-of-tables header opener.
    header_array_open,
    /// A header path segment (e.g., `name` in `[name]` or `a` and `b` in `[a.b]`).
    header_segment,
    /// `]` or `]]` closing a header.
    header_close,
    /// A key-value pair's key segment (one segment of a possibly
    /// dotted key).
    key_segment,
    /// `=` between key and value.
    equals,
    /// A value token whose payload is a string (basic or literal,
    /// single or multi-line).
    value_string,
    /// A value token whose payload is an integer literal.
    value_integer,
    /// A value token whose payload is a float literal.
    value_float,
    /// A value token whose payload is `true` or `false`.
    value_bool,
    /// A value token whose payload is a date/time/datetime literal.
    value_datetime,
    /// `[` or `]` of an inline array, or `,` separator inside.
    array_punct,
    /// `{` or `}` of an inline table, or `,` separator inside.
    inline_table_punct,
    /// `.` separator inside dotted keys/headers.
    dot,
    /// End of physical line (newline, possibly preceded by trailing comment).
    eol,
    /// Unrecognized byte sequence; payload covers whatever the tokenizer
    /// chose to skip. Tooling can highlight as an error.
    err,
};

pub const Token = struct {
    kind: Kind,
    span: Span,
};

pub const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    state: State = .top,

    const State = enum {
        top,           // statement start
        after_eq,      // expecting a value
        in_array,      // inside `[ ... ]` array
        in_inline_tbl, // inside `{ ... }` inline table
        after_value,   // expecting `,`, `]`, `}`, or EOL
    };

    pub fn init(input: []const u8) Tokenizer {
        return .{ .input = input };
    }

    pub fn next(self: *Tokenizer) ?Token {
        if (self.pos >= self.input.len) return null;

        // Skip non-newline whitespace, but not in places where it would
        // skip over newlines (which are tokens).
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t') {
                self.advance();
            } else break;
        }
        if (self.pos >= self.input.len) return null;

        const start = self.snap();
        const c = self.input[self.pos];

        // Newline: always EOL.
        if (c == '\n') {
            self.advance();
            self.state = .top;
            return self.token(.eol, start);
        }
        if (c == '\r') {
            self.advance();
            if (self.pos < self.input.len and self.input[self.pos] == '\n') self.advance();
            self.state = .top;
            return self.token(.eol, start);
        }

        // Comment.
        if (c == '#') {
            while (self.pos < self.input.len and self.input[self.pos] != '\n') self.advance();
            return self.token(.comment, start);
        }

        return switch (self.state) {
            .top => self.tokTopOrKey(start),
            .after_eq => self.tokValue(start),
            .in_array => self.tokInArray(start),
            .in_inline_tbl => self.tokInInlineTable(start),
            .after_value => self.tokAfterValue(start),
        };
    }

    fn tokTopOrKey(self: *Tokenizer, start: Span) Token {
        const c = self.input[self.pos];
        if (c == '[') {
            self.advance();
            if (self.pos < self.input.len and self.input[self.pos] == '[') {
                self.advance();
                self.state = .top; // headers stay in .top so segments parse
                return self.token(.header_array_open, start);
            }
            self.state = .top;
            return self.token(.header_open, start);
        }
        if (c == ']') {
            self.advance();
            if (self.pos < self.input.len and self.input[self.pos] == ']') self.advance();
            self.state = .top;
            return self.token(.header_close, start);
        }
        if (c == '.') {
            self.advance();
            return self.token(.dot, start);
        }
        if (c == '=') {
            self.advance();
            self.state = .after_eq;
            return self.token(.equals, start);
        }
        return self.tokKeyOrSegment(start);
    }

    fn tokKeyOrSegment(self: *Tokenizer, start: Span) Token {
        // Bare or quoted key.
        if (self.input[self.pos] == '"' or self.input[self.pos] == '\'') {
            return self.tokQuotedKey(start);
        }
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            const ok = (c >= 'A' and c <= 'Z') or
                (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or
                c == '_' or c == '-';
            if (!ok) break;
            self.advance();
        }
        if (self.pos == start.start) {
            self.advance();
            return self.token(.err, start);
        }
        return self.token(.key_segment, start);
    }

    fn tokQuotedKey(self: *Tokenizer, start: Span) Token {
        self.consumeQuotedString();
        return self.token(.key_segment, start);
    }

    fn tokValue(self: *Tokenizer, start: Span) Token {
        const c = self.input[self.pos];
        if (c == '[') {
            self.advance();
            self.state = .in_array;
            return self.token(.array_punct, start);
        }
        if (c == '{') {
            self.advance();
            self.state = .in_inline_tbl;
            return self.token(.inline_table_punct, start);
        }
        return self.tokScalar(start);
    }

    fn tokInArray(self: *Tokenizer, start: Span) Token {
        const c = self.input[self.pos];
        if (c == ']') {
            self.advance();
            self.state = .after_value;
            return self.token(.array_punct, start);
        }
        if (c == ',') {
            self.advance();
            return self.token(.array_punct, start);
        }
        if (c == '[') {
            self.advance();
            // Nested array; keep state as in_array (depth not tracked
            // in this minimal tokenizer; consumers can count tokens).
            return self.token(.array_punct, start);
        }
        if (c == '{') {
            self.advance();
            self.state = .in_inline_tbl;
            return self.token(.inline_table_punct, start);
        }
        return self.tokScalar(start);
    }

    fn tokInInlineTable(self: *Tokenizer, start: Span) Token {
        const c = self.input[self.pos];
        if (c == '}') {
            self.advance();
            self.state = .after_value;
            return self.token(.inline_table_punct, start);
        }
        if (c == ',') {
            self.advance();
            return self.token(.inline_table_punct, start);
        }
        if (c == '=') {
            self.advance();
            return self.token(.equals, start);
        }
        if (c == '.') {
            self.advance();
            return self.token(.dot, start);
        }
        return self.tokKeyOrSegment(start);
    }

    fn tokAfterValue(self: *Tokenizer, start: Span) Token {
        // Same as top-level - expect comment, EOL, or next statement.
        self.state = .top;
        return self.tokTopOrKey(start);
    }

    fn tokScalar(self: *Tokenizer, start: Span) Token {
        const c = self.input[self.pos];
        if (c == '"' or c == '\'') {
            self.consumeQuotedString();
            self.state = .after_value;
            return self.token(.value_string, start);
        }
        if (c == 't' or c == 'f') {
            const remaining = self.input[self.pos..];
            if (std.mem.startsWith(u8, remaining, "true")) {
                for (0..4) |_| self.advance();
                self.state = .after_value;
                return self.token(.value_bool, start);
            }
            if (std.mem.startsWith(u8, remaining, "false")) {
                for (0..5) |_| self.advance();
                self.state = .after_value;
                return self.token(.value_bool, start);
            }
        }
        // Numeric / datetime: scan until terminator. Decide which by
        // looking for `-` or `:` past the first byte.
        const num_start = self.pos;
        while (self.pos < self.input.len) {
            const k = self.input[self.pos];
            if (k == ',' or k == ']' or k == '}' or k == '#' or k == '\n' or k == '\r') break;
            if (k == ' ' or k == '\t') {
                // Datetime allows a space between date and time. Heuristic:
                // if the bytes before look like YYYY-MM-DD and next byte
                // is a digit, it's part of the datetime.
                if (self.pos - num_start == 10 and looksLikeDate(self.input[num_start..self.pos])) {
                    if (self.pos + 1 < self.input.len and isDigit(self.input[self.pos + 1])) {
                        self.advance();
                        continue;
                    }
                }
                break;
            }
            self.advance();
        }
        const slice = self.input[num_start..self.pos];
        const kind: Kind = if (looksLikeDateOrTime(slice))
            .value_datetime
        else if (std.mem.indexOfScalar(u8, slice, '.') != null or
            std.mem.indexOfAny(u8, slice, "eE") != null or
            std.mem.eql(u8, slice, "inf") or std.mem.eql(u8, slice, "+inf") or
            std.mem.eql(u8, slice, "-inf") or std.mem.eql(u8, slice, "nan") or
            std.mem.eql(u8, slice, "+nan") or std.mem.eql(u8, slice, "-nan"))
            .value_float
        else
            .value_integer;
        self.state = .after_value;
        return self.token(kind, start);
    }

    fn consumeQuotedString(self: *Tokenizer) void {
        const q = self.input[self.pos];
        if (self.pos + 2 < self.input.len and
            self.input[self.pos + 1] == q and self.input[self.pos + 2] == q)
        {
            // Multi-line string.
            for (0..3) |_| self.advance();
            while (self.pos + 2 < self.input.len) {
                if (q == '"' and self.input[self.pos] == '\\' and self.pos + 1 < self.input.len) {
                    self.advance();
                    self.advance();
                    continue;
                }
                if (self.input[self.pos] == q and
                    self.input[self.pos + 1] == q and
                    self.input[self.pos + 2] == q)
                {
                    for (0..3) |_| self.advance();
                    return;
                }
                self.advance();
            }
            // Unterminated: consume rest.
            while (self.pos < self.input.len) self.advance();
            return;
        }
        // Single-line string.
        self.advance();
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\n') return;
            if (q == '"' and c == '\\' and self.pos + 1 < self.input.len) {
                self.advance();
                self.advance();
                continue;
            }
            if (c == q) {
                self.advance();
                return;
            }
            self.advance();
        }
    }

    fn advance(self: *Tokenizer) void {
        const c = self.input[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
    }

    fn snap(self: *const Tokenizer) Span {
        return .{
            .start = @intCast(self.pos),
            .end = @intCast(self.pos),
            .line = self.line,
            .col = self.col,
        };
    }

    fn token(self: *const Tokenizer, kind: Kind, start: Span) Token {
        return .{
            .kind = kind,
            .span = .{
                .start = start.start,
                .end = @intCast(self.pos),
                .line = start.line,
                .col = start.col,
            },
        };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn looksLikeDate(s: []const u8) bool {
    return s.len == 10 and isDigit(s[0]) and isDigit(s[1]) and isDigit(s[2]) and isDigit(s[3]) and
        s[4] == '-' and isDigit(s[5]) and isDigit(s[6]) and s[7] == '-' and isDigit(s[8]) and isDigit(s[9]);
}

fn looksLikeDateOrTime(s: []const u8) bool {
    if (s.len >= 10 and looksLikeDate(s[0..10])) return true;
    if (s.len >= 8 and isDigit(s[0]) and isDigit(s[1]) and s[2] == ':' and
        isDigit(s[3]) and isDigit(s[4]) and s[5] == ':' and
        isDigit(s[6]) and isDigit(s[7])) return true;
    return false;
}

const testing = std.testing;

test "tokenizer: simple kv" {
    const src = "title = \"hello\"\n";
    var t: Tokenizer = .init(src);
    const k0 = t.next().?;
    try testing.expectEqual(Kind.key_segment, k0.kind);
    try testing.expectEqualStrings("title", src[k0.span.start..k0.span.end]);

    const eq = t.next().?;
    try testing.expectEqual(Kind.equals, eq.kind);

    const v0 = t.next().?;
    try testing.expectEqual(Kind.value_string, v0.kind);
    try testing.expectEqualStrings("\"hello\"", src[v0.span.start..v0.span.end]);
}

test "tokenizer: header" {
    const src = "[server]\n";
    var t: Tokenizer = .init(src);
    try testing.expectEqual(Kind.header_open, t.next().?.kind);
    try testing.expectEqual(Kind.key_segment, t.next().?.kind);
    try testing.expectEqual(Kind.header_close, t.next().?.kind);
    try testing.expectEqual(Kind.eol, t.next().?.kind);
}

test "tokenizer: array of tables header" {
    const src = "[[users]]\n";
    var t: Tokenizer = .init(src);
    try testing.expectEqual(Kind.header_array_open, t.next().?.kind);
    try testing.expectEqual(Kind.key_segment, t.next().?.kind);
    try testing.expectEqual(Kind.header_close, t.next().?.kind);
}

test "tokenizer: comment line" {
    const src = "# this is a comment\n";
    var t: Tokenizer = .init(src);
    const c = t.next().?;
    try testing.expectEqual(Kind.comment, c.kind);
    try testing.expectEqualStrings("# this is a comment", src[c.span.start..c.span.end]);
}

test "tokenizer: integer + float distinguish" {
    const src = "a = 42\nb = 3.14\n";
    var t: Tokenizer = .init(src);
    _ = t.next(); // a
    _ = t.next(); // =
    try testing.expectEqual(Kind.value_integer, t.next().?.kind);
    _ = t.next(); // eol
    _ = t.next(); // b
    _ = t.next(); // =
    try testing.expectEqual(Kind.value_float, t.next().?.kind);
}

test "tokenizer: datetime" {
    const src = "ts = 1979-05-27T07:32:00Z\n";
    var t: Tokenizer = .init(src);
    _ = t.next(); // ts
    _ = t.next(); // =
    try testing.expectEqual(Kind.value_datetime, t.next().?.kind);
}
