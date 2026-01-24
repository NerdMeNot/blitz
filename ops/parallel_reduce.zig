//! Parallel Reduce operations for Blitz.
//!
//! Provides parallel map-reduce primitives:
//! - parallelReduce: Automatic parallelization with adaptive splitting
//! - parallelReduceWithGrain: Manual grain size control
//! - parallelReduceChunked: Range-based reduction for SIMD operations

const std = @import("std");
const runtime = @import("runtime.zig");
const Task = runtime.Task;
const Future = runtime.Future;
const splitter_mod = @import("../internal/splitter.zig");
const LengthSplitter = splitter_mod.LengthSplitter;

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

    if (!runtime.isInitialized()) {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    }

    // Create adaptive splitter
    const split = LengthSplitter.initDefault(n);

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (runtime.current_task) |task| {
        return parallelReduceAdaptive(T, Context, context, map_fn, combine_fn, identity, 0, n, split, task);
    }

    const pool = runtime.getPool() orelse {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(T, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, T, LengthSplitter }) T {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

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

    if (n <= grain_size or !runtime.isInitialized()) {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, map_fn(context, i));
        }
        return result;
    }

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (runtime.current_task) |task| {
        return parallelReduceImpl(T, Context, context, map_fn, combine_fn, identity, 0, n, grain_size, task);
    }

    const pool = runtime.getPool() orelse {
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
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

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

    if (n <= grain_size or !runtime.isInitialized()) {
        return map_fn(context, 0, n);
    }

    // Fast path: if we're already inside a pool context, use fork/join directly
    if (runtime.current_task) |task| {
        return parallelReduceChunkedImpl(T, Context, context, map_fn, combine_fn, identity, 0, n, grain_size, task);
    }

    const pool = runtime.getPool() orelse {
        return map_fn(context, 0, n);
    };

    return pool.call(T, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, T, usize }) T {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

            const ctx = args[0];
            const s = args[1];
            const e = args[2];
            const id = args[3];
            const grain = args[4];
            return parallelReduceChunkedImpl(T, Context, ctx, map_fn, combine_fn, id, s, e, grain, task);
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
// Tests
// ============================================================================

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
