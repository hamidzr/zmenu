const std = @import("std");
const io_compat = @import("io_compat.zig");
const ipc = @import("ipc.zig");

pub fn create(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const pid_name = if (name.len == 0) "zmenu" else name;
    const temp_dir = try ipc.tempDir(allocator);
    const filename = try std.mem.concat(allocator, u8, &.{ pid_name, ".pid" });
    const pid_path = try std.fs.path.join(allocator, &.{ temp_dir, filename });

    if (try existingPidIsRunning(pid_path)) {
        return error.AlreadyRunning;
    }

    const file = io_compat.createFileAbsolute(pid_path, .{ .exclusive = true, .truncate = true }) catch |err| switch (err) {
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
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return true,
    };
    return true;
}
