---
title: Comparing with Rayon
description: How to benchmark Blitz against Rust's Rayon.
slug: 1.0.0-zig0.15.2/testing/comparing-with-rayon
---

## Setup

### Build Rayon Benchmark

```bash
cd core/src/blitz/benchmarks/rayon
cargo build --release
```

### Build Blitz Benchmark

```bash
cd core/src/blitz
zig build-exe --dep blitz \
    -Mroot=benchmarks/rayon_compare.zig \
    -Mblitz=api.zig \
    -lc -O ReleaseFast \
    -femit-bin=blitz_bench
```

## Running Comparison

### Run Both Benchmarks

```bash
# Rayon
cd benchmarks/rayon
./target/release/rayon_bench

# Blitz
cd ..
./blitz_bench
```

### Automated Comparison Script

```bash
cd core/src/blitz/benchmarks
./run_comparison.sh
```

## Benchmark Categories

### 1. Fork-Join Overhead

Measures the cost of creating and joining parallel tasks:

```rust
// Rayon
fn fork_join_bench(depth: u32) -> u64 {
    if depth == 0 { return 1; }
    let (a, b) = rayon::join(
        || fork_join_bench(depth - 1),
        || fork_join_bench(depth - 1),
    );
    a + b
}
```

```zig
// Blitz
fn forkJoinBench(depth: u32) u64 {
    if (depth == 0) return 1;
    const results = blitz.join(u64, u64, forkJoinBench, forkJoinBench, depth - 1, depth - 1);
    return results[0] + results[1];
}
```

**Expected results:**

* Both should achieve ~1 ns/fork at scale
* Blitz may be slightly faster due to lock-free wake

### 2. Parallel Sum

```rust
// Rayon
let sum: i64 = data.par_iter().sum();
```

```zig
// Blitz
const sum = blitz.iter(i64, data).sum();
```

**Expected results:**

* Near-identical for large data (memory-bound)
* Blitz may be faster for medium data (lower overhead)

### 3. Parallel Sort

```rust
// Rayon
data.par_sort();
```

```zig
// Blitz
blitz.sortAsc(i64, data);
```

**Expected results:**

* Both use parallel quicksort variants
* Performance depends on data patterns

### 4. Parallel Iterators

```rust
// Rayon
let result: Vec<_> = data.par_iter()
    .filter(|x| **x > 0)
    .map(|x| x * 2)
    .collect();
```

```zig
// Blitz
// Currently more explicit
const positive = try filterPositive(data);
const doubled = try mapDouble(positive);
```

## Results Interpretation

### Expected Performance Ranges

| Operation | Blitz vs Rayon |
|-----------|----------------|
| Fork-join overhead | Blitz 10-20% faster |
| Parallel sum (large) | Within 5% |
| Parallel sort | Within 10% |
| Iterator chains | Rayon may be faster\* |

\*Rayon's lazy iterators can fuse operations

### When Blitz Wins

1. **Lock-free wake**: Lower latency for task spawning
2. **Simple operations**: Less abstraction overhead
3. **Comptime specialization**: Zero-cost generics

### When Rayon Wins

1. **Iterator fusion**: Chains of operations can be optimized
2. **Adaptive stealing**: More sophisticated heuristics
3. **Mature optimizations**: Years of tuning

## Fair Comparison Guidelines

### 1. Same Hardware

Run both on identical machine with same conditions.

### 2. Same Thread Count

```rust
// Rayon
rayon::ThreadPoolBuilder::new()
    .num_threads(10)
    .build_global()
    .unwrap();
```

```zig
// Blitz
try blitz.initWithConfig(.{ .background_worker_count = 9 });
```

### 3. Same Data

Generate identical test data for both:

```rust
// Rayon
let data: Vec<i64> = (0..n).map(|i| i as i64).collect();
```

```zig
// Blitz
for (data, 0..) |*v, i| v.* = @intCast(i);
```

### 4. Same Optimization Level

```bash
# Rayon
cargo build --release  # -O3

# Blitz
zig build-exe ... -O ReleaseFast  # Similar to -O3
```

### 5. Warmup Both

```rust
// Rayon warmup
let _ = data.par_iter().sum::<i64>();
```

```zig
// Blitz warmup
_ = blitz.iter(i64, data).sum();
```

## Sample Results

```
Hardware: Apple M1 Pro, 10 cores
Data: 10M i64 elements

+--------------------+-----------+-----------+-------------+
| Benchmark          | Blitz     | Rayon     | Comparison  |
+--------------------+-----------+-----------+-------------+
| Fork-join (2M)     | 0.54 ns   | 0.66 ns   | Blitz +22%  |
| Parallel sum       | 1.1 ms    | 1.2 ms    | Blitz +9%   |
| Parallel sort      | 134 ms    | 145 ms    | Blitz +8%   |
| Parallel fib(45)   | 411 ms    | 414 ms    | Equal       |
| Find first         | 3.3 ms    | 3.1 ms    | Rayon +6%   |
+--------------------+-----------+-----------+-------------+
```

## Reporting Results

When sharing benchmark results:

1. **Include hardware specs** (CPU, cores, memory)
2. **Include software versions** (Zig version, Rust version)
3. **Show multiple runs** (min, median, max)
4. **Describe data patterns** (random, sorted, etc.)
5. **Note thread count** used for comparison
