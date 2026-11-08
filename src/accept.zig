const std = @import("std");
const menu = @import("menu.zig");

pub const Decision = union(enum) {
    /// nothing to accept; keep the menu open
    ignore,
    /// label is cached, output goes to stdout
    output: struct { label: []const u8, output: []const u8 },
};

pub fn decide(model: *menu.Model, ipc_only: bool, accept_custom_selection: bool, query: []const u8) Decision {
    if (model.rows.items.len == 0) {
        // ipc-only has no custom selection: there is no payload to print
        if (ipc_only or !accept_custom_selection) return .ignore;
        return .{ .output = .{ .label = query, .output = query } };
    }

    // no selection falls back to the first match
    const item = model.selectedItem() orelse model.items[model.rows.items[0].item];
    const output = if (ipc_only) item.ipc_payload orelse item.label else item.label;
    return .{ .output = .{ .label = item.label, .output = output } };
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

test "accept prefers selection and falls back to first match" {
    const allocator = std.testing.allocator;
    var model = try testModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("", .{});

    model.selected = 1;
    try expectOutput(decide(&model, false, true, ""), "beta", "beta");
    model.selected = -1;
    try expectOutput(decide(&model, false, true, ""), "alpha", "alpha");
}

test "ipc-only accept prints the stored payload or label" {
    const allocator = std.testing.allocator;
    var model = try testModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("", .{});

    model.selected = 0;
    try expectOutput(decide(&model, true, true, ""), "alpha", "{\"label\":\"alpha\",\"id\":\"a\"}");
    model.selected = 1;
    try expectOutput(decide(&model, true, true, ""), "beta", "beta");
}

test "no matches keeps the menu open in ipc-only, else custom or ignore" {
    const allocator = std.testing.allocator;
    var model = try testModel(allocator);
    defer model.deinit(allocator);
    model.applyFilter("zzz", .{ .levenshtein_fallback = false });
    try std.testing.expectEqual(@as(usize, 0), model.rows.items.len);

    try std.testing.expect(decide(&model, true, true, "zzz") == .ignore);
    try std.testing.expect(decide(&model, false, false, "zzz") == .ignore);
    try expectOutput(decide(&model, false, true, "zzz"), "zzz", "zzz");
}
