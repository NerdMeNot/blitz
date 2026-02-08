# Blitz Benchmarks

Performance comparison between Blitz and [Rayon](https://github.com/rayon-rs/rayon).

## Standing on Rayon's Shoulders

Rayon has been the gold standard for parallel iterators and work-stealing runtimes since 2015.
It powers parallel processing in countless Rust applications and has shaped how an entire
generation of developers thinks about fork-join parallelism.

Blitz wouldn't exist without Rayon. Its JEC sleep protocol, its approach to parallel iterators,
its use of Chase-Lev deques, its PDQSort integration — we studied and learned from all of it.
Where Blitz differs, it's because Zig's comptime and value semantics open up paths that weren't
available in Rust, not because we found flaws in Rayon's design.

We benchmark against Rayon to keep ourselves honest, not to claim superiority. Rayon is a
mature, battle-tested library with years of production use. Blitz is new. These numbers are
a snapshot in time on one machine — your mileage will vary.

## Test Platform

- **Machine**: MacBook Pro (Apple M3 Pro, 11 cores, 18 GB RAM)
- **OS**: macOS 26.2 (arm64)
- **Zig**: 0.15.2
- **Rust**: 1.92.0
- **Workers**: 10 threads (both frameworks)
- **Warmup**: 5 iterations discarded
- **Measured**: 10 iterations averaged

## Running Benchmarks

```bash
zig build compare
```

This builds and runs both Blitz and Rayon benchmarks with identical configurations.

## Results

```
┌──────────────────────────┬────────────────┬────────────────┬──────────────────┐
│ Benchmark                │          Blitz │          Rayon │ Difference       │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Fork-Join (depth=10)     │        5.16 ns │       20.07 ns │ +74.3% faster    │
│ Fork-Join (depth=15)     │        1.31 ns │        1.70 ns │ +22.9% faster    │
│ Fork-Join (depth=20)     │        0.76 ns │        0.65 ns │ -16.9% slower    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ fib(35) parallel         │        4.02 ms │        4.67 ms │ +13.9% faster    │
│ fib(35) sequential       │       25.61 ms │       31.00 ms │ +17.4% faster    │
│ fib(40) parallel         │       38.89 ms │       52.37 ms │ +25.7% faster    │
│ fib(40) sequential       │      277.93 ms │      355.71 ms │ +21.9% faster    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Parallel sum (10M)       │        1.62 ms │        1.49 ms │  -8.7% slower    │
│ Sequential sum (10M)     │        7.89 ms │        7.41 ms │  -6.5% slower    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Sort 1M (random)         │        3.68 ms │        3.99 ms │  +7.8% faster    │
│ Sort 1M (sorted)         │        0.25 ms │        0.45 ms │ +44.4% faster    │
│ Sort 1M (reverse)        │        0.37 ms │        0.60 ms │ +38.3% faster    │
│ Sort 1M (equal)          │        0.27 ms │        0.47 ms │ +42.6% faster    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ find (early exit)        │          ~ 0 µs │       18.14 µs │ n/a              │
│ position (early)         │        1.30 µs │       14.12 µs │ +90.8% faster    │
│ position (middle)        │        1.90 µs │       15.85 µs │ +88.0% faster    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ any (early exit)         │        0.10 µs │       16.14 µs │ +99.4% faster    │
│ any (full scan)          │      828.90 µs │     1314.52 µs │ +36.9% faster    │
│ all (pass)               │      918.20 µs │     1300.70 µs │ +29.4% faster    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ minByKey (10M)           │      867.60 µs │     1937.97 µs │ +55.2% faster    │
│ maxByKey (10M)           │      964.00 µs │     1378.01 µs │ +30.0% faster    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ chunks(1000) + sum       │        0.78 ms │        1.05 ms │ +25.7% faster    │
│ enumerate + forEach      │        0.02 ms │        0.07 ms │ +71.4% faster    │
│ chain(2x5M) + sum        │        0.86 ms │        0.98 ms │ +12.2% faster    │
│ zip + dot product        │        0.85 ms │        0.90 ms │  +5.6% faster    │
│ flatten(1000x10k) + sum  │        0.76 ms │        1.17 ms │ +35.0% faster    │
├──────────────────────────┼────────────────┼────────────────┼──────────────────┤
│ Peak Memory              │       208.0 MB │       233.2 MB │ +10.8% less      │
│ Involuntary Ctx Sw       │         30,025 │         34,236 │ +12.3% fewer     │
└──────────────────────────┴────────────────┴────────────────┴──────────────────┘

  Blitz wins: 24 / 27    Rayon wins: 3 / 27

  Legend: + = Blitz faster/less, - = Rayon faster/less
```

## Where Rayon Wins

Rayon outperforms Blitz on parallel and sequential sum (by ~7-9%). At very high fork depths
(depth=20, 2M+ forks), Rayon's mature scheduling also edges ahead. These are areas where
we have more to learn.

## What Helps Blitz

Most of Blitz's advantages come from Zig's language properties rather than algorithmic
breakthroughs:

- **Comptime specialization** — function pointers resolved at compile time eliminate virtual
  dispatch overhead that Rayon pays through trait objects
- **Value semantics** — no heap allocation for closures or iterator adapters
- **Cache-line isolation** — deque `top`/`bottom` on separate cache lines, padded worker
  state to prevent false sharing
- **Packed atomics** — single u64 holds sleeping threads, inactive threads, and JEC counter

The fork-join protocol, the Chase-Lev deque, the PDQSort integration, the sleep/wake
coordination — these are all Rayon's ideas, adapted for Zig.

## Caveats

- Single machine, single OS — results on Linux/x86 may differ significantly
- Microbenchmarks, not real workloads — production performance depends on many factors
- Both frameworks are configured identically (10 workers, same warmup/iteration counts)
- Run-to-run variance is typically 5-15% on these benchmarks
- Rayon is mature and battle-tested; Blitz is new and less proven in production

## Acknowledgments

- [Rayon](https://github.com/rayon-rs/rayon) — the library that taught us how parallel runtimes should work
- [PDQSort](https://github.com/orlp/pdqsort) — Orson Peters' pattern-defeating quicksort
- [BlockQuicksort](https://arxiv.org/abs/1604.06697) — branchless block-based partitioning
- [Chase-Lev Deque](https://www.dre.vanderbilt.edu/~schmidt/PDF/work-stealing-dequeue.pdf) — lock-free work stealing
- [Crossbeam](https://github.com/crossbeam-rs/crossbeam) — lock-free data structures that inspired our deque
- [Lemire's Fast Range](https://arxiv.org/abs/1805.10941) — nearly divisionless random for victim selection
