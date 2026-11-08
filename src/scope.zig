//! Search scopes: a query that starts with "<prefix> " narrows the list to
//! items of the scope's kind and searches only the text after it.

const std = @import("std");
const ipc = @import("ipc.zig");

pub const Scope = ipc.Scope;

pub const Match = struct {
    /// index into the scope list
    index: usize,
    /// the query after the prefix and its space; this is what gets searched
    rest: []const u8,
};

/// The first scope whose prefix, then one space, starts the query (prefix
/// compared ASCII case-insensitively). Scopes with an empty prefix or kind never match.
pub fn match(scopes: []const Scope, query: []const u8) ?Match {
    for (scopes, 0..) |scope, index| {
        if (scope.prefix.len == 0 or scope.kind.len == 0) continue;
        if (query.len < scope.prefix.len + 1) continue;
        if (!std.ascii.eqlIgnoreCase(query[0..scope.prefix.len], scope.prefix)) continue;
        if (query[scope.prefix.len] != ' ') continue;
        return .{ .index = index, .rest = query[scope.prefix.len + 1 ..] };
    }
    return null;
}

/// what the counter shows for the scope: its label, else its kind
pub fn displayLabel(scope: Scope) []const u8 {
    return if (scope.label.len > 0) scope.label else scope.kind;
}

const tabs = [_]Scope{
    .{ .prefix = "t", .kind = "tab", .label = "Tabs" },
    .{ .prefix = "win", .kind = "window" },
};

test "a scope needs its prefix and one space" {
    const hit = match(&tabs, "t gmail").?;
    try std.testing.expectEqual(@as(usize, 0), hit.index);
    try std.testing.expectEqualStrings("gmail", hit.rest);

    try std.testing.expect(match(&tabs, "t") == null);
    try std.testing.expect(match(&tabs, "tgmail") == null);
    try std.testing.expect(match(&tabs, "tab gmail") == null);
    try std.testing.expect(match(&tabs, "") == null);
    try std.testing.expect(match(&tabs, " t gmail") == null);
}

test "scope prefixes are case-insensitive and the rest is verbatim" {
    const hit = match(&tabs, "T  Gmail ").?;
    try std.testing.expectEqualStrings(" Gmail ", hit.rest);
    try std.testing.expectEqualStrings("", match(&tabs, "WIN ").?.rest);
    try std.testing.expectEqual(@as(usize, 1), match(&tabs, "Win x").?.index);
}

test "the first matching scope wins and unusable scopes are skipped" {
    const scopes = [_]Scope{
        .{ .prefix = "", .kind = "x" },
        .{ .prefix = "a", .kind = "" },
        .{ .prefix = "a", .kind = "first" },
        .{ .prefix = "a", .kind = "second" },
    };
    try std.testing.expectEqual(@as(usize, 2), match(&scopes, "a q").?.index);
    try std.testing.expect(match(&.{}, "t q") == null);
}

test "display label falls back to the kind" {
    try std.testing.expectEqualStrings("Tabs", displayLabel(tabs[0]));
    try std.testing.expectEqualStrings("window", displayLabel(tabs[1]));
}
