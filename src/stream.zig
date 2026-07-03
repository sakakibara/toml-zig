//! Reader-backed, table-at-a-time TOML event reader.
//!
//! `EventReader` pulls bytes from a `std.Io.Reader`, frames ONE statement-unit
//! at a time (a `[table]` / `[[array-of-tables]]` header plus its key-values,
//! or the leading top-level key-values), parses each unit with the existing
//! buffered parser, and emits the unit's contents as a flat event stream. The
//! frames are bounded: a unit's VALUES live in a per-unit arena that is reset
//! after the unit's events are emitted, so memory stays proportional to the
//! largest single unit, not the whole stream.
//!
//! Whole-file duplicate detection (the `[a]...[a]` redefinition rule) is
//! preserved by SHARING one `SeenState` across every unit. Its keys (table /
//! key path NAMES) live in a STREAM-lifetime arena, distinct from the per-unit
//! value arena, so they survive after each unit's values are discarded. This
//! is the load-bearing memory split: NAMES persist (bounded by distinct-key
//! count), VALUES do not (bounded to one unit).
//!
//! The framing oracle is the real `Tokenizer` (`frameNextUnit`): it drives the
//! lexer over the buffer so a `[` inside a string / comment / inline array /
//! multi-line string is never mistaken for a unit boundary  -  only a true
//! line-leading header token cuts a unit.
//!
//! Borrow contract: an `Event`'s payload slices (`table_header`, `key`,
//! `value_string`, ...) borrow the per-unit arena / `doc_buf` and are valid
//! ONLY until the next `next()` that crosses a unit boundary. Copy anything
//! that must outlive the unit.

const std = @import("std");
const parser = @import("parser.zig");
const value = @import("value.zig");
const tokenizer = @import("tokenizer.zig");

pub const Value = value.Value;
pub const Span = value.Span;
pub const DateTime = value.DateTime;
pub const Date = value.Date;
pub const Time = value.Time;
pub const Diagnostic = parser.Diagnostic;

/// Errors a streaming parse can surface: the parser's grammar / nesting
/// errors, plus reader and allocator failures. A unit truncated
/// mid-construct at reader EOF (unterminated string, open inline construct)
/// is fed to the parser as-is and surfaces as `TomlParseError`.
pub const StreamError = error{
    TomlParseError,
    NestingTooDeep,
    OutOfMemory,
    /// `materialize` was called when the reader was not positioned right
    /// after a `table_header` / `array_of_tables_header` event.
    MaterializeNotAtHeader,
    /// A single statement-unit exceeds `max_unit_bytes`. The stream cannot
    /// continue: the buffer would grow without bound. Callers that set an
    /// `options.errors` sink still receive this error; it is not recovered.
    LineTooLong,
} || std.Io.Reader.ShortError;

/// A single streaming event. Payload slices borrow the per-unit arena and are
/// valid only until the next unit-boundary-crossing `next()` (see module doc).
pub const Event = struct {
    kind: Kind,
    span: Span,
    /// Trailing `# ...` comment on the same source line, including the `#`.
    /// Empty when the line has no trailing comment. Borrows the per-unit
    /// arena; copy before the next unit-boundary-crossing `next()`.
    comment: []const u8 = "",

    pub const Kind = union(enum) {
        /// `[a.b]` header: decoded dotted path.
        table_header: []const u8,
        /// `[[a.b]]` header: decoded dotted path.
        array_of_tables_header: []const u8,
        /// A key (one leaf key under the current table / array / inline
        /// table). Decoded name.
        key: []const u8,
        value_string: []const u8,
        value_integer: i64,
        value_float: f64,
        value_bool: bool,
        value_datetime: DateTime,
        value_date: Date,
        value_time: Time,
        /// `[` of an inline array value (followed by element value events,
        /// then `array_end`).
        array_begin,
        array_end,
        /// `{` of an inline table value (followed by key/value events, then
        /// `inline_table_end`).
        inline_table_begin,
        inline_table_end,
        /// Final event: the stream is exhausted. `next()` returns null after.
        end_of_input,
    };
};

/// The framing oracle's verdict for the current buffer.
pub const FrameResult = union(enum) {
    /// The first `consumed` bytes are a complete statement-unit.
    complete: usize,
    /// The buffer does not yet hold a complete unit; pull more bytes.
    need_more,
};

/// TOML boundary oracle: given `bytes` (the buffer front) and whether the
/// reader has ended, decide whether `bytes` holds a complete statement-unit.
///
/// A unit runs from offset 0 up to (but not including) the NEXT line-leading
/// top-level header (`[` / `[[`), or to end-of-buffer at EOF. The real
/// `Tokenizer` is the oracle: a `[` inside a string, a comment, a multi-line
/// string, or an inline array/table is tokenized as its true kind (never a
/// header token), so it never cuts a unit. `need_more` is returned when no
/// boundary header has appeared yet AND more bytes are coming  -  including
/// the case where a string/value runs to buffer end mid-token.
pub fn frameNextUnit(bytes: []const u8, ended: bool) FrameResult {
    if (bytes.len == 0) {
        return if (ended) .{ .complete = 0 } else .need_more;
    }

    var t: tokenizer.Tokenizer = .init(bytes);
    var seen_leading_header = false; // the unit's OWN header (if any)
    var saw_any_content = false;

    while (t.next()) |tok| {
        // Span offsets are u64; the framing buffer is small, so narrowing to
        // usize for buffer indexing is safe here.
        const tok_start: usize = @intCast(tok.span.start);
        switch (tok.kind) {
            .blank, .comment, .eol => continue,
            .header_open, .header_array_open => {
                // Only a line-leading header is a real top-level boundary.
                if (!isLineLeading(bytes, tok_start)) {
                    saw_any_content = true;
                    continue;
                }
                if (!seen_leading_header and !saw_any_content) {
                    // This header opens THIS unit; not a boundary.
                    seen_leading_header = true;
                    saw_any_content = true;
                    continue;
                }
                // A later line-leading header: the boundary. The unit is the
                // bytes before it.
                return .{ .complete = tok_start };
            },
            else => saw_any_content = true,
        }
    }

    // Ran out of tokens without finding a boundary header.
    if (ended) return .{ .complete = bytes.len };
    return .need_more;
}

/// True iff the bytes from the start of `pos`'s line up to `pos` are all
/// horizontal whitespace (so the token at `pos` is line-leading).
fn isLineLeading(bytes: []const u8, pos: usize) bool {
    var i = pos;
    while (i > 0) {
        const c = bytes[i - 1];
        if (c == '\n') return true;
        if (c != ' ' and c != '\t') return false;
        i -= 1;
    }
    return true;
}

/// Hard cap on the byte length of the framing buffer (`doc_buf`): the unit
/// currently being framed plus any bytes pulled ahead of it. When the buffer
/// grows past this without a unit boundary appearing, framing returns
/// `LineTooLong` rather than letting `doc_buf` grow without bound. A single
/// statement-unit (one `[table]` / `[[aot]]` header plus its key-values, or
/// the leading top-level kvs) is thus effectively bounded by this cap.
const max_unit_bytes: usize = 16 * 1024 * 1024; // 16 MiB

/// Reader-backed, table-at-a-time TOML event reader. See the module doc for
/// the framing oracle, the per-unit-arena / shared-SeenState memory split, and
/// the borrow contract.
pub const EventReader = struct {
    gpa: std.mem.Allocator,
    options: parser.ParseOptions,
    reader: *std.Io.Reader,

    /// Bytes of the unit currently being framed/drained, plus any bytes pulled
    /// ahead that belong to following units. `doc_buf.items[0]` is at absolute
    /// stream offset `base`.
    doc_buf: std.ArrayList(u8) = .empty,
    /// Absolute stream offset of `doc_buf.items[0]`. Added to every event
    /// span so spans are absolute (exact u64) across the whole stream.
    base: u64 = 0,
    /// Reader at EOF: a short read returned zero bytes. Once set, no further
    /// pulls are attempted.
    ended: bool = false,

    /// STREAM-lifetime arena: owns the shared `SeenState`'s path-NAME keys.
    /// Lives from `fromReader` until `deinit`; never reset. This is what keeps
    /// duplicate detection sound after a unit's values are discarded.
    seen_arena: std.heap.ArenaAllocator,
    /// Shared duplicate-detection state, threaded across every unit.
    seen: parser.SeenState = .empty,
    /// Shared accumulating root. Only the leaf table of the unit being emitted
    /// is walked; intermediate tables it created are not re-walked. Its values
    /// live in `unit_arena` and are reset per unit, so `root` is NOT a stable
    /// whole-document tree  -  it is scratch for the current unit.
    root: parser.Value.Table = .empty,

    /// PER-UNIT arena: owns the current unit's VALUES. Reset after the unit's
    /// events are emitted, bounding value memory to one unit.
    unit_arena: std.heap.ArenaAllocator,

    /// Events flattened from the current unit, plus a cursor. `next()` returns
    /// `events.items[cursor]` and advances; when exhausted the unit is closed
    /// (compact + reset arena) and the next unit framed.
    events: std.ArrayList(Event) = .empty,
    cursor: usize = 0,
    /// Byte length (within doc_buf) of the unit whose events are buffered.
    unit_len: usize = 0,
    /// True once a unit's events are loaded and not yet fully drained.
    unit_open: bool = false,

    /// The current unit's parsed leaf table (the table its key-values landed
    /// in), living in `unit_arena`. `materialize` deep-clones it into the
    /// caller's arena. Valid only while the unit is open; null otherwise.
    cur_leaf: ?*const parser.Value.Table = null,
    /// True exactly when the most recent `next()` returned a `table_header` /
    /// `array_of_tables_header` event, i.e. `materialize` is callable now.
    at_header: bool = false,

    /// Whether the terminating `end_of_input` event has been emitted.
    finished: bool = false,

    diag: ?Diagnostic = null,

    /// Chunk size pulled from the reader per `pull()`.
    const chunk = 4096;

    /// `options.spans` is NOT populated by the streaming path: the reader
    /// keeps a private per-unit spans map (reset at every unit boundary) to
    /// derive event spans, and never writes into a caller-provided map. Use
    /// each `Event.span` instead. The other options (`errors`, `max_depth`)
    /// are honored.
    pub fn fromReader(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: parser.ParseOptions) EventReader {
        return .{
            .gpa = gpa,
            .options = options,
            .reader = reader,
            .seen_arena = std.heap.ArenaAllocator.init(gpa),
            .unit_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *EventReader) void {
        self.events.deinit(self.gpa);
        self.doc_buf.deinit(self.gpa);
        self.unit_arena.deinit();
        self.seen_arena.deinit();
    }

    /// Current allocated capacity of the internal buffer. For the
    /// bounded-memory property: stays proportional to the largest single unit,
    /// not the total stream length.
    pub fn bufCapacity(self: *const EventReader) usize {
        return self.doc_buf.capacity;
    }

    pub fn diagnostic(self: *const EventReader) ?Diagnostic {
        return self.diag;
    }

    /// Read one chunk from the backing reader into `doc_buf`. Sets `ended` at
    /// reader EOF (a zero-length short read).
    fn pull(self: *EventReader) StreamError!void {
        var tmp: [chunk]u8 = undefined;
        const n = try self.reader.readSliceShort(&tmp);
        if (n == 0) {
            self.ended = true;
            return;
        }
        if (n < tmp.len) self.ended = true;
        try self.doc_buf.appendSlice(self.gpa, tmp[0..n]);
    }

    /// Drop `consumed` bytes from the front of `doc_buf`, advancing `base`.
    /// Bytes pulled ahead slide to the front.
    fn compact(self: *EventReader, consumed: usize) void {
        if (consumed == 0) return;
        const keep = self.doc_buf.items.len - consumed;
        std.mem.copyForwards(u8, self.doc_buf.items[0..keep], self.doc_buf.items[consumed..]);
        self.doc_buf.shrinkRetainingCapacity(keep);
        self.base += consumed;
    }

    /// Pull bytes until `doc_buf` holds a complete first unit (or EOF). Returns
    /// the unit's byte length, or null when the buffer holds no further unit
    /// (only whitespace/comments at EOF).
    ///
    /// Resumable framer: the tokenizer is a LOCAL variable whose `pos`,
    /// `state`, and mid-token `pending` survive across `pull()` calls within
    /// this invocation. Each byte in `doc_buf` is examined at most once per
    /// unit frame (O(N) total, not O(N^2)). After each `pull()` we refresh
    /// `ft.input` so the tokenizer sees the enlarged slice; `ft.pos` still
    /// points to the first unexamined byte.
    ///
    /// Load-bearing invariant: the tokenizer runs in resumable mode so a token
    /// TRUNCATED at the buffer end (multi-line string, string, comment, long
    /// value) pauses (`incomplete`) and resumes the SAME scan after the next
    /// pull, instead of force-terminating and re-lexing its tail. Without this
    /// a `[header]`-looking byte run inside a multi-line string spanning the
    /// pull boundary would be mis-cut as a unit boundary (spurious error) or
    /// silently swallow a real header (value corruption).
    fn frame(self: *EventReader) StreamError!?usize {
        var ft: tokenizer.Tokenizer = .init(self.doc_buf.items);
        var seen_leading_header = false;
        var saw_any_content = false;

        while (true) {
            // Refresh the input slice: doc_buf may have reallocated after pull().
            ft.input = self.doc_buf.items;

            if (ft.input.len > max_unit_bytes) return error.LineTooLong;

            // Once the reader is drained, no more bytes will arrive: finalize
            // any paused token at buffer end instead of waiting for input.
            ft.resumable = !self.ended;

            while (ft.next()) |tok| {
                const tok_start: usize = @intCast(tok.span.start);
                switch (tok.kind) {
                    .blank, .comment, .eol => {},
                    .header_open, .header_array_open => {
                        if (!isLineLeading(self.doc_buf.items, tok_start)) {
                            saw_any_content = true;
                        } else if (!seen_leading_header and !saw_any_content) {
                            seen_leading_header = true;
                            saw_any_content = true;
                        } else {
                            // Line-leading header starts the next unit.
                            return tok_start;
                        }
                    },
                    else => saw_any_content = true,
                }
            }

            // A mid-token pause: extend the buffer and resume the same scan
            // (ft.pos + ft.pending preserved). `resumable` was false only when
            // ended, in which case next() finalizes instead of pausing, so
            // reaching here implies the reader is not yet ended.
            if (ft.incomplete) {
                try self.pull();
                continue;
            }

            // Tokenizer exhausted doc_buf between tokens.
            if (self.ended) {
                const len = self.doc_buf.items.len;
                if (len == 0) return null;
                return len;
            }
            try self.pull();
        }
    }

    /// Advance to the next event. Emits the framed units' events one at a time,
    /// then a single `end_of_input`, then null.
    pub fn next(self: *EventReader) StreamError!?Event {
        if (self.finished) return null;

        while (true) {
            if (self.unit_open) {
                if (self.cursor < self.events.items.len) {
                    const ev = self.events.items[self.cursor];
                    self.cursor += 1;
                    self.at_header = switch (ev.kind) {
                        .table_header, .array_of_tables_header => true,
                        else => false,
                    };
                    return ev;
                }
                // Unit drained: discard its bytes + values, frame the next.
                self.closeUnit();
                continue;
            }

            const len = try self.frame() orelse {
                self.finished = true;
                self.at_header = false;
                return Event{ .kind = .end_of_input, .span = self.zeroSpan() };
            };
            try self.openUnit(len);
        }
    }

    /// Compose the CURRENT statement-unit's table as a `Value`, deep-copied
    /// into `arena` so it outlives the per-unit arena reset. The returned
    /// table holds the unit's immediate key-values plus any nested arrays /
    /// inline tables, but NOT sub-tables introduced by later headers (those
    /// are separate units).
    ///
    /// Valid ONLY immediately after `next()` returned a `table_header` or
    /// `array_of_tables_header` event; otherwise returns
    /// `error.MaterializeNotAtHeader`. After it returns, the reader advances
    /// past the current unit's remaining events: the next `next()` yields the
    /// following unit's header or `end_of_input`.
    pub fn materialize(self: *EventReader, arena: std.mem.Allocator) StreamError!Value {
        if (!self.at_header) return error.MaterializeNotAtHeader;
        return self.composeCurrentUnit(arena);
    }

    /// Deep-clone the open unit's leaf table into `arena` and advance past
    /// the unit's remaining events. Shared by `materialize` (header units)
    /// and the leading root-table unit (no header). Asserts a unit is open.
    fn composeCurrentUnit(self: *EventReader, arena: std.mem.Allocator) StreamError!Value {
        const src: Value = .{ .table = self.cur_leaf.?.* };
        const out = try src.clone(arena);
        self.closeUnit();
        return out;
    }

    /// Discard the open unit's remaining events and advance to the next unit
    /// without composing a Value. Asserts a unit is open.
    fn skipCurrentUnit(self: *EventReader) void {
        self.closeUnit();
    }

    /// Parse `doc_buf.items[0..len]` against the shared root + SeenState into
    /// the per-unit arena, then flatten its contents into `events`.
    fn openUnit(self: *EventReader, len: usize) StreamError!void {
        self.unit_len = len;
        self.events.clearRetainingCapacity();
        self.cursor = 0;

        const va = self.unit_arena.allocator();
        const sa = self.seen_arena.allocator();
        const slice = self.doc_buf.items[0..len];

        // Span the unit so value/header/key events carry source offsets. The
        // spans map is per-unit (in the unit arena) and re-based to absolute.
        // The errors list is ALSO unit-arena-backed because the parser grows
        // it with its own (unit) arena; on the error path the unit arena is
        // not reset, so the diagnostic survives until deinit, and we dupe its
        // message into a stream-lifetime allocation for `diagnostic()`.
        var spans: value.Spans = .empty;
        var errors: std.ArrayList(Diagnostic) = .empty;
        var opts = self.options;
        opts.spans = &spans;
        opts.errors = &errors;

        const up = parser.streamParseUnit(va, sa, slice, &self.root, &self.seen, opts) catch |e| {
            self.captureDiag(errors.items);
            // With a caller-provided error sink the stream is recoverable:
            // discard the malformed unit (its bytes + values) so the next
            // `next()` frames the following unit. The error is surfaced once,
            // here. Without a sink the first error is terminal: leave the unit
            // in place and just propagate.
            if (self.options.errors) |sink| {
                for (errors.items) |d| {
                    const rd = self.rebaseDiag(d) catch break;
                    sink.append(self.gpa, rd) catch break;
                }
                self.compact(len);
                _ = self.unit_arena.reset(.retain_capacity);
                self.root = .empty;
                // The discarded unit is gone: nothing is materializable now.
                // Keep the `at_header => cur_leaf != null` invariant truthful
                // so a caller that catches this error cannot bypass the
                // `materialize` guard into a null `cur_leaf`.
                self.cur_leaf = null;
                self.at_header = false;
            }
            return mapParserError(e);
        };

        try self.flattenUnit(up, &spans, slice);
        self.cur_leaf = up.leaf;
        self.unit_open = true;
    }

    /// Discard the just-drained unit: compact its bytes out of doc_buf, reset
    /// the per-unit value arena (the SeenState arena is untouched), and clear
    /// the shared root so the next unit starts from a clean scratch tree. The
    /// SeenState's NAME keys survive the reset, preserving duplicate detection.
    fn closeUnit(self: *EventReader) void {
        self.compact(self.unit_len);
        self.unit_open = false;
        // `cur_leaf` lives in the per-unit arena reset below; drop both it and
        // `at_header` together so the guard invariant (`at_header` true only
        // when `cur_leaf` is non-null) holds across the close.
        self.cur_leaf = null;
        self.at_header = false;
        self.events.clearRetainingCapacity();
        self.cursor = 0;
        // Reset value memory. `root` lived in this arena, so re-init it empty.
        _ = self.unit_arena.reset(.retain_capacity);
        self.root = .empty;
    }

    /// Flatten one parsed unit into the event list: an optional header event,
    /// then the leaf table's key-values walked depth-first.
    fn flattenUnit(self: *EventReader, up: parser.UnitParse, spans: *const value.Spans, unit_buf: []const u8) StreamError!void {
        if (up.header_path.len > 0) {
            const hlocal = headerSpanLocal(unit_buf);
            const hspan = self.rebaseSpan(hlocal);
            const hcomment = trailingComment(unit_buf, @intCast(hlocal.end));
            const hcomment_dup: []const u8 = if (hcomment.len > 0)
                self.dupAbs(hcomment) catch return error.OutOfMemory
            else
                "";
            const path = self.dupAbs(up.header_path) catch return error.OutOfMemory;
            try self.events.append(self.gpa, .{
                .kind = if (up.is_array_element)
                    .{ .array_of_tables_header = path }
                else
                    .{ .table_header = path },
                .span = hspan,
                .comment = hcomment_dup,
            });
        }

        // Path prefix used to look up value spans (header path + key).
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(self.gpa);
        if (up.header_path.len > 0) try prefix.appendSlice(self.gpa, up.header_path);

        try self.walkTable(up.leaf, &prefix, spans, unit_buf);
    }

    /// Emit `key` + value events for every entry of `table`, recursing into
    /// nested tables (created by dotted keys / inline tables) and arrays.
    fn walkTable(self: *EventReader, table: *const parser.Value.Table, prefix: *std.ArrayList(u8), spans: *const value.Spans, unit_buf: []const u8) StreamError!void {
        var it = table.iterator();
        while (it.next()) |entry| {
            const key_name = entry.key_ptr.*;
            const key_dup = self.dupAbs(key_name) catch return error.OutOfMemory;
            const key_span = self.spanFor(spans, unit_buf, prefix.items, key_name);

            // Trailing comment: locate via the value span's line.
            const key_comment: []const u8 = blk: {
                var pbuf: [512]u8 = undefined;
                const n = buildPath(&pbuf, prefix.items, key_name);
                if (n > 0) {
                    if (spans.get(pbuf[0..n])) |sp| {
                        break :blk trailingComment(unit_buf, @intCast(sp.end));
                    }
                }
                break :blk "";
            };
            const key_comment_dup: []const u8 = if (key_comment.len > 0)
                self.dupAbs(key_comment) catch return error.OutOfMemory
            else
                "";

            try self.events.append(self.gpa, .{
                .kind = .{ .key = key_dup },
                .span = key_span,
                .comment = key_comment_dup,
            });

            const saved = prefix.items.len;
            if (prefix.items.len > 0) try prefix.append(self.gpa, '.');
            try prefix.appendSlice(self.gpa, key_name);
            try self.emitValue(entry.value_ptr.*, prefix, spans, unit_buf);
            prefix.shrinkRetainingCapacity(saved);
        }
    }

    /// Emit value events for one value (scalar / array / inline table).
    fn emitValue(self: *EventReader, v: parser.Value, prefix: *std.ArrayList(u8), spans: *const value.Spans, unit_buf: []const u8) StreamError!void {
        const sp = spans.get(prefix.items) orelse self.zeroSpanLocal();
        const abs = self.rebaseSpan(sp);
        switch (v) {
            .string => |s| try self.events.append(self.gpa, .{ .kind = .{ .value_string = self.dupAbs(s) catch return error.OutOfMemory }, .span = abs }),
            .integer => |n| try self.events.append(self.gpa, .{ .kind = .{ .value_integer = n }, .span = abs }),
            .float => |f| try self.events.append(self.gpa, .{ .kind = .{ .value_float = f }, .span = abs }),
            .boolean => |b| try self.events.append(self.gpa, .{ .kind = .{ .value_bool = b }, .span = abs }),
            .datetime => |d| try self.events.append(self.gpa, .{ .kind = .{ .value_datetime = d }, .span = abs }),
            .date => |d| try self.events.append(self.gpa, .{ .kind = .{ .value_date = d }, .span = abs }),
            .time => |tm| try self.events.append(self.gpa, .{ .kind = .{ .value_time = tm }, .span = abs }),
            .array => |arr| {
                try self.events.append(self.gpa, .{ .kind = .array_begin, .span = abs });
                for (arr.items, 0..) |item, i| {
                    const saved = prefix.items.len;
                    try prefix.print(self.gpa, "[{d}]", .{i});
                    try self.emitValue(item, prefix, spans, unit_buf);
                    prefix.shrinkRetainingCapacity(saved);
                }
                try self.events.append(self.gpa, .{ .kind = .array_end, .span = abs });
            },
            .table => |tbl| {
                try self.events.append(self.gpa, .{ .kind = .inline_table_begin, .span = abs });
                try self.walkTable(&tbl, prefix, spans, unit_buf);
                try self.events.append(self.gpa, .{ .kind = .inline_table_end, .span = abs });
            },
        }
    }

    /// Span for a key event: locate the first `key_segment` token on the same
    /// source line as the value. For keys whose path is not in the spans map
    /// (intermediate dotted-key tables), falls back to `zeroSpan`.
    fn spanFor(self: *EventReader, spans: *const value.Spans, unit_buf: []const u8, prefix: []const u8, key: []const u8) Span {
        var buf: [512]u8 = undefined;
        const n = buildPath(&buf, prefix, key);
        if (n > 0) {
            if (spans.get(buf[0..n])) |sp| {
                const local_start: usize = @intCast(sp.start);
                const key_local = keyTokenOnLine(unit_buf, local_start);
                if (key_local.end > key_local.start) return self.rebaseSpan(key_local);
                return self.rebaseSpan(sp);
            }
        }
        return self.zeroSpan();
    }

    /// Span for a header event: scan the unit buffer for the opening `[` or
    /// `[[` and its matching `]` / `]]`, returning the rebased absolute span.
    fn headerSpan(self: *EventReader, unit_buf: []const u8) Span {
        return self.rebaseSpan(headerSpanLocal(unit_buf));
    }

    fn rebaseSpan(self: *const EventReader, sp: Span) Span {
        return .{
            .start = self.base + sp.start,
            .end = self.base + sp.end,
        };
    }

    fn zeroSpan(self: *const EventReader) Span {
        return .{ .start = self.base, .end = self.base };
    }

    fn zeroSpanLocal(self: *const EventReader) Span {
        _ = self;
        return .{ .start = 0, .end = 0 };
    }

    /// Dup a slice into the per-unit arena (event payloads, valid until the
    /// unit boundary).
    fn dupAbs(self: *EventReader, s: []const u8) ![]const u8 {
        return self.unit_arena.allocator().dupe(u8, s);
    }

    /// Capture the parser's last diagnostic, re-based to absolute stream
    /// offsets, into `diag`. All borrowed fields are duped into the
    /// stream-lifetime seen-arena so they stay valid after the per-unit
    /// arena is freed. On OOM the diagnostic is dropped rather than kept
    /// with dangling unit-arena pointers.
    fn captureDiag(self: *EventReader, errors: []const Diagnostic) void {
        if (errors.len == 0) return;
        self.diag = self.rebaseDiag(errors[errors.len - 1]) catch null;
    }

    /// Copy a unit-arena diagnostic into stream-lifetime memory and re-base
    /// its byte ranges (including note spans) to absolute stream offsets.
    /// Every borrowed field (message, path, suggestion, notes) is duped into
    /// the seen-arena so it survives the per-unit arena reset.
    fn rebaseDiag(self: *EventReader, src: Diagnostic) error{OutOfMemory}!Diagnostic {
        const sa = self.seen_arena.allocator();
        var d = src;
        d.message = try sa.dupe(u8, src.message);
        if (src.path) |p| d.path = try sa.dupe(u8, p);
        if (src.suggestion) |s| d.suggestion = try sa.dupe(u8, s);
        if (src.notes.len > 0) {
            const notes = try sa.alloc(Diagnostic.Note, src.notes.len);
            for (src.notes, notes) |n, *out| {
                out.* = .{
                    .span = .{ .start = self.base + n.span.start, .end = self.base + n.span.end },
                    .message = try sa.dupe(u8, n.message),
                };
            }
            d.notes = notes;
        }
        d.span = .{ .start = self.base + src.span.start, .end = self.base + src.span.end };
        return d;
    }
};

fn mapParserError(e: parser.Error) StreamError {
    return switch (e) {
        error.TomlParseError => error.TomlParseError,
        error.NestingTooDeep => error.NestingTooDeep,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Scan `unit_buf` for the first line-leading `[` or `[[` header opener and
/// its matching `]` / `]]` closer. Returns the local (unit-relative) byte
/// span covering the whole `[path]` / `[[path]]` token, or a zero span when
/// the unit has no header (leading-kv unit).
fn headerSpanLocal(unit_buf: []const u8) Span {
    var t: tokenizer.Tokenizer = .init(unit_buf);
    while (t.next()) |tok| {
        switch (tok.kind) {
            .blank, .comment, .eol => {},
            .header_open, .header_array_open => {
                const start = tok.span.start;
                while (t.next()) |tok2| {
                    if (tok2.kind == .header_close) {
                        return .{ .start = start, .end = tok2.span.end };
                    }
                }
                return .{ .start = 0, .end = 0 };
            },
            else => return .{ .start = 0, .end = 0 },
        }
    }
    return .{ .start = 0, .end = 0 };
}

/// Scan from `after` in `unit_buf` for an optional trailing `# comment`.
/// Skips horizontal whitespace then checks for `#`; returns the comment
/// text including the `#` up to (but not including) the line terminator.
/// Returns an empty slice when no comment is present.
fn trailingComment(unit_buf: []const u8, after: usize) []const u8 {
    var i = after;
    while (i < unit_buf.len and (unit_buf[i] == ' ' or unit_buf[i] == '\t')) : (i += 1) {}
    if (i >= unit_buf.len or unit_buf[i] != '#') return "";
    const start = i;
    while (i < unit_buf.len and unit_buf[i] != '\n' and unit_buf[i] != '\r') : (i += 1) {}
    return unit_buf[start..i];
}

/// Find the first `key_segment` token on the line containing byte offset
/// `value_local_start` in `unit_buf`. Returns the local span of that token,
/// or a zero span when none is found (e.g., inline-value context).
fn keyTokenOnLine(unit_buf: []const u8, value_local_start: usize) Span {
    var ls: usize = value_local_start;
    while (ls > 0 and unit_buf[ls - 1] != '\n') ls -= 1;
    var t: tokenizer.Tokenizer = .init(unit_buf);
    t.pos = ls;
    while (t.next()) |tok| {
        if (tok.span.start >= value_local_start) break;
        if (tok.kind == .key_segment) return .{ .start = tok.span.start, .end = tok.span.end };
    }
    return .{ .start = 0, .end = 0 };
}

/// Write `prefix + "." + key` (or just `key` when `prefix` is empty) into
/// `buf`. Returns the byte count written, or 0 when `buf` is too small.
fn buildPath(buf: []u8, prefix: []const u8, key: []const u8) usize {
    const need = if (prefix.len > 0) prefix.len + 1 + key.len else key.len;
    if (need > buf.len) return 0;
    var n: usize = 0;
    @memcpy(buf[0..prefix.len], prefix);
    n = prefix.len;
    if (prefix.len > 0) {
        buf[n] = '.';
        n += 1;
    }
    @memcpy(buf[n .. n + key.len], key);
    n += key.len;
    return n;
}

/// Value-composition layer over `EventReader`: yields one composed `Value`
/// per `next(item_arena)` call. The caller resets `item_arena` between calls,
/// which is what bounds working memory to one statement-unit (for the
/// `tables` / `array_of_tables` shapes).
///
/// Error-recovery granularity differs from the buffered parser. On an
/// already-rejected document both reach the SAME verdict and emit the SAME
/// diagnostics (a rejected stream stays rejected; with an `options.errors`
/// sink the recovered shapes drain past the failures). They differ only in
/// the best-effort recovered TREE: streaming recovery is UNIT-granular, so a
/// malformed unit is dropped whole, whereas buffered recovery is
/// STATEMENT-granular and may keep a partial statement from within that unit.
/// The kept-vs-dropped fragment is best-effort either way; the verdict and
/// diagnostics are what callers rely on, and those match.
pub const ValueStream = struct {
    er: EventReader,
    shape: Shape,
    /// `whole` yields exactly one Value (the whole tree) then null; this
    /// records that the single yield has happened.
    whole_done: bool = false,

    /// What each `next()` yields.
    ///
    /// `tables` and `array_of_tables` keep the bounded-memory property: each
    /// yielded Value holds one unit's content, freed when the caller resets
    /// `item_arena`. `whole` does NOT: it retains the entire reconstructed
    /// document tree in `item_arena`, so its memory is proportional to the
    /// whole document. `whole` is the "parse a whole stream into one tree"
    /// convenience, not a bounded-memory stream.
    pub const Shape = enum {
        /// One Value per statement-unit, in document order. The leading
        /// top-level keys before the first header form one root-table unit.
        tables,
        /// One Value per `[[x]]` element only. Plain `[table]` units and the
        /// leading root keys are skipped. The streaming analog of NDJSON.
        array_of_tables,
        /// Exactly one Value (the whole reconstructed root tree) on the first
        /// call, then null. See the memory caveat above.
        whole,
    };

    pub fn fromReader(
        gpa: std.mem.Allocator,
        reader: *std.Io.Reader,
        options: parser.ParseOptions,
        shape: Shape,
    ) ValueStream {
        return .{
            .er = EventReader.fromReader(gpa, reader, options),
            .shape = shape,
        };
    }

    pub fn deinit(self: *ValueStream) void {
        self.er.deinit();
    }

    pub fn diagnostic(self: *const ValueStream) ?Diagnostic {
        return self.er.diagnostic();
    }

    /// Yield the next composed `Value`, or null when the stream is exhausted.
    /// The returned Value lives in `item_arena`; the caller resets it between
    /// calls (which is what bounds memory for the `tables` /
    /// `array_of_tables` shapes).
    pub fn next(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        return switch (self.shape) {
            .tables => self.nextTable(item_arena),
            .array_of_tables => self.nextArrayElement(item_arena),
            .whole => self.nextWhole(item_arena),
        };
    }

    /// One Value per statement-unit (header units via `materialize`, the
    /// leading root-key unit composed directly).
    fn nextTable(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        const ev = (try self.er.next()) orelse return null;
        switch (ev.kind) {
            .end_of_input => return null,
            .table_header, .array_of_tables_header => return try self.er.materialize(item_arena),
            // Leading root-table unit: no header event precedes its key-values.
            else => return try self.er.composeCurrentUnit(item_arena),
        }
    }

    /// One Value per `[[x]]` element; skip `[table]` units and leading root
    /// keys.
    fn nextArrayElement(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        while (true) {
            const ev = (try self.er.next()) orelse return null;
            switch (ev.kind) {
                .end_of_input => return null,
                .array_of_tables_header => return try self.er.materialize(item_arena),
                .table_header => self.er.skipCurrentUnit(),
                // Leading root-table unit.
                else => self.er.skipCurrentUnit(),
            }
        }
    }

    /// Reconstruct the whole document tree by merging each unit's composed
    /// leaf into a single root, in document order.
    ///
    /// With an `options.errors` sink the drain recovers exactly like the
    /// bounded shapes and like buffered `parse`: a malformed unit's diagnostic
    /// is forwarded to the sink (by the event layer) and the unit is skipped,
    /// while every valid unit is still merged into `root`. The single yielded
    /// tree is therefore a best-effort partial. Without a sink the first error
    /// is terminal: it propagates and no tree is produced.
    fn nextWhole(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        if (self.whole_done) return null;

        var root: Value = .makeTable();
        while (true) {
            const ev = self.er.next() catch |e| {
                // Only unit-level parse errors are recoverable, and only with
                // a sink set: the event layer discarded the malformed unit and
                // forwarded its diagnostic, so keep draining the rest. Every
                // other error (reader failure, LineTooLong, OutOfMemory) does
                // not consume input and must propagate.
                switch (e) {
                    error.TomlParseError, error.NestingTooDeep => {
                        if (self.er.options.errors != null) continue;
                        return e;
                    },
                    else => return e,
                }
            } orelse break;
            switch (ev.kind) {
                .end_of_input => break,
                .table_header => |h| {
                    const path = try item_arena.dupe(u8, h);
                    const leaf = try self.er.materialize(item_arena);
                    try mergeUnit(item_arena, &root, path, false, leaf);
                },
                .array_of_tables_header => |h| {
                    const path = try item_arena.dupe(u8, h);
                    const leaf = try self.er.materialize(item_arena);
                    try mergeUnit(item_arena, &root, path, true, leaf);
                },
                // Leading root-table unit: merge straight into the root.
                else => {
                    const leaf = try self.er.composeCurrentUnit(item_arena);
                    try mergeTableEntries(item_arena, &root.table, leaf.table);
                },
            }
        }
        self.whole_done = true;
        return root;
    }
};

/// Merge one unit's composed `leaf` table into `root` at the `.`-separated
/// header `path`. For `is_array`, the leaf is appended as a new element of
/// the array-of-tables at `path`; otherwise the leaf's entries are merged
/// into the table at `path`. Intermediate tables (and the last element of any
/// intermediate array-of-tables) are navigated/created as needed. The event
/// layer has already validated the document, so no conflict can arise here.
fn mergeUnit(arena: std.mem.Allocator, root: *Value, path: []const u8, is_array: bool, leaf: Value) StreamError!void {
    var dest = &root.table;

    var it = std.mem.splitScalar(u8, path, '.');
    var seg = it.next().?;
    while (it.next()) |nxt| {
        // `seg` is an intermediate segment; resolve / create a table for it,
        // descending into the last element when it is an array-of-tables.
        dest = try descendTable(arena, dest, seg);
        seg = nxt;
    }

    // `seg` is the final header segment.
    if (is_array) {
        const gop = try dest.getOrPut(arena, try arena.dupe(u8, seg));
        if (!gop.found_existing) gop.value_ptr.* = .makeArray();
        try gop.value_ptr.array.append(arena, leaf);
    } else {
        const gop = try dest.getOrPut(arena, try arena.dupe(u8, seg));
        if (!gop.found_existing) {
            gop.value_ptr.* = leaf;
        } else {
            try mergeTableEntries(arena, &gop.value_ptr.table, leaf.table);
        }
    }
}

/// Resolve `seg` under `dest` to a table to descend into: an existing table,
/// the last element of an existing array-of-tables, or a freshly created
/// table. Returns a pointer to that table.
fn descendTable(arena: std.mem.Allocator, dest: *parser.Value.Table, seg: []const u8) StreamError!*parser.Value.Table {
    const gop = try dest.getOrPut(arena, try arena.dupe(u8, seg));
    if (!gop.found_existing) {
        gop.value_ptr.* = .makeTable();
        return &gop.value_ptr.table;
    }
    return switch (gop.value_ptr.*) {
        .array => |*arr| &arr.items[arr.items.len - 1].table,
        else => &gop.value_ptr.table,
    };
}

/// Shallow-merge `src`'s entries into `dest`. Distinct header units never
/// produce a colliding leaf key (the event layer rejected such documents), so
/// a per-key put is sufficient; values are moved as-is (already in `arena`).
fn mergeTableEntries(arena: std.mem.Allocator, dest: *parser.Value.Table, src: parser.Value.Table) StreamError!void {
    var it = src.iterator();
    while (it.next()) |entry| {
        try dest.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

/// Container frame for the reassembler: the dotted path to an open array /
/// inline table and (for arrays) the next element index.
const Frame = struct { base_path: []const u8, idx: usize, is_array: bool };

/// Replay an event stream from `src` into a single Value tree, mirroring how a
/// consumer would rebuild the document. Returns the root table Value or the
/// stream error.
fn reassemble(gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8) StreamError!Value {
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();
    return reassembleFrom(gpa, arena, &er);
}

fn reassembleFrom(gpa: std.mem.Allocator, arena: std.mem.Allocator, er: *EventReader) StreamError!Value {
    _ = gpa;
    var root: Value = .makeTable();
    // Current table prefix (dotted) the events land under. All scratch uses
    // the test arena, freed at the end of the test  -  this is a test oracle,
    // not production code.
    var header: std.ArrayList(u8) = .empty;
    var is_array_header = false;
    var pending_key: ?[]const u8 = null;
    // Container stack for arrays / inline tables.
    var stack: std.ArrayList(Frame) = .empty;

    while (try er.next()) |ev| {
        switch (ev.kind) {
            .end_of_input => break,
            .table_header => |h| {
                header.clearRetainingCapacity();
                try header.appendSlice(arena, h);
                is_array_header = false;
                try ensurePath(arena, &root, h, false);
            },
            .array_of_tables_header => |h| {
                header.clearRetainingCapacity();
                try header.appendSlice(arena, h);
                is_array_header = true;
                try ensurePath(arena, &root, h, true);
            },
            .key => |k| {
                pending_key = try arena.dupe(u8, k);
            },
            .value_string, .value_integer, .value_float, .value_bool, .value_datetime, .value_date, .value_time => {
                try setScalar(arena, &root, &header, is_array_header, &stack, pending_key, ev);
                pending_key = null;
            },
            .array_begin => {
                const bp = try currentPath(arena, &header, is_array_header, &stack, pending_key);
                try stack.append(arena, .{ .base_path = bp, .idx = 0, .is_array = true });
                const full = try resolveHeaderIndex(arena, &root, &header, bp);
                try setContainer(arena, &root, full, false);
                pending_key = null;
            },
            .array_end => {
                _ = stack.pop();
            },
            .inline_table_begin => {
                const bp = try currentPath(arena, &header, is_array_header, &stack, pending_key);
                try stack.append(arena, .{ .base_path = bp, .idx = 0, .is_array = false });
                const full = try resolveHeaderIndex(arena, &root, &header, bp);
                try setContainer(arena, &root, full, true);
                pending_key = null;
            },
            .inline_table_end => {
                _ = stack.pop();
            },
        }
    }
    return root;
}

fn ensurePath(arena: std.mem.Allocator, root: *Value, dotted: []const u8, is_array: bool) !void {
    if (is_array) {
        // Append a fresh table element to the array at `dotted`.
        const existing = root.get(dotted);
        const idx = if (existing) |e| (if (e == .array) e.array.items.len else 0) else 0;
        var buf: [600]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}[{d}]", .{ dotted, idx }) catch return;
        root.set(arena, p, Value.makeTable()) catch {};
    } else {
        if (root.get(dotted) == null) {
            root.set(arena, dotted, Value.makeTable()) catch {};
        }
    }
}

/// Build the dotted path for the current position: header (+ latest array
/// element index) + container-stack frames + pending key.
fn currentPath(gpa: std.mem.Allocator, header: *std.ArrayList(u8), is_array_header: bool, stack: *std.ArrayList(Frame), pending_key: ?[]const u8) ![]const u8 {
    _ = is_array_header;
    var out: std.ArrayList(u8) = .empty;
    if (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        try out.appendSlice(gpa, top.base_path);
        if (top.is_array) {
            try out.print(gpa, "[{d}]", .{top.idx});
            top.idx += 1;
        } else if (pending_key) |k| {
            try out.append(gpa, '.');
            try out.appendSlice(gpa, k);
        }
    } else {
        try headerElemPath(gpa, &out, header);
        if (pending_key) |k| {
            if (out.items.len > 0) try out.append(gpa, '.');
            try out.appendSlice(gpa, k);
        }
    }
    return out.items;
}

/// Append the header path, resolving an array-of-tables header to its last
/// element index.
fn headerElemPath(gpa: std.mem.Allocator, out: *std.ArrayList(u8), header: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, header.items);
}

fn setScalar(
    arena: std.mem.Allocator,
    root: *Value,
    header: *std.ArrayList(u8),
    is_array_header: bool,
    stack: *std.ArrayList(Frame),
    pending_key: ?[]const u8,
    ev: Event,
) !void {
    _ = is_array_header;
    const gpa = arena; // arena suffices for path scratch
    const p = try currentPath(gpa, header, false, stack, pending_key);
    const sval: Value = switch (ev.kind) {
        .value_string => |s| .{ .string = try arena.dupe(u8, s) },
        .value_integer => |n| .{ .integer = n },
        .value_float => |f| .{ .float = f },
        .value_bool => |b| .{ .boolean = b },
        .value_datetime => |d| .{ .datetime = d },
        .value_date => |d| .{ .date = d },
        .value_time => |t| .{ .time = t },
        else => unreachable,
    };
    // Resolve header array index for the leading segment if needed.
    const full = try resolveHeaderIndex(arena, root, header, p);
    root.set(arena, full, sval) catch {};
}

fn setContainer(arena: std.mem.Allocator, root: *Value, path: []const u8, is_table: bool) !void {
    const v: Value = if (is_table) .makeTable() else .makeArray();
    root.set(arena, path, v) catch {};
}

/// When the header was an array-of-tables, the live element is the LAST one.
/// Rewrite a path that starts with the header into `header[last].rest`.
fn resolveHeaderIndex(arena: std.mem.Allocator, root: *Value, header: *std.ArrayList(u8), p: []const u8) ![]const u8 {
    if (header.items.len == 0) return p;
    if (!std.mem.startsWith(u8, p, header.items)) return p;
    const arr = root.get(header.items) orelse return p;
    if (arr != .array) return p;
    if (arr.array.items.len == 0) return p;
    const idx = arr.array.items.len - 1;
    const rest = p[header.items.len..];
    return std.fmt.allocPrint(arena, "{s}[{d}]{s}", .{ header.items, idx, rest });
}

fn parseBuffered(arena: std.mem.Allocator, src: []const u8) !Value {
    return parser.parse(arena, src, .{});
}

// --- Gate A: empty / whitespace-only input --------------------------------

test "gate A: empty reader yields end_of_input then null" {
    for ([_][]const u8{ "", "   ", "\n\n", "  \t\n  \n", "# comment only\n" }) |src| {
        var r: std.Io.Reader = .fixed(src);
        var er = EventReader.fromReader(testing.allocator, &r, .{});
        defer er.deinit();
        const e0 = (try er.next()).?;
        try testing.expect(e0.kind == .end_of_input);
        try testing.expect((try er.next()) == null);
    }
}

// --- Gate B: cross-check reassembled tree vs buffered parser --------------

const cross_cases = [_][]const u8{
    "x = 1\ny = 2\n",
    "title = \"TOML\"\ncount = 42\n",
    "[a]\nx = 1\n[b]\ny = 2\n",
    "[[users]]\nname = \"alice\"\n[[users]]\nname = \"bob\"\n",
    "[a.b]\nc = 1\n[a]\nd = 2\n",
    "top = 1\n[s]\nport = 8080\nhost = \"h\"\n",
    "[t]\narr = [1, 2, 3]\n",
    "[t]\nnested = { a = 1, b = 2 }\n",
    "[t]\nmixed = [ { x = 1 }, { x = 2 } ]\n",
    "[t]\nrows = [ [1, 2], [3, 4] ]\n",
    "ml = \"\"\"line1\nline2\"\"\"\n[after]\nk = 1\n",
    "[nums]\ni = 42\nf = 3.14\ns = \"hi\"\nb = true\nd = 1979-05-27\n",
    "[a.b.c]\nx = 1\n",
    "[srv]\nopts = { tls = true, ports = [80, 443] }\n",
    "[[p]]\nk = 1\n[[p]]\nk = 2\n[[p]]\nk = 3\n",
};

test "gate B: reassembled streamed tree equals buffered parse" {
    for (cross_cases) |src| {
        var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer buf_arena.deinit();
        var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer str_arena.deinit();

        const buffered = try parseBuffered(buf_arena.allocator(), src);
        const streamed = try reassemble(testing.allocator, str_arena.allocator(), src);

        testing.expect(Value.eql(buffered, streamed)) catch |e| {
            std.debug.print("gate B mismatch on:\n{s}\n", .{src});
            return e;
        };
    }
}

test "gate B: accept/reject decision matches buffered parse" {
    const cases = [_]struct { src: []const u8, ok: bool }{
        .{ .src = "[a]\nx = 1\n[b]\ny = 2\n", .ok = true },
        .{ .src = "[a]\nx = 1\n[a]\nz = 3\n", .ok = false },
        .{ .src = "[a.b]\nc = 1\n[a]\nd = 2\n[a.b]\ne = 3\n", .ok = false },
        .{ .src = "[t]\na.b = 1\n[t.a]\nz = 2\n", .ok = false },
        .{ .src = "[a]\nb = { c = 1 }\n[a.b]\nd = 2\n", .ok = false },
        .{ .src = "[[x]]\na = 1\n[[x]]\na = 2\n", .ok = true },

        // A `[header]` / `[[aot]]` / dotted-key that traverses through or
        // redefines a path already defined as a NON-TABLE kv leaf (scalar
        // or static array). The buffered parser rejects these by walking
        // the value tree; the streaming reader discards each unit's tree,
        // so without the `scalar_leaves` seen-set it wrongly accepted.
        .{ .src = "[a]\nb = 1\n[a.b]\nc = 2\n", .ok = false },
        .{ .src = "[a]\nb = 1\n[a.b.c]\nx = 1\n", .ok = false },
        .{ .src = "[a.b.c]\nd = 1\n[a.b.c.d.e]\nx = 1\n", .ok = false },
        .{ .src = "a = 1\n[b]\nz=1\n[a]\nc = 1\n", .ok = false },
        .{ .src = "[a]\nb = 1\n[c]\nz=1\n[[a.b]]\nx = 1\n", .ok = false },
        .{ .src = "x = [1,2]\n[y]\nz=1\n[x]\na = 1\n", .ok = false },
        .{ .src = "x = [1,2]\n[y]\nz=1\n[[x]]\na = 1\n", .ok = false },
        .{ .src = "a.b = 1\n[c]\nz=1\n[a.b.d]\nx=1\n", .ok = false },

        // Non-table leaves defined INSIDE an array-of-tables element. The
        // leaf is recorded under the element-qualified path (`w[0].a`); a
        // later index-free header / dotted-key that targets the SAME element
        // must reject, mirroring the buffered tree-walk. Earlier-element
        // leaves are shadowed (a fresh `[[w]]` makes `[w.a]` address a new
        // element) and must NOT block  -  see the accept cases below.
        .{ .src = "[[w]]\na = 1\n[w.a]\nb = 2\n", .ok = false },
        .{ .src = "[[w]]\na = 1\n[w.a.b]\nx = 2\n", .ok = false },
        .{ .src = "[[w]]\na = [1,2]\n[w.a]\nb = 2\n", .ok = false },
        .{ .src = "[[w]]\na = [1,2]\n[[w.a]]\nb = 2\n", .ok = false },
        .{ .src = "[[w]]\n[[w.sub]]\na=1\n[w.sub.a]\nx=1\n", .ok = false },
        .{ .src = "[[w]]\na.b=1\n[w.a.b]\nx=1\n", .ok = false },
        // Leaf in a LATER aot element, same element targeted: still rejects.
        .{ .src = "[[w]]\nb = 1\n[[w]]\na = 1\n[w.a]\nc = 2\n", .ok = false },

        // Shadowing: `[w.a]` after a second `[[w]]` targets the NEW element,
        // which has no `a`  -  the earlier element's `a` leaf is unreachable
        // and must not false-positive. Buffered accepts; streaming must too.
        .{ .src = "[[w]]\na = 1\n[[w]]\nb = 2\n[w.a]\nc = 3\n", .ok = true },
        // Header into a different child key of the aot element: accept.
        .{ .src = "[[w]]\na = 1\n[w.b]\nc = 2\n", .ok = true },
    };
    for (cases) |c| {
        var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer buf_arena.deinit();
        var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer str_arena.deinit();

        const buf_res = parseBuffered(buf_arena.allocator(), c.src);
        const buf_ok = if (buf_res) |_| true else |_| false;
        try testing.expectEqual(c.ok, buf_ok);

        const str_res = reassemble(testing.allocator, str_arena.allocator(), c.src);
        const str_ok = if (str_res) |_| true else |_| false;
        testing.expectEqual(buf_ok, str_ok) catch |e| {
            std.debug.print("stream verdict mismatch on:\n{s}\n", .{c.src});
            return e;
        };
    }
}

test "gate B: non-table-leaf conflicts keep their buffered error message" {
    // Pins the buffered verdict + message for each non-table-leaf conflict.
    // The streaming fix adds the `scalar_leaves` seen-set as ADDITIONAL
    // bookkeeping; it must not change any buffered decision or message.
    const cases = [_]struct { src: []const u8, msg: []const u8 }{
        .{ .src = "[a]\nb = 1\n[a.b]\nc = 2\n", .msg = "key 'a.b' already defined with different type" },
        .{ .src = "[a]\nb = 1\n[a.b.c]\nx = 1\n", .msg = "key 'a.b' is not a table" },
        .{ .src = "[a.b.c]\nd = 1\n[a.b.c.d.e]\nx = 1\n", .msg = "key 'a.b.c.d' is not a table" },
        .{ .src = "a = 1\n[b]\nz=1\n[a]\nc = 1\n", .msg = "key 'a' already defined with different type" },
        .{ .src = "[a]\nb = 1\n[c]\nz=1\n[[a.b]]\nx = 1\n", .msg = "key 'a.b' already defined" },
        .{ .src = "x = [1,2]\n[y]\nz=1\n[x]\na = 1\n", .msg = "key 'x' already defined with different type" },
        .{ .src = "x = [1,2]\n[y]\nz=1\n[[x]]\na = 1\n", .msg = "cannot append to static array 'x'" },
        .{ .src = "a.b = 1\n[c]\nz=1\n[a.b.d]\nx=1\n", .msg = "key 'a.b' is not a table" },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var errors: std.ArrayList(Diagnostic) = .empty;
        const res = parser.parse(arena.allocator(), c.src, .{ .errors = &errors });
        try testing.expectError(error.TomlParseError, res);
        try testing.expect(errors.items.len > 0);
        try testing.expectEqualStrings(c.msg, errors.items[errors.items.len - 1].message);
    }
}

// --- Gate C: duplicate detection across units after value-discard ---------

test "gate C: redefinition across 1000 lines errors in streaming (value-discard proof)" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "[a]\nx = 1\n");
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try src.print(a, "[t{d}]\nk = {d}\n", .{ i, i });
    }
    try src.appendSlice(a, "[a]\nz = 3\n");

    // Buffered rejects.
    var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer buf_arena.deinit();
    try testing.expectError(error.TomlParseError, parseBuffered(buf_arena.allocator(), src.items));

    // Streaming rejects too: the first `[a]`'s values were discarded and its
    // per-unit arena reset ~1000 times, yet the shared SeenState still rejects
    // the late `[a]` redefinition. Runs under testing.allocator (UAF/leak
    // detector), so a dangling SeenState key would surface here.
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    try testing.expectError(error.TomlParseError, reassemble(testing.allocator, str_arena.allocator(), src.items));
}

test "gate C: dotted-vs-header conflict across units errors in streaming" {
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    const src = "[t]\na.b = 1\n[t.a]\nz = 2\n";
    try testing.expectError(error.TomlParseError, reassemble(testing.allocator, str_arena.allocator(), src));
}

test "gate C: [[x]] append across units succeeds in streaming" {
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    const src = "[[x]]\na = 1\n[[x]]\na = 2\n[[x]]\na = 3\n";
    const v = try reassemble(testing.allocator, str_arena.allocator(), src);
    try testing.expectEqual(@as(usize, 3), v.get("x").?.array.items.len);
    try testing.expectEqual(@as(i64, 3), v.get("x[2].a").?.integer);
}

// --- Gate D: chunk-boundary equivalence -----------------------------------

/// Snapshot of an event's kind + payload, comparable across chunk sizes.
const EvSnap = struct {
    tag: std.meta.Tag(Event.Kind),
    str: []const u8,
    int: i64,
    flt: u64, // bitcast for exact compare
    boolean: bool,
};

fn snapEvent(a: std.mem.Allocator, ev: Event) !EvSnap {
    var s: EvSnap = .{ .tag = ev.kind, .str = "", .int = 0, .flt = 0, .boolean = false };
    switch (ev.kind) {
        .table_header, .array_of_tables_header, .key, .value_string => |x| s.str = try a.dupe(u8, x),
        .value_integer => |n| s.int = n,
        .value_float => |f| s.flt = @bitCast(f),
        .value_bool => |b| s.boolean = b,
        else => {},
    }
    return s;
}

fn drainWhole(a: std.mem.Allocator, src: []const u8) ![]EvSnap {
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();
    var out: std.ArrayList(EvSnap) = .empty;
    while (try er.next()) |ev| try out.append(a, try snapEvent(a, ev));
    return out.toOwnedSlice(a);
}

const ChunkedReader = struct {
    src: []const u8,
    pos: usize = 0,
    step: usize,
    reader: std.Io.Reader,

    fn init(src: []const u8, step: usize, buffer: []u8) ChunkedReader {
        return .{
            .src = src,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("reader", io_r);
        if (self.pos >= self.src.len) return error.EndOfStream;
        const want = @min(self.step, self.src.len - self.pos);
        const give = @min(want, @intFromEnum(limit));
        const n = try w.write(self.src[self.pos..][0..give]);
        self.pos += n;
        return n;
    }
};

fn drainChunked(a: std.mem.Allocator, src: []const u8, step: usize) ![]EvSnap {
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, step, &rbuf);
    var er = EventReader.fromReader(a, &cr.reader, .{});
    defer er.deinit();
    var out: std.ArrayList(EvSnap) = .empty;
    while (try er.next()) |ev| try out.append(a, try snapEvent(a, ev));
    return out.toOwnedSlice(a);
}

fn expectSnapsEqual(want: []const EvSnap, got: []const EvSnap) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.tag, g.tag);
        try testing.expectEqualStrings(w.str, g.str);
        try testing.expectEqual(w.int, g.int);
        try testing.expectEqual(w.flt, g.flt);
        try testing.expectEqual(w.boolean, g.boolean);
    }
}

const chunk_cases = [_][]const u8{
    "[a]\nx = 1\n[b]\ny = 2\n",
    "[[users]]\nname = \"alice\"\n[[users]]\nname = \"bob\"\n",
    "s = \"a [b] not header\"\n[after]\nk = 1\n",
    "c = 1 # [comment] not header\n[after]\nk = 1\n",
    "arr = [1, 2, 3]\n[after]\nk = 1\n",
    "ml = \"\"\"line\n[not a header]\nmore\"\"\"\n[after]\nk = 1\n",
    "[t]\nnested = { a = 1, b = 2 }\n[t2]\nz = 9\n",
    "top = 1\n[a]\nx = 1\n[b]\ny = 2\n[c]\nz = 3\n",
    "[nums]\ni = 42\nf = 3.14\nb = true\nd = 1979-05-27T07:32:00Z\n",
};

test "gate D: event sequence identical at every chunk size including 1 byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (chunk_cases) |src| {
        const whole = try drainWhole(a, src);
        for ([_]usize{ 1, 2, 3, 5, 7, 13, 16, 32 }) |step| {
            const chunked = try drainChunked(a, src, step);
            expectSnapsEqual(whole, chunked) catch |e| {
                std.debug.print("gate D mismatch (step={d}) on:\n{s}\n", .{ step, src });
                return e;
            };
        }
    }
}

/// A reader that releases `src` split at exactly one offset: `[0..at]` first,
/// then the rest. Exercises framing when a chunk boundary lands on a specific
/// byte (inside a string, on a header, mid multi-line string, ...).
const SplitAtReader = struct {
    src: []const u8,
    at: usize,
    pos: usize = 0,
    reader: std.Io.Reader,

    fn init(src: []const u8, at: usize, buffer: []u8) SplitAtReader {
        return .{
            .src = src,
            .at = at,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SplitAtReader = @fieldParentPtr("reader", io_r);
        if (self.pos >= self.src.len) return error.EndOfStream;
        const end = if (self.pos < self.at) self.at else self.src.len;
        const give = @min(@intFromEnum(limit), end - self.pos);
        const n = try w.write(self.src[self.pos..][0..give]);
        self.pos += n;
        return n;
    }
};

test "gate D: event sequence identical at every single split offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (chunk_cases) |src| {
        const whole = try drainWhole(a, src);
        var at: usize = 0;
        while (at <= src.len) : (at += 1) {
            var rbuf: [64]u8 = undefined;
            var sr = SplitAtReader.init(src, at, &rbuf);
            var er = EventReader.fromReader(a, &sr.reader, .{});
            defer er.deinit();
            var got: std.ArrayList(EvSnap) = .empty;
            while (try er.next()) |ev| try got.append(a, try snapEvent(a, ev));
            expectSnapsEqual(whole, got.items) catch |e| {
                std.debug.print("gate D split-at mismatch (at={d}) on:\n{s}\n", .{ at, src });
                return e;
            };
        }
    }
}

test "gate D: reassembled tree identical 1-byte vs whole, equals buffered" {
    for (chunk_cases) |src| {
        var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer buf_arena.deinit();
        const buffered = try parseBuffered(buf_arena.allocator(), src);

        var w_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer w_arena.deinit();
        const whole = try reassembleChunked(testing.allocator, w_arena.allocator(), src, 0);

        var c_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer c_arena.deinit();
        const chunked = try reassembleChunked(testing.allocator, c_arena.allocator(), src, 1);

        testing.expect(Value.eql(buffered, whole)) catch |e| {
            std.debug.print("gate D tree (whole) mismatch on:\n{s}\n", .{src});
            return e;
        };
        testing.expect(Value.eql(buffered, chunked)) catch |e| {
            std.debug.print("gate D tree (1-byte) mismatch on:\n{s}\n", .{src});
            return e;
        };
    }
}

/// Reassemble over a chunked reader (step==0 means whole/fixed).
fn reassembleChunked(gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8, step: usize) StreamError!Value {
    if (step == 0) return reassemble(gpa, arena, src);
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, step, &rbuf);
    return reassembleReader(gpa, arena, &cr.reader);
}

fn reassembleReader(gpa: std.mem.Allocator, arena: std.mem.Allocator, reader: *std.Io.Reader) StreamError!Value {
    var er = EventReader.fromReader(gpa, reader, .{});
    defer er.deinit();
    return reassembleFrom(gpa, arena, &er);
}

// --- Gate E: no dangling SeenState keys (runs under testing.allocator) -----

test "gate E: late duplicate still rejected after many unit-arena resets" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "[dup]\nfirst = 1\n");
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        // Each unit carries real values so the per-unit arena holds + frees data.
        try src.print(a, "[u{d}]\ns = \"value-{d}\"\narr = [{d}, {d}, {d}]\n", .{ i, i, i, i, i });
    }
    try src.appendSlice(a, "[dup]\nsecond = 2\n");

    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    // testing.allocator detects any use-after-free of a SeenState key.
    try testing.expectError(error.TomlParseError, reassemble(testing.allocator, str_arena.allocator(), src.items));
}

test "frameNextUnit: a [ inside a string is not a boundary" {
    const src = "s = \"a [b] c\"\n[real]\nk = 1\n";
    const r = frameNextUnit(src, true);
    try testing.expect(r == .complete);
    // The unit is the leading kv line, ending at the real header.
    const idx = std.mem.indexOf(u8, src, "[real]").?;
    try testing.expectEqual(idx, r.complete);
}

test "frameNextUnit: need_more until boundary appears" {
    const partial = "x = 1\n";
    try testing.expect(frameNextUnit(partial, false) == .need_more);
    try testing.expect(frameNextUnit(partial, true) == .complete);
}

// --- Gate F: materialize + ValueStream value composition -------------------

/// Drive a `ValueStream` of the given shape over `src` (fixed reader) and
/// collect every yielded Value into `arena` (one shared arena, NOT reset per
/// call -- the test inspects all results together). Returns the slice.
fn collectStream(gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8, shape: ValueStream.Shape) StreamError![]Value {
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(gpa, &r, .{}, shape);
    defer vs.deinit();
    var out: std.ArrayList(Value) = .empty;
    while (try vs.next(arena)) |val| try out.append(arena, val);
    return out.toOwnedSlice(arena);
}

/// The `whole`-shape Value over a battery of documents MUST equal the buffered
/// parse. This is the strongest anchor: if the streamed reconstruction is
/// sound, `whole == buffered`.
const compose_cases = [_][]const u8{
    "x = 1\ny = 2\n",
    "title = \"TOML\"\ncount = 42\n",
    "[a]\nx = 1\n[b]\ny = 2\n",
    "[[users]]\nname = \"alice\"\n[[users]]\nname = \"bob\"\n",
    "[a.b]\nc = 1\n[a]\nd = 2\n",
    "top = 1\n[s]\nport = 8080\nhost = \"h\"\n",
    "[t]\narr = [1, 2, 3]\n",
    "[t]\nnested = { a = 1, b = 2 }\n",
    "[t]\nmixed = [ { x = 1 }, { x = 2 } ]\n",
    "[t]\nrows = [ [1, 2], [3, 4] ]\n",
    "[nums]\ni = 42\nf = 3.14\ns = \"hi\"\nb = true\nd = 1979-05-27\n",
    "[a.b.c]\nx = 1\n",
    "[srv]\nopts = { tls = true, ports = [80, 443] }\n",
    "[[p]]\nk = 1\n[[p]]\nk = 2\n[[p]]\nk = 3\n",
    "root = 1\n[a]\nx = 1\n[a.b]\ny = 2\n[[c]]\nz = 3\n[[c]]\nz = 4\n",
    "[w]\na.b.c = 1\nd = 2\n",
    "[[w]]\na = 1\n[[w]]\nb = 2\n[w.c]\nq = 9\n",
};

test "gate F: whole-shape value equals buffered parse" {
    for (compose_cases) |src| {
        var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer buf_arena.deinit();
        var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer str_arena.deinit();

        const buffered = try parseBuffered(buf_arena.allocator(), src);
        const got = try collectStream(testing.allocator, str_arena.allocator(), src, .whole);
        try testing.expectEqual(@as(usize, 1), got.len);
        testing.expect(Value.eql(buffered, got[0])) catch |e| {
            std.debug.print("gate F whole mismatch on:\n{s}\n", .{src});
            return e;
        };
    }
}

test "gate F: whole-shape yields exactly one Value then null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r: std.Io.Reader = .fixed("[a]\nx = 1\n[b]\ny = 2\n");
    var vs = ValueStream.fromReader(testing.allocator, &r, .{}, .whole);
    defer vs.deinit();
    try testing.expect((try vs.next(arena.allocator())) != null);
    try testing.expect((try vs.next(arena.allocator())) == null);
    try testing.expect((try vs.next(arena.allocator())) == null);
}

test "gate F: tables-shape re-merged equals buffered, each unit equals its subtree" {
    // Re-merge the per-unit Values back into one tree and compare to buffered.
    for (compose_cases) |src| {
        var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer buf_arena.deinit();
        var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer str_arena.deinit();
        const a = str_arena.allocator();

        const buffered = try parseBuffered(buf_arena.allocator(), src);

        // Drive `tables` and re-merge using the header path captured per unit.
        var r: std.Io.Reader = .fixed(src);
        var er = EventReader.fromReader(testing.allocator, &r, .{});
        defer er.deinit();
        var root: Value = .makeTable();
        while (try er.next()) |ev| {
            switch (ev.kind) {
                .end_of_input => break,
                .table_header => |h| {
                    const path = try a.dupe(u8, h);
                    const leaf = try er.materialize(a);
                    try mergeUnit(a, &root, path, false, leaf);
                },
                .array_of_tables_header => |h| {
                    const path = try a.dupe(u8, h);
                    const leaf = try er.materialize(a);
                    try mergeUnit(a, &root, path, true, leaf);
                },
                else => {
                    const leaf = try er.composeCurrentUnit(a);
                    try mergeTableEntries(a, &root.table, leaf.table);
                },
            }
        }
        testing.expect(Value.eql(buffered, root)) catch |e| {
            std.debug.print("gate F tables re-merge mismatch on:\n{s}\n", .{src});
            return e;
        };
    }
}

test "gate F: tables-shape leaf equals buffered immediate subtree" {
    // A document whose units have unambiguous leaves (no later-header merge).
    const src = "root = 1\n[a]\nx = 1\ny = 2\n[b]\nz = 3\n";
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    const vals = try collectStream(testing.allocator, str_arena.allocator(), src, .tables);
    try testing.expectEqual(@as(usize, 3), vals.len);

    // Unit 0: leading root keys.
    try testing.expectEqual(@as(i64, 1), vals[0].get("root").?.integer);
    try testing.expect(vals[0].get("a") == null);
    // Unit 1: [a] -> { x = 1, y = 2 }.
    try testing.expectEqual(@as(i64, 1), vals[1].get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), vals[1].get("y").?.integer);
    // Unit 2: [b] -> { z = 3 }.
    try testing.expectEqual(@as(i64, 3), vals[2].get("z").?.integer);
}

test "gate F: array_of_tables-shape yields one Value per [[x]] element only" {
    const src = "lead = 0\n[plain]\np = 1\n[[r]]\na = 1\n[[r]]\na = 2\n[other]\nq = 9\n[[r]]\na = 3\n";
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    const vals = try collectStream(testing.allocator, str_arena.allocator(), src, .array_of_tables);
    try testing.expectEqual(@as(usize, 3), vals.len);
    try testing.expectEqual(@as(i64, 1), vals[0].get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), vals[1].get("a").?.integer);
    try testing.expectEqual(@as(i64, 3), vals[2].get("a").?.integer);
}

test "gate F: array_of_tables-shape i-th element equals buffered i-th element" {
    const src = "[[r]]\nname = \"a\"\nv = 1\n[[r]]\nname = \"b\"\nv = 2\n[[r]]\nname = \"c\"\nv = 3\n";
    var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer buf_arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();

    const buffered = try parseBuffered(buf_arena.allocator(), src);
    const vals = try collectStream(testing.allocator, str_arena.allocator(), src, .array_of_tables);
    const arr = buffered.get("r").?.array;
    try testing.expectEqual(arr.items.len, vals.len);
    for (arr.items, vals) |buf_elem, got| {
        try testing.expect(Value.eql(buf_elem, got));
    }
}

test "gate F: materialize requires a header position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r: std.Io.Reader = .fixed("[a]\nx = 1\ny = 2\n[b]\nz = 3\n");
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();

    // Before any next(): not at a header.
    try testing.expectError(error.MaterializeNotAtHeader, er.materialize(arena.allocator()));

    // First next() is the [a] header: materialize is valid here.
    const e0 = (try er.next()).?;
    try testing.expect(e0.kind == .table_header);
    const av = try er.materialize(arena.allocator());
    try testing.expectEqual(@as(i64, 1), av.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), av.get("y").?.integer);

    // After materialize, the stream continues at the [b] header.
    const e1 = (try er.next()).?;
    try testing.expect(e1.kind == .table_header);
    try testing.expectEqualStrings("b", e1.kind.table_header);

    // Mid-unit (right after a key event): not at a header.
    const e2 = (try er.next()).?;
    try testing.expect(e2.kind == .key);
    try testing.expectError(error.MaterializeNotAtHeader, er.materialize(arena.allocator()));
}

test "gate F: materialized Value survives advancing past later units" {
    // The clone lands in the CALLER arena, so it must stay readable after the
    // reader's per-unit arena is reset many times.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(src_arena.allocator(), "[first]\nkeep = \"hello\"\n");
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        try src.print(src_arena.allocator(), "[t{d}]\nk = {d}\n", .{ i, i });
    }

    var r: std.Io.Reader = .fixed(src.items);
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();

    const e0 = (try er.next()).?;
    try testing.expect(e0.kind == .table_header);
    const first = try er.materialize(a);

    // Drain the rest of the stream (resets the per-unit arena ~200 times).
    while (try er.next()) |ev| {
        if (ev.kind == .end_of_input) break;
    }

    // `first` must still be intact.
    try testing.expectEqualStrings("hello", first.get("keep").?.string);
}

test "gate F: bounded memory over 10k array-of-tables elements" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        try src.print(src_arena.allocator(), "[[r]]\nidx = {d}\nname = \"row-{d}\"\n", .{ i, i });
    }

    var r: std.Io.Reader = .fixed(src.items);
    var vs = ValueStream.fromReader(testing.allocator, &r, .{}, .array_of_tables);
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    var count: usize = 0;
    while (true) {
        _ = item_arena.reset(.retain_capacity);
        const val = (try vs.next(item_arena.allocator())) orelse break;
        try testing.expectEqual(@as(i64, @intCast(count)), val.get("idx").?.integer);
        count += 1;
        // The internal buffer stays proportional to the read-chunk size plus
        // one unit, NOT to N. 10k units at ~30 bytes each would be ~300 KB if
        // the whole stream were retained; the bound below (chunk 4096 + slack)
        // proves it is not.
        try testing.expect(vs.er.bufCapacity() <= 2 * EventReader.chunk);
    }
    try testing.expectEqual(@as(usize, 10_000), count);
}

test "gate F: error policy matches EventReader (sink continues, no sink terminal)" {
    // A malformed middle unit. With an errors sink, the stream surfaces an
    // error but keeps going; without one, the first error is terminal.
    const src = "[ok]\nx = 1\n[bad]\nk = = =\n[after]\ny = 2\n";

    // With a sink: malformed unit errors, stream continues to [after].
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var errors: std.ArrayList(Diagnostic) = .empty;
        defer errors.deinit(testing.allocator);
        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(testing.allocator, &r, .{ .errors = &errors }, .tables);
        defer vs.deinit();

        const v0 = (try vs.next(a)).?;
        try testing.expectEqual(@as(i64, 1), v0.get("x").?.integer);
        try testing.expectError(error.TomlParseError, vs.next(a));
        const v2 = (try vs.next(a)).?;
        try testing.expectEqual(@as(i64, 2), v2.get("y").?.integer);
        try testing.expect((try vs.next(a)) == null);
    }

    // Without a sink: the first error is terminal.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(testing.allocator, &r, .{}, .tables);
        defer vs.deinit();

        const v0 = (try vs.next(a)).?;
        try testing.expectEqual(@as(i64, 1), v0.get("x").?.integer);
        try testing.expectError(error.TomlParseError, vs.next(a));
    }
}

/// Drive a `ValueStream` of `shape` over a 1-byte-per-read reader, collecting
/// every yielded Value into `arena`.
fn collectStreamChunked(gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8, shape: ValueStream.Shape) StreamError![]Value {
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, 1, &rbuf);
    var vs = ValueStream.fromReader(gpa, &cr.reader, .{}, shape);
    defer vs.deinit();
    var out: std.ArrayList(Value) = .empty;
    while (try vs.next(arena)) |val| try out.append(arena, val);
    return out.toOwnedSlice(arena);
}

test "gate F: 1-byte-chunk equivalence for every shape" {
    for (compose_cases) |src| {
        inline for ([_]ValueStream.Shape{ .tables, .array_of_tables, .whole }) |shape| {
            var whole_arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer whole_arena.deinit();
            var chunk_arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer chunk_arena.deinit();

            const whole_vals = try collectStream(testing.allocator, whole_arena.allocator(), src, shape);
            const chunk_vals = try collectStreamChunked(testing.allocator, chunk_arena.allocator(), src, shape);

            try testing.expectEqual(whole_vals.len, chunk_vals.len);
            for (whole_vals, chunk_vals) |w, c| {
                testing.expect(Value.eql(w, c)) catch |e| {
                    std.debug.print("gate F chunk mismatch (shape={s}) on:\n{s}\n", .{ @tagName(shape), src });
                    return e;
                };
            }
        }
    }
}

test "gate F: materialize guard stays truthful after a bare header then a skipped unit" {
    // A BARE header unit (header with no key-values) leaves the reader with
    // `at_header` true momentarily; once drained and the FOLLOWING unit fails
    // on the sink-recovery path, `cur_leaf` is null. The guard must reject
    // `materialize` here instead of dereferencing a null `cur_leaf`. Covers
    // both a leading `[[w]]` and a leading `[t]` bare header.
    const cases = [_][]const u8{
        "[[w]]\n[bad]\nk = = =\n[after]\ny=2\n",
        "[t]\n[bad]\nk = = =\n",
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var errors: std.ArrayList(Diagnostic) = .empty;
        defer errors.deinit(testing.allocator);

        var r: std.Io.Reader = .fixed(src);
        var er = EventReader.fromReader(testing.allocator, &r, .{ .errors = &errors });
        defer er.deinit();

        // Drain until the failing unit surfaces its (recovered) error.
        while (true) {
            const ev = er.next() catch |e| {
                try testing.expectEqual(error.TomlParseError, e);
                break;
            };
            if (ev) |_| continue else unreachable;
        }

        // The bad unit is gone; the reader is not at a header. The guard must
        // return the error, NOT panic on a null `cur_leaf`.
        try testing.expectError(error.MaterializeNotAtHeader, er.materialize(a));
        try testing.expect(errors.items.len > 0);
    }
}

test "gate F: whole-shape recovers valid units past a skipped malformed unit" {
    // A mid-stream malformed unit between two valid header units. With a sink,
    // `whole` must drain the WHOLE stream, drop only the bad unit (forwarding
    // its diagnostic), and still merge `[a]` and `[c]` into the returned tree.
    const src = "[a]\nx=1\n[bad]\nk = = =\n[c]\ny=2\n";

    // With a sink: best-effort partial tree holds the valid units.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var errors: std.ArrayList(Diagnostic) = .empty;
        defer errors.deinit(testing.allocator);

        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(testing.allocator, &r, .{ .errors = &errors }, .whole);
        defer vs.deinit();

        const root = (try vs.next(a)).?;
        try testing.expectEqual(@as(i64, 1), root.get("a").?.get("x").?.integer);
        try testing.expectEqual(@as(i64, 2), root.get("c").?.get("y").?.integer);
        try testing.expect(root.get("bad") == null);
        try testing.expect(errors.items.len > 0);
        // Exactly one tree, then null.
        try testing.expect((try vs.next(a)) == null);
    }

    // Without a sink: the first error is terminal, no tree is produced.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(testing.allocator, &r, .{}, .whole);
        defer vs.deinit();

        try testing.expectError(error.TomlParseError, vs.next(a));
    }
}

test "stream: diagnostic borrowed fields survive continuing past an error" {
    // The failing unit's diagnostic carries a suggestion ("flase" -> false).
    // After the stream continues (per-unit arena reset + later units parsed
    // over the reclaimed memory), every field of both the sink entry and
    // `diagnostic()` must still read back intact.
    const src =
        "[a]\nx = flase\n" ++
        "[b]\ny = \"a fairly long replacement string to reuse arena memory\"\n" ++
        "z = \"another fairly long replacement string to reuse arena memory\"\n";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var errors: std.ArrayList(Diagnostic) = .empty;
    defer errors.deinit(testing.allocator);

    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .errors = &errors }, .tables);
    defer vs.deinit();

    try testing.expectError(error.TomlParseError, vs.next(a));
    // Drain the rest of the stream so later units churn the unit arena.
    const v1 = (try vs.next(a)).?;
    try testing.expect(v1.get("y") != null);
    try testing.expect((try vs.next(a)) == null);

    try testing.expectEqual(@as(usize, 1), errors.items.len);
    for ([_]Diagnostic{ errors.items[0], vs.diagnostic().? }) |d| {
        try testing.expectEqualStrings("invalid value `flase`", d.message);
        try testing.expectEqualStrings("false", d.suggestion.?);
        try testing.expect(d.path == null);
        try testing.expectEqual(@as(usize, 0), d.notes.len);
        // Absolute stream offsets: the bad value sits past the [a] header.
        try testing.expect(d.span.start >= 8);
        try testing.expect(d.span.end <= src.len);
    }
}

/// Reader that fails its first stream() call and reports end-of-stream after.
/// The bounded shape matters for the regression test below: an error-swallowing
/// retry loop TERMINATES (with a wrong success) instead of hanging.
const FailOnceReader = struct {
    failed: bool = false,
    reader: std.Io.Reader,

    fn init(buffer: []u8) FailOnceReader {
        return .{ .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        const self: *FailOnceReader = @fieldParentPtr("reader", io_r);
        if (!self.failed) {
            self.failed = true;
            return error.ReadFailed;
        }
        return error.EndOfStream;
    }
};

test "stream: whole shape propagates reader failure even with a sink" {
    // Only unit-level parse errors are recoverable with a sink; a reader
    // failure consumes no input and must propagate. If a regression swallows
    // it, FailOnceReader's follow-up EOF makes next() return a bogus empty
    // tree, which fails the assertion (bounded: no infinite retry loop).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errors: std.ArrayList(Diagnostic) = .empty;
    defer errors.deinit(testing.allocator);

    var rbuf: [64]u8 = undefined;
    var fr = FailOnceReader.init(&rbuf);
    var vs = ValueStream.fromReader(testing.allocator, &fr.reader, .{ .errors = &errors }, .whole);
    defer vs.deinit();

    try testing.expectError(error.ReadFailed, vs.next(arena.allocator()));
}

// --- Gate G: T-T1 resumable framing ------------------------------------------

test "T-T1: 2 MiB single-unit input completes (O(N) framing regression)" {
    // A unit with no headers; the whole input is one frame. With O(N^2)
    // scanning this would time out; with the resumable tokenizer it is
    // instant. Completing under zig build test's default timeout IS the
    // assertion.
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (src.items.len < 2 * 1024 * 1024) : (i += 1) {
        try src.print(a, "k{d} = {d}\n", .{ i, i });
    }

    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    const v = try reassemble(testing.allocator, str_arena.allocator(), src.items);
    // Spot-check: key 0 exists and has value 0.
    try testing.expectEqual(@as(i64, 0), v.get("k0").?.integer);
}

test "T-T1: unit exceeding max_unit_bytes returns LineTooLong (not a hang)" {
    // Feed enough key-value lines to exceed max_unit_bytes in a single unit
    // (no headers). The framer must return error.LineTooLong instead of
    // looping indefinitely or running out of memory.
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    while (src.items.len <= max_unit_bytes) {
        try src.appendSlice(a, "k = 1\n");
    }

    var r: std.Io.Reader = .fixed(src.items);
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();
    try testing.expectError(error.LineTooLong, er.next());
}

// --- Gate H: T-T2 per-event comment reset ------------------------------------

test "T-T2: each event's comment reflects only its own line" {
    // First key has a trailing comment; second key does not.
    // The second key event must carry an empty comment, not the first's.
    const src = "x = 1  # first comment\ny = 2\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();

    // key "x"
    const kx = (try er.next()).?;
    try testing.expect(kx.kind == .key);
    try testing.expectEqualStrings("x", kx.kind.key);
    try testing.expectEqualStrings("# first comment", kx.comment);

    // value 1
    _ = try er.next();

    // key "y" - must NOT carry forward "# first comment"
    const ky = (try er.next()).?;
    try testing.expect(ky.kind == .key);
    try testing.expectEqualStrings("y", ky.kind.key);
    try testing.expectEqualStrings("", ky.comment);
}

test "T-T2: header trailing comment is attached to header event" {
    const src = "[section]  # header comment\nk = 1\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();

    const hev = (try er.next()).?;
    try testing.expect(hev.kind == .table_header);
    try testing.expectEqualStrings("# header comment", hev.comment);

    // key event has no comment
    const kev = (try er.next()).?;
    try testing.expect(kev.kind == .key);
    try testing.expectEqualStrings("", kev.comment);
}

// --- Gate I: T-T3 real header and key spans ----------------------------------

test "T-T3: header event span covers [section] bytes; key event span covers key bytes" {
    const src = "[section]\nkey = 42\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();

    // Header event
    const hev = (try er.next()).?;
    try testing.expect(hev.kind == .table_header);
    try testing.expect(hev.span.start < hev.span.end);
    try testing.expectEqualStrings("[section]", src[@intCast(hev.span.start)..@intCast(hev.span.end)]);
    try testing.expectEqual(@as(u32, 1), hev.span.lineCol(src).line);

    // Key event
    const kev = (try er.next()).?;
    try testing.expect(kev.kind == .key);
    try testing.expect(kev.span.start < kev.span.end);
    try testing.expectEqualStrings("key", src[@intCast(kev.span.start)..@intCast(kev.span.end)]);
    try testing.expectEqual(@as(u32, 2), kev.span.lineCol(src).line);
}

test "T-T3: array-of-tables header span is non-zero and on the right line" {
    const src = "[[items]]\nname = \"a\"\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();

    const hev = (try er.next()).?;
    try testing.expect(hev.kind == .array_of_tables_header);
    try testing.expect(hev.span.start < hev.span.end);
    try testing.expectEqualStrings("[[items]]", src[@intCast(hev.span.start)..@intCast(hev.span.end)]);
    try testing.expectEqual(@as(u32, 1), hev.span.lineCol(src).line);
}

// --- Gate J: tokens truncated across a pull boundary -------------------------
//
// A single `Tokenizer` is kept alive across `pull()` refills. A token that
// runs past the current buffer end (multi-line string, string, comment, long
// value) must resume the SAME scan after the next pull, never re-lexing its
// tail as fresh statements. These use inputs larger than one 4096-byte chunk
// so `pull()` (which aggregates to 4096 bytes) fires more than once. The
// oracle is the buffered `parser.parse` of the identical bytes.

test "gate J: multi-line basic string across pull boundaries equals buffered" {
    // ~15 KiB of interior content with line-leading `[header]`-looking and
    // `key = val`-looking lines plus adjacent quotes. Spans several pulls; a
    // non-resumable framer mis-lexes the interior (spurious boundary or a
    // swallowed real header). Streamed must equal buffered.
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (body.items.len < 15 * 1024) : (i += 1) {
        try body.print(a, "[not_a_section_{d}]\nkey{d} = val{d}\ntext \"q\" and \"\" pair {d}\n", .{ i, i, i, i });
    }
    var src: std.ArrayList(u8) = .empty;
    try src.print(a, "ml = \"\"\"\n{s}\"\"\"\n[after]\nk = 1\n", .{body.items});

    var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer buf_arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();

    const buffered = try parseBuffered(buf_arena.allocator(), src.items);
    const streamed = try reassemble(testing.allocator, str_arena.allocator(), src.items);
    try testing.expect(Value.eql(buffered, streamed));
    // The follow-on unit must not have been swallowed by the string.
    try testing.expectEqual(@as(i64, 1), streamed.get("after").?.get("k").?.integer);
}

test "gate J: multi-line literal string across pull boundaries equals buffered" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (body.items.len < 15 * 1024) : (i += 1) {
        try body.print(a, "# comment-ish {d}\n[bracket_{d}]\nval {d}\n", .{ i, i, i });
    }
    var src: std.ArrayList(u8) = .empty;
    try src.print(a, "ml = '''\n{s}'''\n[after]\nk = 2\n", .{body.items});

    var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer buf_arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();

    const buffered = try parseBuffered(buf_arena.allocator(), src.items);
    const streamed = try reassemble(testing.allocator, str_arena.allocator(), src.items);
    try testing.expect(Value.eql(buffered, streamed));
    try testing.expectEqual(@as(i64, 2), streamed.get("after").?.get("k").?.integer);
}

test "gate J: closing triple-quote straddling the pull boundary equals buffered" {
    // Sweep the body length so the closing `"""` lands at every offset around
    // the 4096-byte pull boundary (start of triple, middle, after), exercising
    // resume both mid-`"""` and in the single-vs-multi-line classification.
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var blen: usize = 4080;
    while (blen <= 4112) : (blen += 1) {
        const bod = try a.alloc(u8, blen);
        @memset(bod, 'a');
        var src: std.ArrayList(u8) = .empty;
        try src.print(a, "ml = \"\"\"{s}\"\"\"\n[after]\nk = 3\n", .{bod});

        var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer buf_arena.deinit();
        var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer str_arena.deinit();

        const buffered = try parseBuffered(buf_arena.allocator(), src.items);
        const streamed = try reassemble(testing.allocator, str_arena.allocator(), src.items);
        testing.expect(Value.eql(buffered, streamed)) catch |e| {
            std.debug.print("gate J straddle mismatch at body len {d}\n", .{blen});
            return e;
        };
    }
}

test "gate J: unterminated multi-line string over 8 KiB errors (not LineTooLong, not a hang)" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "ml = \"\"\"\n");
    while (src.items.len < 10 * 1024) try src.appendSlice(a, "aaaaaaaa\n");
    // Deliberately no closing `"""`.

    // Buffered rejects with an unterminated-string error; streaming matches.
    var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer buf_arena.deinit();
    try testing.expectError(error.TomlParseError, parseBuffered(buf_arena.allocator(), src.items));

    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();
    try testing.expectError(error.TomlParseError, reassemble(testing.allocator, str_arena.allocator(), src.items));
}

test "gate J: 256 KiB multi-line string with interior brackets equals buffered (O(N))" {
    // A single ~256 KiB multi-line string whose every line is `[header]`-like.
    // Completing well within the test timeout is the O(N) guard: resuming the
    // one giant token per pull must not re-scan it from the start.
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (body.items.len < 256 * 1024) : (i += 1) {
        try body.print(a, "[interior_{d}] line with brackets and key{d} = {d}\n", .{ i, i, i });
    }
    var src: std.ArrayList(u8) = .empty;
    try src.print(a, "big = \"\"\"\n{s}\"\"\"\n[tail]\nn = 7\n", .{body.items});

    var buf_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer buf_arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer str_arena.deinit();

    const buffered = try parseBuffered(buf_arena.allocator(), src.items);
    const streamed = try reassemble(testing.allocator, str_arena.allocator(), src.items);
    try testing.expect(Value.eql(buffered, streamed));
    try testing.expectEqual(@as(i64, 7), streamed.get("tail").?.get("n").?.integer);
}

