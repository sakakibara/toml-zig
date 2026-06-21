# toml

A complete TOML 1.1 implementation for Zig.

- **100% spec compliance** - passes every test in the official [toml-lang/toml-test](https://github.com/toml-lang/toml-test) suite (decoder, encoder, and invalid) against TOML 1.1.0.
- **Typed decoding** - `parseInto(Config, arena, src)` deserializes straight into your Zig struct via comptime reflection. No annotations, no codegen.
- **Lossless document model** - edit a TOML file in place; comments, formatting, ordering preserved. Add/remove/reorder sections, edit sub-keys inside inline tables.
- **Byte-precise spans** - every value (top-level or deeply nested) carries an exact byte range and line/col, populated on demand.
- **Streaming input** - parse from any `std.Io.Reader`. A separate token-stream API yields lex events for incremental tooling.
- **Fast** - single-pass recursive-descent, arena-allocated, zero-copy strings/keys where possible. Run `zig build bench` to measure on your hardware.
- **Portable** - builds on every target Zig supports (verified across 20+ in CI). No allocator surprises, no global state.
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

var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();

const v = try toml.parse(arena.allocator(),
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
annotations), use `toml.encodeTyped(T, value, w, arena)`:

```zig
try toml.encodeTyped(Config, cfg, w, arena);
```

The existing `toml.encode(w, value: Value)` still applies for
hand-built `Value` trees.

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

### Source spans

```zig
var spans: toml.Spans = .empty;
const v = try toml.parse(arena, src, .{ .spans = &spans });

if (v.locate(spans, "server.port")) |port| {
    std.debug.print("port {d} at line {d} col {d}\n",
        .{ port.value.integer, port.span.line, port.span.col });
}
```

Array elements use `[N]` index segments, e.g. `users[0].name`.

### Streaming input

```zig
var stdin_buf: [4096]u8 = undefined;
var stdin_reader = std.Io.File.stdin().readerStreaming(&stdin_buf);
const v = try toml.parseReader(arena, &stdin_reader.interface, .{});
```

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
    if (errs.items.len > 0) std.debug.print("{f}\n", .{errs.items[0]});
    return;
};
```

For rustc-style multi-line output with source-line excerpts, caret
underlines, and `did you mean` suggestions:

```zig
for (errs.items) |d| try d.formatRich(stderr_writer, src);
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
| `encode(w, value)` | Emit canonical TOML to `*std.Io.Writer`. |
| `Document.parse(arena, src, options)` | Lossless parse for the document model. |
| `DateTime.parse(literal)` | Parse a single date/time/datetime literal. |
| `Date.parse(literal)` / `Time.parse(literal)` | Parse a date or time literal. |
| `Tokenizer.init(src)` / `.next()` | Lexer-level token stream for tooling. |

### Types

`Value`, `Date`, `Time`, `DateTime`, `Span`, `Spans`, `Diagnostic`,
`ParseOptions`, `Error`, `ReaderError`, `EncodeError`, `Document`,
`Document.Position`, `document.Error`, `Tokenizer`, `Token`, `TokenKind`.

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
zig build example-basic  # run a specific example (basic, typed, edit, spans)
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

On aarch64-linux, ReleaseFast, this lands at roughly:

| Fixture | Size | Parse p50 | Throughput | Encode p50 | Throughput |
| --- | --- | --- | --- | --- | --- |
| small (manifest) | 1.1 KB | 4187 ns | 268 MB/s | 1782 ns | 629 MB/s |
| medium (cargo-lock) | 21 KB | 67330 ns | 322 MB/s | 19775 ns | 1098 MB/s |
| large (10k tables) | 113 KB | 784447 ns | 144 MB/s | 193052 ns | 587 MB/s |

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
