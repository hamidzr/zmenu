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

pub fn compute(loaded: bool, item_count: usize, filtered_count: usize, query: []const u8) State {
    if (filtered_count > 0) return .list;
    if (!loaded) return .loading;
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

test "matches always show as a list" {
    try std.testing.expectEqual(State.list, compute(false, 5, 2, "a"));
    try std.testing.expectEqual(State.list, compute(true, 5, 5, ""));
}

test "streaming input shows loading until the first update" {
    try std.testing.expectEqual(State.loading, compute(false, 0, 0, ""));
    // typing before the first update still reads as loading, not no results
    try std.testing.expectEqual(State.loading, compute(false, 0, 0, "saf"));
}

test "loaded with nothing to match" {
    try std.testing.expectEqual(State.empty, compute(true, 0, 0, ""));
    try std.testing.expectEqual(State.empty, compute(true, 0, 0, "  "));
    try std.testing.expectEqual(State.no_results, compute(true, 0, 0, "x"));
    try std.testing.expectEqual(State.no_results, compute(true, 12, 0, "zzz"));
}

test "only the list state has no message" {
    try std.testing.expect(message(.list) == null);
    for ([_]State{ .loading, .empty, .no_results }) |state| {
        try std.testing.expect(message(state) != null);
    }
}
