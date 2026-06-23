// Reader-backed streaming: EventReader, ValueStream, and materialize.
//
// Demonstrates the three streaming entry points over in-program multi-table
// buffers, using std.Io.Reader.fixed so no file I/O is needed:
//
//   (a) EventReader walking a multi-table stream, printing event kinds and
//       scalar values as they arrive.
//   (b) ValueStream iterating array-of-tables elements with a per-item arena
//       reset between them, printing one field per element.
//   (c) materialize: calling EventReader.materialize() at a table_header or
//       array_of_tables_header event to compose the whole unit into a Value
//       without stepping through its individual key/value events.

const std = @import("std");
const toml = @import("toml");

// Multi-table TOML document: root keys then two named sections.
const multi_table =
    \\version = 1
    \\
    \\[server]
    \\host = "localhost"
    \\port = 8080
    \\
    \\[client]
    \\host = "example.com"
    \\port = 443
;

// Array-of-tables document for the ValueStream demo.
const value_stream_src =
    \\[[record]]
    \\name = "alice"
    \\
    \\[[record]]
    \\name = "bob"
    \\
    \\[[record]]
    \\name = "carol"
    \\
    \\[[record]]
    \\name = "delta"
    \\
    \\[[record]]
    \\name = "epsilon"
;

// Array-of-tables document for the materialize demo.
const materialize_src =
    \\[[service]]
    \\name = "frontend"
    \\port = 8080
    \\
    \\[[service]]
    \\name = "backend"
    \\port = 9090
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try demoEventReader(gpa);
    try demoValueStream(gpa);
    try demoMaterialize(gpa);
}

// (a) EventReader: walk a multi-table stream event by event.
fn demoEventReader(gpa: std.mem.Allocator) !void {
    std.debug.print("--- EventReader: walk multi-table stream ---\n", .{});

    var r: std.Io.Reader = .fixed(multi_table);
    var er = toml.EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();

    while (try er.next()) |ev| {
        switch (ev.kind) {
            .end_of_input => {},
            .table_header => |path| std.debug.print("table_header: [{s}]  span=[{d},{d})\n", .{ path, ev.span.start, ev.span.end }),
            .key => |k| std.debug.print("  key: {s}\n", .{k}),
            .value_string => |s| std.debug.print("  value_string: {s}\n", .{s}),
            .value_integer => |n| std.debug.print("  value_integer: {d}\n", .{n}),
            .value_bool => |b| std.debug.print("  value_bool: {}\n", .{b}),
            .value_float => |f| std.debug.print("  value_float: {d}\n", .{f}),
            .array_begin => std.debug.print("  array_begin\n", .{}),
            .array_end => std.debug.print("  array_end\n", .{}),
            .inline_table_begin => std.debug.print("  inline_table_begin\n", .{}),
            .inline_table_end => std.debug.print("  inline_table_end\n", .{}),
            else => {},
        }
    }
    std.debug.print("\n", .{});
}

// (b) ValueStream: compose one Value per [[record]] element, resetting a
//     per-item arena between calls to bound memory to one element.
fn demoValueStream(gpa: std.mem.Allocator) !void {
    std.debug.print("--- ValueStream: per-element arena reset ---\n", .{});

    var r: std.Io.Reader = .fixed(value_stream_src);
    var vs = toml.ValueStream.fromReader(gpa, &r, .{}, .array_of_tables);
    defer vs.deinit();

    // A per-item arena: reset between elements to bound memory to one unit.
    var item_arena: std.heap.ArenaAllocator = .init(gpa);
    defer item_arena.deinit();

    var i: usize = 0;
    while (try vs.next(item_arena.allocator())) |v| {
        const name = v.getT([]const u8, "name") orelse "?";
        std.debug.print("record[{d}]: name={s}\n", .{ i, name });
        i += 1;
        _ = item_arena.reset(.retain_capacity);
    }
    std.debug.print("\n", .{});
}

// (c) materialize: at array_of_tables_header, compose the whole unit via
//     EventReader.materialize() without stepping through its key/value events.
fn demoMaterialize(gpa: std.mem.Allocator) !void {
    std.debug.print("--- materialize: compose at array_of_tables_header ---\n", .{});

    var r: std.Io.Reader = .fixed(materialize_src);
    var er = toml.EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();

    var item_arena: std.heap.ArenaAllocator = .init(gpa);
    defer item_arena.deinit();

    var svc_idx: usize = 0;
    while (try er.next()) |ev| {
        if (ev.kind != .array_of_tables_header) continue;

        // At array_of_tables_header: materialize() composes the whole unit and
        // advances the reader past it, so the next next() call sees the
        // following unit's header or end_of_input.
        const v = try er.materialize(item_arena.allocator());
        const name = v.getT([]const u8, "name") orelse "?";
        const port = v.getT(i64, "port") orelse 0;
        std.debug.print("service[{d}]: name={s} port={d}\n", .{ svc_idx, name, port });
        svc_idx += 1;
        _ = item_arena.reset(.retain_capacity);
    }
}
