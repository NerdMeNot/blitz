# Blitz Benchmarks

Performance comparison between Blitz and Rayon, the gold standard for parallel runtimes.

## A Note on Rayon

[Rayon](https://github.com/rayon-rs/rayon) has been the gold standard for parallel iterators
and work-stealing runtimes since 2015. It powers parallel processing in countless Rust
applications and has influenced parallel runtime design across languages.

Blitz is inspired by Rayon's excellent design and aims to bring similar capabilities to Zig.
We benchmark against Rayon not to claim superiority, but to validate that our implementation
achieves competitive performance.

## Running Benchmarks

```bash
./benchmarks/compare_bench.sh
```

This builds and runs both Blitz and Rayon benchmarks with identical configurations.

## System Configuration

- **CPU**: Apple M1 Pro (10 cores)
- **Workers**: 10 threads
- **Warmup**: 5 iterations
- **Benchmark**: 10 iterations
- **Zig**: 0.15.2
- **Rust**: 1.75.0 (for Rayon)

## Results Summary

```
┌──────────────────────────┬────────────────┬────────────────┬──────────────────┐
│ Benchmark                │          Blitz │          Rayon │ Difference       │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Fork-Join (depth=10)     │        4.68 ns │       18.52 ns │ +74.73% faster   │
│ Fork-Join (depth=15)     │        1.02 ns │        1.61 ns │ +36.65% faster   │
│ Fork-Join (depth=20)     │        0.46 ns │        1.05 ns │ +56.19% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ fib(35) parallel         │        3.13 ms │        4.93 ms │ +36.51% faster   │
│ fib(40) parallel         │       42.76 ms │       50.11 ms │ +14.67% faster   │
│ fib(35) sequential       │       24.42 ms │       30.58 ms │ +20.14% faster   │
│ fib(40) sequential       │      275.63 ms │      343.09 ms │ +19.66% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Parallel sum (10M)       │        0.82 ms │        1.28 ms │ +35.94% faster   │
│ Sequential sum (10M)     │        7.41 ms │        7.06 ms │  -4.96% slower   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Sort 1M (random)         │        3.57 ms │        3.53 ms │  -1.13% slower   │
│ Sort 1M (sorted)         │        0.26 ms │        0.41 ms │ +36.59% faster   │
│ Sort 1M (reverse)        │        0.40 ms │        0.54 ms │ +25.93% faster   │
│ Sort 1M (equal)          │        0.25 ms │        0.41 ms │ +39.02% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ find (early exit)        │       12.7 µs │       12.94 µs │  +1.85% faster   │
│ position (early)         │       10.6 µs │       27.55 µs │ +61.52% faster   │
│ position (middle)        │       15.6 µs │       20.01 µs │ +22.04% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ any (early exit)         │       11.0 µs │       12.80 µs │ +14.06% faster   │
│ any (full scan)          │      723.6 µs │      854.4 µs │ +15.31% faster   │
│ all (pass)               │      732.9 µs │      836.3 µs │ +12.36% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ minByKey (10M)           │      956.1 µs │     1256.6 µs │ +23.91% faster   │
│ maxByKey (10M)           │      838.4 µs │     1105.4 µs │ +24.15% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ chunks(1000) + sum       │        0.75 ms │        0.77 ms │  +2.60% faster   │
│ enumerate + forEach      │        0.02 ms │        0.03 ms │ +33.33% faster   │
│ chain(2×5M) + sum        │        0.94 ms │        0.87 ms │  -8.05% slower   │
│ zip + dot product        │        0.80 ms │        0.89 ms │ +10.11% faster   │
│ flatten(1000×10k) + sum  │        0.81 ms │        1.01 ms │ +19.80% faster   │
└──────────────────────────┴────────────────┴────────────────┴──────────────────┘

Legend: + = Blitz faster, - = Rayon faster
```

## Resource Utilization

Blitz uses fewer system resources than Rayon:

```
┌──────────────────────────┬────────────────┬────────────────┬──────────────────┐
│ Metric                   │          Blitz │          Rayon │ Difference       │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Peak Memory              │       207.4 MB │       233.8 MB │ +11.27% less     │
│ Involuntary Ctx Switches │         27,912 │         25,794 │  -8.21% more     │
└──────────────────────────┴────────────────┴────────────────┴──────────────────┘
```

**Peak Memory**: Blitz uses ~11% less memory than Rayon for the same workloads.

## Performance Summary

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         BLITZ vs RAYON SUMMARY                               ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Fork-Join Overhead:        37-75% faster (lock-free futex)                  ║
║  Compute-Bound (Fibonacci): 15-37% faster                                    ║
║  Parallel Sum:              36% faster (SIMD reduction)                      ║
║  Sort (patterns):           26-39% faster (SIMD sorted detection)            ║
║  Sort (random):             ~comparable                                      ║
║  Early Exit Operations:     2-62% faster                                     ║
║  Reductions (min/max/all):  12-24% faster                                    ║
║  Iterator Combinators:      3-33% faster                                     ║
║  Memory Usage:              11% less                                         ║
║                                                                              ║
║  OVERALL: Blitz wins 23 of 26 benchmarks                                     ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

## Detailed Analysis

### Fork-Join Overhead (37-75% faster)

Blitz's lock-free futex wake provides significantly lower synchronization overhead:

| Depth | Total Forks | Blitz | Rayon | Improvement |
|-------|-------------|-------|-------|-------------|
| 10 | 2,047 | 4.68 ns | 18.52 ns | **75% faster** |
| 15 | 65,535 | 1.02 ns | 1.61 ns | **37% faster** |
| 20 | 2,097,151 | 0.46 ns | 1.05 ns | **56% faster** |

**Why Blitz wins**: Lock-free futex wake (`fetchAdd + futex_wake`) vs Rayon's condvar-based approach.

### Parallel Fibonacci (15-37% faster)

Compute-bound recursive workload testing work-stealing efficiency:

| N | Blitz | Rayon | Improvement |
|---|-------|-------|-------------|
| 35 | 3.13 ms | 4.93 ms | **37% faster** |
| 40 | 42.76 ms | 50.11 ms | **15% faster** |

**Why Blitz wins**: Lower fork-join overhead compounds across millions of recursive calls.

### Parallel Sum (36% faster)

SIMD-optimized parallel reduction:

| Mode | Blitz | Rayon | Improvement |
|------|-------|-------|-------------|
| Parallel | 0.82 ms | 1.28 ms | **36% faster** |

**Analysis**: Blitz uses SIMD-accelerated chunked reduction with efficient work distribution.

### PDQSort (Pattern-Defeating Quicksort)

Both Blitz and Rayon implement PDQSort with BlockQuicksort partitioning:

| Pattern | Blitz | Rayon | Improvement |
|---------|-------|-------|-------------|
| Random | 3.57 ms | 3.53 ms | ~same |
| **Sorted** | **0.26 ms** | 0.41 ms | **37% faster** |
| **Reverse** | **0.40 ms** | 0.54 ms | **26% faster** |
| **Equal** | **0.25 ms** | 0.41 ms | **39% faster** |

**Why Blitz wins on patterns**: SIMD-optimized sorted sequence detection. Instead of checking one pair at a time, Blitz checks 4 pairs simultaneously using vector comparisons.

### Early Exit Operations (2-62% faster)

Operations that can terminate early benefit from Blitz's efficient cancellation:

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| find (early) | 12.7 µs | 12.94 µs | **2% faster** |
| position (early) | 10.6 µs | 27.55 µs | **62% faster** |
| position (middle) | 15.6 µs | 20.01 µs | **22% faster** |

### Reduction Operations (12-24% faster)

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| minByKey 10M | 956.1 µs | 1256.6 µs | **24% faster** |
| maxByKey 10M | 838.4 µs | 1105.4 µs | **24% faster** |
| all 10M | 732.9 µs | 836.3 µs | **12% faster** |
| any (full scan) | 723.6 µs | 854.4 µs | **15% faster** |

### Iterator Combinators (3-33% faster)

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| enumerate + forEach | 0.02 ms | 0.03 ms | **33% faster** |
| flatten 1000x10K | 0.81 ms | 1.01 ms | **20% faster** |
| zip 10M | 0.80 ms | 0.89 ms | **10% faster** |
| chunks + sum | 0.75 ms | 0.77 ms | **3% faster** |

## Key Optimizations

### 1. Lock-Free Futex Wake
```
Blitz:       fetchAdd + futex_wake           (~5-10ns)
Traditional: mutex.lock + condvar.signal     (~100-300ns)
```

### 2. SIMD Sorted Detection
```zig
// Scalar (Rayon): check one pair at a time
while (i < len and v[i] >= v[i-1]) i += 1;

// SIMD (Blitz): check 4 pairs at once
const a: @Vector(4, f64) = v[i..][0..4].*;
const b: @Vector(4, f64) = v[i+1..][0..4].*;
if (@reduce(.And, a <= b)) // all 4 pairs sorted
```

### 3. Cache-Line Isolation
- Deque `top` and `bottom` on separate cache lines
- Prevents false sharing between owner and thieves

### 4. Comptime Specialization
- Zig's comptime eliminates virtual dispatch
- Function pointers resolved at compile time

### 5. Lemire's Fast Bounded Random
- O(1) victim selection for work stealing
- No modulo operation or rejection sampling

### 6. Reduced Atomic Operations
- Check atomic flags every 64 elements instead of per-element
- Pre-compute loop invariants to avoid repeated calculations

## Algorithm Choice: Why PDQSort?

| Algorithm | Time | Space | Parallel First Partition | Best For |
|-----------|------|-------|--------------------------|----------|
| **PDQ Sort** | O(n log n) | O(log n) | No | General purpose, in-place |
| Radix Sort | O(n × k) | O(n) | Yes | Fixed-size integers only |
| Sample Sort | O(n log n) | O(n) | Yes | Many cores, large arrays |

PDQSort is the right choice for a general-purpose library:
- Works for any comparable type
- In-place (minimal memory overhead)
- Excellent pattern detection
- Same algorithm used by Rust's standard library

## Acknowledgments

- [Rayon](https://github.com/rayon-rs/rayon) - The gold standard for parallel runtimes
- [PDQSort](https://github.com/orlp/pdqsort) - Orson Peters' pattern-defeating quicksort
- [BlockQuicksort](https://arxiv.org/abs/1604.06697) - Branchless block-based partitioning
- [Chase-Lev Deque](https://www.dre.vanderbilt.edu/~schmidt/PDF/work-stealing-dequeue.pdf) - Lock-free work stealing
- [Crossbeam](https://github.com/crossbeam-rs/crossbeam) - Lock-free data structures
- [Lemire's Fast Range](https://arxiv.org/abs/1805.10941) - Nearly divisionless random
