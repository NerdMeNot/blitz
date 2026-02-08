---
title: Parallel For
description: Execute a function over a range with automatic work distribution
slug: v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/usage/parallel-for
---

Execute a function over a range `[0, n)` with automatic work distribution.

## Basic Usage

```zig
const blitz = @import("blitz");

// Process 1 million elements in parallel
var data: [1_000_000]f64 = undefined;

const Context = struct { data: []f64 };

blitz.parallelFor(data.len, Context, .{ .data = &data }, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        for (ctx.data[start..end], start..) |*v, i| {
            v.* = @sqrt(@as(f64, @floatFromInt(i)));
        }
    }
}.body);
```

## How It Works

1. Range `[0, n)` is divided into chunks
2. Each worker gets a chunk `[start, end)`
3. Work stealing balances load dynamically

```
n = 1000, 4 workers:
┌────────────┬────────────┬────────────┬────────────┐
│  0 - 250   │ 250 - 500  │ 500 - 750  │ 750 - 1000 │
│  Worker 0  │  Worker 1  │  Worker 2  │  Worker 3  │
└────────────┴────────────┴────────────┴────────────┘
```

## Custom Grain Size

Control chunk size for tuning:

```zig
// Each chunk processes at least 1000 elements
blitz.parallelForWithGrain(n, Context, ctx, bodyFn, 1000);
```

**Complete example with grain size:**

```zig
const Context = struct {
    input: []const f64,
    output: []f64,
};

// Small grain (100) for expensive per-element operations
blitz.parallelForWithGrain(
    data.len,
    Context,
    .{ .input = input, .output = output },
    struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.input[start..end], ctx.output[start..end]) |in, *out| {
                out.* = @exp(in) * @sin(in);  // Expensive math
            }
        }
    }.body,
    100,  // Small chunks = more parallelism
);

// Large grain (10000) for cheap operations
blitz.parallelForWithGrain(
    data.len,
    struct { data: []i64 },
    .{ .data = data },
    struct {
        fn body(ctx: @This(), start: usize, end: usize) void {
            for (ctx.data[start..end]) |*v| {
                v.* += 1;  // Very cheap operation
            }
        }
    }.body,
    10000,  // Large chunks = less overhead
);
```

**Grain size effects:**

| Grain Size | Overhead | Load Balance | Best For |
|------------|----------|--------------|----------|
| Small (100) | High | Excellent | Expensive operations |
| Medium (1K) | Low | Good | General purpose |
| Large (10K) | Very low | Poor | Cheap operations |

## Context Patterns

### Read-Only Context

```zig
const Context = struct {
    input: []const f64,
    multiplier: f64,
};

blitz.parallelFor(n, Context, .{
    .input = input_data,
    .multiplier = 2.5,
}, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        for (ctx.input[start..end]) |v| {
            // Read-only access
            processValue(v * ctx.multiplier);
        }
    }
}.body);
```

### Write Context (Disjoint Regions)

```zig
const Context = struct {
    input: []const f64,
    output: []f64,  // Each chunk writes to its own region
};

blitz.parallelFor(n, Context, .{
    .input = input_data,
    .output = output_data,
}, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        // Safe: each chunk writes to disjoint region
        for (ctx.input[start..end], ctx.output[start..end]) |in, *out| {
            out.* = in * 2;
        }
    }
}.body);
```

### No Context Needed

```zig
// Use void when no external data needed
blitz.parallelFor(n, void, {}, struct {
    fn body(_: void, start: usize, end: usize) void {
        for (start..end) |i| {
            // Work with just the index
            doSomething(i);
        }
    }
}.body);
```

## Common Patterns

### Initialize Array

```zig
blitz.parallelFor(data.len, struct { data: []i64 }, .{ .data = data }, struct {
    fn body(ctx: @This(), start: usize, end: usize) void {
        for (ctx.data[start..end], start..) |*v, i| {
            v.* = @intCast(i * i);
        }
    }
}.body);
```

### Transform In-Place

```zig
blitz.parallelFor(data.len, struct { data: []f64 }, .{ .data = data }, struct {
    fn body(ctx: @This(), start: usize, end: usize) void {
        for (ctx.data[start..end]) |*v| {
            v.* = @sqrt(v.*);
        }
    }
}.body);
```

### Copy with Transform

```zig
const Ctx = struct { src: []const f64, dst: []f64, scale: f64 };

blitz.parallelFor(src.len, Ctx, .{ .src = src, .dst = dst, .scale = 2.0 }, struct {
    fn body(ctx: Ctx, start: usize, end: usize) void {
        for (ctx.src[start..end], ctx.dst[start..end]) |s, *d| {
            d.* = s * ctx.scale;
        }
    }
}.body);
```

## Real-World Example: Image Brightness

```zig
const Pixel = struct { r: u8, g: u8, b: u8, a: u8 };

fn adjustBrightness(pixels: []Pixel, factor: f32) void {
    const Context = struct { pixels: []Pixel, factor: f32 };

    blitz.parallelFor(pixels.len, Context, .{
        .pixels = pixels,
        .factor = factor,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.pixels[start..end]) |*p| {
                p.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(p.r)) * ctx.factor));
                p.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(p.g)) * ctx.factor));
                p.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(p.b)) * ctx.factor));
            }
        }
    }.body);
}
```

See the [Image Processing cookbook recipe](/v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/cookbook/image-processing/) for a complete pipeline.

## Performance Tips

1. **Minimize context size** - Large contexts are copied to each worker
2. **Use slices, not arrays** - Slices are just pointer + length
3. **Avoid false sharing** - Don't write to adjacent cache lines
4. **Choose appropriate grain** - Profile to find optimal size

## When NOT to Use

* **Small n (\<1000)**: Overhead exceeds benefit
* **Memory-bound ops**: May not scale with cores
* **Shared mutable state**: Race conditions!

Use `blitz.internal.shouldParallelize()` to decide automatically:

```zig
if (blitz.internal.shouldParallelize(.transform, data.len)) {
    blitz.parallelFor(data.len, ctx_type, ctx, bodyFn);
} else {
    // Sequential fallback
    for (data) |*v| { ... }
}
```
