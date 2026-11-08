const objc = @import("objc");
const objc_helpers = @import("objc_helpers.zig");
const highlight = @import("../search/highlight.zig");
const state = @import("state.zig");

const NSRect = objc_helpers.NSRect;
const NSPoint = objc_helpers.NSPoint;
const nsString = objc_helpers.nsString;
const nsColor = objc_helpers.nsColor;
const lineHeight = objc_helpers.lineHeight;
const label_optical_offset = objc_helpers.label_optical_offset;

const ns_line_break_truncating_tail: c_ulong = 4;

pub const TextCellStyle = struct {
    identifier: [*:0]const u8,
    font: objc.Object,
    text_color: objc.Object,
    alignment: c_ulong,
    left_pad: f64,
    right_pad: f64,
};

/// Dequeue a reusable NSTableCellView, creating one when the reuse queue is empty.
/// The frame is seeded with the real cell size: cells created at 0x0 get their
/// subviews re-centred by AppKit autoresizing, which pushed rows off-axis.
fn makeCellView(table_view: objc.Object, identifier: [*:0]const u8, row_height: f64, column_width: f64) objc.Object {
    const reused = table_view.msgSend(objc.Object, "makeViewWithIdentifier:owner:", .{
        nsString(identifier),
        @as(objc.c.id, null),
    });
    if (reused.value != null) return reused;

    const NSTableCellView = objc.getClass("NSTableCellView").?;
    const cell = NSTableCellView.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = column_width, .height = row_height },
    }});
    cell.msgSend(void, "setIdentifier:", .{nsString(identifier)});
    return cell;
}

/// A single-label cell view. Reuses the label across dequeues.
pub fn textCell(table_view: objc.Object, row_height: f64, column_width: f64, style: TextCellStyle) objc.Object {
    const cell = makeCellView(table_view, style.identifier, row_height, column_width);
    var label = cell.msgSend(objc.Object, "textField", .{});
    if (label.value == null) {
        label = makeLabel(row_height, column_width, style);
        cell.msgSend(void, "addSubview:", .{label});
        cell.msgSend(void, "setTextField:", .{label});
    }
    return cell;
}

pub fn setCellText(cell: objc.Object, text: [*:0]const u8, color: objc.Object) void {
    const label = cell.msgSend(objc.Object, "textField", .{});
    if (label.value == null) return;
    label.msgSend(void, "setStringValue:", .{nsString(text)});
    label.msgSend(void, "setTextColor:", .{color});
}

/// Text on the selection fill is white (or the configured text color), so the
/// two rows whose selected state changed need new colors; cells are not reloaded
/// for that. Call after any selection change.
pub fn restyleSelection(app_state: *state.AppState) void {
    const previous = app_state.styled_selected_row;
    const current = app_state.model.selectedRow();
    app_state.styled_selected_row = current;
    if (previous) |row| restyleRow(app_state, row);
    if (current) |row| {
        if (row != previous) restyleRow(app_state, row);
    }
}

fn restyleRow(app_state: *state.AppState, row: usize) void {
    if (row >= app_state.model.rowCount()) return;
    const selected = app_state.model.selectedRow() == row;
    const palette = app_state.palette;
    if (cellAt(app_state, "index", row)) |cell| {
        const label = cell.msgSend(objc.Object, "textField", .{});
        label.msgSend(void, "setTextColor:", .{if (selected) palette.selected_secondary else palette.secondary});
    }
    if (cellAt(app_state, "items", row)) |cell| configureItemCell(app_state, cell, row);
}

fn cellAt(app_state: *state.AppState, identifier: [*:0]const u8, row: usize) ?objc.Object {
    const column = app_state.table_view.msgSend(c_long, "columnWithIdentifier:", .{nsString(identifier)});
    if (column < 0) return null;
    const cell = app_state.table_view.msgSend(objc.Object, "viewAtColumn:row:makeIfNecessary:", .{
        column,
        @as(c_long, @intCast(row)),
        false,
    });
    if (cell.value == null or cell.msgSend(objc.Object, "textField", .{}).value == null) return null;
    return cell;
}

/// Sets a row label with the query's matched characters bold, and tinted with
/// the accent color unless the row is selected (accent on the selection fill is
/// unreadable). Rows without matches keep the plain string.
pub fn configureItemCell(app_state: *state.AppState, cell: objc.Object, row: usize) void {
    const label_view = cell.msgSend(objc.Object, "textField", .{});
    if (label_view.value == null) return;
    const label = app_state.model.rowItem(row).label;
    const selected = app_state.model.selectedRow() == row;
    const palette = app_state.palette;
    const color = if (selected) palette.selected_text else palette.text;

    var buffer: [max_highlight_ranges]highlight.Range = undefined;
    const ranges = highlight.matchRanges(label, state.currentQuery(app_state), app_state.config.search.method, &buffer);
    if (ranges.len == 0) {
        label_view.msgSend(void, "setStringValue:", .{nsString(label)});
        label_view.msgSend(void, "setFont:", .{app_state.row_font});
        label_view.msgSend(void, "setTextColor:", .{color});
        return;
    }
    label_view.msgSend(void, "setAttributedStringValue:", .{
        highlightedString(app_state, label, ranges, color, if (selected) null else palette.accent),
    });
}

const max_highlight_ranges = 16;

const NSRange = extern struct {
    location: c_ulong,
    length: c_ulong,
};

fn highlightedString(
    app_state: *state.AppState,
    label: [:0]const u8,
    ranges: []const highlight.Range,
    color: objc.Object,
    tint: ?objc.Object,
) objc.Object {
    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSMutableParagraphStyle = objc.getClass("NSMutableParagraphStyle").?;
    const NSMutableAttributedString = objc.getClass("NSMutableAttributedString").?;

    // an attributed string carries its own line breaking; keep the label's tail truncation
    const paragraph = NSMutableParagraphStyle.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    _ = paragraph.msgSend(objc.Object, "autorelease", .{});
    paragraph.msgSend(void, "setLineBreakMode:", .{ns_line_break_truncating_tail});
    const attributes = NSMutableDictionary.msgSend(objc.Object, "dictionary", .{});
    attributes.msgSend(void, "setObject:forKey:", .{ app_state.row_font, nsString("NSFont") });
    attributes.msgSend(void, "setObject:forKey:", .{ color, nsString("NSColor") });
    attributes.msgSend(void, "setObject:forKey:", .{ paragraph, nsString("NSParagraphStyle") });

    const attributed = NSMutableAttributedString.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithString:attributes:", .{ nsString(label), attributes });
    for (ranges) |range| {
        const location = highlight.utf16Len(label[0..range.start]);
        const ns_range = NSRange{ .location = location, .length = highlight.utf16Len(label[range.start..range.end]) };
        attributed.msgSend(void, "addAttribute:value:range:", .{ nsString("NSFont"), app_state.bold_font, ns_range });
        if (tint) |accent| {
            attributed.msgSend(void, "addAttribute:value:range:", .{ nsString("NSColor"), accent, ns_range });
        }
    }
    return attributed.msgSend(objc.Object, "autorelease", .{});
}

/// An icon-only cell view. Reuses the image view across dequeues.
pub fn iconCell(table_view: objc.Object, row_height: f64, column_width: f64, identifier: [*:0]const u8) objc.Object {
    const cell = makeCellView(table_view, identifier, row_height, column_width);
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
    // NSTextFieldCell adds a small top inset, so shift up slightly to land glyphs
    // on the row's vertical axis.
    const y = (row_height - line_height) / 2.0 + label_optical_offset;

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
    label.msgSend(void, "setTextColor:", .{style.text_color});
    label.msgSend(void, "setLineBreakMode:", .{ns_line_break_truncating_tail});
    // width flexible, height fixed
    label.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 2)});
    return label;
}

pub fn iconSide(row_height: f64, column_width: f64) f64 {
    return @max(@min(column_width, row_height) * 0.8, 12.0);
}

fn makeImageView(row_height: f64, column_width: f64) objc.Object {
    const NSImageView = objc.getClass("NSImageView").?;
    const side = iconSide(row_height, column_width);
    const x = @max((column_width - side) / 2.0, 0.0);
    const y = @max((row_height - side) / 2.0, 0.0);

    const image_view = NSImageView.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = side, .height = side },
    }});
    image_view.msgSend(void, "setImageScaling:", .{@as(c_ulong, 3)}); // proportionally up or down
    // fixed size; flexible horizontal margins keep it centred when the column
    // width changes, fixed vertical margins stop AppKit re-centring it low
    image_view.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1 | 4)});
    return image_view;
}

/// Custom NSTableRowView drawing, so the selection fill (`selection_color`, else
/// the system selection color) and hover both apply.
pub fn rowViewDrawSelectionInRect(target: objc.c.id, sel: objc.c.SEL, dirty_rect: NSRect) callconv(.c) void {
    _ = target;
    _ = sel;
    const app_state = state.g_state orelse return;
    _ = paintRowFill(dirty_rect, app_state.palette.selection_fill);
}

/// Paints the hover fill under the pointer. Selection wins, so a selected row
/// keeps its solid highlight. Super draws first to keep alternating rows intact.
pub fn rowViewDrawBackgroundInRect(target: objc.c.id, sel: objc.c.SEL, dirty_rect: NSRect) callconv(.c) void {
    _ = sel;
    if (target == null) return;

    const NSTableRowView = objc.getClass("NSTableRowView").?;
    const row_view = objc.Object.fromId(target);
    row_view.msgSendSuper(NSTableRowView, void, "drawBackgroundInRect:", .{dirty_rect});

    if (row_view.msgSend(bool, "isSelected", .{})) return;

    const app_state = state.g_state orelse return;
    const hovered = app_state.hovered_row orelse return;
    const row = app_state.table_view.msgSend(c_long, "rowForView:", .{target});
    if (row < 0) return;
    if (@as(usize, @intCast(row)) != hovered) return;

    const color = hoverFillColor() orelse return;
    _ = paintRowFill(dirty_rect, color);
}

/// Pointer hover is a muted version of the selection color, or a faint
/// neutral fill when the selection uses the system color.
fn hoverFillColor() ?objc.Object {
    const app_state = state.g_state orelse return null;
    return app_state.palette.hover_fill;
}

fn paintRowFill(dirty_rect: NSRect, color: objc.Object) bool {
    const inset_x: f64 = 4.0;
    const inset_y: f64 = 2.0;
    const rect = NSRect{
        .origin = .{ .x = dirty_rect.origin.x + inset_x, .y = dirty_rect.origin.y + inset_y },
        .size = .{
            .width = @max(dirty_rect.size.width - inset_x * 2.0, 0.0),
            .height = @max(dirty_rect.size.height - inset_y * 2.0, 0.0),
        },
    };
    if (rect.size.width <= 0.0 or rect.size.height <= 0.0) return false;

    color.msgSend(void, "setFill", .{});
    const NSBezierPath = objc.getClass("NSBezierPath").?;
    const radius: f64 = 8.0;
    const path = NSBezierPath.msgSend(objc.Object, "bezierPathWithRoundedRect:xRadius:yRadius:", .{
        rect,
        radius,
        radius,
    });
    path.msgSend(void, "fill", .{});
    return true;
}

/// Movement tracking is table-wide, so only the rows changing state are redrawn.
pub fn setHoveredRow(app_state: *state.AppState, row: ?usize) void {
    if (app_state.hovered_row == row) return;
    const previous = app_state.hovered_row;
    app_state.hovered_row = row;
    if (previous) |old| redrawRow(app_state, old);
    if (row) |new| redrawRow(app_state, new);
}

/// Resolves the row under a point given in window coordinates. Scrolling calls
/// this too, so the highlight tracks the row under a stationary pointer.
pub fn refreshHoverAtWindowPoint(app_state: *state.AppState, window_point: NSPoint) void {
    const local_point = app_state.table_view.msgSend(NSPoint, "convertPoint:fromView:", .{
        window_point,
        @as(objc.c.id, null),
    });
    const row = app_state.table_view.msgSend(c_long, "rowAtPoint:", .{local_point});
    setHoveredRow(app_state, if (row < 0) null else @intCast(row));
}

fn redrawRow(app_state: *state.AppState, row: usize) void {
    if (row >= app_state.model.rowCount()) return;
    const row_view = app_state.table_view.msgSend(objc.Object, "rowViewAtRow:makeIfNecessary:", .{
        @as(c_long, @intCast(row)),
        false,
    });
    if (row_view.value == null) return;
    row_view.msgSend(void, "setNeedsDisplay:", .{true});
}

fn rowViewClass() objc.Class {
    if (objc.getClass("ZigTableRowView")) |cls| return cls;

    const NSTableRowView = objc.getClass("NSTableRowView").?;
    const cls = objc.allocateClassPair(NSTableRowView, "ZigTableRowView").?;
    if (!cls.addMethod("drawSelectionInRect:", rowViewDrawSelectionInRect)) {
        @panic("failed to add drawSelectionInRect: method");
    }
    if (!cls.addMethod("drawBackgroundInRect:", rowViewDrawBackgroundInRect)) {
        @panic("failed to add drawBackgroundInRect: method");
    }
    objc.registerClassPair(cls);
    return cls;
}

pub fn makeRowView() objc.Object {
    const cls = rowViewClass();
    return cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 0, .height = 0 },
    }});
}
