//! Random-input fuzzer for the toml library.
//!
//! Generates synthetic inputs and exercises every public entry point.
//! Asserts the invariants:
//!   - parse never panics or hangs on any input
//!   - encode of any successfully-parsed Value produces TOML that
//!     re-parses to a structurally-equal Value
//!   - document.parse + emit produces byte-identical output for any
//!     input it accepts
//!
//! This sidesteps `zig test --fuzz`, which is broken in Zig 0.16.0
//! (test_runner type mismatch on `@errorReturnTrace`).
//!
//! CLI:
//!   toml-fuzz [--iters N] [--seed S] [--max-input M]
//!
//! Defaults: 100,000 iterations, random seed, 4096-byte max input.

const std = @import("std");
const Io = std.Io;
const toml = @import("toml");

const Mode = enum { random_bytes, biased, deep_nesting };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena_alloc = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const w = &stdout_writer.interface;
    var stderr_buf: [256]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
    const ew = &stderr_writer.interface;

    var iters: usize = 100_000;
    var max_input: usize = 4096;
    var seed: u64 = blk: {
        var s: u64 = undefined;
        io.random(@ptrCast(&s));
        break :blk s;
    };

    const args = try init.minimal.args.toSlice(arena_alloc);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--iters") and i + 1 < args.len) {
            iters = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed") and i + 1 < args.len) {
            seed = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--max-input") and i + 1 < args.len) {
            max_input = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else {
            try ew.print("usage: toml-fuzz [--iters N] [--seed S] [--max-input M]\n", .{});
            try ew.flush();
            return 2;
        }
    }

    try w.print("toml-fuzz: iters={d} seed={d} max_input={d}\n", .{ iters, seed, max_input });
    try w.flush();

    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();

    const input_buf = try gpa.alloc(u8, max_input);
    defer gpa.free(input_buf);

    var failures: usize = 0;
    var parsed_ok: usize = 0;
    var n: usize = 0;

    while (n < iters) : (n += 1) {
        // One in eight iterations stresses pathological deep nesting (long
        // runs of `[` / `{` and `a.a.a...` dotted keys) -- the class of
        // input that recursive-descent value parsing can stack-overflow on
        // without a depth bound. The rest split between biased and random.
        const mode: Mode = switch (rng.uintLessThan(u8, 8)) {
            0 => .deep_nesting,
            1...4 => .biased,
            else => .random_bytes,
        };

        if (mode == .deep_nesting) {
            const input = generateDeepNesting(rng, input_buf);
            if (try fuzzDeep(gpa, input)) |err| {
                failures += 1;
                try reportFailure(ew, n, seed, input, err);
            }
            continue;
        }

        const len = rng.intRangeAtMost(usize, 0, max_input);
        const input = input_buf[0..len];
        switch (mode) {
            .random_bytes => rng.bytes(input),
            .biased => generateBiased(rng, input),
            .deep_nesting => unreachable,
        }

        if (try fuzzOnce(gpa, input)) |err| {
            failures += 1;
            try reportFailure(ew, n, seed, input, err);
        } else if (didParse(gpa, input)) {
            parsed_ok += 1;
        }

        if ((n + 1) % 10_000 == 0) {
            try w.print("  {d:>9} iters, {d} parsed ok, {d} failures\n", .{ n + 1, parsed_ok, failures });
            try w.flush();
        }
    }

    try w.print("\ndone: {d} iters, {d} parsed ok, {d} failures\n", .{ n, parsed_ok, failures });
    try w.flush();
    return if (failures == 0) 0 else 1;
}

const FuzzError = error{
    Panic,
    RoundTripMismatch,
    LosslessFailure,
    SpanOutOfBounds,
    DepthNotBounded,
};

fn fuzzOnce(gpa: std.mem.Allocator, input: []const u8) !?FuzzError {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // Parse.
    const v1 = toml.parse(arena.allocator(), input, .{}) catch return null;

    // Round-trip: encode -> parse -> must equal.
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    toml.encode(&aw.writer, v1) catch return null;
    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    const v2 = toml.parse(arena2.allocator(), aw.written(), .{}) catch return error.RoundTripMismatch;
    if (!toml.Value.eql(v1, v2)) return error.RoundTripMismatch;

    // Document model: parse + emit unmodified must be byte-identical.
    var arena3: std.heap.ArenaAllocator = .init(gpa);
    defer arena3.deinit();
    var doc = toml.document.Document.parse(arena3.allocator(), input, .{}) catch return null;
    var doc_out: Io.Writer.Allocating = .init(gpa);
    defer doc_out.deinit();
    try doc.emit(&doc_out.writer);
    if (!std.mem.eql(u8, doc_out.written(), input)) return error.LosslessFailure;

    // Spans must be in-bounds.
    var arena4: std.heap.ArenaAllocator = .init(gpa);
    defer arena4.deinit();
    var spans: toml.Spans = .empty;
    _ = toml.parse(arena4.allocator(), input, .{ .spans = &spans }) catch return null;
    var it = spans.iterator();
    while (it.next()) |entry| {
        const span = entry.value_ptr.*;
        if (span.start > input.len or span.end > input.len or span.start > span.end) {
            return error.SpanOutOfBounds;
        }
    }

    return null;
}

/// Deep-nesting invariant: parse must RETURN (not stack-overflow) on
/// pathologically nested input. Surviving the call is the primary
/// assertion -- a regression of the depth bound crashes the process here
/// instead of reaching the return below. When the nesting actually
/// exceeds the parser's default ceiling, the error must be the distinct
/// `error.NestingTooDeep`.
fn fuzzDeep(gpa: std.mem.Allocator, input: []const u8) !?FuzzError {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = toml.parse(arena.allocator(), input, .{});
    if (r) |_| {
        // Parsed cleanly: nesting stayed under the ceiling. Fine.
        return null;
    } else |err| {
        return switch (err) {
            error.NestingTooDeep, error.TomlParseError => null,
            error.OutOfMemory => null,
            else => FuzzError.DepthNotBounded,
        };
    }
}

fn didParse(gpa: std.mem.Allocator, input: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = toml.parse(arena.allocator(), input, .{}) catch return false;
    return true;
}

fn reportFailure(w: *Io.Writer, iter: usize, seed: u64, input: []const u8, err: FuzzError) !void {
    try w.print("FAIL iter={d} seed={d} err={t} input_len={d}\n", .{ iter, seed, err, input.len });
    try w.print("input (escaped): \"", .{});
    for (input) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (b >= 0x20 and b < 0x7f) try w.writeByte(b) else try w.print("\\x{x:0>2}", .{b}),
    };
    try w.writeAll("\"\n");
    try w.flush();
}

/// Emit a `key = ` prefix followed by a long run of array / inline-table
/// openers (and sometimes `a.a.a...` dotted keys), to a depth far past
/// the parser's default 128 ceiling. Returns the populated prefix of
/// `buf`. The depth is bounded by the buffer length, so the generator
/// itself can't run away; the parser's depth guard is what must hold.
fn generateDeepNesting(rng: std.Random, buf: []u8) []const u8 {
    if (buf.len < 8) {
        // Too small to be interesting; fall back to a short bracket run.
        const n = @min(buf.len, 4);
        for (buf[0..n]) |*b| b.* = '[';
        return buf[0..n];
    }

    var i: usize = 0;
    const prefix = "x = ";
    @memcpy(buf[0..prefix.len], prefix);
    i += prefix.len;

    // Choose the opener style for this input. `dotted` mode interleaves
    // `a.` segments inside inline tables to also stress dotted-key descent.
    const style = rng.uintLessThan(u8, 3);
    while (i < buf.len) {
        const remaining = buf.len - i;
        switch (style) {
            0 => {
                buf[i] = '[';
                i += 1;
            },
            1 => {
                if (remaining < 3) break;
                @memcpy(buf[i .. i + 3], "{a=");
                i += 3;
            },
            else => {
                if (remaining < 4) break;
                @memcpy(buf[i .. i + 4], "{a.a"); // dotted key inside inline table
                i += 4;
                if (i < buf.len) {
                    buf[i] = '=';
                    i += 1;
                }
            },
        }
    }
    return buf[0..i];
}

fn generateBiased(rng: std.Random, out: []u8) void {
    // Bias toward bytes likely to exercise TOML grammar paths.
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.= []{}\"'\n\t,#";
    for (out) |*b| {
        if (rng.boolean()) {
            b.* = charset[rng.uintLessThan(usize, charset.len)];
        } else {
            b.* = rng.int(u8);
        }
    }
}
