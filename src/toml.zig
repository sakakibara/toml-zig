//! TOML 1.1 parser and encoder.
//!
//! ```zig
//! const toml = @import("toml");
//!
//! var arena: std.heap.ArenaAllocator = .init(gpa);
//! defer arena.deinit();
//!
//! // Parse
//! const v = try toml.parse(arena.allocator(), src, .{});
//!
//! // Access
//! const name = v.table.get("name").?.string;
//!
//! // Encode
//! var aw: std.Io.Writer.Allocating = .init(gpa);
//! defer aw.deinit();
//! try toml.encode(&aw.writer, v);
//! const out = aw.written();
//! ```

const std = @import("std");
const parser_mod = @import("parser.zig");
const encoder_mod = @import("encoder.zig");
const value_mod = @import("value.zig");
const datetime_mod = @import("datetime.zig");
const decode_mod = @import("decode.zig");

/// Unified error set spanning parse + decode. Encode has its own set
/// (`EncodeError`) since it operates on already-built Values.
pub const Error = error{
    // From parser
    TomlParseError,
    NestingTooDeep,
    OutOfMemory,
    // From decode
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
    Overflow,
};

/// Reader-input variants additionally surface the reader's allocation
/// failure path.
pub const ReaderError = Error || std.Io.Reader.LimitedAllocError;

/// All knobs for `parse` / `parseReader` / `parseInto` / `parseIntoReader`.
/// Default is `.{}` (no error capture, no spans, strict struct decode).
pub const ParseOptions = parser_mod.ParseOptions;

/// Lossless document model: parse, edit, emit byte-identical when
/// unmodified. See `src/document.zig`.
pub const document = @import("document.zig");
/// Lossless document model. See `src/document.zig`.
pub const Document = @import("document.zig").Document;

/// Token-level lexer for tooling. See `src/tokenizer.zig`.
pub const Tokenizer = @import("tokenizer.zig").Tokenizer;
pub const Token = @import("tokenizer.zig").Token;
pub const TokenKind = @import("tokenizer.zig").Kind;

pub const Value = value_mod.Value;
pub const DateTime = value_mod.DateTime;
pub const Date = value_mod.Date;
pub const Time = value_mod.Time;
pub const Span = value_mod.Span;
pub const Spans = value_mod.Spans;

pub const Diagnostic = parser_mod.Diagnostic;

/// Reader-backed, table-at-a-time streaming event reader. See `src/stream.zig`.
pub const stream = @import("stream.zig");
pub const EventReader = stream.EventReader;
pub const Event = stream.Event;
pub const StreamError = stream.StreamError;
/// Reader-backed, table-at-a-time value stream. Shape controls what each `next()` yields.
pub const ValueStream = stream.ValueStream;

/// Parse a TOML document from a byte slice. See `ParseOptions` for the
/// option fields.
///
/// Inputs of any in-memory size parse fine: tokenizer/parser offsets and
/// `Span` byte offsets are u64, so there is no 4 GiB cap on plain parses,
/// the opt-in spans map (`ParseOptions.spans`), or the document model.
pub fn parse(arena: std.mem.Allocator, src: []const u8, options: ParseOptions) Error!Value {
    return parser_mod.parse(arena, src, options);
}

/// Reader-input variant of `parse`. Pulls the full input into arena
/// memory first; TOML's grammar requires the whole document to be
/// available before the value tree is complete.
pub fn parseReader(arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!Value {
    return parser_mod.parseReader(arena, reader, options);
}

pub const EncodeError = encoder_mod.EncodeError;
pub const encode = encoder_mod.encode;
pub const encodeTyped = encoder_mod.encodeTyped;

pub const DecodeError = decode_mod.DecodeError;
/// Decode a `Value` tree into an instance of `T`.
pub const decode = decode_mod.decode;

/// Parse TOML and decode straight into an instance of `T`.
pub fn parseInto(comptime T: type, arena: std.mem.Allocator, src: []const u8, options: ParseOptions) Error!T {
    const value = try parse(arena, src, options);
    return decode(T, arena, value, options);
}

/// Reader-input variant of `parseInto`.
pub fn parseIntoReader(comptime T: type, arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!T {
    const value = try parseReader(arena, reader, options);
    return decode(T, arena, value, options);
}

test {
    _ = parser_mod;
    _ = encoder_mod;
    _ = value_mod;
    _ = datetime_mod;
    _ = decode_mod;
    _ = document;
    _ = @import("tokenizer.zig");
    _ = @import("conformance.zig");
    _ = @import("levenshtein.zig");
    _ = @import("stream.zig");
}

test "parseReader matches parse for the same document" {
    const std_testing = std.testing;
    const src =
        \\title = "TOML"
        \\count = 42
        \\nested = { a = 1, b = 2 }
    ;
    var arena_a: std.heap.ArenaAllocator = .init(std_testing.allocator);
    defer arena_a.deinit();
    const from_slice = try parse(arena_a.allocator(), src, .{});

    var arena_b: std.heap.ArenaAllocator = .init(std_testing.allocator);
    defer arena_b.deinit();
    var reader: std.Io.Reader = .fixed(src);
    const from_reader = try parseReader(arena_b.allocator(), &reader, .{});

    try std_testing.expect(Value.eql(from_slice, from_reader));
}

test "parseIntoReader decodes from a reader" {
    const std_testing = std.testing;
    const Config = struct { title: []const u8, count: u32 };
    const src =
        \\title = "TOML"
        \\count = 42
    ;
    var arena: std.heap.ArenaAllocator = .init(std_testing.allocator);
    defer arena.deinit();
    var reader: std.Io.Reader = .fixed(src);
    const cfg = try parseIntoReader(Config, arena.allocator(), &reader, .{});
    try std_testing.expectEqualStrings("TOML", cfg.title);
    try std_testing.expectEqual(@as(u32, 42), cfg.count);
}
