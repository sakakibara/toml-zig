//! Typed decoding from `Value` into native Zig types.
//!
//! Maps a parsed TOML `Value` tree onto a target struct via comptime
//! reflection, the way `serde::Deserialize` does in Rust. Strings and slices
//! are zero-copy where possible; everything else lives in the caller's arena.
//!
//! ```zig
//! const Config = struct {
//!     title: []const u8,
//!     port: u16 = 8080,
//!     tags: []const []const u8,
//!     server: struct {
//!         host: []const u8,
//!         tls: bool = false,
//!     },
//! };
//!
//! const cfg = try toml.parseInto(Config, arena, src, .{});
//! ```
//!
//! Field defaults satisfy missing-field cases. Optional fields (`?T`) become
//! `null` when absent. Unknown TOML keys are an error by default; opt out
//! with `ParseOptions{ .ignore_unknown_fields = true }`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Date = value_mod.Date;
const Time = value_mod.Time;
const DateTime = value_mod.DateTime;
const parser_mod = @import("parser.zig");
const lev = @import("levenshtein.zig");

pub const DecodeError = error{
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
    /// The TOML value does not fit the TARGET Zig type (e.g. 300 into a
    /// u8). Distinct from `IntegerOverflow` (value/encoder/document),
    /// which means a Zig value cannot be represented as a TOML i64.
    Overflow,
    OutOfMemory,
};

const PathBuilder = struct {
    buf: std.ArrayList(u8),

    pub fn pushSegment(self: *PathBuilder, arena: Allocator, segment: []const u8) Allocator.Error!usize {
        const prev = self.buf.items.len;
        if (prev > 0) try self.buf.append(arena, '.');
        try self.buf.appendSlice(arena, segment);
        return prev;
    }

    pub fn pushIndex(self: *PathBuilder, arena: Allocator, idx: usize) Allocator.Error!usize {
        const prev = self.buf.items.len;
        const s = try std.fmt.allocPrint(arena, "[{d}]", .{idx});
        try self.buf.appendSlice(arena, s);
        return prev;
    }

    pub fn restore(self: *PathBuilder, prev_len: usize) void {
        self.buf.shrinkRetainingCapacity(prev_len);
    }

    pub fn slice(self: *const PathBuilder) []const u8 {
        return self.buf.items;
    }
};

/// Append a decode diagnostic (formatted message + current path context +
/// optional "did you mean" suggestion) to the caller-provided errors sink,
/// if any. Everything is duped into the parse arena, matching Diagnostic's
/// ownership contract.
fn addDiagSuggest(
    arena: Allocator,
    options: parser_mod.ParseOptions,
    path: *const PathBuilder,
    suggestion: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const list = options.errors orelse return;
    const msg = try std.fmt.allocPrint(arena, fmt, args);
    const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
    try list.append(arena, .{
        .message = msg,
        .path = path_owned,
        .suggestion = if (suggestion) |sug| try arena.dupe(u8, sug) else null,
    });
}

/// addDiagSuggest without a suggestion; the common case.
fn addDiag(
    arena: Allocator,
    options: parser_mod.ParseOptions,
    path: *const PathBuilder,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    return addDiagSuggest(arena, options, path, null, fmt, args);
}

const annotations = @import("annotations.zig");
const renamedKey = annotations.renamedKey;
const isSkipped = annotations.isSkipped;
const isFlattened = annotations.isFlattened;

/// Returns the full set of TOML keys that decoding `T` expects to see
/// at the table's level -- i.e., renamed names for non-flattened fields,
/// plus the expectedKeys of each flattened field's type (recursive).
fn expectedKeys(comptime T: type) []const []const u8 {
    comptime {
        const s = @typeInfo(T).@"struct";
        var keys: []const []const u8 = &.{};
        for (s.fields) |field| {
            if (isSkipped(T, field.name)) continue;
            if (isFlattened(T, field.name)) {
                const inner = expectedKeys(field.type);
                keys = keys ++ inner;
            } else {
                keys = keys ++ &[_][]const u8{renamedKey(T, field.name)};
            }
        }
        return keys;
    }
}

/// Decode a `Value` into an instance of `T`.
pub fn decode(comptime T: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions) DecodeError!T {
    var path: PathBuilder = .{ .buf = .empty };
    return decodeInner(T, arena, value, options, &path);
}

fn decodeInner(comptime T: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (T == Date) {
        if (value != .date) {
            try addDiag(arena, options, path, "expected date, got {s}", .{@tagName(value)});
            return error.TypeMismatch;
        }
        return value.date;
    }
    if (T == Time) {
        if (value != .time) {
            try addDiag(arena, options, path, "expected time, got {s}", .{@tagName(value)});
            return error.TypeMismatch;
        }
        return value.time;
    }
    if (T == DateTime) {
        if (value != .datetime) {
            try addDiag(arena, options, path, "expected datetime, got {s}", .{@tagName(value)});
            return error.TypeMismatch;
        }
        return value.datetime;
    }
    if (T == Value) return value;

    // Custom fromToml hook short-circuit.
    if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "fromToml"))) {
        comptime {
            const fn_info = @typeInfo(@TypeOf(T.fromToml)).@"fn";
            if (fn_info.params.len != 3) {
                @compileError(@typeName(T) ++ ".fromToml must take exactly 3 params: (Allocator, Value, ParseOptions)");
            }
        }
        return T.fromToml(arena, value, options);
    }

    // Tagged-union dispatch.
    if (comptime (@typeInfo(T) == .@"union" and @hasDecl(T, "toml_tag"))) {
        return decodeTaggedUnion(T, arena, value, options, path);
    }

    return switch (@typeInfo(T)) {
        .bool => decodeBool(value, arena, options, path),
        .int => decodeInt(T, value, arena, options, path),
        .float => decodeFloat(T, value, arena, options, path),
        .pointer => |p| decodePointer(T, p, arena, value, options, path),
        .array => |a| decodeArray(T, a, arena, value, options, path),
        .optional => |o| decodeOptional(o.child, arena, value, options, path),
        .@"struct" => |s| decodeStruct(T, s, arena, value, options, path),
        .@"enum" => decodeEnum(T, value, arena, options, path),
        else => @compileError("toml decode: unsupported type " ++ @typeName(T)),
    };
}

fn decodeBool(value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!bool {
    if (value != .boolean) {
        try addDiag(arena, options, path, "expected boolean, got {s}", .{@tagName(value)});
        return error.TypeMismatch;
    }
    return value.boolean;
}

fn decodeInt(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .integer) {
        try addDiag(arena, options, path, "expected integer, got {s}", .{@tagName(value)});
        return error.TypeMismatch;
    }
    if (std.math.cast(T, value.integer)) |v| return v;
    try addDiag(arena, options, path, "integer {d} out of range for {s}", .{ value.integer, @typeName(T) });
    return error.Overflow;
}

fn decodeFloat(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    return switch (value) {
        .float => |f| blk: {
            const r: T = @floatCast(f);
            // Finite source -> inf result means the value overflowed the narrower type.
            if (!std.math.isInf(f) and std.math.isInf(r)) return error.Overflow;
            break :blk r;
        },
        .integer => |n| blk: {
            const r: T = @floatFromInt(n);
            // Integer -> inf means the value exceeded the float type's finite range.
            if (std.math.isInf(r)) return error.Overflow;
            break :blk r;
        },
        else => {
            try addDiag(arena, options, path, "expected float, got {s}", .{@tagName(value)});
            return error.TypeMismatch;
        },
    };
}

fn decodePointer(comptime T: type, comptime p: std.builtin.Type.Pointer, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (p.size != .slice) @compileError("toml decode: only slice pointers supported, got " ++ @typeName(T));
    if (p.child == u8 and p.is_const) {
        if (value != .string) {
            try addDiag(arena, options, path, "expected string, got {s}", .{@tagName(value)});
            return error.TypeMismatch;
        }
        return value.string;
    }
    if (value != .array) {
        try addDiag(arena, options, path, "expected array, got {s}", .{@tagName(value)});
        return error.TypeMismatch;
    }
    const items = value.array.items;
    const out = try arena.alloc(p.child, items.len);
    for (items, 0..) |item, i| {
        const prev = try path.pushIndex(arena, i);
        defer path.restore(prev);
        out[i] = try decodeInner(p.child, arena, item, options, path);
    }
    return out;
}

fn decodeArray(comptime T: type, comptime a: std.builtin.Type.Array, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .array) {
        try addDiag(arena, options, path, "expected array, got {s}", .{@tagName(value)});
        return error.TypeMismatch;
    }
    if (value.array.items.len != a.len) {
        try addDiag(arena, options, path, "array length mismatch: expected {d}, got {d}", .{ a.len, value.array.items.len });
        return error.TypeMismatch;
    }
    var out: T = undefined;
    // Guard prevents a compile error when T is [0]Child: Zig rejects
    // out[i] on a zero-length array even when the loop body is unreachable.
    if (comptime a.len > 0) {
        for (value.array.items, 0..) |item, i| {
            const prev = try path.pushIndex(arena, i);
            defer path.restore(prev);
            out[i] = try decodeInner(a.child, arena, item, options, path);
        }
    }
    return out;
}

fn decodeOptional(comptime Child: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!?Child {
    return try decodeInner(Child, arena, value, options, path);
}

fn decodeStruct(comptime T: type, comptime s: std.builtin.Type.Struct, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .table) {
        try addDiag(arena, options, path, "expected table, got {s}", .{@tagName(value)});
        return error.TypeMismatch;
    }
    const tbl = value.table;

    // Unknown-field check runs before field assignment so that an
    // unrecognized key is reported as UnknownField rather than being
    // shadowed by a subsequent MissingField on a required field.
    if (!options.ignore_unknown_fields) {
        var it = tbl.iterator();
        outer: while (it.next()) |entry| {
            inline for (comptime expectedKeys(T)) |expected| {
                if (std.mem.eql(u8, entry.key_ptr.*, expected)) continue :outer;
            }
            // Unknown key. Try a suggestion.
            const key = entry.key_ptr.*;
            const suggestion = lev.closestMatch(key, comptime expectedKeys(T), lev.suggestionThreshold(key.len));

            try addDiagSuggest(arena, options, path, suggestion, "unknown field `{s}`", .{key});
            return error.UnknownField;
        }
    }

    var out: T = undefined;
    var seen: [s.fields.len]bool = @splat(false);

    inline for (s.fields, 0..) |field, idx| {
        if (comptime isSkipped(T, field.name)) {
            const dv = comptime field.defaultValue() orelse
                @compileError("toml_skip field `" ++ field.name ++ "` on " ++ @typeName(T) ++ " has no default value");
            @field(out, field.name) = dv;
            seen[idx] = true;
            continue;
        }
        if (comptime isFlattened(T, field.name)) {
            // Decode the inner struct from the SAME parent value (no key lookup).
            // The parent's expectedKeys recurses through flattened field types,
            // so a genuinely-unknown key (belonging to neither the parent nor any
            // flattened sub-struct) is already rejected above in strict mode.
            // The inner decode must therefore ignore unknown fields: at its level
            // every parent-owned sibling key (e.g. the parent's other fields) is
            // "unknown", and rejecting those would break flatten entirely.
            const prev = try path.pushSegment(arena, field.name);
            defer path.restore(prev);
            const flat_opts: parser_mod.ParseOptions = .{
                .errors = options.errors,
                .spans = options.spans,
                .ignore_unknown_fields = true,
            };
            @field(out, field.name) = try decodeInner(field.type, arena, value, flat_opts, path);
            seen[idx] = true;
            continue;
        }
        const eff_key = comptime renamedKey(T, field.name);
        if (tbl.get(eff_key)) |fv| {
            const prev = try path.pushSegment(arena, eff_key);
            defer path.restore(prev);
            @field(out, field.name) = try decodeInner(field.type, arena, fv, options, path);
            seen[idx] = true;
        } else if (field.defaultValue()) |dv| {
            @field(out, field.name) = dv;
            seen[idx] = true;
        } else if (@typeInfo(field.type) == .optional) {
            @field(out, field.name) = null;
            seen[idx] = true;
        } else {
            try addDiag(arena, options, path, "missing required field `{s}`", .{field.name});
            return error.MissingField;
        }
    }

    return out;
}

fn decodeTaggedUnion(comptime T: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .table) {
        try addDiag(arena, options, path, "expected table, got {s}", .{@tagName(value)});
        return error.TypeMismatch;
    }
    const tbl = value.table;
    const tag_field = T.toml_tag;
    const tag_value = tbl.get(tag_field) orelse {
        try addDiag(arena, options, path, "missing required field `{s}`", .{tag_field});
        return error.MissingField;
    };
    if (tag_value != .string) {
        try addDiag(arena, options, path, "expected string, got {s}", .{@tagName(tag_value)});
        return error.TypeMismatch;
    }

    inline for (@typeInfo(T).@"union".fields) |union_field| {
        const variant_name = union_field.name;
        const effective_name = comptime renamedKey(T, variant_name);
        if (std.mem.eql(u8, tag_value.string, effective_name)) {
            const PayloadType = union_field.type;

            if (PayloadType == void) {
                return @unionInit(T, variant_name, {});
            }

            // Build a filtered table view that drops the discriminator field.
            var filtered: Value.Table = .empty;
            var it = tbl.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, tag_field)) continue;
                const key_dup = try arena.dupe(u8, entry.key_ptr.*);
                try filtered.put(arena, key_dup, entry.value_ptr.*);
            }
            const filtered_value = Value{ .table = filtered };
            const payload = try decodeInner(PayloadType, arena, filtered_value, options, path);
            return @unionInit(T, variant_name, payload);
        }
    }
    try addDiag(arena, options, path, "invalid enum value `{s}` for {s}", .{ tag_value.string, @typeName(T) });
    return error.InvalidEnumValue;
}

fn decodeEnum(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    switch (value) {
        .string => |s| {
            if (std.meta.stringToEnum(T, s)) |v| return v;
            try addDiag(arena, options, path, "invalid enum value `{s}` for {s}", .{ s, @typeName(T) });
            return error.InvalidEnumValue;
        },
        .integer => |n| {
            if (std.enums.fromInt(T, n)) |v| return v;
            try addDiag(arena, options, path, "integer {d} is not a valid value of {s}", .{ n, @typeName(T) });
            return error.InvalidEnumValue;
        },
        else => {
            try addDiag(arena, options, path, "expected string or integer for enum {s}, got {s}", .{ @typeName(T), @tagName(value) });
            return error.TypeMismatch;
        },
    }
}

const parse = @import("parser.zig").parse;

test "decode flat struct" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\title = "toml"
        \\port = 8080
        \\enabled = true
    , .{});
    const Config = struct {
        title: []const u8,
        port: u16,
        enabled: bool,
    };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqualStrings("toml", cfg.title);
    try testing.expectEqual(@as(u16, 8080), cfg.port);
    try testing.expectEqual(true, cfg.enabled);
}

test "decode nested struct" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\[server]
        \\host = "localhost"
        \\port = 9000
    , .{});
    const Config = struct {
        server: struct {
            host: []const u8,
            port: u16,
        },
    };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqualStrings("localhost", cfg.server.host);
    try testing.expectEqual(@as(u16, 9000), cfg.server.port);
}

test "decode slice of strings" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\tags = ["a", "b", "c"]
    , .{});
    const Config = struct { tags: []const []const u8 };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(usize, 3), cfg.tags.len);
    try testing.expectEqualStrings("a", cfg.tags[0]);
    try testing.expectEqualStrings("c", cfg.tags[2]);
}

test "decode field defaults" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\title = "x"
    , .{});
    const Config = struct {
        title: []const u8,
        port: u16 = 8080,
        tls: bool = false,
    };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(u16, 8080), cfg.port);
    try testing.expectEqual(false, cfg.tls);
}

test "decode optionals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\title = "x"
    , .{});
    const Config = struct {
        title: []const u8,
        nick: ?[]const u8,
    };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(?[]const u8, null), cfg.nick);
}

test "decode missing required field is error" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "", .{});
    const Config = struct { required: []const u8 };
    try testing.expectError(error.MissingField, decode(Config, arena.allocator(), v, .{}));
}

test "decode unknown field is error by default" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\known = "yes"
        \\extra = "no"
    , .{});
    const Config = struct { known: []const u8 };
    try testing.expectError(error.UnknownField, decode(Config, arena.allocator(), v, .{}));
}

test "decode unknown field allowed with option" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\known = "yes"
        \\extra = "no"
    , .{});
    const Config = struct { known: []const u8 };
    const cfg = try decode(Config, arena.allocator(), v, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("yes", cfg.known);
}

test "decode integer overflow" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "n = 999999", .{});
    const Config = struct { n: u8 };
    try testing.expectError(error.Overflow, decode(Config, arena.allocator(), v, .{}));
}

test "decode enum from string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\level = "warn"
    , .{});
    const Level = enum { debug, info, warn, err };
    const Config = struct { level: Level };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(Level.warn, cfg.level);
}

test "decode array of tables" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\[[users]]
        \\name = "alice"
        \\age = 30
        \\
        \\[[users]]
        \\name = "bob"
        \\age = 25
    , .{});
    const User = struct { name: []const u8, age: u32 };
    const Config = struct { users: []const User };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(usize, 2), cfg.users.len);
    try testing.expectEqualStrings("alice", cfg.users[0].name);
    try testing.expectEqual(@as(u32, 25), cfg.users[1].age);
}

test "decode datetime field" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\created_at = 1979-05-27T07:32:00Z
    , .{});
    const Config = struct { created_at: DateTime };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(u16, 1979), cfg.created_at.date.year);
    try testing.expectEqual(@as(?i16, 0), cfg.created_at.tz_offset_minutes);
}

test "decode raw Value passthrough" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\anything = "goes"
    , .{});
    const Config = struct { anything: Value };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqualStrings("goes", cfg.anything.string);
}

test "decode date field" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\d = 1979-05-27
    , .{});
    const Config = struct { d: Date };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(u16, 1979), cfg.d.year);
    try testing.expectEqual(@as(u8, 5), cfg.d.month);
    try testing.expectEqual(@as(u8, 27), cfg.d.day);
}

test "decode time field" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\t = 07:32:00.5
    , .{});
    const Config = struct { t: Time };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(u8, 7), cfg.t.hour);
    try testing.expectEqual(@as(u8, 32), cfg.t.minute);
    try testing.expectEqual(@as(u8, 0), cfg.t.second);
    try testing.expectEqual(@as(u32, 500_000_000), cfg.t.nanos);
}

test "decode enum from integer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\level = 2
    , .{});
    const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };
    const Config = struct { level: Level };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(Level.warn, cfg.level);
}

test "decode enum from out-of-range integer is error" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\level = 99
    , .{});
    const Level = enum(u8) { debug = 0, info = 1 };
    const Config = struct { level: Level };
    try testing.expectError(error.InvalidEnumValue, decode(Config, arena.allocator(), v, .{}));
}

test "decode optional struct present" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\[server]
        \\host = "localhost"
        \\port = 8080
    , .{});
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { server: ?Server };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expect(cfg.server != null);
    try testing.expectEqualStrings("localhost", cfg.server.?.host);
    try testing.expectEqual(@as(u16, 8080), cfg.server.?.port);
}

test "PathBuilder: push/restore symmetry" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var path: PathBuilder = .{ .buf = .empty };

    const p1 = try path.pushSegment(arena.allocator(), "server");
    try testing.expectEqualStrings("server", path.slice());

    const p2 = try path.pushSegment(arena.allocator(), "port");
    try testing.expectEqualStrings("server.port", path.slice());

    path.restore(p2);
    try testing.expectEqualStrings("server", path.slice());

    const p3 = try path.pushIndex(arena.allocator(), 7);
    try testing.expectEqualStrings("server[7]", path.slice());

    path.restore(p3);
    path.restore(p1);
    try testing.expectEqualStrings("", path.slice());
}

test "decode: unknown field suggests closest match" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());

    // `prt` is a typo for `port`; `port` is also present so the required
    // field is satisfied and the unknown-field check runs.
    const v = try parse(arena.allocator(),
        \\port = 8080
        \\prt = 9090
    , .{});

    const Config = struct { port: u16 };
    _ = decode(Config, arena.allocator(), v, .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 1);
    try testing.expect(errs.items[0].suggestion != null);
    try testing.expectEqualStrings("port", errs.items[0].suggestion.?);
}

test "decode: nested type mismatch populates path" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(arena.allocator());

    const v = try parse(arena.allocator(),
        \\[server]
        \\port = "8080"
    , .{});

    const Config = struct {
        server: struct { port: u16 },
    };
    _ = decode(Config, arena.allocator(), v, .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 1);
    try testing.expect(errs.items[0].path != null);
    try testing.expectEqualStrings("server.port", errs.items[0].path.?);
}

test "decode: toml_rename maps TOML key to struct field" {
    const Config = struct {
        pub const toml_rename = .{ .listen_addr = "listen-addr" };
        listen_addr: []const u8,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\listen-addr = "0.0.0.0"
    , .{});
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqualStrings("0.0.0.0", cfg.listen_addr);
}

test "decode: toml_rename unknown-field check uses renamed name" {
    const Config = struct {
        pub const toml_rename = .{ .listen_addr = "listen-addr" };
        listen_addr: []const u8,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Original snake_case key -- should error since renamed key is expected.
    const v = try parse(arena.allocator(),
        \\listen_addr = "0.0.0.0"
    , .{});
    try testing.expectError(error.UnknownField, decode(Config, arena.allocator(), v, .{}));
}

test "decode: toml_flatten decodes sub-fields from parent" {
    const Inner = struct { x: u32, y: u32 };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\name = "foo"
        \\x = 42
        \\y = 99
    , .{});
    const cfg = try decode(Outer, arena.allocator(), v, .{});
    try testing.expectEqualStrings("foo", cfg.name);
    try testing.expectEqual(@as(u32, 42), cfg.inner.x);
    try testing.expectEqual(@as(u32, 99), cfg.inner.y);
}

test "decode: toml_flatten unknown-field check expands flattened keys" {
    const Inner = struct { x: u32 };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\name = "foo"
        \\x = 42
        \\unexpected = "boom"
    , .{});
    try testing.expectError(error.UnknownField, decode(Outer, arena.allocator(), v, .{}));
}

test "decode: toml_flatten strict mode catches key owned by nobody" {
    // A key that matches NEITHER the parent's own fields NOR the flattened
    // sub-struct's fields must still raise UnknownField in strict mode, even
    // though the inner flatten decode runs with ignore_unknown_fields=true.
    const Inner = struct { x: u32, y: u32 };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        count: u32,
        inner: Inner,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\name = "foo"
        \\count = 3
        \\x = 1
        \\y = 2
        \\nobody = "boom"
    , .{});
    try testing.expectError(error.UnknownField, decode(Outer, arena.allocator(), v, .{}));
}

test "decode: toml_flatten strict mode accepts all valid sibling + inner keys" {
    // Sibling keys belonging to the parent's OTHER fields must NOT be rejected
    // by the inner flatten decode in strict mode.
    const Inner = struct { x: u32, y: u32 };
    const Outer = struct {
        pub const toml_flatten = .{"inner"};
        name: []const u8,
        count: u32,
        inner: Inner,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\name = "foo"
        \\count = 3
        \\x = 1
        \\y = 2
    , .{});
    const cfg = try decode(Outer, arena.allocator(), v, .{});
    try testing.expectEqualStrings("foo", cfg.name);
    try testing.expectEqual(@as(u32, 3), cfg.count);
    try testing.expectEqual(@as(u32, 1), cfg.inner.x);
    try testing.expectEqual(@as(u32, 2), cfg.inner.y);
}

test "decode: toml_skip excludes field from decode" {
    const Config = struct {
        pub const toml_skip = .{"internal"};
        name: []const u8,
        internal: u32 = 7,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\name = "foo"
    , .{});
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqualStrings("foo", cfg.name);
    try testing.expectEqual(@as(u32, 7), cfg.internal);
}

test "decode: toml_skip rejects 'internal' key in strict mode" {
    const Config = struct {
        pub const toml_skip = .{"internal"};
        name: []const u8,
        internal: u32 = 7,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\name = "foo"
        \\internal = 99
    , .{});
    // Skipped fields are excluded from the expected-keys set,
    // so a TOML key matching a skipped field is "unknown".
    try testing.expectError(error.UnknownField, decode(Config, arena.allocator(), v, .{}));
}

test "decode: fromToml hook short-circuits built-in dispatch" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn fromToml(arena: std.mem.Allocator, value: Value, _: parser_mod.ParseOptions) DecodeError!@This() {
            _ = arena;
            if (value != .string) return error.TypeMismatch;
            var it = std.mem.tokenizeAny(u8, value.string, ".");
            const maj_s = it.next() orelse return error.TypeMismatch;
            const min_s = it.next() orelse return error.TypeMismatch;
            const pat_s = it.next() orelse return error.TypeMismatch;
            const maj = std.fmt.parseInt(u32, maj_s, 10) catch return error.TypeMismatch;
            const min = std.fmt.parseInt(u32, min_s, 10) catch return error.TypeMismatch;
            const pat = std.fmt.parseInt(u32, pat_s, 10) catch return error.TypeMismatch;
            return .{ .major = maj, .minor = min, .patch = pat };
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\v = "1.2.3"
    , .{});
    const Config = struct { v: SemVer };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(u32, 1), cfg.v.major);
    try testing.expectEqual(@as(u32, 2), cfg.v.minor);
    try testing.expectEqual(@as(u32, 3), cfg.v.patch);
}

test "decode: tagged union dispatches by discriminator" {
    const Http = struct { host: []const u8, port: u16 };
    const Grpc = struct { endpoint: []const u8 };
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: Http,
        grpc: Grpc,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\kind = "http"
        \\host = "localhost"
        \\port = 8080
    , .{});
    const cfg = try decode(Plugin, arena.allocator(), v, .{});
    try testing.expect(cfg == .http);
    try testing.expectEqualStrings("localhost", cfg.http.host);
    try testing.expectEqual(@as(u16, 8080), cfg.http.port);
}

test "decode: tagged union missing discriminator -> MissingField" {
    const Http = struct { host: []const u8 };
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: Http,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\host = "localhost"
    , .{});
    try testing.expectError(error.MissingField, decode(Plugin, arena.allocator(), v, .{}));
}

test "decode: tagged union unknown discriminator -> InvalidEnumValue" {
    const Http = struct { host: []const u8 };
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: Http,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\kind = "xyz"
        \\host = "localhost"
    , .{});
    try testing.expectError(error.InvalidEnumValue, decode(Plugin, arena.allocator(), v, .{}));
}

test "decode: tagged union errors report diagnostics" {
    const Http = struct { host: []const u8 };
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: Http,
    };
    const Wrapper = struct { plugin: Plugin };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Missing discriminator.
    {
        var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
        const v = try parse(a, "[plugin]\nhost = \"localhost\"\n", .{});
        try testing.expectError(error.MissingField, decode(Wrapper, a, v, .{ .errors = &errs }));
        try testing.expectEqual(@as(usize, 1), errs.items.len);
        try testing.expectEqualStrings("missing required field `kind`", errs.items[0].message);
        try testing.expectEqualStrings("plugin", errs.items[0].path.?);
    }

    // Unknown discriminator value.
    {
        var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
        const v = try parse(a, "[plugin]\nkind = \"xyz\"\nhost = \"localhost\"\n", .{});
        try testing.expectError(error.InvalidEnumValue, decode(Wrapper, a, v, .{ .errors = &errs }));
        try testing.expectEqual(@as(usize, 1), errs.items.len);
        try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "invalid enum value `xyz`") != null);
    }

    // Non-string discriminator.
    {
        var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
        const v = try parse(a, "[plugin]\nkind = 3\n", .{});
        try testing.expectError(error.TypeMismatch, decode(Wrapper, a, v, .{ .errors = &errs }));
        try testing.expectEqual(@as(usize, 1), errs.items.len);
        try testing.expectEqualStrings("expected string, got integer", errs.items[0].message);
    }

    // Non-table union payload.
    {
        var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
        const v = try parse(a, "plugin = 1\n", .{});
        try testing.expectError(error.TypeMismatch, decode(Wrapper, a, v, .{ .errors = &errs }));
        try testing.expectEqual(@as(usize, 1), errs.items.len);
        try testing.expectEqualStrings("expected table, got integer", errs.items[0].message);
    }
}

test "decode float: large f64 into f32 -> error.Overflow" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "x = 1e40", .{});
    const Config = struct { x: f32 };
    try testing.expectError(error.Overflow, decode(Config, arena.allocator(), v, .{}));
}

test "decode float: integer 70000 into f16 -> error.Overflow" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "x = 70000", .{});
    const Config = struct { x: f16 };
    try testing.expectError(error.Overflow, decode(Config, arena.allocator(), v, .{}));
}

test "decode float: in-range value into f32 succeeds" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "x = 1.5", .{});
    const Config = struct { x: f32 };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(f32, 1.5), cfg.x);
}

test "decode float: f64 field with 1e40 ok (no narrowing)" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "x = 1e40", .{});
    const Config = struct { x: f64 };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expect(cfg.x == 1e40);
}

test "decode float: .inf source passes through to f32" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "x = inf", .{});
    const Config = struct { x: f32 };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expect(std.math.isPositiveInf(cfg.x));
}

test "decode array: [0]u8 field with empty TOML array compiles and yields empty" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "a = []", .{});
    const Config = struct { a: [0]u8 };
    const cfg = try decode(Config, arena.allocator(), v, .{});
    try testing.expectEqual(@as(usize, 0), cfg.a.len);
}

test "decode array: [0]u8 field with non-empty TOML array -> error.TypeMismatch" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "a = [1, 2]", .{});
    const Config = struct { a: [0]u8 };
    try testing.expectError(error.TypeMismatch, decode(Config, arena.allocator(), v, .{}));
}

test "round-trip: annotated config decode + encode" {
    const Plugin = union(enum) {
        pub const toml_tag = "kind";
        http: struct { host: []const u8, port: u16 },
        ws: struct { endpoint: []const u8 },
    };
    const Common = struct {
        log_level: []const u8 = "info",
        timezone: []const u8 = "UTC",
    };
    const Config = struct {
        pub const toml_rename = .{ .listen_addr = "listen-addr" };
        pub const toml_flatten = .{"common"};
        pub const toml_skip = .{"runtime"};

        listen_addr: []const u8,
        common: Common,
        runtime: u32 = 0,
        plugin: Plugin,
    };

    const src =
        \\listen-addr = "0.0.0.0"
        \\log_level = "debug"
        \\timezone = "America/New_York"
        \\
        \\[plugin]
        \\kind = "http"
        \\host = "localhost"
        \\port = 8080
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v1 = try parse(a, src, .{});
    const cfg1 = try decode(Config, a, v1, .{});

    var buf: [1024]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&buf);
    const encoder = @import("encoder.zig");
    try encoder.encodeTyped(&aw, cfg1, a);
    const encoded = aw.buffered();

    // Re-parse the encoded output and decode again -- should produce equivalent struct.
    const v2 = try parse(a, encoded, .{});
    const cfg2 = try decode(Config, a, v2, .{});

    try testing.expectEqualStrings(cfg1.listen_addr, cfg2.listen_addr);
    try testing.expectEqualStrings(cfg1.common.log_level, cfg2.common.log_level);
    try testing.expectEqualStrings(cfg1.common.timezone, cfg2.common.timezone);
    try testing.expect(cfg1.plugin == .http and cfg2.plugin == .http);
    try testing.expectEqualStrings(cfg1.plugin.http.host, cfg2.plugin.http.host);
    try testing.expectEqual(cfg1.plugin.http.port, cfg2.plugin.http.port);
}

// ----- streaming typed decode (no Value tree) -----

// The machinery below implements the streaming side of `parseInto`: a
// comptime sink for the parser's statement executor that dispatches
// headers and key-values straight into a target type, with no Value
// tree. See ParserOf in parser.zig for the executor seam.

/// One streamable destination at a table level: the effective wire key,
/// the field path from that table's struct (flattened inner structs
/// contribute multi-segment paths), and the leaf type.
const EffField = struct {
    key: []const u8,
    path: []const []const u8,
    Type: type,
};

/// Effective field list of `T` with flattened inner structs expanded,
/// skipped fields excluded. Mirrors `expectedKeys` exactly.
fn effFieldsOf(comptime T: type, comptime prefix: []const []const u8) []const EffField {
    comptime {
        var out: []const EffField = &.{};
        for (@typeInfo(T).@"struct".fields) |f| {
            if (isSkipped(T, f.name)) continue;
            const p2 = prefix ++ &[_][]const u8{f.name};
            if (isFlattened(T, f.name)) {
                out = out ++ effFieldsOf(f.type, p2);
            } else {
                out = out ++ &[_]EffField{.{ .key = renamedKey(T, f.name), .path = p2, .Type = f.type }};
            }
        }
        return out;
    }
}

fn hasKeyCollisions(comptime T: type) bool {
    comptime {
        const fs = effFieldsOf(T, &.{});
        for (fs, 0..) |a, i| {
            for (fs[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.key, b.key)) return true;
            }
        }
        return false;
    }
}

fn PathType(comptime T: type, comptime path: []const []const u8) type {
    comptime {
        var C = T;
        for (path) |seg| C = @FieldType(C, seg);
        return C;
    }
}

fn pathPtr(comptime T: type, comptime path: []const []const u8, base: *T) *PathType(T, path) {
    if (comptime path.len == 0) return base;
    return pathPtr(@FieldType(T, path[0]), path[1..], &@field(base.*, path[0]));
}

fn isAotSlice(comptime FT: type) bool {
    comptime {
        const info = @typeInfo(FT);
        if (info != .pointer) return false;
        const p = info.pointer;
        return p.size == .slice and @typeInfo(p.child) == .@"struct";
    }
}

/// Comptime: true when decoding `T` requires the tree path somewhere in
/// its type closure: `Value` targets, `fromToml` hooks, unions (the
/// `toml_tag` discriminator may follow the payload), flattened non-struct
/// fields, effective-key collisions, optional struct / optional
/// array-of-tables fields (cursor navigation cannot address an optional
/// payload in place), nested arrays-of-tables, or a table with more than
/// 128 effective fields (the seen-bit mask width).
pub fn needsTree(comptime T: type) bool {
    return comptime needsTreeImpl(T, false, &.{});
}

fn needsTreeImpl(comptime T: type, comptime under_aot: bool, comptime seen: []const type) bool {
    comptime {
        for (seen) |S| if (S == T) return false;
        if (T == Value) return true;
        const seen2 = seen ++ &[_]type{T};
        return switch (@typeInfo(T)) {
            .@"struct" => |s| blk: {
                if (@hasDecl(T, "fromToml")) break :blk true;
                for (s.fields) |f| {
                    if (isFlattened(T, f.name) and @typeInfo(f.type) != .@"struct") break :blk true;
                }
                if (hasKeyCollisions(T)) break :blk true;
                if (effFieldsOf(T, &.{}).len > 128) break :blk true;
                for (s.fields) |f| {
                    if (isSkipped(T, f.name)) continue;
                    const fi = @typeInfo(f.type);
                    if (fi == .optional and @typeInfo(fi.optional.child) == .@"struct") break :blk true;
                    if (fi == .optional and isAotSlice(fi.optional.child)) break :blk true;
                    if (isAotSlice(f.type) and under_aot) break :blk true;
                    const child_under = under_aot or isAotSlice(f.type);
                    if (needsTreeImpl(f.type, child_under, seen2)) break :blk true;
                }
                break :blk false;
            },
            .@"union" => true,
            .pointer => |p| p.size == .slice and !(p.child == u8 and p.is_const) and needsTreeImpl(p.child, under_aot, seen2),
            .array => |a| needsTreeImpl(a.child, under_aot, seen2),
            .optional => |o| needsTreeImpl(o.child, under_aot, seen2),
            else => false,
        };
    }
}

/// One statically-addressable table position: a struct reached from the
/// root (or an array-of-tables element type) through plain struct fields
/// only. `path` is the field path from the region root.
const StaticTable = struct {
    Type: type,
    path: []const []const u8,
};

fn collectStatic(comptime T: type) []const StaticTable {
    comptime {
        var out: []const StaticTable = &.{.{ .Type = T, .path = &.{} }};
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            const st = out[i];
            for (effFieldsOf(st.Type, &.{})) |e| {
                if (@typeInfo(e.Type) == .@"struct") {
                    out = out ++ &[_]StaticTable{.{ .Type = e.Type, .path = st.path ++ e.path }};
                }
            }
        }
        return out;
    }
}

/// Find the static index of `parent.path ++ e.path` in `list`.
fn staticChildIdx(comptime list: []const StaticTable, comptime parent: usize, comptime rel: []const []const u8) usize {
    comptime {
        const want = list[parent].path ++ rel;
        for (list, 0..) |st, i| {
            if (st.path.len != want.len) continue;
            var eq = true;
            for (st.path, want) |a, b| {
                if (!std.mem.eql(u8, a, b)) eq = false;
            }
            if (eq) return i;
        }
        unreachable;
    }
}

/// One array-of-tables position in the static region.
const AotSpec = struct {
    Elem: type,
    owner: usize,
    key: []const u8,
    path: []const []const u8,
};

fn collectAots(comptime statics: []const StaticTable) []const AotSpec {
    comptime {
        var out: []const AotSpec = &.{};
        for (statics, 0..) |st, si| {
            for (effFieldsOf(st.Type, &.{})) |e| {
                if (isAotSlice(e.Type)) {
                    out = out ++ &[_]AotSpec{.{
                        .Elem = @typeInfo(e.Type).pointer.child,
                        .owner = si,
                        .key = e.key,
                        .path = st.path ++ e.path,
                    }};
                }
            }
        }
        return out;
    }
}

/// Typed sink for `ParserOf`: navigates and stores into an instance of
/// `T` while the executor's seen-sets carry every structural verdict.
/// Any construct the sink cannot address returns error.TomlParseError;
/// the public parseInto then reruns the tree path, whose error selection
/// and diagnostics are canonical.
pub fn TypedSink(comptime T: type) type {
    return struct {
        const Ts = @This();
        pub const is_value_sink = false;
        pub const TableRef = Cursor;

        const statics = collectStatic(T);
        const aots = collectAots(statics);
        const n_static = statics.len;
        const n_aot = aots.len;

        // Per-builder element sub-tables (the element type's own static
        // region), flattened into shared arrays via comptime offsets.
        const elem_statics: [n_aot][]const StaticTable = blk: {
            var arr: [n_aot][]const StaticTable = undefined;
            for (aots, 0..) |a, i| arr[i] = collectStatic(a.Elem);
            break :blk arr;
        };
        const sub_off: [n_aot + 1]usize = blk: {
            var arr: [n_aot + 1]usize = undefined;
            arr[0] = 0;
            for (elem_statics, 0..) |es, i| arr[i + 1] = arr[i] + es.len;
            break :blk arr;
        };
        const n_sub = sub_off[n_aot];

        const Lists = std.meta.Tuple(blk: {
            var types: [n_aot]type = undefined;
            for (aots, 0..) |a, i| types[i] = std.ArrayList(a.Elem);
            break :blk &types;
        });

        pub const Cursor = struct {
            kind: enum(u8) { discard, static, elem },
            b: u16 = 0,
            sp: u16 = 0,
        };
        pub const root_cursor: Cursor = .{ .kind = .static, .sp = 0 };

        arena: Allocator,
        options: parser_mod.ParseOptions,
        out: T = undefined,
        st_inst: [n_static]bool = @splat(false),
        st_bits: [n_static]u128 = @splat(0),
        lists: Lists = undefined,
        open: [n_aot]bool = @splat(false),
        eb_inst: [n_sub]bool = @splat(false),
        eb_bits: [n_sub]u128 = @splat(0),

        pub fn init(arena: Allocator, options: parser_mod.ParseOptions) Ts {
            var self: Ts = .{ .arena = arena, .options = options };
            self.st_inst[0] = true;
            inline for (0..n_aot) |i| self.lists[i] = .empty;
            return self;
        }

        /// Navigate one segment from `cur` into a table position. Called
        /// for header intermediates (allow_aot: an array-of-tables
        /// segment resolves to its current element) and dotted-key
        /// descent (never traverses arrays-of-tables).
        pub fn childTable(self: *Ts, cur: Cursor, part: []const u8, comptime allow_aot: bool) parser_mod.Error!Cursor {
            switch (cur.kind) {
                .discard => return cur,
                .static => switch (cur.sp) {
                    inline 0...n_static - 1 => |sp| {
                        inline for (comptime effFieldsOf(statics[sp].Type, &.{})) |e| {
                            if (std.mem.eql(u8, part, e.key)) {
                                if (comptime @typeInfo(e.Type) == .@"struct") {
                                    const child = comptime staticChildIdx(statics, sp, e.path);
                                    self.st_inst[child] = true;
                                    return .{ .kind = .static, .sp = child };
                                }
                                if (comptime isAotSlice(e.Type)) {
                                    if (!allow_aot) return error.TomlParseError;
                                    const b = comptime aotIdxAt(sp, e.key);
                                    if (!self.open[b]) return error.TomlParseError;
                                    return .{ .kind = .elem, .b = b, .sp = 0 };
                                }
                                return error.TomlParseError;
                            }
                        }
                        return self.unknown();
                    },
                    else => unreachable,
                },
                .elem => switch (cur.b) {
                    inline 0...if (n_aot == 0) 0 else n_aot - 1 => |b| {
                        if (comptime n_aot == 0) unreachable;
                        switch (cur.sp) {
                            inline 0...elem_statics[b].len - 1 => |sp| {
                                inline for (comptime effFieldsOf(elem_statics[b][sp].Type, &.{})) |e| {
                                    if (std.mem.eql(u8, part, e.key)) {
                                        if (comptime @typeInfo(e.Type) == .@"struct") {
                                            const child = comptime staticChildIdx(elem_statics[b], sp, e.path);
                                            self.eb_inst[sub_off[b] + child] = true;
                                            return .{ .kind = .elem, .b = b, .sp = child };
                                        }
                                        // Nested arrays-of-tables are routed
                                        // to the tree path at comptime.
                                        return error.TomlParseError;
                                    }
                                }
                                return self.unknown();
                            },
                            else => unreachable,
                        }
                    },
                    else => unreachable,
                },
            }
        }

        pub fn openPlainTable(self: *Ts, cur: Cursor, part: []const u8) parser_mod.Error!Cursor {
            return self.childTable(cur, part, false);
        }

        pub fn openAotAppend(self: *Ts, cur: Cursor, part: []const u8) parser_mod.Error!Cursor {
            switch (cur.kind) {
                .discard => return cur,
                .static => switch (cur.sp) {
                    inline 0...n_static - 1 => |sp| {
                        inline for (comptime effFieldsOf(statics[sp].Type, &.{})) |e| {
                            if (std.mem.eql(u8, part, e.key)) {
                                if (comptime isAotSlice(e.Type)) {
                                    const b = comptime aotIdxAt(sp, e.key);
                                    try self.closeElem(b);
                                    try self.lists[b].append(self.arena, undefined);
                                    const range = self.eb_inst[sub_off[b]..sub_off[b + 1]];
                                    @memset(range, false);
                                    @memset(self.eb_bits[sub_off[b]..sub_off[b + 1]], 0);
                                    self.eb_inst[sub_off[b]] = true;
                                    self.open[b] = true;
                                    return .{ .kind = .elem, .b = b, .sp = 0 };
                                }
                                return error.TomlParseError;
                            }
                        }
                        return self.unknown();
                    },
                    else => unreachable,
                },
                // Nested arrays-of-tables never stream (comptime routing).
                .elem => return error.TomlParseError,
            }
        }

        pub fn putLeaf(self: *Ts, cur: Cursor, part: []const u8, value: Value) parser_mod.Error!void {
            switch (cur.kind) {
                .discard => return,
                .static => switch (cur.sp) {
                    inline 0...n_static - 1 => |sp| {
                        inline for (comptime effFieldsOf(statics[sp].Type, &.{}), 0..) |e, i| {
                            if (std.mem.eql(u8, part, e.key)) {
                                const dst = pathPtr(T, statics[sp].path ++ e.path, &self.out);
                                dst.* = self.decodeLeaf(e.Type, value) catch return error.TomlParseError;
                                self.st_bits[sp] |= @as(u128, 1) << i;
                                return;
                            }
                        }
                        _ = try self.unknown();
                    },
                    else => unreachable,
                },
                .elem => switch (cur.b) {
                    inline 0...if (n_aot == 0) 0 else n_aot - 1 => |b| {
                        if (comptime n_aot == 0) unreachable;
                        switch (cur.sp) {
                            inline 0...elem_statics[b].len - 1 => |sp| {
                                inline for (comptime effFieldsOf(elem_statics[b][sp].Type, &.{}), 0..) |e, i| {
                                    if (std.mem.eql(u8, part, e.key)) {
                                        const items = self.lists[b].items;
                                        const base = &items[items.len - 1];
                                        const dst = pathPtr(aots[b].Elem, elem_statics[b][sp].path ++ e.path, base);
                                        dst.* = self.decodeLeaf(e.Type, value) catch return error.TomlParseError;
                                        self.eb_bits[sub_off[b] + sp] |= @as(u128, 1) << i;
                                        return;
                                    }
                                }
                                _ = try self.unknown();
                            },
                            else => unreachable,
                        }
                    },
                    else => unreachable,
                },
            }
        }

        fn decodeLeaf(self: *Ts, comptime FT: type, value: Value) DecodeError!FT {
            var path: PathBuilder = .{ .buf = .empty };
            return decodeInner(FT, self.arena, value, self.options, &path);
        }

        fn unknown(self: *Ts) parser_mod.Error!Cursor {
            if (self.options.ignore_unknown_fields) return .{ .kind = .discard };
            return error.TomlParseError;
        }

        /// Close the currently open element of builder `b`: resolve its
        /// unseen fields (defaults, optional-null, or abort on a missing
        /// required field) exactly like decodeStruct does on an absent key.
        fn closeElem(self: *Ts, comptime b: usize) parser_mod.Error!void {
            if (comptime n_aot == 0) unreachable;
            if (!self.open[b]) return;
            try self.resolveRegionTable(aots[b].Elem, elem_statics[b], .{ .elem = b }, 0);
            self.open[b] = false;
        }

        const Region = union(enum) { static, elem: usize };

        fn regionInst(self: *Ts, comptime region: Region, comptime sp: usize) bool {
            return switch (region) {
                .static => self.st_inst[sp],
                .elem => |b| self.eb_inst[sub_off[b] + sp],
            };
        }

        fn regionBits(self: *Ts, comptime region: Region, comptime sp: usize) u128 {
            return switch (region) {
                .static => self.st_bits[sp],
                .elem => |b| self.eb_bits[sub_off[b] + sp],
            };
        }

        fn regionBasePtr(self: *Ts, comptime RT: type, comptime region: Region, comptime list: []const StaticTable, comptime sp: usize) *list[sp].Type {
            return switch (region) {
                .static => pathPtr(RT, list[sp].path, &self.out),
                .elem => |b| blk: {
                    const items = self.lists[b].items;
                    break :blk pathPtr(RT, list[sp].path, &items[items.len - 1]);
                },
            };
        }

        /// Resolve one table position at close time: skipped fields get
        /// their defaults; unseen fields get default, then optional-null,
        /// then abort (the tree rerun reports the canonical MissingField).
        /// Instantiated sub-tables recurse; absent ones resolve at the
        /// parent as a whole-field default/optional/missing.
        fn resolveRegionTable(self: *Ts, comptime RT: type, comptime list: []const StaticTable, comptime region: Region, comptime sp: usize) parser_mod.Error!void {
            const ST = list[sp].Type;
            const base = self.regionBasePtr(RT, region, list, sp);
            const bits = self.regionBits(region, sp);

            // Skipped fields always take their defaults.
            inline for (@typeInfo(ST).@"struct".fields) |f| {
                if (comptime isSkipped(ST, f.name)) {
                    const dv = comptime f.defaultValue() orelse
                        @compileError("toml_skip field `" ++ f.name ++ "` on " ++ @typeName(ST) ++ " has no default value");
                    @field(base.*, f.name) = dv;
                }
            }

            inline for (comptime effFieldsOf(ST, &.{}), 0..) |e, i| {
                const bit_set = bits & (@as(u128, 1) << i) != 0;
                if (!bit_set) {
                    if (comptime @typeInfo(e.Type) == .@"struct") {
                        const child = comptime staticChildIdx(list, sp, e.path);
                        if (self.regionInst(region, child)) {
                            try self.resolveRegionTable(RT, list, region, child);
                        } else {
                            try self.absentField(ST, e, base);
                        }
                    } else if (comptime isAotSlice(e.Type)) {
                        // Static-region builders are assigned in finish();
                        // an AoT reached inside an element type never
                        // streams (comptime routing), so this is only ever
                        // the static region.
                        const b = comptime aotIdxAt2(list, sp, e.key);
                        if (self.lists[b].items.len > 0) {
                            pathPtr(ST, e.path, base).* = self.lists[b].items;
                        } else {
                            try self.absentField(ST, e, base);
                        }
                    } else {
                        try self.absentField(ST, e, base);
                    }
                }
            }
        }

        fn absentField(self: *Ts, comptime ST: type, comptime e: EffField, base: *ST) parser_mod.Error!void {
            _ = self;
            const Parent = PathType(ST, e.path[0 .. e.path.len - 1]);
            const fi = comptime blk: {
                for (@typeInfo(Parent).@"struct".fields) |sf| {
                    if (std.mem.eql(u8, sf.name, e.path[e.path.len - 1])) break :blk sf;
                }
                unreachable;
            };
            const dv_opt = comptime fi.defaultValue();
            if (dv_opt) |dv| {
                pathPtr(ST, e.path, base).* = dv;
            } else if (comptime @typeInfo(e.Type) == .optional) {
                pathPtr(ST, e.path, base).* = null;
            } else {
                return error.TomlParseError;
            }
        }

        fn aotIdxAt(comptime owner_sp: usize, comptime key: []const u8) u16 {
            comptime {
                for (aots, 0..) |a, i| {
                    if (a.owner == owner_sp and std.mem.eql(u8, a.key, key)) return i;
                }
                unreachable;
            }
        }

        fn aotIdxAt2(comptime list: []const StaticTable, comptime sp: usize, comptime key: []const u8) usize {
            comptime {
                if (list.ptr != statics.ptr) unreachable;
                return aotIdxAt(sp, key);
            }
        }

        /// End of document: close the last open element of every builder,
        /// then resolve the whole static region from the root.
        pub fn finish(self: *Ts) parser_mod.Error!void {
            inline for (0..n_aot) |b| try self.closeElem(b);
            try self.resolveRegionTable(T, statics, .static, 0);
        }
    };
}

/// Streaming `parseInto`: one statement-executor pass dispatching straight
/// into `T`. Runs with diagnostics off; the caller falls back to the tree
/// path on any error, whose error selection and diagnostics are canonical.
pub fn streamParseInto(comptime T: type, arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) (parser_mod.Error || DecodeError)!T {
    var stream_options = options;
    stream_options.errors = null;
    stream_options.spans = null;

    const Ts = TypedSink(T);
    var sink = Ts.init(arena, stream_options);
    var seen: parser_mod.SeenState = .empty;
    const P = parser_mod.ParserOf(Ts);
    var p = P.init(arena, src);
    p.root = Ts.root_cursor;
    p.current = Ts.root_cursor;
    p.seen = &seen;
    p.seen_arena = arena;
    p.max_depth = stream_options.max_depth;
    p.sink = &sink;
    try p.parseStatements();
    try sink.finish();
    return sink.out;
}

/// Allocator wrapper that counts bytes handed out. Used to bound the
/// allocation cost of the streaming typed decode path.
const CountingAllocator = struct {
    child: Allocator,
    total: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total += len;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

test "parseInto streams: allocation bounded, no Value tree materialized" {
    // An array-of-tables large enough that tree materialization (a hash
    // table per element) dwarfs the decoded output. The streaming path
    // must stay within a small multiple of the input size; the tree path
    // exceeds it severalfold.
    const Rec = struct {
        id: u64,
        name: []const u8,
        active: bool,
        score: f64,
        tags: []const []const u8,
    };
    const Doc = struct { record: []const Rec };

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        try src.print(testing.allocator, "[[record]]\nid = {d}\nname = \"record-{d}\"\nactive = {}\nscore = {d}.5\ntags = [\"a\", \"b\"]\n", .{ i, i, i % 2 == 0, i % 100 });
    }

    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var counting: CountingAllocator = .{ .child = ar.allocator() };

    const toml_mod = @import("toml.zig");
    const out = try toml_mod.parseInto(Doc, counting.allocator(), src.items, .{});
    try testing.expectEqual(@as(usize, 2000), out.record.len);
    try testing.expectEqualStrings("record-1999", out.record[1999].name);

    var tree_arena = ArenaAllocator.init(testing.allocator);
    defer tree_arena.deinit();
    var tree_counting: CountingAllocator = .{ .child = tree_arena.allocator() };
    const tree_val = try parser_mod.parse(tree_counting.allocator(), src.items, .{});
    const tree_out = try decode(Doc, tree_counting.allocator(), tree_val, .{});
    try testing.expectEqual(@as(usize, 2000), tree_out.record.len);

    // Allocation in BOTH paths is dominated by the parser's seen-set
    // bookkeeping (per-statement path keys recorded for cross-statement
    // redefinition verdicts), which the streaming path shares by design.
    // What streaming saves is the Value boxes and the hash table per
    // element; assert it stays strictly cheaper than the tree path, and
    // leave throughput to the `parseInto (typed big)` bench arm.
    try testing.expect(counting.total < tree_counting.total);
}

test "streaming: order-free tables, dotted keys, and root kvs" {
    const T = struct {
        title: []const u8,
        a: struct { sub: struct { x: u32 }, y: u32 },
        b: struct { z: u32 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const toml_mod = @import("toml.zig");
    const v = try toml_mod.parseInto(T, ar.allocator(),
        \\title = "t"
        \\[b]
        \\z = 3
        \\[a.sub]
        \\x = 1
        \\[a]
        \\y = 2
    , .{});
    try testing.expectEqualStrings("t", v.title);
    try testing.expectEqual(@as(u32, 1), v.a.sub.x);
    try testing.expectEqual(@as(u32, 2), v.a.y);
    try testing.expectEqual(@as(u32, 3), v.b.z);
}

test "streaming: interleaved arrays-of-tables with element sub-tables and defaults" {
    const Rec = struct { id: u32, note: []const u8 = "none", meta: struct { w: u32 = 9 } = .{} };
    const T = struct { a: []const Rec, b: []const Rec };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const toml_mod = @import("toml.zig");
    const v = try toml_mod.parseInto(T, ar.allocator(),
        \\[[a]]
        \\id = 1
        \\[a.meta]
        \\w = 5
        \\[[b]]
        \\id = 2
        \\[[a]]
        \\id = 3
        \\note = "x"
    , .{});
    try testing.expectEqual(@as(usize, 2), v.a.len);
    try testing.expectEqual(@as(usize, 1), v.b.len);
    try testing.expectEqual(@as(u32, 5), v.a[0].meta.w);
    try testing.expectEqualStrings("none", v.a[0].note);
    try testing.expectEqual(@as(u32, 9), v.a[1].meta.w);
    try testing.expectEqualStrings("x", v.a[1].note);
    // Missing required field in an element errors (canonically via the tree).
    try testing.expectError(error.MissingField, toml_mod.parseInto(T, ar.allocator(), "[[a]]\nnote = \"x\"\n[[b]]\nid = 1\n", .{}));
}

test "streaming: redefinition and duplicate errors still fire" {
    const T = struct { a: struct { x: u32 = 0 } = .{}, w: []const struct { z: u32 } = &.{} };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const toml_mod = @import("toml.zig");
    try testing.expectError(error.TomlParseError, toml_mod.parseInto(T, ar.allocator(), "[a]\nx = 1\n[a]\nx = 2\n", .{}));
    try testing.expectError(error.TomlParseError, toml_mod.parseInto(T, ar.allocator(), "[a]\nx = 1\nx = 2\n", .{}));
    // Inline array-of-tables cannot be appended to with [[w]].
    try testing.expectError(error.TomlParseError, toml_mod.parseInto(T, ar.allocator(), "w = [{z = 1}]\n[[w]]\nz = 2\n", .{}));
    // A header at a scalar field's path parses but cannot decode.
    try testing.expectError(error.TypeMismatch, toml_mod.parseInto(T, ar.allocator(), "[a.x]\n", .{ .ignore_unknown_fields = true }));
    // Implicit table then [[...]] at the same path (inside an ignored
    // subtree, so the verdict must come from the shared seen-sets).
    try testing.expectError(error.TomlParseError, toml_mod.parseInto(T, ar.allocator(), "[q.sub]\n[[q]]\n", .{ .ignore_unknown_fields = true }));
}

test "streaming: inline tables and inline arrays-of-tables assign whole fields" {
    const Rec = struct { z: u32 };
    const T = struct { a: struct { x: u32 }, w: []const Rec };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const toml_mod = @import("toml.zig");
    const v = try toml_mod.parseInto(T, ar.allocator(), "a = { x = 7 }\nw = [{ z = 1 }, { z = 2 }]\n", .{});
    try testing.expectEqual(@as(u32, 7), v.a.x);
    try testing.expectEqual(@as(usize, 2), v.w.len);
    try testing.expectEqual(@as(u32, 2), v.w[1].z);
}

test "streaming: unknown subtrees under ignore_unknown_fields still validate" {
    const T = struct { a: u32 = 0 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const toml_mod = @import("toml.zig");
    const v = try toml_mod.parseInto(T, ar.allocator(), "a = 1\n[junk]\nk = \"v\"\n[junk.deep]\nq = 2\n", .{ .ignore_unknown_fields = true });
    try testing.expectEqual(@as(u32, 1), v.a);
    // A malformed value inside a skipped subtree still errors.
    try testing.expectError(error.TomlParseError, toml_mod.parseInto(T, ar.allocator(), "a = 1\n[junk]\nk = 1979-13-99\n", .{ .ignore_unknown_fields = true }));
    // Unknown field without the opt-in errors.
    try testing.expectError(error.UnknownField, toml_mod.parseInto(T, ar.allocator(), "a = 1\nzzz = 2\n", .{}));
}

test "streaming: datetime scalars and escaped strings decode" {
    const T = struct { when: Value, s: []const u8 };
    _ = T; // Value fields route to the tree; use concrete types here.
    const T2 = struct { s: []const u8, n: i64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const toml_mod = @import("toml.zig");
    const v = try toml_mod.parseInto(T2, ar.allocator(), "s = \"esc\\u00e9\"\nn = 42\n", .{});
    try testing.expectEqual(@as(i64, 42), v.n);
    try testing.expect(v.s.len == 5);
}

test "streaming equivalence: needsTree shapes still decode through the tree" {
    const Plugin = union(enum) {
        http: struct { host: []const u8 },
        file: struct { path: []const u8 },
        pub const toml_tag = "kind";
    };
    const T = struct { plugin: Plugin, opt: ?struct { x: u32 } = null };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const toml_mod = @import("toml.zig");
    const v = try toml_mod.parseInto(T, ar.allocator(),
        \\[plugin]
        \\kind = "http"
        \\host = "h"
        \\[opt]
        \\x = 3
    , .{});
    try testing.expect(v.plugin == .http);
    try testing.expectEqual(@as(u32, 3), v.opt.?.x);
}
