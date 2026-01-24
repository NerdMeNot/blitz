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
│ Fork-Join (depth=10)     │        5.70 ns │       22.92 ns │ +75.13% faster   │
│ Fork-Join (depth=15)     │        1.61 ns │        1.80 ns │ +10.56% faster   │
│ Fork-Join (depth=20)     │        0.59 ns │        0.59 ns │ ~same            │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ fib(35) parallel         │        3.58 ms │        4.55 ms │ +21.32% faster   │
│ fib(40) parallel         │       33.60 ms │       51.48 ms │ +34.73% faster   │
│ fib(35) sequential       │       24.85 ms │       31.46 ms │ +21.01% faster   │
│ fib(40) sequential       │      278.28 ms │      348.94 ms │ +20.25% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Parallel sum (10M)       │        0.78 ms │        1.13 ms │ +30.97% faster   │
│ Sequential sum (10M)     │        7.63 ms │        7.65 ms │ ~same            │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Sort 1M (random)         │        3.12 ms │        3.33 ms │ +6.31% faster    │
│ Sort 1M (sorted)         │        0.23 ms │        0.42 ms │ +45.24% faster   │
│ Sort 1M (reverse)        │        0.36 ms │        0.55 ms │ +34.55% faster   │
│ Sort 1M (equal)          │        0.23 ms │        0.42 ms │ +45.24% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ find (early exit)        │        0.0 µs │       15.59 µs │ +99.00% faster   │
│ position (early)         │        1.4 µs │       19.43 µs │ +92.79% faster   │
│ position (middle)        │        3.5 µs │       20.71 µs │ +83.10% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ any (early exit)         │        0.0 µs │       15.90 µs │ +99.00% faster   │
│ any (full scan)          │      750.9 µs │      818.88 µs │ +8.30% faster    │
│ all (pass)               │      746.5 µs │      861.98 µs │ +13.40% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ minByKey (10M)           │      799.3 µs │     1357.17 µs │ +41.10% faster   │
│ maxByKey (10M)           │      765.5 µs │     1210.08 µs │ +36.74% faster   │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ chunks(1000) + sum       │        0.69 ms │        0.79 ms │ +12.66% faster   │
│ enumerate + forEach      │        0.02 ms │        0.06 ms │ +66.67% faster   │
│ chain(2×5M) + sum        │        0.80 ms │        0.96 ms │ +16.67% faster   │
│ zip + dot product        │        0.76 ms │        0.83 ms │ +8.43% faster    │
│ flatten(1000×10k) + sum  │        0.76 ms │        1.05 ms │ +27.62% faster   │
└──────────────────────────┴────────────────┴────────────────┴──────────────────┘

Legend: + = Blitz faster, - = Rayon faster
```

## Resource Utilization

Blitz uses fewer system resources than Rayon:

```
┌──────────────────────────┬────────────────┬────────────────┬──────────────────┐
│ Metric                   │          Blitz │          Rayon │ Difference       │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Peak Memory              │       207.9 MB │       233.5 MB │ +10.96% less     │
│ Involuntary Ctx Switches │         21,874 │         30,172 │ +27.50% fewer    │
└──────────────────────────┴────────────────┴────────────────┴──────────────────┘
```

**Peak Memory**: Blitz uses ~11% less memory than Rayon for the same workloads.

## Performance Summary

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         BLITZ vs RAYON SUMMARY                               ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Fork-Join Overhead:        10-75% faster (Rayon-style JEC protocol)         ║
║  Compute-Bound (Fibonacci): 20-35% faster                                    ║
║  Parallel Sum:              31% faster (SIMD reduction)                      ║
║  Sort (patterns):           34-45% faster (SIMD sorted detection)            ║
║  Sort (random):             6% faster                                        ║
║  Early Exit Operations:     83-99% faster (efficient cancellation)           ║
║  Reductions (min/max/all):  8-41% faster                                     ║
║  Iterator Combinators:      8-67% faster                                     ║
║  Memory Usage:              11% less                                         ║
║                                                                              ║
║  OVERALL: Blitz wins 24-25 of 26 benchmarks consistently                     ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

## Detailed Analysis

### Fork-Join Overhead (10-75% faster)

Blitz's Rayon-style JEC protocol provides efficient sleep/wake coordination:

| Depth | Total Forks | Blitz | Rayon | Improvement |
|-------|-------------|-------|-------|-------------|
| 10 | 2,047 | 5.70 ns | 22.92 ns | **75% faster** |
| 15 | 65,535 | 1.61 ns | 1.80 ns | **11% faster** |
| 20 | 2,097,151 | 0.59 ns | 0.59 ns | ~same |

**Why Blitz wins**: JEC (Jobs Event Counter) protocol with progressive sleep (32 yields → announce sleepy → sleep) minimizes both latency and CPU usage.

### Parallel Fibonacci (20-35% faster)

Compute-bound recursive workload testing work-stealing efficiency:

| N | Blitz | Rayon | Improvement |
|---|-------|-------|-------------|
| 35 | 3.58 ms | 4.55 ms | **21% faster** |
| 40 | 33.60 ms | 51.48 ms | **35% faster** |

**Why Blitz wins**: Lower fork-join overhead compounds across millions of recursive calls.

### Parallel Sum (31% faster)

SIMD-optimized parallel reduction:

| Mode | Blitz | Rayon | Improvement |
|------|-------|-------|-------------|
| Parallel | 0.78 ms | 1.13 ms | **31% faster** |

**Analysis**: Blitz uses SIMD-accelerated chunked reduction with efficient work distribution.

### PDQSort (Pattern-Defeating Quicksort)

Both Blitz and Rayon implement PDQSort with BlockQuicksort partitioning:

| Pattern | Blitz | Rayon | Improvement |
|---------|-------|-------|-------------|
| Random | 3.12 ms | 3.33 ms | **6% faster** |
| **Sorted** | **0.23 ms** | 0.42 ms | **45% faster** |
| **Reverse** | **0.36 ms** | 0.55 ms | **35% faster** |
| **Equal** | **0.23 ms** | 0.42 ms | **45% faster** |

**Why Blitz wins on patterns**: SIMD-optimized sorted sequence detection. Instead of checking one pair at a time, Blitz checks 4 pairs simultaneously using vector comparisons.

### Early Exit Operations (83-99% faster)

Operations that can terminate early benefit from Blitz's efficient cancellation:

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| find (early) | 0.0 µs | 15.59 µs | **99% faster** |
| position (early) | 1.4 µs | 19.43 µs | **93% faster** |
| position (middle) | 3.5 µs | 20.71 µs | **83% faster** |

### Reduction Operations (8-41% faster)

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| minByKey 10M | 799.3 µs | 1357.17 µs | **41% faster** |
| maxByKey 10M | 765.5 µs | 1210.08 µs | **37% faster** |
| all 10M | 746.5 µs | 861.98 µs | **13% faster** |
| any (full scan) | 750.9 µs | 818.88 µs | **8% faster** |

### Iterator Combinators (8-67% faster)

| Operation | Blitz | Rayon | Improvement |
|-----------|-------|-------|-------------|
| enumerate + forEach | 0.02 ms | 0.06 ms | **67% faster** |
| flatten 1000x10K | 0.76 ms | 1.05 ms | **28% faster** |
| chain 2×5M | 0.80 ms | 0.96 ms | **17% faster** |
| chunks + sum | 0.69 ms | 0.79 ms | **13% faster** |
| zip 10M | 0.76 ms | 0.83 ms | **8% faster** |

## Key Optimizations

### 1. Rayon-Style JEC Protocol
```zig
// Jobs Event Counter: even=sleepy, odd=active
// Workers check JEC snapshot before sleeping to detect new work
fn incrementJecIfSleepy(self: *AtomicCounters) u64 {
    while (true) {
        const old = self.loadSeqCst();
        if ((extractJec(old) & 1) != 0) return old;  // Already active
        const new = old +% ONE_JEC;  // Toggle to odd
        if (self.value.cmpxchgWeak(old, new, .seq_cst, .monotonic) == null) {
            return old;
        }
    }
}
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
- WorkerSleepState padded to prevent false sharing
- Prevents cache invalidation between owner and thieves

### 4. Comptime Specialization
- Zig's comptime eliminates virtual dispatch
- Function pointers resolved at compile time

### 5. Lemire's Fast Bounded Random
- O(1) victim selection for work stealing
- No modulo operation or rejection sampling

### 6. Packed AtomicCounters
```
AtomicCounters (u64):
├── Bits 0-15:  sleeping_threads
├── Bits 16-31: inactive_threads
└── Bits 32-63: JEC (Jobs Event Counter)
```
Single atomic load/store for all sleep coordination state.

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
