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

/// Returns the effective TOML key for `field_name` on type `T`,
/// consulting `T.toml_rename` if present.
fn renamedKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!@hasDecl(T, "toml_rename")) return field_name;
    const renames = T.toml_rename;
    if (@hasField(@TypeOf(renames), field_name)) {
        return @field(renames, field_name);
    }
    return field_name;
}

/// Returns true if `field_name` on type `T` is listed in `T.toml_skip`.
fn isSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "toml_skip")) return false;
    const skip = T.toml_skip;
    inline for (skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Returns true if `field_name` on type `T` is listed in `T.toml_flatten`.
fn isFlattened(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "toml_flatten")) return false;
    const flat = T.toml_flatten;
    inline for (flat) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

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
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected date, got {s}", .{@tagName(value)});
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
            return error.TypeMismatch;
        }
        return value.date;
    }
    if (T == Time) {
        if (value != .time) {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected time, got {s}", .{@tagName(value)});
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
            return error.TypeMismatch;
        }
        return value.time;
    }
    if (T == DateTime) {
        if (value != .datetime) {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected datetime, got {s}", .{@tagName(value)});
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
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
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected boolean, got {s}", .{@tagName(value)});
            const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
            try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
        }
        return error.TypeMismatch;
    }
    return value.boolean;
}

fn decodeInt(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .integer) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected integer, got {s}", .{@tagName(value)});
            const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
            try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
        }
        return error.TypeMismatch;
    }
    if (std.math.cast(T, value.integer)) |v| return v;
    if (options.errors) |list| {
        const msg = try std.fmt.allocPrint(arena, "integer {d} out of range for {s}", .{ value.integer, @typeName(T) });
        const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
        try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
    }
    return error.Overflow;
}

fn decodeFloat(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        else => {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected float, got {s}", .{@tagName(value)});
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
            return error.TypeMismatch;
        },
    };
}

fn decodePointer(comptime T: type, comptime p: std.builtin.Type.Pointer, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (p.size != .slice) @compileError("toml decode: only slice pointers supported, got " ++ @typeName(T));
    if (p.child == u8 and p.is_const) {
        if (value != .string) {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected string, got {s}", .{@tagName(value)});
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
            return error.TypeMismatch;
        }
        return value.string;
    }
    if (value != .array) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected array, got {s}", .{@tagName(value)});
            const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
            try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
        }
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
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected array, got {s}", .{@tagName(value)});
            const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
            try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
        }
        return error.TypeMismatch;
    }
    if (value.array.items.len != a.len) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "array length mismatch: expected {d}, got {d}", .{ a.len, value.array.items.len });
            const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
            try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
        }
        return error.TypeMismatch;
    }
    var out: T = undefined;
    for (value.array.items, 0..) |item, i| {
        const prev = try path.pushIndex(arena, i);
        defer path.restore(prev);
        out[i] = try decodeInner(a.child, arena, item, options, path);
    }
    return out;
}

fn decodeOptional(comptime Child: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!?Child {
    return try decodeInner(Child, arena, value, options, path);
}

fn decodeStruct(comptime T: type, comptime s: std.builtin.Type.Struct, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .table) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected table, got {s}", .{@tagName(value)});
            const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
            try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
        }
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

            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "unknown field `{s}`", .{key});
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{
                    .line = 0,
                    .col = 0,
                    .message = msg,
                    .path = path_owned,
                    .suggestion = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null,
                });
            }
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
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "missing required field `{s}`", .{field.name});
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
            return error.MissingField;
        }
    }

    return out;
}

fn decodeTaggedUnion(comptime T: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .table) return error.TypeMismatch;
    const tbl = value.table;
    const tag_field = T.toml_tag;
    const tag_value = tbl.get(tag_field) orelse return error.MissingField;
    if (tag_value != .string) return error.TypeMismatch;

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
    return error.InvalidEnumValue;
}

fn decodeEnum(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    switch (value) {
        .string => |s| {
            if (std.meta.stringToEnum(T, s)) |v| return v;
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "invalid enum value `{s}` for {s}", .{ s, @typeName(T) });
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
            return error.InvalidEnumValue;
        },
        .integer => |n| {
            if (std.enums.fromInt(T, n)) |v| return v;
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "integer {d} is not a valid value of {s}", .{ n, @typeName(T) });
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
            return error.InvalidEnumValue;
        },
        else => {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected string or integer for enum {s}, got {s}", .{ @typeName(T), @tagName(value) });
                const path_owned: ?[]const u8 = if (path.slice().len > 0) try arena.dupe(u8, path.slice()) else null;
                try list.append(arena, .{ .line = 0, .col = 0, .message = msg, .path = path_owned });
            }
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
    try encoder.encodeTyped(Config, cfg1, &aw, a);
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
