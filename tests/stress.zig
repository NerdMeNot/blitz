//! Stress tests for concurrent operations and large data sets.
//!
//! These tests verify correctness under high contention and with large inputs.
//! Run with: zig build test-stress

const std = @import("std");
const blitz = @import("blitz");
const Deque = blitz.Deque;

// ============================================================================
// Concurrent Deque Stress Tests
// ============================================================================

test "Deque - concurrent producer-stealers stress" {
    // One producer thread pushes items while multiple stealers try to steal
    const NUM_ITEMS: usize = 10_000;
    const NUM_STEALERS: usize = 4;

    var deque = try Deque(u32).init(std.testing.allocator, 16384);
    defer deque.deinit();

    var stolen_counts: [NUM_STEALERS]usize = [_]usize{0} ** NUM_STEALERS;
    var producer_done = std.atomic.Value(bool).init(false);

    // Stealer threads
    var stealer_threads: [NUM_STEALERS]std.Thread = undefined;
    for (0..NUM_STEALERS) |i| {
        stealer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(d: *Deque(u32), count: *usize, done: *std.atomic.Value(bool)) void {
                while (!done.load(.acquire) or !d.isEmpty()) {
                    const result = d.steal();
                    if (result.result == .success) {
                        count.* += 1;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.run, .{ &deque, &stolen_counts[i], &producer_done });
    }

    // Producer pushes all items
    for (0..NUM_ITEMS) |i| {
        deque.push(@intCast(i));
        // Occasionally yield to give stealers a chance
        if (i % 100 == 0) std.Thread.yield() catch {};
    }

    // Pop remaining items from producer side
    var producer_popped: usize = 0;
    while (deque.pop()) |_| {
        producer_popped += 1;
    }

    producer_done.store(true, .release);

    // Wait for stealers
    for (stealer_threads) |t| {
        t.join();
    }

    // Verify all items were consumed exactly once
    var total_stolen: usize = 0;
    for (stolen_counts) |c| {
        total_stolen += c;
    }

    try std.testing.expectEqual(NUM_ITEMS, total_stolen + producer_popped);
}

test "Deque - high contention steal" {
    // Many threads racing to steal from a small set of items
    const NUM_ITEMS: usize = 100;
    const NUM_STEALERS: usize = 8;

    var deque = try Deque(u32).init(std.testing.allocator, 256);
    defer deque.deinit();

    // Pre-fill deque
    for (0..NUM_ITEMS) |i| {
        deque.push(@intCast(i));
    }

    var stolen_counts: [NUM_STEALERS]usize = [_]usize{0} ** NUM_STEALERS;
    var stealer_threads: [NUM_STEALERS]std.Thread = undefined;

    for (0..NUM_STEALERS) |i| {
        stealer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(d: *Deque(u32), count: *usize) void {
                // Each stealer tries to steal as much as possible
                for (0..1000) |_| {
                    const result = d.steal();
                    if (result.result == .success) {
                        count.* += 1;
                    }
                }
            }
        }.run, .{ &deque, &stolen_counts[i] });
    }

    for (stealer_threads) |t| {
        t.join();
    }

    var total_stolen: usize = 0;
    for (stolen_counts) |c| {
        total_stolen += c;
    }

    // All items should have been stolen
    try std.testing.expectEqual(NUM_ITEMS, total_stolen);
    try std.testing.expect(deque.isEmpty());
}

// ============================================================================
// Concurrent Parallel Sort Stress Tests
// ============================================================================

test "parallelSort - concurrent sorts stress" {
    // Run multiple sorts concurrently to stress the thread pool
    const ARRAY_SIZE: usize = 10_000;
    const NUM_CONCURRENT: usize = 4;

    var arrays: [NUM_CONCURRENT][]i64 = undefined;
    var threads: [NUM_CONCURRENT]std.Thread = undefined;

    // Allocate and fill arrays
    for (0..NUM_CONCURRENT) |i| {
        arrays[i] = try std.testing.allocator.alloc(i64, ARRAY_SIZE);
        // Fill with pseudo-random data (deterministic for reproducibility)
        var rng = std.Random.DefaultPrng.init(@intCast(i * 12345));
        for (arrays[i]) |*v| {
            v.* = rng.random().int(i64);
        }
    }
    defer {
        for (arrays) |arr| {
            std.testing.allocator.free(arr);
        }
    }

    // Launch concurrent sorts
    for (0..NUM_CONCURRENT) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(arr: []i64, allocator: std.mem.Allocator) void {
                blitz.parallelSort(i64, arr, allocator) catch {};
            }
        }.run, .{ arrays[i], std.testing.allocator });
    }

    // Wait for all sorts
    for (threads) |t| {
        t.join();
    }

    // Verify all arrays are sorted
    for (arrays) |arr| {
        for (0..arr.len - 1) |i| {
            try std.testing.expect(arr[i] <= arr[i + 1]);
        }
    }
}

// ============================================================================
// Large Array Tests (10M+ elements)
// ============================================================================

test "parallelSum - 10M elements" {
    const SIZE: usize = 10_000_000;
    const data = try std.testing.allocator.alloc(i64, SIZE);
    defer std.testing.allocator.free(data);

    // Fill with known values: data[i] = i % 100
    for (data, 0..) |*v, i| {
        v.* = @intCast(i % 100);
    }

    // Expected sum: each value 0..99 appears SIZE/100 times
    // Sum of 0..99 = 99*100/2 = 4950
    // Total = 4950 * (SIZE/100) = 4950 * 100_000 = 495_000_000
    const expected: i64 = 495_000_000;

    const result = blitz.iter(i64, data).sum();
    try std.testing.expectEqual(expected, result);
}

test "parallelSort - 10M elements" {
    const SIZE: usize = 10_000_000;
    const data = try std.testing.allocator.alloc(i64, SIZE);
    defer std.testing.allocator.free(data);

    // Fill with pseudo-random data
    var rng = std.Random.DefaultPrng.init(42);
    for (data) |*v| {
        v.* = rng.random().int(i64);
    }

    try blitz.parallelSort(i64, data, std.testing.allocator);

    // Verify sorted
    for (0..data.len - 1) |i| {
        try std.testing.expect(data[i] <= data[i + 1]);
    }
}

test "parallelMin/Max - 10M elements" {
    const SIZE: usize = 10_000_000;
    var data = try std.testing.allocator.alloc(i64, SIZE);
    defer std.testing.allocator.free(data);

    // Fill with sequential values
    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    // Put known min/max at specific positions
    data[SIZE / 3] = -999_999_999;
    data[SIZE * 2 / 3] = 999_999_999;

    const min_result = blitz.iter(i64, data).min();
    const max_result = blitz.iter(i64, data).max();

    try std.testing.expectEqual(@as(?i64, -999_999_999), min_result);
    try std.testing.expectEqual(@as(?i64, 999_999_999), max_result);
}

test "parallelFind - 10M elements" {
    const SIZE: usize = 10_000_000;
    var data = try std.testing.allocator.alloc(i64, SIZE);
    defer std.testing.allocator.free(data);

    // Fill with zeros
    @memset(data, 0);

    // Put a single 42 somewhere
    data[SIZE * 7 / 10] = 42;

    const result = blitz.parallelFindAny(i64, data, struct {
        fn pred(x: i64) bool {
            return x == 42;
        }
    }.pred);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 42), result.?);
}

test "parallelFor - 10M elements" {
    const SIZE: usize = 10_000_000;
    const data = try std.testing.allocator.alloc(i64, SIZE);
    defer std.testing.allocator.free(data);

    @memset(data, 0);

    const Context = struct { data: []i64 };
    blitz.parallelFor(SIZE, Context, .{ .data = data }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (start..end) |i| {
                ctx.data[i] = @intCast(i);
            }
        }
    }.body);

    // Verify
    for (data, 0..) |v, i| {
        try std.testing.expectEqual(@as(i64, @intCast(i)), v);
    }
}

test "iter - 10M elements reduce" {
    const SIZE: usize = 10_000_000;
    const data = try std.testing.allocator.alloc(i64, SIZE);
    defer std.testing.allocator.free(data);

    // Fill with 1s
    @memset(data, 1);

    const result = blitz.iter(i64, data).sum();
    try std.testing.expectEqual(@as(i64, SIZE), result);
}

// ============================================================================
// Edge Cases Under Concurrency
// ============================================================================

test "parallelReduce - empty slice concurrent" {
    // Multiple threads trying to reduce empty slices
    const NUM_THREADS: usize = 8;
    var results: [NUM_THREADS]i64 = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    const empty: []const i64 = &.{};

    for (0..NUM_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(result: *i64, data: []const i64) void {
                result.* = blitz.iter(i64, data).sum();
            }
        }.run, .{ &results[i], empty });
    }

    for (threads) |t| {
        t.join();
    }

    // All should return 0
    for (results) |r| {
        try std.testing.expectEqual(@as(i64, 0), r);
    }
}

test "join - recursive concurrent stress" {
    // Deep recursive fork-join to stress the pool
    const result = recursiveFib(25);
    // fib(25) = 75025
    try std.testing.expectEqual(@as(u64, 75025), result);
}

fn recursiveFib(n: u64) u64 {
    if (n < 2) return n;
    if (n < 15) return sequentialFib(n); // Sequential below threshold

    const results = blitz.join(.{
        .a = .{ recursiveFib, n - 1 },
        .b = .{ recursiveFib, n - 2 },
    });

    return results.a + results.b;
}

fn sequentialFib(n: u64) u64 {
    if (n < 2) return n;
    var a: u64 = 0;
    var b: u64 = 1;
    for (0..n - 1) |_| {
        const tmp = a + b;
        a = b;
        b = tmp;
    }
    return b;
}
