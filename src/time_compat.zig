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
var startup_profile: bool = false;
var first_input_recorded: bool = false;

pub fn enableStartupProfile(enabled: bool) void {
    startup_profile = enabled;
}

// timestamps only: never log query text or menu contents
pub fn startupStage(comptime stage: []const u8) void {
    if (!startup_profile) return;
    io_compat.stderrPrint("startup-profile stage={s} elapsed_ms={d:.3}\n", .{ stage, sinceProcessStartMs() }) catch {};
}

pub fn recordFirstInput() bool {
    if (!startup_profile or first_input_recorded) return false;
    first_input_recorded = true;
    startupStage("first_text_change");
    return true;
}

/// Record process start so benches can report wall time from launch.
pub fn markProcessStart() void {
    process_start_ns = monotonicNs();
}

pub fn sinceProcessStartMs() f64 {
    if (process_start_ns == 0) return 0;
    return @as(f64, @floatFromInt(monotonicNs() - process_start_ns)) / 1_000_000.0;
}
