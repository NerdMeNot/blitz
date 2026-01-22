//! Blitz - Rayon-Style Lock-Free Work-Stealing Parallel Execution Library
//!
//! A high-performance parallel execution library following Rayon's proven design:
//! - Lock-free Chase-Lev work-stealing deques
//! - Zero-allocation fork-join with embedded latches
//! - Comptime-specialized Future(Input, Output)
//!
//! Performance (on 10-core system):
//! - Fork-join overhead: ~1-10 ns/fork at scale
//! - Deque push: ~40 ns (lock-free)
//! - Deque pop: ~1 ns (lock-free)
//! - Deque steal: ~4 ns (lock-free)
//! - 2M+ recursive forks in 1.4ms
//!
//! Key Design Principles (from Rayon):
//! - Jobs are stack-allocated in the owner's frame
//! - Chase-Lev deque provides instant visibility to thieves
//! - Latch embedded in Future eliminates allocation for local execution
//! - Progressive sleep: spin → yield → sleep for optimal latency/CPU balance
//!
//! Usage:
//! ```zig
//! const blitz = @import("blitz/mod.zig");
//!
//! // Initialize (optional - auto-inits on first use)
//! try blitz.init();
//! defer blitz.deinit();
//!
//! // Parallel for loop
//! blitz.parallelFor(1000, void, {}, struct {
//!     fn body(_: void, start: usize, end: usize) void {
//!         for (start..end) |i| { ... }
//!     }
//! }.body);
//!
//! // Parallel reduce
//! const sum = blitz.parallelReduce(f64, data.len, 0.0, slice, struct {
//!     fn map(s: []f64, i: usize) f64 { return s[i]; }
//! }.map, struct {
//!     fn combine(a: f64, b: f64) f64 { return a + b; }
//! }.combine);
//!
//! // Recursive divide-and-conquer (Rayon's strength)
//! fn parallelFib(n: u64) u64 {
//!     if (n < 20) return sequentialFib(n);
//!     const r = blitz.join(.{
//!         .a = .{ parallelFib, n - 2 },
//!         .b = .{ parallelFib, n - 1 },
//!     });
//!     return r.a + r.b;
//! }
//! ```

const std = @import("std");

// Core types
pub const Job = @import("job.zig").Job;

pub const OnceLatch = @import("latch.zig").OnceLatch;
pub const CountLatch = @import("latch.zig").CountLatch;
pub const SpinWait = @import("latch.zig").SpinWait;

pub const Worker = @import("worker.zig").Worker;
pub const Task = @import("worker.zig").Task;

pub const ThreadPool = @import("pool.zig").ThreadPool;
pub const ThreadPoolConfig = @import("pool.zig").ThreadPoolConfig;

pub const Future = @import("future.zig").Future;

// API functions
const api = @import("api.zig");

pub const init = api.init;
pub const initWithConfig = api.initWithConfig;
pub const deinit = api.deinit;
pub const isInitialized = api.isInitialized;
pub const numWorkers = api.numWorkers;

// Runtime configuration
pub const getGrainSize = api.getGrainSize;
pub const setGrainSize = api.setGrainSize;
pub const defaultGrainSize = api.defaultGrainSize;

pub const join = api.join;

// Error-safe join (task B always completes even if task A fails)
pub const tryJoin = api.tryJoin;

pub const parallelFor = api.parallelFor;
pub const parallelForWithGrain = api.parallelForWithGrain;

pub const parallelReduce = api.parallelReduce;
pub const parallelReduceWithGrain = api.parallelReduceWithGrain;
pub const parallelReduceChunked = api.parallelReduceChunked;

// Error-safe parallel iteration variants
pub const tryForEach = api.tryForEach;
pub const tryReduce = api.tryReduce;

// New Polars-parity functions
pub const parallelCollect = api.parallelCollect;
pub const parallelCollectWithGrain = api.parallelCollectWithGrain;
pub const parallelMapInPlace = api.parallelMapInPlace;
pub const parallelMapInPlaceWithGrain = api.parallelMapInPlaceWithGrain;

pub const parallelFlatten = api.parallelFlatten;
pub const parallelFlattenWithGrain = api.parallelFlattenWithGrain;
pub const parallelFlattenWithOffsets = api.parallelFlattenWithOffsets;

pub const parallelScatter = api.parallelScatter;

// Sync primitives for lock-free parallel writes
pub const SyncPtr = api.SyncPtr;
pub const computeOffsetsInto = api.computeOffsetsInto;
pub const capAndOffsets = api.capAndOffsets;

// Also export from sync module directly
const sync = @import("sync.zig");

// Threshold module for intelligent parallelism decisions
pub const threshold = @import("internal/threshold.zig");
pub const OpType = threshold.OpType;
pub const shouldParallelize = threshold.shouldParallelize;
pub const isMemoryBound = threshold.isMemoryBound;

// Worker count alias (for internal use)
pub const getWorkerCount = numWorkers;

// ============================================================================
// New Rayon-Parity Features
// ============================================================================

// Parallel iterators (Rayon-style composable iterators)
pub const iter_mod = @import("iter/mod.zig");
pub const iter = iter_mod.iter;
pub const iterMut = iter_mod.iterMut;
pub const range = iter_mod.range;
pub const ParIter = iter_mod.ParIter;
pub const ParIterMut = iter_mod.ParIterMut;
pub const RangeIter = iter_mod.RangeIter;

// Scope-based parallelism (spawn arbitrary tasks)
pub const scope_mod = @import("scope.zig");
pub const scope = scope_mod.scope;
pub const scopeWithContext = scope_mod.scopeWithContext;
pub const Scope = scope_mod.Scope;
pub const parallelForRange = scope_mod.parallelForRange;
pub const parallelForRangeWithContext = scope_mod.parallelForRangeWithContext;

// Fire-and-forget spawn
pub const spawn = scope_mod.spawn;
pub const spawnWithContext = scope_mod.spawnWithContext;

// Broadcast (execute on all workers)
pub const broadcast = scope_mod.broadcast;
pub const broadcastWithContext = scope_mod.broadcastWithContext;

// Parallel algorithms
pub const algorithms = @import("algorithms.zig");
pub const parallelSort = algorithms.parallelSort;
pub const parallelSortBy = algorithms.parallelSortBy;
pub const parallelScan = algorithms.parallelScan;
pub const parallelScanExclusive = algorithms.parallelScanExclusive;
pub const parallelFind = algorithms.parallelFind;
pub const parallelFindValue = algorithms.parallelFindValue;
pub const parallelPartition = algorithms.parallelPartition;

// SIMD-optimized aggregations (parallel + vectorized)
pub const simd_mod = @import("simd/mod.zig");
pub const simdSum = simd_mod.sum;
pub const simdMin = simd_mod.min;
pub const simdMax = simd_mod.max;

// SIMD parallel threshold (dynamic calculation based on worker count and operation cost)
pub const calculateParallelThreshold = simd_mod.calculateParallelThreshold;
pub const shouldParallelizeSimd = simd_mod.shouldParallelizeSimd;
pub const getParallelThreshold = simd_mod.getParallelThreshold;

// ============================================================================
// Convenience Functions (Rayon-style simple API)
// ============================================================================

/// Parallel sum of all elements. Uses SIMD + multi-threading.
pub fn parallelSum(comptime T: type, data: []const T) T {
    return simd_mod.parallelSum(T, data);
}

/// Parallel minimum. Returns null for empty slices.
pub fn parallelMin(comptime T: type, data: []const T) ?T {
    return simd_mod.parallelMin(T, data);
}

/// Parallel maximum. Returns null for empty slices.
pub fn parallelMax(comptime T: type, data: []const T) ?T {
    return simd_mod.parallelMax(T, data);
}

/// Check if any element satisfies the predicate (parallel with early exit).
pub fn parallelAny(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    return iter_mod.iter(T, data).any(pred);
}

/// Check if all elements satisfy the predicate (parallel with early exit).
pub fn parallelAll(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    return iter_mod.iter(T, data).all(pred);
}

/// Find any element satisfying the predicate (non-deterministic).
pub fn parallelFindAny(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?T {
    return iter_mod.iter(T, data).findAny(pred);
}

/// Execute a function for each element in parallel.
pub fn parallelForEach(comptime T: type, data: []const T, comptime func: fn (T) void) void {
    iter_mod.iter(T, data).forEach(func);
}

/// Transform each element in-place in parallel.
pub fn parallelMap(comptime T: type, data: []T, comptime func: fn (T) T) void {
    iter_mod.iterMut(T, data).mapInPlace(func);
}

/// Fill a slice with a value in parallel.
pub fn parallelFill(comptime T: type, data: []T, value: T) void {
    iter_mod.iterMut(T, data).fill(value);
}

// Adaptive splitting (Phase 2)
pub const splitter_mod = @import("internal/splitter.zig");
pub const Splitter = splitter_mod.Splitter;
pub const LengthSplitter = splitter_mod.LengthSplitter;

// Lock-free primitives (Phase 3)
pub const Deque = @import("deque.zig").Deque;
pub const XorShift64Star = @import("internal/rng.zig").XorShift64Star;

// ============================================================================
// Tests
// ============================================================================

test "blitz - all modules compile" {
    _ = @import("job.zig");
    _ = @import("latch.zig");
    _ = @import("future.zig");
    _ = @import("worker.zig");
    _ = @import("pool.zig");
    _ = @import("api.zig");
    _ = @import("sync.zig");
    _ = @import("scope.zig");
    _ = @import("algorithms.zig");
    _ = @import("deque.zig");
    // Modular imports
    _ = @import("internal/mod.zig");
    _ = @import("iter/mod.zig");
    _ = @import("simd/mod.zig");
    _ = @import("sort/mod.zig");
    // Stress tests
    _ = @import("stress_tests.zig");
}

test "blitz - basic parallel for" {
    var results: [100]u32 = undefined;
    @memset(&results, 0);

    const Context = struct { results: []u32 };
    const ctx = Context{ .results = &results };

    parallelFor(100, Context, ctx, struct {
        fn body(c: Context, start: usize, end: usize) void {
            for (start..end) |i| {
                c.results[i] = @intCast(i * 2);
            }
        }
    }.body);

    for (results, 0..) |v, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 2)), v);
    }
}

test "blitz - basic parallel reduce" {
    const n: usize = 100;
    const expected: i64 = @as(i64, @intCast(n * (n - 1) / 2));

    const result = parallelReduce(
        i64,
        n,
        0,
        void,
        {},
        struct {
            fn map(_: void, i: usize) i64 {
                return @intCast(i);
            }
        }.map,
        struct {
            fn combine(a: i64, b: i64) i64 {
                return a + b;
            }
        }.combine,
    );

    try std.testing.expectEqual(expected, result);
}
