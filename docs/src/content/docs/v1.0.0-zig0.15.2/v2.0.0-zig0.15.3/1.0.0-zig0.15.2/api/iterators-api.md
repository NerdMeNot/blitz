---
title: Iterators API Reference
description: Complete reference for Blitz's Rayon-style parallel iterators
sidebar:
  order: 2
slug: v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/1.0.0-zig0.15.2/api/iterators-api
---

Complete reference for Blitz's Rayon-style parallel iterators.

## Overview

Blitz provides three iterator types:

| Type | Creation | Purpose |
|------|----------|---------|
| `ParIter(T)` | `blitz.iter(T, slice)` | Read-only parallel iteration |
| `ParIterMut(T)` | `blitz.iterMut(T, slice)` | Mutable parallel iteration |
| `RangeIter` | `blitz.range(start, end)` | Index range iteration |

## Creating Iterators

### `blitz.iter(T, slice) -> ParIter(T)`

Create an immutable parallel iterator over a slice.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
const it = blitz.iter(i64, &data);

// All operations are parallel and thread-safe
const sum = it.sum();  // 15
```

**Thread Safety:** Read-only access, fully thread-safe.

***

### `blitz.iterMut(T, slice) -> ParIterMut(T)`

Create a mutable parallel iterator over a slice.

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };
var it = blitz.iterMut(i64, &data);

it.mapInPlace(double);  // data is now [2, 4, 6, 8, 10]

fn double(x: i64) i64 { return x * 2; }
```

**Thread Safety:** Each element written by exactly one thread (disjoint access).

***

### `blitz.range(start, end) -> RangeIter`

Create an iterator over the index range `[start, end)`.

```zig
const it = blitz.range(0, 1000);
it.forEach(processIndex);

fn processIndex(i: usize) void {
    // Process index i
}
```

***

## ParIter(T) Methods

### Aggregations

#### `sum() -> T`

Compute the sum of all elements using parallel reduction.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
const sum = blitz.iter(i64, &data).sum();  // 15
```

**Returns:** Sum of all elements (0 for empty slice)

***

#### `min() -> ?T`

Find the minimum element using parallel reduction.

```zig
const min = blitz.iter(i64, &data).min();  // ?i64
if (min) |m| {
    std.debug.print("Min: {}\n", .{m});
}
```

**Returns:** `?T` - The minimum, or `null` for empty slice

***

#### `max() -> ?T`

Find the maximum element using parallel reduction.

```zig
const max = blitz.iter(i64, &data).max();  // ?i64
```

**Returns:** `?T` - The maximum, or `null` for empty slice

***

#### `count() -> usize`

Count the number of elements.

```zig
const n = blitz.iter(i64, &data).count();  // 5
```

***

### Custom Reduce

#### `reduce(identity, reducer) -> T`

General parallel reduction with a custom binary operation.

```zig
const product = blitz.iter(i64, &data).reduce(1, multiply);

fn multiply(a: i64, b: i64) i64 { return a * b; }
```

**Parameters:**

* `identity`: `T` - Identity value for the operation (e.g., 0 for sum, 1 for product)
* `reducer`: `fn(T, T) T` - Associative binary operation

**Requirements:** The reducer must be associative: `f(f(a,b), c) == f(a, f(b,c))`

***

### Find Operations

#### `findAny(predicate) -> ?T`

Find any element matching the predicate. Non-deterministic order, fastest search.

```zig
const found = blitz.iter(i64, &data).findAny(isNegative);

fn isNegative(x: i64) bool { return x < 0; }
```

**Performance:** Supports early exit - stops when any thread finds a match.

***

#### `findFirst(predicate) -> ?FindResult(T)`

Find the first element matching the predicate (deterministic order).

```zig
const result = blitz.iter(i64, &data).findFirst(isNegative);
if (result) |r| {
    std.debug.print("First negative at index {}: {}\n", .{ r.index, r.value });
}
```

**Returns:** `?struct { index: usize, value: T }` - First match with index

***

#### `findLast(predicate) -> ?FindResult(T)`

Find the last element matching the predicate (deterministic order).

***

#### `position(predicate) -> ?usize`

Find the index of the first matching element.

```zig
const pos = blitz.iter(i64, &data).position(isNegative);
```

***

#### `rposition(predicate) -> ?usize`

Find the index of the last matching element.

***

### Predicates (Early Exit)

#### `any(predicate) -> bool`

Check if any element matches. Short-circuits on first match.

```zig
const hasNegative = blitz.iter(i64, &data).any(isNegative);
```

**Performance:** Early exit when match found - can be 100-1000x faster than full scan.

***

#### `all(predicate) -> bool`

Check if all elements match. Short-circuits on first non-match.

```zig
const allPositive = blitz.iter(i64, &data).all(isPositive);

fn isPositive(x: i64) bool { return x > 0; }
```

***

### Min/Max by Comparator or Key

#### `minBy(comparator) -> ?T`

Find minimum using a custom comparator.

```zig
const Person = struct { name: []const u8, age: u32 };

const youngest = blitz.iter(Person, &people).minBy(compareByAge);

fn compareByAge(a: Person, b: Person) std.math.Order {
    return std.math.order(a.age, b.age);
}
```

***

#### `maxBy(comparator) -> ?T`

Find maximum using a custom comparator.

***

#### `minByKey(K, key_fn) -> ?T`

Find minimum by extracting a comparable key.

```zig
const youngest = blitz.iter(Person, &people).minByKey(u32, getAge);

fn getAge(p: Person) u32 { return p.age; }
```

***

#### `maxByKey(K, key_fn) -> ?T`

Find maximum by extracting a comparable key.

***

### Transformations

#### `map(func) -> MappedIter`

Create a new iterator with transformed values (lazy).

```zig
const squared = blitz.iter(i64, &data).map(square);
const sumOfSquares = squared.sum();

fn square(x: i64) i64 { return x * x; }
```

**Note:** Lazy evaluation - transformation applied when consumed.

***

#### `forEach(func) -> void`

Execute a function for each element in parallel.

```zig
blitz.iter(i64, &data).forEach(process);

fn process(x: i64) void {
    std.debug.print("Value: {}\n", .{x});
}
```

**Note:** No ordering guarantee - elements processed in parallel.

***

#### `collect(allocator) -> ![]T`

Collect elements into a new allocated array.

```zig
const copy = try blitz.iter(i64, &data).collect(allocator);
defer allocator.free(copy);
```

***

### Sub-Iterators

#### `chunks_iter(chunk_size) -> ChunksIter(T)`

Create an iterator over fixed-size chunks.

```zig
const chunks = blitz.iter(f64, &data).chunks_iter(1000);
const numChunks = chunks.count();  // ceil(data.len / 1000)
```

***

#### `enumerate_iter() -> EnumerateIter(T)`

Create an iterator with indices starting at 0.

```zig
const enum_it = blitz.iter(i64, &data).enumerate_iter();
enum_it.forEach(processWithIndex);

fn processWithIndex(index: usize, value: i64) void {
    // ...
}
```

***

## ParIterMut(T) Methods

Includes all `ParIter` methods plus:

### `mapInPlace(func) -> void`

Transform each element in place.

```zig
var it = blitz.iterMut(i64, &data);
it.mapInPlace(double);

fn double(x: i64) i64 { return x * 2; }
```

**Thread Safety:** Each element written by exactly one thread.

***

### `fill(value) -> void`

Set all elements to a value (parallel memset).

```zig
var it = blitz.iterMut(i64, &data);
it.fill(0);  // Zero all elements
```

***

## RangeIter Methods

### `sum(T, value_fn) -> T`

Sum values generated from indices.

```zig
const total = blitz.range(0, 1000).sum(i64, identity);

fn identity(i: usize) i64 { return @intCast(i); }
```

***

### `forEach(func) -> void`

Process each index in parallel.

```zig
blitz.range(0, 1000).forEach(processIndex);

fn processIndex(i: usize) void {
    // Process index i
}
```

***

## Performance Comparison

| Operation | Sequential | Parallel (10 cores) | Speedup |
|-----------|-----------|---------------------|---------|
| sum (100M i64) | 31 ms | 3.1 ms | 10x |
| min (100M i64) | 45 ms | 8 ms | 5.6x |
| any (10M, early exit) | 35 ms | 0.07 ms | 500x |
| findAny (10M) | 35 ms | 0.1 ms | 350x |
| mapInPlace (10M) | 25 ms | 3 ms | 8x |

***

## Best Practices

1. **Use `findAny` over `findFirst`** when order doesn't matter - it's faster
2. **Use `any`/`all` for boolean checks** - early exit is very fast
3. **Use built-in aggregations** (`sum`, `min`, `max`) - optimized parallel reduction
4. **Use `minByKey`/`maxByKey`** when you have a natural key - cleaner than `minBy`
5. **Use `chunks_iter`** for complex per-chunk processing with custom reduction
6. **Don't parallelize tiny data** - overhead exceeds benefit below ~1000 elements
