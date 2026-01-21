# SIMD Operations

Vectorized operations combining SIMD with multi-threading for maximum throughput.

## Overview

Blitz SIMD operations use:
- **8-wide SIMD lanes** (AVX2/NEON)
- **4 accumulators** for instruction-level parallelism (ILP)
- **Multi-threading** for data parallelism

```
┌─────────────────────────────────────────────────────┐
│                    100M Elements                     │
├─────────────┬─────────────┬─────────────┬───────────┤
│  Worker 0   │  Worker 1   │  Worker 2   │ Worker 3  │
│  25M each   │  25M each   │  25M each   │ 25M each  │
├─────────────┼─────────────┼─────────────┼───────────┤
│[8][8][8][8] │[8][8][8][8] │[8][8][8][8] │[8][8][8][8]│
│ 4 SIMD acc  │ 4 SIMD acc  │ 4 SIMD acc  │ 4 SIMD acc│
└─────────────┴─────────────┴─────────────┴───────────┘
```

## Basic Aggregations

```zig
const blitz = @import("blitz");
const simd = blitz.simd_mod;

const data: []const i64 = ...;

// Single-threaded SIMD
const sum = simd.sum(i64, data);
const min_val = simd.min(i64, data);
const max_val = simd.max(i64, data);

// Multi-threaded + SIMD (fastest for large data)
const par_sum = simd.parallelSum(i64, data);
const par_min = simd.parallelMin(i64, data);
const par_max = simd.parallelMax(i64, data);
```

## Argmin/Argmax

Find value AND index simultaneously:

```zig
// Single-threaded
const argmin_result = simd.argmin(i64, data);
const argmax_result = simd.argmax(i64, data);

if (argmin_result) |r| {
    std.debug.print("Min value {} at index {}\n", .{ r.value, r.index });
}

// Multi-threaded + SIMD
const par_argmin = simd.parallelArgmin(i64, data);
const par_argmax = simd.parallelArgmax(i64, data);
```

## Search Operations

```zig
// Find first occurrence of value
const index = simd.findValue(i64, data, target_value);

// Threshold checks (SIMD accelerated)
const has_large = simd.anyGreaterThan(i64, data, threshold);
const all_small = simd.allLessThan(i64, data, upper_bound);
```

## Supported Types

| Type | SIMD Width | Operations |
|------|------------|------------|
| `i8`, `u8` | 32 elements | sum, min, max |
| `i16`, `u16` | 16 elements | sum, min, max |
| `i32`, `u32` | 8 elements | sum, min, max, argmin, argmax |
| `i64`, `u64` | 4 elements | sum, min, max, argmin, argmax |
| `f32` | 8 elements | sum, min, max |
| `f64` | 4 elements | sum, min, max |

## Performance Comparison

```
Data: 50M i64 elements

┌────────────────────┬──────────┬───────────────────┐
│ Method             │ Time     │ Throughput        │
├────────────────────┼──────────┼───────────────────┤
│ Scalar loop        │ 92.5 ms  │ 0.54 B elem/sec   │
│ SIMD (1 thread)    │ 26.5 ms  │ 1.88 B elem/sec   │
│ Parallel SIMD      │ 5.4 ms   │ 9.28 B elem/sec   │
└────────────────────┴──────────┴───────────────────┘

Speedup:
- SIMD vs Scalar: 3.5x
- Parallel SIMD vs Scalar: 17.2x
```

## How SIMD Aggregation Works

### Sum with Multiple Accumulators

```
Data: [a0 a1 a2 a3 a4 a5 a6 a7 | b0 b1 b2 b3 b4 b5 b6 b7 | ...]

SIMD registers (4 accumulators for ILP):
acc0: [a0 a1 a2 a3 a4 a5 a6 a7]
acc1: [b0 b1 b2 b3 b4 b5 b6 b7]
acc2: [c0 c1 c2 c3 c4 c5 c6 c7]
acc3: [d0 d1 d2 d3 d4 d5 d6 d7]

Each iteration processes 32 elements (4 vectors × 8 elements)

Final: horizontal_sum(acc0 + acc1 + acc2 + acc3)
```

### Why 4 Accumulators?

Modern CPUs can execute multiple SIMD instructions per cycle if they're independent. Using 4 accumulators:

- **Intel**: 2-3 SIMD adds/cycle
- **Apple Silicon**: 4 SIMD adds/cycle

## Threshold Calculation

Blitz dynamically decides when to parallelize:

```zig
// Check if parallel is beneficial
const threshold = simd.getParallelThreshold(i64, .sum);

if (data.len >= threshold) {
    return simd.parallelSum(i64, data);
} else {
    return simd.sum(i64, data);
}

// Or use the automatic version
if (simd.shouldParallelizeSimd(i64, .sum, data.len)) {
    // Use parallel
}
```

## Custom Parallel SIMD Pattern

```zig
// Parallel map with SIMD-optimized chunk processing
const Context = struct {
    data: []const i64,
    results: []i64,
};

blitz.parallelFor(data.len, Context, .{
    .data = data,
    .results = results,
}, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        // Each worker processes its chunk with SIMD
        const chunk = ctx.data[start..end];
        const out = ctx.results[start..end];

        // SIMD loop (compiler auto-vectorizes simple patterns)
        for (chunk, out) |v, *o| {
            o.* = v * 2;
        }
    }
}.body);
```

## Memory Bandwidth Considerations

SIMD is compute-bound; parallel SIMD can become memory-bound:

| Array Size | Bottleneck | Best Approach |
|------------|------------|---------------|
| < 64 KB | L1 cache, compute | SIMD (1 thread) |
| 64KB - 1MB | L2/L3 cache | SIMD or light parallel |
| > 1 MB | Memory bandwidth | Parallel SIMD |

## Example: Complete SIMD Workflow

```zig
const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    const allocator = std.heap.page_allocator;
    const n: usize = 100_000_000;  // 100M elements

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    // Initialize
    for (data, 0..) |*v, i| {
        v.* = @intCast(i % 1000);
    }
    data[50_000_000] = -1;  // Hidden minimum

    const simd = blitz.simd_mod;

    // Parallel SIMD sum
    const sum = simd.parallelSum(i64, data);
    std.debug.print("Sum: {}\n", .{sum});

    // Parallel SIMD argmin
    if (simd.parallelArgmin(i64, data)) |r| {
        std.debug.print("Min {} at index {}\n", .{ r.value, r.index });
    }

    // Search
    const threshold: i64 = 500;
    const has_large = simd.anyGreaterThan(i64, data, threshold);
    std.debug.print("Has values > {}: {}\n", .{ threshold, has_large });
}
```
