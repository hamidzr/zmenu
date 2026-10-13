const std = @import("std");
const appconfig = @import("../config.zig");
const menu_id = @import("../menu_id.zig");
const parse = @import("parse.zig");

pub fn resolveMenuIDFromArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !?[:0]const u8 {
    if (findArgValue(args, "--menu-id", "-m")) |value| {
        try menu_id.validate(value);
        return try allocator.dupeSentinel(u8, value, 0);
    }
    return null;
}

pub fn applyArgs(allocator: std.mem.Allocator, args: []const [:0]const u8, config: *appconfig.Config) !void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--menu-id") or std.mem.eql(u8, arg, "-m")) {
            const value = try nextValue(args, &i);
            try menu_id.validate(value);
            config.menu_id = try allocator.dupeSentinel(u8, value, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--initial-query") or std.mem.eql(u8, arg, "-q")) {
            config.initial_query = try allocator.dupeSentinel(u8, try nextValue(args, &i), 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
            config.title = try allocator.dupeSentinel(u8, try nextValue(args, &i), 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            config.placeholder = try allocator.dupeSentinel(u8, try nextValue(args, &i), 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--search-method") or std.mem.eql(u8, arg, "-s")) {
            try parse.applySearchMethod(config, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--terminal")) {
            config.terminal_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--follow-stdin")) {
            config.follow_stdin = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ipc-only")) {
            config.ipc_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--unique") or std.mem.eql(u8, arg, "-u")) {
            config.unique = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-unique")) {
            config.unique = false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--unique=")) {
            const value = arg["--unique=".len..];
            config.unique = try parse.parseBool(value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--preserve-order") or std.mem.eql(u8, arg, "-o")) {
            config.search.preserve_order = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--levenshtein-fallback=")) {
            const value = arg["--levenshtein-fallback=".len..];
            config.search.levenshtein_fallback = try parse.parseBool(value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--levenshtein-fallback")) {
            config.search.levenshtein_fallback = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--no-levenshtein-fallback=")) {
            const value = arg["--no-levenshtein-fallback=".len..];
            config.search.levenshtein_fallback = !try parse.parseBool(value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-levenshtein-fallback")) {
            config.search.levenshtein_fallback = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--auto-accept")) {
            config.auto_accept = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--accept-custom-selection")) {
            config.accept_custom_selection = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-custom-selection")) {
            config.accept_custom_selection = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-numeric-selection")) {
            config.numeric_selection_mode = .off;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--no-numeric-selection=")) {
            const value = arg["--no-numeric-selection=".len..];
            const disabled = try parse.parseBool(value);
            config.numeric_selection_mode = if (disabled) .off else .on;
            continue;
        }
        if (std.mem.eql(u8, arg, "--numeric-selection-mode")) {
            config.numeric_selection_mode = try parse.parseNumericSelectionMode(try nextValue(args, &i));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--numeric-selection-mode=")) {
            const value = arg["--numeric-selection-mode=".len..];
            config.numeric_selection_mode = try parse.parseNumericSelectionMode(value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--show-icons")) {
            config.show_icons = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            config.search.limit = try std.fmt.parseInt(usize, try nextValue(args, &i), 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--min-width")) {
            config.window_width = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--min-height")) {
            config.window_height = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-width")) {
            config.max_width = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-height")) {
            config.max_height = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--row-height")) {
            config.row_height = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--field-height")) {
            config.field_height = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--padding")) {
            config.padding = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--numeric-column-width")) {
            config.numeric_column_width = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--icon-column-width")) {
            config.icon_column_width = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--alternate-rows")) {
            config.alternate_rows = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--corner-radius")) {
            config.corner_radius = try std.fmt.parseFloat(f64, try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-vibrancy")) {
            config.vibrancy = false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--vibrancy=")) {
            const value = arg["--vibrancy=".len..];
            config.vibrancy = try parse.parseBool(value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--background-color")) {
            config.background_color = try parse.parseColorOptional(try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--list-background-color")) {
            config.list_background_color = try parse.parseColorOptional(try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--field-background-color")) {
            config.field_background_color = try parse.parseColorOptional(try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--text-color")) {
            config.text_color = try parse.parseColorOptional(try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--secondary-text-color")) {
            config.secondary_text_color = try parse.parseColorOptional(try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--selection-color")) {
            config.selection_color = try parse.parseColorOptional(try nextValue(args, &i));
            continue;
        }
        if (std.mem.eql(u8, arg, "--render-bench")) {
            config.render_bench = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--startup-profile")) {
            config.startup_profile = true;
            continue;
        }
    }
}

fn nextValue(args: []const [:0]const u8, i: *usize) ![:0]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

pub fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return true;
    }
    return false;
}

fn findArgValue(args: []const [:0]const u8, long_flag: []const u8, short_flag: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, long_flag) or std.mem.eql(u8, arg, short_flag)) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
        if (std.mem.startsWith(u8, arg, long_flag)) {
            if (arg.len > long_flag.len and arg[long_flag.len] == '=') {
                return arg[long_flag.len + 1 ..];
            }
        }
    }
    return null;
}

test "value flags parse and report missing values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = appconfig.defaults();
    try applyArgs(arena.allocator(), &.{ "zmenu", "-m", "work", "--row-height", "40", "--limit", "7", "-t", "Title", "--no-vibrancy" }, &config);
    try std.testing.expectEqualStrings("work", config.menu_id);
    try std.testing.expectEqual(@as(f64, 40), config.row_height);
    try std.testing.expectEqual(@as(usize, 7), config.search.limit);
    try std.testing.expectEqualStrings("Title", config.title);
    try std.testing.expect(!config.vibrancy);

    try std.testing.expectError(error.MissingValue, applyArgs(arena.allocator(), &.{ "zmenu", "--padding" }, &config));
    try std.testing.expectError(error.MissingValue, applyArgs(arena.allocator(), &.{ "zmenu", "-q" }, &config));
}
