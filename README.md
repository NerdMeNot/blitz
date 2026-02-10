<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/logo-light.png">
    <img alt="blitz" src="assets/logo-light.png" height="80">
  </picture>
</p>

<p align="center">
  <strong>Rayon-style parallelism for Zig. Simple API, serious performance.</strong>
</p>

<p align="center">
  <a href="https://github.com/NerdMeNot/blitz/actions/workflows/ci.yml"><img src="https://github.com/NerdMeNot/blitz/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License"></a>
</p>

Blitz brings the ergonomics of Rust's Rayon library to Zig, with a focus on:
- **Zero-allocation fork-join**: Stack-allocated futures, no heap overhead
- **Lock-free work stealing**: Chase-Lev deques with Rayon-style JEC protocol
- **Composable iterators**: Chain, zip, flatten with automatic parallelism
- **Parallel PDQSort**: Adaptive pattern-defeating quicksort across cores

```zig
const blitz = @import("blitz");

// Sum 10 million numbers in parallel - one line
const sum = blitz.iter(i64, data).sum();
```

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
  - [Parallel Iterators](#parallel-iterators)
  - [Fork-Join](#fork-join)
  - [Parallel Algorithms](#parallel-algorithms)
- [Performance](#performance)
- [Architecture](#architecture)
- [Best Practices](#best-practices)
- [Limitations](#limitations)
- [Documentation](#documentation)

## Installation

### Requirements

- Zig 0.15.0 or later
- Linux, macOS, or Windows

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",

    .dependencies = .{
        .blitz = .{
            .url = "https://github.com/NerdMeNot/blitz/archive/refs/tags/v1.0.0-zig0.15.2.tar.gz",
            .hash = "blitz-1.0.0-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            // Run `zig build` to get the correct hash
        },
    },

    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

Add to your `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get blitz dependency
    const blitz_dep = b.dependency("blitz", .{
        .target = target,
        .optimize = optimize,
    });

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add blitz module
    exe.root_module.addImport("blitz", blitz_dep.module("blitz"));

    b.installArtifact(exe);
}
```

### Building from Source

```bash
git clone https://github.com/NerdMeNot/blitz.git
cd blitz
zig build        # Build library
zig build test   # Run tests
zig build bench  # Run benchmarks
```

## Quick Start

```zig
const blitz = @import("blitz");

pub fn main() !void {
    var numbers = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    // ============================================
    // PARALLEL AGGREGATIONS
    // ============================================

    // Sum all elements
    const sum = blitz.iter(i64, &numbers).sum();

    // Find min/max
    const min = blitz.iter(i64, &numbers).min();  // -> ?i64
    const max = blitz.iter(i64, &numbers).max();  // -> ?i64

    // Custom reduction
    const product = blitz.iter(i64, &numbers).reduce(1, multiply);

    // ============================================
    // PARALLEL SEARCH (with early exit)
    // ============================================

    // Find any element matching predicate (fastest, non-deterministic order)
    const found = blitz.iter(i64, &numbers).findAny(isEven);

    // Find first/last match (deterministic, scans all chunks)
    const first = blitz.iter(i64, &numbers).findFirst(isEven);
    const last = blitz.iter(i64, &numbers).findLast(isEven);

    // Get index of match
    const idx = blitz.iter(i64, &numbers).position(isEven);

    // ============================================
    // PARALLEL PREDICATES (with early exit)
    // ============================================

    const has_negative = blitz.iter(i64, &numbers).any(isNegative);
    const all_positive = blitz.iter(i64, &numbers).all(isPositive);

    // ============================================
    // PARALLEL TRANSFORMS (in-place mutation)
    // ============================================

    // Double every element
    blitz.iterMut(i64, &numbers).mapInPlace(double);

    // Fill with a value
    blitz.iterMut(i64, &numbers).fill(0);

    // Execute side effect for each
    blitz.iterMut(i64, &numbers).forEach(printValue);

    // ============================================
    // PARALLEL SORT
    // ============================================

    // Sort ascending (in-place, no allocation needed)
    blitz.sortAsc(i64, &numbers);

    // With custom comparator
    blitz.sort(i64, &numbers, descending);
}

fn multiply(a: i64, b: i64) i64 { return a * b; }
fn isEven(x: i64) bool { return @mod(x, 2) == 0; }
fn isNegative(x: i64) bool { return x < 0; }
fn isPositive(x: i64) bool { return x > 0; }
fn double(x: i64) i64 { return x * 2; }
fn printValue(x: *i64) void { std.debug.print("{} ", .{x.*}); }
fn descending(a: i64, b: i64) bool { return a > b; }
```

## API Reference

### Parallel Iterators

The iterator API is the recommended way to use Blitz. It provides composable, chainable operations that automatically parallelize.

#### Creating Iterators

```zig
// From slice (immutable - for reading)
const it = blitz.iter(T, slice);

// From slice (mutable - for writing)
const it = blitz.iterMut(T, slice);

// From index range
const it = blitz.range(start, end);
```

#### Aggregations

| Method | Return Type | Description |
|--------|-------------|-------------|
| `.sum()` | `T` | Sum of all elements |
| `.min()` | `?T` | Minimum element (null if empty) |
| `.max()` | `?T` | Maximum element (null if empty) |
| `.reduce(identity, fn)` | `T` | Custom reduction with binary function |
| `.count()` | `usize` | Number of elements |

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };

const sum = blitz.iter(i64, &data).sum();           // 15
const min = blitz.iter(i64, &data).min();           // 1
const max = blitz.iter(i64, &data).max();           // 5
const prod = blitz.iter(i64, &data).reduce(1, mul); // 120
```

#### Search Operations

All search operations support **early exit** - they stop as soon as a match is found.

| Method | Return Type | Description |
|--------|-------------|-------------|
| `.findAny(pred)` | `?T` | Any matching element (fastest) |
| `.findFirst(pred)` | `?FindResult(T)` | Leftmost match with index |
| `.findLast(pred)` | `?FindResult(T)` | Rightmost match with index |
| `.position(pred)` | `?usize` | Index of first match |
| `.positionAny(pred)` | `?usize` | Index of any match (fastest) |
| `.rposition(pred)` | `?usize` | Index of last match |

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

// Find any even number (non-deterministic, but fast)
const any_even = blitz.iter(i64, &data).findAny(isEven);  // Some even number

// Find first even number (deterministic)
if (blitz.iter(i64, &data).findFirst(isEven)) |result| {
    std.debug.print("First even: {} at index {}\n", .{ result.value, result.index });
}

// Find index
const idx = blitz.iter(i64, &data).position(isEven);  // 1 (index of 2)
```

#### Predicates

| Method | Return Type | Description |
|--------|-------------|-------------|
| `.any(pred)` | `bool` | True if any element matches |
| `.all(pred)` | `bool` | True if all elements match |

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };

const has_even = blitz.iter(i64, &data).any(isEven);     // true
const all_positive = blitz.iter(i64, &data).all(isPos); // true
```

#### Min/Max by Key or Comparator

```zig
const Point = struct { x: i32, y: i32 };
const points = [_]Point{ .{ .x = 1, .y = 5 }, .{ .x = 3, .y = 2 }, .{ .x = 2, .y = 8 } };

// Min/max by custom comparator
const closest = blitz.iter(Point, &points).minBy(compareByDistance);

// Min/max by key extraction
const leftmost = blitz.iter(Point, &points).minByKey(i32, getX);   // Point with smallest x
const highest = blitz.iter(Point, &points).maxByKey(i32, getY);    // Point with largest y

fn getX(p: Point) i32 { return p.x; }
fn getY(p: Point) i32 { return p.y; }
```

#### Mutation Operations

These require `iterMut` (mutable iterator).

| Method | Description |
|--------|-------------|
| `.mapInPlace(fn)` | Transform each element in place |
| `.fill(value)` | Set all elements to a value |
| `.forEach(fn)` | Execute function for each element |

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };

// Double all elements
blitz.iterMut(i64, &data).mapInPlace(double);  // [2, 4, 6, 8, 10]

// Reset to zero
blitz.iterMut(i64, &data).fill(0);  // [0, 0, 0, 0, 0]
```

#### Iterator Combinators

```zig
const a = [_]i64{ 1, 2, 3 };
const b = [_]i64{ 4, 5, 6 };

// Chain: concatenate two iterators
const sum = blitz.iter(i64, &a).chain(blitz.iter(i64, &b)).sum();  // 21

// Zip: pair elements from two iterators
const pairs = blitz.iter(i64, &a).zip(blitz.iter(i64, &b));
// Iterates over: (1,4), (2,5), (3,6)

// Chunks: process in fixed-size chunks
blitz.iter(i64, &data).chunks(100).forEach(processChunk);

// Enumerate: with indices
blitz.iter(i64, &data).enumerate().forEach(processWithIndex);

// Flatten: flatten nested slices into output
const nested = [_][]const i64{ &a, &b };
var out: [6]i64 = undefined;
blitz.parallelFlatten([]const i64, &nested, &out);
```

### Fork-Join

For divide-and-conquer algorithms and heterogeneous parallel tasks.

#### `blitz.join()` - Parallel Task Execution

Execute multiple tasks in parallel with potentially different return types. Similar to JavaScript's `Promise.all()` but with named results.

```zig
// Simple: function pointers (no arguments)
const result = blitz.join(.{
    .user = fetchUser,
    .posts = fetchPosts,
    .comments = fetchComments,
});
// Access: result.user, result.posts, result.comments

// With arguments: tuple of (function, argument)
const result = blitz.join(.{
    .user = .{ fetchUserById, user_id },
    .posts = .{ fetchPostsByUser, user_id },
    .config = .{ loadConfig, "app.json" },
});
```

#### Recursive Fork-Join (Divide and Conquer)

```zig
fn parallelFib(n: u64) u64 {
    // Base case: below threshold, compute sequentially
    if (n < 20) return fibSequential(n);

    // Recursive case: fork two subtasks
    const r = blitz.join(.{
        .a = .{ parallelFib, n - 1 },
        .b = .{ parallelFib, n - 2 },
    });
    return r.a + r.b;
}

fn parallelMergeSort(comptime T: type, data: []T, allocator: Allocator) void {
    if (data.len <= 1024) {
        std.mem.sort(T, data, {}, std.sort.asc(T));
        return;
    }

    const mid = data.len / 2;

    // Sort both halves in parallel
    _ = blitz.join(.{
        .left = .{ parallelMergeSort, T, data[0..mid], allocator },
        .right = .{ parallelMergeSort, T, data[mid..], allocator },
    });

    merge(data, mid, allocator);
}
```

#### `blitz.scope()` - Dynamic Task Spawning

For when the number of tasks is determined at runtime:

```zig
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        // Spawn tasks dynamically (up to 64)
        for (work_items) |item| {
            s.spawn(.{ processItem, item });
        }
    }
}.run);
// All spawned tasks complete before scope returns
```

#### Error-Safe Join

```zig
// Task B always completes even if A fails
const result = try blitz.tryJoin(
    ResultA, ResultB, MyError,
    taskA, taskB,
    argA, argB,
);
```

### Parallel Algorithms

#### Sorting

```zig
// Sort ascending (in-place, no allocation needed)
blitz.sortAsc(i64, data);

// Sort descending
blitz.sortDesc(i64, data);

// Custom comparator
blitz.sort(i64, data, struct {
    fn lessThan(a: i64, b: i64) bool {
        return a > b;  // Descending
    }
}.lessThan);

// Sort by key
blitz.sortByKey(Person, u32, people, struct {
    fn key(p: Person) u32 { return p.age; }
}.key);
```

**Algorithm**: Parallel Pattern-Defeating Quicksort (PDQSort)
- Adaptive: O(n) for sorted/reverse-sorted data
- Cache-friendly: good locality of reference
- Parallel: work-stealing across cores

#### Find and Partition

```zig
// Find index of first element matching predicate
const idx = blitz.parallelFind(i64, data, isTarget);

// Find index of specific value
const idx = blitz.parallelFindValue(i64, data, 42);

// Partition: move elements matching predicate to front
const pivot = blitz.parallelPartition(i64, data, isNegative);
// data[0..pivot] are negative, data[pivot..] are non-negative
```

### Configuration

#### Initialization

Blitz requires explicit initialization before use:

```zig
// Auto-detect thread count (uses CPU count - 1)
try blitz.init();
defer blitz.deinit();

// Or specify custom thread count
try blitz.initWithConfig(.{
    .background_worker_count = 8,  // Use 8 worker threads
});
defer blitz.deinit();
```

#### Grain Size Control

The grain size controls the minimum work unit size. Smaller values = more parallelism but more overhead.

```zig
// Set globally
blitz.setGrainSize(1024);

// Query current value
const grain = blitz.getGrainSize();

// Per-operation grain size
blitz.parallelForWithGrain(n, ctx, body, 512);
```

**Guidelines**:
- Default (65536) works well for most cases
- Reduce for expensive operations (100-1000)
- Increase for trivial operations (10000+)

## Performance

Benchmarks on 10-core Apple M1 Pro, comparing Blitz to Rust's Rayon:

### Fork-Join Overhead

| Depth | Blitz (ns/fork) | Rayon (ns/fork) | Speedup |
|-------|-----------------|-----------------|---------|
| 10 (1K forks) | 10.54 | 14.73 | **1.40x** |
| 15 (32K forks) | 1.29 | 1.71 | **1.33x** |
| 20 (1M forks) | 0.54 | 0.71 | **1.31x** |

### Parallel Fibonacci

| Workload | Blitz | Rayon | Speedup |
|----------|-------|-------|---------|
| fib(35) | 3.31 ms | 4.92 ms | **1.49x** |
| fib(40) | 35.06 ms | 52.85 ms | **1.51x** |

### Aggregations

| Operation | Blitz | Rayon | Speedup |
|-----------|-------|-------|---------|
| Sum 10M | 0.88 ms | 1.40 ms | **1.59x** |
| Find (early) | 11.1 μs | 18.3 μs | **1.65x** |
| Any (early) | 10.1 μs | 15.7 μs | **1.56x** |

### Sorting

| Data Pattern | Blitz | Rayon | Speedup |
|--------------|-------|-------|---------|
| Random 1M | 4.05 ms | 3.46 ms | 0.85x |
| Sorted 1M | 0.27 ms | 0.43 ms | **1.59x** |
| Reverse 1M | 0.41 ms | 0.56 ms | **1.37x** |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         YOUR CODE                                │
│  iter(data).sum() | join(.{...}) | sortAsc() | range()             │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│                      HIGH-LEVEL API (api.zig)                    │
│  • Automatic grain size calculation                              │
│  • Sequential/parallel threshold decisions                       │
│  • Iterator combinators and transformations                      │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│                      FORK-JOIN LAYER (future.zig)                │
│  • Stack-allocated futures (zero heap allocation)                │
│  • Hybrid join: latch-first for stolen, pop-first for local      │
│  • Active work-stealing while waiting                            │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│                      SCHEDULER (pool.zig)                        │
│  • Rayon-style JEC (Jobs Event Counter) protocol                 │
│  • AtomicCounters: packed u64 sleeping/inactive/JEC              │
│  • Progressive sleep: 32 yields → announce sleepy → sleep        │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│                      LOCK-FREE PRIMITIVES                        │
│  • Chase-Lev deque: wait-free push/pop, lock-free steal          │
│  • 4-state CoreLatch: prevents missed wakes during sleep         │
│  • Cache-line aligned to prevent false sharing                   │
└─────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Rayon-style JEC protocol**: Workers track sleep state via Jobs Event Counter. Prevents missed wakes without hot-path overhead.

2. **Stack-allocated futures**: Jobs are embedded in the caller's stack frame. Zero heap allocation for fork-join operations.

3. **Active work-stealing in join**: While waiting for a stolen job, the owner actively steals and executes other work. No idle cores.

4. **Hybrid join strategy**: Quick latch check (for fast stolen completions) + pop-first (for local jobs). Optimized for both shallow and deep recursion.

5. **Comptime specialization**: All generics resolved at compile time. No virtual dispatch, full inlining possible.

## Best Practices

### Do

```zig
// DO: Use iterators for data-parallel operations
const sum = blitz.iter(i64, data).sum();

// DO: Use join for heterogeneous tasks
const result = blitz.join(.{
    .data = .{ fetchData, url },
    .config = loadConfig,
});

// DO: Set a sequential threshold for recursive algorithms
fn recurse(data: []i64) i64 {
    if (data.len < 1000) return sequentialCompute(data);
    // ... parallel recursion
}

// DO: Use findAny when order doesn't matter (faster)
const found = blitz.iter(i64, data).findAny(predicate);
```

### Don't

```zig
// DON'T: Parallelize tiny workloads (overhead > benefit)
const sum = blitz.iter(i64, tiny_array_of_10).sum();  // Use sequential

// DON'T: Use shared mutable state without synchronization
var counter: i64 = 0;
blitz.iterMut(i64, data).forEach(|_| { counter += 1; });  // RACE CONDITION!

// DON'T: Allocate heavily inside parallel loops
blitz.iter(T, data).forEach(|item| {
    var list = ArrayList.init(allocator);  // BAD: allocation contention
});

// DON'T: Recurse without a base case threshold
fn badFib(n: u64) u64 {
    if (n < 2) return n;
    const r = blitz.join(.{ .a = .{ badFib, n-1 }, .b = .{ badFib, n-2 } });
    return r.a + r.b;  // BAD: too many tiny tasks
}
```

### Tuning Tips

1. **Profile first**: Use `zig build bench` to measure actual performance
2. **Adjust grain size**: Decrease for expensive ops, increase for cheap ops
3. **Check data size**: Below ~10K elements, sequential may be faster
4. **Minimize allocations**: Pre-allocate buffers, reuse memory
5. **Avoid false sharing**: Don't have threads write to adjacent memory

## Limitations

### Current Limitations

1. **No async/await integration**: Blitz is for CPU-bound parallelism, not I/O-bound concurrency.

2. **No nested pool support**: One global thread pool. Don't create multiple pools.

3. **Fixed thread count**: Worker count is set at initialization and cannot be changed.

4. **No priority scheduling**: All tasks have equal priority. No way to prioritize certain work.

5. **Limited error propagation**: Errors in parallel tasks may be lost. Use `tryJoin` for error-safe operations.

### Platform-Specific Notes

- **Linux**: Full support, uses futex for efficient wake
- **macOS**: Full support, uses ulock (futex equivalent)
- **Windows**: Full support, uses WaitOnAddress

### Memory Considerations

- Each worker has a 256-slot deque (~2KB per worker)
- Stack-allocated futures: ~32-64 bytes each on the stack
- No heap allocation for standard fork-join operations

## Documentation

Full documentation is available at [blitz.nerdmenot.in](https://blitz.nerdmenot.in) (built from the `docs/` directory using Astro/Starlight).

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache 2.0. See [LICENSE](LICENSE).

## Acknowledgments

- [Rayon](https://github.com/rayon-rs/rayon) - Inspiration for the API design and work-stealing approach
- [Chase-Lev](https://www.dre.vanderbilt.edu/~schmidt/PDF/work-stealing-dequeue.pdf) - Work-stealing deque algorithm
- [PDQSort](https://github.com/orlp/pdqsort) - Pattern-defeating quicksort algorithm
