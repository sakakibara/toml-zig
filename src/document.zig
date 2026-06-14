//! Document model for TOML  -  lossless parse, edit, and emit.
//!
//! Unlike `toml.parse`, which throws away comments, formatting, and
//! original byte representations, `Document.parse` keeps the input as a
//! sequence of `Item`s (blank lines, comments, headers, key-value pairs).
//! Emitting an unmodified `Document` reproduces the input byte-for-byte.
//!
//! All allocations go through the arena passed to `parse`; calling
//! `arena.deinit()` releases everything. There is no `Document.deinit`.
//!
//! ```zig
//! var doc = try toml.Document.parse(arena, src, .{});
//!
//! // Read existing values
//! const port = doc.get("server.port").?.integer;
//!
//! // Edit existing
//! try doc.setLiteral("server.port", "9999");
//!
//! // Insert new key (appended to its enclosing section)
//! try doc.setLiteral("server.tls", "true");
//!
//! // Remove
//! try doc.remove("dev.unused");
//!
//! // Emit
//! var aw: Io.Writer.Allocating = .init(gpa);
//! defer aw.deinit();
//! try doc.emit(&aw.writer);
//! ```
//!
//! Editing notes:
//! - Sub-keys inside inline tables are editable: setting `point.x` when
//!   `point = { x = 1, y = 2 }` exists rewrites the inline table in
//!   place, preserving the original interior whitespace and key order.
//!   Inserting a new sub-key matches the surrounding style (one-line
//!   tight, one-line loose, or multi-line) by examining adjacent
//!   entries' trailing bytes.
//!   The surrounding document (other lines, comments, header order) is
//!   untouched.
//! - Setting a key whose enclosing section header does not yet exist
//!   appends the header and the new key at the end of the document.
//! - Adding a new key to an existing section appends it as the last
//!   entry of that section; surrounding formatting (other keys,
//!   blank lines, comments) is preserved.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.array_hash_map.String;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const testing = std.testing;

const value_mod = @import("value.zig");
const parser_mod = @import("parser.zig");
const encoder = @import("encoder.zig");
const Value = value_mod.Value;
const Span = value_mod.Span;

pub const Error = error{
    PathNotFound,
    PathExists,
    InvalidValue,
    OutOfMemory,
    WriteFailed,
    TomlParseError,
    NestingTooDeep,
};

/// One source-level construct in the document.
pub const Item = union(enum) {
    /// Blank line (just whitespace + newline).
    blank: []const u8,
    /// A comment line (may have leading whitespace before `#`).
    comment: []const u8,
    /// `[header]` or `[[array.header]]` line.
    header: Header,
    /// `key = value` line, possibly with multi-line value or trailing comment.
    kv: KeyValue,

    pub fn rawBytes(self: Item) []const u8 {
        return switch (self) {
            .blank => |b| b,
            .comment => |c| c,
            .header => |h| h.raw,
            .kv => |k| k.raw,
        };
    }
};

pub const Header = struct {
    /// The full source line (including trailing newline).
    raw: []const u8,
    /// Resolved dotted path (e.g., "server.tls").
    path: []const u8,
    /// True for `[[array]]`, false for `[table]`.
    is_array: bool,
};

/// Structured layout of a TOML inline table, preserving original
/// whitespace and punctuation byte-for-byte.
const InlineTableLayout = struct {
    /// Bytes from `{` through any leading interior whitespace before
    /// the first entry's key. For an empty `{}`, this includes just
    /// the open brace plus any interior ws (typically empty).
    open: []const u8,

    entries: std.ArrayList(InlineEntry),

    /// Bytes from the trailing edge of the last entry through `}`. For
    /// an empty inline table `{}`, `open` is `{` and `close` is `}`; for
    /// `{ }`, `open` is `{ ` and `close` is `}`.
    close: []const u8,
};

/// One key-value pair inside an inline table, with surrounding whitespace
/// and punctuation preserved verbatim.
const InlineEntry = struct {
    /// Raw bytes of the key: bare, basic-quoted, or literal-quoted.
    key_raw: []const u8,

    /// Key name with outer quotes stripped for quoted keys. Bare and
    /// literal-quoted keys are byte-exact; basic-quoted keys with escape
    /// sequences (e.g., `"a\tb"`) retain the escape bytes uninterpreted.
    /// For programmatic path lookup, callers using escape-bearing basic
    /// keys must compare against the same escaped form.
    key: []const u8,

    /// Bytes between key and value: `=` plus its surrounding spaces.
    sep: []const u8,

    value: InlineValue,

    /// Bytes after the value, including the trailing comma (or none
    /// for the last entry without trailing comma), inline trailing
    /// comment, and whitespace up to the next entry's key or to
    /// `close`'s start.
    trailing: []const u8,
};

/// The value of an InlineEntry: either opaque scalar/array bytes
/// (not further structured) or a recursive inline-table layout.
const InlineValue = union(enum) {
    /// Opaque value bytes -- anything that isn't an inline table.
    raw: []const u8,

    /// Nested inline-table layout. Edits descend recursively.
    inline_table: *InlineTableLayout,
};

pub const KeyValue = struct {
    /// Full source bytes (key + `=` + value + any trailing comment + newline).
    raw: []const u8,
    /// Full path resolved against the enclosing header.
    full_path: []const u8,
    /// Byte offset within `raw` where the value text starts.
    value_offset: u32,
    /// Length of the value text inside `raw`.
    value_len: u32,
    /// Structured layout when the value at value_offset is an inline
    /// table. Null otherwise. Owned by the document's arena.
    inline_layout: ?*InlineTableLayout = null,
};

pub const Document = struct {
    pub const Position = enum { before, after };

    arena: Allocator,
    source: []const u8,
    items: ArrayList(Item),
    /// Path -> item index for O(1) lookup of kv pairs.
    kv_index: StringArrayHashMap(usize),
    /// Header path -> item index of last kv in that section (or header
    /// itself if section is empty). Used to append new keys.
    section_end: StringArrayHashMap(usize),
    parsed: Value,

    pub fn parse(arena: Allocator, input: []const u8, options: parser_mod.ParseOptions) !Document {
        const source = try arena.dupe(u8, input);
        var doc: Document = .{
            .arena = arena,
            .source = source,
            .items = .empty,
            .kv_index = .empty,
            .section_end = .empty,
            .parsed = undefined,
        };
        try tokenize(&doc, source);
        // Cross-check by running the strict parser; this also gives us
        // the parsed Value tree for `get` queries.
        doc.parsed = try parser_mod.parse(arena, source, options);
        return doc;
    }

    /// Look up a value by dotted path. Returns null if absent.
    pub fn get(self: *const Document, path: []const u8) ?Value {
        return self.parsed.get(path);
    }

    /// Convenience: `self.get(path) != null`.
    pub fn has(self: *const Document, path: []const u8) bool {
        return self.get(path) != null;
    }

    /// Typed read by dotted path. Returns null on missing path, traversal
    /// through a non-table, type mismatch, or integer overflow. See
    /// Value.getT for the supported type set.
    pub fn getT(self: *const Document, comptime T: type, path: []const u8) ?T {
        return self.parsed.getT(T, path);
    }

    /// Set `path` to literal TOML source. `raw` must be a well-formed value
    /// literal (e.g. `"\"x\""`, `42`, `true`, `[1, 2]`, `{ x = 1 }`). The
    /// library validates by re-parsing; on failure returns InvalidValue.
    /// Use `set` (comptime-dispatched) for native values; this is the escape
    /// hatch for splicing in already-formatted TOML source.
    pub fn setLiteral(self: *Document, path: []const u8, raw: []const u8) Error!void {
        try validateValueLiteral(self.arena, raw);

        if (self.kv_index.get(path)) |idx| {
            return self.replaceValueAt(idx, raw);
        }

        // Walk up the path looking for an enclosing inline-table parent.
        if (try self.editInsideInlineTable(path, raw)) return;

        // Path doesn't match an existing kv or nest into one - append/create.
        return self.insertNewKey(path, raw);
    }

    fn replaceValueAt(self: *Document, idx: usize, raw_value: []const u8) Error!void {
        const old = self.items.items[idx].kv;
        const before = old.raw[0..old.value_offset];
        const after = old.raw[old.value_offset + old.value_len ..];
        const new_raw = try std.mem.concat(self.arena, u8, &.{ before, raw_value, after });
        const inline_layout: ?*InlineTableLayout = if (raw_value.len > 0 and raw_value[0] == '{')
            try parseInlineLayout(self.arena, raw_value)
        else
            null;
        self.items.items[idx] = .{ .kv = .{
            .raw = new_raw,
            .full_path = old.full_path,
            .value_offset = old.value_offset,
            .value_len = @intCast(raw_value.len),
            .inline_layout = inline_layout,
        } };
    }

    /// If `path` like `point.x` falls inside an existing inline-table
    /// value (`point = { x = 1, y = 2 }`), edit the sub-key in place
    /// using the in-memory layout (preserves original whitespace and
    /// key order). Returns true on success, false if no enclosing
    /// inline-table parent was found.
    fn editInsideInlineTable(self: *Document, path: []const u8, raw_value: []const u8) Error!bool {
        var dot_pos = path.len;
        while (true) {
            const dot = std.mem.lastIndexOfScalar(u8, path[0..dot_pos], '.') orelse return false;
            const parent_path = path[0..dot];
            const sub_path = path[dot + 1 ..];

            if (self.kv_index.get(parent_path)) |parent_idx| {
                if (self.items.items[parent_idx].kv.inline_layout) |layout| {
                    try setInLayout(self.arena, layout, sub_path, raw_value);
                    try self.rebuildInlineKv(parent_idx);
                    try self.refreshParsed();
                    return true;
                }
            }

            dot_pos = dot;
        }
    }

    fn insertNewKey(self: *Document, path: []const u8, raw_value: []const u8) Error!void {
        // Insert. Determine enclosing section.
        const enclosing = enclosingSection(path);
        {
            if (self.section_end.get(enclosing)) |after_idx| {
                // Ensure the preceding item ends with a newline so the
                // new line starts cleanly.
                try self.ensureItemEndsWithNewline(after_idx);

                // Append new kv right after the section's last item.
                const local_key = path[enclosing.len + (if (enclosing.len == 0) @as(usize, 0) else @as(usize, 1)) ..];
                const line = try formatKvLine(self.arena, local_key, raw_value);
                const value_offset: u32 = @intCast(local_key.len + " = ".len);
                const new_item: Item = .{ .kv = .{
                    .raw = line,
                    .full_path = try self.arena.dupe(u8, path),
                    .value_offset = value_offset,
                    .value_len = @intCast(raw_value.len),
                } };
                try self.items.insert(self.arena, after_idx + 1, new_item);
                self.shiftIndices(after_idx + 1, 1);
                try self.kv_index.put(self.arena, new_item.kv.full_path, after_idx + 1);
                try self.section_end.put(self.arena, enclosing, after_idx + 1);
            } else {
                // Section doesn't exist. Append a new header and the kv.
                if (enclosing.len == 0) {
                    // Root-level key but the document is empty  -  just append.
                    const line = try formatKvLine(self.arena, path, raw_value);
                    const value_offset: u32 = @intCast(path.len + " = ".len);
                    const new_item: Item = .{ .kv = .{
                        .raw = line,
                        .full_path = try self.arena.dupe(u8, path),
                        .value_offset = value_offset,
                        .value_len = @intCast(raw_value.len),
                    } };
                    try self.items.append(self.arena, new_item);
                    try self.kv_index.put(self.arena, new_item.kv.full_path, self.items.items.len - 1);
                    try self.section_end.put(self.arena, "", self.items.items.len - 1);
                } else {
                    try self.appendNewSection(enclosing);
                    try self.setLiteral(path, raw_value); // recurse now that section exists
                }
            }
            // Refresh parsed view. Cheaper than tracking incrementally.
            try self.refreshParsed();
        }
    }

    /// Set a value from a structured `Value`. Formats the value using the
    /// canonical encoder.
    pub fn setValue(self: *Document, path: []const u8, value: Value) Error!void {
        const raw = formatValue(self.arena, value) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
        try self.setLiteral(path, raw);
    }

    /// Headline setter. Comptime-dispatched on `@TypeOf(value)`:
    ///   - `Value`               -> setValue passthrough
    ///   - `Date` / `Time` / `DateTime` -> wrapped into the matching variant
    ///   - `bool`                -> .boolean
    ///   - integer types         -> .integer (overflow checked at comptime)
    ///   - float types           -> .float
    ///   - `[]const u8` or string literal (`*const [N:0]u8`) -> .string (arena-duped)
    /// Other types raise a compile error.
    pub fn set(self: *Document, path: []const u8, value: anytype) Error!void {
        const T = @TypeOf(value);
        const v = try valueFromAny(self.arena, T, value);
        return self.setValue(path, v);
    }

    /// Remove a key. Returns `error.PathNotFound` if absent.
    pub fn remove(self: *Document, path: []const u8) Error!void {
        if (self.kv_index.get(path)) |idx| {
            _ = self.items.orderedRemove(idx);
            _ = self.kv_index.swapRemove(path);
            self.shiftIndices(idx, -1);
            try self.refreshParsed();
            return;
        }

        if (try self.removeInsideInlineTable(path)) return;

        return error.PathNotFound;
    }

    fn removeInsideInlineTable(self: *Document, path: []const u8) Error!bool {
        var dot_pos = path.len;
        while (true) {
            const dot = std.mem.lastIndexOfScalar(u8, path[0..dot_pos], '.') orelse return false;
            const parent_path = path[0..dot];
            const sub_path = path[dot + 1 ..];

            if (self.kv_index.get(parent_path)) |parent_idx| {
                if (self.items.items[parent_idx].kv.inline_layout) |layout| {
                    if (try removeFromLayout(self.arena, layout, sub_path)) {
                        try self.rebuildInlineKv(parent_idx);
                        try self.refreshParsed();
                        return true;
                    }
                    return error.PathNotFound;
                }
            }

            dot_pos = dot;
        }
    }

    /// Write the (possibly modified) document.
    pub fn emit(self: *const Document, w: *Io.Writer) Io.Writer.Error!void {
        for (self.items.items) |item| {
            try w.writeAll(item.rawBytes());
        }
    }

    /// Insert a comment line immediately before the kv at `path`.
    /// `text` is the comment body without the leading `#` or trailing
    /// newline; both are added automatically.
    pub fn addCommentBefore(self: *Document, path: []const u8, text: []const u8) Error!void {
        const idx = self.kv_index.get(path) orelse return error.PathNotFound;
        const raw = try std.fmt.allocPrint(self.arena, "# {s}\n", .{text});
        try self.items.insert(self.arena, idx, .{ .comment = raw });
        self.shiftIndices(idx, 1);
    }

    /// Insert a comment line immediately after the kv at `path`.
    pub fn addCommentAfter(self: *Document, path: []const u8, text: []const u8) Error!void {
        const idx = self.kv_index.get(path) orelse return error.PathNotFound;
        try self.ensureItemEndsWithNewline(idx);
        const raw = try std.fmt.allocPrint(self.arena, "# {s}\n", .{text});
        try self.items.insert(self.arena, idx + 1, .{ .comment = raw });
        self.shiftIndices(idx + 1, 1);
    }

    /// Remove the comment line immediately preceding the kv at `path`,
    /// if there is one. No-op when the previous item isn't a comment.
    pub fn removeCommentBefore(self: *Document, path: []const u8) Error!void {
        const idx = self.kv_index.get(path) orelse return error.PathNotFound;
        if (idx == 0) return;
        const prev = self.items.items[idx - 1];
        if (prev != .comment) return;
        _ = self.items.orderedRemove(idx - 1);
        self.shiftIndices(idx - 1, -1);
    }

    /// Remove the comment line immediately following the kv at `path`,
    /// if there is one. No-op when the next item isn't a comment.
    pub fn removeCommentAfter(self: *Document, path: []const u8) Error!void {
        const idx = self.kv_index.get(path) orelse return error.PathNotFound;
        if (idx + 1 >= self.items.items.len) return;
        const next = self.items.items[idx + 1];
        if (next != .comment) return;
        _ = self.items.orderedRemove(idx + 1);
        self.shiftIndices(idx + 1, -1);
    }

    /// Set or replace the trailing comment on a kv line. Pass `null` to
    /// remove an existing trailing comment.
    pub fn setTrailingComment(self: *Document, path: []const u8, text: ?[]const u8) Error!void {
        const idx = self.kv_index.get(path) orelse return error.PathNotFound;
        const old = self.items.items[idx].kv;

        // Find the value end inside `raw`. The trailing-comment region
        // starts there.
        const value_end_in_raw = old.value_offset + old.value_len;
        const after_value = old.raw[value_end_in_raw..];

        // The line ending: the trailing region is "<whitespace>[# comment]<newline>".
        // Find where the newline is so we can rebuild.
        const nl = std.mem.indexOfScalar(u8, after_value, '\n') orelse after_value.len;
        const line_end = if (nl < after_value.len) "\n" else "";

        const new_tail = if (text) |t|
            try std.fmt.allocPrint(self.arena, "  # {s}{s}", .{ t, line_end })
        else
            try self.arena.dupe(u8, line_end);

        const new_raw = try std.mem.concat(self.arena, u8, &.{
            old.raw[0..value_end_in_raw],
            new_tail,
        });
        self.items.items[idx] = .{ .kv = .{
            .raw = new_raw,
            .full_path = old.full_path,
            .value_offset = old.value_offset,
            .value_len = old.value_len,
        } };
    }

    /// Move the section identified by `header_path` to a new position
    /// relative to `target_path`. The whole section block (header line
    /// plus all items up to but not including the next header or EOF)
    /// moves as a unit.
    pub fn moveSection(self: *Document, header_path: []const u8, where: Position, target_path: []const u8) Error!void {
        const src_start = findHeaderIndex(self.items.items, header_path) orelse return error.PathNotFound;
        const src_end = findSectionEnd(self.items.items, src_start);
        const dst_anchor = findHeaderIndex(self.items.items, target_path) orelse return error.PathNotFound;
        if (src_start == dst_anchor) return; // moving onto self
        const block = try self.arena.alloc(Item, src_end - src_start);
        @memcpy(block, self.items.items[src_start..src_end]);

        // Remove source block first.
        const removed_len = src_end - src_start;
        self.items.replaceRangeAssumeCapacity(src_start, removed_len, &.{});

        // Adjust dst_anchor for the removal.
        const adjusted_anchor = if (dst_anchor > src_start) dst_anchor - removed_len else dst_anchor;
        const dst_section_end = findSectionEnd(self.items.items, adjusted_anchor);
        const insert_at = switch (where) {
            .before => adjusted_anchor,
            .after => dst_section_end,
        };
        try self.items.insertSlice(self.arena, insert_at, block);

        // The shifts above invalidate kv_index/section_end; rebuild from scratch.
        try self.rebuildIndices();
    }

    fn rebuildIndices(self: *Document) !void {
        self.kv_index.clearRetainingCapacity();
        self.section_end.clearRetainingCapacity();
        for (self.items.items, 0..) |item, i| {
            switch (item) {
                .kv => |k| try self.kv_index.put(self.arena, k.full_path, i),
                .header => |h| try self.section_end.put(self.arena, h.path, i),
                else => {},
            }
        }
        // Re-apply the "section_end is the last kv (or header) of section" invariant
        // by walking forward and recording the last item per current section.
        var current_section: []const u8 = "";
        for (self.items.items, 0..) |item, i| {
            switch (item) {
                .header => |h| {
                    current_section = h.path;
                    try self.section_end.put(self.arena, current_section, i);
                },
                .kv => try self.section_end.put(self.arena, current_section, i),
                else => {},
            }
        }
    }

    fn ensureItemEndsWithNewline(self: *Document, idx: usize) !void {
        const item = self.items.items[idx];
        const raw = item.rawBytes();
        if (raw.len > 0 and raw[raw.len - 1] == '\n') return;
        const new_raw = try std.mem.concat(self.arena, u8, &.{ raw, "\n" });
        switch (item) {
            .blank => self.items.items[idx] = .{ .blank = new_raw },
            .comment => self.items.items[idx] = .{ .comment = new_raw },
            .header => |h| self.items.items[idx] = .{ .header = .{ .raw = new_raw, .path = h.path, .is_array = h.is_array } },
            .kv => |k| self.items.items[idx] = .{ .kv = .{
                .raw = new_raw,
                .full_path = k.full_path,
                .value_offset = k.value_offset,
                .value_len = k.value_len,
            } },
        }
    }

    fn shiftIndices(self: *Document, from_idx: usize, delta: isize) void {
        var it = self.kv_index.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* >= from_idx) {
                if (delta < 0) {
                    e.value_ptr.* -= @intCast(-delta);
                } else {
                    e.value_ptr.* += @intCast(delta);
                }
            }
        }
        var sit = self.section_end.iterator();
        while (sit.next()) |e| {
            if (e.value_ptr.* >= from_idx) {
                if (delta < 0) {
                    e.value_ptr.* -= @intCast(-delta);
                } else {
                    e.value_ptr.* += @intCast(delta);
                }
            }
        }
    }

    fn appendNewSection(self: *Document, header_path: []const u8) !void {
        const needs_blank = self.items.items.len > 0 and !endsWithBlank(self.items.items);
        if (needs_blank) {
            try self.items.append(self.arena, .{ .blank = "\n" });
        }
        const raw = try std.fmt.allocPrint(self.arena, "[{s}]\n", .{header_path});
        const header_item: Item = .{ .header = .{
            .raw = raw,
            .path = try self.arena.dupe(u8, header_path),
            .is_array = false,
        } };
        try self.items.append(self.arena, header_item);
        try self.section_end.put(self.arena, header_item.header.path, self.items.items.len - 1);
    }

    fn rebuildInlineKv(self: *Document, idx: usize) Error!void {
        const layout = self.items.items[idx].kv.inline_layout orelse return;

        var aw: std.Io.Writer.Allocating = .init(self.arena);
        defer aw.deinit();
        try writeLayout(layout, &aw.writer);
        const new_value_bytes = try self.arena.dupe(u8, aw.written());

        const kv = self.items.items[idx].kv;
        const before = kv.raw[0..kv.value_offset];
        const after = kv.raw[kv.value_offset + kv.value_len ..];
        const new_raw = try std.mem.concat(self.arena, u8, &.{ before, new_value_bytes, after });

        self.items.items[idx].kv.raw = new_raw;
        self.items.items[idx].kv.value_len = @intCast(new_value_bytes.len);
        // inline_layout pointer stays the same -- it was mutated in place.
    }

    fn refreshParsed(self: *Document) !void {
        var aw: Io.Writer.Allocating = .init(self.arena);
        defer aw.deinit();
        try self.emit(&aw.writer);
        const new_src = aw.written();
        // Reparse for the next get(); this reuses the user's arena. The
        // old parsed tree becomes inert (still in the arena, just not
        // referenced by the Document).
        self.parsed = try parser_mod.parse(self.arena, new_src, .{});
    }
};

fn findHeaderIndex(items: []const Item, path: []const u8) ?usize {
    for (items, 0..) |item, i| {
        if (item == .header and std.mem.eql(u8, item.header.path, path)) return i;
    }
    return null;
}

fn findSectionEnd(items: []const Item, header_idx: usize) usize {
    var i = header_idx + 1;
    while (i < items.len and items[i] != .header) : (i += 1) {}
    return i;
}

fn endsWithBlank(items: []const Item) bool {
    if (items.len == 0) return true;
    return switch (items[items.len - 1]) {
        .blank => true,
        else => false,
    };
}

fn enclosingSection(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |i| {
        return path[0..i];
    }
    return "";
}

fn formatKvLine(arena: Allocator, key: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s} = {s}\n", .{ key, value });
}

fn formatValue(arena: Allocator, value: Value) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try writeInlineValue(&aw.writer, value);
    return arena.dupe(u8, aw.written());
}

fn writeInlineValue(w: *Io.Writer, value: Value) Io.Writer.Error!void {
    encoder.writeInlineValue(w, value) catch |err| switch (err) {
        // encoder.writeInlineValue delegates to writeValue, which never allocates
        // and never rejects on type - these branches are unreachable.
        error.ExpectedTable, error.OutOfMemory => unreachable,
        else => |e| return e,
    };
}

fn validateValueLiteral(arena: Allocator, raw: []const u8) Error!void {
    const wrapped = std.fmt.allocPrint(arena, "_v = {s}", .{raw}) catch return error.OutOfMemory;
    _ = parser_mod.parse(arena, wrapped, .{}) catch return error.InvalidValue;
}

/// Mutate the layout in place: locate the entry matching sub_path's
/// head, descend recursively for nested inline tables, replace the
/// leaf entry's value bytes with raw_value. Errors on a sub-path
/// through a scalar.
fn setInLayout(arena: Allocator, layout: *InlineTableLayout, sub_path: []const u8, raw_value: []const u8) Error!void {
    const dot = std.mem.indexOfScalar(u8, sub_path, '.');
    const head = if (dot) |d| sub_path[0..d] else sub_path;
    const tail = if (dot) |d| sub_path[d + 1 ..] else "";

    for (layout.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, head)) {
            if (tail.len == 0) {
                entry.value = .{ .raw = try arena.dupe(u8, raw_value) };
            } else {
                switch (entry.value) {
                    .inline_table => |inner| try setInLayout(arena, inner, tail, raw_value),
                    .raw => return error.InvalidValue,
                }
            }
            return;
        }
    }
    // Key not present at this level.
    if (tail.len != 0) return error.PathNotFound;
    try appendInlineEntry(arena, layout, head, raw_value);
}

fn appendInlineEntry(arena: Allocator, layout: *InlineTableLayout, key: []const u8, raw_value: []const u8) Error!void {
    if (layout.entries.items.len == 0) {
        // Empty inline table: `{}` -> `{ key = value }`.
        // Preserve any existing open/close content by checking if open already
        // ends with a space (e.g., `{ ` from `{ }`).
        const open_has_space = layout.open.len > 1 and layout.open[layout.open.len - 1] == ' ';
        if (!open_has_space) {
            layout.open = try arena.dupe(u8, "{ ");
        }
        try layout.entries.append(arena, .{
            .key_raw = try arena.dupe(u8, key),
            .key = try arena.dupe(u8, key),
            .sep = try arena.dupe(u8, " = "),
            .value = .{ .raw = try arena.dupe(u8, raw_value) },
            .trailing = try arena.dupe(u8, " "),
        });
        return;
    }

    const last_idx = layout.entries.items.len - 1;
    const last = &layout.entries.items[last_idx];

    // Inter-entry pattern: the bytes that appear between one entry's value
    // and the next entry's key. We copy this from the next-to-last entry's
    // trailing (which already encodes the user's style: ", " loose, "," tight,
    // ",\n  " multi-line). When only one entry exists, synthesize from open's
    // trailing whitespace (the bytes after `{`).
    const inter_pattern: []const u8 = blk: {
        if (layout.entries.items.len >= 2) {
            break :blk try arena.dupe(u8, layout.entries.items[last_idx - 1].trailing);
        }
        // Single existing entry: build "," + open's trailing ws.
        const open_trail = layout.open[1..]; // bytes after `{`
        break :blk try std.mem.concat(arena, u8, &.{ ",", open_trail });
    };

    // The new (last) entry needs a trailing that continues the close-side
    // pattern. Reuse the old last.trailing when non-empty (it carries either
    // trailing-comma+ws or close-side padding). When empty (tight table with
    // no padding before `}`), derive from close's leading whitespace.
    const new_entry_trailing: []const u8 = if (last.trailing.len > 0)
        try arena.dupe(u8, last.trailing)
    else blk: {
        var n: usize = 0;
        while (n < layout.close.len) : (n += 1) {
            const c = layout.close[n];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        }
        break :blk try arena.dupe(u8, layout.close[0..n]);
    };

    // Patch old last entry to use the inter-entry pattern.
    last.trailing = inter_pattern;

    try layout.entries.append(arena, .{
        .key_raw = try arena.dupe(u8, key),
        .key = try arena.dupe(u8, key),
        .sep = try arena.dupe(u8, last.sep),
        .value = .{ .raw = try arena.dupe(u8, raw_value) },
        .trailing = new_entry_trailing,
    });
}

/// Remove the entry matching sub_path from layout. Returns true when the
/// entry was found and removed, false when not found. Strips a now-redundant
/// trailing comma from the preceding entry when the removed entry was last.
fn removeFromLayout(arena: Allocator, layout: *InlineTableLayout, sub_path: []const u8) Error!bool {
    const dot = std.mem.indexOfScalar(u8, sub_path, '.');
    const head = if (dot) |d| sub_path[0..d] else sub_path;
    const tail = if (dot) |d| sub_path[d + 1 ..] else "";

    for (layout.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.key, head)) {
            if (tail.len == 0) {
                _ = layout.entries.orderedRemove(i);
                // If we removed the last entry, the previous entry's
                // trailing might end with a comma that's now redundant.
                if (i > 0 and i == layout.entries.items.len) {
                    var prev = &layout.entries.items[i - 1];
                    if (std.mem.lastIndexOfScalar(u8, prev.trailing, ',')) |comma_pos| {
                        // Only strip if the remainder after the comma is whitespace only.
                        var all_ws = true;
                        for (prev.trailing[comma_pos + 1 ..]) |c| {
                            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                                all_ws = false;
                                break;
                            }
                        }
                        if (all_ws) {
                            prev.trailing = try arena.dupe(u8, prev.trailing[0..comma_pos]);
                        }
                    }
                }
                return true;
            }
            switch (entry.value) {
                .inline_table => |inner| return removeFromLayout(arena, inner, tail),
                .raw => return error.InvalidValue,
            }
        }
    }
    return false;
}

/// Serialize the layout back to bytes. Walks open, each entry's
/// pieces (key_raw + sep + value-bytes + trailing), and close.
fn writeLayout(layout: *const InlineTableLayout, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(layout.open);
    for (layout.entries.items) |entry| {
        try w.writeAll(entry.key_raw);
        try w.writeAll(entry.sep);
        switch (entry.value) {
            .raw => |bytes| try w.writeAll(bytes),
            .inline_table => |nested| try writeLayout(nested, w),
        }
        try w.writeAll(entry.trailing);
    }
    try w.writeAll(layout.close);
}

fn valueFromAny(arena: Allocator, comptime T: type, value: T) Error!Value {
    return value_mod.fromAny(arena, T, value);
}

const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,
};

fn tokenize(doc: *Document, src: []const u8) !void {
    var tok: Tokenizer = .{ .source = src };
    var current_section: []const u8 = "";

    while (tok.pos < src.len) {
        const line_start = tok.pos;
        const next_significant = skipLeadingWs(src, tok.pos);

        // Blank line.
        if (next_significant >= src.len or src[next_significant] == '\n' or
            (src[next_significant] == '\r' and next_significant + 1 < src.len and src[next_significant + 1] == '\n'))
        {
            const line_end = endOfLine(src, line_start);
            try doc.items.append(doc.arena, .{ .blank = src[line_start..line_end] });
            tok.pos = line_end;
            continue;
        }

        // Comment line.
        if (src[next_significant] == '#') {
            const line_end = endOfLine(src, line_start);
            try doc.items.append(doc.arena, .{ .comment = src[line_start..line_end] });
            tok.pos = line_end;
            continue;
        }

        // Header line.
        if (src[next_significant] == '[') {
            const after_header = scanHeader(src, next_significant);
            const line_end = endOfLine(src, after_header);
            const raw = src[line_start..line_end];
            const is_array = src.len > next_significant + 1 and src[next_significant + 1] == '[';
            const path_start = next_significant + (if (is_array) @as(usize, 2) else @as(usize, 1));
            const path_end = blk: {
                var i = path_start;
                var depth: usize = if (is_array) 2 else 1;
                while (i < src.len and depth > 0) : (i += 1) {
                    if (src[i] == ']') depth -= 1;
                }
                // i now points one past the last ']'
                break :blk i - (if (is_array) @as(usize, 2) else @as(usize, 1));
            };
            const header_path = std.mem.trim(u8, src[path_start..path_end], " \t");
            const owned_path = try doc.arena.dupe(u8, header_path);

            const header_item: Item = .{ .header = .{
                .raw = raw,
                .path = owned_path,
                .is_array = is_array,
            } };
            try doc.items.append(doc.arena, header_item);
            current_section = owned_path;
            try doc.section_end.put(doc.arena, owned_path, doc.items.items.len - 1);

            tok.pos = line_end;
            continue;
        }

        // Key-value line.
        const key_start = next_significant;
        const key_end = scanKey(src, key_start);
        const after_key_ws = skipLeadingWs(src, key_end);
        if (after_key_ws >= src.len or src[after_key_ws] != '=') {
            // Malformed; just consume the line.
            const line_end = endOfLine(src, line_start);
            try doc.items.append(doc.arena, .{ .blank = src[line_start..line_end] });
            tok.pos = line_end;
            continue;
        }
        const after_eq = skipLeadingWs(src, after_key_ws + 1);
        const value_start = after_eq;
        const value_end = scanValue(src, value_start);

        // Item end: include trailing comment and final newline on the
        // last physical line of the value.
        const line_end = endOfLine(src, value_end);

        const raw = src[line_start..line_end];
        const key_raw = src[key_start..key_end];
        const full_path = blk: {
            if (current_section.len == 0) break :blk try doc.arena.dupe(u8, key_raw);
            break :blk try std.fmt.allocPrint(doc.arena, "{s}.{s}", .{ current_section, key_raw });
        };
        const value_offset: u32 = @intCast(value_start - line_start);
        const value_len: u32 = @intCast(value_end - value_start);

        const value_text = src[value_start..value_end];
        const inline_layout: ?*InlineTableLayout = if (value_text.len > 0 and value_text[0] == '{')
            try parseInlineLayout(doc.arena, value_text)
        else
            null;

        const kv_item: Item = .{ .kv = .{
            .raw = raw,
            .full_path = full_path,
            .value_offset = value_offset,
            .value_len = value_len,
            .inline_layout = inline_layout,
        } };
        try doc.items.append(doc.arena, kv_item);
        try doc.kv_index.put(doc.arena, full_path, doc.items.items.len - 1);
        try doc.section_end.put(doc.arena, current_section, doc.items.items.len - 1);
        tok.pos = line_end;
    }
}

fn skipLeadingWs(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    return i;
}

fn endOfLine(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i < src.len and src[i] != '\n') i += 1;
    if (i < src.len) i += 1; // include the \n
    return i;
}

fn scanHeader(src: []const u8, pos: usize) usize {
    // Find the matching ] (or ]]). Headers don't span newlines.
    var i = pos;
    var depth: usize = 0;
    var in_quote: ?u8 = null;
    while (i < src.len and src[i] != '\n') : (i += 1) {
        const c = src[i];
        if (in_quote) |q| {
            if (c == '\\' and q == '"' and i + 1 < src.len) {
                i += 1;
                continue;
            }
            if (c == q) in_quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = c;
            continue;
        }
        if (c == '[') depth += 1;
        if (c == ']') {
            if (depth > 0) depth -= 1;
            if (depth == 0) {
                // Check for ]]
                if (i + 1 < src.len and src[i + 1] == ']') i += 1;
                return i + 1;
            }
        }
    }
    return i;
}

fn scanKey(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '=' or c == '\n') return i;
    }
    return i;
}

/// Scan a TOML value starting at `pos`. Returns the byte index right
/// after the value's last character (excluding trailing whitespace and
/// comment).
fn scanValue(src: []const u8, pos: usize) usize {
    if (pos >= src.len) return pos;
    const c = src[pos];

    // Multi-line basic string: """..."""
    if (c == '"' and pos + 2 < src.len and src[pos + 1] == '"' and src[pos + 2] == '"') {
        return scanMultilineString(src, pos, '"');
    }
    // Multi-line literal string: '''...'''
    if (c == '\'' and pos + 2 < src.len and src[pos + 1] == '\'' and src[pos + 2] == '\'') {
        return scanMultilineString(src, pos, '\'');
    }
    // Single-line basic string.
    if (c == '"') return scanQuotedString(src, pos, '"', true);
    // Single-line literal string.
    if (c == '\'') return scanQuotedString(src, pos, '\'', false);
    // Inline table.
    if (c == '{') return scanBalanced(src, pos, '{', '}');
    // Inline array (possibly multi-line).
    if (c == '[') return scanBalanced(src, pos, '[', ']');

    // Bare value: scan to whitespace, comma, bracket, or comment.
    var i = pos;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '#' or ch == ',' or ch == ']' or ch == '}') return i;
        if (ch == '\r' and i + 1 < src.len and src[i + 1] == '\n') return i;
    }
    return i;
}

fn scanQuotedString(src: []const u8, pos: usize, quote: u8, allow_escape: bool) usize {
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '\n') return i;
        if (allow_escape and c == '\\' and i + 1 < src.len) {
            i += 1;
            continue;
        }
        if (c == quote) return i + 1;
    }
    return i;
}

fn scanMultilineString(src: []const u8, pos: usize, quote: u8) usize {
    var i = pos + 3;
    while (i + 2 < src.len) : (i += 1) {
        if (quote == '"' and src[i] == '\\' and i + 1 < src.len) {
            i += 1;
            continue;
        }
        if (src[i] == quote and src[i + 1] == quote and src[i + 2] == quote) {
            // Allow up to 2 more closing quotes (per TOML spec for """...""""
            // or """...""""": treat them as part of the string). We accept
            // up to 5 quotes total.
            var j = i + 3;
            var extra: usize = 0;
            while (j < src.len and extra < 2 and src[j] == quote) : (j += 1) extra += 1;
            return i + 3 + extra;
        }
    }
    return src.len;
}

fn scanBalanced(src: []const u8, pos: usize, open: u8, close: u8) usize {
    var i = pos + 1;
    var depth: usize = 1;
    while (i < src.len and depth > 0) : (i += 1) {
        const c = src[i];
        if (c == '"' or c == '\'') {
            // Skip string contents to avoid counting brackets inside.
            if (c == '"' and i + 2 < src.len and src[i + 1] == '"' and src[i + 2] == '"') {
                i = scanMultilineString(src, i, '"') - 1;
            } else if (c == '\'' and i + 2 < src.len and src[i + 1] == '\'' and src[i + 2] == '\'') {
                i = scanMultilineString(src, i, '\'') - 1;
            } else {
                i = scanQuotedString(src, i, c, c == '"') - 1;
            }
            continue;
        }
        if (c == '#') {
            // Comment to end of line (only meaningful inside arrays).
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return i;
}

/// Parse inline-table value bytes (exactly `{` ... `}`) into a
/// structured layout. Allocates the layout struct, entry list, and
/// any recursive nested layouts in `arena`.
fn parseInlineLayout(arena: Allocator, value_bytes: []const u8) Error!*InlineTableLayout {
    if (value_bytes.len < 2 or value_bytes[0] != '{') return error.InvalidValue;

    var layout = try arena.create(InlineTableLayout);
    layout.entries = .empty;

    var pos: usize = 1; // past `{`

    // Scan whitespace after the opening brace.
    while (pos < value_bytes.len) : (pos += 1) {
        const c = value_bytes[pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (c == '#') {
            while (pos < value_bytes.len and value_bytes[pos] != '\n') pos += 1;
            continue;
        }
        break;
    }
    layout.open = value_bytes[0..pos];

    if (pos >= value_bytes.len) return error.InvalidValue;

    if (value_bytes[pos] == '}') {
        layout.close = value_bytes[pos..];
        return layout;
    }

    while (true) {
        // Scan key.
        const key_start = pos;
        var key_text: []const u8 = undefined;
        if (value_bytes[pos] == '"' or value_bytes[pos] == '\'') {
            const allow_escape = value_bytes[pos] == '"';
            const quote = value_bytes[pos];
            pos = scanQuotedString(value_bytes, pos, quote, allow_escape);
            key_text = value_bytes[key_start + 1 .. pos - 1];
        } else {
            while (pos < value_bytes.len) : (pos += 1) {
                const c = value_bytes[pos];
                if (c == ' ' or c == '\t' or c == '=') break;
                if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
            }
            key_text = value_bytes[key_start..pos];
        }
        const key_raw = value_bytes[key_start..pos];

        // Scan sep: optional ws + `=` + optional ws.
        const sep_start = pos;
        while (pos < value_bytes.len and (value_bytes[pos] == ' ' or value_bytes[pos] == '\t')) pos += 1;
        if (pos >= value_bytes.len or value_bytes[pos] != '=') return error.InvalidValue;
        pos += 1;
        while (pos < value_bytes.len and (value_bytes[pos] == ' ' or value_bytes[pos] == '\t')) pos += 1;
        const sep = value_bytes[sep_start..pos];

        // Scan value.
        if (pos >= value_bytes.len) return error.InvalidValue;
        var value: InlineValue = undefined;
        if (value_bytes[pos] == '{') {
            const inner_start = pos;
            const inner_end = scanBalanced(value_bytes, pos, '{', '}');
            const inner_bytes = value_bytes[inner_start..inner_end];
            const inner_layout = try parseInlineLayout(arena, inner_bytes);
            value = .{ .inline_table = inner_layout };
            pos = inner_end;
        } else {
            const value_start = pos;
            pos = scanValue(value_bytes, pos);
            value = .{ .raw = value_bytes[value_start..pos] };
        }

        // Scan trailing: whitespace + optional comma + optional comment + whitespace.
        const trailing_start = pos;
        while (pos < value_bytes.len) : (pos += 1) {
            const c = value_bytes[pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
            if (c == ',') {
                continue;
            }
            if (c == '#') {
                while (pos < value_bytes.len and value_bytes[pos] != '\n') pos += 1;
                continue;
            }
            break;
        }
        const trailing = value_bytes[trailing_start..pos];

        try layout.entries.append(arena, .{
            .key_raw = key_raw,
            .key = key_text,
            .sep = sep,
            .value = value,
            .trailing = trailing,
        });

        if (pos >= value_bytes.len) return error.InvalidValue;
        if (value_bytes[pos] == '}') {
            layout.close = value_bytes[pos..];
            return layout;
        }
        // Otherwise loop for the next entry.
    }
}

test "document: byte-identical round-trip" {
    const src =
        \\# top comment
        \\title = "toml"  # trailing
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    ;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{});

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "document: get reads parsed value" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
    , .{});

    try testing.expectEqual(@as(i64, 8080), doc.get("server.port").?.integer);
}

test "document: setLiteral replaces existing value" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
    , .{});

    try doc.setLiteral("server.port", "9999");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[server]\nport = 9999\n", aw.written());
}

test "document: setLiteral appends to existing section" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
    , .{});

    try doc.setLiteral("server.tls", "true");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[server]\nport = 8080\ntls = true\n", aw.written());
}

test "document: setLiteral creates new section if missing" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
    , .{});

    try doc.setLiteral("client.timeout", "30");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "[client]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "timeout = 30") != null);
}

test "document: remove drops the line" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\tls = true
        \\
    , .{});

    try doc.remove("server.tls");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[server]\nport = 8080\n", aw.written());
}

test "document: round-trip preserves comments and blank lines" {
    const src =
        \\# header
        \\
        \\[a]
        \\# inline
        \\x = 1  # trailing
        \\
        \\y = 2
        \\
        \\# end
    ;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{});

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "document: setValue formats canonically" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\name = "old"
        \\
    , .{});

    try doc.setValue("name", .{ .string = "new" });

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("name = \"new\"\n", aw.written());
}

test "document: setLiteral rejects invalid value literal" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\x = 1
    , .{});

    try testing.expectError(error.InvalidValue, doc.setLiteral("x", "this is not toml"));
}

test "document: remove returns PathNotFound" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\x = 1
    , .{});

    try testing.expectError(error.PathNotFound, doc.remove("nope"));
}

test "document: addCommentBefore inserts a comment line" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\
    , .{});

    try doc.addCommentBefore("port", "the listen port");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("# the listen port\nport = 8080\n", aw.written());
}

test "document: addCommentAfter inserts a comment line below" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\
    , .{});

    try doc.addCommentAfter("port", "deprecated");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("port = 8080\n# deprecated\n", aw.written());
}

test "document: removeCommentBefore strips preceding comment" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\# old note
        \\port = 8080
        \\
    , .{});

    try doc.removeCommentBefore("port");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("port = 8080\n", aw.written());
}

test "document: setTrailingComment adds and replaces" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\
    , .{});

    try doc.setTrailingComment("port", "default");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("port = 8080  # default\n", aw.written());

    try doc.setTrailingComment("port", null);
    aw.clearRetainingCapacity();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("port = 8080\n", aw.written());
}

test "document: setLiteral edits inside an inline table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2 }
        \\
    , .{});

    try doc.setLiteral("point.x", "99");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "x = 99") != null);
    try testing.expect(std.mem.indexOf(u8, out, "y = 2") != null);
}

test "document: setLiteral adds new key inside an inline table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2 }
        \\
    , .{});

    try doc.setLiteral("point.z", "3");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "z = 3") != null);
}

test "document: moveSection swaps section order" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
        \\[client]
        \\timeout = 30
        \\
    , .{});

    try doc.moveSection("client", .before, "server");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    const client_idx = std.mem.indexOf(u8, out, "[client]").?;
    const server_idx = std.mem.indexOf(u8, out, "[server]").?;
    try testing.expect(client_idx < server_idx);
}

test "Document.set: comptime-dispatched native values" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "", .{});

    try doc.set("port", @as(u16, 9999));
    try doc.set("name", "ef");
    try doc.set("tls", true);
    try doc.set("ratio", @as(f64, 1.5));

    try testing.expectEqual(@as(i64, 9999), doc.get("port").?.integer);
    try testing.expectEqualStrings("ef", doc.get("name").?.string);
    try testing.expectEqual(true, doc.get("tls").?.boolean);
    try testing.expectEqual(@as(f64, 1.5), doc.get("ratio").?.float);
}

test "Document.set: accepts existing Value passthrough" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "", .{});

    try doc.set("v", Value{ .integer = 42 });
    try testing.expectEqual(@as(i64, 42), doc.get("v").?.integer);
}

test "Document.getT: typed access mirrors Value.getT" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\name = "x"
    , .{});

    try testing.expectEqual(@as(?u16, 8080), doc.getT(u16, "port"));
    try testing.expectEqualStrings("x", doc.getT([]const u8, "name").?);
    try testing.expect(doc.getT(u16, "missing") == null);
    try testing.expect(doc.getT(u16, "name") == null); // type mismatch
}

test "document: removeCommentAfter strips following comment" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\# deprecated
        \\
    , .{});

    try doc.removeCommentAfter("port");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("port = 8080\n", aw.written());
}

test "document: removeCommentAfter is a no-op when next item isn't a comment" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\host = "x"
        \\
    , .{});

    try doc.removeCommentAfter("port");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("port = 8080\nhost = \"x\"\n", aw.written());
}

test "Document.has: convenience wrapper" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\[server]
        \\host = "x"
    , .{});
    try testing.expect(doc.has("port"));
    try testing.expect(doc.has("server.host"));
    try testing.expect(!doc.has("missing"));
}

test "Document.get / getT / has: support array-index paths" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[[users]]
        \\name = "alice"
        \\[[users]]
        \\name = "bob"
    , .{});

    try testing.expectEqualStrings("alice", doc.get("users[0].name").?.string);
    try testing.expectEqualStrings("bob", doc.get("users[1].name").?.string);
    try testing.expect(doc.get("users[2].name") == null);

    try testing.expectEqualStrings("bob", doc.getT([]const u8, "users[1].name").?);
    try testing.expect(doc.has("users[0].name"));
    try testing.expect(!doc.has("users[2].name"));
}

test "InlineTableLayout: types exist and are usable" {
    const layout: InlineTableLayout = .{
        .open = "{",
        .entries = .empty,
        .close = "}",
    };
    try testing.expectEqualStrings("{", layout.open);
    try testing.expectEqual(@as(usize, 0), layout.entries.items.len);

    const entry: InlineEntry = .{
        .key_raw = "x",
        .key = "x",
        .sep = " = ",
        .value = .{ .raw = "1" },
        .trailing = "",
    };
    const iv: InlineValue = entry.value;
    try testing.expectEqualStrings("1", iv.raw);
    try testing.expectEqualStrings("x", entry.key);
}

test "parseInlineLayout: empty table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{}");
    try testing.expectEqual(@as(usize, 0), layout.entries.items.len);
    try testing.expectEqualStrings("{", layout.open);
    try testing.expectEqualStrings("}", layout.close);
}

test "parseInlineLayout: single key tight spacing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{x=1}");
    try testing.expectEqual(@as(usize, 1), layout.entries.items.len);
    const e = layout.entries.items[0];
    try testing.expectEqualStrings("x", e.key);
    try testing.expectEqualStrings("x", e.key_raw);
    try testing.expectEqualStrings("=", e.sep);
    try testing.expectEqualStrings("1", e.value.raw);
    try testing.expectEqualStrings("", e.trailing);
}

test "parseInlineLayout: loose spacing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{ x = 1, y = 2 }");
    try testing.expectEqual(@as(usize, 2), layout.entries.items.len);
    try testing.expectEqualStrings("{ ", layout.open);
    const e0 = layout.entries.items[0];
    try testing.expectEqualStrings("x", e0.key);
    try testing.expectEqualStrings(" = ", e0.sep);
    try testing.expectEqualStrings("1", e0.value.raw);
    try testing.expectEqualStrings(", ", e0.trailing);
    const e1 = layout.entries.items[1];
    try testing.expectEqualStrings("y", e1.key);
    try testing.expectEqualStrings("2", e1.value.raw);
    try testing.expectEqualStrings(" ", e1.trailing);
    try testing.expectEqualStrings("}", layout.close);
}

test "parseInlineLayout: nested inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{ a = 1, inner = { x = 9 }, b = 2 }");
    try testing.expectEqual(@as(usize, 3), layout.entries.items.len);
    const inner_entry = layout.entries.items[1];
    try testing.expectEqualStrings("inner", inner_entry.key);
    try testing.expect(inner_entry.value == .inline_table);
    const inner_layout = inner_entry.value.inline_table;
    try testing.expectEqual(@as(usize, 1), inner_layout.entries.items.len);
    try testing.expectEqualStrings("x", inner_layout.entries.items[0].key);
    try testing.expectEqualStrings("9", inner_layout.entries.items[0].value.raw);
}

test "parseInlineLayout: quoted key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{ \"weird key\" = 1 }");
    try testing.expectEqual(@as(usize, 1), layout.entries.items.len);
    const e = layout.entries.items[0];
    try testing.expectEqualStrings("weird key", e.key);
    try testing.expectEqualStrings("\"weird key\"", e.key_raw);
}

test "parseInlineLayout: string value with braces inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{ msg = \"a, b { c\", n = 1 }");
    try testing.expectEqual(@as(usize, 2), layout.entries.items.len);
    try testing.expectEqualStrings("\"a, b { c\"", layout.entries.items[0].value.raw);
    try testing.expectEqualStrings("1", layout.entries.items[1].value.raw);
}

test "parseInlineLayout: trailing comma (TOML 1.1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{ a = 1, b = 2, }");
    try testing.expectEqual(@as(usize, 2), layout.entries.items.len);
    try testing.expectEqualStrings("1", layout.entries.items[0].value.raw);
    try testing.expectEqualStrings("2", layout.entries.items[1].value.raw);
    // The trailing comma belongs to the last entry's `trailing`.
    try testing.expectEqualStrings(", ", layout.entries.items[1].trailing);
    try testing.expectEqualStrings("}", layout.close);
}

test "parseInlineLayout: trailing comma with no space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{a=1,}");
    try testing.expectEqual(@as(usize, 1), layout.entries.items.len);
    try testing.expectEqualStrings("1", layout.entries.items[0].value.raw);
    try testing.expectEqualStrings(",", layout.entries.items[0].trailing);
    try testing.expectEqualStrings("}", layout.close);
}

test "Document.parse populates kv.inline_layout for inline-table values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2 }
        \\scalar = 42
    , .{});

    // First kv has an inline-table value.
    const kv0 = doc.items.items[0].kv;
    try testing.expect(kv0.inline_layout != null);
    try testing.expectEqual(@as(usize, 2), kv0.inline_layout.?.entries.items.len);

    // Second kv has a scalar value.
    const kv1 = doc.items.items[1].kv;
    try testing.expect(kv1.inline_layout == null);
}

test "document: setLiteral preserves tight spacing inside inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = {x=1,y=2}
        \\
    , .{});
    try doc.setLiteral("point.x", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = {x=99,y=2}\n", aw.written());
}

test "document: setLiteral preserves loose spacing inside inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2 }
        \\
    , .{});
    try doc.setLiteral("point.x", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { x = 99, y = 2 }\n", aw.written());
}

test "document: setLiteral on nested inline table preserves spacing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\outer = { inner = { x = 1 }, y = 2 }
        \\
    , .{});
    try doc.setLiteral("outer.inner.x", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("outer = { inner = { x = 99 }, y = 2 }\n", aw.written());
}

test "document: setLiteral appends new sub-key to inline table with existing entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2 }
        \\
    , .{});
    try doc.setLiteral("point.z", "3");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { x = 1, y = 2, z = 3 }\n", aw.written());
}

test "document: setLiteral creates first sub-key in empty inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = {}
        \\
    , .{});
    try doc.setLiteral("point.x", "1");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { x = 1 }\n", aw.written());
}

test "document: setLiteral appends new sub-key to tight inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = {x=1,y=2}
        \\
    , .{});
    try doc.setLiteral("point.z", "3");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = {x=1,y=2,z=3}\n", aw.written());
}

test "document: remove drops sub-key from inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2 }
        \\
    , .{});
    try doc.remove("point.x");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { y = 2 }\n", aw.written());
}

test "document: remove drops last sub-key from inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1 }
        \\
    , .{});
    try doc.remove("point.x");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    // After dropping the only entry, the inline table is empty. The
    // `open`/`close` keep their original padding -- so output is
    // `point = { }\n` OR `point = {}\n` depending on the layout
    // bytes captured during parse. Either is acceptable; if the
    // implementation collapses padding on empty, prefer `{}`.
    const out = aw.written();
    try testing.expect(std.mem.eql(u8, out, "point = { }\n") or std.mem.eql(u8, out, "point = {}\n"));
}

test "document: remove drops middle sub-key cleanly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2, z = 3 }
        \\
    , .{});
    try doc.remove("point.y");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { x = 1, z = 3 }\n", aw.written());
}

test "round-trip: trailing comma preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\t = { x = 1, y = 2, }
        \\
    , .{});
    try doc.setLiteral("t.x", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("t = { x = 99, y = 2, }\n", aw.written());
}

test "round-trip: inline comment outside the table preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\t = { x = 1, y = 2 } # 2D point
        \\
    , .{});
    try doc.setLiteral("t.x", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("t = { x = 99, y = 2 } # 2D point\n", aw.written());
}

test "round-trip: quoted key preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\t = { "weird key" = 1, normal = 2 }
        \\
    , .{});
    try doc.setLiteral("t.normal", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("t = { \"weird key\" = 1, normal = 99 }\n", aw.written());
}

test "round-trip: string value with braces preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\t = { msg = "a, b { c", n = 1 }
        \\
    , .{});
    try doc.setLiteral("t.n", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("t = { msg = \"a, b { c\", n = 99 }\n", aw.written());
}

test "round-trip: twice-nested inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\a = { b = { c = { x = 1 } } }
        \\
    , .{});
    try doc.setLiteral("a.b.c.x", "42");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("a = { b = { c = { x = 42 } } }\n", aw.written());
}

test "round-trip: edit nested keeps outer scalars intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\c = { name = "x", inner = { v = 1 } }
        \\
    , .{});
    try doc.setLiteral("c.inner.v", "9");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("c = { name = \"x\", inner = { v = 9 } }\n", aw.written());
}

test "round-trip: scalar path through scalar returns InvalidValue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\t = { x = 1 }
        \\
    , .{});
    try testing.expectError(error.InvalidValue, doc.setLiteral("t.x.deeper", "1"));
}

test "round-trip: multi-line inline table preserves newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\point = {
        \\  x = 1,
        \\  y = 2,
        \\}
        \\
    ;
    var doc = try Document.parse(arena.allocator(), src, .{});
    try doc.setLiteral("point.x", "99");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const expected =
        \\point = {
        \\  x = 99,
        \\  y = 2,
        \\}
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}

test "round-trip: multi-line inline table append preserves newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\t = {
        \\  a = 1,
        \\  b = 2,
        \\}
        \\
    ;
    var doc = try Document.parse(arena.allocator(), src, .{});
    try doc.setLiteral("t.z", "3");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const expected =
        \\t = {
        \\  a = 1,
        \\  b = 2,
        \\  z = 3,
        \\}
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}

test "round-trip: trailing comma preserved on append" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\t = { a = 1, b = 2, }
        \\
    , .{});
    try doc.setLiteral("t.z", "3");

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("t = { a = 1, b = 2, z = 3, }\n", aw.written());
}
