//! Decode TOML directly into a Zig struct via comptime reflection.
//!
//! Field defaults satisfy missing-field cases. Optional fields become
//! `null` when absent. Unknown TOML keys cause `error.UnknownField`
//! unless `ParseOptions{ .ignore_unknown_fields = true }` is passed.

const std = @import("std");
const toml = @import("toml");

const LogLevel = enum { debug, info, warn, err };

const ServerConfig = struct {
    host: []const u8,
    port: u16 = 8080,
    tls: bool = false,
    cert_path: ?[]const u8,
};

const Config = struct {
    title: []const u8,
    log_level: LogLevel = .info,
    tags: []const []const u8,
    server: ServerConfig,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const src =
        \\title = "my-service"
        \\log_level = "warn"
        \\tags = ["http", "rpc", "cli"]
        \\
        \\[server]
        \\host = "0.0.0.0"
        \\port = 9000
        \\tls = true
    ;

    const cfg = try toml.parseInto(Config, arena.allocator(), src, .{});

    std.debug.print("title:     {s}\n", .{cfg.title});
    std.debug.print("level:     {s}\n", .{@tagName(cfg.log_level)});
    std.debug.print("tags:     ", .{});
    for (cfg.tags) |t| std.debug.print(" {s}", .{t});
    std.debug.print("\n", .{});
    std.debug.print("host:      {s}\n", .{cfg.server.host});
    std.debug.print("port:      {d}\n", .{cfg.server.port});
    std.debug.print("tls:       {}\n", .{cfg.server.tls});
    std.debug.print("cert_path: {?s}\n", .{cfg.server.cert_path});
}
