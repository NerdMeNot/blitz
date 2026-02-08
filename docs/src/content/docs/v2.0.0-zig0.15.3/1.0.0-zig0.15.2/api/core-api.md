---
title: Core API Reference
description: Comprehensive documentation for all Blitz APIs
sidebar:
  order: 1
slug: v2.0.0-zig0.15.3/1.0.0-zig0.15.2/api/core-api
---

This document provides comprehensive documentation for all Blitz APIs, including function signatures, parameters, return types, examples, limitations, and best practices.

## Initialization

Blitz uses a global thread pool that auto-initializes on first use. You can also initialize explicitly for custom configuration.

### `init() !void`

Initialize the thread pool with default settings (CPU count - 1 workers).

```zig
try blitz.init();
defer blitz.deinit();
```

**Errors**: Returns error if thread creation fails.

**Notes**:

* Safe to call multiple times (no-op if already initialized)
* Auto-called on first API use if not explicitly initialized

### `initWithConfig(config: Config) !void`

Initialize with custom configuration.

```zig
try blitz.initWithConfig(.{
    .background_worker_count = 8,
});
defer blitz.deinit();
```

**Parameters**:
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `background_worker_count` | `?usize` | `null` (auto) | Number of worker threads. `null` = CPU count - 1 |

### `deinit() void`

Shut down the thread pool and release resources.

```zig
blitz.deinit();
```

**Notes**:

* Waits for all pending work to complete
* Safe to call multiple times
* Must be called before program exit to avoid resource leaks

### `isInitialized() bool`

Check if the thread pool is initialized.

```zig
if (!blitz.isInitialized()) {
    try blitz.init();
}
```

### `numWorkers() usize`

Get the number of worker threads.

```zig
const workers = blitz.numWorkers();
std.debug.print("Using {} workers\n", .{workers});
```

***

## Iterator API

The iterator API is the **recommended** way to use Blitz. It provides composable, chainable operations that automatically parallelize when beneficial.

### Creating Iterators

#### `iter(T, slice) ParallelSliceIterator(T)`

Create an immutable parallel iterator over a slice.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
const it = blitz.iter(i64, &data);
const sum = it.sum();  // 15
```

#### `iterMut(T, slice) ParallelMutSliceIterator(T)`

Create a mutable parallel iterator for in-place operations.

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };
blitz.iterMut(i64, &data).mapInPlace(double);
// data is now [2, 4, 6, 8, 10]
```

#### `range(start, end) RangeIterator`

Create a parallel iterator over an index range.

```zig
// Sum of 0 + 1 + 2 + ... + 99
const sum = blitz.range(0, 100).sum(i64, identity);

// Execute function for each index
blitz.range(0, 1000).forEach(processIndex);
```

***

### Aggregation Methods

#### `.sum() T`

Compute the sum of all elements in parallel.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
const total = blitz.iter(i64, &data).sum();  // 15
```

#### `.min() ?T`

Find the minimum element in parallel.

```zig
const data = [_]i64{ 5, 2, 8, 1, 9 };
if (blitz.iter(i64, &data).min()) |m| {
    std.debug.print("Min: {}\n", .{m});  // Min: 1
}
```

#### `.max() ?T`

Find the maximum element in parallel.

```zig
const data = [_]i64{ 5, 2, 8, 1, 9 };
if (blitz.iter(i64, &data).max()) |m| {
    std.debug.print("Max: {}\n", .{m});  // Max: 9
}
```

#### `.reduce(identity, combine) T`

Perform a custom parallel reduction.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };

// Product of all elements
const product = blitz.iter(i64, &data).reduce(1, struct {
    fn mul(a: i64, b: i64) i64 { return a * b; }
}.mul);  // 120
```

**Requirements**:

* `combine` must be **associative**: `combine(a, combine(b, c)) == combine(combine(a, b), c)`
* `identity` must be the **identity element**: `combine(identity, x) == x`

***

### Search Methods

All search methods support **early exit** - they stop processing as soon as the result is determined.

#### `.findAny(predicate) ?T`

Find any element matching the predicate. **Fastest** search method but non-deterministic.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6 };

const even = blitz.iter(i64, &data).findAny(struct {
    fn isEven(x: i64) bool { return @mod(x, 2) == 0; }
}.isEven);
```

#### `.findFirst(predicate) ?FindResult(T)`

Find the **leftmost** element matching the predicate.

```zig
if (blitz.iter(i64, &data).findFirst(isEven)) |result| {
    std.debug.print("First even: {} at index {}\n", .{ result.value, result.index });
}
```

#### `.any(predicate) bool`

Check if **any** element matches the predicate. Supports early exit.

```zig
const has_even = blitz.iter(i64, &data).any(isEven);
```

#### `.all(predicate) bool`

Check if **all** elements match the predicate. Supports early exit.

```zig
const all_positive = blitz.iter(i64, &data).all(isPositive);
```

***

### Mutation Methods

These methods require `iterMut` (mutable iterator).

#### `.mapInPlace(transform) void`

Transform each element in place.

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };
blitz.iterMut(i64, &data).mapInPlace(struct {
    fn double(x: i64) i64 { return x * 2; }
}.double);
// data is now [2, 4, 6, 8, 10]
```

#### `.fill(value) void`

Set all elements to a value.

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };
blitz.iterMut(i64, &data).fill(0);
// data is now [0, 0, 0, 0, 0]
```

***

## Fork-Join API

For divide-and-conquer algorithms and parallel task execution.

### `join(tasks) Result`

Execute multiple tasks in parallel and collect results.

```zig
const result = blitz.join(.{
    .user = .{ fetchUserById, user_id },
    .posts = .{ fetchPostsByUser, user_id },
});
// result.user, result.posts
```

**Parameters**: Anonymous struct where each field is either:

* A function pointer (no arguments)
* A tuple `.{ function, arg1, arg2, ... }` (up to 10 arguments)

**Returns**: Struct with same field names, containing each task's return value.

***

## Parallel Algorithms

### Sorting

All sort operations are in-place and use parallel PDQSort (Pattern-Defeating Quicksort).

#### `sortAsc(T, data) void`

Sort a slice in ascending order.

```zig
var data = [_]i64{ 5, 2, 8, 1, 9, 3 };
blitz.sortAsc(i64, &data);
// data is now [1, 2, 3, 5, 8, 9]
```

#### `sortDesc(T, data) void`

Sort a slice in descending order.

#### `sort(T, data, lessThan) void`

Sort with a custom comparator.

```zig
var data = [_]i64{ 5, -2, 8, -1, 9 };

// Sort by absolute value
blitz.sort(i64, &data, struct {
    fn byAbs(a: i64, b: i64) bool {
        return @abs(a) < @abs(b);
    }
}.byAbs);
```

#### `sortByKey(T, K, data, keyFn) void`

Sort by extracting a comparable key from each element.

```zig
const Person = struct { name: []const u8, age: u32 };
var people: []Person = ...;

blitz.sortByKey(Person, u32, &people, struct {
    fn getAge(p: Person) u32 { return p.age; }
}.getAge);
```

#### `sortByCachedKey(T, K, allocator, data, keyFn) !void`

Two-phase sort: compute keys in parallel, then sort by cached keys.

***

## Low-Level API

For fine-grained control over parallelism.

### `parallelFor(n, Context, ctx, body) void`

Execute a function in parallel over a range.

```zig
const Context = struct {
    data: []f64,
    multiplier: f64,
};

blitz.parallelFor(data.len, Context, .{
    .data = data,
    .multiplier = 2.0,
}, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        for (ctx.data[start..end]) |*x| {
            x.* *= ctx.multiplier;
        }
    }
}.body);
```

### `parallelForWithGrain(n, Context, ctx, body, grain) void`

Execute a function in parallel over a range with explicit grain size control.

Use this when you need fine-grained control over parallelization granularity. For most cases, prefer `parallelFor()` which auto-tunes based on data size.

**Parameters:**

* `n`: Range size `[0, n)`
* `Context`: Type holding shared data
* `ctx`: Context instance
* `body`: `fn(Context, start: usize, end: usize) void`
* `grain`: Minimum elements per chunk

```zig
// Process with small grain for expensive operations
const Context = struct {
    input: []const f64,
    output: []f64,
};

blitz.parallelForWithGrain(
    data.len,
    Context,
    .{ .input = input, .output = output },
    struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.input[start..end], ctx.output[start..end]) |in, *out| {
                out.* = expensiveComputation(in);
            }
        }
    }.body,
    100,  // Small grain = more parallelism for expensive ops
);

// Large grain for cheap operations (reduces overhead)
blitz.parallelForWithGrain(n, void, {}, struct {
    fn body(_: void, start: usize, end: usize) void {
        for (start..end) |i| {
            cheapOperation(i);
        }
    }
}.body, 10000);  // Large grain = less overhead for cheap ops
```

**Grain size guidelines:**
| Operation Cost | Recommended Grain |
|----------------|-------------------|
| Expensive (>1μs/element) | 64-256 |
| Medium (~100ns/element) | 256-1024 |
| Cheap (\<10ns/element) | 4096-10000 |

### `parallelReduce(T, n, identity, Context, ctx, map, combine) T`

Parallel map-reduce with full control over mapping and combining.

Maps each index to a value using `map(ctx, index)`, then combines all values using the associative `combine(a, b)` function in a divide-and-conquer pattern.

**Parameters:**

* `T`: Result type
* `n`: Range size `[0, n)`
* `identity`: Identity value for combine (e.g., 0 for sum, 1 for product)
* `Context`: Type holding shared data
* `ctx`: Context instance
* `map`: `fn(Context, usize) T` - Extract/compute value at index
* `combine`: `fn(T, T) T` - Associative binary operation

**Requirements:**

* `combine` must be **associative**: `combine(a, combine(b, c)) == combine(combine(a, b), c)`
* `identity` must satisfy: `combine(identity, x) == x`

```zig
// Sum of squares
const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

const sum_of_squares = blitz.parallelReduce(
    i64,                // Result type
    data.len,           // Range size
    0,                  // Identity for addition
    []const i64,        // Context type
    &data,              // Context value
    struct {
        fn map(d: []const i64, i: usize) i64 {
            return d[i] * d[i];  // Square each element
        }
    }.map,
    struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;  // Sum the squares
        }
    }.combine,
);
// sum_of_squares = 385

// Dot product of two vectors
const DotCtx = struct { a: []const f64, b: []const f64 };

const dot_product = blitz.parallelReduce(
    f64,
    a.len,
    0.0,
    DotCtx,
    .{ .a = a, .b = b },
    struct {
        fn map(ctx: DotCtx, i: usize) f64 {
            return ctx.a[i] * ctx.b[i];
        }
    }.map,
    struct {
        fn combine(x: f64, y: f64) f64 { return x + y; }
    }.combine,
);

// Find maximum value
const max_val = blitz.parallelReduce(
    i64,
    data.len,
    std.math.minInt(i64),  // Identity for max
    []const i64,
    &data,
    struct {
        fn map(d: []const i64, i: usize) i64 { return d[i]; }
    }.map,
    struct {
        fn combine(a: i64, b: i64) i64 { return @max(a, b); }
    }.combine,
);

// Count elements matching predicate
const count = blitz.parallelReduce(
    usize,
    data.len,
    0,
    []const i64,
    &data,
    struct {
        fn map(d: []const i64, i: usize) usize {
            return if (d[i] > 5) 1 else 0;
        }
    }.map,
    struct {
        fn combine(a: usize, b: usize) usize { return a + b; }
    }.combine,
);
```

### `parallelReduceWithGrain(T, n, identity, Context, ctx, map, combine, grain) T`

Same as `parallelReduce` but with explicit grain size control.

```zig
// Use smaller grain for expensive map operations
const result = blitz.parallelReduceWithGrain(
    f64, n, 0.0, Context, ctx, expensiveMap, add,
    256,  // Smaller grain for expensive operations
);
```

***

## Collection & Scatter API

For parallel materialization patterns (inspired by Polars).

### `parallelCollect(T, U, input, output, Context, ctx, mapFn) void`

Parallel map that collects results into an output slice.

```zig
var input: [1000]i32 = undefined;
var output: [1000]i64 = undefined;

blitz.parallelCollect(i32, i64, &input, &output, void, {}, struct {
    fn map(_: void, x: i32) i64 {
        return @as(i64, x) * 2;
    }
}.map);
```

**Requirements**: `output.len` must equal `input.len`.

### `parallelMapInPlace(T, data, Context, ctx, mapFn) void`

Transform elements in-place in parallel.

```zig
blitz.parallelMapInPlace(f64, data, void, {}, struct {
    fn transform(_: void, x: f64) f64 {
        return @sqrt(x);
    }
}.transform);
```

### `parallelFlatten(T, slices, output) void`

Flatten nested slices into a single output slice in parallel.

```zig
const slices = [_][]const u32{ &.{1, 2, 3}, &.{4, 5}, &.{6, 7, 8, 9} };
var output: [9]u32 = undefined;
blitz.parallelFlatten(u32, &slices, &output);
// output = [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

### `parallelScatter(T, values, indices, output) void`

Scatter values to output using index mapping.

```zig
const values = [_]u32{ 100, 200, 300 };
const indices = [_]usize{ 5, 0, 3 };
var output: [10]u32 = undefined;
blitz.parallelScatter(u32, &values, &indices, &output);
// output[0]=200, output[3]=300, output[5]=100
```

***

## Error-Safe API

All tasks complete before errors propagate. See [Error Handling](/v2.0.0-zig0.15.3/1.0.0-zig0.15.2/usage/error-handling/) for details.

### `tryJoin(tasks) E!Result`

Execute error-returning tasks in parallel with error safety.

```zig
const result = try blitz.tryJoin(.{
    .user = fetchUser,       // returns !User
    .posts = fetchPosts,     // returns ![]Post
});
// result.user, result.posts
```

### `tryForEach(n, E, Context, ctx, bodyFn) E!void`

Parallel iteration with error handling.

```zig
try blitz.tryForEach(data.len, ParseError, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) ParseError!void {
        for (start..end) |i| {
            try processItem(c.data[i]);
        }
    }
}.body);
```

### `tryReduce(T, E, n, identity, Context, ctx, mapFn, combineFn) E!T`

Parallel reduction with error handling.

```zig
const total = try blitz.tryReduce(
    i64, ParseError, data.len, 0, Context, ctx,
    struct { fn map(c: Context, i: usize) ParseError!i64 { return try parse(c.data[i]); } }.map,
    struct { fn combine(a: i64, b: i64) i64 { return a + b; } }.combine,
);
```

***

## Scope & Broadcast API

For dynamic task spawning. See [Scope & Broadcast](/v2.0.0-zig0.15.3/1.0.0-zig0.15.2/usage/scope-broadcast/) for details.

### `scope(func) void`

Execute a scope function. Tasks spawned within run in parallel when the scope exits.

```zig
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        s.spawn(task1);
        s.spawn(task2);
        s.spawn(task3);
    }
}.run);
```

### `broadcast(func) void`

Execute a function on all worker threads.

```zig
blitz.broadcast(struct {
    fn run(worker_index: usize) void {
        // Runs once on each worker thread
        initThreadLocal(worker_index);
    }
}.run);
```

### `getStats() PoolStats`

Get pool statistics for debugging.

```zig
const stats = blitz.getStats();
std.debug.print("Executed: {}, Stolen: {}\n", .{ stats.executed, stats.stolen });
```

***

## Configuration

### Grain Size

The grain size controls the minimum work unit.

#### `setGrainSize(size: usize) void`

Set the global grain size.

```zig
blitz.setGrainSize(1024);
```

#### `getGrainSize() usize`

Get the current grain size.

#### `defaultGrainSize() usize`

Get the default grain size (4096).

**Guidelines**:
| Operation Cost | Recommended Grain |
|----------------|-------------------|
| Trivial (add, compare) | 4096-10000 |
| Light (simple math) | 1024-4096 |
| Medium (string ops) | 256-1024 |
| Heavy (I/O, allocation) | 64-256 |

***

## Thread Safety

| Component | Thread Safety |
|-----------|---------------|
| `iter()`, `iterMut()` | Create from any thread |
| Iterator methods | Execute on worker threads |
| `join()` | Safe from any thread |
| Input slices | Must not be modified during operation |
| Output of `iterMut` | Safe after operation completes |

**Important**: Do not modify input data while a parallel operation is running.
