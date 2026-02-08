---
title: Early Exit Operations
description: Parallel search operations that terminate as soon as a result is found.
slug: v1.0.0-zig0.15.2/algorithms/early-exit-operations
---

## Overview

Many search operations don't need to process all elements:

* **find**: Stop when first match is found
* **any**: Stop when any element satisfies predicate
* **all**: Stop when any element fails predicate
* **position**: Stop when first match is found

Blitz implements these with **atomic early termination** that prunes entire subtrees when a result is found, matching Rayon's `consumer.full()` pattern.

## The Problem

### Naive Parallel Search

```
Finding needle at position 1000 in array of 10M elements:

Worker 0: [0........2.5M]     <- Finds match at 1000, done!
Worker 1: [2.5M.....5M]       <- Still processing...
Worker 2: [5M........7.5M]    <- Still processing...
Worker 3: [7.5M.....10M]      <- Still processing...

Total time: Limited by slowest worker (processes 2.5M elements)
```

### With Early Exit

```
Finding needle at position 1000 in array of 10M elements:

Worker 0: [0..1000] <- Finds match, sets found=true, DONE!
Worker 1: Checks found=true -> STOP (didn't even start)
Worker 2: Checks found=true -> STOP
Worker 3: Checks found=true -> STOP

Total time: ~1000 element scans + overhead
```

## The Solution: `parallelForWithEarlyExit`

### API

```zig
/// Parallel for with early exit capability.
///
/// Like parallelFor, but checks an atomic flag before each recursive split.
/// If the flag becomes true, entire subtrees are pruned (not started at all).
pub fn parallelForWithEarlyExit(
    n: usize,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    early_exit: *std.atomic.Value(bool),
) void;
```

### How It Works

```
                    [0 ---------------------- 10M]
                              |
                 +------------+------------+
        check    |                         |    check
        flag     v                         v    flag
              [0--5M]                   [5M--10M]
                 |                         |
           +-----+-----+             +-----+-----+
  check    |           |    check    |           |
  flag     v           v    flag     v           v
        [0-2.5M]   [2.5-5M]      [5-7.5M]   [7.5-10M]

When Worker 0 finds match at position 1000:
1. Sets early_exit = true (atomic)
2. Returns immediately

Other workers/subtrees:
- Check flag BEFORE splitting -> flag is true -> return immediately
- Entire subtrees are pruned without processing
```

### Implementation

```zig
fn parallelForEarlyExitImpl(
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    start: usize,
    end: usize,
    split: LengthSplitter,
    task: *Task,
    early_exit: *std.atomic.Value(bool),
) void {
    // KEY OPTIMIZATION: Check early exit BEFORE deciding to split.
    // This prunes entire subtrees when a result is found.
    if (early_exit.load(.monotonic)) return;

    var mutable_split = split;
    if (!mutable_split.trySplit(end - start)) {
        // Base case: execute sequentially
        body_fn(context, start, end);
        return;
    }

    const mid = start + (end - start) / 2;

    // Fork right half
    var future_right = Future(...).init();
    future_right.fork(task, rightHalf, args);

    // Execute left half directly (also checks early_exit)
    parallelForEarlyExitImpl(..., start, mid, ...);

    // Join right half
    future_right.join(task);
}
```

## Find Operations

### `findAny` - Non-Deterministic

Returns any matching element (whichever worker finds it first):

```zig
pub fn findAny(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?T {
    if (data.len <= 1024) {
        // Sequential for small data
        for (data) |item| {
            if (pred(item)) return item;
        }
        return null;
    }

    var found = std.atomic.Value(bool).init(false);
    var result: T = undefined;

    api.parallelForWithEarlyExit(data.len, Context, .{
        .slice = data,
        .found = &found,
        .result = &result,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit check at start of each chunk
            if (ctx.found.load(.monotonic)) return;

            for (ctx.slice[start..end]) |item| {
                // Check periodically within chunk
                if (ctx.found.load(.monotonic)) return;

                if (pred(item)) {
                    // Lock-free: only CAS winner writes result
                    if (ctx.found.cmpxchgStrong(false, true, .release, .monotonic) == null) {
                        ctx.result.* = item;
                    }
                    return;
                }
            }
        }
    }.body, &found);

    return if (found.load(.acquire)) result else null;
}
```

**Key insight**: Only the CAS winner writes the result, avoiding data races.

### `findFirst` - Deterministic

Returns the **first** (leftmost) matching element:

```zig
pub fn findFirst(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?FindResult(T) {
    // Track best (lowest) position found
    var best_pos = std.atomic.Value(usize).init(std.math.maxInt(usize));
    var best_value: T = undefined;
    var value_lock: std.Thread.Mutex = .{};

    api.parallelForWithEarlyExit(data.len, Context, .{
        .slice = data,
        .best_pos = &best_pos,
        .best_value = &best_value,
        .value_lock = &value_lock,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit: our entire range is after best match
            if (start >= ctx.best_pos.load(.monotonic)) return;

            for (start..end) |i| {
                // Early exit within loop
                if (i >= ctx.best_pos.load(.monotonic)) return;

                if (pred(ctx.slice[i])) {
                    // Try to update best position using CAS
                    var expected = ctx.best_pos.load(.monotonic);
                    while (i < expected) {
                        if (ctx.best_pos.cmpxchgWeak(expected, i, .release, .monotonic)) |old| {
                            expected = old;
                            // Backoff on contention
                        } else {
                            // Success - update value
                            ctx.value_lock.lock();
                            ctx.best_value.* = ctx.slice[i];
                            ctx.value_lock.unlock();
                            break;
                        }
                    }
                    return;
                }
            }
        }
    }.body, &dummy_exit);

    const pos = best_pos.load(.acquire);
    return if (pos == std.math.maxInt(usize)) null else .{ .index = pos, .value = best_value };
}
```

**Key difference from `findAny`**:

* `findAny` can exit immediately when ANY match is found
* `findFirst` must continue processing ranges BEFORE the best match (they might find an earlier one)

### `findLast` - Deterministic

Returns the **last** (rightmost) matching element:

```zig
pub fn findLast(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?FindResult(T) {
    // Track best (highest) position found
    var best_pos = std.atomic.Value(usize).init(0);
    var has_match = std.atomic.Value(bool).init(false);

    // ... similar to findFirst but:
    // - Iterates from end to start within chunks
    // - Updates if new position > current best
    // - Prunes ranges BEFORE the best match
}
```

## Predicate Operations

### `any` - Existential Quantifier

```zig
pub fn any(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    // Exactly like findAny, but returns bool instead of value
    var found = std.atomic.Value(bool).init(false);

    api.parallelForWithEarlyExit(data.len, ..., struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            if (ctx.found.load(.monotonic)) return;

            for (ctx.slice[start..end]) |item| {
                if (ctx.found.load(.monotonic)) return;
                if (pred(item)) {
                    ctx.found.store(true, .release);
                    return;
                }
            }
        }
    }.body, &found);

    return found.load(.acquire);
}
```

### `all` - Universal Quantifier

```zig
pub fn all(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    // Inverse: stop on first FAILURE
    var failed = std.atomic.Value(bool).init(false);

    api.parallelForWithEarlyExit(data.len, ..., struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            if (ctx.failed.load(.monotonic)) return;

            for (ctx.slice[start..end]) |item| {
                if (ctx.failed.load(.monotonic)) return;
                if (!pred(item)) {
                    ctx.failed.store(true, .release);
                    return;
                }
            }
        }
    }.body, &failed);

    return !failed.load(.acquire);  // All passed if none failed
}
```

## Performance

### Benchmark: Find at Position 1000 in 10M Elements

```
Operation          Blitz       Rayon       Improvement
--------------------------------------------------------
Find (early)       7.4 us      39.5 us     81% faster
Any (early)        7.1 us      8.7 us      19% faster
Position (middle)  7.8 us      15.7 us     50% faster
```

### Why Blitz is Faster

1. **Aggressive subtree pruning**: Check flag BEFORE forking, not just in body
2. **Lock-free result writing**: CAS pattern avoids mutex contention
3. **Frequent flag checks**: Check within chunks, not just at boundaries
4. **Monotonic loads**: Cheap memory ordering for flag checks

### Benchmark: Full Scan (No Early Exit)

```
Operation          Blitz       Rayon       Improvement
--------------------------------------------------------
Any (full scan)    748.7 us    2083.5 us   64% faster
All (pass)         814.7 us    1203.6 us   32% faster
```

Even without early exit, Blitz is faster due to lower fork-join overhead.

## Usage Guidelines

### When to Use Each Operation

| Operation | Use When |
|-----------|----------|
| `findAny` | Need any match, don't care which |
| `findFirst` | Need the first/leftmost match |
| `findLast` | Need the last/rightmost match |
| `position` | Need index of first match |
| `positionAny` | Need index of any match (faster) |
| `any` | Just need to know if match exists |
| `all` | Need to verify all elements pass |

### Choosing Sequential vs Parallel

```zig
// Blitz automatically chooses:
if (data.len <= 1024) {
    // Sequential - overhead not worth it
    return sequentialFind(data, pred);
} else {
    // Parallel with early exit
    return parallelFindWithEarlyExit(data, pred);
}
```

### Custom Early Exit Operations

```zig
fn customSearch(data: []const MyType) ?MyType {
    var found = std.atomic.Value(bool).init(false);
    var result: MyType = undefined;

    api.parallelForWithEarlyExit(data.len, Context, .{
        .data = data,
        .found = &found,
        .result = &result,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            if (ctx.found.load(.monotonic)) return;

            for (ctx.data[start..end]) |item| {
                if (ctx.found.load(.monotonic)) return;

                if (myCustomPredicate(item)) {
                    if (ctx.found.cmpxchgStrong(false, true, .release, .monotonic) == null) {
                        ctx.result.* = item;
                    }
                    return;
                }
            }
        }
    }.body, &found);

    return if (found.load(.acquire)) result else null;
}
```

## Implementation Files

* `iter/find.zig` - Find operations (findAny, findFirst, findLast, position)
* `iter/predicates.zig` - Predicate operations (any, all)
* `api.zig` - `parallelForWithEarlyExit` implementation

## References

1. Rayon's consumer.full() pattern: `rayon-core/src/iter/plumbing.rs`
2. Blitz implementation: `iter/find.zig`
