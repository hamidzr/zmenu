const std = @import("std");
const builtin = @import("builtin");
const io_compat = @import("io_compat.zig");
const test_env = @import("test_env.zig");

pub const State = struct {
    last_query: []const u8,
    last_selection: []const u8,
    last_selection_time: i64,
};

pub fn load(allocator: std.mem.Allocator, menu_id: []const u8) !?State {
    const path = try cacheFilePath(allocator, menu_id);
    const file = io_compat.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer io_compat.closeFile(file);

    const contents = try io_compat.readAllFile(allocator, file, 64 * 1024);
    var last_query: []const u8 = "";
    var last_selection: []const u8 = "";
    var last_selection_time: i64 = 0;

    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "last_query:")) {
            last_query = std.mem.trim(u8, trimmed["last_query:".len..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "last_selection:")) {
            last_selection = std.mem.trim(u8, trimmed["last_selection:".len..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "last_selection_time:")) {
            const raw = std.mem.trim(u8, trimmed["last_selection_time:".len..], " \t");
            last_selection_time = std.fmt.parseInt(i64, raw, 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "last_entry_time:")) {
            const raw = std.mem.trim(u8, trimmed["last_entry_time:".len..], " \t");
            last_selection_time = std.fmt.parseInt(i64, raw, 10) catch 0;
            continue;
        }
    }

    if (last_query.len == 0 and last_selection.len == 0) return null;

    return .{
        .last_query = last_query,
        .last_selection = last_selection,
        .last_selection_time = last_selection_time,
    };
}

pub fn save(allocator: std.mem.Allocator, menu_id: []const u8, state: State) !void {
    const dir = try cacheDir(allocator, menu_id);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_compat.globalIo(), dir, std.Io.File.Permissions.fromMode(0o700));
    const path = try cacheFilePath(allocator, menu_id);

    const file = try io_compat.createFileAbsolute(path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
    defer io_compat.closeFile(file);

    try io_compat.filePrint(
        file,
        "last_query: {s}\nlast_selection: {s}\nlast_selection_time: {d}\n",
        .{ state.last_query, state.last_selection, state.last_selection_time },
    );
}

fn cacheFilePath(allocator: std.mem.Allocator, menu_id: []const u8) ![]const u8 {
    const dir = try cacheDir(allocator, menu_id);
    return std.fs.path.join(allocator, &.{ dir, "cache.yaml" });
}

fn cacheDir(allocator: std.mem.Allocator, menu_id: []const u8) ![]const u8 {
    const root = try cacheRoot(allocator);
    const base = try std.fs.path.join(allocator, &.{ root, "gmenu" });
    if (menu_id.len == 0) return base;
    return std.fs.path.join(allocator, &.{ base, menu_id });
}

fn cacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (try io_compat.getEnvVarOwnedOptional(allocator, "XDG_CACHE_HOME")) |dir| return dir;

    const home = try io_compat.getEnvVarOwned(allocator, "HOME");
    if (builtin.os.tag == .macos) {
        return std.fs.path.join(allocator, &.{ home, "Library", "Caches" });
    }
    return std.fs.path.join(allocator, &.{ home, ".cache" });
}

test "save then load round-trips, legacy keys still parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = io_compat.globalIo();

    const root = "/tmp/zmenu-cache-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const guard = try test_env.Guard.init(allocator, &.{"XDG_CACHE_HOME"});
    defer guard.restore();
    test_env.set("XDG_CACHE_HOME", root);

    try std.testing.expect(try load(allocator, "work") == null);

    try save(allocator, "work", .{ .last_query = "fire", .last_selection = "Firefox", .last_selection_time = 42 });
    const loaded = (try load(allocator, "work")).?;
    try std.testing.expectEqualStrings("fire", loaded.last_query);
    try std.testing.expectEqualStrings("Firefox", loaded.last_selection);
    try std.testing.expectEqual(@as(i64, 42), loaded.last_selection_time);

    const legacy = try io_compat.createFileAbsolute(root ++ "/gmenu/work/cache.yaml", .{ .truncate = true });
    try io_compat.filePrint(legacy, "  last_query:  q  \r\nlast_entry_time: 7\nunknown: x\n", .{});
    io_compat.closeFile(legacy);
    const old = (try load(allocator, "work")).?;
    try std.testing.expectEqualStrings("q", old.last_query);
    try std.testing.expectEqualStrings("", old.last_selection);
    try std.testing.expectEqual(@as(i64, 7), old.last_selection_time);
}
