//! Sort Utility Functions
//!
//! Low-level sorting utilities: insertion sort, heapsort, pattern breaking.

const std = @import("std");
const simd_check = @import("simd_check.zig");
const runtime = @import("../ops/runtime.zig");

// ============================================================================
// Configuration Constants
// ============================================================================

/// Block size for BlockQuicksort partitioning
pub const BLOCK: usize = 128;

/// Maximum elements for insertion sort
pub const MAX_INSERTION: usize = 20;

/// Base threshold before parallel execution kicks in (for 1-2 workers)
pub const BASE_SEQUENTIAL: usize = 2000;

/// Maximum elements before parallel execution kicks in.
/// Scales with worker count: more workers = higher threshold to justify overhead.
/// This is a legacy constant for compatibility - prefer getSequentialThreshold().
pub const MAX_SEQUENTIAL: usize = 2000;

/// Get the adaptive sequential threshold based on worker count.
///
/// With more workers, fork-join overhead increases (more coordination),
/// but work per worker decreases. We need larger chunks to justify the overhead.
///
/// Formula: base * max(1, workers / 2)
/// - 1-2 workers: 2000 elements
/// - 4 workers: 4000 elements
/// - 8 workers: 8000 elements
/// - 16 workers: 16000 elements
pub fn getSequentialThreshold() usize {
    if (!runtime.isInitialized()) {
        return BASE_SEQUENTIAL;
    }
    const workers = runtime.numWorkers();
    const scale = @max(1, workers / 2);
    return BASE_SEQUENTIAL * scale;
}

/// Minimum length for median-of-medians pivot selection
pub const SHORTEST_MEDIAN_OF_MEDIANS: usize = 50;

/// Minimum length for pattern shifting
pub const SHORTEST_SHIFTING: usize = 50;

/// Maximum swaps in pivot selection before reversing
pub const MAX_SWAPS: usize = 4 * 3;

/// Maximum out-of-order pairs to fix in partial insertion sort
pub const MAX_STEPS: usize = 5;

// ============================================================================
// Insertion Sort Utilities
// ============================================================================

/// Inserts `v[v.len() - 1]` into pre-sorted sequence `v[..v.len() - 1]`.
/// Uses shift instead of swap for better performance.
pub fn insertTail(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) void {
    std.debug.assert(v.len >= 2);

    const i = v.len - 1;
    if (is_less(v[i], v[i - 1])) {
        const tmp = v[i];

        // Shift elements right until we find the insertion point
        var j = i - 1;
        while (j > 0 and is_less(tmp, v[j - 1])) : (j -= 1) {
            v[j + 1] = v[j];
        }
        v[j + 1] = v[j];
        v[j] = tmp;
    }
}

/// Inserts `v[0]` into pre-sorted sequence `v[1..]`.
pub fn insertHead(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) void {
    std.debug.assert(v.len >= 2);

    if (is_less(v[1], v[0])) {
        const tmp = v[0];

        // Shift elements left until we find the insertion point
        var j: usize = 1;
        while (j < v.len and is_less(v[j], tmp)) : (j += 1) {
            v[j - 1] = v[j];
        }
        v[j - 1] = tmp;
    }
}

/// Sort `v` assuming `v[..offset]` is already sorted.
pub fn insertionSortShiftLeft(comptime T: type, v: []T, offset: usize, comptime is_less: fn (T, T) bool) void {
    const len = v.len;
    std.debug.assert(offset != 0 and offset <= len);

    for (offset..len) |i| {
        insertTail(T, v[0 .. i + 1], is_less);
    }
}

/// Sort `v` assuming `v[offset..]` is already sorted.
pub fn insertionSortShiftRight(comptime T: type, v: []T, offset: usize, comptime is_less: fn (T, T) bool) void {
    const len = v.len;
    std.debug.assert(offset != 0 and offset <= len and len >= 2);

    var i = offset;
    while (i > 0) {
        i -= 1;
        insertHead(T, v[i..len], is_less);
    }
}

/// Partially sorts a slice by shifting several out-of-order elements.
/// Returns `true` if the slice is sorted at the end. O(n) worst-case.
pub fn partialInsertionSort(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) bool {
    const len = v.len;

    // SIMD fast path: for large arrays of SIMD-friendly types, use vectorized check
    // This is ~4-8x faster than scalar loop for already-sorted data.
    // BUT: Only run SIMD check if the data appears likely sorted (first 8 elements in order).
    // This avoids wasting cycles on random data where SIMD check will certainly fail.
    if (len >= 1024 and simd_check.canSimdCheck(T)) {
        // Quick heuristic: check if first 8 elements are sorted before doing full SIMD scan
        const sample_size = @min(8, len - 1);
        var appears_sorted = true;
        for (0..sample_size) |i| {
            if (is_less(v[i + 1], v[i])) {
                appears_sorted = false;
                break;
            }
        }

        if (appears_sorted) {
            // Check if data is sorted using SIMD
            // is_less(a, b) means a < b, so !is_less(v[i], v[i-1]) means v[i] >= v[i-1]
            // which is equivalent to checking v[i-1] <= v[i] for ascending order
            const is_ordered = struct {
                fn check(a: T, b: T) bool {
                    return !is_less(b, a); // a <= b if !(b < a)
                }
            }.check;

            if (simd_check.isSorted(T, v, is_ordered)) {
                return true;
            }
        }
        // Not sorted - fall through to standard algorithm which may still fix it
    }

    var i: usize = 1;

    for (0..MAX_STEPS) |_| {
        // Find the next pair of adjacent out-of-order elements
        while (i < len and !is_less(v[i], v[i - 1])) {
            i += 1;
        }

        // Are we done?
        if (i == len) {
            return true;
        }

        // Don't shift elements on short arrays
        if (len < SHORTEST_SHIFTING) {
            return false;
        }

        // Swap the found pair
        std.mem.swap(T, &v[i - 1], &v[i]);

        if (i >= 2) {
            // Shift the smaller element to the left
            insertionSortShiftLeft(T, v[0..i], i - 1, is_less);

            // Shift the greater element to the right
            insertionSortShiftRight(T, v[0..i], 1, is_less);
        }
    }

    // Didn't manage to sort in the limited number of steps
    return false;
}

// ============================================================================
// Heapsort (O(n log n) fallback)
// ============================================================================

pub fn heapsort(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) void {
    if (v.len < 2) return;

    // Build the heap
    var i = v.len / 2;
    while (i > 0) {
        i -= 1;
        siftDown(T, v, i, v.len, is_less);
    }

    // Pop elements from the heap
    var end = v.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(T, &v[0], &v[end]);
        siftDown(T, v, 0, end, is_less);
    }
}

fn siftDown(comptime T: type, v: []T, start: usize, end: usize, comptime is_less: fn (T, T) bool) void {
    var node = start;
    while (true) {
        var child = 2 * node + 1;
        if (child >= end) break;

        // Choose the greater child (branchless)
        if (child + 1 < end) {
            child += @intFromBool(is_less(v[child], v[child + 1]));
        }

        // Stop if invariant holds
        if (!is_less(v[node], v[child])) break;

        std.mem.swap(T, &v[node], &v[child]);
        node = child;
    }
}

// ============================================================================
// Pattern Breaking (anti-adversarial)
// ============================================================================

/// Scatters elements to break patterns that might cause imbalanced partitions.
pub fn breakPatterns(comptime T: type, v: []T) void {
    const len = v.len;
    if (len < 8) return;

    // XorShift RNG seeded with length
    var seed = len;
    const genUsize = struct {
        fn gen(s: *usize) usize {
            // XorShift64
            var r = s.*;
            r ^= r << 13;
            r ^= r >> 7;
            r ^= r << 17;
            s.* = r;
            return r;
        }
    }.gen;

    // Take random numbers modulo next power of two
    const modulus = std.math.ceilPowerOfTwo(usize, len) catch len;

    // Randomize pivot candidates near len/2
    const pos = len / 4 * 2;

    for (0..3) |i| {
        var other = genUsize(&seed) & (modulus - 1);
        if (other >= len) {
            other -= len;
        }
        std.mem.swap(T, &v[pos - 1 + i], &v[other]);
    }
}

// ============================================================================
// Pivot Selection
// ============================================================================

/// Result of pivot selection
pub const PivotResult = struct {
    pivot_idx: usize,
    likely_sorted: bool,
};

/// Chooses a pivot and returns whether the slice is likely already sorted.
pub fn choosePivot(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) PivotResult {
    const len = v.len;

    // Three indices near which we are going to choose a pivot
    var a = len / 4 * 1;
    var b = len / 4 * 2;
    var c = len / 4 * 3;

    var swaps: usize = 0;

    if (len >= 8) {
        // sort2: swap indices so that v[a] <= v[b]
        const sort2 = struct {
            fn f(data: []T, pa: *usize, pb: *usize, swap_count: *usize, comptime less: fn (T, T) bool) void {
                if (less(data[pb.*], data[pa.*])) {
                    std.mem.swap(usize, pa, pb);
                    swap_count.* += 1;
                }
            }
        }.f;

        // sort3: swap indices so that v[a] <= v[b] <= v[c]
        const sort3 = struct {
            fn f(data: []T, pa: *usize, pb: *usize, pc: *usize, swap_count: *usize, comptime less: fn (T, T) bool) void {
                const s2 = struct {
                    fn g(d: []T, x: *usize, y: *usize, sc: *usize, comptime l: fn (T, T) bool) void {
                        if (l(d[y.*], d[x.*])) {
                            std.mem.swap(usize, x, y);
                            sc.* += 1;
                        }
                    }
                }.g;
                s2(data, pa, pb, swap_count, less);
                s2(data, pb, pc, swap_count, less);
                s2(data, pa, pb, swap_count, less);
            }
        }.f;

        if (len >= SHORTEST_MEDIAN_OF_MEDIANS) {
            // Find medians in neighborhoods of a, b, c
            var a_m1 = a - 1;
            var a_p1 = a + 1;
            sort3(v, &a_m1, &a, &a_p1, &swaps, is_less);

            var b_m1 = b - 1;
            var b_p1 = b + 1;
            sort3(v, &b_m1, &b, &b_p1, &swaps, is_less);

            var c_m1 = c - 1;
            var c_p1 = c + 1;
            sort3(v, &c_m1, &c, &c_p1, &swaps, is_less);
        }

        // Find the median among a, b, c
        sort2(v, &a, &b, &swaps, is_less);
        sort2(v, &b, &c, &swaps, is_less);
        sort2(v, &a, &b, &swaps, is_less);
    }

    if (swaps < MAX_SWAPS) {
        return .{ .pivot_idx = b, .likely_sorted = swaps == 0 };
    } else {
        // Too many swaps - slice is likely descending, reverse it
        std.mem.reverse(T, v);
        return .{ .pivot_idx = len - 1 - b, .likely_sorted = true };
    }
}
