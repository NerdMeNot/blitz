---
title: Parallel Iterators
description: Rayon-style composable parallel iterators for expressive data processing
slug: v1.0.0-zig0.15.2/1.0.0-zig0.15.2/usage/iterators
---

Rayon-style composable parallel iterators for expressive data processing.

## Basic Usage

```zig
const blitz = @import("blitz");

const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

// Create an iterator
const it = blitz.iter(i64, &data);

// Aggregations
const sum = it.sum();     // 55
const min = it.min();     // 1
const max = it.max();     // 10
const count = it.count(); // 10
```

## Available Operations

### Aggregations

```zig
const it = blitz.iter(i64, data);

const sum = it.sum();           // Sum all elements
const min_val = it.min();       // Minimum (returns ?T)
const max_val = it.max();       // Maximum (returns ?T)
const count = it.count();       // Element count
```

### Find Operations

```zig
const it = blitz.iter(i64, data);

// Find any element matching predicate (fast, non-deterministic)
const found = it.findAny(isNegative);  // Returns ?T

// Find first matching (deterministic, returns index + value)
const first = it.findFirst(isNegative);  // Returns ?{index, value}

// Find last matching (deterministic)
const last = it.findLast(isNegative);    // Returns ?{index, value}

// Get just the position
const pos = it.position(isNegative);     // Returns ?usize
```

### Predicates (with Early Exit)

```zig
const it = blitz.iter(i64, data);

// Check if any element matches
const hasNegative = it.any(isNegative);  // true/false

// Check if all elements match
const allPositive = it.all(isPositive);  // true/false
```

### Min/Max by Key or Comparator

```zig
const Person = struct { name: []const u8, age: u32 };
const people: []const Person = ...;

const it = blitz.iter(Person, people);

// By custom comparator
const youngest = it.minBy(struct {
    fn cmp(a: Person, b: Person) std.math.Order {
        return std.math.order(a.age, b.age);
    }
}.cmp);

// By key function
const oldest = it.maxByKey(u32, struct {
    fn key(p: Person) u32 { return p.age; }
}.key);
```

## Mutable Iterators

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };

// Create mutable iterator
var it = blitz.iterMut(i64, &data);

// Map in place
it.mapInPlace(struct {
    fn double(x: i64) i64 { return x * 2; }
}.double);
// data is now [2, 4, 6, 8, 10]

// Fill with value
it.fill(0);
// data is now [0, 0, 0, 0, 0]
```

## Chunk Iteration

Process data in fixed-size chunks:

```zig
const it = blitz.iter(f64, data);
const chunks = it.chunks_iter(1000);  // 1000 elements per chunk

// Count chunks
const num_chunks = chunks.count();

// Process each chunk
chunks.forEach(struct {
    fn process(chunk: []const f64) void {
        // Process this chunk
    }
}.process);

// Reduce over chunks
const total = chunks.reduce(f64, 0.0,
    struct {
        fn chunkSum(chunk: []const f64) f64 {
            var sum: f64 = 0;
            for (chunk) |v| sum += v;
            return sum;
        }
    }.chunkSum,
    struct {
        fn combine(a: f64, b: f64) f64 { return a + b; }
    }.combine,
);
```

## Enumerated Iteration

Iterate with indices:

```zig
const it = blitz.iter(i64, data);
const enum_it = it.enumerate_iter();

// Check indexed predicate
const hasOddAtEvenIndex = enum_it.any(struct {
    fn pred(index: usize, value: i64) bool {
        return index % 2 == 0 and value % 2 == 1;
    }
}.pred);

// With custom start offset
const offset_it = it.enumerateFrom(1000);
```

## Range Iteration

Iterate over numeric ranges:

```zig
// Range [0, 1000)
const range_it = blitz.range(0, 1000);

// Sum indices
const sum = range_it.sum(i64, struct {
    fn value(i: usize) i64 { return @intCast(i); }
}.value);

// Process each index
range_it.forEach(struct {
    fn process(i: usize) void {
        // Handle index i
    }
}.process);
```

## Custom Reduce

```zig
const it = blitz.iter(i64, data);

// General reduce with any operation
const product = it.reduce(1, struct {
    fn mul(a: i64, b: i64) i64 { return a * b; }
}.mul);
```

## For Each

```zig
const it = blitz.iter(i64, data);

it.forEach(struct {
    fn process(value: i64) void {
        std.debug.print("Value: {}\n", .{value});
    }
}.process);
```

## Collect to Array

```zig
const it = blitz.iter(i64, data);

// Collect (identity copy)
const copy = try it.collect(allocator);
defer allocator.free(copy);
```

## Chaining (Map)

```zig
const it = blitz.iter(i64, data);

// Map creates new iterator with transformed values
const mapped = it.map(struct {
    fn square(x: i64) i64 { return x * x; }
}.square);

const sumOfSquares = mapped.sum();
```

## Performance Comparison

```
Operation: Find minimum in 10M elements

Scalar loop:        45 ms
Parallel iter.min:  8 ms  (5.6x faster)

Operation: Any negative in 10M elements

Scalar loop:           35 ms
Parallel any (early):  0.07 ms (500x faster with early exit)
```

## Iterators vs parallelFor

| | `iter()` / `iterMut()` | `parallelFor()` |
|---|---|---|
| **Best for** | Aggregations, search, transforms | Custom range-based work |
| **API style** | Fluent, chainable | Context struct + body function |
| **Early exit** | Built-in (`findAny`, `any`, `all`) | Manual via `parallelForWithEarlyExit` |
| **Return value** | Direct (sum, min, max, etc.) | None (void) — write to context |
| **Grain control** | Automatic | Manual with `WithGrain` variants |
| **Code verbosity** | Concise | More explicit |

**Rule of thumb**: Use iterators when a built-in operation fits your use case. Use `parallelFor` when you need full control over the loop body or are writing to complex output structures.

## Best Practices

1. **Use built-in aggregations** for sum/min/max - optimized parallel reduction
2. **Use findAny** when order doesn't matter - faster than findFirst
3. **Use predicates** (any/all) for boolean checks - early exit is fast
4. **Prefer minByKey/maxByKey** over minBy when you have a natural key
5. **Use chunks** for complex per-chunk processing
