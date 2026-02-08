---
title: Performance Tuning
description: Grain size tuning, profiling, and optimization strategies for Blitz parallel workloads
---

Practical guidance for getting the best performance out of Blitz's parallel runtime.

## When to Parallelize

Parallelism has overhead: forking tasks, work-stealing, and joining results. The work per element must be large enough to amortize this cost.

| Data Size | Per-Element Cost | Parallelize? |
|-----------|-----------------|--------------|
| < 1,000 | Any | No -- overhead dominates |
| 1K - 10K | Cheap (add, compare) | Probably not |
| 1K - 10K | Moderate (sqrt, trig) | Maybe -- benchmark it |
| 1K - 10K | Expensive (> 1us) | Yes |
| > 10K | Cheap | Yes |
| > 100K | Any | Definitely |

Use `blitz.internal.shouldParallelize()` for automatic decisions:

```zig
if (blitz.internal.shouldParallelize(.transform, data.len)) {
    blitz.parallelFor(data.len, ctx_type, ctx, bodyFn);
} else {
    for (data) |*v| v.* = transform(v.*);
}
```

## Grain Size

The grain size controls the minimum number of elements per parallel task. It is the single most important tuning knob.

### Default Behavior

Blitz uses a default grain size of 65,536. This works well for lightweight per-element operations.

### Reading and Setting Grain Size

```zig
// Check current grain size
const current = blitz.getGrainSize();

// Set a custom grain size
blitz.setGrainSize(1000);

// Reset to default
blitz.setGrainSize(0);
```

### Per-Call Grain Size

Most parallel operations have a `WithGrain` variant for one-off tuning:

```zig
// Global grain size is unchanged
blitz.parallelForWithGrain(n, ctx_type, ctx, bodyFn, 500);
blitz.parallelReduceWithGrain(T, n, identity, ctx_type, ctx, mapFn, combineFn, 4096);
blitz.parallelCollectWithGrain(T, U, input, output, ctx_type, ctx, mapFn, 100);
```

### Choosing a Grain Size

| Per-Element Work | Suggested Grain | Rationale |
|------------------|-----------------|-----------|
| Trivial (increment, assign) | 50,000 - 100,000 | Fork/join overhead is significant relative to work |
| Light (arithmetic, comparison) | 10,000 - 50,000 | Default range works well |
| Moderate (sqrt, exp, string ops) | 1,000 - 10,000 | More parallelism justified |
| Heavy (complex math, I/O, alloc) | 100 - 1,000 | Each element is expensive enough |
| Very heavy (> 1ms per element) | 1 - 100 | Maximum parallelism |

**Rule of thumb**: Each chunk should take at least 10-100 microseconds of work. If a chunk finishes in nanoseconds, the grain is too small.

### Measuring Grain Impact

```zig
const std = @import("std");
const blitz = @import("blitz");

fn benchmarkGrain(data: []f64, grain: usize) u64 {
    const start = std.time.nanoTimestamp();

    blitz.parallelForWithGrain(data.len, []f64, data, struct {
        fn body(d: []f64, s: usize, e: usize) void {
            for (d[s..e]) |*v| v.* = @exp(v.*);
        }
    }.body, grain);

    return @intCast(std.time.nanoTimestamp() - start);
}

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    var data: [1_000_000]f64 = undefined;
    for (&data, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i)) / 1_000_000.0;

    // Try different grain sizes
    const grains = [_]usize{ 100, 1_000, 10_000, 50_000, 100_000 };
    for (grains) |g| {
        @memset(&data, 0.5); // Reset
        const ns = benchmarkGrain(&data, g);
        std.debug.print("Grain {d:>7}: {d:>6.2} ms\n", .{
            g, @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        });
    }
}
```

## Memory-Bound vs Compute-Bound

### Compute-Bound Workloads

Operations limited by CPU throughput (math, logic, branching). These scale well with cores.

```zig
// Compute-bound: scales nearly linearly
blitz.parallelFor(n, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) void {
        for (c.data[start..end]) |*v| {
            v.* = @exp(v.*) * @sin(v.*) + @cos(v.*);  // Heavy math
        }
    }
}.body);
```

### Memory-Bound Workloads

Operations limited by memory bandwidth (simple reads/writes over large arrays). Adding more cores does not help once bandwidth is saturated.

```zig
// Memory-bound: may not scale beyond 2-4 cores
blitz.parallelFor(n, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) void {
        for (c.data[start..end]) |*v| {
            v.* += 1;  // Trivial compute, bottleneck is memory
        }
    }
}.body);
```

**Signs of memory-bound behavior**:
- Speedup plateaus at 2-4x regardless of core count
- Performance varies with array size (cache effects)
- Same throughput as `@memcpy` for similar data sizes

**Strategies for memory-bound code**:
- Use larger grain sizes to reduce overhead
- Process data in cache-friendly order (sequential access patterns)
- Consider whether parallelism is needed at all
- Combine multiple passes into one (kernel fusion)

## False Sharing

False sharing occurs when threads write to different variables that share the same cache line (typically 64 bytes). This causes cache lines to bounce between cores, destroying performance.

### The Problem

```zig
// BAD: Adjacent counters share cache lines
var counters: [8]u64 = undefined;  // 64 bytes total = 1 cache line!

blitz.parallelFor(n, *[8]u64, &counters, struct {
    fn body(c: *[8]u64, start: usize, end: usize) void {
        const worker = start % 8;
        for (start..end) |_| {
            c[worker] += 1;  // All 8 workers thrash the same cache line
        }
    }
}.body);
```

### The Fix

Pad structures to cache line boundaries:

```zig
// GOOD: Each counter on its own cache line
const PaddedCounter = struct {
    value: u64 = 0,
    _padding: [7]u64 = undefined,  // Pad to 64 bytes
};

var counters: [8]PaddedCounter = .{.{}} ** 8;
```

Or better yet, avoid shared mutable state entirely. Use parallel reduction:

```zig
// BEST: No shared state at all
const total = blitz.parallelReduce(
    u64, n, 0,
    Context, ctx,
    struct { fn map(c: Context, i: usize) u64 { return c.data[i]; } }.map,
    struct { fn add(a: u64, b: u64) u64 { return a + b; } }.add,
);
```

## Pool Statistics

Use `blitz.getStats()` to inspect runtime behavior:

```zig
try blitz.init();
defer blitz.deinit();

blitz.resetStats();

// Run your workload
blitz.parallelFor(n, ctx_type, ctx, bodyFn);

const stats = blitz.getStats();
std.debug.print("Tasks executed: {d}\n", .{stats.executed});
std.debug.print("Tasks stolen:   {d}\n", .{stats.stolen});
```

### Interpreting Stats

| Metric | Meaning |
|--------|---------|
| `executed` | Total tasks run across all workers |
| `stolen` | Tasks taken from another worker's deque |

**What to look for**:

- **High stolen / executed ratio** (> 30%): Good load balancing, work-stealing is active
- **Low stolen ratio** (< 5%): Work is evenly distributed (or grain is too large)
- **Zero stolen**: Either single-threaded or grain so large that each worker gets one chunk

## Profiling Tips

### 1. Establish a Baseline

Always measure sequential performance first:

```zig
// Sequential baseline
const seq_start = std.time.nanoTimestamp();
for (data) |*v| v.* = transform(v.*);
const seq_time = std.time.nanoTimestamp() - seq_start;

// Parallel
const par_start = std.time.nanoTimestamp();
blitz.parallelFor(data.len, ctx_type, ctx, bodyFn);
const par_time = std.time.nanoTimestamp() - par_start;

const speedup = @as(f64, @floatFromInt(seq_time)) / @as(f64, @floatFromInt(par_time));
std.debug.print("Speedup: {d:.1}x\n", .{speedup});
```

### 2. Warm Up

The first parallel call initializes threads and populates caches. Always discard the first iteration:

```zig
// Warm up (discard)
blitz.parallelFor(data.len, ctx_type, ctx, bodyFn);

// Actual measurement
const start = std.time.nanoTimestamp();
for (0..iterations) |_| {
    blitz.parallelFor(data.len, ctx_type, ctx, bodyFn);
}
const elapsed = std.time.nanoTimestamp() - start;
```

### 3. Use Enough Iterations

For fast operations, run thousands of iterations to get stable measurements. A single run can be noisy due to OS scheduling and cache state.

### 4. Check Worker Count

```zig
std.debug.print("Workers: {d}\n", .{blitz.numWorkers()});
```

Maximum theoretical speedup is bounded by the number of workers. If you see 4x speedup on an 8-core machine, investigate whether the workload is memory-bound or the grain is suboptimal.

### 5. Profile with System Tools

On macOS:
```bash
# Sample CPU usage during benchmark
sample <pid> 5 -file output.txt

# Instruments (Time Profiler)
xcrun xctrace record --template "Time Profiler" --launch -- ./benchmark
```

On Linux:
```bash
# perf stat for hardware counters
perf stat ./benchmark

# Flame graph
perf record -g ./benchmark && perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

## Common Pitfalls

### 1. Parallelizing Too Little Work

```zig
// BAD: 100 elements is too few
blitz.parallelFor(100, ctx_type, ctx, bodyFn);

// GOOD: Check size first
if (data.len > 10_000) {
    blitz.parallelFor(data.len, ctx_type, ctx, bodyFn);
} else {
    for (data) |*v| v.* = process(v.*);
}
```

### 2. Excessive Allocations in Parallel Bodies

```zig
// BAD: Each chunk allocates
fn body(ctx: Context, start: usize, end: usize) void {
    var list = std.ArrayList(i64).init(allocator);  // Allocation contention!
    defer list.deinit();
    ...
}

// GOOD: Pre-allocate or use stack buffers
fn body(ctx: Context, start: usize, end: usize) void {
    var buf: [1024]i64 = undefined;
    ...
}
```

### 3. Forgetting Initialization

```zig
// Without init(), everything runs sequentially (no crash, just slow)
blitz.parallelFor(n, ctx_type, ctx, bodyFn);

// Always initialize
try blitz.init();
defer blitz.deinit();
```

## Quick Reference

| Situation | Action |
|-----------|--------|
| Too slow, CPU idle | Decrease grain size |
| Too slow, high overhead | Increase grain size |
| Doesn't scale past 4x | Likely memory-bound; increase grain or fuse passes |
| Slower than sequential | Data too small or grain too small |
| Inconsistent timings | Warm up, run more iterations |
| High stolen ratio | Work is being rebalanced (usually good) |
| Need per-worker data | Use `broadcast()` for init, array indexed by worker |
