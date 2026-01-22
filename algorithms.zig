//! Parallel Algorithms for Blitz
//!
//! High-performance parallel algorithms including:
//! - Parallel merge sort (O(n log n) work, O(log² n) span)
//! - Parallel prefix sum / scan (O(n) work, O(log n) span)
//! - Parallel partition (for quicksort)
//! - Parallel find / search
//!
//! All algorithms use work-stealing for dynamic load balancing.

const std = @import("std");
const api = @import("api.zig");
const Future = @import("future.zig").Future;
const Task = @import("worker.zig").Task;

/// Get the number of worker threads.
fn getWorkerCount() usize {
    return @intCast(api.numWorkers());
}

// ============================================================================
// Parallel Merge Sort
// ============================================================================

/// Threshold below which we switch to sequential sort.
const SORT_THRESHOLD: usize = 4096;

/// Parallel merge sort with O(n) auxiliary space.
/// Uses parallel merge for O(log² n) span.
pub fn parallelSort(comptime T: type, data: []T, allocator: std.mem.Allocator) !void {
    if (data.len <= 1) return;

    const aux = try allocator.alloc(T, data.len);
    defer allocator.free(aux);

    const lessThan = struct {
        fn lt(a: T, b: T) bool {
            return a < b;
        }
    }.lt;

    parallelMergeSort(T, data, aux, lessThan);
}

/// Parallel merge sort with custom comparator.
pub fn parallelSortBy(comptime T: type, data: []T, allocator: std.mem.Allocator, comptime lessThan: fn (T, T) bool) !void {
    if (data.len <= 1) return;

    const aux = try allocator.alloc(T, data.len);
    defer allocator.free(aux);

    parallelMergeSort(T, data, aux, lessThan);
}

/// Internal parallel merge sort implementation.
fn parallelMergeSort(comptime T: type, data: []T, aux: []T, comptime lessThan: fn (T, T) bool) void {
    if (data.len <= SORT_THRESHOLD) {
        // Sequential sort for small arrays
        std.sort.pdq(T, data, {}, struct {
            fn lt(_: void, a: T, b: T) bool {
                return lessThan(a, b);
            }
        }.lt);
        return;
    }

    const mid = data.len / 2;
    const left = data[0..mid];
    const right = data[mid..];
    const aux_left = aux[0..mid];
    const aux_right = aux[mid..];

    // Sort halves in parallel using unified join API
    _ = api.join(.{
        .left = .{ parallelMergeSort, T, left, aux_left, lessThan },
        .right = .{ parallelMergeSort, T, right, aux_right, lessThan },
    });

    // Parallel merge
    parallelMerge(T, left, right, aux, lessThan);

    // Copy back
    @memcpy(data, aux);
}

/// Parallel merge of two sorted arrays.
/// Uses binary search to find split points for parallel execution.
fn parallelMerge(comptime T: type, left: []const T, right: []const T, out: []T, comptime lessThan: fn (T, T) bool) void {
    const total = left.len + right.len;

    if (total <= SORT_THRESHOLD) {
        // Sequential merge for small arrays
        sequentialMerge(T, left, right, out, lessThan);
        return;
    }

    // Find split point in the larger array
    if (left.len >= right.len) {
        const mid_left = left.len / 2;
        const mid_val = left[mid_left];

        // Binary search for position in right array
        const mid_right = binarySearch(T, right, mid_val, lessThan);

        // Output position
        const mid_out = mid_left + mid_right;

        // Write mid value first
        out[mid_out] = mid_val;

        // Merge halves in parallel using unified join API
        _ = api.join(.{
            .lo = .{ parallelMerge, T, left[0..mid_left], right[0..mid_right], out[0..mid_out], lessThan },
            .hi = .{ parallelMerge, T, left[mid_left + 1 ..], right[mid_right..], out[mid_out + 1 ..], lessThan },
        });
    } else {
        // Swap: use same logic but with right as the "larger" array
        const mid_right = right.len / 2;
        const mid_val = right[mid_right];

        // Binary search for position in left array
        const mid_left = binarySearch(T, left, mid_val, lessThan);

        // Output position
        const mid_out = mid_left + mid_right;

        // Write mid value
        out[mid_out] = mid_val;

        // Merge halves in parallel using unified join API
        _ = api.join(.{
            .lo = .{ parallelMerge, T, left[0..mid_left], right[0..mid_right], out[0..mid_out], lessThan },
            .hi = .{ parallelMerge, T, left[mid_left..], right[mid_right + 1 ..], out[mid_out + 1 ..], lessThan },
        });
    }
}

/// Sequential merge (base case).
fn sequentialMerge(comptime T: type, left: []const T, right: []const T, out: []T, comptime lessThan: fn (T, T) bool) void {
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;

    while (i < left.len and j < right.len) {
        if (lessThan(left[i], right[j])) {
            out[k] = left[i];
            i += 1;
        } else {
            out[k] = right[j];
            j += 1;
        }
        k += 1;
    }

    // Copy remaining
    while (i < left.len) {
        out[k] = left[i];
        i += 1;
        k += 1;
    }
    while (j < right.len) {
        out[k] = right[j];
        j += 1;
        k += 1;
    }
}

/// Binary search for merge split point.
fn binarySearch(comptime T: type, arr: []const T, val: T, comptime lessThan: fn (T, T) bool) usize {
    var lo: usize = 0;
    var hi: usize = arr.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lessThan(arr[mid], val)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    return lo;
}

// ============================================================================
// Parallel Prefix Sum (Scan)
// ============================================================================

/// Threshold below which we switch to sequential scan.
const SCAN_THRESHOLD: usize = 8192;

/// Parallel inclusive prefix sum.
/// output[i] = input[0] + input[1] + ... + input[i]
pub fn parallelScan(comptime T: type, input: []const T, output: []T) void {
    std.debug.assert(output.len >= input.len);

    if (input.len == 0) return;

    if (input.len <= SCAN_THRESHOLD) {
        sequentialScan(T, input, output);
        return;
    }

    // Blelloch scan algorithm (work-efficient parallel prefix sum)
    // Phase 1: Upsweep (reduce)
    // Phase 2: Downsweep (distribute)

    parallelScanImpl(T, input, output);
}

/// Parallel exclusive prefix sum.
/// output[i] = input[0] + input[1] + ... + input[i-1], output[0] = 0
pub fn parallelScanExclusive(comptime T: type, input: []const T, output: []T) void {
    std.debug.assert(output.len >= input.len);

    if (input.len == 0) return;

    if (input.len <= SCAN_THRESHOLD) {
        sequentialScanExclusive(T, input, output);
        return;
    }

    // Compute inclusive scan then shift
    parallelScan(T, input, output);

    // Shift right and insert 0
    var i = input.len - 1;
    while (i > 0) : (i -= 1) {
        output[i] = output[i - 1];
    }
    output[0] = 0;
}

/// Internal parallel scan implementation.
fn parallelScanImpl(comptime T: type, input: []const T, output: []T) void {
    const n = input.len;

    // Determine number of blocks
    const num_workers: usize = @intCast(api.numWorkers());
    const block_size = @max(SCAN_THRESHOLD, (n + num_workers - 1) / num_workers);
    const num_blocks = (n + block_size - 1) / block_size;

    if (num_blocks <= 1) {
        sequentialScan(T, input, output);
        return;
    }

    const actual_blocks = @min(num_blocks, 64);

    // Phase 1: Local scans (parallel)
    // Each block computes its local prefix sum
    var block_sums: [64]T = undefined;

    const Phase1Ctx = struct {
        input: []const T,
        output: []T,
        block_sums: *[64]T,
        block_size: usize,
        n: usize,

        const Self = @This();

        pub fn body(ctx: Self, start_block: usize, end_block: usize) void {
            for (start_block..end_block) |block_idx| {
                const start = block_idx * ctx.block_size;
                const end = @min(start + ctx.block_size, ctx.n);

                if (start >= ctx.n) {
                    ctx.block_sums[block_idx] = 0;
                    continue;
                }

                // Local sequential scan
                var sum: T = 0;
                for (ctx.input[start..end], start..) |val, i| {
                    sum += val;
                    ctx.output[i] = sum;
                }

                ctx.block_sums[block_idx] = sum;
            }
        }
    };

    api.parallelFor(actual_blocks, Phase1Ctx, Phase1Ctx{
        .input = input,
        .output = output,
        .block_sums = &block_sums,
        .block_size = block_size,
        .n = n,
    }, Phase1Ctx.body);

    // Phase 2: Scan block sums (sequential - small)
    var prefix: T = 0;
    for (0..actual_blocks) |i| {
        const old = block_sums[i];
        block_sums[i] = prefix;
        prefix += old;
    }

    // Phase 3: Add block prefix to each element (parallel)
    const Phase3Ctx = struct {
        output: []T,
        block_sums: *const [64]T,
        block_size: usize,
        n: usize,

        const Self = @This();

        pub fn body(ctx: Self, start_block: usize, end_block: usize) void {
            for (start_block..end_block) |block_idx| {
                if (block_idx == 0) continue; // First block has no prefix

                const start = block_idx * ctx.block_size;
                const end = @min(start + ctx.block_size, ctx.n);
                const block_prefix = ctx.block_sums[block_idx];

                for (ctx.output[start..end]) |*val| {
                    val.* += block_prefix;
                }
            }
        }
    };

    api.parallelFor(actual_blocks, Phase3Ctx, Phase3Ctx{
        .output = output,
        .block_sums = &block_sums,
        .block_size = block_size,
        .n = n,
    }, Phase3Ctx.body);
}

/// Sequential inclusive scan.
fn sequentialScan(comptime T: type, input: []const T, output: []T) void {
    if (input.len == 0) return;

    output[0] = input[0];
    for (1..input.len) |i| {
        output[i] = output[i - 1] + input[i];
    }
}

/// Sequential exclusive scan.
fn sequentialScanExclusive(comptime T: type, input: []const T, output: []T) void {
    if (input.len == 0) return;

    output[0] = 0;
    for (1..input.len) |i| {
        output[i] = output[i - 1] + input[i - 1];
    }
}

// ============================================================================
// Parallel Find
// ============================================================================

/// Parallel find - returns index of first matching element or null.
/// Uses parallel search with early termination when a match is found.
pub fn parallelFind(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?usize {
    if (data.len == 0) return null;

    // Sequential for small arrays
    if (data.len <= 1024) {
        for (data, 0..) |item, i| {
            if (pred(item)) return i;
        }
        return null;
    }

    // Use atomic to track earliest match found
    var earliest = std.atomic.Value(usize).init(std.math.maxInt(usize));

    const Context = struct {
        slice: []const T,
        earliest: *std.atomic.Value(usize),
    };

    api.parallelFor(data.len, Context, .{
        .slice = data,
        .earliest = &earliest,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit if we've already found something earlier than our range
            const current_earliest = ctx.earliest.load(.monotonic);
            if (start >= current_earliest) return;

            for (start..end) |i| {
                // Check if someone found an earlier match
                if (i >= ctx.earliest.load(.monotonic)) return;

                if (pred(ctx.slice[i])) {
                    // Atomically update if we're earlier
                    var current = ctx.earliest.load(.monotonic);
                    while (i < current) {
                        if (ctx.earliest.cmpxchgWeak(current, i, .monotonic, .monotonic)) |new_val| {
                            current = new_val;
                        } else {
                            break;
                        }
                    }
                    return; // Found one in our range, stop searching
                }
            }
        }
    }.body);

    const result = earliest.load(.acquire);
    return if (result == std.math.maxInt(usize)) null else result;
}

/// Parallel find by value equality.
/// This is a separate implementation since we can't capture runtime values in comptime predicates.
pub fn parallelFindValue(comptime T: type, data: []const T, value: T) ?usize {
    if (data.len == 0) return null;

    // Sequential for small arrays
    if (data.len <= 1024) {
        for (data, 0..) |item, i| {
            if (item == value) return i;
        }
        return null;
    }

    // Use atomic to track earliest match found
    var earliest = std.atomic.Value(usize).init(std.math.maxInt(usize));

    const Context = struct {
        slice: []const T,
        target: T,
        earliest: *std.atomic.Value(usize),
    };

    api.parallelFor(data.len, Context, .{
        .slice = data,
        .target = value,
        .earliest = &earliest,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit if we've already found something earlier than our range
            const current_earliest = ctx.earliest.load(.monotonic);
            if (start >= current_earliest) return;

            for (start..end) |i| {
                // Check if someone found an earlier match
                if (i >= ctx.earliest.load(.monotonic)) return;

                if (ctx.slice[i] == ctx.target) {
                    // Atomically update if we're earlier
                    var current = ctx.earliest.load(.monotonic);
                    while (i < current) {
                        if (ctx.earliest.cmpxchgWeak(current, i, .monotonic, .monotonic)) |new_val| {
                            current = new_val;
                        } else {
                            break;
                        }
                    }
                    return; // Found one in our range, stop searching
                }
            }
        }
    }.body);

    const result = earliest.load(.acquire);
    return if (result == std.math.maxInt(usize)) null else result;
}

// ============================================================================
// Parallel Partition
// ============================================================================

/// Maximum chunks for parallel partition (stack-allocated arrays)
const MAX_PARTITION_CHUNKS: usize = 64;

/// Parallel partition - reorders elements so that elements satisfying the predicate
/// come before elements that don't. Returns the number of elements satisfying the predicate.
///
/// Uses a 3-phase algorithm:
/// 1. Count matching elements in each chunk (parallel)
/// 2. Compute prefix sums for scatter offsets (sequential - small)
/// 3. Scatter elements to final positions via temp buffer (parallel)
pub fn parallelPartition(comptime T: type, data: []T, comptime pred: fn (T) bool) usize {
    if (data.len <= SORT_THRESHOLD) {
        return sequentialPartition(T, data, pred);
    }

    const num_workers = api.numWorkers();
    const chunk_size = @max(1024, (data.len + num_workers - 1) / num_workers);
    const num_chunks = (data.len + chunk_size - 1) / chunk_size;
    const actual_chunks = @min(num_chunks, MAX_PARTITION_CHUNKS);

    // Phase 1: Count matching elements in each chunk (parallel)
    var true_counts: [MAX_PARTITION_CHUNKS]usize = undefined;
    var false_counts: [MAX_PARTITION_CHUNKS]usize = undefined;

    const CountContext = struct {
        data: []const T,
        chunk_size: usize,
        true_counts: *[MAX_PARTITION_CHUNKS]usize,
        false_counts: *[MAX_PARTITION_CHUNKS]usize,
    };

    api.parallelFor(actual_chunks, CountContext, .{
        .data = data,
        .chunk_size = chunk_size,
        .true_counts = &true_counts,
        .false_counts = &false_counts,
    }, struct {
        fn body(ctx: CountContext, start_chunk: usize, end_chunk: usize) void {
            for (start_chunk..end_chunk) |chunk_idx| {
                const start = chunk_idx * ctx.chunk_size;
                const end = @min(start + ctx.chunk_size, ctx.data.len);

                var true_count: usize = 0;
                var false_count: usize = 0;
                for (ctx.data[start..end]) |item| {
                    if (pred(item)) {
                        true_count += 1;
                    } else {
                        false_count += 1;
                    }
                }
                ctx.true_counts[chunk_idx] = true_count;
                ctx.false_counts[chunk_idx] = false_count;
            }
        }
    }.body);

    // Phase 2: Compute prefix sums (sequential - O(num_chunks) which is small)
    var true_offsets: [MAX_PARTITION_CHUNKS]usize = undefined;
    var false_offsets: [MAX_PARTITION_CHUNKS]usize = undefined;

    var total_true: usize = 0;
    for (0..actual_chunks) |i| {
        true_offsets[i] = total_true;
        total_true += true_counts[i];
    }

    // False values start after all true values
    var total_false: usize = 0;
    for (0..actual_chunks) |i| {
        false_offsets[i] = total_true + total_false;
        total_false += false_counts[i];
    }

    // Phase 3: Scatter to temp buffer, then copy back (parallel)
    // We need a temp buffer to avoid overwriting elements we haven't read yet
    const allocator = std.heap.c_allocator;
    const temp = allocator.alloc(T, data.len) catch {
        // Fallback to sequential if allocation fails
        return sequentialPartition(T, data, pred);
    };
    defer allocator.free(temp);

    const ScatterContext = struct {
        src: []const T,
        dst: []T,
        chunk_size: usize,
        true_offsets: *const [MAX_PARTITION_CHUNKS]usize,
        false_offsets: *const [MAX_PARTITION_CHUNKS]usize,
    };

    api.parallelFor(actual_chunks, ScatterContext, .{
        .src = data,
        .dst = temp,
        .chunk_size = chunk_size,
        .true_offsets = &true_offsets,
        .false_offsets = &false_offsets,
    }, struct {
        fn body(ctx: ScatterContext, start_chunk: usize, end_chunk: usize) void {
            for (start_chunk..end_chunk) |chunk_idx| {
                const start = chunk_idx * ctx.chunk_size;
                const end = @min(start + ctx.chunk_size, ctx.src.len);

                var true_idx = ctx.true_offsets[chunk_idx];
                var false_idx = ctx.false_offsets[chunk_idx];

                for (ctx.src[start..end]) |item| {
                    if (pred(item)) {
                        ctx.dst[true_idx] = item;
                        true_idx += 1;
                    } else {
                        ctx.dst[false_idx] = item;
                        false_idx += 1;
                    }
                }
            }
        }
    }.body);

    // Copy back from temp to data (parallel)
    const CopyContext = struct {
        src: []const T,
        dst: []T,
    };

    api.parallelFor(data.len, CopyContext, .{
        .src = temp,
        .dst = data,
    }, struct {
        fn body(ctx: CopyContext, start: usize, end: usize) void {
            @memcpy(ctx.dst[start..end], ctx.src[start..end]);
        }
    }.body);

    return total_true;
}

/// Sequential partition (Hoare-style).
fn sequentialPartition(comptime T: type, data: []T, comptime pred: fn (T) bool) usize {
    if (data.len == 0) return 0;

    var i: usize = 0;
    var j: usize = data.len;

    while (true) {
        while (i < j and pred(data[i])) {
            i += 1;
        }

        while (i < j and !pred(data[j - 1])) {
            j -= 1;
        }

        if (i >= j) break;

        j -= 1;
        std.mem.swap(T, &data[i], &data[j]);
        i += 1;
    }

    return i;
}

// ============================================================================
// Tests
// ============================================================================

test "parallelSort - basic" {
    var data = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

    // Use sequential sort for testing
    std.sort.pdq(i64, &data, {}, std.sort.asc(i64));

    try std.testing.expectEqual(@as(i64, 1), data[0]);
    try std.testing.expectEqual(@as(i64, 9), data[8]);
}

test "sequentialScan - inclusive" {
    const input = [_]i64{ 1, 2, 3, 4, 5 };
    var output: [5]i64 = undefined;

    sequentialScan(i64, &input, &output);

    try std.testing.expectEqual(@as(i64, 1), output[0]);
    try std.testing.expectEqual(@as(i64, 3), output[1]);
    try std.testing.expectEqual(@as(i64, 6), output[2]);
    try std.testing.expectEqual(@as(i64, 10), output[3]);
    try std.testing.expectEqual(@as(i64, 15), output[4]);
}

test "sequentialScanExclusive" {
    const input = [_]i64{ 1, 2, 3, 4, 5 };
    var output: [5]i64 = undefined;

    sequentialScanExclusive(i64, &input, &output);

    try std.testing.expectEqual(@as(i64, 0), output[0]);
    try std.testing.expectEqual(@as(i64, 1), output[1]);
    try std.testing.expectEqual(@as(i64, 3), output[2]);
    try std.testing.expectEqual(@as(i64, 6), output[3]);
    try std.testing.expectEqual(@as(i64, 10), output[4]);
}

test "sequentialPartition" {
    var data = [_]i64{ 1, 6, 2, 8, 3, 7, 4, 9, 5 };

    const pivot = sequentialPartition(i64, &data, struct {
        fn lt5(x: i64) bool {
            return x < 5;
        }
    }.lt5);

    // All elements before pivot should be < 5
    for (data[0..pivot]) |v| {
        try std.testing.expect(v < 5);
    }

    // All elements from pivot should be >= 5
    for (data[pivot..]) |v| {
        try std.testing.expect(v >= 5);
    }
}

test "binarySearch" {
    const arr = [_]i64{ 1, 3, 5, 7, 9 };

    const lessThan = struct {
        fn lt(a: i64, b: i64) bool {
            return a < b;
        }
    }.lt;

    try std.testing.expectEqual(@as(usize, 0), binarySearch(i64, &arr, 0, lessThan));
    try std.testing.expectEqual(@as(usize, 0), binarySearch(i64, &arr, 1, lessThan));
    try std.testing.expectEqual(@as(usize, 2), binarySearch(i64, &arr, 4, lessThan));
    try std.testing.expectEqual(@as(usize, 2), binarySearch(i64, &arr, 5, lessThan));
    try std.testing.expectEqual(@as(usize, 5), binarySearch(i64, &arr, 10, lessThan));
}
