const std = @import("std");

pub fn unixTimestamp() i64 {
    return @intCast(std.c.time(null));
}

pub fn milliTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * std.time.ms_per_s +
        @divFloor(@as(i64, @intCast(tv.usec)), std.time.us_per_ms);
}
