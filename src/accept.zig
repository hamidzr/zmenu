const std = @import("std");
const menu = @import("menu.zig");

pub const Decision = union(enum) {
    /// nothing to accept; keep the menu open
    ignore,
    /// label is cached, output goes to stdout
    output: struct { label: []const u8, output: []const u8 },
};

/// `arena` owns the spliced output; the caller prints it and exits
pub fn decide(arena: std.mem.Allocator, model: *menu.Model, ipc_only: bool, accept_custom_selection: bool, query: []const u8) Decision {
    if (model.rows.items.len == 0) {
        // ipc-only has no custom selection: there is no payload to print
        if (ipc_only or !accept_custom_selection) return .ignore;
        return .{ .output = .{ .label = query, .output = query } };
    }

    // no selection falls back to the first row
    const row = model.selectedRow() orelse 0;
    const item = model.rowItem(row);
    const label = model.rowLabel(row);
    if (!ipc_only) return .{ .output = .{ .label = label, .output = label } };
    const payload = item.ipc_payload orelse return .{ .output = .{ .label = label, .output = label } };
    const expanded = model.rows.items[row].expanded;
    const fields = Fields{
        .query = query,
        .arg = if (expanded) |e| e.arg else null,
        .result = if (expanded) |e| e.result else null,
    };
    // a payload that cannot be spliced (cannot happen for stored payloads) goes out as stored
    const output = spliceFields(arena, payload, fields) catch payload;
    return .{ .output = .{ .label = label, .output = output } };
}

/// what zmenu adds to the stored payload on accept
pub const Fields = struct {
    /// the full raw query text, always
    query: []const u8,
    /// canonical "+"-joined modifiers; null or empty adds nothing
    mods: ?[]const u8 = null,
    /// template rows: the prefix remainder, the whole query, or the expression
    arg: ?[]const u8 = null,
    /// calc rows: the formatted value
    result: ?[]const u8 = null,
};

/// Splices `fields` into the payload object. An existing key of the same name is
/// replaced, so the injected value wins and no key repeats. Values are JSON-escaped.
pub fn spliceFields(arena: std.mem.Allocator, payload: []const u8, fields: Fields) ![]const u8 {
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{});
    if (parsed != .object) return error.NotAnObject;
    try parsed.object.put(arena, "query", .{ .string = fields.query });
    if (fields.mods) |mods| {
        if (mods.len > 0) try parsed.object.put(arena, "mods", .{ .string = mods });
    }
    if (fields.arg) |arg| try parsed.object.put(arena, "arg", .{ .string = arg });
    if (fields.result) |result| try parsed.object.put(arena, "result", .{ .string = result });
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(parsed, .{}, &out.writer);
    return out.written();
}

fn testModel(allocator: std.mem.Allocator) !menu.Model {
    const items = try allocator.alloc(menu.MenuItem, 2);
    items[0] = .{ .label = "alpha", .index = 0, .icon = null, .ipc_payload = "{\"label\":\"alpha\",\"id\":\"a\"}" };
    items[1] = .{ .label = "beta", .index = 1, .icon = null };
    return menu.Model.init(allocator, items, false);
}

fn expectOutput(decision: Decision, label: []const u8, output: []const u8) !void {
    try std.testing.expectEqualStrings(label, decision.output.label);
    try std.testing.expectEqualStrings(output, decision.output.output);
}

fn expectJsonField(arena: std.mem.Allocator, output: []const u8, key: []const u8, expected: ?[]const u8) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{});
    const value = parsed.object.get(key) orelse {
        try std.testing.expect(expected == null);
        return;
    };
    try std.testing.expectEqualStrings(expected.?, value.string);
}

test "accept prefers selection and falls back to first match" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var model = try testModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("", .{});

    model.selected = 1;
    try expectOutput(decide(arena.allocator(), &model, false, true, ""), "beta", "beta");
    model.selected = -1;
    try expectOutput(decide(arena.allocator(), &model, false, true, ""), "alpha", "alpha");
}

test "ipc-only accept prints the stored payload with the query, or the label" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var model = try testModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("", .{});

    model.selected = 0;
    try expectOutput(decide(arena.allocator(), &model, true, true, ""), "alpha", "{\"label\":\"alpha\",\"id\":\"a\",\"query\":\"\"}");
    model.selected = 1;
    try expectOutput(decide(arena.allocator(), &model, true, true, ""), "beta", "beta");
}

test "no matches keeps the menu open in ipc-only, else custom or ignore" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var model = try testModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("zzz", .{ .levenshtein_fallback = false });
    try std.testing.expectEqual(@as(usize, 0), model.rows.items.len);

    try std.testing.expect(decide(arena.allocator(), &model, true, true, "zzz") == .ignore);
    try std.testing.expect(decide(arena.allocator(), &model, false, false, "zzz") == .ignore);
    try expectOutput(decide(arena.allocator(), &model, false, true, "zzz"), "zzz", "zzz");
}

test "splice adds fields, escapes values and lets the injected value win" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try spliceFields(a, "{\"id\":\"x\",\"query\":\"old\",\"arg\":\"old\"}", .{
        .query = "say \"hi\"\n\\",
        .mods = "shift+cmd",
        .arg = "a\tb",
        .result = "42",
    });
    try expectJsonField(a, out, "id", "x");
    try expectJsonField(a, out, "query", "say \"hi\"\n\\");
    try expectJsonField(a, out, "mods", "shift+cmd");
    try expectJsonField(a, out, "arg", "a\tb");
    try expectJsonField(a, out, "result", "42");
    // no key repeats
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"query\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"arg\""));
}

test "splice omits empty mods and unset fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try spliceFields(a, "{\"label\":\"x\"}", .{ .query = "q", .mods = "" });
    try expectJsonField(a, out, "mods", null);
    try expectJsonField(a, out, "arg", null);
    try expectJsonField(a, out, "result", null);
    try expectJsonField(a, out, "query", "q");
    try std.testing.expectError(error.NotAnObject, spliceFields(a, "[1]", .{ .query = "q" }));
}

test "template rows output their arg and result" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const items = try allocator.alloc(menu.MenuItem, 3);
    items[0] = .{ .label = "Safari", .index = 0, .icon = null, .ipc_payload = "{\"id\":\"app:safari\",\"label\":\"Safari\"}" };
    items[1] = .{
        .label = "Search Google for {q}",
        .index = 1,
        .icon = null,
        .template = .prefix,
        .template_prefix = "g ",
        .ipc_payload = "{\"id\":\"g\",\"label\":\"Search Google for {q}\"}",
    };
    items[2] = .{
        .label = "{result}",
        .subtitle = "{q}",
        .index = 2,
        .icon = null,
        .template = .calc,
        .ipc_payload = "{\"id\":\"calc\",\"label\":\"{result}\"}",
    };
    var model = try menu.Model.init(allocator, items, false);
    defer model.deinit(allocator);

    model.applyFilter("g weather", .{});
    model.selected = 0;
    const prefixed = decide(arena.allocator(), &model, true, false, "g weather");
    try std.testing.expectEqualStrings("Search Google for weather", prefixed.output.label);
    try expectJsonField(arena.allocator(), prefixed.output.output, "arg", "weather");
    try expectJsonField(arena.allocator(), prefixed.output.output, "query", "g weather");
    try expectJsonField(arena.allocator(), prefixed.output.output, "result", null);
    try expectJsonField(arena.allocator(), prefixed.output.output, "id", "g");

    model.applyFilter("12*(3+4)", .{});
    model.selected = 0;
    const calc = decide(arena.allocator(), &model, true, false, "12*(3+4)");
    try std.testing.expectEqualStrings("84", calc.output.label);
    try expectJsonField(arena.allocator(), calc.output.output, "arg", "12*(3+4)");
    try expectJsonField(arena.allocator(), calc.output.output, "result", "84");
    try expectJsonField(arena.allocator(), calc.output.output, "query", "12*(3+4)");
}
