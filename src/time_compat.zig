const std = @import("std");
const io_compat = @import("io_compat.zig");

pub fn unixTimestamp() i64 {
    return std.Io.Timestamp.now(io_compat.globalIo(), .real).toSeconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io_compat.globalIo(), .real).toMilliseconds();
}

/// Monotonic nanosecond timestamp for elapsed-time measurement.
pub fn monotonicNs() i128 {
    return std.Io.Timestamp.now(io_compat.globalIo(), .awake).nanoseconds;
}
