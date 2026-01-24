//! Tests for parallel iterators.

const std = @import("std");
const mod = @import("iter.zig");
const iter = mod.iter;
const iterMut = mod.iterMut;
const range = mod.range;

test "ParIter - sum" {
    const data = [_]i64{ 1, 2, 3, 4, 5 };
    const result = iter(i64, &data).sum();
    try std.testing.expectEqual(@as(i64, 15), result);
}

test "ParIter - min/max" {
    const data = [_]i64{ 3, 1, 4, 1, 5, 9, 2, 6 };
    try std.testing.expectEqual(@as(?i64, 1), iter(i64, &data).min());
    try std.testing.expectEqual(@as(?i64, 9), iter(i64, &data).max());
}

test "ParIter - empty" {
    const data: []const i64 = &.{};
    try std.testing.expectEqual(@as(?i64, null), iter(i64, data).min());
    try std.testing.expectEqual(@as(?i64, null), iter(i64, data).max());
}

test "ParIterMut - fill" {
    var data = [_]i64{ 1, 2, 3, 4, 5 };
    iterMut(i64, &data).fill(42);

    for (data) |v| {
        try std.testing.expectEqual(@as(i64, 42), v);
    }
}

test "RangeIter - sum" {
    const result = range(0, 10).sum(i64, struct {
        fn identity(i: usize) i64 {
            return @intCast(i);
        }
    }.identity);
    try std.testing.expectEqual(@as(i64, 45), result);
}

test "ParIter - find" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const result = iter(i64, &data).findAny(struct {
        fn pred(x: i64) bool {
            return x > 5;
        }
    }.pred);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? > 5);
}

test "ParIter - find not found" {
    const data = [_]i64{ 1, 2, 3, 4, 5 };
    const result = iter(i64, &data).findAny(struct {
        fn pred(x: i64) bool {
            return x > 100;
        }
    }.pred);
    try std.testing.expectEqual(@as(?i64, null), result);
}

test "ParIter - findFirst" {
    const data = [_]i64{ 1, 2, 3, 10, 5, 10, 7, 10, 9 };
    const result = iter(i64, &data).findFirst(struct {
        fn pred(x: i64) bool {
            return x == 10;
        }
    }.pred);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.index);
    try std.testing.expectEqual(@as(i64, 10), result.?.value);
}

test "ParIter - findLast" {
    const data = [_]i64{ 1, 2, 3, 10, 5, 10, 7, 10, 9 };
    const result = iter(i64, &data).findLast(struct {
        fn pred(x: i64) bool {
            return x == 10;
        }
    }.pred);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 7), result.?.index);
    try std.testing.expectEqual(@as(i64, 10), result.?.value);
}

test "ParIter - position" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const result = iter(i64, &data).position(struct {
        fn pred(x: i64) bool {
            return x == 5;
        }
    }.pred);
    try std.testing.expectEqual(@as(?usize, 4), result);
}

test "ParIter - rposition" {
    const data = [_]i64{ 1, 5, 3, 5, 5, 6, 7, 8, 9 };
    const result = iter(i64, &data).rposition(struct {
        fn pred(x: i64) bool {
            return x == 5;
        }
    }.pred);
    try std.testing.expectEqual(@as(?usize, 4), result);
}

test "ParIter - positionAny" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const result = iter(i64, &data).positionAny(struct {
        fn pred(x: i64) bool {
            return x > 5;
        }
    }.pred);
    // positionAny returns any matching index, not necessarily the first
    try std.testing.expect(result != null);
    try std.testing.expect(data[result.?] > 5);
}

test "ParIter - positionAny not found" {
    const data = [_]i64{ 1, 2, 3, 4, 5 };
    const result = iter(i64, &data).positionAny(struct {
        fn pred(x: i64) bool {
            return x > 100;
        }
    }.pred);
    try std.testing.expectEqual(@as(?usize, null), result);
}

test "ParIter - any" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const has_even = iter(i64, &data).any(struct {
        fn pred(x: i64) bool {
            return @mod(x, 2) == 0;
        }
    }.pred);
    try std.testing.expect(has_even);

    const has_negative = iter(i64, &data).any(struct {
        fn pred(x: i64) bool {
            return x < 0;
        }
    }.pred);
    try std.testing.expect(!has_negative);
}

test "ParIter - all" {
    const data = [_]i64{ 2, 4, 6, 8, 10 };
    const all_even = iter(i64, &data).all(struct {
        fn pred(x: i64) bool {
            return @mod(x, 2) == 0;
        }
    }.pred);
    try std.testing.expect(all_even);

    const all_less_than_5 = iter(i64, &data).all(struct {
        fn pred(x: i64) bool {
            return x < 5;
        }
    }.pred);
    try std.testing.expect(!all_less_than_5);
}

test "ParIter - minBy" {
    const data = [_]i64{ 5, 2, 8, 1, 9, 3 };
    const result = iter(i64, &data).minBy(struct {
        fn cmp(a: i64, b: i64) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp);
    try std.testing.expectEqual(@as(?i64, 1), result);
}

test "ParIter - maxBy" {
    const data = [_]i64{ 5, 2, 8, 1, 9, 3 };
    const result = iter(i64, &data).maxBy(struct {
        fn cmp(a: i64, b: i64) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp);
    try std.testing.expectEqual(@as(?i64, 9), result);
}

test "ParIter - minByKey" {
    const Item = struct {
        value: i64,
        priority: i32,
    };

    const data = [_]Item{
        .{ .value = 100, .priority = 3 },
        .{ .value = 200, .priority = 1 },
        .{ .value = 300, .priority = 2 },
    };

    const result = iter(Item, &data).minByKey(i32, struct {
        fn key(item: Item) i32 {
            return item.priority;
        }
    }.key);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 1), result.?.priority);
    try std.testing.expectEqual(@as(i64, 200), result.?.value);
}

test "ParIter - maxByKey" {
    const Item = struct {
        value: i64,
        priority: i32,
    };

    const data = [_]Item{
        .{ .value = 100, .priority = 3 },
        .{ .value = 200, .priority = 1 },
        .{ .value = 300, .priority = 2 },
    };

    const result = iter(Item, &data).maxByKey(i32, struct {
        fn key(item: Item) i32 {
            return item.priority;
        }
    }.key);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 3), result.?.priority);
    try std.testing.expectEqual(@as(i64, 100), result.?.value);
}

test "ParIter - minBy/maxBy empty" {
    const data: []const i64 = &.{};
    try std.testing.expectEqual(@as(?i64, null), iter(i64, data).minBy(struct {
        fn cmp(a: i64, b: i64) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp));
    try std.testing.expectEqual(@as(?i64, null), iter(i64, data).maxBy(struct {
        fn cmp(a: i64, b: i64) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp));
}

test "ChunksIter - count" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(usize, 4), iter(i64, &data).chunks_iter(3).count());
    try std.testing.expectEqual(@as(usize, 2), iter(i64, &data).chunks_iter(5).count());
    try std.testing.expectEqual(@as(usize, 1), iter(i64, &data).chunks_iter(10).count());
    try std.testing.expectEqual(@as(usize, 1), iter(i64, &data).chunks_iter(100).count());
}

test "ChunksIter - forEach" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    iter(i64, &data).chunks_iter(3).forEach(struct {
        fn process(chunk: []const i64) void {
            _ = chunk;
        }
    }.process);

    var sum: i64 = 0;
    for (data) |v| {
        sum += v;
    }

    const chunk_sum = iter(i64, &data).chunks_iter(3).reduce(i64, 0, struct {
        fn sumChunk(chunk: []const i64) i64 {
            var s: i64 = 0;
            for (chunk) |v| s += v;
            return s;
        }
    }.sumChunk, struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;
        }
    }.combine);

    try std.testing.expectEqual(sum, chunk_sum);
}

test "ChunksIter - reduce" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    const sum = iter(i64, &data).chunks_iter(3).reduce(i64, 0, struct {
        fn sumChunk(chunk: []const i64) i64 {
            var s: i64 = 0;
            for (chunk) |v| s += v;
            return s;
        }
    }.sumChunk, struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;
        }
    }.combine);

    try std.testing.expectEqual(@as(i64, 55), sum);
}

test "ChunksMutIter - forEach" {
    var data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    iterMut(i64, &data).chunksMut(3).forEach(struct {
        fn process(chunk: []i64) void {
            for (chunk) |*v| {
                v.* *= 2;
            }
        }
    }.process);

    const expected = [_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 };
    try std.testing.expectEqualSlices(i64, &expected, &data);
}

test "EnumerateIter - forEach" {
    const data = [_]i64{ 10, 20, 30, 40, 50 };

    iter(i64, &data).enumerate_iter().forEach(struct {
        fn process(idx: usize, val: i64) void {
            _ = idx;
            _ = val;
        }
    }.process);

    const result = iter(i64, &data).enumerate_iter().reduce(i64, 0, struct {
        fn mapFn(idx: usize, val: i64) i64 {
            return @as(i64, @intCast(idx)) * val;
        }
    }.mapFn, struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;
        }
    }.combine);

    try std.testing.expectEqual(@as(i64, 400), result);
}

test "EnumerateIter - enumerateFrom" {
    const data = [_]i64{ 10, 20, 30 };

    const result = iter(i64, &data).enumerateFrom(100).reduce(i64, 0, struct {
        fn mapFn(idx: usize, val: i64) i64 {
            return @as(i64, @intCast(idx)) + val;
        }
    }.mapFn, struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;
        }
    }.combine);

    try std.testing.expectEqual(@as(i64, 363), result);
}

test "EnumerateIter - any" {
    const data = [_]i64{ 10, 20, 30, 40, 50 };

    const found = iter(i64, &data).enumerate_iter().any(struct {
        fn pred(idx: usize, val: i64) bool {
            return idx % 2 == 1 and val > 25;
        }
    }.pred);

    try std.testing.expect(found);
}

test "EnumerateIter - all" {
    const data = [_]i64{ 10, 20, 30, 40, 50 };

    const all_positive = iter(i64, &data).enumerate_iter().all(struct {
        fn pred(idx: usize, val: i64) bool {
            _ = idx;
            return val > 0;
        }
    }.pred);

    try std.testing.expect(all_positive);
}

test "EnumerateMutIter - forEach" {
    var data = [_]i64{ 1, 2, 3, 4, 5 };

    iterMut(i64, &data).enumerate_iter().forEach(struct {
        fn process(idx: usize, val: *i64) void {
            val.* += @as(i64, @intCast(idx));
        }
    }.process);

    const expected = [_]i64{ 1, 3, 5, 7, 9 };
    try std.testing.expectEqualSlices(i64, &expected, &data);
}

test "EnumerateMutIter - mapInPlace" {
    var data = [_]i64{ 10, 20, 30, 40, 50 };

    iterMut(i64, &data).enumerate_iter().mapInPlace(struct {
        fn process(idx: usize, val: i64) i64 {
            return val * @as(i64, @intCast(idx + 1));
        }
    }.process);

    const expected = [_]i64{ 10, 40, 90, 160, 250 };
    try std.testing.expectEqualSlices(i64, &expected, &data);
}
