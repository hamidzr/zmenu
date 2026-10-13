const std = @import("std");
const appconfig = @import("../config.zig");

pub fn applySearchMethod(config: *appconfig.Config, value: []const u8) !void {
    for ([_]@TypeOf(config.search.method){ .direct, .fuzzy, .fuzzy1, .fuzzy3, .default }) |method| {
        if (std.ascii.eqlIgnoreCase(value, @tagName(method))) {
            config.search.method = method;
            return;
        }
    }
    return error.InvalidSearchMethod;
}

pub fn parseBool(value: []const u8) !bool {
    if (eqlAnyIgnoreCase(value, &.{ "true", "1", "yes", "on" })) return true;
    if (eqlAnyIgnoreCase(value, &.{ "false", "0", "no", "off" })) return false;
    return error.InvalidBool;
}

/// bool words map to on/off, plus auto
pub fn parseNumericSelectionMode(value: []const u8) !appconfig.NumericSelectionMode {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    const enabled = parseBool(value) catch return error.InvalidNumericSelectionMode;
    return if (enabled) .on else .off;
}

fn eqlAnyIgnoreCase(value: []const u8, words: []const []const u8) bool {
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return true;
    }
    return false;
}

pub fn parseColorOptional(value: []const u8) !?appconfig.Color {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "none") or std.ascii.eqlIgnoreCase(trimmed, "default")) {
        return null;
    }
    return try parseHexColor(trimmed);
}

fn parseHexColor(value: []const u8) !appconfig.Color {
    var hex = value;
    if (hex.len > 0 and hex[0] == '#') {
        hex = hex[1..];
    }
    if (hex.len != 6 and hex.len != 8) return error.InvalidColor;

    const r = try parseHexByte(hex[0..2]);
    const g = try parseHexByte(hex[2..4]);
    const b = try parseHexByte(hex[4..6]);
    const a: u8 = if (hex.len == 8) try parseHexByte(hex[6..8]) else 255;

    return .{
        .r = @as(f64, @floatFromInt(r)) / 255.0,
        .g = @as(f64, @floatFromInt(g)) / 255.0,
        .b = @as(f64, @floatFromInt(b)) / 255.0,
        .a = @as(f64, @floatFromInt(a)) / 255.0,
    };
}

fn parseHexByte(value: []const u8) !u8 {
    return std.fmt.parseInt(u8, value, 16);
}

test "search method names match case-insensitively" {
    var config = appconfig.defaults();
    for ([_][]const u8{ "direct", "FUZZY", "fuzzy1", "Fuzzy3", "default" }, [_]@TypeOf(config.search.method){ .direct, .fuzzy, .fuzzy1, .fuzzy3, .default }) |name, expected| {
        try applySearchMethod(&config, name);
        try std.testing.expectEqual(expected, config.search.method);
    }
    try std.testing.expectError(error.InvalidSearchMethod, applySearchMethod(&config, "regex"));
}

test "bool and numeric selection words" {
    for ([_][]const u8{ "true", "1", "YES", "on" }) |word| {
        try std.testing.expect(try parseBool(word));
        try std.testing.expectEqual(appconfig.NumericSelectionMode.on, try parseNumericSelectionMode(word));
    }
    for ([_][]const u8{ "false", "0", "No", "OFF" }) |word| {
        try std.testing.expect(!try parseBool(word));
        try std.testing.expectEqual(appconfig.NumericSelectionMode.off, try parseNumericSelectionMode(word));
    }
    try std.testing.expectEqual(appconfig.NumericSelectionMode.auto, try parseNumericSelectionMode("Auto"));
    try std.testing.expectError(error.InvalidBool, parseBool("auto"));
    try std.testing.expectError(error.InvalidBool, parseBool("maybe"));
    try std.testing.expectError(error.InvalidNumericSelectionMode, parseNumericSelectionMode("maybe"));
}

test "colors parse hex with optional alpha and none" {
    const c = (try parseColorOptional(" #ff000080 ")).?;
    try std.testing.expectEqual(@as(f64, 1.0), c.r);
    try std.testing.expectEqual(@as(f64, 0.0), c.g);
    try std.testing.expectEqual(@as(f64, 128.0 / 255.0), c.a);
    try std.testing.expectEqual(@as(f64, 1.0), (try parseColorOptional("00ff00")).?.a);
    try std.testing.expect(try parseColorOptional("none") == null);
    try std.testing.expect(try parseColorOptional("") == null);
    try std.testing.expectError(error.InvalidColor, parseColorOptional("#abc"));
}
