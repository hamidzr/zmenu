const objc = @import("objc");
const objc_helpers = @import("objc_helpers.zig");
const state = @import("state.zig");

const NSRect = objc_helpers.NSRect;
const nsString = objc_helpers.nsString;
const nsColor = objc_helpers.nsColor;

pub const TextCellStyle = struct {
    identifier: [*:0]const u8,
    font: objc.Object,
    text_color: ?objc.Object,
    alignment: c_ulong,
    left_pad: f64,
    right_pad: f64,
};

/// Dequeue a reusable NSTableCellView, creating one when the reuse queue is empty.
fn makeCellView(table_view: objc.Object, identifier: [*:0]const u8) objc.Object {
    const reused = table_view.msgSend(objc.Object, "makeViewWithIdentifier:owner:", .{
        nsString(identifier),
        @as(objc.c.id, null),
    });
    if (reused.value != null) return reused;

    const NSTableCellView = objc.getClass("NSTableCellView").?;
    const cell = NSTableCellView.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 0, .height = 0 },
    }});
    cell.msgSend(void, "setIdentifier:", .{nsString(identifier)});
    return cell;
}

/// A single-label cell view. Reuses the label across dequeues.
pub fn textCell(table_view: objc.Object, row_height: f64, column_width: f64, style: TextCellStyle) objc.Object {
    const cell = makeCellView(table_view, style.identifier);
    var label = cell.msgSend(objc.Object, "textField", .{});
    if (label.value == null) {
        label = makeLabel(row_height, column_width, style);
        cell.msgSend(void, "addSubview:", .{label});
        cell.msgSend(void, "setTextField:", .{label});
    }
    return cell;
}

pub fn setCellText(cell: objc.Object, text: [*:0]const u8) void {
    const label = cell.msgSend(objc.Object, "textField", .{});
    if (label.value == null) return;
    label.msgSend(void, "setStringValue:", .{nsString(text)});
}

/// An icon-only cell view. Reuses the image view across dequeues.
pub fn iconCell(table_view: objc.Object, row_height: f64, column_width: f64, identifier: [*:0]const u8) objc.Object {
    const cell = makeCellView(table_view, identifier);
    var image_view = cell.msgSend(objc.Object, "imageView", .{});
    if (image_view.value == null) {
        image_view = makeImageView(row_height, column_width);
        cell.msgSend(void, "addSubview:", .{image_view});
        cell.msgSend(void, "setImageView:", .{image_view});
    }
    return cell;
}

pub fn setCellImage(cell: objc.Object, image: ?objc.Object) void {
    const image_view = cell.msgSend(objc.Object, "imageView", .{});
    if (image_view.value == null) return;
    const value = if (image) |img| img.value else null;
    image_view.msgSend(void, "setImage:", .{value});
}

fn makeLabel(row_height: f64, column_width: f64, style: TextCellStyle) objc.Object {
    const NSTextField = objc.getClass("NSTextField").?;
    const line_height = lineHeight(style.font);
    const width = @max(column_width - style.left_pad - style.right_pad, 0.0);
    const y = @max((row_height - line_height) / 2.0, 0.0);

    const label = NSTextField.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = style.left_pad, .y = y },
        .size = .{ .width = width, .height = line_height },
    }});
    label.msgSend(void, "setEditable:", .{false});
    label.msgSend(void, "setSelectable:", .{false});
    label.msgSend(void, "setBezeled:", .{false});
    label.msgSend(void, "setBordered:", .{false});
    label.msgSend(void, "setDrawsBackground:", .{false});
    label.msgSend(void, "setAlignment:", .{style.alignment});
    label.msgSend(void, "setFont:", .{style.font});
    if (style.text_color) |color| {
        label.msgSend(void, "setTextColor:", .{color});
    }
    label.msgSend(void, "setLineBreakMode:", .{@as(c_ulong, 2)}); // truncating tail
    // width flexible, vertically centred
    label.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 2 | 8 | 32)});
    return label;
}

fn makeImageView(row_height: f64, column_width: f64) objc.Object {
    const NSImageView = objc.getClass("NSImageView").?;
    const side = @max(@min(column_width, row_height) * 0.7, 12.0);
    const x = @max((column_width - side) / 2.0, 0.0);
    const y = @max((row_height - side) / 2.0, 0.0);

    const image_view = NSImageView.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = side, .height = side },
    }});
    image_view.msgSend(void, "setImageScaling:", .{@as(c_ulong, 3)}); // proportionally up or down
    // fixed size, centred both axes
    image_view.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1 | 4 | 8 | 32)});
    return image_view;
}

fn lineHeight(font: objc.Object) f64 {
    const ascender = font.msgSend(f64, "ascender", .{});
    const descender = font.msgSend(f64, "descender", .{});
    const leading = font.msgSend(f64, "leading", .{});
    const height = ascender - descender + leading;
    return if (height > 1.0) height else 16.0;
}

/// Custom NSTableRowView drawing, so `selection_color` applies. When no color is
/// configured it falls back to the system selection highlight.
pub fn rowViewDrawSelectionInRect(target: objc.c.id, sel: objc.c.SEL, dirty_rect: NSRect) callconv(.c) void {
    _ = sel;

    const app_state = state.g_state orelse {
        drawSystemSelection(target, dirty_rect);
        return;
    };
    const color = app_state.config.selection_color orelse {
        drawSystemSelection(target, dirty_rect);
        return;
    };

    const inset_x: f64 = 2.0;
    const inset_y: f64 = 1.0;
    const rect = NSRect{
        .origin = .{ .x = dirty_rect.origin.x + inset_x, .y = dirty_rect.origin.y + inset_y },
        .size = .{
            .width = @max(dirty_rect.size.width - inset_x * 2.0, 0.0),
            .height = @max(dirty_rect.size.height - inset_y * 2.0, 0.0),
        },
    };
    if (rect.size.width <= 0.0 or rect.size.height <= 0.0) return;

    nsColor(color).msgSend(void, "setFill", .{});
    const NSBezierPath = objc.getClass("NSBezierPath").?;
    const radius: f64 = 6.0;
    const path = NSBezierPath.msgSend(objc.Object, "bezierPathWithRoundedRect:xRadius:yRadius:", .{
        rect,
        radius,
        radius,
    });
    path.msgSend(void, "fill", .{});
}

fn drawSystemSelection(target: objc.c.id, dirty_rect: NSRect) void {
    if (target == null) return;
    const NSTableRowView = objc.getClass("NSTableRowView").?;
    objc.Object.fromId(target).msgSendSuper(NSTableRowView, void, "drawSelectionInRect:", .{dirty_rect});
}
