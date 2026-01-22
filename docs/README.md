# Blitz Documentation

Comprehensive documentation for the Blitz parallel runtime.

## Quick Start

```zig
const blitz = @import("blitz");

// Parallel sum - one line
const sum = blitz.iter(i64, data).sum();

// Parallel min/max
const min = blitz.iter(i64, data).min();

// Parallel search with early exit
const found = blitz.iter(i64, data).findAny(isTarget);

// Parallel transform
blitz.iterMut(i64, data).mapInPlace(double);
```

## Quick Links

- [Quick Start Guide](01-getting-started/02-quick-start.md) - Get running in 2 minutes
- [API Reference](03-api/01-core-api.md) - Complete API docs
- [Examples](../examples/) - Runnable code

## Documentation Structure

### 1. Getting Started
- [Installation](01-getting-started/01-installation.md)
- [Quick Start](01-getting-started/02-quick-start.md)
- [Basic Concepts](01-getting-started/03-basic-concepts.md)

### 2. Usage Guide
- [Iterators](02-usage/05-iterators.md) - **Start here** (recommended API)
- [Fork-Join](02-usage/04-fork-join.md) - Divide and conquer
- [Sorting](02-usage/06-sorting.md) - Parallel sorting
- [SIMD Operations](02-usage/07-simd-operations.md) - Vectorized operations
- [Initialization](02-usage/01-initialization.md) - Configuration options
- [Parallel For](02-usage/02-parallel-for.md) - Low-level parallel loops
- [Parallel Reduce](02-usage/03-parallel-reduce.md) - Low-level reductions

### 3. API Reference
- [Core API](03-api/01-core-api.md) - All functions and types
- [Iterators API](03-api/02-iterators-api.md) - Iterator methods
- [SIMD API](03-api/03-simd-api.md) - Vectorized functions
- [Sort API](03-api/04-sort-api.md) - Sorting functions

### 4. Algorithms (Internals)
- [Work Stealing](04-algorithms/01-work-stealing.md)
- [Chase-Lev Deque](04-algorithms/02-chase-lev-deque.md)
- [PDQSort](04-algorithms/03-pdqsort.md)

### 5. Testing
- [Running Tests](05-testing/01-running-tests.md)
- [Benchmarking](05-testing/02-benchmarking.md)
- [Comparing with Rayon](05-testing/03-comparing-with-rayon.md)

## API at a Glance

| Task | Code |
|------|------|
| Sum | `blitz.iter(T, data).sum()` |
| Min/Max | `blitz.iter(T, data).min()` / `.max()` |
| Find | `blitz.iter(T, data).findAny(pred)` |
| Any/All | `blitz.iter(T, data).any(pred)` / `.all(pred)` |
| Transform | `blitz.iterMut(T, data).mapInPlace(fn)` |
| Fill | `blitz.iterMut(T, data).fill(value)` |
| Sort | `blitz.parallelSort(T, data, allocator)` |
| Fork-Join | `blitz.join(A, B, fnA, fnB, argA, argB)` |

## Resources

- [Main README](../README.md) - Project overview
- [Examples](../examples/) - Runnable examples
- [Benchmarks](../BENCHMARKS.md) - Performance data
