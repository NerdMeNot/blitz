//! Parallel Iterator Examples
//!
//! Demonstrates Blitz's Rayon-style parallel iterators.
//! Run with: zig build-exe --dep blitz -Mroot=examples/iterators.zig -Mblitz=api.zig -lc -O ReleaseFast
//!           ./iterators
//!
//! Examples covered:
//! 1. Basic iteration (sum, min, max)
//! 2. Find operations (findAny, findFirst, findLast, position)
//! 3. Predicates (any, all)
//! 4. Min/Max by key
//! 5. Chunks iteration
//! 6. Enumerated iteration

const std = @import("std");
const blitz = @import("blitz");

const print = std.debug.print;

pub fn main() !void {
    print(
        \\
        \\======================================================================
        \\              BLITZ PARALLEL ITERATOR EXAMPLES
        \\======================================================================
        \\
        \\
    , .{});

    try blitz.init();
    defer blitz.deinit();

    print("Initialized with {} workers\n\n", .{blitz.numWorkers()});

    try example1_basic_iteration();
    try example2_find_operations();
    try example3_predicates();
    try example4_minmax_by_key();
    try example5_chunks();
    try example6_enumerate();

    print(
        \\
        \\======================================================================
        \\                    ALL EXAMPLES COMPLETE
        \\======================================================================
        \\
    , .{});
}

// ============================================================================
// Example 1: Basic Iteration (sum, min, max)
// ============================================================================

fn example1_basic_iteration() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 1: Basic Parallel Iteration
        \\ SIMD-optimized sum, min, max operations
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    // Initialize with values
    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    // Create iterator
    const it = blitz.iter(i64, data);

    // SIMD-optimized sum
    const start_sum = std.time.nanoTimestamp();
    const sum = it.sum();
    const elapsed_sum = std.time.nanoTimestamp() - start_sum;

    const expected_sum: i64 = @intCast(n * (n - 1) / 2);
    print("  Sum of 0..{}: {} (expected: {})\n", .{ n - 1, sum, expected_sum });
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_sum)) / 1_000_000.0});

    // SIMD-optimized min/max
    const start_minmax = std.time.nanoTimestamp();
    const min_val = it.min();
    const max_val = it.max();
    const elapsed_minmax = std.time.nanoTimestamp() - start_minmax;

    print("  Min: {?}, Max: {?}\n", .{ min_val, max_val });
    print("  Time: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed_minmax)) / 1_000_000.0});
}

// ============================================================================
// Example 2: Find Operations
// ============================================================================

fn example2_find_operations() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 2: Find Operations
        \\ findAny (fast), findFirst/findLast (deterministic), position
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }
    // Place some special values
    data[1234567] = -1; // First negative
    data[8765432] = -2; // Last negative

    const it = blitz.iter(i64, data);

    // findAny - returns any match (non-deterministic, fast)
    const isNegative = struct {
        fn pred(x: i64) bool {
            return x < 0;
        }
    }.pred;

    const start_any = std.time.nanoTimestamp();
    const found_any = it.findAny(isNegative);
    const elapsed_any = std.time.nanoTimestamp() - start_any;

    print("  findAny(negative): {?} (could be -1 or -2)\n", .{found_any});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_any)) / 1_000_000.0});

    // findFirst - returns leftmost match (deterministic)
    const start_first = std.time.nanoTimestamp();
    const found_first = it.findFirst(isNegative);
    const elapsed_first = std.time.nanoTimestamp() - start_first;

    if (found_first) |r| {
        print("  findFirst(negative): value={}, index={}\n", .{ r.value, r.index });
    }
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_first)) / 1_000_000.0});

    // findLast - returns rightmost match (deterministic)
    const start_last = std.time.nanoTimestamp();
    const found_last = it.findLast(isNegative);
    const elapsed_last = std.time.nanoTimestamp() - start_last;

    if (found_last) |r| {
        print("  findLast(negative): value={}, index={}\n", .{ r.value, r.index });
    }
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_last)) / 1_000_000.0});

    // position - returns just the index
    const start_pos = std.time.nanoTimestamp();
    const pos = it.position(isNegative);
    const elapsed_pos = std.time.nanoTimestamp() - start_pos;

    print("  position(negative): {?}\n", .{pos});
    print("  Time: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed_pos)) / 1_000_000.0});
}

// ============================================================================
// Example 3: Predicates (any, all)
// ============================================================================

fn example3_predicates() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 3: Predicates
        \\ any() and all() with atomic early termination
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    const it = blitz.iter(i64, data);

    // any() - check if any element satisfies predicate
    const isLarge = struct {
        fn pred(x: i64) bool {
            return x > 9_999_990;
        }
    }.pred;

    const start_any = std.time.nanoTimestamp();
    const has_large = it.any(isLarge);
    const elapsed_any = std.time.nanoTimestamp() - start_any;

    print("  any(x > 9,999,990): {} (expected: true)\n", .{has_large});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_any)) / 1_000_000.0});

    // all() - check if all elements satisfy predicate
    const isNonNegative = struct {
        fn pred(x: i64) bool {
            return x >= 0;
        }
    }.pred;

    const start_all = std.time.nanoTimestamp();
    const all_positive = it.all(isNonNegative);
    const elapsed_all = std.time.nanoTimestamp() - start_all;

    print("  all(x >= 0): {} (expected: true)\n", .{all_positive});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_all)) / 1_000_000.0});

    // Early exit demonstration - put a failing element early
    data[100] = -1;

    const start_all2 = std.time.nanoTimestamp();
    const all_positive2 = it.all(isNonNegative);
    const elapsed_all2 = std.time.nanoTimestamp() - start_all2;

    print("  all(x >= 0) with early fail: {} (expected: false)\n", .{all_positive2});
    print("  Time: {d:.2} ms (fast due to early exit!)\n\n", .{@as(f64, @floatFromInt(elapsed_all2)) / 1_000_000.0});
}

// ============================================================================
// Example 4: Min/Max by Key
// ============================================================================

fn example4_minmax_by_key() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 4: Min/Max by Key
        \\ Find extrema using custom comparators or key functions
        \\----------------------------------------------------------------------
        \\
    , .{});

    const Person = struct {
        name: []const u8,
        age: u32,
        score: i32,
    };

    const people = [_]Person{
        .{ .name = "Alice", .age = 30, .score = 95 },
        .{ .name = "Bob", .age = 25, .score = 87 },
        .{ .name = "Charlie", .age = 35, .score = 92 },
        .{ .name = "Diana", .age = 28, .score = 99 },
        .{ .name = "Eve", .age = 22, .score = 85 },
    };

    const it = blitz.iter(Person, &people);

    // minByKey - find person with lowest age
    const youngest = it.minByKey(u32, struct {
        fn key(p: Person) u32 {
            return p.age;
        }
    }.key);

    if (youngest) |p| {
        print("  Youngest: {s} (age {})\n", .{ p.name, p.age });
    }

    // maxByKey - find person with highest score
    const top_scorer = it.maxByKey(i32, struct {
        fn key(p: Person) i32 {
            return p.score;
        }
    }.key);

    if (top_scorer) |p| {
        print("  Top scorer: {s} (score {})\n", .{ p.name, p.score });
    }

    // minBy - custom comparator (compare by name length)
    const shortest_name = it.minBy(struct {
        fn cmp(a: Person, b: Person) std.math.Order {
            return std.math.order(a.name.len, b.name.len);
        }
    }.cmp);

    if (shortest_name) |p| {
        print("  Shortest name: {s} ({} chars)\n", .{ p.name, p.name.len });
    }

    // maxBy - custom comparator
    const longest_name = it.maxBy(struct {
        fn cmp(a: Person, b: Person) std.math.Order {
            return std.math.order(a.name.len, b.name.len);
        }
    }.cmp);

    if (longest_name) |p| {
        print("  Longest name: {s} ({} chars)\n\n", .{ p.name, p.name.len });
    }
}

// ============================================================================
// Example 5: Chunks Iteration
// ============================================================================

fn example5_chunks() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 5: Chunks Iteration
        \\ Process data in fixed-size chunks in parallel
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 1_000_000;
    const chunk_size: usize = 10_000;

    const data = try allocator.alloc(f64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    const it = blitz.iter(f64, data);
    const chunks_it = it.chunks_iter(chunk_size);

    // Count chunks
    const num_chunks = chunks_it.count();
    print("  Data size: {}, Chunk size: {}\n", .{ n, chunk_size });
    print("  Number of chunks: {}\n", .{num_chunks});

    // Compute sum of each chunk, then sum those (parallel reduction over chunks)
    const start = std.time.nanoTimestamp();

    const total = chunks_it.reduce(f64, 0.0, struct {
        fn chunkSum(chunk: []const f64) f64 {
            var sum: f64 = 0;
            for (chunk) |v| sum += v;
            return sum;
        }
    }.chunkSum, struct {
        fn combine(a: f64, b: f64) f64 {
            return a + b;
        }
    }.combine);

    const elapsed = std.time.nanoTimestamp() - start;

    const expected: f64 = @floatFromInt(n * (n - 1) / 2);
    print("  Total sum via chunks: {d:.0}\n", .{total});
    print("  Expected: {d:.0}\n", .{expected});
    print("  Time: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
}

// ============================================================================
// Example 6: Enumerated Iteration
// ============================================================================

fn example6_enumerate() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 6: Enumerated Iteration
        \\ Parallel iteration with index tracking
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 1_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @intCast(i * 2); // Even numbers
    }

    const it = blitz.iter(i64, data);
    const enum_it = it.enumerate_iter();

    // Find first index where value != index * 2 (should find none)
    const start = std.time.nanoTimestamp();

    const mismatch = enum_it.any(struct {
        fn pred(index: usize, value: i64) bool {
            return value != @as(i64, @intCast(index)) * 2;
        }
    }.pred);

    const elapsed = std.time.nanoTimestamp() - start;

    print("  Checking {} elements for value == index * 2\n", .{n});
    print("  Found mismatch: {}\n", .{mismatch});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});

    // enumerateFrom - start from custom offset
    const offset_it = it.enumerateFrom(1000);

    const all_match = offset_it.all(struct {
        fn pred(index: usize, value: i64) bool {
            // index starts at 1000, but value at data[0]
            const actual_idx = index - 1000;
            return value == @as(i64, @intCast(actual_idx)) * 2;
        }
    }.pred);

    print("  enumerateFrom(1000) all match: {}\n\n", .{all_match});
}
