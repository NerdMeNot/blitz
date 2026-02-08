---
title: Cookbook Overview
description: Practical recipes for common parallel computing tasks using Blitz
slug: 1.0.0-zig0.15.2/cookbook
---

Practical recipes showing how to solve real-world problems with Blitz. Each recipe follows the same structure: a problem statement, a complete solution with working Zig code, an explanation of which APIs are used and why, and performance guidance.

## Recipes

| Recipe | Description | Key APIs |
|--------|-------------|----------|
| [Image Processing](/1.0.0-zig0.15.2/cookbook/image-processing/) | Pixel transforms, grayscale conversion, and gaussian blur on image buffers | `parallelFor`, `iterMut().mapInPlace()` |
| [CSV Data Parsing](/1.0.0-zig0.15.2/cookbook/csv-parsing/) | Parse CSV lines in parallel and aggregate numeric results | `parallelReduce`, `join()` |
| [Monte Carlo Simulation](/1.0.0-zig0.15.2/cookbook/monte-carlo/) | Estimate pi using random sampling across threads | `parallelReduce`, `range()` |
| [Log File Analysis](/1.0.0-zig0.15.2/cookbook/log-analysis/) | Search logs for patterns, count errors, and find specific entries | `iter().any()`, `iter().findAny()`, `join()` |
| [Matrix Multiplication](/1.0.0-zig0.15.2/cookbook/matrix-multiplication/) | Dense matrix multiply with parallel row computation | `parallelFor` with context |

## Choosing the Right API

These recipes demonstrate different Blitz APIs. Use this guide to pick the right one for your task:

| Task Pattern | Recommended API | Why |
|-------------|-----------------|-----|
| Transform every element | `iterMut().mapInPlace()` | In-place, zero allocation |
| Aggregate to single value | `iter().sum()` / `.min()` / `.max()` | Optimized parallel reduction |
| Custom aggregation | `iter().reduce()` or `parallelReduce()` | Full control over combine logic |
| Search for element | `iter().findAny()` / `.any()` / `.all()` | Early exit stops all workers |
| Index-based loop with context | `parallelFor()` | Access external data via context struct |
| Multiple independent tasks | `join()` | Named results, heterogeneous types |
| Range-based computation | `range().forEach()` / `.sum()` | No backing slice needed |

## Common Patterns Across Recipes

### Context Structs

Most low-level APIs use a context struct to pass data into the parallel body:

```zig
const Context = struct {
    input: []const f64,
    output: []f64,
    scale: f64,
};

blitz.parallelFor(n, Context, .{
    .input = input,
    .output = output,
    .scale = 2.0,
}, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        for (ctx.input[start..end], ctx.output[start..end]) |in, *out| {
            out.* = in * ctx.scale;
        }
    }
}.body);
```

### Sequential Thresholds

For small data sizes, the overhead of parallelism exceeds the benefit. Blitz handles this internally for iterator operations, but for custom algorithms you should add your own thresholds:

```zig
if (data.len < 10_000) {
    // Sequential fallback
    for (data) |*v| v.* = transform(v.*);
} else {
    blitz.iterMut(f64, data).mapInPlace(transform);
}
```

### Associative Combine Functions

When using `parallelReduce` or `iter().reduce()`, the combine function must be associative. Addition, multiplication, min, and max all qualify. Subtraction and division do not.
