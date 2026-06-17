const std = @import("std");

/// Parse a fixed-point decimal string into an integer number of minor units.
pub fn parseFixedToMinor(txt: []const u8, decimals: u8) !i64 {
    const trimmed = std.mem.trim(u8, txt, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAmount;

    var sign: i64 = 1;
    var s = trimmed;
    if (s[0] == '-') {
        sign = -1;
        s = s[1..];
    } else if (s[0] == '+') {
        s = s[1..];
    }
    if (s.len == 0) return error.InvalidAmount;

    var whole: i64 = 0;
    var frac_minor: i64 = 0;
    var in_frac = false;
    var frac_digits: u8 = 0;
    var saw_digit = false;

    for (s) |c| switch (c) {
        '.' => {
            if (in_frac) return error.InvalidAmount;
            in_frac = true;
        },
        '0'...'9' => {
            saw_digit = true;
            const digit: i64 = @intCast(c - '0');
            if (!in_frac) {
                whole = std.math.mul(i64, whole, 10) catch return error.InvalidAmount;
                whole = std.math.add(i64, whole, digit) catch return error.InvalidAmount;
                continue;
            }
            if (frac_digits < decimals) {
                frac_minor = std.math.mul(i64, frac_minor, 10) catch return error.InvalidAmount;
                frac_minor = std.math.add(i64, frac_minor, digit) catch return error.InvalidAmount;
                frac_digits += 1;
            }
        },
        else => return error.InvalidAmount,
    };
    if (!saw_digit) return error.InvalidAmount;

    // Pad fractional part to the desired precision
    while (frac_digits < decimals) : (frac_digits += 1) {
        frac_minor = std.math.mul(i64, frac_minor, 10) catch return error.InvalidAmount;
    }

    const scale = pow10(i64, decimals) catch return error.InvalidAmount;
    const scaled_whole = std.math.mul(i64, whole, scale) catch return error.InvalidAmount;
    const magnitude = std.math.add(i64, scaled_whole, frac_minor) catch return error.InvalidAmount;
    return std.math.mul(i64, sign, magnitude) catch return error.InvalidAmount;
}

pub fn parseUsdToCents(txt: []const u8) !i64 {
    return parseFixedToMinor(txt, 2);
}

/// Format minor units into a decimal string.
///
/// If `trim_trailing_zeros` is true, fractional trailing zeros are removed and
/// the decimal point is removed if nothing remains after it.
pub fn formatFixedFromMinor(
    alloc: std.mem.Allocator,
    amount_minor: i64,
    decimals: u8,
    trim_trailing_zeros: bool,
) ![]u8 {
    if (decimals == 0) {
        return try std.fmt.allocPrint(alloc, "{d}", .{amount_minor});
    }

    const neg = amount_minor < 0;
    const abs: i128 = @intCast(@abs(@as(i128, amount_minor)));
    const denom: i128 = pow10(i128, decimals) catch unreachable;

    const whole: i128 = @divTrunc(abs, denom);
    const frac: i128 = abs - whole * denom;

    var frac_buf: [64]u8 = undefined;
    std.debug.assert(@as(usize, decimals) <= frac_buf.len);
    var rem: i128 = frac;
    var j: usize = @as(usize, decimals);
    while (j > 0) {
        j -= 1;
        const digit: i128 = @mod(rem, 10);
        frac_buf[j] = @as(u8, @intCast(digit)) + '0';
        rem = @divTrunc(rem, 10);
    }

    var frac_len: usize = @as(usize, decimals);
    if (trim_trailing_zeros) {
        while (frac_len > 0 and frac_buf[frac_len - 1] == '0') : (frac_len -= 1) {}
    }

    var whole_buf: [64]u8 = undefined;
    const whole_slice = std.fmt.bufPrint(&whole_buf, "{d}", .{whole}) catch unreachable;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, whole_slice.len + 1 + frac_len + @intFromBool(neg));
    if (neg) out.appendAssumeCapacity('-');
    out.appendSliceAssumeCapacity(whole_slice);
    if (frac_len > 0) {
        out.appendAssumeCapacity('.');
        out.appendSliceAssumeCapacity(frac_buf[0..frac_len]);
    }
    return try out.toOwnedSlice(alloc);
}

pub fn formatUsdFromCents(alloc: std.mem.Allocator, usd_cents: i64) ![]u8 {
    return formatFixedFromMinor(alloc, usd_cents, 2, false);
}

pub fn pow10(comptime T: type, decimals: u8) error{Overflow}!T {
    var p: T = 1;
    var i: u8 = 0;
    while (i < decimals) : (i += 1) {
        p = try std.math.mul(T, p, 10);
    }
    return p;
}

test parseUsdToCents {
    const t = std.testing;
    try t.expectEqual(@as(i64, 12300), try parseUsdToCents("123"));
    try t.expectEqual(@as(i64, 120), try parseUsdToCents("1.2"));
    try t.expectEqual(@as(i64, 123), try parseUsdToCents("1.23"));
    try t.expectEqual(@as(i64, 123), try parseUsdToCents("1.239"));

    try t.expectEqual(@as(i64, 123), try parseUsdToCents("+1.239"));
    try t.expectError(error.InvalidAmount, parseUsdToCents("1.2x"));
    try t.expectError(error.InvalidAmount, parseUsdToCents("1.239x"));
    try t.expectError(error.InvalidAmount, parseUsdToCents("."));
    try t.expectError(error.InvalidAmount, parseUsdToCents("-"));
}

test formatUsdFromCents {
    const t = std.testing;
    const gpa = t.allocator;

    const s0 = try formatUsdFromCents(gpa, 0);
    defer gpa.free(s0);
    try t.expectEqualStrings("0.00", s0);

    const s1 = try formatUsdFromCents(gpa, 120);
    defer gpa.free(s1);
    try t.expectEqualStrings("1.20", s1);

    const s2 = try formatUsdFromCents(gpa, -123);
    defer gpa.free(s2);
    try t.expectEqualStrings("-1.23", s2);
}

test formatFixedFromMinor {
    const t = std.testing;
    const gpa = t.allocator;

    const s0 = try formatFixedFromMinor(gpa, 123000000, 8, true);
    defer gpa.free(s0);
    try t.expectEqualStrings("1.23", s0);

    const s1 = try formatFixedFromMinor(gpa, 100000000, 8, true);
    defer gpa.free(s1);
    try t.expectEqualStrings("1", s1);

    const s2 = try formatFixedFromMinor(gpa, 1, 8, true);
    defer gpa.free(s2);
    try t.expectEqualStrings("0.00000001", s2);
}
