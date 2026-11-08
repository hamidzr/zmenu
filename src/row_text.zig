//! The text of a list row: the label, then the subtitle after two spaces, as one
//! string so tail truncation cuts the subtitle before the label. Highlight
//! ranges are byte ranges of the label and of the subtitle separately; this maps
//! them onto the joined string's UTF-16 offsets (NSRange units).

const std = @import("std");
const highlight = @import("search/highlight.zig");

pub const separator = "  ";

/// label ++ separator ++ subtitle, NUL-terminated
pub fn compose(allocator: std.mem.Allocator, label: []const u8, subtitle: []const u8) std.mem.Allocator.Error![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{ label, separator, subtitle }, 0);
}

pub const Span = struct {
    location: usize,
    length: usize,
};

/// UTF-16 span of a label byte range
pub fn labelSpan(label: []const u8, range: highlight.Range) Span {
    return .{
        .location = highlight.utf16Len(label[0..range.start]),
        .length = highlight.utf16Len(label[range.start..range.end]),
    };
}

/// UTF-16 span of the whole subtitle in the joined string
pub fn subtitleSpan(label: []const u8, subtitle: []const u8) Span {
    return .{
        .location = highlight.utf16Len(label) + separator.len,
        .length = highlight.utf16Len(subtitle),
    };
}

/// UTF-16 span of a subtitle byte range in the joined string
pub fn subtitleRangeSpan(label: []const u8, subtitle: []const u8, range: highlight.Range) Span {
    return .{
        .location = highlight.utf16Len(label) + separator.len + highlight.utf16Len(subtitle[0..range.start]),
        .length = highlight.utf16Len(subtitle[range.start..range.end]),
    };
}

test "compose joins label and subtitle with two spaces" {
    const text = try compose(std.testing.allocator, "Inbox - Gmail", "Safari");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Inbox - Gmail  Safari", text);
    try std.testing.expectEqual(@as(u8, 0), text[text.len]);
}

test "spans are in UTF-16 units of the joined string" {
    // "é" is two bytes, one unit; the emoji is four bytes, two units
    const label = "Caf\u{e9} \u{1F600}";
    const subtitle = "na\u{ef}ve web";
    const label_span = labelSpan(label, .{ .start = 3, .end = 5 });
    try std.testing.expectEqual(@as(usize, 3), label_span.location);
    try std.testing.expectEqual(@as(usize, 1), label_span.length);

    const whole = subtitleSpan(label, subtitle);
    // "Caf" + e-acute + space + surrogate pair = 7 units, then two spaces
    try std.testing.expectEqual(@as(usize, 9), whole.location);
    try std.testing.expectEqual(@as(usize, 9), whole.length);

    // "web" starts after "na" + i-diaeresis (2 bytes) + "ve " = 6 units
    const web = subtitleRangeSpan(label, subtitle, .{ .start = 7, .end = 10 });
    try std.testing.expectEqual(@as(usize, 9 + 6), web.location);
    try std.testing.expectEqual(@as(usize, 3), web.length);
}
