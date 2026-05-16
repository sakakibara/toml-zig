//! Edit a TOML document while preserving comments, whitespace, and key
//! ordering. The lossless document model emits byte-identical output for
//! unmodified input, and minimal-diff output when you do modify it.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const src =
        \\# Service configuration. Hand-edited; preserve formatting!
        \\title = "my-service"
        \\
        \\[server]
        \\host = "localhost"  # bind address
        \\port = 8080
        \\
    ;

    var doc = try toml.Document.parse(arena.allocator(), src, .{});

    // Read.
    std.debug.print("current port: {d}\n", .{doc.getT(u16, "server.port").?});

    // Edit existing — set is comptime-dispatched on the Zig type.
    try doc.set("server.port", @as(u16, 9999));
    try doc.set("server.tls", true);
    try doc.set("metrics.endpoint", "/metrics");

    // Escape hatch: splice in a literal TOML value when you have one.
    // try doc.setLiteral("server.tags", "[\"alpha\", \"beta\"]");

    // Emit. Comments and ordering are preserved.
    var aw: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);

    std.debug.print("--- updated ---\n{s}", .{aw.written()});
}
