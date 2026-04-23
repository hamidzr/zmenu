const std = @import("std");
const io_compat = @import("io_compat.zig");

pub const Item = struct {
    id: []const u8 = "",
    label: []const u8,
    icon: ?[]const u8 = null,
};

pub const Message = struct {
    v: u32 = 1,
    cmd: []const u8,
    items: ?[]Item = null,
};

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
    if (io_compat.getEnvVarOwned(allocator, "TMPDIR")) |value| return value else |err| {
        if (err != error.EnvironmentVariableNotFound) return err;
    }
    if (io_compat.getEnvVarOwned(allocator, "TMP")) |value| return value else |err| {
        if (err != error.EnvironmentVariableNotFound) return err;
    }
    if (io_compat.getEnvVarOwned(allocator, "TEMP")) |value| return value else |err| {
        if (err != error.EnvironmentVariableNotFound) return err;
    }
    return "/tmp";
}
