//! test-only helpers for tweaking process env vars
const std = @import("std");
const io_compat = @import("io_compat.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// a silent failure here would point the code under test at real user dirs
pub fn set(name: [:0]const u8, value: [:0]const u8) void {
    if (setenv(name, value, 1) != 0) @panic("setenv failed");
}

pub fn unset(name: [:0]const u8) void {
    if (unsetenv(name) != 0) @panic("unsetenv failed");
}

/// per-process dir under /tmp so concurrent test runs don't stomp each other
pub const Scratch = struct {
    allocator: std.mem.Allocator,
    root: [:0]const u8,

    pub fn init(allocator: std.mem.Allocator, comptime name: []const u8) !Scratch {
        const root = try std.fmt.allocPrintSentinel(allocator, "/tmp/zmenu-" ++ name ++ "-test-{d}", .{std.c.getpid()}, 0);
        const io = io_compat.globalIo();
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        try std.Io.Dir.cwd().createDirPath(io, root);
        return .{ .allocator = allocator, .root = root };
    }

    /// root ++ sub, e.g. path("/home")
    pub fn path(self: Scratch, sub: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.allocator, "{s}{s}", .{ self.root, sub }, 0);
    }

    pub fn deinit(self: Scratch) void {
        std.Io.Dir.cwd().deleteTree(io_compat.globalIo(), self.root) catch {};
    }
};

/// snapshot of a few vars so a test can restore them; pass an arena
pub const Guard = struct {
    names: []const [:0]const u8,
    saved: []?[:0]const u8,

    pub fn init(allocator: std.mem.Allocator, names: []const [:0]const u8) !Guard {
        const saved = try allocator.alloc(?[:0]const u8, names.len);
        for (names, saved) |name, *slot| {
            const value = try io_compat.getEnvVarOwnedOptional(allocator, name);
            slot.* = if (value) |v| try allocator.dupeSentinel(u8, v, 0) else null;
        }
        return .{ .names = names, .saved = saved };
    }

    pub fn restore(self: Guard) void {
        for (self.names, self.saved) |name, value| {
            if (value) |v| set(name, v) else unset(name);
        }
    }
};
