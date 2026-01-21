# Changelog

All notable changes to Blitz will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2024-XX-XX

### Added

- **Core Runtime**
  - Lock-free work-stealing thread pool
  - Chase-Lev deque for task distribution
  - Futex-based worker wake (lock-free)
  - Fork-join API (`join`, `joinVoid`)

- **Parallel Primitives**
  - `parallelFor` - parallel iteration over ranges
  - `parallelReduce` - map-reduce with associative combine
  - `parallelCollect` - parallel collection into output buffer
  - `parallelFlatten` - parallel flattening of nested slices
  - `parallelScatter` - parallel scatter writes

- **Parallel Iterators** (Rayon-style)
  - `iter()` / `iterMut()` - create parallel iterators
  - `sum()`, `min()`, `max()` - SIMD-optimized reductions
  - `any()`, `all()` - predicates with early termination
  - `find()`, `findFirst()`, `findLast()` - parallel search
  - `position()`, `rposition()` - index finding
  - `minBy()`, `maxBy()`, `minByKey()`, `maxByKey()` - custom comparisons
  - `chunks()`, `enumerate()` - chunk and index iteration
  - `chain()`, `zip()`, `flatten()` - combinators

- **Parallel Sorting**
  - PDQSort (pattern-defeating quicksort)
  - `sort()`, `sortAsc()`, `sortDesc()`
  - `sortByKey()`, `sortByCachedKey()`
  - `stableSort()` for stable ordering
  - SIMD-optimized sorted detection

- **SIMD Operations**
  - Vectorized sum, min, max
  - argmin, argmax with index tracking
  - findValue, anyGreaterThan, allLessThan

- **Convenience Functions**
  - `parallelSum`, `parallelMin`, `parallelMax`, `parallelMean`
  - `parallelAdd`, `parallelFill`, `parallelMap`
  - `parallelAny`, `parallelAll`, `parallelCount`

- **Synchronization Primitives**
  - `SyncPtr` for lock-free parallel writes
  - `OnceLatch`, `CountLatch` for coordination
  - `SpinWait` for efficient spinning

### Performance

- Matches or beats Rust's Rayon on 26/28 benchmarks
- Fork-join overhead: ~0.5 ns/fork
- Lock-free hot path throughout

### Documentation

- Comprehensive README with architecture diagrams
- API reference with examples
- Benchmark results vs Rayon
