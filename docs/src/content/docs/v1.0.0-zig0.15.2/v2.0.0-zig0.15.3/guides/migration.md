---
title: Migration from Sequential
description: Step-by-step patterns for converting sequential Zig code to parallel Blitz code
slug: v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/guides/migration
---

Step-by-step patterns for converting sequential Zig code to parallel equivalents using Blitz.

## Setup

Every program using Blitz needs initialization. Add this once at the top of your `main`:

```zig
const blitz = @import("blitz");

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    // ... rest of your program
}
```

## For Loop to parallelFor

### Before: Sequential Loop

```zig
for (data, 0..) |*v, i| {
    v.* = @sqrt(@as(f64, @floatFromInt(i)));
}
```

### After: Parallel Loop

```zig
const Context = struct { data: []f64 };

blitz.parallelFor(data.len, Context, .{ .data = data }, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        for (ctx.data[start..end], start..) |*v, i| {
            v.* = @sqrt(@as(f64, @floatFromInt(i)));
        }
    }
}.body);
```

**Key changes**:

1. Define a `Context` struct holding all data the loop body needs
2. The body receives chunk boundaries `(start, end)`, not a single index
3. Loop over the chunk `[start..end)` inside the body

### Simpler: Per-Index Variant

If chunk-based processing is awkward, use `parallelForRange`:

```zig
// Before
for (0..1000) |i| {
    processItem(i);
}

// After
blitz.parallelForRange(0, 1000, struct {
    fn process(i: usize) void {
        processItem(i);
    }
}.process);
```

## Accumulation to parallelReduce

### Before: Sequential Sum

```zig
var sum: i64 = 0;
for (data) |v| {
    sum += v;
}
```

### After: Parallel Reduce

```zig
const sum = blitz.parallelReduce(
    i64,              // Result type
    data.len,         // Element count
    0,                // Identity (starting value for sum)
    []const i64,      // Context type
    data,             // Context value
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
```

### Even Simpler: Iterator

```zig
const sum = blitz.iter(i64, data).sum();
```

## Accumulation to iter().min() / iter().max()

### Before: Sequential Min

```zig
var min_val: i64 = std.math.maxInt(i64);
for (data) |v| {
    if (v < min_val) min_val = v;
}
```

### After: Parallel Min

```zig
const min_val = blitz.iter(i64, data).min();
// Returns ?i64 (null if data is empty)
```

### Before: Sequential Max

```zig
var max_val: i64 = std.math.minInt(i64);
for (data) |v| {
    if (v > max_val) max_val = v;
}
```

### After: Parallel Max

```zig
const max_val = blitz.iter(i64, data).max();
```

## Search to findAny

### Before: Sequential Search

```zig
var found: ?i64 = null;
for (data) |v| {
    if (v < 0) {
        found = v;
        break;
    }
}
```

### After: Parallel Search

```zig
const found = blitz.iter(i64, data).findAny(struct {
    fn isNegative(v: i64) bool {
        return v < 0;
    }
}.isNegative);
// Returns ?i64 — finds any matching element (non-deterministic order)
```

`findAny` is the fastest parallel search. It checks chunks in parallel and returns as soon as any thread finds a match. The result is non-deterministic -- you get whichever match is found first by any worker.

For deterministic results:

```zig
// Finds the first matching element (by index) — slower but deterministic
const first = blitz.iter(i64, data).findFirst(isNegative);

// Finds the last matching element (by index)
const last = blitz.iter(i64, data).findLast(isNegative);
```

## Boolean Check to any/all

### Before: Sequential any

```zig
var has_negative = false;
for (data) |v| {
    if (v < 0) {
        has_negative = true;
        break;
    }
}
```

### After: Parallel any

```zig
const has_negative = blitz.iter(i64, data).any(struct {
    fn isNegative(v: i64) bool {
        return v < 0;
    }
}.isNegative);
```

### Before: Sequential all

```zig
var all_positive = true;
for (data) |v| {
    if (v <= 0) {
        all_positive = false;
        break;
    }
}
```

### After: Parallel all

```zig
const all_positive = blitz.iter(i64, data).all(struct {
    fn isPositive(v: i64) bool {
        return v > 0;
    }
}.isPositive);
```

Both `any` and `all` support early exit -- they stop checking as soon as the answer is known.

## Sort to sortAsc/sortDesc

### Before: Standard Library Sort

```zig
std.mem.sort(i64, data, {}, std.sort.asc(i64));
```

### After: Parallel Sort

```zig
blitz.sortAsc(i64, data);
```

### Before: Custom Comparator

```zig
std.mem.sort(Person, people, {}, struct {
    fn lessThan(_: void, a: Person, b: Person) bool {
        return a.age < b.age;
    }
}.lessThan);
```

### After: Parallel Custom Sort

```zig
blitz.sort(Person, people, struct {
    fn lessThan(a: Person, b: Person) bool {
        return a.age < b.age;
    }
}.lessThan);
```

Note: Blitz's sort comparator takes `(T, T) bool` directly, without the `void` context parameter that `std.mem.sort` requires.

### Sort by Key

```zig
// Before: full comparator
blitz.sort(Person, people, struct {
    fn cmp(a: Person, b: Person) bool { return a.age < b.age; }
}.cmp);

// After: key extraction (simpler)
blitz.sortByKey(Person, u32, people, struct {
    fn key(p: Person) u32 { return p.age; }
}.key);
```

## Transform to parallelMapInPlace

### Before: Sequential In-Place Transform

```zig
for (data) |*v| {
    v.* = v.* * 2 + 1;
}
```

### After: Parallel In-Place Transform

```zig
blitz.parallelMapInPlace(i64, data, void, {}, struct {
    fn transform(_: void, x: i64) i64 {
        return x * 2 + 1;
    }
}.transform);
```

Or using the mutable iterator:

```zig
blitz.iterMut(i64, data).mapInPlace(struct {
    fn transform(x: i64) i64 {
        return x * 2 + 1;
    }
}.transform);
```

## Map to parallelCollect

### Before: Sequential Map to New Array

```zig
var output: [N]f64 = undefined;
for (input, &output) |in_val, *out_val| {
    out_val.* = @as(f64, @floatFromInt(in_val)) / 255.0;
}
```

### After: Parallel Collect

```zig
blitz.parallelCollect(
    u8, f64,          // Input type -> Output type
    input, &output,
    void, {},
    struct {
        fn normalize(_: void, x: u8) f64 {
            return @as(f64, @floatFromInt(x)) / 255.0;
        }
    }.normalize,
);
```

## Two Independent Tasks to join

### Before: Sequential

```zig
const stats = computeStatistics(data);
const histogram = buildHistogram(data);
// Total time: stats_time + histogram_time
```

### After: Parallel

```zig
const result = blitz.join(.{
    .stats = .{ computeStatistics, data },
    .histogram = .{ buildHistogram, data },
});
// Total time: max(stats_time, histogram_time)

const stats = result.stats;
const histogram = result.histogram;
```

## Recursive Divide-and-Conquer to join

### Before: Sequential Merge Sort

```zig
fn mergeSort(data: []i64) void {
    if (data.len <= 1) return;
    const mid = data.len / 2;
    mergeSort(data[0..mid]);
    mergeSort(data[mid..]);
    merge(data, mid);
}
```

### After: Parallel Merge Sort

```zig
fn parallelMergeSort(data: []i64) void {
    if (data.len <= 1024) {
        // Sequential below threshold
        std.mem.sort(i64, data, {}, std.sort.asc(i64));
        return;
    }
    const mid = data.len / 2;
    _ = blitz.join(.{
        .left = .{ parallelMergeSort, data[0..mid] },
        .right = .{ parallelMergeSort, data[mid..] },
    });
    merge(data, mid);
}
```

**Always add a sequential threshold** for recursive fork-join. Without it, the overhead of spawning tasks for tiny arrays will make the parallel version slower.

## Migration Checklist

1. **Add `blitz.init()` / `defer blitz.deinit()`** to your main function
2. **Identify hot loops** using profiling (not guessing)
3. **Check data size** -- parallelism only helps above ~10K elements
4. **Choose the right API** (see [Choosing the Right API](/v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/guides/choosing-api/))
5. **Define a Context struct** holding all data the parallel body needs
6. **Test correctness** -- parallel code should produce identical results
7. **Benchmark** -- measure actual speedup, do not assume
8. **Tune grain size** if default performance is unsatisfactory

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Parallelizing small arrays | Check size first, fall back to sequential |
| Shared mutable state | Use `parallelReduce` or atomic operations |
| Missing `init()` | All operations run sequentially without it |
| No sequential threshold in recursion | Add `if (n < threshold) return sequential(...)` |
| Expecting linear speedup | Memory-bound code plateaus at 2-4x |
