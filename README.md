# Blitz: High-Performance Parallel Runtime

[![CI](https://github.com/NerdMeNot/blitz/actions/workflows/ci.yml/badge.svg)](https://github.com/NerdMeNot/blitz/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**A lock-free work-stealing parallel runtime for Zig, inspired by Rayon**

Blitz brings Rayon-style fork-join parallelism to Zig with competitive performance.
The entire hot path is lock-free, using Chase-Lev deques and futex-based synchronization.

## Requirements

- **Zig**: 0.15.0 or later
- **OS**: Linux, macOS, Windows
- **libc**: Required (links against libc for threading primitives)

## Installation

Add Blitz to your `build.zig.zon`:

```zig
.dependencies = .{
    .blitz = .{
        // Option 1: Release archive (recommended)
        .url = "https://github.com/NerdMeNot/blitz/archive/refs/tags/v1.0.0-zig0.15.2.tar.gz",
        .hash = "...", // Run `zig build` and it will tell you the hash
    },
},
```

Or use a git URL with tag:
```zig
.blitz = .{
    .url = "git+https://github.com/NerdMeNot/blitz.git#v1.0.0-zig0.15.2",
    .hash = "...",
},
```

Or use a specific branch/commit:
```zig
.blitz = .{
    .url = "git+https://github.com/NerdMeNot/blitz.git#main",  // branch
    // .url = "git+https://github.com/NerdMeNot/blitz.git#abc123",  // commit
    .hash = "...",
},
```

Then in your `build.zig`:

```zig
const blitz = b.dependency("blitz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("blitz", blitz.module("blitz"));
```

Or clone and use locally:

```bash
git clone https://github.com/NerdMeNot/blitz.git
cd blitz
make test  # Run tests
```

```
                          ╔═══════════════════════════════════════╗
                          ║         BLITZ WORK STEALING           ║
                          ╚═══════════════════════════════════════╝

    ┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
    │  Worker 0   │     │  Worker 1   │     │  Worker 2   │     │  Worker N   │
    │ ┌─────────┐ │     │ ┌─────────┐ │     │ ┌─────────┐ │     │ ┌─────────┐ │
    │ │  Deque  │ │     │ │  Deque  │ │     │ │  Deque  │ │     │ │  Deque  │ │
    │ │ ┌─────┐ │ │     │ │ ┌─────┐ │ │     │ │ ┌─────┐ │ │     │ │ ┌─────┐ │ │
    │ │ │ Job │◄┼─┼─────┼─┼─┤STEAL│ │ │     │ │ │     │ │ │     │ │ │     │ │ │
    │ │ ├─────┤ │ │     │ │ └─────┘ │ │     │ │ │     │ │ │     │ │ │     │ │ │
    │ │ │ Job │ │ │     │ │         │ │     │ │ │ Job │◄┼─┼─────┼─┼─┤STEAL│ │ │
    │ │ ├─────┤ │ │     │ │         │ │     │ │ └─────┘ │ │     │ │ └─────┘ │ │
    │ │ │ Job │ │ │     │ │         │ │     │ │         │ │     │ │         │ │
    │ │ └──▲──┘ │ │     │ │         │ │     │ │         │ │     │ │         │ │
    │ └────┼────┘ │     │ └─────────┘ │     │ └─────────┘ │     │ └─────────┘ │
    │   push/pop  │     │             │     │             │     │             │
    │   (owner)   │     │             │     │             │     │             │
    └─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
           │                   │                   │                   │
           └───────────────────┴───────────────────┴───────────────────┘
                                       │
                              ┌────────▼────────┐
                              │   Lock-Free!    │
                              │  • CAS stealing │
                              │  • Futex wake   │
                              │  • No mutexes   │
                              └─────────────────┘
```

## Key Features

- **Lock-Free Hot Path** - Chase-Lev deque with atomic CAS operations
- **Zero Heap Allocation** - Jobs embedded in stack-allocated Futures
- **Futex-Based Wake** - Lock-free worker wake using OS futex
- **Rayon-Compatible API** - `join()`, `parallelFor()`, `parallelReduce()`
- **Adaptive Splitting** - Automatically tunes parallelism to thread count
- **SIMD Integration** - Vectorized reductions for numeric types
- **Cache-Line Isolation** - Padding prevents false sharing between workers

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           BLITZ ARCHITECTURE                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                         USER CODE                                │    │
│  │  join() | parallelFor() | parallelReduce() | iter().sum()        │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      FORK-JOIN LAYER                             │    │
│  │  Future.fork() ──► Push to deque + Futex wake                    │    │
│  │  Future.join() ──► Pop or wait (active work-stealing)            │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                     LOCK-FREE PRIMITIVES                         │    │
│  │  Deque: Chase-Lev (push/pop/steal with CAS)                      │    │
│  │  Wake: Futex (lock-free sleep/wake)                              │    │
│  │  RNG: XorShift64* (Lemire's fast bounded)                        │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### How It Works

```
                        FORK-JOIN FLOW

    fork(taskB)                              join()
        │                                       │
        ▼                                       ▼
   ┌─────────┐                            ┌──────────┐
   │ Push to │───► Job visible ◄─── Steal │ Pop from │
   │  deque  │     to thieves             │  deque   │
   └────┬────┘                            └────┬─────┘
        │                                      │
        ▼                                      ▼
   ┌─────────┐                            ┌──────────┐
   │ Wake if │                            │ Execute  │
   │  idle   │ (futex - lock-free)        │  taskA   │
   └─────────┘                            └──────────┘
```

1. **Chase-Lev Deque** (Lock-Free)
   - Owner pushes jobs to bottom, pops from bottom (LIFO - cache hot)
   - Thieves steal from top (FIFO - load balancing)
   - CAS operations ensure mutual exclusion without locks

2. **Futex-Based Wake** (Lock-Free)
   - Idle workers sleep on a futex (no mutex!)
   - `fork()` wakes workers atomically: `fetchAdd + futex_wake`
   - ~5-10ns overhead vs ~100-300ns for mutex

3. **Active Work-Stealing in `join()`**
   - While waiting for stolen job, worker steals and executes other work
   - Keeps all CPUs busy, maximizes throughput
   - Same strategy that makes Rayon so effective

### Why This Design?

| Feature | Blitz | Rayon | Traditional |
|---------|-------|-------|-------------|
| Deque push/pop | Lock-free CAS | Lock-free CAS | Mutex |
| Worker wake | **Lock-free futex** | Condvar + mutex | Condvar + mutex |
| Work-stealing | Lock-free CAS | Lock-free CAS | Mutex |
| Cache-line isolation | **Yes** | Yes | Often no |

## Project Structure

```
blitz/
├── api.zig              # High-level API (join, parallelFor, parallelReduce)
├── mod.zig              # Library entry point
├── pool.zig             # ThreadPool with lock-free futex wake
├── worker.zig           # Worker and Task types
├── deque.zig            # Chase-Lev lock-free work-stealing deque
├── future.zig           # Future(Input, Output) for fork-join
├── job.zig              # Minimal Job struct (8 bytes)
├── latch.zig            # Synchronization primitives (OnceLatch, SpinWait)
├── scope.zig            # Scope-based parallelism (join2, join3, joinN)
├── algorithms.zig       # Parallel algorithms (sort, scan, find)
├── sync.zig             # SyncPtr for lock-free parallel writes
│
├── iter/                # Parallel iterators (Rayon-style)
│   ├── mod.zig          # Iterator entry point
│   ├── find.zig         # findAny, findFirst, findLast, position
│   ├── predicates.zig   # any, all with early termination
│   ├── minmax.zig       # minBy, maxBy, minByKey, maxByKey
│   ├── chunks.zig       # Chunk iterators
│   ├── enumerate.zig    # Enumerated iteration
│   └── ...
│
├── simd/                # SIMD-accelerated operations
│   ├── mod.zig          # SIMD entry point
│   ├── aggregations.zig # sum, min, max (vectorized)
│   ├── argminmax.zig    # argmin, argmax with index
│   ├── search.zig       # findValue, anyGreaterThan, allLessThan
│   └── parallel.zig     # Multi-threaded + SIMD combined
│
├── sort/                # Parallel PDQSort
│   ├── mod.zig          # Sort entry point
│   ├── pdqsort.zig      # Pattern-defeating quicksort
│   ├── by_key.zig       # sortByKey, sortByCachedKey
│   └── helpers.zig      # Insertion sort, heapsort, pivot
│
├── internal/            # Internal utilities
│   ├── mod.zig          # Internal entry point
│   ├── threshold.zig    # Parallelism threshold heuristics
│   ├── splitter.zig     # Adaptive work splitting
│   └── rng.zig          # XorShift64* RNG
│
├── examples/            # Runnable examples
│   ├── examples.zig     # Core API examples
│   ├── iterators.zig    # Iterator examples
│   ├── simd.zig         # SIMD examples
│   └── sorting.zig      # Sorting examples
│
├── benchmarks/          # Performance benchmarks
│   ├── rayon_compare.zig
│   └── rayon/           # Rust Rayon for comparison
│
└── docs/                # Documentation
    ├── 01-getting-started/
    ├── 02-usage/
    ├── 03-api/
    ├── 04-algorithms/
    ├── 05-testing/
    └── 06-internals/
```

## API Reference

### Initialization

```zig
const blitz = @import("blitz");

// Initialize with defaults (auto-detect thread count)
try blitz.init();
defer blitz.deinit();

// Or with custom configuration
try blitz.initWithConfig(.{
    .background_worker_count = 8,
});

// Check status
const workers = blitz.numWorkers();
const initialized = blitz.isInitialized();
```

### Fork-Join (join)

Execute two tasks potentially in parallel:

```zig
const results = blitz.join(
    u64,  // Return type A
    u64,  // Return type B
    computeA,  // fn(ArgA) -> u64
    computeB,  // fn(ArgB) -> u64
    arg_a,
    arg_b,
);
// results[0] = computeA(arg_a)
// results[1] = computeB(arg_b)
```

For void functions:
```zig
blitz.joinVoid(doWorkA, doWorkB, arg_a, arg_b);
```

For error-safe execution (task B always completes even if task A fails):
```zig
const results = try blitz.tryJoin(
    u64,       // Return type A
    u64,       // Return type B
    MyError,   // Error type
    computeA,  // fn(ArgA) -> MyError!u64
    computeB,  // fn(ArgB) -> MyError!u64
    arg_a,
    arg_b,
);
```

### Parallel For (parallelFor)

Execute a function over range [0, n):

```zig
const Context = struct { data: []f64 };
const ctx = Context{ .data = my_data };

blitz.parallelFor(my_data.len, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) void {
        for (c.data[start..end]) |*v| {
            v.* = processValue(v.*);
        }
    }
}.body);
```

With custom grain size:
```zig
blitz.parallelForWithGrain(n, Context, ctx, body_fn, grain_size);
```

### Parallel Reduce (parallelReduce)

Map-reduce with associative combine:

```zig
const sum = blitz.parallelReduce(
    f64,           // Result type
    data.len,      // Count
    0.0,           // Identity
    []const f64,   // Context type
    data,          // Context
    struct {
        fn map(d: []const f64, i: usize) f64 {
            return d[i];
        }
    }.map,
    struct {
        fn combine(a: f64, b: f64) f64 {
            return a + b;
        }
    }.combine,
);
```

### Convenience Functions

```zig
// Aggregations (SIMD + multi-threaded)
const sum = blitz.parallelSum(f64, data);
const min_val = blitz.parallelMin(f64, data);  // Returns ?f64
const max_val = blitz.parallelMax(f64, data);  // Returns ?f64

// Works with any numeric type
const sum_i = blitz.parallelSum(i64, int_data);
const min_i = blitz.parallelMin(i64, int_data);
const max_i = blitz.parallelMax(i64, int_data);

// In-place transformations
blitz.parallelMap(f64, data, struct {
    fn transform(x: f64) f64 { return x * 2; }
}.transform);

blitz.parallelFill(f64, data, 0.0);

// Predicates with early exit
const has_negative = blitz.parallelAny(f64, data, struct {
    fn pred(x: f64) bool { return x < 0; }
}.pred);

const all_positive = blitz.parallelAll(f64, data, struct {
    fn pred(x: f64) bool { return x > 0; }
}.pred);

// Find with early exit
const found = blitz.parallelFindAny(f64, data, struct {
    fn pred(x: f64) bool { return x > 100; }
}.pred);

// For-each
blitz.parallelForEach(f64, data, struct {
    fn process(x: f64) void { _ = x; /* process */ }
}.process);
```

### Threshold System

Blitz includes heuristics to avoid parallelization overhead for small data:

```zig
const OpType = blitz.OpType;

// Check if parallelization is beneficial
if (blitz.shouldParallelize(OpType.sum, data.len)) {
    // Use parallel version
} else {
    // Use sequential version
}

// Memory-bound operations have higher thresholds
const is_mem_bound = blitz.isMemoryBound(OpType.add);
```

## Performance

Blitz achieves performance competitive with Rayon, the gold standard for parallel runtimes.
See [BENCHMARKS.md](BENCHMARKS.md) for full methodology and results.

### Blitz vs Rayon (10 workers, Apple Silicon)

| Benchmark | Blitz | Rayon | Result |
|-----------|-------|-------|--------|
| Fork-join (depth 20, 2M forks) | 0.54 ns/fork | 0.66 ns/fork | **Blitz 22% faster** |
| Parallel fib(45) | 411 ms | 414 ms | Equal |
| Parallel sum 1M | 0.11 ms | 0.13 ms | **Blitz 18% faster** |
| Parallel sum 100M | 11.7 ms | 10.7 ms | Rayon 9% faster |
| Parallel sort 10M | 134 ms | 145 ms | **Blitz 8% faster** |

### When to Use Blitz

**Ideal for:**
- Compute-bound work (transforms, math)
- Recursive divide-and-conquer (fib, sort)
- Large datasets (>100K elements)
- Fine-grained parallelism

**Less ideal for:**
- Memory-bound operations (simple copy)
- Very small datasets (<10K elements)
- I/O-bound work

## Low-Level API

For advanced use cases, you can use the low-level primitives directly:

### Future

```zig
const Future = blitz.Future;

var future = Future(i32, i64).init();
future.fork(&task, compute, input);

// ... do other work ...

const result = future.join(&task) orelse compute(&task, input);
```

### Worker and Task

```zig
const pool = blitz.getPool();

_ = pool.call(ResultType, struct {
    fn compute(task: *Task, arg: ArgType) ResultType {
        // task.tick() - check heartbeat
        // task.call(T, fn, arg) - recursive call with tick
        // Future.fork/join - parallel subtasks
    }
}.compute, arg);
```

## Parallel Iterators (Rayon-style)

Blitz provides composable parallel iterators similar to Rayon:

```zig
const blitz = @import("blitz");

// Parallel sum
const sum = blitz.iter(i64, data).sum();

// Parallel min/max
const min = blitz.iter(i64, data).min();
const max = blitz.iter(i64, data).max();

// Map and collect
var result = try blitz.iter(i64, data)
    .map(square)
    .collect(allocator);
defer allocator.free(result);

// In-place mutation
blitz.iterMut(i64, data).mapInPlace(double);
blitz.iterMut(i64, data).fill(42);

// Range iteration
blitz.range(0, 1000).forEach(processIndex);
const total = blitz.range(0, 100).sum(i64, valueAtIndex);
```

## Scope-Based Parallelism

Execute multiple tasks in parallel:

```zig
// Execute 2 tasks in parallel (different return types OK)
const results = blitz.join2(i32, i64, fnA, fnB);
// results[0]: i32, results[1]: i64

// Execute 3 tasks in parallel (different return types OK)
const results = blitz.join3(i32, i64, f64, fnA, fnB, fnC);

// Execute N tasks in parallel (same return type required)
const funcs = [_]fn() i64{ fn1, fn2, fn3, fn4 };
const results = blitz.joinN(i64, 4, &funcs);  // Returns [4]i64

// Spawn up to 64 tasks with scope
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        s.spawn(task1);
        s.spawn(task2);
        s.spawn(task3);
    }
}.run);  // All tasks execute in parallel when scope exits

// Parallel for over index range
blitz.parallelForRange(0, 1000, processIndex);
blitz.parallelForRangeWithContext(MyCtx, ctx, 0, 1000, processWithContext);
```

## Parallel Algorithms

```zig
// Parallel merge sort
try blitz.parallelSort(i64, data, allocator);

// With custom comparator
try blitz.parallelSortBy(i64, data, allocator, myLessThan);

// Parallel prefix sum (scan)
blitz.parallelScan(i64, input, output);           // inclusive
blitz.parallelScanExclusive(i64, input, output);  // exclusive

// Parallel find
if (blitz.parallelFind(i64, data, isTarget)) |index| {
    // Found at index
}

// Parallel partition
const pivot = blitz.parallelPartition(i64, data, lessThanFive);
```

## Lock-Free Parallel Writes

For parallel materialization patterns (like Polars):

```zig
// SyncPtr for parallel writes to disjoint regions
var buffer: [1000]u64 = undefined;
const ptr = blitz.SyncPtr(u64).init(&buffer);

// Each thread writes to its region
blitz.parallelFor(num_chunks, Context, ctx, struct {
    fn body(c: Context, chunk_start: usize, chunk_end: usize) void {
        for (c.values[chunk_start..chunk_end], 0..) |val, i| {
            ptr.writeAt(c.offsets[chunk_start] + i, val);
        }
    }
}.body);

// Parallel flatten nested slices
blitz.parallelFlatten(u64, slices, output);

// Parallel scatter
blitz.parallelScatter(u64, values, indices, output);
```

## Comparison with Rayon

Rayon has been the gold standard for parallel runtimes since 2015. Blitz aims to bring
similar capabilities to Zig while learning from Rayon's excellent design.

| Feature | Blitz | Rayon |
|---------|-------|-------|
| Language | Zig | Rust |
| Work stealing | Chase-Lev deque | Chase-Lev deque |
| Worker wake | **Lock-free futex** | Condvar + mutex |
| Fork-join overhead | ~0.5 ns/fork | ~0.7 ns/fork |
| Parallel iterators | Yes | Yes |
| Parallel sort | Yes | Yes |
| Parallel scan | Yes | Yes |
| Comptime specialization | **Yes** | Via monomorphization |

### Key Differences

1. **Lock-free wake**: Blitz uses futex directly, avoiding mutex overhead
2. **Comptime dispatch**: Zig's comptime eliminates virtual dispatch overhead
3. **Cache-line isolation**: Explicit padding prevents false sharing

## Implementation Notes

### Thread-Local Task Context

To avoid pool.call() overhead on recursive joins, Blitz maintains a thread-local
`current_task` pointer. When already inside a pool context, subsequent join()
calls use the fast path directly.

### Active Work-Stealing in Join

When waiting for a stolen job to complete, the worker doesn't just spin - it
actively steals and executes other work. This keeps all CPUs busy and is what
makes both Blitz and Rayon achieve near-linear scaling on compute-bound work.

## Building and Testing

```bash
# Run all tests
make test

# Run tests with verbose output (shows all test names)
make test-verbose

# Build the library
make build

# Run benchmarks
make bench

# Compare against Rust's Rayon
make bench-rayon

# Build and run examples
make examples
make example-sum
make example-sort
make example-fork-join

# Code quality
make fmt          # Format code
make check        # Format check + tests
make test-coverage  # Module-level coverage analysis

# See all available commands
make help
```

### Comparing with Rayon

Both benchmark suites measure the same operations:
- Join overhead
- Parallel sum
- Parallel map
- Parallel reduce (find max)
- Parallel for (write indices)
- Parallel sort
- Parallel iterators

This allows direct comparison of Blitz vs Rayon performance.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
