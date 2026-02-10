//! Parallel Stable Sort (TimSort-based Merge Sort)
//!
//! A stable, parallel sorting algorithm that maintains relative order of equal elements.
//! Parallel merge sort adapted from Tim Peters' TimSort.
//!
//! Features:
//! - Stability: equal elements maintain their original relative order
//! - Adaptive: exploits existing sorted runs in the data
//! - Parallel: uses fork-join for parallel chunk sorting and merging
//! - Memory: allocates O(n) temporary buffer
//!
//! Time: O(n log n) worst-case
//! Space: O(n) temporary buffer
//!
//! Reference: https://github.com/rayon-rs/rayon/blob/main/src/slice/sort.rs (original implementation)

const std = @import("std");
const blitz = @import("../api.zig");
const helpers = @import("helpers.zig");

// ============================================================================
// Configuration Constants
// ============================================================================

/// Length at which we switch to insertion sort
const MAX_INSERTION: usize = 20;

/// Minimum length of a TimSort run after extension
const MIN_RUN: usize = 10;

/// Chunk length for parallel processing
const CHUNK_LENGTH: usize = 2000;

/// Maximum sequential merge size
const MAX_SEQUENTIAL_MERGE: usize = 5000;

// ============================================================================
// Run Tracking
// ============================================================================

/// A run of sorted elements
const TimSortRun = struct {
    start: usize,
    len: usize,
};

/// Result of merge sort on a chunk
const MergeSortResult = enum {
    /// Already sorted in non-descending order
    non_descending,
    /// Was sorted in descending order (needs reversal)
    descending,
    /// Was sorted by the algorithm
    sorted,
};

// ============================================================================
// Run Detection
// ============================================================================

/// Finds a streak of presorted elements starting at the beginning.
/// Returns the length of the streak and whether it was reversed (descending).
fn findStreak(comptime T: type, v: []const T, comptime is_less: fn (T, T) bool) struct { len: usize, was_reversed: bool } {
    const len = v.len;

    if (len < 2) {
        return .{ .len = len, .was_reversed = false };
    }

    var end: usize = 2;

    // Check if descending
    if (is_less(v[1], v[0])) {
        // Strictly descending
        while (end < len and is_less(v[end], v[end - 1])) {
            end += 1;
        }
        return .{ .len = end, .was_reversed = true };
    } else {
        // Non-descending
        while (end < len and !is_less(v[end], v[end - 1])) {
            end += 1;
        }
        return .{ .len = end, .was_reversed = false };
    }
}

/// Extends a sorted run using insertion sort to meet MIN_RUN.
fn provideSortedBatch(comptime T: type, v: []T, start: usize, end_in: usize, comptime is_less: fn (T, T) bool) usize {
    const len = v.len;
    var end = end_in;

    const diff = end - start;

    if (diff < MIN_RUN and end < len) {
        // Extend the run to MIN_RUN elements
        end = @min(start + MIN_RUN, len);
        const presorted_start = if (diff > 1) diff else 1;
        helpers.insertionSortShiftLeft(T, v[start..end], presorted_start, is_less);
    }

    return end;
}

// ============================================================================
// Merge Operations
// ============================================================================

/// Merges two sorted runs: v[..mid] and v[mid..] using buf as scratch.
/// The shorter run is copied to buf, then elements are merged back.
fn merge(comptime T: type, v: []T, mid: usize, buf: [*]T, comptime is_less: fn (T, T) bool) void {
    const len = v.len;
    std.debug.assert(mid > 0 and mid < len);

    if (mid <= len - mid) {
        // Left run is shorter - copy it to buffer
        @memcpy(buf[0..mid], v[0..mid]);

        var left: usize = 0;
        var right: usize = mid;
        var out: usize = 0;

        while (left < mid and right < len) {
            // If right < left, take from right; otherwise take from left (stability)
            if (is_less(v[right], buf[left])) {
                v[out] = v[right];
                right += 1;
            } else {
                v[out] = buf[left];
                left += 1;
            }
            out += 1;
        }

        // Copy remaining left elements
        if (left < mid) {
            @memcpy(v[out..][0 .. mid - left], buf[left..mid]);
        }
        // Right elements are already in place
    } else {
        // Right run is shorter - copy it to buffer
        const right_len = len - mid;
        @memcpy(buf[0..right_len], v[mid..len]);

        var left = mid;
        var right = right_len;
        var out = len;

        while (left > 0 and right > 0) {
            // Working backwards for stability
            if (is_less(buf[right - 1], v[left - 1])) {
                out -= 1;
                left -= 1;
                v[out] = v[left];
            } else {
                out -= 1;
                right -= 1;
                v[out] = buf[right];
            }
        }

        // Copy remaining right elements
        if (right > 0) {
            @memcpy(v[0..right], buf[0..right]);
        }
        // Left elements are already in place
    }
}

/// Determines which pair of runs to merge next based on Tim's invariants.
/// Returns the index of the run to merge with run+1, or null if no merge needed.
fn collapse(runs: []const TimSortRun, stop: usize) ?usize {
    const n = runs.len;
    if (n < 2) return null;

    // Tim's invariants on top 4 runs:
    // 1. runs[n-1] + runs[n-2] < runs[n-3]
    // 2. runs[n-2] < runs[n-3]
    const should_collapse = blk: {
        // Force merge if we've reached the end
        if (runs[n - 1].start + runs[n - 1].len == stop) break :blk true;

        // Check invariant 2
        if (runs[n - 2].len <= runs[n - 1].len) break :blk true;

        // Check invariant 1 for top 3
        if (n >= 3 and runs[n - 3].len <= runs[n - 2].len + runs[n - 1].len) break :blk true;

        // Check invariant 1 for top 4
        if (n >= 4 and runs[n - 4].len <= runs[n - 3].len + runs[n - 2].len) break :blk true;

        break :blk false;
    };

    if (!should_collapse) return null;

    // Choose which pair to merge
    if (n >= 3 and runs[n - 3].len < runs[n - 1].len) {
        return n - 3;
    } else {
        return n - 2;
    }
}

/// Sequential TimSort for a single chunk.
fn mergeSort(comptime T: type, v: []T, buf: [*]T, comptime is_less: fn (T, T) bool) MergeSortResult {
    const len = v.len;
    if (len < 2) return .non_descending;

    const allocator = std.heap.page_allocator;
    var runs: std.ArrayListUnmanaged(TimSortRun) = .{};
    defer runs.deinit(allocator);

    var start: usize = 0;
    var end: usize = 0;

    while (end < len) {
        const streak = findStreak(T, v[start..], is_less);
        end = start + streak.len;

        // Check if entire array is one run
        if (start == 0 and end == len) {
            if (streak.was_reversed) {
                return .descending;
            } else {
                return .non_descending;
            }
        }

        if (streak.was_reversed) {
            std.mem.reverse(T, v[start..end]);
        }

        // Extend short runs using insertion sort
        end = provideSortedBatch(T, v, start, end, is_less);

        // Push run onto stack
        runs.append(allocator, .{ .start = start, .len = end - start }) catch unreachable;
        start = end;

        // Merge runs to maintain invariants
        while (collapse(runs.items, len)) |r| {
            const left = runs.items[r];
            const right = runs.items[r + 1];
            const merge_slice = v[left.start .. right.start + right.len];
            merge(T, merge_slice, left.len, buf, is_less);

            runs.items[r + 1] = .{
                .start = left.start,
                .len = left.len + right.len,
            };
            _ = runs.orderedRemove(r);
        }
    }

    // Final merge pass
    while (runs.items.len > 1) {
        const r = runs.items.len - 2;
        const left = runs.items[r];
        const right = runs.items[r + 1];
        const merge_slice = v[left.start .. right.start + right.len];
        merge(T, merge_slice, left.len, buf, is_less);

        runs.items[r] = .{
            .start = left.start,
            .len = left.len + right.len,
        };
        _ = runs.pop();
    }

    return .sorted;
}

// ============================================================================
// Parallel Merge
// ============================================================================

/// Splits two sorted slices at a point where they can be merged in parallel.
/// Returns (left_split, right_split) where left[..left_split] and right[..right_split]
/// come before left[left_split..] and right[right_split..].
fn splitForMerge(comptime T: type, left: []const T, right: []const T, comptime is_less: fn (T, T) bool) struct { usize, usize } {
    const left_len = left.len;
    const right_len = right.len;

    if (left_len >= right_len) {
        const left_mid = left_len / 2;

        // Binary search: find first element in right >= left[left_mid]
        var a: usize = 0;
        var b: usize = right_len;
        while (a < b) {
            const m = a + (b - a) / 2;
            if (is_less(right[m], left[left_mid])) {
                a = m + 1;
            } else {
                b = m;
            }
        }

        return .{ left_mid, a };
    } else {
        const right_mid = right_len / 2;

        // Binary search: find first element in left > right[right_mid]
        var a: usize = 0;
        var b: usize = left_len;
        while (a < b) {
            const m = a + (b - a) / 2;
            if (is_less(right[right_mid], left[m])) {
                b = m;
            } else {
                a = m + 1;
            }
        }

        return .{ a, right_mid };
    }
}

/// Parallel merge: merges left and right into dest.
fn parMerge(comptime T: type, left: []T, right: []T, dest: [*]T, comptime is_less: fn (T, T) bool) void {
    const left_len = left.len;
    const right_len = right.len;

    // Sequential merge for small sizes
    if (left_len == 0) {
        @memcpy(dest[0..right_len], right);
        return;
    }
    if (right_len == 0) {
        @memcpy(dest[0..left_len], left);
        return;
    }
    if (left_len + right_len <= MAX_SEQUENTIAL_MERGE) {
        // Sequential merge
        var l: usize = 0;
        var r: usize = 0;
        var out: usize = 0;

        while (l < left_len and r < right_len) {
            if (is_less(right[r], left[l])) {
                dest[out] = right[r];
                r += 1;
            } else {
                dest[out] = left[l];
                l += 1;
            }
            out += 1;
        }

        // Copy remaining
        if (l < left_len) {
            @memcpy(dest[out..][0 .. left_len - l], left[l..]);
        } else if (r < right_len) {
            @memcpy(dest[out..][0 .. right_len - r], right[r..]);
        }
        return;
    }

    // Parallel merge using unified join API
    const split = splitForMerge(T, left, right, is_less);
    const left_split = split[0];
    const right_split = split[1];

    _ = blitz.join(.{
        .lo = .{ parMerge, T, @constCast(left[0..left_split]), @constCast(right[0..right_split]), dest, is_less },
        .hi = .{ parMerge, T, @constCast(left[left_split..]), @constCast(right[right_split..]), dest + left_split + right_split, is_less },
    });
}

/// Recursively merges pre-sorted chunks.
/// If into_buf is true, result goes into buf; otherwise into v.
fn mergeRecurse(
    comptime T: type,
    v: [*]T,
    buf: [*]T,
    chunks: []const struct { usize, usize },
    into_buf: bool,
    comptime is_less: fn (T, T) bool,
) void {
    const len = chunks.len;
    std.debug.assert(len > 0);

    // Base case: single chunk
    if (len == 1) {
        if (into_buf) {
            const start = chunks[0][0];
            const end = chunks[0][1];
            @memcpy(buf[start..end], v[start..end]);
        }
        return;
    }

    // Split chunks in half
    const start = chunks[0][0];
    const mid = chunks[len / 2][0];
    const end = chunks[len - 1][1];

    const left_chunks = chunks[0 .. len / 2];
    const right_chunks = chunks[len / 2 ..];

    // Source and destination alternate at each level
    const src: [*]T = if (into_buf) v else buf;
    const dest: [*]T = if (into_buf) buf else v;

    // Recursively process both halves in parallel using unified join API
    // Note: child calls get !into_buf, so we pass that flag
    const child_into_buf = !into_buf;

    _ = blitz.join(.{
        .left = .{ mergeRecurse, T, v, buf, left_chunks, child_into_buf, is_less },
        .right = .{ mergeRecurse, T, v, buf, right_chunks, child_into_buf, is_less },
    });

    // Merge the two halves
    const src_left = src[start..mid];
    const src_right = src[mid..end];
    parMerge(T, @constCast(src_left), @constCast(src_right), dest + start, is_less);
}

// ============================================================================
// Public API
// ============================================================================

/// Sorts `v` in-place using a stable, parallel merge sort.
///
/// This is a stable sort: equal elements maintain their relative order.
/// Allocates O(n) temporary memory.
///
/// Time: O(n log n) worst-case
/// Space: O(n) temporary buffer
pub fn stableSort(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) void {
    // Zero-sized types need no sorting
    if (@sizeOf(T) == 0) return;

    const len = v.len;
    if (len <= 1) return;

    // Short slices use insertion sort
    if (len <= MAX_INSERTION) {
        helpers.insertionSortShiftLeft(T, v, 1, is_less);
        return;
    }

    // Allocate temporary buffer
    const allocator = std.heap.page_allocator;
    const buf = allocator.alloc(T, len) catch {
        // Fallback to heapsort if allocation fails
        helpers.heapsort(T, v, is_less);
        return;
    };
    defer allocator.free(buf);

    // For small arrays, use sequential merge sort
    if (len <= CHUNK_LENGTH) {
        const result = mergeSort(T, v, buf.ptr, is_less);
        if (result == .descending) {
            std.mem.reverse(T, v);
        }
        return;
    }

    // Parallel: split into chunks and sort each
    const num_chunks = (len + CHUNK_LENGTH - 1) / CHUNK_LENGTH;

    // Sort chunks in parallel
    const ChunkResult = struct {
        start: usize,
        end: usize,
        result: MergeSortResult,
    };

    const chunk_results = allocator.alloc(ChunkResult, num_chunks) catch {
        // Fallback
        const result = mergeSort(T, v, buf.ptr, is_less);
        if (result == .descending) std.mem.reverse(T, v);
        return;
    };
    defer allocator.free(chunk_results);

    // Process chunks in parallel
    const Context = struct {
        v: []T,
        buf: [*]T,
        results: []ChunkResult,
    };

    blitz.parallelFor(num_chunks, Context, .{ .v = v, .buf = buf.ptr, .results = chunk_results }, struct {
        fn sortChunk(ctx: Context, chunk_start: usize, chunk_end: usize) void {
            for (chunk_start..chunk_end) |i| {
                const start = i * CHUNK_LENGTH;
                const end = @min(start + CHUNK_LENGTH, ctx.v.len);
                const chunk = ctx.v[start..end];
                const result = mergeSort(T, chunk, ctx.buf + start, is_less);
                ctx.results[i] = .{ .start = start, .end = end, .result = result };
            }
        }
    }.sortChunk);

    // Concatenate adjacent sorted chunks and reverse descending ones
    const ChunkBounds = struct { usize, usize };
    var chunks: std.ArrayListUnmanaged(ChunkBounds) = .{};
    defer chunks.deinit(allocator);

    var i: usize = 0;
    while (i < num_chunks) {
        const result = chunk_results[i];
        var end = result.end;

        // Concatenate adjacent chunks of the same type
        if (result.result != .sorted) {
            while (i + 1 < num_chunks) {
                const next = chunk_results[i + 1];
                if (next.result == result.result) {
                    // Check if they can be concatenated
                    const can_concat = if (result.result == .descending)
                        is_less(v[next.start], v[next.start - 1])
                    else
                        !is_less(v[next.start], v[next.start - 1]);

                    if (can_concat) {
                        end = next.end;
                        i += 1;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }
        }

        // Reverse descending chunks
        if (result.result == .descending) {
            std.mem.reverse(T, v[result.start..end]);
        }

        chunks.append(allocator, .{ result.start, end }) catch unreachable;
        i += 1;
    }

    // Merge all chunks
    if (chunks.items.len > 1) {
        mergeRecurse(T, v.ptr, buf.ptr, chunks.items, false, is_less);
    }
}

/// Sorts `v` in ascending order using a stable sort.
pub fn stableSortAsc(comptime T: type, v: []T) void {
    stableSort(T, v, struct {
        fn less(a: T, b: T) bool {
            return a < b;
        }
    }.less);
}

/// Sorts `v` in descending order using a stable sort.
pub fn stableSortDesc(comptime T: type, v: []T) void {
    stableSort(T, v, struct {
        fn less(a: T, b: T) bool {
            return a > b;
        }
    }.less);
}

// ============================================================================
// Tests
// ============================================================================

test "stableSort - empty" {
    var v: [0]i32 = .{};
    stableSortAsc(i32, &v);
}

test "stableSort - single element" {
    var v = [_]i32{42};
    stableSortAsc(i32, &v);
    try std.testing.expectEqual(@as(i32, 42), v[0]);
}

test "stableSort - two elements" {
    var v = [_]i32{ 2, 1 };
    stableSortAsc(i32, &v);
    try std.testing.expectEqual(@as(i32, 1), v[0]);
    try std.testing.expectEqual(@as(i32, 2), v[1]);
}

test "stableSort - small array" {
    var v = [_]i32{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    stableSortAsc(i32, &v);
    for (1..v.len) |i| {
        try std.testing.expect(v[i - 1] <= v[i]);
    }
}

test "stableSort - already sorted" {
    var v = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    stableSortAsc(i32, &v);
    for (0..v.len) |i| {
        try std.testing.expectEqual(@as(i32, @intCast(i + 1)), v[i]);
    }
}

test "stableSort - reverse sorted" {
    var v = [_]i32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    stableSortAsc(i32, &v);
    for (0..v.len) |i| {
        try std.testing.expectEqual(@as(i32, @intCast(i + 1)), v[i]);
    }
}

test "stableSort - duplicates" {
    var v = [_]i32{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
    stableSortAsc(i32, &v);
    for (1..v.len) |i| {
        try std.testing.expect(v[i - 1] <= v[i]);
    }
}

test "stableSort - stability" {
    // Test that equal elements maintain their relative order
    const Item = struct {
        key: i32,
        order: usize, // Original position
    };

    var items = [_]Item{
        .{ .key = 1, .order = 0 },
        .{ .key = 2, .order = 1 },
        .{ .key = 1, .order = 2 },
        .{ .key = 2, .order = 3 },
        .{ .key = 1, .order = 4 },
    };

    stableSort(Item, &items, struct {
        fn less(a: Item, b: Item) bool {
            return a.key < b.key;
        }
    }.less);

    // All 1s should come first, in original order
    try std.testing.expectEqual(@as(i32, 1), items[0].key);
    try std.testing.expectEqual(@as(usize, 0), items[0].order);
    try std.testing.expectEqual(@as(i32, 1), items[1].key);
    try std.testing.expectEqual(@as(usize, 2), items[1].order);
    try std.testing.expectEqual(@as(i32, 1), items[2].key);
    try std.testing.expectEqual(@as(usize, 4), items[2].order);

    // All 2s should come after, in original order
    try std.testing.expectEqual(@as(i32, 2), items[3].key);
    try std.testing.expectEqual(@as(usize, 1), items[3].order);
    try std.testing.expectEqual(@as(i32, 2), items[4].key);
    try std.testing.expectEqual(@as(usize, 3), items[4].order);
}

test "stableSort - descending" {
    var v = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    stableSortDesc(i32, &v);
    for (1..v.len) |i| {
        try std.testing.expect(v[i - 1] >= v[i]);
    }
}

test "stableSort - medium array" {
    const allocator = std.heap.page_allocator;
    const v = allocator.alloc(i32, 1000) catch unreachable;
    defer allocator.free(v);

    // Fill with descending values
    for (v, 0..) |*val, i| {
        val.* = @intCast(1000 - i);
    }

    stableSortAsc(i32, v);

    for (1..v.len) |i| {
        try std.testing.expect(v[i - 1] <= v[i]);
    }
}

test "stableSort - large array" {
    const allocator = std.heap.page_allocator;
    const v = allocator.alloc(i32, 10000) catch unreachable;
    defer allocator.free(v);

    // Fill with pseudo-random values
    var seed: u64 = 12345;
    for (v) |*val| {
        seed = seed *% 6364136223846793005 +% 1;
        val.* = @intCast(@as(i64, @bitCast(seed)) >> 33);
    }

    stableSortAsc(i32, v);

    for (1..v.len) |i| {
        try std.testing.expect(v[i - 1] <= v[i]);
    }
}
