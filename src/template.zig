//! Template items (prefix, fallback, calc) carry label text with `{q}` and
//! `{result}` placeholders, filled in per query. Plain Zig so the rules are
//! testable headless.

const std = @import("std");

/// `text` with `{q}` replaced by `query` and `{result}` by `result`. Without a
/// result `{result}` stays as typed. NUL-terminated for AppKit.
pub fn expand(allocator: std.mem.Allocator, text: []const u8, query: []const u8, result: ?[]const u8) std.mem.Allocator.Error![:0]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var rest = text;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "{q}")) {
            try out.appendSlice(allocator, query);
            rest = rest["{q}".len..];
        } else if (result != null and std.mem.startsWith(u8, rest, "{result}")) {
            try out.appendSlice(allocator, result.?);
            rest = rest["{result}".len..];
        } else {
            try out.append(allocator, rest[0]);
            rest = rest[1..];
        }
    }
    return out.toOwnedSliceSentinel(allocator, 0);
}

/// The query after `prefix` (leading spaces trimmed) when the query starts with
/// it, ASCII case-insensitively. Null otherwise, and for an empty prefix.
pub fn prefixRemainder(prefix: []const u8, query: []const u8) ?[]const u8 {
    if (prefix.len == 0 or query.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(query[0..prefix.len], prefix)) return null;
    return std.mem.trimStart(u8, query[prefix.len..], " ");
}

fn expectExpand(text: []const u8, query: []const u8, result: ?[]const u8, expected: []const u8) !void {
    const out = try expand(std.testing.allocator, text, query, result);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expectEqual(@as(u8, 0), out[out.len]);
}

test "expand fills query and result" {
    try expectExpand("Search Google for {q}", "weather", null, "Search Google for weather");
    try expectExpand("{result}", "1+2", "3", "3");
    try expectExpand("{q} = {result}", "1+2", "3", "1+2 = 3");
    try expectExpand("{q}{q}", "ab", null, "abab");
    try expectExpand("no placeholders", "x", "y", "no placeholders");
    try expectExpand("{q}", "", null, "");
    try expectExpand("", "x", null, "");
}

test "expand leaves other braces and a missing result alone" {
    try expectExpand("{result} for {q}", "x", null, "{result} for x");
    try expectExpand("{Q} {query} {", "x", "y", "{Q} {query} {");
    // the query is inserted verbatim, not rescanned
    try expectExpand("{q}", "{q}{result}", "r", "{q}{result}");
    try expectExpand("café {q}", "naïve", null, "café naïve");
}

test "prefix remainder trims leading spaces only" {
    try std.testing.expectEqualStrings("weather", prefixRemainder("g ", "g weather").?);
    try std.testing.expectEqualStrings("weather today ", prefixRemainder("g ", "g   weather today ").?);
    try std.testing.expectEqualStrings("", prefixRemainder("g ", "g ").?);
    try std.testing.expectEqualStrings("Weather", prefixRemainder("g ", "G Weather").?);
    try std.testing.expectEqualStrings("x", prefixRemainder("gh", "ghx").?);
}

test "prefix remainder needs the whole prefix" {
    try std.testing.expect(prefixRemainder("g ", "g") == null);
    try std.testing.expect(prefixRemainder("g ", "gx weather") == null);
    try std.testing.expect(prefixRemainder("g ", "") == null);
    try std.testing.expect(prefixRemainder("", "anything") == null);
    // prefix chars must match exactly after ASCII case folding
    try std.testing.expect(prefixRemainder("é ", "E x") == null);
}
