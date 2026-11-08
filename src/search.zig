const std = @import("std");
pub const fold = @import("search/fold.zig");
pub const highlight = @import("search/highlight.zig");
const fuzzy = @import("search/fuzzy.zig");
const levenshtein = @import("search/levenshtein.zig");
const rank = @import("search/rank.zig");
const types = @import("search/types.zig");

test {
    _ = rank;
    _ = fold;
    _ = highlight;
}

pub const SearchMethod = types.SearchMethod;
pub const Options = types.Options;
pub const Match = types.Match;
pub const Doc = types.Doc;

pub fn filterIndices(
    labels: []const []const u8,
    query: []const u8,
    opts: Options,
    matches: *std.ArrayList(Match),
    out_indices: *std.ArrayList(usize),
) void {
    matches.clearRetainingCapacity();
    out_indices.clearRetainingCapacity();

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        for (labels, 0..) |_, idx| {
            matches.appendAssumeCapacity(.{ .index = idx, .score = 0 });
        }
    } else {
        matchTexts(labels, query, trimmed, opts, matches);
    }

    for (matches.items[0..effectiveLimit(opts.limit, matches.items.len)]) |match| {
        out_indices.appendAssumeCapacity(match.index);
    }
}

/// matches of a non-blank query against one text per item, ordered by the options
fn matchTexts(texts: []const []const u8, query: []const u8, trimmed: []const u8, opts: Options, matches: *std.ArrayList(Match)) void {
    switch (opts.method) {
        .direct => fuzzy.directSearch(texts, query, matches),
        .fuzzy, .default => fuzzy.fuzzyTokenSearch(texts, trimmed, matches),
        .fuzzy3 => fuzzy.fuzzySearchBrute(texts, query, 2, matches),
        .fuzzy1 => fuzzy.fuzzyScoreSearch(texts, query, opts.preserve_order, matches),
    }

    if (opts.levenshtein_fallback and matches.items.len < 3) {
        levenshtein.appendFallbackMatches(texts, trimmed, matches);
        std.sort.insertion(Match, matches.items, {}, fuzzy.scoreDescIndexAsc);
    }
    if (opts.preserve_order) {
        std.sort.insertion(Match, matches.items, {}, fuzzy.indexAsc);
    }
}

/// Like `filterIndices` for items searched by label, subtitle and keywords.
/// `candidates` (ascending doc indexes) are the docs in play; `out_indices` gets
/// doc indexes. `view` is scratch space the caller has sized to the number of
/// docs. The default fuzzy method scores each token on the label first and
/// accepts a reduced score from the subtitle or keywords (`rank.docTokenScore`);
/// the other methods match one haystack of all three texts.
pub fn filterDocs(
    docs: []const Doc,
    candidates: []const usize,
    query: []const u8,
    opts: Options,
    matches: *std.ArrayList(Match),
    out_indices: *std.ArrayList(usize),
    view: *std.ArrayList([]const u8),
) void {
    matches.clearRetainingCapacity();
    out_indices.clearRetainingCapacity();

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        for (candidates) |doc_index| matches.appendAssumeCapacity(.{ .index = doc_index, .score = 0 });
    } else {
        switch (opts.method) {
            .fuzzy, .default => {
                fuzzy.fuzzyDocSearch(docs, candidates, trimmed, matches);
                if (opts.levenshtein_fallback and matches.items.len < 3) {
                    fillView(view, docs, candidates, .label);
                    levenshtein.appendFallbackMatches(view.items, trimmed, matches);
                    std.sort.insertion(Match, matches.items, {}, fuzzy.scoreDescIndexAsc);
                }
                if (opts.preserve_order) std.sort.insertion(Match, matches.items, {}, fuzzy.indexAsc);
            },
            else => {
                fillView(view, docs, candidates, .haystack);
                matchTexts(view.items, query, trimmed, opts, matches);
            },
        }
        // match indexes are positions in candidates; hand back doc indexes
        for (matches.items) |*match| match.index = candidates[match.index];
    }

    for (matches.items[0..effectiveLimit(opts.limit, matches.items.len)]) |match| {
        out_indices.appendAssumeCapacity(match.index);
    }
}

fn fillView(view: *std.ArrayList([]const u8), docs: []const Doc, candidates: []const usize, comptime field: enum { label, haystack }) void {
    view.clearRetainingCapacity();
    for (candidates) |doc_index| {
        view.appendAssumeCapacity(switch (field) {
            .label => docs[doc_index].label,
            .haystack => docs[doc_index].haystack,
        });
    }
}

fn effectiveLimit(limit: usize, count: usize) usize {
    if (limit == 0 or limit > count) return count;
    return limit;
}

test "direct smart-case matches only uppercase when query has uppercase" {
    const labels = [_][]const u8{ "Alpha", "bravo", "BRAVO" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "BR", .{ .method = .direct }, &matches, &out);
    try std.testing.expectEqualSlices(usize, &[_]usize{2}, out.items);

    out.clearRetainingCapacity();
    matches.clearRetainingCapacity();
    filterIndices(labels[0..], "br", .{ .method = .direct }, &matches, &out);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2 }, out.items);
}

test "fuzzy tokenized requires all tokens" {
    const labels = [_][]const u8{ "alpha bravo", "alpha", "bravo" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "al br", .{ .method = .fuzzy }, &matches, &out);
    try std.testing.expectEqualSlices(usize, &[_]usize{0}, out.items);

    out.clearRetainingCapacity();
    matches.clearRetainingCapacity();
    filterIndices(labels[0..], "al zz", .{ .method = .fuzzy, .levenshtein_fallback = false }, &matches, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "fuzzy3 orders direct matches before fuzzy" {
    const labels = [_][]const u8{ "abXc", "abc" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "abc", .{ .method = .fuzzy3, .levenshtein_fallback = false }, &matches, &out);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, out.items);
}

test "limit caps results" {
    const labels = [_][]const u8{
        "item0",  "item1",  "item2",  "item3", "item4",
        "item5",  "item6",  "item7",  "item8", "item9",
        "item10", "item11", "item12",
    };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "item", .{ .method = .direct, .limit = 10 }, &matches, &out);
    try std.testing.expectEqual(@as(usize, 10), out.items.len);
    try std.testing.expectEqual(@as(usize, 0), out.items[0]);
    try std.testing.expectEqual(@as(usize, 9), out.items[9]);
}

test "levenshtein fallback returns closest matches when enabled" {
    const labels = [_][]const u8{ "abc", "abcde", "wxyzq" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "abcd", .{ .method = .direct }, &matches, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(usize, 1), out.items[0]);
    try std.testing.expectEqual(@as(usize, 0), out.items[1]);
}

test "preserve order applies to fallback matches before result limit" {
    const labels = [_][]const u8{ "abc", "abcde", "wxyzq" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    const methods = [_]SearchMethod{ .direct, .fuzzy, .fuzzy1, .fuzzy3, .default };
    for (methods) |method| {
        filterIndices(labels[0..], "abcd", .{ .method = method, .preserve_order = true }, &matches, &out);
        try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, out.items);

        filterIndices(labels[0..], "abcd", .{ .method = method, .preserve_order = true, .limit = 1 }, &matches, &out);
        try std.testing.expectEqualSlices(usize, &[_]usize{0}, out.items);
    }
}

test "preserve order applies to ranked matches without fallback" {
    const labels = [_][]const u8{ "abXc", "abc" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    const methods = [_]SearchMethod{ .fuzzy, .fuzzy1, .fuzzy3, .default };
    for (methods) |method| {
        filterIndices(labels[0..], "abc", .{ .method = method, .preserve_order = true, .levenshtein_fallback = false }, &matches, &out);
        try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, out.items);
    }
}

test "fuzzy matches agenda after direct hit for anda" {
    const labels = [_][]const u8{ "agenda", "anda" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "anda", .{ .method = .fuzzy }, &matches, &out);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, out.items);
}

test "today query returns only lock screen and today note" {
    const labels = [_][]const u8{
        "[OS] Lock Screen - put the display to sleep immediately",
        "Edit: ~/notes/today.md",
        "Edit: ~/notes/agenda.md",
        "Open: ~/notes/week.md",
    };

    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "today", .{ .method = .fuzzy, .levenshtein_fallback = true }, &matches, &out);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, out.items);
}

test "fuzzy ranks direct substring above subsequence match" {
    const labels = [_][]const u8{
        // matches "today" via subsequence (to + d + a + y), but not as a verbatim substring
        "to d a y",
        // matches "today" as a direct substring
        "today.md",
    };

    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);

    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "today", .{ .method = .fuzzy, .levenshtein_fallback = true }, &matches, &out);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, out.items);
}

fn expectOrder(labels: []const []const u8, query: []const u8, expected: []const usize) !void {
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);
    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels, query, .{ .method = .fuzzy, .levenshtein_fallback = false }, &matches, &out);
    try std.testing.expectEqualSlices(usize, expected, out.items);
}

test "fuzzy ranks acronym vsc first" {
    const labels = [_][]const u8{ "Preview scratch", "Visual Studio Code", "Vivaldi", "Discover screencast" };
    try expectOrder(&labels, "vsc", &.{ 1, 0, 3 });
}

test "fuzzy ranks label prefix above later word start" {
    const labels = [_][]const u8{ "Dash - safari docs", "Safari", "Unsafe mode" };
    try expectOrder(&labels, "saf", &.{ 1, 0, 2 });
}

test "fuzzy multi-token scores sum across tokens" {
    const labels = [_][]const u8{
        "xchrome xdev",
        "Notes: chromium dev notes",
        "Google Chrome",
        "Chrome Canary - dev tools",
    };
    // prefix + word start > two word starts > two mid-word hits; Google Chrome lacks "dev"
    try expectOrder(&labels, "chr dev", &.{ 3, 1, 0 });
}

test "fuzzy ties keep input order" {
    const labels = [_][]const u8{ "Zebra app", "Alpha app", "Mango app" };
    try expectOrder(&labels, "app", &.{ 0, 1, 2 });
}

test "fuzzy empty query keeps input order" {
    const labels = [_][]const u8{ "c", "a", "b" };
    try expectOrder(&labels, "  ", &.{ 0, 1, 2 });
}

test "fuzzy substring beats scattered subsequence regardless of order" {
    const labels = [_][]const u8{ "to d a y", "today.md" };
    try expectOrder(&labels, "today", &.{ 1, 0 });
}

test "levenshtein fallback stays quiet for short queries" {
    const labels = [_][]const u8{ "ab", "abc", "xyz", "q" };
    var matches = std.ArrayList(Match).empty;
    var out = std.ArrayList(usize).empty;
    defer matches.deinit(std.testing.allocator);
    defer out.deinit(std.testing.allocator);
    try matches.ensureTotalCapacity(std.testing.allocator, labels.len);
    try out.ensureTotalCapacity(std.testing.allocator, labels.len);

    filterIndices(labels[0..], "zz", .{ .method = .fuzzy }, &matches, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

fn doc(comptime label: []const u8, comptime subtitle: []const u8, comptime keywords: []const u8) Doc {
    return .{ .label = label, .subtitle = subtitle, .keywords = keywords, .haystack = label ++ "  " ++ subtitle ++ " " ++ keywords };
}

const DocRun = struct {
    matches: std.ArrayList(Match) = .empty,
    out: std.ArrayList(usize) = .empty,
    view: std.ArrayList([]const u8) = .empty,

    fn init(count: usize) !DocRun {
        var run = DocRun{};
        try run.matches.ensureTotalCapacity(std.testing.allocator, count);
        try run.out.ensureTotalCapacity(std.testing.allocator, count);
        try run.view.ensureTotalCapacity(std.testing.allocator, count);
        return run;
    }

    fn deinit(self: *DocRun) void {
        self.matches.deinit(std.testing.allocator);
        self.out.deinit(std.testing.allocator);
        self.view.deinit(std.testing.allocator);
    }

    fn filter(self: *DocRun, docs: []const Doc, candidates: []const usize, query: []const u8, opts: Options) []const usize {
        filterDocs(docs, candidates, query, opts, &self.matches, &self.out, &self.view);
        return self.out.items;
    }
};

const all_four = [_]usize{ 0, 1, 2, 3 };

test "subtitle and keywords are searched" {
    const docs = [_]Doc{
        doc("Inbox - Gmail", "Safari", ""),
        doc("Notes", "", "scratchpad memo"),
        doc("Terminal", "iTerm", ""),
        doc("Calendar", "", ""),
    };
    var run = try DocRun.init(docs.len);
    defer run.deinit();
    const opts = Options{ .levenshtein_fallback = false };
    try std.testing.expectEqualSlices(usize, &.{0}, run.filter(&docs, &all_four, "safari", opts));
    try std.testing.expectEqualSlices(usize, &.{1}, run.filter(&docs, &all_four, "memo", opts));
    try std.testing.expectEqualSlices(usize, &.{2}, run.filter(&docs, &all_four, "iterm", opts));
    // every token must hit some field, not necessarily the same one
    try std.testing.expectEqualSlices(usize, &.{0}, run.filter(&docs, &all_four, "inbox safari", opts));
    try std.testing.expectEqual(@as(usize, 0), run.filter(&docs, &all_four, "inbox iterm", opts).len);
}

test "label matches rank above subtitle and keywords matches" {
    const docs = [_]Doc{
        doc("Inbox - Gmail", "Safari", ""),
        doc("Docs", "", "safari browser"),
        doc("Safari", "", ""),
        doc("Safari Technology Preview", "", ""),
    };
    var run = try DocRun.init(docs.len);
    defer run.deinit();
    // app first, longer label next, then subtitle hit, then keywords hit
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 0, 1 }, run.filter(&docs, &all_four, "safari", .{ .levenshtein_fallback = false }));
}

test "candidates restrict the search and the output holds doc indexes" {
    const docs = [_]Doc{ doc("alpha", "", ""), doc("alpine", "", ""), doc("alps", "", ""), doc("beta", "", "") };
    var run = try DocRun.init(docs.len);
    defer run.deinit();
    const only = [_]usize{ 1, 3 };
    try std.testing.expectEqualSlices(usize, &.{1}, run.filter(&docs, &only, "al", .{}));
    // blank query lists every candidate in order, and the limit applies
    try std.testing.expectEqualSlices(usize, &.{ 1, 3 }, run.filter(&docs, &only, "  ", .{}));
    try std.testing.expectEqualSlices(usize, &.{1}, run.filter(&docs, &only, "", .{ .limit = 1 }));
    try std.testing.expectEqual(@as(usize, 0), run.filter(&docs, &.{}, "al", .{}).len);
}

test "levenshtein fallback uses labels of the candidates only" {
    const docs = [_]Doc{ doc("Google Chrome", "", ""), doc("Chrome helper", "", ""), doc("Other", "", "") };
    var run = try DocRun.init(docs.len);
    defer run.deinit();
    const only = [_]usize{ 1, 2 };
    try std.testing.expectEqualSlices(usize, &.{1}, run.filter(&docs, &only, "chrme", .{}));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, run.filter(&docs, &.{ 0, 1, 2 }, "chrme", .{ .preserve_order = true }));
}

test "preserve order keeps candidate order for doc matches" {
    const docs = [_]Doc{ doc("xx app", "", ""), doc("app", "", ""), doc("my app", "", "") };
    var run = try DocRun.init(docs.len);
    defer run.deinit();
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, run.filter(&docs, &.{ 0, 1, 2 }, "app", .{ .preserve_order = true }));
}

test "non-default methods match the haystack" {
    const docs = [_]Doc{ doc("Inbox", "Safari", ""), doc("Notes", "", "memo"), doc("Other", "", "") };
    var run = try DocRun.init(docs.len);
    defer run.deinit();
    const methods = [_]SearchMethod{ .direct, .fuzzy1, .fuzzy3 };
    for (methods) |method| {
        const opts = Options{ .method = method, .levenshtein_fallback = false };
        try std.testing.expectEqualSlices(usize, &.{0}, run.filter(&docs, &.{ 0, 1, 2 }, "safari", opts));
        try std.testing.expectEqualSlices(usize, &.{1}, run.filter(&docs, &.{ 0, 1, 2 }, "memo", opts));
    }
}
