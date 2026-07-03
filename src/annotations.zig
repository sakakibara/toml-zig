//! Comptime helpers for the `toml_*` annotations user types may declare
//! (`pub const toml_rename / toml_flatten / toml_skip`). Shared by the
//! typed decoder and the typed encoder so both sides consult the exact
//! same rules.

const std = @import("std");

/// Returns the effective TOML key for `field_name` on type `T`,
/// consulting `T.toml_rename` if present.
pub fn renamedKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!@hasDecl(T, "toml_rename")) return field_name;
    const renames = T.toml_rename;
    if (@hasField(@TypeOf(renames), field_name)) {
        return @field(renames, field_name);
    }
    return field_name;
}

/// Returns true if `field_name` on type `T` is listed in `T.toml_skip`.
pub fn isSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "toml_skip")) return false;
    const skip = T.toml_skip;
    inline for (skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Returns true if `field_name` on type `T` is listed in `T.toml_flatten`.
pub fn isFlattened(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "toml_flatten")) return false;
    const flat = T.toml_flatten;
    inline for (flat) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}
