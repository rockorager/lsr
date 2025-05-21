//! This file is a port of C implementaion that can be found here
//! https://github.com/sourcefrog/natsort.
const std = @import("std");
const isSpace = std.ascii.isWhitespace;
const isDigit = std.ascii.isDigit;
const Order = std.math.Order;
const testing = std.testing;

pub fn order(a: []const u8, b: []const u8) Order {
    return natOrder(a, b, false);
}

pub fn orderIgnoreCase(a: []const u8, b: []const u8) Order {
    return natOrder(a, b, true);
}

fn natOrder(a: []const u8, b: []const u8, comptime fold_case: bool) Order {
    var ai: usize = 0;
    var bi: usize = 0;

    while (true) : ({
        ai += 1;
        bi += 1;
    }) {
        var ca = if (ai == a.len) 0 else a[ai];
        var cb = if (bi == b.len) 0 else b[bi];

        while (isSpace(ca)) {
            ai += 1;
            ca = if (ai == a.len) 0 else a[ai];
        }

        while (isSpace(cb)) {
            bi += 1;
            cb = if (bi == b.len) 0 else b[bi];
        }

        if (isDigit(ca) and isDigit(cb)) {
            const fractional = ca == '0' or cb == '0';

            if (fractional) {
                const result = compareLeft(a[ai..], b[bi..]);
                if (result != .eq) return result;
            } else {
                const result = compareRight(a[ai..], b[bi..]);
                if (result != .eq) return result;
            }
        }

        if (ca == 0 and cb == 0) {
            return .eq;
        }

        if (fold_case) {
            ca = std.ascii.toUpper(ca);
            cb = std.ascii.toUpper(cb);
        }

        if (ca < cb) {
            return .lt;
        }

        if (ca > cb) {
            return .gt;
        }
    }
}

fn compareLeft(a: []const u8, b: []const u8) Order {
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = if (i == a.len) 0 else a[i];
        const cb = if (i == b.len) 0 else b[i];

        if (!isDigit(ca) and !isDigit(cb)) {
            return .eq;
        }
        if (!isDigit(ca)) {
            return .lt;
        }
        if (!isDigit(cb)) {
            return .gt;
        }
        if (ca < cb) {
            return .lt;
        }
        if (ca > cb) {
            return .gt;
        }
    }

    return .eq;
}

fn compareRight(a: []const u8, b: []const u8) Order {
    var bias = Order.eq;

    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = if (i == a.len) 0 else a[i];
        const cb = if (i == b.len) 0 else b[i];

        if (!isDigit(ca) and !isDigit(cb)) {
            return bias;
        }
        if (!isDigit(ca)) {
            return .lt;
        }
        if (!isDigit(cb)) {
            return .gt;
        }

        if (ca < cb) {
            if (bias != .eq) {
                bias = .lt;
            }
        } else if (ca > cb) {
            if (bias != .eq) {
                bias = .gt;
            }
        } else if (ca == 0 and cb == 0) {
            return bias;
        }
    }

    return .eq;
}

const SortContext = struct {
    ignore_case: bool = false,
    reverse: bool = false,

    fn compare(self: @This(), a: []const u8, b: []const u8) bool {
        const ord: std.math.Order = if (self.reverse) .gt else .lt;
        if (self.ignore_case) {
            return orderIgnoreCase(a, b) == ord;
        } else {
            return order(a, b) == ord;
        }
    }
};

test "lt" {
    try testing.expectEqual(Order.lt, order("a_1", "a_10"));
}

test "eq" {
    try testing.expectEqual(Order.eq, order("a_1", "a_1"));
}

test "gt" {
    try testing.expectEqual(Order.gt, order("a_10", "a_1"));
}

fn sortAndAssert(context: SortContext, input: [][]const u8, want: []const []const u8) !void {
    std.sort.pdq([]const u8, input, context, SortContext.compare);

    for (input, want) |actual, expected| {
        try testing.expectEqualStrings(expected, actual);
    }
}

test "sorting" {
    const context = SortContext{};
    var items = [_][]const u8{
        "item100",
        "item10",
        "item1",
    };
    const want = [_][]const u8{
        "item1",
        "item10",
        "item100",
    };

    try sortAndAssert(context, &items, &want);
}

test "sorting 2" {
    const context = SortContext{};
    var items = [_][]const u8{
        "item_30",
        "item_15",
        "item_3",
        "item_2",
        "item_10",
    };
    const want = [_][]const u8{
        "item_2",
        "item_3",
        "item_10",
        "item_15",
        "item_30",
    };

    try sortAndAssert(context, &items, &want);
}

test "leading zeros" {
    const context = SortContext{};
    var items = [_][]const u8{
        "item100",
        "item999",
        "item001",
        "item010",
        "item000",
    };
    const want = [_][]const u8{
        "item000",
        "item001",
        "item010",
        "item100",
        "item999",
    };

    try sortAndAssert(context, &items, &want);
}

test "dates" {
    const context = SortContext{};
    var items = [_][]const u8{
        "2000-1-10",
        "2000-1-2",
        "1999-12-25",
        "2000-3-23",
        "1999-3-3",
    };
    const want = [_][]const u8{
        "1999-3-3",
        "1999-12-25",
        "2000-1-2",
        "2000-1-10",
        "2000-3-23",
    };

    try sortAndAssert(context, &items, &want);
}

test "fractions" {
    const context = SortContext{};
    var items = [_][]const u8{
        "Fractional release numbers",
        "1.011.02",
        "1.010.12",
        "1.009.02",
        "1.009.20",
        "1.009.10",
        "1.002.08",
        "1.002.03",
        "1.002.01",
    };
    const want = [_][]const u8{
        "1.002.01",
        "1.002.03",
        "1.002.08",
        "1.009.02",
        "1.009.10",
        "1.009.20",
        "1.010.12",
        "1.011.02",
        "Fractional release numbers",
    };

    try sortAndAssert(context, &items, &want);
}

test "words" {
    const context = SortContext{};
    var items = [_][]const u8{
        "fred",
        "pic2",
        "pic100a",
        "pic120",
        "pic121",
        "jane",
        "tom",
        "pic02a",
        "pic3",
        "pic4",
        "1-20",
        "pic100",
        "pic02000",
        "10-20",
        "1-02",
        "1-2",
        "x2-y7",
        "x8-y8",
        "x2-y08",
        "x2-g8",
        "pic01",
        "pic02",
        "pic 6",
        "pic   7",
        "pic 5",
        "pic05",
        "pic 5 ",
        "pic 5 something",
        "pic 4 else",
    };
    const want = [_][]const u8{
        "1-02",
        "1-2",
        "1-20",
        "10-20",
        "fred",
        "jane",
        "pic01",
        "pic02",
        "pic02a",
        "pic02000",
        "pic05",
        "pic2",
        "pic3",
        "pic4",
        "pic 4 else",
        "pic 5",
        "pic 5 ",
        "pic 5 something",
        "pic 6",
        "pic   7",
        "pic100",
        "pic100a",
        "pic120",
        "pic121",
        "tom",
        "x2-g8",
        "x2-y08",
        "x2-y7",
        "x8-y8",
    };

    try sortAndAssert(context, &items, &want);
}

test "fuzz" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;

            const a = input[0..(input.len / 2)];
            const b = input[(input.len / 2)..];
            _ = order(a, b);
        }
    };

    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
