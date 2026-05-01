const std = @import("std");
const appconfig = @import("config.zig");
const args = @import("cli/args.zig");
const config_file = @import("cli/config_file.zig");
const env = @import("cli/env.zig");
const io_compat = @import("io_compat.zig");

pub fn parse(allocator: std.mem.Allocator, proc_args: std.process.Args) !appconfig.Config {
    var config = appconfig.defaults();
    const argv = try proc_args.toSlice(allocator);

    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        printHelp();
        std.process.exit(0);
    }

    const cli_menu_id = try args.resolveMenuIDFromArgs(allocator, argv);
    const config_menu_id: [:0]const u8 = cli_menu_id orelse "";

    if (args.hasFlag(argv, "--init-config")) {
        const path = try config_file.writeDefaultConfig(allocator, config_menu_id);
        io_compat.stdoutPrint("zmenu: wrote config to {s}\n", .{path}) catch {};
        std.process.exit(0);
    }

    try config_file.loadConfigFile(allocator, config_menu_id, &config);
    try env.applyEnv(allocator, &config);
    try args.applyArgs(allocator, argv, &config);

    return config;
}

fn printHelp() void {
    io_compat.stdoutPrint(
        \\zmenu (zig gmenu) usage:
        \\  zmenu [flags]
        \\
        \\Flags:
        \\  -h, --help                  Show this help text
        \\  -m, --menu-id <id>           Menu ID namespace
        \\  -q, --initial-query <text>   Pre-filled search query
        \\  -t, --title <text>           Window title
        \\  -p, --prompt <text>          Prompt text
        \\  -s, --search-method <name>   direct|fuzzy|fuzzy1|fuzzy3|default
        \\  -o, --preserve-order         Preserve match order
        \\      --no-levenshtein-fallback Disable Levenshtein fallback
        \\      --auto-accept            Auto accept when final single match
        \\      --terminal               Terminal mode
        \\      --follow-stdin           Keep running and append stdin
        \\      --ipc-only               Ignore stdin and wait for IPC updates
        \\  -u, --unique                 Drop duplicate rows by label
        \\      --no-unique              Allow duplicates (default)
        \\      --numeric-selection-mode <mode> off|on|auto
        \\      --no-numeric-selection   Disable numeric shortcuts
        \\      --show-icons             Show icon hint column
        \\      --min-width <px>         Minimum window width
        \\      --min-height <px>        Minimum window height
        \\      --max-width <px>         Maximum window width
        \\      --max-height <px>        Maximum window height
        \\      --row-height <px>        Table row height
        \\      --field-height <px>      Search field height
        \\      --padding <px>           Window padding
        \\      --numeric-column-width <px> Numeric column width
        \\      --icon-column-width <px> Icon column width
        \\      --alternate-rows         Zebra striping
        \\      --background-color <hex> Window background (#RRGGBB or #RRGGBBAA)
        \\      --list-background-color <hex> List background
        \\      --field-background-color <hex> Input background
        \\      --text-color <hex>        Primary text color
        \\      --secondary-text-color <hex> Secondary text color
        \\      --selection-color <hex>   Selected row highlight
        \\      --init-config            Write default config and exit
        \\
    , .{}) catch {};
}
