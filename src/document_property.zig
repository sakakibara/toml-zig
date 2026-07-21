//! Deterministic property/round-trip battery for the `Document` editor.
//!
//! Generates a fixed, bounded number of random-but-valid TOML documents
//! (nested tables, comments, blank lines, adversarial key names) plus a
//! random segment-path edit against each one, then asserts the invariants
//! the editor is meant to satisfy:
//!
//!   1. Set is total-or-clean: it either succeeds, or returns a defined
//!      error and leaves the document byte-unchanged.
//!   2. On success, `emit()` output re-parses without error.
//!   3. The edited path reads back exactly the value that was set.
//!   4. Every other leaf from the original document still reads back its
//!      original value.
//!   5. Every comment present in the source is still present in the
//!      output; a pure value-replace on an existing leaf changes only
//!      the value's own byte span.
//!   6. Re-applying the same set is a byte-identical no-op.
//!   7. Removing an existing leaf drops it, re-parses cleanly, and
//!      preserves siblings and comments.
//!
//! The PRNG is seeded deterministically from a fixed base seed; each case
//! derives its seed as `base +% index`, so any failure prints enough
//! (case index, seed, source, target path, value) to replay it exactly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const testing = std.testing;

const document = @import("document.zig");
const parser_mod = @import("parser.zig");
const encoder = @import("encoder.zig");
const value_mod = @import("value.zig");

const Document = document.Document;
const Value = value_mod.Value;

const base_seed: u64 = 0x746f6d6c5f70726f;
const case_count: usize = 3000;
const max_depth: u32 = 4;
const max_fanout: u32 = 4;

test "document property battery: generated set/remove edits preserve every editor invariant" {
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        runCase(case_index) catch |err| {
            std.debug.print("document property battery: case {d} (seed {d}) aborted with {s}\n", .{ case_index, base_seed +% case_index, @errorName(err) });
            return err;
        };
    }
}

const Leaf = struct {
    segments: []const []const u8,
    value: Value,
};

const Model = struct {
    leaves: std.ArrayList(Leaf) = .empty,
    containers: std.ArrayList([]const []const u8) = .empty,
    comments: std.ArrayList([]const u8) = .empty,
    aot_root: ?[]const []const u8 = null,
    counter: u32 = 0,
};

const Ctx = struct {
    case_index: usize,
    seed: u64,
    source: []const u8,
    target_desc: []const u8 = "",
    value_desc: []const u8 = "",
};

fn runCase(case_index: usize) !void {
    const seed = base_seed +% case_index;
    var arena_state = ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();

    var model: Model = .{};
    const source = try genDocument(arena, rng, &model);

    var ctx: Ctx = .{ .case_index = case_index, .seed = seed, .source = source };

    try runSetCase(arena, rng, &model, source, &ctx);
    try runRemoveCase(arena, rng, &model, source, &ctx);
}

// generation

fn genDocument(arena: Allocator, rng: std.Random, model: *Model) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try genContainer(arena, rng, model, &aw.writer, &.{}, 0);
    if (rng.uintLessThan(u8, 3) == 0) {
        try genAotBlock(arena, rng, model, &aw.writer);
    }
    return aw.written();
}

fn genContainer(arena: Allocator, rng: std.Random, model: *Model, w: *Io.Writer, path: []const []const u8, depth: u32) !void {
    try model.containers.append(arena, path);

    var used: std.ArrayList([]const u8) = .empty;
    const total = rng.intRangeAtMost(u32, 1, max_fanout);
    const leaf_count = rng.intRangeAtMost(u32, 1, total);
    const sub_count: u32 = if (depth < max_depth) total - leaf_count else 0;

    var li: u32 = 0;
    while (li < leaf_count) : (li += 1) {
        try maybeBlankOrComment(arena, rng, model, w);
        const key = try freshKey(arena, rng, model, &used);
        const value = try genValue(arena, rng, model, true);
        try writeKvLine(w, key, value);
        const seg = try appendSeg(arena, path, key);
        try model.leaves.append(arena, .{ .segments = seg, .value = value });
    }

    var si: u32 = 0;
    while (si < sub_count) : (si += 1) {
        if (rng.uintLessThan(u8, 4) == 0) try w.writeByte('\n');
        const key = try freshKey(arena, rng, model, &used);
        const sub_path = try appendSeg(arena, path, key);
        try writeHeaderLine(w, sub_path);
        try genContainer(arena, rng, model, w, sub_path, depth + 1);
    }
}

fn genAotBlock(arena: Allocator, rng: std.Random, model: *Model, w: *Io.Writer) !void {
    model.counter += 1;
    const name = try std.fmt.allocPrint(arena, "aot{d}", .{model.counter});
    try w.writeByte('\n');
    var elem: u8 = 0;
    while (elem < 2) : (elem += 1) {
        try w.writeAll("[[");
        try encoder.writeKey(w, name);
        try w.writeAll("]]\n");
        try encoder.writeKey(w, "field");
        try w.writeAll(" = ");
        try encoder.writeInlineValue(w, .{ .integer = elem });
        try w.writeByte('\n');
    }
    _ = rng;
    const root = try arena.alloc([]const u8, 1);
    root[0] = name;
    model.aot_root = root;
}

fn maybeBlankOrComment(arena: Allocator, rng: std.Random, model: *Model, w: *Io.Writer) !void {
    const roll = rng.uintLessThan(u8, 100);
    if (roll < 15) {
        try w.writeByte('\n');
    } else if (roll < 30) {
        model.counter += 1;
        const text = try std.fmt.allocPrint(arena, "# note {d}\n", .{model.counter});
        try w.writeAll(text);
        try model.comments.append(arena, text);
    }
}

fn writeKvLine(w: *Io.Writer, key: []const u8, value: Value) !void {
    try encoder.writeKey(w, key);
    try w.writeAll(" = ");
    try encoder.writeInlineValue(w, value);
    try w.writeByte('\n');
}

fn writeHeaderLine(w: *Io.Writer, segments: []const []const u8) !void {
    try w.writeByte('[');
    for (segments, 0..) |seg, i| {
        if (i > 0) try w.writeByte('.');
        try encoder.writeKey(w, seg);
    }
    try w.writeAll("]\n");
}

fn appendSeg(arena: Allocator, path: []const []const u8, key: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, path.len + 1);
    @memcpy(out[0..path.len], path);
    out[path.len] = key;
    return out;
}

// key/value pools

const bare_pool = [_][]const u8{ "abc", "alpha", "beta", "foo_bar", "k", "val", "item", "field", "name", "x_y_z" };

const adversarial_pool = [_][]const u8{
    "a.b",   "with space", "qu\"ote", "back\\slash", "-leading",
    "?lead", "#lead",      ";lead",   "[lead",       "true",
    "false", "null",       "123",     "1.5",         "2024-01-01",
    "",
};

fn freshKey(arena: Allocator, rng: std.Random, model: *Model, used: *std.ArrayList([]const u8)) ![]const u8 {
    if (rng.uintLessThan(u8, 10) < 3) {
        const start = rng.uintLessThan(usize, adversarial_pool.len);
        var i: usize = 0;
        while (i < adversarial_pool.len) : (i += 1) {
            const cand = adversarial_pool[(start + i) % adversarial_pool.len];
            if (!containsStr(used.items, cand)) {
                try used.append(arena, cand);
                return cand;
            }
        }
    }
    model.counter += 1;
    const base = bare_pool[rng.uintLessThan(usize, bare_pool.len)];
    const key = try std.fmt.allocPrint(arena, "{s}{d}", .{ base, model.counter });
    try used.append(arena, key);
    return key;
}

fn containsStr(items: []const []const u8, needle: []const u8) bool {
    for (items) |it| {
        if (std.mem.eql(u8, it, needle)) return true;
    }
    return false;
}

const string_pool = [_][]const u8{
    "hello",       "true",         "123", "- x",        "he said \"hi\"",
    "back\\slash", "line1\nline2", "",    "  spaced  ", "unicode: h\xc3\xa9llo",
};

fn genStringValue(rng: std.Random) Value {
    return .{ .string = string_pool[rng.uintLessThan(usize, string_pool.len)] };
}

fn genInt(rng: std.Random) i64 {
    return switch (rng.uintLessThan(u8, 10)) {
        0 => std.math.minInt(i64),
        1 => std.math.maxInt(i64),
        2 => 0,
        else => rng.intRangeAtMost(i64, -1_000_000, 1_000_000),
    };
}

fn genFloat(rng: std.Random) f64 {
    return switch (rng.uintLessThan(u8, 10)) {
        0 => 0.0,
        1 => -0.0,
        2 => std.math.inf(f64),
        3 => -std.math.inf(f64),
        else => (rng.float(f64) - 0.5) * 2_000_000.0,
    };
}

fn genDateValue(rng: std.Random) Value {
    const date: value_mod.Date = .{
        .year = 1970 + rng.uintLessThan(u16, 100),
        .month = 1 + rng.uintLessThan(u8, 12),
        .day = 1 + rng.uintLessThan(u8, 28),
    };
    const time: value_mod.Time = .{
        .hour = rng.uintLessThan(u8, 24),
        .minute = rng.uintLessThan(u8, 60),
        .second = rng.uintLessThan(u8, 60),
        .nanos = 0,
    };
    return switch (rng.uintLessThan(u8, 3)) {
        0 => .{ .date = date },
        1 => .{ .time = time },
        else => .{ .datetime = .{ .date = date, .time = time, .tz_offset_minutes = if (rng.boolean()) 0 else null } },
    };
}

fn genArrayValue(arena: Allocator, rng: std.Random, model: *Model) Allocator.Error!Value {
    var arr: Value.Array = .empty;
    const n = rng.intRangeAtMost(u32, 0, 3);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try arr.append(arena, try genValue(arena, rng, model, false));
    }
    return .{ .array = arr };
}

fn genTableValue(arena: Allocator, rng: std.Random, model: *Model) Allocator.Error!Value {
    var tbl: Value.Table = .empty;
    const n = rng.intRangeAtMost(u32, 1, 2);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        model.counter += 1;
        const key = try std.fmt.allocPrint(arena, "f{d}", .{model.counter});
        try tbl.put(arena, key, try genValue(arena, rng, model, false));
    }
    return .{ .table = tbl };
}

fn genValue(arena: Allocator, rng: std.Random, model: *Model, allow_container: bool) Allocator.Error!Value {
    const roll = rng.uintLessThan(u32, 100);
    if (roll < 26) return genStringValue(rng);
    if (roll < 44) return .{ .integer = genInt(rng) };
    if (roll < 58) return .{ .float = genFloat(rng) };
    if (roll < 68) return .{ .boolean = rng.boolean() };
    if (roll < 76) return genDateValue(rng);
    if (allow_container) {
        if (roll < 88) return genArrayValue(arena, rng, model);
        return genTableValue(arena, rng, model);
    }
    return genStringValue(rng);
}

// target-path selection

const TargetKind = enum { existing_leaf, new_leaf, missing_chain, aot_blocked };

const Target = struct {
    segments: []const []const u8,
    kind: TargetKind,
};

fn pickTarget(arena: Allocator, rng: std.Random, model: *Model) !Target {
    const roll = rng.uintLessThan(u8, 100);

    if (model.aot_root != null and roll < 15) {
        return .{ .segments = try appendSeg(arena, model.aot_root.?, "newfield"), .kind = .aot_blocked };
    }
    if (roll < 40) {
        const leaf = model.leaves.items[rng.uintLessThan(usize, model.leaves.items.len)];
        return .{ .segments = leaf.segments, .kind = .existing_leaf };
    }
    if (roll < 70) {
        const container = model.containers.items[rng.uintLessThan(usize, model.containers.items.len)];
        var used: std.ArrayList([]const u8) = .empty;
        try collectChildren(arena, model, container, &used);
        const key = try freshKey(arena, rng, model, &used);
        return .{ .segments = try appendSeg(arena, container, key), .kind = .new_leaf };
    }

    const container = model.containers.items[rng.uintLessThan(usize, model.containers.items.len)];
    const chain_len = rng.intRangeAtMost(u32, 1, 3);
    var path = container;
    var i: u32 = 0;
    while (i < chain_len) : (i += 1) {
        model.counter += 1;
        const seg = try std.fmt.allocPrint(arena, "new{d}", .{model.counter});
        path = try appendSeg(arena, path, seg);
    }
    return .{ .segments = path, .kind = .missing_chain };
}

fn collectChildren(arena: Allocator, model: *Model, container: []const []const u8, used: *std.ArrayList([]const u8)) !void {
    for (model.leaves.items) |leaf| {
        if (leaf.segments.len == container.len + 1 and segPrefixEq(leaf.segments, container)) {
            try used.append(arena, leaf.segments[container.len]);
        }
    }
    for (model.containers.items) |c| {
        if (c.len == container.len + 1 and segPrefixEq(c, container)) {
            try used.append(arena, c[container.len]);
        }
    }
}

fn segPrefixEq(full: []const []const u8, prefix: []const []const u8) bool {
    if (full.len < prefix.len) return false;
    for (prefix, 0..) |p, i| {
        if (!std.mem.eql(u8, p, full[i])) return false;
    }
    return true;
}

fn segEq(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn resolveSegments(root: Value, segments: []const []const u8) ?Value {
    var cur = root;
    for (segments) |seg| {
        if (cur != .table) return null;
        cur = cur.table.get(seg) orelse return null;
    }
    return cur;
}

// per-case checks

fn parseOrReport(arena: Allocator, source: []const u8, ctx: *const Ctx) !Document {
    return Document.parse(arena, source, .{}) catch |err| {
        std.debug.print("document property battery: case {d} seed {d}: generated document failed to parse ({s})\nsource:\n{s}\n", .{ ctx.case_index, ctx.seed, @errorName(err), source });
        return err;
    };
}

const PreEditSpan = struct { start: usize, end: usize, doc_source_len: usize };

fn findValueSpan(doc: *const Document, segments: []const []const u8) ?PreEditSpan {
    for (doc.items.items) |item| {
        if (item != .kv) continue;
        if (!segEq(item.kv.full_path_segments, segments)) continue;
        const raw = item.kv.raw;
        const item_start = @intFromPtr(raw.ptr) - @intFromPtr(doc.source.ptr);
        const start = item_start + item.kv.value_offset;
        return .{ .start = start, .end = start + item.kv.value_len, .doc_source_len = doc.source.len };
    }
    return null;
}

fn runSetCase(arena: Allocator, rng: std.Random, model: *Model, source: []const u8, ctx: *Ctx) !void {
    var doc = try parseOrReport(arena, source, ctx);
    const target = try pickTarget(arena, rng, model);
    const value = try genValue(arena, rng, model, true);

    ctx.target_desc = try formatSegments(arena, target.segments);
    ctx.value_desc = try formatValueDebug(arena, value);

    var pre_edit: ?PreEditSpan = null;
    if (target.kind == .existing_leaf) {
        pre_edit = findValueSpan(&doc, target.segments) orelse
            return fail(ctx, "setup", "existing leaf target not found before editing (generator bug)");
    }

    if (doc.setValueSegments(target.segments, value)) |_| {
        try checkSetSuccess(arena, &doc, model, target, value, pre_edit, ctx);
    } else |err| {
        try checkSetFailureRollback(arena, &doc, source, err, target, ctx);
    }
}

fn checkSetFailureRollback(arena: Allocator, doc: *Document, source: []const u8, err: anyerror, target: Target, ctx: *Ctx) !void {
    var aw: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw.writer);
    if (!std.mem.eql(u8, aw.written(), source)) {
        return fail(ctx, "1-clean-error-rollback", "emitted output differs from the original source after a failed set");
    }
    if (target.kind == .aot_blocked and err != error.UnsupportedPath) {
        return fail(ctx, "1-aot-blocked-error-kind", "expected UnsupportedPath for a path through an array-of-tables");
    }
}

fn checkSetSuccess(arena: Allocator, doc: *Document, model: *Model, target: Target, value: Value, pre_edit: ?PreEditSpan, ctx: *Ctx) !void {
    var aw1: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw1.writer);
    const emitted1 = aw1.written();

    const reparsed1 = parser_mod.parse(arena, emitted1, .{}) catch
        return fail(ctx, "2-reparse-clean", "emitted output failed to reparse");

    const got = resolveSegments(reparsed1, target.segments) orelse
        return fail(ctx, "3-read-back-exact", "target path missing after the edit");
    if (!Value.eql(got, value)) {
        return fail(ctx, "3-read-back-exact", "target path resolved to a different value than was set");
    }

    for (model.leaves.items) |leaf| {
        if (segEq(leaf.segments, target.segments)) continue;
        const sib = resolveSegments(reparsed1, leaf.segments) orelse
            return fail(ctx, "4-sibling-preservation", "a sibling leaf is missing after the edit");
        if (!Value.eql(sib, leaf.value)) {
            return fail(ctx, "4-sibling-preservation", "a sibling leaf's value changed after the edit");
        }
    }

    for (model.comments.items) |c| {
        if (std.mem.indexOf(u8, emitted1, c) == null) {
            return fail(ctx, "5-comment-preservation", "a comment present in source is missing from the output");
        }
    }

    if (target.kind == .existing_leaf) {
        try checkByteExactExceptValue(arena, doc, pre_edit.?, ctx);
    }

    try doc.setValueSegments(target.segments, value);
    var aw2: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw2.writer);
    if (!std.mem.eql(u8, aw2.written(), emitted1)) {
        return fail(ctx, "6-idempotence", "re-applying the same set produced different bytes");
    }
}

fn checkByteExactExceptValue(arena: Allocator, doc: *Document, pre_edit: PreEditSpan, ctx: *Ctx) !void {
    var aw: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw.writer);
    const output = aw.written();
    const old_span_len = pre_edit.end - pre_edit.start;

    if (output.len + old_span_len < pre_edit.doc_source_len) {
        return fail(ctx, "5b-byte-exact-except-value", "output is shorter than possible for a pure value replace");
    }
    const new_span_len = output.len + old_span_len - pre_edit.doc_source_len;
    if (pre_edit.start + new_span_len > output.len) {
        return fail(ctx, "5b-byte-exact-except-value", "value span arithmetic landed out of bounds");
    }
    if (!std.mem.eql(u8, output[0..pre_edit.start], doc.source[0..pre_edit.start])) {
        return fail(ctx, "5b-byte-exact-except-value", "bytes before the replaced value changed");
    }
    if (!std.mem.eql(u8, output[pre_edit.start + new_span_len ..], doc.source[pre_edit.end..])) {
        return fail(ctx, "5b-byte-exact-except-value", "bytes after the replaced value changed");
    }
}

fn runRemoveCase(arena: Allocator, rng: std.Random, model: *Model, source: []const u8, ctx: *Ctx) !void {
    var doc = try parseOrReport(arena, source, ctx);
    const leaf = model.leaves.items[rng.uintLessThan(usize, model.leaves.items.len)];
    ctx.target_desc = try formatSegments(arena, leaf.segments);
    ctx.value_desc = try formatValueDebug(arena, leaf.value);

    doc.removeSegments(leaf.segments) catch
        return fail(ctx, "7-remove-round-trip", "removeSegments on an existing leaf unexpectedly errored");

    var aw: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw.writer);
    const output = aw.written();

    const reparsed = parser_mod.parse(arena, output, .{}) catch
        return fail(ctx, "7-reparse-clean", "output after remove failed to reparse");

    if (resolveSegments(reparsed, leaf.segments) != null) {
        return fail(ctx, "7-remove-absent", "removed path still resolves after removal");
    }

    for (model.leaves.items) |other| {
        if (segEq(other.segments, leaf.segments)) continue;
        const sib = resolveSegments(reparsed, other.segments) orelse
            return fail(ctx, "7-sibling-preservation", "a sibling leaf is missing after remove");
        if (!Value.eql(sib, other.value)) {
            return fail(ctx, "7-sibling-preservation", "a sibling leaf's value changed after remove");
        }
    }

    for (model.comments.items) |c| {
        if (std.mem.indexOf(u8, output, c) == null) {
            return fail(ctx, "7-comment-preservation", "a comment present in source is missing after remove");
        }
    }
}

// debug replay helpers

fn formatSegments(arena: Allocator, segments: []const []const u8) ![]const u8 {
    return std.mem.join(arena, " / ", segments);
}

fn formatValueDebug(arena: Allocator, value: Value) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    encoder.writeInlineValue(&aw.writer, value) catch return "<unprintable>";
    return aw.written();
}

fn fail(ctx: *const Ctx, label: []const u8, detail: []const u8) error{PropertyViolation} {
    std.debug.print(
        "document property battery FAILURE\n  case: {d}  seed: {d}\n  invariant: {s}\n  detail: {s}\n  target path: {s}\n  value: {s}\n  source:\n{s}\n",
        .{ ctx.case_index, ctx.seed, label, detail, ctx.target_desc, ctx.value_desc, ctx.source },
    );
    return error.PropertyViolation;
}
