---
title: Parallel Sorting
description: High-performance parallel PDQSort (Pattern-Defeating Quicksort)
slug: v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/1.0.0-zig0.15.2/usage/sorting
---

High-performance parallel PDQSort (Pattern-Defeating Quicksort).

## Basic Usage

```zig
const blitz = @import("blitz");

var data = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

// Sort ascending with custom comparator
blitz.sort(i64, &data, struct {
    fn lessThan(a: i64, b: i64) bool {
        return a < b;
    }
}.lessThan);
// data is now [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

## Sort Variants

### Basic Sort (Custom Comparator)

```zig
blitz.sort(T, slice, lessThanFn);
```

### Ascending Sort

```zig
blitz.sortAsc(i64, &data);
// Uses natural < ordering
```

### Descending Sort

```zig
blitz.sortDesc(i64, &data);
// Uses natural > ordering
```

## Sort by Key

Sort using a key extraction function:

```zig
const Person = struct {
    name: []const u8,
    age: u32,
    score: i32,
};

var people: []Person = ...;

// Sort by age
blitz.sortByKey(Person, u32, people, struct {
    fn key(p: Person) u32 { return p.age; }
}.key);
```

## Sort by Cached Key

For expensive key functions, compute keys once in parallel:

```zig
// Two-phase: parallel key computation, then sort
try blitz.sortByCachedKey(
    Person,
    u32,
    allocator,
    people,
    struct {
        fn expensiveKey(p: Person) u32 {
            // Expensive computation done once per element
            return computeComplexScore(p);
        }
    }.expensiveKey,
);
```

**When to use cached key:**

* Key function is expensive (> 100ns)
* Sorting large arrays (> 10K elements)
* Key computation can be parallelized

## Custom Comparator Examples

### Sort Strings by Length

```zig
blitz.sort([]const u8, strings, struct {
    fn byLength(a: []const u8, b: []const u8) bool {
        return a.len < b.len;
    }
}.byLength);
```

### Sort by Absolute Value

```zig
blitz.sort(i64, &data, struct {
    fn byAbs(a: i64, b: i64) bool {
        return @abs(a) < @abs(b);
    }
}.byAbs);
```

### Sort Structs by Multiple Fields

```zig
blitz.sort(Person, people, struct {
    fn compare(a: Person, b: Person) bool {
        // Primary: by age
        if (a.age != b.age) return a.age < b.age;
        // Secondary: by score (descending)
        return a.score > b.score;
    }
}.compare);
```

## Performance

Blitz PDQSort achieves excellent performance through:

1. **Parallel recursive sorting** - Fork-join on large partitions
2. **Pattern-defeating** - Handles sorted/reverse/equal inputs efficiently
3. **Hybrid approach** - Insertion sort for small arrays, heapsort fallback
4. **Block partitioning** - Cache-efficient element movement

```
Sorting 10M random i64:

std.mem.sort:     4,644 ms
Blitz PDQSort:      430 ms (10.8x faster)

Different patterns (10M elements):
Already sorted:    36 ms
Reverse sorted:    69 ms
All equal:         36 ms
Random:           430 ms
```

## Algorithm Details

PDQSort (Pattern-Defeating Quicksort) combines:

| Technique | When Used | Benefit |
|-----------|-----------|---------|
| Quicksort | Large arrays | O(n log n) average |
| Insertion sort | \< 24 elements | Low overhead |
| Heapsort | Bad pivot patterns | O(n log n) guaranteed |
| Block partition | Large partitions | Cache efficiency |
| Pattern breaking | Detected patterns | Prevents O(n²) |

## Parallelization Strategy

```
Array: [........................1M elements........................]
        ├──────────────────────┼──────────────────────┤
        │     Left Half        │     Right Half       │
        │    (Worker 0)        │    (Worker 1)        │
        │         │            │         │            │
        │    ┌────┴────┐       │    ┌────┴────┐       │
        │  Left   Right        │  Left   Right        │
        │  (W0)   (W2)         │  (W1)   (W3)         │
        └──────────────────────┴──────────────────────┘
                    Recursive fork-join
```

* Fork at each partition (if large enough)
* Sequential threshold: 8,192 elements
* Work stealing balances uneven partitions

## Stability

**Important**: Blitz sort is **not stable**. Equal elements may be reordered.

For stable sorting needs:

```zig
// Use standard library stable sort
std.mem.sort(T, data, {}, lessThanFn);
```

## Memory Usage

* **In-place**: Minimal extra memory (~log n stack depth)
* **sortByCachedKey**: Allocates O(n) for key array

## When to Use Parallel Sort

| Data Size | Recommendation |
|-----------|----------------|
| \< 1,000 | Sequential (overhead too high) |
| 1K - 10K | May parallelize (depends on comparator cost) |
| > 10K | Parallel (significant speedup) |

```zig
if (data.len > 10_000) {
    blitz.sort(T, data, lessThanFn);
} else {
    std.mem.sort(T, data, {}, lessThanFn);
}
```

## Complete Example

```zig
const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Generate random data
    var data = try allocator.alloc(i64, 1_000_000);
    defer allocator.free(data);

    var rng = std.Random.DefaultPrng.init(12345);
    for (data) |*v| {
        v.* = rng.random().int(i64);
    }

    // Sort
    const start = std.time.nanoTimestamp();
    blitz.sortAsc(i64, data);
    const elapsed = std.time.nanoTimestamp() - start;

    std.debug.print("Sorted 1M elements in {d:.2} ms\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    // Verify
    for (data[1..], data[0 .. data.len - 1]) |curr, prev| {
        std.debug.assert(curr >= prev);
    }
}
```
