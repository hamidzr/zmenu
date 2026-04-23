const std = @import("std");
const appconfig = @import("config.zig");
const pid = @import("pid.zig");
const menu = @import("menu.zig");
const exit_codes = @import("exit_codes.zig");
const io_compat = @import("io_compat.zig");

pub fn run(config: appconfig.Config, allocator: std.mem.Allocator) !void {
    const items = menu.readItems(allocator, false) catch {
        io_compat.stderrPrint("zmenu: stdin is empty\n", .{}) catch {};
        std.process.exit(exit_codes.unknown_error);
    };

    const pid_path = pid.create(allocator, config.menu_id) catch {
        io_compat.stderrPrint("zmenu: another instance is running\n", .{}) catch {};
        std.process.exit(exit_codes.unknown_error);
    };
    defer pid.remove(pid_path);

    var tty = io_compat.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) catch {
        io_compat.stderrPrint("zmenu: unable to open tty\n", .{}) catch {};
        std.process.exit(exit_codes.unknown_error);
    };
    defer io_compat.closeFile(tty);

    const original_term = enableRawMode(tty.handle) catch {
        io_compat.stderrPrint("zmenu: unable to enter raw mode\n", .{}) catch {};
        std.process.exit(exit_codes.unknown_error);
    };
    defer std.posix.tcsetattr(tty.handle, .NOW, original_term) catch {};

    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);
    if (config.initial_query.len > 0) {
        try input.appendSlice(allocator, config.initial_query);
    }

    try renderMatches(&tty, config.placeholder, input.items, items, config.numeric_selection_mode);

    var final_query: []const u8 = input.items;
    var exit_code: ?u8 = null;

    while (true) {
        const ch = io_compat.readByte(tty.handle) catch {
            exit_code = exit_codes.unknown_error;
            break;
        };

        switch (ch) {
            '\r', '\n' => {
                final_query = input.items;
                break;
            },
            127, 8 => {
                if (input.items.len > 0) {
                    input.items.len -= 1;
                    try renderMatches(&tty, config.placeholder, input.items, items, config.numeric_selection_mode);
                }
            },
            3 => {
                io_compat.filePrint(tty, "\r\n{s}Input cancelled\r\n", .{config.placeholder}) catch {};
                exit_code = exit_codes.user_canceled;
                break;
            },
            else => {
                if (ch >= 32 and ch <= 126) {
                    try input.append(allocator, ch);
                    try renderMatches(&tty, config.placeholder, input.items, items, config.numeric_selection_mode);
                }
            },
        }
    }

    if (exit_code != null) {
        std.posix.tcsetattr(tty.handle, .NOW, original_term) catch {};
        std.process.exit(exit_code.?);
    }

    var match_count: usize = 0;
    var first_match: ?[]const u8 = null;
    for (items) |item| {
        if (containsInsensitive(item.label, final_query)) {
            match_count += 1;
            if (first_match == null) {
                first_match = item.label;
            }
        }
    }

    if (match_count == 0) {
        io_compat.stderrPrint("No matches found\n", .{}) catch {};
        return;
    }
    if (match_count > 1) {
        io_compat.stderrPrint("Multiple matches found. Picking the first one.\n", .{}) catch {};
    }

    io_compat.stdoutPrint("\x1b[2J\x1b[H", .{}) catch {};
    io_compat.stdoutPrint("{s}", .{first_match.?}) catch {};
}

fn enableRawMode(fd: std.posix.fd_t) !std.posix.termios {
    const term = try std.posix.tcgetattr(fd);
    var raw = term;

    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.PARMRK = false;

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    try std.posix.tcsetattr(fd, .NOW, raw);
    return term;
}

fn renderMatches(
    tty: *std.Io.File,
    prompt: [:0]const u8,
    query: []const u8,
    items: []menu.MenuItem,
    numeric_selection_mode: appconfig.NumericSelectionMode,
) !void {
    try io_compat.filePrint(tty, "\x1b[2J\x1b[H", .{});
    try io_compat.filePrint(tty, "{s}: {s}\r\n", .{ prompt, query });
    try io_compat.filePrint(tty, "--------------------------------\r\n", .{});

    var total_matches: usize = 0;
    for (items) |item| {
        if (containsInsensitive(item.label, query)) {
            total_matches += 1;
        }
    }
    const numeric_enabled = appconfig.numericSelectionEnabledForMode(numeric_selection_mode, total_matches, query);

    var match_index: usize = 0;
    for (items) |item| {
        if (containsInsensitive(item.label, query)) {
            match_index += 1;
            if (numeric_enabled and match_index <= appconfig.numeric_shortcut_max) {
                try io_compat.filePrint(tty, "{d}. {s}\r\n", .{ match_index, item.label });
            } else {
                try io_compat.filePrint(tty, "{s}\r\n", .{item.label});
            }
        }
    }

    if (match_index == 0) {
        try io_compat.filePrint(tty, "(no matches)\r\n", .{});
    }
    try io_compat.filePrint(tty, "--------------------------------\r\n", .{});
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                break;
            }
        }
        if (j == needle.len) return true;
    }

    return false;
}
