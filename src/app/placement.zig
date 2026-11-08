const objc = @import("objc");
const geometry = @import("../geometry.zig");
const layout = @import("../layout.zig");

const max_screens = 16;

/// Puts the window on the screen holding the mouse pointer (the main screen
/// when none does), centred horizontally with its top edge a fixed fraction
/// down the visible frame. The top stays put while the height changes.
pub fn placeOnPointerScreen(window: objc.Object, max_height: f64) void {
    const NSEvent = objc.getClass("NSEvent").?;
    const NSScreen = objc.getClass("NSScreen").?;
    const mouse = NSEvent.msgSend(geometry.Point, "mouseLocation", .{});

    var frames: [max_screens]geometry.Rect = undefined;
    var visibles: [max_screens]geometry.Rect = undefined;
    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    const total = screens.msgSend(c_ulong, "count", .{});
    const count: usize = @min(total, max_screens);
    for (0..count) |index| {
        const screen = screens.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, index)});
        frames[index] = screen.msgSend(geometry.Rect, "frame", .{});
        visibles[index] = screen.msgSend(geometry.Rect, "visibleFrame", .{});
    }

    const visible = if (layout.screenIndexAt(frames[0..count], mouse)) |index|
        visibles[index]
    else blk: {
        const main = NSScreen.msgSend(objc.Object, "mainScreen", .{});
        if (main.value == null) return;
        break :blk main.msgSend(geometry.Rect, "visibleFrame", .{});
    };

    const frame = window.msgSend(geometry.Rect, "frame", .{});
    const top_left = layout.topLeftIn(visible, frame.size.width, max_height);
    window.msgSend(void, "setFrameOrigin:", .{geometry.Point{ .x = top_left.x, .y = top_left.y - frame.size.height }});
}
