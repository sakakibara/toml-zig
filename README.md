# toml

A complete TOML 1.1 implementation for Zig.

- **100% spec compliance** - passes every test in the official [toml-lang/toml-test](https://github.com/toml-lang/toml-test) suite (valid, invalid, and encoder) against TOML 1.1.0.
- **Typed decoding** - `parseInto(Config, arena, src, .{})` deserializes straight into your Zig struct via comptime reflection, in a single streaming pass with no intermediate value tree for most shapes. No annotations, no codegen.
- **Lossless document model** - edit a TOML file in place; comments, formatting, ordering preserved. Add/remove/reorder sections, edit sub-keys inside inline tables.
- **Byte-precise spans** - every value (top-level or deeply nested) carries an exact u64 byte range; line/col are derived on demand.
- **Streaming input** - parse from any `std.Io.Reader`. A separate token-stream API yields lex events for incremental tooling.
- **Fast** - single-pass recursive-descent, arena-allocated, zero-copy strings/keys where possible. Run `zig build bench` to measure on your hardware.
- **Portable** - builds on every target Zig supports (verified across 20+ targets in CI). No allocator surprises, no global state.
- **No dependencies** - pure Zig, libc-free.

```zig
const toml = @import("toml");

const Config = struct {
    title: []const u8,
    port: u16 = 8080,
    server: struct {
        host: []const u8,
        tls: bool = false,
    },
};

var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();
const arena = arena_state.allocator();

const cfg = try toml.parseInto(Config, arena, src, .{});
```

## Install

Requires Zig 0.16.0 or newer.

```sh
zig fetch --save git+https://github.com/sakakibara/toml-zig
```

In `build.zig`:

```zig
const toml = b.dependency("toml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toml", toml.module("toml"));
```

## Quickstart

### Dynamic parse

```zig
const std = @import("std");
const toml = @import("toml");

var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();
const arena = arena_state.allocator();

const v = try toml.parse(arena,
    \\title = "example"
    \\
    \\[server]
    \\port = 8080
, .{});

const port = v.getT(u16, "server.port") orelse 8080;
```

### Typed decoding

Decode straight into a struct. Field defaults are honored; optionals become
`null` when absent; unknown TOML keys raise `error.UnknownField` (opt out
with `.ignore_unknown_fields = true`).

```zig
const Config = struct {
    title: []const u8,
    port: u16 = 8080,
    nick: ?[]const u8,
    tags: []const []const u8,
    server: struct {
        host: []const u8,
        tls: bool = false,
    },
};

const cfg = try toml.parseInto(Config, arena, src, .{});
```

Supported types: `bool`, all int/float widths (overflow-checked), `[]const u8`,
slices, fixed-size arrays, optionals, nested structs, enums (string or integer
tag), `union(enum)` (tagged-union with the `toml_tag` annotation -- see below),
`Date`/`Time`/`DateTime`. Embed a raw `toml.Value` to keep dynamic
substructures.

### Annotation-driven decode and encode

Decode supports the following `pub const` annotations on the target struct:

```zig
const Server = struct {
    pub const toml_rename = .{ .listen_addr = "listen-addr" };
    pub const toml_flatten = .{"common"};
    pub const toml_skip = .{"runtime"};

    listen_addr: []const u8,
    common: CommonConfig, // sub-fields decode from parent table
    runtime: u32 = 0,     // excluded from decode/encode
};
```

For custom (de)serialization of a type, provide either or both of these
hooks on the type:

```zig
pub fn fromToml(arena: Allocator, value: Value, options: ParseOptions) DecodeError!Self;
pub fn toToml(self: Self, arena: Allocator) Allocator.Error!Value;
```

Tagged unions decode/encode by a TOML discriminator field:

```zig
const Plugin = union(enum) {
    pub const toml_tag = "kind";

    http: HttpConfig,
    grpc: GrpcConfig,
};
```

`kind = "http"` in TOML picks the `.http` variant; remaining fields
decode as `HttpConfig`. For variant-name overrides, use `toml_rename`
on the union itself.

For symmetric encoding of typed values (consulting the same
annotations), use `toml.encodeTyped(w, value, arena, options)`:

```zig
const cfg: Config = .{ .listen_addr = "0.0.0.0" };
try toml.encodeTyped(w, cfg, arena, .{});
```

Annotations are looked up on `@TypeOf(value)`, so bind anonymous
literals to a typed const as above; a bare `.{ ... }` literal carries
no `toml_*` decls.

The existing `toml.encode(w, value, options)` still applies for
hand-built `Value` trees. `options.sort_keys` emits keys in ascending
order within each structural group (default keeps insertion order).

### Editing (lossless document model)

Read a TOML file, edit values in place, emit byte-identical output when
unmodified or minimal-diff output when modified. Comments, blank lines,
key formatting, and section ordering are all preserved.

```zig
var doc = try toml.Document.parse(arena, src, .{});

const port = doc.getT(u16, "server.port") orelse 8080;

// `set` is comptime-dispatched on the Zig type:
try doc.set("server.port", @as(u16, 9999));
try doc.set("server.tls", true);
try doc.set("server.host", "0.0.0.0");
try doc.set("metrics.endpoint", "/metrics");

// Escape hatch: splice in a literal TOML value string.
try doc.setLiteral("server.tags", "[\"alpha\", \"beta\"]");

try doc.addCommentBefore("server.port", "default port");
try doc.setTrailingComment("server.tls", "production only");

try doc.moveSection("client", .before, "server");

var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
try doc.emit(&aw.writer);
```

Sub-key edits inside inline tables are also byte-minimal-diff lossless:
only the changed value's bytes move; surrounding whitespace, key
order, trailing commas, and inline comments are preserved.

```toml
# Before:
point = { x = 1, y = 2 }
# doc.setLiteral("point.x", "99") produces:
point = { x = 99, y = 2 }
```

`Document.empty(arena, options)` bootstraps a document with no source
bytes at all -- the "file doesn't exist yet" case. And `setValueSegments`
/ `setSegments` / `removeSegments` take a path as pre-split,
already-unescaped key segments instead of a dotted string, so a key
containing a literal `.` is addressed unambiguously:

```zig
var doc = try toml.Document.empty(arena, .{});
try doc.setSegments(&.{ "host", "example.com" }, "1.2.3.4");
// "host".example.com is unambiguous: one literal key "example.com"
// under table "host", not "example" -> "com" nested two levels deep.
```

Missing intermediate tables along a path are created too, whichever
setter is used: `set("a.b.c", v)` on a document lacking `a` or `a.b`
creates them as one combined `[a.b]` header (TOML's implicit-super-table
rule). Array elements are still only ever replaced, never created.

### Source spans

A `Span` stores u64 byte offsets (`start`, `end`); line and column are
derived on demand with `span.lineCol(src)`.

```zig
var spans: toml.Spans = .empty;
const v = try toml.parse(arena, src, .{ .spans = &spans });

if (v.locate(spans, "server.port")) |port| {
    const lc = port.span.lineCol(src);
    std.debug.print("port {d} at line {d} col {d}\n",
        .{ port.value.integer, lc.line, lc.col });
}
```

Array elements use `[N]` index segments, e.g. `users[0].name`.

### Streaming input

```zig
var stdin_buf: [4096]u8 = undefined;
var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
const v = try toml.parseReader(arena, &stdin_reader.interface, .{});
```

### Reader-backed streaming (table-at-a-time)

Parse a `std.Io.Reader` one statement-unit at a time without buffering the
whole document. Memory is bounded to ONE unit plus a small pull buffer,
regardless of total stream length.

```zig
// ValueStream shape .array_of_tables: one Value per [[x]] element.
var r: std.Io.Reader = .fixed(src);
var vs = toml.ValueStream.fromReader(gpa, &r, .{}, .array_of_tables);
defer vs.deinit();

var item_arena: std.heap.ArenaAllocator = .init(gpa);
defer item_arena.deinit();

while (try vs.next(item_arena.allocator())) |v| {
    const name = v.getT([]const u8, "name") orelse "?";
    std.debug.print("{s}\n", .{name});
    _ = item_arena.reset(.retain_capacity); // free previous element, keep capacity
}
```

Three shapes control what each `next(item_arena)` yields:

- `.tables` - one `Value` per statement-unit in document order (leading
  top-level key-values, each `[table]` section, each `[[array-of-tables]]`
  element).
- `.array_of_tables` - one `Value` per `[[x]]` element only; plain `[table]`
  sections and leading root keys are skipped. The streaming analog of NDJSON.
- `.whole` - exactly one `Value` holding the full reconstructed document tree,
  then null. A convenience for "I want a normal `parse` but from a reader";
  memory is NOT bounded to one unit with this shape.

For event-level access, use `EventReader`:

```zig
// EventReader: one parser event at a time across the whole stream.
var r: std.Io.Reader = .fixed(src);
var er = toml.EventReader.fromReader(gpa, &r, .{});
defer er.deinit();

while (try er.next()) |ev| {
    switch (ev.kind) {
        .table_header => |path| std.debug.print("[{s}]\n", .{path}),
        .key => |k| std.debug.print("  {s}\n", .{k}),
        .value_string => |s| std.debug.print("  = {s}\n", .{s}),
        else => {},
    }
}
```

To compose a unit into a `Value` at a header boundary without walking its
individual key/value events, call `materialize()` immediately after `next()`
returns a `table_header` or `array_of_tables_header` event:

```zig
while (try er.next()) |ev| {
    if (ev.kind != .array_of_tables_header) continue;
    const v = try er.materialize(item_arena.allocator());
    // use v; then reset item_arena
    _ = item_arena.reset(.retain_capacity);
}
```

#### Event kinds

| Kind | Meaning |
| --- | --- |
| `table_header` | `[a.b]` header; payload is the decoded dotted path. |
| `array_of_tables_header` | `[[a.b]]` header; payload is the decoded dotted path. |
| `key` | A key under the current unit; payload is the decoded name. |
| `value_string` / `value_integer` / `value_float` / `value_bool` / `value_datetime` / `value_date` / `value_time` | A scalar value. |
| `array_begin` / `array_end` | An inline array open/close. |
| `inline_table_begin` / `inline_table_end` | An inline table open/close. |
| `end_of_input` | Final event; `next()` returns null after. |

#### Borrow contract

Event payload slices (`table_header`, `key`, `value_string`, ...) borrow the
internal unit buffer and are valid ONLY until the next unit boundary (the
`next()` call that crosses into the following unit, or a call to
`materialize()`). Copy any slice that must outlive the unit.

#### Error / recovery policy

The per-unit error recovery policy mirrors buffered `parse`:

- `options.errors == null` (default): a parse error on one unit terminates
  the stream. The error is returned from `next()` and subsequent calls return
  null.
- `options.errors != null`: a parse error on one unit is appended to the
  errors sink, the bad unit is skipped, and the stream continues to the
  following unit.

#### Memory bound

The internal buffer grows to hold at most ONE unit plus a small pull chunk
(4 KiB). A 100 000-element array-of-tables stream uses the same peak buffer
as a 10-element stream, provided each element fits in memory.

**Honest caveat:** the `whole` shape retains the full reconstructed document
tree in `item_arena` throughout the drain -- its memory scales with the whole
document, not one unit. For bounded-memory streaming, use `.tables` or
`.array_of_tables`.

See `examples/event_stream.zig` for a runnable walk-through of all three
entry points.

### Token stream (for tooling)

For incremental syntax highlighters, format-preserving editors, or any
tool that wants to walk the source token-by-token without building a
Value tree:

```zig
var t: toml.Tokenizer = .init(src);
while (t.next()) |tok| switch (tok.kind) {
    .key_segment => highlight(.key, tok.span),
    .value_string, .value_integer, .value_float, .value_bool, .value_datetime => highlight(.value, tok.span),
    .comment => highlight(.comment, tok.span),
    .header_open, .header_close, .header_array_open => highlight(.punct, tok.span),
    else => {},
};
```

### Diagnostics on parse error

```zig
var errs: std.ArrayList(toml.Diagnostic) = .empty;
defer errs.deinit(arena);
const v = toml.parse(arena, src, .{ .errors = &errs }) catch {
    if (errs.items.len > 0) try errs.items[0].render(w, src);
    return;
};
```

For rustc-style multi-line output with source-line excerpts, caret
underlines, and `did you mean` suggestions:

```zig
for (errs.items) |d| try d.renderRich(stderr_writer, src);
```

The parser collects every error in one pass when `errors` is set, up
to 100 diagnostics per parse. Set it to `null` for single-error mode
(bail on first error, no diagnostic captured).

## API surface

### Functions

| Function | Purpose |
| --- | --- |
| `parse(arena, src, options)` | Dynamic parse to a `Value` tree. |
| `parseReader(arena, reader, options)` | Reader-input variant. |
| `parseInto(T, arena, src, options)` | Decode straight into an instance of `T`. |
| `parseIntoReader(T, arena, reader, options)` | Reader-input variant of `parseInto`. |
| `decode(T, arena, value, options)` | Decode an existing `Value` into `T`. |
| `encode(w, value, options)` | Emit canonical TOML to `*std.Io.Writer` (`options.sort_keys` to sort keys). |
| `encodeTyped(w, value, arena, options)` | Emit TOML from a typed Zig struct, consulting `toml_*` annotations. |
| `Document.parse(arena, src, options)` | Lossless parse for the document model. |
| `Document.empty(arena, options)` | Bootstrap a document with no source bytes. |
| `DateTime.parse(literal)` | Parse a single date/time/datetime literal. |
| `Date.parse(literal)` / `Time.parse(literal)` | Parse a date or time literal. |
| `Tokenizer.init(src)` / `.next()` | Lexer-level token stream for tooling. |

#### Streaming (reader-backed, table-at-a-time)

| Type / method | Purpose |
| --- | --- |
| `EventReader.fromReader(gpa, reader, options)` | Create a reader-backed streaming event reader. |
| `er.next()` | Return the next `Event`, or null at stream end. |
| `er.materialize(arena)` | At a `table_header` / `array_of_tables_header`: compose the whole current unit into a `Value`. |
| `er.diagnostic()` | Return the most recent per-unit error diagnostic, if any. |
| `er.bufCapacity()` | Return the internal buffer's allocated capacity (bytes); for benchmarks and tests. |
| `ValueStream.fromReader(gpa, reader, options, shape)` | Create a reader-backed value stream with the given `Shape`. |
| `vs.next(item_arena)` | Compose and return the next `Value`, or null at stream end. |

### Types

`Value`, `Date`, `Time`, `DateTime`, `Span`, `Spans`, `Diagnostic`,
`ParseOptions`, `Error`, `ReaderError`, `DecodeError`, `EncodeError`,
`Document`,
`Document.Position`, `document.Error`, `Tokenizer`, `Token`, `TokenKind`,
`EventReader`, `ValueStream`, `ValueStream.Shape`, `Event`, `Event.Kind`,
`StreamError`.

Generated reference docs are published at
**https://sakakibara.github.io/toml-zig/**.

Building locally (Zig's docs viewer is WASM-based and must be served over
HTTP, not opened as a `file://` URL):

```sh
zig build docs
cd zig-out/docs && python3 -m http.server 8000
# then visit http://localhost:8000/
```

## Build commands

```sh
zig build test           # unit + conformance tests
zig build fuzz           # random-input fuzzer
zig build bench          # microbenchmarks (ReleaseFast)
zig build docs           # generate reference docs
zig build examples       # build all examples
zig build example-basic  # run a specific example (basic, typed, edit, spans, event_stream)
```

## Spec conformance

Validated against [toml-lang/toml-test](https://github.com/toml-lang/toml-test) v2.2.0 with the `-toml=1.1` flag:

```
  valid tests: 214 passed,  0 failed
encoder tests: 214 passed,  0 failed
invalid tests: 467 passed,  0 failed
```

Reproduce:

```sh
zig build
toml-test test -toml=1.1 \
  -decoder=zig-out/bin/toml-test-decoder \
  -encoder=zig-out/bin/toml-test-encoder
```

(`toml-test` itself is an external Go binary; install it from the
[toml-test releases](https://github.com/toml-lang/toml-test/releases).)

## Performance

Run the bench yourself on your hardware with your inputs:

```sh
zig build bench
```

The harness reports min/p50/p99/max latency and throughput across multiple
samples with explicit warmup. See `bench/main.zig`.

On an Apple M1 Max (aarch64-macos), Zig 0.16.0, ReleaseFast -- p50
latency, median of ten runs, cross-run spread below 8% per cell:

| Benchmark | small (1.1 KB) | medium (21 KB) | large (113 KB) |
| --- | --- | --- | --- |
| parse | 7.11 us, 150 MB/s | 78.3 us, 265 MB/s | 1.06 ms, 102 MB/s |
| encode | 1.97 us, 541 MB/s | 21.1 us, 980 MB/s | 231 us, 468 MB/s |

The fixtures are a package manifest (small), a Cargo-style lock file
(medium), and a 10k-table document (large); see `bench/fixtures.zig`.

The hot path uses SIMD basic-string scanning and SIMD encoder escape
scanning (`@Vector(16, u8)`) plus a hand-rolled fast-path decimal
integer parser. The biggest wins are on string-heavy inputs (medium
parse, medium encode). See `CHANGELOG.md` for details.

## Memory model

`parse` and friends accept an `Allocator` (call it the parse arena). All
values, table keys, and any non-zero-copy strings live in that arena. To
free everything, deinit the arena - no need to walk the tree.

Strings parsed from the input may be zero-copy slices into the source
buffer when no escape processing is needed; otherwise they are
arena-allocated copies. Either way, keep the input alive for as long as
the parse tree is in use.

The document model also takes an arena. It owns the source string, the
item list, and any edits.

## Limits

Nesting depth is bounded to guard against stack overflow on deeply nested
untrusted input. `ParseOptions.max_depth` (default 128) caps array and
inline-table nesting; exceeding it returns `error.NestingTooDeep` rather
than overflowing the stack. The encoder applies the same bound when
writing a `Value` tree. Raising `max_depth` trades stack for depth - each
level costs roughly 1-1.5 KB of stack, so values in the thousands can
exhaust the stack before the guard fires.

## Examples

See `examples/` for runnable samples:

- `basic.zig` - dynamic parse and field access
- `typed.zig` - decode straight into a Zig struct
- `edit.zig` - lossless document edit + emit
- `spans.zig` - source spans for tooling and validators
- `event_stream.zig` - reader-backed streaming: EventReader, ValueStream, and materialize
