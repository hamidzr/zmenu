const std = @import("std");
const io_compat = @import("io_compat.zig");
const calc = @import("calc.zig");
const ipc = @import("ipc.zig");
const search = @import("search.zig");
const template = @import("template.zig");

/// Template items are not matched against the query: they appear on a
/// condition (see `rows`). Regular items have `.none`.
pub const Template = enum { none, calc, prefix, fallback };

pub const MenuItem = struct {
    label: [:0]const u8,
    index: usize,
    icon: ?[:0]const u8,
    ipc_payload: ?[]const u8 = null,
    /// client-supplied IPC id; stdin items have none
    id: ?[]const u8 = null,
    /// dim text after the label; searched and highlighted
    subtitle: ?[:0]const u8 = null,
    /// short right-aligned dim text; not searched
    detail: ?[:0]const u8 = null,
    /// searched, never shown
    keywords: ?[]const u8 = null,
    /// category that scopes select on
    kind: ?[]const u8 = null,
    /// plain-Enter action label, alternate actions and confirmation: kept for
    /// the action UI, not acted on yet
    action: ?[]const u8 = null,
    actions: ?[]const ipc.Action = null,
    confirm: ?std.json.Value = null,
    /// condition of a template item; `template_prefix` is the trigger of `.prefix`
    template: Template = .none,
    template_prefix: []const u8 = "",
};

/// A template row's text with `{q}` and `{result}` filled in, plus what accepting
/// it reports. Lives until the next refilter.
pub const Expanded = struct {
    label: [:0]const u8,
    subtitle: ?[:0]const u8,
    /// prefix: the query after the prefix; fallback and calc: the whole query
    arg: []const u8,
    /// calc: the formatted value
    result: ?[]const u8,
};

/// One visible line of the list: the item behind it. Rows, not items, are what
/// the list shows, selects, numbers and accepts.
pub const Row = struct {
    item: usize,
    /// set on template rows, whose text depends on the query
    expanded: ?*const Expanded = null,
};

/// what the user had selected before an items update, to find it again
const Anchor = struct {
    key: []u8,
    by_id: bool,
    row: usize,
};

pub const stdin_max_bytes: usize = 16 * 1024 * 1024;

pub const LineBuffer = struct {
    buffer: []u8,
    lines: [][]const u8,

    pub fn deinit(self: *LineBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
        allocator.free(self.buffer);
    }
};

pub fn readStdinLines(allocator: std.mem.Allocator, max_bytes: usize) !LineBuffer {
    const buffer = try io_compat.readAllFromFd(allocator, std.posix.STDIN_FILENO, max_bytes);

    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);

    var iter = std.mem.splitScalar(u8, buffer, '\n');
    while (iter.next()) |line| {
        const trimmed = trimLineEnding(line);
        if (trimmed.len == 0) continue;
        try lines.append(allocator, trimmed);
    }

    return .{
        .buffer = buffer,
        .lines = try lines.toOwnedSlice(allocator),
    };
}

fn trimLineEnding(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

pub fn parseItem(allocator: std.mem.Allocator, line: []const u8, index: usize) !MenuItem {
    const label = trimLineEnding(line);
    if (label.len == 0) return error.EmptyLabel;

    const label_z = try allocator.dupeSentinel(u8, label, 0);
    return .{ .label = label_z, .index = index, .icon = null, .ipc_payload = null };
}

pub fn readItems(allocator: std.mem.Allocator, unique: bool) ![]MenuItem {
    var input = try readStdinLines(allocator, stdin_max_bytes);
    defer input.deinit(allocator);

    if (input.lines.len == 0) return error.NoInput;

    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer if (unique) seen.deinit(allocator);

    var items = std.ArrayList(MenuItem).empty;
    errdefer items.deinit(allocator);

    for (input.lines) |line| {
        const item = try parseItem(allocator, line, items.items.len);
        if (unique) {
            const gop = try seen.getOrPut(allocator, item.label);
            if (gop.found_existing) continue;
        }
        try items.append(allocator, item);
    }

    if (items.items.len == 0) return error.NoInput;

    return items.toOwnedSlice(allocator);
}

/// folded search text; an OOM falls back to the raw text
fn foldText(arena: *std.heap.ArenaAllocator, text: []const u8) []const u8 {
    return search.fold.foldAlloc(arena.allocator(), text) catch text;
}

/// What an item is searched by, folded once here instead of per keystroke.
/// Template items are never matched, so only their label is kept.
fn makeDoc(arena: *std.heap.ArenaAllocator, item: MenuItem) search.Doc {
    const label = foldText(arena, item.label);
    if (item.template != .none) return .{ .label = label, .haystack = label };
    const subtitle = if (item.subtitle) |text| foldText(arena, text) else "";
    const keywords = if (item.keywords) |text| foldText(arena, text) else "";
    if (subtitle.len == 0 and keywords.len == 0) return .{ .label = label, .haystack = label };
    const haystack = std.fmt.allocPrint(arena.allocator(), "{s}  {s} {s}", .{ label, subtitle, keywords }) catch label;
    return .{ .label = label, .subtitle = subtitle, .keywords = keywords, .haystack = haystack };
}

pub const Model = struct {
    items: []MenuItem,
    /// diacritic-folded search text, parallel to items (display uses the item's own text)
    docs: []search.Doc,
    /// owns the folded copies
    fold_arena: std.heap.ArenaAllocator,
    matches: std.ArrayList(search.Match),
    /// items the query is matched against (no template items), ascending
    candidates: std.ArrayList(usize),
    /// scratch for `search.filterDocs`
    view: std.ArrayList([]const u8),
    /// items matching the query, best first
    regular: std.ArrayList(usize),
    /// template items (calc, prefix, fallback), ascending
    templates: std.ArrayList(usize),
    /// what the list shows, top to bottom
    rows: std.ArrayList(Row),
    /// owns the `Expanded` text of the current rows
    row_arena: std.heap.ArenaAllocator,
    scores: []i32,
    match_count: usize,
    selected: isize,
    unique: bool,
    seen: std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    /// the user explicitly moved the selection since the last query change
    moved: bool = false,
    anchor: ?Anchor = null,

    pub fn init(allocator: std.mem.Allocator, items: []MenuItem, unique: bool) !Model {
        var seen: std.StringHashMapUnmanaged(void) = .{};
        errdefer seen.deinit(allocator);

        var working = items;
        if (unique) {
            var write_idx: usize = 0;
            for (items) |item| {
                const gop = try seen.getOrPut(allocator, item.label);
                if (gop.found_existing) continue;
                items[write_idx] = item;
                write_idx += 1;
            }
            if (write_idx < items.len) {
                working = try allocator.realloc(items, write_idx);
            }
        }

        var fold_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer fold_arena.deinit();
        const docs = try allocator.alloc(search.Doc, working.len);
        for (working, 0..) |*item, idx| {
            item.index = idx;
            docs[idx] = makeDoc(&fold_arena, item.*);
        }

        const scores = try allocator.alloc(i32, working.len);
        @memset(scores, 0);

        var model: Model = .{
            .items = working,
            .docs = docs,
            .fold_arena = fold_arena,
            .matches = .empty,
            .candidates = .empty,
            .view = .empty,
            .regular = .empty,
            .templates = .empty,
            .rows = .empty,
            .row_arena = std.heap.ArenaAllocator.init(allocator),
            .scores = scores,
            .match_count = 0,
            .selected = -1,
            .unique = unique,
            .seen = seen,
            .allocator = allocator,
        };
        try model.reserveRows(allocator, working.len);
        model.reindex();
        return model;
    }

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.clearAnchor();
        self.fold_arena.deinit();
        self.matches.deinit(allocator);
        self.candidates.deinit(allocator);
        self.view.deinit(allocator);
        self.regular.deinit(allocator);
        self.rows.deinit(allocator);
        self.templates.deinit(allocator);
        self.row_arena.deinit();
        self.seen.deinit(allocator);
        allocator.free(self.items);
        allocator.free(self.docs);
        allocator.free(self.scores);
    }

    fn filterUniqueIncoming(
        self: *Model,
        allocator: std.mem.Allocator,
        new_items: []const MenuItem,
    ) !struct { items: []const MenuItem, owned: ?[]MenuItem } {
        if (!self.unique) return .{ .items = new_items, .owned = null };

        const buf = try allocator.alloc(MenuItem, new_items.len);
        var write_idx: usize = 0;
        for (new_items) |item| {
            const gop = try self.seen.getOrPut(allocator, item.label);
            if (gop.found_existing) continue;
            buf[write_idx] = item;
            write_idx += 1;
        }
        if (write_idx == 0) {
            allocator.free(buf);
            return .{ .items = &[_]MenuItem{}, .owned = null };
        }
        return .{ .items = buf[0..write_idx], .owned = buf };
    }

    fn clearAnchor(self: *Model) void {
        if (self.anchor) |anchor| self.allocator.free(anchor.key);
        self.anchor = null;
    }

    /// remember the user-chosen item before an items update replaces the rows
    fn captureAnchor(self: *Model) void {
        if (self.anchor != null or !self.moved) return;
        const row = self.selectedRow() orelse return;
        const item = self.items[self.rows.items[row].item];
        const key = self.allocator.dupe(u8, item.id orelse item.label) catch return;
        self.anchor = .{ .key = key, .by_id = item.id != null, .row = row };
    }

    fn anchorMatches(anchor: Anchor, item: MenuItem) bool {
        if (anchor.by_id) return if (item.id) |id| std.mem.eql(u8, id, anchor.key) else false;
        return item.id == null and std.mem.eql(u8, item.label, anchor.key);
    }

    fn refilter(self: *Model, query: []const u8, opts: search.Options) void {
        @memset(self.scores, 0);
        var fold_buf: [512]u8 = undefined;
        const folded_query = search.fold.foldBuf(&fold_buf, query);
        search.filterDocs(self.docs, self.candidates.items, folded_query, opts, &self.matches, &self.regular, &self.view);
        self.match_count = self.matches.items.len;
        for (self.matches.items) |match| {
            if (match.index < self.scores.len) {
                self.scores[match.index] = match.score;
            }
        }
        self.buildRows(query);
    }

    /// Rows are [calc] [active prefix] [regular matches] [fallbacks when there
    /// is no regular match]; the template rows are expanded for this query.
    fn buildRows(self: *Model, query: []const u8) void {
        _ = self.row_arena.reset(.retain_capacity);
        self.rows.clearRetainingCapacity();
        const has_query = std.mem.trim(u8, query, " \t\r\n").len > 0;

        if (has_query) self.appendCalcRows(query);
        self.appendPrefixRows(query);
        for (self.regular.items) |item_index| self.rows.appendAssumeCapacity(.{ .item = item_index });
        if (has_query and self.regular.items.len == 0) self.appendTemplateRows(.fallback, query, query, null);
    }

    fn appendCalcRows(self: *Model, query: []const u8) void {
        const value = calc.evaluate(query) orelse return;
        var buf: [calc.format_buf_len]u8 = undefined;
        const result = self.row_arena.allocator().dupe(u8, calc.format(&buf, value)) catch return;
        self.appendTemplateRows(.calc, query, query, result);
    }

    fn appendPrefixRows(self: *Model, query: []const u8) void {
        for (self.templates.items) |item_index| {
            const item = self.items[item_index];
            if (item.template != .prefix) continue;
            const rest = template.prefixRemainder(item.template_prefix, query) orelse continue;
            self.appendExpandedRow(item_index, rest, rest, null);
        }
    }

    /// a row for every template item of `kind`, in the order supplied
    fn appendTemplateRows(self: *Model, kind: Template, q: []const u8, arg: []const u8, result: ?[]const u8) void {
        for (self.templates.items) |item_index| {
            if (self.items[item_index].template == kind) self.appendExpandedRow(item_index, q, arg, result);
        }
    }

    fn appendExpandedRow(self: *Model, item_index: usize, q: []const u8, arg: []const u8, result: ?[]const u8) void {
        const arena = self.row_arena.allocator();
        const item = self.items[item_index];
        const expanded = arena.create(Expanded) catch return;
        expanded.* = .{
            .label = template.expand(arena, item.label, q, result) catch return,
            .subtitle = if (item.subtitle) |text| template.expand(arena, text, q, result) catch return else null,
            .arg = arg,
            .result = result,
        };
        self.rows.appendAssumeCapacity(.{ .item = item_index, .expanded = expanded });
    }

    /// items that count in the "n / total" counter: everything but template items
    pub fn regularTotal(self: *const Model) usize {
        return self.candidates.items.len;
    }

    /// rebuild the candidate list after the items changed; capacity is reserved
    fn reindex(self: *Model) void {
        self.candidates.clearRetainingCapacity();
        self.templates.clearRetainingCapacity();
        for (self.items, 0..) |item, index| {
            if (item.template == .none) {
                self.candidates.appendAssumeCapacity(index);
            } else {
                self.templates.appendAssumeCapacity(index);
            }
        }
    }

    fn reserveRows(self: *Model, allocator: std.mem.Allocator, count: usize) !void {
        try self.candidates.ensureTotalCapacity(allocator, count);
        try self.templates.ensureTotalCapacity(allocator, count);
        try self.view.ensureTotalCapacity(allocator, count);
        try self.matches.ensureTotalCapacity(allocator, count);
        try self.regular.ensureTotalCapacity(allocator, count);
        try self.rows.ensureTotalCapacity(allocator, count);
    }

    pub fn rowCount(self: *const Model) usize {
        return self.rows.items.len;
    }

    pub fn rowItem(self: *const Model, row: usize) *const MenuItem {
        return &self.items[self.rows.items[row].item];
    }

    pub fn rowLabel(self: *const Model, row: usize) [:0]const u8 {
        if (self.rows.items[row].expanded) |expanded| return expanded.label;
        return self.rowItem(row).label;
    }

    pub fn rowSubtitle(self: *const Model, row: usize) ?[:0]const u8 {
        if (self.rows.items[row].expanded) |expanded| return expanded.subtitle;
        return self.rowItem(row).subtitle;
    }

    /// regular rows are matched against the query, so their text is highlighted
    pub fn rowIsMatch(self: *const Model, row: usize) bool {
        return self.rowItem(row).template == .none;
    }

    /// query changed: select the top row and forget any manual move
    pub fn applyFilter(self: *Model, query: []const u8, opts: search.Options) void {
        self.refilter(query, opts);
        self.moved = false;
        self.clearAnchor();
        self.selected = if (self.rows.items.len == 0) -1 else 0;
    }

    /// items changed under an unchanged query: if the user moved the
    /// selection, keep it on the same item (id, else label), else on the same
    /// row clamped; otherwise select the top row
    pub fn applyFilterKeepSelection(self: *Model, query: []const u8, opts: search.Options) void {
        self.refilter(query, opts);
        defer self.clearAnchor();
        const count = self.rows.items.len;
        if (count == 0) {
            self.selected = -1;
            return;
        }
        self.selected = 0;
        const anchor = self.anchor orelse return;
        for (self.rows.items, 0..) |row_data, row| {
            if (anchorMatches(anchor, self.items[row_data.item])) {
                self.selected = @intCast(row);
                return;
            }
        }
        self.selected = @intCast(@min(anchor.row, count - 1));
    }

    pub fn appendItems(self: *Model, allocator: std.mem.Allocator, new_items: []const MenuItem) !void {
        if (new_items.len == 0) return;

        const filter_result = try self.filterUniqueIncoming(allocator, new_items);
        defer if (filter_result.owned) |buf| allocator.free(buf);
        const to_add = filter_result.items;
        if (to_add.len == 0) return;
        self.captureAnchor();

        const old_len = self.items.len;
        const new_len = old_len + to_add.len;

        self.items = try allocator.realloc(self.items, new_len);
        self.docs = try allocator.realloc(self.docs, new_len);
        self.scores = try allocator.realloc(self.scores, new_len);

        var i: usize = 0;
        while (i < to_add.len) : (i += 1) {
            const idx = old_len + i;
            var item = to_add[i];
            item.index = idx;
            self.items[idx] = item;
            self.docs[idx] = makeDoc(&self.fold_arena, item);
            self.scores[idx] = 0;
        }

        try self.reserveRows(allocator, new_len);
        self.reindex();
    }

    pub fn prependItems(self: *Model, allocator: std.mem.Allocator, new_items: []const MenuItem) !void {
        if (new_items.len == 0) return;

        const filter_result = try self.filterUniqueIncoming(allocator, new_items);
        defer if (filter_result.owned) |buf| allocator.free(buf);
        const to_add = filter_result.items;
        if (to_add.len == 0) return;
        self.captureAnchor();

        const old_items = self.items;
        const old_docs = self.docs;
        const old_scores = self.scores;

        const old_len = old_items.len;
        const new_len = old_len + to_add.len;

        const items = try allocator.alloc(MenuItem, new_len);
        const docs = try allocator.alloc(search.Doc, new_len);
        const scores = try allocator.alloc(i32, new_len);
        @memset(scores, 0);

        for (to_add, 0..) |item_in, idx| {
            var item = item_in;
            item.index = idx;
            items[idx] = item;
            docs[idx] = makeDoc(&self.fold_arena, item);
        }

        for (old_items, 0..) |item_in, offset| {
            const idx = to_add.len + offset;
            var item = item_in;
            item.index = idx;
            items[idx] = item;
            docs[idx] = old_docs[offset];
        }

        self.items = items;
        self.docs = docs;
        self.scores = scores;

        allocator.free(old_items);
        allocator.free(old_docs);
        allocator.free(old_scores);

        try self.reserveRows(allocator, new_len);
        self.reindex();
    }

    pub fn setItems(self: *Model, allocator: std.mem.Allocator, new_items: []const MenuItem) !void {
        self.captureAnchor();
        if (self.unique) self.seen.clearRetainingCapacity();

        const filter_result = try self.filterUniqueIncoming(allocator, new_items);
        defer if (filter_result.owned) |buf| allocator.free(buf);
        const to_set = filter_result.items;
        const new_len = to_set.len;

        self.items = try allocator.realloc(self.items, new_len);
        self.docs = try allocator.realloc(self.docs, new_len);
        self.scores = try allocator.realloc(self.scores, new_len);
        @memset(self.scores, 0);

        // the old folded copies are unreachable once the labels are rebuilt
        _ = self.fold_arena.reset(.retain_capacity);
        for (to_set, 0..) |item_in, idx| {
            var item = item_in;
            item.index = idx;
            self.items[idx] = item;
            self.docs[idx] = makeDoc(&self.fold_arena, item);
        }

        self.matches.clearRetainingCapacity();
        self.regular.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        try self.reserveRows(allocator, new_len);
        self.reindex();
        self.match_count = 0;
        self.selected = -1;
    }

    pub fn moveSelection(self: *Model, delta: isize) void {
        self.moved = true;
        if (self.rows.items.len == 0) {
            self.selected = -1;
            return;
        }

        const count: isize = @intCast(self.rows.items.len);
        self.selected = @mod(@max(self.selected, 0) + delta, count);
    }

    /// move without wrapping, clamped to the first and last row
    pub fn moveSelectionClamped(self: *Model, delta: isize) void {
        self.moved = true;
        if (self.rows.items.len == 0) {
            self.selected = -1;
            return;
        }

        const last: isize = @intCast(self.rows.items.len - 1);
        self.selected = std.math.clamp(@max(self.selected, 0) +| delta, 0, last);
    }

    pub fn selectFirst(self: *Model) void {
        self.moveSelectionClamped(std.math.minInt(isize));
    }

    pub fn selectLast(self: *Model) void {
        self.moveSelectionClamped(std.math.maxInt(isize));
    }

    pub fn selectedRow(self: *Model) ?usize {
        if (self.selected < 0) return null;
        const row: usize = @intCast(self.selected);
        if (row >= self.rows.items.len) return null;
        return row;
    }

    pub fn selectedItem(self: *Model) ?MenuItem {
        const row = self.selectedRow() orelse return null;
        return self.items[self.rows.items[row].item];
    }
};

fn testItems(allocator: std.mem.Allocator, labels: []const [:0]const u8) ![]MenuItem {
    const items = try allocator.alloc(MenuItem, labels.len);
    for (labels, 0..) |label, idx| items[idx] = .{ .label = label, .index = idx, .icon = null };
    return items;
}

test "setItems dedupes labels when unique" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{"a"}), true);
    defer model.deinit(allocator);

    const incoming = [_]MenuItem{
        .{ .label = "b", .index = 0, .icon = null },
        .{ .label = "c", .index = 0, .icon = null },
        .{ .label = "b", .index = 0, .icon = null },
    };
    try model.setItems(allocator, &incoming);
    try std.testing.expectEqual(@as(usize, 2), model.items.len);
    try std.testing.expectEqualStrings("b", model.items[0].label);
    try std.testing.expectEqualStrings("c", model.items[1].label);
    try std.testing.expectEqual(@as(usize, 1), model.items[1].index);

    // old labels are forgotten, so a later append of "a" is kept
    try model.appendItems(allocator, &.{.{ .label = "a", .index = 0, .icon = null }});
    try std.testing.expectEqual(@as(usize, 3), model.items.len);

    try model.setItems(allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), model.items.len);
}

test "moveSelection wraps both ways" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "a", "b", "c" }), false);
    defer model.deinit(allocator);
    model.applyFilter("", .{});
    try std.testing.expectEqual(@as(isize, 0), model.selected);

    model.moveSelection(-1);
    try std.testing.expectEqual(@as(isize, 2), model.selected);
    model.moveSelection(1);
    try std.testing.expectEqual(@as(isize, 0), model.selected);

    model.selected = -1;
    model.moveSelection(1);
    try std.testing.expectEqual(@as(isize, 1), model.selected);
}

fn idItem(id: ?[:0]const u8, label: [:0]const u8) MenuItem {
    return .{ .label = label, .index = 0, .icon = null, .id = id };
}

test "update keeps the user-chosen item selected by id" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{}), false);
    defer model.deinit(allocator);
    try model.setItems(allocator, &.{ idItem("x", "X"), idItem("y", "Y"), idItem("z", "Z") });
    model.applyFilter("", .{});
    model.moveSelection(1);
    try std.testing.expectEqualStrings("y", model.selectedItem().?.id.?);

    // reordered, and the label changed: the id wins
    try model.setItems(allocator, &.{ idItem("z", "Z"), idItem("x", "X"), idItem("y", "Y2") });
    model.applyFilterKeepSelection("", .{});
    try std.testing.expectEqual(@as(isize, 2), model.selected);
    try std.testing.expectEqualStrings("y", model.selectedItem().?.id.?);

    // several updates before one filter keep the first anchor
    try model.setItems(allocator, &.{ idItem("q", "Q"), idItem("y", "Y2") });
    try model.appendItems(allocator, &.{idItem("r", "R")});
    model.applyFilterKeepSelection("", .{});
    try std.testing.expectEqualStrings("y", model.selectedItem().?.id.?);
}

test "update selects the top row when the user has not moved" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "a", "b" }), false);
    defer model.deinit(allocator);
    model.applyFilter("", .{});

    try model.setItems(allocator, &.{ idItem("y", "Y"), idItem("x", "X") });
    model.applyFilterKeepSelection("", .{});
    try std.testing.expectEqual(@as(isize, 0), model.selected);
}

test "update falls back to the same row when the item is gone" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "a", "b", "c" }), false);
    defer model.deinit(allocator);
    model.applyFilter("", .{});
    model.moveSelection(2);

    try model.setItems(allocator, &.{ idItem("x", "X"), idItem("y", "Y"), idItem("z", "Z"), idItem("w", "W") });
    model.applyFilterKeepSelection("", .{});
    try std.testing.expectEqual(@as(isize, 2), model.selected);

    // row index is clamped when the list shrinks
    model.moveSelection(1);
    try model.setItems(allocator, &.{ idItem("p", "P"), idItem("q", "Q") });
    model.applyFilterKeepSelection("", .{});
    try std.testing.expectEqual(@as(isize, 1), model.selected);

    try model.setItems(allocator, &.{});
    model.applyFilterKeepSelection("", .{});
    try std.testing.expectEqual(@as(isize, -1), model.selected);
}

test "stdin items without ids reselect by label" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "a", "b", "c" }), false);
    defer model.deinit(allocator);
    model.applyFilter("", .{});
    model.moveSelection(1);

    try model.prependItems(allocator, &.{idItem(null, "new")});
    try model.appendItems(allocator, &.{idItem(null, "last")});
    model.applyFilterKeepSelection("", .{});
    try std.testing.expectEqualStrings("b", model.selectedItem().?.label);
}

test "query change resets selection and the moved flag" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "ab", "ac", "ad" }), false);
    defer model.deinit(allocator);
    model.applyFilter("", .{});
    model.moveSelection(2);
    try std.testing.expect(model.moved);

    // an update leaves a pending anchor that a query change must discard
    try model.setItems(allocator, &.{ idItem(null, "ab"), idItem(null, "ac") });
    model.applyFilter("a", .{});
    try std.testing.expectEqual(@as(isize, 0), model.selected);
    try std.testing.expect(!model.moved);
    try std.testing.expect(model.anchor == null);

    try model.setItems(allocator, &.{ idItem(null, "ab"), idItem(null, "ac") });
    model.applyFilterKeepSelection("a", .{});
    try std.testing.expectEqual(@as(isize, 0), model.selected);
}

test "accent-insensitive search in both directions" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "Café Nero", "Éclair shop", "Zürich", "Plain" }), false);
    defer model.deinit(allocator);

    model.applyFilter("cafe", .{});
    try std.testing.expectEqual(@as(usize, 1), model.rows.items.len);
    try std.testing.expectEqualStrings("Café Nero", model.selectedItem().?.label);

    model.applyFilter("eclair", .{});
    try std.testing.expectEqualStrings("Éclair shop", model.selectedItem().?.label);

    model.applyFilter("Zurich", .{});
    try std.testing.expectEqualStrings("Zürich", model.selectedItem().?.label);

    // accented query finds unaccented and accented labels alike
    model.applyFilter("café", .{});
    try std.testing.expectEqualStrings("Café Nero", model.selectedItem().?.label);

    // set, prepend and append keep folding
    try model.setItems(allocator, &.{idItem(null, "Crème brûlée")});
    try model.prependItems(allocator, &.{idItem(null, "Smörgåsbord")});
    try model.appendItems(allocator, &.{idItem(null, "Año nuevo")});
    model.applyFilter("creme brulee", .{});
    try std.testing.expectEqualStrings("Crème brûlée", model.selectedItem().?.label);
    model.applyFilter("smorgasbord", .{});
    try std.testing.expectEqualStrings("Smörgåsbord", model.selectedItem().?.label);
    model.applyFilter("ano", .{});
    try std.testing.expectEqualStrings("Año nuevo", model.selectedItem().?.label);
}

test "clamped moves stop at the ends and count as user moves" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "a", "b", "c", "d", "e" }), false);
    defer model.deinit(allocator);
    model.applyFilter("", .{});
    try std.testing.expect(!model.moved);

    model.moveSelectionClamped(3);
    try std.testing.expectEqual(@as(isize, 3), model.selected);
    try std.testing.expect(model.moved);
    model.moveSelectionClamped(3);
    try std.testing.expectEqual(@as(isize, 4), model.selected);
    model.moveSelectionClamped(-10);
    try std.testing.expectEqual(@as(isize, 0), model.selected);

    model.selectLast();
    try std.testing.expectEqual(@as(isize, 4), model.selected);
    model.selectFirst();
    try std.testing.expectEqual(@as(isize, 0), model.selected);

    model.applyFilter("zzzz", .{ .levenshtein_fallback = false });
    model.selectLast();
    try std.testing.expectEqual(@as(isize, -1), model.selected);
}

fn richItem(label: [:0]const u8, subtitle: ?[:0]const u8, keywords: ?[]const u8) MenuItem {
    return .{ .label = label, .index = 0, .icon = null, .subtitle = subtitle, .keywords = keywords };
}

test "search covers subtitle and keywords with the label ranked first" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{}), false);
    defer model.deinit(allocator);
    try model.setItems(allocator, &.{
        richItem("Inbox - Gmail", "Safari", null),
        richItem("Notes", null, "scratch safari"),
        richItem("Safari", null, null),
        richItem("Calendar", null, null),
    });
    model.applyFilter("safari", .{ .levenshtein_fallback = false });
    try std.testing.expectEqual(@as(usize, 3), model.rowCount());
    try std.testing.expectEqualStrings("Safari", model.rowItem(0).label);
    try std.testing.expectEqualStrings("Inbox - Gmail", model.rowItem(1).label);
    try std.testing.expectEqualStrings("Notes", model.rowItem(2).label);

    model.applyFilter("scratch", .{});
    try std.testing.expectEqualStrings("Notes", model.selectedItem().?.label);
}

test "accented subtitles and keywords are folded" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{}), false);
    defer model.deinit(allocator);
    try model.setItems(allocator, &.{richItem("Mail", "Café Nero", "Zürich")});
    try model.prependItems(allocator, &.{richItem("Other", null, "Crème")});
    model.applyFilter("cafe", .{});
    try std.testing.expectEqualStrings("Mail", model.selectedItem().?.label);
    model.applyFilter("zurich", .{});
    try std.testing.expectEqualStrings("Mail", model.selectedItem().?.label);
    model.applyFilter("creme", .{});
    try std.testing.expectEqualStrings("Other", model.selectedItem().?.label);
}

test "template items are never matched as regular items" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "Search Google", "Google" }), false);
    defer model.deinit(allocator);
    try model.appendItems(allocator, &.{.{ .label = "Google {q}", .index = 0, .icon = null, .template = .prefix, .template_prefix = "g " }});
    model.applyFilter("google", .{});
    try std.testing.expectEqual(@as(usize, 2), model.rowCount());
    model.applyFilter("", .{});
    try std.testing.expectEqual(@as(usize, 2), model.rowCount());
}

fn templateItem(id: [:0]const u8, label: [:0]const u8, kind: Template, prefix: []const u8) MenuItem {
    return .{ .label = label, .index = 0, .icon = null, .id = id, .template = kind, .template_prefix = prefix };
}

fn launcherModel(allocator: std.mem.Allocator) !Model {
    var model = try Model.init(allocator, try testItems(allocator, &.{}), false);
    try model.setItems(allocator, &.{
        idItem("app:safari", "Safari"),
        idItem("app:notes", "Notes"),
        templateItem("calc", "{result}", .calc, ""),
        templateItem("g", "Search Google for {q}", .prefix, "g "),
        templateItem("yt", "YouTube: {q}", .prefix, "yt "),
        templateItem("web", "Search the web for {q}", .fallback, ""),
        templateItem("web2", "Look up {q}", .fallback, ""),
    });
    return model;
}

fn expectRows(model: *const Model, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, model.rowCount());
    for (expected, 0..) |label, row| try std.testing.expectEqualStrings(label, model.rowLabel(row));
}

test "calc row is pinned on top for an arithmetic query" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("12*(3+4)", .{});
    // nothing else matches, so the fallbacks follow the calc row
    try expectRows(&model, &.{ "84", "Search the web for 12*(3+4)", "Look up 12*(3+4)" });
    try std.testing.expectEqualStrings("12*(3+4)", model.rows.items[0].expanded.?.arg);
    try std.testing.expectEqualStrings("84", model.rows.items[0].expanded.?.result.?);
    try std.testing.expectEqual(@as(isize, 0), model.selected);

    // a plain number or an incomplete expression is not a calculation
    model.applyFilter("42", .{});
    try expectRows(&model, &.{ "Search the web for 42", "Look up 42" });
    model.applyFilter("1+", .{});
    try expectRows(&model, &.{ "Search the web for 1+", "Look up 1+" });
    model.applyFilter("1/0", .{});
    try expectRows(&model, &.{ "Search the web for 1/0", "Look up 1/0" });
}

test "calc sits above regular matches" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{}), false);
    defer model.deinit(allocator);
    try model.setItems(allocator, &.{ idItem("a", "Notes 1+2"), templateItem("calc", "= {result}", .calc, "") });
    model.applyFilter("1+2", .{});
    try expectRows(&model, &.{ "= 3", "Notes 1+2" });
    try std.testing.expectEqual(@as(usize, 1), model.match_count);
}

test "prefix rows are pinned above regular matches with the remainder" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    try model.appendItems(allocator, &.{idItem("n2", "g weather notes")});
    model.applyFilter("g  weather", .{});
    try expectRows(&model, &.{ "Search Google for weather", "g weather notes" });
    try std.testing.expectEqualStrings("weather", model.rows.items[0].expanded.?.arg);
    try std.testing.expect(model.rows.items[0].expanded.?.result == null);
    model.applyFilter("G x", .{});
    try expectRows(&model, &.{ "Search Google for x", "Search the web for G x", "Look up G x" });
    model.applyFilter("yt cats", .{});
    try expectRows(&model, &.{ "YouTube: cats", "Search the web for yt cats", "Look up yt cats" });
    // fallbacks stay hidden while a regular item matches
    model.applyFilter("g weather", .{});
    try expectRows(&model, &.{ "Search Google for weather", "g weather notes" });
}

test "a prefix needs the whole prefix typed" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("g", .{});
    // "g" alone is no prefix; it matches nothing, so fallbacks show
    try expectRows(&model, &.{ "Search the web for g", "Look up g" });
    model.applyFilter("g ", .{});
    try expectRows(&model, &.{ "Search Google for ", "Search the web for g ", "Look up g " });
}

test "fallbacks show only for a non-empty query with no regular match" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("", .{});
    try expectRows(&model, &.{ "Safari", "Notes" });
    model.applyFilter("   ", .{});
    try expectRows(&model, &.{ "Safari", "Notes" });
    model.applyFilter("saf", .{});
    try expectRows(&model, &.{"Safari"});
    model.applyFilter("zzqq", .{ .levenshtein_fallback = false });
    try expectRows(&model, &.{ "Search the web for zzqq", "Look up zzqq" });
    try std.testing.expectEqualStrings("zzqq", model.rows.items[1].expanded.?.arg);
    try std.testing.expectEqual(@as(usize, 0), model.match_count);
    try std.testing.expectEqual(@as(isize, 0), model.selected);
}

test "prefix rows come before fallbacks when nothing else matches" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("g zzqq", .{ .levenshtein_fallback = false });
    try expectRows(&model, &.{ "Search Google for zzqq", "Search the web for g zzqq", "Look up g zzqq" });
}

test "template items stay out of the counter total" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), model.regularTotal());
    try model.appendItems(allocator, &.{idItem("x", "X")});
    try std.testing.expectEqual(@as(usize, 3), model.regularTotal());
    try model.prependItems(allocator, &.{templateItem("t", "T {q}", .fallback, "")});
    try std.testing.expectEqual(@as(usize, 3), model.regularTotal());
    model.applyFilter("g hi", .{});
    try std.testing.expectEqual(@as(usize, 0), model.match_count);
    try std.testing.expectEqual(@as(usize, 4), model.rowCount());
}

test "selection by id survives updates that keep or move template rows" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("zzqq", .{ .levenshtein_fallback = false });
    model.moveSelection(1);
    try std.testing.expectEqualStrings("web2", model.selectedItem().?.id.?);

    // reordered template items: the user's row follows its id
    try model.setItems(allocator, &.{
        templateItem("web2", "Look up {q}", .fallback, ""),
        templateItem("web", "Search the web for {q}", .fallback, ""),
        idItem("app:x", "X"),
    });
    model.applyFilterKeepSelection("zzqq", .{ .levenshtein_fallback = false });
    try std.testing.expectEqual(@as(isize, 0), model.selected);
    try std.testing.expectEqualStrings("web2", model.selectedItem().?.id.?);
    try std.testing.expectEqualStrings("Look up zzqq", model.rowLabel(0));
}

test "selection by id survives updates under a calc query" {
    const allocator = std.testing.allocator;
    var model = try launcherModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("1+1", .{});
    try expectRows(&model, &.{ "2", "Search the web for 1+1", "Look up 1+1" });
    model.moveSelection(2);
    try std.testing.expectEqualStrings("web2", model.selectedItem().?.id.?);

    // regular items arrive and a prefix row is added; the user stays on "web2"
    try model.appendItems(allocator, &.{idItem("late", "Late 1+1")});
    model.applyFilterKeepSelection("1+1", .{});
    try expectRows(&model, &.{ "2", "Late 1+1" });
    // the selected template row is gone (fallbacks hide), so the same row index is kept, clamped
    try std.testing.expectEqual(@as(isize, 1), model.selected);

    try model.setItems(allocator, &.{ templateItem("calc", "{result}", .calc, ""), templateItem("web2", "Look up {q}", .fallback, "") });
    model.applyFilterKeepSelection("1+1", .{});
    try std.testing.expectEqualStrings("web2", model.selectedItem().?.id.?);
    try std.testing.expectEqual(@as(isize, 1), model.selected);
}

test "template rows show only when an item is a template" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator, try testItems(allocator, &.{ "alpha", "beta" }), false);
    defer model.deinit(allocator);
    model.applyFilter("1+2", .{});
    try std.testing.expectEqual(@as(usize, 0), model.rowCount());
    model.applyFilter("zzqq", .{});
    try std.testing.expectEqual(@as(usize, 0), model.rowCount());
}
