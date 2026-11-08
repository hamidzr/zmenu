//! Two-step accept as a plain state machine. An item or action that declares
//! `confirm` does not accept on the first Enter: it becomes pending, the row
//! shows the prompt, and a second accept of the same row with the same
//! modifiers within `timeout_ms` goes through. Anything else clears it.

const std = @import("std");
const mods_mod = @import("mods.zig");

const Mods = mods_mod.Mods;

pub const timeout_ms: i64 = 4000;

pub const default_prompt = "Press " ++ mods_mod.return_glyph ++ " again to confirm";

/// what a `confirm` field asks for
pub const Spec = union(enum) {
    /// `true`: the default prompt
    default,
    /// a prompt string
    text: []const u8,

    pub fn prompt(self: Spec) []const u8 {
        return switch (self) {
            .default => default_prompt,
            .text => |text| text,
        };
    }
};

/// A `confirm` JSON value: a non-empty string is the prompt, `true` the default
/// prompt; false, null, an empty string and anything else mean no confirmation.
pub fn fromValue(value: ?std.json.Value) ?Spec {
    const v = value orelse return null;
    return switch (v) {
        .string => |text| if (std.mem.trim(u8, text, " \t\r\n").len > 0) .{ .text = text } else null,
        .bool => |on| if (on) .default else null,
        else => null,
    };
}

/// identity of a list row: its item id (else label), plus the template argument
pub fn keyOf(id_or_label: []const u8, arg: ?[]const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(id_or_label);
    if (arg) |text| {
        hasher.update("\x00");
        hasher.update(text);
    }
    return hasher.final();
}

const prompt_cap = 256;

pub const Pending = struct {
    key: u64,
    mods: Mods,
    deadline_ms: i64,
    prompt_len: usize,
    /// NUL-terminated copy of the prompt, cut to fit on a character boundary
    prompt_buf: [prompt_cap + 1]u8,
};

pub const Outcome = enum {
    /// first accept (or a different row or mods): show the prompt
    prompt,
    /// confirmed: carry on and accept
    accept,
};

pub const State = struct {
    pending: ?Pending = null,

    /// An accept of (`key`, `mods`) that needs confirmation at `now_ms`.
    pub fn request(self: *State, key: u64, mods: Mods, spec: Spec, now_ms: i64) Outcome {
        if (self.pending) |pending| {
            if (pending.key == key and pending.mods.eql(mods) and now_ms <= pending.deadline_ms) {
                self.pending = null;
                return .accept;
            }
        }
        var next = Pending{
            .key = key,
            .mods = mods,
            .deadline_ms = now_ms + timeout_ms,
            .prompt_len = 0,
            .prompt_buf = undefined,
        };
        const text = spec.prompt();
        var len = @min(text.len, prompt_cap);
        while (len > 0 and len < text.len and text[len] & 0xC0 == 0x80) len -= 1;
        @memcpy(next.prompt_buf[0..len], text[0..len]);
        next.prompt_buf[len] = 0;
        next.prompt_len = len;
        self.pending = next;
        return .prompt;
    }

    pub fn isPending(self: *const State) bool {
        return self.pending != null;
    }

    pub fn clear(self: *State) void {
        self.pending = null;
    }

    /// Clears a pending confirmation that is not for `key` (the selected row, null
    /// when there is none): a selection change or a vanished item cancels it.
    /// True when something was cleared.
    pub fn keepOnlyFor(self: *State, key: ?u64) bool {
        const pending = self.pending orelse return false;
        if (key) |current| {
            if (current == pending.key) return false;
        }
        self.pending = null;
        return true;
    }

    /// Clears a pending confirmation whose time is up. True when it did.
    pub fn expire(self: *State, now_ms: i64) bool {
        const pending = self.pending orelse return false;
        if (now_ms < pending.deadline_ms) return false;
        self.pending = null;
        return true;
    }

    /// the prompt to show on the row `key`, if it is the pending one
    pub fn promptFor(self: *const State, key: u64) ?[:0]const u8 {
        const pending = &(self.pending orelse return null);
        if (pending.key != key) return null;
        return pending.prompt_buf[0..pending.prompt_len :0];
    }
};

test "confirm value forms" {
    try std.testing.expect(fromValue(null) == null);
    try std.testing.expect(fromValue(.{ .bool = false }) == null);
    try std.testing.expect(fromValue(.null) == null);
    try std.testing.expect(fromValue(.{ .integer = 1 }) == null);
    try std.testing.expect(fromValue(.{ .string = "  " }) == null);
    try std.testing.expect(fromValue(.{ .bool = true }).? == .default);
    try std.testing.expectEqualStrings("Quit Safari?", fromValue(.{ .string = "Quit Safari?" }).?.prompt());
    try std.testing.expectEqualStrings(default_prompt, fromValue(.{ .bool = true }).?.prompt());
    try std.testing.expectEqualStrings("Press \u{21b5} again to confirm", default_prompt);
}

test "first accept is pending, the second within the window confirms" {
    var state = State{};
    const key = keyOf("win:1", null);
    const plain = Mods{};
    try std.testing.expectEqual(Outcome.prompt, state.request(key, plain, .default, 1000));
    try std.testing.expectEqualStrings(default_prompt, state.promptFor(key).?);
    try std.testing.expect(state.promptFor(keyOf("win:2", null)) == null);
    try std.testing.expectEqual(Outcome.accept, state.request(key, plain, .default, 1000 + timeout_ms));
    // confirming consumes the pending state
    try std.testing.expect(!state.isPending());
}

test "a late second accept starts over" {
    var state = State{};
    const key = keyOf("win:1", null);
    _ = state.request(key, .{}, .default, 0);
    try std.testing.expectEqual(Outcome.prompt, state.request(key, .{}, .default, timeout_ms + 1));
    // and the new window counts from the second request
    try std.testing.expectEqual(Outcome.accept, state.request(key, .{}, .default, timeout_ms + 2));
}

test "different mods or a different row reset the pending state" {
    var state = State{};
    const key = keyOf("win:1", null);
    const alt = Mods{ .alt = true };
    try std.testing.expectEqual(Outcome.prompt, state.request(key, alt, .{ .text = "Quit Safari?" }, 0));
    try std.testing.expectEqualStrings("Quit Safari?", state.promptFor(key).?);
    // plain Enter on the same row is not the pending accept
    try std.testing.expectEqual(Outcome.prompt, state.request(key, .{}, .default, 10));
    try std.testing.expect(state.pending.?.mods.isEmpty());
    // another row replaces it, and the first row no longer shows a prompt
    const other = keyOf("win:2", null);
    try std.testing.expectEqual(Outcome.prompt, state.request(other, .{}, .default, 20));
    try std.testing.expect(state.promptFor(key) == null);
    try std.testing.expect(state.promptFor(other) != null);
}

test "selection change, removal and timeout clear the pending state" {
    var state = State{};
    const key = keyOf("win:1", null);
    _ = state.request(key, .{}, .default, 0);
    try std.testing.expect(!state.keepOnlyFor(key));
    try std.testing.expect(state.isPending());
    // the same selection, even after a refilter, keeps it
    try std.testing.expect(!state.keepOnlyFor(keyOf("win:1", null)));
    try std.testing.expect(state.keepOnlyFor(keyOf("win:2", null)));
    try std.testing.expect(!state.isPending());

    _ = state.request(key, .{}, .default, 0);
    try std.testing.expect(state.keepOnlyFor(null));
    try std.testing.expect(!state.isPending());

    _ = state.request(key, .{}, .default, 100);
    try std.testing.expect(!state.expire(100 + timeout_ms - 1));
    try std.testing.expect(state.isPending());
    try std.testing.expect(state.expire(100 + timeout_ms));
    try std.testing.expect(!state.isPending());
    try std.testing.expect(!state.expire(1 << 40));

    _ = state.request(key, .{}, .default, 0);
    state.clear();
    try std.testing.expect(state.promptFor(key) == null);
}

test "template rows with different arguments are different rows" {
    try std.testing.expect(keyOf("g", "weather") != keyOf("g", "news"));
    try std.testing.expect(keyOf("g", null) != keyOf("g", ""));
    try std.testing.expectEqual(keyOf("x", null), keyOf("x", null));
}

test "a long prompt is cut on a character boundary" {
    var state = State{};
    var long_buf: [259]u8 = undefined;
    @memset(long_buf[0..255], 'x');
    @memcpy(long_buf[255..], "\u{e9}\u{e9}");
    const long: []const u8 = &long_buf;
    _ = state.request(1, .{}, .{ .text = long }, 0);
    const shown = state.promptFor(1).?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
    try std.testing.expectEqual(@as(usize, 255), shown.len);
    try std.testing.expectEqual(@as(u8, 0), shown.ptr[shown.len]);
}
