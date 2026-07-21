//! Document model for TOML -- lossless parse, edit, and emit.
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
//!   creates the missing table header (covering every missing segment
//!   in one `[a.b.c]`-style line, TOML's implicit-super-table rule) and
//!   appends the leaf key under it, at the end of the document.
//! - Adding a new key to an existing section appends it as the last
//!   entry of that section; surrounding formatting (other keys,
//!   blank lines, comments) is preserved.
//! - `Document.empty` bootstraps a document with no source bytes at
//!   all. TOML already treats empty input as a valid (empty) document,
//!   so this is a thin, explicitly-named alias for `Document.parse(arena,
//!   "", options)` -- the "file may not exist yet" entry point.
//! - `setValueSegments` / `setSegments` / `removeSegments` take a path
//!   as pre-split, already-unescaped key segments (`&.{ "a", "b.c" }`)
//!   instead of a dotted string, so a key containing a literal `.` is
//!   addressed unambiguously: each segment is one literal key, never
//!   re-split on `.`. A segment that isn't a valid bare TOML key is
//!   quoted on emit. `set` / `setValue` / `setLiteral` / `remove` still
//!   take dotted string paths and split them into segments the same way
//!   as before (naive `.`-splitting, quote-unaware) before doing the
//!   same work, so a dot-free path behaves identically either way.

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
    InvalidComment,
    UnsupportedPath,
    /// A Zig integer value cannot be represented as a TOML integer (i64).
    /// Distinct from decode's `Overflow` (target-Zig-type overflow).
    IntegerOverflow,
    PathTooDeep,
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
    /// Resolved dotted path (e.g., "server.tls"). Lossy: a segment
    /// containing a literal '.' joins indistinguishably from two plain
    /// segments. Kept for the string-path editors and comment lookups;
    /// segment-based resolution uses `path_segments` instead.
    path: []const u8,
    /// Decoded path segments, unjoined -- the collision-free identity
    /// `path` cannot represent. `["a", "b.c"]` for `[a."b.c"]`, distinct
    /// from `["a", "b", "c"]` for `[a.b.c]`.
    path_segments: []const []const u8,
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

    /// Decoded key identity: quotes stripped and escape sequences
    /// interpreted (e.g., `"a\tb"` decodes to `a<TAB>b`). This matches the
    /// decoded dotted paths that callers pass to set/remove, so lookups
    /// compare decoded-vs-decoded. `key_raw` keeps the source bytes for
    /// lossless emit.
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
    /// Full path resolved against the enclosing header, joined by '.'.
    /// Lossy (see `Header.path`); kept for the string-path editors and
    /// comment lookups. Segment-based resolution uses `full_path_segments`.
    full_path: []const u8,
    /// Decoded full path segments (enclosing header's segments, if any,
    /// followed by this line's own key segment(s) -- a source line may
    /// itself use inline dotted-key syntax, e.g. `a.b = 1`). The
    /// collision-free identity `full_path` cannot represent.
    full_path_segments: []const []const u8,
    /// Byte offset within `raw` where the value text starts.
    value_offset: usize,
    /// Length of the value text inside `raw`.
    value_len: usize,
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
    /// Decoded paths of `[[x]]` array-of-tables headers. Keys through these
    /// are ambiguous without an element index (kv_index would silently
    /// resolve to the LAST element), so the editors refuse them; `get`
    /// requires an explicit `[N]` for the same reason.
    aot_paths: StringArrayHashMap(void),
    parsed: Value,

    pub fn parse(arena: Allocator, input: []const u8, options: parser_mod.ParseOptions) !Document {
        const source = try arena.dupe(u8, input);
        var doc: Document = .{
            .arena = arena,
            .source = source,
            .items = .empty,
            .kv_index = .empty,
            .section_end = .empty,
            .aot_paths = .empty,
            .parsed = undefined,
        };
        try tokenize(&doc, source);
        // Cross-check by running the strict parser; this also gives us
        // the parsed Value tree for `get` queries.
        doc.parsed = try parser_mod.parse(arena, source, options);
        return doc;
    }

    /// Bootstrap a document with no source bytes -- the "file doesn't
    /// exist yet" case. Empty input is already valid TOML (an empty
    /// table), so this is a thin, explicitly-named alias for
    /// `parse(arena, "", options)`: reads see nothing, and the first
    /// `set` (or any segment variant) creates the whole requested table
    /// path and leaf as one edit.
    pub fn empty(arena: Allocator, options: parser_mod.ParseOptions) Error!Document {
        return parse(arena, "", options);
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
    /// True when `path` is, or descends through, an array-of-tables. Such a
    /// path needs an `[N]` element index to be readable via `get`, and the
    /// editors support no `[N]` syntax at all, so they refuse it outright
    /// (rather than silently editing the LAST element).
    fn pathThroughArrayOfTables(self: *const Document, path: []const u8) bool {
        var it = self.aot_paths.iterator();
        while (it.next()) |e| {
            const p = e.key_ptr.*;
            if (std.mem.eql(u8, path, p)) return true;
            if (path.len > p.len and std.mem.startsWith(u8, path, p) and path[p.len] == '.') return true;
        }
        return false;
    }

    /// Segment-based twin of `pathThroughArrayOfTables`, used by the
    /// write core (never by the comment editors, which stay string-only).
    /// Scans headers directly rather than consulting `aot_paths` (which
    /// is keyed by the lossy joined string) so a segment containing a
    /// literal '.' cannot collide with an unrelated array-of-tables path.
    fn pathThroughArrayOfTablesSegments(self: *const Document, segments: []const []const u8) bool {
        for (self.items.items) |item| {
            if (item != .header or !item.header.is_array) continue;
            const p = item.header.path_segments;
            if (p.len <= segments.len and segArrayEq(p, segments[0..p.len])) return true;
        }
        return false;
    }

    /// kv_index lookup for the comment editors: refuses ambiguous paths
    /// (through an array-of-tables) before consulting the index.
    fn editableKvIndex(self: *const Document, path: []const u8) Error!usize {
        if (self.pathThroughArrayOfTables(path)) return error.UnsupportedPath;
        return self.kv_index.get(path) orelse error.PathNotFound;
    }

    pub fn setLiteral(self: *Document, path: []const u8, raw: []const u8) Error!void {
        // `get` reads `arr[0]` as array element 0; setLiteral cannot edit
        // array elements, so reject the syntax rather than silently mint a
        // literal `"arr[0]"` key that disagrees with the read path.
        if (pathHasArrayIndex(path)) return error.UnsupportedPath;
        return self.setLiteralSegments(try segmentsFromPath(self.arena, path), raw);
    }

    /// Segment-taking twin of `setValue`. `segments` are literal key names
    /// addressed in order -- never re-split on `.` -- so a key containing a
    /// literal `.` is addressed unambiguously; a segment that isn't a valid
    /// bare TOML key is quoted on emit. Missing intermediate tables along
    /// `segments` are created the same way `set` creates them for a dotted
    /// string path (see the module doc comment).
    pub fn setValueSegments(self: *Document, segments: []const []const u8, value: Value) Error!void {
        const raw = formatValue(self.arena, value) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NestingTooDeep => return error.NestingTooDeep,
            else => return error.InvalidValue,
        };
        return self.setLiteralSegments(segments, raw);
    }

    /// Segment-taking twin of `set`.
    pub fn setSegments(self: *Document, segments: []const []const u8, value: anytype) Error!void {
        const v = try valueFromAny(self.arena, @TypeOf(value), value);
        return self.setValueSegments(segments, v);
    }

    /// Segment-based core shared by `setLiteral` (string paths, pre-split
    /// via `segmentsFromPath`) and `setValueSegments` (already literal key
    /// segments).
    fn setLiteralSegments(self: *Document, segments: []const []const u8, raw: []const u8) Error!void {
        if (segments.len == 0) return error.UnsupportedPath;
        if (self.pathThroughArrayOfTablesSegments(segments)) return error.UnsupportedPath;
        try validateValueLiteral(self.arena, raw);

        if (self.findKvIndexBySegments(segments)) |idx| {
            return self.replaceValueAt(idx, raw);
        }

        // Walk up the path looking for an enclosing inline-table parent.
        if (try self.editInsideInlineTableSegments(segments, raw)) return;

        // Path doesn't match an existing kv or nest into one - append/create.
        return self.insertNewKeySegments(segments, raw);
    }

    fn replaceValueAt(self: *Document, idx: usize, raw_value: []const u8) Error!void {
        const old_item = self.items.items[idx];
        const old = old_item.kv;
        const before = old.raw[0..old.value_offset];
        const after = old.raw[old.value_offset + old.value_len ..];
        const new_raw = try std.mem.concat(self.arena, u8, &.{ before, raw_value, after });
        const inline_layout: ?*InlineTableLayout = if (raw_value.len > 0 and raw_value[0] == '{')
            try parseInlineLayout(self.arena, raw_value, 0)
        else
            null;
        self.items.items[idx] = .{ .kv = .{
            .raw = new_raw,
            .full_path = old.full_path,
            .full_path_segments = old.full_path_segments,
            .value_offset = old.value_offset,
            .value_len = raw_value.len,
            .inline_layout = inline_layout,
        } };
        // Keep the cached value tree in sync so get/getT/has see the edit.
        // On a reparse failure, roll the item back so a failed edit leaves
        // the document unchanged.
        self.refreshParsed() catch |e| {
            self.items.items[idx] = old_item;
            return e;
        };
    }

    /// If `segments` like `&.{ "point", "x" }` falls inside an existing
    /// inline-table value (`point = { x = 1, y = 2 }`), edit the sub-key in
    /// place using the in-memory layout (preserves original whitespace and
    /// key order). Tries progressively shorter leading segment counts as
    /// the candidate parent, longest first. Returns true on success, false
    /// if no enclosing inline-table parent was found.
    fn editInsideInlineTableSegments(self: *Document, segments: []const []const u8, raw_value: []const u8) Error!bool {
        var split = segments.len;
        while (split > 1) {
            split -= 1;
            const parent_segments = segments[0..split];
            const sub_segments = segments[split..];

            if (self.findKvIndexBySegments(parent_segments)) |parent_idx| {
                if (self.items.items[parent_idx].kv.inline_layout) |layout| {
                    // Edit a fresh clone of the layout so a failed reparse
                    // rolls back cleanly: the layout is mutated in place, so
                    // the original must survive untouched to restore the item
                    // (mirrors replaceValueAt / setTrailingComment). Reachable
                    // e.g. splicing a `1 # c` literal, which validates
                    // standalone but whose `#` comments out the inline table's
                    // closing brace on reparse.
                    const old_item = self.items.items[parent_idx];
                    self.items.items[parent_idx].kv.inline_layout = try cloneLayout(self.arena, layout);
                    self.applyInlineEditSegments(parent_idx, sub_segments, raw_value) catch |e| {
                        self.items.items[parent_idx] = old_item;
                        return e;
                    };
                    return true;
                }
            }
        }
        return false;
    }

    /// Mutate the (already-cloned) inline layout at `parent_idx`, rebuild its
    /// kv raw, and reparse to validate. The caller snapshots the item first
    /// and restores it on any error here.
    fn applyInlineEditSegments(self: *Document, parent_idx: usize, sub_segments: []const []const u8, raw_value: []const u8) Error!void {
        const layout = self.items.items[parent_idx].kv.inline_layout.?;
        try setInLayout(self.arena, layout, sub_segments, raw_value);
        try self.rebuildInlineKv(parent_idx);
        try self.refreshParsed();
    }

    fn insertNewKeySegments(self: *Document, segments: []const []const u8, raw_value: []const u8) Error!void {
        // Atomicity: snapshot the in-memory state mutated by the insert, do
        // the (possibly multi-step, section-creating) mutation, then validate
        // by reparsing exactly once. If anything fails, restore the snapshot
        // so a failed insert leaves the document byte-identical to before.
        const items_snapshot = try self.arena.dupe(Item, self.items.items);
        const kv_snapshot = try self.kv_index.clone(self.arena);
        const section_snapshot = try self.section_end.clone(self.arena);
        const parsed_snapshot = self.parsed;

        self.insertNewKeySegmentsMutate(segments, raw_value) catch |e| {
            self.restoreSnapshot(items_snapshot, kv_snapshot, section_snapshot, parsed_snapshot);
            return e;
        };

        // Validate the mutated document. On failure, roll everything back.
        self.refreshParsed() catch |e| {
            self.restoreSnapshot(items_snapshot, kv_snapshot, section_snapshot, parsed_snapshot);
            return e;
        };
    }

    fn restoreSnapshot(
        self: *Document,
        items: []const Item,
        kv: StringArrayHashMap(usize),
        section: StringArrayHashMap(usize),
        parsed: Value,
    ) void {
        self.items.clearRetainingCapacity();
        self.items.appendSliceAssumeCapacity(items);
        self.kv_index = kv;
        self.section_end = section;
        self.parsed = parsed;
    }

    /// Perform the in-memory mutation for inserting a new key, without
    /// reparsing. Recurses through appendNewSectionSegments for a missing
    /// enclosing table, creating every missing level in one combined
    /// header (`[a.b.c]`) via TOML's implicit-super-table rule -- no
    /// per-level header is emitted separately. The caller
    /// (insertNewKeySegments) validates via a single refreshParsed and
    /// rolls back on failure.
    fn insertNewKeySegmentsMutate(self: *Document, segments: []const []const u8, raw_value: []const u8) Error!void {
        const enclosing = segments[0 .. segments.len - 1];
        const leaf = segments[segments.len - 1];
        if (self.sectionAppendPoint(enclosing)) |after_idx| {
            // Ensure the preceding item ends with a newline so the
            // new line starts cleanly.
            try self.ensureItemEndsWithNewline(after_idx);

            // Append new kv right after the section's last item.
            const fmt = try formatKvLine(self.arena, leaf, raw_value);
            const full_segments = try dupeSegments(self.arena, segments);
            const new_item: Item = .{ .kv = .{
                .raw = fmt.line,
                .full_path = try std.mem.join(self.arena, ".", full_segments),
                .full_path_segments = full_segments,
                .value_offset = fmt.value_offset,
                .value_len = raw_value.len,
            } };
            try self.items.insert(self.arena, after_idx + 1, new_item);
            self.shiftIndices(after_idx + 1, 1);
            try self.kv_index.put(self.arena, new_item.kv.full_path, after_idx + 1);
            try self.section_end.put(self.arena, try std.mem.join(self.arena, ".", enclosing), after_idx + 1);
        } else if (enclosing.len == 0) {
            // Root-level key but the document has no root content yet -- just append.
            const fmt = try formatKvLine(self.arena, leaf, raw_value);
            const full_segments = try dupeSegments(self.arena, segments);
            const new_item: Item = .{ .kv = .{
                .raw = fmt.line,
                .full_path = try std.mem.join(self.arena, ".", full_segments),
                .full_path_segments = full_segments,
                .value_offset = fmt.value_offset,
                .value_len = raw_value.len,
            } };
            try self.items.append(self.arena, new_item);
            try self.kv_index.put(self.arena, new_item.kv.full_path, self.items.items.len - 1);
            try self.section_end.put(self.arena, "", self.items.items.len - 1);
        } else {
            // Section doesn't exist: create the header covering every
            // missing segment, then recurse to add the key now that the
            // section is present.
            try self.appendNewSectionSegments(enclosing);
            try self.insertNewKeySegmentsMutate(segments, raw_value);
        }
    }

    /// Set a value from a structured `Value`. Formats the value using the
    /// canonical encoder.
    pub fn setValue(self: *Document, path: []const u8, value: Value) Error!void {
        const raw = formatValue(self.arena, value) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NestingTooDeep => return error.NestingTooDeep,
            else => return error.InvalidValue,
        };
        try self.setLiteral(path, raw);
    }

    /// Headline setter. Comptime-dispatched on `@TypeOf(value)`:
    ///   - `Value`               -> setValue passthrough
    ///   - `Date` / `Time` / `DateTime` -> wrapped into the matching variant
    ///   - `bool`                -> .boolean
    ///   - integer types         -> .integer (runtime i64 range check;
    ///                             returns IntegerOverflow for values that
    ///                             do not fit in i64)
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
        // Mirror setLiteral: `arr[0]` is array-element access, which remove
        // does not support. Erroring keeps it consistent with `get`.
        if (pathHasArrayIndex(path)) return error.UnsupportedPath;
        return self.removeSeg(try segmentsFromPath(self.arena, path));
    }

    /// Segment-taking twin of `remove`.
    pub fn removeSegments(self: *Document, segments: []const []const u8) Error!void {
        return self.removeSeg(segments);
    }

    fn removeSeg(self: *Document, segments: []const []const u8) Error!void {
        if (segments.len == 0) return error.UnsupportedPath;
        if (self.pathThroughArrayOfTablesSegments(segments)) return error.UnsupportedPath;
        if (self.findKvIndexBySegments(segments)) |idx| {
            _ = self.items.orderedRemove(idx);
            // section_end may point exactly at the removed kv (last item of
            // its section); a plain index shift would underflow or leave a
            // stale entry, so rebuild both indices from the item list.
            try self.rebuildIndices();
            try self.refreshParsed();
            return;
        }

        if (try self.removeInsideInlineTableSegments(segments)) return;

        return error.PathNotFound;
    }

    /// Segment-based twin of the old `removeInsideInlineTable`: tries
    /// progressively shorter leading segment counts as the candidate
    /// enclosing inline-table parent, longest first.
    fn removeInsideInlineTableSegments(self: *Document, segments: []const []const u8) Error!bool {
        var split = segments.len;
        while (split > 1) {
            split -= 1;
            const parent_segments = segments[0..split];
            const sub_segments = segments[split..];

            if (self.findKvIndexBySegments(parent_segments)) |parent_idx| {
                if (self.items.items[parent_idx].kv.inline_layout) |layout| {
                    if (try removeFromLayout(self.arena, layout, sub_segments)) {
                        try self.rebuildInlineKv(parent_idx);
                        try self.refreshParsed();
                        return true;
                    }
                    return error.PathNotFound;
                }
            }
        }
        return false;
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
        const idx = try self.editableKvIndex(path);
        try rejectMultilineComment(text);
        const raw = try std.fmt.allocPrint(self.arena, "# {s}\n", .{text});
        try self.items.insert(self.arena, idx, .{ .comment = raw });
        self.shiftIndices(idx, 1);
        self.refreshParsed() catch |e| {
            _ = self.items.orderedRemove(idx);
            self.shiftIndices(idx, -1);
            return e;
        };
    }

    /// Insert a comment line immediately after the kv at `path`.
    pub fn addCommentAfter(self: *Document, path: []const u8, text: []const u8) Error!void {
        const idx = try self.editableKvIndex(path);
        try rejectMultilineComment(text);
        try self.ensureItemEndsWithNewline(idx);
        const raw = try std.fmt.allocPrint(self.arena, "# {s}\n", .{text});
        try self.items.insert(self.arena, idx + 1, .{ .comment = raw });
        self.shiftIndices(idx + 1, 1);
        self.refreshParsed() catch |e| {
            _ = self.items.orderedRemove(idx + 1);
            self.shiftIndices(idx + 1, -1);
            return e;
        };
    }

    /// Remove the comment line immediately preceding the kv at `path`,
    /// if there is one. No-op when the previous item isn't a comment.
    pub fn removeCommentBefore(self: *Document, path: []const u8) Error!void {
        const idx = try self.editableKvIndex(path);
        if (idx == 0) return;
        const prev = self.items.items[idx - 1];
        if (prev != .comment) return;
        _ = self.items.orderedRemove(idx - 1);
        self.shiftIndices(idx - 1, -1);
    }

    /// Remove the comment line immediately following the kv at `path`,
    /// if there is one. No-op when the next item isn't a comment.
    pub fn removeCommentAfter(self: *Document, path: []const u8) Error!void {
        const idx = try self.editableKvIndex(path);
        if (idx + 1 >= self.items.items.len) return;
        const next = self.items.items[idx + 1];
        if (next != .comment) return;
        _ = self.items.orderedRemove(idx + 1);
        self.shiftIndices(idx + 1, -1);
    }

    /// Set or replace the trailing comment on a kv line. Pass `null` to
    /// remove an existing trailing comment.
    pub fn setTrailingComment(self: *Document, path: []const u8, text: ?[]const u8) Error!void {
        const idx = try self.editableKvIndex(path);
        if (text) |t| try rejectMultilineComment(t);
        const old_item = self.items.items[idx];
        const old = old_item.kv;

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
            .full_path_segments = old.full_path_segments,
            .value_offset = old.value_offset,
            .value_len = old.value_len,
        } };
        self.refreshParsed() catch |e| {
            self.items.items[idx] = old_item;
            return e;
        };
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
            .header => |h| self.items.items[idx] = .{ .header = .{ .raw = new_raw, .path = h.path, .path_segments = h.path_segments, .is_array = h.is_array } },
            .kv => |k| self.items.items[idx] = .{ .kv = .{
                .raw = new_raw,
                .full_path = k.full_path,
                .full_path_segments = k.full_path_segments,
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

    /// Append a new `[a.b.c]`-style header covering every segment of
    /// `enclosing` in one line, relying on TOML's implicit-super-table
    /// rule rather than emitting a separate header per level. Each
    /// segment is re-encoded so one needing quotes (spaces, dots,
    /// specials) emits valid TOML; `.path`/`.path_segments` stay decoded
    /// so they share identity with kv full paths and `get`.
    fn appendNewSectionSegments(self: *Document, enclosing: []const []const u8) !void {
        const needs_blank = self.items.items.len > 0 and !endsWithBlank(self.items.items);
        if (needs_blank) {
            try self.items.append(self.arena, .{ .blank = "\n" });
        }
        const rendered = try renderHeaderSegments(self.arena, enclosing);
        const raw = try std.fmt.allocPrint(self.arena, "[{s}]\n", .{rendered});
        const path_segments = try dupeSegments(self.arena, enclosing);
        const header_item: Item = .{ .header = .{
            .raw = raw,
            .path = try std.mem.join(self.arena, ".", path_segments),
            .path_segments = path_segments,
            .is_array = false,
        } };
        try self.items.append(self.arena, header_item);
        try self.section_end.put(self.arena, header_item.header.path, self.items.items.len - 1);
    }

    /// Segment-based twin of `findHeaderIndex`, comparing decoded segment
    /// arrays directly instead of the lossy joined string -- so a header
    /// whose own path has a literal-dot segment cannot collide with an
    /// unrelated dotted header.
    fn findHeaderIndexBySegments(self: *const Document, segments: []const []const u8) ?usize {
        for (self.items.items, 0..) |item, i| {
            if (item == .header and segArrayEq(item.header.path_segments, segments)) return i;
        }
        return null;
    }

    /// Segment-based twin of a `kv_index` lookup: scans for the kv line
    /// whose full path segments exactly match `segments`.
    fn findKvIndexBySegments(self: *const Document, segments: []const []const u8) ?usize {
        for (self.items.items, 0..) |item, i| {
            if (item == .kv and segArrayEq(item.kv.full_path_segments, segments)) return i;
        }
        return null;
    }

    /// Where to insert a new kv line addressed to `enclosing` (a table's
    /// full segment path, or `&.{}` for the root pseudo-section): the
    /// index of the last existing item belonging to that section, or null
    /// if there is nothing to append after (root with no kv yet, or a
    /// missing table). Segment-based twin of what `section_end` tracks
    /// for the string-path editors.
    fn sectionAppendPoint(self: *const Document, enclosing: []const []const u8) ?usize {
        if (enclosing.len == 0) {
            var last: ?usize = null;
            for (self.items.items, 0..) |item, i| {
                if (item == .header) break;
                if (item == .kv) last = i;
            }
            return last;
        }
        const header_idx = self.findHeaderIndexBySegments(enclosing) orelse return null;
        const end = findSectionEnd(self.items.items, header_idx);
        var last = header_idx;
        var i = header_idx + 1;
        while (i < end) : (i += 1) if (self.items.items[i] == .kv) {
            last = i;
        };
        return last;
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
        self.items.items[idx].kv.value_len = new_value_bytes.len;
        // inline_layout pointer stays the same -- it was mutated in place.
    }

    fn refreshParsed(self: *Document) !void {
        var aw: Io.Writer.Allocating = .init(self.arena);
        // Do NOT deinit aw: the parser is zero-copy and slices into the emit
        // buffer. The arena reclaims the buffer at Document teardown.
        // (deinit on an arena-backed allocator would rawFree the buffer,
        // making the parsed keys/strings dangle.)
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

/// Elementwise equality of two decoded segment arrays.
fn segArrayEq(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Split a dotted string path into segments the same way the write core
/// always has: naive per-'.' splitting, quote-unaware. This is "today's"
/// splitting (unchanged), just factored out so the string-path editors
/// feed the same segment-based core the segment-taking editors use.
fn segmentsFromPath(arena: Allocator, path: []const u8) Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| try list.append(arena, seg);
    return list.toOwnedSlice(arena);
}

/// Deep-copy `segments` into the arena (outer slice and each segment's
/// bytes) so a stored `path_segments` / `full_path_segments` field
/// outlives a caller-owned or transient source (e.g. a naive split of a
/// caller's string, or a caller's own segment slice).
fn dupeSegments(arena: Allocator, segments: []const []const u8) Error![]const []const u8 {
    const out = try arena.alloc([]const u8, segments.len);
    for (segments, out) |s, *o| o.* = try arena.dupe(u8, s);
    return out;
}

const FormattedKv = struct { line: []const u8, value_offset: usize };

/// Format a `key = value\n` line. The key is re-emitted via the encoder so
/// a decoded special key (spaces, dots, etc.) is quoted into valid TOML.
/// Returns the line and the byte offset where the value text begins, which
/// depends on the emitted key length (it may differ from `key.len`).
fn formatKvLine(arena: Allocator, key: []const u8, value: []const u8) !FormattedKv {
    const key_raw = try encodeKey(arena, key);
    const value_offset: usize = key_raw.len + " = ".len;
    const line = try std.fmt.allocPrint(arena, "{s} = {s}\n", .{ key_raw, value });
    return .{ .line = line, .value_offset = value_offset };
}

fn formatValue(arena: Allocator, value: Value) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try writeInlineValue(&aw.writer, value);
    return arena.dupe(u8, aw.written());
}

fn writeInlineValue(w: *Io.Writer, value: Value) (Io.Writer.Error || error{ NestingTooDeep, OutOfMemory })!void {
    encoder.writeInlineValue(w, value) catch |err| switch (err) {
        // encoder.writeInlineValue delegates to writeValue, which encodes
        // Value.integer (always i64) and never calls writeTypedValue, so
        // IntegerOverflow / UnsupportedType cannot arise here; ExpectedTable
        // is only raised by top-level document encoding. A caller-supplied
        // Value CAN exceed the encoder's depth cap, so NestingTooDeep is a
        // real error and must propagate.
        error.ExpectedTable,
        error.IntegerOverflow,
        error.UnsupportedType,
        => unreachable,
        else => |e| return e,
    };
}

/// A comment is a single source line. Reject any embedded line break so a
/// comment edit cannot splice in a new statement that re-parses live.
fn rejectMultilineComment(text: []const u8) Error!void {
    if (std.mem.indexOfAny(u8, text, "\n\r") != null) return error.InvalidComment;
}

/// True when `path` uses `[N]` array-index syntax, which `get` honors but
/// the structural editors (setLiteral/remove) cannot act on.
fn pathHasArrayIndex(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '[') != null;
}

/// Validate that `raw` is a single TOML value literal, not a fragment that
/// smuggles in extra statements. Wrapping `_v = {raw}` and merely checking
/// that it parses is not enough: a `raw` like `1\n[evil]\npwned=true` parses
/// as MULTIPLE statements and would, once spliced verbatim, inject a table
/// header and reparent unrelated keys. Require the parse to yield exactly the
/// one wrapper key `_v` so the literal can only ever replace one value.
fn validateValueLiteral(arena: Allocator, raw: []const u8) Error!void {
    const wrapped = std.fmt.allocPrint(arena, "_v = {s}", .{raw}) catch return error.OutOfMemory;
    const parsed = parser_mod.parse(arena, wrapped, .{}) catch return error.InvalidValue;
    if (parsed != .table or parsed.table.count() != 1 or parsed.table.get("_v") == null) {
        return error.InvalidValue;
    }
}

/// Mutate the layout in place: locate the entry matching sub_path's
/// head, descend recursively for nested inline tables, replace the
/// leaf entry's value bytes with raw_value. Errors on a sub-path
/// through a scalar.
/// Deep-copy a layout so it can be edited without touching the original
/// (needed for rollback: the editors mutate a layout in place). Byte slices
/// (`open`, `close`, keys, seps, raw values, trailings) are immutable and
/// arena-owned, so they are shared; only the mutable spine -- the entries
/// list and any nested inline-table layouts -- is duplicated.
fn cloneLayout(arena: Allocator, src: *const InlineTableLayout) Error!*InlineTableLayout {
    const out = try arena.create(InlineTableLayout);
    out.* = .{ .open = src.open, .close = src.close, .entries = .empty };
    try out.entries.ensureTotalCapacityPrecise(arena, src.entries.items.len);
    for (src.entries.items) |entry| {
        var copy = entry;
        copy.value = switch (entry.value) {
            .raw => |r| .{ .raw = r },
            .inline_table => |inner| .{ .inline_table = try cloneLayout(arena, inner) },
        };
        out.entries.appendAssumeCapacity(copy);
    }
    return out;
}

fn setInLayout(arena: Allocator, layout: *InlineTableLayout, segments: []const []const u8, raw_value: []const u8) Error!void {
    const head = segments[0];
    const tail = segments[1..];

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
    // `key` is the decoded identity; re-encode it to valid TOML key bytes
    // (quoting spaces/specials) for the emitted `key_raw`.
    const key_raw = try encodeKey(arena, key);
    if (layout.entries.items.len == 0) {
        // Empty inline table: `{}` -> `{ key = value }`.
        // Preserve any existing open/close content by checking if open already
        // ends with a space (e.g., `{ ` from `{ }`).
        const open_has_space = layout.open.len > 1 and layout.open[layout.open.len - 1] == ' ';
        if (!open_has_space) {
            layout.open = try arena.dupe(u8, "{ ");
        }
        try layout.entries.append(arena, .{
            .key_raw = key_raw,
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
    // ",\n  " multi-line), with any inline comment stripped: a comment
    // belongs to its own entry and must never be copied to another one.
    // When only one entry exists, synthesize from open's trailing whitespace
    // (the bytes after `{`).
    const inter_pattern: []const u8 = blk: {
        if (layout.entries.items.len >= 2) {
            break :blk try stripInlineComment(arena, layout.entries.items[last_idx - 1].trailing);
        }
        const open_trail = layout.open[1..]; // bytes after `{`
        break :blk try std.mem.concat(arena, u8, &.{ ",", open_trail });
    };

    if (std.mem.indexOfScalar(u8, last.trailing, '#')) |hash| {
        // The old last entry carries an inline comment. Keep the comment on
        // its entry: add the separating comma before it when missing, end
        // the comment's line, and indent the new entry like its siblings.
        // The bytes after the comment's line break (close-side padding)
        // move to the new entry.
        const nl = std.mem.indexOfScalarPos(u8, last.trailing, hash, '\n');
        const new_entry_trailing: []const u8 = if (nl) |n|
            try arena.dupe(u8, last.trailing[n..])
        else
            "";
        const comma: []const u8 = if (std.mem.indexOfScalar(u8, last.trailing, ',') == null) "," else "";
        const head = if (nl) |n| last.trailing[0..n] else last.trailing;
        const sep = try arena.dupe(u8, last.sep);
        last.trailing = try std.mem.concat(arena, u8, &.{ comma, head, "\n", wsTail(inter_pattern) });
        try layout.entries.append(arena, .{
            .key_raw = key_raw,
            .key = try arena.dupe(u8, key),
            .sep = sep,
            .value = .{ .raw = try arena.dupe(u8, raw_value) },
            .trailing = new_entry_trailing,
        });
        return;
    }

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
        .key_raw = key_raw,
        .key = try arena.dupe(u8, key),
        .sep = try arena.dupe(u8, last.sep),
        .value = .{ .raw = try arena.dupe(u8, raw_value) },
        .trailing = new_entry_trailing,
    });
}

/// Drop an inline `# ...` comment from a trailing-bytes pattern, keeping the
/// comma and the line-break/indent structure around it.
fn stripInlineComment(arena: Allocator, t: []const u8) Error![]const u8 {
    const hash = std.mem.indexOfScalar(u8, t, '#') orelse return arena.dupe(u8, t);
    var head_end = hash;
    while (head_end > 0 and (t[head_end - 1] == ' ' or t[head_end - 1] == '\t')) head_end -= 1;
    const nl = std.mem.indexOfScalarPos(u8, t, hash, '\n') orelse t.len;
    return std.mem.concat(arena, u8, &.{ t[0..head_end], t[nl..] });
}

/// The indentation bytes after the last line break of `pattern`, or an
/// empty slice for a single-line pattern.
fn wsTail(pattern: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, pattern, '\n')) |n| return pattern[n + 1 ..];
    return "";
}

/// Render decoded key segments as a TOML header body, re-encoding each
/// segment so one needing quotes emits valid TOML (`my server` ->
/// `"my server"`, a segment containing a literal `.` like `a.b` ->
/// `"a.b"`). Mirrors the encoder's writePath segment-by-segment quoting.
fn renderHeaderSegments(arena: Allocator, segments: []const []const u8) Error![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    for (segments, 0..) |segment, i| {
        if (i > 0) aw.writer.writeByte('.') catch return error.WriteFailed;
        encoder.writeKey(&aw.writer, segment) catch |e| switch (e) {
            error.WriteFailed => return error.WriteFailed,
            else => unreachable,
        };
    }
    return arena.dupe(u8, aw.written());
}

/// Render a decoded key segment as valid TOML key bytes via the encoder
/// (bare when possible, basic-quoted otherwise). Used wherever a decoded
/// key identity must be emitted as TOML presentation.
fn encodeKey(arena: Allocator, key: []const u8) Error![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    encoder.writeKey(&aw.writer, key) catch |e| switch (e) {
        error.WriteFailed => return error.WriteFailed,
        else => unreachable,
    };
    return arena.dupe(u8, aw.written());
}

/// Remove the entry matching `segments` from layout. Returns true when the
/// entry was found and removed, false when not found. Strips a now-redundant
/// trailing comma from the preceding entry when the removed entry was last.
fn removeFromLayout(arena: Allocator, layout: *InlineTableLayout, segments: []const []const u8) Error!bool {
    const head = segments[0];
    const tail = segments[1..];

    for (layout.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.key, head)) {
            if (tail.len == 0) {
                const removed = entry;
                _ = layout.entries.orderedRemove(i);
                // When the removed entry was last, the new last entry's
                // trailing still carries the inter-entry comma. Replace it
                // with the removed entry's close-side spacing so the padding
                // before `}` stays symmetric (`{ x = 1 }`, not `{ x = 1}`).
                if (i > 0 and i == layout.entries.items.len) {
                    var prev = &layout.entries.items[i - 1];
                    if (std.mem.lastIndexOfScalar(u8, prev.trailing, ',')) |comma_pos| {
                        var all_ws = true;
                        for (prev.trailing[comma_pos + 1 ..]) |c| {
                            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                                all_ws = false;
                                break;
                            }
                        }
                        if (all_ws) {
                            prev.trailing = try arena.dupe(u8, removed.trailing);
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

fn valueFromAny(arena: Allocator, comptime T: type, value: T) (Allocator.Error || error{IntegerOverflow})!Value {
    return value_mod.fromAny(arena, T, value);
}

const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,
};

fn tokenize(doc: *Document, src: []const u8) !void {
    var tok: Tokenizer = .{ .source = src };
    var current_section: []const u8 = "";
    var current_section_segments: []const []const u8 = &.{};

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
            // scanHeader already found the closing bracket(s) quote-aware
            // (a quoted segment may contain `]`); derive the path end from
            // it instead of rescanning naively.
            const closer_len: usize = if (is_array) 2 else 1;
            const path_end = if (after_header >= path_start + closer_len)
                after_header - closer_len
            else
                path_start;
            const header_path = std.mem.trim(u8, src[path_start..path_end], " \t");
            // Decode into segments first (the collision-free identity),
            // then derive the joined `.path` from them: this is index by
            // their decoded dotted path so kv full_paths, section lookups,
            // and `get` all share one key identity, while `path_segments`
            // keeps the unjoined form segment-based resolution needs.
            const path_segments = parser_mod.decodeKeyPathSegments(doc.arena, header_path) catch blk: {
                const one = try doc.arena.alloc([]const u8, 1);
                one[0] = header_path;
                break :blk one;
            };
            const owned_path = try std.mem.join(doc.arena, ".", path_segments);

            const header_item: Item = .{ .header = .{
                .raw = raw,
                .path = owned_path,
                .path_segments = path_segments,
                .is_array = is_array,
            } };
            try doc.items.append(doc.arena, header_item);
            current_section = owned_path;
            current_section_segments = path_segments;
            try doc.section_end.put(doc.arena, owned_path, doc.items.items.len - 1);
            if (is_array) try doc.aot_paths.put(doc.arena, owned_path, {});

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
        // The editor index keys kv lines by their DECODED dotted path so a
        // quoted/literal/escaped key resolves under the same identity as
        // `get` (which reads the decoded value tree). `kv.raw` still holds
        // the source bytes for lossless emit. Segments decode first (the
        // collision-free identity); `full_path`/`key_decoded` are then
        // just the joined form, kept for the string-path editors.
        const key_segments = parser_mod.decodeKeyPathSegments(doc.arena, key_raw) catch blk: {
            const one = try doc.arena.alloc([]const u8, 1);
            one[0] = key_raw;
            break :blk one;
        };
        const full_path_segments = if (current_section_segments.len == 0)
            key_segments
        else
            try std.mem.concat(doc.arena, []const u8, &.{ current_section_segments, key_segments });
        const full_path = try std.mem.join(doc.arena, ".", full_path_segments);
        const value_offset: usize = value_start - line_start;
        const value_len: usize = value_end - value_start;

        const value_text = src[value_start..value_end];
        const inline_layout: ?*InlineTableLayout = if (value_text.len > 0 and value_text[0] == '{')
            try parseInlineLayout(doc.arena, value_text, 0)
        else
            null;

        const kv_item: Item = .{ .kv = .{
            .raw = raw,
            .full_path = full_path,
            .full_path_segments = full_path_segments,
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

/// Scan a (possibly dotted, possibly quoted) TOML key starting at `pos`.
/// Returns the index of the byte ending the key span: the last non-blank
/// byte of the key, plus one. Quote-aware so a quoted key may contain
/// spaces, tabs, `=`, and dots without terminating the scan; dotted keys
/// span across the dots (and any surrounding whitespace) too. Stops at the
/// unquoted `=` separator, a newline, or end of input.
fn scanKey(src: []const u8, pos: usize) usize {
    var i = pos;
    var last_nonblank = pos;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '"' or c == '\'') {
            i = scanQuotedString(src, i, c, c == '"');
            last_nonblank = i;
            i -= 1; // loop's increment re-advances
            continue;
        }
        if (c == '=' or c == '\n') break;
        if (c != ' ' and c != '\t' and c != '\r') last_nonblank = i + 1;
    }
    return last_nonblank;
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

/// Nesting ceiling for the document-model inline-table layout parser,
/// mirroring the strict parser's max_depth so both reject the same
/// adversarial inputs. tokenize() runs this BEFORE the strict parser, so
/// without an own bound a deeply nested `{a={a=...}}` would overflow the
/// stack here first.
const max_layout_depth: usize = (parser_mod.ParseOptions{}).max_depth;

/// Parse inline-table value bytes (exactly `{` ... `}`) into a
/// structured layout. Allocates the layout struct, entry list, and
/// any recursive nested layouts in `arena`. `depth` is the current
/// nesting level; recursion past `max_layout_depth` returns
/// `error.NestingTooDeep` rather than overflowing the stack.
fn parseInlineLayout(arena: Allocator, value_bytes: []const u8, depth: usize) Error!*InlineTableLayout {
    if (depth >= max_layout_depth) return error.NestingTooDeep;
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
        if (value_bytes[pos] == '"' or value_bytes[pos] == '\'') {
            const allow_escape = value_bytes[pos] == '"';
            const quote = value_bytes[pos];
            pos = scanQuotedString(value_bytes, pos, quote, allow_escape);
        } else {
            while (pos < value_bytes.len) : (pos += 1) {
                const c = value_bytes[pos];
                if (c == ' ' or c == '\t' or c == '=') break;
                if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
            }
        }
        const key_raw = value_bytes[key_start..pos];
        // Decoded identity for matching: quotes stripped, escapes interpreted,
        // so it lines up with the decoded paths callers pass to set/remove.
        const key_text = parser_mod.decodeKeyPath(arena, key_raw) catch key_raw;

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
            const inner_layout = try parseInlineLayout(arena, inner_bytes, depth + 1);
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
    // The cached value tree must reflect the edit, not the original.
    try testing.expectEqual(@as(i64, 9999), doc.get("server.port").?.integer);
    try testing.expectEqual(@as(i64, 9999), doc.getT(i64, "server.port").?);
}

test "document: get/getT see scalar edits via set/setValue/setLiteral" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\name = "alpha"
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    , .{});

    try doc.setLiteral("server.host", "\"h\"");
    try testing.expectEqualStrings("h", doc.get("server.host").?.string);

    try doc.set("server.port", @as(i64, 9999));
    try testing.expectEqual(@as(i64, 9999), doc.get("server.port").?.integer);

    try doc.setValue("name", .{ .string = "beta" });
    try testing.expectEqualStrings("beta", doc.get("name").?.string);
}

test "document: quoted kv key is editable by decoded identity" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\"weird key" = 1
        \\
    , .{});

    try testing.expectEqual(@as(i64, 1), doc.get("weird key").?.integer);

    try doc.setLiteral("weird key", "2");
    try testing.expectEqual(@as(i64, 2), doc.get("weird key").?.integer);

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("\"weird key\" = 2\n", aw.written());
}

test "document: quoted kv key supports remove and comment editors" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\"weird key" = 1
        \\
    , .{});

    try doc.setTrailingComment("weird key", "x");
    try doc.addCommentBefore("weird key", "note");
    {
        var aw: Io.Writer.Allocating = .init(arena.allocator());
        defer aw.deinit();
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("# note\n\"weird key\" = 1  # x\n", aw.written());
    }

    try doc.remove("weird key");
    {
        var aw: Io.Writer.Allocating = .init(arena.allocator());
        defer aw.deinit();
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("# note\n", aw.written());
    }
}

test "document: key with escape sequence editable by decoded form" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\"a\tb" = 1
        \\
    , .{});

    // Decoded key contains a literal tab.
    try testing.expectEqual(@as(i64, 1), doc.get("a\tb").?.integer);
    try doc.setLiteral("a\tb", "2");
    try testing.expectEqual(@as(i64, 2), doc.get("a\tb").?.integer);

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    // Source bytes preserved verbatim for lossless emit.
    try testing.expectEqualStrings("\"a\\tb\" = 2\n", aw.written());
}

test "document: failed scalar replace leaves document unchanged (atomic)" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\x = 1
        \\
    , .{});

    // A value the up-front validator rejects must leave the document
    // untouched. (The reparse-rollback path -- where a literal passes
    // up-front validation but yields an invalid document on reparse -- is
    // exercised separately for replace and insert.)
    try testing.expectError(error.InvalidValue, doc.setLiteral("x", "not toml here"));
    try testing.expectEqual(@as(i64, 1), doc.get("x").?.integer);

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("x = 1\n", aw.written());
}

test "document: quoted header path indexes kv by decoded identity" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\["a b"]
        \\k = 1
        \\
    , .{});

    try testing.expectEqual(@as(i64, 1), doc.get("a b.k").?.integer);
    try doc.setLiteral("a b.k", "2");
    try testing.expectEqual(@as(i64, 2), doc.get("a b.k").?.integer);
}

test "document: header with a bracket inside a quoted segment is editable" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\["a]b"]
        \\x = 1
        \\
    , .{});

    try testing.expectEqual(@as(i64, 1), doc.get("a]b.x").?.integer);
    try doc.setLiteral("a]b.x", "2");
    try testing.expectEqual(@as(i64, 2), doc.get("a]b.x").?.integer);

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[\"a]b\"]\nx = 2\n", aw.written());
}

test "document: editors refuse paths through arrays-of-tables" {
    const src =
        \\[[users]]
        \\name = "a"
        \\[[users]]
        \\name = "b"
        \\
    ;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{});

    // Direction 1: `get` cannot address through the array without an index,
    // so the editors must refuse rather than silently edit the LAST element.
    try testing.expect(doc.get("users.name") == null);
    try testing.expectError(error.UnsupportedPath, doc.setLiteral("users.name", "\"c\""));
    try testing.expectError(error.UnsupportedPath, doc.remove("users.name"));
    try testing.expectError(error.UnsupportedPath, doc.setTrailingComment("users.name", "hm"));
    try testing.expectError(error.UnsupportedPath, doc.addCommentBefore("users.name", "hm"));

    // Direction 2: the indexed form IS readable, and the editors reject it
    // explicitly as unsupported (no silent misdirection either way).
    try testing.expectEqualStrings("a", doc.get("users[0].name").?.string);
    try testing.expectEqualStrings("b", doc.get("users[1].name").?.string);
    try testing.expectError(error.UnsupportedPath, doc.setLiteral("users[1].name", "\"c\""));

    // Nothing was modified.
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "document: set over a quoted-string value replaces the whole token" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = "8080"
        \\
    , .{});

    try doc.set("port", @as(i64, 9090));

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    // The whole value token (quotes included) is replaced, not spliced
    // inside the quotes.
    try testing.expectEqualStrings("port = 9090\n", aw.written());
    try testing.expectEqual(@as(i64, 9090), doc.get("port").?.integer);
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

test "document: setLiteral appends before a trailing blank and next header" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
        \\[other]
        \\x = 1
        \\
    , .{});

    try doc.setLiteral("server.host", "\"h\"");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(
        "[server]\nport = 8080\nhost = \"h\"\n\n[other]\nx = 1\n",
        aw.written(),
    );
}

test "document: setLiteral appends before a trailing comment and next header" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\# trailing comment
        \\[other]
        \\x = 1
        \\
    , .{});

    try doc.setLiteral("server.host", "\"h\"");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(
        "[server]\nport = 8080\nhost = \"h\"\n# trailing comment\n[other]\nx = 1\n",
        aw.written(),
    );
}

test "document: setLiteral appends before a trailing blank at EOF in the last section" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
        \\
    , .{});

    try doc.setLiteral("server.host", "\"h\"");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[server]\nport = 8080\nhost = \"h\"\n\n", aw.written());
}

test "document: setLiteral into a header-only section with no existing kv" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[empty]
        \\[other]
        \\x = 1
        \\
    , .{});

    try doc.setLiteral("empty.host", "\"h\"");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[empty]\nhost = \"h\"\n[other]\nx = 1\n", aw.written());
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

test "document: remove first, middle, last, and only kv" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Only kv in the document (section_end for "" points at index 0).
    var only = try Document.parse(arena.allocator(), "x = 1\n", .{});
    try only.remove("x");
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try only.emit(&aw.writer);
    try testing.expectEqualStrings("", aw.written());
    try testing.expect(only.get("x") == null);

    var doc = try Document.parse(arena.allocator(),
        \\a = 1
        \\b = 2
        \\c = 3
        \\
    , .{});
    try doc.remove("a");
    try doc.remove("b");
    try doc.remove("c");
    var aw2: Io.Writer.Allocating = .init(arena.allocator());
    defer aw2.deinit();
    try doc.emit(&aw2.writer);
    try testing.expectEqualStrings("", aw2.written());

    // Middle then last, checking survivors stay addressable/editable.
    var doc2 = try Document.parse(arena.allocator(),
        \\a = 1
        \\b = 2
        \\c = 3
        \\
    , .{});
    try doc2.remove("b");
    try doc2.remove("c");
    try doc2.set("d", @as(i64, 4));
    var aw3: Io.Writer.Allocating = .init(arena.allocator());
    defer aw3.deinit();
    try doc2.emit(&aw3.writer);
    try testing.expectEqualStrings("a = 1\nd = 4\n", aw3.written());
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

test "document: append to inline table does not duplicate entry comments" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "p = {\n  a = 1, # note\n  b = 2\n}\n", .{});

    try doc.setLiteral("p.c", "3");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    try testing.expectEqualStrings("p = {\n  a = 1, # note\n  b = 2,\n  c = 3\n}\n", out);
    try testing.expectEqual(@as(i64, 3), doc.get("p.c").?.integer);
}

test "document: append after a commented last inline entry keeps its comment" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "q = {\n  a = 1, # note\n}\n", .{});

    try doc.setLiteral("q.b", "2");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    try testing.expectEqualStrings("q = {\n  a = 1, # note\n  b = 2\n}\n", out);
    try testing.expectEqual(@as(i64, 2), doc.get("q.b").?.integer);
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

test "Document.parse: deeply nested inline table errors instead of overflowing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `x = ` + 12000 `{a=` ... : the document model tokenizes inline-table
    // layout recursively, BEFORE the strict parser's depth guard runs. Without
    // its own bound this overflows the stack; it must return NestingTooDeep.
    // The brace count bounds the construction.
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "x = ");
    var i: usize = 0;
    while (i < 12000) : (i += 1) try src.appendSlice(a, "{a=");
    try src.append(a, '1');
    i = 0;
    while (i < 12000) : (i += 1) try src.append(a, '}');
    try testing.expectError(error.NestingTooDeep, Document.parse(a, src.items, .{}));
}

test "Document.setValue: value deeper than the encoder cap errors, no panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.parse(a, "x = 1\n", .{});

    // 200 nested single-element arrays (past the encoder's depth cap).
    var deep: Value = .{ .integer = 1 };
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var arr: std.ArrayList(Value) = .empty;
        try arr.append(a, deep);
        deep = .{ .array = arr };
    }
    try testing.expectError(error.NestingTooDeep, doc.setValue("x", deep));

    // The document is unchanged and still editable.
    try testing.expectEqual(@as(i64, 1), doc.get("x").?.integer);
}

test "parseInlineLayout: empty table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{}", 0);
    try testing.expectEqual(@as(usize, 0), layout.entries.items.len);
    try testing.expectEqualStrings("{", layout.open);
    try testing.expectEqualStrings("}", layout.close);
}

test "parseInlineLayout: single key tight spacing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{x=1}", 0);
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
    const layout = try parseInlineLayout(arena.allocator(), "{ x = 1, y = 2 }", 0);
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
    const layout = try parseInlineLayout(arena.allocator(), "{ a = 1, inner = { x = 9 }, b = 2 }", 0);
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
    const layout = try parseInlineLayout(arena.allocator(), "{ \"weird key\" = 1 }", 0);
    try testing.expectEqual(@as(usize, 1), layout.entries.items.len);
    const e = layout.entries.items[0];
    try testing.expectEqualStrings("weird key", e.key);
    try testing.expectEqualStrings("\"weird key\"", e.key_raw);
}

test "parseInlineLayout: string value with braces inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{ msg = \"a, b { c\", n = 1 }", 0);
    try testing.expectEqual(@as(usize, 2), layout.entries.items.len);
    try testing.expectEqualStrings("\"a, b { c\"", layout.entries.items[0].value.raw);
    try testing.expectEqualStrings("1", layout.entries.items[1].value.raw);
}

test "parseInlineLayout: trailing comma (TOML 1.1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const layout = try parseInlineLayout(arena.allocator(), "{ a = 1, b = 2, }", 0);
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
    const layout = try parseInlineLayout(arena.allocator(), "{a=1,}", 0);
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

test "document: failed inline-table edit rolls back to unchanged document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { x = 1, y = 2 }
        \\
    , .{});

    // `1 # x` validates as a standalone value literal (the `#` is a trailing
    // comment), but spliced into the single-line inline table its `#` comments
    // out the closing brace, so the reparse fails. setLiteral must roll the
    // mutated layout + kv raw back, leaving the document byte-identical and
    // its parsed tree intact.
    try testing.expectError(error.TomlParseError, doc.setLiteral("point.x", "1 # x"));

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { x = 1, y = 2 }\n", aw.written());
    try testing.expectEqual(@as(i64, 1), doc.get("point.x").?.integer);
    try testing.expectEqual(@as(i64, 2), doc.get("point.y").?.integer);

    // The rollback must leave the layout editable: a subsequent valid edit
    // still works (proving the original layout, not a half-mutated clone, is
    // what remained live).
    try doc.setLiteral("point.x", "99");
    aw.clearRetainingCapacity();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { x = 99, y = 2 }\n", aw.written());
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

test "Document.set: u64 >= 2^63 returns IntegerOverflow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Out-of-range value must return an error, not panic.
    var doc = try Document.parse(arena.allocator(), "port = 8080", .{});
    const big: u64 = @as(u64, std.math.maxInt(i64)) + 1;
    try testing.expectError(error.IntegerOverflow, doc.set("port", big));
    // In-range u64 must succeed and the emitted source must reflect it.
    try doc.set("port", @as(u64, 9000));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "9000") != null);
}

test "Document.parse accepts a normal small input (guard no false positive)" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "title = \"toml\"\n", .{});
    try testing.expectEqualStrings("toml", doc.get("title").?.string);
}

test "document: new section with a space in the name re-encodes the header" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
    , .{});

    // The section "my server" does not exist yet. Its decoded name has a
    // space, so the emitted header must quote it: ["my server"].
    try doc.setLiteral("my server.port", "80");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "[\"my server\"]") != null);
    // The bare, unquoted form would be invalid TOML and must not appear.
    try testing.expect(std.mem.indexOf(u8, out, "[my server]") == null);
    // The document round-trips and the value is reachable by decoded path.
    try testing.expectEqual(@as(i64, 80), doc.get("my server.port").?.integer);
}

test "document: dotted new section re-encodes each segment" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "", .{});

    // First segment is a bare key, second needs quoting.
    try doc.setLiteral("a.my key.v", "1");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "[a.\"my key\"]") != null);
    try testing.expectEqual(@as(i64, 1), doc.get("a.my key.v").?.integer);
}

test "document: new inline-table key with a space is quoted on emit" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { a = 1 }
        \\
    , .{});

    try doc.setLiteral("point.my key", "2");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { a = 1, \"my key\" = 2 }\n", aw.written());
    try testing.expectEqual(@as(i64, 2), doc.get("point.my key").?.integer);
}

test "document: inline-table escape key updates in place, no duplicate" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\point = { "a\tb" = 1 }
        \\
    , .{});

    // Callers pass the DECODED path (literal tab); this must match the
    // existing entry and update it, not append a duplicate.
    try doc.setLiteral("point.a\tb", "2");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    // Exactly one entry, source key bytes preserved, value updated.
    try testing.expectEqualStrings("point = { \"a\\tb\" = 2 }\n", aw.written());
    try testing.expectEqual(@as(i64, 2), doc.get("point.a\tb").?.integer);
}

test "document: failed insert (reparse rollback) leaves document unchanged" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\[server]
        \\port = 8080
        \\
    , .{});

    // Inserting `server.port` again as a NEW key (the path is registered, so
    // this would normally replace; instead use a sibling that collides on
    // reparse). A duplicate dotted key surfaced via a fresh path that the
    // strict reparse rejects must roll back, leaving items/index/source as
    // they were and reporting the parse error -- not a corrupted document.
    //
    // `port` already lives under [server]; defining the same key as a bare
    // top-level dotted key `server.port` collides on reparse.
    const before_emit = blk: {
        var aw: Io.Writer.Allocating = .init(arena.allocator());
        defer aw.deinit();
        try doc.emit(&aw.writer);
        break :blk try arena.allocator().dupe(u8, aw.written());
    };

    try testing.expectError(error.TomlParseError, doc.setLiteral("server.port.deeper", "1"));

    // Document is byte-identical to before the failed insert.
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(before_emit, aw.written());

    // And still fully functional afterwards: an unrelated valid insert works.
    try doc.setLiteral("server.tls", "true");
    try testing.expectEqual(true, doc.get("server.tls").?.boolean);
    try testing.expectEqual(@as(i64, 8080), doc.get("server.port").?.integer);
}

test "document: setTrailingComment rejects newline injection (atomic, cache consistent)" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\
    , .{});

    // A newline in the comment text would splice a real `injected = 1` key
    // that re-parses live. It must be rejected before any mutation.
    try testing.expectError(error.InvalidComment, doc.setTrailingComment("port", "c\ninjected = 1"));

    // Document is byte-identical and the cached tree never saw an injection.
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("port = 8080\n", aw.written());
    try testing.expectEqual(@as(i64, 8080), doc.get("port").?.integer);
    try testing.expect(doc.get("injected") == null);

    // A lone carriage return is rejected too.
    try testing.expectError(error.InvalidComment, doc.setTrailingComment("port", "a\rb"));
}

test "document: addCommentBefore/After reject newline; normal comment keeps cache consistent" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\port = 8080
        \\
    , .{});

    try testing.expectError(error.InvalidComment, doc.addCommentBefore("port", "x\ny = 1"));
    try testing.expectError(error.InvalidComment, doc.addCommentAfter("port", "x\ny = 1"));

    // Untouched after the rejected edits.
    {
        var aw: Io.Writer.Allocating = .init(arena.allocator());
        defer aw.deinit();
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("port = 8080\n", aw.written());
    }

    // A `#` inside the body is harmless and allowed.
    try doc.addCommentBefore("port", "see # ref");
    try doc.setTrailingComment("port", "default");
    {
        var aw: Io.Writer.Allocating = .init(arena.allocator());
        defer aw.deinit();
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("# see # ref\nport = 8080  # default\n", aw.written());
    }
    // The cached tree agrees with the emitted bytes: the value is intact and
    // re-parses, and no stray key was introduced by the comment edits.
    try testing.expectEqual(@as(i64, 8080), doc.get("port").?.integer);
}

test "document: setLiteral rejects multi-statement injection (atomic, no reparent)" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\name = "keep"
        \\port = 8080
        \\
    , .{});

    // `1\n[evil]\npwned=true` would inject `[evil]` and reparent `name`.
    try testing.expectError(error.InvalidValue, doc.setLiteral("port", "1\n[evil]\npwned=true"));

    // Atomic: byte-identical, no injected table, no reparented key.
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("name = \"keep\"\nport = 8080\n", aw.written());
    try testing.expectEqual(@as(i64, 8080), doc.get("port").?.integer);
    try testing.expectEqualStrings("keep", doc.get("name").?.string);
    try testing.expect(doc.get("evil.pwned") == null);

    // A genuine single-value literal still works and stays consistent.
    try doc.setLiteral("port", "42");
    try testing.expectEqual(@as(i64, 42), doc.get("port").?.integer);
    aw.clearRetainingCapacity();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("name = \"keep\"\nport = 42\n", aw.written());
}

test "document: remove last inline member keeps the space before the brace" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\t = { x = 1, y = 2 }
        \\
    , .{});

    try doc.remove("t.y");

    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    // Symmetric spacing: `{ x = 1 }`, not `{ x = 1}`.
    try testing.expectEqualStrings("t = { x = 1 }\n", aw.written());
}

test "document: setLiteral/remove reject array-index paths" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(),
        \\arr = [1, 2, 3]
        \\
    , .{});

    // `get` reads element 0; the editors must not silently mint an `arr[0]`
    // literal key (or PathNotFound on remove) for the same path string.
    try testing.expectError(error.UnsupportedPath, doc.setLiteral("arr[0]", "9"));
    try testing.expectError(error.UnsupportedPath, doc.remove("arr[0]"));

    // No bogus key was created; the document is unchanged.
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("arr = [1, 2, 3]\n", aw.written());
    try testing.expect(doc.get("arr[0]").?.integer == 1);
}

test "document: simple bare-key new section still emits unquoted" {
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
    try testing.expectEqualStrings("[server]\nport = 8080\n\n[client]\ntimeout = 30\n", aw.written());
}

test "Document.empty bootstraps a document with no source bytes" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.empty(a, .{});

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("", aw.written());
    try testing.expect(!doc.has("a.b.c"));

    try doc.set("a.b.c", @as(i64, 1));

    var aw2: Io.Writer.Allocating = .init(a);
    defer aw2.deinit();
    try doc.emit(&aw2.writer);
    try testing.expectEqualStrings("[a.b]\nc = 1\n", aw2.written());
    try testing.expectEqual(@as(i64, 1), doc.getT(i64, "a.b.c").?);
}

test "setValueSegments creates a missing 3-level table chain, preserving surrounding trivia" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "# keep me\ntitle = \"toml\"\n";
    var doc = try Document.parse(a, src, .{});

    try doc.setValueSegments(&.{ "a", "b", "c" }, .{ .integer = 9 });

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("# keep me\ntitle = \"toml\"\n\n[a.b]\nc = 9\n", aw.written());
    try testing.expectEqual(@as(i64, 9), doc.get("a.b.c").?.integer);
}

test "setSegments creates missing intermediates through a partially existing prefix" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a,
        \\[a]
        \\x = 1
        \\
    , .{});

    try doc.setSegments(&.{ "a", "b", "c" }, @as(i64, 2));

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[a]\nx = 1\n\n[a.b]\nc = 2\n", aw.written());
    try testing.expectEqual(@as(i64, 2), doc.get("a.b.c").?.integer);
    try testing.expectEqual(@as(i64, 1), doc.get("a.x").?.integer);
}

test "setValueSegments creates the single literal key \"a.b\", not a nested a->b path" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, "", .{});

    try doc.setValueSegments(&.{"a.b"}, .{ .string = "x" });

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("\"a.b\" = \"x\"\n", aw.written());

    // Re-parse independently and confirm the root has exactly one key, the
    // literal "a.b" -- not a table "a" containing key "b".
    var check = try Document.parse(a, aw.written(), .{});
    try testing.expectEqual(@as(usize, 1), check.parsed.table.count());
    try testing.expectEqualStrings("x", check.parsed.table.get("a.b").?.string);
    try testing.expect(check.parsed.table.get("a") == null);
}

test "setSegments dispatches native types like set" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, "", .{});

    try doc.setSegments(&.{ "server", "host" }, "example.com");

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[server]\nhost = \"example.com\"\n", aw.written());
    try testing.expectEqualStrings("example.com", doc.get("server.host").?.string);
}

test "setValueSegments quotes and escapes a segment needing it" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, "", .{});

    // The segment itself contains a double quote and a backslash.
    try doc.setValueSegments(&.{"a\"b\\c"}, .{ .integer = 1 });

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\" = 1\n", aw.written());

    var check = try Document.parse(a, aw.written(), .{});
    try testing.expectEqual(@as(usize, 1), check.parsed.table.count());
    try testing.expectEqual(@as(i64, 1), check.parsed.table.get("a\"b\\c").?.integer);
}

test "removeSegments removes a quoted-dotted key without touching a same-named table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a,
        \\"a.b" = 1
        \\other = 2
        \\
    , .{});

    try doc.removeSegments(&.{"a.b"});

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("other = 2\n", aw.written());
    try testing.expectError(error.PathNotFound, doc.removeSegments(&.{"a.b"}));
}

test "existing bare-key path set is byte-identical via string path and segments" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "[a]\nx = 1\ny = 2\n";

    var via_path = try Document.parse(a, src, .{});
    try via_path.setLiteral("a.x", "99");

    var via_seg = try Document.parse(a, src, .{});
    try via_seg.setValueSegments(&.{ "a", "x" }, .{ .integer = 99 });

    const wanted = "[a]\nx = 99\ny = 2\n";
    var aw1: Io.Writer.Allocating = .init(a);
    defer aw1.deinit();
    try via_path.emit(&aw1.writer);
    try testing.expectEqualStrings(wanted, aw1.written());

    var aw2: Io.Writer.Allocating = .init(a);
    defer aw2.deinit();
    try via_seg.emit(&aw2.writer);
    try testing.expectEqualStrings(wanted, aw2.written());
}

test "an array index in a missing tail is still rejected, never fabricated" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "", .{});

    try testing.expectError(error.UnsupportedPath, doc.set("missing[0].c", true));
    try testing.expectError(error.UnsupportedPath, doc.set("missing[0]", true));
}

test "setValueSegments rejects an empty segment list" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "", .{});

    try testing.expectError(error.UnsupportedPath, doc.setValueSegments(&.{}, .{ .integer = 1 }));
    try testing.expectError(error.UnsupportedPath, doc.removeSegments(&.{}));
}

test "setSegments creates a sub-key inside an existing inline table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, "point = { x = 1 }\n", .{});

    try doc.setSegments(&.{ "point", "y" }, @as(i64, 2));

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("point = { x = 1, y = 2 }\n", aw.written());
    try testing.expectEqual(@as(i64, 2), doc.get("point.y").?.integer);
}

test "setValueSegments refuses a path through an array-of-tables" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a,
        \\[[items]]
        \\name = "a"
        \\
    , .{});

    try testing.expectError(error.UnsupportedPath, doc.setValueSegments(&.{ "items", "name" }, .{ .string = "b" }));
}
