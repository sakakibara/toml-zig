//! Track source positions for tooling: IDE features, custom validators,
//! rich error messages that point at the offending byte range.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const src =
        \\name = "my-service"
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[[users]]
        \\name = "alice"
        \\
        \\[[users]]
        \\name = "bob"
    ;

    var spans: toml.Spans = .empty;
    const v = try toml.parse(arena.allocator(), src, .{ .spans = &spans });

    // Validate that `port` is in range; if not, point at the offending span.
    // `locate` returns value + span in one lookup.
    const port_at = v.locate(spans, "server.port").?;
    const port = port_at.value.integer;
    if (port < 1024 or port > 65535) {
        const lc = port_at.span.lineCol(src);
        std.debug.print("error at line {d} col {d}: port {d} out of range\n", .{
            lc.line, lc.col, port,
        });
        std.debug.print("  bytes [{d}..{d}]: {s}\n", .{
            port_at.span.start, port_at.span.end, src[@intCast(port_at.span.start)..@intCast(port_at.span.end)],
        });
        return;
    }

    // Walk the second user.
    if (v.locate(spans, "users[1].name")) |loc| {
        const lc = loc.span.lineCol(src);
        std.debug.print("users[1].name = {s} at line {d}, col {d}\n", .{
            loc.value.string, lc.line, lc.col,
        });
    }
}
