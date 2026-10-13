const std = @import("std");
const io_compat = @import("io_compat.zig");
const test_env = @import("test_env.zig");

pub const Item = struct {
    id: []const u8 = "",
    label: []const u8,
    icon: ?[]const u8 = null,
};

pub const Message = struct {
    v: u32 = 2,
    cmd: []const u8,
    items: ?[]Item = null,
};

pub const Command = enum { set, append, prepend };

/// commands match case-insensitively
pub fn parseCommand(cmd: []const u8) ?Command {
    for ([_]Command{ .set, .append, .prepend }) |command| {
        if (std.ascii.eqlIgnoreCase(cmd, @tagName(command))) return command;
    }
    return null;
}

pub fn socketPath(allocator: std.mem.Allocator, menu_id: []const u8) ![]const u8 {
    const dir = try tempDir(allocator);
    const name = try socketName(allocator, menu_id);
    return std.fs.path.join(allocator, &.{ dir, name });
}

pub fn socketName(allocator: std.mem.Allocator, menu_id: []const u8) ![]const u8 {
    if (menu_id.len > 0) {
        return std.fmt.allocPrint(allocator, "zmenu.{s}.sock", .{menu_id});
    }
    return allocator.dupe(u8, "zmenu.sock");
}

pub fn tempDir(allocator: std.mem.Allocator) ![]const u8 {
    for ([_][]const u8{ "TMPDIR", "TMP", "TEMP" }) |name| {
        if (try io_compat.getEnvVarOwnedOptional(allocator, name)) |value| return value;
    }
    return "/tmp";
}

test parseCommand {
    try std.testing.expectEqual(Command.set, parseCommand("SET").?);
    try std.testing.expectEqual(Command.append, parseCommand("append").?);
    try std.testing.expectEqual(Command.prepend, parseCommand("Prepend").?);
    try std.testing.expect(parseCommand("clear") == null);
}

test "tempDir falls back TMPDIR, TMP, TEMP, then /tmp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const names = [_][:0]const u8{ "TMPDIR", "TMP", "TEMP" };
    const guard = try test_env.Guard.init(allocator, &names);
    defer guard.restore();
    for (names) |name| test_env.unset(name);

    try std.testing.expectEqualStrings("/tmp", try tempDir(allocator));
    test_env.set("TEMP", "/c");
    try std.testing.expectEqualStrings("/c", try tempDir(allocator));
    test_env.set("TMP", "/b");
    try std.testing.expectEqualStrings("/b", try tempDir(allocator));
    test_env.set("TMPDIR", "/a");
    try std.testing.expectEqualStrings("/a", try tempDir(allocator));
}
