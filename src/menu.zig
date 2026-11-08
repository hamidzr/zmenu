const std = @import("std");
const io_compat = @import("io_compat.zig");
const search = @import("search.zig");

pub const MenuItem = struct {
    label: [:0]const u8,
    index: usize,
    icon: ?[:0]const u8,
    ipc_payload: ?[]const u8 = null,
    /// client-supplied IPC id; stdin items have none
    id: ?[]const u8 = null,
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

pub const Model = struct {
    items: []MenuItem,
    labels: [][]const u8,
    matches: std.ArrayList(search.Match),
    filtered: std.ArrayList(usize),
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

        const labels = try allocator.alloc([]const u8, working.len);
        for (working, 0..) |*item, idx| {
            item.index = idx;
            labels[idx] = item.label[0..item.label.len];
        }

        var matches = std.ArrayList(search.Match).empty;
        try matches.ensureTotalCapacity(allocator, working.len);

        var filtered = std.ArrayList(usize).empty;
        try filtered.ensureTotalCapacity(allocator, working.len);

        const scores = try allocator.alloc(i32, working.len);
        @memset(scores, 0);

        return .{
            .items = working,
            .labels = labels,
            .matches = matches,
            .filtered = filtered,
            .scores = scores,
            .match_count = 0,
            .selected = -1,
            .unique = unique,
            .seen = seen,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.clearAnchor();
        self.matches.deinit(allocator);
        self.filtered.deinit(allocator);
        self.seen.deinit(allocator);
        allocator.free(self.items);
        allocator.free(self.labels);
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
        const item = self.items[self.filtered.items[row]];
        const key = self.allocator.dupe(u8, item.id orelse item.label) catch return;
        self.anchor = .{ .key = key, .by_id = item.id != null, .row = row };
    }

    fn anchorMatches(anchor: Anchor, item: MenuItem) bool {
        if (anchor.by_id) return if (item.id) |id| std.mem.eql(u8, id, anchor.key) else false;
        return item.id == null and std.mem.eql(u8, item.label, anchor.key);
    }

    fn refilter(self: *Model, query: []const u8, opts: search.Options) void {
        @memset(self.scores, 0);
        search.filterIndices(self.labels, query, opts, &self.matches, &self.filtered);
        self.match_count = self.matches.items.len;
        for (self.matches.items) |match| {
            if (match.index < self.scores.len) {
                self.scores[match.index] = match.score;
            }
        }
    }

    /// query changed: select the top row and forget any manual move
    pub fn applyFilter(self: *Model, query: []const u8, opts: search.Options) void {
        self.refilter(query, opts);
        self.moved = false;
        self.clearAnchor();
        self.selected = if (self.filtered.items.len == 0) -1 else 0;
    }

    /// items changed under an unchanged query: if the user moved the
    /// selection, keep it on the same item (id, else label), else on the same
    /// row clamped; otherwise select the top row
    pub fn applyFilterKeepSelection(self: *Model, query: []const u8, opts: search.Options) void {
        self.refilter(query, opts);
        defer self.clearAnchor();
        const count = self.filtered.items.len;
        if (count == 0) {
            self.selected = -1;
            return;
        }
        self.selected = 0;
        const anchor = self.anchor orelse return;
        for (self.filtered.items, 0..) |item_index, row| {
            if (anchorMatches(anchor, self.items[item_index])) {
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
        self.labels = try allocator.realloc(self.labels, new_len);
        self.scores = try allocator.realloc(self.scores, new_len);

        var i: usize = 0;
        while (i < to_add.len) : (i += 1) {
            const idx = old_len + i;
            var item = to_add[i];
            item.index = idx;
            self.items[idx] = item;
            self.labels[idx] = item.label[0..item.label.len];
            self.scores[idx] = 0;
        }

        try self.matches.ensureTotalCapacity(allocator, new_len);
        try self.filtered.ensureTotalCapacity(allocator, new_len);
    }

    pub fn prependItems(self: *Model, allocator: std.mem.Allocator, new_items: []const MenuItem) !void {
        if (new_items.len == 0) return;

        const filter_result = try self.filterUniqueIncoming(allocator, new_items);
        defer if (filter_result.owned) |buf| allocator.free(buf);
        const to_add = filter_result.items;
        if (to_add.len == 0) return;
        self.captureAnchor();

        const old_items = self.items;
        const old_labels = self.labels;
        const old_scores = self.scores;

        const old_len = old_items.len;
        const new_len = old_len + to_add.len;

        const items = try allocator.alloc(MenuItem, new_len);
        const labels = try allocator.alloc([]const u8, new_len);
        const scores = try allocator.alloc(i32, new_len);
        @memset(scores, 0);

        for (to_add, 0..) |item_in, idx| {
            var item = item_in;
            item.index = idx;
            items[idx] = item;
            labels[idx] = item.label[0..item.label.len];
        }

        for (old_items, 0..) |item_in, offset| {
            const idx = to_add.len + offset;
            var item = item_in;
            item.index = idx;
            items[idx] = item;
            labels[idx] = item.label[0..item.label.len];
        }

        self.items = items;
        self.labels = labels;
        self.scores = scores;

        allocator.free(old_items);
        allocator.free(old_labels);
        allocator.free(old_scores);

        try self.matches.ensureTotalCapacity(allocator, new_len);
        try self.filtered.ensureTotalCapacity(allocator, new_len);
    }

    pub fn setItems(self: *Model, allocator: std.mem.Allocator, new_items: []const MenuItem) !void {
        self.captureAnchor();
        if (self.unique) self.seen.clearRetainingCapacity();

        const filter_result = try self.filterUniqueIncoming(allocator, new_items);
        defer if (filter_result.owned) |buf| allocator.free(buf);
        const to_set = filter_result.items;
        const new_len = to_set.len;

        self.items = try allocator.realloc(self.items, new_len);
        self.labels = try allocator.realloc(self.labels, new_len);
        self.scores = try allocator.realloc(self.scores, new_len);
        @memset(self.scores, 0);

        for (to_set, 0..) |item_in, idx| {
            var item = item_in;
            item.index = idx;
            self.items[idx] = item;
            self.labels[idx] = item.label[0..item.label.len];
        }

        self.matches.clearRetainingCapacity();
        self.filtered.clearRetainingCapacity();
        try self.matches.ensureTotalCapacity(allocator, new_len);
        try self.filtered.ensureTotalCapacity(allocator, new_len);
        self.match_count = 0;
        self.selected = -1;
    }

    pub fn moveSelection(self: *Model, delta: isize) void {
        self.moved = true;
        if (self.filtered.items.len == 0) {
            self.selected = -1;
            return;
        }

        const count: isize = @intCast(self.filtered.items.len);
        self.selected = @mod(@max(self.selected, 0) + delta, count);
    }

    pub fn selectedRow(self: *Model) ?usize {
        if (self.selected < 0) return null;
        const row: usize = @intCast(self.selected);
        if (row >= self.filtered.items.len) return null;
        return row;
    }

    pub fn selectedItem(self: *Model) ?MenuItem {
        const row = self.selectedRow() orelse return null;
        const item_index = self.filtered.items[row];
        return self.items[item_index];
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
