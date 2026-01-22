//! Pattern-Defeating Quicksort (PDQSort)
//!
//! Core partitioning and recursive sorting implementation.
//! Based on Orson Peters' PDQSort and Rayon's parallel implementation.
//!
//! Features:
//! - BlockQuicksort partitioning with cyclic permutation
//! - Pattern detection for nearly-sorted data
//! - Equal element optimization
//! - Heapsort fallback for guaranteed O(n log n)
//! - Parallel execution via Blitz fork-join

const std = @import("std");
const blitz = @import("../api.zig");
const helpers = @import("helpers.zig");
const simd_partition = @import("simd_partition.zig");

// Re-export constants
pub const BLOCK = helpers.BLOCK;
pub const MAX_INSERTION = helpers.MAX_INSERTION;
pub const MAX_SEQUENTIAL = helpers.MAX_SEQUENTIAL;

// ============================================================================
// BlockQuicksort Partitioning
// ============================================================================

/// Partitions `v` into elements smaller than `pivot`, followed by elements >= pivot.
/// Returns the number of elements smaller than `pivot`.
/// Uses block-based branchless partitioning with cyclic permutation.
pub fn partitionInBlocks(comptime T: type, v: []T, pivot: *const T, comptime is_less: fn (T, T) bool) usize {
    if (v.len == 0) return 0;

    var l: usize = 0;
    var r: usize = v.len;

    // Block offsets
    var offsets_l: [BLOCK]u8 = undefined;
    var offsets_r: [BLOCK]u8 = undefined;

    var start_l: usize = 0;
    var end_l: usize = 0;
    var start_r: usize = 0;
    var end_r: usize = 0;

    var block_l: usize = BLOCK;
    var block_r: usize = BLOCK;

    while (true) {
        const is_done = r - l <= 2 * BLOCK;

        if (is_done) {
            // Adjust block sizes for remaining elements
            var rem = r - l;
            if (start_l < end_l or start_r < end_r) {
                rem -= BLOCK;
            }

            if (start_l < end_l) {
                block_r = rem;
            } else if (start_r < end_r) {
                block_l = rem;
            } else {
                block_l = rem / 2;
                block_r = rem - block_l;
            }
        }

        // Trace left block
        if (start_l == end_l) {
            start_l = 0;
            end_l = 0;

            var i: u8 = 0;
            while (i < @as(u8, @intCast(block_l))) : (i += 1) {
                // Branchless: store offset if element >= pivot
                offsets_l[end_l] = i;
                end_l += @intFromBool(!is_less(v[l + i], pivot.*));
            }
        }

        // Trace right block
        if (start_r == end_r) {
            start_r = 0;
            end_r = 0;

            var i: u8 = 0;
            while (i < @as(u8, @intCast(block_r))) : (i += 1) {
                // Branchless: store offset if element < pivot
                offsets_r[end_r] = i;
                end_r += @intFromBool(is_less(v[r - 1 - i], pivot.*));
            }
        }

        // Number of elements to swap
        const count = @min(end_l - start_l, end_r - start_r);

        if (count > 0) {
            // Cyclic permutation (more cache-efficient than pair swaps)
            const tmp = v[l + offsets_l[start_l]];

            var k: usize = 0;
            while (k < count - 1) : (k += 1) {
                const left_idx = l + offsets_l[start_l + k];
                const right_idx = r - 1 - offsets_r[start_r + k];
                v[left_idx] = v[right_idx];

                const next_left_idx = l + offsets_l[start_l + k + 1];
                v[right_idx] = v[next_left_idx];
            }

            const last_right_idx = r - 1 - offsets_r[start_r + count - 1];
            v[l + offsets_l[start_l + count - 1]] = v[last_right_idx];
            v[last_right_idx] = tmp;

            start_l += count;
            start_r += count;
        }

        // Advance block pointers
        if (start_l == end_l) {
            l += block_l;
        }
        if (start_r == end_r) {
            r -= block_r;
        }

        if (is_done) break;
    }

    // Handle remaining elements in one block
    if (start_l < end_l) {
        // Left block remains - move elements to the right
        while (start_l < end_l) {
            end_l -= 1;
            r -= 1;
            std.mem.swap(T, &v[l + offsets_l[end_l]], &v[r]);
        }
        return r;
    } else if (start_r < end_r) {
        // Right block remains - move elements to the left
        while (start_r < end_r) {
            end_r -= 1;
            std.mem.swap(T, &v[l], &v[r - 1 - offsets_r[end_r]]);
            l += 1;
        }
        return l;
    } else {
        return l;
    }
}

/// Result of partition
pub const PartitionResult = struct {
    mid: usize,
    was_partitioned: bool,
};

/// Partitions `v` around `v[pivot_idx]`.
/// Returns the final position of the pivot and whether the slice was already partitioned.
pub fn partition(comptime T: type, v: []T, pivot_idx: usize, comptime is_less: fn (T, T) bool) PartitionResult {
    // Move pivot to the start
    std.mem.swap(T, &v[0], &v[pivot_idx]);
    const pivot = v[0];
    const rest = v[1..];

    // Check if already partitioned by finding first out-of-order pair
    var l: usize = 0;
    var r: usize = rest.len;

    while (l < r and is_less(rest[l], pivot)) {
        l += 1;
    }

    while (l < r and !is_less(rest[r - 1], pivot)) {
        r -= 1;
    }

    const already_partitioned = l >= r;

    // Partition the rest
    const mid = partitionInBlocks(T, rest[l..r], &pivot, is_less) + l;

    // Move pivot to its final position
    std.mem.swap(T, &v[0], &v[mid]);

    return .{ .mid = mid, .was_partitioned = already_partitioned };
}

/// Partitions `v` into elements equal to `v[pivot_idx]` followed by elements greater.
/// Assumes no elements are smaller than the pivot. Returns count of equal elements.
pub fn partitionEqual(comptime T: type, v: []T, pivot_idx: usize, comptime is_less: fn (T, T) bool) usize {
    // Move pivot to start
    std.mem.swap(T, &v[0], &v[pivot_idx]);
    const pivot = v[0];

    const rest = v[1..];
    const len = rest.len;
    if (len == 0) return 1;

    var l: usize = 0;
    var r: usize = len;

    while (true) {
        // Find first element greater than pivot
        while (l < r and !is_less(pivot, rest[l])) {
            l += 1;
        }

        // Find last element equal to pivot
        while (l < r) {
            r -= 1;
            if (!is_less(pivot, rest[r])) {
                break;
            }
        }

        if (l >= r) break;

        std.mem.swap(T, &rest[l], &rest[r]);
        l += 1;
    }

    // Return count including the pivot
    return l + 1;
}

// ============================================================================
// Recursive Sort Implementation
// ============================================================================

/// Internal recursive PDQSort implementation.
pub fn recurse(
    comptime T: type,
    v_in: []T,
    comptime is_less: fn (T, T) bool,
    pred_in: ?*const T,
    limit_in: u32,
) void {
    var v = v_in;
    var pred = pred_in;
    var limit = limit_in;
    var was_balanced = true;
    var was_partitioned = true;

    while (true) {
        const len = v.len;

        // Base case: insertion sort for small arrays
        if (len <= MAX_INSERTION) {
            if (len >= 2) {
                helpers.insertionSortShiftLeft(T, v, 1, is_less);
            }
            return;
        }

        // Fallback to heapsort if too many bad pivots
        if (limit == 0) {
            helpers.heapsort(T, v, is_less);
            return;
        }

        // Break patterns if last partition was imbalanced
        if (!was_balanced) {
            helpers.breakPatterns(T, v);
            limit -= 1;
        }

        // Choose pivot
        const pivot_result = helpers.choosePivot(T, v, is_less);

        // If likely sorted, try partial insertion sort
        if (was_balanced and was_partitioned and pivot_result.likely_sorted) {
            if (helpers.partialInsertionSort(T, v, is_less)) {
                return;
            }
        }

        // Handle equal elements: if pivot equals predecessor, partition differently
        if (pred) |p| {
            if (!is_less(p.*, v[pivot_result.pivot_idx])) {
                const mid = partitionEqual(T, v, pivot_result.pivot_idx, is_less);
                v = v[mid..];
                continue;
            }
        }

        // Partition
        const part = partition(T, v, pivot_result.pivot_idx, is_less);
        was_balanced = @min(part.mid, len - part.mid) >= len / 8;
        was_partitioned = part.was_partitioned;

        // Split into left, pivot, right
        const left = v[0..part.mid];
        const pivot_ptr: *const T = &v[part.mid];
        const right = v[part.mid + 1 ..];

        // Decide sequential vs parallel recursion
        if (@max(left.len, right.len) <= MAX_SEQUENTIAL) {
            // Sequential: recurse into shorter side first
            if (left.len < right.len) {
                recurse(T, left, is_less, pred, limit);
                v = right;
                pred = pivot_ptr;
            } else {
                recurse(T, right, is_less, pivot_ptr, limit);
                v = left;
                // pred stays the same
            }
        } else {
            // Parallel: use unified join API for fork-join
            _ = blitz.join(.{
                .left = .{ recurse, T, left, is_less, pred, limit },
                .right = .{ recurse, T, right, is_less, pivot_ptr, limit },
            });
            return;
        }
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Sorts `v` in-place using parallel pattern-defeating quicksort.
/// Uses work-stealing for automatic load balancing.
///
/// Unstable sort: equal elements may be reordered.
/// Time: O(n log n) worst-case (heapsort fallback)
/// Space: O(log n) stack space
pub fn sort(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) void {
    // Sorting has no meaningful behavior on zero-sized types
    if (@sizeOf(T) == 0) return;
    if (v.len <= 1) return;

    // Limit: floor(log2(len)) + 1
    const limit: u32 = @intCast(@bitSizeOf(usize) - @clz(v.len));

    recurse(T, v, is_less, null, limit);
}

/// Sorts `v` in ascending order using the default `<` comparison.
pub fn sortAsc(comptime T: type, v: []T) void {
    sort(T, v, struct {
        fn less(a: T, b: T) bool {
            return a < b;
        }
    }.less);
}

/// Sorts `v` in descending order using the default `>` comparison.
pub fn sortDesc(comptime T: type, v: []T) void {
    sort(T, v, struct {
        fn less(a: T, b: T) bool {
            return a > b;
        }
    }.less);
}
