//! Parse a TOML document into a dynamic `Value` tree, read fields, and
//! emit it back. The simplest entry point.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const src =
        \\title = "TOML Example"
        \\edition = 2024
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\tls = true
        \\
        \\[[features]]
        \\name = "auth"
        \\enabled = true
        \\
        \\[[features]]
        \\name = "metrics"
        \\enabled = false
    ;

    const v = try toml.parse(arena.allocator(), src, .{});

    std.debug.print("title:  {s}\n", .{v.getT([]const u8, "title").?});
    std.debug.print("port:   {d}\n", .{v.getT(u16, "server.port").?});

    const features = v.get("features").?.array.items;
    for (features) |f| {
        std.debug.print("feature {s}: enabled={}\n", .{
            f.getT([]const u8, "name").?,
            f.getT(bool, "enabled").?,
        });
    }
}
