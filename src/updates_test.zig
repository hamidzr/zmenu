const std = @import("std");
const updates = @import("app/updates.zig");

// A set must become visible to the UI in one drain, never item by item.
test "set batch enters update queue atomically" {
    const allocator = std.testing.allocator;
    var queue = updates.UpdateQueue.init(allocator);
    defer queue.items.deinit(allocator);

    const first = try allocator.dupe(u8, "first");
    const second = try allocator.dupe(u8, "WhatsApp");
    const batch = [_]updates.ItemUpdate{
        .{ .kind = .set, .source = .ipc, .line = first, .batch = 1 },
        .{ .kind = .set, .source = .ipc, .line = second, .batch = 1 },
    };
    queue.pushBatchOwned(&batch);

    const drained = queue.drain();
    defer {
        for (drained) |item| allocator.free(item.line.?);
        allocator.free(drained);
    }
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expectEqual(@as(u64, 1), drained[0].batch);
    try std.testing.expectEqual(@as(u64, 1), drained[1].batch);
}
