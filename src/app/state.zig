const std = @import("std");
const objc = @import("objc");
const action_panel = @import("../action_panel.zig");
const appconfig = @import("../config.zig");
const confirm = @import("../confirm.zig");
const display = @import("../display.zig");
const layout = @import("../layout.zig");
const menu = @import("../menu.zig");
const theme = @import("theme.zig");
const updates = @import("updates.zig");

pub const AppState = struct {
    model: menu.Model,
    window: objc.Object,
    content_view: objc.Object,
    table_view: objc.Object,
    text_field: objc.Object,
    match_label: objc.Object,
    /// small spinning indicator left of the counter, shown while the client is loading
    spinner: objc.Object,
    message_label: objc.Object,
    scroll_view: objc.Object,
    /// hint bar at the bottom: the container with its separator, and the text
    footer_view: objc.Object,
    footer_label: objc.Object,
    handler: objc.Object,
    row_font: objc.Object,
    counter_font: objc.Object,
    hint_font: objc.Object,
    search_font: objc.Object,
    /// footer hint text, and the key glyphs in it
    footer_font: objc.Object,
    footer_key_font: objc.Object,
    /// matched characters of a row label
    bold_font: objc.Object,
    /// subtitle after the label, and the right-aligned detail
    subtitle_font: objc.Object,
    detail_font: objc.Object,
    palette: theme.Palette,
    /// row last styled as selected, so a selection change restyles just two rows
    styled_selected_row: ?usize = null,
    config: appconfig.Config,
    metrics: layout.Metrics,
    pid_path: ?[]const u8,
    ipc_path: ?[]const u8,
    allocator: std.mem.Allocator,
    update_queue: ?*updates.UpdateQueue,
    stream_closed: bool,
    /// false until a streaming source (IPC, followed stdin) delivers its first update
    loaded: bool,
    display_state: display.State = .list,
    last_keystroke_ms: i64,
    pending_stream_close_auto_accept: bool,
    had_focus: bool,
    hovered_row: ?usize,
    /// width of the list (and search field background), for the header layout
    list_width: f64,
    /// true while the latest IPC update said more are coming
    client_loading: bool = false,
    footer_visible: bool = false,
    /// the open Cmd+K action panel; the list then shows its rows, not `model`'s
    panel: ?*action_panel.Panel = null,
    /// a two-step accept waiting for its second Enter, and the row showing the prompt
    confirm: confirm.State = .{},
    confirm_row: ?usize = null,

    /// the model the list shows: the panel's rows while it is open, else the items.
    /// IPC updates always go to `model`.
    pub fn view(self: *AppState) *menu.Model {
        if (self.panel) |panel| return &panel.model;
        return &self.model;
    }
};

/// indent of the search text inside its background
pub const search_text_inset: f64 = 10.0;

/// Cmd+digit hints; the shortcut is Cmd+1 .. Cmd+9, not the bare digit
pub const digit_labels = [_][:0]const u8{
    "\u{2318}1", "\u{2318}2", "\u{2318}3", "\u{2318}4", "\u{2318}5", "\u{2318}6", "\u{2318}7", "\u{2318}8", "\u{2318}9",
};

pub var g_state: ?*AppState = null;

/// the text in the search field, as UTF-8 owned by AppKit (valid until the next change)
pub fn currentQuery(app_state: *AppState) []const u8 {
    const text = app_state.text_field.msgSend(objc.Object, "stringValue", .{});
    const utf8_ptr = text.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return "";
    return std.mem.sliceTo(utf8_ptr.?, 0);
}

/// identity of a list row for the confirm state: its item (id, else label) and template argument
pub fn rowKey(model: *const menu.Model, row: usize) u64 {
    const item = model.rowItem(row);
    const expanded = model.rows.items[row].expanded;
    return confirm.keyOf(item.id orelse item.label, if (expanded) |e| e.arg else null);
}
