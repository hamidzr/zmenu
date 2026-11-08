const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const levenshtein_distance_threshold: usize = 2;
/// shorter queries are within the threshold of almost any short word
const min_query_len: usize = 4;

/// Suggest labels with a word within the distance threshold of the query,
/// so typos like "chrme" find "Google Chrome" without whole-label noise.
pub fn appendFallbackMatches(labels: []const []const u8, query: []const u8, matches: *std.ArrayList(types.Match)) void {
    if (query.len < min_query_len) return;

    var max_len: usize = query.len;
    for (labels) |label| {
        if (label.len > max_len) max_len = label.len;
    }

    const row_buffer = std.heap.page_allocator.alloc(usize, max_len + 1) catch return;
    defer std.heap.page_allocator.free(row_buffer);

    const ignore_case = !util.hasUpperAscii(query);
    for (labels, 0..) |label, idx| {
        var already_matched = false;
        for (matches.items) |match| {
            if (match.index == idx) {
                already_matched = true;
                break;
            }
        }
        if (already_matched) continue;
        const distance = bestWordDistance(query, label, row_buffer, ignore_case);
        if (distance <= levenshtein_distance_threshold) {
            matches.appendAssumeCapacity(.{
                .index = idx,
                .score = distanceScore(distance),
            });
        }
    }
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// smallest distance from the query to any word of the label; row needs
/// label.len + 1 slots
fn bestWordDistance(query: []const u8, label: []const u8, row: []usize, ignore_case: bool) usize {
    var best: usize = std.math.maxInt(usize);
    var i: usize = 0;
    while (i < label.len) {
        if (!isWordByte(label[i])) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < label.len and isWordByte(label[end])) end += 1;
        const word = label[i..end];
        i = end;
        // distance is at least the length gap, so skip guaranteed misses
        const len_gap = @max(word.len, query.len) - @min(word.len, query.len);
        if (len_gap > levenshtein_distance_threshold) continue;
        best = @min(best, levenshteinDistance(query, word, row[0 .. word.len + 1], ignore_case));
    }
    return best;
}

fn levenshteinDistance(a: []const u8, b: []const u8, row: []usize, ignore_case: bool) usize {
    const b_len = b.len;
    var j: usize = 0;
    while (j <= b_len) : (j += 1) {
        row[j] = j;
    }

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        var prev = row[0];
        row[0] = i + 1;
        j = 0;
        while (j < b_len) : (j += 1) {
            const old = row[j + 1];
            const cost: usize = if (util.charsEqual(a[i], b[j], ignore_case)) 0 else 1;
            const deletion = old + 1;
            const insertion = row[j] + 1;
            const substitution = prev + cost;
            row[j + 1] = @min(deletion, @min(insertion, substitution));
            prev = old;
        }
    }

    return row[b_len];
}

fn distanceScore(distance: usize) i32 {
    const capped: i32 = if (distance > std.math.maxInt(i32)) std.math.maxInt(i32) else @as(i32, @intCast(distance));
    return -capped;
}

test "fallback keeps words at the length-difference boundary" {
    var buf: [8]types.Match = undefined;
    var matches = std.ArrayList(types.Match).initBuffer(&buf);
    // "abcd" -> "abcdef" is two insertions; "abcdefg" is three and must be dropped
    appendFallbackMatches(&.{ "abcdef", "abcdefg", "xbcd", "abc" }, "abcd", &matches);
    try std.testing.expectEqual(@as(usize, 3), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].index);
    try std.testing.expectEqual(@as(i32, -2), matches.items[0].score);
    try std.testing.expectEqual(@as(usize, 2), matches.items[1].index);
    try std.testing.expectEqual(@as(usize, 3), matches.items[2].index);
}

test "fallback ignores queries shorter than four chars" {
    var buf: [8]types.Match = undefined;
    var matches = std.ArrayList(types.Match).initBuffer(&buf);
    appendFallbackMatches(&.{ "ab", "abc", "xyz" }, "abc", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "fallback compares against label words, not the whole label" {
    var buf: [8]types.Match = undefined;
    var matches = std.ArrayList(types.Match).initBuffer(&buf);
    appendFallbackMatches(&.{ "Google Chrome Dev", "Safari", "Chromium - release notes" }, "chrme", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].index);
    try std.testing.expectEqual(@as(i32, -1), matches.items[0].score);
}
