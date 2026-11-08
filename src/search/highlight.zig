//! Which parts of a label the query matched, for drawing them emphasized. The
//! rules are `rank.zig`'s: per space-separated token, a substring hit shows the
//! substring, an acronym shows the word-start letters, a loose subsequence shows
//! the matched letters. Matching runs on folded text (see `fold.zig`), whose
//! byte offsets differ from the label, so folded positions are mapped back to
//! byte ranges of the original label. Only called for rows being drawn.

const std = @import("std");
const fold = @import("fold.zig");
const rank = @import("rank.zig");
const types = @import("types.zig");

/// byte range `start..end` of the original label
pub const Range = struct {
    start: usize,
    end: usize,
};

/// longer labels, or queries, get no highlight
pub const max_label_bytes: usize = 512;
pub const max_query_bytes: usize = 256;

/// Ranges (ascending, non-overlapping, on UTF-8 boundaries) of `label` matched by
/// `query`; empty when the query is blank or nothing matches. Writes into `out`
/// and returns the used prefix, dropping ranges that do not fit.
pub fn matchRanges(label: []const u8, query: []const u8, method: types.SearchMethod, out: []Range) []Range {
    const none = out[0..0];
    // offsets are only meaningful for text that converts to a string unchanged
    if (!std.unicode.utf8ValidateSlice(label)) return none;
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_query_bytes or label.len > max_label_bytes) return none;

    var text_buf: [max_label_bytes]u8 = undefined;
    var starts: [max_label_bytes]u32 = undefined;
    var ends: [max_label_bytes]u32 = undefined;
    const folded = fold.foldWithMap(&text_buf, &starts, &ends, label) orelse return none;

    var query_buf: [max_query_bytes]u8 = undefined;
    const folded_query = fold.foldBuf(&query_buf, trimmed);

    var mask: [max_label_bytes]bool = @splat(false);
    var positions: [max_label_bytes]usize = undefined;
    switch (method) {
        .fuzzy, .default => {
            var tokens = std.mem.splitScalar(u8, folded_query, ' ');
            while (tokens.next()) |token| {
                const hit = rank.tokenPositions(token, folded, &positions) orelse continue;
                for (hit) |index| mask[index] = true;
            }
        },
        // these match the whole query as one substring
        .direct, .fuzzy3, .fuzzy1 => {
            const at = std.ascii.findIgnoreCase(folded, folded_query) orelse return none;
            @memset(mask[at .. at + folded_query.len], true);
        },
    }

    var count: usize = 0;
    var i: usize = 0;
    while (i < folded.len) {
        if (!mask[i]) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < folded.len and mask[end]) end += 1;
        const range = snapToChars(label, starts[i], ends[end - 1]);
        i = end;

        // folded bytes of one original letter (a ligature) can split into runs
        if (count > 0 and range.start <= out[count - 1].end) {
            out[count - 1].end = @max(out[count - 1].end, range.end);
            continue;
        }
        if (count == out.len) break;
        out[count] = range;
        count += 1;
    }
    return out[0..count];
}

/// widen to whole UTF-8 characters: a token's bytes can land inside a multi-byte letter
fn snapToChars(label: []const u8, start: usize, end: usize) Range {
    var s = start;
    var e = end;
    while (s > 0 and isContinuation(label[s])) s -= 1;
    while (e < label.len and isContinuation(label[e])) e += 1;
    return .{ .start = s, .end = e };
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// UTF-16 code units in valid UTF-8 text, to turn byte ranges into NSRange
pub fn utf16Len(text: []const u8) usize {
    var units: usize = 0;
    for (text) |byte| {
        if (isContinuation(byte)) continue;
        // a four-byte sequence is a surrogate pair
        units += if (byte >= 0xF0) 2 else 1;
    }
    return units;
}

fn expectRanges(label: []const u8, query: []const u8, expected: []const Range) !void {
    var out: [16]Range = undefined;
    const got = matchRanges(label, query, .fuzzy, &out);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| {
        try std.testing.expectEqual(want.start, have.start);
        try std.testing.expectEqual(want.end, have.end);
    }
}

test "substring match shows the substring" {
    try expectRanges("Safari", "saf", &.{.{ .start = 0, .end = 3 }});
    try expectRanges("Dash - safari docs", "SAFARI", &.{.{ .start = 7, .end = 13 }});
}

test "blank query and non-matches show nothing" {
    try expectRanges("Safari", "", &.{});
    try expectRanges("Safari", "   ", &.{});
    try expectRanges("Safari", "xyz", &.{});
}

test "every token is highlighted" {
    // "vs" is an acronym (V, S), "co" a substring of Code
    try expectRanges("Visual Studio Code", "vs co", &.{
        .{ .start = 0, .end = 1 },
        .{ .start = 7, .end = 8 },
        .{ .start = 14, .end = 16 },
    });
    try expectRanges("alpha bravo", "al br", &.{
        .{ .start = 0, .end = 2 },
        .{ .start = 6, .end = 8 },
    });
}

test "acronym shows the word-start letters" {
    try expectRanges("Visual Studio Code", "vsc", &.{
        .{ .start = 0, .end = 1 },
        .{ .start = 7, .end = 8 },
        .{ .start = 14, .end = 15 },
    });
}

test "loose subsequence shows the aligned letters" {
    try expectRanges("agenda", "agda", &.{
        .{ .start = 0, .end = 2 },
        .{ .start = 4, .end = 6 },
    });
    // a gap in the middle of the match
    try expectRanges("Safari", "safi", &.{
        .{ .start = 0, .end = 3 },
        .{ .start = 5, .end = 6 },
    });
}

test "adjacent matched letters merge into one range" {
    try expectRanges("Safari", "safari", &.{.{ .start = 0, .end = 6 }});
}

test "folded text maps back to original byte offsets" {
    // e-acute is two bytes in the label but one in folded text
    try expectRanges("Café Notes", "cafe", &.{.{ .start = 0, .end = 5 }});
    try expectRanges("Café Notes", "notes", &.{.{ .start = 6, .end = 11 }});
    try expectRanges("Zürich Hbf", "hbf", &.{.{ .start = 8, .end = 11 }});
    // ss in the query covers the whole sharp s
    try expectRanges("Straße Maps", "strasse", &.{.{ .start = 0, .end = 7 }});
    // half a ligature still highlights all of it
    try expectRanges("Straße Maps", "stras", &.{.{ .start = 0, .end = 6 }});
}

test "non-ascii letters are never split" {
    var out: [16]Range = undefined;
    const label = "日本語 menu";
    for (matchRanges(label, "本", .fuzzy, &out)) |range| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(label[range.start..range.end]));
    }
    for (matchRanges(label, "m", .fuzzy, &out)) |range| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(label[range.start..range.end]));
    }
}

test "direct method highlights the whole query as one substring" {
    var out: [4]Range = undefined;
    const got = matchRanges("alpha bravo", "ha br", .direct, &out);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(usize, 3), got[0].start);
    try std.testing.expectEqual(@as(usize, 8), got[0].end);
}

test "too many ranges are dropped, oversize labels get none" {
    var out: [1]Range = undefined;
    try std.testing.expectEqual(@as(usize, 1), matchRanges("a b c", "a b c", .fuzzy, &out).len);

    var long: [max_label_bytes + 1]u8 = undefined;
    @memset(&long, 'a');
    var big: [4]Range = undefined;
    try std.testing.expectEqual(@as(usize, 0), matchRanges(&long, "a", .fuzzy, &big).len);
}

test "utf16 length counts code units" {
    try std.testing.expectEqual(@as(usize, 4), utf16Len("abcd"));
    try std.testing.expectEqual(@as(usize, 4), utf16Len("Café"));
    try std.testing.expectEqual(@as(usize, 3), utf16Len("日本語"));
    try std.testing.expectEqual(@as(usize, 3), utf16Len("a\u{1F600}"));
}

test "invalid utf-8 gets no ranges" {
    var out: [4]Range = undefined;
    try std.testing.expectEqual(@as(usize, 0), matchRanges("caf\xe9 notes", "caf", .fuzzy, &out).len);
}
