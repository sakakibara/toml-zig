//! Conformance tests for the TOML 1.1 parser.
//!
//! Original tests covering every corner of the spec: strings (basic,
//! literal, multiline, escapes, UTF-8, BOM), integers (all radixes,
//! sign, underscores, overflow), floats (sign, exponent, inf/nan,
//! underscores), booleans, datetimes (offset, local, date-only,
//! time-only, fractional seconds), arrays (nesting, mixed types,
//! trailing commas), tables (headers, dotted keys, super-tables,
//! redefinition), inline tables, arrays-of-tables, comments, whitespace,
//! line endings, plus a regression group that pins past bugs.

const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const toml = @import("toml.zig");

/// Parse `src` and return a borrowed reference to the table root plus an
/// arena the caller owns. Caller must call `arena.deinit()` when done.
const Parsed = struct {
    arena: ArenaAllocator,
    value: toml.Value,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    pub fn root(self: *const Parsed) *const std.array_hash_map.String(toml.Value) {
        return &self.value.table;
    }

    pub fn get(self: *const Parsed, key: []const u8) ?toml.Value {
        return self.value.table.get(key);
    }
};

fn parseOk(src: []const u8) !Parsed {
    var arena = ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const val = try toml.parse(arena.allocator(), src, .{});
    return .{ .arena = arena, .value = val };
}

fn expectParseFails(src: []const u8) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = toml.parse(arena.allocator(), src, .{});
    try testing.expectError(error.TomlParseError, result);
}

fn getPath(val: toml.Value, path: []const []const u8) ?toml.Value {
    var cur = val;
    for (path) |segment| {
        if (cur != .table) return null;
        cur = cur.table.get(segment) orelse return null;
    }
    return cur;
}

test "doc: empty input parses to empty table" {
    var p = try parseOk("");
    defer p.deinit();
    try testing.expect(p.value == .table);
    try testing.expectEqual(@as(usize, 0), p.value.table.count());
}

test "doc: only whitespace is valid" {
    var p = try parseOk("   \n\t\n   ");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.table.count());
}

test "doc: comments without key/value are valid" {
    var p = try parseOk("# just a comment\n# another\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.table.count());
}

test "doc: mixed blank lines and comments" {
    var p = try parseOk("\n\n   # hello\n\n#more\n\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.table.count());
}

test "doc: final newline optional" {
    var p = try parseOk("x = 1");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.integer);
}

test "doc: leading BOM is rejected (require clean UTF-8)" {
    // TOML 1.0 is ambiguous about BOM handling -- this parser treats a
    // leading BOM as an unrecognized character at the start of a key.
    try expectParseFails("\xEF\xBB\xBFx = 1");
}

test "doc: CRLF line endings are accepted" {
    var p = try parseOk("a = 1\r\nb = 2\r\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("b").?.integer);
}

test "doc: LF-only line endings are accepted" {
    var p = try parseOk("a = 1\nb = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("b").?.integer);
}

test "key: bare ascii letters and digits" {
    var p = try parseOk("key1 = 1\nkey_2 = 2\nkey-3 = 3\n9key = 4\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("key1").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("key_2").?.integer);
    try testing.expectEqual(@as(i64, 3), p.get("key-3").?.integer);
    try testing.expectEqual(@as(i64, 4), p.get("9key").?.integer);
}

test "key: bare underscore only" {
    var p = try parseOk("_ = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("_").?.integer);
}

test "key: bare hyphen only" {
    var p = try parseOk("- = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("-").?.integer);
}

test "key: basic-quoted with special characters" {
    var p = try parseOk("\"a b\" = 1\n\"c.d\" = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("a b").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("c.d").?.integer);
}

test "key: basic-quoted empty string is allowed" {
    var p = try parseOk("\"\" = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("").?.integer);
}

test "key: literal-quoted key passes through raw" {
    var p = try parseOk("'a\\b' = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("a\\b").?.integer);
}

test "key: literal-quoted empty key is allowed" {
    var p = try parseOk("'' = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("").?.integer);
}

test "key: quoted with unicode escape" {
    var p = try parseOk("\"\\u00e9\" = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("\u{e9}").?.integer);
}

test "key: dotted produces nested tables" {
    var p = try parseOk("a.b.c = 1\n");
    defer p.deinit();
    const leaf = getPath(p.value, &.{ "a", "b", "c" }) orelse return error.TestFailed;
    try testing.expectEqual(@as(i64, 1), leaf.integer);
}

test "key: dotted with spaces around dots is allowed" {
    var p = try parseOk("a . b . c = 1\n");
    defer p.deinit();
    const leaf = getPath(p.value, &.{ "a", "b", "c" }) orelse return error.TestFailed;
    try testing.expectEqual(@as(i64, 1), leaf.integer);
}

test "key: dotted siblings accumulate under same prefix" {
    var p = try parseOk("a.b = 1\na.c = 2\n");
    defer p.deinit();
    const a = p.get("a").?;
    try testing.expectEqual(@as(i64, 1), a.table.get("b").?.integer);
    try testing.expectEqual(@as(i64, 2), a.table.get("c").?.integer);
}

test "key: missing value is error" {
    try expectParseFails("x =\n");
}

test "key: duplicate plain key is error" {
    try expectParseFails("x = 1\nx = 2\n");
}

test "key: duplicate via dotted is error" {
    try expectParseFails("a.b = 1\na.b = 2\n");
}

test "key: empty bare key is error" {
    try expectParseFails("= 1\n");
}

test "key: no whitespace allowed as bare key" {
    try expectParseFails("\"\" = 1\n= 2\n");
}

test "key: trailing dot in dotted key is error" {
    try expectParseFails("a. = 1\n");
}

test "key: leading dot in dotted key is error" {
    try expectParseFails(".a = 1\n");
}

test "key: double dot in dotted key is error" {
    try expectParseFails("a..b = 1\n");
}

test "key: missing = is error" {
    try expectParseFails("x 1\n");
}

test "key: no space or = is error" {
    try expectParseFails("x\n");
}

test "string: basic ascii" {
    var p = try parseOk("s = \"hello world\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("hello world", p.get("s").?.string);
}

test "string: basic empty" {
    var p = try parseOk("s = \"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("", p.get("s").?.string);
}

test "string: basic with \\t escape" {
    var p = try parseOk("s = \"a\\tb\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\tb", p.get("s").?.string);
}

test "string: basic with \\n escape" {
    var p = try parseOk("s = \"a\\nb\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\nb", p.get("s").?.string);
}

test "string: basic with \\r escape" {
    var p = try parseOk("s = \"a\\rb\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\rb", p.get("s").?.string);
}

test "string: basic with \\f escape" {
    var p = try parseOk("s = \"a\\fb\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\x0cb", p.get("s").?.string);
}

test "string: basic with \\b escape" {
    var p = try parseOk("s = \"a\\bb\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\x08b", p.get("s").?.string);
}

test "string: basic escaped quote" {
    var p = try parseOk("s = \"a\\\"b\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\"b", p.get("s").?.string);
}

test "string: basic escaped backslash" {
    var p = try parseOk("s = \"a\\\\b\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\\b", p.get("s").?.string);
}

test "string: basic \\u short unicode escape" {
    var p = try parseOk("s = \"\\u00e9\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("\u{e9}", p.get("s").?.string);
}

test "string: basic \\U long unicode escape" {
    var p = try parseOk("s = \"\\U0001F600\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("\u{1F600}", p.get("s").?.string);
}

test "string: basic \\u0000 NUL escape" {
    var p = try parseOk("s = \"a\\u0000b\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\x00b", p.get("s").?.string);
}

test "string: basic \\u with minimum exactly 4 hex digits" {
    var p = try parseOk("s = \"\\u0041\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("A", p.get("s").?.string);
}

test "string: basic \\U with max codepoint 0x10FFFF" {
    var p = try parseOk("s = \"\\U0010FFFF\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("\u{10FFFF}", p.get("s").?.string);
}

test "string: basic contains raw UTF-8 multibyte" {
    var p = try parseOk("s = \"caf\u{e9}\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("caf\u{e9}", p.get("s").?.string);
}

test "string: literal ignores backslash escapes" {
    var p = try parseOk("s = 'a\\tb'\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\\tb", p.get("s").?.string);
}

test "string: literal preserves single quotes not required" {
    var p = try parseOk("s = 'windows\\path\\here'\n");
    defer p.deinit();
    try testing.expectEqualStrings("windows\\path\\here", p.get("s").?.string);
}

test "string: literal empty" {
    var p = try parseOk("s = ''\n");
    defer p.deinit();
    try testing.expectEqualStrings("", p.get("s").?.string);
}

test "string: multiline basic preserves interior newlines" {
    var p = try parseOk("s = \"\"\"line1\nline2\nline3\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("line1\nline2\nline3", p.get("s").?.string);
}

test "string: multiline basic strips leading newline right after opener" {
    var p = try parseOk("s = \"\"\"\nhello\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("hello", p.get("s").?.string);
}

test "string: multiline basic line continuation" {
    var p = try parseOk("s = \"\"\"one \\\n  two\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("one two", p.get("s").?.string);
}

test "string: multiline basic allows embedded single quote" {
    var p = try parseOk("s = \"\"\"a'b'c\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a'b'c", p.get("s").?.string);
}

test "string: multiline basic allows one quote inside" {
    var p = try parseOk("s = \"\"\"say \"hi\" ok\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("say \"hi\" ok", p.get("s").?.string);
}

test "string: multiline basic allows trailing single quote before terminator" {
    // Up to 2 quotes before the closing \"\"\" are allowed.
    var p = try parseOk("s = \"\"\"yep\"\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("yep\"", p.get("s").?.string);
}

test "string: multiline basic allows two quotes before terminator" {
    var p = try parseOk("s = \"\"\"a\"\"\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\"\"", p.get("s").?.string);
}

test "string: multiline basic CRLF normalized to LF" {
    var p = try parseOk("s = \"\"\"line1\r\nline2\"\"\"\n");
    defer p.deinit();
    // we normalize CRLF to LF inside multiline basic strings so
    // round-tripping a Windows-authored TOML is portable.
    try testing.expectEqualStrings("line1\nline2", p.get("s").?.string);
}

test "string: multiline literal preserves interior newlines and backslashes" {
    var p = try parseOk("s = '''a\\nb\nc'''\n");
    defer p.deinit();
    try testing.expectEqualStrings("a\\nb\nc", p.get("s").?.string);
}

test "string: multiline literal strips leading newline" {
    var p = try parseOk("s = '''\nhello'''\n");
    defer p.deinit();
    try testing.expectEqualStrings("hello", p.get("s").?.string);
}

test "string: multiline literal allows up to two single quotes" {
    var p = try parseOk("s = '''abc''''\n");
    defer p.deinit();
    try testing.expectEqualStrings("abc'", p.get("s").?.string);
}

test "string: invalid escape sequence is error" {
    try expectParseFails("s = \"a\\xb\"\n");
}

test "string: invalid escape \\q is error" {
    try expectParseFails("s = \"\\q\"\n");
}

test "string: bare newline in basic string is error" {
    try expectParseFails("s = \"line1\nline2\"\n");
}

test "string: bare CR in basic string is error" {
    try expectParseFails("s = \"line1\rline2\"\n");
}

test "string: unterminated basic string is error" {
    try expectParseFails("s = \"hello\n");
}

test "string: unterminated literal string is error" {
    try expectParseFails("s = 'hello\n");
}

test "string: unterminated multiline basic is error" {
    try expectParseFails("s = \"\"\"hello\n");
}

test "string: unterminated multiline literal is error" {
    try expectParseFails("s = '''hello\n");
}

test "string: \\u with fewer than 4 digits is error" {
    try expectParseFails("s = \"\\u00\"\n");
}

test "string: \\U with fewer than 8 digits is error" {
    try expectParseFails("s = \"\\U0001F60\"\n");
}

test "string: \\u with surrogate code point is error" {
    try expectParseFails("s = \"\\uD800\"\n");
}

test "string: \\U with code point above 0x10FFFF is error" {
    try expectParseFails("s = \"\\U00110000\"\n");
}

test "string: invalid UTF-8 bytes in basic string are error" {
    // lone continuation byte 0x80 is invalid
    try expectParseFails("s = \"a\x80b\"\n");
}

test "string: invalid UTF-8 in literal string is error" {
    try expectParseFails("s = 'a\x80b'\n");
}

test "string: control char 0x01 in basic is error" {
    try expectParseFails("s = \"a\x01b\"\n");
}

test "string: DEL 0x7F in basic is error" {
    try expectParseFails("s = \"a\x7Fb\"\n");
}

test "string: literal cannot contain 0x00 NUL" {
    try expectParseFails("s = 'a\x00b'\n");
}

test "string: literal cannot contain control 0x1F" {
    try expectParseFails("s = 'a\x1fb'\n");
}

test "int: zero" {
    var p = try parseOk("x = 0\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), p.get("x").?.integer);
}

test "int: positive sign" {
    var p = try parseOk("x = +42\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 42), p.get("x").?.integer);
}

test "int: negative sign" {
    var p = try parseOk("x = -42\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, -42), p.get("x").?.integer);
}

test "int: +0 and -0 both parse to 0" {
    var p = try parseOk("a = +0\nb = -0\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), p.get("a").?.integer);
    try testing.expectEqual(@as(i64, 0), p.get("b").?.integer);
}

test "int: max i64" {
    var p = try parseOk("x = 9223372036854775807\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), p.get("x").?.integer);
}

test "int: min i64" {
    var p = try parseOk("x = -9223372036854775808\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), p.get("x").?.integer);
}

test "int: underscores between digits" {
    var p = try parseOk("x = 1_234_567\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1234567), p.get("x").?.integer);
}

test "int: signed with underscores" {
    var p = try parseOk("x = -1_000\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, -1000), p.get("x").?.integer);
}

test "int: hex lowercase" {
    var p = try parseOk("x = 0xdeadbeef\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0xdeadbeef), p.get("x").?.integer);
}

test "int: hex uppercase" {
    var p = try parseOk("x = 0xDEADBEEF\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0xdeadbeef), p.get("x").?.integer);
}

test "int: hex mixed case" {
    var p = try parseOk("x = 0xDeAdBeEf\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0xdeadbeef), p.get("x").?.integer);
}

test "int: hex with underscores" {
    var p = try parseOk("x = 0xDEAD_BEEF\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0xdeadbeef), p.get("x").?.integer);
}

test "int: hex zero" {
    var p = try parseOk("x = 0x0\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), p.get("x").?.integer);
}

test "int: octal" {
    var p = try parseOk("x = 0o755\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0o755), p.get("x").?.integer);
}

test "int: octal zero" {
    var p = try parseOk("x = 0o0\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), p.get("x").?.integer);
}

test "int: octal with underscores" {
    var p = try parseOk("x = 0o1_2_3\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0o123), p.get("x").?.integer);
}

test "int: binary" {
    var p = try parseOk("x = 0b101010\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 42), p.get("x").?.integer);
}

test "int: binary zero" {
    var p = try parseOk("x = 0b0\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), p.get("x").?.integer);
}

test "int: binary with underscores" {
    var p = try parseOk("x = 0b1010_1010\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0xAA), p.get("x").?.integer);
}

test "int: leading zeros in decimal is error" {
    try expectParseFails("x = 01\n");
}

test "int: leading zeros positive signed is error" {
    try expectParseFails("x = +01\n");
}

test "int: leading zeros negative signed is error" {
    try expectParseFails("x = -01\n");
}

test "int: double underscore is error" {
    try expectParseFails("x = 1__2\n");
}

test "int: leading underscore is error" {
    try expectParseFails("x = _1\n");
}

test "int: trailing underscore is error" {
    try expectParseFails("x = 1_\n");
}

test "int: underscore adjacent to sign is error" {
    try expectParseFails("x = -_1\n");
}

test "int: sign on hex is error" {
    try expectParseFails("x = +0x10\n");
}

test "int: sign on octal is error" {
    try expectParseFails("x = -0o10\n");
}

test "int: sign on binary is error" {
    try expectParseFails("x = +0b10\n");
}

test "int: hex empty after prefix is error" {
    try expectParseFails("x = 0x\n");
}

test "int: octal empty after prefix is error" {
    try expectParseFails("x = 0o\n");
}

test "int: binary empty after prefix is error" {
    try expectParseFails("x = 0b\n");
}

test "int: octal digit 8 is error" {
    try expectParseFails("x = 0o8\n");
}

test "int: binary digit 2 is error" {
    try expectParseFails("x = 0b2\n");
}

test "int: hex non-hex digit is error" {
    try expectParseFails("x = 0xG\n");
}

test "int: integer overflow on decimal is error" {
    try expectParseFails("x = 99999999999999999999\n");
}

test "int: integer overflow on hex is error" {
    try expectParseFails("x = 0xFFFFFFFFFFFFFFFF\n");
}

test "int: sole underscore is error" {
    try expectParseFails("x = _\n");
}

test "int: underscore at end of radix digits is error" {
    try expectParseFails("x = 0xFF_\n");
}

test "float: basic fractional" {
    var p = try parseOk("x = 3.14\n");
    defer p.deinit();
    try testing.expectApproxEqAbs(@as(f64, 3.14), p.get("x").?.float, 1e-12);
}

test "float: negative fractional" {
    var p = try parseOk("x = -0.5\n");
    defer p.deinit();
    try testing.expectApproxEqAbs(@as(f64, -0.5), p.get("x").?.float, 1e-12);
}

test "float: positive sign" {
    var p = try parseOk("x = +3.14\n");
    defer p.deinit();
    try testing.expectApproxEqAbs(@as(f64, 3.14), p.get("x").?.float, 1e-12);
}

test "float: +0.0 is positive zero" {
    var p = try parseOk("x = +0.0\n");
    defer p.deinit();
    const bits: u64 = @bitCast(p.get("x").?.float);
    try testing.expectEqual(@as(u64, 0), bits);
}

test "float: -0.0 is negative zero" {
    var p = try parseOk("x = -0.0\n");
    defer p.deinit();
    const bits: u64 = @bitCast(p.get("x").?.float);
    try testing.expectEqual(@as(u64, 0x8000000000000000), bits);
}

test "float: exponent lowercase e" {
    var p = try parseOk("x = 1e10\n");
    defer p.deinit();
    try testing.expectApproxEqRel(@as(f64, 1e10), p.get("x").?.float, 1e-12);
}

test "float: exponent uppercase E" {
    var p = try parseOk("x = 2E3\n");
    defer p.deinit();
    try testing.expectApproxEqRel(@as(f64, 2000.0), p.get("x").?.float, 1e-12);
}

test "float: negative exponent" {
    var p = try parseOk("x = 1.5e-3\n");
    defer p.deinit();
    try testing.expectApproxEqRel(@as(f64, 1.5e-3), p.get("x").?.float, 1e-12);
}

test "float: positive exponent sign" {
    var p = try parseOk("x = 2e+5\n");
    defer p.deinit();
    try testing.expectApproxEqRel(@as(f64, 2e5), p.get("x").?.float, 1e-12);
}

test "float: underscore in integer part" {
    var p = try parseOk("x = 1_000.5\n");
    defer p.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1000.5), p.get("x").?.float, 1e-12);
}

test "float: underscore in fractional part" {
    var p = try parseOk("x = 1.123_456\n");
    defer p.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1.123456), p.get("x").?.float, 1e-12);
}

test "float: inf literal" {
    var p = try parseOk("x = inf\n");
    defer p.deinit();
    try testing.expect(std.math.isPositiveInf(p.get("x").?.float));
}

test "float: +inf literal" {
    var p = try parseOk("x = +inf\n");
    defer p.deinit();
    try testing.expect(std.math.isPositiveInf(p.get("x").?.float));
}

test "float: -inf literal" {
    var p = try parseOk("x = -inf\n");
    defer p.deinit();
    try testing.expect(std.math.isNegativeInf(p.get("x").?.float));
}

test "float: nan literal" {
    var p = try parseOk("x = nan\n");
    defer p.deinit();
    try testing.expect(std.math.isNan(p.get("x").?.float));
}

test "float: +nan literal" {
    var p = try parseOk("x = +nan\n");
    defer p.deinit();
    try testing.expect(std.math.isNan(p.get("x").?.float));
}

test "float: -nan literal" {
    var p = try parseOk("x = -nan\n");
    defer p.deinit();
    try testing.expect(std.math.isNan(p.get("x").?.float));
}

test "float: leading zero error" {
    try expectParseFails("x = 03.14\n");
}

test "float: leading zero positive signed error" {
    try expectParseFails("x = +03.14\n");
}

test "float: leading zero negative signed error" {
    try expectParseFails("x = -03.14\n");
}

test "float: fractional must have digits after dot" {
    try expectParseFails("x = 1.\n");
}

test "float: fractional must have digits before dot" {
    try expectParseFails("x = .5\n");
}

test "float: underscore at start of fractional is error" {
    try expectParseFails("x = 1._5\n");
}

test "float: underscore adjacent to dot is error" {
    try expectParseFails("x = 1_.5\n");
}

test "float: underscore adjacent to e is error" {
    try expectParseFails("x = 1_e5\n");
}

test "float: underscore adjacent to exponent sign is error" {
    try expectParseFails("x = 1e_5\n");
}

test "float: double dot is error" {
    try expectParseFails("x = 1..5\n");
}

test "float: two exponents is error" {
    try expectParseFails("x = 1e2e3\n");
}

test "float: missing exponent digits is error" {
    try expectParseFails("x = 1e\n");
}

test "bool: true" {
    var p = try parseOk("x = true\n");
    defer p.deinit();
    try testing.expectEqual(true, p.get("x").?.boolean);
}

test "bool: false" {
    var p = try parseOk("x = false\n");
    defer p.deinit();
    try testing.expectEqual(false, p.get("x").?.boolean);
}

test "bool: TRUE uppercase is error" {
    try expectParseFails("x = TRUE\n");
}

test "bool: True mixed case is error" {
    try expectParseFails("x = True\n");
}

test "bool: False mixed case is error" {
    try expectParseFails("x = False\n");
}

test "bool: tru truncated is error" {
    try expectParseFails("x = tru\n");
}

test "datetime: offset UTC Z" {
    var p = try parseOk("x = 1979-05-27T07:32:00Z\n");
    defer p.deinit();
    const d = p.get("x").?.datetime;
    try testing.expectEqual(@as(u16, 1979), d.date.year);
    try testing.expectEqual(@as(u8, 5), d.date.month);
    try testing.expectEqual(@as(u8, 27), d.date.day);
    try testing.expectEqual(@as(u8, 7), d.time.hour);
    try testing.expectEqual(@as(u8, 32), d.time.minute);
    try testing.expectEqual(@as(u8, 0), d.time.second);
    try testing.expectEqual(@as(?i16, 0), d.tz_offset_minutes);
}

test "datetime: offset positive" {
    var p = try parseOk("x = 1979-05-27T07:32:00+09:00\n");
    defer p.deinit();
    const d = p.get("x").?.datetime;
    try testing.expectEqual(@as(?i16, 9 * 60), d.tz_offset_minutes);
}

test "datetime: offset negative" {
    var p = try parseOk("x = 1979-05-27T07:32:00-08:00\n");
    defer p.deinit();
    try testing.expectEqual(@as(?i16, -8 * 60), p.get("x").?.datetime.tz_offset_minutes);
}

test "datetime: offset half-hour zone" {
    var p = try parseOk("x = 1979-05-27T07:32:00+05:30\n");
    defer p.deinit();
    try testing.expectEqual(@as(?i16, 5 * 60 + 30), p.get("x").?.datetime.tz_offset_minutes);
}

test "datetime: offset with fractional seconds" {
    var p = try parseOk("x = 1979-05-27T07:32:00.123456Z\n");
    defer p.deinit();
    try testing.expectEqual(@as(u32, 123_456_000), p.get("x").?.datetime.time.nanos);
}

test "datetime: lowercase t separator" {
    var p = try parseOk("x = 1979-05-27t07:32:00Z\n");
    defer p.deinit();
    try testing.expectEqual(@as(u16, 1979), p.get("x").?.datetime.date.year);
}

test "datetime: space separator" {
    var p = try parseOk("x = 1979-05-27 07:32:00Z\n");
    defer p.deinit();
    try testing.expectEqual(@as(u16, 1979), p.get("x").?.datetime.date.year);
}

test "datetime: lowercase z is accepted" {
    var p = try parseOk("x = 1979-05-27T07:32:00z\n");
    defer p.deinit();
    try testing.expectEqual(@as(?i16, 0), p.get("x").?.datetime.tz_offset_minutes);
}

test "datetime: local datetime has no tz" {
    var p = try parseOk("x = 1979-05-27T07:32:00\n");
    defer p.deinit();
    try testing.expectEqual(@as(?i16, null), p.get("x").?.datetime.tz_offset_minutes);
}

test "datetime: local datetime with fractional" {
    var p = try parseOk("x = 1979-05-27T07:32:00.999\n");
    defer p.deinit();
    try testing.expectEqual(@as(u32, 999_000_000), p.get("x").?.datetime.time.nanos);
}

test "datetime: local date" {
    var p = try parseOk("x = 1979-05-27\n");
    defer p.deinit();
    const d = p.get("x").?.date;
    try testing.expectEqual(@as(u16, 1979), d.year);
    try testing.expectEqual(@as(u8, 5), d.month);
    try testing.expectEqual(@as(u8, 27), d.day);
}

test "datetime: local time" {
    var p = try parseOk("x = 07:32:00\n");
    defer p.deinit();
    const t = p.get("x").?.time;
    try testing.expectEqual(@as(u8, 7), t.hour);
    try testing.expectEqual(@as(u8, 32), t.minute);
    try testing.expectEqual(@as(u8, 0), t.second);
}

test "datetime: local time with fractional" {
    var p = try parseOk("x = 07:32:00.500\n");
    defer p.deinit();
    try testing.expectEqual(@as(u32, 500_000_000), p.get("x").?.time.nanos);
}

test "datetime: leap day is accepted" {
    var p = try parseOk("x = 2020-02-29\n");
    defer p.deinit();
    try testing.expectEqual(@as(u8, 29), p.get("x").?.date.day);
}

test "datetime: invalid month is error" {
    try expectParseFails("x = 1979-13-27\n");
}

test "datetime: invalid day is error" {
    try expectParseFails("x = 1979-05-32\n");
}

test "datetime: february 30 is error" {
    try expectParseFails("x = 1979-02-30\n");
}

test "datetime: non-leap year feb 29 is error" {
    try expectParseFails("x = 2021-02-29\n");
}

test "datetime: invalid hour is error" {
    try expectParseFails("x = 25:00:00\n");
}

test "datetime: invalid minute is error" {
    try expectParseFails("x = 07:60:00\n");
}

test "datetime: invalid second is error" {
    // TOML allows 60 for leap second but 61 is never valid.
    try expectParseFails("x = 07:32:61\n");
}

test "datetime: malformed offset is error" {
    try expectParseFails("x = 1979-05-27T07:32:00+9:00\n");
}

test "datetime: offset minutes out of range is error" {
    try expectParseFails("x = 1979-05-27T07:32:00+00:99\n");
}

test "array: empty" {
    var p = try parseOk("x = []\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.get("x").?.array.items.len);
}

test "array: single integer" {
    var p = try parseOk("x = [1]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.get("x").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), p.get("x").?.array.items[0].integer);
}

test "array: multiple integers" {
    var p = try parseOk("x = [1, 2, 3]\n");
    defer p.deinit();
    const arr = p.get("x").?.array.items;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(i64, 1), arr[0].integer);
    try testing.expectEqual(@as(i64, 2), arr[1].integer);
    try testing.expectEqual(@as(i64, 3), arr[2].integer);
}

test "array: trailing comma" {
    var p = try parseOk("x = [1, 2, 3,]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.get("x").?.array.items.len);
}

test "array: mixed types allowed in TOML 1.0" {
    var p = try parseOk("x = [1, \"two\", 3.0, true]\n");
    defer p.deinit();
    const arr = p.get("x").?.array.items;
    try testing.expectEqual(@as(i64, 1), arr[0].integer);
    try testing.expectEqualStrings("two", arr[1].string);
    try testing.expectApproxEqAbs(@as(f64, 3.0), arr[2].float, 1e-12);
    try testing.expectEqual(true, arr[3].boolean);
}

test "array: nested arrays" {
    var p = try parseOk("x = [[1, 2], [3, 4]]\n");
    defer p.deinit();
    const arr = p.get("x").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(i64, 2), arr[0].array.items[1].integer);
    try testing.expectEqual(@as(i64, 3), arr[1].array.items[0].integer);
}

test "array: empty nested" {
    var p = try parseOk("x = [[]]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.get("x").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), p.get("x").?.array.items[0].array.items.len);
}

test "array: multi-line values allowed" {
    var p = try parseOk("x = [\n  1,\n  2,\n  3,\n]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.get("x").?.array.items.len);
}

test "array: comments inside are allowed" {
    var p = try parseOk("x = [\n  1, # one\n  2, # two\n  3,\n]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.get("x").?.array.items.len);
}

test "array: whitespace around commas" {
    var p = try parseOk("x = [ 1 , 2 , 3 ]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.get("x").?.array.items.len);
}

test "array: of strings" {
    var p = try parseOk("x = [\"a\", \"b\", \"c\"]\n");
    defer p.deinit();
    try testing.expectEqualStrings("a", p.get("x").?.array.items[0].string);
    try testing.expectEqualStrings("c", p.get("x").?.array.items[2].string);
}

test "array: of inline tables" {
    var p = try parseOk("x = [{a = 1}, {a = 2}]\n");
    defer p.deinit();
    const arr = p.get("x").?.array.items;
    try testing.expectEqual(@as(i64, 1), arr[0].table.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), arr[1].table.get("a").?.integer);
}

test "array: deeply nested" {
    var p = try parseOk("x = [[[[1]]]]\n");
    defer p.deinit();
    const inner = p.get("x").?.array.items[0].array.items[0].array.items[0];
    try testing.expectEqual(@as(i64, 1), inner.array.items[0].integer);
}

test "array: unterminated is error" {
    try expectParseFails("x = [1, 2,\n");
}

test "array: leading comma is error" {
    try expectParseFails("x = [, 1]\n");
}

test "array: double comma is error" {
    try expectParseFails("x = [1,, 2]\n");
}

test "array: missing comma between values is error" {
    try expectParseFails("x = [1 2]\n");
}

test "table: single header" {
    var p = try parseOk("[a]\nb = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b" }).?.integer);
}

test "table: dotted header creates nested tables" {
    var p = try parseOk("[a.b.c]\nd = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b", "c", "d" }).?.integer);
}

test "table: multiple headers" {
    var p = try parseOk("[a]\nx = 1\n[b]\ny = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "x" }).?.integer);
    try testing.expectEqual(@as(i64, 2), getPath(p.value, &.{ "b", "y" }).?.integer);
}

test "table: super-table created implicitly" {
    var p = try parseOk("[a.b]\nc = 1\n[a]\nd = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b", "c" }).?.integer);
    try testing.expectEqual(@as(i64, 2), getPath(p.value, &.{ "a", "d" }).?.integer);
}

test "table: quoted header segment" {
    var p = try parseOk("[\"a.b\"]\nc = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a.b", "c" }).?.integer);
}

test "table: quoted and bare header segments mix" {
    var p = try parseOk("[a.\"b c\".d]\nx = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b c", "d", "x" }).?.integer);
}

test "table: empty table body is allowed" {
    var p = try parseOk("[a]\n");
    defer p.deinit();
    try testing.expect(p.get("a").? == .table);
    try testing.expectEqual(@as(usize, 0), p.get("a").?.table.count());
}

test "table: spaces inside header brackets" {
    var p = try parseOk("[ a.b ]\nc = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b", "c" }).?.integer);
}

test "table: redefining header is error" {
    try expectParseFails("[a]\n[a]\n");
}

test "table: key shadows subtable is error" {
    try expectParseFails("a = 1\n[a]\nb = 2\n");
}

test "table: promote implicit to defined via later header is allowed" {
    // [a.b] creates 'a' implicitly; then [a] may be defined.
    var p = try parseOk("[a.b]\nc = 1\n[a]\nd = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 2), getPath(p.value, &.{ "a", "d" }).?.integer);
}

test "table: cannot redefine defined as implicit later" {
    // Explicitly defining then re-defining is error.
    try expectParseFails("[a]\nb = 1\n[a]\nc = 2\n");
}

test "table: unclosed header is error" {
    try expectParseFails("[a\n");
}

test "table: missing header name is error" {
    try expectParseFails("[]\nx = 1\n");
}

test "table: trailing garbage after header is error" {
    try expectParseFails("[a] garbage\n");
}

test "table: header followed by comment is allowed" {
    var p = try parseOk("[a] # comment\nb = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b" }).?.integer);
}

test "inline: empty" {
    var p = try parseOk("x = {}\n");
    defer p.deinit();
    try testing.expect(p.get("x").? == .table);
    try testing.expectEqual(@as(usize, 0), p.get("x").?.table.count());
}

test "inline: single key" {
    var p = try parseOk("x = {a = 1}\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.table.get("a").?.integer);
}

test "inline: multiple keys" {
    var p = try parseOk("x = {a = 1, b = 2}\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.table.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("x").?.table.get("b").?.integer);
}

test "inline: dotted keys inside create subtables" {
    var p = try parseOk("x = {a.b = 1}\n");
    defer p.deinit();
    const ab = p.get("x").?.table.get("a").?.table.get("b").?;
    try testing.expectEqual(@as(i64, 1), ab.integer);
}

test "inline: nested inline table" {
    var p = try parseOk("x = {a = {b = 1}}\n");
    defer p.deinit();
    const b = p.get("x").?.table.get("a").?.table.get("b").?;
    try testing.expectEqual(@as(i64, 1), b.integer);
}

test "inline: with arrays" {
    var p = try parseOk("x = {a = [1, 2]}\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.get("x").?.table.get("a").?.array.items.len);
}

test "inline: newlines allowed (TOML 1.1)" {
    var p = try parseOk("x = {a = 1,\nb = 2}\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.table.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("x").?.table.get("b").?.integer);
}

test "inline: trailing comma allowed (TOML 1.1)" {
    var p = try parseOk("x = {a = 1,}\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.table.get("a").?.integer);
}

test "inline: leading comma is error" {
    try expectParseFails("x = {, a = 1}\n");
}

test "inline: unterminated is error" {
    try expectParseFails("x = {a = 1\n");
}

test "inline: sealed -- cannot extend via header" {
    try expectParseFails("a = {}\n[a.b]\nx = 1\n");
}

test "inline: sealed -- cannot extend via array of tables" {
    try expectParseFails("a = {}\n[[a.b]]\nx = 1\n");
}

test "inline: sealed -- cannot extend via dotted key at top level" {
    try expectParseFails("a = {b = 1}\na.c = 2\n");
}

test "inline: duplicate key is error" {
    try expectParseFails("x = {a = 1, a = 2}\n");
}

test "dotted: simple a.b.c in kv" {
    var p = try parseOk("a.b.c = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b", "c" }).?.integer);
}

test "dotted: siblings build up subtable" {
    var p = try parseOk("a.b = 1\na.c = 2\n");
    defer p.deinit();
    const a = p.get("a").?;
    try testing.expectEqual(@as(i64, 1), a.table.get("b").?.integer);
    try testing.expectEqual(@as(i64, 2), a.table.get("c").?.integer);
}

test "dotted: cannot conflict with explicit table header below" {
    try expectParseFails("a.b = 1\n[a]\nc = 2\n");
}

test "dotted: cannot extend header-defined table via cross-scope descent" {
    // After [a.b.c] is an explicit header, entering [a] and writing
    // `b.c.t = ...` would descend through the already-defined `a.b.c`.
    try expectParseFails("[a.b.c]\nx = 1\n[a]\nb.c.t = 2\n");
}

test "dotted: dotted under header is scoped to that header" {
    var p = try parseOk("[pkg]\na.b = 1\na.c = 2\n");
    defer p.deinit();
    const a = getPath(p.value, &.{ "pkg", "a" }).?;
    try testing.expectEqual(@as(i64, 1), a.table.get("b").?.integer);
    try testing.expectEqual(@as(i64, 2), a.table.get("c").?.integer);
}

test "dotted: quoted segments work" {
    var p = try parseOk("\"a b\".c = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a b", "c" }).?.integer);
}

test "dotted: literal-quoted segment" {
    var p = try parseOk("'a.b'.c = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a.b", "c" }).?.integer);
}

test "array-of-tables: two elements" {
    var p = try parseOk("[[items]]\nx = 1\n[[items]]\nx = 2\n");
    defer p.deinit();
    const items = p.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(i64, 1), items[0].table.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), items[1].table.get("x").?.integer);
}

test "array-of-tables: elements independent" {
    var p = try parseOk("[[items]]\nx = 1\n[[items]]\ny = 2\n");
    defer p.deinit();
    const items = p.get("items").?.array.items;
    try testing.expect(items[0].table.get("x") != null);
    try testing.expect(items[0].table.get("y") == null);
    try testing.expect(items[1].table.get("x") == null);
    try testing.expect(items[1].table.get("y") != null);
}

test "array-of-tables: nested under element" {
    var p = try parseOk("[[items]]\nx = 1\n[items.inner]\ny = 2\n[[items]]\nx = 3\n");
    defer p.deinit();
    const items = p.get("items").?.array.items;
    try testing.expectEqual(@as(i64, 1), items[0].table.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), items[0].table.get("inner").?.table.get("y").?.integer);
    try testing.expectEqual(@as(i64, 3), items[1].table.get("x").?.integer);
}

test "array-of-tables: dotted name creates super-table" {
    var p = try parseOk("[[a.b]]\nx = 1\n");
    defer p.deinit();
    const a = p.get("a").?;
    try testing.expect(a == .table);
    const b = a.table.get("b").?;
    try testing.expect(b == .array);
    try testing.expectEqual(@as(i64, 1), b.array.items[0].table.get("x").?.integer);
}

test "array-of-tables: cannot collide with static array" {
    try expectParseFails("items = [1]\n[[items]]\nx = 1\n");
}

test "array-of-tables: cannot redefine plain table as aot" {
    try expectParseFails("[items]\nx = 1\n[[items]]\ny = 2\n");
}

test "array-of-tables: missing closing brackets is error" {
    try expectParseFails("[[items]\nx = 1\n");
}

test "comment: after value" {
    var p = try parseOk("x = 1 # inline\ny = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("y").?.integer);
}

test "comment: tab in comment is allowed" {
    var p = try parseOk("# a\tb\nc = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("c").?.integer);
}

test "comment: unicode in comment" {
    var p = try parseOk("# caf\u{e9}\nx = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.integer);
}

test "comment: bare CR is error" {
    try expectParseFails("# hi\ronly\n");
}

test "comment: control chars in comment are error" {
    try expectParseFails("# a\x01b\n");
}

test "comment: invalid UTF-8 in comment is error" {
    try expectParseFails("# a\x80b\n");
}

test "comment: DEL in comment is error" {
    try expectParseFails("# a\x7fb\n");
}

test "whitespace: tabs between tokens" {
    var p = try parseOk("a\t=\t1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("a").?.integer);
}

test "whitespace: many spaces between tokens" {
    var p = try parseOk("a     =     1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("a").?.integer);
}

test "regression: CRLF inside a comment is accepted" {
    // Bug 1: CRLF in comments used to fail because bare CR detection didn't
    // look ahead for a paired LF.
    var p = try parseOk("# a comment\r\nkey = 1\r\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("key").?.integer);
}

test "regression: bare CR at top level is rejected" {
    // Bug 2 and 9: lone CR (no following LF) must be a parse error, not
    // treated as whitespace.
    try expectParseFails("key = 1\rother = 2\n");
}

test "regression: bare CR in comment is rejected" {
    try expectParseFails("# abc\rdef\n");
}

test "regression: UTF-8 validation in strings rejects lone continuation byte" {
    // Bug 3: basic strings used to accept raw 0x80 bytes without validation.
    try expectParseFails("s = \"a\x80b\"\n");
}

test "regression: UTF-8 validation in strings rejects overlong sequence" {
    // 0xC0 0x80 is an overlong encoding of NUL and must be rejected.
    try expectParseFails("s = \"\xc0\x80\"\n");
}

test "regression: UTF-8 validation in comments rejects bad bytes" {
    try expectParseFails("# bad \xff\n");
}

test "regression: leading-zero float 03.14 is rejected" {
    // Bug 4: parser used to accept leading-zero floats.
    try expectParseFails("x = 03.14\n");
}

test "regression: leading-zero float +03.14 is rejected" {
    try expectParseFails("x = +03.14\n");
}

test "regression: leading-zero float -03.14 is rejected" {
    try expectParseFails("x = -03.14\n");
}

test "regression: inline-table sealing blocks later header extension" {
    // Bug 5: `a = {}` then `[a.b]` must fail -- the inline table is sealed.
    try expectParseFails("a = {}\n[a.b]\nx = 1\n");
}

test "regression: inline-table sealing blocks later dotted extension" {
    try expectParseFails("a = {b = 1}\na.c = 2\n");
}

test "regression: dotted-key sibling extension inside inline tables works" {
    // Bug 6: inside an inline table, `{a.b = 1, a.c = 2}` should succeed  - 
    // the inline table's own 'a' subtable may have multiple dotted children.
    var p = try parseOk("x = {a.b = 1, a.c = 2}\n");
    defer p.deinit();
    const a = p.get("x").?.table.get("a").?;
    try testing.expectEqual(@as(i64, 1), a.table.get("b").?.integer);
    try testing.expectEqual(@as(i64, 2), a.table.get("c").?.integer);
}

test "regression: header re-opens dotted-key-created subtable when the dotted key is adjacent" {
    // Bug 7: within a single `[header]` scope, a dotted key may create an
    // intermediate table, and a subsequent `[header.child]` may enter it.
    var p = try parseOk("[pkg]\na.b = 1\n[pkg.a.c]\nx = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "pkg", "a", "b" }).?.integer);
    try testing.expectEqual(@as(i64, 2), getPath(p.value, &.{ "pkg", "a", "c", "x" }).?.integer);
}

test "regression: cross-scope bare-key descent into header-defined table is rejected" {
    // Bug 8: `[a.b.c]` then `[a]` with dotted `b.c.t = ...` must fail,
    // because descent from the `[a]` scope would cross into the already
    // header-defined `a.b.c` table.
    try expectParseFails("[a.b.c]\nx = 1\n[a]\nb.c.t = 2\n");
}

test "regression: array-of-tables path collision between adjacent elements is handled" {
    // Bug 9: two adjacent `[[arr]]` headers each start fresh elements;
    // paths inside one element must not bleed into the next.
    var p = try parseOk("[[arr]]\ninner.x = 1\n[[arr]]\ninner.x = 2\n");
    defer p.deinit();
    const arr = p.get("arr").?.array.items;
    try testing.expectEqual(@as(i64, 1), arr[0].table.get("inner").?.table.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), arr[1].table.get("inner").?.table.get("x").?.integer);
}

fn encodeToOwned(val: toml.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    try toml.encode(&aw.writer, val);
    return aw.toOwnedSlice();
}

test "encode: roundtrip of small document preserves values" {
    const src =
        \\title = "toml"
        \\answer = 42
        \\pi = 3.14
        \\enabled = true
        \\tags = ["toml", "parser"]
        \\
    ;
    var p = try parseOk(src);
    defer p.deinit();
    const encoded = try encodeToOwned(p.value);
    defer testing.allocator.free(encoded);
    var p2 = try parseOk(encoded);
    defer p2.deinit();
    try testing.expect(toml.Value.eql(p.value, p2.value));
}

test "encode: roundtrip with nested tables" {
    const src =
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[server.tls]
        \\enabled = true
        \\
    ;
    var p = try parseOk(src);
    defer p.deinit();
    const encoded = try encodeToOwned(p.value);
    defer testing.allocator.free(encoded);
    var p2 = try parseOk(encoded);
    defer p2.deinit();
    try testing.expect(toml.Value.eql(p.value, p2.value));
}

test "encode: roundtrip with array of tables" {
    const src =
        \\[[rows]]
        \\id = 1
        \\name = "a"
        \\
        \\[[rows]]
        \\id = 2
        \\name = "b"
        \\
    ;
    var p = try parseOk(src);
    defer p.deinit();
    const encoded = try encodeToOwned(p.value);
    defer testing.allocator.free(encoded);
    var p2 = try parseOk(encoded);
    defer p2.deinit();
    try testing.expect(toml.Value.eql(p.value, p2.value));
}

test "invalid: key followed by equals only" {
    try expectParseFails("x = \n");
}

test "invalid: unterminated basic string at EOF" {
    try expectParseFails("s = \"oops");
}

test "invalid: unterminated literal string at EOF" {
    try expectParseFails("s = 'oops");
}

test "invalid: single quote in middle of bare key" {
    try expectParseFails("a'b = 1\n");
}

test "invalid: equals at start of line" {
    try expectParseFails("= 1\n");
}

test "invalid: dot at start of line" {
    try expectParseFails(".a = 1\n");
}

test "invalid: array missing close bracket at EOF" {
    try expectParseFails("x = [1");
}

test "invalid: inline table missing close brace at EOF" {
    try expectParseFails("x = {a = 1");
}

test "invalid: stray closing bracket" {
    try expectParseFails("] = 1\n");
}

test "invalid: stray closing brace" {
    try expectParseFails("} = 1\n");
}

test "invalid: two assignments on one line" {
    try expectParseFails("a = 1 b = 2\n");
}

test "invalid: value after value on same line (integer)" {
    try expectParseFails("a = 1 2\n");
}

test "invalid: datetime with missing time" {
    try expectParseFails("x = 1979-05-27T\n");
}

test "invalid: datetime with letters in date" {
    try expectParseFails("x = 19aa-05-27\n");
}

test "invalid: integer with hex char" {
    try expectParseFails("x = 12A\n");
}

test "invalid: boolean with extra chars" {
    try expectParseFails("x = truely\n");
}

test "inline: opener may be followed by newline (TOML 1.1)" {
    var p = try parseOk("x = {\na = 1}\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("x").?.table.get("a").?.integer);
}

test "invalid: float with +/- in middle of mantissa" {
    try expectParseFails("x = 1+2\n");
}

test "invalid: string key not followed by equals" {
    try expectParseFails("\"key\" 1\n");
}

test "invalid: table header must follow newline after kv" {
    try expectParseFails("a = 1 [b]\n");
}

test "invalid: duplicate key via quoted variants" {
    try expectParseFails("\"a\" = 1\n'a' = 2\n");
}

test "invalid: duplicate assignment via dotted under header" {
    // Under [a], b = 1 then a.b = 2 would assign a.a.b = 2 which is
    // fine; this instead asserts the direct duplicate case.
    try expectParseFails("[a]\nb = 1\nb = 2\n");
}

test "invalid: plain kv conflicts with dotted kv" {
    try expectParseFails("a = 1\na.b = 2\n");
}

test "invalid: dotted kv conflicts with later plain kv" {
    try expectParseFails("a.b = 1\na = 2\n");
}

test "invalid: array-of-tables conflicts with later array-of-tables as plain table" {
    try expectParseFails("[[a]]\nx = 1\n[a]\ny = 2\n");
}

test "pos: many keys in one table" {
    var p = try parseOk("a = 1\nb = 2\nc = 3\nd = 4\ne = 5\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 5), p.value.table.count());
}

test "pos: many nested levels via dotted" {
    var p = try parseOk("a.b.c.d.e.f = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b", "c", "d", "e", "f" }).?.integer);
}

test "pos: arrays of various lengths" {
    var p = try parseOk("a = []\nb = [1]\nc = [1, 2]\nd = [1, 2, 3, 4, 5]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.get("a").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), p.get("b").?.array.items.len);
    try testing.expectEqual(@as(usize, 2), p.get("c").?.array.items.len);
    try testing.expectEqual(@as(usize, 5), p.get("d").?.array.items.len);
}

test "pos: header with trailing comment then kv" {
    var p = try parseOk("[section] # header\nk = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "section", "k" }).?.integer);
}

test "pos: header surrounded by blank lines" {
    var p = try parseOk("\n\n[s]\n\nk = 1\n\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "s", "k" }).?.integer);
}

test "pos: document with mixed of everything" {
    const src =
        \\title = "toml"
        \\author = "sho"
        \\version = 1
        \\ratio = 0.5
        \\
        \\[paths]
        \\bin = "/usr/local/bin"
        \\src = "/var/src"
        \\
        \\[[jobs]]
        \\name = "build"
        \\tags = ["ci", "release"]
        \\
        \\[[jobs]]
        \\name = "test"
        \\tags = ["ci"]
        \\
    ;
    var p = try parseOk(src);
    defer p.deinit();
    try testing.expectEqualStrings("toml", p.get("title").?.string);
    try testing.expectEqualStrings("/usr/local/bin", getPath(p.value, &.{ "paths", "bin" }).?.string);
    try testing.expectEqual(@as(usize, 2), p.get("jobs").?.array.items.len);
    try testing.expectEqualStrings("build", p.get("jobs").?.array.items[0].table.get("name").?.string);
}

test "pos: integer underscores at various positions" {
    var p = try parseOk("a = 1_0\nb = 1_0_0\nc = 1_000_000\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 10), p.get("a").?.integer);
    try testing.expectEqual(@as(i64, 100), p.get("b").?.integer);
    try testing.expectEqual(@as(i64, 1000000), p.get("c").?.integer);
}

test "pos: hex underscores at various positions" {
    var p = try parseOk("a = 0xFF_FF\nb = 0x1_2_3\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0xFFFF), p.get("a").?.integer);
    try testing.expectEqual(@as(i64, 0x123), p.get("b").?.integer);
}

test "pos: float zero exponent" {
    var p = try parseOk("x = 1e0\n");
    defer p.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1.0), p.get("x").?.float, 1e-12);
}

test "pos: float mantissa + exponent" {
    var p = try parseOk("x = 6.022e23\n");
    defer p.deinit();
    try testing.expectApproxEqRel(@as(f64, 6.022e23), p.get("x").?.float, 1e-12);
}

test "pos: string with all basic escapes" {
    var p = try parseOk("s = \"\\b\\t\\n\\f\\r\\\"\\\\/ok\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("\x08\t\n\x0c\r\"\\/ok", p.get("s").?.string);
}

test "pos: mix of escape and raw unicode" {
    var p = try parseOk("s = \"\\u00e9-\u{1F600}\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("\u{e9}-\u{1F600}", p.get("s").?.string);
}

test "pos: multiline with three consecutive quotes via escape" {
    // `"""abc\"\"\"..."""`  -> literal abc""".
    var p = try parseOk("s = \"\"\"abc\\\"\\\"\\\"def\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("abc\"\"\"def", p.get("s").?.string);
}

test "pos: empty multiline basic" {
    var p = try parseOk("s = \"\"\"\"\"\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("", p.get("s").?.string);
}

test "pos: empty multiline literal" {
    var p = try parseOk("s = ''''''\n");
    defer p.deinit();
    try testing.expectEqualStrings("", p.get("s").?.string);
}

test "pos: array of booleans" {
    var p = try parseOk("x = [true, false, true]\n");
    defer p.deinit();
    const arr = p.get("x").?.array.items;
    try testing.expectEqual(true, arr[0].boolean);
    try testing.expectEqual(false, arr[1].boolean);
    try testing.expectEqual(true, arr[2].boolean);
}

test "pos: array of floats including inf and nan" {
    var p = try parseOk("x = [1.0, inf, -inf, nan]\n");
    defer p.deinit();
    const arr = p.get("x").?.array.items;
    try testing.expectEqual(@as(f64, 1.0), arr[0].float);
    try testing.expect(std.math.isPositiveInf(arr[1].float));
    try testing.expect(std.math.isNegativeInf(arr[2].float));
    try testing.expect(std.math.isNan(arr[3].float));
}

test "pos: array of dates" {
    var p = try parseOk("x = [1979-05-27, 2020-02-29]\n");
    defer p.deinit();
    const arr = p.get("x").?.array.items;
    try testing.expectEqual(@as(u16, 1979), arr[0].date.year);
    try testing.expectEqual(@as(u16, 2020), arr[1].date.year);
}

test "pos: array with single trailing-comma only element" {
    var p = try parseOk("x = [1,]\n");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.get("x").?.array.items.len);
}

test "pos: header with numeric bare segment" {
    var p = try parseOk("[a.0.b]\nx = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "0", "b", "x" }).?.integer);
}

test "pos: key named 'true'" {
    var p = try parseOk("true = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("true").?.integer);
}

test "pos: key named 'inf' and 'nan'" {
    var p = try parseOk("inf = 1\nnan = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("inf").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("nan").?.integer);
}

test "pos: header with bare digits" {
    var p = try parseOk("[12345]\nx = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "12345", "x" }).?.integer);
}

test "pos: key with hyphen prefix" {
    var p = try parseOk("-key = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("-key").?.integer);
}

test "pos: value CRLF followed by next kv" {
    var p = try parseOk("a = 1\r\nb = 2\r\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("b").?.integer);
}

test "pos: string containing '=' character" {
    var p = try parseOk("s = \"a = b\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a = b", p.get("s").?.string);
}

test "pos: string containing brackets" {
    var p = try parseOk("s = \"[not a header]\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("[not a header]", p.get("s").?.string);
}

test "pos: string with forward slash unescaped" {
    // TOML permits `/` raw and also as `\/`.
    var p = try parseOk("s = \"a/b/c\"\n");
    defer p.deinit();
    try testing.expectEqualStrings("a/b/c", p.get("s").?.string);
}

test "invalid: string escape \\/ is rejected (not a TOML 1.0 escape)" {
    // JSON permits \\/, but TOML 1.0 does not. we reject it.
    try expectParseFails("s = \"a\\/b\"\n");
}

test "pos: integer i64 near boundaries" {
    var p = try parseOk("a = 9223372036854775806\nb = -9223372036854775807\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 9223372036854775806), p.get("a").?.integer);
    try testing.expectEqual(@as(i64, -9223372036854775807), p.get("b").?.integer);
}

test "pos: negative float near zero" {
    var p = try parseOk("x = -1e-300\n");
    defer p.deinit();
    try testing.expect(p.get("x").?.float < 0);
}

// Quoted vs dotted table-header key segments (segment-aware bookkeeping)

test "table: quoted dotted segment is distinct from dotted path" {
    // `[a."b.c"]` is table a with a child whose single key is "b.c"; it must
    // NOT collide with the three-segment path `[a.b.c]`.
    var p = try parseOk("[a.b.c]\n[a.\"b.c\"]\n");
    defer p.deinit();
    try testing.expect(getPath(p.value, &.{ "a", "b", "c" }).? == .table);
    try testing.expect(getPath(p.value, &.{ "a", "b.c" }).? == .table);
    // a has exactly two children: b and "b.c".
    try testing.expectEqual(@as(usize, 2), getPath(p.value, &.{"a"}).?.table.count());
}

test "table: literal-quoted dotted segment is distinct from dotted path" {
    var p = try parseOk("[a.b.c]\n[a.'b.c']\n");
    defer p.deinit();
    try testing.expect(getPath(p.value, &.{ "a", "b", "c" }).? == .table);
    try testing.expect(getPath(p.value, &.{ "a", "b.c" }).? == .table);
}

test "table: quoted segment decoding to a bare key still redefines" {
    // `"b"` decodes to segment b, same as bare b -> genuine redefinition.
    try expectParseFails("[a.b]\n[a.\"b\"]\n");
}

test "table: quoted dotted segment defined twice is a redefinition" {
    try expectParseFails("[a.\"b.c\"]\n[a.\"b.c\"]\n");
}

test "table: dotted path defined twice is still a redefinition" {
    try expectParseFails("[a.b.c]\n[a.b.c]\n");
}

test "table: whitespace and quoted-mix header parses" {
    var p = try parseOk("[ j . \"x\" . 'l' ]\nv = 1\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "j", "x", "l", "v" }).?.integer);
}

test "table: names-style mixed quoted/dotted/numeric headers parse distinctly" {
    const src =
        \\[a.b.c]
        \\[a.'b.c']
        \\[a.'d.e']
        \\[a.' x ']
        \\[ d.e ]
        \\[ g . h . i ]
        \\[ j . '?' . '?' ]
        \\['l'.'q'.'r']
        \\['p.q'.r]
        \\
    ;
    var p = try parseOk(src);
    defer p.deinit();
    try testing.expect(getPath(p.value, &.{ "a", "b", "c" }).? == .table);
    try testing.expect(getPath(p.value, &.{ "a", "b.c" }).? == .table);
    try testing.expect(getPath(p.value, &.{ "a", "d.e" }).? == .table);
    try testing.expect(getPath(p.value, &.{ "a", " x " }).? == .table);
    try testing.expect(getPath(p.value, &.{ "d", "e" }).? == .table);
    try testing.expect(getPath(p.value, &.{ "g", "h", "i" }).? == .table);
    try testing.expect(getPath(p.value, &.{ "p.q", "r" }).? == .table);
}

test "table: aot scoping with quoted subtable parses across elements" {
    // Two [[a]] elements, each with a distinct-key quoted subtable "b.c".
    var p = try parseOk("[[a]]\n[a.\"b.c\"]\nx = 1\n[[a]]\n[a.\"b.c\"]\nx = 2\n");
    defer p.deinit();
    const arr = getPath(p.value, &.{"a"}).?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(i64, 1), getPath(arr[0], &.{ "b.c", "x" }).?.integer);
    try testing.expectEqual(@as(i64, 2), getPath(arr[1], &.{ "b.c", "x" }).?.integer);
}

test "table: quoted subtable twice within one aot element is a redefinition" {
    try expectParseFails("[[a]]\n[a.\"b.c\"]\n[a.\"b.c\"]\n");
}

test "table: dotted key-value with quoted dotted segment is distinct" {
    var p = try parseOk("a.\"b.c\" = 1\na.b.c = 2\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), getPath(p.value, &.{ "a", "b.c" }).?.integer);
    try testing.expectEqual(@as(i64, 2), getPath(p.value, &.{ "a", "b", "c" }).?.integer);
}

