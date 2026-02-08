---
title: PDQSort Algorithm
description: Pattern-Defeating Quicksort - a hybrid sorting algorithm.
slug: 1.0.0-zig0.15.2/algorithms/pdqsort
---

## Overview

PDQSort (Pattern-Defeating Quicksort) is a hybrid sorting algorithm that combines:

* **Quicksort** for average-case O(n log n)
* **Insertion sort** for small arrays
* **Heapsort** fallback for O(n log n) worst-case guarantee
* **Pattern detection** to exploit already-sorted data

It was designed by Orson Peters and is used in Rust's standard library.

## Why PDQSort?

### The Problem with Quicksort

Standard quicksort has issues:

1. **O(n^2) worst case** on sorted/reverse-sorted input
2. **Poor pivot selection** leads to unbalanced partitions
3. **No pattern exploitation** - treats sorted data same as random

### PDQSort Solutions

| Problem | PDQSort Solution |
|---------|------------------|
| O(n^2) worst case | Heapsort fallback after too many bad partitions |
| Bad pivots | Median-of-3, swaps to break patterns |
| Sorted input | Detects and exploits ascending/descending runs |
| Equal elements | Three-way partition for many duplicates |

## Configuration Constants

Blitz uses carefully tuned constants:

```zig
pub const BLOCK: usize = 128;           // Block size for BlockQuicksort
pub const MAX_INSERTION: usize = 20;    // Max elements for insertion sort
pub const MAX_SEQUENTIAL: usize = 2000; // Threshold for parallel execution
pub const SHORTEST_MEDIAN_OF_MEDIANS: usize = 50;
pub const MAX_SWAPS: usize = 4 * 3;     // Before reversing slice
pub const MAX_STEPS: usize = 5;         // Partial insertion sort attempts
```

## Algorithm Structure

```
pdqsort(array, limit):
    if len <= 20:
        insertion_sort(array)
        return

    if limit == 0:
        heapsort(array)  // Guaranteed O(n log n)
        return

    if !was_balanced:
        break_patterns(array)
        limit -= 1

    pivot = choose_pivot(array)

    if likely_sorted and partial_insertion_sort(array):
        return  // Already sorted!

    partition_point = partition(array, pivot)
    was_balanced = min(left, right) >= len/8

    if max(left.len, right.len) <= 2000:
        // Sequential recursion
        pdqsort(smaller_half)
        pdqsort(larger_half)  // Tail call
    else:
        // Parallel fork-join
        blitz.join(pdqsort(left), pdqsort(right))
```

## Key Components

### 1. Insertion Sort (Small Arrays)

For arrays of 20 or fewer elements, insertion sort with shift optimization:

```zig
/// Inserts v[v.len - 1] into pre-sorted sequence v[..v.len - 1].
/// Uses shift instead of swap for better performance.
pub fn insertTail(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) void {
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
```

**Why shift instead of swap?**

* Swap: 3 memory operations per position (read tmp, read other, write both)
* Shift: 1 read + 1 write per position, final write at end

### 2. Pivot Selection (Median-of-Medians)

For large arrays (>=50 elements), uses median-of-medians:

```zig
pub fn choosePivot(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) PivotResult {
    // Three indices at 25%, 50%, 75%
    var a = len / 4 * 1;
    var b = len / 4 * 2;
    var c = len / 4 * 3;

    if (len >= 50) {
        // Find medians in neighborhoods of a, b, c
        sort3(v, &(a-1), &a, &(a+1), &swaps, is_less);
        sort3(v, &(b-1), &b, &(b+1), &swaps, is_less);
        sort3(v, &(c-1), &c, &(c+1), &swaps, is_less);
    }

    // Find the median among a, b, c
    sort3(v, &a, &b, &c, &swaps, is_less);

    if (swaps >= 12) {
        // Too many swaps - likely descending, reverse it
        std.mem.reverse(T, v);
        return .{ .pivot_idx = len - 1 - b, .likely_sorted = true };
    }

    return .{ .pivot_idx = b, .likely_sorted = swaps == 0 };
}
```

### 3. BlockQuicksort Partitioning

The core innovation - branchless block-based partitioning with **4x loop unrolling**:

```zig
pub fn partitionInBlocks(comptime T: type, v: []T, pivot: *const T, comptime is_less: fn (T, T) bool) usize {
    var offsets_l: [BLOCK]u8 = undefined;  // BLOCK = 128
    var offsets_r: [BLOCK]u8 = undefined;

    while (true) {
        // Trace left block - UNROLLED 4x for better pipelining
        if (start_l == end_l) {
            start_l = 0;
            end_l = 0;

            const piv = pivot.*;  // Cache pivot value
            var i: u8 = 0;

            // Unrolled loop: process 4 elements at a time
            while (i + 4 <= block_l) : (i += 4) {
                offsets_l[end_l] = i;
                end_l += @intFromBool(!is_less(v[l + i], piv));
                offsets_l[end_l] = i + 1;
                end_l += @intFromBool(!is_less(v[l + i + 1], piv));
                offsets_l[end_l] = i + 2;
                end_l += @intFromBool(!is_less(v[l + i + 2], piv));
                offsets_l[end_l] = i + 3;
                end_l += @intFromBool(!is_less(v[l + i + 3], piv));
            }
            // Handle remaining elements
            while (i < block_l) : (i += 1) {
                offsets_l[end_l] = i;
                end_l += @intFromBool(!is_less(v[l + i], piv));
            }
        }

        // Similar for right block...

        // Cyclic permutation (more cache-efficient than pair swaps)
        const count = @min(end_l - start_l, end_r - start_r);
        if (count > 0) {
            const tmp = v[l + offsets_l[start_l]];
            var k: usize = 0;
            while (k < count - 1) : (k += 1) {
                const left_idx = l + offsets_l[start_l + k];
                const right_idx = r - 1 - offsets_r[start_r + k];
                v[left_idx] = v[right_idx];
                v[right_idx] = v[l + offsets_l[start_l + k + 1]];
            }
            v[l + offsets_l[start_l + count - 1]] = v[r - 1 - offsets_r[start_r + count - 1]];
            v[r - 1 - offsets_r[start_r + count - 1]] = tmp;
        }
        // ...
    }
}
```

**Why 4x unrolling?**

```
Without unrolling:
    Compare → Branch → Store → Compare → Branch → Store
    Dependencies cause pipeline stalls

With 4x unrolling:
    Compare0 → Compare1 → Compare2 → Compare3
    Store0   → Store1   → Store2   → Store3
    4 operations in flight, better instruction pipelining
```

**Why cyclic permutation?**

```
Pair swaps (traditional):
    tmp = A; A = B; B = tmp;  // 3 ops per pair
    tmp = C; C = D; D = tmp;  // 3 ops per pair
    Total: 6 memory operations for 2 swaps

Cyclic permutation:
    tmp = A;
    A = B; B = C; C = D; D = tmp;
    Total: 5 memory operations for 2 swaps
    Better cache line utilization
```

### 4. SIMD Sorted Sequence Detection

For pattern detection, Blitz uses SIMD to check multiple pairs at once:

```zig
// Vector width depends on element size:
// - 8-byte (f64/i64): 4 elements per vector
// - 4-byte (f32/i32): 8 elements per vector
// - 2-byte (i16):     16 elements per vector
// - 1-byte (i8):      32 elements per vector

// Scalar (Rayon): check one pair at a time
while (i < len and v[i] >= v[i-1]) i += 1;

// SIMD (Blitz): check vec_len pairs at once
const vec_len = switch (@sizeOf(T)) { 8 => 4, 4 => 8, 2 => 16, 1 => 32 };
const a: @Vector(vec_len, T) = v[i..][0..vec_len].*;
const b: @Vector(vec_len, T) = v[i+1..][0..vec_len].*;
if (@reduce(.And, a <= b)) {
    // All pairs are in order
    i += vec_len;
}
```

This makes sorted/nearly-sorted detection **52-69% faster**.

### 5. Pattern Breaking

When partition is unbalanced, break patterns to prevent O(n^2):

```zig
pub fn breakPatterns(comptime T: type, v: []T) void {
    if (v.len < 8) return;

    // XorShift RNG seeded with length
    var seed = v.len;

    // Randomize pivot candidates near len/2
    const pos = v.len / 4 * 2;

    for (0..3) |i| {
        var other = genUsize(&seed) & (modulus - 1);
        if (other >= v.len) other -= v.len;
        std.mem.swap(T, &v[pos - 1 + i], &v[other]);
    }
}
```

### 6. Heapsort Fallback

After too many unbalanced partitions (limit reaches 0), switch to heapsort:

```zig
fn recurse(v: []T, is_less: fn(T,T) bool, limit: u32) void {
    // ...
    if (limit == 0) {
        heapsort(T, v, is_less);  // Guaranteed O(n log n)
        return;
    }

    if (!was_balanced) {
        breakPatterns(T, v);
        limit -= 1;  // Decrement limit on bad partition
    }
    // ...
}

// Initial limit: floor(log2(len)) + 1
const limit: u32 = @intCast(@bitSizeOf(usize) - @clz(v.len));
```

## Parallel PDQSort

Blitz parallelizes PDQSort using fork-join when subarrays exceed 2000 elements:

```zig
fn recurse(comptime T: type, v: []T, is_less: fn(T,T) bool, pred: ?*const T, limit: u32) void {
    // ... partition ...

    const left = v[0..mid];
    const right = v[mid + 1..];

    if (@max(left.len, right.len) <= MAX_SEQUENTIAL) {
        // Sequential: recurse into shorter side first (better cache)
        if (left.len < right.len) {
            recurse(T, left, is_less, pred, limit);
            v = right;  // Tail call optimization
        } else {
            recurse(T, right, is_less, pivot_ptr, limit);
            v = left;
        }
    } else {
        // Parallel: fork-join via Blitz
        _ = blitz.join(.{
            .left = .{ recurse, T, left, is_less, pred, limit },
            .right = .{ recurse, T, right, is_less, pivot_ptr, limit },
        });
        return;
    }
}
```

## Performance

Benchmark results (Apple M1 Pro, 10 cores, 1M elements):

```
Input Pattern        Blitz       Rayon       Improvement
-------------------------------------------------------
Random               4.08 ms     4.21 ms     3% faster
Already sorted       0.23 ms     0.48 ms     52% faster
Reverse sorted       0.36 ms     0.56 ms     36% faster
All equal            0.24 ms     0.77 ms     69% faster
```

**Why Blitz excels on patterns:**

* SIMD sorted detection checks 4 pairs per iteration
* Early bailout via `partialInsertionSort` for nearly-sorted
* Efficient `partitionEqual` for many duplicates

**Why random is competitive:**

* 4x loop unrolling in block tracing
* Pivot value caching (`const piv = pivot.*`)
* Same BlockQuicksort algorithm as Rayon
* Both use identical O(n log n) approach

## Complexity

| Case | Time | Space |
|------|------|-------|
| Best | O(n log n) | O(log n) |
| Average | O(n log n) | O(log n) |
| Worst | O(n log n) | O(log n) |

The worst-case is guaranteed by the heapsort fallback.

## Implementation Files

* `sort/pdqsort.zig` - Main PDQSort implementation
* `sort/helpers.zig` - Insertion sort, heapsort, pivot selection
* `sort/simd_check.zig` - SIMD sorted detection
* `sort/stablesort.zig` - Stable merge sort variant

## References

1. Peters, O. "Pattern-defeating Quicksort" - https://github.com/orlp/pdqsort
2. Edelkamp, S. & Weiss, A. "BlockQuicksort" - https://arxiv.org/abs/1604.06697
3. Rust std library sort implementation
4. Blitz implementation: `sort/pdqsort.zig`
