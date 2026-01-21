# SIMD API Reference

Vectorized operations with optional multi-threading.

## Access

```zig
const simd = blitz.simd_mod;
```

---

## Single-Threaded SIMD Aggregations

### `sum(T, slice) T`

SIMD-vectorized sum with 4 accumulators.

```zig
const total = simd.sum(i64, data);
```

**Supported types:** `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`

### `min(T, slice) ?T`

SIMD-vectorized minimum.

```zig
const min_val = simd.min(i64, data);  // Returns ?i64
```

### `max(T, slice) ?T`

SIMD-vectorized maximum.

```zig
const max_val = simd.max(i64, data);  // Returns ?i64
```

---

## Parallel SIMD Aggregations

Multi-threaded with SIMD per thread.

### `parallelSum(T, slice) T`

```zig
const total = simd.parallelSum(i64, data);  // Fastest for large data
```

### `parallelMin(T, slice) ?T`

```zig
const min_val = simd.parallelMin(i64, data);
```

### `parallelMax(T, slice) ?T`

```zig
const max_val = simd.parallelMax(i64, data);
```

---

## Argmin/Argmax

Returns value AND index.

### `ArgMinMaxResult(T)`

```zig
pub fn ArgMinMaxResult(comptime T: type) type {
    return struct {
        value: T,
        index: usize,
    };
}
```

### `argmin(T, slice) ?ArgMinMaxResult(T)`

```zig
if (simd.argmin(i64, data)) |result| {
    std.debug.print("Min {} at index {}\n", .{ result.value, result.index });
}
```

### `argmax(T, slice) ?ArgMinMaxResult(T)`

```zig
if (simd.argmax(i64, data)) |result| {
    std.debug.print("Max {} at index {}\n", .{ result.value, result.index });
}
```

### `parallelArgmin(T, slice) ?ArgMinMaxResult(T)`

Multi-threaded argmin.

### `parallelArgmax(T, slice) ?ArgMinMaxResult(T)`

Multi-threaded argmax.

---

## Search Operations

### `findValue(T, slice, value) ?usize`

Find first occurrence of value.

```zig
const index = simd.findValue(i64, data, target);  // Returns ?usize
```

### `anyGreaterThan(T, slice, threshold) bool`

Check if any element exceeds threshold.

```zig
const has_large = simd.anyGreaterThan(i64, data, 1000);
```

### `allLessThan(T, slice, threshold) bool`

Check if all elements are below threshold.

```zig
const all_small = simd.allLessThan(i64, data, 1000);
```

---

## Threshold Utilities

### `getParallelThreshold(T, op) usize`

Get minimum data size for profitable parallelization.

```zig
const threshold = simd.getParallelThreshold(i64, .sum);
```

### `shouldParallelizeSimd(T, op, len) bool`

Check if parallel SIMD is beneficial.

```zig
if (simd.shouldParallelizeSimd(i64, .sum, data.len)) {
    return simd.parallelSum(i64, data);
} else {
    return simd.sum(i64, data);
}
```

### `calculateParallelThreshold(T, op) usize`

Calculate threshold based on operation and hardware.

---

## SIMD Constants

```zig
pub const VECTOR_WIDTH = 8;    // Elements per SIMD register
pub const UNROLL_FACTOR = 4;   // Accumulators for ILP
```

---

## Performance Characteristics

| Operation | Throughput (single-thread) | Throughput (parallel) |
|-----------|---------------------------|----------------------|
| Sum i64 | ~2B elem/sec | ~9B elem/sec |
| Min/Max i64 | ~2B elem/sec | ~9B elem/sec |
| Argmin i64 | ~1.5B elem/sec | ~6B elem/sec |
| FindValue | ~4B elem/sec | N/A (early exit) |

---

## Example: Complete SIMD Workflow

```zig
const simd = blitz.simd_mod;

// Choose best strategy based on data size
fn fastSum(data: []const i64) i64 {
    if (data.len == 0) return 0;

    if (simd.shouldParallelizeSimd(i64, .sum, data.len)) {
        return simd.parallelSum(i64, data);
    } else if (data.len >= 32) {
        return simd.sum(i64, data);
    } else {
        // Scalar for tiny arrays
        var sum: i64 = 0;
        for (data) |v| sum += v;
        return sum;
    }
}
```
