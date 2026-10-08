const std = @import("std");
const appconfig = @import("../config.zig");
const io_compat = @import("../io_compat.zig");
const parse = @import("parse.zig");
const paths = @import("paths.zig");

const ConfigKeyVariant = struct {
    canonical: []const u8,
    camel: []const u8,
};

const config_key_variants = [_]ConfigKeyVariant{
    .{ .canonical = "title", .camel = "" },
    .{ .canonical = "prompt", .camel = "" },
    .{ .canonical = "menu_id", .camel = "menuId" },
    .{ .canonical = "search_method", .camel = "searchMethod" },
    .{ .canonical = "preserve_order", .camel = "preserveOrder" },
    .{ .canonical = "levenshtein_fallback", .camel = "levenshteinFallback" },
    .{ .canonical = "initial_query", .camel = "initialQuery" },
    .{ .canonical = "auto_accept", .camel = "autoAccept" },
    .{ .canonical = "terminal_mode", .camel = "terminalMode" },
    .{ .canonical = "follow_stdin", .camel = "followStdin" },
    .{ .canonical = "ipc_only", .camel = "ipcOnly" },
    .{ .canonical = "unique", .camel = "" },
    .{ .canonical = "numeric_selection_mode", .camel = "numericSelectionMode" },
    .{ .canonical = "no_numeric_selection", .camel = "noNumericSelection" },
    .{ .canonical = "show_icons", .camel = "showIcons" },
    .{ .canonical = "limit", .camel = "" },
    .{ .canonical = "min_width", .camel = "minWidth" },
    .{ .canonical = "min_height", .camel = "minHeight" },
    .{ .canonical = "max_width", .camel = "maxWidth" },
    .{ .canonical = "max_height", .camel = "maxHeight" },
    .{ .canonical = "row_height", .camel = "rowHeight" },
    .{ .canonical = "field_height", .camel = "fieldHeight" },
    .{ .canonical = "padding", .camel = "" },
    .{ .canonical = "numeric_column_width", .camel = "numericColumnWidth" },
    .{ .canonical = "icon_column_width", .camel = "iconColumnWidth" },
    .{ .canonical = "alternate_rows", .camel = "alternateRows" },
    .{ .canonical = "accept_custom_selection", .camel = "acceptCustomSelection" },
    .{ .canonical = "background_color", .camel = "backgroundColor" },
    .{ .canonical = "list_background_color", .camel = "listBackgroundColor" },
    .{ .canonical = "field_background_color", .camel = "fieldBackgroundColor" },
    .{ .canonical = "text_color", .camel = "textColor" },
    .{ .canonical = "secondary_text_color", .camel = "secondaryTextColor" },
    .{ .canonical = "selection_color", .camel = "selectionColor" },
    .{ .canonical = "corner_radius", .camel = "cornerRadius" },
    .{ .canonical = "vibrancy", .camel = "" },
};

pub fn loadConfigFile(allocator: std.mem.Allocator, menu_id: [:0]const u8, config: *appconfig.Config) !void {
    const path = try paths.findConfigPath(allocator, menu_id);
    if (path == null) return;

    const file = io_compat.openFileAbsolute(path.?, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer io_compat.closeFile(file);

    const contents = try io_compat.readAllFile(allocator, file, 64 * 1024);
    defer allocator.free(contents);
    try applyConfigContents(allocator, config, contents);
}

fn applyConfigContents(allocator: std.mem.Allocator, config: *appconfig.Config, contents: []const u8) !void {
    var seen_keys: [config_key_variants.len]?[]const u8 = @splat(null);
    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |line| {
        var trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        trimmed = std.mem.trim(u8, stripComment(trimmed), " \t");
        if (trimmed.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        value = stripQuotes(value);
        if (key.len == 0) continue;

        const canonical_index = canonicalKeyIndex(key) orelse return error.InvalidConfigKey;
        if (seen_keys[canonical_index]) |previous| {
            if (!std.mem.eql(u8, previous, key)) return error.ConfigKeyStyleConflict;
        } else {
            seen_keys[canonical_index] = key;
        }

        try applyConfigKV(allocator, config, key, value);
    }
}

pub fn writeDefaultConfig(allocator: std.mem.Allocator, menu_id: [:0]const u8) ![]const u8 {
    const path = try paths.defaultConfigPath(allocator, menu_id);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try paths.makePathAbsolute(dir);

    const defaults = appconfig.defaults();
    const file = try io_compat.createFileAbsolute(path, .{ .exclusive = true });
    defer io_compat.closeFile(file);

    try io_compat.filePrint(
        file,
        \\# gmenu config
        \\title: {s}
        \\prompt: {s}
        \\menu_id: "{s}"
        \\search_method: fuzzy
        \\preserve_order: false
        \\levenshtein_fallback: true
        \\initial_query: ""
        \\terminal_mode: false
        \\follow_stdin: false
        \\ipc_only: false
        \\unique: false
        \\auto_accept: false
        \\accept_custom_selection: true
        \\numeric_selection_mode: auto
        \\show_icons: false
        \\min_width: {d}
        \\min_height: {d}
        \\max_width: {d}
        \\max_height: {d}
        \\row_height: {d}
        \\field_height: {d}
        \\padding: {d}
        \\numeric_column_width: {d}
        \\icon_column_width: {d}
        \\alternate_rows: true
        \\background_color: ""
        \\list_background_color: ""
        \\field_background_color: ""
        \\text_color: ""
        \\secondary_text_color: ""
        \\selection_color: ""
        \\corner_radius: {d}
        \\vibrancy: true
        \\
    ,
        .{
            defaults.title,
            defaults.placeholder,
            menu_id,
            @as(i64, @intFromFloat(defaults.window_width)),
            @as(i64, @intFromFloat(defaults.window_height)),
            @as(i64, @intFromFloat(defaults.max_width)),
            @as(i64, @intFromFloat(defaults.max_height)),
            @as(i64, @intFromFloat(defaults.row_height)),
            @as(i64, @intFromFloat(defaults.field_height)),
            @as(i64, @intFromFloat(defaults.padding)),
            @as(i64, @intFromFloat(defaults.numeric_column_width)),
            @as(i64, @intFromFloat(defaults.icon_column_width)),
            @as(i64, @intFromFloat(defaults.corner_radius)),
        },
    );

    return path;
}

fn canonicalKeyIndex(key: []const u8) ?usize {
    for (config_key_variants, 0..) |variant, idx| {
        if (std.mem.eql(u8, key, variant.canonical)) return idx;
        if (variant.camel.len > 0 and std.mem.eql(u8, key, variant.camel)) return idx;
    }
    return null;
}

fn applyConfigKV(allocator: std.mem.Allocator, config: *appconfig.Config, key: []const u8, value: []const u8) !void {
    if (eqKey(key, "title")) {
        config.title = try allocator.dupeSentinel(u8, value, 0);
        return;
    }
    if (eqKey(key, "prompt")) {
        config.placeholder = try allocator.dupeSentinel(u8, value, 0);
        return;
    }
    if (eqKey(key, "menu_id") or eqKey(key, "menuId")) {
        config.menu_id = try allocator.dupeSentinel(u8, value, 0);
        return;
    }
    if (eqKey(key, "initial_query") or eqKey(key, "initialQuery")) {
        config.initial_query = try allocator.dupeSentinel(u8, value, 0);
        return;
    }
    if (eqKey(key, "search_method") or eqKey(key, "searchMethod")) {
        try parse.applySearchMethod(config, value);
        return;
    }
    if (eqKey(key, "terminal_mode") or eqKey(key, "terminalMode")) {
        config.terminal_mode = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "follow_stdin") or eqKey(key, "followStdin")) {
        config.follow_stdin = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "ipc_only") or eqKey(key, "ipcOnly")) {
        config.ipc_only = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "unique")) {
        config.unique = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "preserve_order") or eqKey(key, "preserveOrder")) {
        config.search.preserve_order = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "levenshtein_fallback") or eqKey(key, "levenshteinFallback")) {
        config.search.levenshtein_fallback = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "auto_accept") or eqKey(key, "autoAccept")) {
        config.auto_accept = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "accept_custom_selection") or eqKey(key, "acceptCustomSelection")) {
        config.accept_custom_selection = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "numeric_selection_mode") or eqKey(key, "numericSelectionMode")) {
        config.numeric_selection_mode = try parse.parseNumericSelectionMode(value);
        return;
    }
    if (eqKey(key, "no_numeric_selection") or eqKey(key, "noNumericSelection")) {
        const disabled = try parse.parseBool(value);
        config.numeric_selection_mode = if (disabled) .off else .on;
        return;
    }
    if (eqKey(key, "show_icons") or eqKey(key, "showIcons")) {
        config.show_icons = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "limit")) {
        config.search.limit = try std.fmt.parseInt(usize, value, 10);
        return;
    }
    if (eqKey(key, "min_width") or eqKey(key, "minWidth")) {
        config.window_width = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "min_height") or eqKey(key, "minHeight")) {
        config.window_height = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "max_width") or eqKey(key, "maxWidth")) {
        config.max_width = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "max_height") or eqKey(key, "maxHeight")) {
        config.max_height = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "row_height") or eqKey(key, "rowHeight")) {
        config.row_height = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "field_height") or eqKey(key, "fieldHeight")) {
        config.field_height = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "padding")) {
        config.padding = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "numeric_column_width") or eqKey(key, "numericColumnWidth")) {
        config.numeric_column_width = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "icon_column_width") or eqKey(key, "iconColumnWidth")) {
        config.icon_column_width = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "alternate_rows") or eqKey(key, "alternateRows")) {
        config.alternate_rows = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "corner_radius") or eqKey(key, "cornerRadius")) {
        config.corner_radius = try std.fmt.parseFloat(f64, value);
        return;
    }
    if (eqKey(key, "vibrancy")) {
        config.vibrancy = try parse.parseBool(value);
        return;
    }
    if (eqKey(key, "background_color") or eqKey(key, "backgroundColor")) {
        config.background_color = try parse.parseColorOptional(value);
        return;
    }
    if (eqKey(key, "list_background_color") or eqKey(key, "listBackgroundColor")) {
        config.list_background_color = try parse.parseColorOptional(value);
        return;
    }
    if (eqKey(key, "field_background_color") or eqKey(key, "fieldBackgroundColor")) {
        config.field_background_color = try parse.parseColorOptional(value);
        return;
    }
    if (eqKey(key, "text_color") or eqKey(key, "textColor")) {
        config.text_color = try parse.parseColorOptional(value);
        return;
    }
    if (eqKey(key, "secondary_text_color") or eqKey(key, "secondaryTextColor")) {
        config.secondary_text_color = try parse.parseColorOptional(value);
        return;
    }
    if (eqKey(key, "selection_color") or eqKey(key, "selectionColor")) {
        config.selection_color = try parse.parseColorOptional(value);
        return;
    }
}

fn stripComment(line: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return line;
    if (std.mem.indexOfScalar(u8, line[0..colon], '#')) |idx| return line[0..idx];
    const value_start = line.len - std.mem.trimStart(u8, line[colon + 1 ..], " \t").len;
    var quote: ?u8 = null;
    var escaped = false;
    for (line, 0..) |char, idx| {
        if (quote) |delimiter| {
            if (escaped) {
                escaped = false;
            } else if (delimiter == '"' and char == '\\') {
                escaped = true;
            } else if (char == delimiter) {
                quote = null;
            }
        } else if (char == '#') {
            return line[0..idx];
        } else if (idx == value_start and (char == '"' or char == '\'')) {
            quote = char;
        }
    }
    return line;
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn eqKey(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "quoted color hashes survive inline comments" {
    var config = appconfig.defaults();
    try applyConfigContents(std.testing.allocator, &config,
        \\background_color: "#112233" # dark theme
        \\textColor: '#aabbccdd' # camel alias
    );
    try std.testing.expectEqual(try parse.parseColorOptional("#112233"), config.background_color);
    try std.testing.expectEqual(try parse.parseColorOptional("#aabbccdd"), config.text_color);
}

test "quoted text retains hashes and comment markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = appconfig.defaults();
    try applyConfigContents(arena.allocator(), &config,
        \\title: "Review #2" # trailing comment
        \\prompt: 'Search #tag' # trailing comment
        \\initial_query: "quote \" #inside" # trailing comment
    );
    try std.testing.expectEqualStrings("Review #2", config.title);
    try std.testing.expectEqualStrings("Search #tag", config.placeholder);
    try std.testing.expectEqualStrings(
        \\quote \" #inside
    , config.initial_query);
}

test "unquoted comments and key style conflicts retain behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = appconfig.defaults();
    try applyConfigContents(arena.allocator(), &config,
        \\# full line comment
        \\ignored # comment containing a colon:
        \\title: Today's menu # trailing comment
        \\preserve_order: true # retain order
        \\background_color: none # no color
    );
    try std.testing.expectEqualStrings("Today's menu", config.title);
    try std.testing.expect(config.search.preserve_order);
    try std.testing.expectEqual(null, config.background_color);
    try std.testing.expectError(error.ConfigKeyStyleConflict, applyConfigContents(std.testing.allocator, &config,
        \\preserve_order: true
        \\preserveOrder: false
    ));
}
