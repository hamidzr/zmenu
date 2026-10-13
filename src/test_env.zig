//! test-only helpers for tweaking process env vars
const std = @import("std");
const io_compat = @import("io_compat.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub fn set(name: [:0]const u8, value: [:0]const u8) void {
    _ = setenv(name, value, 1);
}

pub fn unset(name: [:0]const u8) void {
    _ = unsetenv(name);
}

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
