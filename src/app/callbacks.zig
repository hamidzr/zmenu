const std = @import("std");
const objc = @import("objc");
const menu = @import("../menu.zig");
const mods_mod = @import("../mods.zig");
const exit_codes = @import("../exit_codes.zig");
const time_compat = @import("../time_compat.zig");
const objc_helpers = @import("objc_helpers.zig");
const updates = @import("updates.zig");
const logic = @import("logic.zig");
const state = @import("state.zig");
const views = @import("views.zig");

const nsString = objc_helpers.nsString;
const NSPoint = objc_helpers.NSPoint;
const columnIsIndex = objc_helpers.columnIsIndex;
const columnIsIcon = objc_helpers.columnIsIcon;
const iconImage = objc_helpers.iconImage;

const NSEventModifierFlagShift: u64 = 1 << 17;
const NSEventModifierFlagControl: u64 = 1 << 18;
const NSEventModifierFlagOption: u64 = 1 << 19;
const NSEventModifierFlagCommand: u64 = 1 << 20;

pub fn controlTextDidChange(target: objc.c.id, sel: objc.c.SEL, notification: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;

    const app_state = state.g_state orelse return;
    if (notification == null) return;

    const notification_obj = objc.Object.fromId(notification);
    const field = notification_obj.msgSend(objc.Object, "object", .{});
    const text = field.msgSend(objc.Object, "stringValue", .{});
    const utf8_ptr = text.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (utf8_ptr == null) {
        applyUserQuery(app_state, "");
        return;
    }

    const query: []const u8 = std.mem.sliceTo(utf8_ptr.?, 0);
    applyUserQuery(app_state, query);
}

pub fn onStartupProfileTimer(target: objc.c.id, sel: objc.c.SEL, timer: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    const app_state = state.g_state orelse return;
    const app = objc.getClass("NSApplication").?.msgSend(objc.Object, "sharedApplication", .{});
    const editor = app_state.text_field.msgSend(objc.c.id, "currentEditor", .{});
    if (app.msgSend(bool, "isActive", .{}) and app_state.window.msgSend(bool, "isKeyWindow", .{}) and editor != null) {
        time_compat.startupStage("input_ready");
        objc.Object.fromId(timer).msgSend(void, "invalidate", .{});
    }
}

pub fn controlTextViewDoCommandBySelector(
    target: objc.c.id,
    sel: objc.c.SEL,
    control: objc.c.id,
    text_view: objc.c.id,
    command: objc.c.SEL,
) callconv(.c) bool {
    _ = target;
    _ = sel;
    _ = control;
    _ = text_view;

    const app_state = state.g_state orelse return false;

    if (command == objc.sel("cancelOperation:").value) {
        escape(app_state);
        return true;
    }
    // Enter with modifiers: the field editor maps Shift/Option/Control+Return to
    // these commands (Command+Return normally never gets this far, see
    // performKeyEquivalent). Plain Enter stays with the field's action (onSubmit).
    if (commandIs(command, &enter_commands)) {
        const held = currentEventMods();
        if (held.isEmpty()) return false;
        logic.acceptWith(app_state, held);
        return true;
    }
    if (command == objc.sel("moveUp:").value) {
        logic.moveSelection(app_state, -1);
        return true;
    }
    if (command == objc.sel("moveDown:").value) {
        logic.moveSelection(app_state, 1);
        return true;
    }
    if (command == objc.sel("insertTab:").value) {
        logic.moveSelection(app_state, 1);
        return true;
    }
    if (command == objc.sel("insertBacktab:").value) {
        logic.moveSelection(app_state, -1);
        return true;
    }
    if (commandIs(command, &.{ "pageDown:", "scrollPageDown:" })) {
        logic.moveSelectionClamped(app_state, logic.visibleRows(app_state));
        return true;
    }
    if (commandIs(command, &.{ "pageUp:", "scrollPageUp:" })) {
        logic.moveSelectionClamped(app_state, -logic.visibleRows(app_state));
        return true;
    }
    // Cmd+Up/Down
    if (commandIs(command, &.{"moveToBeginningOfDocument:"})) {
        logic.selectEdge(app_state, true);
        return true;
    }
    if (commandIs(command, &.{"moveToEndOfDocument:"})) {
        logic.selectEdge(app_state, false);
        return true;
    }
    // Home/End: jump in the list only while there is no text to edit
    if (logic.currentQuery(app_state).len == 0) {
        if (commandIs(command, &.{"scrollToBeginningOfDocument:"})) {
            logic.selectEdge(app_state, true);
            return true;
        }
        if (commandIs(command, &.{"scrollToEndOfDocument:"})) {
            logic.selectEdge(app_state, false);
            return true;
        }
    }
    return false;
}

/// every command a Return key press can turn into, depending on its modifiers
const enter_commands = [_][:0]const u8{
    "insertNewline:",
    "insertNewlineIgnoringFieldEditor:",
    "insertLineBreak:",
    "insertParagraphSeparator:",
    "insertLineSeparator:",
    "insertContainerBreak:",
};

fn commandIs(command: objc.c.SEL, comptime names: []const [:0]const u8) bool {
    inline for (names) |name| {
        if (command == objc.sel(name).value) return true;
    }
    return false;
}

pub fn onSubmit(target: objc.c.id, sel: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;

    const app_state = state.g_state orelse return;
    // NSSearchField also fires its action when the query is cleared, so only
    // accept field submits that come from Return/Enter
    if (sender == app_state.text_field.value and !currentEventIsReturnKey()) return;
    logic.acceptWith(app_state, currentEventMods());
}

/// Single click on a row accepts it. The click also selected the row (marking a
/// user move); clicks past the last row have no `clickedRow` and are ignored.
pub fn onRowClick(target: objc.c.id, sel: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = sender;

    const app_state = state.g_state orelse return;
    const row = app_state.table_view.msgSend(c_long, "clickedRow", .{});
    const model = app_state.view();
    if (row < 0 or @as(usize, @intCast(row)) >= model.rowCount()) return;
    model.selected = row;
    logic.acceptSelection(app_state);
}

const NSEventTypeKeyDown: c_ulong = 10;
const kVK_Return: c_ushort = 36;
const kVK_ANSI_KeypadEnter: c_ushort = 76;

fn isReturnKeyCode(key_code: c_ushort) bool {
    return key_code == kVK_Return or key_code == kVK_ANSI_KeypadEnter;
}

/// the Return/Enter key press being handled, if that is what the current event is
fn currentReturnEvent() ?objc.Object {
    const app = objc.getClass("NSApplication").?.msgSend(objc.Object, "sharedApplication", .{});
    const event = app.msgSend(objc.c.id, "currentEvent", .{});
    if (event == null) return null;
    const event_obj = objc.Object.fromId(event);
    if (event_obj.msgSend(c_ulong, "type", .{}) != NSEventTypeKeyDown) return null;
    if (!isReturnKeyCode(event_obj.msgSend(c_ushort, "keyCode", .{}))) return null;
    return event_obj;
}

fn currentEventIsReturnKey() bool {
    return currentReturnEvent() != null;
}

/// the modifiers held on the current Return press; none for any other event
fn currentEventMods() mods_mod.Mods {
    const event = currentReturnEvent() orelse return .{};
    return eventMods(event);
}

fn eventMods(event: objc.Object) mods_mod.Mods {
    return mods_mod.Mods.fromFlags(event.msgSend(c_ulong, "modifierFlags", .{}));
}

/// Table-wide tracking: the row under the pointer drives the hover highlight.
pub fn mouseMoved(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    if (event == null) return;

    const app_state = state.g_state orelse return;
    const event_obj = objc.Object.fromId(event);
    const window_point = event_obj.msgSend(NSPoint, "locationInWindow", .{});
    views.refreshHoverAtWindowPoint(app_state, window_point);
}

/// Scrolling moves rows under a stationary pointer, so re-resolve the hover row.
pub fn scrollViewBoundsChanged(target: objc.c.id, sel: objc.c.SEL, notification: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = notification;

    const app_state = state.g_state orelse return;
    const window_point = app_state.window.msgSend(NSPoint, "mouseLocationOutsideOfEventStream", .{});
    views.refreshHoverAtWindowPoint(app_state, window_point);
}

pub fn mouseExited(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = event;

    const app_state = state.g_state orelse return;
    views.setHoveredRow(app_state, null);
}

pub fn numberOfRowsInTableView(target: objc.c.id, sel: objc.c.SEL, table: objc.c.id) callconv(.c) c_long {
    _ = target;
    _ = sel;
    _ = table;

    const app_state = state.g_state orelse return 0;
    return @intCast(app_state.view().rowCount());
}

pub fn tableViewViewForTableColumn(
    target: objc.c.id,
    sel: objc.c.SEL,
    table: objc.c.id,
    column: objc.c.id,
    row: c_long,
) callconv(.c) objc.c.id {
    _ = target;
    _ = sel;
    _ = table;

    const app_state = state.g_state orelse return null;
    if (column == null or row < 0) return null;

    const row_index: usize = @intCast(row);
    const model = app_state.view();
    if (row_index >= model.rowCount()) return null;

    const column_obj = objc.Object.fromId(column);
    const table_view = app_state.table_view;
    const row_height = app_state.config.row_height;
    const column_width = column_obj.msgSend(f64, "width", .{});

    if (columnIsIndex(column_obj)) {
        const cell = views.textCell(table_view, row_height, column_width, .{
            .identifier = "zmenuIndexCell",
            .font = app_state.hint_font,
            .text_color = app_state.palette.secondary,
            .alignment = 0,
            .left_pad = 10.0,
            .right_pad = 2.0,
        });
        const selected = model.selectedRow() == row_index;
        const hint_color = if (selected) app_state.palette.selected_secondary else app_state.palette.secondary;
        const query = logic.currentQuery(app_state);
        if (app_state.config.numericSelectionEnabled(model.rowCount(), query) and row_index < state.digit_labels.len) {
            views.setCellText(cell, state.digit_labels[row_index], hint_color);
        } else {
            views.setCellText(cell, "", hint_color);
        }
        return cell.value;
    }

    if (app_state.config.show_icons and columnIsIcon(column_obj)) {
        const cell = views.iconCell(table_view, row_height, column_width, "zmenuIconCell");
        views.setCellImage(cell, iconImage(model.rowItem(row_index).icon, views.iconSide(row_height, column_width)));
        return cell.value;
    }

    const cell = views.textCell(table_view, row_height, column_width, .{
        .identifier = "zmenuItemCell",
        .font = app_state.row_font,
        .text_color = app_state.palette.text,
        .alignment = 0,
        // text sits inside the rounded selection fill, which starts 4pt in
        .left_pad = if (app_state.config.hasNumericSelectionColumn() or app_state.config.show_icons) 6.0 else 12.0,
        .right_pad = views.item_right_pad,
    });
    views.configureItemCell(app_state, cell, row_index);
    return cell.value;
}

pub fn tableViewRowViewForRow(
    target: objc.c.id,
    sel: objc.c.SEL,
    table: objc.c.id,
    row: c_long,
) callconv(.c) objc.c.id {
    _ = target;
    _ = sel;
    _ = table;
    _ = row;

    const app_state = state.g_state orelse return null;
    const identifier = "zmenuRow";
    const reused = app_state.table_view.msgSend(objc.Object, "makeViewWithIdentifier:owner:", .{
        nsString(identifier),
        @as(objc.c.id, null),
    });
    if (reused.value != null) return reused.value;

    const row_view = views.makeRowView();
    row_view.msgSend(void, "setIdentifier:", .{nsString(identifier)});
    return row_view.value;
}

pub fn tableViewShouldSelectRow(
    target: objc.c.id,
    sel: objc.c.SEL,
    table: objc.c.id,
    row: c_long,
) callconv(.c) bool {
    _ = target;
    _ = sel;
    _ = table;

    const app_state = state.g_state orelse return true;
    // only user gestures (clicks) reach here; programmatic selection does not
    app_state.view().moved = true;
    syncSelectedRow(app_state, row);
    return true;
}

pub fn tableViewSelectionDidChange(target: objc.c.id, sel: objc.c.SEL, notification: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;

    const app_state = state.g_state orelse return;
    if (notification == null) return;

    const notification_obj = objc.Object.fromId(notification);
    const table = notification_obj.msgSend(objc.Object, "object", .{});
    syncSelectedRow(app_state, table.msgSend(c_long, "selectedRow", .{}));
    views.restyleSelection(app_state);
}

/// mirror a table row into the model, clearing it when out of range
fn syncSelectedRow(app_state: *state.AppState, row: c_long) void {
    const model = app_state.view();
    const in_range = row >= 0 and @as(usize, @intCast(row)) < model.rowCount();
    model.selected = if (in_range) @intCast(row) else -1;
}

fn clearQuery(app_state: *state.AppState) void {
    app_state.text_field.msgSend(void, "setStringValue:", .{nsString("")});
    applyUserQuery(app_state, "");
}

/// Esc closes the action panel, else drops a pending confirmation, else clears
/// a non-empty query, then cancels
fn escape(app_state: *state.AppState) void {
    if (logic.panelOpen(app_state)) {
        logic.closePanel(app_state);
        return;
    }
    if (app_state.confirm.isPending()) {
        logic.clearConfirm(app_state);
        return;
    }
    if (logic.currentQuery(app_state).len > 0) {
        clearQuery(app_state);
        return;
    }
    logic.quit(app_state, exit_codes.user_canceled);
}

pub fn cancelOperation(target: objc.c.id, sel: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = sender;
    if (state.g_state) |app_state| {
        escape(app_state);
        return;
    }
    std.process.exit(exit_codes.user_canceled);
}

pub fn onFocusLossTimer(target: objc.c.id, sel: objc.c.SEL, timer: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = timer;
    if (state.g_state) |app_state| {
        logic.quit(app_state, exit_codes.user_canceled);
    }
    std.process.exit(exit_codes.user_canceled);
}

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

/// UpdateQueue wake hook: runs on the pushing thread, drains on the main queue
pub fn wakeMainThread(ctx: ?*anyopaque) void {
    dispatch_async_f(&_dispatch_main_q, ctx, drainOnMainQueue);
}

fn drainOnMainQueue(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    drainUpdates();
}

/// one-shot fired when a delayed stream-close auto-accept may be due
pub fn onAutoAcceptTimer(target: objc.c.id, sel: objc.c.SEL, timer: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = timer;

    const app_state = state.g_state orelse return;
    if (app_state.pending_stream_close_auto_accept) {
        logic.maybeAutoAccept(app_state, .stream_close);
    }
}

/// one-shot fired when a pending confirmation is due to expire
pub fn onConfirmTimer(target: objc.c.id, sel: objc.c.SEL, timer: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = timer;
    const app_state = state.g_state orelse return;
    logic.expireConfirm(app_state);
}

pub fn drainUpdates() void {
    const app_state = state.g_state orelse return;
    const queue = app_state.update_queue orelse return;
    const updates_slice = queue.drain();
    if (updates_slice.len == 0) return;

    var saw_stream_closed = false;
    var latest_set_batch: ?u64 = null;
    for (updates_slice) |update| {
        if (update.kind == .stream_closed) {
            saw_stream_closed = true;
            continue;
        }
        if (update.kind != .set) continue;
        if (latest_set_batch == null or update.batch > latest_set_batch.?) {
            latest_set_batch = update.batch;
        }
    }

    var set_items = std.ArrayList(menu.MenuItem).empty;
    defer set_items.deinit(app_state.allocator);
    var prepend_items = std.ArrayList(menu.MenuItem).empty;
    defer prepend_items.deinit(app_state.allocator);
    var append_items = std.ArrayList(menu.MenuItem).empty;
    defer append_items.deinit(app_state.allocator);

    var meta_arena = std.heap.ArenaAllocator.init(app_state.allocator);
    defer meta_arena.deinit();
    var meta: ?updates.Meta = null;
    for (updates_slice) |update| {
        if (update.kind == .stream_closed) continue;
        if (update.kind == .meta) {
            if (update.line) |line| {
                if (updates.parseMeta(meta_arena.allocator(), line)) |parsed| {
                    // the last message wins for loading; scopes stay until a message sends a list
                    const scopes = parsed.scopes orelse if (meta) |previous| previous.scopes else null;
                    meta = .{ .loading = parsed.loading, .scopes = scopes };
                }
                queue.allocator.free(line);
            }
            continue;
        }
        if (update.kind == .set and latest_set_batch != null and update.batch != latest_set_batch.?) {
            if (update.line) |line| {
                queue.allocator.free(line);
            }
            continue;
        }
        const line = update.line orelse continue;
        const item = switch (update.source) {
            .stdin => menu.parseItem(app_state.allocator, line, 0) catch {
                queue.allocator.free(line);
                continue;
            },
            .ipc => updates.menuItemFromIpc(app_state.allocator, line) orelse {
                queue.allocator.free(line);
                continue;
            },
        };
        queue.allocator.free(line);
        switch (update.kind) {
            .set => set_items.append(app_state.allocator, item) catch {},
            .prepend => prepend_items.append(app_state.allocator, item) catch {},
            .append => append_items.append(app_state.allocator, item) catch {},
            .stream_closed, .meta => unreachable,
        }
    }
    queue.allocator.free(updates_slice);

    // scopes before items: the refilter below sees both
    var meta_changed = false;
    var scopes_changed = false;
    if (meta) |applied| {
        if (app_state.client_loading != applied.loading) {
            app_state.client_loading = applied.loading;
            meta_changed = true;
        }
        if (applied.scopes) |scopes| {
            app_state.model.setScopes(scopes) catch {};
            meta_changed = true;
            scopes_changed = true;
        }
    }

    const has_set = latest_set_batch != null;
    const has_item_updates = has_set or prepend_items.items.len > 0 or append_items.items.len > 0;
    if (has_set) {
        app_state.model.setItems(app_state.allocator, set_items.items) catch return;
    }
    if (has_item_updates and prepend_items.items.len > 0) {
        app_state.model.prependItems(app_state.allocator, prepend_items.items) catch return;
    }
    if (has_item_updates and append_items.items.len > 0) {
        app_state.model.appendItems(app_state.allocator, append_items.items) catch return;
    }
    // the first update (or the end of the stream) ends "Loading..."
    const first_load = !app_state.loaded and (has_item_updates or saw_stream_closed);
    if (first_load) app_state.loaded = true;
    if (has_item_updates or first_load or meta_changed) {
        logic.applyItemUpdate(app_state, has_item_updates or scopes_changed);
    }
    if (saw_stream_closed) {
        app_state.stream_closed = true;
        logic.maybeAutoAccept(app_state, .stream_close);
    }
}

fn scheduleFocusLossCancel() void {
    const app_state = state.g_state orelse return;
    objc_helpers.scheduleTimer(0.04, app_state.handler, "onFocusLossTimer:", false);
}

pub fn resignKeyWindow(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
    _ = sel;
    if (target == null) return;

    const obj = objc.Object.fromId(target);
    const NSWindow = objc.getClass("NSWindow").?;
    obj.msgSendSuper(NSWindow, void, "resignKeyWindow", .{});
    if (state.g_state) |app_state| {
        if (!app_state.had_focus) return;
    }
    scheduleFocusLossCancel();
}

pub fn keyDown(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    _ = sel;
    if (target == null) return;
    if (event == null) return;

    const obj = objc.Object.fromId(target);

    if (state.g_state) |app_state| {
        if (eventChar(event)) |ec| {
            if ((ec.modifiers & NSEventModifierFlagCommand) != 0 and (ec.char == 'a' or ec.char == 'A')) {
                app_state.text_field.msgSend(void, "selectText:", .{@as(objc.c.id, null)});
                return;
            }
        }
    }

    const NSSearchField = objc.getClass("NSSearchField").?;
    obj.msgSendSuper(NSSearchField, void, "keyDown:", .{event});
}

pub fn performKeyEquivalent(target: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) bool {
    _ = sel;
    if (target == null) return false;
    if (event == null) return false;

    const obj = objc.Object.fromId(target);
    // Enter with modifiers: Command (and usually Control) chords reach here before
    // the field editor sees them; it only maps the others to commands
    // (see controlTextViewDoCommandBySelector)
    if (state.g_state) |app_state| {
        const event_obj = objc.Object.fromId(event);
        if (event_obj.msgSend(c_ulong, "type", .{}) == NSEventTypeKeyDown and isReturnKeyCode(event_obj.msgSend(c_ushort, "keyCode", .{}))) {
            const held = eventMods(event_obj);
            if (!held.isEmpty()) {
                logic.acceptWith(app_state, held);
                return true;
            }
        }
    }
    if (eventChar(event)) |ec| {
        if (state.g_state) |app_state| {
            // Cmd+K: the action panel
            if (ec.modifiers == NSEventModifierFlagCommand and std.ascii.toLower(ec.char) == 'k') {
                logic.togglePanel(app_state);
                return true;
            }
            if (controlNavDelta(ec)) |delta| {
                logic.moveSelection(app_state, delta);
                return true;
            }
            // not in keyDown: with the field editor active, keys never reach the field
            if (ec.modifiers == NSEventModifierFlagControl and std.ascii.toLower(ec.char) == 'l') {
                clearQuery(app_state);
                return true;
            }
        }
        if ((ec.modifiers & NSEventModifierFlagCommand) != 0) {
            if (ec.char == 'a' or ec.char == 'A') {
                obj.msgSend(void, "selectText:", .{@as(objc.c.id, null)});
                return true;
            }
            if (state.g_state) |app_state| {
                if (handleNumericShortcut(app_state, ec.char)) {
                    return true;
                }
            }
        }
    }

    const NSSearchField = objc.getClass("NSSearchField").?;
    return obj.msgSendSuper(NSSearchField, bool, "performKeyEquivalent:", .{event});
}

/// Ctrl+N/J move down, Ctrl+P/K move up. Taken over here so Ctrl+K never
/// reaches the field's delete-to-end-of-line binding.
fn controlNavDelta(ec: EventChar) ?isize {
    if (ec.modifiers != NSEventModifierFlagControl) return null;
    return switch (std.ascii.toLower(ec.char)) {
        'n', 'j' => 1,
        'p', 'k' => -1,
        else => null,
    };
}

const EventChar = struct {
    char: u8,
    modifiers: c_ulong,
};

/// extract single-char + modifier flags from an NSEvent id
fn eventChar(event_id: objc.c.id) ?EventChar {
    if (event_id == null) return null;
    const event_obj = objc.Object.fromId(event_id);
    const chars = event_obj.msgSend(objc.Object, "charactersIgnoringModifiers", .{});
    const utf8_ptr = chars.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return null;
    const text = std.mem.sliceTo(utf8_ptr.?, 0);
    if (text.len != 1) return null;

    const modifiers = event_obj.msgSend(c_ulong, "modifierFlags", .{});
    const masked = modifiers & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand);
    return .{ .char = text[0], .modifiers = masked };
}

fn handleNumericShortcut(app_state: *state.AppState, ch: u8) bool {
    const query = logic.currentQuery(app_state);
    return handleNumericShortcutWithQuery(app_state, ch, query);
}

fn handleNumericShortcutWithQuery(app_state: *state.AppState, ch: u8, query_for_mode: []const u8) bool {
    const model = app_state.view();
    if (!app_state.config.numericSelectionEnabled(model.rowCount(), query_for_mode)) return false;
    if (ch < '1' or ch > '9') return false;

    const index: usize = @intCast(ch - '1');
    if (index < model.rowCount()) {
        model.selected = @intCast(index);
        logic.updateSelection(app_state);
        logic.acceptSelection(app_state);
    }
    return true;
}

fn applyUserQuery(app_state: *state.AppState, query: []const u8) void {
    logic.clearConfirm(app_state);
    const first_input = time_compat.recordFirstInput();
    app_state.last_keystroke_ms = time_compat.milliTimestamp();
    logic.applyFilter(app_state, query);
    if (first_input) time_compat.startupStage("first_query_applied");
    logic.maybeAutoAccept(app_state, .keystroke);
}

pub fn becomeFirstResponder(target: objc.c.id, sel: objc.c.SEL) callconv(.c) bool {
    _ = sel;
    if (target == null) return false;

    const obj = objc.Object.fromId(target);
    const NSSearchField = objc.getClass("NSSearchField").?;
    const accepted = obj.msgSendSuper(NSSearchField, bool, "becomeFirstResponder", .{});
    if (accepted) {
        if (state.g_state) |app_state| {
            app_state.had_focus = true;
        }
        // preserve query replacement without restarting the active field editor
        const editor = obj.msgSend(objc.Object, "currentEditor", .{});
        if (editor.value != null) editor.msgSend(void, "selectAll:", .{@as(objc.c.id, null)});
    }
    return accepted;
}

pub fn windowCanBecomeKey(target: objc.c.id, sel: objc.c.SEL) callconv(.c) bool {
    _ = target;
    _ = sel;
    return true;
}

pub fn windowCanBecomeMain(target: objc.c.id, sel: objc.c.SEL) callconv(.c) bool {
    _ = target;
    _ = sel;
    return true;
}
