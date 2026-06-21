# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-06-21

### Added

- `ParseOptions.max_depth` (default 128) caps array and inline-table
  nesting depth; exceeding it returns the new `error.NestingTooDeep`.

### Fixed

- Encoder: size the float-formatting buffer for full-precision decimal
  `f64`, fixing a fixed-size buffer that could be too small for some
  values.
- Parser: remove the fixed-length cap on float literals, which had
  rejected long but otherwise-valid float tokens.
- `parseReader` / `parseIntoReader`: correct `ReaderError` to
  `std.Io.Reader.LimitedAllocError`; the previous
  `std.Io.Reader.AllocError` does not exist on Zig 0.16.

### Security

- Bound recursion depth in both the parser and the encoder so deeply
  nested untrusted input fails with `error.NestingTooDeep` instead of
  overflowing the stack.

## [0.1.0] - 2026-05-16

Initial release. TOML 1.1 parser, encoder, lossless document model,
typed struct decoding, and tooling.

### Highlights

- TOML 1.1 parser and encoder. Conformance against upstream `toml-test`
  v2.2.0: 214/214 valid, 467/467 invalid, 214/214 encoder. CI runs the
  full corpus on every push across Linux x86_64/aarch64, macOS aarch64,
  and Windows x86_64.
- Lossless `Document` editing. Edits to existing keys, including
  sub-keys inside inline tables, preserve interior whitespace, key
  order, trailing commas, inline comments, and multi-line formatting.
- Typed decode (`parseInto`, `parseIntoReader`) and typed encode
  (`encodeTyped`). Struct annotations: `toml_rename`, `toml_flatten`,
  `toml_skip`, `toml_tag` for tagged-union (de)serialization, plus
  `fromToml` / `toToml` hooks for custom (de)serialization.
- Rich diagnostics. Byte ranges, TOML-path context, did-you-mean
  suggestions for typo'd struct fields and bareword keywords,
  multi-error recovery (up to 100 diagnostics per parse), and a
  rustc-style `Diagnostic.formatRich` multi-line renderer with line
  excerpt, caret underline, notes, and suggestion.
- Single `ParseOptions` bag for diagnostics, span tracking, and decode
  strictness; default `.{}`. Unified `Error` set spanning parse and
  decode failures.
- `Value` helpers: `Value.get` / `Value.getT` dotted-path lookup with
  `[N]` array indexing (`users[0].name`, `matrix[3][7]`), `makeTable`
  / `makeArray` / `fromString` construction helpers, `tablePut` /
  `tableGet` / `arrayAppend` container helpers, `Value.locate` for
  paired value + span lookup, and `Value.clone` for deep-copy across
  arenas.
- `Document` helpers: `Document.set(path, value: anytype)` for
  comptime-dispatched typed write, `Document.getT(T, path)` for typed
  read, `setLiteral` for raw TOML escape-hatch writes, `Document.has`
  and `Document.removeCommentBefore` / `removeCommentAfter` for
  comment management, and `Document.Position` for `moveSection`
  placement.
- Date / Time / DateTime literal parsers (`Date.parse`, `Time.parse`,
  `DateTime.parse`) with nested `ParseError` and (for `DateTime`) a
  `Parsed` discriminated alias.
- Arena-only memory model. `arena.deinit()` is the only cleanup call;
  no per-value or per-document `deinit` to track.

### Performance

Benchmarks captured on aarch64-linux, ReleaseFast, p50 median across 3
runs:

| Fixture | Size | Parse p50 | Throughput | Encode p50 | Throughput |
| --- | --- | --- | --- | --- | --- |
| small (manifest) | 1.1 KB | 4187 ns | 268 MB/s | 1782 ns | 629 MB/s |
| medium (cargo-lock) | 21 KB | 67330 ns | 322 MB/s | 19775 ns | 1098 MB/s |
| large (10k tables) | 113 KB | 784447 ns | 144 MB/s | 193052 ns | 587 MB/s |

The hot path uses a SIMD basic-string scanner (`@Vector(16, u8)`), a
SIMD escape scanner in the encoder (`scanQuotedStringPlain`), a
hand-rolled fast-path decimal integer parser (`parseDecFast`), and
inlined parser primitives (`peek`, `peekAt`, `advance`, `match`,
`eof`).

[Unreleased]: https://github.com/sakakibara/toml-zig/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/sakakibara/toml-zig/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sakakibara/toml-zig/releases/tag/v0.1.0
