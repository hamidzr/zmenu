//! What an item offers besides plain Enter: its alternate actions (by modifier),
//! the footer hint text and which accepts need confirmation. Plain Zig.

const std = @import("std");
const confirm = @import("confirm.zig");
const highlight = @import("search/highlight.zig");
const ipc = @import("ipc.zig");
const menu = @import("menu.zig");
const mods_mod = @import("mods.zig");

const Mods = mods_mod.Mods;

/// plain-Enter label when an item has no `action`
pub const default_action = "Open";

/// the action-related fields of an item
pub const Source = struct {
    action: ?[]const u8 = null,
    actions: ?[]const ipc.Action = null,
    confirm: ?std.json.Value = null,

    pub fn fromItem(item: menu.MenuItem) Source {
        return .{ .action = item.action, .actions = item.actions, .confirm = item.confirm };
    }

    pub fn primaryLabel(self: Source) []const u8 {
        const label = self.action orelse return default_action;
        return if (label.len > 0) label else default_action;
    }

    pub fn hasActions(self: Source) bool {
        const list = self.actions orelse return false;
        return list.len > 0;
    }

    /// Cmd+K has something to show, and the footer is worth showing
    pub fn isActionable(self: Source) bool {
        const label = self.action orelse "";
        return label.len > 0 or self.hasActions();
    }
};

/// the label an action shows; unnamed ones read "Action"
pub fn actionLabel(action: ipc.Action) []const u8 {
    return if (action.label.len > 0) action.label else "Action";
}

pub const Resolved = struct {
    /// set when this accept has to be confirmed first
    confirm: ?confirm.Spec,
};

/// What accepting with `mods` means for this item: plain Enter is always the
/// item itself (confirmed per its `confirm`); modifiers only work when the item
/// declares an action with exactly those modifiers. Null: nothing to do.
pub fn resolve(source: Source, mods: Mods) ?Resolved {
    if (mods.isEmpty()) return .{ .confirm = confirm.fromValue(source.confirm) };
    const list = source.actions orelse return null;
    for (list) |action| {
        const declared = Mods.parse(action.mods) orelse continue;
        if (declared.eql(mods)) return .{ .confirm = confirm.fromValue(action.confirm) };
    }
    return null;
}

/// Whether any listed row offers actions: this is what makes the footer show.
pub fn anyActionable(model: *const menu.Model) bool {
    for (model.rows.items) |row| {
        if (Source.fromItem(model.items[row.item]).isActionable()) return true;
    }
    return false;
}

/// one footer entry: the keys and what they do
pub const Segment = struct {
    keys_buf: [mods_mod.glyphs_max_len + mods_mod.return_glyph.len]u8 = undefined,
    keys_len: usize = 0,
    label: []const u8 = "",

    pub fn keys(self: *const Segment) []const u8 {
        return self.keys_buf[0..self.keys_len];
    }

    fn set(self: *Segment, modifiers: Mods, key: []const u8, label: []const u8) void {
        var glyphs_buf: [mods_mod.glyphs_max_len]u8 = undefined;
        const glyphs = modifiers.glyphs(&glyphs_buf);
        @memcpy(self.keys_buf[0..glyphs.len], glyphs);
        @memcpy(self.keys_buf[glyphs.len .. glyphs.len + key.len], key);
        self.keys_len = glyphs.len + key.len;
        self.label = label;
    }
};

/// at most "enter", two alternates and "cmd+k"
pub const max_segments = 4;
const max_alternates = 2;

pub const Hint = struct {
    segments: [max_segments]Segment = undefined,
    len: usize = 0,

    fn add(self: *Hint, modifiers: Mods, key: []const u8, label: []const u8) void {
        self.segments[self.len] = .{};
        self.segments[self.len].set(modifiers, key, label);
        self.len += 1;
    }

    pub fn items(self: *const Hint) []const Segment {
        return self.segments[0..self.len];
    }
};

pub const hint_separator = "   ";

/// Footer content for an item: "enter <action>", up to two alternates, then
/// "cmd+K Actions" when it has actions. Labels point into `source`.
pub fn hint(source: Source) Hint {
    var out = Hint{};
    out.add(.{}, mods_mod.return_glyph, source.primaryLabel());
    if (source.actions) |list| {
        var alternates: usize = 0;
        for (list) |action| {
            if (alternates == max_alternates) break;
            const declared = Mods.parse(action.mods) orelse continue;
            out.add(declared, mods_mod.return_glyph, actionLabel(action));
            alternates += 1;
        }
    }
    if (source.hasActions()) out.add(.{ .cmd = true }, "K", "Actions");
    return out;
}

/// fixed footer text for the action panel
pub fn panelHint() Hint {
    var out = Hint{};
    out.add(.{}, mods_mod.return_glyph, "Run");
    out.add(.{}, "esc", "Back");
    return out;
}

/// A hint as one string, entries joined by `hint_separator`, with the UTF-16
/// span of each entry's keys (for styling them apart from the labels).
pub const Rendered = struct {
    text: [:0]const u8,
    key_spans: [max_segments]struct { location: usize, length: usize } = undefined,
    span_count: usize = 0,
};

pub fn render(buf: []u8, value: *const Hint) Rendered {
    // the last byte is kept for the terminator
    const room = buf[0 .. buf.len - 1];
    var len: usize = 0;
    var out = Rendered{ .text = "" };
    for (value.items(), 0..) |segment, index| {
        if (index > 0) len = append(room, len, hint_separator);
        const keys = segment.keys();
        out.key_spans[out.span_count] = .{ .location = highlight.utf16Len(room[0..len]), .length = highlight.utf16Len(keys) };
        out.span_count += 1;
        len = append(room, len, keys);
        len = append(room, len, " ");
        len = append(room, len, segment.label);
    }
    buf[len] = 0;
    out.text = buf[0..len :0];
    return out;
}

/// appends as much of `text` as fits, never splitting a character
fn append(buf: []u8, len: usize, text: []const u8) usize {
    var take = @min(text.len, buf.len - len);
    while (take > 0 and take < text.len and text[take] & 0xC0 == 0x80) take -= 1;
    @memcpy(buf[len .. len + take], text[0..take]);
    return len + take;
}

const test_actions = [_]ipc.Action{
    .{ .mods = "cmd", .label = "Close window" },
    .{ .mods = "alt", .label = "Quit Safari", .confirm = .{ .string = "Quit Safari?" } },
    .{ .mods = "shift+cmd", .label = "Move to space" },
};

test "plain accept is the item, confirmed per its confirm" {
    try std.testing.expect(resolve(.{}, .{}).?.confirm == null);
    try std.testing.expect(resolve(.{ .confirm = .{ .bool = true } }, .{}).?.confirm.? == .default);
    try std.testing.expectEqualStrings("Sure?", resolve(.{ .confirm = .{ .string = "Sure?" } }, .{}).?.confirm.?.prompt());
}

test "modifiers need an action declared with exactly those modifiers" {
    const source = Source{ .actions = &test_actions };
    try std.testing.expect(resolve(source, .{ .cmd = true }) != null);
    try std.testing.expect(resolve(source, .{ .cmd = true }).?.confirm == null);
    try std.testing.expectEqualStrings("Quit Safari?", resolve(source, .{ .alt = true }).?.confirm.?.prompt());
    // combos match as a set, in any order
    try std.testing.expect(resolve(source, .{ .cmd = true, .shift = true }) != null);
    // a superset or a subset of a declared combo is not a match
    try std.testing.expect(resolve(source, .{ .cmd = true, .alt = true }) == null);
    try std.testing.expect(resolve(source, .{ .shift = true }) == null);
    try std.testing.expect(resolve(source, .{ .ctrl = true }) == null);
    // no actions at all
    try std.testing.expect(resolve(.{}, .{ .cmd = true }) == null);
    try std.testing.expect(resolve(.{ .action = "Open" }, .{ .cmd = true }) == null);
}

test "an action with unparseable mods never matches" {
    const bad = [_]ipc.Action{ .{ .mods = "hyper", .label = "x" }, .{ .mods = "", .label = "y" } };
    const source = Source{ .actions = &bad };
    try std.testing.expect(resolve(source, .{ .cmd = true }) == null);
    // an action with empty mods is not plain Enter either: that stays the item
    try std.testing.expect(resolve(source, .{}).?.confirm == null);
}

fn renderText(buf: []u8, source: Source) []const u8 {
    const built = hint(source);
    return render(buf, &built).text;
}

test "hint shows the action, two alternates and the actions key" {
    var buf: [256]u8 = undefined;
    const source = Source{ .action = "Switch", .actions = &test_actions };
    try std.testing.expectEqualStrings(
        "\u{21b5} Switch   \u{2318}\u{21b5} Close window   \u{2325}\u{21b5} Quit Safari   \u{2318}K Actions",
        renderText(&buf, source),
    );
}

test "hint defaults to Open and only lists Actions when there are some" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("\u{21b5} Open", renderText(&buf, .{}));
    try std.testing.expectEqualStrings("\u{21b5} Switch", renderText(&buf, .{ .action = "Switch" }));
    try std.testing.expectEqualStrings("\u{21b5} Open", renderText(&buf, .{ .action = "" }));
    const one = [_]ipc.Action{.{ .mods = "ctrl+alt", .label = "Copy path" }};
    try std.testing.expectEqualStrings(
        "\u{21b5} Open   \u{2303}\u{2325}\u{21b5} Copy path   \u{2318}K Actions",
        renderText(&buf, .{ .actions = &one }),
    );
    var empty = [_]ipc.Action{};
    try std.testing.expectEqualStrings("\u{21b5} Open", renderText(&buf, .{ .actions = &empty }));
}

test "hint skips actions it cannot match and unnamed ones read Action" {
    var buf: [256]u8 = undefined;
    const list = [_]ipc.Action{
        .{ .mods = "hyper", .label = "Never" },
        .{ .mods = "shift", .label = "" },
    };
    try std.testing.expectEqualStrings(
        "\u{21b5} Open   \u{21e7}\u{21b5} Action   \u{2318}K Actions",
        renderText(&buf, .{ .actions = &list }),
    );
}

test "key spans are UTF-16 offsets of each entry's keys" {
    var buf: [256]u8 = undefined;
    const built = hint(.{ .action = "Switch", .actions = &test_actions });
    const rendered = render(&buf, &built);
    try std.testing.expectEqual(@as(usize, 4), rendered.span_count);
    try std.testing.expectEqual(@as(usize, 0), rendered.key_spans[0].location);
    try std.testing.expectEqual(@as(usize, 1), rendered.key_spans[0].length);
    // "<enter> Switch" is 8 units, then the 3 spaces
    try std.testing.expectEqual(@as(usize, 8 + 3), rendered.key_spans[1].location);
    try std.testing.expectEqual(@as(usize, 2), rendered.key_spans[1].length);
}

test "render cuts at the buffer end on a character boundary" {
    var buf: [10]u8 = undefined;
    const built = hint(.{ .action = "Switch", .actions = &test_actions });
    const rendered = render(&buf, &built);
    try std.testing.expect(std.unicode.utf8ValidateSlice(rendered.text));
    try std.testing.expect(rendered.text.len <= buf.len);
}

test "panel hint is fixed" {
    var buf: [64]u8 = undefined;
    const built = panelHint();
    try std.testing.expectEqualStrings("\u{21b5} Run   esc Back", render(&buf, &built).text);
}

test "footer shows when any listed row has an action or actions" {
    const allocator = std.testing.allocator;
    const items = try allocator.alloc(menu.MenuItem, 3);
    items[0] = .{ .label = "alpha", .index = 0, .icon = null };
    items[1] = .{ .label = "beta", .index = 1, .icon = null, .action = "Switch" };
    items[2] = .{ .label = "gamma", .index = 2, .icon = null, .actions = &test_actions };
    var model = try menu.Model.init(allocator, items, false);
    defer model.deinit(allocator);

    model.applyFilter("", .{});
    try std.testing.expect(anyActionable(&model));
    // only rows that are listed count
    model.applyFilter("alph", .{});
    try std.testing.expect(!anyActionable(&model));
    model.applyFilter("gam", .{});
    try std.testing.expect(anyActionable(&model));
    model.applyFilter("zzqq", .{ .levenshtein_fallback = false });
    try std.testing.expect(!anyActionable(&model));
}
