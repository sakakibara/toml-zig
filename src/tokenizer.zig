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
//!
//! Resumable mode (`resumable = true`) lets a caller lex a growing buffer
//! without mis-reading a token that is truncated at the current buffer end.
//! When a string / comment / scalar / bare-key body runs to the end of
//! `input` mid-token, `next()` returns null with `incomplete` set instead of
//! force-terminating the token; the caller appends more bytes, refreshes
//! `input`, and calls `next()` again, which RESUMES the same token scan from
//! where it paused (never re-scanning consumed bytes, so streaming stays
//! O(N)). With `resumable = false` (the default) the tokenizer is one-shot:
//! a token running to buffer end is terminated there, as for an in-memory
//! whole-input lex.

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
    state: State = .top,
    /// When true, a token whose body runs to the end of `input` pauses
    /// (next() returns null with `incomplete` set) so the caller can extend
    /// `input` and resume the SAME token. When false the tokenizer is
    /// one-shot and terminates such a token at the buffer end.
    resumable: bool = false,
    /// Set by next() when a resumable scan paused at buffer end; cleared at
    /// the top of every next() call. Only meaningful when next() returned
    /// null: distinguishes a mid-token pause from genuine end-of-input.
    incomplete: bool = false,
    /// The in-progress token scan to resume on the next next() call, or
    /// `.none` when the tokenizer is between tokens.
    pending: Pending = .none,

    const State = enum {
        top,           // statement start
        after_eq,      // expecting a value
        in_array,      // inside `[ ... ]` array
        in_inline_tbl, // inside `{ ... }` inline table
        after_value,   // expecting `,`, `]`, `}`, or EOL
    };

    /// A paused token scan, carrying just enough state to resume mid-token
    /// after `input` grows. `string_open` is the ambiguous `"` / `""` / `"""`
    /// classification phase (needs up to 3 bytes to pick single vs multi-line).
    const Pending = union(enum) {
        none,
        string_open: StringScan,
        string_body: StringScan,
        comment: usize,
        scalar: ScalarScan,
        bare_key: usize,
    };

    const StringScan = struct {
        start: usize,
        q: u8,
        multiline: bool,
        /// The kind to emit on completion: `value_string` or `key_segment`.
        emit: Kind,
        /// State to enter after the string, or null to leave `state` as-is
        /// (quoted keys do not change state; values move to `after_value`).
        set_state: ?State,
    };

    const ScalarScan = struct { start: usize, num_start: usize };

    pub fn init(input: []const u8) Tokenizer {
        return .{ .input = input };
    }

    /// Yield the next token. Span byte offsets are u64, exact for any
    /// in-memory input. In resumable mode a mid-token buffer end yields null
    /// with `incomplete` set (see the module doc).
    pub fn next(self: *Tokenizer) ?Token {
        self.incomplete = false;

        // Resume a paused token before touching a fresh statement.
        switch (self.pending) {
            .none => {},
            .string_open => |s| return self.classifyString(s),
            .string_body => |s| return self.scanString(s),
            .comment => |start| return self.scanComment(start),
            .scalar => |s| return self.scanScalar(s.start, s.num_start),
            .bare_key => |start| return self.scanBareKey(start),
        }

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

        const start = self.mark();
        const c = self.input[self.pos];

        // Newline: always EOL.
        if (c == '\n') {
            self.advance();
            self.state = .top;
            return self.token(.eol, start);
        }
        if (c == '\r') {
            // In resumable mode a \r at the last buffered byte cannot yet see
            // whether \n follows; pause so the resume sees both bytes and emits
            // one combined EOL, matching whole-input behavior.
            if (self.resumable and self.pos + 1 >= self.input.len) {
                self.incomplete = true;
                return null;
            }
            self.advance();
            if (self.pos < self.input.len and self.input[self.pos] == '\n') self.advance();
            self.state = .top;
            return self.token(.eol, start);
        }

        // Comment.
        if (c == '#') {
            return self.scanComment(start);
        }

        return switch (self.state) {
            .top => self.tokTopOrKey(start),
            .after_eq => self.tokValue(start),
            .in_array => self.tokInArray(start),
            .in_inline_tbl => self.tokInInlineTable(start),
            .after_value => self.tokAfterValue(start),
        };
    }

    fn tokTopOrKey(self: *Tokenizer, start: usize) ?Token {
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

    fn tokKeyOrSegment(self: *Tokenizer, start: usize) ?Token {
        // Bare or quoted key.
        if (self.input[self.pos] == '"' or self.input[self.pos] == '\'') {
            return self.tokStringStart(start, .key_segment, null);
        }
        return self.scanBareKey(start);
    }

    fn scanBareKey(self: *Tokenizer, start: usize) ?Token {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            const ok = (c >= 'A' and c <= 'Z') or
                (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or
                c == '_' or c == '-';
            if (!ok) break;
            self.advance();
        }
        // A bare key that runs to buffer end may continue in the next chunk.
        if (self.pos >= self.input.len and self.resumable) {
            self.pending = .{ .bare_key = start };
            self.incomplete = true;
            return null;
        }
        self.pending = .none;
        if (self.pos == start) {
            self.advance();
            return self.token(.err, start);
        }
        return self.token(.key_segment, start);
    }

    fn tokValue(self: *Tokenizer, start: usize) ?Token {
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

    fn tokInArray(self: *Tokenizer, start: usize) ?Token {
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

    fn tokInInlineTable(self: *Tokenizer, start: usize) ?Token {
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

    fn tokAfterValue(self: *Tokenizer, start: usize) ?Token {
        // Same as top-level - expect comment, EOL, or next statement.
        self.state = .top;
        return self.tokTopOrKey(start);
    }

    fn tokScalar(self: *Tokenizer, start: usize) ?Token {
        const c = self.input[self.pos];
        if (c == '"' or c == '\'') {
            return self.tokStringStart(start, .value_string, .after_value);
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
        return self.scanScalar(start, self.pos);
    }

    /// Scan a numeric / datetime / bare value body until a terminator, then
    /// classify it. `num_start` is where the number body began (past any
    /// leading skip), preserved across a resume so the date/time heuristic
    /// still measures from the true start.
    fn scanScalar(self: *Tokenizer, start: usize, num_start: usize) ?Token {
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
        // A value that runs to buffer end may extend in the next chunk.
        if (self.pos >= self.input.len and self.resumable) {
            self.pending = .{ .scalar = .{ .start = start, .num_start = num_start } };
            self.incomplete = true;
            return null;
        }
        self.pending = .none;
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

    /// Begin a quoted string / quoted key. `pos` is at the opening quote.
    fn tokStringStart(self: *Tokenizer, start: usize, emit: Kind, set_state: ?State) ?Token {
        const s: StringScan = .{
            .start = start,
            .q = self.input[self.pos],
            .multiline = false,
            .emit = emit,
            .set_state = set_state,
        };
        return self.classifyString(s);
    }

    /// Decide single- vs multi-line and enter the body scan. `pos` is at the
    /// opening quote. Deciding needs up to three bytes (`"` / `""` / `"""`),
    /// so in resumable mode too few bytes pauses in `string_open` until the
    /// buffer grows.
    fn classifyString(self: *Tokenizer, s: StringScan) ?Token {
        const q = s.q;
        // Ambiguous only while a hidden `qq` could still turn `"` into `"""`.
        if (self.resumable and self.pos + 2 >= self.input.len and
            (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == q))
        {
            self.pending = .{ .string_open = s };
            self.incomplete = true;
            return null;
        }
        const multiline = self.pos + 2 < self.input.len and
            self.input[self.pos + 1] == q and self.input[self.pos + 2] == q;
        var body = s;
        body.multiline = multiline;
        if (multiline) {
            for (0..3) |_| self.advance();
        } else {
            self.advance();
        }
        return self.scanString(body);
    }

    /// Scan a string body from `pos` to its terminator, resuming across
    /// buffer ends in resumable mode. Handles basic-string escapes so an
    /// escaped quote never closes the string early.
    fn scanString(self: *Tokenizer, s: StringScan) ?Token {
        const q = s.q;
        if (s.multiline) {
            while (self.pos + 2 < self.input.len) {
                if (q == '"' and self.input[self.pos] == '\\') {
                    self.advance();
                    self.advance();
                    continue;
                }
                if (self.input[self.pos] == q and
                    self.input[self.pos + 1] == q and
                    self.input[self.pos + 2] == q)
                {
                    for (0..3) |_| self.advance();
                    return self.finishString(s);
                }
                self.advance();
            }
            // Fewer than three bytes remain: a closing `"""` could straddle
            // the buffer end, so pause rather than guess.
            if (self.resumable) {
                self.pending = .{ .string_body = s };
                self.incomplete = true;
                return null;
            }
            while (self.pos < self.input.len) self.advance();
            return self.finishString(s);
        }

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\n') return self.finishString(s);
            if (q == '"' and c == '\\') {
                // An escape needs its escaped byte; if it is past the buffer
                // end, pause at the backslash so the resume re-reads it.
                if (self.pos + 1 >= self.input.len) break;
                self.advance();
                self.advance();
                continue;
            }
            if (c == q) {
                self.advance();
                return self.finishString(s);
            }
            self.advance();
        }
        if (self.resumable) {
            self.pending = .{ .string_body = s };
            self.incomplete = true;
            return null;
        }
        // Finalize an unterminated single-line string (consume a trailing
        // lone backslash, matching the whole-input lex).
        while (self.pos < self.input.len) self.advance();
        return self.finishString(s);
    }

    fn finishString(self: *Tokenizer, s: StringScan) Token {
        self.pending = .none;
        if (s.set_state) |st| self.state = st;
        return self.token(s.emit, s.start);
    }

    /// Scan a `# ...` comment to end-of-line. In resumable mode a comment that
    /// runs to buffer end pauses so its tail is not re-lexed as statements.
    fn scanComment(self: *Tokenizer, start: usize) ?Token {
        while (self.pos < self.input.len and self.input[self.pos] != '\n') self.advance();
        if (self.pos >= self.input.len and self.resumable) {
            self.pending = .{ .comment = start };
            self.incomplete = true;
            return null;
        }
        self.pending = .none;
        return self.token(.comment, start);
    }

    fn advance(self: *Tokenizer) void {
        self.pos += 1;
    }

    fn mark(self: *const Tokenizer) usize {
        return self.pos;
    }

    fn token(self: *const Tokenizer, kind: Kind, start: usize) Token {
        return .{
            .kind = kind,
            .span = .{ .start = start, .end = self.pos },
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

test "tokenizer: Token.span carries exact u64 byte offsets" {
    const src = "title = \"hello\"\n";
    var t: Tokenizer = .init(src);
    const k0 = t.next().?;
    try testing.expectEqual(Span, @TypeOf(k0.span));
    try testing.expectEqual(u64, @TypeOf(k0.span.start));
    try testing.expectEqual(@as(u64, 0), k0.span.start);
    try testing.expectEqual(@as(u64, 5), k0.span.end);
    // Line/col are derived on demand from the source, not stored.
    try testing.expectEqual(@as(u32, 1), k0.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 1), k0.span.lineCol(src).col);
}

test "tokenizer: span offsets stay byte-precise across lines" {
    const src = "[a.b]\nk = [1, 2]\n";
    var t: Tokenizer = .init(src);
    while (t.next()) |tok| {
        try testing.expect(tok.span.end >= tok.span.start);
        try testing.expect(tok.span.end <= src.len);
    }
}

test "tokenizer: resumable lex of a growing buffer matches whole-input lex" {
    // Feed the input one byte at a time in resumable mode; the token stream
    // (kind + span) must be identical to a single whole-input lex. Covers
    // multi-line strings, single-line strings with interior brackets and
    // escaped quotes, comments, scalars, and headers.
    const src =
        "key = \"\"\"line1\n[not a header]\nk = v\nline\\\"end\"\"\"\n" ++
        "s = \"a [b] \\\" c\"  # trailing [x] comment\n" ++
        "n = 1979-05-27T07:32:00Z\n" ++
        "[real]\nx = 42\n";

    // Oracle: whole-input, non-resumable.
    var whole: Tokenizer = .init(src);
    var want: std.ArrayList(Token) = .empty;
    defer want.deinit(testing.allocator);
    while (whole.next()) |tok| try want.append(testing.allocator, tok);

    // Resumable, one byte revealed per step.
    var t: Tokenizer = .{ .input = src[0..0], .resumable = true };
    var got: std.ArrayList(Token) = .empty;
    defer got.deinit(testing.allocator);
    var revealed: usize = 0;
    while (true) {
        if (t.next()) |tok| {
            try got.append(testing.allocator, tok);
            continue;
        }
        if (t.incomplete) {
            if (revealed < src.len) {
                revealed += 1;
                t.input = src[0..revealed];
                continue;
            }
            // No more bytes will arrive: finalize the paused token.
            t.resumable = false;
            continue;
        }
        if (revealed < src.len) {
            revealed += 1;
            t.input = src[0..revealed];
            continue;
        }
        break;
    }

    try testing.expectEqual(want.items.len, got.items.len);
    for (want.items, got.items) |w, g| {
        try testing.expectEqual(w.kind, g.kind);
        try testing.expectEqual(w.span.start, g.span.start);
        try testing.expectEqual(w.span.end, g.span.end);
    }
}

test "tokenizer: resumable CRLF at buffer boundary emits one EOL matching whole-input" {
    // Sweeps every split offset by revealing one byte at a time (implicit
    // sweep over k = 0..src.len). Covers: \r\n mid-stream, multiple \r\n
    // pairs, \r\n inside a multiline string, lone \r at EOF, \r\n at start.
    const cases = [_][]const u8{
        "a = 1\r\nb = 2\r\n",
        "a = 1\r\nb = 2\r\n\r\nc = 3\r\n",
        "[x]\r\nk = \"v\"\r\n",
        "ml = \"\"\"\r\nline1\r\nline2\r\n\"\"\"\r\n[after]\r\nk = 1\r\n",
        "a = 1\r",          // lone \r at EOF
        "\r\na = 1\r\n",    // \r\n at start
    };
    for (cases) |src| {
        // Oracle: whole-input, non-resumable.
        var whole: Tokenizer = .init(src);
        var want: std.ArrayList(Token) = .empty;
        defer want.deinit(testing.allocator);
        while (whole.next()) |tok| try want.append(testing.allocator, tok);

        // Resumable, one byte revealed per step (sweeps all split offsets).
        var t: Tokenizer = .{ .input = src[0..0], .resumable = true };
        var got: std.ArrayList(Token) = .empty;
        defer got.deinit(testing.allocator);
        var revealed: usize = 0;
        while (true) {
            if (t.next()) |tok| {
                try got.append(testing.allocator, tok);
                continue;
            }
            if (t.incomplete) {
                if (revealed < src.len) {
                    revealed += 1;
                    t.input = src[0..revealed];
                    continue;
                }
                t.resumable = false;
                continue;
            }
            if (revealed < src.len) {
                revealed += 1;
                t.input = src[0..revealed];
                continue;
            }
            break;
        }

        testing.expectEqual(want.items.len, got.items.len) catch |e| {
            std.debug.print("CRLF token-count mismatch on: {s}\n", .{src});
            return e;
        };
        for (want.items, got.items) |w, g| {
            testing.expectEqual(w.kind, g.kind) catch |e| {
                std.debug.print("CRLF kind mismatch on: {s}\n", .{src});
                return e;
            };
            testing.expectEqual(w.span.start, g.span.start) catch |e| {
                std.debug.print("CRLF span.start mismatch on: {s}\n", .{src});
                return e;
            };
            testing.expectEqual(w.span.end, g.span.end) catch |e| {
                std.debug.print("CRLF span.end mismatch on: {s}\n", .{src});
                return e;
            };
        }
    }
}
