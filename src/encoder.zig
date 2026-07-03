//! TOML 1.1 encoder.
//!
//! Walks a `Value` tree (which must be a table at the root) and writes
//! canonical TOML to a `std.Io.Writer`. Output round-trips through
//! `parse` to a structurally-equal `Value`. Tables preserve insertion
//! order; arrays-of-tables are emitted as `[[header]]` sections; inline
//! tables are used only inside arrays of inline tables. Keys outside
//! `[A-Za-z0-9_-]` are quoted; strings escape control characters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.array_hash_map.String;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const testing = std.testing;
const v = @import("value.zig");

pub const Value = v.Value;

/// `IntegerOverflow`: a Zig integer value cannot be represented as a TOML
/// integer (i64). Distinct from decode's `Overflow`, which means a TOML
/// value does not fit the target Zig type.
pub const EncodeError = std.Io.Writer.Error || error{ ExpectedTable, NestingTooDeep, OutOfMemory, IntegerOverflow, UnsupportedType };

const max_path_depth = 256;

/// Maximum table / array / inline-table nesting depth. Parsed trees are
/// already capped by the parser's `max_depth` (128); this constant
/// matches that default so hand-built `Value` trees get the same bound,
/// returning `error.NestingTooDeep` rather than overflowing the stack.
const max_encode_depth = 128;

/// Encode `value` as TOML to `w`. `value` must be `.table`.
pub fn encode(w: *Io.Writer, value: Value) EncodeError!void {
    if (value != .table) return error.ExpectedTable;

    var path_buf: [max_path_depth * @sizeOf([]const u8)]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    var path: ArrayList([]const u8) = .empty;
    defer path.deinit(fba.allocator());

    try encodeTable(w, value.table, &path, fba.allocator(), true, 0);
}

/// Encode a typed Zig value as TOML, consulting any `toml_*`
/// annotations declared on the type. The top-level type must be a
/// struct (the root TOML value is always a table).
///
/// Use this when the source is a typed Zig struct. Use `encode` when
/// you have a hand-built `Value` tree.
pub fn encodeTyped(w: *std.Io.Writer, comptime T: type, value: T, arena: std.mem.Allocator) EncodeError!void {
    if (@typeInfo(T) != .@"struct") @compileError("encodeTyped: root must be a struct, got " ++ @typeName(T));

    var path_buf: [max_path_depth * @sizeOf([]const u8)]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    var path: ArrayList([]const u8) = .empty;
    defer path.deinit(fba.allocator());

    try encodeTypedTable(T, value, w, &path, fba.allocator(), arena, true);
}

fn encodeTaggedUnion(
    comptime T: type,
    value: T,
    w: *std.Io.Writer,
    path: *ArrayList([]const u8),
    path_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    is_root: bool,
) EncodeError!void {
    const tag_field = T.toml_tag;
    const active_tag = std.meta.activeTag(value);

    inline for (@typeInfo(T).@"union".fields) |union_field| {
        if (active_tag == @field(std.meta.Tag(T), union_field.name)) {
            const variant_name = union_field.name;
            const effective_name = comptime renamedKey(T, variant_name);

            // Emit the discriminator first.
            try writeKey(w, tag_field);
            try w.writeAll(" = ");
            try writeQuotedString(w, effective_name);
            try w.writeByte('\n');

            // Pass 1: flat scalars from the payload.
            // Pass 2: sub-tables from the payload.
            const PayloadType = union_field.type;
            if (PayloadType != void) {
                const payload = @field(value, variant_name);
                // true because the discriminator key was already emitted
                // above, so emitStructSubTables must insert a blank line
                // before any sub-table section header.
                var has: bool = true;
                try emitFlatScalars(PayloadType, payload, w, arena, &has);
                try emitStructSubTables(PayloadType, payload, w, path, path_alloc, arena, is_root, &has);
            }
            return;
        }
    }
    unreachable;
}

fn encodeTypedTable(
    comptime T: type,
    value: T,
    w: *std.Io.Writer,
    path: *ArrayList([]const u8),
    path_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    is_root: bool,
) EncodeError!void {
    var has_any_kv = false;

    // Pass 1: scalars (recursively expanding flattened fields).
    try emitFlatScalars(T, value, w, arena, &has_any_kv);

    // Pass 2: sub-tables (descending into flattened fields, skipping skipped fields).
    try emitStructSubTables(T, value, w, path, path_alloc, arena, is_root, &has_any_kv);
}

// emitStructSubTables is the shared pass-2 body: walks `T`'s fields and
// emits sub-table sections. For flattened fields it descends into the inner
// type without pushing the field's own key (flattening means "merge at this
// level"). For tagged-union fields it delegates to encodeTaggedUnion.
fn emitStructSubTables(
    comptime T: type,
    value: T,
    w: *std.Io.Writer,
    path: *ArrayList([]const u8),
    path_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    is_root: bool,
    has_any_kv: *bool,
) EncodeError!void {
    const s = @typeInfo(T).@"struct";
    inline for (s.fields) |field| {
        if (comptime isSkipped(T, field.name)) continue;
        const fv = @field(value, field.name);
        if (comptime isFlattened(T, field.name)) {
            // Descend into the flattened struct's sub-tables at the current
            // path level (do NOT push the flattened field's own key).
            try emitStructSubTables(field.type, fv, w, path, path_alloc, arena, is_root, has_any_kv);
            continue;
        }
        if (comptime fieldHasSubTable(field.type)) {
            const eff_key = comptime renamedKey(T, field.name);
            const is_opt = comptime @typeInfo(field.type) == .optional;
            const ActualType = comptime if (is_opt) @typeInfo(field.type).optional.child else field.type;
            // Unwrap ?T: null -> absent section (mirrors decode's absent-table -> null).
            const should_emit: bool = if (comptime is_opt) fv != null else true;
            if (should_emit) {
                const actual_val: ActualType = if (comptime is_opt) fv.? else fv;
                if (comptime arrayOfTablesChild(ActualType)) |Elem| {
                    try emitArrayOfTables(Elem, actual_val, eff_key, w, path, path_alloc, arena, is_root, has_any_kv);
                } else {
                    try path.append(path_alloc, eff_key);
                    defer _ = path.pop();
                    if (has_any_kv.* or !is_root) try w.writeByte('\n');
                    has_any_kv.* = true;
                    try w.writeByte('[');
                    try writePath(w, path.items);
                    try w.writeAll("]\n");
                    if (comptime (@typeInfo(ActualType) == .@"union" and @hasDecl(ActualType, "toml_tag"))) {
                        try encodeTaggedUnion(ActualType, actual_val, w, path, path_alloc, arena, false);
                    } else {
                        try encodeTypedTable(ActualType, actual_val, w, path, path_alloc, arena, false);
                    }
                }
            }
        }
    }
}

// Emit a slice/array of sub-tables as consecutive `[[eff_key]]` sections, one
// per element, in order. `Elem` is the element type (possibly `?SubTable`); a
// null element is skipped, as TOML arrays-of-tables cannot hold a null entry.
// Nested arrays-of-tables render correctly because each element's body is
// emitted via encodeTypedTable at the pushed path (`[[a]]` then `[[a.b]]`).
fn emitArrayOfTables(
    comptime Elem: type,
    value: anytype,
    eff_key: []const u8,
    w: *std.Io.Writer,
    path: *ArrayList([]const u8),
    path_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    is_root: bool,
    has_any_kv: *bool,
) EncodeError!void {
    const is_elem_opt = comptime @typeInfo(Elem) == .optional;
    const ElemActual = comptime if (is_elem_opt) @typeInfo(Elem).optional.child else Elem;

    try path.append(path_alloc, eff_key);
    defer _ = path.pop();
    for (value) |elem| {
        const item: ElemActual = if (comptime is_elem_opt) (elem orelse continue) else elem;
        if (has_any_kv.* or !is_root) try w.writeByte('\n');
        has_any_kv.* = true;
        try w.writeAll("[[");
        try writePath(w, path.items);
        try w.writeAll("]]\n");
        if (comptime (@typeInfo(ElemActual) == .@"union" and @hasDecl(ElemActual, "toml_tag"))) {
            try encodeTaggedUnion(ElemActual, item, w, path, path_alloc, arena, false);
        } else {
            try encodeTypedTable(ElemActual, item, w, path, path_alloc, arena, false);
        }
    }
}

fn emitFlatScalars(
    comptime T: type,
    value: T,
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    has_any_kv: *bool,
) EncodeError!void {
    const s = @typeInfo(T).@"struct";
    inline for (s.fields) |field| {
        if (comptime isSkipped(T, field.name)) continue;
        const fv = @field(value, field.name);
        if (comptime isFlattened(T, field.name)) {
            try emitFlatScalars(field.type, fv, w, arena, has_any_kv);
            continue;
        }
        if (!comptime fieldHasSubTable(field.type)) {
            // Null optional fields are omitted entirely; decode treats an
            // absent key as null for optional fields, so this round-trips.
            const emit: bool = if (comptime @typeInfo(field.type) == .optional)
                fv != null
            else
                true;
            if (emit) {
                const eff_key = comptime renamedKey(T, field.name);
                try writeKey(w, eff_key);
                try w.writeAll(" = ");
                try writeTypedValue(field.type, fv, w, arena);
                try w.writeByte('\n');
                has_any_kv.* = true;
            }
        }
    }
}

const annotations = @import("annotations.zig");
const renamedKey = annotations.renamedKey;
const isFlattened = annotations.isFlattened;
const isSkipped = annotations.isSkipped;

fn fieldHasSubTable(comptime FT: type) bool {
    return switch (@typeInfo(FT)) {
        .@"struct" => !@hasDecl(FT, "toToml"),
        .@"union" => @hasDecl(FT, "toml_tag"),
        // ?T is a sub-table field when T itself is one. The optional wrapper
        // just controls whether the section is emitted (non-null) or skipped (null).
        .optional => |o| fieldHasSubTable(o.child),
        // A slice/array of sub-tables encodes as [[array-of-tables]], mirroring
        // how decode reads []const Struct / [N]Struct from `[[header]]` blocks.
        // A []const u8 (string) or []const <scalar> (inline array) has a
        // non-sub-table element, so it stays in the scalar pass.
        .pointer => |p| p.size == .slice and fieldHasSubTable(p.child),
        .array => |a| fieldHasSubTable(a.child),
        else => false,
    };
}

/// If `FT` is a slice/array whose element is a sub-table type (possibly an
/// optional sub-table), returns that element type; otherwise null. Used to
/// route array-of-tables fields to the `[[header]]` emission path.
fn arrayOfTablesChild(comptime FT: type) ?type {
    return switch (@typeInfo(FT)) {
        .pointer => |p| if (p.size == .slice and fieldHasSubTable(p.child)) p.child else null,
        .array => |a| if (fieldHasSubTable(a.child)) a.child else null,
        else => null,
    };
}

fn writeTypedValue(comptime T: type, value: T, w: *std.Io.Writer, arena: std.mem.Allocator) EncodeError!void {
    if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "toToml"))) {
        comptime {
            const fn_info = @typeInfo(@TypeOf(T.toToml)).@"fn";
            if (fn_info.params.len != 2) {
                @compileError(@typeName(T) ++ ".toToml must take exactly 2 params: (Self, Allocator)");
            }
        }
        const hooked = T.toToml(value, arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        return writeValue(w, hooked, 0);
    }
    return switch (@typeInfo(T)) {
        .bool => w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => blk: {
            // TOML integers are i64 by spec; values outside i64 range cannot
            // be represented and would produce output that re-parse fails on.
            const i = std.math.cast(i64, value) orelse return error.IntegerOverflow;
            break :blk w.print("{d}", .{i});
        },
        .float, .comptime_float => writeFloat(w, @floatCast(value)),
        .pointer => |p| if (p.size == .slice and p.child == u8 and p.is_const)
            writeQuotedString(w, value)
        else if (p.size == .slice) blk: {
            try w.writeByte('[');
            for (value, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeTypedValue(p.child, item, w, arena);
            }
            break :blk w.writeByte(']');
        } else
            @compileError("encodeTyped: unsupported pointer type " ++ @typeName(T)),
        .array => |a| blk: {
            try w.writeByte('[');
            // Guard avoids a compile error for [0]T: Zig rejects indexing
            // into zero-length arrays even in unreachable loop bodies.
            if (comptime a.len > 0) {
                for (value, 0..) |item, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeTypedValue(a.child, item, w, arena);
                }
            }
            break :blk w.writeByte(']');
        },
        .optional => |o| if (value) |inner|
            writeTypedValue(o.child, inner, w, arena)
        else
            error.UnsupportedType,
        .@"enum" => writeQuotedString(w, @tagName(value)),
        else => @compileError("encodeTyped: unsupported value type " ++ @typeName(T)),
    };
}

fn encodeTable(
    w: *Io.Writer,
    tbl: StringArrayHashMap(Value),
    path: *ArrayList([]const u8),
    path_alloc: std.mem.Allocator,
    is_root: bool,
    depth: usize,
) EncodeError!void {
    if (depth > max_encode_depth) return error.NestingTooDeep;
    var has_any_kv = false;

    // Pass 1: scalars, arrays of non-tables.
    var it = tbl.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        switch (val) {
            .table => continue,
            .array => |arr| if (isArrayOfTables(arr)) continue,
            else => {},
        }
        try writeKey(w, k);
        try w.writeAll(" = ");
        try writeValue(w, val, depth);
        try w.writeByte('\n');
        has_any_kv = true;
    }

    // Pass 2: sub-tables and arrays-of-tables as headers.
    it = tbl.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        switch (val) {
            .table => |sub| {
                try path.append(path_alloc, k);
                defer _ = path.pop();
                if (has_any_kv or !is_root) try w.writeByte('\n');
                has_any_kv = true;
                try w.writeByte('[');
                try writePath(w, path.items);
                try w.writeAll("]\n");
                try encodeTable(w, sub, path, path_alloc, false, depth + 1);
            },
            .array => |arr| {
                if (!isArrayOfTables(arr)) continue;
                try path.append(path_alloc, k);
                defer _ = path.pop();
                for (arr.items) |elem| {
                    if (has_any_kv or !is_root) try w.writeByte('\n');
                    has_any_kv = true;
                    try w.writeAll("[[");
                    try writePath(w, path.items);
                    try w.writeAll("]]\n");
                    try encodeTable(w, elem.table, path, path_alloc, false, depth + 1);
                }
            },
            else => {},
        }
    }
}

fn isArrayOfTables(arr: ArrayList(Value)) bool {
    if (arr.items.len == 0) return false;
    for (arr.items) |item| {
        if (item != .table) return false;
    }
    return true;
}

fn writePath(w: *Io.Writer, parts: []const []const u8) EncodeError!void {
    for (parts, 0..) |part, i| {
        if (i > 0) try w.writeByte('.');
        try writeKey(w, part);
    }
}

/// Write a single key segment to `w`: bare when it is a valid bare key,
/// otherwise as a single-line basic-quoted string. TOML keys may not use
/// multiline string syntax, so the multiline path is bypassed unconditionally.
pub fn writeKey(w: *Io.Writer, k: []const u8) EncodeError!void {
    if (isBareKey(k)) {
        try w.writeAll(k);
        return;
    }
    try writeSingleLineBasicString(w, k);
}

fn isBareKey(k: []const u8) bool {
    if (k.len == 0) return false;
    for (k) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Write a single TOML value (scalar, inline table, or inline array) to
/// `w`. Used by the document model when inserting or replacing a typed
/// value via canonical formatting.
pub fn writeInlineValue(w: *Io.Writer, val: Value) EncodeError!void {
    return writeValue(w, val, 0);
}

fn writeValue(w: *Io.Writer, val: Value, depth: usize) EncodeError!void {
    if (depth > max_encode_depth) return error.NestingTooDeep;
    switch (val) {
        .string => |s| try writeQuotedString(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |d| try writeDateTime(w, d),
        .date => |d| try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }),
        .time => |t| try writeTime(w, t),
        .array => |arr| try writeArrayValue(w, arr, depth),
        .table => |tbl| try writeInlineTable(w, tbl, depth),
    }
}

fn writeArrayValue(w: *Io.Writer, arr: ArrayList(Value), depth: usize) EncodeError!void {
    try w.writeByte('[');
    for (arr.items, 0..) |item, i| {
        if (i > 0) try w.writeAll(", ");
        try writeValue(w, item, depth + 1);
    }
    try w.writeByte(']');
}

fn writeInlineTable(w: *Io.Writer, tbl: StringArrayHashMap(Value), depth: usize) EncodeError!void {
    try w.writeAll("{ ");
    var it = tbl.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try w.writeAll(", ");
        first = false;
        try writeKey(w, entry.key_ptr.*);
        try w.writeAll(" = ");
        try writeValue(w, entry.value_ptr.*, depth + 1);
    }
    try w.writeAll(" }");
}

/// Skip bytes that are safe to emit verbatim inside a basic string
/// (i.e., not `"`, `\`, control char, or DEL). Returns the skip count;
/// caller handles the byte at the returned offset.
fn scanQuotedStringPlain(bytes: []const u8) usize {
    const W = 16;
    var i: usize = 0;
    const quote: @Vector(W, u8) = @splat('"');
    const backslash: @Vector(W, u8) = @splat('\\');
    const ctrl_max: @Vector(W, u8) = @splat(0x1f);
    const del: @Vector(W, u8) = @splat(0x7f);
    while (i + W <= bytes.len) {
        const chunk: @Vector(W, u8) = bytes[i..][0..W].*;
        const stop =
            (chunk == quote) |
            (chunk == backslash) |
            (chunk == del) |
            (chunk <= ctrl_max);
        const mask: u16 = @bitCast(stop);
        if (mask != 0) return i + @ctz(mask);
        i += W;
    }
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '"' or c == '\\' or c < 0x20 or c == 0x7f) return i;
        i += 1;
    }
    return i;
}

fn writeSingleLineBasicString(w: *Io.Writer, s: []const u8) EncodeError!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const skip = scanQuotedStringPlain(s[i..]);
        if (skip > 0) {
            try w.writeAll(s[i .. i + skip]);
            i += skip;
            if (i >= s.len) break;
        }
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0A => try w.writeAll("\\n"),
            0x0C => try w.writeAll("\\f"),
            0x0D => try w.writeAll("\\r"),
            else => if (c < 0x20 or c == 0x7F) {
                try w.print("\\u{X:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
        i += 1;
    }
    try w.writeByte('"');
}

fn writeQuotedString(w: *Io.Writer, s: []const u8) EncodeError!void {
    if (shouldUseMultiline(s)) return writeMultilineString(w, s);
    return writeSingleLineBasicString(w, s);
}

const multiline_threshold = 60;

fn shouldUseMultiline(s: []const u8) bool {
    // Worth multi-line form when the string holds at least one newline
    // AND total length is large enough that escapes would dominate.
    if (s.len < multiline_threshold) return false;
    var newlines: usize = 0;
    for (s) |c| {
        if (c == '\n') newlines += 1;
        if (c < 0x20 and c != '\n' and c != '\t' and c != '\r') return false;
    }
    return newlines >= 1;
}

fn writeMultilineString(w: *Io.Writer, s: []const u8) EncodeError!void {
    try w.writeAll("\"\"\"\n"); // immediate newline after opener is trimmed by parsers
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => {
                // Escape any run of 3+ quotes to avoid prematurely closing.
                var run: usize = 0;
                while (i + run < s.len and s[i + run] == '"' and run < 5) run += 1;
                if (run >= 3) {
                    try w.writeByte('\\');
                    try w.writeByte('"');
                    var k: usize = 1;
                    while (k < run) : (k += 1) try w.writeByte('"');
                    i += run - 1;
                } else {
                    try w.writeByte('"');
                }
            },
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            // CR must be escaped: a bare \r is invalid in multiline strings per
            // spec, and even \r\n pairs are normalized away by compliant parsers
            // so the value would not survive a round-trip without escaping.
            0x0D => try w.writeAll("\\r"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"\"\"");
}

fn writeFloat(w: *Io.Writer, f: f64) EncodeError!void {
    if (std.math.isNan(f)) return w.writeAll(if (std.math.signbit(f)) "-nan" else "nan");
    if (std.math.isPositiveInf(f)) return w.writeAll("inf");
    if (std.math.isNegativeInf(f)) return w.writeAll("-inf");

    // Force a fractional/exponent form so the parser sees a float, not int.
    // Decimal f64 needs up to 347 bytes (e.g. floatMin/subnormals); a smaller
    // buffer would overflow and panic for large-magnitude or tiny values.
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const s = std.fmt.float.render(&buf, f, .{ .mode = .decimal }) catch unreachable;
    try w.writeAll(s);
    var has_marker = false;
    for (s) |c| {
        if (c == '.' or c == 'e' or c == 'E') {
            has_marker = true;
            break;
        }
    }
    if (!has_marker) try w.writeAll(".0");
}

/// Emit an offset datetime. A zero offset (parsed from `Z`, `+00:00`, or
/// `-00:00`) is always re-encoded as `Z`; see parseOffset in datetime.zig.
fn writeDateTime(w: *Io.Writer, d: v.DateTime) EncodeError!void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T", .{ d.date.year, d.date.month, d.date.day });
    try writeTime(w, d.time);
    const off = d.tz_offset_minutes orelse return;
    if (off == 0) {
        try w.writeByte('Z');
    } else {
        const abs: u16 = @intCast(if (off < 0) -off else off);
        const sign: u8 = if (off < 0) '-' else '+';
        try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 });
    }
}

fn writeTime(w: *Io.Writer, t: v.Time) EncodeError!void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanos == 0) return;

    // Trim trailing zeros from the 9-digit nanosecond field.
    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{t.nanos}) catch unreachable;
    var end: usize = 9;
    while (end > 1 and buf[end - 1] == '0') : (end -= 1) {}
    try w.writeByte('.');
    try w.writeAll(buf[0..end]);
}

const parser = @import("parser.zig");

fn allocEncode(alloc: std.mem.Allocator, val: Value) ![]u8 {
    var aw: Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try encode(&aw.writer, val);
    return aw.toOwnedSlice();
}

fn roundtrip(alloc: std.mem.Allocator, src: []const u8) !void {
    var arena1: ArenaAllocator = .init(alloc);
    defer arena1.deinit();
    const v1 = try parser.parse(arena1.allocator(), src, .{});
    const encoded = try allocEncode(alloc, v1);
    defer alloc.free(encoded);
    var arena2: ArenaAllocator = .init(alloc);
    defer arena2.deinit();
    const v2 = try parser.parse(arena2.allocator(), encoded, .{});
    if (!Value.eql(v1, v2)) {
        std.debug.print("round-trip mismatch\noriginal:\n{s}\nencoded:\n{s}\n", .{ src, encoded });
        return error.RoundTripMismatch;
    }
}

test "encode basic kv" {
    try roundtrip(testing.allocator,
        \\title = "TOML"
        \\count = 42
        \\pi = 3.14
        \\ok = true
    );
}

test "encode nested tables" {
    try roundtrip(testing.allocator,
        \\[servers]
        \\hostname = "localhost"
        \\
        \\[servers.alpha]
        \\ip = "10.0.0.1"
        \\
        \\[servers.beta]
        \\ip = "10.0.0.2"
    );
}

test "encode arrays" {
    try roundtrip(testing.allocator,
        \\nums = [1, 2, 3]
        \\strs = ["a", "b"]
    );
}

test "encode arrays of tables" {
    try roundtrip(testing.allocator,
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]
        \\name = "Nail"
        \\sku = 284758393
    );
}

test "encode special float forms" {
    try roundtrip(testing.allocator,
        \\a = inf
        \\b = -inf
    );
}

test "encode large-magnitude floats round-trip bit-exact" {
    // Regression: writeFloat used a 64-byte buffer; decimal-mode f64 needs up
    // to 347 bytes, so these would overflow bufPrint and panic before the fix.
    const cases = [_]f64{
        1e300,
        -1e300,
        1e-300,
        std.math.floatMax(f64),
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64), // smallest positive subnormal
        1.0,
    };
    for (cases) |f| {
        var doc: Value = undefined;
        var tbl: Value.Table = .empty;
        defer tbl.deinit(testing.allocator);
        try tbl.put(testing.allocator, "x", .{ .float = f });
        doc = .{ .table = tbl };

        const encoded = try allocEncode(testing.allocator, doc);
        defer testing.allocator.free(encoded);

        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const reparsed = try parser.parse(arena.allocator(), encoded, .{});
        const got = reparsed.table.get("x").?;
        // Must re-parse as a float, not an integer.
        try testing.expect(got == .float);
        // Bit-exact round-trip.
        try testing.expectEqual(@as(u64, @bitCast(f)), @as(u64, @bitCast(got.float)));
    }
}

test "encode datetime" {
    try roundtrip(testing.allocator,
        \\dt = 1979-05-27T07:32:00Z
        \\ld = 1979-05-27
        \\lt = 07:32:00
        \\dtf = 1979-05-27T07:32:00.999999Z
    );
}

test "encode quoted key" {
    try roundtrip(testing.allocator,
        \\"weird key" = 1
        \\"with space" = 2
    );
}

test "scanQuotedStringPlain: matches byte-loop on every stop byte" {
    const fixtures = [_][]const u8{
        "hello",
        "hello\\world",
        "hello\"world",
        "hello\nworld",
        "hello\x01world",
        "hello\x7fworld",
        "abcdefghijklmnopqrstuvwxyz", // long plain
        "abcdefghijklmnop\"rest", // stop at lane boundary (idx 16)
        "", // empty
    };
    for (fixtures) |f| {
        const fast = scanQuotedStringPlain(f);
        var slow: usize = 0;
        while (slow < f.len) : (slow += 1) {
            const c = f[slow];
            if (c == '"' or c == '\\' or c < 0x20 or c == 0x7f) break;
        }
        try testing.expectEqual(slow, fast);
    }
}

test "encode long multi-line string uses triple-quote form" {
    // Round-trip a long multi-line string and verify the encoded output
    // uses the """...""" form (more readable than escaped \n in single-line).
    const alloc = testing.allocator;
    const src =
        \\body = """
        \\Lorem ipsum dolor sit amet, consectetur adipiscing elit.
        \\Sed do eiusmod tempor incididunt ut labore et dolore magna.
        \\Ut enim ad minim veniam, quis nostrud exercitation ullamco.
        \\"""
    ;
    var arena: ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const v1 = try parser.parse(arena.allocator(), src, .{});
    const encoded = try allocEncode(alloc, v1);
    defer alloc.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"\"\"") != null);

    var arena2: ArenaAllocator = .init(alloc);
    defer arena2.deinit();
    const v2 = try parser.parse(arena2.allocator(), encoded, .{});
    try testing.expect(Value.eql(v1, v2));
}

test "encodeTyped: un-annotated struct matches encode output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Config = struct {
        name: []const u8,
        port: u16,
        tls: bool,
    };

    const cfg = Config{ .name = "ef", .port = 8080, .tls = true };

    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "name = \"ef\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port = 8080") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tls = true") != null);
}

test "encodeTyped: toml_rename emits renamed key" {
    const Config = struct {
        pub const toml_rename = .{ .listen_addr = "listen-addr" };
        listen_addr: []const u8,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Config{ .listen_addr = "0.0.0.0" };

    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, arena.allocator());
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "listen-addr = \"0.0.0.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "listen_addr") == null);
}

test "encodeTyped: toml_flatten inlines sub-fields at parent level" {
    const Inner = struct { x: u32, y: u32 };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Outer{ .name = "foo", .inner = .{ .x = 42, .y = 99 } };

    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Outer, cfg, arena.allocator());
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "name = \"foo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x = 42") != null);
    try testing.expect(std.mem.indexOf(u8, out, "y = 99") != null);
    // No [inner] section.
    try testing.expect(std.mem.indexOf(u8, out, "[inner]") == null);
}

test "encodeTyped: toml_skip omits field from output" {
    const Config = struct {
        pub const toml_skip = .{"internal"};
        name: []const u8,
        internal: u32 = 7,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Config{ .name = "foo" };

    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, arena.allocator());
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "name = \"foo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "internal") == null);
}

test "encodeTyped: toToml hook bypasses built-in encoding" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn toToml(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            const s = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{
                self.major, self.minor, self.patch,
            });
            return Value{ .string = s };
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct {
        v: SemVer,
    };
    const cfg = Config{ .v = .{ .major = 1, .minor = 2, .patch = 3 } };

    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, arena.allocator());
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "v = \"1.2.3\"") != null);
}

test "encodeTyped: tagged union writes discriminator + payload" {
    const Http = struct { host: []const u8, port: u16 };
    const Grpc = struct { endpoint: []const u8 };
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: Http,
        grpc: Grpc,
    };
    const Wrapper = struct { p: Plugin };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Wrapper{ .p = .{ .http = .{ .host = "localhost", .port = 8080 } } };

    var buf: [512]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Wrapper, cfg, arena.allocator());
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "kind = \"http\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "host = \"localhost\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port = 8080") != null);
}

test "encode nesting depth guard: deep array tree errors, shallow succeeds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a (max_encode_depth + 2)-deep chain of single-element arrays
    // wrapped in a root table, then encode it. The bracket depth past the
    // ceiling must surface error.NestingTooDeep, not overflow the stack.
    // The loop count bounds the construction so the test can't run away.
    const over = max_encode_depth + 2;
    var inner: Value = .{ .integer = 0 };
    var d: usize = 0;
    while (d < over) : (d += 1) {
        var arr: Value.Array = .empty;
        try arr.append(a, inner);
        inner = .{ .array = arr };
    }
    var over_tbl: Value.Table = .empty;
    try over_tbl.put(a, "x", inner);
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try testing.expectError(error.NestingTooDeep, encode(&aw.writer, .{ .table = over_tbl }));
    }

    // A shallow chain (well under the ceiling) encodes without error.
    var shallow: Value = .{ .integer = 0 };
    d = 0;
    while (d < 64) : (d += 1) {
        var arr: Value.Array = .empty;
        try arr.append(a, shallow);
        shallow = .{ .array = arr };
    }
    var ok_tbl: Value.Table = .empty;
    try ok_tbl.put(a, "x", shallow);
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .table = ok_tbl }); // must not error
    }
}

test "encode nesting depth guard: deep table tree errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Nested tables become [header] sections via encodeTable recursion;
    // a chain past max_encode_depth must error rather than overflow.
    const over = max_encode_depth + 2;
    var inner: Value.Table = .empty;
    var d: usize = 0;
    while (d < over) : (d += 1) {
        var outer: Value.Table = .empty;
        try outer.put(a, "t", .{ .table = inner });
        inner = outer;
    }
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try testing.expectError(error.NestingTooDeep, encode(&aw.writer, .{ .table = inner }));
}

test "encodeTyped: toml_flatten with nested sub-table round-trips" {
    // A flattened field that itself contains a sub-table (nested struct) must
    // produce a [section] header for that sub-table, not silently drop it.
    const Sub = struct { z: u32 };
    const Inner = struct {
        x: u32,
        sub: Sub,
    };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = Outer{
        .name = "flat-sub",
        .inner = .{ .x = 10, .sub = .{ .z = 99 } },
    };

    var buf: [512]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Outer, cfg, a);
    const out = aw.buffered();

    // Flat scalars from inner must appear at the root level.
    try testing.expect(std.mem.indexOf(u8, out, "name = \"flat-sub\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x = 10") != null);
    // inner's [sub] section must appear (not be silently dropped).
    try testing.expect(std.mem.indexOf(u8, out, "[sub]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "z = 99") != null);
    // The flattened field's own key must not appear as a section header.
    try testing.expect(std.mem.indexOf(u8, out, "[inner]") == null);

    // Full round-trip: encode then decode must recover all fields.
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Outer, a, v1, .{});
    try testing.expectEqualStrings("flat-sub", cfg2.name);
    try testing.expectEqual(@as(u32, 10), cfg2.inner.x);
    try testing.expectEqual(@as(u32, 99), cfg2.inner.sub.z);
}

test "encodeTyped: toml_flatten scalars-only still works after refactor" {
    // Regression: flatten with only scalar fields must still produce flat output.
    const Inner = struct { x: u32, y: u32 };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Outer{ .name = "foo", .inner = .{ .x = 42, .y = 99 } };

    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Outer, cfg, arena.allocator());
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "name = \"foo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x = 42") != null);
    try testing.expect(std.mem.indexOf(u8, out, "y = 99") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[inner]") == null);
}

test "encodeTyped: tagged union payload with nested sub-table round-trips" {
    // A tagged-union variant whose payload contains a nested struct (sub-table)
    // must emit a [section] header for that sub-table, not silently drop it.
    const Backend = struct { address: []const u8, timeout: u32 };
    const Http = struct {
        host: []const u8,
        backend: Backend,
    };
    const Grpc = struct { endpoint: []const u8 };
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: Http,
        grpc: Grpc,
    };
    const Wrapper = struct { p: Plugin };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = Wrapper{ .p = .{ .http = .{
        .host = "localhost",
        .backend = .{ .address = "10.0.0.1", .timeout = 30 },
    } } };

    var buf: [512]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Wrapper, cfg, a);
    const out = aw.buffered();

    // Discriminator and flat scalar from the union payload.
    try testing.expect(std.mem.indexOf(u8, out, "kind = \"http\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "host = \"localhost\"") != null);
    // The nested sub-table inside the union payload must appear.
    try testing.expect(std.mem.indexOf(u8, out, "[p.backend]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "address = \"10.0.0.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "timeout = 30") != null);

    // Full round-trip via decode.
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Wrapper, a, v1, .{});
    try testing.expect(cfg2.p == .http);
    try testing.expectEqualStrings("localhost", cfg2.p.http.host);
    try testing.expectEqualStrings("10.0.0.1", cfg2.p.http.backend.address);
    try testing.expectEqual(@as(u32, 30), cfg2.p.http.backend.timeout);
}

test "encodeTyped: tagged union scalars-only still works after refactor" {
    // Regression: tagged union variants with only scalar payload fields must
    // still produce correct output.
    const Http = struct { host: []const u8, port: u16 };
    const Grpc = struct { endpoint: []const u8 };
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: Http,
        grpc: Grpc,
    };
    const Wrapper = struct { p: Plugin };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Wrapper{ .p = .{ .http = .{ .host = "localhost", .port = 8080 } } };

    var buf: [512]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Wrapper, cfg, arena.allocator());
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "kind = \"http\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "host = \"localhost\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port = 8080") != null);
}

test "encodeTyped: toml_flatten two levels deep merges all scalars at root" {
    // flatten-inside-flatten: both emitFlatScalars and emitStructSubTables
    // recurse through every flattened layer, so all scalar fields from all
    // levels land in the root table (no [section] headers for flattened types).
    const Deep = struct { a: u32, b: u32 };
    const Inner = struct {
        pub const toml_flatten = .{"deep"};
        x: u32,
        deep: Deep,
    };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Outer{ .name = "test", .inner = .{ .x = 10, .deep = .{ .a = 1, .b = 2 } } };

    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Outer, cfg, arena.allocator());
    const out = aw.buffered();

    // All scalars from all three struct types must appear at the root level.
    try testing.expect(std.mem.indexOf(u8, out, "name = \"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x = 10") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a = 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "b = 2") != null);
    // Neither intermediate type may appear as a section header.
    try testing.expect(std.mem.indexOf(u8, out, "[inner]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "[deep]") == null);
}

test "encodeTyped: u64 field exceeding i64 max -> IntegerOverflow" {
    const Config = struct { n: u64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Config{ .n = @as(u64, std.math.maxInt(i64)) + 1 };
    var buf: [64]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.IntegerOverflow, encodeTyped(&aw, Config, cfg, arena.allocator()));
}

test "encodeTyped: u64 within i64 range round-trips" {
    const Config = struct { n: u64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = Config{ .n = 100 };
    var buf: [64]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, arena.allocator());
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "n = 100") != null);
}

test "encodeTyped: []const i64 emits TOML array and round-trips" {
    const Config = struct { nums: []const i64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nums: []const i64 = &.{ 1, 2, 3 };
    const cfg = Config{ .nums = nums };
    var buf: [128]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "nums = [1, 2, 3]") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqualSlices(i64, cfg.nums, cfg2.nums);
}

test "encodeTyped: []const f64 emits TOML array and round-trips" {
    const Config = struct { vals: []const f64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vals: []const f64 = &.{ 1.5, 2.5, 3.5 };
    const cfg = Config{ .vals = vals };
    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(usize, 3), cfg2.vals.len);
    try testing.expectEqual(@as(f64, 1.5), cfg2.vals[0]);
    try testing.expectEqual(@as(f64, 3.5), cfg2.vals[2]);
}

test "encodeTyped: [3]u8 fixed array is array of ints (not string)" {
    // [N]u8 is NOT a string in TOML; both encode and decode treat it as an
    // array of integers. Only []const u8 (slice) maps to a TOML string.
    const Config = struct { bytes: [3]u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .bytes = .{ 1, 2, 3 } };
    var buf: [128]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "bytes = [1, 2, 3]") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(cfg.bytes, cfg2.bytes);
}

test "encodeTyped: [3]i64 fixed array round-trips" {
    const Config = struct { vals: [3]i64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .vals = .{ 10, 20, 30 } };
    var buf: [128]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "vals = [10, 20, 30]") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(cfg.vals, cfg2.vals);
}

test "encodeTyped: [0]i64 emits empty TOML array and round-trips" {
    const Config = struct { empty: [0]i64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .empty = .{} };
    var buf: [64]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "empty = []") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual([0]i64{}, cfg2.empty);
}

test "encodeTyped: ?i64 non-null emits key and round-trips" {
    const Config = struct { x: ?i64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .x = 5 };
    var buf: [64]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "x = 5") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(?i64, 5), cfg2.x);
}

test "encodeTyped: ?i64 null omits key entirely; decode yields null" {
    const Config = struct { x: ?i64, y: i64 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .x = null, .y = 7 };
    var buf: [64]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    // x must be absent from the TOML output.
    try testing.expect(std.mem.indexOf(u8, out, "x") == null);
    try testing.expect(std.mem.indexOf(u8, out, "y = 7") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(?i64, null), cfg2.x);
    try testing.expectEqual(@as(i64, 7), cfg2.y);
}

test "encodeTyped: enum field emits tag name as string and round-trips" {
    const Color = enum { red, green, blue };
    const Config = struct { color: Color };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .color = .red };
    var buf: [64]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "color = \"red\"") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(Color.red, cfg2.color);
}

test "encodeTyped: []const []const u8 emits array of strings and round-trips" {
    const Config = struct { tags: []const []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags: []const []const u8 = &.{ "foo", "bar", "baz" };
    const cfg = Config{ .tags = tags };
    var buf: [128]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "tags = [\"foo\", \"bar\", \"baz\"]") != null);
    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(usize, 3), cfg2.tags.len);
    try testing.expectEqualStrings("foo", cfg2.tags[0]);
    try testing.expectEqualStrings("baz", cfg2.tags[2]);
}

test "encode multiline string: CR escaped as \\r, CRLF round-trip byte-exact" {
    // Build the initial value by parsing a single-line TOML that uses \r\n
    // escape sequences. The decoded string has literal CR and LF bytes. At
    // 62 bytes (>= multiline_threshold=60, has LF) it re-encodes as multiline.
    const toml_src = "v = \"\\r\\n" ++ ("x" ** 60) ++ "\"\n";
    var arena1: ArenaAllocator = .init(testing.allocator);
    defer arena1.deinit();
    const parsed1 = try parser.parse(arena1.allocator(), toml_src, .{});

    const encoded = try allocEncode(testing.allocator, parsed1);
    defer testing.allocator.free(encoded);

    // Must use multiline form.
    try testing.expect(std.mem.indexOf(u8, encoded, "\"\"\"") != null);
    // No literal CR byte anywhere in the encoded TOML.
    try testing.expect(std.mem.indexOfScalar(u8, encoded, '\r') == null);

    // Round-trip: re-parse and compare structurally.
    var arena2: ArenaAllocator = .init(testing.allocator);
    defer arena2.deinit();
    const parsed2 = try parser.parse(arena2.allocator(), encoded, .{});
    try testing.expect(Value.eql(parsed1, parsed2));
}

test "encode multiline string: multiple CRs and CRLF pairs all escaped" {
    // "start\r\n" ++ 58×'x' ++ "\r\nend" -> 70-byte value (>= 60, has LF).
    const toml_src = "v = \"start\\r\\n" ++ ("x" ** 58) ++ "\\r\\nend\"\n";
    var arena1: ArenaAllocator = .init(testing.allocator);
    defer arena1.deinit();
    const parsed1 = try parser.parse(arena1.allocator(), toml_src, .{});

    const encoded = try allocEncode(testing.allocator, parsed1);
    defer testing.allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "\"\"\"") != null);
    try testing.expect(std.mem.indexOfScalar(u8, encoded, '\r') == null);

    var arena2: ArenaAllocator = .init(testing.allocator);
    defer arena2.deinit();
    const parsed2 = try parser.parse(arena2.allocator(), encoded, .{});
    try testing.expect(Value.eql(parsed1, parsed2));
}

test "encode key with embedded newline: single-line basic string, no multiline form" {
    // Parse a TOML document whose key uses \n escape to embed a newline.
    // On re-encode, writeKey must emit a single-line basic string (not """).
    const toml_src = "\"a\\nb\" = 1\n";
    var arena1: ArenaAllocator = .init(testing.allocator);
    defer arena1.deinit();
    const parsed1 = try parser.parse(arena1.allocator(), toml_src, .{});

    const encoded = try allocEncode(testing.allocator, parsed1);
    defer testing.allocator.free(encoded);

    // Key token (everything before the first " = ") must be single-line.
    const eq_idx = std.mem.indexOf(u8, encoded, " = ").?;
    const key_token = encoded[0..eq_idx];
    try testing.expect(std.mem.indexOf(u8, key_token, "\"\"\"") == null);
    try testing.expect(std.mem.indexOfScalar(u8, key_token, '\n') == null);
    try testing.expect(std.mem.indexOfScalar(u8, key_token, '\r') == null);

    // Round-trip: re-parse and structural equality.
    var arena2: ArenaAllocator = .init(testing.allocator);
    defer arena2.deinit();
    const parsed2 = try parser.parse(arena2.allocator(), encoded, .{});
    try testing.expect(Value.eql(parsed1, parsed2));
}

test "encode key with embedded CR: single-line basic string, no multiline form" {
    // Key contains a \r escape (CR). Must re-encode as single-line basic string.
    const toml_src = "\"a\\rb\" = 1\n";
    var arena1: ArenaAllocator = .init(testing.allocator);
    defer arena1.deinit();
    const parsed1 = try parser.parse(arena1.allocator(), toml_src, .{});

    const encoded = try allocEncode(testing.allocator, parsed1);
    defer testing.allocator.free(encoded);

    const eq_idx = std.mem.indexOf(u8, encoded, " = ").?;
    const key_token = encoded[0..eq_idx];
    try testing.expect(std.mem.indexOf(u8, key_token, "\"\"\"") == null);
    try testing.expect(std.mem.indexOfScalar(u8, key_token, '\n') == null);
    try testing.expect(std.mem.indexOfScalar(u8, key_token, '\r') == null);

    var arena2: ArenaAllocator = .init(testing.allocator);
    defer arena2.deinit();
    const parsed2 = try parser.parse(arena2.allocator(), encoded, .{});
    try testing.expect(Value.eql(parsed1, parsed2));
}

test "encodeTyped: optional sub-table present round-trips" {
    const Sub = struct { x: i64, y: i64 };
    const S = struct { name: []const u8, sub: ?Sub };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = S{ .name = "hello", .sub = .{ .x = 1, .y = 2 } };
    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, S, cfg, a);
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "[sub]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x = 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "y = 2") != null);

    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(S, a, v1, .{});
    try testing.expectEqualStrings("hello", cfg2.name);
    try testing.expect(cfg2.sub != null);
    try testing.expectEqual(@as(i64, 1), cfg2.sub.?.x);
    try testing.expectEqual(@as(i64, 2), cfg2.sub.?.y);
}

test "encodeTyped: optional sub-table null emits no header" {
    const Sub = struct { x: i64, y: i64 };
    const S = struct { name: []const u8, sub: ?Sub };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = S{ .name = "hello", .sub = null };
    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, S, cfg, a);
    const out = aw.buffered();

    // No [sub] section header when the optional sub-table is null.
    try testing.expect(std.mem.indexOf(u8, out, "[sub]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "name = \"hello\"") != null);

    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(S, a, v1, .{});
    try testing.expectEqualStrings("hello", cfg2.name);
    try testing.expectEqual(@as(?Sub, null), cfg2.sub);
}

test "encodeTyped: nested optional sub-tables round-trip" {
    const Inner = struct { v: i64 };
    const Outer = struct { b: ?Inner };
    const Root = struct { a: ?Outer };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both levels present.
    {
        const cfg = Root{ .a = .{ .b = .{ .v = 42 } } };
        var buf: [256]u8 = undefined;
        var aw: std.Io.Writer = .fixed(&buf);
        try encodeTyped(&aw, Root, cfg, a);
        const out = aw.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "[a]") != null);
        try testing.expect(std.mem.indexOf(u8, out, "[a.b]") != null);
        try testing.expect(std.mem.indexOf(u8, out, "v = 42") != null);
        const decode_mod = @import("decode.zig");
        const v1 = try parser.parse(a, out, .{});
        const cfg2 = try decode_mod.decode(Root, a, v1, .{});
        try testing.expect(cfg2.a != null and cfg2.a.?.b != null);
        try testing.expectEqual(@as(i64, 42), cfg2.a.?.b.?.v);
    }

    // Outer present, inner null.
    {
        const cfg = Root{ .a = .{ .b = null } };
        var buf: [256]u8 = undefined;
        var aw: std.Io.Writer = .fixed(&buf);
        try encodeTyped(&aw, Root, cfg, a);
        const out = aw.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "[a]") != null);
        // Inner null means no [a.b] section.
        try testing.expect(std.mem.indexOf(u8, out, "[a.b]") == null);
        const decode_mod = @import("decode.zig");
        const v1 = try parser.parse(a, out, .{});
        const cfg2 = try decode_mod.decode(Root, a, v1, .{});
        try testing.expect(cfg2.a != null);
        try testing.expectEqual(@as(?Inner, null), cfg2.a.?.b);
    }

    // Both null.
    {
        const cfg = Root{ .a = null };
        var buf: [256]u8 = undefined;
        var aw: std.Io.Writer = .fixed(&buf);
        try encodeTyped(&aw, Root, cfg, a);
        const out = aw.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "[a]") == null);
        const decode_mod = @import("decode.zig");
        const v1 = try parser.parse(a, out, .{});
        const cfg2 = try decode_mod.decode(Root, a, v1, .{});
        try testing.expectEqual(@as(?Outer, null), cfg2.a);
    }
}

test "encodeTyped: slice-of-struct emits [[array-of-tables]] and round-trips" {
    const Item = struct { x: i64, name: []const u8 };
    const Config = struct { items: []const Item };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items: []const Item = &.{
        .{ .x = 1, .name = "alpha" },
        .{ .x = 2, .name = "beta" },
        .{ .x = 3, .name = "gamma" },
    };
    const cfg = Config{ .items = items };

    var buf: [1024]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();

    // Three [[items]] headers, one per element.
    try testing.expect(std.mem.indexOf(u8, out, "[[items]]") != null);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "[[items]]")) |pos| : (i = pos + 1) count += 1;
    try testing.expectEqual(@as(usize, 3), count);

    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(usize, 3), cfg2.items.len);
    try testing.expectEqual(@as(i64, 1), cfg2.items[0].x);
    try testing.expectEqualStrings("alpha", cfg2.items[0].name);
    try testing.expectEqual(@as(i64, 3), cfg2.items[2].x);
    try testing.expectEqualStrings("gamma", cfg2.items[2].name);
}

test "encodeTyped: ?[]const struct null emits nothing, present emits blocks" {
    const Item = struct { v: i64 };
    const Config = struct { name: []const u8, items: ?[]const Item };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decode_mod = @import("decode.zig");

    // null -> no [[items]] header.
    {
        const cfg = Config{ .name = "n", .items = null };
        var buf: [512]u8 = undefined;
        var aw: std.Io.Writer = .fixed(&buf);
        try encodeTyped(&aw, Config, cfg, a);
        const out = aw.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "[[items]]") == null);
        const v1 = try parser.parse(a, out, .{});
        const cfg2 = try decode_mod.decode(Config, a, v1, .{});
        try testing.expectEqual(@as(?[]const Item, null), cfg2.items);
    }

    // present -> [[items]] blocks round-trip.
    {
        const items: []const Item = &.{ .{ .v = 10 }, .{ .v = 20 } };
        const cfg = Config{ .name = "n", .items = items };
        var buf: [512]u8 = undefined;
        var aw: std.Io.Writer = .fixed(&buf);
        try encodeTyped(&aw, Config, cfg, a);
        const out = aw.buffered();
        try testing.expect(std.mem.indexOf(u8, out, "[[items]]") != null);
        const v1 = try parser.parse(a, out, .{});
        const cfg2 = try decode_mod.decode(Config, a, v1, .{});
        try testing.expect(cfg2.items != null);
        try testing.expectEqual(@as(usize, 2), cfg2.items.?.len);
        try testing.expectEqual(@as(i64, 20), cfg2.items.?[1].v);
    }
}

test "encodeTyped: empty slice-of-struct emits no blocks, round-trips empty" {
    const Item = struct { v: i64 };
    // Absent array-of-tables decodes through the field default; decode has no
    // absent-means-empty rule, so an empty slice needs a default (or optional)
    // to round-trip -- otherwise an absent required field is MissingField.
    const Config = struct { items: []const Item = &.{} };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = Config{ .items = &.{} };
    var buf: [256]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "[[items]]") == null);

    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(usize, 0), cfg2.items.len);
}

test "encodeTyped: nested array-of-tables emits [[a]] + [[a.b]] and round-trips" {
    const Inner = struct { val: i64 };
    const Outer = struct { b: []const Inner };
    const Config = struct { a: []const Outer };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = Config{ .a = &.{
        .{ .b = &.{ .{ .val = 1 }, .{ .val = 2 } } },
        .{ .b = &.{.{ .val = 3 }} },
    } };

    var buf: [1024]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "[[a]]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[[a.b]]") != null);

    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(usize, 2), cfg2.a.len);
    try testing.expectEqual(@as(usize, 2), cfg2.a[0].b.len);
    try testing.expectEqual(@as(i64, 1), cfg2.a[0].b[0].val);
    try testing.expectEqual(@as(i64, 2), cfg2.a[0].b[1].val);
    try testing.expectEqual(@as(usize, 1), cfg2.a[1].b.len);
    try testing.expectEqual(@as(i64, 3), cfg2.a[1].b[0].val);
}

test "encodeTyped: array-of-tables element mixing scalar and sub-table field" {
    // An array-of-tables element carrying both a scalar and a nested sub-table
    // emits the scalar in the `[[items]]` body and the sub-table as an
    // `[items.sub]` header at the element's path. Each `[items.sub]` attaches
    // to its own element, so the emitted document parses and decodes back to
    // the original.
    const Sub = struct { y: i64 };
    const Item = struct { x: i64, sub: Sub };
    const Config = struct { items: []const Item };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = Config{ .items = &.{
        .{ .x = 1, .sub = .{ .y = 11 } },
        .{ .x = 2, .sub = .{ .y = 22 } },
    } };

    var buf: [1024]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();

    // Two [[items]] element headers, each with its own scalar and [items.sub].
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "[[items]]")) |pos| : (i = pos + 1) count += 1;
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(std.mem.indexOf(u8, out, "[items.sub]") != null);

    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(usize, 2), cfg2.items.len);
    try testing.expectEqual(@as(i64, 1), cfg2.items[0].x);
    try testing.expectEqual(@as(i64, 11), cfg2.items[0].sub.y);
    try testing.expectEqual(@as(i64, 2), cfg2.items[1].x);
    try testing.expectEqual(@as(i64, 22), cfg2.items[1].sub.y);
}

test "encodeTyped: [N]struct fixed array emits [[array-of-tables]] and round-trips" {
    const Item = struct { v: i64 };
    const Config = struct { items: [2]Item };

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = Config{ .items = .{ .{ .v = 7 }, .{ .v = 8 } } };
    var buf: [512]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    try encodeTyped(&aw, Config, cfg, a);
    const out = aw.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "[[items]]") != null);

    const decode_mod = @import("decode.zig");
    const v1 = try parser.parse(a, out, .{});
    const cfg2 = try decode_mod.decode(Config, a, v1, .{});
    try testing.expectEqual(@as(i64, 7), cfg2.items[0].v);
    try testing.expectEqual(@as(i64, 8), cfg2.items[1].v);
}

test "encode float: NaN sign bit preserved; inf spellings correct" {
    const neg_nan: f64 = @bitCast(@as(u64, 0xFFF8000000000000));
    const pos_nan: f64 = @bitCast(@as(u64, 0x7FF8000000000000));

    var buf: [32]u8 = undefined;

    var aw_neg_nan: Io.Writer = .fixed(&buf);
    try writeFloat(&aw_neg_nan, neg_nan);
    try testing.expectEqualStrings("-nan", aw_neg_nan.buffered());

    var aw_pos_nan: Io.Writer = .fixed(&buf);
    try writeFloat(&aw_pos_nan, pos_nan);
    try testing.expectEqualStrings("nan", aw_pos_nan.buffered());

    var aw_inf: Io.Writer = .fixed(&buf);
    try writeFloat(&aw_inf, std.math.inf(f64));
    try testing.expectEqualStrings("inf", aw_inf.buffered());

    var aw_neg_inf: Io.Writer = .fixed(&buf);
    try writeFloat(&aw_neg_inf, -std.math.inf(f64));
    try testing.expectEqualStrings("-inf", aw_neg_inf.buffered());
}
