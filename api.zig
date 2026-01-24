//! High-Level API for Blitz - Rayon-style Work Stealing
//!
//! This module provides ergonomic parallel primitives built on top of
//! the lock-free work-stealing runtime (following Rayon's proven design).
//!
//! Key functions:
//! - join(): Fork-join two tasks with return values
//! - parallelFor(): Parallel iteration over a range (auto-tuning)
//! - parallelForWithGrain(): Parallel iteration with manual grain size
//! - parallelReduce(): Parallel map-reduce with associative combine
//!
//! Both auto-tuning and manual-grain APIs are available. Use auto-tuning
//! for most cases; use manual grain for fine-tuned performance control.

const std = @import("std");

// ============================================================================
// Internal Module Imports
// ============================================================================

const pool_mod = @import("pool.zig");
const sync = @import("sync.zig");

// Operations modules
const runtime = @import("ops/runtime.zig");
const parallel_for = @import("ops/parallel_for.zig");
const parallel_reduce = @import("ops/parallel_reduce.zig");
const collect = @import("ops/collect.zig");
const join_mod = @import("ops/join.zig");
const try_join_mod = @import("ops/try_join.zig");
const try_ops = @import("ops/try_ops.zig");

// ============================================================================
// Public Type Exports
// ============================================================================

pub const Job = pool_mod.Job;
pub const Worker = pool_mod.Worker;
pub const Task = pool_mod.Task;
pub const ThreadPool = pool_mod.ThreadPool;
pub const ThreadPoolConfig = pool_mod.ThreadPoolConfig;

pub const SyncPtr = sync.SyncPtr;
pub const computeOffsetsInto = sync.computeOffsetsInto;
pub const capAndOffsets = sync.capAndOffsets;

/// Parallel sorting algorithms.
const sort_impl = @import("sort/sort.zig");
pub const sort_mod = sort_impl;

/// Parallel iterators.
pub const iter_mod = @import("iter/iter.zig");

/// SIMD operations.
pub const simd_mod = @import("simd/simd.zig");

/// Internal utilities (threshold, splitter, rng).
pub const internal = @import("internal/internal.zig");

// ============================================================================
// Runtime Configuration (re-exports from ops/runtime.zig)
// ============================================================================

/// Default grain size - minimum work per task.
pub const DEFAULT_GRAIN_SIZE = runtime.DEFAULT_GRAIN_SIZE;

/// Get the current grain size (runtime-configurable).
pub const getGrainSize = runtime.getGrainSize;

/// Set the grain size for parallel operations.
pub const setGrainSize = runtime.setGrainSize;

/// Get the default grain size (compile-time constant).
pub const defaultGrainSize = runtime.defaultGrainSize;

// ============================================================================
// Global Pool Management (re-exports from ops/runtime.zig)
// ============================================================================

/// Thread-local task context for fast recursive calls.
/// Access via ops/runtime.zig directly for read/write.
/// (Threadlocal variables cannot be re-exported as pointers.)
/// Initialize the global thread pool.
pub const init = runtime.init;

/// Initialize with custom configuration.
pub const initWithConfig = runtime.initWithConfig;

/// Shutdown the global thread pool.
pub const deinit = runtime.deinit;

/// Check if the pool is initialized.
pub const isInitialized = runtime.isInitialized;

/// Get the number of worker threads.
pub const numWorkers = runtime.numWorkers;

/// Pool stats for debugging.
pub const PoolStats = runtime.PoolStats;

/// Get pool stats (executed, stolen) for debugging.
pub const getStats = runtime.getStats;

/// Reset pool stats.
pub const resetStats = runtime.resetStats;

// ============================================================================
// Parallel For Operations (re-exports from ops/parallel_for.zig)
// ============================================================================

/// Execute a function over range [0, n) with automatic parallelization.
pub const parallelFor = parallel_for.parallelFor;

/// Execute a function over range [0, n) with custom grain size.
pub const parallelForWithGrain = parallel_for.parallelForWithGrain;

/// Parallel for with early exit capability.
pub const parallelForWithEarlyExit = parallel_for.parallelForWithEarlyExit;

// ============================================================================
// Parallel Reduce Operations (re-exports from ops/parallel_reduce.zig)
// ============================================================================

/// Parallel reduction with associative combine function.
pub const parallelReduce = parallel_reduce.parallelReduce;

/// Parallel reduction with custom grain size.
pub const parallelReduceWithGrain = parallel_reduce.parallelReduceWithGrain;

/// Parallel reduction using a chunk-based map function (for SIMD).
pub const parallelReduceChunked = parallel_reduce.parallelReduceChunked;

// ============================================================================
// Collection Operations (re-exports from ops/collect.zig)
// ============================================================================

/// Parallel map that collects results into an output slice.
pub const parallelCollect = collect.parallelCollect;

/// Parallel map with custom grain size.
pub const parallelCollectWithGrain = collect.parallelCollectWithGrain;

/// Parallel map in-place: transform elements without allocating.
pub const parallelMapInPlace = collect.parallelMapInPlace;

/// Parallel map in-place with custom grain size.
pub const parallelMapInPlaceWithGrain = collect.parallelMapInPlaceWithGrain;

/// Flatten nested slices into a single output slice in parallel.
pub const parallelFlatten = collect.parallelFlatten;

/// Parallel flatten with custom grain size.
pub const parallelFlattenWithGrain = collect.parallelFlattenWithGrain;

/// Flatten with pre-computed offsets.
pub const parallelFlattenWithOffsets = collect.parallelFlattenWithOffsets;

/// Scatter values to output using pre-computed offsets.
pub const parallelScatter = collect.parallelScatter;

// ============================================================================
// Join Operations (re-exports from ops/join.zig)
// ============================================================================

/// Execute N tasks in parallel with heterogeneous return types.
pub const join = join_mod.join;

// ============================================================================
// Error-Safe Join Operations (re-exports from ops/try_join.zig)
// ============================================================================

/// Execute N error-returning tasks in parallel with error safety.
pub const tryJoin = try_join_mod.tryJoin;

// ============================================================================
// Error-Safe Parallel Operations (re-exports from ops/try_ops.zig)
// ============================================================================

/// Execute a fallible function over range [0, n) with automatic parallelization.
pub const tryForEach = try_ops.tryForEach;

/// Parallel reduction with error handling.
pub const tryReduce = try_ops.tryReduce;

// ============================================================================
// Parallel Sorting (re-exports from sort/sort.zig)
// ============================================================================

/// Sort a slice in-place using parallel unstable sort.
pub fn sort(comptime T: type, v: []T, comptime is_less: fn (T, T) bool) void {
    sort_impl.sort(T, v, is_less);
}

/// Sort a slice in ascending order.
pub fn sortAsc(comptime T: type, v: []T) void {
    sort_impl.sortAsc(T, v);
}

/// Sort a slice in descending order.
pub fn sortDesc(comptime T: type, v: []T) void {
    sort_impl.sortDesc(T, v);
}

/// Sort by a key extraction function.
pub fn sortByKey(
    comptime T: type,
    comptime K: type,
    v: []T,
    comptime key_fn: fn (T) K,
) void {
    sort_impl.sortByKey(T, K, v, key_fn);
}

/// Sort by key with parallel key caching.
pub fn sortByCachedKey(
    comptime T: type,
    comptime K: type,
    allocator: std.mem.Allocator,
    v: []T,
    comptime key_fn: fn (T) K,
) !void {
    return sort_impl.sortByCachedKey(T, K, allocator, v, key_fn);
}

// ============================================================================
// Tests
// ============================================================================

test {
    // Operations tests (each module has its own tests)
    _ = @import("ops/runtime.zig");
    _ = @import("ops/parallel_for.zig");
    _ = @import("ops/parallel_reduce.zig");
    _ = @import("ops/collect.zig");
    _ = @import("ops/join.zig");
    _ = @import("ops/try_join.zig");
    _ = @import("ops/try_ops.zig");

    // Sort module tests
    _ = @import("sort/tests.zig");

    // Iterator module tests
    _ = @import("iter/tests.zig");

    // SIMD module tests
    _ = @import("simd/tests.zig");

    // Internal module tests
    _ = @import("internal/internal.zig");
}
