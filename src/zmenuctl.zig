const std = @import("std");
const io_compat = @import("io_compat.zig");
const ipc = @import("ipc.zig");
const menu = @import("menu.zig");
const menu_id_check = @import("menu_id.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var menu_id: []const u8 = "";
    var socket_override: ?[]const u8 = null;
    var read_stdin = false;
    var raw_json = false;

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
        if (std.mem.eql(u8, arg, "--json")) {
            raw_json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        }

        cmd_index = i;
        break;
    }

    menu_id_check.validate(menu_id) catch {
        io_compat.stderrPrint("zmenuctl: invalid menu id (use letters, digits, '-', '_', '.'; max 64; no leading dot)\n", .{}) catch {};
        std.process.exit(1);
    };

    if (raw_json) {
        // the message comes from stdin as is: any protocol version, every item field
        const raw = try io_compat.readAllFromFd(allocator, std.posix.STDIN_FILENO, ipc_max_payload);
        const payload = std.mem.trim(u8, raw, " \t\r\n");
        ipc.validateRaw(allocator, payload) catch |err| {
            io_compat.stderrPrint("zmenuctl: stdin is not a protocol message ({s})\n", .{@errorName(err)}) catch {};
            std.process.exit(1);
        };
        return send(allocator, socket_override, menu_id, payload);
    }

    if (cmd_index == null) {
        return usage();
    }

    const cmd = args[cmd_index.?];
    const command = ipc.parseCommand(cmd) orelse return usage();

    const item_args = args[cmd_index.? + 1 ..];
    for (item_args) |arg| {
        if (std.mem.eql(u8, arg, "--stdin")) read_stdin = true;
    }

    var items = std.ArrayList(ipc.Item).empty;
    defer items.deinit(allocator);

    if (read_stdin) {
        try readItemsFromStdin(allocator, &items);
    } else {
        for (item_args) |arg| {
            if (arg.len == 0) continue;
            try items.append(allocator, .{ .id = arg, .label = arg });
        }
    }

    if (items.items.len == 0 and command != .set) {
        io_compat.stderrPrint("zmenuctl: no items provided\n", .{}) catch {};
        std.process.exit(1);
    }

    const msg = ipc.Message{
        .cmd = cmd,
        .items = items.items,
    };

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    try std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &json_out.writer);
    return send(allocator, socket_override, menu_id, json_out.written());
}

/// the server ignores messages over 1 MiB
const ipc_max_payload: usize = 1024 * 1024;

fn send(allocator: std.mem.Allocator, socket_override: ?[]const u8, menu_id: []const u8, payload: []const u8) !void {
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
        \\  zmenuctl [--menu-id <id>] [--socket <path>] --json    send one raw protocol message from stdin
        \\
        \\Examples:
        \\  zmenuctl --menu-id demo set --stdin
        \\  zmenuctl --menu-id demo append "new item"
        \\  zmenuctl --menu-id demo --json < samples/snapshot_v3_actions.json
        \\
    , .{}) catch {};
}
