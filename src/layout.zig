//! Window sizing and placement as plain Zig. The window is a search field on
//! top of a list; its height follows the number of visible rows. AppKit
//! coordinates have the origin at the bottom left, so "top" means maxY.

const std = @import("std");
const geometry = @import("geometry.zig");

const Point = geometry.Point;
const Rect = geometry.Rect;

/// the window's top edge sits this far down from the top of the screen's visible frame
pub const top_fraction: f64 = 0.22;

pub const Metrics = struct {
    field_height: f64,
    padding: f64,
    row_height: f64,
    /// rows that fit in the configured (capped) window height, at least one
    max_rows: usize,

    pub fn init(max_window_height: f64, field_height: f64, padding: f64, row_height: f64) Metrics {
        const row = @max(row_height, 1.0);
        const list_height = max_window_height - field_height - padding * 3.0;
        const whole_rows = @floor(list_height / row);
        const max_rows: usize = if (whole_rows >= 1.0) @intFromFloat(whole_rows) else 1;
        return .{
            .field_height = field_height,
            .padding = padding,
            .row_height = row_height,
            .max_rows = max_rows,
        };
    }

    /// visible rows for `wanted` display rows: at least one, at most max_rows
    pub fn rows(self: Metrics, wanted: usize) usize {
        return std.math.clamp(wanted, 1, self.max_rows);
    }

    pub fn listHeight(self: Metrics, row_count: usize) f64 {
        return @as(f64, @floatFromInt(row_count)) * @max(self.row_height, 1.0);
    }

    /// window height without the footer bar
    pub fn windowHeight(self: Metrics, row_count: usize) f64 {
        return self.windowHeightFor(row_count, false);
    }

    /// Space below the list: the window padding, or the footer bar when shown
    /// (it takes the place of that padding).
    pub fn bottomInset(self: Metrics, footer: bool) f64 {
        return if (footer) footer_height + footer_gap else self.padding;
    }

    pub fn windowHeightFor(self: Metrics, row_count: usize, footer: bool) f64 {
        return self.field_height + self.padding * 2.0 + self.bottomInset(footer) + self.listHeight(row_count);
    }

    /// y of the list's bottom edge (AppKit origin at the bottom left)
    pub fn listY(self: Metrics, footer: bool) f64 {
        return self.bottomInset(footer);
    }
};

/// height of the hint bar at the bottom of the window, and the space between it and the list
pub const footer_height: f64 = 32.0;
pub const footer_gap: f64 = 6.0;
/// the hint text starts this far in from the list's left edge
pub const footer_text_inset: f64 = 12.0;

/// Header geometry: the search field, the optional loading spinner and the
/// counter share one line. The counter grows with its text (a scope label makes
/// it longer) and the search field gives way.
pub const counter_min_width: f64 = 88.0;
const counter_text_pad: f64 = 4.0;
const counter_max_fraction: f64 = 0.45;
pub const counter_right_inset: f64 = 12.0;
pub const spinner_side: f64 = 16.0;
const spinner_gap: f64 = 6.0;
const field_gap: f64 = 10.0;

pub const Header = struct {
    /// width of the search text field
    search_width: f64,
    counter_x: f64,
    counter_width: f64,
    spinner_x: f64,
};

/// `padding` is the window margin, `text_inset` the search field's indent in its
/// background, `text_width` the counter text's natural width.
pub fn header(padding: f64, list_width: f64, text_inset: f64, text_width: f64, spinner: bool) Header {
    const counter_width = std.math.clamp(text_width + counter_text_pad, counter_min_width, @max(list_width * counter_max_fraction, counter_min_width));
    const counter_x = padding + list_width - counter_right_inset - counter_width;
    // the spinner hugs the text (right-aligned in a column that may be wider), never leaving the column
    const text_left = @max(counter_x + counter_width - text_width - counter_text_pad / 2.0, counter_x);
    const spinner_x = text_left - spinner_gap - spinner_side;
    const right_limit = if (spinner) @min(spinner_x, counter_x) else counter_x;
    const field_x = padding + text_inset;
    return .{
        .search_width = @max(right_limit - field_gap - field_x, 0.0),
        .counter_x = counter_x,
        .counter_width = counter_width,
        .spinner_x = spinner_x,
    };
}

/// a row's detail text takes at most this share of the row width
pub const detail_max_fraction: f64 = 0.30;

/// gap between the label area and the detail text
pub const detail_gap: f64 = 8.0;

/// Width given to the detail text: its own width, at most `detail_max_fraction`
/// of the row. Longer text is tail-truncated inside that width.
pub fn detailWidth(text_width: f64, row_width: f64) f64 {
    return detailWidthUpTo(text_width, row_width, detail_max_fraction);
}

/// a confirm prompt replaces the detail and may take this share of the row
pub const prompt_max_fraction: f64 = 0.62;

pub fn detailWidthUpTo(text_width: f64, row_width: f64, fraction: f64) f64 {
    const limit = @max(row_width, 0.0) * fraction;
    return @min(@max(text_width, 0.0), limit);
}

/// index of the screen frame containing the point (the mouse pointer)
pub fn screenIndexAt(frames: []const Rect, point: Point) ?usize {
    for (frames, 0..) |frame, index| {
        if (frame.contains(point)) return index;
    }
    return null;
}

/// Horizontally centred in `visible`, top edge `top_fraction` down from its top.
/// `max_height` is the tallest the window gets: the top is lifted when it would
/// not fit below, so growing never runs off the bottom of a small screen.
/// Returns the window's top-left corner.
pub fn topLeftIn(visible: Rect, width: f64, max_height: f64) Point {
    const centered = visible.minX() + (visible.size.width - width) / 2.0;
    const x = @max(centered, visible.minX());
    const wanted_top = visible.maxY() - visible.size.height * top_fraction;
    const lowest_top = visible.minY() + max_height;
    const top = @min(@max(wanted_top, lowest_top), visible.maxY());
    return .{ .x = x, .y = top };
}

test "metrics match the legacy fixed layout at the default height" {
    const metrics = Metrics.init(450, 44, 14, 34);
    try std.testing.expectEqual(@as(usize, 10), metrics.max_rows);
    try std.testing.expectEqual(@as(f64, 44 + 42 + 340), metrics.windowHeight(10));
}

test "the footer bar replaces the bottom padding" {
    const metrics = Metrics.init(450, 44, 14, 34);
    try std.testing.expectEqual(metrics.windowHeight(3), metrics.windowHeightFor(3, false));
    try std.testing.expectEqual(metrics.windowHeight(3) - 14 + footer_height + footer_gap, metrics.windowHeightFor(3, true));
    try std.testing.expectEqual(@as(f64, 14), metrics.listY(false));
    try std.testing.expectEqual(footer_height + footer_gap, metrics.listY(true));
    // the list's top edge is the same distance below the window top either way
    const top_gap_plain = metrics.windowHeightFor(3, false) - (metrics.listY(false) + metrics.listHeight(3));
    const top_gap_footer = metrics.windowHeightFor(3, true) - (metrics.listY(true) + metrics.listHeight(3));
    try std.testing.expectEqual(top_gap_plain, top_gap_footer);
}

test "rows clamp between one and max_rows" {
    const metrics = Metrics.init(450, 44, 14, 34);
    try std.testing.expectEqual(@as(usize, 1), metrics.rows(0));
    try std.testing.expectEqual(@as(usize, 2), metrics.rows(2));
    try std.testing.expectEqual(@as(usize, 10), metrics.rows(500));
    try std.testing.expectEqual(@as(f64, 44 + 42 + 68), metrics.windowHeight(metrics.rows(2)));
}

test "a window shorter than one row still shows one row" {
    const metrics = Metrics.init(60, 44, 14, 34);
    try std.testing.expectEqual(@as(usize, 1), metrics.max_rows);
}

test "screen under the pointer, with a second screen to the left" {
    const frames = [_]Rect{
        .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1440, .height = 900 } },
        .{ .origin = .{ .x = -1920, .y = -100 }, .size = .{ .width = 1920, .height = 1080 } },
    };
    try std.testing.expectEqual(@as(?usize, 0), screenIndexAt(&frames, .{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(?usize, 1), screenIndexAt(&frames, .{ .x = -5, .y = 500 }));
    try std.testing.expectEqual(@as(?usize, null), screenIndexAt(&frames, .{ .x = 5000, .y = 0 }));
    // the shared edge belongs to the right-hand screen only
    try std.testing.expectEqual(@as(?usize, 0), screenIndexAt(&frames, .{ .x = 0, .y = 50 }));
}

test "top-left is centred and 22 percent down" {
    const visible = Rect{ .origin = .{ .x = 100, .y = 0 }, .size = .{ .width = 1000, .height = 800 } };
    const p = topLeftIn(visible, 600, 426);
    try std.testing.expectEqual(@as(f64, 300), p.x);
    try std.testing.expectEqual(@as(f64, 800 - 176), p.y);
}

test "top is lifted so the tallest window fits below it" {
    const visible = Rect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1000, .height = 500 } };
    const p = topLeftIn(visible, 600, 426);
    try std.testing.expectEqual(@as(f64, 426), p.y);
    // taller than the screen: pinned to the top edge
    const tall = topLeftIn(visible, 600, 900);
    try std.testing.expectEqual(@as(f64, 500), tall.y);
}

test "a window wider than the screen starts at the left edge" {
    const visible = Rect{ .origin = .{ .x = 50, .y = 0 }, .size = .{ .width = 400, .height = 800 } };
    try std.testing.expectEqual(@as(f64, 50), topLeftIn(visible, 600, 100).x);
}

test "detail takes its own width up to 30 percent of the row" {
    try std.testing.expectEqual(@as(f64, 24), detailWidth(24, 600));
    try std.testing.expectEqual(@as(f64, 180), detailWidth(400, 600));
    try std.testing.expectEqual(@as(f64, 0), detailWidth(-3, 600));
    try std.testing.expectEqual(@as(f64, 0), detailWidth(50, -10));
}

test "a prompt may use more of the row than a detail" {
    try std.testing.expectEqual(@as(f64, 372), detailWidthUpTo(500, 600, prompt_max_fraction));
    try std.testing.expectEqual(@as(f64, 180), detailWidthUpTo(500, 600, detail_max_fraction));
    try std.testing.expectEqual(@as(f64, 90), detailWidthUpTo(90, 600, prompt_max_fraction));
}

test "default header matches the fixed 100pt counter column" {
    const h = header(14, 872, 10, 40, false);
    try std.testing.expectEqual(@as(f64, 88), h.counter_width);
    try std.testing.expectEqual(@as(f64, 14 + 872 - 100), h.counter_x);
    // field spans from its inset to 10pt short of the counter column
    try std.testing.expectEqual(@as(f64, (14 + 872 - 100) - 10 - 24), h.search_width);
}

test "a long counter widens its column and narrows the search field" {
    const narrow = header(14, 872, 10, 60, false);
    const wide = header(14, 872, 10, 150, false);
    try std.testing.expectEqual(@as(f64, 154), wide.counter_width);
    try std.testing.expect(wide.counter_x < narrow.counter_x);
    try std.testing.expect(wide.search_width < narrow.search_width);
    // never past 45% of the list
    const huge = header(14, 872, 10, 5000, false);
    try std.testing.expectApproxEqAbs(@as(f64, 392.4), huge.counter_width, 1e-9);
}

test "the spinner sits left of the counter text and takes room from the field" {
    const plain = header(14, 872, 10, 60, false);
    const spun = header(14, 872, 10, 60, true);
    try std.testing.expectEqual(plain.counter_x, spun.counter_x);
    // text is 60 wide in an 88 wide column: the spinner sits 6 before the text's left edge
    try std.testing.expectEqual(plain.counter_x + 88 - 60 - 2 - 6 - 16, spun.spinner_x);
    try std.testing.expect(spun.search_width <= plain.search_width);
    try std.testing.expect(spun.spinner_x + spinner_side < plain.counter_x + plain.counter_width);
}

test "with a wide counter text the spinner narrows the search field" {
    const plain = header(14, 872, 10, 200, false);
    const spun = header(14, 872, 10, 200, true);
    try std.testing.expect(spun.search_width < plain.search_width);
}

test "a tiny list never gets negative widths" {
    const h = header(14, 60, 10, 200, true);
    try std.testing.expect(h.search_width >= 0);
    try std.testing.expect(h.counter_width >= counter_min_width);
}
