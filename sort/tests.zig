//! Sort Module Tests

const std = @import("std");
const mod = @import("sort.zig");
const helpers = @import("helpers.zig");
const pdqsort = @import("pdqsort.zig");
const by_key = @import("by_key.zig");

// ============================================================================
// Basic Sort Tests
// ============================================================================

test "sort - empty" {
    var v: [0]i64 = .{};
    mod.sortAsc(i64, &v);
}

test "sort - single element" {
    var v = [_]i64{42};
    mod.sortAsc(i64, &v);
    try std.testing.expectEqual(@as(i64, 42), v[0]);
}

test "sort - two elements" {
    var v = [_]i64{ 5, 3 };
    mod.sortAsc(i64, &v);
    try std.testing.expectEqual(@as(i64, 3), v[0]);
    try std.testing.expectEqual(@as(i64, 5), v[1]);
}

test "sort - small array ascending" {
    var v = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    mod.sortAsc(i64, &v);

    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] <= v[i + 1]);
    }
}

test "sort - small array descending" {
    var v = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    mod.sortDesc(i64, &v);

    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] >= v[i + 1]);
    }
}

test "sort - already sorted" {
    var v = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    mod.sortAsc(i64, &v);

    for (0..v.len) |i| {
        try std.testing.expectEqual(@as(i64, @intCast(i + 1)), v[i]);
    }
}

test "sort - reverse sorted" {
    var v = [_]i64{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    mod.sortAsc(i64, &v);

    for (0..v.len) |i| {
        try std.testing.expectEqual(@as(i64, @intCast(i + 1)), v[i]);
    }
}

test "sort - all equal" {
    var v = [_]i64{ 5, 5, 5, 5, 5, 5, 5, 5, 5 };
    mod.sortAsc(i64, &v);

    for (v) |x| {
        try std.testing.expectEqual(@as(i64, 5), x);
    }
}

test "sort - duplicates" {
    var v = [_]i64{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
    mod.sortAsc(i64, &v);

    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] <= v[i + 1]);
    }
}

test "sort - f64" {
    var v = [_]f64{ 3.14, 1.41, 2.72, 0.58, 1.73 };
    mod.sortAsc(f64, &v);

    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] <= v[i + 1]);
    }
}

// ============================================================================
// Helper Tests
// ============================================================================

test "heapsort - basic" {
    var v = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

    helpers.heapsort(i64, &v, struct {
        fn less(a: i64, b: i64) bool {
            return a < b;
        }
    }.less);

    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] <= v[i + 1]);
    }
}

test "partialInsertionSort - nearly sorted" {
    var v = [_]i64{ 1, 2, 4, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50 };

    const sorted = helpers.partialInsertionSort(i64, &v, struct {
        fn less(a: i64, b: i64) bool {
            return a < b;
        }
    }.less);

    try std.testing.expect(sorted);
    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] <= v[i + 1]);
    }
}

test "breakPatterns - doesn't crash" {
    var v = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    helpers.breakPatterns(i64, &v);
    // Just verify it doesn't crash - patterns are broken randomly
}

test "partition - basic" {
    var v = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

    const result = pdqsort.partition(i64, &v, 0, struct {
        fn less(a: i64, b: i64) bool {
            return a < b;
        }
    }.less);

    // All elements before mid should be < pivot
    for (v[0..result.mid]) |x| {
        try std.testing.expect(x < v[result.mid]);
    }

    // All elements after mid should be >= pivot
    for (v[result.mid + 1 ..]) |x| {
        try std.testing.expect(x >= v[result.mid]);
    }
}

// ============================================================================
// Sort By Key Tests
// ============================================================================

test "sortByKey - basic" {
    const Item = struct {
        value: i64,
        priority: i32,
    };

    var items = [_]Item{
        .{ .value = 100, .priority = 3 },
        .{ .value = 200, .priority = 1 },
        .{ .value = 300, .priority = 2 },
    };

    mod.sortByKey(Item, i32, &items, struct {
        fn key(item: Item) i32 {
            return item.priority;
        }
    }.key);

    // Should be sorted by priority: 1, 2, 3
    try std.testing.expectEqual(@as(i32, 1), items[0].priority);
    try std.testing.expectEqual(@as(i32, 2), items[1].priority);
    try std.testing.expectEqual(@as(i32, 3), items[2].priority);
}

test "sortByKey - negated key for descending" {
    var v = [_]i64{ 5, 2, 8, 1, 9, 3 };

    mod.sortByKey(i64, i64, &v, struct {
        fn key(x: i64) i64 {
            return -x; // Negate for descending order
        }
    }.key);

    // Should be descending
    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] >= v[i + 1]);
    }
}

test "sortByCachedKey - basic" {
    const Item = struct {
        value: i64,
        priority: i32,
    };

    var items = [_]Item{
        .{ .value = 100, .priority = 3 },
        .{ .value = 200, .priority = 1 },
        .{ .value = 300, .priority = 2 },
        .{ .value = 400, .priority = 5 },
        .{ .value = 500, .priority = 4 },
    };

    try mod.sortByCachedKey(Item, i32, std.testing.allocator, &items, struct {
        fn key(item: Item) i32 {
            return item.priority;
        }
    }.key);

    // Should be sorted by priority: 1, 2, 3, 4, 5
    try std.testing.expectEqual(@as(i32, 1), items[0].priority);
    try std.testing.expectEqual(@as(i32, 2), items[1].priority);
    try std.testing.expectEqual(@as(i32, 3), items[2].priority);
    try std.testing.expectEqual(@as(i32, 4), items[3].priority);
    try std.testing.expectEqual(@as(i32, 5), items[4].priority);
}

test "sortByCachedKey - i64 array" {
    var v = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

    try mod.sortByCachedKey(i64, i64, std.testing.allocator, &v, struct {
        fn key(x: i64) i64 {
            return x;
        }
    }.key);

    for (0..v.len - 1) |i| {
        try std.testing.expect(v[i] <= v[i + 1]);
    }
}

// ============================================================================
// Permutation Tests
// ============================================================================

test "applyPermutation - basic" {
    var v = [_]i32{ 10, 20, 30, 40, 50 };
    var indices = [_]usize{ 4, 3, 2, 1, 0 }; // Reverse

    try by_key.applyPermutation(i32, &v, &indices, std.testing.allocator);

    const expected = [_]i32{ 50, 40, 30, 20, 10 };
    try std.testing.expectEqualSlices(i32, &expected, &v);
}

test "applyPermutation - cycle" {
    var v = [_]i32{ 10, 20, 30, 40 };
    var indices = [_]usize{ 1, 2, 3, 0 }; // Rotate left

    try by_key.applyPermutation(i32, &v, &indices, std.testing.allocator);

    const expected = [_]i32{ 20, 30, 40, 10 };
    try std.testing.expectEqualSlices(i32, &expected, &v);
}
