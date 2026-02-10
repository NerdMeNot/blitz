//! Error-Safe Parallel operations for Blitz.
//!
//! Provides parallel primitives with error handling:
//! - tryForEach: Error-safe parallel iteration
//! - tryReduce: Error-safe parallel reduction
//!
//! All operations guarantee that parallel work completes before errors propagate.

const std = @import("std");
const runtime = @import("runtime.zig");
const Task = runtime.Task;
const Future = runtime.Future;
const splitter_mod = @import("../internal/Splitter.zig");
const LengthSplitter = splitter_mod.LengthSplitter;

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

    if (!runtime.isInitialized()) {
        return body_fn(context, 0, n);
    }

    // Create adaptive splitter
    const split = LengthSplitter.initDefault(n);

    // Fast path: if we're already inside a pool context
    if (runtime.current_task) |task| {
        return tryForEachAdaptive(E, Context, context, body_fn, 0, n, split, task);
    }

    const pool = runtime.getPool() orelse {
        return body_fn(context, 0, n);
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(E!void, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, LengthSplitter }) E!void {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

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

    if (!runtime.isInitialized()) {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, try map_fn(context, i));
        }
        return result;
    }

    // Create adaptive splitter
    const split = LengthSplitter.initDefault(n);

    // Fast path: if we're already inside a pool context
    if (runtime.current_task) |task| {
        return tryReduceAdaptive(T, E, Context, context, map_fn, combine_fn, identity, 0, n, split, task);
    }

    const pool = runtime.getPool() orelse {
        var result = identity;
        for (0..n) |i| {
            result = combine_fn(result, try map_fn(context, i));
        }
        return result;
    };

    // Slow path: create a new worker context via pool.call()
    return pool.call(E!T, struct {
        fn compute(task: *Task, args: struct { Context, usize, usize, T, LengthSplitter }) E!T {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

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
// Tests
// ============================================================================

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
