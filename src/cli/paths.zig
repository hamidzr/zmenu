const std = @import("std");
const builtin = @import("builtin");
const io_compat = @import("../io_compat.zig");
const test_env = @import("../test_env.zig");

pub fn defaultConfigPath(allocator: std.mem.Allocator, menu_id: [:0]const u8) ![]const u8 {
    const home = try homeDir(allocator);
    const gmenu_dir = if (home) |home_dir|
        try std.fs.path.join(allocator, &.{ home_dir, ".config", "gmenu" })
    else if (try userConfigDir(allocator, null)) |dir|
        try std.fs.path.join(allocator, &.{ dir, "gmenu" })
    else
        return error.MissingHome;
    return configFileIn(allocator, gmenu_dir, menu_id);
}

/// menu-scoped files win over base files; within each, ~/.config/gmenu,
/// ~/.gmenu, then the platform config dir
pub fn findConfigPath(allocator: std.mem.Allocator, menu_id: [:0]const u8) !?[]const u8 {
    const home = try homeDir(allocator);
    const config_home = try userConfigDir(allocator, home);

    var dirs: [3][]const u8 = undefined;
    var dir_count: usize = 0;
    if (home) |home_dir| {
        dirs[dir_count] = try std.fs.path.join(allocator, &.{ home_dir, ".config", "gmenu" });
        dirs[dir_count + 1] = try std.fs.path.join(allocator, &.{ home_dir, ".gmenu" });
        dir_count += 2;
    }
    if (config_home) |dir| {
        dirs[dir_count] = try std.fs.path.join(allocator, &.{ dir, "gmenu" });
        dir_count += 1;
    }

    const scopes: []const [:0]const u8 = if (menu_id.len > 0) &.{ menu_id, "" } else &.{""};
    for (scopes) |scope| {
        for (dirs[0..dir_count]) |dir| {
            const path = try configFileIn(allocator, dir, scope);
            if (pathExists(path)) return path;
        }
    }
    return null;
}

fn configFileIn(allocator: std.mem.Allocator, gmenu_dir: []const u8, menu_id: []const u8) ![]const u8 {
    if (menu_id.len > 0) return std.fs.path.join(allocator, &.{ gmenu_dir, menu_id, "config.yaml" });
    return std.fs.path.join(allocator, &.{ gmenu_dir, "config.yaml" });
}

pub fn makePathAbsolute(path: []const u8) !void {
    const io = io_compat.globalIo();
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, path);
    }
    var root = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    defer root.close(io);
    const trimmed = std.mem.trimStart(u8, path, "/");
    if (trimmed.len == 0) return;
    try root.createDirPath(io, trimmed);
}

fn homeDir(allocator: std.mem.Allocator) !?[]const u8 {
    return io_compat.getEnvVarOwnedOptional(allocator, "HOME");
}

fn userConfigDir(allocator: std.mem.Allocator, home: ?[]const u8) !?[]const u8 {
    if (try io_compat.getEnvVarOwnedOptional(allocator, "XDG_CONFIG_HOME")) |dir| return dir;
    if (home == null) return null;
    if (builtin.os.tag == .macos) {
        const path = try std.fs.path.join(allocator, &.{ home.?, "Library", "Application Support" });
        return @as(?[]const u8, path);
    }
    const path = try std.fs.path.join(allocator, &.{ home.?, ".config" });
    return @as(?[]const u8, path);
}

fn pathExists(path: []const u8) bool {
    io_compat.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "config lookup prefers scoped, then home before xdg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scratch = try test_env.Scratch.init(allocator, "paths");
    defer scratch.deinit();

    const guard = try test_env.Guard.init(allocator, &.{ "HOME", "XDG_CONFIG_HOME" });
    defer guard.restore();
    test_env.set("HOME", try scratch.path("/home"));
    test_env.set("XDG_CONFIG_HOME", try scratch.path("/xdg"));

    const touch = struct {
        fn f(path: []const u8) !void {
            try makePathAbsolute(std.fs.path.dirname(path).?);
            io_compat.closeFile(try io_compat.createFileAbsolute(path, .{}));
        }
    }.f;
    const expectFound = struct {
        fn f(alloc: std.mem.Allocator, menu_id: [:0]const u8, expected: ?[]const u8) !void {
            const found = try findConfigPath(alloc, menu_id);
            if (expected) |path| {
                try std.testing.expectEqualStrings(path, found.?);
            } else {
                try std.testing.expect(found == null);
            }
        }
    }.f;

    try expectFound(allocator, "work", null);
    try touch(try scratch.path("/xdg/gmenu/config.yaml"));
    try expectFound(allocator, "work", try scratch.path("/xdg/gmenu/config.yaml"));
    try touch(try scratch.path("/home/.gmenu/config.yaml"));
    try expectFound(allocator, "", try scratch.path("/home/.gmenu/config.yaml"));
    try touch(try scratch.path("/home/.config/gmenu/config.yaml"));
    try expectFound(allocator, "", try scratch.path("/home/.config/gmenu/config.yaml"));
    try touch(try scratch.path("/xdg/gmenu/work/config.yaml"));
    try expectFound(allocator, "work", try scratch.path("/xdg/gmenu/work/config.yaml"));
    try touch(try scratch.path("/home/.gmenu/work/config.yaml"));
    try expectFound(allocator, "work", try scratch.path("/home/.gmenu/work/config.yaml"));
    try touch(try scratch.path("/home/.config/gmenu/work/config.yaml"));
    try expectFound(allocator, "work", try scratch.path("/home/.config/gmenu/work/config.yaml"));

    try std.testing.expectEqualStrings(try scratch.path("/home/.config/gmenu/work/config.yaml"), try defaultConfigPath(allocator, "work"));
    try std.testing.expectEqualStrings(try scratch.path("/home/.config/gmenu/config.yaml"), try defaultConfigPath(allocator, ""));
    test_env.unset("HOME");
    try std.testing.expectEqualStrings(try scratch.path("/xdg/gmenu/config.yaml"), try defaultConfigPath(allocator, ""));
    test_env.unset("XDG_CONFIG_HOME");
    try std.testing.expectError(error.MissingHome, defaultConfigPath(allocator, ""));
}
