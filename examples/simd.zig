//! SIMD Operations Examples
//!
//! Demonstrates Blitz's SIMD-optimized operations that combine
//! vectorization with multi-threading for maximum performance.
//!
//! Run with: zig build-exe --dep blitz -Mroot=examples/simd.zig -Mblitz=api.zig -lc -O ReleaseFast
//!           ./simd
//!
//! Examples covered:
//! 1. SIMD Aggregations (sum, min, max)
//! 2. SIMD Argmin/Argmax (value + index)
//! 3. SIMD Search operations
//! 4. Parallel SIMD (multi-threaded + vectorized)
//! 5. Performance comparison

const std = @import("std");
const blitz = @import("blitz");

const print = std.debug.print;

pub fn main() !void {
    print(
        \\
        \\======================================================================
        \\              BLITZ SIMD OPERATIONS EXAMPLES
        \\======================================================================
        \\
        \\
    , .{});

    try blitz.init();
    defer blitz.deinit();

    print("Initialized with {} workers\n\n", .{blitz.numWorkers()});

    try example1_simd_aggregations();
    try example2_simd_argminmax();
    try example3_simd_search();
    try example4_parallel_simd();
    try example5_performance_comparison();

    print(
        \\
        \\======================================================================
        \\                    ALL EXAMPLES COMPLETE
        \\======================================================================
        \\
    , .{});
}

// ============================================================================
// Example 1: SIMD Aggregations
// ============================================================================

fn example1_simd_aggregations() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 1: SIMD Aggregations
        \\ Vectorized sum, min, max using 8-wide SIMD lanes
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

    const simd = blitz.simd_mod;

    // SIMD sum with 4 accumulators for ILP
    const start_sum = std.time.nanoTimestamp();
    const sum = simd.sum(i64, data);
    const elapsed_sum = std.time.nanoTimestamp() - start_sum;

    const expected: i64 = @intCast(n * (n - 1) / 2);
    print("  SIMD sum of {} elements: {}\n", .{ n, sum });
    print("  Expected: {}\n", .{expected});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_sum)) / 1_000_000.0});
    print("  Throughput: {d:.1} billion elements/sec\n", .{
        @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed_sum)) / 1_000_000_000.0) / 1_000_000_000.0,
    });

    // SIMD min/max
    const start_minmax = std.time.nanoTimestamp();
    const min_val = simd.min(i64, data);
    const max_val = simd.max(i64, data);
    const elapsed_minmax = std.time.nanoTimestamp() - start_minmax;

    print("  SIMD min: {?}, max: {?}\n", .{ min_val, max_val });
    print("  Time: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed_minmax)) / 1_000_000.0});
}

// ============================================================================
// Example 2: SIMD Argmin/Argmax
// ============================================================================

fn example2_simd_argminmax() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 2: SIMD Argmin/Argmax
        \\ Find value AND index using vectorized comparison with @select
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    // Create data with minimum at index 7654321
    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }
    data[7654321] = -999;

    const simd = blitz.simd_mod;

    // SIMD argmin - finds both value and index
    const start_argmin = std.time.nanoTimestamp();
    const argmin_result = simd.argmin(i64, data);
    const elapsed_argmin = std.time.nanoTimestamp() - start_argmin;

    if (argmin_result) |r| {
        print("  SIMD argmin: value={}, index={}\n", .{ r.value, r.index });
        print("  Correct index: {}\n", .{r.index == 7654321});
    }
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_argmin)) / 1_000_000.0});

    // Reset and test argmax
    data[7654321] = 7654321;
    data[1234567] = 999_999_999;

    const start_argmax = std.time.nanoTimestamp();
    const argmax_result = simd.argmax(i64, data);
    const elapsed_argmax = std.time.nanoTimestamp() - start_argmax;

    if (argmax_result) |r| {
        print("  SIMD argmax: value={}, index={}\n", .{ r.value, r.index });
        print("  Correct index: {}\n", .{r.index == 1234567});
    }
    print("  Time: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed_argmax)) / 1_000_000.0});
}

// ============================================================================
// Example 3: SIMD Search Operations
// ============================================================================

fn example3_simd_search() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 3: SIMD Search Operations
        \\ Vectorized find, any, all predicates
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

    const simd = blitz.simd_mod;

    // findValue - find first occurrence of a value
    const needle: i64 = 5_000_000;
    const start_find = std.time.nanoTimestamp();
    const found_idx = simd.findValue(i64, data, needle);
    const elapsed_find = std.time.nanoTimestamp() - start_find;

    print("  findValue({}): index={?}\n", .{ needle, found_idx });
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_find)) / 1_000_000.0});

    // anyGreaterThan - vectorized threshold check
    const threshold: i64 = @intCast(n - 100);
    const start_any = std.time.nanoTimestamp();
    const has_large = simd.anyGreaterThan(i64, data, threshold);
    const elapsed_any = std.time.nanoTimestamp() - start_any;

    print("  anyGreaterThan({}): {}\n", .{ threshold, has_large });
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_any)) / 1_000_000.0});

    // allLessThan - vectorized range check
    const upper_bound: i64 = @intCast(n + 1);
    const start_all = std.time.nanoTimestamp();
    const all_in_range = simd.allLessThan(i64, data, upper_bound);
    const elapsed_all = std.time.nanoTimestamp() - start_all;

    print("  allLessThan({}): {}\n", .{ upper_bound, all_in_range });
    print("  Time: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed_all)) / 1_000_000.0});
}

// ============================================================================
// Example 4: Parallel SIMD (Multi-threaded + Vectorized)
// ============================================================================

fn example4_parallel_simd() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 4: Parallel SIMD
        \\ Combining multi-threading with SIMD for maximum throughput
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 100_000_000; // 100M elements

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @intCast(i % 1000); // Values 0-999
    }
    data[50_000_000] = -1; // Put minimum in the middle

    const simd = blitz.simd_mod;

    // Parallel SIMD sum - divides work across threads, each using SIMD
    const start_sum = std.time.nanoTimestamp();
    const par_sum = simd.parallelSum(i64, data);
    const elapsed_sum = std.time.nanoTimestamp() - start_sum;

    print("  Parallel SIMD sum of {}M elements: {}\n", .{ n / 1_000_000, par_sum });
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_sum)) / 1_000_000.0});
    print("  Throughput: {d:.1} billion elements/sec\n", .{
        @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed_sum)) / 1_000_000_000.0) / 1_000_000_000.0,
    });

    // Parallel SIMD min
    const start_min = std.time.nanoTimestamp();
    const par_min = simd.parallelMin(i64, data);
    const elapsed_min = std.time.nanoTimestamp() - start_min;

    print("  Parallel SIMD min: {?}\n", .{par_min});
    print("  Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_min)) / 1_000_000.0});

    // Parallel SIMD argmin
    const start_argmin = std.time.nanoTimestamp();
    const par_argmin = simd.parallelArgmin(i64, data);
    const elapsed_argmin = std.time.nanoTimestamp() - start_argmin;

    if (par_argmin) |r| {
        print("  Parallel SIMD argmin: value={}, index={}\n", .{ r.value, r.index });
        print("  Correct: {}\n", .{r.index == 50_000_000});
    }
    print("  Time: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(elapsed_argmin)) / 1_000_000.0});
}

// ============================================================================
// Example 5: Performance Comparison
// ============================================================================

fn example5_performance_comparison() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 5: Performance Comparison
        \\ Scalar vs SIMD vs Parallel SIMD
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 50_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    const simd = blitz.simd_mod;

    // Scalar sum
    const start_scalar = std.time.nanoTimestamp();
    var scalar_sum: i64 = 0;
    for (data) |v| {
        scalar_sum += v;
    }
    const elapsed_scalar = std.time.nanoTimestamp() - start_scalar;

    // SIMD sum (single-threaded)
    const start_simd = std.time.nanoTimestamp();
    const simd_sum = simd.sum(i64, data);
    const elapsed_simd = std.time.nanoTimestamp() - start_simd;

    // Parallel SIMD sum (multi-threaded + vectorized)
    const start_par = std.time.nanoTimestamp();
    const par_sum = simd.parallelSum(i64, data);
    const elapsed_par = std.time.nanoTimestamp() - start_par;

    print("  Data size: {}M elements\n\n", .{n / 1_000_000});

    print("  Scalar sum:        {d:>8.2} ms\n", .{@as(f64, @floatFromInt(elapsed_scalar)) / 1_000_000.0});
    print("  SIMD sum:          {d:>8.2} ms ({d:.1}x faster)\n", .{
        @as(f64, @floatFromInt(elapsed_simd)) / 1_000_000.0,
        @as(f64, @floatFromInt(elapsed_scalar)) / @as(f64, @floatFromInt(elapsed_simd)),
    });
    print("  Parallel SIMD sum: {d:>8.2} ms ({d:.1}x faster)\n", .{
        @as(f64, @floatFromInt(elapsed_par)) / 1_000_000.0,
        @as(f64, @floatFromInt(elapsed_scalar)) / @as(f64, @floatFromInt(elapsed_par)),
    });

    print("\n  Results match: {}\n", .{scalar_sum == simd_sum and simd_sum == par_sum});

    // Throughput comparison
    print("\n  Throughput:\n", .{});
    print("    Scalar:        {d:>5.2} billion elements/sec\n", .{
        @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed_scalar)) / 1_000_000_000.0) / 1_000_000_000.0,
    });
    print("    SIMD:          {d:>5.2} billion elements/sec\n", .{
        @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed_simd)) / 1_000_000_000.0) / 1_000_000_000.0,
    });
    print("    Parallel SIMD: {d:>5.2} billion elements/sec\n\n", .{
        @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed_par)) / 1_000_000_000.0) / 1_000_000_000.0,
    });
}
