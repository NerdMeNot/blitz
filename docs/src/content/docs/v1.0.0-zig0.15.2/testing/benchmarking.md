---
title: Benchmarking
description: How to benchmark Blitz performance.
slug: v1.0.0-zig0.15.2/testing/benchmarking
---

## Quick Start

```bash
# Run benchmarks (builds with ReleaseFast automatically)
zig build bench

# Run comparative benchmark (Blitz vs Rayon)
zig build compare
```

## Benchmark Suite

The main benchmark compares Blitz against baseline and Rayon:

```
======================================================================
              BLITZ vs RAYON COMPARISON BENCHMARKS
======================================================================

Initialized with 10 workers

+-----------------------+------------+------------+----------+
| Benchmark             | Blitz      | Sequential | Speedup  |
+-----------------------+------------+------------+----------+
| Parallel Sum 10M      | 1.2 ms     | 35.0 ms    | 29.2x    |
| Parallel Sort 10M     | 430 ms     | 4644 ms    | 10.8x    |
| Fork-Join fib(40)     | 93 ms      | 635 ms     | 6.8x     |
| Find First 10M        | 3.3 ms     | 28.0 ms    | 8.5x     |
+-----------------------+------------+------------+----------+
```

## Writing Benchmarks

### Basic Benchmark Pattern

```zig
fn benchmarkSum() void {
    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data = allocator.alloc(i64, n) catch unreachable;
    defer allocator.free(data);

    // Initialize
    for (data, 0..) |*v, i| v.* = @intCast(i);

    // Warmup
    _ = blitz.iter(i64, data).sum(i64, data);

    // Benchmark
    const iterations = 10;
    var total_ns: i64 = 0;

    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        _ = blitz.iter(i64, data).sum(i64, data);
        total_ns += std.time.nanoTimestamp() - start;
    }

    const avg_ms = @as(f64, @floatFromInt(total_ns)) / @as(f64, iterations) / 1_000_000.0;
    std.debug.print("Parallel sum: {d:.2} ms\n", .{avg_ms});
}
```

### Comparing Implementations

```zig
fn benchmarkComparison() void {
    const data = generateData(10_000_000);

    // Sequential baseline
    const seq_start = std.time.nanoTimestamp();
    var seq_sum: i64 = 0;
    for (data) |v| seq_sum += v;
    const seq_time = std.time.nanoTimestamp() - seq_start;

    // Parallel
    const par_start = std.time.nanoTimestamp();
    const par_sum = blitz.iter(i64, data).sum(i64, data);
    const par_time = std.time.nanoTimestamp() - par_start;

    // Verify correctness
    std.debug.assert(seq_sum == par_sum);

    // Report
    const speedup = @as(f64, @floatFromInt(seq_time)) /
                    @as(f64, @floatFromInt(par_time));
    std.debug.print("Speedup: {d:.1}x\n", .{speedup});
}
```

## Benchmarking Best Practices

### 1. Use Release Mode

```bash
# Always benchmark with optimizations
zig build-exe ... -O ReleaseFast

# NOT debug mode
zig build-exe ... -O Debug  # Much slower!
```

### 2. Warmup

```zig
// Run once to warm caches and trigger JIT
_ = functionToBenchmark();

// Then measure
const start = std.time.nanoTimestamp();
_ = functionToBenchmark();
const elapsed = std.time.nanoTimestamp() - start;
```

### 3. Multiple Iterations

```zig
const iterations = 100;
var min_time: i64 = std.math.maxInt(i64);

for (0..iterations) |_| {
    const start = std.time.nanoTimestamp();
    _ = functionToBenchmark();
    const elapsed = std.time.nanoTimestamp() - start;
    min_time = @min(min_time, elapsed);
}

// Report minimum (least affected by noise)
```

### 4. Prevent Optimization

```zig
// Use doNotOptimizeAway to prevent dead code elimination
const result = functionToBenchmark();
std.mem.doNotOptimizeAway(&result);
```

### 5. Isolate Measurements

```zig
// Allocate OUTSIDE the timing loop
const data = allocator.alloc(i64, n);
defer allocator.free(data);

// Only measure the operation
const start = std.time.nanoTimestamp();
processData(data);
const elapsed = std.time.nanoTimestamp() - start;
```

## Metrics to Track

### Throughput

```zig
const elements_per_sec = @as(f64, @floatFromInt(n)) /
                         (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

std.debug.print("Throughput: {d:.2} billion elements/sec\n", .{
    elements_per_sec / 1_000_000_000.0,
});
```

### Speedup

```zig
const speedup = @as(f64, @floatFromInt(sequential_time)) /
                @as(f64, @floatFromInt(parallel_time));

std.debug.print("Speedup: {d:.1}x over sequential\n", .{speedup});
```

### Efficiency

```zig
const efficiency = speedup / @as(f64, @floatFromInt(num_workers)) * 100.0;
std.debug.print("Parallel efficiency: {d:.1}%\n", .{efficiency});
```

## Input Patterns

Test with various data patterns:

```zig
fn benchmarkSort() void {
    const patterns = .{
        .{ "Random", generateRandom },
        .{ "Sorted", generateSorted },
        .{ "Reverse", generateReverse },
        .{ "Equal", generateEqual },
        .{ "Few unique", generateFewUnique },
    };

    inline for (patterns) |pattern| {
        const name = pattern[0];
        const generator = pattern[1];
        const data = generator(10_000_000);

        const start = std.time.nanoTimestamp();
        blitz.sortAsc(i64, data);
        const elapsed = std.time.nanoTimestamp() - start;

        std.debug.print("{s}: {d:.2} ms\n", .{
            name,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    }
}
```

## Scaling Analysis

Measure how performance scales with cores:

```zig
fn benchmarkScaling() void {
    const core_counts = [_]u32{ 1, 2, 4, 8, 16 };

    for (core_counts) |cores| {
        blitz.deinit();
        try blitz.initWithConfig(.{ .background_worker_count = cores - 1 });

        const time = measureOperation();
        std.debug.print("{} cores: {d:.2} ms\n", .{ cores, time });
    }
}
```

## Thread Pool Efficiency

When benchmarking parallel workloads, track CPU efficiency metrics:

### Resource Usage

```zig
const posix = std.posix;

fn getResourceUsage() struct { ctx_switches: i64, peak_memory: i64 } {
    const ru = posix.getrusage(posix.RUSAGE.SELF);
    return .{
        .ctx_switches = ru.nivcsw,  // Involuntary context switches
        .peak_memory = ru.maxrss,   // Peak RSS in bytes (macOS) or KB (Linux)
    };
}
```

### Key Metrics

| Metric | Good | Concerning |
|--------|------|------------|
| CPU time / wall time | \< 2x (for N threads) | > 3x indicates contention |
| Involuntary ctx switches | \< 1000 | > 10000 indicates spinning |
| Instructions per cycle | > 1.5 | \< 0.5 indicates stalls |

### Thread Pool Parameters

Blitz uses progressive sleep (spin -> yield -> sleep) with tunable constants:

```zig
// In pool.zig
const SPIN_LIMIT: u32 = 32;   // Spin rounds before yielding
const YIELD_LIMIT: u32 = 64;  // Total rounds before sleeping
```

**Trade-offs:**

* Higher values: Better latency for continuous workloads, more CPU usage
* Lower values: Better CPU efficiency for bursty workloads, higher wake latency

Current values (32/64) combined with smart wake provide:

* Excellent performance on continuous workloads (24/26 benchmark wins vs Rayon)
* Smart wake (`wakeOneIfNeeded`) avoids unnecessary worker wakes
* Good balance between latency and CPU efficiency

### Diagnosing Contention

If you see high CPU time relative to wall time:

1. **Check context switches**: High involuntary switches indicate thread contention
2. **Profile with perf**: Look for time spent in `futex_wait`/`spinLoopHint`
3. **Measure efficiency**: `speedup / num_threads` should be > 50%

## Profiling

### CPU Profiling

```bash
# Linux perf
perf record ./benchmark
perf report

# macOS Instruments
xcrun xctrace record --template "Time Profiler" --launch ./benchmark
```

### Cache Analysis

```bash
# Linux
perf stat -e cache-misses,cache-references ./benchmark

# Valgrind cachegrind
valgrind --tool=cachegrind ./benchmark
```
