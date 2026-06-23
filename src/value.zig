//! TOML value types.
//!
//! `Value` is a tagged union covering every TOML 1.1 value kind: string,
//! integer, float, boolean, datetime/date/time, array, table.
//!
//! Memory model: all allocations belong to a caller-owned arena. Free
//! everything with `arena.deinit()`. `string` may be a zero-copy slice
//! into the original input buffer or an arena-allocated copy; the caller
//! must keep the input alive while the parse tree is in use.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.array_hash_map.String;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const testing = std.testing;

/// Source location of a parsed value. Byte offsets are relative to the
/// start of the input buffer; `line`/`col` are 1-indexed and refer to
/// the value's starting position.
pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    col: u32,
};

/// Path -> source span map, populated when `options.spans` is set on a
/// `parse` call. Array elements use `[N]` index segments (e.g.,
/// `users[0].name`).
pub const Spans = StringHashMapUnmanaged(Span);

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub const ParseError = error{InvalidDateTime};

    /// Parse a `YYYY-MM-DD` literal. The slice must contain exactly the
    /// literal -- no trailing bytes.
    pub fn parse(s: []const u8) ParseError!Date {
        return @import("datetime.zig").parseDate(s);
    }
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanos: u32 = 0,

    pub const ParseError = error{InvalidDateTime};

    /// Parse a `HH:MM:SS[.fff]` literal. The slice must contain exactly
    /// the literal -- no trailing bytes.
    pub fn parse(s: []const u8) ParseError!Time {
        return @import("datetime.zig").parseTimeOnly(s);
    }
};

pub const DateTime = struct {
    date: Date,
    time: Time,
    /// Minutes east of UTC. `null` = local datetime; `0` = `Z`/UTC.
    tz_offset_minutes: ?i16 = null,

    pub const ParseError = error{InvalidDateTime};

    /// Discriminated result alias: a TOML datetime/date/time literal can
    /// shape to any of the three types depending on its bytes. The actual
    /// union is defined in datetime.zig; aliased here so callers can
    /// refer to it as `toml.DateTime.Parsed`.
    pub const Parsed = @import("datetime.zig").Parsed;

    /// Parse any TOML datetime/date/time literal. The slice must contain
    /// exactly the literal -- no trailing bytes.
    pub fn parse(s: []const u8) ParseError!Parsed {
        return @import("datetime.zig").parseAny(s);
    }
};

/// Dynamic TOML value. Tables preserve insertion order for deterministic emit.
pub const Value = union(enum) {
    pub const Array = std.ArrayList(Value);
    pub const Table = std.array_hash_map.String(Value);

    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: DateTime,
    date: Date,
    time: Time,
    array: Array,
    table: Table,

    /// Deep equality. Order-sensitive for tables.
    pub fn eql(a: Value, b: Value) bool {
        if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
        return switch (a) {
            .string => std.mem.eql(u8, a.string, b.string),
            .integer => a.integer == b.integer,
            .float => blk: {
                // Bitwise compare so NaN==NaN and +0 != -0.
                const ab: u64 = @bitCast(a.float);
                const bb: u64 = @bitCast(b.float);
                break :blk ab == bb;
            },
            .boolean => a.boolean == b.boolean,
            .datetime => std.meta.eql(a.datetime, b.datetime),
            .date => std.meta.eql(a.date, b.date),
            .time => std.meta.eql(a.time, b.time),
            .array => blk: {
                if (a.array.items.len != b.array.items.len) break :blk false;
                for (a.array.items, b.array.items) |ai, bi| {
                    if (!eql(ai, bi)) break :blk false;
                }
                break :blk true;
            },
            .table => blk: {
                if (a.table.count() != b.table.count()) break :blk false;
                var it = a.table.iterator();
                while (it.next()) |entry| {
                    const other = b.table.get(entry.key_ptr.*) orelse break :blk false;
                    if (!eql(entry.value_ptr.*, other)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Look up a dotted path. Returns null if any segment is missing or
    /// traverses through a non-table. Array indices use `[N]` syntax:
    /// `users[0].name`, `matrix[3][7]`. A trailing `.` (e.g., `"a."`) is
    /// stripped -- `get("a.")` and `get("a")` return the same value.
    pub fn get(self: Value, path: []const u8) ?Value {
        var cur = self;
        var rest = path;
        while (rest.len > 0) {
            // Array index `[N]` immediately after a value.
            if (rest[0] == '[') {
                const close = std.mem.indexOfScalarPos(u8, rest, 1, ']') orelse return null;
                const idx = std.fmt.parseInt(usize, rest[1..close], 10) catch return null;
                if (cur != .array) return null;
                if (idx >= cur.array.items.len) return null;
                cur = cur.array.items[idx];
                rest = rest[close + 1 ..];
                if (rest.len > 0 and rest[0] == '.') rest = rest[1..];
                continue;
            }

            // Bare segment up to next '.' or '['.
            const seg_end = blk: {
                var i: usize = 0;
                while (i < rest.len and rest[i] != '.' and rest[i] != '[') : (i += 1) {}
                break :blk i;
            };
            const segment = rest[0..seg_end];
            if (cur != .table) return null;
            cur = cur.table.get(segment) orelse return null;
            rest = rest[seg_end..];
            if (rest.len > 0 and rest[0] == '.') rest = rest[1..];
        }
        return cur;
    }

    /// Convenience: `self.get(path) != null`.
    pub fn has(self: Value, path: []const u8) bool {
        return self.get(path) != null;
    }

    /// Paired result of `locate`: the value at `path` plus its source span.
    pub const Located = struct {
        value: Value,
        span: Span,
    };

    /// Look up a value at `path` AND its source span in one call. Returns
    /// null if the path is missing OR if the span map doesn't carry an
    /// entry for this path. Avoids typing the path twice when you need
    /// both pieces. Spans are populated when `parse` was called with
    /// `options.spans` set.
    pub fn locate(self: Value, spans: Spans, path: []const u8) ?Located {
        const v = self.get(path) orelse return null;
        const span = spans.get(path) orelse return null;
        return .{ .value = v, .span = span };
    }

    /// Look up + decode to T in one step. Returns null on missing OR on
    /// type mismatch (use `get` + `decode` when you need to distinguish).
    /// Supported T: bool, integer types (overflow returns null), float
    /// types, `[]const u8`, `Date`, `Time`, `DateTime`, `Value` (passthrough).
    pub fn getT(self: Value, comptime T: type, path: []const u8) ?T {
        const v = self.get(path) orelse return null;
        if (T == Value) return v;
        if (T == Date) return if (v == .date) v.date else null;
        if (T == Time) return if (v == .time) v.time else null;
        if (T == DateTime) return if (v == .datetime) v.datetime else null;
        return switch (@typeInfo(T)) {
            .bool => if (v == .boolean) v.boolean else null,
            .int => if (v == .integer) std.math.cast(T, v.integer) else null,
            .float => switch (v) {
                .float => |f| @floatCast(f),
                .integer => |n| @floatFromInt(n),
                else => null,
            },
            .pointer => |p| if (p.size == .slice and p.child == u8 and p.is_const)
                (if (v == .string) v.string else null)
            else
                @compileError("Value.getT: only []const u8 slices supported, got " ++ @typeName(T)),
            else => @compileError("Value.getT: unsupported type " ++ @typeName(T)),
        };
    }

    /// `var v: Value = .makeTable();` -- empty table. Allocations happen
    /// lazily on `tablePut`; no allocator needed up front.
    pub fn makeTable() Value {
        return .{ .table = .empty };
    }

    /// `var v: Value = .makeArray();` -- empty array. Allocations happen
    /// lazily on `arrayAppend`; no allocator needed up front.
    pub fn makeArray() Value {
        return .{ .array = .empty };
    }

    /// Allocate a string Value with an arena-owned copy of `s`.
    pub fn fromString(arena: Allocator, s: []const u8) Allocator.Error!Value {
        return .{ .string = try arena.dupe(u8, s) };
    }

    /// Insert key->value into a table Value. Key is duped into the arena;
    /// caller-owned `key` slice does not need to outlive this call. The
    /// `value` is moved as-is -- its inner allocations must already live in
    /// the same arena.
    pub fn tablePut(self: *Value, arena: Allocator, key: []const u8, value: Value) Allocator.Error!void {
        std.debug.assert(self.* == .table);
        const dup = try arena.dupe(u8, key);
        try self.table.put(arena, dup, value);
    }

    /// Fetch a value by key from a table Value. Returns null when self
    /// isn't a table or the key is absent.
    pub fn tableGet(self: Value, key: []const u8) ?Value {
        if (self != .table) return null;
        return self.table.get(key);
    }

    /// Append `value` to an array Value.
    pub fn arrayAppend(self: *Value, arena: Allocator, value: Value) Allocator.Error!void {
        std.debug.assert(self.* == .array);
        try self.array.append(arena, value);
    }

    pub const SetError = error{
        NotATable,
        InvalidPath,
        IntegerOverflow,
        PathTooDeep,
        OutOfMemory,
    };

    /// Set a value at `path` on this Value. Path syntax matches `get`:
    /// dotted segments (`server.port`) and `[N]` array indices (`users[0].name`).
    ///
    /// Creates intermediate tables/arrays as needed. Array-index writes
    /// extend by one when N == current length; out-of-bounds (N > length)
    /// returns InvalidPath. Setting through a non-matching segment (e.g.
    /// `leaf.deeper` where `leaf` is a scalar) returns InvalidPath.
    ///
    /// self must be a table or array; any other variant returns NotATable.
    /// (The error name is kept for API compatibility.)
    ///
    /// `value` is comptime-dispatched the same way as `Document.set`:
    /// Value passthrough, Date/Time/DateTime, bool, integer (runtime i64
    /// range check; returns IntegerOverflow for out-of-range unsigned or
    /// wide integer values), float, []const u8 / string literals.
    pub fn set(self: *Value, arena: Allocator, path: []const u8, value: anytype) SetError!void {
        switch (self.*) {
            .table, .array => {},
            else => return error.NotATable,
        }
        const v = try fromAny(arena, @TypeOf(value), value);
        return setAtPath(arena, self, path, v, 0);
    }

    /// Canonical type name used in error messages.
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .string => "string",
            .integer => "integer",
            .float => "float",
            .boolean => "bool",
            .datetime => "datetime",
            .date => "date",
            .time => "time",
            .array => "array",
            .table => "table",
        };
    }

    /// Deep-copy this Value into `target_arena`. All strings, table keys,
    /// arrays, and nested tables are re-allocated in the target. The
    /// returned Value is independent of the source's arena.
    ///
    /// Use this when a Value needs to outlive the parse arena (e.g.,
    /// caching parsed config across arena resets).
    pub fn clone(self: Value, target_arena: Allocator) Allocator.Error!Value {
        return switch (self) {
            .string => |s| .{ .string = try target_arena.dupe(u8, s) },
            .integer => |n| .{ .integer = n },
            .float => |f| .{ .float = f },
            .boolean => |b| .{ .boolean = b },
            .datetime => |dt| .{ .datetime = dt },
            .date => |d| .{ .date = d },
            .time => |t| .{ .time = t },
            .array => |arr| blk: {
                var out: Array = .empty;
                try out.ensureTotalCapacity(target_arena, arr.items.len);
                for (arr.items) |item| {
                    out.appendAssumeCapacity(try item.clone(target_arena));
                }
                break :blk .{ .array = out };
            },
            .table => |tbl| blk: {
                var out: Table = .empty;
                try out.ensureTotalCapacity(target_arena, @intCast(tbl.count()));
                var it = tbl.iterator();
                while (it.next()) |entry| {
                    const key_copy = try target_arena.dupe(u8, entry.key_ptr.*);
                    const val_copy = try entry.value_ptr.clone(target_arena);
                    out.putAssumeCapacity(key_copy, val_copy);
                }
                break :blk .{ .table = out };
            },
        };
    }
};

/// Convert a native Zig value into a `Value`, comptime-dispatched on
/// `@TypeOf(value)`. Used by `Value.set` and `Document.set`.
/// Supported: Value passthrough, Date/Time/DateTime, bool, integer
/// (runtime i64 range check; returns IntegerOverflow for values that do
/// not fit), float, []const u8, string literal pointers
/// (`*const [N:0]u8` and `*const [N]u8`). Unsupported types compile-error.
pub fn fromAny(arena: Allocator, comptime T: type, value: T) (Allocator.Error || error{IntegerOverflow})!Value {
    if (T == Value) return value;
    if (T == Date) return .{ .date = value };
    if (T == Time) return .{ .time = value };
    if (T == DateTime) return .{ .datetime = value };
    return switch (@typeInfo(T)) {
        .bool => .{ .boolean = value },
        .int, .comptime_int => .{ .integer = std.math.cast(i64, value) orelse return error.IntegerOverflow },
        .float, .comptime_float => .{ .float = @floatCast(value) },
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8 and p.is_const) {
                break :blk Value.fromString(arena, value);
            }
            if (p.size == .one and p.is_const) {
                const child_info = @typeInfo(p.child);
                if (child_info == .array and child_info.array.child == u8) {
                    const as_slice: []const u8 = value;
                    break :blk Value.fromString(arena, as_slice);
                }
            }
            @compileError("Value.fromAny: only []const u8 / string literal supported, got " ++ @typeName(T));
        },
        else => @compileError("Value.fromAny: unsupported type " ++ @typeName(T)),
    };
}

/// Maximum path depth accepted by setAtPath, mirroring the parser's
/// max_depth = 128 to give consistent nesting limits across parse and set.
const set_max_depth: usize = 128;

fn setAtPath(arena: Allocator, root: *Value, path: []const u8, new: Value, depth: usize) Value.SetError!void {
    if (depth >= set_max_depth) return error.PathTooDeep;

    if (path.len == 0) {
        root.* = new;
        return;
    }

    // Array index `[N]` at the start of the remaining path.
    if (path[0] == '[') {
        if (root.* != .array) return error.InvalidPath;
        const close = std.mem.indexOfScalarPos(u8, path, 1, ']') orelse return error.InvalidPath;
        const idx = std.fmt.parseInt(usize, path[1..close], 10) catch return error.InvalidPath;
        var rest = path[close + 1 ..];
        if (rest.len > 0 and rest[0] == '.') rest = rest[1..];

        if (idx < root.array.items.len) {
            if (rest.len == 0) {
                root.array.items[idx] = new;
                return;
            }
            return setAtPath(arena, &root.array.items[idx], rest, new, depth + 1);
        } else if (idx == root.array.items.len) {
            // One-past-end: append (extends array by one).
            if (rest.len == 0) {
                try root.array.append(arena, new);
                return;
            }
            var sub: Value = if (rest[0] == '[')
                .{ .array = .empty }
            else
                .{ .table = .empty };
            try setAtPath(arena, &sub, rest, new, depth + 1);
            try root.array.append(arena, sub);
            return;
        } else {
            return error.InvalidPath;
        }
    }

    // Bare segment up to next '.' or '['.
    const seg_end = blk: {
        var i: usize = 0;
        while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
        break :blk i;
    };
    const segment = path[0..seg_end];
    var rest = path[seg_end..];
    if (rest.len > 0 and rest[0] == '.') rest = rest[1..];

    if (root.* != .table) return error.InvalidPath;
    if (root.table.getPtr(segment)) |existing| {
        if (rest.len == 0) {
            existing.* = new;
            return;
        }
        return setAtPath(arena, existing, rest, new, depth + 1);
    } else {
        if (rest.len == 0) {
            const k = try arena.dupe(u8, segment);
            try root.table.put(arena, k, new);
            return;
        }
        // Create an intermediate table or array depending on the next segment shape.
        var sub: Value = if (rest[0] == '[')
            .{ .array = .empty }
        else
            .{ .table = .empty };
        try setAtPath(arena, &sub, rest, new, depth + 1);
        const k = try arena.dupe(u8, segment);
        try root.table.put(arena, k, sub);
        return;
    }
}

test "scalar Value: type name and access" {
    const v: Value = .{ .integer = 42 };
    try testing.expectEqual(@as(i64, 42), v.integer);
    try testing.expectEqualStrings("integer", v.typeName());
}

test "array Value: construction via helpers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v: Value = .makeArray();
    try v.arrayAppend(a, .{ .integer = 1 });
    try v.arrayAppend(a, .{ .integer = 2 });
    try v.arrayAppend(a, .{ .integer = 3 });
    try testing.expectEqual(@as(usize, 3), v.array.items.len);
    try testing.expectEqual(@as(i64, 2), v.array.items[1].integer);
}

test "nested table Value: construction via helpers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inner: Value = .makeTable();
    try inner.tablePut(a, "a", .{ .integer = 1 });
    var outer: Value = .makeTable();
    try outer.tablePut(a, "inner", inner);
    try outer.tablePut(a, "s", try Value.fromString(a, "hi"));

    try testing.expectEqual(@as(usize, 2), outer.table.count());
    const inner_v = outer.tableGet("inner") orelse return error.MissingKey;
    try testing.expectEqual(@as(i64, 1), inner_v.tableGet("a").?.integer);
}

test "eql value types" {
    const a = Value{ .integer = 10 };
    const b = Value{ .integer = 10 };
    const c = Value{ .integer = 11 };
    try testing.expect(Value.eql(a, b));
    try testing.expect(!Value.eql(a, c));

    const s1 = Value{ .string = "foo" };
    const s2 = Value{ .string = "foo" };
    const s3 = Value{ .string = "bar" };
    try testing.expect(Value.eql(s1, s2));
    try testing.expect(!Value.eql(s1, s3));
    try testing.expect(!Value.eql(a, s1));
}

test "eql floats incl. nan" {
    const a = Value{ .float = std.math.nan(f64) };
    const b = Value{ .float = std.math.nan(f64) };
    try testing.expect(Value.eql(a, b));

    const pos_zero = Value{ .float = 0.0 };
    const neg_zero = Value{ .float = -0.0 };
    try testing.expect(!Value.eql(pos_zero, neg_zero));
}

test "Value.get: dotted path traversal" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\title = "x"
        \\[server]
        \\port = 8080
    , .{});
    try testing.expectEqualStrings("x", v.get("title").?.string);
    try testing.expectEqual(@as(i64, 8080), v.get("server.port").?.integer);
    try testing.expect(v.get("missing") == null);
    try testing.expect(v.get("server.missing") == null);
    try testing.expect(v.get("title.never") == null); // can't traverse through scalar
}

test "Value.get: array index syntax" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\[[users]]
        \\name = "alice"
        \\[[users]]
        \\name = "bob"
    , .{});
    try testing.expectEqualStrings("alice", v.get("users[0].name").?.string);
    try testing.expectEqualStrings("bob", v.get("users[1].name").?.string);
    try testing.expect(v.get("users[2].name") == null); // out of bounds
}

test "Value.get: adjacent array indices (matrix[i][j] style)" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\rows = [ [1, 2, 3], [4, 5, 6] ]
    , .{});
    try testing.expectEqual(@as(i64, 1), v.get("rows[0][0]").?.integer);
    try testing.expectEqual(@as(i64, 6), v.get("rows[1][2]").?.integer);
    try testing.expect(v.get("rows[2][0]") == null);
    try testing.expect(v.get("rows[0][3]") == null);
}

test "Value.getT: typed access" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\port = 8080
        \\name = "x"
        \\tls = true
    , .{});
    try testing.expectEqual(@as(?u16, 8080), v.getT(u16, "port"));
    try testing.expectEqualStrings("x", v.getT([]const u8, "name").?);
    try testing.expectEqual(@as(?bool, true), v.getT(bool, "tls"));
    try testing.expect(v.getT(u16, "name") == null);    // type mismatch
    try testing.expect(v.getT(u16, "missing") == null); // missing path
    try testing.expect(v.getT(u8, "port") == null);     // overflow
}

test "Value.makeTable + tablePut + tableGet: build a table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Value = .makeTable();
    try t.tablePut(a, "name", try Value.fromString(a, "ef"));
    try t.tablePut(a, "port", .{ .integer = 8080 });
    try testing.expectEqualStrings("ef", t.tableGet("name").?.string);
    try testing.expectEqual(@as(i64, 8080), t.tableGet("port").?.integer);
    try testing.expect(t.tableGet("missing") == null);
}

test "Value.makeArray + arrayAppend: build an array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr: Value = .makeArray();
    try arr.arrayAppend(a, .{ .integer = 1 });
    try arr.arrayAppend(a, .{ .integer = 2 });
    try arr.arrayAppend(a, try Value.fromString(a, "three"));
    try testing.expectEqual(@as(usize, 3), arr.array.items.len);
    try testing.expectEqual(@as(i64, 2), arr.array.items[1].integer);
    try testing.expectEqualStrings("three", arr.array.items[2].string);
}

test "Value.fromString: dupes into arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf = [_]u8{ 'h', 'i' };
    const v = try Value.fromString(arena.allocator(), &buf);
    buf[0] = 'x'; // mutate the source
    try testing.expectEqualStrings("hi", v.string); // copy is independent
}

test "Date.parse: literal" {
    const d = try Date.parse("1979-05-27");
    try testing.expectEqual(@as(u16, 1979), d.year);
    try testing.expectEqual(@as(u8, 5), d.month);
    try testing.expectEqual(@as(u8, 27), d.day);
    try testing.expectError(error.InvalidDateTime, Date.parse("not-a-date"));
}

test "Time.parse: literal" {
    const t = try Time.parse("07:32:00");
    try testing.expectEqual(@as(u8, 7), t.hour);
    try testing.expectEqual(@as(u8, 32), t.minute);
    try testing.expectEqual(@as(u8, 0), t.second);
    try testing.expectError(error.InvalidDateTime, Time.parse("nope"));
}

test "DateTime.parse: discriminated by literal shape" {
    const p1 = try DateTime.parse("1979-05-27T07:32:00Z");
    try testing.expect(p1 == .datetime);
    try testing.expectEqual(@as(?i16, 0), p1.datetime.tz_offset_minutes);

    const p2 = try DateTime.parse("1979-05-27");
    try testing.expect(p2 == .date);

    const p3 = try DateTime.parse("07:32:00");
    try testing.expect(p3 == .time);

    try testing.expectError(error.InvalidDateTime, DateTime.parse("not-anything"));
}

test "Value.getT: Date / Time / DateTime targets" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\d = 1979-05-27
        \\t = 07:32:00
        \\dt = 1979-05-27T07:32:00Z
    , .{});

    const d = v.getT(Date, "d").?;
    try testing.expectEqual(@as(u16, 1979), d.year);

    const t = v.getT(Time, "t").?;
    try testing.expectEqual(@as(u8, 7), t.hour);

    const dt = v.getT(DateTime, "dt").?;
    try testing.expectEqual(@as(u16, 1979), dt.date.year);
    try testing.expectEqual(@as(?i16, 0), dt.tz_offset_minutes);

    // Type mismatch: asking for Date where the path holds a Time.
    try testing.expect(v.getT(Date, "t") == null);
    // Missing path.
    try testing.expect(v.getT(DateTime, "missing") == null);
}

test "Value.set: simple top-level keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root: Value = .makeTable();
    try root.set(a, "name", "ef");
    try root.set(a, "port", @as(u16, 8080));
    try root.set(a, "tls", true);

    try testing.expectEqualStrings("ef", root.tableGet("name").?.string);
    try testing.expectEqual(@as(i64, 8080), root.tableGet("port").?.integer);
    try testing.expectEqual(true, root.tableGet("tls").?.boolean);
}

test "Value.set: nested path creates intermediates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root: Value = .makeTable();
    try root.set(a, "server.host", "localhost");
    try root.set(a, "server.port", @as(u16, 9000));
    try root.set(a, "client.timeout", @as(u32, 30));

    try testing.expectEqualStrings("localhost", root.get("server.host").?.string);
    try testing.expectEqual(@as(i64, 9000), root.get("server.port").?.integer);
    try testing.expectEqual(@as(i64, 30), root.get("client.timeout").?.integer);
}

test "Value.set: errors on non-table self" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v: Value = .{ .integer = 42 };
    try testing.expectError(error.NotATable, v.set(arena.allocator(), "x", @as(u16, 1)));
}

test "Value.set: errors on intermediate non-table segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .makeTable();
    try root.tablePut(a, "leaf", .{ .integer = 42 });
    try testing.expectError(error.InvalidPath, root.set(a, "leaf.deeper", @as(u16, 1)));
}

test "Value.set: Value passthrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var root: Value = .makeTable();
    try root.set(arena.allocator(), "x", Value{ .integer = 99 });
    try testing.expectEqual(@as(i64, 99), root.get("x").?.integer);
}

test "Value.has: convenience wrapper" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\title = "x"
        \\[server]
        \\port = 8080
    , .{});
    try testing.expect(v.has("title"));
    try testing.expect(v.has("server.port"));
    try testing.expect(!v.has("missing"));
    try testing.expect(!v.has("server.missing"));
}

test "Value.locate: paired value + span lookup" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: Spans = .empty;
    const v = try parse(arena.allocator(),
        \\title = "x"
        \\[server]
        \\port = 8080
    , .{ .spans = &spans });

    const located = v.locate(spans, "server.port").?;
    try testing.expectEqual(@as(i64, 8080), located.value.integer);
    try testing.expect(located.span.end > located.span.start);
    try testing.expectEqual(@as(u32, 3), located.span.line); // line 3 (1-indexed)

    try testing.expect(v.locate(spans, "missing") == null);
}

test "Value.locate: returns null when spans wasn't tracked" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty_spans: Spans = .empty;
    const v = try parse(arena.allocator(),
        \\port = 8080
    , .{});
    try testing.expect(v.locate(empty_spans, "port") == null);
}

test "Value.clone: scalar variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v1: Value = .{ .integer = 42 };
    const c1 = try v1.clone(a);
    try testing.expectEqual(@as(i64, 42), c1.integer);

    const v2: Value = .{ .boolean = true };
    const c2 = try v2.clone(a);
    try testing.expectEqual(true, c2.boolean);

    const v3: Value = .{ .float = 1.5 };
    const c3 = try v3.clone(a);
    try testing.expectEqual(@as(f64, 1.5), c3.float);
}

test "Value.clone: strings dup into target arena" {
    const parse = @import("parser.zig").parse;
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    var tgt_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tgt_arena.deinit();

    // Parse into src_arena, then clone into tgt_arena, then drop src.
    const v = try parse(src_arena.allocator(),
        \\name = "ef"
    , .{});
    const cloned = try v.clone(tgt_arena.allocator());

    // Drop the source arena -- cloned must still be readable.
    src_arena.deinit();

    try testing.expectEqualStrings("ef", cloned.get("name").?.string);
}

test "Value.clone: nested tables and arrays" {
    const parse = @import("parser.zig").parse;
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    var tgt_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tgt_arena.deinit();

    const v = try parse(src_arena.allocator(),
        \\[server]
        \\port = 8080
        \\hosts = ["alpha", "beta"]
        \\
        \\[[users]]
        \\name = "alice"
        \\
        \\[[users]]
        \\name = "bob"
    , .{});

    const cloned = try v.clone(tgt_arena.allocator());
    src_arena.deinit();

    try testing.expectEqual(@as(i64, 8080), cloned.get("server.port").?.integer);
    try testing.expectEqualStrings("alpha", cloned.get("server.hosts[0]").?.string);
    try testing.expectEqualStrings("bob", cloned.get("users[1].name").?.string);
}

test "Value.clone: structural equality with source" {
    const parse = @import("parser.zig").parse;
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var tgt_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tgt_arena.deinit();

    const v = try parse(src_arena.allocator(),
        \\title = "x"
        \\port = 8080
        \\tags = ["a", "b"]
    , .{});

    const cloned = try v.clone(tgt_arena.allocator());
    try testing.expect(Value.eql(v, cloned));
}

test "Value.set: array index write into existing slot" {
    const parse = @import("parser.zig").parse;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var root = try parse(arena.allocator(),
        \\[[users]]
        \\name = "alice"
        \\[[users]]
        \\name = "bob"
    , .{});

    try root.set(arena.allocator(), "users[0].name", "ALICE");
    try testing.expectEqualStrings("ALICE", root.get("users[0].name").?.string);
    try testing.expectEqualStrings("bob", root.get("users[1].name").?.string);
}

test "Value.set: array append at one-past-end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .makeTable();
    try root.tablePut(a, "tags", .makeArray());
    try root.set(a, "tags[0]", "alpha");
    try root.set(a, "tags[1]", "beta");
    try testing.expectEqualStrings("alpha", root.get("tags[0]").?.string);
    try testing.expectEqualStrings("beta", root.get("tags[1]").?.string);
}

test "Value.set: out-of-bounds array index errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .makeTable();
    try root.tablePut(a, "tags", .makeArray());
    try testing.expectError(error.InvalidPath, root.set(a, "tags[5]", "boom"));
}

test "Value.set: nested table inside array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .makeTable();
    try root.set(a, "users[0].name", "alice");
    try root.set(a, "users[0].age", @as(u8, 30));
    try root.set(a, "users[1].name", "bob");
    try testing.expectEqualStrings("alice", root.get("users[0].name").?.string);
    try testing.expectEqual(@as(i64, 30), root.get("users[0].age").?.integer);
    try testing.expectEqualStrings("bob", root.get("users[1].name").?.string);
}

test "Value.set: u64 >= 2^63 returns IntegerOverflow, not panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .{ .table = .empty };
    const big: u64 = @as(u64, std.math.maxInt(i64)) + 1;
    try testing.expectError(error.IntegerOverflow, root.set(a, "k", big));
    // In-range values must still work.
    try root.set(a, "k", @as(u64, std.math.maxInt(i64)));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), root.get("k").?.integer);
}

test "Value.set: setAtPath depth limit returns PathTooDeep, not segfault" {
    // Build a dotted path of ~200 segments, well above the 128-segment
    // limit. The guard must return an error before exhausting stack space.
    // 200 segments * 2 bytes each ("a.") = 400 bytes -- trivially cheap to
    // allocate and fast to reject.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const seg_count = 200;
    // "a.a.a..." with seg_count segments = seg_count * 2 - 1 bytes.
    var path_buf = try a.alloc(u8, seg_count * 2 - 1);
    for (0..seg_count) |i| {
        path_buf[i * 2] = 'a';
        if (i + 1 < seg_count) path_buf[i * 2 + 1] = '.';
    }
    const path = path_buf[0 .. seg_count * 2 - 1];

    var root: Value = .{ .table = .empty };
    try testing.expectError(error.PathTooDeep, root.set(a, path, @as(i64, 42)));
}

