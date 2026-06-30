//! Decoder for the toml-lang/toml-test conformance suite.
//!
//! Reads TOML on stdin; on success writes the toml-test JSON description on
//! stdout and exits 0; on parse error writes the error on stderr and exits 1.

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

    var errs: std.ArrayList(toml.Diagnostic) = .empty;
    defer errs.deinit(arena);
    const value = toml.parse(arena, src, .{ .errors = &errs }) catch {
        var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buffer);
        const w = &stderr_writer.interface;
        if (errs.items.len > 0) {
            const e = errs.items[0];
            const lc = e.span.lineCol(src);
            try w.print("toml: line {d} col {d}: {s}\n", .{ lc.line, lc.col, e.message });
        } else {
            try w.writeAll("toml: parse failed\n");
        }
        try w.flush();
        return 1;
    };

    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try emit(w, value);
    try w.writeByte('\n');
    try w.flush();
    return 0;
}

fn emit(w: *Io.Writer, v: toml.Value) Io.Writer.Error!void {
    switch (v) {
        .table => |t| try emitTable(w, t),
        .array => |a| try emitArray(w, a),
        else => try emitScalar(w, v),
    }
}

fn emitTable(w: *Io.Writer, t: std.array_hash_map.String(toml.Value)) Io.Writer.Error!void {
    try w.writeByte('{');
    var it = t.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try emitJsonString(w, entry.key_ptr.*);
        try w.writeByte(':');
        try emit(w, entry.value_ptr.*);
    }
    try w.writeByte('}');
}

fn emitArray(w: *Io.Writer, a: std.ArrayList(toml.Value)) Io.Writer.Error!void {
    try w.writeByte('[');
    for (a.items, 0..) |item, i| {
        if (i != 0) try w.writeByte(',');
        try emit(w, item);
    }
    try w.writeByte(']');
}

fn emitScalar(w: *Io.Writer, v: toml.Value) Io.Writer.Error!void {
    try w.writeAll("{\"type\":\"");
    switch (v) {
        .string => try w.writeAll("string"),
        .integer => try w.writeAll("integer"),
        .float => try w.writeAll("float"),
        .boolean => try w.writeAll("bool"),
        .datetime => |dt| try w.writeAll(if (dt.tz_offset_minutes == null) "datetime-local" else "datetime"),
        .date => try w.writeAll("date-local"),
        .time => try w.writeAll("time-local"),
        .array, .table => unreachable,
    }
    try w.writeAll("\",\"value\":");
    switch (v) {
        .string => |s| try emitJsonString(w, s),
        .integer => |n| {
            try w.writeByte('"');
            try w.print("{d}", .{n});
            try w.writeByte('"');
        },
        .float => |f| try emitFloat(w, f),
        .boolean => |b| try w.writeAll(if (b) "\"true\"" else "\"false\""),
        .datetime => |dt| try emitDateTime(w, dt),
        .date => |d| try emitDate(w, d),
        .time => |t| try emitTime(w, t),
        .array, .table => unreachable,
    }
    try w.writeByte('}');
}

fn emitFloat(w: *Io.Writer, f: f64) Io.Writer.Error!void {
    try w.writeByte('"');
    if (std.math.isNan(f)) {
        try w.writeAll(if (std.math.signbit(f)) "-nan" else "nan");
    } else if (std.math.isInf(f)) {
        try w.writeAll(if (f < 0) "-inf" else "inf");
    } else {
        try w.print("{d}", .{f});
    }
    try w.writeByte('"');
}

fn emitDateTime(w: *Io.Writer, dt: toml.DateTime) Io.Writer.Error!void {
    try w.writeByte('"');
    try writeDate(w, dt.date);
    try w.writeByte('T');
    try writeTime(w, dt.time);
    if (dt.tz_offset_minutes) |off| {
        if (off == 0) {
            try w.writeByte('Z');
        } else {
            const abs: u16 = @intCast(@abs(@as(i32, off)));
            const sign: u8 = if (off < 0) '-' else '+';
            try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 });
        }
    }
    try w.writeByte('"');
}

fn emitDate(w: *Io.Writer, d: toml.Date) Io.Writer.Error!void {
    try w.writeByte('"');
    try writeDate(w, d);
    try w.writeByte('"');
}

fn emitTime(w: *Io.Writer, t: toml.Time) Io.Writer.Error!void {
    try w.writeByte('"');
    try writeTime(w, t);
    try w.writeByte('"');
}

fn writeDate(w: *Io.Writer, d: toml.Date) Io.Writer.Error!void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

fn writeTime(w: *Io.Writer, t: toml.Time) Io.Writer.Error!void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanos != 0) try w.print(".{d:0>9}", .{t.nanos});
}

fn emitJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (b < 0x20) {
                    try w.print("\\u{x:0>4}", .{b});
                } else {
                    try w.writeByte(b);
                }
            },
        }
        i += 1;
    }
    try w.writeByte('"');
}
