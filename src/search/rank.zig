//! Per-token scoring for the default `fuzzy` method. A token must match the
//! label as a substring, a word-start acronym, or a loose subsequence (case
//! insensitive). Substring and acronym hits score at least `substring_base`
//! and always outrank loose subsequence hits, which stay below
//! `subsequence_max`. No allocation: the subsequence pass uses stack rows.

const std = @import("std");
const util = @import("util.zig");

const substring_base: i32 = 1000;
const exact_label_bonus: i32 = 600;
const prefix_bonus: i32 = 300;
const word_start_bonus: i32 = 150;
const case_match_bonus: i32 = 20;
// between a word-start substring and a label-prefix substring
const acronym_base: i32 = 1180;
const acronym_prefix_bonus: i32 = 100;

const subsequence_max: i32 = 999;
const char_base: i32 = 10;
const char_word_start: i32 = 20;
const char_label_start: i32 = 10;
const contiguous_bonus: i32 = 15;
const gap_open_penalty: i32 = 3;
const gap_extend_penalty: i32 = 1;
const leading_gap_penalty_max: usize = 10;

const dp_max_label: usize = 256;
const dp_max_query: usize = 32;
const unreachable_score: i32 = -1_000_000;
const reachable_floor: i32 = unreachable_score / 2;

/// A hit in the subtitle or keywords counts for a fraction of the same hit in
/// the label, so "safari" ranks the Safari app above a tab that merely mentions
/// it. Any label substring or acronym hit (>= `substring_base`) outranks every
/// subtitle or keywords hit.
const subtitle_divisor: i32 = 2;
const keywords_divisor: i32 = 3;

/// Score of one token against an item's label, subtitle and keywords (folded
/// text; the latter two may be empty): the best of the label score and the
/// reduced subtitle and keywords scores. Null when no field matches.
pub fn docTokenScore(token: []const u8, label: []const u8, subtitle: []const u8, keywords: []const u8) ?i32 {
    const in_label = tokenScore(token, label);
    if (in_label) |score| {
        if (score >= substring_base) return score;
    }
    var best = in_label;
    if (subtitle.len > 0) {
        if (tokenScore(token, subtitle)) |score| best = @max(best orelse 0, @divTrunc(score, subtitle_divisor));
    }
    if (keywords.len > 0) {
        if (tokenScore(token, keywords)) |score| best = @max(best orelse 0, @divTrunc(score, keywords_divisor));
    }
    return best;
}

/// score of one token against a label, null when it does not match
pub fn tokenScore(token: []const u8, label: []const u8) ?i32 {
    if (token.len == 0) return 0;
    if (token.len > label.len) return null;
    if (!isSubsequence(token, label)) return null;

    const substring = substringScore(token, label);
    const acronym = if (token.len >= 2) acronymScore(token, label) else null;
    if (substring != null or acronym != null) {
        return @max(substring orelse 0, acronym orelse 0);
    }
    return subsequenceScore(token, label);
}

pub fn isBoundary(label: []const u8, index: usize) bool {
    if (index == 0) return true;
    const prev = label[index - 1];
    return switch (prev) {
        ' ', '-', '_', '/', '.', '[', '(', ':', '\\' => true,
        else => std.ascii.isLower(prev) and std.ascii.isUpper(label[index]),
    };
}

fn isSubsequence(token: []const u8, label: []const u8) bool {
    var ti: usize = 0;
    for (label) |c| {
        if (util.charsEqual(c, token[ti], true)) {
            ti += 1;
            if (ti == token.len) return true;
        }
    }
    return false;
}

const SubstringHit = struct { score: i32, index: usize };

/// best-scoring occurrence of the token, the first one on ties
fn substringBest(token: []const u8, label: []const u8) ?SubstringHit {
    const upper = util.hasUpperAscii(token);
    var best: ?SubstringHit = null;
    var i: usize = 0;
    while (i + token.len <= label.len) : (i += 1) {
        const window = label[i .. i + token.len];
        if (!std.ascii.eqlIgnoreCase(window, token)) continue;
        var score = substring_base;
        if (i == 0) {
            score += prefix_bonus;
            if (token.len == label.len) score += exact_label_bonus;
        } else if (isBoundary(label, i)) {
            score += word_start_bonus;
        }
        if (upper and std.mem.eql(u8, window, token)) score += case_match_bonus;
        if (best == null or score > best.?.score) best = .{ .score = score, .index = i };
    }
    return best;
}

fn substringScore(token: []const u8, label: []const u8) ?i32 {
    return (substringBest(token, label) orelse return null).score;
}

/// every token char lands on a word start, in order
fn acronymScore(token: []const u8, label: []const u8) ?i32 {
    return acronymMatch(token, label, null);
}

/// acronym score; when `positions` is given it receives the label index of each
/// token char (it must hold token.len entries)
fn acronymMatch(token: []const u8, label: []const u8, positions: ?[]usize) ?i32 {
    var ti: usize = 0;
    var starts_label = false;
    for (label, 0..) |c, j| {
        if (!isBoundary(label, j) or !util.charsEqual(c, token[ti], true)) continue;
        if (ti == 0 and j == 0) starts_label = true;
        if (positions) |out| out[ti] = j;
        ti += 1;
        if (ti == token.len) break;
    }
    if (ti < token.len) return null;
    return acronym_base + if (starts_label) acronym_prefix_bonus else 0;
}

fn charScore(label: []const u8, j: usize) i32 {
    var score = char_base;
    if (isBoundary(label, j)) score += char_word_start;
    if (j == 0) score += char_label_start;
    return score;
}

const Row = [dp_max_label]i32;

fn dpFirstRow(token: []const u8, label: []const u8, n: usize, cur: *Row) void {
    for (0..n) |j| {
        cur[j] = if (util.charsEqual(label[j], token[0], true))
            charScore(label, j) - @as(i32, @intCast(@min(j, leading_gap_penalty_max)))
        else
            unreachable_score;
    }
}

/// row i (>= 1) of the alignment table from row i - 1
fn dpNextRow(token: []const u8, label: []const u8, n: usize, i: usize, prev: *const Row, cur: *Row) void {
    // best prev-row score ending at least one char before j, minus its gap
    var gap: i32 = unreachable_score;
    for (0..n) |j| {
        gap -= gap_extend_penalty;
        if (j >= 2 and prev[j - 2] > reachable_floor) gap = @max(gap, prev[j - 2] - gap_open_penalty);
        cur[j] = unreachable_score;
        if (!util.charsEqual(label[j], token[i], true)) continue;

        var best: i32 = unreachable_score;
        if (j >= 1 and prev[j - 1] > reachable_floor) best = prev[j - 1] + contiguous_bonus;
        if (i != 1 or isBoundary(label, j)) best = @max(best, gap);
        if (best > reachable_floor) cur[j] = best + charScore(label, j);
    }
}

/// Best alignment of the token as a subsequence. The second token char must
/// be adjacent to the first or start a word, so loose matches cannot start
/// with two unrelated letters; later chars may sit anywhere.
fn subsequenceScore(token: []const u8, label: []const u8) ?i32 {
    const n = @min(label.len, dp_max_label);
    const m = token.len;
    // too big to align; the caller already knows it is a subsequence
    if (m > dp_max_query) return 1;

    var row_a: Row = undefined;
    var row_b: Row = undefined;
    var prev: *Row = &row_a;
    var cur: *Row = &row_b;

    dpFirstRow(token, label, n, cur);
    var i: usize = 1;
    while (i < m) : (i += 1) {
        std.mem.swap(*Row, &prev, &cur);
        dpNextRow(token, label, n, i, prev, cur);
    }

    var best: i32 = unreachable_score;
    for (cur[0..n]) |score| best = @max(best, score);
    if (best <= reachable_floor) return if (label.len > n) 1 else null;
    return std.math.clamp(best, 1, subsequence_max);
}

/// label indexes of the best subsequence alignment (same table as the score),
/// null when there is none or the token/label exceed the alignment window
fn subsequencePositions(token: []const u8, label: []const u8, out: []usize) ?[]usize {
    const n = @min(label.len, dp_max_label);
    const m = token.len;
    if (m == 0 or m > dp_max_query or m > out.len) return null;

    var table: [dp_max_query]Row = undefined;
    dpFirstRow(token, label, n, &table[0]);
    var i: usize = 1;
    while (i < m) : (i += 1) dpNextRow(token, label, n, i, &table[i - 1], &table[i]);

    var j: usize = 0;
    var best: i32 = unreachable_score;
    for (table[m - 1][0..n], 0..) |score, idx| {
        if (score > best) {
            best = score;
            j = idx;
        }
    }
    if (best <= reachable_floor) return null;

    // walk back: each cell came from the adjacent cell (contiguous bonus) or a
    // gap-penalized earlier one in the previous row
    i = m - 1;
    while (true) {
        out[i] = j;
        if (i == 0) break;
        const target = table[i][j] - charScore(label, j);
        const prev = &table[i - 1];
        if (j >= 1 and prev[j - 1] > reachable_floor and prev[j - 1] + contiguous_bonus == target) {
            j -= 1;
        } else {
            if (j < 2) return null;
            var k: usize = j - 1;
            j = while (k > 0) {
                k -= 1;
                const gap = gap_open_penalty + gap_extend_penalty * @as(i32, @intCast(j - 2 - k));
                if (prev[k] > reachable_floor and prev[k] - gap == target) break k;
            } else return null;
        }
        i -= 1;
    }
    return out[0..m];
}

/// Label indexes (ascending) that a token matches, with the same rules as
/// `tokenScore`: the best substring, else a word-start acronym, else the best
/// loose subsequence. Null when the token does not match.
pub fn tokenPositions(token: []const u8, label: []const u8, out: []usize) ?[]usize {
    if (token.len == 0 or token.len > label.len or token.len > out.len) return null;
    if (!isSubsequence(token, label)) return null;

    const substring = substringBest(token, label);
    const acronym_score = if (token.len >= 2) acronymMatch(token, label, out) else null;
    if (substring) |hit| {
        if (acronym_score == null or hit.score >= acronym_score.?) {
            for (out[0..token.len], hit.index..) |*slot, index| slot.* = index;
            return out[0..token.len];
        }
    }
    if (acronym_score != null) return out[0..token.len];
    return subsequencePositions(token, label, out);
}

fn expectRanked(query: []const u8, labels: []const []const u8, expected_first: usize) !void {
    var best_idx: ?usize = null;
    var best: i32 = -1;
    for (labels, 0..) |label, idx| {
        const score = tokenScore(query, label) orelse continue;
        if (score > best) {
            best = score;
            best_idx = idx;
        }
    }
    try std.testing.expectEqual(expected_first, best_idx.?);
}

test "acronym matches words that are not adjacent" {
    const labels = [_][]const u8{ "Visual Studio Code", "Vivaldi", "Preview scratch", "Discover screencast" };
    try expectRanked("vsc", &labels, 0);
    try std.testing.expect(tokenScore("vsc", "Safari") == null);
}

test "prefix beats mid-label word start beats mid-word" {
    const prefix = tokenScore("saf", "Safari").?;
    const word = tokenScore("saf", "Dash - safari docs").?;
    const mid = tokenScore("saf", "Unsafe mode").?;
    try std.testing.expect(prefix > word);
    try std.testing.expect(word > mid);
    try std.testing.expect(tokenScore("safari", "Safari").? > tokenScore("safari", "Safari Technology Preview").?);
}

test "substring beats scattered subsequence" {
    const sub = tokenScore("today", "xx today.md").?;
    const scattered = tokenScore("today", "to d a y").?;
    try std.testing.expect(sub > scattered);
    try std.testing.expect(scattered >= 1 and scattered <= subsequence_max);
}

test "loose subsequence needs adjacent or word-start second char" {
    try std.testing.expect(tokenScore("sfr", "Safari") == null);
    try std.testing.expect(tokenScore("sri", "Safari") == null);
    try std.testing.expect(tokenScore("sai", "Safari") != null);
    try std.testing.expect(tokenScore("agda", "agenda") != null);
    try std.testing.expect(tokenScore("aeda", "agenda") == null);
}

test "camelCase and separators are word starts" {
    try std.testing.expect(isBoundary("fooBar", 3));
    try std.testing.expect(!isBoundary("foobar", 3));
    try std.testing.expect(isBoundary("a[b", 2));
    try std.testing.expect(isBoundary("a:b", 2));
    try std.testing.expect(tokenScore("fb", "fooBar") != null);
    try std.testing.expect(tokenScore("fb", "foobar") == null);
}

test "uppercase query prefers exact case" {
    try std.testing.expect(tokenScore("Saf", "Safari").? > tokenScore("Saf", "safari").?);
}

test "long labels and tokens stay matchable" {
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    long[390] = 'q';
    long[391] = 'z';
    try std.testing.expect(tokenScore("qz", &long) != null);
    // subsequence beyond the alignment window still matches
    try std.testing.expect(tokenScore("xqz", &long) != null);
}

test "token positions exist exactly when the token scores, and spell the token" {
    const labels = [_][]const u8{
        "Visual Studio Code", "Safari",      "agenda",      "Dash - safari docs", "fooBar baz",
        "to d a y",           "xx today.md", "Unsafe mode", "a",                  "",
    };
    const tokens = [_][]const u8{ "vsc", "saf", "agda", "safi", "fb", "today", "sai", "zz", "a", "co", "Saf" };
    var out: [64]usize = undefined;
    for (labels) |label| {
        for (tokens) |token| {
            const score = tokenScore(token, label);
            const positions = tokenPositions(token, label, &out);
            try std.testing.expectEqual(score != null, positions != null);
            const hit = positions orelse continue;
            try std.testing.expectEqual(token.len, hit.len);
            for (hit, 0..) |index, n| {
                if (n > 0) try std.testing.expect(index > hit[n - 1]);
                try std.testing.expect(util.charsEqual(label[index], token[n], true));
            }
        }
    }
}

test "positions prefer the same occurrence the score does" {
    var out: [8]usize = undefined;
    // the word-start occurrence beats the mid-word one
    const hit = tokenPositions("saf", "Unsafe safari", &out).?;
    try std.testing.expectEqual(@as(usize, 7), hit[0]);
}

test "label hits outrank subtitle and keywords hits" {
    // exact label vs a tab whose subtitle is the same word
    const app = docTokenScore("safari", "Safari", "", "").?;
    const tab = docTokenScore("safari", "Inbox - Gmail", "Safari", "").?;
    try std.testing.expect(app > tab);
    // even a mid-label substring beats a perfect subtitle hit
    const weak_label = docTokenScore("safari", "Unsafari", "", "").?;
    try std.testing.expect(weak_label > tab);
    // subtitle outranks keywords for the same hit
    const keyword = docTokenScore("safari", "Inbox - Gmail", "", "Safari").?;
    try std.testing.expect(tab > keyword);
    try std.testing.expect(keyword > 0);
}

test "doc token score needs a hit in some field" {
    try std.testing.expect(docTokenScore("zzz", "Safari", "web", "browser") == null);
    try std.testing.expect(docTokenScore("web", "Safari", "web", "browser") != null);
    try std.testing.expect(docTokenScore("brow", "Safari", "web", "browser") != null);
    // a weak label subsequence does not hide a strong subtitle hit
    const label_loose = tokenScore("saf", "s a x f").?;
    const doc = docTokenScore("saf", "s a x f", "Safari", "").?;
    try std.testing.expect(doc >= label_loose);
}
