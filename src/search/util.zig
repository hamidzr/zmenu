const std = @import("std");

pub fn hasUpperAscii(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

pub fn charsEqual(a: u8, b: u8, ignore_case: bool) bool {
    if (!ignore_case) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

pub fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test containsInsensitive {
    try std.testing.expect(containsInsensitive("Hello World", "WORLD"));
    try std.testing.expect(containsInsensitive("abc", ""));
    try std.testing.expect(containsInsensitive("", ""));
    try std.testing.expect(!containsInsensitive("ab", "abc"));
    try std.testing.expect(!containsInsensitive("Hello", "hellp"));
}
