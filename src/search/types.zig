pub const SearchMethod = enum {
    direct,
    fuzzy,
    fuzzy1,
    fuzzy3,
    default,
};

pub const Options = struct {
    method: SearchMethod = .fuzzy,
    preserve_order: bool = false,
    limit: usize = 0,
    levenshtein_fallback: bool = true,
};

pub const Match = struct {
    index: usize,
    score: i32,
};

/// The text an item is searched by, all folded (see fold.zig). Subtitle and
/// keywords are empty when the item has none.
pub const Doc = struct {
    label: []const u8,
    subtitle: []const u8 = "",
    keywords: []const u8 = "",
    /// label, subtitle and keywords in one string, for the methods that match
    /// a single text (everything but the default fuzzy one)
    haystack: []const u8,
};
