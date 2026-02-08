---
title: Collect & Scatter
description: Parallel map-collect, in-place transforms, flatten, scatter, and
  SyncPtr for lock-free writes
slug: v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/1.0.0-zig0.15.2/usage/collect-scatter
---

Parallel collection primitives for gathering, transforming, and distributing data. These APIs follow the Polars-style pattern of computing offsets, then writing in parallel without locks.

## parallelCollect

Map each element in parallel and collect results into an output slice. This is equivalent to Rayon's `.par_iter().map().collect()`.

```zig
const blitz = @import("blitz");

var input: [100_000]i32 = undefined;
var output: [100_000]f64 = undefined;

// Initialize input
for (&input, 0..) |*v, i| v.* = @intCast(i);

// Parallel map: i32 -> f64
blitz.parallelCollect(
    i32,                    // Input type
    f64,                    // Output type
    &input,                 // Input slice
    &output,                // Output slice (must be same length)
    void,                   // Context type
    {},                     // Context value
    struct {
        fn transform(_: void, x: i32) f64 {
            return @sqrt(@as(f64, @floatFromInt(x)));
        }
    }.transform,
);
// output[i] = sqrt(i) for all i
```

### With Context

```zig
const ScaleCtx = struct {
    scale: f64,
    offset: f64,
};

blitz.parallelCollect(
    i32, f64,
    &input, &output,
    ScaleCtx,
    .{ .scale = 2.5, .offset = 10.0 },
    struct {
        fn transform(ctx: ScaleCtx, x: i32) f64 {
            return @as(f64, @floatFromInt(x)) * ctx.scale + ctx.offset;
        }
    }.transform,
);
```

### Custom Grain Size

```zig
// Use fine-grained parallelism for expensive transforms
blitz.parallelCollectWithGrain(
    i32, f64,
    &input, &output,
    void, {},
    expensiveTransform,
    100,  // Small grain for expensive per-element work
);
```

## parallelMapInPlace

Transform elements in-place without allocating a separate output buffer:

```zig
var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

// Double every element in parallel
blitz.parallelMapInPlace(
    i32,
    &data,
    void,
    {},
    struct {
        fn double(_: void, x: i32) i32 {
            return x * 2;
        }
    }.double,
);
// data is now [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]
```

### With Context

```zig
const NormCtx = struct {
    max_val: f64,
};

blitz.parallelMapInPlace(
    f64,
    data_slice,
    NormCtx,
    .{ .max_val = 255.0 },
    struct {
        fn normalize(ctx: NormCtx, x: f64) f64 {
            return x / ctx.max_val;
        }
    }.normalize,
);
```

## parallelFlatten

Flatten an array of slices into a single contiguous output slice in parallel:

```zig
const slice_a = [_]u32{ 1, 2, 3 };
const slice_b = [_]u32{ 4, 5 };
const slice_c = [_]u32{ 6, 7, 8, 9 };

const slices = [_][]const u32{ &slice_a, &slice_b, &slice_c };
var output: [9]u32 = undefined;

blitz.parallelFlatten(u32, &slices, &output);
// output = [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

### How It Works

The algorithm has two phases:

```
Input slices:  [A, A, A]  [B, B]  [C, C, C, C]

Phase 1: Compute offsets (sequential prefix sum)
  lengths = [3, 2, 4]
  offsets = [0, 3, 5]
  total   = 9

Phase 2: Parallel copy (each slice copies independently)
  ┌─────────┬──────┬───────────┐
  │ A A A   │ B B  │ C C C C   │
  │ offset=0│ =3   │ =5        │
  │ Worker 0│ W-1  │ W-2       │
  └─────────┴──────┴───────────┘
```

Because each slice writes to a disjoint region of the output, no locks are needed.

### With Pre-Computed Offsets

If you have already computed offsets (e.g., from a prior pass), avoid recomputation:

```zig
var offsets: [3]usize = undefined;
const total = blitz.capAndOffsets(u32, &slices, &offsets);
// offsets = [0, 3, 5], total = 9

var output = try allocator.alloc(u32, total);
defer allocator.free(output);

blitz.parallelFlattenWithOffsets(u32, &slices, &offsets, output);
```

## parallelScatter

Scatter values to arbitrary positions in an output array using index mapping:

```zig
const values  = [_]u32{ 100, 200, 300, 400 };
const indices = [_]usize{ 3, 0, 7, 1 };
var output: [10]u32 = undefined;
@memset(&output, 0);

blitz.parallelScatter(u32, &values, &indices, &output);
// output[0] = 200, output[1] = 400, output[3] = 100, output[7] = 300
// (other positions remain 0)
```

**Safety requirement**: Each index in `indices` must be unique. If two values map to the same output index, the result is a data race.

## SyncPtr

`SyncPtr` is a lock-free parallel write pointer. It wraps a raw pointer and provides thread-safe write operations for disjoint memory regions.

```zig
var buffer: [1000]u64 = undefined;
const ptr = blitz.SyncPtr(u64).init(&buffer);

// These can run on different threads (disjoint offsets):
ptr.writeAt(0, 42);       // Write single value
ptr.readAt(0);             // Read single value
ptr.copyAt(100, src);      // Copy a slice to offset 100
const s = ptr.sliceFrom(50, 10);  // Get slice view [50..60]
```

### SyncPtr API

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `fn([]T) SyncPtr(T)` | Create from a slice |
| `writeAt` | `fn(offset, value)` | Write one element |
| `readAt` | `fn(offset) T` | Read one element |
| `copyAt` | `fn(offset, []const T)` | Copy a slice to offset |
| `sliceFrom` | `fn(offset, len) []T` | Get a slice view |

**Safety**: You must ensure that concurrent writes target disjoint offsets. SyncPtr does not check for overlapping writes.

## computeOffsetsInto

Compute prefix sums (running totals) of lengths into an offsets buffer. Returns the grand total.

```zig
const lengths = [_]usize{ 3, 0, 5, 2 };
var offsets: [4]usize = undefined;

const total = blitz.computeOffsetsInto(&lengths, &offsets);
// offsets = [0, 3, 3, 8]
// total   = 10
```

This is the fundamental primitive for the Polars-style parallel write pattern: compute where each thread should write, then let every thread write independently.

## capAndOffsets

Compute offsets for flattening nested slices. Like `computeOffsetsInto`, but takes slices directly and extracts their lengths.

```zig
const slices = [_][]const u32{ slice_a, slice_b, slice_c };
var offsets: [3]usize = undefined;

const total = blitz.capAndOffsets(u32, &slices, &offsets);
// total = sum of all slice lengths
// offsets[i] = starting position for slices[i] in the flattened output
```

## Complete Example: Flatten Nested Results

A common pattern is to process data in parallel where each task produces a variable number of results, then flatten everything into a single output array.

```zig
const std = @import("std");
const blitz = @import("blitz");

/// Each chunk produces variable-length filtered results.
fn filterChunk(chunk: []const i64, buf: []i64) []i64 {
    var count: usize = 0;
    for (chunk) |v| {
        if (v > 0) {
            buf[count] = v;
            count += 1;
        }
    }
    return buf[0..count];
}

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Step 1: Split data into chunks and filter each in parallel
    const data: []const i64 = input_data;
    const chunk_size = 10_000;
    const num_chunks = (data.len + chunk_size - 1) / chunk_size;

    // Allocate per-chunk buffers and result slices
    var chunk_results = try allocator.alloc([]i64, num_chunks);
    defer allocator.free(chunk_results);

    var chunk_bufs = try allocator.alloc([]i64, num_chunks);
    defer {
        for (chunk_bufs) |buf| allocator.free(buf);
        allocator.free(chunk_bufs);
    }

    for (0..num_chunks) |i| {
        chunk_bufs[i] = try allocator.alloc(i64, chunk_size);
    }

    // Process each chunk (could be parallelized with parallelFor)
    for (0..num_chunks) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, data.len);
        chunk_results[i] = filterChunk(data[start..end], chunk_bufs[i]);
    }

    // Step 2: Compute offsets from result lengths
    var offsets = try allocator.alloc(usize, num_chunks);
    defer allocator.free(offsets);

    // Convert chunk_results to []const []const i64 for capAndOffsets
    var const_results = try allocator.alloc([]const i64, num_chunks);
    defer allocator.free(const_results);
    for (chunk_results, 0..) |r, i| const_results[i] = r;

    const total = blitz.capAndOffsets(i64, const_results, offsets);

    // Step 3: Allocate output and flatten in parallel
    var output = try allocator.alloc(i64, total);
    defer allocator.free(output);

    blitz.parallelFlattenWithOffsets(i64, const_results, offsets, output);

    // output now contains all positive values from input_data, flattened
    std.debug.print("Filtered {d} positive values from {d} total\n", .{
        total, data.len,
    });
}
```

## The Polars Pattern

The APIs in this module follow the pattern used by the Polars DataFrame library for parallel materialization:

```
1. PLAN:    Determine output sizes (lengths array)
2. OFFSET:  Compute prefix sums   (computeOffsetsInto)
3. ALLOC:   Allocate output buffer (total from step 2)
4. WRITE:   Parallel scatter/copy  (SyncPtr, parallelFlatten, parallelScatter)
```

Each step is simple and composable. The key insight is that once offsets are computed, every thread knows exactly where to write, eliminating the need for locks.

## When to Use What

| Goal | API | Notes |
|------|-----|-------|
| Transform A\[] to B\[] | `parallelCollect` | Different input/output types |
| Transform A\[] in-place | `parallelMapInPlace` | No allocation needed |
| Merge slice-of-slices | `parallelFlatten` | Auto-computes offsets |
| Merge with known offsets | `parallelFlattenWithOffsets` | Reuse pre-computed offsets |
| Write to arbitrary positions | `parallelScatter` | Index-based placement |
| Low-level parallel writes | `SyncPtr` | Maximum control |
| Compute write positions | `computeOffsetsInto` | Prefix sum of lengths |
| Offsets from nested slices | `capAndOffsets` | Prefix sum of slice lengths |
