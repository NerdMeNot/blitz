# SIMD Aggregations

Vectorized reduction algorithms for maximum throughput.

## Overview

SIMD (Single Instruction Multiple Data) allows processing multiple elements with one instruction. Blitz uses:
- **8-wide vectors** (AVX2/NEON)
- **4 accumulators** for instruction-level parallelism
- **Multi-threading** for data parallelism

## The SIMD Advantage

### Scalar Sum

```
for each element:
    sum += element    // 1 addition per cycle

10M elements × 1 op/cycle = 10M cycles
```

### SIMD Sum (8-wide)

```
for each 8 elements:
    vec_sum += vec_load(8 elements)  // 8 additions per instruction

10M elements / 8 = 1.25M vector ops
```

### SIMD Sum with 4 Accumulators

```
for each 32 elements:
    acc0 += vec_load(elements[0:8])
    acc1 += vec_load(elements[8:16])
    acc2 += vec_load(elements[16:24])
    acc3 += vec_load(elements[24:32])
    // All 4 additions execute in parallel!

10M elements / 32 = 312K loop iterations
```

## Implementation

### Vector Types

```zig
// SIMD vector constants
const VECTOR_WIDTH = 8;
const UNROLL_FACTOR = 4;

// Native SIMD type for the platform
fn Vec(comptime T: type) type {
    return @Vector(VECTOR_WIDTH, T);
}
```

### Sum Algorithm

```zig
pub fn sum(comptime T: type, data: []const T) T {
    if (data.len == 0) return 0;
    if (data.len < VECTOR_WIDTH * UNROLL_FACTOR) {
        return scalarSum(T, data);
    }

    const vec_len = VECTOR_WIDTH * UNROLL_FACTOR;

    // Initialize 4 accumulators
    var acc0: Vec(T) = @splat(0);
    var acc1: Vec(T) = @splat(0);
    var acc2: Vec(T) = @splat(0);
    var acc3: Vec(T) = @splat(0);

    // Main SIMD loop
    var i: usize = 0;
    const aligned_len = (data.len / vec_len) * vec_len;

    while (i < aligned_len) : (i += vec_len) {
        // Load 4 vectors (32 elements for i64)
        const v0: Vec(T) = data[i..][0..VECTOR_WIDTH].*;
        const v1: Vec(T) = data[i + VECTOR_WIDTH..][0..VECTOR_WIDTH].*;
        const v2: Vec(T) = data[i + 2 * VECTOR_WIDTH..][0..VECTOR_WIDTH].*;
        const v3: Vec(T) = data[i + 3 * VECTOR_WIDTH..][0..VECTOR_WIDTH].*;

        // Accumulate (4 independent operations)
        acc0 += v0;
        acc1 += v1;
        acc2 += v2;
        acc3 += v3;
    }

    // Combine accumulators
    const combined = acc0 + acc1 + acc2 + acc3;

    // Horizontal sum of vector
    var result: T = @reduce(.Add, combined);

    // Handle remainder
    for (data[aligned_len..]) |v| {
        result += v;
    }

    return result;
}
```

### Why 4 Accumulators?

Modern CPUs have multiple execution units:

```
Intel Skylake:   2 SIMD add units, 4-6 cycle latency
Apple M1:        4 SIMD add units, 3 cycle latency

Without multiple accumulators:
    acc += load()  // Must wait for previous add to complete
    acc += load()  // Stalled waiting...
    Throughput: 1 vector / 4 cycles

With 4 accumulators:
    acc0 += load()  // Cycle 0
    acc1 += load()  // Cycle 0 (parallel!)
    acc2 += load()  // Cycle 0 (parallel!)
    acc3 += load()  // Cycle 0 (parallel!)
    Throughput: 4 vectors / 1 cycle
```

## Min/Max Algorithm

Finding minimum/maximum uses vector comparisons:

```zig
pub fn min(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;

    // Initialize with max value
    var min_vec: Vec(T) = @splat(std.math.maxInt(T));

    var i: usize = 0;
    while (i + VECTOR_WIDTH <= data.len) : (i += VECTOR_WIDTH) {
        const v: Vec(T) = data[i..][0..VECTOR_WIDTH].*;
        min_vec = @min(min_vec, v);  // Element-wise min
    }

    // Horizontal reduction
    var result: T = @reduce(.Min, min_vec);

    // Handle remainder
    for (data[i..]) |v| {
        result = @min(result, v);
    }

    return result;
}
```

## Argmin/Argmax Algorithm

Finding both value AND index requires tracking indices:

```zig
pub fn argmin(comptime T: type, data: []const T) ?ArgMinMaxResult(T) {
    if (data.len == 0) return null;

    // Track minimum values and their indices
    var min_vals: Vec(T) = @splat(std.math.maxInt(T));
    var min_idxs: Vec(usize) = @splat(0);

    var i: usize = 0;
    while (i + VECTOR_WIDTH <= data.len) : (i += VECTOR_WIDTH) {
        const vals: Vec(T) = data[i..][0..VECTOR_WIDTH].*;

        // Create index vector: [i, i+1, i+2, ...]
        var idxs: Vec(usize) = undefined;
        inline for (0..VECTOR_WIDTH) |j| {
            idxs[j] = i + j;
        }

        // Compare and select
        const mask = vals < min_vals;
        min_vals = @select(T, mask, vals, min_vals);
        min_idxs = @select(usize, mask, idxs, min_idxs);
    }

    // Find minimum among vector lanes
    var best_val: T = min_vals[0];
    var best_idx: usize = min_idxs[0];

    inline for (1..VECTOR_WIDTH) |j| {
        if (min_vals[j] < best_val) {
            best_val = min_vals[j];
            best_idx = min_idxs[j];
        }
    }

    // Handle remainder
    for (data[i..], i..) |v, idx| {
        if (v < best_val) {
            best_val = v;
            best_idx = idx;
        }
    }

    return .{ .value = best_val, .index = best_idx };
}
```

## Parallel + SIMD

Combining multi-threading with SIMD:

```zig
pub fn parallelSum(comptime T: type, data: []const T) T {
    if (data.len < getParallelThreshold(T, .sum)) {
        return sum(T, data);  // SIMD only
    }

    // Parallel reduce with SIMD chunks
    return blitz.parallelReduceChunked(
        T, T, data, 0,
        struct {
            fn chunkSum(chunk: []const T) T {
                return sum(T, chunk);  // Each thread uses SIMD
            }
        }.chunkSum,
        struct {
            fn combine(a: T, b: T) T { return a + b; }
        }.combine,
    );
}
```

## Performance Numbers

```
Platform: Apple M1, 10 cores
Data: 50M i64 elements

Method              Time        Throughput
────────────────────────────────────────────
Scalar loop         92.5 ms     0.54 B/sec
SIMD (1 thread)     26.5 ms     1.88 B/sec
SIMD (4 accum)      13.2 ms     3.79 B/sec
Parallel SIMD       5.4 ms      9.28 B/sec

Speedup vs scalar: 17.2x
```

## Memory Bandwidth Limits

At some point, memory bandwidth limits parallelism:

```
Theoretical peak (DDR4-3200):
    51.2 GB/s = 6.4 billion i64/sec

Achieved (parallel SIMD):
    9.28 B/sec = 74.2 GB/s effective

We're memory-bound! Adding more threads won't help.
```

## Best Practices

1. **Use parallel SIMD for large data** (>100K elements)
2. **Use SIMD-only for medium data** (1K-100K elements)
3. **Use scalar for small data** (<1K elements)
4. **Profile to find your crossover points** - they vary by hardware

```zig
fn adaptiveSum(data: []const i64) i64 {
    if (data.len < 1024) {
        return scalarSum(data);
    } else if (data.len < 100_000) {
        return simd.sum(i64, data);
    } else {
        return simd.parallelSum(i64, data);
    }
}
```
