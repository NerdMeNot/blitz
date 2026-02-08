---
title: Sort API Reference
description: Parallel PDQSort (Pattern-Defeating Quicksort)
sidebar:
  order: 3
slug: v2.0.0-zig0.15.3/api/sort-api
---

Parallel PDQSort (Pattern-Defeating Quicksort).

## Access

```zig
// Via api.zig
blitz.sort(...)
blitz.sortAsc(...)
blitz.sortDesc(...)
blitz.sortByKey(...)
blitz.sortByCachedKey(...)
```

***

## Basic Sorting

### `sort(T, slice, lessThan) void`

In-place parallel sort with custom comparator.

```zig
var data = [_]i64{ 5, 2, 8, 1, 9 };

blitz.sort(i64, &data, struct {
    fn lt(a: i64, b: i64) bool { return a < b; }
}.lt);

// data is now [1, 2, 5, 8, 9]
```

### `sortAsc(T, slice) void`

Sort in ascending order using natural `<` comparison.

```zig
var data = [_]i64{ 5, 2, 8, 1, 9 };
blitz.sortAsc(i64, &data);
// data is now [1, 2, 5, 8, 9]
```

### `sortDesc(T, slice) void`

Sort in descending order.

```zig
var data = [_]i64{ 5, 2, 8, 1, 9 };
blitz.sortDesc(i64, &data);
// data is now [9, 8, 5, 2, 1]
```

***

## Sort by Key

### `sortByKey(T, K, slice, keyFn) void`

Sort using a key extraction function. Key is computed for each comparison.

```zig
const Person = struct { name: []const u8, age: u32 };
var people: []Person = ...;

// Sort by age
blitz.sortByKey(Person, u32, people, struct {
    fn key(p: Person) u32 { return p.age; }
}.key);
```

### `sortByCachedKey(T, K, allocator, slice, keyFn) !void`

Two-phase sort: compute keys in parallel, then sort by cached keys.

**When to use:**

* Key function is expensive (>100ns per call)
* Large arrays (>10K elements)
* Key computation parallelizes well

```zig
try blitz.sortByCachedKey(Person, u32, allocator, people, struct {
    fn expensiveKey(p: Person) u32 {
        return computeComplexScore(p);  // Expensive!
    }
}.expensiveKey);
```

***

## Comparator Requirements

Comparators must define a strict weak ordering:

```zig
// Valid comparator
fn lessThan(a: T, b: T) bool {
    return a < b;  // Strict: a < a is false
}

// Invalid (not strict)
fn badLessThan(a: T, b: T) bool {
    return a <= b;  // Wrong: a <= a is true
}
```

**Properties:**

1. **Irreflexive**: `lessThan(a, a)` is `false`
2. **Asymmetric**: if `lessThan(a, b)` then `!lessThan(b, a)`
3. **Transitive**: if `lessThan(a, b)` and `lessThan(b, c)` then `lessThan(a, c)`

***

## Performance Characteristics

| Array Size | Expected Performance |
|------------|---------------------|
| \< 24 | Insertion sort (immediate) |
| 24 - 8192 | Sequential PDQSort |
| > 8192 | Parallel PDQSort |

**Benchmark (10M random i64):**

```
std.mem.sort: 4,644 ms
Blitz PDQSort:  430 ms  (10.8x faster)
```

***

## Algorithm Selection

PDQSort automatically adapts:

| Pattern Detected | Strategy |
|------------------|----------|
| Random | Quicksort partitioning |
| Nearly sorted | Few swaps, fast |
| Reverse sorted | Pattern breaking + quicksort |
| Many duplicates | Three-way partition |
| Bad pivots | Fallback to heapsort |

***

## Memory Usage

| Function | Extra Memory |
|----------|--------------|
| `sort` | O(log n) stack |
| `sortAsc/sortDesc` | O(log n) stack |
| `sortByKey` | O(log n) stack |
| `sortByCachedKey` | O(n) for keys + O(n) for indices |

***

## Stability

**Blitz sort is NOT stable.** Equal elements may be reordered.

For stable sorting:

```zig
// Use std library stable sort
std.mem.sort(T, data, {}, lessThanFn);
```

***

## Thread Safety

* Sorting the same array from multiple threads: **NOT SAFE**
* Sorting different arrays concurrently: **SAFE**

***

## Example: Sort Structs

```zig
const Person = struct {
    name: []const u8,
    age: u32,
    score: i32,
};

var people: []Person = ...;

// Sort by age (ascending)
blitz.sortByKey(Person, u32, people, struct {
    fn key(p: Person) u32 { return p.age; }
}.key);

// Sort by score (descending) - negate for descending
blitz.sort(Person, people, struct {
    fn lt(a: Person, b: Person) bool {
        return a.score > b.score;  // Note: > for descending
    }
}.lt);

// Multi-field sort
blitz.sort(Person, people, struct {
    fn lt(a: Person, b: Person) bool {
        if (a.age != b.age) return a.age < b.age;
        return a.score > b.score;  // Secondary: score descending
    }
}.lt);
```
