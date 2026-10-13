const std = @import("std");
const io_compat = @import("io_compat.zig");
const ipc = @import("ipc.zig");
const test_env = @import("test_env.zig");

pub fn create(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const pid_name = if (name.len == 0) "zmenu" else name;
    const temp_dir = try ipc.tempDir(allocator);
    const filename = try std.mem.concat(allocator, u8, &.{ pid_name, ".pid" });
    const pid_path = try std.fs.path.join(allocator, &.{ temp_dir, filename });

    if (try existingPidIsRunning(pid_path)) {
        return error.AlreadyRunning;
    }

    const file = io_compat.createFileAbsolute(pid_path, .{ .exclusive = true, .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AlreadyRunning,
        else => return err,
    };
    defer io_compat.closeFile(file);

    const pid: std.posix.pid_t = @intCast(std.c.getpid());
    io_compat.filePrint(file, "{d}\n", .{pid}) catch {};

    return pid_path;
}

pub fn remove(path: []const u8) void {
    io_compat.deleteFileAbsolute(path) catch {};
}

fn existingPidIsRunning(pid_path: []const u8) !bool {
    const file = io_compat.openFileAbsolute(pid_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer io_compat.closeFile(file);

    const contents = io_compat.readAllFile(std.heap.page_allocator, file, 64) catch return false;
    defer std.heap.page_allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len == 0) {
        io_compat.deleteFileAbsolute(pid_path) catch {};
        return false;
    }

    const parsed_pid = std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch {
        io_compat.deleteFileAbsolute(pid_path) catch {};
        return false;
    };
    if (parsed_pid <= 0) {
        io_compat.deleteFileAbsolute(pid_path) catch {};
        return false;
    }
    if (pidIsAlive(parsed_pid)) {
        return true;
    }

    io_compat.deleteFileAbsolute(pid_path) catch {};
    return false;
}

fn pidIsAlive(pid: std.posix.pid_t) bool {
    if (pid <= 0) return false;
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return true,
    };
    return true;
}

test "pid file blocks a second instance and stale files are replaced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = io_compat.globalIo();

    const root = "/tmp/zmenu-pid-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const guard = try test_env.Guard.init(allocator, &.{"TMPDIR"});
    defer guard.restore();
    test_env.set("TMPDIR", root);

    const path = try create(allocator, "work");
    try std.testing.expectEqualStrings(root ++ "/work.pid", path);
    // our own pid is alive, so a second instance is refused
    try std.testing.expectError(error.AlreadyRunning, create(allocator, "work"));
    remove(path);

    for ([_][]const u8{ "", "garbage\n", "0\n", "-5\n" }) |stale| {
        const file = try io_compat.createFileAbsolute(path, .{ .truncate = true });
        try io_compat.filePrint(file, "{s}", .{stale});
        io_compat.closeFile(file);
        _ = try create(allocator, "work");
        remove(path);
    }
}
