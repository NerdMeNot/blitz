# Blitz Documentation

Comprehensive documentation for the Blitz parallel runtime.

## Quick Links

- [Quick Start](01-getting-started/02-quick-start.md) - Get parallel code running in 5 minutes
- [API Reference](03-api/01-core-api.md) - Complete API documentation
- [Examples](../examples/) - Runnable code examples

## Documentation Structure

### 1. Getting Started
- [Installation](01-getting-started/01-installation.md)
- [Quick Start](01-getting-started/02-quick-start.md)
- [Basic Concepts](01-getting-started/03-basic-concepts.md)

### 2. Usage Guide
- [Initialization](02-usage/01-initialization.md)
- [Parallel For](02-usage/02-parallel-for.md)
- [Parallel Reduce](02-usage/03-parallel-reduce.md)
- [Fork-Join](02-usage/04-fork-join.md)
- [Iterators](02-usage/05-iterators.md)
- [Sorting](02-usage/06-sorting.md)
- [SIMD Operations](02-usage/07-simd-operations.md)

### 3. API Reference
- [Core API](03-api/01-core-api.md) - join, parallelFor, parallelReduce
- [Iterators API](03-api/02-iterators-api.md) - ParIter, find, predicates
- [SIMD API](03-api/03-simd-api.md) - sum, min, max, argmin
- [Sort API](03-api/04-sort-api.md) - sort, sortByKey, sortByCachedKey
- [Internal API](03-api/05-internal-api.md) - thresholds, splitters, RNG

### 4. Algorithms
- [Work Stealing](04-algorithms/01-work-stealing.md) - The core scheduling algorithm
- [Chase-Lev Deque](04-algorithms/02-chase-lev-deque.md) - Lock-free work-stealing deque
- [PDQSort](04-algorithms/03-pdqsort.md) - Pattern-defeating quicksort
- [SIMD Aggregations](04-algorithms/04-simd-aggregations.md) - Vectorized reductions
- [Parallel Reduction](04-algorithms/05-parallel-reduction.md) - Tree-based reduction
- [Adaptive Splitting](04-algorithms/06-adaptive-splitting.md) - Work division heuristics

### 5. Testing
- [Running Tests](05-testing/01-running-tests.md)
- [Benchmarking](05-testing/02-benchmarking.md)
- [Comparing with Rayon](05-testing/03-comparing-with-rayon.md)

### 6. Internals
- [Architecture](06-internals/01-architecture.md) - System design overview
- [Thread Pool](06-internals/02-thread-pool.md) - Worker management
- [Futures and Jobs](06-internals/03-futures-and-jobs.md) - Fork-join implementation
- [Synchronization](06-internals/04-synchronization.md) - Lock-free primitives

## Additional Resources

- [README](../README.md) - Project overview
- [BENCHMARKS](../BENCHMARKS.md) - Performance comparisons
- [Examples](../examples/) - Runnable example files

## Navigation

Each documentation file follows a consistent structure:
1. **Overview** - What this covers
2. **Basic Usage** - Simple examples
3. **Detailed Explanation** - How it works
4. **API Reference** - Function signatures
5. **Performance Notes** - When to use what

## Contributing

To add or update documentation:
1. Follow the existing structure
2. Use numbered prefixes for ordering (01-, 02-, etc.)
3. Include code examples with proper syntax highlighting
4. Add cross-references to related topics
