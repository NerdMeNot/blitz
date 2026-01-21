# PDQSort Algorithm

Pattern-Defeating Quicksort - a hybrid sorting algorithm.

## Overview

PDQSort (Pattern-Defeating Quicksort) is a hybrid sorting algorithm that combines:
- **Quicksort** for average-case O(n log n)
- **Insertion sort** for small arrays
- **Heapsort** fallback for O(n log n) worst-case guarantee
- **Pattern detection** to exploit already-sorted data

It was designed by Orson Peters and is used in Rust's standard library.

## Why PDQSort?

### The Problem with Quicksort

Standard quicksort has issues:
1. **O(n²) worst case** on sorted/reverse-sorted input
2. **Poor pivot selection** leads to unbalanced partitions
3. **No pattern exploitation** - treats sorted data same as random

### PDQSort Solutions

| Problem | PDQSort Solution |
|---------|------------------|
| O(n²) worst case | Heapsort fallback after too many bad partitions |
| Bad pivots | Median-of-3, swaps to break patterns |
| Sorted input | Detects and exploits ascending/descending runs |
| Equal elements | Three-way partition for many duplicates |

## Algorithm Structure

```
pdqsort(array):
    if len ≤ 24:
        insertion_sort(array)
        return

    if recursion_limit_exceeded:
        heapsort(array)  // Guaranteed O(n log n)
        return

    pivot = choose_pivot(array)
    partition_point = partition(array, pivot)

    // Check for bad partition
    if partition is very unbalanced:
        break_patterns(array)  // Shuffle to prevent O(n²)

    // Recurse (potentially in parallel)
    pdqsort(array[0..partition_point])
    pdqsort(array[partition_point..])
```

## Key Components

### 1. Insertion Sort (Small Arrays)

For arrays ≤ 24 elements, insertion sort is faster due to:
- No recursion overhead
- Excellent cache locality
- Few comparisons for small n

```zig
fn insertionSort(comptime T: type, slice: []T, lessThan: fn(T, T) bool) void {
    for (1..slice.len) |i| {
        var j = i;
        while (j > 0 and lessThan(slice[j], slice[j - 1])) {
            std.mem.swap(T, &slice[j], &slice[j - 1]);
            j -= 1;
        }
    }
}
```

### 2. Pivot Selection (Median-of-3)

Choose pivot as median of first, middle, and last elements:

```zig
fn choosePivot(comptime T: type, slice: []T, lessThan: fn(T, T) bool) usize {
    const len = slice.len;
    const first = 0;
    const mid = len / 2;
    const last = len - 1;

    // Sort the three elements
    if (lessThan(slice[mid], slice[first])) std.mem.swap(T, &slice[mid], &slice[first]);
    if (lessThan(slice[last], slice[mid])) std.mem.swap(T, &slice[last], &slice[mid]);
    if (lessThan(slice[mid], slice[first])) std.mem.swap(T, &slice[mid], &slice[first]);

    return mid;  // Median is now at mid
}
```

### 3. Block Partition

Partition using blocks for better cache efficiency:

```
Traditional partition:
    ←scan→              ←scan→
    [  <  |   ?????   |  >=  ]

Block partition:
    [blocks of 64]  →  [blocks of 64]
    [<<<<][<<<<]  |  [????]  |  [>>>>][>>>>]

Block offsets stored, swapped in batches
```

```zig
const BLOCK_SIZE = 64;

fn partitionInBlocks(comptime T: type, slice: []T, pivot: T, lessThan: fn(T, T) bool) usize {
    var offsets_l: [BLOCK_SIZE]u8 = undefined;
    var offsets_r: [BLOCK_SIZE]u8 = undefined;

    var l: usize = 0;
    var r: usize = slice.len;

    while (r - l > 2 * BLOCK_SIZE) {
        // Fill left block offsets (elements >= pivot)
        var num_l: usize = 0;
        for (0..BLOCK_SIZE) |i| {
            offsets_l[num_l] = @intCast(i);
            num_l += @intFromBool(!lessThan(slice[l + i], pivot));
        }

        // Fill right block offsets (elements < pivot)
        var num_r: usize = 0;
        for (0..BLOCK_SIZE) |i| {
            offsets_r[num_r] = @intCast(i);
            num_r += @intFromBool(lessThan(slice[r - 1 - i], pivot));
        }

        // Swap misplaced elements
        const swaps = @min(num_l, num_r);
        for (0..swaps) |i| {
            std.mem.swap(T, &slice[l + offsets_l[i]], &slice[r - 1 - offsets_r[i]]);
        }

        // Advance pointers
        if (num_l >= num_r) l += BLOCK_SIZE;
        if (num_r >= num_l) r -= BLOCK_SIZE;
    }

    // Handle remaining elements
    return standardPartition(slice[l..r], pivot, lessThan) + l;
}
```

### 4. Pattern Breaking

When partition is unbalanced, break patterns to prevent O(n²):

```zig
fn breakPatterns(comptime T: type, slice: []T) void {
    if (slice.len < 8) return;

    var rng = XorShift64Star.init(@intCast(slice.len));

    // Swap random pairs to destroy sorted patterns
    for ([_]usize{ 0, slice.len / 4, slice.len / 2, 3 * slice.len / 4 }) |pos| {
        const other = rng.bounded(slice.len);
        std.mem.swap(T, &slice[pos], &slice[@intCast(other)]);
    }
}
```

### 5. Heapsort Fallback

After too many unbalanced partitions, switch to heapsort:

```zig
fn recurse(slice: []T, lessThan: fn(T,T) bool, limit: u32) void {
    if (slice.len <= 24) {
        insertionSort(T, slice, lessThan);
        return;
    }

    if (limit == 0) {
        heapsort(T, slice, lessThan);  // Guaranteed O(n log n)
        return;
    }

    const pivot_idx = partition(slice, lessThan);
    const was_balanced = checkBalance(pivot_idx, slice.len);

    const new_limit = if (was_balanced) limit else limit - 1;

    recurse(slice[0..pivot_idx], lessThan, new_limit);
    recurse(slice[pivot_idx..], lessThan, new_limit);
}
```

## Parallel PDQSort

Blitz parallelizes PDQSort using fork-join:

```zig
fn parallelRecurse(slice: []T, lessThan: fn(T,T) bool, limit: u32) void {
    if (slice.len <= SEQUENTIAL_THRESHOLD) {
        recurse(slice, lessThan, limit);
        return;
    }

    const pivot_idx = partition(slice, lessThan);

    // Fork-join: sort halves in parallel
    blitz.joinVoid(
        struct { fn left(args: anytype) void { parallelRecurse(args.slice, args.lt, args.lim); } }.left,
        struct { fn right(args: anytype) void { parallelRecurse(args.slice, args.lt, args.lim); } }.right,
        .{ .slice = slice[0..pivot_idx], .lt = lessThan, .lim = limit },
        .{ .slice = slice[pivot_idx..], .lt = lessThan, .lim = limit },
    );
}
```

## Performance

```
Sorting 10M elements:

Input Pattern        std.sort    Blitz PDQSort    Speedup
─────────────────────────────────────────────────────────
Random               4,644 ms    430 ms           10.8x
Already sorted       1,200 ms    36 ms            33x
Reverse sorted       1,180 ms    69 ms            17x
All equal            450 ms      36 ms            12.5x
Few unique           2,100 ms    180 ms           11.7x
```

## Complexity

| Case | Time | Space |
|------|------|-------|
| Best | O(n log n) | O(log n) |
| Average | O(n log n) | O(log n) |
| Worst | O(n log n) | O(log n) |

The worst-case is guaranteed by the heapsort fallback.

## References

1. Peters, O. "Pattern-defeating Quicksort" - https://github.com/orlp/pdqsort
2. Rust std library sort implementation
3. Blitz implementation: `sort/pdqsort.zig`
