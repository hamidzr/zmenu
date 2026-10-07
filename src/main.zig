const std = @import("std");
const app = @import("app.zig");
const cli = @import("cli.zig");
const io_compat = @import("io_compat.zig");
const terminal = @import("terminal.zig");
const time_compat = @import("time_compat.zig");

pub fn main(init: std.process.Init) !void {
    time_compat.markProcessStart();
    const allocator = init.arena.allocator();
    const config = cli.parse(allocator, init.minimal.args) catch |err| {
        io_compat.stderrPrint("zmenu: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    time_compat.enableStartupProfile(config.startup_profile);
    time_compat.startupStage("config_parsed");

    if (config.terminal_mode) {
        try terminal.run(config, allocator);
    } else {
        try app.run(config);
    }
}
