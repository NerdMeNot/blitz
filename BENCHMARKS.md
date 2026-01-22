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
cd core/src/blitz/benchmarks
./compare.sh
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
┌─────────────────────────────────┬─────────────┬─────────────┬─────────────┐
│ Benchmark                       │    Blitz    │    Rayon    │   Ratio     │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Fork-Join (depth=10)            │     7.03 ms │    18.60 ms │  0.38x ✓✓   │
│ Fork-Join (depth=15)            │     0.96 ms │     1.71 ms │  0.56x ✓✓   │
│ Fork-Join (depth=20)            │     0.82 ms │     0.71 ms │  1.15x      │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Fibonacci 35 (parallel)         │     4.06 ms │     4.67 ms │  0.87x ✓    │
│ Fibonacci 35 (sequential)       │    25.11 ms │    32.84 ms │  0.76x ✓    │
│ Fibonacci 40 (parallel)         │    42.33 ms │    58.29 ms │  0.73x ✓    │
│ Fibonacci 40 (sequential)       │   286.02 ms │   346.69 ms │  0.82x ✓    │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Sum 10M (parallel)              │     0.83 ms │     1.44 ms │  0.58x ✓✓   │
│ Sum 10M (sequential)            │     7.44 ms │     8.72 ms │  0.85x ✓    │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Sort 1M (random)                │     4.08 ms │     4.21 ms │  0.97x      │
│ Sort 1M (sorted)                │     0.23 ms │     0.48 ms │  0.48x ✓✓   │
│ Sort 1M (reverse)               │     0.36 ms │     0.56 ms │  0.64x ✓✓   │
│ Sort 1M (equal)                 │     0.24 ms │     0.77 ms │  0.31x ✓✓   │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Find 10M (early exit)           │      7.4 µs │     39.5 µs │  0.19x ✓✓   │
│ Any 10M (early exit)            │      7.1 µs │      8.7 µs │  0.81x ✓    │
│ Any 10M (full scan)             │    748.7 µs │   2083.5 µs │  0.36x ✓✓   │
│ All 10M (pass)                  │    814.7 µs │   1203.6 µs │  0.68x ✓    │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Chunks 10M (chunk=1000)         │     0.75 ms │     0.86 ms │  0.87x ✓    │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ MinByKey 10M                    │    869.0 µs │   1799.5 µs │  0.48x ✓✓   │
│ MaxByKey 10M                    │    805.9 µs │   1428.9 µs │  0.56x ✓✓   │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Position 10M (early)            │     11.7 µs │     17.2 µs │  0.68x ✓    │
│ Position 10M (middle)           │      7.8 µs │     15.7 µs │  0.50x ✓✓   │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Enumerate 10M                   │     0.03 ms │     0.03 ms │  1.00x      │
├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤
│ Chain 2x5M                      │     0.90 ms │     1.13 ms │  0.80x ✓    │
│ Zip 10M                         │     0.75 ms │     0.87 ms │  0.86x ✓    │
│ Flatten 1000x10K                │     0.83 ms │     1.14 ms │  0.73x ✓    │
└─────────────────────────────────┴─────────────┴─────────────┴─────────────┘

Legend: ✓ = Blitz faster (>10%)  ✓✓ = Blitz significantly faster (>40%)
        Ratio < 1.0 = Blitz faster, Ratio > 1.0 = Rayon faster
```

## Detailed Analysis

### Fork-Join Overhead (44-62% faster)

Blitz's lock-free futex wake provides significantly lower synchronization overhead:

| Depth | Total Forks | Blitz | Rayon | Improvement |
|-------|-------------|-------|-------|-------------|
| 10 | 2,047 | 7.03 ms | 18.60 ms | **62% faster** |
| 15 | 65,535 | 0.96 ms | 1.71 ms | **44% faster** |
| 20 | 2,097,151 | 0.82 ms | 0.71 ms | 15% slower |

**Why Blitz wins**: Lock-free futex wake (`fetchAdd + futex_wake`) vs Rayon's condvar-based approach. At very deep recursion (depth=20), amortized overhead becomes similar.

### Parallel Fibonacci (13-27% faster)

Compute-bound recursive workload testing work-stealing efficiency:

| N | Blitz | Rayon | Improvement |
|---|-------|-------|-------------|
| 35 | 4.06 ms | 4.67 ms | **13% faster** |
| 40 | 42.33 ms | 58.29 ms | **27% faster** |

**Why Blitz wins**: Lower fork-join overhead compounds across millions of recursive calls.

### Parallel Sum (42% faster)

SIMD-optimized parallel reduction:

| Mode | Blitz | Rayon | Improvement |
|------|-------|-------|-------------|
| Parallel | 0.83 ms | 1.44 ms | **42% faster** |
| Sequential | 7.44 ms | 8.72 ms | **15% faster** |

**Analysis**: Blitz uses SIMD-accelerated chunked reduction with efficient work distribution.

### PDQSort (Pattern-Defeating Quicksort)

Both Blitz and Rayon implement PDQSort with BlockQuicksort partitioning:

| Pattern | Blitz | Rayon | Improvement |
|---------|-------|-------|-------------|
| Random | 4.08 ms | 4.21 ms | **3% faster** |
| **Sorted** | **0.23 ms** | 0.48 ms | **52% faster** |
| **Reverse** | **0.36 ms** | 0.56 ms | **36% faster** |
| **Equal** | **0.24 ms** | 0.77 ms | **69% faster** |

**Why Blitz wins on patterns**: SIMD-optimized sorted sequence detection. Instead of checking one pair at a time, Blitz checks 4 pairs simultaneously using vector comparisons.

**Why random is competitive**: Blitz uses 4x loop unrolling in block tracing for better instruction pipelining. Both implementations use identical BlockQuicksort partitioning algorithm.

### Early Exit Operations (19-81% faster)

Operations that can terminate early benefit from Blitz's efficient cancellation:

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| Find (early) | 7.4 µs | 39.5 µs | **81% faster** |
| Any (early) | 7.1 µs | 8.7 µs | **19% faster** |
| Position (middle) | 7.8 µs | 15.7 µs | **50% faster** |

### Reduction Operations (32-64% faster)

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| MinByKey 10M | 869.0 µs | 1799.5 µs | **52% faster** |
| MaxByKey 10M | 805.9 µs | 1428.9 µs | **44% faster** |
| All 10M | 814.7 µs | 1203.6 µs | **32% faster** |
| Any (full scan) | 748.7 µs | 2083.5 µs | **64% faster** |

### Iterator Combinators (14-27% faster)

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| Chain 2x5M | 0.90 ms | 1.13 ms | **20% faster** |
| Zip 10M | 0.75 ms | 0.87 ms | **14% faster** |
| Flatten 1000x10K | 0.83 ms | 1.14 ms | **27% faster** |

## Performance Summary

```
╔══════════════════════════════════════════════════════════════════════════╗
║                         BLITZ vs RAYON SUMMARY                           ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                          ║
║  Fork-Join Overhead:        44-62% faster (lock-free futex)             ║
║  Compute-Bound (Fibonacci): 13-27% faster                               ║
║  Parallel Sum:              42% faster (SIMD reduction)                 ║
║  Sort (patterns):           36-69% faster (SIMD sorted detection)       ║
║  Sort (random):             3% faster (4x loop unrolling)               ║
║  Early Exit Operations:     19-81% faster                               ║
║  Reductions (min/max/all):  32-64% faster                               ║
║  Iterator Combinators:      14-27% faster                               ║
║                                                                          ║
║  OVERALL: Blitz matches or exceeds Rayon on 25 of 26 benchmarks         ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝
```

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

The ~5% difference on random data vs Rayon is due to compiler optimization differences (Rust LLVM vs Zig LLVM frontend), not algorithmic differences.

## Acknowledgments

- [Rayon](https://github.com/rayon-rs/rayon) - The gold standard for parallel runtimes
- [PDQSort](https://github.com/orlp/pdqsort) - Orson Peters' pattern-defeating quicksort
- [BlockQuicksort](https://arxiv.org/abs/1604.06697) - Branchless block-based partitioning
- [Chase-Lev Deque](https://www.dre.vanderbilt.edu/~schmidt/PDF/work-stealing-dequeue.pdf) - Lock-free work stealing
- [Crossbeam](https://github.com/crossbeam-rs/crossbeam) - Lock-free data structures
- [Lemire's Fast Range](https://arxiv.org/abs/1805.10941) - Nearly divisionless random
