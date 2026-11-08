const std = @import("std");
const objc = @import("objc");
const appconfig = @import("../config.zig");
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
    message_label: objc.Object,
    handler: objc.Object,
    row_font: objc.Object,
    counter_font: objc.Object,
    hint_font: objc.Object,
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
};

/// Cmd+digit hints; the shortcut is Cmd+1 .. Cmd+9, not the bare digit
pub const digit_labels = [_][:0]const u8{
    "\u{2318}1", "\u{2318}2", "\u{2318}3", "\u{2318}4", "\u{2318}5", "\u{2318}6", "\u{2318}7", "\u{2318}8", "\u{2318}9",
};

pub var g_state: ?*AppState = null;
