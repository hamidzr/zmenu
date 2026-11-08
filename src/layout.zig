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

    pub fn windowHeight(self: Metrics, row_count: usize) f64 {
        return self.field_height + self.padding * 3.0 + self.listHeight(row_count);
    }
};

/// a row's detail text takes at most this share of the row width
pub const detail_max_fraction: f64 = 0.30;

/// gap between the label area and the detail text
pub const detail_gap: f64 = 8.0;

/// Width given to the detail text: its own width, at most `detail_max_fraction`
/// of the row. Longer text is tail-truncated inside that width.
pub fn detailWidth(text_width: f64, row_width: f64) f64 {
    const limit = @max(row_width, 0.0) * detail_max_fraction;
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
