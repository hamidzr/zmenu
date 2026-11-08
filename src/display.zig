//! What the list area shows. Matches are normal selectable rows; with none, the
//! table has no rows and a dim message line stands in, so there is nothing to
//! select, count or accept. Plain Zig so the rules are testable headless.

const std = @import("std");

pub const State = enum {
    /// rows are matches
    list,
    /// streaming input (IPC or followed stdin) has not delivered its first update yet
    loading,
    /// loaded, and there are no items at all
    empty,
    /// items exist but the query matches none
    no_results,
};

/// `client_loading`: the latest update said more are coming, so an empty list is not final
pub fn compute(loaded: bool, item_count: usize, filtered_count: usize, query: []const u8, client_loading: bool) State {
    if (filtered_count > 0) return .list;
    if (!loaded or client_loading) return .loading;
    if (item_count == 0 and std.mem.trim(u8, query, " \t\r\n").len == 0) return .empty;
    return .no_results;
}

/// text of the message row, null when the list shows matches
pub fn message(state: State) ?[:0]const u8 {
    return switch (state) {
        .list => null,
        .loading => "Loading...",
        .empty => "No items",
        .no_results => "No results",
    };
}

/// Counter text: "n / total", prefixed by "<scope> \u{b7} " while a scope is
/// active. A long scope label is cut on a character boundary.
pub fn counterText(buf: []u8, scope_label: ?[]const u8, matched: usize, total: usize) [:0]const u8 {
    const max_label_bytes = 40;
    var label = scope_label orelse "";
    if (label.len > max_label_bytes) {
        var end: usize = max_label_bytes;
        while (end > 0 and label[end] & 0xC0 == 0x80) end -= 1;
        label = label[0..end];
    }
    const text = if (scope_label != null)
        std.fmt.bufPrintSentinel(buf, "{s} \u{b7} {d} / {d}", .{ label, matched, total }, 0)
    else
        std.fmt.bufPrintSentinel(buf, "{d} / {d}", .{ matched, total }, 0);
    return text catch "";
}

test "counter shows n over total, with the scope label when scoped" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("3 / 41", counterText(&buf, null, 3, 41));
    try std.testing.expectEqualStrings("Tabs \u{b7} 3 / 41", counterText(&buf, "Tabs", 3, 41));
    try std.testing.expectEqualStrings("Tabs \u{b7} 0 / 0", counterText(&buf, "Tabs", 0, 0));
}

test "a long scope label is cut on a character boundary" {
    var buf: [128]u8 = undefined;
    const long = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\u{e9}\u{e9}";
    const text = counterText(&buf, long, 1, 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expectEqualStrings("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \u{b7} 1 / 2", text);
}

test "matches always show as a list" {
    try std.testing.expectEqual(State.list, compute(false, 5, 2, "a", false));
    try std.testing.expectEqual(State.list, compute(true, 5, 5, "", false));
}

test "streaming input shows loading until the first update" {
    try std.testing.expectEqual(State.loading, compute(false, 0, 0, "", false));
    // typing before the first update still reads as loading, not no results
    try std.testing.expectEqual(State.loading, compute(false, 0, 0, "saf", false));
}

test "loaded with nothing to match" {
    try std.testing.expectEqual(State.empty, compute(true, 0, 0, "", false));
    try std.testing.expectEqual(State.empty, compute(true, 0, 0, "  ", false));
    try std.testing.expectEqual(State.no_results, compute(true, 0, 0, "x", false));
    try std.testing.expectEqual(State.no_results, compute(true, 12, 0, "zzz", false));
}

test "only the list state has no message" {
    try std.testing.expect(message(.list) == null);
    for ([_]State{ .loading, .empty, .no_results }) |state| {
        try std.testing.expect(message(state) != null);
    }
}

test "an empty list reads as loading while the client has more coming" {
    try std.testing.expectEqual(State.loading, compute(true, 3, 0, "gm", true));
    try std.testing.expectEqual(State.loading, compute(true, 0, 0, "", true));
    // rows win over the flag
    try std.testing.expectEqual(State.list, compute(true, 3, 1, "gm", true));
}
