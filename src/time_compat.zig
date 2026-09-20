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

var process_start_ns: i128 = 0;

/// Record process start so benches can report wall time from launch.
pub fn markProcessStart() void {
    process_start_ns = monotonicNs();
}

pub fn sinceProcessStartMs() f64 {
    if (process_start_ns == 0) return 0;
    return @as(f64, @floatFromInt(monotonicNs() - process_start_ns)) / 1_000_000.0;
}
