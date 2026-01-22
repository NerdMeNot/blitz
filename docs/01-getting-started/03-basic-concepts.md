# Basic Concepts

Understanding Blitz's execution model and core concepts.

## Work Stealing

Blitz uses a **work-stealing** scheduler, the same approach used by Rayon, Intel TBB, and other high-performance parallel runtimes.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Worker 0   │     │  Worker 1   │     │  Worker 2   │
│ ┌─────────┐ │     │ ┌─────────┐ │     │ ┌─────────┐ │
│ │  Deque  │ │     │ │  Deque  │ │     │ │  Deque  │ │
│ │ ┌─────┐ │ │     │ │         │ │     │ │         │ │
│ │ │Job A│◄┼─┼─────┼─┼─STEAL───┼─┼─────┼─┼─STEAL   │ │
│ │ ├─────┤ │ │     │ │         │ │     │ │         │ │
│ │ │Job B│ │ │     │ │         │ │     │ │         │ │
│ │ └──▲──┘ │ │     │ └─────────┘ │     │ └─────────┘ │
│ └────┼────┘ │     │             │     │             │
│   push/pop  │     │             │     │             │
└─────────────┘     └─────────────┘     └─────────────┘
```

### How It Works

1. **Each worker has a deque** (double-ended queue)
2. **Workers push/pop from the bottom** (LIFO - keeps cache hot)
3. **Idle workers steal from the top** (FIFO - takes oldest work)
4. **No central queue** - work is distributed automatically

### Why Work Stealing?

| Approach | Pros | Cons |
|----------|------|------|
| Central queue | Simple | Contention bottleneck |
| Static partitioning | No overhead | Load imbalance |
| **Work stealing** | Dynamic balance, low contention | Slightly complex |

## Fork-Join Model

Blitz follows the **fork-join** execution model:

```
        fork(B)              join()
           │                    │
           ▼                    ▼
    ┌──────────┐         ┌──────────┐
    │ Task B   │         │ Wait for │
    │ (stolen) │         │ B result │
    └──────────┘         └──────────┘
           │                    │
           └────────────────────┘
                    │
              Both complete
```

1. **Fork**: Create a subtask that *may* run in parallel
2. **Execute**: Do local work while subtask runs
3. **Join**: Wait for subtask and combine results

```zig
// Fork-join example
const results = blitz.join(
    u64, u64,
    computeLeft, computeRight,
    leftData, rightData,
);
const total = results[0] + results[1];
```

## Grain Size

**Grain size** controls the minimum chunk size before parallelization:

```zig
// Default: automatic grain size
blitz.parallelFor(n, ctx_type, ctx, bodyFn);

// Custom grain size (1000 elements per chunk)
blitz.parallelForWithGrain(n, ctx_type, ctx, bodyFn, 1000);
```

### Choosing Grain Size

| Grain Size | Effect |
|------------|--------|
| Too small | Overhead dominates, slower than sequential |
| Too large | Poor load balancing, some cores idle |
| Just right | Amortizes overhead, good balance |

**Rule of thumb**: Start with defaults. Only tune if profiling shows issues.

## Sequential Threshold

Blitz automatically avoids parallelization for small data:

```zig
// Uses internal threshold heuristics
if (blitz.internal.shouldParallelize(.sum, data.len)) {
    // Parallel path
} else {
    // Sequential path (less overhead)
}
```

The threshold depends on:
- **Operation type**: Memory-bound ops need more data
- **Worker count**: More workers = higher threshold
- **Data size**: Must amortize fork/join overhead

## Context Pattern

Blitz uses a **context struct** to pass data to parallel bodies:

```zig
// Define what data the parallel body needs
const Context = struct {
    input: []const f64,
    output: []f64,
    scale: f64,
};

// Create context instance
const ctx = Context{
    .input = input_data,
    .output = output_data,
    .scale = 2.5,
};

// Pass to parallel operation
blitz.parallelFor(input_data.len, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) void {
        for (c.input[start..end], c.output[start..end]) |in, *out| {
            out.* = in * c.scale;
        }
    }
}.body);
```

### Why Context?

1. **No closures in Zig** - Can't capture variables
2. **Explicit data flow** - Clear what's shared
3. **Comptime optimization** - Struct access is fast

## SIMD Integration

Blitz combines multi-threading with SIMD for maximum throughput:

```
┌─────────────────────────────────────────────────────┐
│                    100M Elements                     │
├─────────────┬─────────────┬─────────────┬───────────┤
│  Worker 0   │  Worker 1   │  Worker 2   │ Worker 3  │
│  25M each   │  25M each   │  25M each   │ 25M each  │
├─────────────┼─────────────┼─────────────┼───────────┤
│ SIMD lanes  │ SIMD lanes  │ SIMD lanes  │SIMD lanes │
│ [8 floats]  │ [8 floats]  │ [8 floats]  │[8 floats] │
└─────────────┴─────────────┴─────────────┴───────────┘
```

```zig
// Parallel + SIMD sum (fastest)
const sum = blitz.simd_mod.parallelSum(i64, data);

// Compare throughput:
// - Scalar:        0.5 billion elements/sec
// - SIMD only:     2.0 billion elements/sec
// - Parallel+SIMD: 9.0 billion elements/sec
```

## Thread Pool Lifecycle

```zig
// 1. Initialize (spawns worker threads)
try blitz.init();

// 2. Use parallel operations (any number of times)
blitz.parallelFor(...);
blitz.parallelReduce(...);
const sum = blitz.iter(data).sum();

// 3. Cleanup (joins worker threads)
blitz.deinit();
```

**Important**:
- `init()` can be called multiple times (idempotent)
- Always pair with `deinit()` using `defer`
- Worker threads are reused across all operations
