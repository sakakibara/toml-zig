# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Document.setValueSegments` / `Document.setSegments` /
  `Document.removeSegments`: segment-taking twins of `setValue` / `set` /
  `remove` that address a path as pre-split, already-unescaped key
  segments (e.g. `&.{ "host", "example.com" }`) instead of a dotted
  string, so a key containing a literal `.` is addressed unambiguously.
  A segment that isn't a valid bare TOML key is quoted on emit. Missing
  intermediate tables along the path are created the same way `set`
  already creates them for a dotted string path (one combined `[a.b]`
  header, via TOML's implicit-super-table rule). Array elements are
  still never created, only replaced: an `[N]` index anywhere in the
  path is `error.UnsupportedPath`.
- `Document.empty`: bootstrap a document with no source bytes (the "file
  doesn't exist yet" case). TOML already treats empty input as valid (an
  empty table), so this is a thin, explicitly-named alias for
  `Document.parse(arena, "", options)`.

### Fixed

- `set` / `setValue` / `setLiteral` / `remove` now resolve a path against
  decoded key *segments* internally instead of a lossily `.`-joined
  string, so a document containing both a literally-dotted key (e.g.
  `"a.b" = 1`) and an unrelated nested table (`[a.b]` i.e. table `a`'s
  key `b`) can no longer have one edit silently target the other.

## [0.4.0] - 2026-07-05

### Changed

- **BREAKING:** `encode` and `encodeTyped` take an `EncodeOptions` argument.
  Migrate `encode(w, v)` to `encode(w, v, .{})` and `encodeTyped(w, v, arena)`
  to `encodeTyped(w, v, arena, .{})`. Default options reproduce the prior
  output byte-for-byte.

### Added

- `EncodeOptions.sort_keys`: emit keys in ascending byte-lexicographic order
  within each structural group (a table's key/values sorted, then its
  sub-table headers sorted), recursively, on both the `Value` and typed
  paths. TOML's key-values-before-headers rule is preserved. Default `false`
  keeps insertion / declaration order. Ordering only, not RFC 8785 (JCS)
  canonicalization. A flattened struct field's members sort within their own
  group, not interleaved with the parent's fields.

## [0.3.1] - 2026-07-05

### Fixed

- 32-bit targets now compile. `u64` span offsets are cast to `usize` at
  slice-indexing and loop-index sites that failed to build where `usize`
  is 32-bit (`x86-linux`, `arm-linux`, `mips-linux`, `wasm32-wasi`, and
  other 32-bit targets). No API or behavior change on 64-bit targets.

## [0.3.0] - 2026-07-03

### Changed

- **BREAKING:** `encodeTyped(w, value, arena)` takes the writer first,
  matching `encode`, and takes the value as `anytype` (the type is
  `@TypeOf(value)`). Bind anonymous literals to a typed const before
  calling, or the type's `toml_*` annotation decls are not seen.
- **BREAKING:** `Diagnostic.format` / `Diagnostic.formatRich` are now
  `render` / `renderRich`, and both take the source bytes to derive
  line/col from the span. The renderer cannot keep the name `format`:
  that is the magic `{f}` method name in std formatting, whose required
  signature cannot carry `src`.
- **BREAKING:** `toml.Error` is exactly the parse error set
  (`TomlParseError`, `NestingTooDeep`, `OutOfMemory`); `parseInto` /
  `parseIntoReader` return `(Error || DecodeError)` /
  `(ReaderError || DecodeError)`. Code matching on error literals is
  unaffected.

- **BREAKING:** `Span` is now `{ start: u64, end: u64 }` -- byte offsets only,
  no stored `line`/`col`. The struct stays 16 bytes, and the 4 GiB cap is gone:
  spans address any in-memory buffer. Line and column are derived on demand
  from a span and the source via `span.lineCol(src) -> LineCol{ line, col }`
  (1-indexed; O(start), intended for occasional human-facing display, not
  bulk per-value use). This affects `Span`, the opt-in spans map
  (`ParseOptions.spans`), `Value.locate`, the public tokenizer `Token.span`,
  and the streaming `Event.span`, all of which now expose u64 offsets and no
  longer cap at 4 GiB. `Diagnostic` carries the offending `Span` instead of
  stored `line`/`col`/`range`; `Diagnostic.render`/`renderRich` now take the
  source bytes and derive line/col from the span. Plain parses, the spans
  map, and the document model are all uncapped.

### Added

- Reader-backed, table-at-a-time streaming API: `EventReader`, `ValueStream`
  (and the `StreamError` error set), all exported from the top-level `toml`
  module. The unit of streaming is one TOML statement-unit: the leading
  top-level key-values, a `[table]` section with its key-values, or a
  `[[array-of-tables]]` element with its key-values. `EventReader.fromReader`
  / `next` / `materialize` walk a `std.Io.Reader` event-by-event, framing one
  unit at a time and re-basing spans to absolute stream offsets.
  `ValueStream.fromReader` takes a `Shape` argument controlling what each
  `next(item_arena)` yields: `tables` (one `Value` per unit in document order,
  including the leading root-table unit); `array_of_tables` (one `Value` per
  `[[array-of-tables]]` element only -- the streaming analog of NDJSON);
  `whole` (exactly one `Value` holding the full reconstructed document tree,
  then null -- a convenience, not a bounded-memory stream). Memory is bounded
  to one unit plus a small pull buffer (4 KiB chunks) for the `tables` and
  `array_of_tables` shapes; the caller resets `item_arena` between calls to
  release the previous unit's allocation. The `whole` shape retains the entire
  reconstructed tree in `item_arena` throughout the drain -- its memory is
  proportional to the whole document, not one unit. Whole-stream duplicate
  detection (`[a]...[a]` and scalar/array-vs-table conflicts, including through
  array-of-tables) is threaded across every unit so streaming rejects exactly
  what buffered `parse` rejects. `EventReader.materialize(arena)` (valid
  immediately after a `table_header` or `array_of_tables_header` event)
  composes the whole current unit into a `Value` without stepping through its
  individual key/value events. `EventReader.bufCapacity()` exposes the internal
  buffer capacity for bounded-memory benchmarks and tests.
  `EventReader.diagnostic()` returns the most recent per-unit error diagnostic.
  Per-unit error recovery: with `options.errors` set, a malformed unit's
  diagnostic is appended to the sink and the unit is skipped, so `next()`
  continues to the following unit; without a sink the first error is terminal.
- `examples/event_stream.zig`: runnable walk-through of `EventReader`,
  `ValueStream` (shape `.array_of_tables`), and `materialize` against
  in-program TOML buffers.
- Bounded-memory streaming bench (`zig build bench`): streams 100 000 small
  `[[record]]` elements via `ValueStream` shape `.array_of_tables`, asserts the
  internal buffer peak `bufCapacity()` stays below 64 KiB (a few pull chunks),
  and prints peak capacity alongside throughput.
- Single-pass typed decode: `parseInto` dispatches parsed statements
  straight into the target type (no intermediate `Value` tree) for types
  without `Value` fields, `fromToml` hooks, tagged unions, optional
  sub-tables, or nested arrays-of-tables; on any error it re-decodes
  through the tree path so diagnostics are identical either way.

### Fixed

- Document editor: removing the first key-value no longer corrupts the
  editor index; setValue propagates nesting-depth errors instead of
  panicking; inline-table appends no longer duplicate trailing comments;
  quoted header keys containing `]` stay editable; edit addressability
  through arrays-of-tables matches `get`.
- Multi-line literal strings reject a lone CR (only CRLF pairs are
  valid breaks), matching the basic-string path.
- The standalone `Tokenizer` lexes commas, closers, and values inside
  inline arrays and tables with the documented kinds, and always makes
  progress on invalid input.
- `Value.set` / `Document.set`: narrowing an integer to the TOML i64 domain
  is checked (`error.IntegerOverflow`) instead of a safety panic (UB in
  ReleaseFast), and dotted-path recursion is bounded (`error.PathTooDeep`,
  limit 128, matching the parser) instead of overflowing the stack. Both
  errors are added to `Value.SetError` and `Document.Error`.
- Encoder: flattened fields and tagged-union payloads whose type contains a
  nested struct now emit their sub-tables; previously they were silently
  dropped from the output.
- Document model: the editor indexes key-value lines and headers by their
  DECODED dotted path, so quoted, literal, dotted, and escape-bearing keys
  are editable under the same identity `get` resolves; special keys are
  re-quoted on emit instead of written as raw decoded bytes; replace and
  insert are atomic (rolled back on a failed reparse); and the reparse
  buffer stays in the document arena, fixing a use-after-free under a
  non-arena allocator.
- Parser: a lone CR that is not part of a CRLF pair is rejected inside
  multi-line strings instead of being absorbed.
- Typed codec: decoding a finite float into a narrower float field that would
  overflow now returns `error.Overflow` (and `Value.getT` returns null)
  instead of silently yielding infinity; zero-length array fields (`[0]T`)
  compile; `encodeTyped` range-checks integer fields to the TOML i64 domain
  (`error.IntegerOverflow`) rather than emitting an out-of-range literal.
  `encodeTyped` now also handles optionals, enums (by tag name), fixed-size
  and non-`u8` slice arrays, optional sub-table fields, and slice/array of
  struct fields (emitted as `[[array-of-tables]]`), making typed encode TOTAL
  over the decoder's type surface: any type `parseInto` accepts now compiles
  and encodes, round-tripping when representable.
- Encoder: carriage returns in multi-line strings are escaped for byte-exact
  round-trip; keys are never emitted with multi-line quoting; negative NaN
  keeps its sign.
- Document model: comment and literal edits reject embedded newlines and
  terminators (injection guard); the parsed cache stays consistent, rolling
  back on a failed edit (including inline-table sub-key edits); array-index
  paths are guarded.
- Parser conformance: a sub-table defined under an array-of-tables element
  (`[a.sub]` after `[[a]]`) now scopes to the current element instead of being
  rejected as a redefinition; a quoted header key containing dots
  (`[a."b.c"]`) stays distinct from the dotted path (`[a.b.c]`); and a leading
  empty quoted key no longer collapses distinct paths. toml-zig passes the
  full toml-test 1.1 suite (214 valid, 467 invalid, 214 encoder).

### Security

- Bounded dotted-key, table-header, and inline-table/array nesting depth in
  both the parser and the document builder (`error.NestingTooDeep`), so deeply
  nested untrusted input fails cleanly instead of overflowing the stack.
  Hardened under multi-seed ReleaseSafe fuzzing.

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

[Unreleased]: https://github.com/sakakibara/toml-zig/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/sakakibara/toml-zig/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/sakakibara/toml-zig/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/sakakibara/toml-zig/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sakakibara/toml-zig/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sakakibara/toml-zig/releases/tag/v0.1.0
