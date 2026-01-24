//! Parallel For operations for Blitz.
//!
//! Provides parallel iteration primitives:
//! - parallelFor: Automatic parallelization with adaptive splitting
//! - parallelForWithGrain: Manual grain size control
//! - parallelForWithEarlyExit: Early termination support

const std = @import("std");
const runtime = @import("runtime.zig");
const Task = runtime.Task;
const Future = runtime.Future;
const splitter_mod = @import("../internal/splitter.zig");
const LengthSplitter = splitter_mod.LengthSplitter;

// ============================================================================
// parallelFor() - Parallel Iteration
// ============================================================================

/// Execute a function over range [0, n) with automatic parallelization.
///
/// Uses adaptive splitting that automatically determines the optimal parallelism
/// level based on thread count and data size. No manual tuning required.
pub fn parallelFor(
    n: usize,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
) void {
    if (n == 0) return;

    if (!runtime.isInitialized()) {
        body_fn(context, 0, n);
        return;
    }

    const split = LengthSplitter.initDefault(n);

    if (runtime.current_task) |task| {
        parallelForAdaptive(Context, context, body_fn, 0, n, split, task);
        return;
    }

    const pool = runtime.getPool() orelse {
        body_fn(context, 0, n);
        return;
    };

    _ = pool.call(void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, LengthSplitter }) void {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

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

    if (n <= grain_size or !runtime.isInitialized()) {
        body_fn(context, 0, n);
        return;
    }

    if (runtime.current_task) |task| {
        parallelForImpl(Context, context, body_fn, 0, n, grain_size, task);
        return;
    }

    const pool = runtime.getPool() orelse {
        body_fn(context, 0, n);
        return;
    };

    _ = pool.call(void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, usize }) void {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

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

    var mutable_split = split;
    if (!mutable_split.trySplit(len)) {
        body_fn(context, start, end);
        return;
    }

    const mid = start + len / 2;
    const right_split = mutable_split.clone();

    const RightArgs = struct { Context, usize, usize, LengthSplitter };

    var future_right = Future(RightArgs, void).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: RightArgs) void {
            parallelForAdaptive(Context, args[0], body_fn, args[1], args[2], args[3], t);
        }
    }.call, .{ context, mid, end, right_split });

    parallelForAdaptive(Context, context, body_fn, start, mid, mutable_split, task);

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
/// If the flag becomes true, entire subtrees are pruned.
pub fn parallelForWithEarlyExit(
    n: usize,
    comptime Context: type,
    context: Context,
    comptime body_fn: fn (Context, usize, usize) void,
    early_exit: *std.atomic.Value(bool),
) void {
    if (n == 0) return;

    if (early_exit.load(.monotonic)) return;

    if (!runtime.isInitialized()) {
        body_fn(context, 0, n);
        return;
    }

    const split = LengthSplitter.initDefault(n);

    if (runtime.current_task) |task| {
        parallelForEarlyExitImpl(Context, context, body_fn, 0, n, split, task, early_exit);
        return;
    }

    const pool = runtime.getPool() orelse {
        body_fn(context, 0, n);
        return;
    };

    _ = pool.call(void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, LengthSplitter, *std.atomic.Value(bool) }) void {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

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

    if (early_exit.load(.monotonic)) return;

    var mutable_split = split;
    if (!mutable_split.trySplit(len)) {
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

    parallelForEarlyExitImpl(Context, context, body_fn, start, mid, mutable_split, task, early_exit);

    _ = future_right.join(task) orelse {
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

    const RightArgs = struct { Context, usize, usize, usize };

    var future_right = Future(RightArgs, void).init();
    future_right.fork(task, struct {
        fn call(t: *Task, args: RightArgs) void {
            parallelForImpl(Context, args[0], body_fn, args[1], args[2], args[3], t);
        }
    }.call, .{ context, mid, end, grain_size });

    parallelForImpl(Context, context, body_fn, start, mid, grain_size, task);

    _ = future_right.join(task) orelse {
        parallelForImpl(Context, context, body_fn, mid, end, grain_size, task);
    };
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
