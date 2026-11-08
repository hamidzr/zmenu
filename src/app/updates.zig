const std = @import("std");
const appconfig = @import("../config.zig");
const ipc = @import("../ipc.zig");
const io_compat = @import("../io_compat.zig");
const menu = @import("../menu.zig");
const test_env = @import("../test_env.zig");

const ipc_max_payload: usize = 1024 * 1024;
const stdin_max_line_bytes: usize = 64 * 1024;

pub const UpdateKind = enum {
    append,
    prepend,
    set,
    stream_closed,
};

pub const UpdateSource = enum {
    stdin,
    ipc,
};

pub const ItemUpdate = struct {
    kind: UpdateKind,
    source: UpdateSource,
    line: ?[]const u8,
    batch: u64,
};

pub const WakeFn = *const fn (ctx: ?*anyopaque) void;

pub const UpdateQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(ItemUpdate),
    next_batch: u64,
    /// called from the pushing thread when the consumer should drain; at most
    /// one call is outstanding until the next drain
    wake_fn: ?WakeFn = null,
    wake_ctx: ?*anyopaque = null,
    wake_pending: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator) UpdateQueue {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(ItemUpdate).empty,
            .next_batch = 1,
        };
    }

    /// install before the first push; wake() requests a drain of anything queued earlier
    pub fn setWake(self: *UpdateQueue, wake_fn: WakeFn, ctx: ?*anyopaque) void {
        self.wake_fn = wake_fn;
        self.wake_ctx = ctx;
        self.wake();
    }

    pub fn wake(self: *UpdateQueue) void {
        const wake_fn = self.wake_fn orelse return;
        if (self.wake_pending.swap(true, .acq_rel)) return;
        wake_fn(self.wake_ctx);
    }

    pub fn pushOwned(self: *UpdateQueue, kind: UpdateKind, source: UpdateSource, line: []const u8, batch: u64) void {
        self.push(kind, source, line, batch);
    }

    pub fn pushBatchOwned(self: *UpdateQueue, batch: []const ItemUpdate) void {
        if (batch.len == 0) return;
        {
            self.mutex.lockUncancelable(io_compat.globalIo());
            defer self.mutex.unlock(io_compat.globalIo());
            self.items.appendSlice(self.allocator, batch) catch freeLines(self.allocator, batch);
        }
        self.wake();
    }

    pub fn pushSignal(self: *UpdateQueue, kind: UpdateKind, source: UpdateSource, batch: u64) void {
        self.push(kind, source, null, batch);
    }

    fn push(self: *UpdateQueue, kind: UpdateKind, source: UpdateSource, line: ?[]const u8, batch: u64) void {
        {
            self.mutex.lockUncancelable(io_compat.globalIo());
            defer self.mutex.unlock(io_compat.globalIo());
            self.items.append(self.allocator, .{ .kind = kind, .source = source, .line = line, .batch = batch }) catch {
                if (line) |owned_line| {
                    self.allocator.free(owned_line);
                }
            };
        }
        self.wake();
    }

    pub fn nextBatchId(self: *UpdateQueue) u64 {
        self.mutex.lockUncancelable(io_compat.globalIo());
        defer self.mutex.unlock(io_compat.globalIo());
        const batch = self.next_batch;
        self.next_batch += 1;
        return batch;
    }

    pub fn reset(self: *UpdateQueue) void {
        self.mutex.lockUncancelable(io_compat.globalIo());
        defer self.mutex.unlock(io_compat.globalIo());
        freeLines(self.allocator, self.items.items);
        self.items.clearRetainingCapacity();
        self.next_batch = 1;
    }

    pub fn drain(self: *UpdateQueue) []const ItemUpdate {
        self.mutex.lockUncancelable(io_compat.globalIo());
        defer self.mutex.unlock(io_compat.globalIo());
        // cleared under the lock: a push after this point wakes us again
        self.wake_pending.store(false, .release);
        if (self.items.items.len == 0) {
            return &[_]ItemUpdate{};
        }
        const out = self.allocator.alloc(ItemUpdate, self.items.items.len) catch {
            freeLines(self.allocator, self.items.items);
            self.items.clearRetainingCapacity();
            return &[_]ItemUpdate{};
        };
        @memcpy(out, self.items.items);
        self.items.clearRetainingCapacity();
        return out;
    }
};

fn freeLines(allocator: std.mem.Allocator, batch: []const ItemUpdate) void {
    for (batch) |update| {
        if (update.line) |line| allocator.free(line);
    }
}

pub const QueueState = struct {
    queue: ?*UpdateQueue,
    ipc_path: ?[]const u8,

    pub fn deinit(self: QueueState) void {
        if (self.queue) |queue| {
            queue.reset();
            std.heap.c_allocator.destroy(queue);
        }
        if (self.ipc_path) |path| {
            io_compat.deleteFileAbsolute(path) catch {};
        }
    }
};

pub fn startUpdateQueue(config: appconfig.Config) !QueueState {
    if (!config.follow_stdin and !config.ipc_only) {
        return .{ .queue = null, .ipc_path = null };
    }

    const queue = try std.heap.c_allocator.create(UpdateQueue);
    queue.* = UpdateQueue.init(std.heap.c_allocator);

    const ipc_path = startIpcServer(queue, config.menu_id);
    if (config.ipc_only) {
        queue.reset();
    }

    return .{ .queue = queue, .ipc_path = ipc_path };
}

pub fn followStdinThread(queue: *UpdateQueue) void {
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(queue.allocator);
    defer queue.pushSignal(.stream_closed, .stdin, 0);

    var buf: [4096]u8 = undefined;
    var discarding = false;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return;
        if (n == 0) break;
        processStdinChunk(queue, &pending, &discarding, buf[0..n]) catch return;
    }
    if (!discarding) flushPendingStdinLine(queue, &pending);
}

fn processStdinChunk(queue: *UpdateQueue, pending: *std.ArrayList(u8), discarding: *bool, chunk: []const u8) !void {
    for (chunk) |byte| {
        if (byte == '\n') {
            if (!discarding.*) flushPendingStdinLine(queue, pending);
            pending.clearRetainingCapacity();
            discarding.* = false;
        } else if (!discarding.*) {
            if (pending.items.len == stdin_max_line_bytes) {
                pending.clearRetainingCapacity();
                discarding.* = true;
            } else {
                try pending.append(queue.allocator, byte);
            }
        }
    }
}

fn flushPendingStdinLine(queue: *UpdateQueue, pending: *std.ArrayList(u8)) void {
    defer pending.clearRetainingCapacity();
    const trimmed = std.mem.trimEnd(u8, pending.items, "\r");
    if (trimmed.len == 0) return;

    const line = queue.allocator.dupe(u8, trimmed) catch return;
    queue.pushOwned(.append, .stdin, line, 0);
}

pub fn menuItemFromIpc(allocator: std.mem.Allocator, payload: []const u8) ?menu.MenuItem {
    const parsed = std.json.parseFromSlice(ipc.Item, allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const item = parsed.value;
    const label = std.mem.trim(u8, item.label, " \t\r\n");
    if (label.len == 0) return null;

    const label_z = allocator.dupeSentinel(u8, label, 0) catch return null;
    errdefer allocator.free(label_z);
    const icon = if (item.icon) |path|
        allocator.dupeSentinel(u8, path, 0) catch return null
    else
        null;
    const payload_copy = allocator.dupe(u8, payload) catch return null;
    const id = if (item.id.len > 0) allocator.dupe(u8, item.id) catch return null else null;

    return .{ .label = label_z, .index = 0, .icon = icon, .ipc_payload = payload_copy, .id = id };
}

fn startIpcServer(queue: *UpdateQueue, menu_id: []const u8) ?[]const u8 {
    const path = ipc.socketPath(std.heap.c_allocator, menu_id) catch return null;
    var server = openIpcServer(path) catch return null;

    const server_ptr = std.heap.c_allocator.create(std.Io.net.Server) catch {
        server.deinit(io_compat.globalIo());
        return null;
    };
    server_ptr.* = server;

    _ = std.Thread.spawn(.{}, ipcServerLoop, .{ server_ptr, queue }) catch {
        server.deinit(io_compat.globalIo());
        std.heap.c_allocator.destroy(server_ptr);
        return null;
    };

    return path;
}

fn openIpcServer(path: []const u8) !std.Io.net.Server {
    io_compat.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.Io.net.UnixAddress.init(path);
    // connect needs write access to the socket file; bind it 0600 so a
    // permissive umask (002, 000) can't open it to other users when the temp
    // dir is shared (TMPDIR unset, falling back to /tmp)
    const old_mask = std.c.umask(0o077);
    defer _ = std.c.umask(old_mask);
    return address.listen(io_compat.globalIo(), .{});
}

fn ipcServerLoop(server: *std.Io.net.Server, queue: *UpdateQueue) void {
    while (true) {
        const stream = server.accept(io_compat.globalIo()) catch continue;
        handleIpcConnection(stream, queue);
        stream.close(io_compat.globalIo());
    }
}

fn handleIpcConnection(stream: std.Io.net.Stream, queue: *UpdateQueue) void {
    var buf: [4096]u8 = undefined;
    var reader = stream.reader(io_compat.globalIo(), &buf);
    const io_reader = &reader.interface;

    while (true) {
        const line_opt = readLineAlloc(io_reader, std.heap.c_allocator, 64) catch return;
        if (line_opt == null) return;
        const line = line_opt.?;
        defer std.heap.c_allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const payload_len = std.fmt.parseInt(usize, trimmed, 10) catch continue;
        if (payload_len == 0 or payload_len > ipc_max_payload) return;

        const payload = std.heap.c_allocator.alloc(u8, payload_len) catch return;
        defer std.heap.c_allocator.free(payload);

        io_reader.readSliceAll(payload) catch return;

        handleIpcPayload(queue, payload);
    }
}

fn readLineAlloc(reader: *std.Io.Reader, allocator: std.mem.Allocator, max_len: usize) !?[]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    while (buffer.items.len < max_len) {
        var byte: [1]u8 = undefined;
        const n = reader.readSliceShort(&byte) catch return null;
        if (n == 0) {
            if (buffer.items.len == 0) return null;
            break;
        }
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        try buffer.append(allocator, byte[0]);
    }

    return try buffer.toOwnedSlice(allocator);
}

pub fn handleIpcPayload(queue: *UpdateQueue, payload: []const u8) void {
    const parsed = std.json.parseFromSlice(ipc.Message, std.heap.c_allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const kind: UpdateKind = switch (ipc.parseCommand(parsed.value.cmd) orelse return) {
        .set => .set,
        .append => .append,
        .prepend => .prepend,
    };
    const items = parsed.value.items orelse return;

    const batch_id = queue.nextBatchId();
    var batch = std.ArrayList(ItemUpdate).empty;
    defer batch.deinit(queue.allocator);
    for (items) |item| {
        const label = std.mem.trim(u8, item.label, " \t\r\n");
        if (label.len == 0) continue;

        var json_out: std.Io.Writer.Allocating = .init(queue.allocator);
        defer json_out.deinit();
        std.json.Stringify.value(item, .{}, &json_out.writer) catch continue;
        const payload_copy = queue.allocator.dupe(u8, json_out.written()) catch continue;
        batch.append(queue.allocator, .{ .kind = kind, .source = .ipc, .line = payload_copy, .batch = batch_id }) catch {
            queue.allocator.free(payload_copy);
        };
    }
    if (kind == .set and batch.items.len == 0) {
        queue.pushSignal(.set, .ipc, batch_id);
        return;
    }
    queue.pushBatchOwned(batch.items);
}

test "oversized stdin line is skipped and later lines survive" {
    const allocator = std.testing.allocator;
    var queue = UpdateQueue.init(allocator);
    defer {
        queue.reset();
        queue.items.deinit(allocator);
    }
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(allocator);
    var discarding = false;

    const oversized = try allocator.alloc(u8, stdin_max_line_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try processStdinChunk(&queue, &pending, &discarding, oversized);
    try processStdinChunk(&queue, &pending, &discarding, "\nvalid\n");

    const drained = queue.drain();
    defer {
        for (drained) |update| if (update.line) |line| allocator.free(line);
        allocator.free(drained);
    }
    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expectEqualStrings("valid", drained[0].line.?);
}

test "IPC socket is owner-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = try test_env.Scratch.init(arena.allocator(), "ipcsock");
    defer scratch.deinit();

    const path = try scratch.path("/zmenu.sock");
    var server = try openIpcServer(path);
    defer server.deinit(io_compat.globalIo());

    const stat = try std.Io.Dir.cwd().statFile(io_compat.globalIo(), path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o077);
}

test "empty IPC set enqueues a clear signal" {
    const allocator = std.testing.allocator;
    var queue = UpdateQueue.init(allocator);
    defer {
        queue.reset();
        queue.items.deinit(allocator);
    }
    handleIpcPayload(&queue, "{\"v\":2,\"cmd\":\"set\",\"items\":[]}");
    const drained = queue.drain();
    defer allocator.free(drained);
    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expectEqual(UpdateKind.set, drained[0].kind);
    try std.testing.expect(drained[0].line == null);
}

test "menuItemFromIpc keeps the item id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const with_id = menuItemFromIpc(allocator, "{\"id\":\"w:1\",\"label\":\"Safari\"}").?;
    try std.testing.expectEqualStrings("w:1", with_id.id.?);
    const without = menuItemFromIpc(allocator, "{\"label\":\"Safari\"}").?;
    try std.testing.expect(without.id == null);
}

const WakeCounter = struct {
    var calls: usize = 0;
    fn wake(_: ?*anyopaque) void {
        calls += 1;
    }
};

test "pushes wake the consumer once until it drains" {
    const allocator = std.testing.allocator;
    var queue = UpdateQueue.init(allocator);
    defer {
        queue.reset();
        queue.items.deinit(allocator);
    }
    WakeCounter.calls = 0;

    // no hook yet: pushes just queue
    queue.pushSignal(.append, .ipc, 0);
    try std.testing.expectEqual(@as(usize, 0), WakeCounter.calls);

    // installing the hook asks for a drain of what is already queued
    queue.setWake(WakeCounter.wake, null);
    try std.testing.expectEqual(@as(usize, 1), WakeCounter.calls);

    // coalesced while the wake is outstanding
    queue.pushSignal(.append, .ipc, 0);
    queue.pushSignal(.set, .ipc, 1);
    try std.testing.expectEqual(@as(usize, 1), WakeCounter.calls);

    allocator.free(queue.drain());
    queue.pushSignal(.stream_closed, .stdin, 0);
    try std.testing.expectEqual(@as(usize, 2), WakeCounter.calls);

    // an empty drain still rearms the wake
    allocator.free(queue.drain());
    queue.pushSignal(.append, .ipc, 0);
    try std.testing.expectEqual(@as(usize, 3), WakeCounter.calls);
}
