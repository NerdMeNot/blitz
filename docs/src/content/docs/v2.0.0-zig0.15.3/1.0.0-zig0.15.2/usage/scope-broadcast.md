---
title: Scope & Broadcast
description: Scope-based parallelism, fire-and-forget spawn, parallel index
  ranges, and broadcast to all workers
slug: v2.0.0-zig0.15.3/1.0.0-zig0.15.2/usage/scope-broadcast
---

Scope-based parallelism for spawning arbitrary tasks that must all complete before the scope exits, plus utilities for fire-and-forget background work and broadcasting to all worker threads.

## Scope

A scope collects tasks during its body, then executes them all in parallel when the scope exits. This is the "collect and execute" model.

```zig
const blitz = @import("blitz");

blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        s.spawn(computeStatistics);
        s.spawn(buildIndex);
        s.spawn(validateData);
    }
    // All three tasks execute in parallel here, when scope exits
}.run);
// All tasks guaranteed complete at this point
```

### How It Works

```
blitz.scope(func):
┌─────────────────────────────────────────────────┐
│  1. Create scope                                │
│  2. Run func(scope) — collects tasks            │
│     scope.spawn(A)  → tasks = [A]               │
│     scope.spawn(B)  → tasks = [A, B]            │
│     scope.spawn(C)  → tasks = [A, B, C]         │
│                                                 │
│  3. scope.wait() — execute all in parallel      │
│     ┌─────┐  ┌─────┐  ┌─────┐                  │
│     │  A  │  │  B  │  │  C  │                   │
│     │ W-0 │  │ W-1 │  │ W-2 │                   │
│     └─────┘  └─────┘  └─────┘                   │
│                                                 │
│  4. All complete → scope returns                │
└─────────────────────────────────────────────────┘
```

Tasks are not started until the scope body returns (or `wait()` is called explicitly). This differs from Rayon's immediate-spawn model but provides the same parallel execution semantics.

### Scope with Context

Pass data into the scope body using `scopeWithContext`:

```zig
const Config = struct {
    data: []const f64,
    threshold: f64,
};

const config = Config{
    .data = sensor_data,
    .threshold = 0.95,
};

blitz.scopeWithContext(Config, config, struct {
    fn run(cfg: Config, s: *blitz.Scope) void {
        // Access config inside the scope
        if (cfg.data.len > 1000) {
            s.spawn(heavyAnalysis);
            s.spawn(buildReport);
        } else {
            s.spawn(quickSummary);
        }
    }
}.run);
```

### 64-Task Limit

A scope supports a maximum of 64 spawned tasks. This is a compile-time fixed limit for stack allocation efficiency.

```zig
// This will panic at runtime:
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        for (0..65) |_| {
            s.spawn(someTask);  // Panics on the 65th spawn!
        }
    }
}.run);
```

For larger workloads, use `parallelFor` or `parallelForRange` instead, which split work adaptively without a fixed task limit:

```zig
// Process 10,000 items — no task limit
blitz.parallelFor(10_000, Context, ctx, bodyFn);
```

### Manual Wait

You can call `wait()` explicitly to execute tasks mid-scope, then spawn more:

```zig
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        // Phase 1: data loading
        s.spawn(loadDataA);
        s.spawn(loadDataB);
        s.wait();  // Execute and wait for phase 1

        // Phase 2: processing (runs after phase 1 completes)
        s.spawn(processResults);
        s.spawn(generateReport);
        // wait() called automatically when scope exits
    }
}.run);
```

## Parallel For Range

Execute a function over each index in a range `[start, end)`:

```zig
// Process indices 100..500
blitz.parallelForRange(100, 500, struct {
    fn process(i: usize) void {
        updatePixel(i);
    }
}.process);
```

Unlike `parallelFor`, where the body receives chunk boundaries `(start, end)`, `parallelForRange` calls the function once per index. This is simpler when per-element work is the natural unit.

### With Context

```zig
const ImageCtx = struct {
    pixels: []Pixel,
    brightness: f32,
};

blitz.parallelForRangeWithContext(
    ImageCtx,
    .{ .pixels = pixels, .brightness = 1.5 },
    0,
    pixels.len,
    struct {
        fn adjust(ctx: ImageCtx, i: usize) void {
            ctx.pixels[i].r = @min(255, ctx.pixels[i].r * ctx.brightness);
            ctx.pixels[i].g = @min(255, ctx.pixels[i].g * ctx.brightness);
            ctx.pixels[i].b = @min(255, ctx.pixels[i].b * ctx.brightness);
        }
    }.adjust,
);
```

### parallelForRange vs parallelFor

| Feature | `parallelForRange` | `parallelFor` |
|---------|-------------------|---------------|
| Callback receives | Single index `i` | Chunk `(start, end)` |
| Use when | Per-element work is natural | Batch processing is efficient |
| Overhead | Slightly higher (one call per element) | Lower (one call per chunk) |
| Context | `parallelForRangeWithContext` | Built into `parallelFor` |

## Spawn (Fire-and-Forget)

Spawn a background task that runs asynchronously:

```zig
// Fire and forget — returns immediately
blitz.spawn(struct {
    fn run() void {
        writeAuditLog();
    }
}.run);
```

With context:

```zig
const LogCtx = struct {
    message: []const u8,
    level: u8,
};

blitz.spawnWithContext(LogCtx, .{
    .message = "operation completed",
    .level = 2,
}, struct {
    fn run(ctx: LogCtx) void {
        appendToLog(ctx.message, ctx.level);
    }
}.run);
```

**Note**: The spawned task must complete before program exit. If you need to wait for completion, use `scope()` instead.

## Broadcast

Execute a function on every worker thread. Each invocation receives the worker index:

```zig
blitz.broadcast(struct {
    fn run(worker_index: usize) void {
        std.debug.print("Hello from worker {}\n", .{worker_index});
    }
}.run);
```

### Thread-Local Initialization

Broadcast is ideal for initializing per-thread state:

```zig
// Per-worker scratch buffers (module-level storage)
var worker_buffers: [64][4096]u8 = undefined;

// Initialize all worker buffers in parallel
blitz.broadcast(struct {
    fn init(worker_index: usize) void {
        @memset(&worker_buffers[worker_index], 0);
    }
}.init);
```

### With Context

```zig
const SeedCtx = struct {
    base_seed: u64,
};

blitz.broadcastWithContext(SeedCtx, .{ .base_seed = 12345 }, struct {
    fn init(ctx: SeedCtx, worker_index: usize) void {
        // Each worker gets a unique seed derived from base + index
        initWorkerRng(ctx.base_seed + worker_index);
    }
}.init);
```

### Common Broadcast Patterns

| Pattern | Description |
|---------|-------------|
| Thread-local init | Initialize per-worker buffers or RNG seeds |
| Cache warming | Pre-load data into each worker's cache |
| Statistics reset | Clear per-worker counters before a benchmark |
| Health check | Verify each worker thread is responsive |

## When to Use What

| Goal | API | Why |
|------|-----|-----|
| Run 2-8 heterogeneous tasks | `join(.{...})` | Named results, different return types |
| Run 2-64 homogeneous tasks | `scope()` + `spawn()` | Dynamic task count |
| Process every element in a range | `parallelForRange()` | Per-element callback |
| Process array in chunks | `parallelFor()` | Chunk-based, lower overhead |
| Background work | `spawn()` | Fire-and-forget |
| Run on every worker | `broadcast()` | Thread-local init |
| 65+ independent tasks | `parallelFor()` | No task limit |

## Complete Example

```zig
const std = @import("std");
const blitz = @import("blitz");

// Per-worker accumulators
var worker_sums: [64]std.atomic.Value(i64) = init: {
    var sums: [64]std.atomic.Value(i64) = undefined;
    for (&sums) |*s| s.* = std.atomic.Value(i64).init(0);
    break :init sums;
};

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    // Step 1: Reset all worker accumulators
    blitz.broadcast(struct {
        fn reset(worker_index: usize) void {
            worker_sums[worker_index].store(0, .release);
        }
    }.reset);

    // Step 2: Use scope to run analysis phases
    blitz.scope(struct {
        fn run(s: *blitz.Scope) void {
            s.spawn(analyzePhaseA);
            s.spawn(analyzePhaseB);
            s.spawn(analyzePhaseC);
        }

        fn analyzePhaseA() void {
            // ... heavy computation ...
        }
        fn analyzePhaseB() void {
            // ... heavy computation ...
        }
        fn analyzePhaseC() void {
            // ... heavy computation ...
        }
    }.run);

    // Step 3: All phases complete here
    std.debug.print("Analysis complete\n", .{});
}
```
