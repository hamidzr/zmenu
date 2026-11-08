const std = @import("std");
const objc = @import("objc");
const accept = @import("../accept.zig");
const action_panel = @import("../action_panel.zig");
const actions = @import("../actions.zig");
const cache = @import("../cache.zig");
const io_compat = @import("../io_compat.zig");
const pid = @import("../pid.zig");
const time_compat = @import("../time_compat.zig");
const objc_helpers = @import("objc_helpers.zig");
const confirm = @import("../confirm.zig");
const display = @import("../display.zig");
const layout = @import("../layout.zig");
const mods_mod = @import("../mods.zig");
const state = @import("state.zig");
const views = @import("views.zig");

const stream_close_auto_accept_delay_ms: i64 = 150;

extern "c" fn NSBeep() void;

const Mods = mods_mod.Mods;

pub const AutoAcceptTrigger = enum {
    initial,
    keystroke,
    stream_close,
};

pub fn quit(app_state: *state.AppState, code: u8) noreturn {
    if (app_state.pid_path) |path| {
        pid.remove(path);
    }
    if (app_state.ipc_path) |path| {
        io_compat.deleteFileAbsolute(path) catch {};
    }
    std.process.exit(code);
}

pub fn updateSelection(app_state: *state.AppState) void {
    const row = app_state.view().selectedRow() orelse {
        app_state.table_view.msgSend(void, "deselectAll:", .{@as(objc.c.id, null)});
        selectionSettled(app_state);
        return;
    };

    const NSIndexSet = objc.getClass("NSIndexSet").?;
    const index_set = NSIndexSet.msgSend(objc.Object, "indexSetWithIndex:", .{@as(c_ulong, @intCast(row))});
    app_state.table_view.msgSend(void, "selectRowIndexes:byExtendingSelection:", .{ index_set, false });
    app_state.table_view.msgSend(void, "scrollRowToVisible:", .{@as(c_long, @intCast(row))});
    selectionSettled(app_state);
}

/// A new selection cancels a confirmation waiting on another row and changes the footer hint.
fn selectionSettled(app_state: *state.AppState) void {
    const model = app_state.view();
    const key: ?u64 = if (model.selectedRow()) |row| state.rowKey(model, row) else null;
    if (app_state.confirm.keepOnlyFor(key)) refreshConfirmRow(app_state);
    views.restyleSelection(app_state);
    views.updateFooter(app_state);
}

pub fn updateMatchLabel(app_state: *state.AppState) void {
    var buf: [160]u8 = undefined;
    const model = app_state.view();
    const text = display.counterText(&buf, model.scopeLabel(), model.match_count, model.counterTotal());
    app_state.match_label.msgSend(void, "setStringValue:", .{objc_helpers.nsString(text)});
    layoutHeader(app_state, objc_helpers.textWidth(app_state.counter_font, text));
}

/// the counter grows with its text, so the search field and spinner give way
fn layoutHeader(app_state: *state.AppState, counter_text_width: f64) void {
    const header = layout.header(
        app_state.config.padding,
        app_state.list_width,
        state.search_text_inset,
        counter_text_width,
        app_state.client_loading,
    );
    setFrameX(app_state.match_label, header.counter_x, header.counter_width);
    setFrameX(app_state.spinner, header.spinner_x, layout.spinner_side);
    const spinning = app_state.spinner.msgSend(bool, "isHidden", .{}) == false;
    if (app_state.client_loading and !spinning) {
        app_state.spinner.msgSend(void, "setHidden:", .{false});
        app_state.spinner.msgSend(void, "startAnimation:", .{@as(objc.c.id, null)});
    } else if (!app_state.client_loading and spinning) {
        app_state.spinner.msgSend(void, "stopAnimation:", .{@as(objc.c.id, null)});
        app_state.spinner.msgSend(void, "setHidden:", .{true});
    }
    const field_frame = app_state.text_field.msgSend(objc_helpers.NSRect, "frame", .{});
    if (@abs(field_frame.size.width - header.search_width) > 0.5) {
        var resized = field_frame;
        resized.size.width = header.search_width;
        app_state.text_field.msgSend(void, "setFrame:", .{resized});
    }
}

/// moves and resizes a view horizontally, leaving y and height alone
fn setFrameX(view: objc.Object, x: f64, width: f64) void {
    var frame = view.msgSend(objc_helpers.NSRect, "frame", .{});
    if (@abs(frame.origin.x - x) < 0.5 and @abs(frame.size.width - width) < 0.5) return;
    frame.origin.x = x;
    frame.size.width = width;
    view.msgSend(void, "setFrame:", .{frame});
}

pub fn applyFilter(app_state: *state.AppState, query: []const u8) void {
    app_state.view().applyFilter(query, app_state.config.search);
    refreshView(app_state, query);
}

/// Items changed under the current query: keep a user-moved selection.
/// `rows_changed`: items or scopes changed, not just the loading flag.
pub fn applyItemUpdate(app_state: *state.AppState, rows_changed: bool) void {
    // the panel shows its own rows under its own query: leave them alone and
    // rebuild the main list when it closes
    if (app_state.panel) |panel| {
        if (rows_changed) panel.model_dirty = true;
        updateMatchLabel(app_state);
        return;
    }
    const query = currentQuery(app_state);
    app_state.model.applyFilterKeepSelection(query, app_state.config.search);
    refreshView(app_state, query);
}

fn refreshView(app_state: *state.AppState, query: []const u8) void {
    // rows move under a possibly stationary pointer, so drop the stale hover
    app_state.hovered_row = null;
    const model = app_state.view();
    app_state.display_state = display.compute(
        app_state.loaded,
        model.items.len,
        model.rowCount(),
        query,
        app_state.client_loading,
    );
    fitWindow(app_state);
    // the hint column keeps its width whether or not hints are active, so the
    // text does not shift; reloading rewrites the hint cells
    app_state.table_view.msgSend(void, "reloadData", .{});
    updateSelection(app_state);
    updateMatchLabel(app_state);
    updateMessage(app_state);
}

/// the footer shows while the panel is open or any listed row offers actions
fn footerNeeded(app_state: *state.AppState) bool {
    if (app_state.panel != null) return true;
    return actions.anyActionable(&app_state.model);
}

/// Resizes the window to the rows on show, keeping the top edge fixed so the
/// search field does not move while typing. Subviews follow by autoresizing; the
/// footer bar takes the place of the bottom padding when shown.
pub fn fitWindow(app_state: *state.AppState) void {
    const footer = footerNeeded(app_state);
    // a message line takes the place of the first row
    const rows = app_state.metrics.rows(app_state.view().rowCount());
    const height = app_state.metrics.windowHeightFor(rows, footer);
    const frame = app_state.window.msgSend(objc_helpers.NSRect, "frame", .{});
    const resized_window = @abs(frame.size.height - height) >= 0.5;
    if (resized_window) {
        const resized = objc_helpers.NSRect{
            .origin = .{ .x = frame.origin.x, .y = frame.origin.y + frame.size.height - height },
            .size = .{ .width = frame.size.width, .height = height },
        };
        app_state.window.msgSend(void, "setFrame:display:", .{ resized, true });
    }
    if (footer != app_state.footer_visible) {
        app_state.footer_visible = footer;
        app_state.footer_view.msgSend(void, "setHidden:", .{!footer});
    }
    // autoresizing keeps the bottom margin; the footer changes it
    if (resized_window or footer) layoutList(app_state, rows, footer);
}

/// the list sits above the footer (or the bottom padding), exactly as tall as its rows
fn layoutList(app_state: *state.AppState, rows: usize, footer: bool) void {
    var frame = app_state.scroll_view.msgSend(objc_helpers.NSRect, "frame", .{});
    const y = app_state.metrics.listY(footer);
    const list_height = app_state.metrics.listHeight(rows);
    if (@abs(frame.origin.y - y) < 0.5 and @abs(frame.size.height - list_height) < 0.5) return;
    frame.origin.y = y;
    frame.size.height = list_height;
    app_state.scroll_view.msgSend(void, "setFrame:", .{frame});
}

/// shows the "Loading..." / "No results" line while the table has no rows
fn updateMessage(app_state: *state.AppState) void {
    const message = display.message(app_state.display_state) orelse {
        app_state.message_label.msgSend(void, "setHidden:", .{true});
        return;
    };
    app_state.message_label.msgSend(void, "setStringValue:", .{objc_helpers.nsString(message)});
    app_state.message_label.msgSend(void, "setHidden:", .{false});
}

pub fn maybeAutoAccept(app_state: *state.AppState, trigger: AutoAcceptTrigger) void {
    const filtered_len = app_state.model.rowCount();
    if (app_state.panel != null or !app_state.config.auto_accept or !app_state.stream_closed or filtered_len != 1) {
        app_state.pending_stream_close_auto_accept = false;
        return;
    }

    if (trigger == .stream_close) {
        const wait_ms = streamCloseAutoAcceptWaitMs(app_state.last_keystroke_ms, time_compat.milliTimestamp());
        if (wait_ms > 0) {
            app_state.pending_stream_close_auto_accept = true;
            const seconds = @as(f64, @floatFromInt(wait_ms)) / 1000.0;
            objc_helpers.scheduleTimer(seconds, app_state.handler, "onAutoAcceptTimer:", false);
            return;
        }
    }

    app_state.pending_stream_close_auto_accept = false;
    acceptSelection(app_state);
}

pub fn moveSelection(app_state: *state.AppState, delta: isize) void {
    app_state.view().moveSelection(delta);
    updateSelection(app_state);
}

/// page moves, edges and Home/End: no wrapping
pub fn moveSelectionClamped(app_state: *state.AppState, delta: isize) void {
    app_state.view().moveSelectionClamped(delta);
    updateSelection(app_state);
}

pub fn selectEdge(app_state: *state.AppState, first: bool) void {
    if (first) app_state.view().selectFirst() else app_state.view().selectLast();
    updateSelection(app_state);
}

/// rows that fit in the visible part of the list, at least one
pub fn visibleRows(app_state: *state.AppState) isize {
    const rect = app_state.table_view.msgSend(objc_helpers.NSRect, "visibleRect", .{});
    const row_height = @max(app_state.config.row_height, 1.0);
    return @max(1, @as(isize, @intFromFloat(@floor(rect.size.height / row_height))));
}

pub const currentQuery = state.currentQuery;

/// the search text the user typed for the list: while the action panel is open
/// the field holds the panel's filter, and the main query is saved aside
fn mainQuery(app_state: *state.AppState) []const u8 {
    if (app_state.panel) |panel| return panel.saved_query;
    return currentQuery(app_state);
}

pub fn saveCache(app_state: *state.AppState, selection: []const u8) void {
    if (app_state.config.menu_id.len == 0) return;
    const query = mainQuery(app_state);
    cache.save(app_state.allocator, app_state.config.menu_id, .{
        .last_query = query,
        .last_selection = selection,
        .last_selection_time = time_compat.unixTimestamp(),
    }) catch {};
}

pub fn acceptSelection(app_state: *state.AppState) void {
    acceptWith(app_state, .{});
}

/// Accepts the selected row with the modifiers held on Enter. Plain Enter is the
/// item itself; modifiers need an action declared with exactly them (else a beep).
/// An accept that must be confirmed shows its prompt instead, until repeated.
pub fn acceptWith(app_state: *state.AppState, requested: Mods) void {
    if (app_state.panel) |panel| return acceptFromPanel(app_state, panel, requested);

    const config = app_state.config;
    const model = &app_state.model;
    var spec: ?confirm.Spec = null;
    if (model.rowCount() > 0) {
        // no selection falls back to the first row, as in accept.decide
        const row = model.selectedRow() orelse 0;
        const resolved = actions.resolve(actions.Source.fromItem(model.rowItem(row).*), requested) orelse return NSBeep();
        spec = resolved.confirm;
        if (spec) |wanted| {
            if (needsConfirm(app_state, state.rowKey(model, row), requested, wanted)) return;
        }
    } else if (!requested.isEmpty()) {
        return NSBeep();
    }
    switch (accept.decide(app_state.allocator, model, config.ipc_only, config.accept_custom_selection, currentQuery(app_state), requested)) {
        .ignore => return,
        .output => |out| outputAndQuit(app_state, out.label, out.output),
    }
}

/// Enter in the action panel accepts the original item with the chosen row's
/// modifiers; modifiers held on Enter pick the item's matching action directly.
fn acceptFromPanel(app_state: *state.AppState, panel: *action_panel.Panel, requested: Mods) void {
    var chosen = requested;
    var spec: ?confirm.Spec = null;
    if (requested.isEmpty()) {
        const choice = panel.selectedChoice() orelse return;
        chosen = choice.mods;
        spec = choice.confirm;
    } else {
        const resolved = actions.resolve(panel.source, requested) orelse return NSBeep();
        spec = resolved.confirm;
    }
    if (spec) |wanted| {
        const key = if (panel.model.selectedRow()) |row| state.rowKey(&panel.model, row) else confirm.keyOf(panel.label, null);
        if (needsConfirm(app_state, key, chosen, wanted)) return;
    }
    switch (accept.decideHeld(app_state.allocator, panel.held(), app_state.config.ipc_only, panel.saved_query, chosen)) {
        .ignore => return,
        .output => |out| outputAndQuit(app_state, out.label, out.output),
    }
}

/// True when the accept must wait: the prompt is now showing on the selected row
fn needsConfirm(app_state: *state.AppState, key: u64, mods: Mods, spec: confirm.Spec) bool {
    switch (app_state.confirm.request(key, mods, spec, time_compat.milliTimestamp())) {
        .accept => return false,
        .prompt => {
            refreshConfirmRow(app_state);
            app_state.confirm_row = app_state.view().selectedRow() orelse 0;
            views.refreshRow(app_state, app_state.confirm_row.?);
            // one-shot, no polling: the prompt goes away by itself
            const seconds = @as(f64, @floatFromInt(confirm.timeout_ms)) / 1000.0 + 0.05;
            objc_helpers.scheduleTimer(seconds, app_state.handler, "onConfirmTimer:", false);
            return true;
        },
    }
}

/// redraws the row that showed a confirm prompt, now cleared
fn refreshConfirmRow(app_state: *state.AppState) void {
    const row = app_state.confirm_row orelse return;
    app_state.confirm_row = null;
    views.refreshRow(app_state, row);
}

/// a typed key, a different selection, Esc or a timeout drops a pending confirmation
pub fn clearConfirm(app_state: *state.AppState) void {
    if (!app_state.confirm.isPending()) return;
    app_state.confirm.clear();
    refreshConfirmRow(app_state);
}

pub fn expireConfirm(app_state: *state.AppState) void {
    if (app_state.confirm.expire(time_compat.milliTimestamp())) refreshConfirmRow(app_state);
}

pub fn panelOpen(app_state: *state.AppState) bool {
    return app_state.panel != null;
}

/// Cmd+K: opens the action panel for the selected item when it has actions, or closes it
pub fn togglePanel(app_state: *state.AppState) void {
    if (app_state.panel != null) return closePanel(app_state);
    openPanel(app_state);
}

pub fn openPanel(app_state: *state.AppState) void {
    if (app_state.panel != null) return;
    const model = &app_state.model;
    const row = model.selectedRow() orelse return;
    const item = model.rowItem(row);
    if (!actions.Source.fromItem(item.*).hasActions()) return;

    const visible = app_state.table_view.msgSend(objc_helpers.NSRect, "visibleRect", .{});
    const panel = action_panel.Panel.create(std.heap.c_allocator, item.*, model.rowLabel(row), model.rows.items[row].expanded, .{
        .query = currentQuery(app_state),
        .selected = model.selected,
        .scroll_y = visible.origin.y,
    }) catch return;
    // the item under the panel is the user's pick: an update keeps it selected
    model.moved = true;
    clearConfirm(app_state);
    app_state.panel = panel;
    app_state.text_field.msgSend(void, "setStringValue:", .{objc_helpers.nsString("")});
    setPlaceholder(app_state, panel.placeholder);
    applyFilter(app_state, "");
}

/// Closes the panel and shows the main list as it was: the same query, selection
/// and scroll, unless items changed meanwhile (then rebuilt under that query).
pub fn closePanel(app_state: *state.AppState) void {
    const panel = app_state.panel orelse return;
    clearConfirm(app_state);
    app_state.panel = null;
    defer panel.destroy();
    app_state.text_field.msgSend(void, "setStringValue:", .{objc_helpers.nsString(panel.saved_query)});
    setPlaceholder(app_state, app_state.config.placeholder);
    if (panel.model_dirty) {
        applyItemUpdate(app_state, true);
        return;
    }
    app_state.model.selected = panel.saved_selected;
    refreshView(app_state, panel.saved_query);
    app_state.table_view.msgSend(void, "scrollPoint:", .{objc_helpers.NSPoint{ .x = 0, .y = panel.saved_scroll_y }});
}

fn setPlaceholder(app_state: *state.AppState, text: [:0]const u8) void {
    if (app_state.config.secondary_text_color) |color| {
        objc_helpers.applyPlaceholderColor(app_state.text_field, text.ptr, objc_helpers.nsColor(color), app_state.search_font);
    } else {
        app_state.text_field.msgSend(void, "setPlaceholderString:", .{objc_helpers.nsString(text.ptr)});
    }
}

fn outputAndQuit(app_state: *state.AppState, label: []const u8, output: []const u8) noreturn {
    saveCache(app_state, label);
    io_compat.stdoutPrint("{s}\n", .{output}) catch {};
    quit(app_state, 0);
}

/// time left before a stream-close auto-accept may fire, 0 when it can fire now
fn streamCloseAutoAcceptWaitMs(last_keystroke_ms: i64, now_ms: i64) i64 {
    if (last_keystroke_ms <= 0) return 0;
    return @max(0, stream_close_auto_accept_delay_ms - (now_ms - last_keystroke_ms));
}
