//! The Cmd+K action panel as plain Zig. Opening it holds a copy of the item and
//! turns its actions into a small `menu.Model` of rows (the primary action,
//! then one row per declared action), so the list, filter, selection and
//! number shortcuts work on it like on any list. The copy keeps the panel
//! working when an IPC update removes the item behind it.

const std = @import("std");
const accept = @import("accept.zig");
const actions = @import("actions.zig");
const confirm = @import("confirm.zig");
const ipc = @import("ipc.zig");
const menu = @import("menu.zig");
const mods_mod = @import("mods.zig");

const Mods = mods_mod.Mods;

/// what accepting a panel row does
pub const Choice = struct {
    mods: Mods,
    confirm: ?confirm.Spec,
};

/// the main list as it was, to restore on close
pub const Saved = struct {
    query: []const u8,
    selected: isize,
    scroll_y: f64,
};

pub const Panel = struct {
    allocator: std.mem.Allocator,
    /// owns every copy below (and the row texts)
    arena: std.heap.ArenaAllocator,
    /// the panel rows
    model: menu.Model,
    /// per panel item (`MenuItem.index`): what accepting it does
    choices: []const Choice,
    /// the item the panel was opened for, with the text its row showed
    label: [:0]const u8,
    placeholder: [:0]const u8,
    source: actions.Source,
    payload: ?[]const u8,
    arg: ?[]const u8,
    result: ?[]const u8,
    /// the main list's query, selection and scroll position
    saved_query: [:0]const u8,
    saved_selected: isize,
    saved_scroll_y: f64,
    /// an items update reached the main model while the panel was open, so its
    /// rows are stale and must be rebuilt on close
    model_dirty: bool = false,

    /// Builds the panel for `item`. `row_label` is the text the row showed (a
    /// template row's expanded label) and `expanded` its template expansion.
    /// Error.NoActions when the item has none.
    pub fn create(
        allocator: std.mem.Allocator,
        item: menu.MenuItem,
        row_label: []const u8,
        expanded: ?*const menu.Expanded,
        saved: Saved,
    ) !*Panel {
        const original = actions.Source.fromItem(item);
        if (!original.hasActions()) return error.NoActions;

        const self = try allocator.create(Panel);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        self.source = .{
            .action = if (item.action) |text| try arena.dupe(u8, text) else null,
            .actions = try copyActions(arena, original.actions.?),
            .confirm = try copyValue(arena, item.confirm),
        };
        self.payload = if (item.ipc_payload) |text| try arena.dupe(u8, text) else null;
        self.arg = if (expanded) |e| try arena.dupe(u8, e.arg) else null;
        self.result = if (expanded) |e| if (e.result) |text| try arena.dupe(u8, text) else null else null;
        self.label = try arena.dupeSentinel(u8, row_label, 0);
        self.placeholder = try std.fmt.allocPrintSentinel(arena, "Actions for {s}", .{row_label}, 0);
        self.saved_query = try arena.dupeSentinel(u8, saved.query, 0);
        self.saved_selected = saved.selected;
        self.saved_scroll_y = saved.scroll_y;
        self.model_dirty = false;

        // the primary action, then every action whose modifiers parse
        const list = self.source.actions.?;
        var items = try allocator.alloc(menu.MenuItem, list.len + 1);
        errdefer allocator.free(items);
        const choices = try arena.alloc(Choice, list.len + 1);
        const icon = if (item.icon) |path| try arena.dupeSentinel(u8, path, 0) else null;

        var count: usize = 0;
        items[count] = .{
            .label = try arena.dupeSentinel(u8, original.primaryLabel(), 0),
            .index = count,
            .icon = icon,
            .detail = mods_mod.return_glyph,
        };
        choices[count] = .{ .mods = .{}, .confirm = confirm.fromValue(self.source.confirm) };
        count += 1;
        for (list) |action| {
            const declared = Mods.parse(action.mods) orelse continue;
            var glyphs_buf: [mods_mod.glyphs_max_len]u8 = undefined;
            items[count] = .{
                .label = try arena.dupeSentinel(u8, actions.actionLabel(action), 0),
                .index = count,
                .icon = icon,
                .detail = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ declared.glyphs(&glyphs_buf), mods_mod.return_glyph }, 0),
            };
            choices[count] = .{ .mods = declared, .confirm = confirm.fromValue(action.confirm) };
            count += 1;
        }
        self.choices = choices[0..count];
        // the model frees its items slice with this length
        items = try allocator.realloc(items, count);
        self.model = try menu.Model.init(allocator, items, false);
        return self;
    }

    pub fn destroy(self: *Panel) void {
        const allocator = self.allocator;
        self.model.deinit(allocator);
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// what the selected panel row does; null when no row is selected
    pub fn selectedChoice(self: *Panel) ?Choice {
        const row = self.model.selectedRow() orelse return null;
        return self.choices[self.model.rowItem(row).index];
    }

    /// what accepting prints: the original item, not a panel row
    pub fn held(self: *const Panel) accept.Held {
        return .{ .label = self.label, .payload = self.payload, .arg = self.arg, .result = self.result };
    }
};

/// only string and boolean `confirm` values mean anything
fn copyValue(arena: std.mem.Allocator, value: ?std.json.Value) !?std.json.Value {
    const v = value orelse return null;
    return switch (v) {
        .string => |text| .{ .string = try arena.dupe(u8, text) },
        .bool => v,
        else => null,
    };
}

fn copyActions(arena: std.mem.Allocator, list: []const ipc.Action) ![]const ipc.Action {
    const copy = try arena.alloc(ipc.Action, list.len);
    for (list, copy) |source, *target| {
        target.* = .{
            .mods = try arena.dupe(u8, source.mods),
            .label = try arena.dupe(u8, source.label),
            .confirm = try copyValue(arena, source.confirm),
        };
    }
    return copy;
}

fn windowItem(allocator: std.mem.Allocator) !menu.MenuItem {
    const list = try allocator.alloc(ipc.Action, 3);
    list[0] = .{ .mods = "cmd", .label = "Close window" };
    list[1] = .{ .mods = "alt", .label = "Quit Safari", .confirm = .{ .string = "Quit Safari?" } };
    list[2] = .{ .mods = "hyper", .label = "Unusable" };
    return .{
        .label = "Inbox - Gmail",
        .index = 0,
        .icon = null,
        .id = "win:1",
        .action = "Switch",
        .actions = list,
        .confirm = .{ .bool = true },
        .ipc_payload = try allocator.dupe(u8, "{\"id\":\"win:1\",\"label\":\"Inbox - Gmail\"}"),
    };
}

test "rows are the primary action then each usable action with its glyphs" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const item = try windowItem(scratch.allocator());

    const panel = try Panel.create(allocator, item, item.label, null, .{ .query = "gm", .selected = 3, .scroll_y = 12 });
    defer panel.destroy();
    panel.model.applyFilter("", .{});

    try std.testing.expectEqualStrings("Actions for Inbox - Gmail", panel.placeholder);
    try std.testing.expectEqual(@as(usize, 3), panel.model.rowCount());
    try std.testing.expectEqualStrings("Switch", panel.model.rowLabel(0));
    try std.testing.expectEqualStrings("\u{21b5}", panel.model.rowItem(0).detail.?);
    try std.testing.expectEqualStrings("Close window", panel.model.rowLabel(1));
    try std.testing.expectEqualStrings("\u{2318}\u{21b5}", panel.model.rowItem(1).detail.?);
    try std.testing.expectEqualStrings("Quit Safari", panel.model.rowLabel(2));
    try std.testing.expectEqualStrings("\u{2325}\u{21b5}", panel.model.rowItem(2).detail.?);
    try std.testing.expectEqual(@as(isize, 0), panel.model.selected);
}

test "an item without a label action opens as Open" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var item = try windowItem(scratch.allocator());
    item.action = null;
    const panel = try Panel.create(allocator, item, "x", null, .{ .query = "", .selected = 0, .scroll_y = 0 });
    defer panel.destroy();
    panel.model.applyFilter("", .{});
    try std.testing.expectEqualStrings("Open", panel.model.rowLabel(0));
}

test "choices carry the mods and confirmation of each row" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const item = try windowItem(scratch.allocator());
    const panel = try Panel.create(allocator, item, item.label, null, .{ .query = "", .selected = 0, .scroll_y = 0 });
    defer panel.destroy();
    panel.model.applyFilter("", .{});

    // primary row: no mods, the item's own confirm (true)
    const primary = panel.selectedChoice().?;
    try std.testing.expect(primary.mods.isEmpty());
    try std.testing.expect(primary.confirm.? == .default);
    panel.model.moveSelection(1);
    const close = panel.selectedChoice().?;
    try std.testing.expect(close.mods.eql(.{ .cmd = true }));
    try std.testing.expect(close.confirm == null);
    panel.model.moveSelection(1);
    const quit = panel.selectedChoice().?;
    try std.testing.expect(quit.mods.eql(.{ .alt = true }));
    try std.testing.expectEqualStrings("Quit Safari?", quit.confirm.?.prompt());
}

test "typing filters the action rows and the choice follows the filtered row" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const item = try windowItem(scratch.allocator());
    const panel = try Panel.create(allocator, item, item.label, null, .{ .query = "", .selected = 0, .scroll_y = 0 });
    defer panel.destroy();

    panel.model.applyFilter("quit", .{});
    try std.testing.expectEqual(@as(usize, 1), panel.model.rowCount());
    try std.testing.expectEqualStrings("Quit Safari", panel.model.rowLabel(0));
    try std.testing.expect(panel.selectedChoice().?.mods.eql(.{ .alt = true }));
    panel.model.applyFilter("zzqq", .{ .levenshtein_fallback = false });
    try std.testing.expectEqual(@as(usize, 0), panel.model.rowCount());
    try std.testing.expect(panel.selectedChoice() == null);
}

test "the panel keeps its own copy of the item and what the list had" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    const item = try windowItem(scratch.allocator());
    var query_buf = [_]u8{ 'g', 'm' };
    const expanded = menu.Expanded{ .label = "84", .subtitle = null, .arg = "12*(3+4)", .result = "84" };

    const panel = try Panel.create(allocator, item, "84", &expanded, .{ .query = &query_buf, .selected = 4, .scroll_y = 36.5 });
    defer panel.destroy();
    // everything the item pointed at is gone, as after an IPC update that replaced it
    scratch.deinit();
    @memset(&query_buf, 'X');

    try std.testing.expectEqualStrings("gm", panel.saved_query);
    try std.testing.expectEqual(@as(isize, 4), panel.saved_selected);
    try std.testing.expectEqual(@as(f64, 36.5), panel.saved_scroll_y);
    const held = panel.held();
    try std.testing.expectEqualStrings("84", held.label);
    try std.testing.expectEqualStrings("{\"id\":\"win:1\",\"label\":\"Inbox - Gmail\"}", held.payload.?);
    try std.testing.expectEqualStrings("12*(3+4)", held.arg.?);
    try std.testing.expectEqualStrings("84", held.result.?);
    try std.testing.expectEqualStrings("Close window", panel.source.actions.?[0].label);
    try std.testing.expect(actions.resolve(panel.source, .{ .alt = true }).?.confirm != null);
    try std.testing.expectEqualStrings("Quit Safari?", actions.resolve(panel.source, .{ .alt = true }).?.confirm.?.prompt());
    try std.testing.expect(actions.resolve(panel.source, .{}).?.confirm.? == .default);
}

test "held output carries the saved query and the chosen mods" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const item = try windowItem(scratch.allocator());
    const panel = try Panel.create(allocator, item, item.label, null, .{ .query = "gm", .selected = 0, .scroll_y = 0 });
    defer panel.destroy();

    const decision = accept.decideHeld(scratch.allocator(), panel.held(), true, panel.saved_query, .{ .cmd = true });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), decision.output.output, .{});
    try std.testing.expectEqualStrings("win:1", parsed.object.get("id").?.string);
    try std.testing.expectEqualStrings("gm", parsed.object.get("query").?.string);
    try std.testing.expectEqualStrings("cmd", parsed.object.get("mods").?.string);
}

test "an item without actions has no panel" {
    const allocator = std.testing.allocator;
    const item = menu.MenuItem{ .label = "x", .index = 0, .icon = null, .action = "Open" };
    try std.testing.expectError(error.NoActions, Panel.create(allocator, item, "x", null, .{ .query = "", .selected = 0, .scroll_y = 0 }));
    const empty = [_]ipc.Action{};
    const none = menu.MenuItem{ .label = "x", .index = 0, .icon = null, .actions = &empty };
    try std.testing.expectError(error.NoActions, Panel.create(allocator, none, "x", null, .{ .query = "", .selected = 0, .scroll_y = 0 }));
}
