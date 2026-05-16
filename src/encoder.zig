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

pub const EncodeError = std.Io.Writer.Error || error{ ExpectedTable, OutOfMemory };

const max_path_depth = 256;

/// Encode `value` as TOML to `w`. `value` must be `.table`.
pub fn encode(w: *Io.Writer, value: Value) EncodeError!void {
    if (value != .table) return error.ExpectedTable;

    var path_buf: [max_path_depth * @sizeOf([]const u8)]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    var path: ArrayList([]const u8) = .empty;
    defer path.deinit(fba.allocator());

    try encodeTable(w, value.table, &path, fba.allocator(), true);
}

/// Encode a typed Zig value as TOML, consulting any `toml_*`
/// annotations declared on the type. The top-level type must be a
/// struct (the root TOML value is always a table).
///
/// Use this when the source is a typed Zig struct. Use `encode` when
/// you have a hand-built `Value` tree.
pub fn encodeTyped(comptime T: type, value: T, w: *std.Io.Writer, arena: std.mem.Allocator) EncodeError!void {
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
    _ = path;
    _ = path_alloc;
    _ = is_root;

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

            // Emit the payload's fields (if any) inline at this level.
            const PayloadType = union_field.type;
            if (PayloadType != void) {
                const payload = @field(value, variant_name);
                var has: bool = true;
                try emitFlatScalars(PayloadType, payload, w, arena, &has);
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

    // Pass 2: sub-tables (skipping flattened and skipped fields).
    const s = @typeInfo(T).@"struct";
    inline for (s.fields) |field| {
        if (comptime isSkipped(T, field.name)) continue;
        if (comptime isFlattened(T, field.name)) continue;
        const fv = @field(value, field.name);
        if (comptime fieldHasSubTable(field.type)) {
            const eff_key = comptime renamedKey(T, field.name);
            try path.append(path_alloc, eff_key);
            defer _ = path.pop();
            if (has_any_kv or !is_root) try w.writeByte('\n');
            has_any_kv = true;
            try w.writeByte('[');
            try writePath(w, path.items);
            try w.writeAll("]\n");
            if (comptime (@typeInfo(field.type) == .@"union" and @hasDecl(field.type, "toml_tag"))) {
                try encodeTaggedUnion(field.type, fv, w, path, path_alloc, arena, false);
            } else {
                try encodeTypedTable(field.type, fv, w, path, path_alloc, arena, false);
            }
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
            const eff_key = comptime renamedKey(T, field.name);
            try writeKey(w, eff_key);
            try w.writeAll(" = ");
            try writeTypedValue(field.type, fv, w, arena);
            try w.writeByte('\n');
            has_any_kv.* = true;
        }
    }
}

fn renamedKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!@hasDecl(T, "toml_rename")) return field_name;
    const renames = T.toml_rename;
    if (@hasField(@TypeOf(renames), field_name)) {
        return @field(renames, field_name);
    }
    return field_name;
}

fn isFlattened(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "toml_flatten")) return false;
    const flat = T.toml_flatten;
    inline for (flat) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

fn isSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "toml_skip")) return false;
    const skip = T.toml_skip;
    inline for (skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

fn fieldHasSubTable(comptime FT: type) bool {
    return switch (@typeInfo(FT)) {
        .@"struct" => !@hasDecl(FT, "toToml"),
        .@"union" => @hasDecl(FT, "toml_tag"),
        else => false,
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
        return writeValue(w, hooked);
    }
    return switch (@typeInfo(T)) {
        .bool => w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => w.print("{d}", .{value}),
        .float, .comptime_float => writeFloat(w, @floatCast(value)),
        .pointer => |p| if (p.size == .slice and p.child == u8 and p.is_const)
            writeQuotedString(w, value)
        else
            @compileError("encodeTyped: unsupported pointer type " ++ @typeName(T)),
        else => @compileError("encodeTyped: unsupported value type " ++ @typeName(T)),
    };
}

fn encodeTable(
    w: *Io.Writer,
    tbl: StringArrayHashMap(Value),
    path: *ArrayList([]const u8),
    path_alloc: std.mem.Allocator,
    is_root: bool,
) EncodeError!void {
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
        try writeValue(w, val);
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
                try encodeTable(w, sub, path, path_alloc, false);
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
                    try encodeTable(w, elem.table, path, path_alloc, false);
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

fn writeKey(w: *Io.Writer, k: []const u8) EncodeError!void {
    if (isBareKey(k)) {
        try w.writeAll(k);
        return;
    }
    try writeQuotedString(w, k);
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
    return writeValue(w, val);
}

fn writeValue(w: *Io.Writer, val: Value) EncodeError!void {
    switch (val) {
        .string => |s| try writeQuotedString(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |d| try writeDateTime(w, d),
        .date => |d| try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }),
        .time => |t| try writeTime(w, t),
        .array => |arr| try writeArrayValue(w, arr),
        .table => |tbl| try writeInlineTable(w, tbl),
    }
}

fn writeArrayValue(w: *Io.Writer, arr: ArrayList(Value)) EncodeError!void {
    try w.writeByte('[');
    for (arr.items, 0..) |item, i| {
        if (i > 0) try w.writeAll(", ");
        try writeValue(w, item);
    }
    try w.writeByte(']');
}

fn writeInlineTable(w: *Io.Writer, tbl: StringArrayHashMap(Value)) EncodeError!void {
    try w.writeAll("{ ");
    var it = tbl.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try w.writeAll(", ");
        first = false;
        try writeKey(w, entry.key_ptr.*);
        try w.writeAll(" = ");
        try writeValue(w, entry.value_ptr.*);
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

fn writeQuotedString(w: *Io.Writer, s: []const u8) EncodeError!void {
    if (shouldUseMultiline(s)) return writeMultilineString(w, s);
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
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"\"\"");
}

fn writeFloat(w: *Io.Writer, f: f64) EncodeError!void {
    if (std.math.isNan(f)) return w.writeAll("nan");
    if (std.math.isPositiveInf(f)) return w.writeAll("inf");
    if (std.math.isNegativeInf(f)) return w.writeAll("-inf");

    // Force a fractional/exponent form so the parser sees a float, not int.
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
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
        "abcdefghijklmnopqrstuvwxyz",        // long plain
        "abcdefghijklmnop\"rest",            // stop at lane boundary (idx 16)
        "",                                  // empty
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
    try encodeTyped(Config, cfg, &aw, a);
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
    try encodeTyped(Config, cfg, &aw, arena.allocator());
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
    try encodeTyped(Outer, cfg, &aw, arena.allocator());
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
    try encodeTyped(Config, cfg, &aw, arena.allocator());
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
    try encodeTyped(Config, cfg, &aw, arena.allocator());
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
    try encodeTyped(Wrapper, cfg, &aw, arena.allocator());
    const out = aw.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "kind = \"http\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "host = \"localhost\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port = 8080") != null);
}
