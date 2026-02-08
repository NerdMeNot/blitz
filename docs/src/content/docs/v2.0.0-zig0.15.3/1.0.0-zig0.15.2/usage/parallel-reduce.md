---
title: Parallel Reduce
description: Map-reduce pattern for aggregating data in parallel
slug: v2.0.0-zig0.15.3/1.0.0-zig0.15.2/usage/parallel-reduce
---

Map-reduce pattern for aggregating data in parallel.

## Basic Usage

```zig
const blitz = @import("blitz");

// Sum all elements
const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

const sum = blitz.parallelReduce(
    i64,              // Result type
    data.len,         // Element count
    0,                // Identity element
    []const i64,      // Context type
    &data,            // Context value
    struct {
        fn map(d: []const i64, i: usize) i64 {
            return d[i];
        }
    }.map,
    struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;
        }
    }.combine,
);
// sum = 55
```

## How It Works

```
Data: [1, 2, 3, 4, 5, 6, 7, 8]

Step 1: Parallel map (each worker processes a chunk)
┌─────────────┬─────────────┬─────────────┬─────────────┐
│ Worker 0    │ Worker 1    │ Worker 2    │ Worker 3    │
│ map(0,1)    │ map(2,3)    │ map(4,5)    │ map(6,7)    │
│ 1+2=3       │ 3+4=7       │ 5+6=11      │ 7+8=15      │
└─────────────┴─────────────┴─────────────┴─────────────┘

Step 2: Parallel combine (tree reduction)
         3 + 7 = 10              11 + 15 = 26
              \                      /
               \                    /
                10 + 26 = 36 (final result)
```

## Parameters Explained

| Parameter | Purpose |
|-----------|---------|
| `T` | Result type (must be copyable) |
| `n` | Number of elements to process |
| `identity` | Starting value (0 for sum, 1 for product) |
| `Context` | Type holding data/parameters |
| `ctx` | Context instance |
| `map` | `fn(Context, usize) -> T` - Extract/transform element |
| `combine` | `fn(T, T) -> T` - Merge two results |

## Identity Element Rules

| Operation | Identity | Why |
|-----------|----------|-----|
| Sum | 0 | x + 0 = x |
| Product | 1 | x \* 1 = x |
| Min | maxInt | min(x, maxInt) = x |
| Max | minInt | max(x, minInt) = x |
| And | true | x && true = x |
| Or | false | x || false = x |

## Common Patterns

### Sum

```zig
const sum = blitz.parallelReduce(
    i64, data.len, 0,
    []const i64, data,
    struct { fn map(d: []const i64, i: usize) i64 { return d[i]; } }.map,
    struct { fn add(a: i64, b: i64) i64 { return a + b; } }.add,
);
```

### Max

```zig
const max = blitz.parallelReduce(
    i64, data.len, std.math.minInt(i64),
    []const i64, data,
    struct { fn map(d: []const i64, i: usize) i64 { return d[i]; } }.map,
    struct { fn max(a: i64, b: i64) i64 { return @max(a, b); } }.max,
);
```

### Count Matching

```zig
const count = blitz.parallelReduce(
    usize, data.len, 0,
    []const i64, data,
    struct {
        fn map(d: []const i64, i: usize) usize {
            return if (d[i] > 0) 1 else 0;
        }
    }.map,
    struct {
        fn add(a: usize, b: usize) usize { return a + b; }
    }.add,
);
```

### Dot Product

```zig
const Context = struct { a: []const f64, b: []const f64 };

const dot = blitz.parallelReduce(
    f64, a.len, 0.0,
    Context, .{ .a = a, .b = b },
    struct {
        fn map(ctx: Context, i: usize) f64 {
            return ctx.a[i] * ctx.b[i];
        }
    }.map,
    struct {
        fn add(x: f64, y: f64) f64 { return x + y; }
    }.add,
);
```

## With Custom Grain Size

```zig
const result = blitz.parallelReduceWithGrain(
    T, n, identity,
    Context, ctx,
    mapFn, combineFn,
    4096,  // grain size
);
```

## Chunked Reduce

Process chunks instead of individual elements:

```zig
const sum = blitz.parallelReduceChunked(
    i64,           // Result type
    i64,           // Element type
    data,          // Slice
    0,             // Identity
    struct {
        fn processChunk(chunk: []const i64) i64 {
            var total: i64 = 0;
            for (chunk) |v| total += v;
            return total;
        }
    }.processChunk,
    struct {
        fn combine(a: i64, b: i64) i64 { return a + b; }
    }.combine,
);
```

## Combine Must Be Associative!

**Important**: The combine function must be associative:

```
combine(combine(a, b), c) == combine(a, combine(b, c))
```

**Valid:**

* Addition: (1+2)+3 = 1+(2+3) = 6
* Multiplication: (2*3)*4 = 2*(3*4) = 24
* Min/Max: max(max(1,2),3) = max(1,max(2,3)) = 3

**Invalid:**

* Subtraction: (5-3)-1 ≠ 5-(3-1)
* Division: (8/4)/2 ≠ 8/(4/2)

## Performance: Parallel vs Sequential

```zig
// For small data, sequential may be faster
if (data.len < 10_000) {
    // Sequential reduce
    var sum: i64 = 0;
    for (data) |v| sum += v;
    return sum;
} else {
    // Parallel reduce
    return blitz.parallelReduce(...);
}
```

Use `blitz.internal.shouldParallelize(.sum, data.len)` for automatic decision.
