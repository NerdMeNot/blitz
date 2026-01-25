# Blitz Documentation

Comprehensive documentation for the Blitz parallel runtime - a high-performance, lock-free work-stealing scheduler for Zig.

## Quick Start

```zig
const blitz = @import("blitz");

// Parallel sum - one line, auto-parallelized
const sum = blitz.iter(i64, data).sum();

// Parallel min/max
const min = blitz.iter(i64, data).min();

// Parallel search with early exit
const found = blitz.iter(i64, data).findAny(isTarget);

// Parallel transform in-place
blitz.iterMut(i64, data).mapInPlace(double);

// Fork-join for divide-and-conquer
const result = blitz.join(.{
    .left = .{ computeLeft, left_data },
    .right = .{ computeRight, right_data },
});
```

## Performance

Blitz achieves **1.3-5x speedup** over Rust's Rayon on equivalent benchmarks:

| Operation | Blitz | Rayon | Speedup |
|-----------|-------|-------|---------|
| Fork-Join (depth 20) | 0.54 ms | 0.71 ms | 1.31x |
| Parallel Sum (100M) | 3.1 ms | 8.2 ms | 2.6x |
| Parallel Sort (10M) | 89 ms | 119 ms | 1.34x |

## Documentation Structure

### 1. Getting Started

| Document | Description |
|----------|-------------|
| [Installation](01-getting-started/01-installation.md) | Add Blitz to your project |
| [Quick Start](01-getting-started/02-quick-start.md) | Get running in 5 minutes |
| [Basic Concepts](01-getting-started/03-basic-concepts.md) | Work stealing, fork-join, grain size |

### 2. Usage Guides

| Document | Description |
|----------|-------------|
| [Iterators](02-usage/05-iterators.md) | **Recommended API** - Rayon-style composable iterators |
| [Fork-Join](02-usage/04-fork-join.md) | Divide and conquer parallelism |
| [Sorting](02-usage/06-sorting.md) | Parallel PDQSort |
| [Initialization](02-usage/01-initialization.md) | Thread pool configuration |
| [Parallel For](02-usage/02-parallel-for.md) | Low-level parallel loops |
| [Parallel Reduce](02-usage/03-parallel-reduce.md) | Low-level map-reduce |

### 3. API Reference

| Document | Description |
|----------|-------------|
| [Core API](03-api/01-core-api.md) | Complete function reference |
| [Iterators API](03-api/02-iterators-api.md) | Iterator method reference |
| [Sort API](03-api/04-sort-api.md) | Sorting function reference |

### 4. Algorithms (Internals)

| Document | Description |
|----------|-------------|
| [Work Stealing](04-algorithms/01-work-stealing.md) | Chase-Lev deque algorithm |
| [Chase-Lev Deque](04-algorithms/02-chase-lev-deque.md) | Lock-free deque implementation |
| [PDQSort](04-algorithms/03-pdqsort.md) | Pattern-defeating quicksort |
| [Parallel Reduction](04-algorithms/05-parallel-reduction.md) | Tree reduction strategy |
| [Adaptive Splitting](04-algorithms/06-adaptive-splitting.md) | Dynamic grain size |

### 5. Testing & Benchmarking

| Document | Description |
|----------|-------------|
| [Running Tests](05-testing/01-running-tests.md) | Test suite guide |
| [Benchmarking](05-testing/02-benchmarking.md) | Performance measurement |
| [Comparing with Rayon](05-testing/03-comparing-with-rayon.md) | Cross-language benchmarks |

### 6. Internals

| Document | Description |
|----------|-------------|
| [Architecture](06-internals/01-architecture.md) | System design overview |
| [Thread Pool](06-internals/02-thread-pool.md) | Pool implementation |
| [Futures and Jobs](06-internals/03-futures-and-jobs.md) | Fork-join mechanics |
| [Synchronization](06-internals/04-synchronization.md) | Latches and atomics |

## API at a Glance

### Iterator Operations

| Operation | Code | Notes |
|-----------|------|-------|
| Sum | `blitz.iter(T, data).sum()` | Parallel reduction |
| Min/Max | `.min()` / `.max()` | Returns `?T` |
| Find Any | `.findAny(pred)` | Non-deterministic, fast |
| Find First | `.findFirst(pred)` | Deterministic order |
| Any/All | `.any(pred)` / `.all(pred)` | Early exit |
| Transform | `blitz.iterMut(T, data).mapInPlace(fn)` | In-place |
| Fill | `.fill(value)` | Parallel memset |
| Reduce | `.reduce(identity, fn)` | Custom aggregation |
| Count | `.count()` | Element count |

### Fork-Join Operations

| Operation | Code | Notes |
|-----------|------|-------|
| Two tasks | `blitz.join(.{.a = .{fn, arg}, .b = .{fn, arg}})` | Returns named tuple |
| N tasks | `blitz.join(.{.a = ..., .b = ..., .c = ...})` | Up to 8 tasks |

### Sorting

| Operation | Code | Notes |
|-----------|------|-------|
| Sort | `blitz.sortAsc(T, data)` | Ascending order |
| Sort Desc | `blitz.sortDesc(T, data)` | Descending order |
| Sort Custom | `blitz.sort(T, data, lessThan)` | Custom comparator |
| Sort by Key | `blitz.sortByKey(T, K, data, keyFn)` | Extract key |

### Low-Level

| Operation | Code | Notes |
|-----------|------|-------|
| Parallel For | `blitz.parallelFor(n, Ctx, ctx, body)` | Index ranges |
| Parallel Reduce | `blitz.parallelReduce(Out, data, id, map, reduce)` | Map-reduce |

## Best Practices

### Do

```zig
// Use iterators for data processing
const sum = blitz.iter(i64, data).sum();

// Use fork-join for recursive algorithms
const result = blitz.join(.{.left = .{fib, n-1}, .right = .{fib, n-2}});

// Set sequential thresholds in recursive functions
if (n < 20) return fibSequential(n);

// Use findAny when order doesn't matter
const found = blitz.iter(T, data).findAny(pred);
```

### Don't

```zig
// Don't parallelize tiny workloads
blitz.iter(i64, small_array).sum(); // Overhead > benefit for <1000 elements

// Don't share mutable state without synchronization
var counter: usize = 0;
blitz.parallelFor(n, ..., fn() { counter += 1; }); // DATA RACE!

// Don't ignore the sequential threshold in fork-join
fn fib(n: u64) u64 {
    // Missing: if (n < 20) return fibSequential(n);
    return blitz.join(...); // Overhead explodes at small n
}
```

## Limitations

| Limitation | Details |
|------------|---------|
| No lazy evaluation | All operations execute immediately |
| No automatic fusion | Chained operations allocate intermediate results |
| Fixed thread count | Worker count set at initialization |
| No priority scheduling | All tasks are equal priority |
| Stack-allocated futures | Deep recursion may cause stack overflow |

## Thread Safety

| Component | Safety | Notes |
|-----------|--------|-------|
| `blitz.iter()` | Thread-safe | Read-only access |
| `blitz.iterMut()` | Thread-safe | Disjoint writes only |
| `blitz.join()` | Thread-safe | Independent tasks |
| `blitz.parallelFor()` | User responsibility | Body must be safe |
| ThreadPool | Thread-safe | All operations atomic |

## Resources

- [Main README](../README.md) - Project overview and benchmarks
- [Examples](../examples/) - Runnable code examples
- [GitHub Repository](https://github.com/jdz/blitz) - Source code and issues
