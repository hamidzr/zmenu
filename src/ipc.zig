const std = @import("std");
const io_compat = @import("io_compat.zig");

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
    const libc = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const names = [_][:0]const u8{ "TMPDIR", "TMP", "TEMP" };
    var saved: [names.len]?[:0]const u8 = undefined;
    for (names, 0..) |name, idx| {
        const value = try io_compat.getEnvVarOwnedOptional(allocator, name);
        saved[idx] = if (value) |v| try allocator.dupeSentinel(u8, v, 0) else null;
        _ = libc.unsetenv(name);
    }
    defer for (names, saved) |name, value| {
        if (value) |v| _ = libc.setenv(name, v, 1) else _ = libc.unsetenv(name);
    };

    try std.testing.expectEqualStrings("/tmp", try tempDir(allocator));
    _ = libc.setenv("TEMP", "/c", 1);
    try std.testing.expectEqualStrings("/c", try tempDir(allocator));
    _ = libc.setenv("TMP", "/b", 1);
    try std.testing.expectEqualStrings("/b", try tempDir(allocator));
    _ = libc.setenv("TMPDIR", "/a", 1);
    try std.testing.expectEqualStrings("/a", try tempDir(allocator));
}
