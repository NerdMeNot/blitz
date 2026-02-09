---
title: Parallel Reduction
description: Tree-based reduction for aggregating data in parallel.
---

## Overview

Parallel reduction combines elements using an associative operation, achieving O(log n) depth with n processors.

## The Algorithm

### Sequential Reduction

```
data: [1, 2, 3, 4, 5, 6, 7, 8]

sum = 0
for each element:
    sum += element

Time: O(n)
```

### Parallel Reduction

```
Step 1: Parallel local reductions (8 workers)
┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐
│ 1 │ │ 2 │ │ 3 │ │ 4 │ │ 5 │ │ 6 │ │ 7 │ │ 8 │
└─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘

Step 2: Combine pairs
    3       7       11      15
    └───┬───┘       └───┬───┘
       10              26

Step 3: Final combine
          10 + 26 = 36

Depth: O(log n)
Work: O(n)
```

## Blitz Implementation

### Map-Reduce Pattern

```zig
pub fn parallelReduce(
    comptime T: type,
    n: usize,
    identity: T,
    comptime Context: type,
    ctx: Context,
    comptime map: fn(Context, usize) T,
    comptime combine: fn(T, T) T,
) T {
    if (n == 0) return identity;

    // Determine chunk size
    const num_workers = blitz.numWorkers();
    const chunk_size = @max(n / (num_workers * 4), MIN_CHUNK_SIZE);

    // Allocate partial results
    var partials: [MAX_WORKERS]T = undefined;
    var num_partials: usize = 0;

    // Parallel map phase
    blitz.parallelFor(n, struct {
        ctx: Context,
        partials: []T,
        chunk_size: usize,
    }, .{
        .ctx = ctx,
        .partials = &partials,
        .chunk_size = chunk_size,
    }, struct {
        fn body(c: @This(), start: usize, end: usize) void {
            var local_result = identity;
            for (start..end) |i| {
                local_result = combine(local_result, map(c.ctx, i));
            }
            // Store partial result
            const chunk_idx = start / c.chunk_size;
            c.partials[chunk_idx] = local_result;
        }
    }.body);

    // Sequential combine phase (small number of partials)
    var result = identity;
    for (partials[0..num_partials]) |partial| {
        result = combine(result, partial);
    }

    return result;
}
```

### Chunked Variant

Process chunks directly for better efficiency:

```zig
pub fn parallelReduceChunked(
    comptime T: type,
    comptime E: type,
    data: []const E,
    identity: T,
    comptime chunkFn: fn([]const E) T,
    comptime combine: fn(T, T) T,
) T {
    if (data.len == 0) return identity;

    const num_workers = blitz.numWorkers();
    const chunk_size = @max(data.len / num_workers, 1024);
    const num_chunks = (data.len + chunk_size - 1) / chunk_size;

    var partials: [MAX_WORKERS]T = undefined;

    // Process chunks in parallel
    blitz.parallelFor(num_chunks, struct {
        data: []const E,
        chunk_size: usize,
        partials: *[MAX_WORKERS]T,
    }, .{
        .data = data,
        .chunk_size = chunk_size,
        .partials = &partials,
    }, struct {
        fn body(c: @This(), chunk_start: usize, chunk_end: usize) void {
            for (chunk_start..chunk_end) |chunk_idx| {
                const start = chunk_idx * c.chunk_size;
                const end = @min(start + c.chunk_size, c.data.len);
                c.partials[chunk_idx] = chunkFn(c.data[start..end]);
            }
        }
    }.body);

    // Combine partials
    var result = identity;
    for (partials[0..num_chunks]) |p| {
        result = combine(result, p);
    }
    return result;
}
```

## Associativity Requirement

The combine function MUST be associative:

```
combine(combine(a, b), c) == combine(a, combine(b, c))
```

**Why?** Parallel execution groups elements differently than sequential:

```
Sequential: ((((1+2)+3)+4)+5)
Parallel:   (1+2) + (3+4) + 5

If + is associative, both equal 15.
If we used subtraction: ((1-2)-3) != (1-(2-3))  // Wrong!
```

### Valid Operations

| Operation | Identity | Associative? |
|-----------|----------|--------------|
| Addition | 0 | Yes |
| Multiplication | 1 | Yes |
| Min | maxInt | Yes |
| Max | minInt | Yes |
| Bitwise AND | all 1s | Yes |
| Bitwise OR | 0 | Yes |
| Bitwise XOR | 0 | Yes |
| String concat | "" | Yes |

### Invalid Operations

| Operation | Why Not? |
|-----------|----------|
| Subtraction | (a-b)-c != a-(b-c) |
| Division | (a/b)/c != a/(b/c) |
| Average | Not associative |

### Computing Average

Average isn't directly associative, but we can work around it:

```zig
// Reduce to (sum, count), then divide
const SumCount = struct { sum: f64, count: usize };

const result = parallelReduce(
    SumCount, data.len, .{ .sum = 0, .count = 0 },
    data,
    struct {
        fn map(d: []const f64, i: usize) SumCount {
            return .{ .sum = d[i], .count = 1 };
        }
    }.map,
    struct {
        fn combine(a: SumCount, b: SumCount) SumCount {
            return .{ .sum = a.sum + b.sum, .count = a.count + b.count };
        }
    }.combine,
);

const average = result.sum / @as(f64, @floatFromInt(result.count));
```

## Tree Reduction Depth

```
n elements, p processors:

Parallel depth: O(n/p + log p)
- n/p: local reduction within each chunk
- log p: combining partial results

For n=1M, p=8:
- Local: 125,000 ops per worker
- Combine: 3 levels (log2 8)
```

## Work Efficiency

Parallel reduction is work-efficient:

```
Sequential work: n-1 operations
Parallel work:   n-1 operations (same!)
Parallel depth:  O(log n)

Efficiency = Sequential work / Parallel work = 1 (optimal)
```

## Load Balancing

Work stealing handles uneven chunks:

```
Without work stealing:
Worker 0: [==========] done
Worker 1: [==========] done
Worker 2: [====================] still working...
Worker 3: [==========] done

With work stealing:
Worker 0: [==========][steal]
Worker 1: [==========][steal]
Worker 2: [============]
Worker 3: [==========][steal]
```

## Performance Characteristics

```
Benchmark: Sum 10M i64 elements, 10 workers

Implementation         Time       Speedup
------------------------------------------
Sequential            35.2 ms    1.0x
Parallel reduce       4.1 ms     8.6x
```

## When to Use

| Data Size | Recommendation |
|-----------|----------------|
| < 1,000 | Sequential (overhead too high) |
| > 1,000 | Parallel reduce |

Use a size threshold:

```zig
if (data.len >= blitz.DEFAULT_GRAIN_SIZE) {
    return parallelReduce(...);
} else {
    return sequentialReduce(...);
}
```
