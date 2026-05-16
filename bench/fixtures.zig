//! Static benchmark fixtures.

pub const small: []const u8 =
    \\[package]
    \\name = "example"
    \\version = "1.2.3"
    \\edition = "2024"
    \\authors = ["Alice <alice@example.com>", "Bob <bob@example.com>"]
    \\description = """
    \\A sample package manifest for benchmarking. Contains
    \\representative keys, nested tables, arrays of tables, dotted
    \\keys, basic/literal strings, integers of multiple radixes, and
    \\a couple of datetime values.
    \\"""
    \\license = "MIT OR Apache-2.0"
    \\repository = "https://github.com/example/example"
    \\keywords = ["editor", "text", "zig", "lua"]
    \\categories = ["text-editors"]
    \\readme = "README.md"
    \\rust-version = "1.80"
    \\
    \\[dependencies]
    \\serde = "1.0"
    \\tokio = { version = "1.34", features = ["rt", "macros"] }
    \\clap = { version = "4.5", default-features = false }
    \\log = "0.4"
    \\
    \\[dev-dependencies]
    \\criterion = "0.5"
    \\proptest = "1.4"
    \\
    \\[features]
    \\default = ["std", "network"]
    \\std = []
    \\network = ["reqwest"]
    \\
    \\[profile.release]
    \\opt-level = 3
    \\lto = true
    \\codegen-units = 1
    \\panic = "abort"
    \\strip = true
    \\
    \\[[bin]]
    \\name = "example-cli"
    \\path = "src/cli/main.rs"
    \\
    \\[[bin]]
    \\name = "example-daemon"
    \\path = "src/daemon/main.rs"
    \\
    \\[metadata]
    \\created = 2025-03-01T12:34:56Z
    \\updated = 2026-04-17
    \\hash = 0xDEADBEEF
;

pub const medium = blk: {
    @setEvalBranchQuota(200_000);
    var buf: []const u8 =
        \\version = 4
        \\
        \\
    ;
    var i: u32 = 0;
    while (i < 80) : (i += 1) {
        buf = buf ++ std.fmt.comptimePrint(
            \\[[package]]
            \\name = "crate-{d}"
            \\version = "0.{d}.0"
            \\source = "registry+https://github.com/rust-lang/crates.io-index"
            \\checksum = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
            \\dependencies = [
            \\    "dep-a {d}.0.0",
            \\    "dep-b {d}.0.0",
            \\    "dep-c {d}.0.0",
            \\]
            \\
            \\
        , .{ i, i, i, i, i });
    }
    break :blk buf;
};

pub const large = blk: {
    @setEvalBranchQuota(2_000_000);
    var buf: []const u8 = "";
    var i: u32 = 0;
    while (i < 800) : (i += 1) {
        buf = buf ++ std.fmt.comptimePrint(
            \\[[entry]]
            \\id = {d}
            \\name = "entry-{d}"
            \\enabled = true
            \\score = {d}.5
            \\tags = ["alpha", "beta", "gamma", "delta"]
            \\created = 2024-01-{d:0>2}T12:00:00Z
            \\
            \\
        , .{ i, i, i, (i % 28) + 1 });
    }
    break :blk buf;
};

const std = @import("std");
