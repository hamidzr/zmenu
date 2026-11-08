//! Inline calculator for `calc` template items. A query counts as a calculation
//! when it is an arithmetic expression with at least one binary operator that
//! evaluates to a finite number, so "42" or "-5" are left to normal search.
//!
//! Grammar (whitespace between tokens is ignored):
//!   expr   = term { ("+" | "-") term }
//!   term   = unary { ("*" | "/" | "%") unary }      % is the remainder, like C
//!   unary  = ("-" | "+") unary | power
//!   power  = atom [ "^" unary ]                      right-associative; -2^2 is -4
//!   atom   = number | "(" expr ")"
//!   number = digits [ "." digits ] | "." digits      "_" may separate digits
//! Division by zero, NaN and overflow to infinity (at any step) reject the query.

const std = @import("std");

/// longer queries are not calculations
const max_query_bytes = 256;
/// nesting limit for parentheses and unary/power chains, to bound recursion
const max_depth = 48;
const max_number_bytes = 64;

const ParseError = error{Invalid};

/// the value of `text`, null when it is not a calculation
pub fn evaluate(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0 or trimmed.len > max_query_bytes) return null;

    var parser = Parser{ .src = trimmed };
    const value = parser.expr() catch return null;
    parser.skipSpace();
    if (parser.pos != parser.src.len) return null;
    if (parser.binary_ops == 0) return null;
    return finite(value) catch null;
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    binary_ops: usize = 0,
    depth: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
    }

    /// the next non-space byte, 0 at the end
    fn peek(self: *Parser) u8 {
        self.skipSpace();
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn enter(self: *Parser) ParseError!void {
        if (self.depth >= max_depth) return error.Invalid;
        self.depth += 1;
    }

    fn expr(self: *Parser) ParseError!f64 {
        try self.enter();
        defer self.depth -= 1;
        var value = try self.term();
        while (true) {
            const op = self.peek();
            if (op != '+' and op != '-') return value;
            self.pos += 1;
            self.binary_ops += 1;
            const rhs = try self.term();
            value = try finite(if (op == '+') value + rhs else value - rhs);
        }
    }

    fn term(self: *Parser) ParseError!f64 {
        var value = try self.unary();
        while (true) {
            const op = self.peek();
            if (op != '*' and op != '/' and op != '%') return value;
            self.pos += 1;
            self.binary_ops += 1;
            const rhs = try self.unary();
            value = try finite(switch (op) {
                '*' => value * rhs,
                '/' => value / rhs,
                else => @rem(value, rhs),
            });
        }
    }

    fn unary(self: *Parser) ParseError!f64 {
        try self.enter();
        defer self.depth -= 1;
        switch (self.peek()) {
            '-' => {
                self.pos += 1;
                return -(try self.unary());
            },
            '+' => {
                self.pos += 1;
                return self.unary();
            },
            else => return self.power(),
        }
    }

    fn power(self: *Parser) ParseError!f64 {
        const base = try self.atom();
        if (self.peek() != '^') return base;
        self.pos += 1;
        self.binary_ops += 1;
        const exponent = try self.unary();
        return finite(std.math.pow(f64, base, exponent));
    }

    fn atom(self: *Parser) ParseError!f64 {
        if (self.peek() == '(') {
            self.pos += 1;
            const value = try self.expr();
            if (self.peek() != ')') return error.Invalid;
            self.pos += 1;
            return value;
        }
        return self.number();
    }

    /// digits with single "_" between them; false when there are none
    fn digits(self: *Parser, out: []u8, len: *usize) ParseError!bool {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c)) {
                if (len.* == out.len) return error.Invalid;
                out[len.*] = c;
                len.* += 1;
            } else if (c == '_') {
                // only between digits
                const after = self.pos + 1;
                const joins = self.pos > start and std.ascii.isDigit(self.src[self.pos - 1]) and
                    after < self.src.len and std.ascii.isDigit(self.src[after]);
                if (!joins) return error.Invalid;
            } else break;
            self.pos += 1;
        }
        return self.pos > start;
    }

    fn number(self: *Parser) ParseError!f64 {
        _ = self.peek();
        var buf: [max_number_bytes]u8 = undefined;
        var len: usize = 0;
        const has_int = try self.digits(&buf, &len);
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            if (len == buf.len) return error.Invalid;
            buf[len] = '.';
            len += 1;
            if (!try self.digits(&buf, &len)) return error.Invalid;
        } else if (!has_int) return error.Invalid;
        // "_" right after the number ("1_") or a letter ("2x") is not part of the grammar
        return std.fmt.parseFloat(f64, buf[0..len]) catch error.Invalid;
    }
};

fn finite(value: f64) ParseError!f64 {
    if (!std.math.isFinite(value)) return error.Invalid;
    return value;
}

/// significant digits shown
const sig_digits = 12;
/// plain notation covers 1e-6 <= |x| < 1e15
const plain_min_exp = -6;
const plain_max_exp = 14;

/// Buffer size `format` needs.
pub const format_buf_len = 48;

/// `value` with up to 12 significant digits and no trailing zeros: plain
/// notation for 1e-6 <= |x| < 1e15, else "1.5e20" / "1e-7". The result lives in
/// `buf` (at least `format_buf_len` bytes).
pub fn format(buf: []u8, value: f64) []const u8 {
    if (value == 0 or !std.math.isFinite(value)) return "0";

    // d.ddddddddddde<exp> with 12 digits, correctly rounded
    var sci_buf: [32]u8 = undefined;
    const sci = std.fmt.bufPrint(&sci_buf, "{e:.11}", .{@abs(value)}) catch return "0";
    const e_at = std.mem.indexOfScalar(u8, sci, 'e') orelse return "0";
    const exp_text = std.mem.trimStart(u8, sci[e_at + 1 ..], "+");
    const exp = std.fmt.parseInt(i32, exp_text, 10) catch return "0";

    var digit_buf: [sig_digits]u8 = undefined;
    var count: usize = 0;
    for (sci[0..e_at]) |c| {
        if (c == '.') continue;
        digit_buf[count] = c;
        count += 1;
    }
    var digits = digit_buf[0..count];
    while (digits.len > 1 and digits[digits.len - 1] == '0') digits = digits[0 .. digits.len - 1];

    var out = std.Io.Writer.fixed(buf);
    writeNumber(&out, value < 0, digits, exp) catch return "0";
    return out.buffered();
}

fn writeNumber(out: *std.Io.Writer, negative: bool, digits: []const u8, exp: i32) std.Io.Writer.Error!void {
    if (negative) try out.writeByte('-');
    if (exp < plain_min_exp or exp > plain_max_exp) {
        try out.writeByte(digits[0]);
        if (digits.len > 1) {
            try out.writeByte('.');
            try out.writeAll(digits[1..]);
        }
        try out.print("e{d}", .{exp});
    } else if (exp >= 0) {
        const int_len: usize = @intCast(exp + 1);
        if (digits.len <= int_len) {
            try out.writeAll(digits);
            try out.splatByteAll('0', int_len - digits.len);
        } else {
            try out.writeAll(digits[0..int_len]);
            try out.writeByte('.');
            try out.writeAll(digits[int_len..]);
        }
    } else {
        try out.writeAll("0.");
        try out.splatByteAll('0', @intCast(-exp - 1));
        try out.writeAll(digits);
    }
}

fn expectValue(text: []const u8, expected: f64) !void {
    const got = evaluate(text) orelse {
        std.debug.print("not a calculation: '{s}'\n", .{text});
        return error.TestExpectedValue;
    };
    try std.testing.expectApproxEqRel(expected, got, 1e-12);
}

fn expectRejected(text: []const u8) !void {
    if (evaluate(text)) |value| {
        std.debug.print("unexpectedly evaluated '{s}' to {d}\n", .{ text, value });
        return error.TestExpectedRejection;
    }
}

fn expectFormat(value: f64, expected: []const u8) !void {
    var buf: [format_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings(expected, format(&buf, value));
}

test "arithmetic follows precedence" {
    try expectValue("1+2*3", 7);
    try expectValue("(1+2)*3", 9);
    try expectValue("12*(3+4)", 84);
    try expectValue("10-4-3", 3);
    try expectValue("100/10/5", 2);
    try expectValue("2+3*4-5/5", 13);
    try expectValue("1 + 2", 3);
    try expectValue("  1 +\t2  ", 3);
}

test "power is right-associative and binds tighter than unary minus" {
    try expectValue("2^3^2", 512);
    try expectValue("2^10", 1024);
    try expectValue("-2^2", -4);
    try expectValue("(-2)^2", 4);
    try expectValue("2^-1", 0.5);
    try expectValue("2*3^2", 18);
    try expectValue("4^0.5", 2);
}

test "unary minus and plus" {
    try expectValue("1--1", 2);
    try expectValue("1+-1", 0);
    try expectValue("2*-3", -6);
    try expectValue("-(1+2)*2", -6);
    try expectValue("+1+1", 2);
    try expectValue("--3+0", 3);
}

test "percent is the remainder" {
    try expectValue("10%3", 1);
    try expectValue("10 % 5", 0);
    try expectValue("7.5%2", 1.5);
    try expectValue("-7%3", -1);
    try expectValue("2+10%4*3", 8);
}

test "decimals and digit separators" {
    try expectValue("1.5*2", 3);
    try expectValue(".5+.25", 0.75);
    try expectValue("0.1+0.2", 0.3);
    try expectValue("1_000*3", 3000);
    try expectValue("1_000_000.5+0.5", 1000001);
    try expectValue("3.14_15*2", 6.283);
}

test "parentheses around an operation count" {
    try expectValue("(1+2)", 3);
    try expectValue("((2))*3", 6);
    try expectValue("((1+2)*(3+4))/7", 3);
}

test "a lone number or sign is not a calculation" {
    try expectRejected("42");
    try expectRejected(" 42 ");
    try expectRejected("3.14");
    try expectRejected("-5");
    try expectRejected("+5");
    try expectRejected("(42)");
    try expectRejected("-(3)");
    try expectRejected("((5))");
    try expectRejected("1_000");
}

test "malformed expressions are rejected" {
    try expectRejected("");
    try expectRejected("   ");
    try expectRejected("1+");
    try expectRejected("+");
    try expectRejected("*2");
    try expectRejected("1+*2");
    try expectRejected("abc");
    try expectRejected("1+a");
    try expectRejected("2x+1");
    try expectRejected("1 2");
    try expectRejected("1+2 3");
    try expectRejected("(1+2");
    try expectRejected("1+2)");
    try expectRejected("()");
    try expectRejected("2(3)");
    try expectRejected("(1+2)(3)");
    try expectRejected("5%");
    try expectRejected("1,5+1");
    try expectRejected("0x10+1");
    try expectRejected("1e3+1");
    try expectRejected("12.+1");
    try expectRejected("1.2.3+1");
    try expectRejected("1+2=");
}

test "bad digit separators are rejected" {
    try expectRejected("_1+1");
    try expectRejected("1_+1");
    try expectRejected("1__0+1");
    try expectRejected("1_.5+1");
    try expectRejected("1._5+1");
    try expectRejected("1+_");
}

test "division by zero, nan and overflow are rejected" {
    try expectRejected("1/0");
    try expectRejected("0/0");
    try expectRejected("1%0");
    try expectRejected("5/(2-2)");
    try expectRejected("0^-1");
    try expectRejected("(-8)^0.5");
    try expectRejected("10^400");
    try expectRejected("9^9^9");
    // an overflow that later shrinks back to a finite number is still rejected
    try expectRejected("1/(10^308*10)");
    try expectRejected("1e308+1");
}

test "very deep nesting and overlong queries are rejected, not crashed" {
    var buf: [200]u8 = undefined;
    @memset(buf[0..100], '(');
    buf[100] = '1';
    @memset(buf[101..200], ')');
    try expectRejected(buf[0..200]);
    // within the limit it still works
    @memset(buf[0..10], '(');
    buf[10] = '1';
    buf[11] = '+';
    buf[12] = '1';
    @memset(buf[13..23], ')');
    try expectValue(buf[0..23], 2);

    var minus: [100]u8 = undefined;
    @memset(&minus, '-');
    minus[99] = '1';
    try expectRejected(&minus);

    var long: [300]u8 = undefined;
    @memset(&long, '1');
    long[150] = '+';
    try expectRejected(&long);
}

test "format drops trailing zeros and caps at 12 significant digits" {
    try expectFormat(84, "84");
    try expectFormat(-84, "-84");
    try expectFormat(0, "0");
    try expectFormat(-0.0, "0");
    try expectFormat(0.5, "0.5");
    try expectFormat(1234.5, "1234.5");
    try expectFormat(0.30000000000000004, "0.3");
    try expectFormat(1.0 / 3.0, "0.333333333333");
    try expectFormat(2.0 / 3.0, "0.666666666667");
    try expectFormat(100.0 / 3.0, "33.3333333333");
    try expectFormat(1234567890123.456, "1234567890120");
    try expectFormat(123456789012.3456, "123456789012");
    try expectFormat(3.14159265358979, "3.14159265359");
    try expectFormat(1000000, "1000000");
}

test "format uses plain notation between 1e-6 and 1e15" {
    try expectFormat(1e-6, "0.000001");
    try expectFormat(1.5e-6, "0.0000015");
    try expectFormat(123456.789e-9, "0.000123456789");
    try expectFormat(999999999999000.0, "999999999999000");
    try expectFormat(999999999999999.0, "1e15");
    try expectFormat(100000000000000.0, "100000000000000");
    try expectFormat(-1e-6, "-0.000001");
}

test "format switches to exponent outside that range" {
    try expectFormat(1e15, "1e15");
    try expectFormat(1.5e20, "1.5e20");
    try expectFormat(-2.5e30, "-2.5e30");
    try expectFormat(9.9e-7, "9.9e-7");
    try expectFormat(1e-7, "1e-7");
    try expectFormat(1.23456789012345e-10, "1.23456789012e-10");
    try expectFormat(1e300, "1e300");
    try expectFormat(1.7976931348623157e308, "1.79769313486e308");
    // rounding up across the plain limit uses the exponent form
    try expectFormat(999999999999999.9, "1e15");
    try expectFormat(0.0000009999999999999, "0.000001");
    try expectFormat(9.99999999999e-7, "9.99999999999e-7");
}

test "evaluate and format together" {
    var buf: [format_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("84", format(&buf, evaluate("12*(3+4)").?));
    try std.testing.expectEqualStrings("0.3", format(&buf, evaluate("0.1+0.2").?));
    try std.testing.expectEqualStrings("1024", format(&buf, evaluate("2^10").?));
    try std.testing.expectEqualStrings("3.33333333333", format(&buf, evaluate("10/3").?));
    try std.testing.expectEqualStrings("1e20", format(&buf, evaluate("10^20").?));
}
