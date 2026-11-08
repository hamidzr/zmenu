const std = @import("std");
const objc = @import("objc");
const accept = @import("../accept.zig");
const cache = @import("../cache.zig");
const io_compat = @import("../io_compat.zig");
const pid = @import("../pid.zig");
const time_compat = @import("../time_compat.zig");
const objc_helpers = @import("objc_helpers.zig");
const display = @import("../display.zig");
const state = @import("state.zig");
const views = @import("views.zig");

const stream_close_auto_accept_delay_ms: i64 = 150;

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
    const row = app_state.model.selectedRow() orelse {
        app_state.table_view.msgSend(void, "deselectAll:", .{@as(objc.c.id, null)});
        views.restyleSelection(app_state);
        return;
    };

    const NSIndexSet = objc.getClass("NSIndexSet").?;
    const index_set = NSIndexSet.msgSend(objc.Object, "indexSetWithIndex:", .{@as(c_ulong, @intCast(row))});
    app_state.table_view.msgSend(void, "selectRowIndexes:byExtendingSelection:", .{ index_set, false });
    app_state.table_view.msgSend(void, "scrollRowToVisible:", .{@as(c_long, @intCast(row))});
    views.restyleSelection(app_state);
}

pub fn updateMatchLabel(app_state: *state.AppState) void {
    var buf: [32]u8 = undefined;
    const label_z = std.fmt.bufPrintSentinel(
        &buf,
        "{d} / {d}",
        .{ app_state.model.match_count, app_state.model.items.len },
        0,
    ) catch return;
    app_state.match_label.msgSend(void, "setStringValue:", .{objc_helpers.nsString(label_z)});
}

pub fn applyFilter(app_state: *state.AppState, query: []const u8) void {
    app_state.model.applyFilter(query, app_state.config.search);
    refreshView(app_state, query);
}

/// items changed under the current query: keep a user-moved selection
pub fn applyItemUpdate(app_state: *state.AppState) void {
    const query = currentQuery(app_state);
    app_state.model.applyFilterKeepSelection(query, app_state.config.search);
    refreshView(app_state, query);
}

fn refreshView(app_state: *state.AppState, query: []const u8) void {
    // rows move under a possibly stationary pointer, so drop the stale hover
    app_state.hovered_row = null;
    app_state.display_state = display.compute(
        app_state.loaded,
        app_state.model.items.len,
        app_state.model.rowCount(),
        query,
    );
    fitWindow(app_state);
    // the hint column keeps its width whether or not hints are active, so the
    // text does not shift; reloading rewrites the hint cells
    app_state.table_view.msgSend(void, "reloadData", .{});
    updateSelection(app_state);
    updateMatchLabel(app_state);
    updateMessage(app_state);
}

/// Resizes the window to the rows on show, keeping the top edge fixed so the
/// search field does not move while typing. Subviews follow by autoresizing.
pub fn fitWindow(app_state: *state.AppState) void {
    // a message line takes the place of the first row
    const rows = app_state.metrics.rows(app_state.model.rowCount());
    const height = app_state.metrics.windowHeight(rows);
    const frame = app_state.window.msgSend(objc_helpers.NSRect, "frame", .{});
    if (@abs(frame.size.height - height) < 0.5) return;
    const resized = objc_helpers.NSRect{
        .origin = .{ .x = frame.origin.x, .y = frame.origin.y + frame.size.height - height },
        .size = .{ .width = frame.size.width, .height = height },
    };
    app_state.window.msgSend(void, "setFrame:display:", .{ resized, true });
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
    if (!app_state.config.auto_accept or !app_state.stream_closed or filtered_len != 1) {
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
    app_state.model.moveSelection(delta);
    updateSelection(app_state);
}

/// page moves, edges and Home/End: no wrapping
pub fn moveSelectionClamped(app_state: *state.AppState, delta: isize) void {
    app_state.model.moveSelectionClamped(delta);
    updateSelection(app_state);
}

pub fn selectEdge(app_state: *state.AppState, first: bool) void {
    if (first) app_state.model.selectFirst() else app_state.model.selectLast();
    updateSelection(app_state);
}

/// rows that fit in the visible part of the list, at least one
pub fn visibleRows(app_state: *state.AppState) isize {
    const rect = app_state.table_view.msgSend(objc_helpers.NSRect, "visibleRect", .{});
    const row_height = @max(app_state.config.row_height, 1.0);
    return @max(1, @as(isize, @intFromFloat(@floor(rect.size.height / row_height))));
}

pub const currentQuery = state.currentQuery;

pub fn saveCache(app_state: *state.AppState, selection: []const u8) void {
    if (app_state.config.menu_id.len == 0) return;
    const query = currentQuery(app_state);
    cache.save(app_state.allocator, app_state.config.menu_id, .{
        .last_query = query,
        .last_selection = selection,
        .last_selection_time = time_compat.unixTimestamp(),
    }) catch {};
}

pub fn acceptSelection(app_state: *state.AppState) void {
    const config = app_state.config;
    switch (accept.decide(&app_state.model, config.ipc_only, config.accept_custom_selection, currentQuery(app_state))) {
        .ignore => return,
        .output => |out| outputAndQuit(app_state, out.label, out.output),
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
