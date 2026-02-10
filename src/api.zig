//! High-Level API for Blitz
//!
//! This module provides ergonomic parallel primitives built on top of
//! the lock-free work-stealing runtime.
//!
//! ## API Tiers
//!
//! **Core (start here — covers 95% of use cases):**
//! - `join()`              — Fork-join N tasks with heterogeneous return types
//! - `parallelFor()`       — Parallel loop over [0, n) with adaptive splitting
//! - `parallelReduce()`    — Parallel map-reduce with associative combine
//! - `parallelCollect()`   — Parallel map collecting results into a slice
//! - `parallelMapInPlace()` — Transform elements in-place in parallel
//!
//! **Advanced tuning (manual grain size control):**
//! - `parallelForWithGrain()`, `parallelReduceWithGrain()`
//! - `parallelCollectWithGrain()`, `parallelMapInPlaceWithGrain()`
//! - `parallelFlattenWithGrain()`
//!
//! **Specialized operations:**
//! - `parallelForWithEarlyExit()` — Loop with cancellation flag
//! - `parallelReduceChunked()`    — SIMD-friendly range-based reduction
//! - `parallelFlatten()` / `parallelFlattenWithOffsets()` — Nested slice flattening
//! - `parallelScatter()` — Scatter values using pre-computed offsets
//!
//! **Error-safe variants (for fallible operations):**
//! - `tryJoin()`, `tryForEach()`, `tryReduce()`
//!
//! **Sorting:**
//! - `sort()`, `sortAsc()`, `sortDesc()`, `sortByKey()`, `sortByCachedKey()`
//!
//! Use the auto-tuning (no `WithGrain`) variants for most cases.
//! Only reach for `WithGrain` when profiling shows the default splitting is suboptimal.

const std = @import("std");

// ============================================================================
// Internal Module Imports
// ============================================================================

const pool_mod = @import("Pool.zig");
const sync = @import("Sync.zig");

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
pub const iter = iter_mod.iter;
pub const iterMut = iter_mod.iterMut;
pub const range = iter_mod.range;

/// Internal utilities (threshold, splitter, rng).
pub const internal = @import("internal/internal.zig");

// ============================================================================
// Runtime Configuration (re-exports from ops/runtime.zig)
// ============================================================================

/// Default grain size (65536) — the minimum number of elements per parallel task.
///
/// When a parallel operation (parallelFor, parallelReduce, etc.) is called,
/// the work is split into chunks. If a chunk has fewer elements than the grain
/// size, it executes sequentially rather than spawning further parallel tasks.
///
/// Tuning guidance:
/// - Larger grain size = fewer tasks, less overhead, less parallelism
/// - Smaller grain size = more tasks, more overhead, more parallelism
/// - The default (65536) works well for lightweight per-element work
/// - For expensive per-element work (e.g. 1ms+ per element), use a smaller
///   grain size (e.g. 100-1000) via parallelForWithGrain or setGrainSize
/// - Setting grain_size=1 is a footgun: fork/join overhead will dominate
pub const DEFAULT_GRAIN_SIZE = runtime.DEFAULT_GRAIN_SIZE;

/// Get the current grain size (runtime-configurable).
pub const getGrainSize = runtime.getGrainSize;

/// Set the grain size for all parallel operations.
/// Pass 0 to reset to the default (65536).
pub const setGrainSize = runtime.setGrainSize;

/// Get the default grain size (compile-time constant, 65536).
pub const defaultGrainSize = runtime.defaultGrainSize;

// ============================================================================
// Global Pool Management (re-exports from ops/runtime.zig)
// ============================================================================

/// Initialize the global thread pool with default configuration.
///
/// Must be called before using any parallel operations. Without this,
/// all parallel operations execute sequentially as a fallback.
/// Use `defer blitz.deinit()` immediately after to ensure cleanup.
///
/// ```zig
/// try blitz.init();
/// defer blitz.deinit();
/// ```
pub const init = runtime.init;

/// Initialize with custom configuration (e.g. worker count).
///
/// Returns error.AlreadyInitialized if called more than once.
/// Call deinit() first if you need to re-initialize with different settings.
pub const initWithConfig = runtime.initWithConfig;

/// Shutdown the global thread pool and free all resources.
///
/// All worker threads are joined before returning. After this call,
/// parallel operations will execute sequentially until init() is called again.
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
// Core Parallel Primitives (start here)
// ============================================================================

/// Execute N tasks in parallel with heterogeneous return types.
///
/// The primary fork-join primitive. Accepts a struct of functions (with
/// optional arguments) and returns a struct of their results.
/// ```zig
/// const r = blitz.join(.{
///     .sum = computeSum,
///     .max = .{ computeMax, data },  // with argument
/// });
/// // r.sum, r.max
/// ```
pub const join = join_mod.join;

/// Execute a function over range [0, n) with automatic parallelization.
pub const parallelFor = parallel_for.parallelFor;

/// Parallel reduction with associative combine function.
pub const parallelReduce = parallel_reduce.parallelReduce;

/// Parallel map that collects results into an output slice.
pub const parallelCollect = collect.parallelCollect;

/// Parallel map in-place: transform elements without allocating.
pub const parallelMapInPlace = collect.parallelMapInPlace;

/// Flatten nested slices into a single output slice in parallel.
pub const parallelFlatten = collect.parallelFlatten;

/// Scatter values to output using pre-computed offsets.
pub const parallelScatter = collect.parallelScatter;

// ============================================================================
// Advanced Tuning (manual grain size control)
// ============================================================================

/// Execute a function over range [0, n) with custom grain size.
pub const parallelForWithGrain = parallel_for.parallelForWithGrain;

/// Parallel reduction with custom grain size.
pub const parallelReduceWithGrain = parallel_reduce.parallelReduceWithGrain;

/// Parallel map with custom grain size.
pub const parallelCollectWithGrain = collect.parallelCollectWithGrain;

/// Parallel map in-place with custom grain size.
pub const parallelMapInPlaceWithGrain = collect.parallelMapInPlaceWithGrain;

/// Parallel flatten with custom grain size.
pub const parallelFlattenWithGrain = collect.parallelFlattenWithGrain;

// ============================================================================
// Specialized Operations
// ============================================================================

/// Parallel for with early exit capability.
pub const parallelForWithEarlyExit = parallel_for.parallelForWithEarlyExit;

/// Parallel reduction using a chunk-based map function (for SIMD).
pub const parallelReduceChunked = parallel_reduce.parallelReduceChunked;

/// Flatten with pre-computed offsets (reuse offset computation across calls).
pub const parallelFlattenWithOffsets = collect.parallelFlattenWithOffsets;

// ============================================================================
// Error-Safe Variants (all tasks complete even if some fail)
// ============================================================================

/// Execute N error-returning tasks in parallel with error safety.
/// All tasks are guaranteed to complete before any error propagates.
pub const tryJoin = try_join_mod.tryJoin;

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

    // Internal module tests
    _ = @import("internal/internal.zig");
}
