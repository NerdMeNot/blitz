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
const Job = @import("job.zig").Job;
const Future = @import("future.zig").Future;
const Worker = @import("worker.zig").Worker;
const Task = @import("worker.zig").Task;
const ThreadPool = @import("pool.zig").ThreadPool;
const ThreadPoolConfig = @import("pool.zig").ThreadPoolConfig;
const sync = @import("sync.zig");
pub const SyncPtr = sync.SyncPtr;
pub const computeOffsetsInto = sync.computeOffsetsInto;
pub const capAndOffsets = sync.capAndOffsets;

/// Parallel sorting algorithms.
const sort_impl = @import("sort/mod.zig");
pub const sort_mod = sort_impl;

/// Parallel iterators.
pub const iter_mod = @import("iter/mod.zig");

/// SIMD operations.
pub const simd_mod = @import("simd/mod.zig");

/// Internal utilities (threshold, splitter, rng).
pub const internal = @import("internal/mod.zig");

/// Default grain size - minimum work per task.
/// Below this, we don't parallelize to avoid overhead.
/// Set high enough that parallelism overhead is amortized for simple operations.
const DEFAULT_GRAIN_SIZE: usize = 65536;

// ============================================================================
// Runtime Configuration
// ============================================================================

/// Runtime-configurable grain size. Defaults to DEFAULT_GRAIN_SIZE.
/// Uses atomic for thread-safe access.
var configured_grain_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(DEFAULT_GRAIN_SIZE);

/// Get the current grain size (runtime-configurable).
pub fn getGrainSize() usize {
    return configured_grain_size.load(.monotonic);
}

/// Set the grain size for parallel operations.
/// This affects all subsequent parallel operations.
/// Pass 0 to reset to the default value.
pub fn setGrainSize(size: usize) void {
    const value = if (size == 0) DEFAULT_GRAIN_SIZE else size;
    configured_grain_size.store(value, .monotonic);
}

/// Get the default grain size (compile-time constant).
pub fn defaultGrainSize() usize {
    return DEFAULT_GRAIN_SIZE;
}

// ============================================================================
// Global Pool Management
// ============================================================================

var global_pool: ?*ThreadPool = null;
var pool_mutex: std.Thread.Mutex = .{};
var pool_allocator: std.mem.Allocator = undefined;

/// Atomic flag for fast isInitialized() check (avoids lock in hot path).
var pool_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Cached worker count (set once at init, read without lock).
var cached_num_workers: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

/// Thread-local task context for fast recursive calls.
/// When set, we're already inside a pool.call() and can use fork/join directly.
/// Public so that Future's handler can set it for stolen jobs.
pub threadlocal var current_task: ?*Task = null;

/// Initialize the global thread pool.
pub fn init() !void {
    return initWithConfig(.{});
}

/// Initialize with custom configuration.
pub fn initWithConfig(config: ThreadPoolConfig) !void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool != null) return;

    pool_allocator = std.heap.c_allocator;
    const pool = try pool_allocator.create(ThreadPool);
    pool.* = ThreadPool.init(pool_allocator);
    pool.start(config);
    global_pool = pool;

    // Set atomic flags for lock-free access
    cached_num_workers.store(@intCast(pool.numWorkers()), .release);
    pool_initialized.store(true, .release);
}

/// Shutdown the global thread pool.
pub fn deinit() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |pool| {
        // Clear atomic flags first (stops new work from being submitted)
        pool_initialized.store(false, .release);
        cached_num_workers.store(1, .release);

        pool.deinit();
        pool_allocator.destroy(pool);
        global_pool = null;
    }
}

/// Check if the pool is initialized.
/// Uses atomic flag for lock-free fast path.
pub inline fn isInitialized() bool {
    return pool_initialized.load(.acquire);
}

/// Get the number of worker threads.
/// Uses cached value for lock-free access in hot paths.
pub inline fn numWorkers() u32 {
    return cached_num_workers.load(.monotonic);
}

/// Pool stats for debugging.
pub const PoolStats = struct { executed: u64, stolen: u64 };

/// Get pool stats (executed, stolen) for debugging.
pub fn getStats() PoolStats {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |pool| {
        const s = pool.getStats();
        return .{ .executed = s.executed, .stolen = s.stolen };
    }
    return .{ .executed = 0, .stolen = 0 };
}

/// Reset pool stats.
pub fn resetStats() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |pool| {
        pool.resetStats();
    }
}

/// Get the global pool, auto-initializing if needed.
fn getPool() ?*ThreadPool {
    // Fast path: check atomic flag first (no lock)
    if (pool_initialized.load(.acquire)) {
        return global_pool;
    }

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |pool| {
        return pool;
    }

    // Auto-initialize
    pool_allocator = std.heap.c_allocator;
    const pool = pool_allocator.create(ThreadPool) catch return null;
    pool.* = ThreadPool.init(pool_allocator);
    pool.start(.{});
    global_pool = pool;

    // Set atomic flags
    cached_num_workers.store(@intCast(pool.numWorkers()), .release);
    pool_initialized.store(true, .release);

    return pool;
}

// ============================================================================
// join() - Fork-Join with Return Values
// ============================================================================

/// Execute two tasks potentially in parallel, returning both results.
///
/// The second task is pushed to the local queue where other workers can steal it,
/// while the first task is executed immediately. This enables recursive
/// divide-and-conquer algorithms.
///
/// Returns a tuple with results from both functions.
pub fn join(
    comptime RA: type,
    comptime RB: type,
    comptime fn_a: anytype,
    comptime fn_b: anytype,
    arg_a: anytype,
    arg_b: anytype,
) struct { RA, RB } {
    const ArgA = @TypeOf(arg_a);
    const ArgB = @TypeOf(arg_b);

    // Wrapper functions with correct signature
    const wrapper_a = struct {
        fn call(task: *Task, arg: ArgA) RA {
            _ = task;
            return @call(.auto, fn_a, .{arg});
        }
    }.call;

    const wrapper_b = struct {
        fn call(task: *Task, arg: ArgB) RB {
            _ = task;
            return @call(.auto, fn_b, .{arg});
        }
    }.call;

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (current_task) |task| {
        var future_b = Future(ArgB, RB).init();
        future_b.fork(task, wrapper_b, arg_b);

        const result_a = task.call(RA, wrapper_a, arg_a);
        const result_b = future_b.join(task) orelse wrapper_b(task, arg_b);

        return .{ result_a, result_b };
    }

    // Get pool or fallback to sequential
    const pool = getPool() orelse {
        const result_a = fn_a(arg_a);
        const result_b = fn_b(arg_b);
        return .{ result_a, result_b };
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(struct { RA, RB }, struct {
        fn compute(task: *Task, args: struct { ArgA, ArgB }) struct { RA, RB } {
            // Set thread-local context for nested calls
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            var future_b = Future(ArgB, RB).init();
            future_b.fork(task, wrapper_b, args[1]);

            const result_a = task.call(RA, wrapper_a, args[0]);
            const result_b = future_b.join(task) orelse wrapper_b(task, args[1]);

            return .{ result_a, result_b };
        }
    }.compute, .{ arg_a, arg_b });
}

/// Execute two void tasks potentially in parallel.
pub fn joinVoid(
    comptime fn_a: anytype,
    comptime fn_b: anytype,
    arg_a: anytype,
    arg_b: anytype,
) void {
    _ = join(void, void, fn_a, fn_b, arg_a, arg_b);
}

// ============================================================================
// Error-Safe Join Variants
// ============================================================================
//
// These variants ensure that job B completes even if job A returns an error.
// This is critical for safety because job B may reference data in the caller's
// stack frame (via closures). If we propagate job A's error without waiting
// for job B, the stack frame could be invalidated while job B is still running.
//
// This mirrors Rayon's panic safety: "No matter what happens, both closures
// will always be executed."
//
// Note on Zig panics: Unlike Rust, Zig panics are terminal and cannot be
// caught. This error safety only applies to recoverable errors (error unions).
// If a function calls @panic, the program will terminate regardless.
// ============================================================================

/// Execute two error-returning tasks potentially in parallel, with error safety.
///
/// If function A returns an error, this function will STILL wait for function B
/// to complete before propagating the error. This ensures B doesn't access
/// invalidated stack frames.
///
/// Both functions must return error unions. For non-error functions, use join().
///
/// Returns:
/// - On success: .{ result_a, result_b }
/// - On error from A: error (after B completes)
/// - On error from B: error (A's result is discarded)
/// - On both error: error from A (B's error is discarded, following Rayon's behavior)
pub fn tryJoin(
    comptime RA: type,
    comptime RB: type,
    comptime E: type,
    comptime fn_a: anytype,
    comptime fn_b: anytype,
    arg_a: anytype,
    arg_b: anytype,
) E!struct { RA, RB } {
    const ArgA = @TypeOf(arg_a);
    const ArgB = @TypeOf(arg_b);

    // Wrapper functions with correct signature
    const wrapper_a = struct {
        fn call(task: *Task, arg: ArgA) E!RA {
            _ = task;
            return @call(.auto, fn_a, .{arg});
        }
    }.call;

    const wrapper_b = struct {
        fn call(task: *Task, arg: ArgB) E!RB {
            _ = task;
            return @call(.auto, fn_b, .{arg});
        }
    }.call;

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (current_task) |task| {
        return tryJoinImpl(RA, RB, E, ArgA, ArgB, wrapper_a, wrapper_b, arg_a, arg_b, task);
    }

    // Get pool or fallback to sequential
    const pool = getPool() orelse {
        const result_a = try fn_a(arg_a);
        const result_b = try fn_b(arg_b);
        return .{ result_a, result_b };
    };

    // Slow path: create a new worker context via pool.call()
    const Args = struct { ArgA, ArgB };
    return pool.call(E!struct { RA, RB }, struct {
        fn compute(task: *Task, args: Args) E!struct { RA, RB } {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            return tryJoinImpl(RA, RB, E, ArgA, ArgB, wrapper_a, wrapper_b, args[0], args[1], task);
        }
    }.compute, .{ arg_a, arg_b });
}

/// Implementation of tryJoin with error safety
fn tryJoinImpl(
    comptime RA: type,
    comptime RB: type,
    comptime E: type,
    comptime ArgA: type,
    comptime ArgB: type,
    comptime wrapper_a: fn (*Task, ArgA) E!RA,
    comptime wrapper_b: fn (*Task, ArgB) E!RB,
    arg_a: ArgA,
    arg_b: ArgB,
    task: *Task,
) E!struct { RA, RB } {
    var future_b = Future(ArgB, E!RB).init();
    future_b.fork(task, wrapper_b, arg_b);

    // Store any error from A so we can propagate it after B completes
    var error_a: ?E = null;
    var result_a: RA = undefined;

    // Execute A - capture any error
    if (task.call(E!RA, wrapper_a, arg_a)) |ra| {
        result_a = ra;
    } else |err| {
        error_a = err;
    }

    // CRITICAL: Always wait for B to complete, even if A errored.
    // This is the key safety guarantee - B may reference our stack frame.
    const result_b_or_null = future_b.join(task);
    const result_b_union: E!RB = result_b_or_null orelse wrapper_b(task, arg_b);

    // Now handle errors - A's error takes priority (following Rayon)
    if (error_a) |err| {
        return err;
    }

    // Check B's result
    const result_b = try result_b_union;

    return .{ result_a, result_b };
}

/// Execute two void error-returning tasks potentially in parallel, with error safety.
///
/// If function A returns an error, waits for B to complete before propagating.
pub fn tryJoinVoid(
    comptime E: type,
    comptime fn_a: anytype,
    comptime fn_b: anytype,
    arg_a: anytype,
    arg_b: anytype,
) E!void {
    const result = try tryJoin(void, void, E, fn_a, fn_b, arg_a, arg_b);
    _ = result;
}

// ============================================================================
// tryForEach() - Error-Safe Parallel Iteration
// ============================================================================

/// Execute a fallible function over range [0, n) with automatic parallelization.
///
/// Like parallelFor(), but the body function can return an error.
/// If any chunk returns an error, all other chunks are allowed to complete
/// before the error is propagated. This ensures parallel work doesn't access
/// invalidated stack frames.
///
/// Returns the first error encountered (in execution order, not index order).
///
/// Example:
/// ```zig
/// const result = blitz.tryForEach(data.len, E, Context, ctx, struct {
///     fn body(c: Context, start: usize, end: usize) E!void {
///         for (start..end) |i| {
///             try processItem(c.data[i]);
///         }
///     }
/// }.body);
/// ```
pub fn tryForEach(
    n: usize,
    comptime E: type,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) E!void,
) E!void {
    if (n == 0) return;

    if (!isInitialized()) {
        return body_fn(context, 0, n);
    }

    // Create adaptive splitter
    const split = LengthSplitter.initDefault(n);

    // Fast path: if we're already inside a pool context
    if (current_task) |task| {
        return tryForEachAdaptive(E, Context, context, body_fn, 0, n, split, task);
    }

    const pool = getPool() orelse {
        return body_fn(context, 0, n);
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(E!void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, LengthSplitter }) E!void {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            return tryForEachAdaptive(E, Context, args[0], body_fn, args[1], args[2], args[3], task);
        }
    }.compute, .{ context, 0, n, split });
}

/// Adaptive tryForEach implementation using LengthSplitter.
fn tryForEachAdaptive(
    comptime E: type,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) E!void,
    start: usize,
    end: usize,
    split: LengthSplitter,
    task: *Task,
) E!void {
    const len = end - start;

    // Let the splitter decide: should we split or execute sequentially?
    var mutable_split = split;
    if (!mutable_split.trySplit(len)) {
        // Base case: execute sequentially
        return body_fn(context, start, end);
    }

    const mid = start + len / 2;

    // Clone splitter for the forked task
    const right_split = mutable_split.clone();

    // Type for the right task's result
    const RightArgs = struct { Context, usize, usize, LengthSplitter };

    var future_right = Future(RightArgs, E!void).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: RightArgs) E!void {
            return tryForEachAdaptive(E, Context, args[0], body_fn, args[1], args[2], args[3], t);
        }
    }.call, .{ context, mid, end, right_split });

    // Execute left half - capture any error
    var error_left: ?E = null;
    if (tryForEachAdaptive(E, Context, context, body_fn, start, mid, mutable_split, task)) |_| {
        // Left succeeded
    } else |err| {
        error_left = err;
    }

    // CRITICAL: Always wait for right to complete, even if left errored
    const result_right_or_null = future_right.join(task);
    const result_right: E!void = result_right_or_null orelse
        tryForEachAdaptive(E, Context, context, body_fn, mid, end, right_split, task);

    // Propagate errors - left takes priority
    if (error_left) |err| {
        return err;
    }

    return result_right;
}

// ============================================================================
// tryReduce() - Error-Safe Parallel Reduction
// ============================================================================

/// Parallel reduction with error handling.
///
/// Like parallelReduce(), but the map function can return an error.
/// All parallel work completes before any error is propagated.
///
/// Example:
/// ```zig
/// const result = try blitz.tryReduce(
///     i64,
///     E,
///     data.len,
///     0,
///     Context,
///     ctx,
///     struct {
///         fn map(c: Context, i: usize) E!i64 {
///             return try parseValue(c.data[i]);
///         }
///     }.map,
///     struct {
///         fn combine(a: i64, b: i64) i64 {
///             return a + b;
///         }
///     }.combine,
/// );
/// ```
pub fn tryReduce(
    comptime T: type,
    comptime E: type,
    n: usize,
    identity: T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize) E!T,
    comptime combine_fn: fn (T, T) T,
) E!T {
    if (n == 0) return identity;

    if (!isInitialized()) {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, try map_fn(context, i));
        }
        return result;
    }

    // Create adaptive splitter
    const split = LengthSplitter.initDefault(n);

    // Fast path: if we're already inside a pool context
    if (current_task) |task| {
        return tryReduceAdaptive(T, E, Context, context, map_fn, combine_fn, identity, 0, n, split, task);
    }

    const pool = getPool() orelse {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, try map_fn(context, i));
        }
        return result;
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(E!T, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, T, LengthSplitter }) E!T {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            return tryReduceAdaptive(T, E, Context, args[0], map_fn, combine_fn, args[3], args[1], args[2], args[4], task);
        }
    }.compute, .{ context, 0, n, identity, split });
}

/// Adaptive tryReduce implementation using LengthSplitter.
fn tryReduceAdaptive(
    comptime T: type,
    comptime E: type,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize) E!T,
    comptime combine_fn: fn (T, T) T,
    identity: T,
    start: usize,
    end: usize,
    split: LengthSplitter,
    task: *Task,
) E!T {
    const len = end - start;

    // Let the splitter decide: should we split or execute sequentially?
    var mutable_split = split;
    if (!mutable_split.trySplit(len)) {
        // Base case: execute sequentially
        var result = identity;
        for (start..end) |i| {
            result = combine_fn(result, try map_fn(context, i));
        }
        return result;
    }

    const mid = start + len / 2;

    // Clone splitter for the forked task
    const right_split = mutable_split.clone();

    // Type for the right task
    const Args = struct { Context, usize, usize, T, LengthSplitter };

    var future_right = Future(Args, E!T).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: Args) E!T {
            return tryReduceAdaptive(T, E, Context, args[0], map_fn, combine_fn, args[3], args[1], args[2], args[4], t);
        }
    }.call, .{ context, mid, end, identity, right_split });

    // Execute left half - capture result or error
    var error_left: ?E = null;
    var result_left: T = identity;
    if (tryReduceAdaptive(T, E, Context, context, map_fn, combine_fn, identity, start, mid, mutable_split, task)) |left| {
        result_left = left;
    } else |err| {
        error_left = err;
    }

    // CRITICAL: Always wait for right to complete, even if left errored
    const result_right_or_null = future_right.join(task);
    const result_right_union: E!T = result_right_or_null orelse
        tryReduceAdaptive(T, E, Context, context, map_fn, combine_fn, identity, mid, end, right_split, task);

    // Propagate errors - left takes priority
    if (error_left) |err| {
        return err;
    }

    const result_right = try result_right_union;

    return combine_fn(result_left, result_right);
}

// ============================================================================
// parallelFor() - Parallel Iteration
// ============================================================================

const splitter_mod = @import("internal/splitter.zig");
const Splitter = splitter_mod.Splitter;
const LengthSplitter = splitter_mod.LengthSplitter;

/// Execute a function over range [0, n) with automatic parallelization.
///
/// Uses adaptive splitting that automatically determines the optimal parallelism
/// level based on thread count and data size. No manual tuning required.
///
/// The range is recursively split using fork-join until the splitter decides
/// to execute sequentially, enabling work-stealing for load balancing.
pub fn parallelFor(
    n: usize,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
) void {
    if (n == 0) return;

    if (!isInitialized()) {
        body_fn(context, 0, n);
        return;
    }

    // Create adaptive splitter - automatically determines parallelism
    const split = LengthSplitter.initDefault(n);

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (current_task) |task| {
        parallelForAdaptive(Context, context, body_fn, 0, n, split, task);
        return;
    }

    const pool = getPool() orelse {
        body_fn(context, 0, n);
        return;
    };

    // Slow path: create a new worker context via pool.call()
    _ = pool.call(void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, LengthSplitter }) void {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            parallelForAdaptive(Context, args[0], body_fn, args[1], args[2], args[3], task);
        }
    }.compute, .{ context, 0, n, split });
}

/// Execute a function over range [0, n) with custom grain size.
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelFor() which auto-tunes based on data size.
pub fn parallelForWithGrain(
    n: usize,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    grain_size: usize,
) void {
    if (n == 0) return;

    if (n <= grain_size or !isInitialized()) {
        body_fn(context, 0, n);
        return;
    }

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (current_task) |task| {
        parallelForImpl(Context, context, body_fn, 0, n, grain_size, task);
        return;
    }

    const pool = getPool() orelse {
        body_fn(context, 0, n);
        return;
    };

    // Slow path: create a new worker context via pool.call()
    _ = pool.call(void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, usize }) void {
            // Set thread-local context for nested calls
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            const ctx = args[0];
            const start = args[1];
            const end = args[2];
            const grain = args[3];
            parallelForImpl(Context, ctx, body_fn, start, end, grain, task);
        }
    }.compute, .{ context, 0, n, grain_size });
}

/// Adaptive parallel for implementation using LengthSplitter.
fn parallelForAdaptive(
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    start: usize,
    end: usize,
    split: LengthSplitter,
    task: *Task,
) void {
    const len = end - start;

    // Let the splitter decide: should we split or execute sequentially?
    var mutable_split = split;
    if (!mutable_split.trySplit(len)) {
        // Base case: execute sequentially
        body_fn(context, start, end);
        return;
    }

    const mid = start + len / 2;

    // Clone splitter for the forked task (each branch gets its own counter)
    const right_split = mutable_split.clone();

    // Pass splitter by VALUE (not pointer) to avoid dangling reference when stolen
    const RightArgs = struct { Context, usize, usize, LengthSplitter };

    var future_right = Future(RightArgs, void).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: RightArgs) void {
            parallelForAdaptive(Context, args[0], body_fn, args[1], args[2], args[3], t);
        }
    }.call, .{ context, mid, end, right_split });

    // Execute left half directly
    parallelForAdaptive(Context, context, body_fn, start, mid, mutable_split, task);

    // Join right half
    _ = future_right.join(task) orelse {
        parallelForAdaptive(Context, context, body_fn, mid, end, right_split, task);
    };
}

// ============================================================================
// parallelForWithEarlyExit() - Parallel For with Early Termination
// ============================================================================

/// Parallel for with early exit capability.
///
/// Like parallelFor, but checks an atomic flag before each recursive split.
/// If the flag becomes true, entire subtrees are pruned (not started at all).
/// This matches Rayon's consumer.full() pattern for short-circuiting operations.
///
/// Usage:
/// ```zig
/// var found = std.atomic.Value(bool).init(false);
/// parallelForWithEarlyExit(n, Context, ctx, bodyFn, &found);
/// ```
pub fn parallelForWithEarlyExit(
    n: usize,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    early_exit: *std.atomic.Value(bool),
) void {
    if (n == 0) return;

    // Check early exit before doing anything
    if (early_exit.load(.monotonic)) return;

    if (!isInitialized()) {
        body_fn(context, 0, n);
        return;
    }

    const split = LengthSplitter.initDefault(n);

    if (current_task) |task| {
        parallelForEarlyExitImpl(Context, context, body_fn, 0, n, split, task, early_exit);
        return;
    }

    const pool = getPool() orelse {
        body_fn(context, 0, n);
        return;
    };

    _ = pool.call(void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, LengthSplitter, *std.atomic.Value(bool) }) void {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            parallelForEarlyExitImpl(Context, args[0], body_fn, args[1], args[2], args[3], task, args[4]);
        }
    }.compute, .{ context, 0, n, split, early_exit });
}

/// Internal implementation of parallelForWithEarlyExit.
fn parallelForEarlyExitImpl(
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    start: usize,
    end: usize,
    split: LengthSplitter,
    task: *Task,
    early_exit: *std.atomic.Value(bool),
) void {
    const len = end - start;

    // KEY OPTIMIZATION: Check early exit BEFORE deciding to split.
    // This prunes entire subtrees when a result is found.
    // Matches Rayon's "if consumer.full() { return early }" pattern.
    if (early_exit.load(.monotonic)) return;

    var mutable_split = split;
    if (!mutable_split.trySplit(len)) {
        // Base case: execute sequentially (body should also check early_exit internally)
        body_fn(context, start, end);
        return;
    }

    const mid = start + len / 2;
    const right_split = mutable_split.clone();

    const RightArgs = struct { Context, usize, usize, LengthSplitter, *std.atomic.Value(bool) };

    var future_right = Future(RightArgs, void).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: RightArgs) void {
            parallelForEarlyExitImpl(Context, args[0], body_fn, args[1], args[2], args[3], t, args[4]);
        }
    }.call, .{ context, mid, end, right_split, early_exit });

    // Execute left half directly
    parallelForEarlyExitImpl(Context, context, body_fn, start, mid, mutable_split, task, early_exit);

    // Join right half (or execute inline if not stolen)
    _ = future_right.join(task) orelse {
        // Only execute if not early exited
        if (!early_exit.load(.monotonic)) {
            parallelForEarlyExitImpl(Context, context, body_fn, mid, end, right_split, task, early_exit);
        }
    };
}

/// Legacy grain-based implementation (for parallelForWithGrain compatibility)
fn parallelForImpl(
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    start: usize,
    end: usize,
    grain_size: usize,
    task: *Task,
) void {
    const len = end - start;

    if (len <= grain_size) {
        body_fn(context, start, end);
        return;
    }

    const mid = start + len / 2;

    // Pass only data needed - the forked handler receives its own Task from the framework
    const RightArgs = struct { Context, usize, usize, usize };

    var future_right = Future(RightArgs, void).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: RightArgs) void {
            parallelForImpl(Context, args[0], body_fn, args[1], args[2], args[3], t);
        }
    }.call, .{ context, mid, end, grain_size });

    // Execute left half directly
    parallelForImpl(Context, context, body_fn, start, mid, grain_size, task);

    // Join right half
    _ = future_right.join(task) orelse {
        parallelForImpl(Context, context, body_fn, mid, end, grain_size, task);
    };
}

// ============================================================================
// parallelReduce() - Parallel Map-Reduce
// ============================================================================

/// Parallel reduction with associative combine function.
///
/// Uses adaptive splitting that automatically determines the optimal parallelism
/// level. Maps each index to a value, then combines values in parallel using
/// a divide-and-conquer pattern with work-stealing.
pub fn parallelReduce(
    comptime T: type,
    n: usize,
    identity: T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize) T,
    comptime combine_fn: fn (T, T) T,
) T {
    if (n == 0) return identity;

    if (!isInitialized()) {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    }

    // Create adaptive splitter
    const split = LengthSplitter.initDefault(n);

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (current_task) |task| {
        return parallelReduceAdaptive(T, Context, context, map_fn, combine_fn, identity, 0, n, split, task);
    }

    const pool = getPool() orelse {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(T, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, T, LengthSplitter }) T {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            return parallelReduceAdaptive(T, Context, args[0], map_fn, combine_fn, args[3], args[1], args[2], args[4], task);
        }
    }.compute, .{ context, 0, n, identity, split });
}

/// Parallel reduction with custom grain size.
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelReduce() which auto-tunes based on data size.
pub fn parallelReduceWithGrain(
    comptime T: type,
    n: usize,
    identity: T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize) T,
    comptime combine_fn: fn (T, T) T,
    grain_size: usize,
) T {
    if (n == 0) return identity;

    if (n <= grain_size or !isInitialized()) {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    }

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (current_task) |task| {
        return parallelReduceImpl(T, Context, context, map_fn, combine_fn, identity, 0, n, grain_size, task);
    }

    const pool = getPool() orelse {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(T, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, T, usize }) T {
            // Set thread-local context for nested calls
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            const ctx = args[0];
            const start = args[1];
            const end = args[2];
            const id = args[3];
            const grain = args[4];
            return parallelReduceImpl(T, Context, ctx, map_fn, combine_fn, id, start, end, grain, task);
        }
    }.compute, .{ context, 0, n, identity, grain_size });
}

/// Adaptive parallel reduce implementation using LengthSplitter.
fn parallelReduceAdaptive(
    comptime T: type,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize) T,
    comptime combine_fn: fn (T, T) T,
    identity: T,
    start: usize,
    end: usize,
    split: LengthSplitter,
    task: *Task,
) T {
    const len = end - start;

    // Let the splitter decide: should we split or execute sequentially?
    var mutable_split = split;
    if (!mutable_split.trySplit(len)) {
        // Base case: execute sequentially
        var result = identity;
        for (start..end) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    }

    const mid = start + len / 2;

    // Clone splitter for the forked task (each branch gets its own counter)
    const right_split = mutable_split.clone();

    // Pass splitter by VALUE (not pointer) to avoid dangling reference when stolen
    const Args = struct { Context, usize, usize, T, LengthSplitter };

    var future_right = Future(Args, T).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: Args) T {
            return parallelReduceAdaptive(T, Context, args[0], map_fn, combine_fn, args[3], args[1], args[2], args[4], t);
        }
    }.call, .{ context, mid, end, identity, right_split });

    // Compute left half directly
    const left_result = parallelReduceAdaptive(T, Context, context, map_fn, combine_fn, identity, start, mid, mutable_split, task);

    // Join right half
    const right_result = future_right.join(task) orelse
        parallelReduceAdaptive(T, Context, context, map_fn, combine_fn, identity, mid, end, right_split, task);

    return combine_fn(left_result, right_result);
}

/// Legacy grain-based implementation (for parallelReduceWithGrain compatibility)
fn parallelReduceImpl(
    comptime T: type,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize) T,
    comptime combine_fn: fn (T, T) T,
    identity: T,
    start: usize,
    end: usize,
    grain_size: usize,
    task: *Task,
) T {
    const len = end - start;

    if (len <= grain_size) {
        var result = identity;
        for (start..end) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    }

    const mid = start + len / 2;

    // Pass only data needed - the forked handler receives its own Task from the framework
    const Args = struct { Context, usize, usize, T, usize };

    var future_right = Future(Args, T).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: Args) T {
            return parallelReduceImpl(T, Context, args[0], map_fn, combine_fn, args[3], args[1], args[2], args[4], t);
        }
    }.call, .{ context, mid, end, identity, grain_size });

    // Compute left half directly
    const left_result = parallelReduceImpl(T, Context, context, map_fn, combine_fn, identity, start, mid, grain_size, task);

    // Join right half
    const right_result = future_right.join(task) orelse
        parallelReduceImpl(T, Context, context, map_fn, combine_fn, identity, mid, end, grain_size, task);

    return combine_fn(left_result, right_result);
}

// ============================================================================
// parallelReduceChunked() - Range-based Parallel Reduction (for SIMD)
// ============================================================================

/// Parallel reduction using a chunk-based map function.
/// This is optimized for SIMD operations where the map function processes
/// a range of elements at once rather than one element at a time.
///
/// The map_fn signature is: `fn(Context, start: usize, end: usize) T`
/// This allows SIMD-optimized implementations within each chunk.
pub fn parallelReduceChunked(
    comptime T: type,
    n: usize,
    identity: T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize, usize) T,
    comptime combine_fn: fn (T, T) T,
    grain_size: usize,
) T {
    if (n == 0) return identity;

    if (n <= grain_size or !isInitialized()) {
        return map_fn(context, 0, n);
    }

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (current_task) |task| {
        return parallelReduceChunkedImpl(T, Context, context, map_fn, combine_fn, identity, 0, n, grain_size, task);
    }

    const pool = getPool() orelse {
        return map_fn(context, 0, n);
    };

    return pool.call(T, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, T, usize }) T {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            const ctx = args[0];
            const start = args[1];
            const end = args[2];
            const id = args[3];
            const grain = args[4];
            return parallelReduceChunkedImpl(T, Context, ctx, map_fn, combine_fn, id, start, end, grain, task);
        }
    }.compute, .{ context, 0, n, identity, grain_size });
}

fn parallelReduceChunkedImpl(
    comptime T: type,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, usize, usize) T,
    comptime combine_fn: fn (T, T) T,
    identity: T,
    start: usize,
    end: usize,
    grain_size: usize,
    task: *Task,
) T {
    const len = end - start;

    // Base case: use the chunked map function (SIMD-optimized)
    if (len <= grain_size) {
        return map_fn(context, start, end);
    }

    const mid = start + len / 2;

    // Pass only data needed - the forked handler receives its own Task from the framework
    const Args = struct { Context, usize, usize, T, usize };

    var future_right = Future(Args, T).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: Args) T {
            return parallelReduceChunkedImpl(T, Context, args[0], map_fn, combine_fn, args[3], args[1], args[2], args[4], t);
        }
    }.call, .{ context, mid, end, identity, grain_size });

    // Compute left half directly
    const left_result = parallelReduceChunkedImpl(T, Context, context, map_fn, combine_fn, identity, start, mid, grain_size, task);

    // Join right half
    const right_result = future_right.join(task) orelse
        parallelReduceChunkedImpl(T, Context, context, map_fn, combine_fn, identity, mid, end, grain_size, task);

    return combine_fn(left_result, right_result);
}

// ============================================================================
// parallelCollect() - Parallel Map with Result Collection
// ============================================================================

/// Parallel map that collects results into an output slice.
///
/// Maps each element of `input` through `map_fn` and stores the result
/// in `output`. Work is divided and stolen using the standard fork-join pattern.
///
/// This is equivalent to Rayon's `.par_iter().map().collect()`.
///
/// Requirements:
/// - `output.len` must equal `input.len`
/// - `map_fn` signature: `fn(Context, T) U`
pub fn parallelCollect(
    comptime T: type,
    comptime U: type,
    input: []const T,
    output: []U,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) U,
) void {
    parallelCollectWithGrain(T, U, input, output, Context, context, map_fn, getGrainSize());
}

/// Parallel map with custom grain size.
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelCollect() which auto-tunes based on data size.
pub fn parallelCollectWithGrain(
    comptime T: type,
    comptime U: type,
    input: []const T,
    output: []U,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) U,
    grain_size: usize,
) void {
    std.debug.assert(input.len == output.len);

    if (input.len == 0) return;

    if (input.len <= grain_size or !isInitialized()) {
        for (input, output) |in_val, *out_val| {
            out_val.* = map_fn(context, in_val);
        }
        return;
    }

    const CollectContext = struct {
        input: []const T,
        output: []U,
        ctx: Context,
    };

    const collect_ctx = CollectContext{
        .input = input,
        .output = output,
        .ctx = context,
    };

    parallelForWithGrain(input.len, CollectContext, collect_ctx, struct {
        fn body(c: CollectContext, start: usize, end: usize) void {
            for (start..end) |i| {
                c.output[i] = map_fn(c.ctx, c.input[i]);
            }
        }
    }.body, grain_size);
}

/// Parallel map in-place: transform elements without allocating new storage.
pub fn parallelMapInPlace(
    comptime T: type,
    data: []T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) T,
) void {
    parallelMapInPlaceWithGrain(T, data, Context, context, map_fn, getGrainSize());
}

/// Parallel map in-place with custom grain size.
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelMapInPlace() which auto-tunes based on data size.
pub fn parallelMapInPlaceWithGrain(
    comptime T: type,
    data: []T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) T,
    grain_size: usize,
) void {
    if (data.len == 0) return;

    if (data.len <= grain_size or !isInitialized()) {
        for (data) |*val| {
            val.* = map_fn(context, val.*);
        }
        return;
    }

    const MapContext = struct { data: []T, ctx: Context };
    const map_ctx = MapContext{ .data = data, .ctx = context };

    parallelForWithGrain(data.len, MapContext, map_ctx, struct {
        fn body(c: MapContext, start: usize, end: usize) void {
            for (c.data[start..end]) |*val| {
                val.* = map_fn(c.ctx, val.*);
            }
        }
    }.body, grain_size);
}

// ============================================================================
// parallelFlatten() - Parallel Flatten Nested Slices
// ============================================================================

/// Flatten nested slices into a single output slice in parallel.
///
/// This is the pattern used in Polars' `flatten_par` for combining
/// thread-local results into a single output array.
///
/// The algorithm:
/// 1. Compute offsets for each input slice (where it starts in output)
/// 2. Copy each slice to its designated output region in parallel
///
/// Requirements:
/// - `output.len` must equal the sum of all input slice lengths
/// - Pre-compute total length using `capAndOffsets` if needed
pub fn parallelFlatten(
    comptime T: type,
    slices: []const []const T,
    output: []T,
) void {
    parallelFlattenWithGrain(T, slices, output, 1); // Grain=1 since each slice is independent work
}

/// Parallel flatten with custom grain size (number of slices per task).
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelFlatten() which auto-tunes.
pub fn parallelFlattenWithGrain(
    comptime T: type,
    slices: []const []const T,
    output: []T,
    grain_size: usize,
) void {
    if (slices.len == 0) return;

    // Compute offsets
    var offsets_buf: [1024]usize = undefined;
    const offsets = if (slices.len <= 1024)
        offsets_buf[0..slices.len]
    else blk: {
        // For very large slice counts, allocate (rare case)
        const allocator = std.heap.c_allocator;
        break :blk allocator.alloc(usize, slices.len) catch @panic("OOM");
    };
    defer if (slices.len > 1024) std.heap.c_allocator.free(offsets);

    const total = capAndOffsets(T, slices, offsets);
    std.debug.assert(output.len == total);

    if (slices.len <= grain_size or !isInitialized()) {
        // Sequential path
        for (slices, offsets) |slice, offset| {
            @memcpy(output[offset..][0..slice.len], slice);
        }
        return;
    }

    // Parallel path: each task copies its assigned slices
    const out_ptr = SyncPtr(T).init(output);

    const FlattenContext = struct {
        slices: []const []const T,
        offsets: []const usize,
        out_ptr: SyncPtr(T),
    };

    const flatten_ctx = FlattenContext{
        .slices = slices,
        .offsets = offsets,
        .out_ptr = out_ptr,
    };

    parallelForWithGrain(slices.len, FlattenContext, flatten_ctx, struct {
        fn body(c: FlattenContext, start: usize, end: usize) void {
            for (start..end) |i| {
                const slice = c.slices[i];
                const offset = c.offsets[i];
                c.out_ptr.copyAt(offset, slice);
            }
        }
    }.body, grain_size);
}

/// Flatten with pre-computed offsets (avoids recomputing).
/// Use this when you've already called `capAndOffsets` to get the total size.
pub fn parallelFlattenWithOffsets(
    comptime T: type,
    slices: []const []const T,
    offsets: []const usize,
    output: []T,
) void {
    if (slices.len == 0) return;

    std.debug.assert(offsets.len >= slices.len);

    if (slices.len <= 1 or !isInitialized()) {
        for (slices, offsets[0..slices.len]) |slice, offset| {
            @memcpy(output[offset..][0..slice.len], slice);
        }
        return;
    }

    const out_ptr = SyncPtr(T).init(output);

    const FlattenContext = struct {
        slices: []const []const T,
        offsets: []const usize,
        out_ptr: SyncPtr(T),
    };

    const flatten_ctx = FlattenContext{
        .slices = slices,
        .offsets = offsets,
        .out_ptr = out_ptr,
    };

    // Use grain size of 1 - each slice is independent
    parallelForWithGrain(slices.len, FlattenContext, flatten_ctx, struct {
        fn body(c: FlattenContext, start: usize, end: usize) void {
            for (start..end) |i| {
                const slice = c.slices[i];
                const offset = c.offsets[i];
                c.out_ptr.copyAt(offset, slice);
            }
        }
    }.body, 1);
}

// ============================================================================
// parallelScatter() - Parallel Scatter with Pre-computed Offsets
// ============================================================================

/// Scatter values to output using pre-computed offsets.
///
/// This is the pattern used in Polars' BUILD phase where each thread
/// scatters its partition to pre-computed locations in the output.
///
/// Each element `values[i]` is written to `output[offsets[i]]`.
/// After completion, `offsets[i]` is incremented by 1 (for multi-value scatter).
pub fn parallelScatter(
    comptime T: type,
    values: []const T,
    indices: []const usize,
    output: []T,
) void {
    std.debug.assert(values.len == indices.len);

    if (values.len == 0) return;

    if (values.len <= getGrainSize() or !isInitialized()) {
        for (values, indices) |val, idx| {
            output[idx] = val;
        }
        return;
    }

    const out_ptr = SyncPtr(T).init(output);

    const ScatterContext = struct {
        values: []const T,
        indices: []const usize,
        out_ptr: SyncPtr(T),
    };

    const scatter_ctx = ScatterContext{
        .values = values,
        .indices = indices,
        .out_ptr = out_ptr,
    };

    parallelFor(values.len, ScatterContext, scatter_ctx, struct {
        fn body(c: ScatterContext, start: usize, end: usize) void {
            for (start..end) |i| {
                c.out_ptr.writeAt(c.indices[i], c.values[i]);
            }
        }
    }.body);
}

// ============================================================================
// Parallel Sorting
// ============================================================================

/// Sort a slice in-place using parallel unstable sort.
/// Uses pattern-defeating quicksort (PDQSort) internally.
///
/// Unstable: equal elements may be reordered.
/// Time: O(n log n) average and worst-case
/// Space: O(log n) stack space
///
/// Example:
/// ```zig
/// var data = [_]i64{ 5, 2, 8, 1, 9, 3 };
/// blitz.sort(i64, &data, std.sort.asc(i64));
/// // data is now [1, 2, 3, 5, 8, 9]
/// ```
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
/// Keys are computed on each comparison.
pub fn sortByKey(
    comptime T: type,
    comptime K: type,
    v: []T,
    comptime key_fn: fn (T) K,
) void {
    sort_impl.sortByKey(T, K, v, key_fn);
}

/// Sort by key with parallel key caching.
/// Two-phase algorithm: parallel key computation, then sort by cached keys.
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

test "parallelFor - basic" {
    var results: [1000]u32 = undefined;
    @memset(&results, 0);

    const Context = struct { results: []u32 };
    const ctx = Context{ .results = &results };

    parallelFor(1000, Context, ctx, struct {
        fn body(c: Context, start: usize, end: usize) void {
            for (start..end) |i| {
                c.results[i] = @intCast(i);
            }
        }
    }.body);

    for (results, 0..) |v, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), v);
    }
}

test "parallelFor - empty range" {
    var called = false;
    const Context = struct { called: *bool };
    const ctx = Context{ .called = &called };

    parallelFor(0, Context, ctx, struct {
        fn body(c: Context, _: usize, _: usize) void {
            c.called.* = true;
        }
    }.body);

    try std.testing.expect(!called);
}

test "parallelReduce - sum" {
    var data: [10000]f64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    const expected: f64 = 10000.0 * 9999.0 / 2.0;

    const Context = struct { data: []f64 };
    const ctx = Context{ .data = &data };

    const result = parallelReduce(
        f64,
        data.len,
        0.0,
        Context,
        ctx,
        struct {
            fn map(c: Context, i: usize) f64 {
                return c.data[i];
            }
        }.map,
        struct {
            fn combine(a: f64, b: f64) f64 {
                return a + b;
            }
        }.combine,
    );

    try std.testing.expectApproxEqAbs(expected, result, 0.001);
}

test "parallelCollect - basic" {
    var input: [100]i32 = undefined;
    var output: [100]i64 = undefined;

    for (&input, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    parallelCollect(i32, i64, &input, &output, void, {}, struct {
        fn map(_: void, x: i32) i64 {
            return @as(i64, x) * 2;
        }
    }.map);

    for (output, 0..) |v, i| {
        try std.testing.expectEqual(@as(i64, @intCast(i * 2)), v);
    }
}

test "parallelCollect - empty" {
    var input: [0]i32 = undefined;
    var output: [0]i64 = undefined;

    parallelCollect(i32, i64, &input, &output, void, {}, struct {
        fn map(_: void, x: i32) i64 {
            return x;
        }
    }.map);
}

test "parallelMapInPlace - basic" {
    var data: [100]i32 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    parallelMapInPlace(i32, &data, void, {}, struct {
        fn map(_: void, x: i32) i32 {
            return x * 3;
        }
    }.map);

    for (data, 0..) |v, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i * 3)), v);
    }
}

test "parallelFlatten - basic" {
    const slice0 = [_]u32{ 1, 2, 3 };
    const slice1 = [_]u32{ 4, 5 };
    const slice2 = [_]u32{ 6, 7, 8, 9 };

    const slices = [_][]const u32{ &slice0, &slice1, &slice2 };
    var output: [9]u32 = undefined;

    parallelFlatten(u32, &slices, &output);

    const expected = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try std.testing.expectEqualSlices(u32, &expected, &output);
}

test "parallelFlatten - empty slices" {
    const slice0 = [_]u32{ 1, 2 };
    const slice1 = [_]u32{};
    const slice2 = [_]u32{ 3 };

    const slices = [_][]const u32{ &slice0, &slice1, &slice2 };
    var output: [3]u32 = undefined;

    parallelFlatten(u32, &slices, &output);

    const expected = [_]u32{ 1, 2, 3 };
    try std.testing.expectEqualSlices(u32, &expected, &output);
}

test "parallelFlattenWithOffsets - basic" {
    const slice0 = [_]u64{ 10, 20 };
    const slice1 = [_]u64{ 30, 40, 50 };

    const slices = [_][]const u64{ &slice0, &slice1 };
    var offsets: [2]usize = undefined;
    const total = capAndOffsets(u64, &slices, &offsets);

    try std.testing.expectEqual(@as(usize, 5), total);
    try std.testing.expectEqual(@as(usize, 0), offsets[0]);
    try std.testing.expectEqual(@as(usize, 2), offsets[1]);

    var output: [5]u64 = undefined;
    parallelFlattenWithOffsets(u64, &slices, &offsets, &output);

    const expected = [_]u64{ 10, 20, 30, 40, 50 };
    try std.testing.expectEqualSlices(u64, &expected, &output);
}

test "parallelScatter - basic" {
    const values = [_]u32{ 100, 200, 300, 400 };
    const indices = [_]usize{ 3, 0, 7, 1 };
    var output: [10]u32 = undefined;
    @memset(&output, 0);

    parallelScatter(u32, &values, &indices, &output);

    try std.testing.expectEqual(@as(u32, 200), output[0]);
    try std.testing.expectEqual(@as(u32, 400), output[1]);
    try std.testing.expectEqual(@as(u32, 0), output[2]);
    try std.testing.expectEqual(@as(u32, 100), output[3]);
    try std.testing.expectEqual(@as(u32, 300), output[7]);
}

test "SyncPtr - parallel write simulation" {
    var buffer: [100]u64 = undefined;
    @memset(&buffer, 0);

    const ptr = SyncPtr(u64).init(&buffer);

    // Simulate what parallel threads would do
    // Thread 0: write to [0..25)
    for (0..25) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Thread 1: write to [25..50)
    for (25..50) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Thread 2: write to [50..75)
    for (50..75) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Thread 3: write to [75..100)
    for (75..100) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Verify all writes
    for (buffer, 0..) |v, i| {
        try std.testing.expectEqual(@as(u64, i * 10), v);
    }
}

test "tryJoin - both succeed" {
    const TestError = error{TestFailed};

    const fn_a = struct {
        fn call(x: i32) TestError!i32 {
            return x * 2;
        }
    }.call;

    const fn_b = struct {
        fn call(x: i32) TestError!i32 {
            return x * 3;
        }
    }.call;

    const result = tryJoin(i32, i32, TestError, fn_a, fn_b, @as(i32, 5), @as(i32, 7));
    const values = try result;

    try std.testing.expectEqual(@as(i32, 10), values[0]);
    try std.testing.expectEqual(@as(i32, 21), values[1]);
}

test "tryJoin - A fails, B still completes" {
    const TestError = error{AFailed};
    var b_completed = std.atomic.Value(bool).init(false);

    const Context = struct {
        completed: *std.atomic.Value(bool),
    };

    const fn_a = struct {
        fn call(_: i32) TestError!i32 {
            return TestError.AFailed;
        }
    }.call;

    const fn_b = struct {
        fn call(ctx: Context) TestError!i32 {
            // Simulate some work
            for (0..100) |_| {
                std.atomic.spinLoopHint();
            }
            ctx.completed.store(true, .release);
            return 42;
        }
    }.call;

    const result = tryJoin(i32, i32, TestError, fn_a, fn_b, @as(i32, 5), Context{ .completed = &b_completed });

    // Should return A's error
    try std.testing.expectError(TestError.AFailed, result);

    // B should have completed before error was propagated
    try std.testing.expect(b_completed.load(.acquire));
}

test "tryJoin - B fails" {
    const TestError = error{BFailed};

    const fn_a = struct {
        fn call(x: i32) TestError!i32 {
            return x * 2;
        }
    }.call;

    const fn_b = struct {
        fn call(_: i32) TestError!i32 {
            return TestError.BFailed;
        }
    }.call;

    const result = tryJoin(i32, i32, TestError, fn_a, fn_b, @as(i32, 5), @as(i32, 7));

    try std.testing.expectError(TestError.BFailed, result);
}

test "tryJoin - both fail, A's error takes priority" {
    const TestError = error{ AFailed, BFailed };

    const fn_a = struct {
        fn call(_: i32) TestError!i32 {
            return TestError.AFailed;
        }
    }.call;

    const fn_b = struct {
        fn call(_: i32) TestError!i32 {
            return TestError.BFailed;
        }
    }.call;

    const result = tryJoin(i32, i32, TestError, fn_a, fn_b, @as(i32, 5), @as(i32, 7));

    // A's error takes priority (Rayon behavior)
    try std.testing.expectError(TestError.AFailed, result);
}

test "tryJoinVoid - both succeed" {
    const TestError = error{TestFailed};
    var a_called = false;
    var b_called = false;

    const Context = struct {
        called: *bool,
    };

    const fn_a = struct {
        fn call(ctx: Context) TestError!void {
            ctx.called.* = true;
        }
    }.call;

    const fn_b = struct {
        fn call(ctx: Context) TestError!void {
            ctx.called.* = true;
        }
    }.call;

    try tryJoinVoid(TestError, fn_a, fn_b, Context{ .called = &a_called }, Context{ .called = &b_called });

    try std.testing.expect(a_called);
    try std.testing.expect(b_called);
}

test "tryForEach - all succeed" {
    const TestError = error{ProcessFailed};
    var results: [100]u32 = undefined;
    @memset(&results, 0);

    const Context = struct { results: []u32 };
    const ctx = Context{ .results = &results };

    try tryForEach(100, TestError, Context, ctx, struct {
        fn body(c: Context, start: usize, end: usize) TestError!void {
            for (start..end) |i| {
                c.results[i] = @intCast(i * 2);
            }
        }
    }.body);

    for (results, 0..) |v, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 2)), v);
    }
}

test "tryForEach - error in middle" {
    const TestError = error{ProcessFailed};
    var processed = std.atomic.Value(u32).init(0);

    const Context = struct {
        processed: *std.atomic.Value(u32),
        fail_at: usize,
    };
    const ctx = Context{ .processed = &processed, .fail_at = 50 };

    const result = tryForEach(100, TestError, Context, ctx, struct {
        fn body(c: Context, start: usize, end: usize) TestError!void {
            for (start..end) |i| {
                if (i == c.fail_at) {
                    return TestError.ProcessFailed;
                }
                _ = c.processed.fetchAdd(1, .monotonic);
            }
        }
    }.body);

    try std.testing.expectError(TestError.ProcessFailed, result);
    // Some items should have been processed before/after the error
    try std.testing.expect(processed.load(.monotonic) > 0);
}

test "tryForEach - empty range" {
    const TestError = error{ProcessFailed};
    var called = false;

    const Context = struct { called: *bool };
    const ctx = Context{ .called = &called };

    try tryForEach(0, TestError, Context, ctx, struct {
        fn body(c: Context, _: usize, _: usize) TestError!void {
            c.called.* = true;
        }
    }.body);

    try std.testing.expect(!called);
}

test "tryReduce - all succeed" {
    const TestError = error{MapFailed};
    var data: [1000]i64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    const expected: i64 = 1000 * 999 / 2;

    const Context = struct { data: []i64 };
    const ctx = Context{ .data = &data };

    const result = try tryReduce(
        i64,
        TestError,
        data.len,
        0,
        Context,
        ctx,
        struct {
            fn map(c: Context, i: usize) TestError!i64 {
                return c.data[i];
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

test "tryReduce - error in map" {
    const TestError = error{MapFailed};
    var data: [100]i64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    const Context = struct { data: []i64, fail_at: usize };
    const ctx = Context{ .data = &data, .fail_at = 42 };

    const result = tryReduce(
        i64,
        TestError,
        data.len,
        0,
        Context,
        ctx,
        struct {
            fn map(c: Context, i: usize) TestError!i64 {
                if (i == c.fail_at) {
                    return TestError.MapFailed;
                }
                return c.data[i];
            }
        }.map,
        struct {
            fn combine(a: i64, b: i64) i64 {
                return a + b;
            }
        }.combine,
    );

    try std.testing.expectError(TestError.MapFailed, result);
}

test "tryReduce - empty range" {
    const TestError = error{MapFailed};

    const result = try tryReduce(
        i64,
        TestError,
        0,
        42, // identity
        void,
        {},
        struct {
            fn map(_: void, _: usize) TestError!i64 {
                unreachable;
            }
        }.map,
        struct {
            fn combine(a: i64, b: i64) i64 {
                return a + b;
            }
        }.combine,
    );

    try std.testing.expectEqual(@as(i64, 42), result);
}

// ============================================================================
// Module Tests - Include all submodule tests
// ============================================================================

test {
    // Sort module tests
    _ = @import("sort/tests.zig");

    // Iterator module tests
    _ = @import("iter/tests.zig");

    // SIMD module tests
    _ = @import("simd/tests.zig");

    // Internal module tests
    _ = @import("internal/mod.zig");
}
