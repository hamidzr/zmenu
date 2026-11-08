const std = @import("std");
const objc = @import("objc");
const layout = @import("../layout.zig");
const objc_helpers = @import("objc_helpers.zig");
const highlight = @import("../search/highlight.zig");
const row_text = @import("../row_text.zig");
const state = @import("state.zig");

const NSRect = objc_helpers.NSRect;
const NSPoint = objc_helpers.NSPoint;
const NSSize = objc_helpers.NSSize;
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

/// right padding of the item text inside the cell, shared with the cell setup
pub const item_right_pad: f64 = 6.0;

/// tag of the detail text field inside an item cell, to find it again on reuse
const detail_tag: c_long = 0x7a64;

const max_highlight_ranges = 16;

const NSRange = extern struct {
    location: c_ulong,
    length: c_ulong,
};

// NSTextAlignmentRight (AppKit: left 0, right 1, center 2)
const ns_text_alignment_right: c_ulong = 1;

/// Fills a row's item cell: the label with the query's matched characters bold
/// and tinted with the accent color (not on the selection fill, where accent is
/// unreadable), the subtitle dim after it, and the detail dim at the right.
/// Rows without matches or subtitle keep the plain string.
pub fn configureItemCell(app_state: *state.AppState, cell: objc.Object, row: usize) void {
    const label_view = cell.msgSend(objc.Object, "textField", .{});
    if (label_view.value == null) return;
    const model = &app_state.model;
    const label = model.rowLabel(row);
    const subtitle = model.rowSubtitle(row);
    const selected = model.selectedRow() == row;
    const palette = app_state.palette;
    const color = if (selected) palette.selected_text else palette.text;
    const dim = if (selected) palette.selected_secondary else palette.secondary;

    layoutDetail(app_state, cell, label_view, model.rowItem(row).detail, dim);

    var label_buffer: [max_highlight_ranges]highlight.Range = undefined;
    var subtitle_buffer: [max_highlight_ranges]highlight.Range = undefined;
    var label_ranges: []const highlight.Range = label_buffer[0..0];
    var subtitle_ranges: []const highlight.Range = subtitle_buffer[0..0];
    if (model.rowIsMatch(row)) {
        // in a scope only the text after its prefix is matched
        const query = model.searchText(state.currentQuery(app_state));
        const method = app_state.config.search.method;
        label_ranges = highlight.matchRanges(label, query, method, &label_buffer);
        if (subtitle) |text| subtitle_ranges = highlight.matchRanges(text, query, method, &subtitle_buffer);
    }

    if (subtitle == null and label_ranges.len == 0) {
        label_view.msgSend(void, "setStringValue:", .{nsString(label)});
        label_view.msgSend(void, "setFont:", .{app_state.row_font});
        label_view.msgSend(void, "setTextColor:", .{color});
        return;
    }
    label_view.msgSend(void, "setAttributedStringValue:", .{styledRowString(app_state, .{
        .label = label,
        .subtitle = subtitle,
        .label_ranges = label_ranges,
        .subtitle_ranges = subtitle_ranges,
        .color = color,
        .dim = dim,
        .tint = if (selected) null else palette.accent,
    })});
}

const RowString = struct {
    label: [:0]const u8,
    subtitle: ?[:0]const u8,
    label_ranges: []const highlight.Range,
    subtitle_ranges: []const highlight.Range,
    color: objc.Object,
    dim: objc.Object,
    tint: ?objc.Object,
};

fn addAttribute(attributed: objc.Object, name: [*:0]const u8, value: objc.Object, span: row_text.Span) void {
    const ns_range = NSRange{ .location = span.location, .length = span.length };
    attributed.msgSend(void, "addAttribute:value:range:", .{ nsString(name), value, ns_range });
}

fn styledRowString(app_state: *state.AppState, row: RowString) objc.Object {
    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSMutableParagraphStyle = objc.getClass("NSMutableParagraphStyle").?;
    const NSMutableAttributedString = objc.getClass("NSMutableAttributedString").?;

    // an attributed string carries its own line breaking; keep the label's tail truncation
    const paragraph = NSMutableParagraphStyle.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    _ = paragraph.msgSend(objc.Object, "autorelease", .{});
    paragraph.msgSend(void, "setLineBreakMode:", .{ns_line_break_truncating_tail});
    const attributes = NSMutableDictionary.msgSend(objc.Object, "dictionary", .{});
    attributes.msgSend(void, "setObject:forKey:", .{ app_state.row_font, nsString("NSFont") });
    attributes.msgSend(void, "setObject:forKey:", .{ row.color, nsString("NSColor") });
    attributes.msgSend(void, "setObject:forKey:", .{ paragraph, nsString("NSParagraphStyle") });

    // label and subtitle are one string, so tail truncation cuts the subtitle first
    var joined: ?[:0]u8 = null;
    defer if (joined) |text| std.heap.c_allocator.free(text);
    if (row.subtitle) |subtitle| joined = row_text.compose(std.heap.c_allocator, row.label, subtitle) catch null;
    const text: [:0]const u8 = joined orelse row.label;
    const has_subtitle = joined != null;

    const attributed = NSMutableAttributedString.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithString:attributes:", .{ nsString(text), attributes });
    if (has_subtitle) {
        const subtitle = row.subtitle.?;
        const span = row_text.subtitleSpan(row.label, subtitle);
        addAttribute(attributed, "NSFont", app_state.subtitle_font, span);
        addAttribute(attributed, "NSColor", row.dim, span);
        for (row.subtitle_ranges) |range| {
            const hit = row_text.subtitleRangeSpan(row.label, subtitle, range);
            addAttribute(attributed, "NSFont", app_state.bold_font, hit);
            if (row.tint) |accent| addAttribute(attributed, "NSColor", accent, hit);
        }
    }
    for (row.label_ranges) |range| {
        const hit = row_text.labelSpan(row.label, range);
        addAttribute(attributed, "NSFont", app_state.bold_font, hit);
        if (row.tint) |accent| addAttribute(attributed, "NSColor", accent, hit);
    }
    return attributed.msgSend(objc.Object, "autorelease", .{});
}

/// Shows the detail text right-aligned in the cell, up to 30% of its width, and
/// gives the label the rest. Without detail the label spans the cell.
fn layoutDetail(app_state: *state.AppState, cell: objc.Object, label_view: objc.Object, detail: ?[:0]const u8, color: objc.Object) void {
    const cell_width = cell.msgSend(NSRect, "frame", .{}).size.width;
    var label_frame = label_view.msgSend(NSRect, "frame", .{});
    var field = cell.msgSend(objc.Object, "viewWithTag:", .{detail_tag});

    const text = detail orelse {
        if (field.value != null) field.msgSend(void, "setHidden:", .{true});
        label_frame.size.width = @max(cell_width - label_frame.origin.x - item_right_pad, 0.0);
        label_view.msgSend(void, "setFrame:", .{label_frame});
        return;
    };

    if (field.value == null) {
        field = makeDetailField(app_state, cell);
        cell.msgSend(void, "addSubview:", .{field});
    }
    field.msgSend(void, "setStringValue:", .{nsString(text)});
    field.msgSend(void, "setTextColor:", .{color});
    field.msgSend(void, "setHidden:", .{false});

    const width = layout.detailWidth(detailTextWidth(app_state, text), cell_width);
    var field_frame = field.msgSend(NSRect, "frame", .{});
    field_frame.origin.x = @max(cell_width - item_right_pad - width, 0.0);
    field_frame.size.width = width;
    field.msgSend(void, "setFrame:", .{field_frame});

    label_frame.size.width = @max(field_frame.origin.x - layout.detail_gap - label_frame.origin.x, 0.0);
    label_view.msgSend(void, "setFrame:", .{label_frame});
}

/// natural width of the detail text, plus the text cell's side insets
fn detailTextWidth(app_state: *state.AppState, text: [:0]const u8) f64 {
    return objc_helpers.textWidth(app_state.detail_font, text) + detail_text_inset;
}

/// NSTextFieldCell draws its text this far in from each side
const detail_text_inset: f64 = 10.0;

fn makeDetailField(app_state: *state.AppState, cell: objc.Object) objc.Object {
    const NSTextField = objc.getClass("NSTextField").?;
    const row_height = app_state.config.row_height;
    const line_height = lineHeight(app_state.detail_font);
    const cell_width = cell.msgSend(NSRect, "frame", .{}).size.width;
    const field = NSTextField.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = cell_width, .y = (row_height - line_height) / 2.0 + label_optical_offset },
        .size = .{ .width = 0, .height = line_height },
    }});
    field.msgSend(void, "setEditable:", .{false});
    field.msgSend(void, "setSelectable:", .{false});
    field.msgSend(void, "setBezeled:", .{false});
    field.msgSend(void, "setBordered:", .{false});
    field.msgSend(void, "setDrawsBackground:", .{false});
    field.msgSend(void, "setAlignment:", .{ns_text_alignment_right});
    field.msgSend(void, "setFont:", .{app_state.detail_font});
    field.msgSend(void, "setLineBreakMode:", .{ns_line_break_truncating_tail});
    field.msgSend(void, "setTag:", .{detail_tag});
    // pinned to the right edge
    field.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 1)});
    return field;
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
