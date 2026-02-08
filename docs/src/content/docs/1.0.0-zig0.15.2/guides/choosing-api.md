---
title: Choosing the Right API
description: Decision guide for selecting the best Blitz API for your parallel workload
slug: 1.0.0-zig0.15.2/guides/choosing-api
---

Blitz offers several parallel APIs, each optimized for different patterns. This guide helps you pick the right one.

## Quick Decision Guide

**Start here: "I want to..."**

| I want to... | Use | Example |
|--------------|-----|---------|
| Process every element in an array | `parallelFor` | Apply transform to each pixel |
| Sum / min / max an array | `iter().sum()` / `.min()` / `.max()` | Total revenue, highest score |
| Search for an element | `iter().findAny()` | Find first negative value |
| Check a condition on all elements | `iter().any()` / `.all()` | Any NaN? All positive? |
| Transform array to new array | `parallelCollect` | Convert i32\[] to f64\[] |
| Transform array in place | `parallelMapInPlace` or `iterMut().mapInPlace()` | Normalize pixel values |
| Run 2-8 independent tasks | `join` | Compute stats + histogram |
| Run 2-64 dynamic tasks | `scope` + `spawn` | Load multiple files |
| Run tasks that may fail | `tryJoin` / `tryForEach` / `tryReduce` | Parse + validate data |
| Sort an array | `sortAsc` / `sortDesc` / `sort` | Sort by timestamp |
| Merge many slices into one | `parallelFlatten` | Combine per-thread results |
| Write to scattered positions | `parallelScatter` | Build hash table |
| Run code on every thread | `broadcast` | Initialize thread-local state |
| Fire-and-forget background work | `spawn` | Write audit log |
| Aggregate with custom logic | `parallelReduce` | Weighted average, dot product |

## API Comparison

### Data Parallelism: iter vs parallelFor vs parallelCollect

These three APIs all process array elements in parallel, but they serve different purposes:

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
```

**`iter()` -- Built-in aggregations and searches**

```zig
const sum = blitz.iter(i64, &data).sum();       // 15
const min = blitz.iter(i64, &data).min();        // 1
const found = blitz.iter(i64, &data).findAny(pred);
```

Best for: Standard aggregations (sum, min, max, count), searches (findAny, findFirst), and predicates (any, all). Zero boilerplate.

**`parallelFor` -- Custom chunk processing**

```zig
blitz.parallelFor(data.len, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) void {
        for (c.data[start..end]) |*v| {
            v.* = expensiveTransform(v.*);
        }
    }
}.body);
```

Best for: Side effects, in-place mutation, or when you need the chunk boundaries `(start, end)` for efficient batch processing.

**`parallelCollect` -- Map to a new array**

```zig
blitz.parallelCollect(i64, f64, &input, &output, void, {}, struct {
    fn transform(_: void, x: i64) f64 {
        return @as(f64, @floatFromInt(x)) * 0.1;
    }
}.transform);
```

Best for: Transforming an array of type T into an array of type U, producing a new output array.

**Summary**:

| Feature | `iter()` | `parallelFor` | `parallelCollect` |
|---------|----------|---------------|-------------------|
| Aggregation (sum, min) | Built-in | Manual | No |
| Search (find, any, all) | Built-in | Manual | No |
| In-place mutation | `iterMut` | Yes | No |
| Map T -> U | No | Manual | Built-in |
| Chunk access (start, end) | No | Yes | No |
| Custom grain size | No | `WithGrain` | `WithGrain` |
| Boilerplate | Low | Medium | Medium |

### Task Parallelism: join vs scope vs spawn

These APIs run independent tasks in parallel, differing in flexibility and guarantees:

**`join` -- Fixed tasks with results**

```zig
const result = blitz.join(.{
    .a = .{ computeA, arg_a },
    .b = .{ computeB, arg_b },
});
// result.a, result.b
```

Best for: 2-8 tasks with known types and return values. Supports heterogeneous return types. Works with recursive divide-and-conquer.

**`scope` + `spawn` -- Dynamic task set**

```zig
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        s.spawn(task1);
        s.spawn(task2);
        if (condition) s.spawn(task3);
    }
}.run);
```

Best for: Variable number of tasks decided at runtime. Tasks are void (no return values). Maximum 64 tasks.

**`spawn` -- Fire-and-forget**

```zig
blitz.spawn(struct {
    fn run() void { writeLog(); }
}.run);
// Returns immediately
```

Best for: Background work where the caller does not need the result.

**Summary**:

| Feature | `join` | `scope` | `spawn` |
|---------|--------|---------|---------|
| Max tasks | 8 | 64 | 1 |
| Return values | Yes (per task) | No | No |
| Wait for completion | Yes | Yes (at scope exit) | No |
| Dynamic task count | No (comptime) | Yes (runtime) | N/A |
| Recursive | Yes | No | No |
| Error variants | `tryJoin` | No | No |

### Reduction: iter vs parallelReduce

**`iter()` aggregations** are best for standard operations:

```zig
const sum = blitz.iter(i64, data).sum();
const count = blitz.iter(i64, data).count();
```

**`parallelReduce`** is best for custom reductions:

```zig
// Dot product (no built-in for this)
const dot = blitz.parallelReduce(
    f64, a.len, 0.0,
    DotCtx, .{ .a = a, .b = b },
    struct {
        fn map(ctx: DotCtx, i: usize) f64 {
            return ctx.a[i] * ctx.b[i];
        }
    }.map,
    struct {
        fn add(x: f64, y: f64) f64 { return x + y; }
    }.add,
);
```

| Feature | `iter()` | `parallelReduce` |
|---------|----------|------------------|
| sum, min, max, count | Built-in | Manual |
| Custom reduction | `reduce(identity, combineFn)` | Full control |
| Map + reduce | Limited | Built-in (map + combine) |
| Error handling | No | `tryReduce` |
| Grain control | No | `WithGrain` |

### Error Handling: try Variants

Every core API has an error-safe variant:

| Infallible | Fallible | Guarantee |
|------------|----------|-----------|
| `join` | `tryJoin` | All tasks complete before error propagates |
| `parallelFor` | `tryForEach` | All chunks complete before error propagates |
| `parallelReduce` | `tryReduce` | All reductions complete before error propagates |

Use `try*` variants when your parallel body can return a Zig error. See [Error Handling](/1.0.0-zig0.15.2/usage/error-handling/) for details.

## Decision Flowchart

```
Do you have an array/slice to process?
├── Yes
│   ├── Need sum/min/max/count?
│   │   └── iter().sum() / .min() / .max() / .count()
│   ├── Need to search/check?
│   │   └── iter().findAny() / .any() / .all()
│   ├── Need to map T[] -> U[]?
│   │   └── parallelCollect()
│   ├── Need to transform in place?
│   │   └── parallelMapInPlace() or iterMut().mapInPlace()
│   ├── Need to sort?
│   │   └── sortAsc() / sortDesc() / sort() / sortByKey()
│   ├── Need custom reduction?
│   │   └── parallelReduce()
│   └── Need chunk-based processing?
│       └── parallelFor()
│
├── Do you have independent tasks?
│   ├── 2-8 tasks with return values?
│   │   └── join()
│   ├── Dynamic number of tasks (up to 64)?
│   │   └── scope() + spawn()
│   ├── Tasks can fail?
│   │   └── tryJoin()
│   └── Fire-and-forget?
│       └── spawn()
│
├── Need to combine/flatten results?
│   ├── Merge slices into one?
│   │   └── parallelFlatten()
│   └── Scatter to indexed positions?
│       └── parallelScatter()
│
└── Need per-thread operations?
    └── broadcast()
```

## Performance Characteristics

| API | Overhead | Scalability | Best Data Size |
|-----|----------|-------------|----------------|
| `iter().sum()` | Very low | Excellent | > 10K |
| `iter().findAny()` | Very low | Excellent (early exit) | Any |
| `parallelFor` | Low | Excellent | > 10K |
| `parallelReduce` | Low | Excellent | > 10K |
| `parallelCollect` | Low | Excellent | > 10K |
| `join` (2 tasks) | ~10 ns | 2x max | N/A |
| `join` (8 tasks) | ~50 ns | 8x max | N/A |
| `scope` (N tasks) | ~100 ns | Nx max | N/A |
| `sort` | Medium | Good | > 10K |
| `parallelFlatten` | Low | Good | > 100 slices |
| `broadcast` | Low | Linear | N/A |

## Examples by Domain

### Scientific Computing

```zig
// Matrix operations
const dot = blitz.parallelReduce(f64, n, 0.0, ctx_type, ctx, mapFn, addFn);
blitz.parallelFor(n, ctx_type, ctx, matmulBody);

// Statistical analysis
const result = blitz.join(.{
    .mean = .{ computeMean, data },
    .stddev = .{ computeStdDev, data },
    .median = .{ computeMedian, data },
});
```

### Data Processing

```zig
// ETL pipeline
blitz.parallelCollect(RawRecord, CleanRecord, raw, clean, void, {}, cleanFn);
blitz.sortByKey(CleanRecord, u64, clean, timestampKey);
const total = blitz.iter(CleanRecord, clean).reduce(0, sumRevenue);
```

### Game Development

```zig
// Entity updates
blitz.parallelFor(entities.len, EntityCtx, ctx, updatePhysics);
blitz.parallelFor(entities.len, EntityCtx, ctx, updateAI);

// Spatial queries
const nearest = blitz.iter(Entity, entities).minByKey(f64, distToPlayer);
```

### Image Processing

```zig
// Per-pixel transform
blitz.parallelMapInPlace(Pixel, pixels, BrightnessCtx, ctx, adjustBrightness);

// Histogram
const histogram = blitz.parallelReduce(
    [256]u32, pixels.len, .{0} ** 256,
    []const Pixel, pixels, histMap, histCombine,
);
```
