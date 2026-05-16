//! Encoder for the toml-lang/toml-test conformance suite.
//!
//! Reads JSON in toml-test's tagged format on stdin, builds a `toml.Value`,
//! and writes the equivalent TOML on stdout. Exits 0 on success, 1 on any
//! error.

const std = @import("std");
const Io = std.Io;
const toml = @import("toml");

var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [256]u8 = undefined;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdin_reader = Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const src = try stdin_reader.interface.allocRemaining(arena, .unlimited);

    const json = std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch |err| {
        return reportFail(io, "json parse: {t}", .{err});
    };

    const value = jsonToToml(arena, json) catch |err| {
        return reportFail(io, "json -> toml: {t}", .{err});
    };

    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout_writer.interface;
    toml.encode(w, value) catch |err| {
        return reportFail(io, "encode: {t}", .{err});
    };
    try w.flush();
    return 0;
}

fn reportFail(io: Io, comptime fmt: []const u8, args: anytype) !u8 {
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const w = &stderr_writer.interface;
    try w.print(fmt ++ "\n", args);
    try w.flush();
    return 1;
}

const ConvertError = error{
    BadType,
    BadValue,
    OutOfMemory,
    InvalidNumber,
    Overflow,
};

fn jsonToToml(arena: std.mem.Allocator, j: std.json.Value) ConvertError!toml.Value {
    return switch (j) {
        .array => |a| try arrayToToml(arena, a),
        .object => |o| try objectToToml(arena, o),
        else => error.BadType,
    };
}

fn arrayToToml(arena: std.mem.Allocator, a: std.json.Array) ConvertError!toml.Value {
    var out: std.ArrayList(toml.Value) = .empty;
    try out.ensureTotalCapacityPrecise(arena, a.items.len);
    for (a.items) |item| {
        out.appendAssumeCapacity(try jsonToToml(arena, item));
    }
    return .{ .array = out };
}

fn objectToToml(arena: std.mem.Allocator, o: std.json.ObjectMap) ConvertError!toml.Value {
    // Tagged scalar form: exactly two fields, "type" and "value", both strings.
    if (o.count() == 2) {
        if (o.get("type")) |t_val| {
            if (o.get("value")) |v_val| {
                if (t_val == .string and v_val == .string) {
                    return scalarFromTag(arena, t_val.string, v_val.string);
                }
            }
        }
    }

    var tbl: std.array_hash_map.String(toml.Value) = .empty;
    try tbl.ensureTotalCapacity(arena, @intCast(o.count()));
    var it = o.iterator();
    while (it.next()) |entry| {
        const k = try arena.dupe(u8, entry.key_ptr.*);
        const v = try jsonToToml(arena, entry.value_ptr.*);
        tbl.putAssumeCapacityNoClobber(k, v);
    }
    return .{ .table = tbl };
}

fn scalarFromTag(arena: std.mem.Allocator, type_str: []const u8, value_str: []const u8) ConvertError!toml.Value {
    if (std.mem.eql(u8, type_str, "string")) {
        return .{ .string = try arena.dupe(u8, value_str) };
    }
    if (std.mem.eql(u8, type_str, "integer")) {
        const n = std.fmt.parseInt(i64, value_str, 10) catch return error.InvalidNumber;
        return .{ .integer = n };
    }
    if (std.mem.eql(u8, type_str, "float")) {
        return .{ .float = try parseFloat(value_str) };
    }
    if (std.mem.eql(u8, type_str, "bool")) {
        if (std.mem.eql(u8, value_str, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, value_str, "false")) return .{ .boolean = false };
        return error.BadValue;
    }
    if (std.mem.eql(u8, type_str, "datetime")) {
        const p = toml.DateTime.parse(value_str) catch return error.BadValue;
        if (p != .datetime) return error.BadValue;
        if (p.datetime.tz_offset_minutes == null) return error.BadValue;
        return .{ .datetime = p.datetime };
    }
    if (std.mem.eql(u8, type_str, "datetime-local")) {
        const p = toml.DateTime.parse(value_str) catch return error.BadValue;
        if (p != .datetime) return error.BadValue;
        if (p.datetime.tz_offset_minutes != null) return error.BadValue;
        return .{ .datetime = p.datetime };
    }
    if (std.mem.eql(u8, type_str, "date-local")) {
        const p = toml.DateTime.parse(value_str) catch return error.BadValue;
        if (p != .date) return error.BadValue;
        return .{ .date = p.date };
    }
    if (std.mem.eql(u8, type_str, "time-local")) {
        const p = toml.DateTime.parse(value_str) catch return error.BadValue;
        if (p != .time) return error.BadValue;
        return .{ .time = p.time };
    }
    return error.BadType;
}

fn parseFloat(s: []const u8) ConvertError!f64 {
    if (std.mem.eql(u8, s, "nan") or std.mem.eql(u8, s, "+nan")) return std.math.nan(f64);
    if (std.mem.eql(u8, s, "-nan")) return -std.math.nan(f64);
    if (std.mem.eql(u8, s, "inf") or std.mem.eql(u8, s, "+inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-inf")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, s) catch error.InvalidNumber;
}
