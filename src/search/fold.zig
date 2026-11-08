//! Diacritic folding for matching: UTF-8 Latin-1 Supplement and Latin
//! Extended-A letters map to their ASCII base letters (case kept), so "cafe"
//! finds "Café". Everything else passes through untouched. Labels are folded
//! once when items are set; the display text is never changed.

const std = @import("std");

const first_cp: u21 = 0xC0;
const last_cp: u21 = 0x17F;

// one char per code point starting at first_cp; '.' means no folding
const latin1 = "AAAAAA.CEEEEIIIIDNOOOOO.OUUUUY..aaaaaa.ceeeeiiiidnooooo.ouuuuy.y";
const ext_a = "AaAaAaCcCcCcCcDdDdEeEeEeEeEe" ++
    "GgGgGgGgHhHhIiIiIiIiIi..JjKkkLlLlLlLlLl" ++
    "NnNnNnnNnOoOoOo..RrRrRrSsSsSsSsTtTtTt" ++
    "UuUuUuUuUuUuWwYyYZzZzZzs";

const ligatures = [_]struct { cp: u21, text: []const u8 }{
    .{ .cp = 0xC6, .text = "AE" },
    .{ .cp = 0xE6, .text = "ae" },
    .{ .cp = 0xDF, .text = "ss" },
    .{ .cp = 0x132, .text = "IJ" },
    .{ .cp = 0x133, .text = "ij" },
    .{ .cp = 0x152, .text = "OE" },
    .{ .cp = 0x153, .text = "oe" },
};

const table_len = last_cp - first_cp + 1;
const table: [table_len][]const u8 = blk: {
    const spec = latin1 ++ ext_a;
    std.debug.assert(spec.len == table_len);
    var t: [table_len][]const u8 = undefined;
    for (&t, 0..) |*slot, i| {
        slot.* = if (spec[i] == '.') "" else spec[i..][0..1];
    }
    for (ligatures) |lig| t[lig.cp - first_cp] = lig.text;
    break :blk t;
};

const Fold = struct { text: []const u8, consumed: usize };

/// replacement for the sequence at s[i], null when it is left as is
fn foldAt(s: []const u8, i: usize) ?Fold {
    const lead = s[i];
    if (lead < 0xC3 or lead > 0xC5 or i + 1 >= s.len) return null;
    const next = s[i + 1];
    if (next & 0xC0 != 0x80) return null;
    const cp: u21 = (@as(u21, lead & 0x1F) << 6) | (next & 0x3F);
    if (cp < first_cp or cp > last_cp) return null;
    const text = table[cp - first_cp];
    if (text.len == 0) return null;
    return .{ .text = text, .consumed = 2 };
}

fn changes(s: []const u8) bool {
    for (s, 0..) |c, i| {
        if (c >= 0xC3 and c <= 0xC5 and foldAt(s, i) != null) return true;
    }
    return false;
}

fn foldedLen(s: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (foldAt(s, i)) |f| {
            len += f.text.len;
            i += f.consumed;
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

fn foldInto(out: []u8, s: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (foldAt(s, i)) |f| {
            @memcpy(out[n..][0..f.text.len], f.text);
            n += f.text.len;
            i += f.consumed;
        } else {
            out[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

/// folded copy of s, or s itself (no allocation) when nothing folds
pub fn foldAlloc(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!changes(s)) return s;
    const out = try allocator.alloc(u8, foldedLen(s));
    return foldInto(out, s);
}

/// fold into a caller buffer; returns s itself when nothing folds or buf is too small
pub fn foldBuf(buf: []u8, s: []const u8) []const u8 {
    if (!changes(s)) return s;
    if (foldedLen(s) > buf.len) return s;
    return foldInto(buf, s);
}

/// Folds `s` into `text_buf` and records, per folded byte, the byte range of the
/// original sequence it came from (`starts[i]..ends[i]`), so a match found in
/// folded text can be shown on the original label. A multi-byte letter folds to
/// one byte, a ligature to several bytes that all map to the same original
/// range. Null when a buffer is too small.
pub fn foldWithMap(text_buf: []u8, starts: []u32, ends: []u32, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const text: []const u8, const consumed: usize = if (foldAt(s, i)) |f| .{ f.text, f.consumed } else .{ s[i..][0..1], 1 };
        if (n + text.len > text_buf.len or n + text.len > starts.len or n + text.len > ends.len) return null;
        for (text, 0..) |byte, offset| {
            text_buf[n + offset] = byte;
            starts[n + offset] = @intCast(i);
            ends[n + offset] = @intCast(i + consumed);
        }
        n += text.len;
        i += consumed;
    }
    return text_buf[0..n];
}

test "foldWithMap maps folded bytes back to original ranges" {
    var text: [32]u8 = undefined;
    var starts: [32]u32 = undefined;
    var ends: [32]u32 = undefined;

    const cafe = foldWithMap(&text, &starts, &ends, "Café x").?;
    try std.testing.expectEqualStrings("Cafe x", cafe);
    try std.testing.expectEqual(@as(u32, 3), starts[3]);
    try std.testing.expectEqual(@as(u32, 5), ends[3]);
    // bytes after the two-byte letter shift by one
    try std.testing.expectEqual(@as(u32, 5), starts[4]);
    try std.testing.expectEqual(@as(u32, 6), ends[4]);

    const strasse = foldWithMap(&text, &starts, &ends, "Straße").?;
    try std.testing.expectEqualStrings("Strasse", strasse);
    try std.testing.expectEqual(@as(u32, 4), starts[4]);
    try std.testing.expectEqual(@as(u32, 6), ends[4]);
    try std.testing.expectEqual(@as(u32, 4), starts[5]);
    try std.testing.expectEqual(@as(u32, 6), ends[5]);
    try std.testing.expectEqual(@as(u32, 6), starts[6]);

    var tiny: [3]u8 = undefined;
    try std.testing.expect(foldWithMap(&tiny, &starts, &ends, "Café x") == null);
}

test "folds common Latin letters and keeps case" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Cafe", foldBuf(&buf, "Café"));
    try std.testing.expectEqualStrings("Eclair", foldBuf(&buf, "Éclair"));
    try std.testing.expectEqualStrings("Uber", foldBuf(&buf, "Über"));
    try std.testing.expectEqualStrings("nino", foldBuf(&buf, "niño"));
    try std.testing.expectEqualStrings("Oslo Aland", foldBuf(&buf, "Øslo Åland"));
    try std.testing.expectEqualStrings("facade", foldBuf(&buf, "façade"));
    try std.testing.expectEqualStrings("Strasse", foldBuf(&buf, "Straße"));
    try std.testing.expectEqualStrings("Lodz Zolc", foldBuf(&buf, "Łódź Żółć"));
    try std.testing.expectEqualStrings("Cesky Sramek", foldBuf(&buf, "Český Šrámek"));
    try std.testing.expectEqualStrings("AEon oeuvre", foldBuf(&buf, "Æon œuvre"));
}

test "ASCII, other scripts and invalid UTF-8 pass through" {
    var buf: [64]u8 = undefined;
    const same = [_][]const u8{ "plain", "日本語", "ж", "x × y ÷ z", "\xC3", "\xC3A", "ab\xC3" };
    for (same) |s| try std.testing.expectEqualStrings(s, foldBuf(&buf, s));
}

test "foldAlloc returns the input when nothing folds" {
    const allocator = std.testing.allocator;
    const plain = "no accents";
    const same = try foldAlloc(allocator, plain);
    try std.testing.expect(same.ptr == plain.ptr);

    const folded = try foldAlloc(allocator, "Zürich");
    defer allocator.free(folded);
    try std.testing.expectEqualStrings("Zurich", folded);
}

test "foldBuf falls back when the buffer is too small" {
    var buf: [2]u8 = undefined;
    try std.testing.expectEqualStrings("Café", foldBuf(&buf, "Café"));
}
