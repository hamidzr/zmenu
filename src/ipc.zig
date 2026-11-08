const std = @import("std");
const builtin = @import("builtin");
const io_compat = @import("io_compat.zig");
const test_env = @import("test_env.zig");

/// IPC protocol version this build implements; `zmenu --version` reports it so a
/// client (combo-switcher doctor) can check compatibility
pub const protocol_version: u32 = 3;

/// A search scope: "<prefix> <text>" narrows the list to items of `kind`
pub const Scope = struct {
    prefix: []const u8,
    kind: []const u8,
    label: []const u8 = "",
};

/// an alternate action of an item; parsed and kept, not acted on yet
pub const Action = struct {
    mods: []const u8 = "",
    label: []const u8 = "",
    /// a prompt string, or `true` for the default prompt
    confirm: ?std.json.Value = null,
};

/// One item as clients send it. Only the fields zmenu reads are typed; the
/// stored payload (what accepting prints) keeps every field, typed or not.
pub const Item = struct {
    id: []const u8 = "",
    label: []const u8,
    icon: ?[]const u8 = null,
    /// dim text after the label; searched and highlighted
    subtitle: ?[]const u8 = null,
    /// short right-aligned dim text; not searched
    detail: ?[]const u8 = null,
    /// searched, never shown
    keywords: ?[]const u8 = null,
    /// category, matched by scopes
    kind: ?[]const u8 = null,
    /// label of the plain-Enter action
    action: ?[]const u8 = null,
    actions: ?[]const Action = null,
    /// a prompt string, or `true`
    confirm: ?std.json.Value = null,
    /// template item shown while the query starts with this prefix
    prefix: ?[]const u8 = null,
    /// template item shown when nothing else matches
    fallback: ?bool = null,
    /// template item shown when the query is an arithmetic expression
    calc: ?bool = null,
};

/// What zmenuctl sends. Absent optionals are left out of the JSON.
pub const Message = struct {
    v: u32 = 2,
    cmd: []const u8,
    items: ?[]const Item = null,
    loading: ?bool = null,
    scopes: ?[]const Scope = null,
};

/// What zmenu reads. Items stay raw JSON values so unknown fields survive into
/// the payload printed on accept; each is parsed into an `Item` separately.
pub const Incoming = struct {
    v: u32 = 2,
    cmd: []const u8,
    items: ?[]const std.json.Value = null,
    loading: ?bool = null,
    scopes: ?[]const Scope = null,
};

pub const Command = enum { set, append, prepend };

/// commands match case-insensitively
pub fn parseCommand(cmd: []const u8) ?Command {
    for ([_]Command{ .set, .append, .prepend }) |command| {
        if (std.ascii.eqlIgnoreCase(cmd, @tagName(command))) return command;
    }
    return null;
}

pub fn socketPath(allocator: std.mem.Allocator, menu_id: []const u8) ![]const u8 {
    const dir = try tempDir(allocator);
    const name = try socketName(allocator, menu_id);
    return std.fs.path.join(allocator, &.{ dir, name });
}

pub fn socketName(allocator: std.mem.Allocator, menu_id: []const u8) ![]const u8 {
    if (menu_id.len > 0) {
        return std.fmt.allocPrint(allocator, "zmenu.{s}.sock", .{menu_id});
    }
    return allocator.dupe(u8, "zmenu.sock");
}

extern "c" fn confstr(name: c_int, buf: [*]u8, len: usize) usize;
extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
const CS_DARWIN_USER_TEMP_DIR: c_int = 65537;

/// Directory for sockets and pid files. combo-switcher computes the same path
/// (pkg/usertmp); keep both in sync. TMPDIR, TMP, TEMP (when non-empty), then
/// the per-user Darwin temp dir, then $XDG_RUNTIME_DIR, then a 0700 per-user
/// dir under /tmp. Never the shared /tmp itself: another user could squat it.
pub fn tempDir(allocator: std.mem.Allocator) ![]const u8 {
    for ([_][]const u8{ "TMPDIR", "TMP", "TEMP" }) |name| {
        if (try io_compat.getEnvVarOwnedOptional(allocator, name)) |value| {
            if (value.len > 0) return value;
        }
    }
    if (darwinUserTempDir(allocator)) |dir| return dir;
    if (try io_compat.getEnvVarOwnedOptional(allocator, "XDG_RUNTIME_DIR")) |value| {
        if (std.fs.path.isAbsolute(value)) return value;
    }
    return privateTmpDir(allocator, "/tmp", @intCast(std.c.getuid()));
}

fn darwinUserTempDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    var buf: [1024]u8 = undefined;
    const len = confstr(CS_DARWIN_USER_TEMP_DIR, &buf, buf.len);
    // len counts the NUL; 0 is failure, > buf.len is truncation
    if (len <= 1 or len > buf.len) return null;
    const dir = std.mem.trimEnd(u8, buf[0 .. len - 1], "/");
    if (dir.len == 0) return null;
    return allocator.dupe(u8, dir) catch null;
}

/// <base>/zmenu-<uid>, created 0700 or verified as a real dir owned by uid
/// with no group/other access
fn privateTmpDir(allocator: std.mem.Allocator, base: []const u8, uid: u32) ![]const u8 {
    const dir = try std.fmt.allocPrintSentinel(allocator, "{s}/zmenu-{d}", .{ base, uid }, 0);
    const rc = std.c.mkdir(dir, 0o700);
    if (rc != 0 and std.posix.errno(rc) != .EXIST) return error.PrivateTmpDirFailed;
    var st: std.c.Stat = undefined;
    if (lstat(dir, &st) != 0) return error.PrivateTmpDirFailed;
    const is_dir = (st.mode & std.c.S.IFMT) == std.c.S.IFDIR;
    if (!is_dir or st.uid != uid or (st.mode & 0o077) != 0) return error.PrivateTmpDirUnsafe;
    return dir;
}

test parseCommand {
    try std.testing.expectEqual(Command.set, parseCommand("SET").?);
    try std.testing.expectEqual(Command.append, parseCommand("append").?);
    try std.testing.expectEqual(Command.prepend, parseCommand("Prepend").?);
    try std.testing.expect(parseCommand("clear") == null);
}

const env_names = [_][:0]const u8{ "TMPDIR", "TMP", "TEMP", "XDG_RUNTIME_DIR" };

test "tempDir prefers TMPDIR, TMP, TEMP, skipping empty values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const guard = try test_env.Guard.init(allocator, &env_names);
    defer guard.restore();
    for (env_names) |name| test_env.unset(name);

    test_env.set("TEMP", "/c");
    try std.testing.expectEqualStrings("/c", try tempDir(allocator));
    test_env.set("TMP", "/b");
    try std.testing.expectEqualStrings("/b", try tempDir(allocator));
    test_env.set("TMPDIR", "");
    try std.testing.expectEqualStrings("/b", try tempDir(allocator));
    test_env.set("TMPDIR", "/a");
    try std.testing.expectEqualStrings("/a", try tempDir(allocator));
}

test "tempDir fallback is never the shared /tmp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const guard = try test_env.Guard.init(allocator, &env_names);
    defer guard.restore();
    for (env_names) |name| test_env.unset(name);

    const dir = try tempDir(allocator);
    try std.testing.expect(!std.mem.eql(u8, dir, "/tmp"));
    if (builtin.os.tag == .macos) {
        try std.testing.expect(std.mem.startsWith(u8, dir, "/var/folders/") or std.mem.startsWith(u8, dir, "/private/var/folders/"));
        try std.testing.expect(!std.mem.endsWith(u8, dir, "/"));
    }
}

test "tempDir uses absolute XDG_RUNTIME_DIR off darwin" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const guard = try test_env.Guard.init(allocator, &env_names);
    defer guard.restore();
    for (env_names) |name| test_env.unset(name);
    test_env.set("XDG_RUNTIME_DIR", "/run/user/1000");
    try std.testing.expectEqualStrings("/run/user/1000", try tempDir(allocator));
}

test privateTmpDir {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scratch = try test_env.Scratch.init(allocator, "usertmp");
    defer scratch.deinit();
    const me: u32 = @intCast(std.c.getuid());

    const dir = try privateTmpDir(allocator, scratch.root, me);
    var st: std.c.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), lstat(@ptrCast(dir.ptr), &st));
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, st.mode) & 0o777);
    // reuse is fine
    _ = try privateTmpDir(allocator, scratch.root, me);
    // loose permissions are rejected
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(@ptrCast(dir.ptr), 0o755));
    try std.testing.expectError(error.PrivateTmpDirUnsafe, privateTmpDir(allocator, scratch.root, me));
    // a dir for another uid would be created by us, so the owner check rejects it
    try std.testing.expectError(error.PrivateTmpDirUnsafe, privateTmpDir(allocator, scratch.root, me + 1));
}
