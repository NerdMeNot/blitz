# Blitz: High-Performance Parallel Runtime for Zig

[![CI](https://github.com/NerdMeNot/blitz/actions/workflows/ci.yml/badge.svg)](https://github.com/NerdMeNot/blitz/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**Rayon-style parallelism for Zig. Simple API, serious performance.**

```zig
const blitz = @import("blitz");

// That's it. Sum 10 million numbers in parallel.
const sum = blitz.iter(i64, data).sum();
```

## Quick Start

```zig
const blitz = @import("blitz");

pub fn main() !void {
    // Parallel sum
    const sum = blitz.iter(i64, numbers).sum();

    // Parallel min/max
    const min = blitz.iter(i64, numbers).min();
    const max = blitz.iter(i64, numbers).max();

    // Parallel search with early exit
    const found = blitz.iter(i64, numbers).findAny(isTarget);

    // Parallel predicates
    const has_negative = blitz.iter(i64, numbers).any(isNegative);
    const all_positive = blitz.iter(i64, numbers).all(isPositive);

    // Parallel transform (in-place)
    blitz.iterMut(i64, numbers).mapInPlace(double);
    blitz.iterMut(i64, numbers).fill(0);

    // Parallel sort
    try blitz.parallelSort(i64, numbers, allocator);
}

fn isTarget(x: i64) bool { return x == 42; }
fn isNegative(x: i64) bool { return x < 0; }
fn isPositive(x: i64) bool { return x > 0; }
fn double(x: i64) i64 { return x * 2; }
```

## Installation

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .blitz = .{
        .url = "https://github.com/NerdMeNot/blitz/archive/refs/tags/v1.0.0-zig0.15.2.tar.gz",
        .hash = "...", // zig build will tell you
    },
},
```

Add to `build.zig`:

```zig
const blitz_dep = b.dependency("blitz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("blitz", blitz_dep.module("blitz"));
```

**Requirements:** Zig 0.15.0+, Linux/macOS/Windows

## API Reference

### Iterators (Primary API)

The iterator API is the simplest way to use Blitz:

```zig
const blitz = @import("blitz");

// Create iterator from slice
const it = blitz.iter(T, slice);      // immutable
const it = blitz.iterMut(T, slice);   // mutable
const it = blitz.range(start, end);   // index range
```

#### Aggregations

```zig
blitz.iter(i64, data).sum()           // -> i64
blitz.iter(i64, data).min()           // -> ?i64
blitz.iter(i64, data).max()           // -> ?i64
blitz.iter(i64, data).reduce(0, add)  // -> i64 (custom reducer)
```

#### Search (with early exit)

```zig
blitz.iter(T, data).findAny(pred)     // -> ?T (any match, fast)
blitz.iter(T, data).findFirst(pred)   // -> ?FindResult(T) (leftmost)
blitz.iter(T, data).findLast(pred)    // -> ?FindResult(T) (rightmost)
blitz.iter(T, data).position(pred)    // -> ?usize (index of first match)
```

#### Predicates (with early exit)

```zig
blitz.iter(T, data).any(pred)         // -> bool (true if any match)
blitz.iter(T, data).all(pred)         // -> bool (true if all match)
```

#### Min/Max by Key

```zig
blitz.iter(T, data).minBy(comparator) // -> ?T
blitz.iter(T, data).maxBy(comparator) // -> ?T
blitz.iter(T, data).minByKey(K, keyFn)// -> ?T
blitz.iter(T, data).maxByKey(K, keyFn)// -> ?T
```

#### Mutation

```zig
blitz.iterMut(T, data).mapInPlace(fn) // transform each element
blitz.iterMut(T, data).fill(value)    // fill with value
blitz.iterMut(T, data).forEach(fn)    // execute fn for each
```

#### Combinators

```zig
blitz.iter(T, a).chain(blitz.iter(T, b))  // concatenate
blitz.iter(T, a).zip(blitz.iter(U, b))    // pair elements
blitz.flatten(slices)                      // flatten nested slices
```

### Fork-Join

For divide-and-conquer algorithms:

```zig
// Execute two functions in parallel
const result = blitz.join(u64, u64, computeLeft, computeRight, left_arg, right_arg);
// result[0] = computeLeft(left_arg)
// result[1] = computeRight(right_arg)

// Classic example: parallel fibonacci
fn fib(n: u64) u64 {
    if (n < 20) return fibSequential(n);
    const r = blitz.join(u64, u64, fib, fib, n - 1, n - 2);
    return r[0] + r[1];
}
```

#### Multiple Tasks

```zig
// 2 tasks, different return types
const r = blitz.join2(i32, i64, fnA, fnB);

// 3 tasks, different return types
const r = blitz.join3(i32, i64, f64, fnA, fnB, fnC);

// N tasks, same return type
const funcs = [_]fn() i64{ fn1, fn2, fn3, fn4 };
const results = blitz.joinN(i64, 4, &funcs);

// Spawn up to 64 tasks dynamically
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        s.spawn(task1);
        s.spawn(task2);
        s.spawn(task3);
    }
}.run);
```

### Parallel Algorithms

```zig
// Sort
try blitz.parallelSort(i64, data, allocator);
try blitz.parallelSortBy(i64, data, allocator, lessThan);

// Scan (prefix sum)
blitz.parallelScan(i64, input, output);          // inclusive
blitz.parallelScanExclusive(i64, input, output); // exclusive

// Find
blitz.parallelFind(i64, data, predicate);        // -> ?usize
blitz.parallelFindValue(i64, data, value);       // -> ?usize

// Partition
blitz.parallelPartition(i64, data, predicate);   // -> pivot index
```

### Range Iteration

```zig
// Parallel for over indices
blitz.range(0, 1000).forEach(processIndex);

// With sum
const total = blitz.range(0, 100).sum(i64, valueAt);

// For-range with context
blitz.parallelForRange(0, n, processIndex);
```

### Error Handling

```zig
// Error-safe join: task B always completes even if A fails
const result = try blitz.tryJoin(u64, u64, MyError, fnA, fnB, argA, argB);

// Error-safe iteration
try blitz.tryForEach(...);
try blitz.tryReduce(...);
```

## Performance

Blitz matches or beats Rayon on most workloads:

| Benchmark | Blitz | Rayon | Winner |
|-----------|-------|-------|--------|
| Fork-join (2M forks) | 0.54 ns/fork | 0.66 ns/fork | Blitz +22% |
| Parallel fib(45) | 411 ms | 414 ms | Tie |
| Sum 10M | 0.78 ms | 0.80 ms | Blitz +3% |
| Sort 1M | 3.55 ms | 3.80 ms | Blitz +7% |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         YOUR CODE                                │
│  iter(data).sum() | join(a, b) | parallelSort() | range()       │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│                      WORK STEALING                               │
│  • Chase-Lev deques (lock-free push/pop/steal)                  │
│  • Futex-based wake (no mutex on hot path)                      │
│  • Adaptive work splitting                                       │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│                      SIMD + THREADS                              │
│  • Vectorized aggregations (sum, min, max)                      │
│  • Automatic parallelism threshold                              │
└─────────────────────────────────────────────────────────────────┘
```

## When to Use Blitz

**Great for:**
- Numeric computation (sum, min, max, transforms)
- Sorting large arrays
- Divide-and-conquer algorithms
- Search with early termination
- Data >100K elements

**Less ideal for:**
- I/O-bound work
- Very small data (<10K elements)
- Simple memory copies

## Advanced Usage

### Low-Level API

For fine-grained control:

```zig
// Manual grain size control
blitz.parallelForWithGrain(n, Context, ctx, body, grain_size);
blitz.parallelReduceWithGrain(...);

// Direct SIMD access
const sum = blitz.simdSum(i64, data);  // SIMD only, no threading
```

### Configuration

```zig
// Custom thread count
try blitz.initWithConfig(.{ .background_worker_count = 8 });
defer blitz.deinit();

// Adjust grain size globally
blitz.setGrainSize(1024);
```

## Project Structure

```
blitz/
├── mod.zig          # Library entry point
├── api.zig          # High-level API
├── iter/            # Parallel iterators
├── simd/            # SIMD-accelerated operations
├── sort/            # Parallel sorting
├── pool.zig         # Thread pool
├── deque.zig        # Lock-free work-stealing deque
├── future.zig       # Fork-join primitives
└── scope.zig        # Scope-based parallelism
```

## Building

```bash
zig build              # Build library
zig build test         # Run tests
zig build bench        # Run benchmarks
```

## License

Apache 2.0. See [LICENSE](LICENSE).
