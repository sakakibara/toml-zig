//! TOML 1.1 parser  -  single-pass recursive descent, arena-allocated.
//!
//! Entry point: `parse(arena, input, options) -> Value` (always returns a table).
//! On error: returns `error.TomlParseError`. Set `options.errors` to a
//! `*std.ArrayList(Diagnostic)` to recover line/col/message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.array_hash_map.String;
const StringHashMap = std.StringHashMapUnmanaged;

const v = @import("value.zig");
const dt = @import("datetime.zig");
const lev = @import("levenshtein.zig");

pub const Value = v.Value;
pub const Date = v.Date;
pub const Time = v.Time;
pub const DateTime = v.DateTime;
pub const Span = v.Span;

pub const Diagnostic = struct {
    /// Arena-allocated. Lifetime: the parse arena.
    message: []const u8,
    /// Byte range of the offending token within the original source. A
    /// zero-width span (`start == end`) marks a locationless error (e.g. a
    /// decode type mismatch with no underlying token); line/col then resolve
    /// to the start of `src` and no source excerpt is rendered. Line and
    /// column are derived on demand via `Span.lineCol(src)`.
    span: Span = .{ .start = 0, .end = 0 },
    /// Path context for decode errors (e.g., "users[2].name"). Empty
    /// for parser-side errors.
    path: ?[]const u8 = null,
    /// "Did you mean X?" suggestion. Set when a typo'd key or value
    /// is rejected. Arena-allocated.
    suggestion: ?[]const u8 = null,
    /// Secondary annotations (e.g., "previously declared here").
    notes: []const Note = &.{},

    pub const Note = struct {
        span: Span,
        message: []const u8,
    };

    /// Single-line summary. Line/col are computed from `span` against `src`
    /// (the same slice passed to `parse`).
    pub fn format(self: Diagnostic, writer: *std.Io.Writer, src: []const u8) !void {
        const lc = self.span.lineCol(src);
        try writer.print("TOML parse error at {d}:{d}: {s}", .{ lc.line, lc.col, self.message });
    }

    /// Multi-line rich form. Emits a rustc-style block: header,
    /// source-line with caret underline, notes, suggestion.
    /// Caller provides the original source bytes (the same slice passed
    /// to `parse`). ASCII only -- no terminal color escapes.
    pub fn formatRich(self: Diagnostic, w: *std.Io.Writer, source: []const u8) !void {
        const lc = self.span.lineCol(source);
        try w.print("error at {d}:{d}: {s}\n", .{ lc.line, lc.col, self.message });
        if (self.path) |p| try w.print("  at {s}\n", .{p});

        // Source excerpt, only for a real (non-zero-width) span whose line
        // falls within the source bounds.
        if (self.span.end > self.span.start) blk: {
            var line_start: usize = 0;
            var lineno: u32 = 1;
            var i: usize = 0;
            while (i < source.len and lineno < lc.line) : (i += 1) {
                if (source[i] == '\n') {
                    lineno += 1;
                    line_start = i + 1;
                }
            }
            if (lineno != lc.line) break :blk;
            var line_end = line_start;
            while (line_end < source.len and source[line_end] != '\n') line_end += 1;

            const line_text = source[line_start..line_end];
            try w.print("  |\n{d:>3} | {s}\n  | ", .{ lc.line, line_text });

            // col is 1-indexed; subtract 1 for the zero-based offset into the line.
            const col0: usize = if (lc.col > 0) lc.col - 1 else 0;
            const carets: usize = @intCast(self.span.end - self.span.start);
            var c: usize = 0;
            while (c < col0) : (c += 1) try w.writeByte(' ');
            var k: usize = 0;
            while (k < carets) : (k += 1) try w.writeByte('^');
            try w.writeByte('\n');
        }

        for (self.notes) |n| {
            const nlc = n.span.lineCol(source);
            try w.print("  = note: at {d}:{d}: {s}\n", .{ nlc.line, nlc.col, n.message });
        }

        if (self.suggestion) |s| {
            try w.print("  = help: did you mean `{s}`?\n", .{s});
        }
    }
};

pub const Error = error{
    TomlParseError,
    NestingTooDeep,
    OutOfMemory,
};

/// All knobs for parse / parseReader / parseInto / parseIntoReader.
/// Default `.{}` is the no-knob common case. Defined here; re-exported
/// by `toml.zig` as `toml.ParseOptions` (which is the canonical name
/// callers should use).
pub const ParseOptions = struct {
    /// When non-null, parser appends each error and continues (recover-and-
    /// skip-to-next-newline). Returns `error.TomlParseError` if any errors
    /// were collected. When null, parser bails on the first error with no
    /// error info captured.
    errors: ?*std.ArrayList(Diagnostic) = null,

    /// If non-null, populated with one Span per emitted Value, keyed by
    /// dotted path. Array elements use `[N]` index segments. Spans store
    /// u64 byte offsets, so any in-memory buffer can be recorded.
    spans: ?*v.Spans = null,

    /// Decode-only. When true, TOML keys absent from the target struct
    /// are silently dropped instead of triggering `error.UnknownField`.
    /// Honored by parseInto / parseIntoReader / decode. Ignored by
    /// dynamic parse / parseReader.
    ignore_unknown_fields: bool = false,

    /// Maximum array / inline-table nesting depth. Exceeding it returns
    /// `error.NestingTooDeep`. The default 128 is safe on any supported
    /// stack size. Raising it trades stack space for depth: each
    /// additional level costs roughly 1-1.5 KB of stack, so values in
    /// the thousands can exhaust the stack before this guard fires.
    max_depth: usize = 128,
};

const MAX_RECOVERY_ERRORS: usize = 100;

/// Skip ASCII bytes in `bytes` that are unambiguously safe to include in
/// a basic string (i.e., not `"`, `\`, control char, DEL, or non-ASCII).
/// Returns the number of bytes skipped. The caller handles the byte at
/// the returned offset (or hits EOF).
fn scanBasicStringFast(bytes: []const u8) usize {
    const W = 16;
    var i: usize = 0;
    const quote: @Vector(W, u8) = @splat('"');
    const backslash: @Vector(W, u8) = @splat('\\');
    const ctrl_max: @Vector(W, u8) = @splat(0x1f);
    const tab: @Vector(W, u8) = @splat('\t');
    const del: @Vector(W, u8) = @splat(0x7f);
    const high: @Vector(W, u8) = @splat(0x80);
    while (i + W <= bytes.len) {
        const chunk: @Vector(W, u8) = bytes[i..][0..W].*;
        const stop =
            (chunk == quote) |
            (chunk == backslash) |
            (chunk == del) |
            (chunk >= high) |
            ((chunk <= ctrl_max) & (chunk != tab));
        const mask: u16 = @bitCast(stop);
        if (mask != 0) return i + @ctz(mask);
        i += W;
    }
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '"' or c == '\\' or c == 0x7f or c >= 0x80 or
            (c <= 0x1f and c != '\t')) return i;
        i += 1;
    }
    return i;
}

/// Fast path for the common case: decimal integer, no underscores, no
/// sign, no leading zero (unless the value is exactly "0"), fits in
/// i64. Returns null otherwise; caller falls back to the full parser.
fn parseDecFast(s: []const u8) ?i64 {
    if (s.len == 0 or s.len > 19) return null;
    // TOML rejects leading zeros (except for "0" itself).
    if (s.len > 1 and s[0] == '0') return null;
    var result: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit: i64 = @intCast(c - '0');
        const product = @mulWithOverflow(result, 10);
        if (product[1] != 0) return null;
        const sum = @addWithOverflow(product[0], digit);
        if (sum[1] != 0) return null;
        result = sum[0];
    }
    return result;
}

/// Options-aware parse. See `toml.ParseOptions`.
pub fn parse(arena: Allocator, input: []const u8, options: ParseOptions) Error!Value {
    var root: StringArrayHashMap(Value) = .empty;
    var seen: SeenState = .empty;
    var p = Parser.init(arena, input);
    p.root = &root;
    p.seen = &seen;
    p.spans = options.spans;
    p.errors = options.errors;
    p.max_depth = options.max_depth;
    return p.parseDocument();
}

/// Decode a TOML key (bare, basic-quoted, literal-quoted, or dotted) into
/// its canonical decoded form: each segment decoded the same way the value
/// tree decodes keys, joined by '.'. This is the identity used by
/// `Value.get`, so the document model uses it to index editable kv lines
/// under the same key `get` resolves. `raw` must be exactly the key bytes
/// (no surrounding `=` or value). Returns InvalidValue on a malformed key.
pub fn decodeKeyPath(arena: Allocator, raw: []const u8) Error![]const u8 {
    var p = Parser.init(arena, raw);
    var parts: ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    p.parseKeyPath(&parts) catch return error.TomlParseError;
    p.skipWs();
    if (!p.eof()) return error.TomlParseError;
    if (parts.items.len == 0) return error.TomlParseError;

    var out: ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(arena, '.');
        try out.appendSlice(arena, part);
    }
    return out.items;
}

/// Whole-file duplicate-detection bookkeeping, holding only PATH NAMES
/// (void-valued sets), never values. Shared across statement-units so
/// cross-unit uniqueness survives even when each unit's VALUES are
/// discarded: the streaming reader parses one `[table]` / `[[x]]` unit
/// against an existing root + an existing `SeenState`, keeping the
/// reject decisions byte-identical to a whole-file buffered parse.
///
/// Bounded by distinct-key-count x name-length, independent of value
/// size  -  the same bookkeeping the buffered parser already carries.
pub const SeenState = struct {
    /// Tables that were explicitly defined via `[header]`  -  redefining
    /// one is an error. Header-defined tables cannot be extended via
    /// dotted-key from a different `[header]` scope.
    defined_tables: StringHashMap(void) = .empty,
    /// Tables that were created as implicit intermediates of an
    /// `[a.b.c]` header (only). These can still be promoted to
    /// defined by a later `[a.b]` header. Populated only in parseHeader.
    implicit_tables: StringHashMap(void) = .empty,
    /// Keys that are inline-defined (value of `key = {...}` or nested
    /// within an inline table literal). Any such key and its sub-paths
    /// are permanently sealed  -  no header may re-open them, no dotted-key
    /// may extend them.
    inline_tables: StringHashMap(void) = .empty,
    /// Full paths of tables that were created as intermediates by a
    /// dotted-key kv descent (in ANY header's scope, cumulative).
    /// A later `[p.q]` header must reject if `p.q` is in this set.
    dotted_created: StringHashMap(void) = .empty,
    /// Full paths of tables kv-dotted-created within the CURRENT header
    /// scope. Cleared on each header. Used to allow same-header dotted
    /// extension while rejecting cross-header extension.
    dotted_current: StringHashMap(void) = .empty,
    /// Names of arrays-of-tables (tracked so we know to append).
    array_tables: StringHashMap(void) = .empty,
    /// Current element COUNT of each array-of-tables, keyed by its index-free
    /// path. Incremented once per `[[path]]`. The current (last) element's
    /// index is `count - 1`. Lets a verdict site reconstruct the
    /// element-qualified leaf path (`path[count-1].rest`) for `scalar_leaves`
    /// even in the streaming reader, where the live tree holds only the
    /// current unit's element and the cumulative length is otherwise lost.
    aot_lengths: StringHashMap(usize) = .empty,
    /// Full paths of NON-TABLE kv leaves: scalars and static (non-aot)
    /// arrays. A header / `[[aot]]` / dotted-key that tries to traverse
    /// through or redefine one of these is a type conflict. The buffered
    /// parser catches this by tree-walking the value tree, but the
    /// streaming reader discards each unit's value tree, so the leaf's
    /// slot is gone by the time a later unit references the path. This set
    /// makes the conflict catchable without the tree, exactly like the
    /// other duplicate-detection sets. Inline tables are NOT recorded here
    /// (they live in `inline_tables`); only scalars and static arrays.
    /// The value records the leaf KIND so the error message matches the
    /// buffered tree-walk exactly (an intermediate-traversal conflict
    /// reports a static array differently from a scalar).
    scalar_leaves: StringHashMap(LeafKind) = .empty,

    /// Kind of a non-table kv leaf, used to reproduce the buffered
    /// tree-walk's per-kind error message when the value tree is absent.
    pub const LeafKind = enum { scalar, static_array };

    pub const empty: SeenState = .{};

    /// Entering a new `[header]` / `[[header]]` invalidates the
    /// "dotted-created in the current header" scope  -  headers never
    /// share dotted-created tables. Called at the top of header parsing.
    pub fn clearHeaderScope(self: *SeenState) void {
        self.dotted_current.clearRetainingCapacity();
    }
};

pub const ReaderError = Error || std.Io.Reader.LimitedAllocError;

/// Reader-input variant. Pulls the full input into arena memory first,
/// then runs `parse` over it. TOML's grammar requires the whole document
/// to be available before the value tree is complete.
pub fn parseReader(arena: Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!Value {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parse(arena, input, options);
}

/// Result of `streamParseUnit`: where the parsed unit's key-values landed.
/// `leaf` points at the table the unit's statements wrote into (the root
/// for a leading top-level-kv unit, or the table a `[header]` navigated
/// to). `header_path` is the decoded dotted header path that selected
/// `leaf` (empty for a leading-kv unit), e.g. `a.b` or `a.b[0]` for an
/// array-of-tables element. `is_array_element` is true when the unit's
/// header was `[[...]]`. All slices/pointers borrow the shared root and
/// the value arena passed in.
pub const UnitParse = struct {
    leaf: *StringArrayHashMap(Value),
    header_path: []const u8,
    is_array_element: bool,
};

/// Streaming seam: parse ONE statement-unit's bytes against a shared root +
/// shared `SeenState`, returning where its key-values landed. The streaming
/// reader frames units (a `[table]` / `[[x]]` header plus its key-values, or
/// the leading top-level kvs) and calls this per unit.
///
/// `value_arena` owns the unit's VALUES (the streaming reader resets it after
/// the unit's events are emitted). `seen_arena` owns `seen`'s path NAMES and
/// must outlive every unit so duplicate detection spans the whole stream.
/// `root` and `seen` are shared across all units. `options.spans`/`.errors`
/// are honored as in `parse`.
pub fn streamParseUnit(
    value_arena: Allocator,
    seen_arena: Allocator,
    input: []const u8,
    root: *StringArrayHashMap(Value),
    seen: *SeenState,
    options: ParseOptions,
) Error!UnitParse {
    var p = Parser.initUnit(value_arena, seen_arena, input, root, seen);
    p.spans = options.spans;
    p.errors = options.errors;
    p.max_depth = options.max_depth;
    try p.parseStatements();
    return .{
        .leaf = p.current,
        .header_path = p.last_header_path.items,
        .is_array_element = p.last_header_was_array,
    };
}

const Parser = struct {
    arena: Allocator,
    input: []const u8,
    pos: usize = 0,
    /// Byte position of the current token attempt's start. Captured at the
    /// top of parse* helpers that may error; used to populate the offending
    /// span on a Diagnostic. Line/col are not tracked during scanning -- they
    /// are derived from the span at render time (see `Span.lineCol`).
    token_start: usize = 0,

    /// Top-level (root) table. Injected: the buffered path points it at a
    /// fresh local map; the streaming path points it at the accumulating
    /// shared root so units land in the same tree.
    root: *StringArrayHashMap(Value) = undefined,

    /// Where the next `key = value` pair lands. Changes on
    /// `[header]` / `[[array-of-tables]]`.
    current: *StringArrayHashMap(Value) = undefined,
    /// Dotted path prefix that identifies `current` (empty at root).
    /// Used to build full keys during kv dotted-descent.
    current_prefix: ArrayList(u8) = .empty,

    /// Decoded dotted header path of the most recent `[header]` /
    /// `[[header]]` (without the synthetic `[N]` array index), or empty
    /// when no header has been seen (a leading top-level-kv unit). Read by
    /// the streaming seam (`streamParseUnit`) to label `table_header` /
    /// `array_of_tables_header` events. Borrows the value arena.
    last_header_path: ArrayList(u8) = .empty,
    /// Whether the most recent header was `[[...]]` (array-of-tables).
    last_header_was_array: bool = false,

    /// Whole-file duplicate-detection sets. Injected: the buffered path
    /// points it at a fresh local `SeenState`; the streaming path points
    /// it at one shared across units so redefinition rejection spans the
    /// whole stream.
    seen: *SeenState = undefined,

    /// Arena owning `seen`'s key bytes. In the buffered path this is the
    /// same arena as `arena` (the whole document outlives one parse). In
    /// the streaming path it is the STREAM-lifetime arena, distinct from
    /// the per-unit `arena`: a unit's values are discarded and its arena
    /// reset after each frame, but `seen`'s path NAMES must survive for the
    /// whole stream so cross-unit duplicate detection holds. Defaults to
    /// `arena` so non-streaming callers see no behavior change.
    seen_arena: Allocator = undefined,

    /// Current array / inline-table nesting depth. Incremented on
    /// entering `parseArray` / `parseInlineTable`; exceeding `max_depth`
    /// bails with `error.NestingTooDeep` before recursing further, which
    /// bounds stack growth on hostile deeply-nested input.
    depth: usize = 0,
    /// Nesting-depth ceiling. Set from `ParseOptions.max_depth` in `parse`.
    max_depth: usize = 128,

    /// Multi-error sink. When set, each error append + recover; when null,
    /// first error bails. Set from ParseOptions.errors in `parse` / `parseReader`.
    errors: ?*std.ArrayList(Diagnostic) = null,

    /// When non-null, populated with one entry per emitted value
    /// (path -> source span). Set via `ParseOptions.spans`.
    spans: ?*v.Spans = null,
    /// Mutable buffer holding the current value's full dotted path while
    /// inside `parseValue`. Composite parsers (`parseArray`,
    /// `parseInlineTable`) push child segments before recursing and
    /// restore the buffer length on exit. Only meaningful when
    /// `spans != null`.
    current_path: ArrayList(u8) = .empty,

    /// Bare init. Leaves `root` / `seen` undefined; the caller must either
    /// drive `parseDocument` (which wires fresh local storage) or only use
    /// helpers that don't touch the value tree (e.g. `parseKeyPath`).
    fn init(arena: Allocator, input: []const u8) Parser {
        return .{ .arena = arena, .input = input, .seen_arena = arena };
    }

    /// Per-unit init: parse one statement-unit's bytes against an EXISTING
    /// shared root + EXISTING shared `SeenState`. `current` / `current_prefix`
    /// start at the root; a leading `[header]` in the unit re-navigates them
    /// before its key-values land. This is the seam the streaming reader
    /// uses to parse table-by-table while preserving cross-unit duplicate
    /// detection.
    ///
    /// `arena` owns this unit's VALUES (reset/discarded after the unit's
    /// events are emitted). `seen_arena` owns `seen`'s path-NAME keys and
    /// must outlive every unit (the stream-lifetime arena) so duplicate
    /// detection survives the per-unit reset. Pass the same allocator for
    /// both to get the non-streaming behavior (statement-by-statement over
    /// one arena, as the equivalence tests do).
    fn initUnit(
        arena: Allocator,
        seen_arena: Allocator,
        input: []const u8,
        root: *StringArrayHashMap(Value),
        seen: *SeenState,
    ) Parser {
        return .{
            .arena = arena,
            .seen_arena = seen_arena,
            .input = input,
            .root = root,
            .seen = seen,
            .current = root,
        };
    }

    /// The offending span for a diagnostic: `[token_start, pos]` as u64 byte
    /// offsets. Line/col are derived from it at render time.
    fn diagSpan(self: *const Parser) Span {
        return .{ .start = self.token_start, .end = self.pos };
    }

    /// Append a child path segment, returning the previous length so the
    /// caller can restore via `popPath`. Cheap when spans are off.
    fn pushPath(self: *Parser, separator: u8, segment: []const u8) Error!usize {
        if (self.spans == null) return 0;
        const prev_len = self.current_path.items.len;
        if (prev_len > 0 and separator != 0) try self.current_path.append(self.arena, separator);
        try self.current_path.appendSlice(self.arena, segment);
        return prev_len;
    }

    /// Append `[N]` index segment.
    fn pushIndex(self: *Parser, idx: usize) Error!usize {
        if (self.spans == null) return 0;
        const prev_len = self.current_path.items.len;
        try self.current_path.print(self.arena, "[{d}]", .{idx});
        return prev_len;
    }

    fn popPath(self: *Parser, prev_len: usize) void {
        if (self.spans == null) return;
        self.current_path.shrinkRetainingCapacity(prev_len);
    }

    fn parseDocument(self: *Parser) Error!Value {
        self.current = self.root;
        try self.parseStatements();
        return Value{ .table = self.root.* };
    }

    /// Parse every statement in `input` against the injected shared root +
    /// `SeenState`, leaving `current` wherever the last header pointed it.
    /// Used by the streaming reader to feed one statement-unit's bytes
    /// (constructed via `initUnit`). Runs the identical statement loop as
    /// `parseDocument`, but does NOT own the value tree  -  the shared root
    /// is the result and persists across units. Recovery semantics match
    /// the buffered path.
    fn parseStatements(self: *Parser) Error!void {
        var had_error = false;

        while (true) {
            try self.skipWsAndComments();
            if (self.eof()) break;

            const c = self.peek();
            const stmt_result: Error!void = if (c == '[')
                self.parseHeader()
            else
                self.parseKeyValue(self.current);

            if (stmt_result) |_| {
                try self.expectEol();
            } else |err| {
                if (err != error.TomlParseError) return err;
                had_error = true;
                if (self.errors == null) return err;
                if (self.errors.?.items.len >= MAX_RECOVERY_ERRORS) return err;
                self.recoverToNextStatement();
                continue;
            }
        }

        if (had_error) return error.TomlParseError;
    }

    // ----- location / lookahead primitives -----

    inline fn eof(self: *Parser) bool {
        return self.pos >= self.input.len;
    }

    inline fn peek(self: *Parser) u8 {
        return self.input[self.pos];
    }

    inline fn peekAt(self: *Parser, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.input.len) return null;
        return self.input[idx];
    }

    inline fn advance(self: *Parser) void {
        self.pos += 1;
    }

    inline fn match(self: *Parser, c: u8) bool {
        if (self.eof() or self.peek() != c) return false;
        self.advance();
        return true;
    }

    fn matchStr(self: *Parser, s: []const u8) bool {
        if (self.pos + s.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + s.len], s)) return false;
        var i: usize = 0;
        while (i < s.len) : (i += 1) self.advance();
        return true;
    }

    fn skipWs(self: *Parser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t') self.advance() else return;
        }
    }

    /// Skip to the end of the current line and consume the newline.
    /// Used for error recovery: after a statement-level parse failure,
    /// advance past the bad line so the outer loop can attempt the next one.
    fn recoverToNextStatement(self: *Parser) void {
        while (!self.eof() and self.peek() != '\n') self.advance();
        if (!self.eof()) self.advance(); // consume the newline
    }

    /// Skip whitespace, comments, and newlines. Used at statement
    /// boundaries. Returns an error on malformed comments or bare CR.
    fn skipWsAndComments(self: *Parser) Error!void {
        while (!self.eof()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t' => self.advance(),
                '\n' => self.advance(),
                '\r' => {
                    // A lone CR (not part of CRLF) is invalid.
                    if (self.peekAt(1) != '\n') {
                        return self.setError("bare CR is invalid");
                    }
                    self.advance();
                },
                '#' => {
                    try self.consumeComment();
                },
                else => return,
            }
        }
    }

    /// Consume a `#`-prefixed comment up to (but not including) the
    /// terminating newline. Returns an error if the comment contains
    /// disallowed control characters or invalid UTF-8.
    fn consumeComment(self: *Parser) Error!void {
        _ = self.match('#');
        while (!self.eof() and self.peek() != '\n') {
            const k = self.peek();
            if (k == '\r') {
                if (self.peekAt(1) == '\n') return; // CRLF ends comment.
                return self.setError("bare CR in comment");
            }
            if (k < 0x20 and k != 0x09) {
                return self.setError("control character in comment");
            }
            if (k == 0x7F) {
                return self.setError("DEL control character in comment");
            }
            if (k >= 0x80) {
                // Validate UTF-8 multi-byte sequence.
                try self.validateUtf8();
                continue;
            }
            self.advance();
        }
    }

    /// Validate that the current position is the start of a valid UTF-8
    /// multi-byte sequence and advance past it. Rejects overlong
    /// encodings and surrogate code points.
    fn validateUtf8(self: *Parser) Error!void {
        const b0 = self.peek();
        const seq_len: usize = if (b0 < 0x80) 1 else if (b0 < 0xC2) 0 // 0x80..0xC1: invalid continuation or overlong
            else if (b0 < 0xE0) 2 else if (b0 < 0xF0) 3 else if (b0 < 0xF5) 4 else 0;
        if (seq_len == 0) return self.setError("invalid UTF-8 byte");
        if (self.pos + seq_len > self.input.len) return self.setError("truncated UTF-8 sequence");
        const bytes = self.input[self.pos .. self.pos + seq_len];
        const cp = std.unicode.utf8Decode(bytes) catch return self.setError("invalid UTF-8 sequence");
        // Surrogates (encoded as 3 bytes) are rejected by utf8Decode,
        // but double-check code point range.
        if (cp > 0x10FFFF) return self.setError("code point out of range");
        var i: usize = 0;
        while (i < seq_len) : (i += 1) self.advance();
    }

    /// Expect end-of-line (newline or EOF), possibly preceded by whitespace
    /// and a comment.
    fn expectEol(self: *Parser) Error!void {
        self.skipWs();
        if (self.eof()) return;
        if (self.peek() == '#') {
            try self.consumeComment();
        }
        if (self.eof()) return;
        if (self.peek() == '\n') {
            self.advance();
            return;
        }
        if (self.peek() == '\r') {
            if (self.peekAt(1) != '\n') return self.setError("bare CR");
            self.advance();
            self.advance();
            return;
        }
        return self.setError("expected newline");
    }

    fn setError(self: *Parser, comptime msg: []const u8) Error {
        if (self.errors) |list| {
            const owned_msg = self.arena.dupe(u8, msg) catch return error.OutOfMemory;
            list.append(self.arena, .{
                .message = owned_msg,
                .span = self.diagSpan(),
            }) catch return error.OutOfMemory;
        }
        return error.TomlParseError;
    }

    /// Depth-guard failure: records a diagnostic but returns the distinct
    /// `error.NestingTooDeep`, which the document recovery loop never swallows.
    fn setDepthError(self: *Parser) Error {
        if (self.errors) |list| {
            const msg = std.fmt.allocPrint(self.arena, "nesting depth exceeds limit ({d})", .{self.max_depth}) catch return error.OutOfMemory;
            list.append(self.arena, .{
                .message = msg,
                .span = self.diagSpan(),
            }) catch return error.OutOfMemory;
        }
        return error.NestingTooDeep;
    }

    fn setErrorFmt(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        if (self.errors) |list| {
            const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
            list.append(self.arena, .{
                .message = msg,
                .span = self.diagSpan(),
            }) catch return error.OutOfMemory;
        }
        return error.TomlParseError;
    }

    fn setErrorWithSuggestion(self: *Parser, msg: []const u8, suggestion: ?[]const u8) Error {
        if (self.errors) |list| {
            const owned_msg = self.arena.dupe(u8, msg) catch return error.OutOfMemory;
            const owned_sug = if (suggestion) |s| self.arena.dupe(u8, s) catch return error.OutOfMemory else null;
            list.append(self.arena, .{
                .message = owned_msg,
                .span = self.diagSpan(),
                .suggestion = owned_sug,
            }) catch return error.OutOfMemory;
        }
        return error.TomlParseError;
    }

    // ----- header / array-of-tables parsing -----

    fn parseHeader(self: *Parser) Error!void {
        // Already saw `[`
        _ = self.match('[');
        const is_array = self.match('[');

        self.skipWs();
        self.token_start = self.pos;
        var key_parts: ArrayList([]const u8) = .empty;
        defer key_parts.deinit(self.arena);

        try self.parseKeyPath(&key_parts);
        self.skipWs();

        if (is_array) {
            if (!self.match(']')) return self.setError("expected ']]'");
            if (!self.match(']')) return self.setError("expected ']]'");
        } else {
            if (!self.match(']')) return self.setError("expected ']'");
        }

        // Entering a new header invalidates the "dotted in current header"
        // scope  -  headers never share dotted-created tables.
        self.seen.clearHeaderScope();

        // Navigate / create intermediate tables.
        var table = self.root;
        var full_key: ArrayList(u8) = .empty;
        defer full_key.deinit(self.arena);

        // Same path as `full_key` but with each traversed array-of-tables
        // segment resolved to its CURRENT element index (`name[N]`), matching
        // the `current_prefix` convention `parseKeyValue` uses to key
        // `scalar_leaves`. Non-table leaves live inside a specific AOT element,
        // so this is the path that lets the verdict reject a same-element
        // conflict while letting a later element's `[w.a]` (which targets a
        // fresh element with no such leaf) through. Used ONLY for
        // `scalar_leaves` lookups; the other seen-sets stay index-free.
        var indexed_key: ArrayList(u8) = .empty;
        defer indexed_key.deinit(self.arena);

        for (key_parts.items, 0..) |part, i| {
            if (i > 0) try full_key.append(self.arena, '.');
            try full_key.appendSlice(self.arena, part);

            if (indexed_key.items.len > 0) try indexed_key.append(self.arena, '.');
            try indexed_key.appendSlice(self.arena, part);

            const last = i == key_parts.items.len - 1;
            // Duped into the seen-arena: it is stored into seen-sets
            // (implicit/defined/array) and used as their lookup key, so it
            // must outlive the per-unit value arena in the streaming path.
            const key_owned = try self.seen_arena.dupe(u8, full_key.items);

            // Inline-defined paths are sealed  -  never re-openable via
            // `[header]` (even for intermediates, you can't traverse
            // into an inline table's sub-structure).
            if (self.seen.inline_tables.contains(key_owned)) {
                return self.setErrorFmt("cannot extend inline table '{s}'", .{full_key.items});
            }
            // Dotted-key-created paths only block direct RE-DEFINITION
            // by a header with the exact same path. Deeper sub-tables
            // (`[a.b.seeds]` after `a.b.x = ...`) are allowed.
            if (last and self.seen.dotted_created.contains(key_owned)) {
                return self.setErrorFmt("cannot redefine dotted-key-created table '{s}'", .{full_key.items});
            }

            if (last) {
                // Record the clean (index-free) header path + shape for the
                // streaming seam before appending the synthetic `[N]`.
                self.last_header_path.clearRetainingCapacity();
                try self.last_header_path.appendSlice(self.arena, full_key.items);
                self.last_header_was_array = is_array;
                if (is_array) {
                    try self.openArrayOfTables(table, part, key_owned, indexed_key.items);
                    // current becomes the newly appended table element
                    const gop = table.getPtr(part).?; // array entry
                    const last_elem = &gop.array.items[gop.array.items.len - 1];
                    self.current = &last_elem.table;
                    // `current_prefix` keys the non-table leaves a kv records
                    // (`scalar_leaves`), so it must equal the path the verdict
                    // sites reconstruct: every array-of-tables segment (including
                    // outer ones in a nested `[[w]] / [[w.sub]]`) carries its
                    // element index. `indexed_key` already holds the outer
                    // indices; append THIS element's. Its index is the CUMULATIVE
                    // count (`aot_lengths`), not the live per-unit array length:
                    // in the streaming path each `[[w]]` unit sees a fresh
                    // single-element array, so a live `len - 1` is always 0 and
                    // later elements' leaves would collide with the first.
                    const idx = (self.seen.aot_lengths.get(key_owned) orelse 1) - 1;
                    self.current_prefix.clearRetainingCapacity();
                    try self.current_prefix.appendSlice(self.arena, indexed_key.items);
                    try self.current_prefix.print(self.arena, "[{d}]", .{idx});
                } else {
                    try self.openTable(table, part, key_owned, indexed_key.items);
                    self.current = &table.getPtr(part).?.table;
                    self.current_prefix.clearRetainingCapacity();
                    try self.current_prefix.appendSlice(self.arena, indexed_key.items);
                }
            } else {
                // Intermediate  -  walk or create, but forbid traversing
                // through scalars, inline tables, or arrays-of-tables
                // (must target the last element of array-of-tables) or
                // normal arrays.
                // A scalar / static-array leaf at this path is a conflict:
                // the seen-set catches it even when the value tree was
                // discarded (streaming). The message mirrors the buffered
                // tree-walk below, which reports a static array
                // ("cannot redefine array ...") differently from a scalar
                // ("... is not a table").
                if (self.seen.scalar_leaves.get(indexed_key.items)) |kind| {
                    return switch (kind) {
                        .static_array => self.setErrorFmt("cannot redefine array '{s}' as table", .{full_key.items}),
                        .scalar => self.setErrorFmt("key '{s}' is not a table", .{full_key.items}),
                    };
                }
                // An array-of-tables intermediate resolves to its CURRENT
                // element (per `aot_lengths`, which is sound even when the live
                // slot is absent in the streaming path). Qualify `indexed_key`
                // with that element's index so deeper `scalar_leaves` lookups
                // address the element the leaf was recorded under.
                if (self.seen.array_tables.contains(key_owned)) {
                    const count = self.seen.aot_lengths.get(key_owned) orelse 0;
                    if (count > 0) try indexed_key.print(self.arena, "[{d}]", .{count - 1});
                }
                if (table.getPtr(part)) |existing| {
                    switch (existing.*) {
                        .table => table = &existing.table,
                        .array => {
                            if (!self.seen.array_tables.contains(key_owned)) {
                                return self.setErrorFmt("cannot redefine array '{s}' as table", .{full_key.items});
                            }
                            const last_elem = &existing.array.items[existing.array.items.len - 1];
                            table = &last_elem.table;
                        },
                        else => return self.setErrorFmt("key '{s}' is not a table", .{full_key.items}),
                    }
                } else {
                    // Create implicit intermediate table. `part` is a
                    // zero-copy slice into self.input.
                    try table.put(self.arena, part, .{ .table = .empty });
                    try self.seen.implicit_tables.put(self.seen_arena, key_owned, {});
                    table = &table.getPtr(part).?.table;
                }
            }
        }
    }

    /// `full_key` is the index-free header path used to key the table-shaped
    /// seen-sets. `leaf_key` is the same path with traversed array-of-tables
    /// segments resolved to their current element index (`name[N].rest`); it
    /// addresses `scalar_leaves`, whose non-table leaves were recorded under
    /// that element-qualified form by `parseKeyValue`.
    fn openTable(self: *Parser, parent: *StringArrayHashMap(Value), key: []const u8, full_key: []const u8, leaf_key: []const u8) Error!void {
        if (self.seen.inline_tables.contains(full_key)) {
            return self.setErrorFmt("cannot redefine inline table '{s}'", .{full_key});
        }
        // Seen-sets are authoritative for the redefinition / type-conflict
        // verdict, so the decision holds even when the live tree slot is
        // absent (the streaming path frames units against a fresh per-unit
        // root). In the buffered path the tree and seen-sets always agree, so
        // these early checks reproduce the previous behavior exactly.
        if (self.seen.defined_tables.contains(full_key)) {
            return self.setErrorFmt("table '{s}' redefined", .{full_key});
        }
        if (self.seen.array_tables.contains(full_key)) {
            return self.setErrorFmt("key '{s}' already defined with different type", .{full_key});
        }
        // A scalar / static-array leaf at this path is a type conflict.
        // The seen-set catches it even when the value tree was discarded
        // (streaming), matching the buffered tree-walk's `else` branch below.
        if (self.seen.scalar_leaves.contains(leaf_key)) {
            return self.setErrorFmt("key '{s}' already defined with different type", .{full_key});
        }
        if (parent.getPtr(key)) |existing| {
            switch (existing.*) {
                .table => {
                    _ = self.seen.implicit_tables.remove(full_key);
                    try self.seen.defined_tables.put(self.seen_arena, full_key, {});
                    return;
                },
                else => return self.setErrorFmt("key '{s}' already defined with different type", .{full_key}),
            }
        }
        // Zero-copy: `key` is a slice into self.input.
        try parent.put(self.arena, key, .{ .table = .empty });
        _ = self.seen.implicit_tables.remove(full_key);
        try self.seen.defined_tables.put(self.seen_arena, full_key, {});
    }

    /// See `openTable` for the `full_key` / `leaf_key` split.
    fn openArrayOfTables(self: *Parser, parent: *StringArrayHashMap(Value), key: []const u8, full_key: []const u8, leaf_key: []const u8) Error!void {
        // Seen-sets are authoritative for the type-conflict verdict (see
        // `openTable`). A path previously defined as a `[table]`, an inline
        // table, or a dotted-key table cannot be reopened as `[[array]]`.
        if (self.seen.defined_tables.contains(full_key) or
            self.seen.inline_tables.contains(full_key) or
            self.seen.dotted_created.contains(full_key))
        {
            return self.setErrorFmt("key '{s}' already defined", .{full_key});
        }
        // A non-table leaf at this path blocks `[[aot]]`. The message
        // mirrors the buffered tree-walk below: a static array reports
        // "cannot append to static array", a scalar "already defined".
        if (self.seen.scalar_leaves.get(leaf_key)) |kind| {
            return switch (kind) {
                .static_array => self.setErrorFmt("cannot append to static array '{s}'", .{full_key}),
                .scalar => self.setErrorFmt("key '{s}' already defined", .{full_key}),
            };
        }
        if (parent.getPtr(key)) |existing| {
            switch (existing.*) {
                .array => {
                    if (!self.seen.array_tables.contains(full_key)) {
                        return self.setErrorFmt("cannot append to static array '{s}'", .{full_key});
                    }
                    try existing.array.append(self.arena, .{ .table = .empty });
                    try self.bumpAotLength(full_key);
                    return;
                },
                else => return self.setErrorFmt("key '{s}' already defined", .{full_key}),
            }
        }
        // Slot absent. In the buffered path this is a first definition; in the
        // streaming path (fresh per-unit root) it may instead be an append to
        // an array-of-tables defined in an earlier unit  -  the seen-set knows
        // which. Either way one fresh element table is created in THIS unit's
        // tree; the streaming reader emits it as one `[[x]]` element and the
        // consumer appends across units.
        var arr: ArrayList(Value) = .empty;
        try arr.append(self.arena, .{ .table = .empty });
        try parent.put(self.arena, key, .{ .array = arr });
        try self.seen.array_tables.put(self.seen_arena, full_key, {});
        try self.bumpAotLength(full_key);
    }

    /// Record one more element for the array-of-tables at the index-free path
    /// `full_key`. `full_key` is already seen-arena-owned (it is the lookup key
    /// the other AOT sets store), so it can key `aot_lengths` directly.
    fn bumpAotLength(self: *Parser, full_key: []const u8) Error!void {
        const gop = try self.seen.aot_lengths.getOrPut(self.seen_arena, full_key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    // ----- key/value parsing -----

    fn parseKeyValue(self: *Parser, target: *StringArrayHashMap(Value)) Error!void {
        self.skipWs();
        self.token_start = self.pos;
        var parts: ArrayList([]const u8) = .empty;
        defer parts.deinit(self.arena);
        try self.parseKeyPath(&parts);
        self.skipWs();
        if (!self.match('=')) return self.setError("expected '=' after key");
        self.skipWs();

        // Build the full key prefix so we can check against closed-set
        // rules. The prefix is `current_prefix` + parts joined by '.'.
        var full_key: ArrayList(u8) = .empty;
        defer full_key.deinit(self.arena);
        try full_key.appendSlice(self.arena, self.current_prefix.items);

        // Descend intermediate tables for dotted keys.
        var t = target;
        for (parts.items[0 .. parts.items.len - 1], 0..) |part, i| {
            // Always emit a separator for joins  -  empty keys are valid
            // in TOML (e.g. `""."x" = 1`) and would otherwise collapse.
            if (self.current_prefix.items.len > 0 or i > 0) try full_key.append(self.arena, '.');
            try full_key.appendSlice(self.arena, part);
            // Duped into the seen-arena: stored into dotted_created /
            // dotted_current and used as their lookup key, so it must
            // outlive the per-unit value arena in the streaming path.
            const fk = try self.seen_arena.dupe(u8, full_key.items);

            // Inline/header-defined/other-header-dotted-created tables
            // cannot be extended via dotted-key descent.
            if (self.seen.inline_tables.contains(fk)) {
                return self.setErrorFmt("cannot extend inline table '{s}'", .{fk});
            }
            if (self.seen.defined_tables.contains(fk)) {
                return self.setErrorFmt("cannot extend header-defined table '{s}'", .{fk});
            }
            if (self.seen.dotted_created.contains(fk) and !self.seen.dotted_current.contains(fk)) {
                return self.setErrorFmt("cannot extend dotted-key-created table '{s}' from a different scope", .{fk});
            }
            // A scalar / static-array leaf at this intermediate path is a
            // conflict: the seen-set catches it even when the value tree was
            // discarded (streaming), matching the buffered tree-walk's `else`
            // branch below.
            if (self.seen.scalar_leaves.contains(fk)) {
                return self.setErrorFmt("key '{s}' is not a table", .{fk});
            }

            if (t.getPtr(part)) |existing| {
                switch (existing.*) {
                    .table => {
                        t = &existing.table;
                    },
                    else => return self.setErrorFmt("key '{s}' is not a table", .{fk}),
                }
            } else {
                // Zero-copy: `part` is a slice into self.input.
                try t.put(self.arena, part, .{ .table = .empty });
                t = &t.getPtr(part).?.table;
                try self.seen.dotted_created.put(self.seen_arena, fk, {});
                try self.seen.dotted_current.put(self.seen_arena, fk, {});
            }
        }

        // Final key: full path for this leaf.
        const last = parts.items[parts.items.len - 1];
        if (self.current_prefix.items.len > 0 or parts.items.len > 1) try full_key.append(self.arena, '.');
        try full_key.appendSlice(self.arena, last);
        const fk_final = try self.arena.dupe(u8, full_key.items);

        if (t.contains(last)) {
            return self.setErrorFmt("duplicate key '{s}'", .{last});
        }

        // Set the current path so parseValue records its span (and
        // nested element spans, recursively) against the right key.
        const prev_path_len = self.current_path.items.len;
        self.current_path.clearRetainingCapacity();
        try self.current_path.appendSlice(self.arena, fk_final);
        defer {
            self.current_path.shrinkRetainingCapacity(prev_path_len);
        }

        const value = try self.parseValue();
        // Zero-copy: `last` is a slice into self.input, which the caller
        // guarantees outlives the parse tree (documented contract). The
        // HashMap stores the slice header, not a copy of the bytes.
        try t.put(self.arena, last, value);

        // Record non-table leaves (scalars and static arrays) so a later
        // header / `[[aot]]` / dotted-key that traverses through or
        // redefines this path is rejected even after the value tree is
        // discarded (the streaming path). Inline tables are handled by
        // `sealInlineValue` -> `inline_tables` instead. The key is duped
        // into the seen-arena (stream-lifetime), not the per-unit arena.
        switch (value) {
            .table => {},
            .array => {
                const owned = try self.seen_arena.dupe(u8, fk_final);
                try self.seen.scalar_leaves.put(self.seen_arena, owned, .static_array);
            },
            else => {
                const owned = try self.seen_arena.dupe(u8, fk_final);
                try self.seen.scalar_leaves.put(self.seen_arena, owned, .scalar);
            },
        }

        // If value is an inline table or an array containing inline
        // tables, seal the affected paths so they can't be reopened
        // or extended.
        try self.sealInlineValue(fk_final, value);
    }

    /// Recursively mark `full_key` (and, if the value is a table or array
    /// of tables, its children) as inline-defined.
    fn sealInlineValue(self: *Parser, full_key: []const u8, value: Value) Error!void {
        // Only inline-table values (and their sub-tables) need sealing.
        // Scalars and inline arrays don't introduce header-extendable
        // table paths, so we save the HashMap insert in the hot path.
        switch (value) {
            .table => |t| {
                // The key is duped into the seen-arena: it is stored into
                // inline_tables (a seen-set), so it must outlive the
                // per-unit value arena in the streaming path. `full_key`
                // may be a per-unit-arena slice (from `parseKeyValue`), so
                // re-dupe rather than store it directly.
                const owned = try self.seen_arena.dupe(u8, full_key);
                try self.seen.inline_tables.put(self.seen_arena, owned, {});
                var it = t.iterator();
                while (it.next()) |entry| {
                    const sub = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ full_key, entry.key_ptr.* });
                    try self.sealInlineValue(sub, entry.value_ptr.*);
                }
            },
            else => {},
        }
    }

    fn parseKeyPath(self: *Parser, out: *ArrayList([]const u8)) Error!void {
        while (true) {
            self.skipWs();
            const part = try self.parseOneKey();
            try out.append(self.arena, part);
            self.skipWs();
            if (!self.match('.')) return;
        }
    }

    fn parseOneKey(self: *Parser) Error![]const u8 {
        if (self.eof()) return self.setError("expected key");
        const c = self.peek();
        if (c == '"') {
            return self.parseBasicString();
        }
        if (c == '\'') {
            return self.parseLiteralString();
        }
        // Bare key: A-Za-z0-9_-
        const start = self.pos;
        while (!self.eof()) {
            const k = self.peek();
            if ((k >= 'A' and k <= 'Z') or (k >= 'a' and k <= 'z') or (k >= '0' and k <= '9') or k == '_' or k == '-') {
                self.advance();
            } else break;
        }
        if (self.pos == start) return self.setError("expected key");
        return self.input[start..self.pos];
    }

    // ----- values -----

    fn parseValue(self: *Parser) Error!Value {
        if (self.eof()) return self.setError("expected value");

        self.token_start = self.pos;
        // Snapshot the value's byte-precise start so any nested parser
        // (parseArray, parseInlineTable) can record spans against this
        // exact position regardless of how deep we recurse.
        const start = self.pos;
        const value = try self.parseValueInner();
        try self.recordSpanAtCurrentPath(start);
        return value;
    }

    fn parseValueInner(self: *Parser) Error!Value {
        const c = self.peek();
        switch (c) {
            '"' => {
                if (self.peekAt(1) == '"' and self.peekAt(2) == '"') {
                    const s = try self.parseMultilineBasicString();
                    return .{ .string = s };
                }
                const s = try self.parseBasicString();
                return .{ .string = s };
            },
            '\'' => {
                if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') {
                    const s = try self.parseMultilineLiteralString();
                    return .{ .string = s };
                }
                const s = try self.parseLiteralString();
                return .{ .string = s };
            },
            '[' => return self.parseArray(),
            '{' => return self.parseInlineTable(),
            't', 'f' => return self.parseBoolean(),
            else => return self.parseNumberOrDateTime(),
        }
    }

    /// Record a span for the value currently being parsed at the current
    /// path. No-op when spans are disabled. `start` is the value's byte offset.
    fn recordSpanAtCurrentPath(self: *Parser, start: usize) Error!void {
        const sm = self.spans orelse return;
        const dup = try self.arena.dupe(u8, self.current_path.items);
        try sm.put(self.arena, dup, .{
            .start = start,
            .end = self.pos,
        });
    }

    // ----- strings -----

    fn parseBasicString(self: *Parser) Error![]const u8 {
        self.token_start = self.pos;
        if (!self.match('"')) return self.setError("expected '\"'");

        // Zero-copy fast-path: scan for end-of-string without building a buffer.
        // SIMD bulk-skip plain ASCII 16 bytes at a time; only drop to scalar for
        // stop bytes (quote, backslash, control, DEL, non-ASCII).
        const start = self.pos;
        var has_escape = false;
        while (!self.eof()) {
            // Bulk-advance past plain ASCII before touching individual bytes.
            const skip = scanBasicStringFast(self.input[self.pos..]);
            self.pos += skip;
            if (self.eof()) break;

            const c = self.peek();
            if (c == '"') break;
            if (c == '\\') {
                has_escape = true;
                break;
            }
            if (c == '\n' or c == '\r') return self.setError("newline in basic string");
            if (c < 0x20 and c != 0x09) return self.setError("control character in string");
            if (c == 0x7F) return self.setError("DEL in string");
            if (c >= 0x80) {
                try self.validateUtf8();
                continue;
            }
            self.advance();
        }
        if (!has_escape) {
            if (self.eof() or self.peek() != '"') return self.setError("unterminated string");
            const slice = self.input[start..self.pos];
            self.advance();
            return slice;
        }

        var buf: ArrayList(u8) = .empty;
        try buf.appendSlice(self.arena, self.input[start..self.pos]);
        while (!self.eof()) {
            // Bulk-advance past plain ASCII.
            const skip = scanBasicStringFast(self.input[self.pos..]);
            if (skip > 0) {
                try buf.appendSlice(self.arena, self.input[self.pos .. self.pos + skip]);
                self.pos += skip;
                if (self.eof()) break;
            }

            const c = self.peek();
            if (c == '"') {
                self.advance();
                return buf.items;
            }
            if (c == '\\') {
                try self.consumeEscape(&buf, false);
                continue;
            }
            if (c == '\n' or c == '\r') return self.setError("newline in basic string");
            if (c < 0x20 and c != 0x09) return self.setError("control character in string");
            if (c == 0x7F) return self.setError("DEL in string");
            if (c >= 0x80) {
                const before = self.pos;
                try self.validateUtf8();
                try buf.appendSlice(self.arena, self.input[before..self.pos]);
                continue;
            }
            try buf.append(self.arena, c);
            self.advance();
        }
        return self.setError("unterminated string");
    }

    fn consumeEscape(self: *Parser, buf: *ArrayList(u8), multiline: bool) Error!void {
        _ = self.match('\\');
        if (self.eof()) return self.setError("unterminated escape");
        const e = self.peek();
        switch (e) {
            'b' => {
                try buf.append(self.arena, 0x08);
                self.advance();
            },
            't' => {
                try buf.append(self.arena, 0x09);
                self.advance();
            },
            'n' => {
                try buf.append(self.arena, 0x0A);
                self.advance();
            },
            'f' => {
                try buf.append(self.arena, 0x0C);
                self.advance();
            },
            'r' => {
                try buf.append(self.arena, 0x0D);
                self.advance();
            },
            'e' => {
                // TOML 1.1: \e -> U+001B (ESC).
                try buf.append(self.arena, 0x1B);
                self.advance();
            },
            '"' => {
                try buf.append(self.arena, '"');
                self.advance();
            },
            '\\' => {
                try buf.append(self.arena, '\\');
                self.advance();
            },
            'x' => {
                // TOML 1.1: \xHH -> single byte. The two hex digits form
                // a codepoint < 256; emit as UTF-8.
                self.advance();
                const cp = try self.parseUnicodeEscape(2);
                try appendCodepoint(buf, self.arena, cp);
            },
            'u' => {
                self.advance();
                const cp = try self.parseUnicodeEscape(4);
                try appendCodepoint(buf, self.arena, cp);
            },
            'U' => {
                self.advance();
                const cp = try self.parseUnicodeEscape(8);
                try appendCodepoint(buf, self.arena, cp);
            },
            '\n', '\r', ' ', '\t' => {
                if (!multiline) return self.setError("invalid escape");
                // Line-ending backslash: eat whitespace+newline+whitespace.
                // Must reach a newline or the sequence is an error.
                // Skip trailing spaces/tabs on this line.
                while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t')) self.advance();
                if (self.eof()) return self.setError("unterminated string");
                if (self.peek() == '\r') self.advance();
                if (self.eof() or self.peek() != '\n') return self.setError("invalid line-ending backslash");
                self.advance();
                // Now skip ALL subsequent whitespace incl. newlines.
                while (!self.eof()) {
                    const k = self.peek();
                    if (k == ' ' or k == '\t' or k == '\n' or k == '\r') self.advance() else break;
                }
            },
            else => return self.setError("invalid escape"),
        }
    }

    fn parseUnicodeEscape(self: *Parser, n: usize) Error!u32 {
        if (self.pos + n > self.input.len) return self.setError("short unicode escape");
        var cp: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = self.peek();
            const d: u32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return self.setError("invalid hex in \\u escape"),
            };
            cp = cp * 16 + d;
            self.advance();
        }
        if (cp > 0x10FFFF) return self.setError("\\U code point out of range");
        // Surrogates are invalid.
        if (cp >= 0xD800 and cp <= 0xDFFF) return self.setError("surrogate code point in \\u escape");
        return cp;
    }

    fn appendCodepoint(buf: *ArrayList(u8), arena: Allocator, cp: u32) Error!void {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &utf8) catch return error.TomlParseError;
        try buf.appendSlice(arena, utf8[0..n]);
    }

    fn parseLiteralString(self: *Parser) Error![]const u8 {
        self.token_start = self.pos;
        if (!self.match('\'')) return self.setError("expected '\\''");
        const start = self.pos;
        while (!self.eof()) {
            const c = self.peek();
            if (c == '\'') {
                const slice = self.input[start..self.pos];
                self.advance();
                return slice;
            }
            if (c == '\n' or c == '\r') return self.setError("newline in literal string");
            if (c < 0x20 and c != 0x09) return self.setError("control in literal string");
            if (c == 0x7F) return self.setError("DEL in literal string");
            if (c >= 0x80) {
                try self.validateUtf8();
                continue;
            }
            self.advance();
        }
        return self.setError("unterminated literal string");
    }

    fn parseMultilineBasicString(self: *Parser) Error![]const u8 {
        self.token_start = self.pos;
        // consume opening """
        _ = self.match('"');
        _ = self.match('"');
        _ = self.match('"');
        // Trim at most one newline (LF or CRLF pair) immediately after the
        // opening delimiter. A lone CR is NOT a newline per TOML ABNF and
        // must fall through to the body loop where it is rejected.
        if (!self.eof() and self.peek() == '\r' and self.peekAt(1) == '\n') {
            self.advance();
            self.advance();
        } else if (!self.eof() and self.peek() == '\n') {
            self.advance();
        }

        var buf: ArrayList(u8) = .empty;

        while (!self.eof()) {
            // Look for closing """
            if (self.peek() == '"') {
                if (self.peekAt(1) == '"' and self.peekAt(2) == '"') {
                    // Consume three ", then allow up to 2 more as content.
                    self.advance();
                    self.advance();
                    self.advance();
                    if (!self.eof() and self.peek() == '"') {
                        try buf.append(self.arena, '"');
                        self.advance();
                        if (!self.eof() and self.peek() == '"') {
                            try buf.append(self.arena, '"');
                            self.advance();
                        }
                    }
                    return buf.items;
                }
                // else: single/double " not at terminator
                try buf.append(self.arena, '"');
                self.advance();
                continue;
            }
            if (self.peek() == '\\') {
                try self.consumeEscape(&buf, true);
                continue;
            }
            const c = self.peek();
            if (c < 0x20 and c != 0x09 and c != 0x0A and c != 0x0D) return self.setError("control character in string");
            if (c == 0x7F) return self.setError("DEL in string");
            // Normalize CRLF to LF.
            if (c == '\r') {
                if (self.peekAt(1) == '\n') {
                    self.advance();
                    continue;
                }
                return self.setError("bare CR in multiline string");
            }
            if (c >= 0x80) {
                const before = self.pos;
                try self.validateUtf8();
                try buf.appendSlice(self.arena, self.input[before..self.pos]);
                continue;
            }
            try buf.append(self.arena, c);
            self.advance();
        }
        return self.setError("unterminated multiline string");
    }

    fn parseMultilineLiteralString(self: *Parser) Error![]const u8 {
        self.token_start = self.pos;
        _ = self.match('\'');
        _ = self.match('\'');
        _ = self.match('\'');
        // Trim at most one newline (LF or CRLF pair) immediately after the
        // opening delimiter. A lone CR is NOT a newline per TOML ABNF and
        // must fall through to the body loop where it is rejected.
        if (!self.eof() and self.peek() == '\r' and self.peekAt(1) == '\n') {
            self.advance();
            self.advance();
        } else if (!self.eof() and self.peek() == '\n') {
            self.advance();
        }

        // Try zero-copy: scan for ''' without any special processing.
        const start = self.pos;
        var zero_copy_possible = true;
        while (!self.eof()) {
            const c = self.peek();
            if (c == '\r' and self.peekAt(1) == '\n') {
                // Zero-copy would preserve CR  -  TOML wants LF only here.
                zero_copy_possible = false;
                break;
            }
            if (c == '\'') {
                if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') {
                    const end = self.pos;
                    self.advance();
                    self.advance();
                    self.advance();
                    // Content may have up to 2 trailing single quotes folded in.
                    var tail: usize = 0;
                    while (tail < 2 and !self.eof() and self.peek() == '\'') {
                        self.advance();
                        tail += 1;
                    }
                    if (tail == 0) {
                        return self.input[start..end];
                    }
                    // Fall through: we consumed extras, need copy path.
                    var buf: ArrayList(u8) = .empty;
                    try buf.appendSlice(self.arena, self.input[start..end]);
                    var k: usize = 0;
                    while (k < tail) : (k += 1) try buf.append(self.arena, '\'');
                    return buf.items;
                }
            }
            // Lone CR (not followed by LF) is invalid per TOML 1.1.
            if (c == 0x0D and self.peekAt(1) != '\n') return self.setError("lone CR in literal string");
            if (c < 0x20 and c != 0x09 and c != 0x0A and c != 0x0D) return self.setError("control in literal string");
            if (c == 0x7F) return self.setError("DEL in literal string");
            if (c >= 0x80) {
                try self.validateUtf8();
                continue;
            }
            self.advance();
        }
        if (!zero_copy_possible) {
            // Rewind to start of body and walk with copy path.
            self.pos = start;
            // Recompute line/col is impractical here; for simplicity the
            // error location may be off by at most this single string,
            // which is acceptable for diagnostics.
            var buf: ArrayList(u8) = .empty;
            while (!self.eof()) {
                const c = self.peek();
                if (c == '\r' and self.peekAt(1) == '\n') {
                    try buf.append(self.arena, '\n');
                    self.advance();
                    self.advance();
                    continue;
                }
                if (c == '\'') {
                    if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') {
                        self.advance();
                        self.advance();
                        self.advance();
                        var tail: usize = 0;
                        while (tail < 2 and !self.eof() and self.peek() == '\'') {
                            try buf.append(self.arena, '\'');
                            self.advance();
                            tail += 1;
                        }
                        return buf.items;
                    }
                }
                if (c < 0x20 and c != 0x09 and c != 0x0A and c != 0x0D) return self.setError("control in literal string");
                if (c == 0x7F) return self.setError("DEL in literal string");
                if (c >= 0x80) {
                    const before = self.pos;
                    try self.validateUtf8();
                    try buf.appendSlice(self.arena, self.input[before..self.pos]);
                    continue;
                }
                try buf.append(self.arena, c);
                self.advance();
            }
            return self.setError("unterminated multiline literal string");
        }
        return self.setError("unterminated multiline literal string");
    }

    // ----- booleans -----

    fn parseBoolean(self: *Parser) Error!Value {
        self.token_start = self.pos;
        if (self.matchStr("true")) return .{ .boolean = true };
        if (self.matchStr("false")) return .{ .boolean = false };
        // Scan the bareword so we can give a suggestion.
        const word_start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.pos += 1;
            } else break;
        }
        const word = self.input[word_start..self.pos];
        const known = [_][]const u8{ "true", "false", "inf", "nan" };
        const suggestion = lev.closestMatch(word, &known, lev.suggestionThreshold(word.len));
        const msg = std.fmt.allocPrint(self.arena, "invalid value `{s}`", .{word}) catch return error.OutOfMemory;
        return self.setErrorWithSuggestion(msg, suggestion);
    }

    // ----- numbers / datetimes -----

    /// Unified entry point for unquoted values: integers, floats, inf/nan,
    /// and datetimes. Needs lookahead because `1979-05-27` looks like a
    /// subtraction in integer context.
    fn parseNumberOrDateTime(self: *Parser) Error!Value {
        self.token_start = self.pos;
        // Scan the token.
        const start = self.pos;
        // Allow a leading sign for numbers only.
        var has_sign = false;
        if (self.peek() == '+' or self.peek() == '-') {
            has_sign = true;
            self.advance();
        }

        // inf / nan keywords
        if (self.peekKeyword("inf")) {
            _ = self.matchStr("inf");
            const f: f64 = if (self.input[start] == '-') -std.math.inf(f64) else std.math.inf(f64);
            return .{ .float = f };
        }
        if (self.peekKeyword("nan")) {
            _ = self.matchStr("nan");
            // Bit-set nan; sign preserved for completeness but TOML reader
            // treats nan as nan regardless.
            const base = std.math.nan(f64);
            const f: f64 = if (self.input[start] == '-') -base else base;
            return .{ .float = f };
        }

        // Collect the token. For a datetime we need at least 4 digits + '-',
        // so look ahead.
        if (!has_sign and self.pos + 4 < self.input.len and
            isDig(self.input[self.pos]) and isDig(self.input[self.pos + 1]) and
            isDig(self.input[self.pos + 2]) and isDig(self.input[self.pos + 3]) and
            self.input[self.pos + 4] == '-')
        {
            // Likely a date/datetime. Scan to end of token.
            const token = self.scanDateTimeLiteral();
            const parsed = dt.parseAny(token) catch return self.setError("invalid datetime");
            return switch (parsed) {
                .datetime => |d| .{ .datetime = d },
                .date => |d| .{ .date = d },
                .time => |t| .{ .time = t },
            };
        }
        // Time literal: HH:MM:SS...
        if (!has_sign and self.pos + 2 < self.input.len and
            isDig(self.input[self.pos]) and isDig(self.input[self.pos + 1]) and self.input[self.pos + 2] == ':')
        {
            const token = self.scanTimeLiteral();
            const parsed = dt.parseAny(token) catch return self.setError("invalid time");
            return switch (parsed) {
                .time => |t| .{ .time = t },
                else => self.setError("invalid time"),
            };
        }

        // Number. Distinguish integer from float by scanning.
        // Check for radix prefix (only after optional sign and only if no sign).
        if (!has_sign and self.pos + 1 < self.input.len and self.input[self.pos] == '0') {
            const prefix = self.input[self.pos + 1];
            if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
                self.advance();
                self.advance();
                return switch (prefix) {
                    'x' => self.parseRadixInteger(16),
                    'o' => self.parseRadixInteger(8),
                    'b' => self.parseRadixInteger(2),
                    else => unreachable,
                };
            }
        }

        // Decimal int or float. Scan digits, check for `.` or `e`/`E`.
        var has_dot = false;
        var has_exp = false;
        var scan = self.pos;
        while (scan < self.input.len) : (scan += 1) {
            const c = self.input[scan];
            switch (c) {
                '0'...'9', '_' => {},
                '.' => {
                    if (has_dot or has_exp) break;
                    has_dot = true;
                },
                'e', 'E' => {
                    if (has_exp) break;
                    has_exp = true;
                    // optional sign follows
                    if (scan + 1 < self.input.len and (self.input[scan + 1] == '+' or self.input[scan + 1] == '-')) scan += 1;
                },
                else => break,
            }
        }
        const end = scan;

        if (has_dot or has_exp) {
            // float
            const raw = self.input[start..end];
            const f = parseFloatRaw(self.arena, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidFloat => return self.setError("invalid float"),
            };
            // Advance parser.
            while (self.pos < end) self.advance();
            return .{ .float = f };
        }

        // integer (decimal)
        const raw = self.input[start..end];
        const i = parseDecFast(raw) orelse
            (parseDecIntRaw(raw) catch return self.setError("invalid integer"));
        while (self.pos < end) self.advance();
        return .{ .integer = i };
    }

    fn peekKeyword(self: *Parser, kw: []const u8) bool {
        if (self.pos + kw.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + kw.len], kw)) return false;
        // Must be followed by a non-identifier char.
        const after_idx = self.pos + kw.len;
        if (after_idx < self.input.len) {
            const c = self.input[after_idx];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') return false;
        }
        return true;
    }

    fn scanDateTimeLiteral(self: *Parser) []const u8 {
        // Scan characters valid in a TOML datetime literal:
        // digits, `-`, `:`, `T`, `t`, ` `, `.`, `+`, `Z`, `z`.
        // Stop at whitespace/comma/]/}/#/newline.
        const start = self.pos;
        var last_nonspace_end = start;
        // The space separator between date and time complicates this:
        // `1979-05-27 07:32:00`  -  the space is content. We allow a single
        // space only if immediately followed by a digit (time section).
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0'...'9', '-', ':', '.', '+', 'T', 't', 'Z', 'z' => {
                    self.advance();
                    last_nonspace_end = self.pos;
                },
                ' ' => {
                    // Only valid if it separates date from time (first space only).
                    if (self.pos + 1 < self.input.len and isDig(self.input[self.pos + 1]) and self.pos - start == 10) {
                        self.advance();
                        last_nonspace_end = self.pos;
                    } else break;
                },
                else => break,
            }
        }
        self.pos = last_nonspace_end;
        // Recompute is unnecessary for pos-only consumers; line/col is
        // whatever we walked to.
        return self.input[start..last_nonspace_end];
    }

    fn scanTimeLiteral(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0'...'9', ':', '.' => self.advance(),
                else => break,
            }
        }
        return self.input[start..self.pos];
    }

    fn parseArray(self: *Parser) Error!Value {
        self.token_start = self.pos;
        if (self.depth >= self.max_depth) return self.setDepthError();
        self.depth += 1;
        defer self.depth -= 1;
        _ = self.match('[');
        var arr: ArrayList(Value) = .empty;
        try self.skipWsAndComments();
        if (self.match(']')) return .{ .array = arr };
        var idx: usize = 0;
        while (true) : (idx += 1) {
            try self.skipWsAndComments();

            // Push `[N]` onto the current path so parseValue records the
            // element span at e.g. `users[0]` rather than the parent's path.
            const prev = try self.pushIndex(idx);
            const value = try self.parseValue();
            self.popPath(prev);

            try arr.append(self.arena, value);
            try self.skipWsAndComments();
            if (self.match(',')) {
                try self.skipWsAndComments();
                if (self.match(']')) return .{ .array = arr };
                continue;
            }
            if (self.match(']')) return .{ .array = arr };
            return self.setError("expected ',' or ']'");
        }
    }

    fn parseInlineTable(self: *Parser) Error!Value {
        self.token_start = self.pos;
        if (self.depth >= self.max_depth) return self.setDepthError();
        self.depth += 1;
        defer self.depth -= 1;
        _ = self.match('{');
        var tbl: StringArrayHashMap(Value) = .empty;
        // Local seal set: paths (as joined dotted keys) that have been
        // directly assigned within THIS inline-table literal and therefore
        // cannot be extended via dotted-key in a later kv entry.
        var sealed: StringHashMap(void) = .empty;
        defer sealed.deinit(self.arena);

        // TOML 1.1 allows newlines, comments, and trailing commas inside
        // inline tables.
        try self.skipWsAndComments();
        if (self.match('}')) return .{ .table = tbl };
        while (true) {
            try self.skipWsAndComments();
            // Trailing comma support: closer may immediately follow.
            if (self.match('}')) return .{ .table = tbl };
            var parts: ArrayList([]const u8) = .empty;
            defer parts.deinit(self.arena);
            try self.parseKeyPath(&parts);
            self.skipWs();
            if (!self.match('=')) return self.setError("expected '=' in inline table");
            try self.skipWsAndComments();

            // Build the path incrementally so we can check the seal set.
            var fkbuf: ArrayList(u8) = .empty;
            defer fkbuf.deinit(self.arena);

            var t = &tbl;
            for (parts.items[0 .. parts.items.len - 1], 0..) |part, i| {
                if (i > 0) try fkbuf.append(self.arena, '.');
                try fkbuf.appendSlice(self.arena, part);
                if (sealed.contains(fkbuf.items)) {
                    return self.setErrorFmt("cannot extend inline key '{s}'", .{fkbuf.items});
                }
                if (t.getPtr(part)) |existing| {
                    switch (existing.*) {
                        .table => t = &existing.table,
                        else => return self.setError("key is not a table"),
                    }
                } else {
                    // Zero-copy: `part` is a slice into self.input.
                    try t.put(self.arena, part, .{ .table = .empty });
                    t = &t.getPtr(part).?.table;
                }
            }
            const last = parts.items[parts.items.len - 1];
            if (parts.items.len > 1) try fkbuf.append(self.arena, '.');
            try fkbuf.appendSlice(self.arena, last);
            if (sealed.contains(fkbuf.items)) {
                return self.setErrorFmt("cannot redefine inline key '{s}'", .{fkbuf.items});
            }
            if (t.contains(last)) return self.setError("duplicate key in inline table");

            // Push `.fkbuf` onto current_path so parseValue records the
            // span at the right path inside this inline table literal.
            const prev = try self.pushPath('.', fkbuf.items);
            const value = try self.parseValue();
            self.popPath(prev);

            // Zero-copy: `last` is a slice into self.input.
            try t.put(self.arena, last, value);
            // Seal key MUST be duped: fkbuf is a temporary buffer.
            const seal_key = try self.arena.dupe(u8, fkbuf.items);
            try sealed.put(self.arena, seal_key, {});

            try self.skipWsAndComments();
            if (self.match(',')) {
                try self.skipWsAndComments();
                continue;
            }
            if (self.match('}')) return .{ .table = tbl };
            return self.setError("expected ',' or '}'");
        }
    }

    fn parseRadixInteger(self: *Parser, comptime base: u8) Error!Value {
        const start = self.pos;
        var last_was_underscore = true; // require digit first
        while (self.pos < self.input.len) {
            const c = self.peek();
            if (c == '_') {
                if (last_was_underscore) return self.setError("invalid underscore in integer");
                last_was_underscore = true;
                self.advance();
                continue;
            }
            const ok = switch (base) {
                16 => (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'),
                8 => c >= '0' and c <= '7',
                2 => c == '0' or c == '1',
                else => unreachable,
            };
            if (!ok) break;
            last_was_underscore = false;
            self.advance();
        }
        if (last_was_underscore) return self.setError("trailing underscore in integer");
        if (self.pos == start) return self.setError("missing digits");

        // Parse. Build from bytes skipping underscores.
        var acc: u64 = 0;
        var i: usize = start;
        while (i < self.pos) : (i += 1) {
            const c = self.input[i];
            if (c == '_') continue;
            const d: u64 = switch (base) {
                16 => switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => unreachable,
                },
                8 => c - '0',
                2 => c - '0',
                else => unreachable,
            };
            // Overflow-aware multiply+add.
            const mul = std.math.mul(u64, acc, base) catch return self.setError("integer overflow");
            acc = std.math.add(u64, mul, d) catch return self.setError("integer overflow");
            if (acc > @as(u64, std.math.maxInt(i64))) return self.setError("integer overflow");
        }
        return .{ .integer = @intCast(acc) };
    }
};

fn isDig(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Parse a TOML decimal integer (allowing underscore separators and a
/// leading sign). No radix prefix allowed.
fn parseDecIntRaw(s: []const u8) error{InvalidInteger}!i64 {
    if (s.len == 0) return error.InvalidInteger;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+') i += 1 else if (s[0] == '-') {
        neg = true;
        i += 1;
    }
    if (i >= s.len) return error.InvalidInteger;

    // No leading zeros (except for literal 0).
    if (s[i] == '0' and i + 1 < s.len) {
        // Allow "0" only; "00", "01" etc. invalid.
        if (s[i + 1] != 0) return error.InvalidInteger;
    }

    var last_underscore = true; // require digit first
    var acc: u64 = 0;
    const max_pos: u64 = @as(u64, std.math.maxInt(i64));
    const max_neg: u64 = @as(u64, std.math.maxInt(i64)) + 1;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') {
            if (last_underscore) return error.InvalidInteger;
            last_underscore = true;
            continue;
        }
        if (c < '0' or c > '9') return error.InvalidInteger;
        last_underscore = false;
        const d: u64 = c - '0';
        const mul = std.math.mul(u64, acc, 10) catch return error.InvalidInteger;
        acc = std.math.add(u64, mul, d) catch return error.InvalidInteger;
        if (!neg and acc > max_pos) return error.InvalidInteger;
        if (neg and acc > max_neg) return error.InvalidInteger;
    }
    if (last_underscore) return error.InvalidInteger;
    if (neg) {
        if (acc == max_neg) return std.math.minInt(i64);
        return -@as(i64, @intCast(acc));
    }
    return @intCast(acc);
}

/// Parse a TOML float literal (decimal, with optional exponent; underscores).
fn parseFloatRaw(arena: Allocator, s: []const u8) error{ InvalidFloat, OutOfMemory }!f64 {
    // Strip underscores: TOML underscores cannot be adjacent, nor leading/
    // trailing, nor next to `.`/`e`. We enforce those conditions here.
    // Stripping only removes bytes, so the input length is a safe upper
    // bound for the output; a fixed buffer would reject long-but-valid
    // literals (e.g. the full decimal form of floatMin / subnormals).
    const buf = try arena.alloc(u8, s.len);
    var n: usize = 0;

    var prev_was_digit = false;
    var prev_was_underscore = false;
    var seen_dot = false;
    var seen_exp = false;
    var digits_since_dot_or_start: usize = 0;

    // Reject leading zeros in the integer part: `03.14` or `+03.14` or
    // `-03.14` are invalid. A single `0` before `.` or `e` is fine.
    {
        var idx: usize = 0;
        if (idx < s.len and (s[idx] == '+' or s[idx] == '-')) idx += 1;
        if (idx + 1 < s.len and s[idx] == '0' and s[idx + 1] >= '0' and s[idx + 1] <= '9') {
            return error.InvalidFloat;
        }
    }

    for (s, 0..) |c, idx| {
        switch (c) {
            '+', '-' => {
                if (idx != 0 and !(idx > 0 and (s[idx - 1] == 'e' or s[idx - 1] == 'E'))) return error.InvalidFloat;
                buf[n] = c;
                n += 1;
                prev_was_digit = false;
                prev_was_underscore = false;
            },
            '0'...'9' => {
                buf[n] = c;
                n += 1;
                prev_was_digit = true;
                prev_was_underscore = false;
                digits_since_dot_or_start += 1;
            },
            '_' => {
                if (!prev_was_digit) return error.InvalidFloat;
                if (idx + 1 >= s.len) return error.InvalidFloat;
                const next = s[idx + 1];
                if (next < '0' or next > '9') return error.InvalidFloat;
                prev_was_digit = false;
                prev_was_underscore = true;
                // don't copy underscore
            },
            '.' => {
                if (seen_dot or seen_exp) return error.InvalidFloat;
                if (!prev_was_digit) return error.InvalidFloat;
                seen_dot = true;
                buf[n] = c;
                n += 1;
                prev_was_digit = false;
                prev_was_underscore = false;
                digits_since_dot_or_start = 0;
            },
            'e', 'E' => {
                if (seen_exp) return error.InvalidFloat;
                if (!prev_was_digit) return error.InvalidFloat;
                seen_exp = true;
                buf[n] = c;
                n += 1;
                prev_was_digit = false;
                prev_was_underscore = false;
            },
            else => return error.InvalidFloat,
        }
    }
    if (prev_was_underscore) return error.InvalidFloat;
    if (!seen_dot and !seen_exp) return error.InvalidFloat;
    // If we have a fractional part, must have digits after dot.
    if (seen_dot and !seen_exp and digits_since_dot_or_start == 0) return error.InvalidFloat;
    // std.fmt.parseFloat rejects leading + signs on some Zig versions; trim.
    const slice = buf[0..n];
    return std.fmt.parseFloat(f64, slice) catch error.InvalidFloat;
}

const testing = std.testing;

test "parse empty document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "", .{});
    try testing.expect(val == .table);
    try testing.expectEqual(@as(usize, 0), val.table.count());
}

test "parse whitespace + comments only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\# comment
        \\
        \\   # another
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expect(val == .table);
    try testing.expectEqual(@as(usize, 0), val.table.count());
}

test "parse basic string kv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\title = "TOML Example"
    , .{});
    try testing.expectEqualStrings("TOML Example", val.table.get("title").?.string);
}

test "parse literal string kv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\path = 'C:\Users\nodejs\templates'
    , .{});
    try testing.expectEqualStrings("C:\\Users\\nodejs\\templates", val.table.get("path").?.string);
}

test "parse basic string escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\s = "a\tb\nc\"d\\e"
    , .{});
    try testing.expectEqualStrings("a\tb\nc\"d\\e", val.table.get("s").?.string);
}

test "parse unicode escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\s = "\u00e9\U0001F600"
    , .{});
    try testing.expectEqualStrings("\u{e9}\u{1F600}", val.table.get("s").?.string);
}

test "parse multiline basic string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\s = """
        \\Roses are red
        \\Violets are blue"""
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("Roses are red\nViolets are blue", val.table.get("s").?.string);
}

test "parse multiline basic string with backslash line ending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\s = """\
        \\    The quick brown \
        \\    fox jumps over \
        \\    the lazy dog.\
        \\    """
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("The quick brown fox jumps over the lazy dog.", val.table.get("s").?.string);
}

test "parse multiline literal string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\s = '''
        \\I [dw]on't need \d{2} apples'''
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("I [dw]on't need \\d{2} apples", val.table.get("s").?.string);
}

test "multiline basic string: lone leading CR is rejected" {
    // A bare CR (not part of CRLF) immediately after """ is invalid.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "a = \"\"\"\rx\"\"\"";
    try testing.expectError(error.TomlParseError, parse(arena.allocator(), src, .{}));
}

test "multiline literal string: lone leading CR is rejected" {
    // A bare CR (not part of CRLF) immediately after ''' is invalid.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "a = '''\rx'''";
    try testing.expectError(error.TomlParseError, parse(arena.allocator(), src, .{}));
}

test "multiline basic string: leading CRLF is trimmed (valid)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "a = \"\"\"\r\nx\"\"\"";
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("x", val.table.get("a").?.string);
}

test "multiline basic string: leading LF is trimmed (valid)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "a = \"\"\"\nx\"\"\"";
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("x", val.table.get("a").?.string);
}

test "parse integers all radixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\a = 42
        \\b = -17
        \\c = +99
        \\hex = 0xdeadBEEF
        \\oct = 0o755
        \\bin = 0b1010
        \\underscores = 1_000_000
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqual(@as(i64, 42), val.table.get("a").?.integer);
    try testing.expectEqual(@as(i64, -17), val.table.get("b").?.integer);
    try testing.expectEqual(@as(i64, 99), val.table.get("c").?.integer);
    try testing.expectEqual(@as(i64, 0xDEADBEEF), val.table.get("hex").?.integer);
    try testing.expectEqual(@as(i64, 0o755), val.table.get("oct").?.integer);
    try testing.expectEqual(@as(i64, 0b1010), val.table.get("bin").?.integer);
    try testing.expectEqual(@as(i64, 1_000_000), val.table.get("underscores").?.integer);
}

test "parse floats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\pi = 3.14
        \\neg = -0.01
        \\sci = 5e+22
        \\big = 1e6
        \\smell = 6.626e-34
        \\under = 9_224_617.445_991_228
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqual(@as(f64, 3.14), val.table.get("pi").?.float);
    try testing.expectEqual(@as(f64, -0.01), val.table.get("neg").?.float);
    try testing.expectEqual(@as(f64, 5e22), val.table.get("sci").?.float);
    try testing.expectEqual(@as(f64, 1e6), val.table.get("big").?.float);
}

test "parse inf/nan" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\a = inf
        \\b = +inf
        \\c = -inf
        \\d = nan
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expect(std.math.isPositiveInf(val.table.get("a").?.float));
    try testing.expect(std.math.isPositiveInf(val.table.get("b").?.float));
    try testing.expect(std.math.isNegativeInf(val.table.get("c").?.float));
    try testing.expect(std.math.isNan(val.table.get("d").?.float));
}

test "parse booleans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\a = true
        \\b = false
    , .{});
    try testing.expectEqual(true, val.table.get("a").?.boolean);
    try testing.expectEqual(false, val.table.get("b").?.boolean);
}

test "parse datetime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\dt = 1979-05-27T07:32:00Z
        \\ld = 1979-05-27
        \\lt = 07:32:00
    , .{});
    try testing.expectEqual(@as(u16, 1979), val.table.get("dt").?.datetime.date.year);
    try testing.expectEqual(@as(i16, 0), val.table.get("dt").?.datetime.tz_offset_minutes.?);
    try testing.expectEqual(@as(u8, 27), val.table.get("ld").?.date.day);
    try testing.expectEqual(@as(u8, 32), val.table.get("lt").?.time.minute);
}

test "parse arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\nums = [1, 2, 3]
        \\strs = ["a", "b", "c"]
        \\nested = [[1, 2], [3, 4]]
        \\trailing = [
        \\  1,
        \\  2,
        \\  3,
        \\]
    ;
    const val = try parse(arena.allocator(), src, .{});
    try testing.expectEqual(@as(usize, 3), val.table.get("nums").?.array.items.len);
    try testing.expectEqual(@as(i64, 2), val.table.get("nums").?.array.items[1].integer);
    try testing.expectEqual(@as(usize, 2), val.table.get("nested").?.array.items.len);
    try testing.expectEqual(@as(i64, 3), val.table.get("nested").?.array.items[1].array.items[0].integer);
    try testing.expectEqual(@as(usize, 3), val.table.get("trailing").?.array.items.len);
}

test "parse inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "point = { x = 1, y = 2 }";
    const val = try parse(arena.allocator(), src, .{});
    const pt = val.table.get("point").?.table;
    try testing.expectEqual(@as(i64, 1), pt.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), pt.get("y").?.integer);
}

test "parse table headers + dotted keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\[servers]
        \\hostname = "localhost"
        \\
        \\[servers.alpha]
        \\ip = "10.0.0.1"
        \\
        \\[servers.beta]
        \\ip = "10.0.0.2"
    ;
    const val = try parse(arena.allocator(), src, .{});
    const servers = val.table.get("servers").?.table;
    try testing.expectEqualStrings("localhost", servers.get("hostname").?.string);
    try testing.expectEqualStrings("10.0.0.1", servers.get("alpha").?.table.get("ip").?.string);
    try testing.expectEqualStrings("10.0.0.2", servers.get("beta").?.table.get("ip").?.string);
}

test "parse array of tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]
        \\name = "Nail"
        \\sku = 284758393
    ;
    const val = try parse(arena.allocator(), src, .{});
    const products = val.table.get("products").?.array;
    try testing.expectEqual(@as(usize, 2), products.items.len);
    try testing.expectEqualStrings("Hammer", products.items[0].table.get("name").?.string);
    try testing.expectEqualStrings("Nail", products.items[1].table.get("name").?.string);
}

test "duplicate key error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());
    const res = parse(arena.allocator(), "a = 1\na = 2\n", .{ .errors = &errs });
    try testing.expectError(error.TomlParseError, res);
    try testing.expect(errs.items.len > 0);
}

test "redefine table error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\[a]
        \\x = 1
        \\[a]
        \\y = 2
    ;
    try testing.expectError(error.TomlParseError, parse(arena.allocator(), src, .{}));
}

test "dotted keys create tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\a.b.c = 1
        \\a.b.d = 2
    ;
    const val = try parse(arena.allocator(), src, .{});
    const abc = val.table.get("a").?.table.get("b").?.table.get("c").?;
    const abd = val.table.get("a").?.table.get("b").?.table.get("d").?;
    try testing.expectEqual(@as(i64, 1), abc.integer);
    try testing.expectEqual(@as(i64, 2), abd.integer);
}

test "spans: top-level scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "title = \"toml\"";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });
    const s = spans.get("title").?;
    try testing.expectEqual(@as(u64, 8), s.start); // after `title = `
    try testing.expectEqual(@as(u64, 14), s.end); // after closing quote of "toml"
    const lc = s.lineCol(src);
    try testing.expectEqual(@as(u32, 1), lc.line);
    try testing.expectEqual(@as(u32, 9), lc.col);
}

test "spans: nested table value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "[server]\nport = 8080";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });
    const s = spans.get("server.port").?;
    const lc = s.lineCol(src);
    try testing.expectEqual(@as(u32, 2), lc.line);
    try testing.expectEqual(@as(u32, 8), lc.col);
}

test "spans: array of tables uses bracket index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "[[users]]\nname = \"alice\"\n\n[[users]]\nname = \"bob\"";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });
    const s0 = spans.get("users[0].name").?;
    const s1 = spans.get("users[1].name").?;
    try testing.expectEqual(@as(u32, 2), s0.lineCol(src).line);
    try testing.expectEqual(@as(u32, 5), s1.lineCol(src).line);
}

test "spans: dotted-key path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "physical.color = \"red\"";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });
    const s = spans.get("physical.color").?;
    try testing.expectEqual(@as(u32, 1), s.lineCol(src).line);
}

test "spans: missing path returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    _ = try parse(arena.allocator(),
        \\a = 1
    , .{ .spans = &spans });
    try testing.expect(spans.get("nonexistent") == null);
}

test "spans: opt-out doesn't pay cost" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\a = 1
    , .{});
    try testing.expectEqual(@as(i64, 1), val.table.get("a").?.integer);
}

test "spans: inline array elements get byte-precise spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "tags = [\"alpha\", \"beta\", \"gamma\"]";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });

    const s0 = spans.get("tags[0]").?;
    const s1 = spans.get("tags[1]").?;
    const s2 = spans.get("tags[2]").?;

    try testing.expectEqualStrings("\"alpha\"", src[s0.start..s0.end]);
    try testing.expectEqualStrings("\"beta\"", src[s1.start..s1.end]);
    try testing.expectEqualStrings("\"gamma\"", src[s2.start..s2.end]);
}

test "spans: nested array element spans are byte-precise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "matrix = [[1, 2], [3, 4]]";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });

    try testing.expectEqualStrings("[1, 2]", src[spans.get("matrix[0]").?.start..spans.get("matrix[0]").?.end]);
    try testing.expectEqualStrings("3", src[spans.get("matrix[1][0]").?.start..spans.get("matrix[1][0]").?.end]);
    try testing.expectEqualStrings("4", src[spans.get("matrix[1][1]").?.start..spans.get("matrix[1][1]").?.end]);
}

test "spans: inline table value spans are byte-precise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "point = { x = 10, y = 20 }";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });

    try testing.expectEqualStrings("10", src[spans.get("point.x").?.start..spans.get("point.x").?.end]);
    try testing.expectEqualStrings("20", src[spans.get("point.y").?.start..spans.get("point.y").?.end]);
}

test "parseDecFast: matches std.fmt.parseInt for common cases" {
    const cases = [_]struct { s: []const u8, expect: ?i64 }{
        .{ .s = "0", .expect = 0 },
        .{ .s = "1", .expect = 1 },
        .{ .s = "42", .expect = 42 },
        .{ .s = "8080", .expect = 8080 },
        .{ .s = "9223372036854775807", .expect = 9223372036854775807 }, // i64 max
        .{ .s = "9223372036854775808", .expect = null }, // i64 max + 1 (overflow)
        .{ .s = "99999999999999999999", .expect = null }, // way overflow (20 digits)
        .{ .s = "01", .expect = null }, // leading zero rejected
        .{ .s = "07", .expect = null }, // leading zero rejected
        .{ .s = "0a", .expect = null }, // non-digit
        .{ .s = "", .expect = null }, // empty
        .{ .s = "12345678901234567890", .expect = null }, // 20 digits, > i64 max
        .{ .s = "1_000", .expect = null }, // underscore -- fast path rejects
        .{ .s = "-5", .expect = null }, // sign -- fast path rejects
    };
    for (cases) |c| {
        try testing.expectEqual(c.expect, parseDecFast(c.s));
    }
}

test "scanBasicStringFast: matches byte-loop on quote/backslash/control/high" {
    const fixtures = [_][]const u8{
        "hello", // all plain
        "hello\"world", // quote at index 5
        "hello\\world", // backslash at 5
        "hello\x01world", // control at 5
        "hello\x7fworld", // DEL at 5
        "hello\xc2\xa0world", // high-bit at 5
        "abcdefghijklmnopqrstuvwxyz", // long plain (exercises SIMD lane)
        "abcdefghijklmnop\"rest", // quote exactly at lane boundary (idx 16)
        "abcde\"fghijklmnop\"rest", // quote inside first lane
        "\"first", // quote at idx 0
        "", // empty
        "\t", // tab is OK (not a stop byte)
    };
    for (fixtures) |f| {
        const fast = scanBasicStringFast(f);
        var slow: usize = 0;
        while (slow < f.len) : (slow += 1) {
            const c = f[slow];
            if (c == '"' or c == '\\' or c == 0x7f or c >= 0x80 or
                (c <= 0x1f and c != '\t')) break;
        }
        try testing.expectEqual(slow, fast);
    }
}

test "Diagnostic: extended struct supports default-null new fields" {
    const d: Diagnostic = .{
        .message = "expected u16, got string",
    };
    try testing.expectEqual(@as(u64, 0), d.span.start);
    try testing.expectEqual(@as(u64, 0), d.span.end);
    try testing.expect(d.path == null);
    try testing.expect(d.suggestion == null);
    try testing.expectEqual(@as(usize, 0), d.notes.len);
}

test "Diagnostic.Note: shape" {
    const n: Diagnostic.Note = .{
        .span = .{ .start = 30, .end = 36 },
        .message = "previously declared here",
    };
    try testing.expectEqual(@as(u64, 30), n.span.start);
}

test "Diagnostic.span covers the offending token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());

    // `port = "\q"` -- \q is an invalid escape inside a basic string.
    // The opening `"` is at byte 7 (after "port = "), so span.start must be 7.
    // The error fires after consuming the `\`, with pos pointing at `q`
    // (byte 9), giving a non-zero-width span.
    _ = parse(arena.allocator(), "port = \"\\q\"\n", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    const d = errs.items[0];
    try testing.expectEqual(@as(u64, 7), d.span.start);
    try testing.expect(d.span.end > d.span.start);
}

test "multi-error mode collects all errors in one parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());

    // 5 lines: bad, good, bad, good, bad. Expect 3 errors.
    // "\q" is an invalid escape in a basic string -- confirmed to produce a
    // parser-side diagnostic with a non-zero range (see DT3 test above).
    const src =
        \\port = "\q"
        \\name = "ok"
        \\flag = "\q"
        \\count = 42
        \\extra = "\q"
    ;
    _ = parse(arena.allocator(), src, .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 3);
    try testing.expectEqual(@as(u32, 1), errs.items[0].span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 3), errs.items[1].span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 5), errs.items[2].span.lineCol(src).line);
}

test "multi-error mode bounded by MAX_RECOVERY_ERRORS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());

    // 200 bad lines. Bound should cap at 100.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(arena.allocator());
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        try src.appendSlice(arena.allocator(), "x = \"\\q\"\n");
    }

    _ = parse(arena.allocator(), src.items, .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len <= 100);
    try testing.expect(errs.items.len >= 99); // allow off-by-one
}

test "parser: typo'd keyword suggests correct form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());

    _ = parse(arena.allocator(), "x = tru\n", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(errs.items[0].suggestion != null);
    try testing.expectEqualStrings("true", errs.items[0].suggestion.?);
}

test "Diagnostic.formatRich: basic shape" {
    const src =
        \\title = "x"
        \\port = "8080"
        \\name = "ef"
    ;
    const d: Diagnostic = .{
        .message = "expected integer, got string",
        .span = .{ .start = 19, .end = 25 }, // covers "8080"
    };

    var buf: [1024]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try d.formatRich(&aw, src);
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "error at 2:8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "expected integer") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port = \"8080\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "^") != null);
}

test "Diagnostic.formatRich: includes path and suggestion" {
    const src = "prt = 8080\n";
    const d: Diagnostic = .{
        .message = "unknown field `prt`",
        .path = "config.prt",
        .suggestion = "port",
    };

    var buf: [1024]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try d.formatRich(&aw, src);
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "at config.prt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "did you mean `port`?") != null);
}

test "Diagnostic.formatRich: emits notes" {
    const src = "[server]\n[server]\n";
    const d: Diagnostic = .{
        .message = "redefinition of section [server]",
        .span = .{ .start = 9, .end = 17 },
        .notes = &.{
            .{ .span = .{ .start = 0, .end = 8 }, .message = "previously declared here" },
        },
    };

    var buf: [1024]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try d.formatRich(&aw, src);
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "previously declared here") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1:1") != null);
}

test "end-to-end: multi-error parse + rich rendering of each" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());

    const src =
        \\port = "\q"
        \\name = "ok"
        \\flag = "\q"
        \\
        \\[server]
        \\port = "8080"
    ;

    _ = parse(arena.allocator(), src, .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len >= 2);

    // Verify rich rendering doesn't crash and produces non-empty output.
    var buf: [4096]u8 = undefined;
    for (errs.items) |d| {
        var aw: std.Io.Writer = .fixed(&buf);
        try d.formatRich(&aw, src);
        try testing.expect(aw.buffered().len > 0);
    }
}

test "nesting depth guard: array branch errors at max_depth+1, parses at max_depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const default_max: usize = (ParseOptions{}).max_depth;

    // `x = ` + (max_depth+1) `[`: one bracket past the ceiling must error
    // (not overflow the stack). The bracket count bounds the construction.
    var over: ArrayList(u8) = .empty;
    try over.appendSlice(a, "x = ");
    try over.appendNTimes(a, '[', default_max + 1);
    try testing.expectError(error.NestingTooDeep, parse(a, over.items, .{}));

    // Exactly max_depth deep (balanced, innermost holds an integer) parses.
    var ok: ArrayList(u8) = .empty;
    try ok.appendSlice(a, "x = ");
    try ok.appendNTimes(a, '[', default_max);
    try ok.append(a, '0');
    try ok.appendNTimes(a, ']', default_max);
    const v_ok = try parse(a, ok.items, .{});
    try testing.expect(v_ok.table.get("x").? == .array);
}

test "nesting depth guard: inline-table branch errors at max_depth+1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const default_max: usize = (ParseOptions{}).max_depth;

    // `x = ` + (max_depth+1) `{a=`: each `{` is one nesting level.
    var over: ArrayList(u8) = .empty;
    try over.appendSlice(a, "x = ");
    var i: usize = 0;
    while (i < default_max + 1) : (i += 1) try over.appendSlice(a, "{a=");
    try testing.expectError(error.NestingTooDeep, parse(a, over.items, .{}));
}

test "nesting depth guard: records a diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const default_max: usize = (ParseOptions{}).max_depth;

    var over: ArrayList(u8) = .empty;
    try over.appendSlice(a, "x = ");
    try over.appendNTimes(a, '[', default_max + 1);
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    try testing.expectError(error.NestingTooDeep, parse(a, over.items, .{ .errors = &errs }));
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    try testing.expectEqualStrings("nesting depth exceeds limit (128)", errs.items[0].message);
}

test "nesting depth guard: custom max_depth honored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var over: ArrayList(u8) = .empty;
    try over.appendSlice(a, "x = ");
    try over.appendNTimes(a, '[', 11);
    try testing.expectError(error.NestingTooDeep, parse(a, over.items, .{ .max_depth = 10 }));
}

test "spans map: byte offsets past 4 GiB record without a cap (boundary injected)" {
    // Span offsets are u64. recordSpanAtCurrentPath must store an offset past
    // maxInt(u32) verbatim rather than rejecting or truncating it. Inject the
    // boundary by setting pos directly so no 4 GiB buffer is allocated.
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: v.Spans = .empty;
    var p = Parser.init(ar.allocator(), "x");
    p.spans = &spans;

    const over: usize = @as(usize, std.math.maxInt(u32)) + 1;
    p.pos = over + 5;
    try p.recordSpanAtCurrentPath(over);

    const s = spans.get("").?;
    try testing.expectEqual(@as(u64, over), s.start);
    try testing.expectEqual(@as(u64, over + 5), s.end);
}

// ----- statement-by-statement (shared SeenState) equivalence -----

/// Deep structural equality over the parser's Value tree. Compares
/// scalars by value and tables/arrays recursively. Table key ORDER is
/// significant (the parser preserves insertion order, and the streaming
/// path must reproduce it) so tables are compared entry-by-entry in order.
fn valuesEqual(a: Value, b: Value) bool {
    const Tag = std.meta.Tag(Value);
    if (@as(Tag, a) != @as(Tag, b)) return false;
    return switch (a) {
        .string => |s| std.mem.eql(u8, s, b.string),
        .integer => |i| i == b.integer,
        .boolean => |x| x == b.boolean,
        .float => |f| (std.math.isNan(f) and std.math.isNan(b.float)) or f == b.float,
        .date => |d| std.meta.eql(d, b.date),
        .time => |t| std.meta.eql(t, b.time),
        .datetime => |d| std.meta.eql(d, b.datetime),
        .array => |arr| blk: {
            if (arr.items.len != b.array.items.len) break :blk false;
            for (arr.items, b.array.items) |x, y| {
                if (!valuesEqual(x, y)) break :blk false;
            }
            break :blk true;
        },
        .table => |t| blk: {
            if (t.count() != b.table.count()) break :blk false;
            var it = t.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                const bk = b.table.keys()[i];
                if (!std.mem.eql(u8, entry.key_ptr.*, bk)) break :blk false;
                if (!valuesEqual(entry.value_ptr.*, b.table.values()[i])) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Split `doc` into statement-units for the equivalence test: a maximal
/// run of lines beginning at a top-level header line (a line whose first
/// non-whitespace byte is `[`) up to but not including the next top-level
/// header line. Any leading top-level key-value lines form the first unit.
///
/// This is a deliberately minimal splitter (the real boundary oracle is a
/// later task): it keys off line-leading `[`, so it does NOT handle a `[`
/// that opens a multi-line inline array spanning a line that itself starts
/// with `[`. The equivalence fixtures avoid that shape on purpose.
fn splitUnits(arena: Allocator, doc: []const u8) Error![][]const u8 {
    var units: ArrayList([]const u8) = .empty;
    var unit_start: usize = 0;
    var i: usize = 0;
    var have_content = false; // current unit has any non-blank line yet
    while (i < doc.len) {
        const line_start = i;
        while (i < doc.len and doc[i] != '\n') i += 1;
        if (i < doc.len) i += 1; // consume newline

        // First non-whitespace byte of this line.
        var j = line_start;
        while (j < doc.len and (doc[j] == ' ' or doc[j] == '\t')) j += 1;
        const is_header = j < doc.len and doc[j] == '[';

        if (is_header and have_content) {
            try units.append(arena, doc[unit_start..line_start]);
            unit_start = line_start;
        }
        if (j < i) have_content = true; // counts headers and kv lines
    }
    if (unit_start < doc.len) try units.append(arena, doc[unit_start..doc.len]);
    return units.items;
}

/// Parse `doc` unit-by-unit against ONE shared root + ONE shared
/// SeenState, mirroring how the streaming reader will drive per-unit
/// parses. Returns the accumulated root as a Value, or the first error.
fn parseStatementByStatement(arena: Allocator, doc: []const u8) Error!Value {
    var root: StringArrayHashMap(Value) = .empty;
    var seen: SeenState = .empty;
    const units = try splitUnits(arena, doc);
    for (units) |unit| {
        var p = Parser.initUnit(arena, arena, unit, &root, &seen);
        try p.parseStatements();
    }
    return Value{ .table = root };
}

test "streaming seam: statement-by-statement parse equals buffered parse" {
    // Each fixture is parsed two ways: (i) the normal buffered parse, and
    // (ii) statement-unit-by-unit against ONE shared root + ONE shared
    // SeenState. Both must reach the IDENTICAL accept/reject decision, and
    // on accept the IDENTICAL Value tree. This proves duplicate detection
    // survives across separately-parsed units  -  the core requirement for
    // streaming, where a unit's VALUES are discarded but its NAME stays
    // known in the shared SeenState.
    const cases = [_]struct {
        src: []const u8,
        ok: bool,
    }{
        // Plain multi-table accept.
        .{ .src = "[a]\nx = 1\n[b]\ny = 2\n", .ok = true },
        // Redefinition across units -> ERROR (the headline carried-SeenState case).
        .{ .src = "[a]\nx = 1\n[b]\ny = 2\n[a]\nz = 3\n", .ok = false },
        // Array-of-tables append across units -> accept (two elements).
        .{ .src = "[[x]]\na = 1\n[[x]]\na = 2\n[[x]]\na = 3\n", .ok = true },
        // Super-table created implicitly by [a.b], then promoted by [a].
        .{ .src = "[a.b]\nc = 1\n[a]\nd = 2\n", .ok = true },
        // Reverse: define [a] then deeper [a.b] -> accept.
        .{ .src = "[a]\nd = 2\n[a.b]\nc = 1\n", .ok = true },
        // Header redefines a deeper super-table -> ERROR.
        .{ .src = "[a.b]\nc = 1\n[a]\nd = 2\n[a.b]\ne = 3\n", .ok = false },
        // Dotted-key creates a table, then a header tries to redefine the
        // EXACT dotted-created path -> ERROR (cross-unit).
        .{ .src = "[t]\na.b = 1\n[t.a]\nz = 2\n", .ok = false },
        // Dotted-key creates intermediate, header targets a DEEPER path ->
        // accept (only exact redefinition is blocked).
        .{ .src = "[t]\na.b.c = 1\n[t.a.b.d]\nz = 2\n", .ok = true },
        // Inline-table sealing across units: [a] holds inline table, then a
        // later [a.b] header tries to reopen the sealed sub-path -> ERROR.
        .{ .src = "[a]\nb = { c = 1 }\n[a.b]\nd = 2\n", .ok = false },
        // Inline table sealed, later dotted-key extension attempt -> ERROR.
        .{ .src = "[a]\nb = { c = 1 }\n[z]\n", .ok = true },
        // Duplicate key in a reopened (array-of-tables) element name across
        // units is fine; duplicate of the SAME key within one element errs.
        .{ .src = "[[p]]\nk = 1\n[[p]]\nk = 2\n", .ok = true },
        // Plain top-level kv before any header, then headers.
        .{ .src = "top = 1\n[a]\nx = 1\n[b]\ny = 2\n", .ok = true },
        // Mixed values to exercise scalar reproduction across units.
        .{ .src = "[nums]\ni = 42\nf = 3.14\ns = \"hi\"\nb = true\n[dt]\nd = 1979-05-27\n", .ok = true },
    };

    for (cases, 0..) |c, ci| {
        var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer buf_arena.deinit();
        var stm_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer stm_arena.deinit();

        const buf_res = parse(buf_arena.allocator(), c.src, .{});
        const stm_res = parseStatementByStatement(stm_arena.allocator(), c.src);

        const buf_ok = if (buf_res) |_| true else |_| false;
        const stm_ok = if (stm_res) |_| true else |_| false;

        // (1) accept/reject must agree with each other and the fixture.
        testing.expect(buf_ok == c.ok) catch |e| {
            std.debug.print("case {d}: buffered ok={} expected {}\n", .{ ci, buf_ok, c.ok });
            return e;
        };
        testing.expect(stm_ok == buf_ok) catch |e| {
            std.debug.print("case {d}: stream ok={} buffered ok={}\n", .{ ci, stm_ok, buf_ok });
            return e;
        };

        // (2) on accept, the Value trees must be byte-identical in shape.
        if (buf_ok) {
            const bv = buf_res catch unreachable;
            const sv = stm_res catch unreachable;
            testing.expect(valuesEqual(bv, sv)) catch |e| {
                std.debug.print("case {d}: value trees differ\n", .{ci});
                return e;
            };
        }
    }
}

test "streaming seam: 1000-line gap before redefinition still errors" {
    // The headline carried-SeenState test from the design plan: `[a]`,
    // many lines, then `[a]` again. In the statement-by-statement path the
    // first unit's VALUES could be discarded, but its NAME must persist in
    // the shared SeenState so the second `[a]` is rejected exactly as the
    // buffered parser rejects it.
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var src: ArrayList(u8) = .empty;
    try src.appendSlice(a, "[a]\n");
    var i: u32 = 0;
    while (i < 1000) : (i += 1) try src.print(a, "k{d} = {d}\n", .{ i, i });
    try src.appendSlice(a, "[b]\nz = 1\n[a]\nredef = 2\n");

    var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer buf_arena.deinit();
    var stm_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer stm_arena.deinit();

    try testing.expectError(error.TomlParseError, parse(buf_arena.allocator(), src.items, .{}));
    try testing.expectError(error.TomlParseError, parseStatementByStatement(stm_arena.allocator(), src.items));
}

test "diagnostics: span records byte offsets past 4 GiB without clamping" {
    // Offsets are u64; a diagnostic span past 4 GiB is stored verbatim.
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var p = Parser.init(ar.allocator(), "x");
    p.token_start = @as(usize, std.math.maxInt(u32)) + 100;
    p.pos = @as(usize, std.math.maxInt(u32)) + 200;
    const s = p.diagSpan();
    try testing.expectEqual(@as(u64, @as(usize, std.math.maxInt(u32)) + 100), s.start);
    try testing.expectEqual(@as(u64, @as(usize, std.math.maxInt(u32)) + 200), s.end);
}

test "plain parse with spans under 4 GiB is byte-identical (no regression)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: v.Spans = .empty;
    const src = "title = \"toml\"";
    _ = try parse(arena.allocator(), src, .{ .spans = &spans });
    const s = spans.get("title").?;
    try testing.expectEqual(@as(u64, 8), s.start);
    try testing.expectEqual(@as(u64, 14), s.end);
    const lc = s.lineCol(src);
    try testing.expectEqual(@as(u32, 1), lc.line);
    try testing.expectEqual(@as(u32, 9), lc.col);
}
