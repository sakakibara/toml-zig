//! Microbenchmarks for the toml library.
//!
//! Methodology:
//! - Each benchmark runs `inner_iters` operations to amortize timer
//!   resolution; the total elapsed time divided by `inner_iters` is one
//!   sample.
//! - `samples` such samples are collected; the reported numbers are the
//!   min, median, p99, max, and standard deviation across samples.
//! - One untimed warmup sample is run first to populate caches and
//!   trigger JIT-equivalent paths in the compiler-generated code.
//! - Arenas are reset between iterations so allocator behavior doesn't
//!   dominate the parser cost.
//! - The monotonic `awake` clock is used for timing.
//! - Compiler-side dead-code elimination is suppressed via
//!   `std.mem.doNotOptimizeAway` on the result.
//!
//! Caveats:
//! - These are microbenchmarks. They measure parser/encoder hot paths
//!   on representative-but-synthetic inputs. Real workloads vary; if
//!   your file is huge, structurally weird, or pathological for any
//!   particular reason, your numbers will differ.
//! - CPU frequency scaling, thermal throttling, and noisy neighbors
//!   on shared CI runners can shift absolute numbers by 2x or more.
//!   Compare runs on the same machine; treat absolute numbers as
//!   "order of magnitude" only.
//! - Numbers are wall-clock, single-threaded.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const toml = @import("toml");

const fixtures = @import("fixtures.zig");

const Bench = struct {
    name: []const u8,
    fixture: []const u8,
    inner_iters: usize,
    samples: usize = 11,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    try printHeader(w);

    const benches = [_]Bench{
        .{ .name = "small  (manifest)", .fixture = fixtures.small, .inner_iters = 10_000 },
        .{ .name = "medium (cargo-lock)", .fixture = fixtures.medium, .inner_iters = 1_000 },
        .{ .name = "large  (10k tables)", .fixture = fixtures.large, .inner_iters = 50 },
    };

    for (benches) |b| {
        try runBench(w, gpa, io, b);
        try w.writeByte('\n');
    }

    // Bounded-memory streaming bench: 100 000 small [[record]] elements in one
    // buffer, streamed via ValueStream with a per-item arena reset. The
    // EventReader's peak bufCapacity() must stay proportional to ONE element,
    // not to the total stream length -- that is the bounded-memory guarantee.
    // The bench prints peak capacity alongside throughput so regressions are
    // visible.
    try benchValueStreamBounded(w, gpa, io);
    try benchParseIntoBig(w, gpa, io);

    try printFooter(w);
    try w.flush();
}

/// Large typed-decode bench: a multi-MB [[record]] array-of-tables decoded
/// into a slice of structs. This is the workload where typed decode
/// throughput matters most (manifests are small; data files are not).
fn benchParseIntoBig(w: *Io.Writer, gpa: std.mem.Allocator, io: Io) !void {
    const Rec = struct {
        id: u64,
        name: []const u8,
        active: bool,
        score: f64,
        tags: []const []const u8,
    };
    const Doc = struct { record: []const Rec };

    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    for (0..30_000) |i| {
        try buf.writer.print(
            "[[record]]\nid = {d}\nname = \"record-{d}-with-some-name\"\nactive = {}\nscore = {d}.5\ntags = [\"alpha\", \"beta-{d}\"]\n",
            .{ i, i, i % 2 == 0, i % 100, i % 97 },
        );
    }
    const src = buf.written();

    const samples = try gpa.alloc(u64, 11);
    defer gpa.free(samples);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // One untimed warmup pass.
    {
        _ = arena.reset(.retain_capacity);
        const doc = try toml.parseInto(Doc, arena.allocator(), src, .{});
        std.mem.doNotOptimizeAway(&doc);
    }
    for (samples) |*s| {
        _ = arena.reset(.retain_capacity);
        const t0 = Io.Clock.Timestamp.now(io, .awake);
        const doc = try toml.parseInto(Doc, arena.allocator(), src, .{});
        s.* = @intCast(@max(t0.untilNow(io).raw.toNanoseconds(), 0));
        std.mem.doNotOptimizeAway(&doc);
    }

    const stats = computeStats(samples, 1);
    try w.print(
        "\n== parseInto (typed big)  (30000 [[record]] elements, {d} bytes) ==\n",
        .{src.len},
    );
    try w.print(
        "  typed    min {d:>9} ns  p50 {d:>9} ns  p99 {d:>9} ns  max {d:>9} ns  stddev {d:>7.0} ns  ({d:>6.1} MB/s)\n",
        .{
            stats.min_per_op,
            stats.p50_per_op,
            stats.p99_per_op,
            stats.max_per_op,
            stats.stddev,
            mbPerSec(src.len, stats.p50_per_op),
        },
    );
}

fn printHeader(w: *Io.Writer) !void {
    try w.print(
        \\toml microbenchmarks
        \\  zig:        {s}
        \\  optimize:   {t}
        \\  target:     {t}-{t}-{t}
        \\  cpu:        {s}
        \\
        \\
    , .{
        builtin.zig_version_string,
        builtin.mode,
        builtin.cpu.arch,
        builtin.os.tag,
        builtin.abi,
        builtin.cpu.model.name,
    });
}

fn printFooter(w: *Io.Writer) !void {
    try w.writeAll(
        \\methodology: each row is `samples` repetitions of `inner_iters` ops;
        \\reported numbers (min/p50/p99/max) are per-op latency across samples.
        \\throughput is computed from the median sample.
        \\
    );
}

fn runBench(w: *Io.Writer, gpa: std.mem.Allocator, io: Io, b: Bench) !void {
    try w.print("== {s}  ({d} bytes, {d} samples x {d} iters) ==\n", .{
        b.name, b.fixture.len, b.samples, b.inner_iters,
    });

    try sampleAndReport(w, gpa, io, b, "parse  ", benchParse);
    try sampleAndReport(w, gpa, io, b, "encode ", benchEncode);
}

const SampleFn = fn (gpa: std.mem.Allocator, io: Io, fixture: []const u8, iters: usize) anyerror!u64;

fn sampleAndReport(
    w: *Io.Writer,
    gpa: std.mem.Allocator,
    io: Io,
    b: Bench,
    label: []const u8,
    sample: SampleFn,
) !void {
    // Warmup (untimed, result discarded).
    _ = try sample(gpa, io, b.fixture, b.inner_iters);

    const samples = try gpa.alloc(u64, b.samples);
    defer gpa.free(samples);

    for (samples) |*s| {
        s.* = try sample(gpa, io, b.fixture, b.inner_iters);
    }

    const stats = computeStats(samples, b.inner_iters);
    try w.print(
        "  {s}  min {d:>9} ns  p50 {d:>9} ns  p99 {d:>9} ns  max {d:>9} ns  stddev {d:>7.0} ns  ({d:>6.1} MB/s)\n",
        .{
            label,
            stats.min_per_op,
            stats.p50_per_op,
            stats.p99_per_op,
            stats.max_per_op,
            stats.stddev,
            mbPerSec(b.fixture.len, stats.p50_per_op),
        },
    );
}

const Stats = struct {
    min_per_op: u64,
    p50_per_op: u64,
    p99_per_op: u64,
    max_per_op: u64,
    stddev: f64,
};

fn computeStats(total_ns_samples: []u64, inner_iters: usize) Stats {
    // Convert to per-op nanoseconds in place; samples slice is mutable.
    for (total_ns_samples) |*s| s.* /= inner_iters;
    std.sort.heap(u64, total_ns_samples, {}, std.sort.asc(u64));

    const n = total_ns_samples.len;
    const min = total_ns_samples[0];
    const max = total_ns_samples[n - 1];
    const p50 = total_ns_samples[n / 2];
    const p99_idx = (n * 99 + 99) / 100;
    const p99 = total_ns_samples[@min(p99_idx, n - 1)];

    var sum: f64 = 0;
    for (total_ns_samples) |x| sum += @floatFromInt(x);
    const mean = sum / @as(f64, @floatFromInt(n));
    var sq_diff_sum: f64 = 0;
    for (total_ns_samples) |x| {
        const d = @as(f64, @floatFromInt(x)) - mean;
        sq_diff_sum += d * d;
    }
    const stddev = std.math.sqrt(sq_diff_sum / @as(f64, @floatFromInt(n)));

    return .{ .min_per_op = min, .p50_per_op = p50, .p99_per_op = p99, .max_per_op = max, .stddev = stddev };
}

fn mbPerSec(bytes: usize, per_op_ns: u64) f64 {
    if (per_op_ns == 0) return 0;
    const bytes_per_op_f: f64 = @floatFromInt(bytes);
    const ns_f: f64 = @floatFromInt(per_op_ns);
    // bytes/op / (ns/op) = bytes/ns; * 1e9 = bytes/s; / (1024*1024) = MB/s.
    return bytes_per_op_f * 1_000.0 / ns_f / 1.048576;
}

// Benchmark bodies

fn benchParse(gpa: std.mem.Allocator, io: Io, fixture: []const u8, iters: usize) !u64 {
    // Fresh arena per iteration: matches the typical "parse a config file
    // once, then drop it" usage pattern. A retained-capacity arena would
    // give larger numbers but understate real-world allocation cost.
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    var i: usize = 0;
    var sink: usize = 0;
    while (i < iters) : (i += 1) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const v = try toml.parse(arena.allocator(), fixture, .{});
        sink +%= v.table.count();
    }
    std.mem.doNotOptimizeAway(&sink);
    return @intCast(@max(t0.untilNow(io).raw.toNanoseconds(), 0));
}

/// Bounded-memory streaming bench. Builds a large synthetic N-element TOML
/// stream of [[record]] array-of-tables entries (100 000 elements, each ~30
/// bytes), then streams it via ValueStream with a per-item arena reset between
/// elements.
///
/// The key property under test: the EventReader's internal doc_buf grows to
/// roughly ONE element's size and stays there, regardless of how many elements
/// the stream contains. The reported peak capacity is the regression guard: it
/// must not grow with N.
fn benchValueStreamBounded(w: *Io.Writer, gpa: std.mem.Allocator, io: Io) !void {
    const n_elems = 100_000;

    // Build the synthetic stream: N [[record]] elements.
    // Each element: "[[record]]\nname = \"elem-NNNNN\"\nseq = NNNNN\n" (~35 bytes).
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    for (0..n_elems) |i| {
        try buf.writer.print("[[record]]\nname = \"elem-{d}\"\nseq = {d}\n", .{ i, i });
    }
    const stream_src = buf.written();
    const stream_bytes = stream_src.len;

    // Single element's byte length (rough reference for the cap assertion).
    const one_elem_approx: usize = stream_bytes / n_elems + 8;

    const samples = try gpa.alloc(u64, 11);
    defer gpa.free(samples);
    var peak_cap: usize = 0;

    // One untimed warmup pass.
    {
        var item_arena = std.heap.ArenaAllocator.init(gpa);
        defer item_arena.deinit();
        var r: std.Io.Reader = .fixed(stream_src);
        var vs = toml.ValueStream.fromReader(gpa, &r, .{}, .array_of_tables);
        defer vs.deinit();
        while (try vs.next(item_arena.allocator())) |v| {
            std.mem.doNotOptimizeAway(&v);
            _ = item_arena.reset(.retain_capacity);
        }
    }

    for (samples) |*s| {
        var item_arena = std.heap.ArenaAllocator.init(gpa);
        defer item_arena.deinit();

        var r: std.Io.Reader = .fixed(stream_src);
        var vs = toml.ValueStream.fromReader(gpa, &r, .{}, .array_of_tables);
        defer vs.deinit();

        const t0 = Io.Clock.Timestamp.now(io, .awake);
        var count: usize = 0;
        while (try vs.next(item_arena.allocator())) |v| {
            std.mem.doNotOptimizeAway(&v);
            count += 1;
            _ = item_arena.reset(.retain_capacity);
        }
        s.* = @intCast(@max(t0.untilNow(io).raw.toNanoseconds(), 0));

        const cap = vs.er.bufCapacity();
        if (cap > peak_cap) peak_cap = cap;
    }

    const stats = computeStats(samples, 1);
    try w.print(
        "\n== ValueStream bounded-memory  ({d} [[record]] elements, {d} bytes) ==\n",
        .{ n_elems, stream_bytes },
    );
    try w.print(
        "  stream   min {d:>9} ns  p50 {d:>9} ns  p99 {d:>9} ns  max {d:>9} ns  stddev {d:>7.0} ns  ({d:>6.1} MB/s)\n",
        .{
            stats.min_per_op,
            stats.p50_per_op,
            stats.p99_per_op,
            stats.max_per_op,
            stats.stddev,
            mbPerSec(stream_bytes, stats.p50_per_op),
        },
    );

    // The peak doc_buf capacity must stay bounded to roughly one element's
    // size plus a pull chunk (4 KiB). We set the limit at 64 KiB -- 16x the
    // pull chunk -- as a generous regression guard. A capacity near the full
    // stream size (3+ MB) would indicate the bounded-memory guarantee has
    // regressed.
    const cap_limit = 64 * 1024;
    if (peak_cap > cap_limit) {
        try w.print(
            "BOUNDED-MEMORY FAIL: peak bufCapacity {d} B exceeds limit {d} B (one_elem_approx={d} B)\n",
            .{ peak_cap, cap_limit, one_elem_approx },
        );
        try w.flush();
        std.process.exit(1);
    }

    try w.print(
        "  bounded-memory: peak bufCapacity = {d} B  (one_elem_approx = {d} B, n_elems = {d})\n",
        .{ peak_cap, one_elem_approx, n_elems },
    );
}

fn benchEncode(gpa: std.mem.Allocator, io: Io, fixture: []const u8, iters: usize) !u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try toml.parse(arena.allocator(), fixture, .{});

    const t0 = Io.Clock.Timestamp.now(io, .awake);
    var i: usize = 0;
    var sink: usize = 0;
    while (i < iters) : (i += 1) {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try toml.encode(&aw.writer, v, .{});
        sink +%= aw.writer.end;
    }
    std.mem.doNotOptimizeAway(&sink);
    return @intCast(@max(t0.untilNow(io).raw.toNanoseconds(), 0));
}
