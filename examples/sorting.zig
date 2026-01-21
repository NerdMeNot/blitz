//! Sorting Examples
//!
//! Demonstrates Blitz's parallel sorting algorithms based on PDQSort.
//!
//! Run with: zig build-exe --dep blitz -Mroot=examples/sorting.zig -Mblitz=api.zig -lc -O ReleaseFast
//!           ./sorting
//!
//! Examples covered:
//! 1. Basic sorting (ascending, descending)
//! 2. Custom comparator sorting
//! 3. Sort by key (computed on each comparison)
//! 4. Sort by cached key (parallel key computation)
//! 5. Sorting structs
//! 6. Performance comparison

const std = @import("std");
const blitz = @import("blitz");

const print = std.debug.print;

pub fn main() !void {
    print(
        \\
        \\======================================================================
        \\              BLITZ PARALLEL SORTING EXAMPLES
        \\======================================================================
        \\
        \\
    , .{});

    try blitz.init();
    defer blitz.deinit();

    print("Initialized with {} workers\n\n", .{blitz.numWorkers()});

    try example1_basic_sorting();
    try example2_custom_comparator();
    try example3_sort_by_key();
    try example4_sort_by_cached_key();
    try example5_sorting_structs();
    try example6_performance_comparison();

    print(
        \\
        \\======================================================================
        \\                    ALL EXAMPLES COMPLETE
        \\======================================================================
        \\
    , .{});
}

// ============================================================================
// Example 1: Basic Sorting
// ============================================================================

fn example1_basic_sorting() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 1: Basic Sorting
        \\ Parallel PDQSort with ascending/descending order
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    // Initialize with random-ish data
    var seed: u64 = 12345;
    for (data) |*v| {
        seed = seed *% 6364136223846793005 +% 1;
        v.* = @bitCast(seed);
    }

    // Sort ascending
    const start_asc = std.time.nanoTimestamp();
    blitz.sortAsc(i64, data);
    const elapsed_asc = std.time.nanoTimestamp() - start_asc;

    // Verify sorted
    var is_sorted = true;
    for (0..n - 1) |i| {
        if (data[i] > data[i + 1]) {
            is_sorted = false;
            break;
        }
    }

    print("  Sorted {} elements ascending\n", .{n});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_asc)) / 1_000_000.0});
    print("  Verified sorted: {}\n", .{is_sorted});
    print("  First 5: {}, {}, {}, {}, {}\n", .{ data[0], data[1], data[2], data[3], data[4] });
    print("  Last 5:  {}, {}, {}, {}, {}\n", .{
        data[n - 5], data[n - 4], data[n - 3], data[n - 2], data[n - 1],
    });

    // Shuffle and sort descending
    seed = 54321;
    for (data) |*v| {
        seed = seed *% 6364136223846793005 +% 1;
        v.* = @bitCast(seed);
    }

    const start_desc = std.time.nanoTimestamp();
    blitz.sortDesc(i64, data);
    const elapsed_desc = std.time.nanoTimestamp() - start_desc;

    is_sorted = true;
    for (0..n - 1) |i| {
        if (data[i] < data[i + 1]) {
            is_sorted = false;
            break;
        }
    }

    print("\n  Sorted {} elements descending\n", .{n});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_desc)) / 1_000_000.0});
    print("  Verified sorted: {}\n\n", .{is_sorted});
}

// ============================================================================
// Example 2: Custom Comparator
// ============================================================================

fn example2_custom_comparator() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 2: Custom Comparator
        \\ Sort with any comparison function
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 1_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    // Initialize with values -n/2 to n/2
    for (data, 0..) |*v, i| {
        v.* = @as(i64, @intCast(i)) - @as(i64, @intCast(n / 2));
    }

    // Shuffle
    var seed: u64 = 99999;
    for (0..n) |i| {
        seed = seed *% 6364136223846793005 +% 1;
        const j = seed % n;
        const tmp = data[i];
        data[i] = data[j];
        data[j] = tmp;
    }

    // Sort by absolute value (smallest absolute values first)
    const start = std.time.nanoTimestamp();

    blitz.sort(i64, data, struct {
        fn lessThan(a: i64, b: i64) bool {
            const abs_a = if (a < 0) -a else a;
            const abs_b = if (b < 0) -b else b;
            return abs_a < abs_b;
        }
    }.lessThan);

    const elapsed = std.time.nanoTimestamp() - start;

    print("  Sorted {} elements by absolute value\n", .{n});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    print("  First 10 (smallest abs): ", .{});
    for (0..10) |i| {
        print("{} ", .{data[i]});
    }
    print("\n  Last 10 (largest abs):   ", .{});
    for (n - 10..n) |i| {
        print("{} ", .{data[i]});
    }
    print("\n\n", .{});
}

// ============================================================================
// Example 3: Sort by Key
// ============================================================================

fn example3_sort_by_key() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 3: Sort by Key
        \\ Sort using a key extraction function
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 1_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    // Initialize with random values
    var seed: u64 = 11111;
    for (data) |*v| {
        seed = seed *% 6364136223846793005 +% 1;
        v.* = @intCast(seed % 1_000_000);
    }

    // Sort by last 3 digits (modulo 1000)
    const start = std.time.nanoTimestamp();

    blitz.sortByKey(i64, i64, data, struct {
        fn key(x: i64) i64 {
            return @mod(x, 1000);
        }
    }.key);

    const elapsed = std.time.nanoTimestamp() - start;

    // Verify sorted by key
    var is_sorted = true;
    for (0..n - 1) |i| {
        if (@mod(data[i], 1000) > @mod(data[i + 1], 1000)) {
            is_sorted = false;
            break;
        }
    }

    print("  Sorted {} elements by last 3 digits\n", .{n});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    print("  Verified sorted by key: {}\n", .{is_sorted});
    print("  Sample: {} (key={}), {} (key={}), {} (key={})\n\n", .{
        data[0],      @mod(data[0], 1000),
        data[n / 2],  @mod(data[n / 2], 1000),
        data[n - 1],  @mod(data[n - 1], 1000),
    });
}

// ============================================================================
// Example 4: Sort by Cached Key
// ============================================================================

fn example4_sort_by_cached_key() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 4: Sort by Cached Key
        \\ Parallel key computation, then sort by cached keys
        \\ Best for expensive key functions
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 1_000_000;

    // Create strings to sort
    const StringBuf = struct {
        data: [32]u8,
        len: usize,

        fn slice(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };

    const strings = try allocator.alloc(StringBuf, n);
    defer allocator.free(strings);

    // Generate pseudo-random strings
    var seed: u64 = 77777;
    for (strings) |*s| {
        seed = seed *% 6364136223846793005 +% 1;
        const len = 5 + (seed % 20);
        s.len = len;
        for (s.data[0..len]) |*c| {
            seed = seed *% 6364136223846793005 +% 1;
            c.* = @intCast(97 + (seed % 26)); // a-z
        }
    }

    // Sort by string length using cached key
    // (In real code, the key function might be expensive like hashing)
    const start = std.time.nanoTimestamp();

    try blitz.sortByCachedKey(StringBuf, usize, allocator, strings, struct {
        fn key(s: StringBuf) usize {
            return s.len;
        }
    }.key);

    const elapsed = std.time.nanoTimestamp() - start;

    // Verify sorted by length
    var is_sorted = true;
    for (0..n - 1) |i| {
        if (strings[i].len > strings[i + 1].len) {
            is_sorted = false;
            break;
        }
    }

    print("  Sorted {} strings by length (cached key)\n", .{n});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    print("  Verified sorted: {}\n", .{is_sorted});
    print("  First: \"{s}\" (len {})\n", .{ strings[0].slice(), strings[0].len });
    print("  Last:  \"{s}\" (len {})\n\n", .{ strings[n - 1].slice(), strings[n - 1].len });
}

// ============================================================================
// Example 5: Sorting Structs
// ============================================================================

fn example5_sorting_structs() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 5: Sorting Structs
        \\ Sort complex data by various fields
        \\----------------------------------------------------------------------
        \\
    , .{});

    const Person = struct {
        id: u32,
        age: u8,
        score: i32,
        name: [16]u8,

        fn nameSlice(self: *const @This()) []const u8 {
            var len: usize = 0;
            for (self.name) |c| {
                if (c == 0) break;
                len += 1;
            }
            return self.name[0..len];
        }
    };

    const allocator = std.heap.page_allocator;
    const n: usize = 100_000;

    const people = try allocator.alloc(Person, n);
    defer allocator.free(people);

    // Generate random people
    var seed: u64 = 33333;
    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Henry" };

    for (people, 0..) |*p, i| {
        seed = seed *% 6364136223846793005 +% 1;
        p.id = @intCast(i);
        p.age = @intCast(18 + (seed % 60));
        seed = seed *% 6364136223846793005 +% 1;
        p.score = @intCast(seed % 1000);
        const name = names[seed % names.len];
        @memset(&p.name, 0);
        @memcpy(p.name[0..name.len], name);
    }

    // Sort by age
    var start = std.time.nanoTimestamp();
    blitz.sortByKey(Person, u8, people, struct {
        fn key(p: Person) u8 {
            return p.age;
        }
    }.key);
    var elapsed = std.time.nanoTimestamp() - start;

    print("  Sorted {} people by age\n", .{n});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    print("  Youngest: {s} (age {})\n", .{ people[0].nameSlice(), people[0].age });
    print("  Oldest:   {s} (age {})\n", .{ people[n - 1].nameSlice(), people[n - 1].age });

    // Sort by score (descending - negate the key)
    start = std.time.nanoTimestamp();
    blitz.sortByKey(Person, i32, people, struct {
        fn key(p: Person) i32 {
            return -p.score; // Negate for descending
        }
    }.key);
    elapsed = std.time.nanoTimestamp() - start;

    print("\n  Sorted {} people by score (descending)\n", .{n});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    print("  Top scorer:    {s} (score {})\n", .{ people[0].nameSlice(), people[0].score });
    print("  Bottom scorer: {s} (score {})\n\n", .{ people[n - 1].nameSlice(), people[n - 1].score });
}

// ============================================================================
// Example 6: Performance Comparison
// ============================================================================

fn example6_performance_comparison() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 6: Performance Comparison
        \\ Sequential vs Parallel PDQSort
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data1 = try allocator.alloc(i64, n);
    defer allocator.free(data1);
    const data2 = try allocator.alloc(i64, n);
    defer allocator.free(data2);

    // Initialize both with same random data
    var seed: u64 = 88888;
    for (data1, data2) |*v1, *v2| {
        seed = seed *% 6364136223846793005 +% 1;
        const val: i64 = @bitCast(seed);
        v1.* = val;
        v2.* = val;
    }

    // Sequential sort (std.sort)
    const start_std = std.time.nanoTimestamp();
    std.mem.sort(i64, data1, {}, struct {
        fn lessThan(_: void, a: i64, b: i64) bool {
            return a < b;
        }
    }.lessThan);
    const elapsed_std = std.time.nanoTimestamp() - start_std;

    // Parallel PDQSort (Blitz)
    const start_blitz = std.time.nanoTimestamp();
    blitz.sortAsc(i64, data2);
    const elapsed_blitz = std.time.nanoTimestamp() - start_blitz;

    // Verify both produce same result
    var results_match = true;
    for (data1, data2) |v1, v2| {
        if (v1 != v2) {
            results_match = false;
            break;
        }
    }

    const speedup = @as(f64, @floatFromInt(elapsed_std)) / @as(f64, @floatFromInt(elapsed_blitz));

    print("  Sorting {}M random i64 elements\n\n", .{n / 1_000_000});
    print("  std.mem.sort:   {d:>8.2} ms\n", .{@as(f64, @floatFromInt(elapsed_std)) / 1_000_000.0});
    print("  Blitz PDQSort:  {d:>8.2} ms ({d:.1}x speedup)\n", .{
        @as(f64, @floatFromInt(elapsed_blitz)) / 1_000_000.0,
        speedup,
    });
    print("\n  Results match: {}\n", .{results_match});

    // Test different patterns
    print("\n  Different input patterns ({}M elements):\n", .{n / 1_000_000});

    // Already sorted
    for (data2, 0..) |*v, i| v.* = @intCast(i);
    var start = std.time.nanoTimestamp();
    blitz.sortAsc(i64, data2);
    var elapsed = std.time.nanoTimestamp() - start;
    print("    Already sorted: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});

    // Reverse sorted
    for (data2, 0..) |*v, i| v.* = @intCast(n - i);
    start = std.time.nanoTimestamp();
    blitz.sortAsc(i64, data2);
    elapsed = std.time.nanoTimestamp() - start;
    print("    Reverse sorted: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});

    // All equal
    for (data2) |*v| v.* = 42;
    start = std.time.nanoTimestamp();
    blitz.sortAsc(i64, data2);
    elapsed = std.time.nanoTimestamp() - start;
    print("    All equal:      {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
}
