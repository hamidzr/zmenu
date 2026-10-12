const std = @import("std");

pub const max_len = 64;

// menu ids become path components (pid, socket, cache dir), so keep them to
// a safe charset: no separators, no leading dot
pub fn isValid(id: []const u8) bool {
    if (id.len == 0 or id.len > max_len) return false;
    if (id[0] == '.') return false;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return false;
    }
    return true;
}

// empty id means "no namespace" and is allowed
pub fn validate(id: []const u8) error{InvalidMenuId}!void {
    if (id.len == 0) return;
    if (!isValid(id)) return error.InvalidMenuId;
}

test "accepts plain ids" {
    try std.testing.expect(isValid("demo"));
    try std.testing.expect(isValid("my-menu_1.v2"));
}

test "rejects traversal and separators" {
    try std.testing.expect(!isValid("../../x"));
    try std.testing.expect(!isValid(".."));
    try std.testing.expect(!isValid(".hidden"));
    try std.testing.expect(!isValid("a/b"));
    try std.testing.expect(!isValid("a\\b"));
    try std.testing.expect(!isValid("a b"));
    try std.testing.expect(!isValid("a\x00b"));
}

const long_id: [max_len + 1]u8 = @splat('a');

test "rejects empty and overlong ids in isValid, validate allows empty" {
    try std.testing.expect(!isValid(""));
    try validate("");
    try std.testing.expect(!isValid(&long_id));
    try std.testing.expect(isValid(long_id[0..max_len]));
    try std.testing.expectError(error.InvalidMenuId, validate("../x"));
}
