# Core API Reference

## Iterator API (Recommended)

The iterator API is the simplest and most ergonomic way to use Blitz.

### Creating Iterators

```zig
const blitz = @import("blitz");

// From slice (immutable)
const it = blitz.iter(T, slice);

// From slice (mutable)
const it = blitz.iterMut(T, slice);

// From index range
const it = blitz.range(start, end);
```

### Aggregations

```zig
blitz.iter(i64, data).sum()              // Sum all elements
blitz.iter(i64, data).min()              // Minimum (returns ?T)
blitz.iter(i64, data).max()              // Maximum (returns ?T)
blitz.iter(i64, data).reduce(0, addFn)   // Custom reduction
blitz.iter(i64, data).count()            // Element count
```

### Search (with early exit)

```zig
blitz.iter(T, data).findAny(pred)        // Any match (fast, non-deterministic)
blitz.iter(T, data).findFirst(pred)      // First match (leftmost)
blitz.iter(T, data).findLast(pred)       // Last match (rightmost)
blitz.iter(T, data).position(pred)       // Index of first match
blitz.iter(T, data).positionAny(pred)    // Index of any match
blitz.iter(T, data).rposition(pred)      // Index of last match
```

### Predicates (with early exit)

```zig
blitz.iter(T, data).any(pred)            // True if any match
blitz.iter(T, data).all(pred)            // True if all match
```

### Min/Max by Comparator or Key

```zig
blitz.iter(T, data).minBy(comparator)    // Min by custom comparator
blitz.iter(T, data).maxBy(comparator)    // Max by custom comparator
blitz.iter(T, data).minByKey(K, keyFn)   // Min by key extraction
blitz.iter(T, data).maxByKey(K, keyFn)   // Max by key extraction
```

### Mutation

```zig
blitz.iterMut(T, data).mapInPlace(fn)    // Transform each element
blitz.iterMut(T, data).fill(value)       // Fill with value
blitz.iterMut(T, data).forEach(fn)       // Execute for each
```

### Combinators

```zig
blitz.iter(T, a).chain(blitz.iter(T, b)) // Concatenate iterators
blitz.iter(T, a).zip(blitz.iter(U, b))   // Pair elements
blitz.iter(T, data).chunks_iter(size)    // Fixed-size chunks
blitz.iter(T, data).enumerate_iter()     // With indices
```

---

## Fork-Join

For divide-and-conquer algorithms.

### `join(RetA, RetB, fnA, fnB, argA, argB)`

Execute two functions in parallel, return both results.

```zig
const result = blitz.join(u64, u64, computeA, computeB, arg1, arg2);
// result[0] = computeA(arg1)
// result[1] = computeB(arg2)
```

### `joinVoid(fnA, fnB, argA, argB)`

Execute two void functions in parallel.

```zig
blitz.joinVoid(processLeft, processRight, leftData, rightData);
```

### `tryJoin(RetA, RetB, E, fnA, fnB, argA, argB)`

Error-safe join. Task B always completes even if A fails.

```zig
const result = try blitz.tryJoin(u64, u64, MyError, fnA, fnB, argA, argB);
```

### `join2`, `join3`, `joinN`

Convenience for multiple tasks.

```zig
// 2 tasks, different return types
const r = blitz.join2(i32, i64, fnA, fnB);

// 3 tasks
const r = blitz.join3(i32, i64, f64, fnA, fnB, fnC);

// N tasks (same return type required)
const funcs = [_]fn() i64{ fn1, fn2, fn3, fn4 };
const results = blitz.joinN(i64, 4, &funcs);
```

### `scope(fn)`

Spawn up to 64 tasks dynamically.

```zig
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        s.spawn(task1);
        s.spawn(task2);
        s.spawn(task3);
    }
}.run);
```

---

## Parallel Algorithms

### Sorting

```zig
try blitz.parallelSort(T, data, allocator);
try blitz.parallelSortBy(T, data, allocator, lessThanFn);
```

### Scan (Prefix Sum)

```zig
blitz.parallelScan(T, input, output);           // Inclusive
blitz.parallelScanExclusive(T, input, output);  // Exclusive
```

### Find

```zig
blitz.parallelFind(T, data, predicate);         // -> ?usize
blitz.parallelFindValue(T, data, value);        // -> ?usize
```

### Partition

```zig
const pivot = blitz.parallelPartition(T, data, predicate);
```

---

## Range Iteration

```zig
// Parallel for-each over indices
blitz.range(0, 1000).forEach(processIndex);

// Sum over range with value function
const total = blitz.range(0, 100).sum(i64, valueAtIndex);

// Alternative API
blitz.parallelForRange(0, n, processIndex);
blitz.parallelForRangeWithContext(Context, ctx, 0, n, processFn);
```

---

## Convenience Functions

Top-level wrappers for common operations:

```zig
blitz.parallelSum(T, data)                // -> T
blitz.parallelMin(T, data)                // -> ?T
blitz.parallelMax(T, data)                // -> ?T
blitz.parallelAny(T, data, pred)          // -> bool
blitz.parallelAll(T, data, pred)          // -> bool
blitz.parallelFindAny(T, data, pred)      // -> ?T
blitz.parallelForEach(T, data, fn)        // -> void
blitz.parallelMap(T, data, fn)            // -> void (in-place)
blitz.parallelFill(T, data, value)        // -> void
```

---

## Low-Level API

For fine-grained control when needed.

### `parallelFor(n, Context, ctx, body)`

```zig
const Ctx = struct { data: []f64 };
blitz.parallelFor(data.len, Ctx, .{ .data = data }, struct {
    fn body(c: Ctx, start: usize, end: usize) void {
        for (c.data[start..end]) |*v| v.* *= 2;
    }
}.body);
```

### `parallelReduce(T, n, identity, Context, ctx, map, combine)`

```zig
const sum = blitz.parallelReduce(
    i64, data.len, 0,
    []const i64, data,
    struct { fn map(d: []const i64, i: usize) i64 { return d[i]; } }.map,
    struct { fn add(a: i64, b: i64) i64 { return a + b; } }.add,
);
```

### Grain Size Control

```zig
blitz.setGrainSize(1024);           // Set minimum chunk size
blitz.getGrainSize();               // Get current grain size
blitz.defaultGrainSize();           // Get default
blitz.parallelForWithGrain(..., grain_size);
```

---

## Initialization

Blitz auto-initializes on first use, but you can configure manually:

```zig
// Auto-detect thread count
try blitz.init();
defer blitz.deinit();

// Custom configuration
try blitz.initWithConfig(.{
    .background_worker_count = 8,
});

// Query
const workers = blitz.numWorkers();
const ready = blitz.isInitialized();
```
