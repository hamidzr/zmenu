const std = @import("std");

pub const EnvError = std.mem.Allocator.Error || error{EnvironmentVariableNotFound};

pub fn globalIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn openFileAbsolute(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(globalIo(), path, options);
}

pub fn createFileAbsolute(path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(globalIo(), path, options);
}

pub fn deleteFileAbsolute(path: []const u8) !void {
    try std.Io.Dir.deleteFileAbsolute(globalIo(), path);
}

pub fn accessAbsolute(path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    try std.Io.Dir.accessAbsolute(globalIo(), path, options);
}

pub fn closeFile(file: std.Io.File) void {
    file.close(globalIo());
}

pub fn stdoutPrint(comptime fmt: []const u8, args: anytype) !void {
    try filePrint(std.Io.File.stdout(), fmt, args);
}

pub fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    try filePrint(std.Io.File.stderr(), fmt, args);
}

pub fn filePrint(file: anytype, comptime fmt: []const u8, args: anytype) !void {
    const file_value: std.Io.File = switch (@typeInfo(@TypeOf(file))) {
        .pointer => file.*,
        else => file,
    };
    const msg = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(msg);
    try std.Io.File.writeStreamingAll(file_value, globalIo(), msg);
}

pub fn printFd(fd: std.posix.fd_t, comptime fmt: []const u8, args: anytype) !void {
    try filePrint(.{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    }, fmt, args);
}

pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try std.posix.write(fd, bytes[offset..]);
        if (n == 0) return error.WriteFailed;
        offset += n;
    }
}

pub fn readAllFromFd(allocator: std.mem.Allocator, fd: std.posix.fd_t, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &buf);
        if (n == 0) break;
        if (out.items.len > max_bytes - n) return error.StreamTooLong;
        try out.appendSlice(allocator, buf[0..n]);
    }

    return out.toOwnedSlice(allocator);
}

pub fn readByte(fd: std.posix.fd_t) !u8 {
    var byte: [1]u8 = undefined;
    const n = try std.posix.read(fd, &byte);
    if (n == 0) return error.EndOfStream;
    return byte[0];
}

pub fn readAllFile(allocator: std.mem.Allocator, file: std.Io.File, max_bytes: usize) ![]u8 {
    return readAllFromFd(allocator, file.handle, max_bytes);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) EnvError![]const u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value_ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.sliceTo(value_ptr, 0));
}
