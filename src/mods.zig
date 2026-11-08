//! Keyboard modifiers of an accept (Cmd+Enter and friends) as plain Zig. The
//! wire form is a "+"-joined subset in the order ctrl, alt, shift, cmd.

const std = @import("std");

/// NSEventModifierFlag bits (device-independent part) the menu cares about
pub const flag_shift: u64 = 1 << 17;
pub const flag_control: u64 = 1 << 18;
pub const flag_option: u64 = 1 << 19;
pub const flag_command: u64 = 1 << 20;
pub const flag_mask: u64 = flag_shift | flag_control | flag_option | flag_command;

/// longest canonical form: "ctrl+alt+shift+cmd"
pub const canonical_max_len = 18;
/// longest glyph form: the four glyphs, three bytes each
pub const glyphs_max_len = 12;

pub const return_glyph = "\u{21b5}";

pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    cmd: bool = false,

    pub fn isEmpty(self: Mods) bool {
        return !(self.ctrl or self.alt or self.shift or self.cmd);
    }

    pub fn eql(self: Mods, other: Mods) bool {
        return self.ctrl == other.ctrl and self.alt == other.alt and self.shift == other.shift and self.cmd == other.cmd;
    }

    /// from NSEvent.modifierFlags; caps lock, numeric pad and the like are ignored
    pub fn fromFlags(flags: u64) Mods {
        return .{
            .ctrl = flags & flag_control != 0,
            .alt = flags & flag_option != 0,
            .shift = flags & flag_shift != 0,
            .cmd = flags & flag_command != 0,
        };
    }

    /// Parses "cmd", "shift+cmd", ... in any order, case-insensitive; a few
    /// aliases are accepted. Null for an empty string or an unknown token.
    pub fn parse(text: []const u8) ?Mods {
        var result: Mods = .{};
        var parts = std.mem.splitScalar(u8, text, '+');
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, " ");
            if (eqlAny(part, &.{ "ctrl", "control" })) {
                result.ctrl = true;
            } else if (eqlAny(part, &.{ "alt", "opt", "option" })) {
                result.alt = true;
            } else if (eqlAny(part, &.{"shift"})) {
                result.shift = true;
            } else if (eqlAny(part, &.{ "cmd", "command" })) {
                result.cmd = true;
            } else {
                return null;
            }
        }
        return if (result.isEmpty()) null else result;
    }

    /// "ctrl+alt+shift+cmd" order, the subset set; empty for no modifiers
    pub fn canonical(self: Mods, buf: *[canonical_max_len]u8) []const u8 {
        var len: usize = 0;
        const names = [_]struct { on: bool, name: []const u8 }{
            .{ .on = self.ctrl, .name = "ctrl" },
            .{ .on = self.alt, .name = "alt" },
            .{ .on = self.shift, .name = "shift" },
            .{ .on = self.cmd, .name = "cmd" },
        };
        for (names) |entry| {
            if (!entry.on) continue;
            if (len > 0) {
                buf[len] = '+';
                len += 1;
            }
            @memcpy(buf[len .. len + entry.name.len], entry.name);
            len += entry.name.len;
        }
        return buf[0..len];
    }

    /// the modifier glyphs in the order ctrl, alt, shift, cmd
    pub fn glyphs(self: Mods, buf: *[glyphs_max_len]u8) []const u8 {
        var len: usize = 0;
        const parts = [_]struct { on: bool, glyph: []const u8 }{
            .{ .on = self.ctrl, .glyph = "\u{2303}" },
            .{ .on = self.alt, .glyph = "\u{2325}" },
            .{ .on = self.shift, .glyph = "\u{21e7}" },
            .{ .on = self.cmd, .glyph = "\u{2318}" },
        };
        for (parts) |entry| {
            if (!entry.on) continue;
            @memcpy(buf[len .. len + entry.glyph.len], entry.glyph);
            len += entry.glyph.len;
        }
        return buf[0..len];
    }
};

fn eqlAny(text: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (std.ascii.eqlIgnoreCase(text, name)) return true;
    }
    return false;
}

test "flags map to modifiers and ignore everything else" {
    try std.testing.expect(Mods.fromFlags(0).isEmpty());
    // caps lock (1 << 16) and the numeric pad flag (1 << 21) are not modifiers here
    try std.testing.expect(Mods.fromFlags((1 << 16) | (1 << 21)).isEmpty());
    const combo = Mods.fromFlags(flag_command | flag_shift | (1 << 16));
    try std.testing.expect(combo.cmd and combo.shift and !combo.alt and !combo.ctrl);
    try std.testing.expect(Mods.fromFlags(flag_mask).eql(.{ .ctrl = true, .alt = true, .shift = true, .cmd = true }));
}

test "canonical order is ctrl, alt, shift, cmd" {
    var buf: [canonical_max_len]u8 = undefined;
    try std.testing.expectEqualStrings("", (Mods{}).canonical(&buf));
    try std.testing.expectEqualStrings("cmd", (Mods{ .cmd = true }).canonical(&buf));
    try std.testing.expectEqualStrings("shift+cmd", (Mods{ .cmd = true, .shift = true }).canonical(&buf));
    try std.testing.expectEqualStrings("ctrl+alt+shift+cmd", (Mods{ .cmd = true, .shift = true, .alt = true, .ctrl = true }).canonical(&buf));
    try std.testing.expectEqualStrings("ctrl+alt", (Mods{ .alt = true, .ctrl = true }).canonical(&buf));
}

test "parse accepts any order, case and aliases, and round-trips canonical" {
    try std.testing.expect(Mods.parse("cmd").?.eql(.{ .cmd = true }));
    try std.testing.expect(Mods.parse("CMD+Shift").?.eql(.{ .cmd = true, .shift = true }));
    try std.testing.expect(Mods.parse("shift+cmd").?.eql(Mods.parse("cmd+shift").?));
    try std.testing.expect(Mods.parse("option").?.eql(.{ .alt = true }));
    try std.testing.expect(Mods.parse("control+command").?.eql(.{ .ctrl = true, .cmd = true }));
    try std.testing.expect(Mods.parse("") == null);
    try std.testing.expect(Mods.parse("cmd+") == null);
    try std.testing.expect(Mods.parse("hyper") == null);
    var buf: [canonical_max_len]u8 = undefined;
    const all = Mods.parse("cmd+shift+alt+ctrl").?;
    try std.testing.expectEqualStrings("ctrl+alt+shift+cmd", all.canonical(&buf));
}

test "glyphs follow the ctrl, alt, shift, cmd order" {
    var buf: [glyphs_max_len]u8 = undefined;
    try std.testing.expectEqualStrings("\u{2318}", (Mods{ .cmd = true }).glyphs(&buf));
    try std.testing.expectEqualStrings("\u{2325}\u{21e7}", (Mods{ .shift = true, .alt = true }).glyphs(&buf));
    try std.testing.expectEqualStrings("\u{2303}\u{2325}\u{21e7}\u{2318}", (Mods{ .cmd = true, .shift = true, .alt = true, .ctrl = true }).glyphs(&buf));
    try std.testing.expectEqualStrings("", (Mods{}).glyphs(&buf));
}
