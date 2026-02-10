//! Join operations for Blitz.
//!
//! Provides fork-join parallelism primitives:
//! - join: Execute N tasks in parallel with heterogeneous return types
//! - Supports both comptime and runtime arguments
//!
//! This module implements Rayon-style join() semantics.

const std = @import("std");
const runtime = @import("runtime.zig");
const Task = runtime.Task;
const Future = runtime.Future;
const parallel_for = @import("parallel_for.zig");

// ============================================================================
// join() - Unified Fork-Join API
// ============================================================================

/// Execute N tasks in parallel with heterogeneous return types.
///
/// This is the unified join API that handles 2 to N tasks with different
/// return types, similar to JavaScript's Promise.all but with named results.
///
/// Usage:
/// ```zig
/// // Simple: just function pointers (no arguments)
/// const result = blitz.join(.{
///     .user = fetchUser,
///     .posts = fetchPosts,
/// });
/// // Access: result.user, result.posts
///
/// // With arguments: tuple of (function, arg1, arg2, ...)
/// const result = blitz.join(.{
///     .user = .{ fetchUserById, user_id },
///     .posts = .{ fetchPostsByUser, user_id, limit },
/// });
///
/// // Divide-and-conquer (recursive):
/// fn fib(n: u64) u64 {
///     if (n < 20) return fibSeq(n);
///     const r = blitz.join(.{
///         .a = .{ fib, n - 1 },
///         .b = .{ fib, n - 2 },
///     });
///     return r.a + r.b;
/// }
/// ```
///
/// Supports both comptime and runtime arguments - use the same API for all cases.
pub fn join(tasks: anytype) JoinResultType(@TypeOf(tasks)) {
    const TasksType = @TypeOf(tasks);
    const fields = @typeInfo(TasksType).@"struct".fields;

    if (fields.len == 0) {
        return .{};
    }

    var results: JoinResultType(TasksType) = undefined;

    if (fields.len == 1) {
        // Single task - just execute it directly
        executeTaskByIndex(TasksType, &tasks, &results, 0);
        return results;
    }

    // Check if pool is initialized
    if (!runtime.isInitialized()) {
        // Sequential fallback
        inline for (0..fields.len) |i| {
            executeTaskByIndex(TasksType, &tasks, &results, i);
        }
        return results;
    }

    // Fast path for 2 tasks - Rayon-style fork-join
    // This is the most common case (recursive divide-and-conquer)
    if (fields.len == 2) {
        return join2Fast(TasksType, &tasks);
    }

    // Multiple tasks (3+) - use parallel fork-join with work stealing
    const Context = struct {
        tasks: *const TasksType,
        results: *JoinResultType(TasksType),
    };

    parallel_for.parallelForWithGrain(fields.len, Context, Context{
        .tasks = &tasks,
        .results = &results,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // inline for unrolls at comptime, runtime check selects which to execute
            inline for (0..fields.len) |i| {
                if (i >= start and i < end) {
                    executeTaskByIndex(TasksType, ctx.tasks, ctx.results, i);
                }
            }
        }
    }.body, 1);

    return results;
}

/// Fast path for 2-task join - matches Rayon's optimized implementation.
/// 1. Fork task B (push to deque for potential stealing)
/// 2. Execute task A inline
/// 3. Join task B (pop if not stolen, wait if stolen)
fn join2Fast(comptime TasksType: type, tasks: *const TasksType) JoinResultType(TasksType) {
    const fields = @typeInfo(TasksType).@"struct".fields;
    const ResultType = JoinResultType(TasksType);
    const ReturnB = TaskReturnType(fields[1].type);

    // Context struct to pass through Future (pointer, not the actual function values)
    const FutureInput = struct {
        tasks_ptr: *const TasksType,
        results_ptr: *ResultType,
    };

    // Fast path: if already on a worker thread, use direct fork-join
    if (runtime.current_task) |task| {
        var results: ResultType = undefined;

        // Fork task B WITHOUT waking (idle workers actively steal)
        // This matches Rayon's behavior and avoids overhead at scale
        var future_b = Future(FutureInput, ReturnB).init();
        future_b.fork(task, struct {
            fn call(_: *Task, input: FutureInput) ReturnB {
                // Execute task B and return result
                const task_b = @field(input.tasks_ptr.*, fields[1].name);
                return executeTaskValue(task_b);
            }
        }.call, FutureInput{ .tasks_ptr = tasks, .results_ptr = &results });

        // Execute task A inline (like Rayon does)
        executeTaskByIndex(TasksType, tasks, &results, 0);

        // Join task B (pop if not stolen, wait and return result if stolen)
        @field(results, fields[1].name) = future_b.join(task) orelse blk: {
            // Not stolen - execute inline
            const task_b = @field(tasks.*, fields[1].name);
            break :blk executeTaskValue(task_b);
        };

        return results;
    }

    // Slow path: inject into pool
    const pool = runtime.getPool() orelse {
        // No pool - sequential
        var results: ResultType = undefined;
        executeTaskByIndex(TasksType, tasks, &results, 0);
        executeTaskByIndex(TasksType, tasks, &results, 1);
        return results;
    };

    return pool.call(ResultType, struct {
        fn compute(task: *Task, tasks_ptr: *const TasksType) ResultType {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

            var results: ResultType = undefined;

            // Fork task B (no wake - we'll work-steal while waiting)
            var future_b = Future(FutureInput, ReturnB).init();
            future_b.fork(task, struct {
                fn call(_: *Task, input: FutureInput) ReturnB {
                    const task_b = @field(input.tasks_ptr.*, fields[1].name);
                    return executeTaskValue(task_b);
                }
            }.call, FutureInput{ .tasks_ptr = tasks_ptr, .results_ptr = &results });

            // Execute task A inline
            executeTaskByIndex(TasksType, tasks_ptr, &results, 0);

            // Join task B
            @field(results, fields[1].name) = future_b.join(task) orelse blk: {
                const task_b = @field(tasks_ptr.*, fields[1].name);
                break :blk executeTaskValue(task_b);
            };

            return results;
        }
    }.compute, tasks);
}

// ============================================================================
// Task Execution Helpers
// ============================================================================

/// Execute task at comptime index and store result.
/// Works with both comptime and runtime task values.
pub fn executeTaskByIndex(
    comptime TasksType: type,
    tasks: *const TasksType,
    results: *JoinResultType(TasksType),
    comptime idx: usize,
) void {
    const fields = @typeInfo(TasksType).@"struct".fields;
    const field = fields[idx];
    const task_val = @field(tasks.*, field.name);
    @field(results.*, field.name) = executeTaskValue(task_val);
}

/// Execute a single task value (handles bare functions and tuples with args).
/// Works with runtime task values.
///
/// Note: Supports up to 10 arguments. This manual enumeration is required because
/// some arguments may be comptime types (like `type`), which can't be stored in
/// runtime variables or handled dynamically with @call.
pub fn executeTaskValue(task_val: anytype) TaskReturnType(@TypeOf(task_val)) {
    const FieldType = @TypeOf(task_val);
    const field_info = @typeInfo(FieldType);

    if (field_info == .@"struct" and field_info.@"struct".is_tuple) {
        // Tuple: (function, args...)
        const num_args = field_info.@"struct".fields.len - 1;
        if (num_args == 0) {
            return task_val[0]();
        } else if (num_args == 1) {
            return task_val[0](task_val[1]);
        } else if (num_args == 2) {
            return task_val[0](task_val[1], task_val[2]);
        } else if (num_args == 3) {
            return task_val[0](task_val[1], task_val[2], task_val[3]);
        } else if (num_args == 4) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4]);
        } else if (num_args == 5) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5]);
        } else if (num_args == 6) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5], task_val[6]);
        } else if (num_args == 7) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5], task_val[6], task_val[7]);
        } else if (num_args == 8) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5], task_val[6], task_val[7], task_val[8]);
        } else if (num_args == 9) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5], task_val[6], task_val[7], task_val[8], task_val[9]);
        } else if (num_args == 10) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5], task_val[6], task_val[7], task_val[8], task_val[9], task_val[10]);
        } else {
            @compileError("join supports up to 10 arguments per task. For more arguments, wrap them in a struct.");
        }
    } else {
        // Bare function pointer (no args)
        return task_val();
    }
}

// ============================================================================
// Type Computation Helpers
// ============================================================================

/// Get return type from a task value type (function or tuple).
pub fn TaskReturnType(comptime FieldType: type) type {
    const field_info = @typeInfo(FieldType);

    if (field_info == .@"struct" and field_info.@"struct".is_tuple) {
        const FnType = field_info.@"struct".fields[0].type;
        const fn_info = @typeInfo(FnType);
        if (fn_info == .pointer) {
            return @typeInfo(fn_info.pointer.child).@"fn".return_type.?;
        }
        return fn_info.@"fn".return_type.?;
    } else if (field_info == .@"fn") {
        return field_info.@"fn".return_type.?;
    } else if (field_info == .pointer) {
        return @typeInfo(field_info.pointer.child).@"fn".return_type.?;
    } else {
        @compileError("Task must be a function or tuple of (function, args...)");
    }
}

/// Compute the result type for a join operation.
/// Each field in the input becomes a field with the function's return type.
pub fn JoinResultType(comptime TasksType: type) type {
    const fields = @typeInfo(TasksType).@"struct".fields;
    var result_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, 0..) |field, i| {
        const ReturnType = getTaskReturnType(TasksType, field.name);
        result_fields[i] = .{
            .name = field.name,
            .type = ReturnType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(ReturnType),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &result_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Get the return type of a task (handles both bare functions and tuples with multiple args).
pub fn getTaskReturnType(comptime TasksType: type, comptime field_name: [:0]const u8) type {
    const FieldType = @TypeOf(@field(@as(TasksType, undefined), field_name));
    const field_info = @typeInfo(FieldType);

    if (field_info == .@"struct" and field_info.@"struct".is_tuple) {
        // Tuple: first element is the function, rest are args
        const FnType = field_info.@"struct".fields[0].type;
        return @typeInfo(FnType).@"fn".return_type.?;
    } else if (field_info == .@"fn" or field_info == .pointer) {
        // Bare function pointer
        const fn_info = if (field_info == .pointer)
            @typeInfo(field_info.pointer.child)
        else
            field_info;
        return fn_info.@"fn".return_type.?;
    } else {
        @compileError("Task must be a function or tuple of (function, args...)");
    }
}

// ============================================================================
// Comptime Join Helpers (for comptime task values)
// ============================================================================

/// Execute a single task from the tasks struct (comptime).
/// Supports: bare function, (function, arg), or (function, arg1, arg2, ...)
pub fn executeTask(
    comptime tasks: anytype,
    comptime field_name: [:0]const u8,
) getTaskReturnType(@TypeOf(tasks), field_name) {
    const task_val = @field(tasks, field_name);
    const FieldType = @TypeOf(task_val);
    const field_info = @typeInfo(FieldType);

    if (field_info == .@"struct" and field_info.@"struct".is_tuple) {
        // Tuple: (function, args...)
        const num_args = field_info.@"struct".fields.len - 1;
        if (num_args == 0) {
            return task_val[0]();
        } else if (num_args == 1) {
            return task_val[0](task_val[1]);
        } else if (num_args == 2) {
            return task_val[0](task_val[1], task_val[2]);
        } else if (num_args == 3) {
            return task_val[0](task_val[1], task_val[2], task_val[3]);
        } else if (num_args == 4) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4]);
        } else if (num_args == 5) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5]);
        } else if (num_args == 6) {
            return task_val[0](task_val[1], task_val[2], task_val[3], task_val[4], task_val[5], task_val[6]);
        } else {
            @compileError("join supports up to 6 arguments per task");
        }
    } else {
        // Bare function pointer (no args)
        return task_val();
    }
}

/// Binary tree implementation of join for work-stealing (comptime).
pub fn joinImpl(
    comptime tasks: anytype,
    comptime start: usize,
    comptime end: usize,
) JoinResultType(@TypeOf(tasks)) {
    const TasksType = @TypeOf(tasks);
    const fields = @typeInfo(TasksType).@"struct".fields;
    const len = end - start;

    if (len == 1) {
        const result = executeTask(tasks, fields[start].name);
        var ret: JoinResultType(TasksType) = undefined;
        @field(ret, fields[start].name) = result;
        return ret;
    }

    if (len == 2) {
        const left_name = fields[start].name;
        const right_name = fields[start + 1].name;

        const LeftRet = getTaskReturnType(TasksType, left_name);
        const RightRet = getTaskReturnType(TasksType, right_name);

        const pair = joinBinary(LeftRet, RightRet, tasks, left_name, right_name);

        var ret: JoinResultType(TasksType) = undefined;
        @field(ret, left_name) = pair[0];
        @field(ret, right_name) = pair[1];
        return ret;
    }

    // Recursive case: split into halves
    const mid = start + len / 2;

    const LeftResult = JoinResultSlice(TasksType, start, mid);
    const RightResult = JoinResultSlice(TasksType, mid, end);

    const pair = joinBinaryGeneric(
        LeftResult,
        RightResult,
        struct {
            fn left() LeftResult {
                return joinImplSlice(tasks, start, mid);
            }
        }.left,
        struct {
            fn right() RightResult {
                return joinImplSlice(tasks, mid, end);
            }
        }.right,
    );

    var ret: JoinResultType(TasksType) = undefined;
    inline for (fields[start..mid]) |field| {
        @field(ret, field.name) = @field(pair[0], field.name);
    }
    inline for (fields[mid..end]) |field| {
        @field(ret, field.name) = @field(pair[1], field.name);
    }
    return ret;
}

/// Result type for a slice of fields.
pub fn JoinResultSlice(comptime TasksType: type, comptime start: usize, comptime end: usize) type {
    const all_fields = @typeInfo(TasksType).@"struct".fields;
    const slice_fields = all_fields[start..end];
    var result_fields: [slice_fields.len]std.builtin.Type.StructField = undefined;

    for (slice_fields, 0..) |field, i| {
        const ReturnType = getTaskReturnType(TasksType, field.name);
        result_fields[i] = .{
            .name = field.name,
            .type = ReturnType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(ReturnType),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &result_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Implementation for a slice of tasks (comptime).
pub fn joinImplSlice(
    comptime tasks: anytype,
    comptime start: usize,
    comptime end: usize,
) JoinResultSlice(@TypeOf(tasks), start, end) {
    const TasksType = @TypeOf(tasks);
    const all_fields = @typeInfo(TasksType).@"struct".fields;
    const len = end - start;

    if (len == 1) {
        const result = executeTask(tasks, all_fields[start].name);
        var ret: JoinResultSlice(TasksType, start, end) = undefined;
        @field(ret, all_fields[start].name) = result;
        return ret;
    }

    if (len == 2) {
        const left_name = all_fields[start].name;
        const right_name = all_fields[start + 1].name;

        const LeftRet = getTaskReturnType(TasksType, left_name);
        const RightRet = getTaskReturnType(TasksType, right_name);

        const pair = joinBinary(LeftRet, RightRet, tasks, left_name, right_name);

        var ret: JoinResultSlice(TasksType, start, end) = undefined;
        @field(ret, left_name) = pair[0];
        @field(ret, right_name) = pair[1];
        return ret;
    }

    // Recursive case: split into halves
    const mid = start + len / 2;

    const LeftResult = JoinResultSlice(TasksType, start, mid);
    const RightResult = JoinResultSlice(TasksType, mid, end);

    const pair = joinBinaryGeneric(
        LeftResult,
        RightResult,
        struct {
            fn left() LeftResult {
                return joinImplSlice(tasks, start, mid);
            }
        }.left,
        struct {
            fn right() RightResult {
                return joinImplSlice(tasks, mid, end);
            }
        }.right,
    );

    var ret: JoinResultSlice(TasksType, start, end) = undefined;
    inline for (all_fields[start..mid]) |field| {
        @field(ret, field.name) = @field(pair[0], field.name);
    }
    inline for (all_fields[mid..end]) |field| {
        @field(ret, field.name) = @field(pair[1], field.name);
    }
    return ret;
}

/// Binary join for two named tasks (comptime).
pub fn joinBinary(
    comptime RA: type,
    comptime RB: type,
    comptime tasks: anytype,
    comptime left_name: [:0]const u8,
    comptime right_name: [:0]const u8,
) struct { RA, RB } {
    return joinBinaryGeneric(
        RA,
        RB,
        struct {
            fn left() RA {
                return executeTask(tasks, left_name);
            }
        }.left,
        struct {
            fn right() RB {
                return executeTask(tasks, right_name);
            }
        }.right,
    );
}

/// Core binary join implementation (comptime functions).
pub fn joinBinaryGeneric(
    comptime RA: type,
    comptime RB: type,
    comptime fn_a: fn () RA,
    comptime fn_b: fn () RB,
) struct { RA, RB } {
    const wrapper_a = struct {
        fn call(task: *Task, _: void) RA {
            _ = task;
            return fn_a();
        }
    }.call;

    const wrapper_b = struct {
        fn call(task: *Task, _: void) RB {
            _ = task;
            return fn_b();
        }
    }.call;

    // Fast path: if we're already inside a pool context
    if (runtime.current_task) |task| {
        var future_b = Future(void, RB).init();
        future_b.fork(task, wrapper_b, {});

        const result_a = task.call(RA, wrapper_a, {});
        const result_b = future_b.join(task) orelse wrapper_b(task, {});

        return .{ result_a, result_b };
    }

    // Get pool or fallback to sequential
    const pool = runtime.getPool() orelse {
        return .{ fn_a(), fn_b() };
    };

    // Slow path: create a new worker context
    return pool.call(struct { RA, RB }, struct {
        fn compute(task: *Task, _: void) struct { RA, RB } {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

            var future_b = Future(void, RB).init();
            future_b.fork(task, wrapper_b, {});

            const result_a = task.call(RA, wrapper_a, {});
            const result_b = future_b.join(task) orelse wrapper_b(task, {});

            return .{ result_a, result_b };
        }
    }.compute, {});
}

// ============================================================================
// Tests
// ============================================================================

test "join - two tasks no args" {
    const result = join(.{
        .a = struct {
            fn call() i32 {
                return 42;
            }
        }.call,
        .b = struct {
            fn call() i64 {
                return 100;
            }
        }.call,
    });

    try std.testing.expectEqual(@as(i32, 42), result.a);
    try std.testing.expectEqual(@as(i64, 100), result.b);
}

test "join - three tasks no args" {
    const result = join(.{
        .x = struct {
            fn call() i32 {
                return 1;
            }
        }.call,
        .y = struct {
            fn call() i64 {
                return 2;
            }
        }.call,
        .z = struct {
            fn call() f64 {
                return 3.0;
            }
        }.call,
    });

    try std.testing.expectEqual(@as(i32, 1), result.x);
    try std.testing.expectEqual(@as(i64, 2), result.y);
    try std.testing.expectEqual(@as(f64, 3.0), result.z);
}

test "join - tasks with arguments" {
    const double = struct {
        fn call(x: i32) i32 {
            return x * 2;
        }
    }.call;

    const triple = struct {
        fn call(x: i32) i32 {
            return x * 3;
        }
    }.call;

    const result = join(.{
        .doubled = .{ double, @as(i32, 5) },
        .tripled = .{ triple, @as(i32, 7) },
    });

    try std.testing.expectEqual(@as(i32, 10), result.doubled);
    try std.testing.expectEqual(@as(i32, 21), result.tripled);
}

test "join - single task" {
    const result = join(.{
        .only = struct {
            fn call() i32 {
                return 42;
            }
        }.call,
    });

    try std.testing.expectEqual(@as(i32, 42), result.only);
}

test "join - empty" {
    const result = join(.{});
    _ = result;
}
