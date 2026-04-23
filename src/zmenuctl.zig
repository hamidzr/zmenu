const std = @import("std");
const io_compat = @import("io_compat.zig");
const ipc = @import("ipc.zig");
const menu = @import("menu.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var menu_id: []const u8 = "";
    var socket_override: ?[]const u8 = null;
    var read_stdin = false;

    var cmd_index: ?usize = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--menu-id") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return usage();
            menu_id = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i >= args.len) return usage();
            socket_override = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdin")) {
            read_stdin = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        }

        cmd_index = i;
        break;
    }

    if (cmd_index == null) {
        return usage();
    }

    const cmd = args[cmd_index.?];
    if (!isSupportedCommand(cmd)) {
        return usage();
    }

    var items = std.ArrayList(ipc.Item).empty;
    defer items.deinit(allocator);

    if (read_stdin) {
        try readItemsFromStdin(allocator, &items);
    } else {
        const start = cmd_index.? + 1;
        if (start < args.len) {
            for (args[start..]) |arg| {
                if (arg.len == 0) continue;
                try items.append(allocator, .{ .id = arg, .label = arg });
            }
        }
    }

    if (items.items.len == 0) {
        io_compat.stderrPrint("zmenuctl: no items provided\n", .{}) catch {};
        std.process.exit(1);
    }

    const msg = ipc.Message{
        .cmd = cmd,
        .items = items.items,
    };

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    try std.json.Stringify.value(msg, .{}, &json_out.writer);
    const payload = json_out.written();

    const socket_path = socket_override orelse try ipc.socketPath(allocator, menu_id);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io_compat.globalIo());
    defer stream.close(io_compat.globalIo());

    var buf: [4096]u8 = undefined;
    var writer = stream.writer(io_compat.globalIo(), &buf);
    const header = try std.fmt.allocPrint(allocator, "{d}\n", .{payload.len});
    defer allocator.free(header);
    try writer.interface.writeAll(header);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn isSupportedCommand(cmd: []const u8) bool {
    return std.ascii.eqlIgnoreCase(cmd, "set") or std.ascii.eqlIgnoreCase(cmd, "append") or std.ascii.eqlIgnoreCase(cmd, "prepend");
}

fn readItemsFromStdin(allocator: std.mem.Allocator, items: *std.ArrayList(ipc.Item)) !void {
    var input = try menu.readStdinLines(allocator, menu.stdin_max_bytes);
    defer input.deinit(allocator);

    for (input.lines) |line| {
        const owned = try allocator.dupe(u8, line);
        try items.append(allocator, .{ .id = owned, .label = owned });
    }
}

fn usage() void {
    io_compat.stdoutPrint(
        \\zmenuctl usage:
        \\  zmenuctl [--menu-id <id>] [--socket <path>] [--stdin] <set|append|prepend> [items...]
        \\
        \\Examples:
        \\  zmenuctl --menu-id demo set --stdin
        \\  zmenuctl --menu-id demo append "new item"
        \\
    , .{}) catch {};
}
