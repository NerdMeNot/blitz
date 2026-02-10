//! Error-Safe Join operations for Blitz.
//!
//! Provides fork-join parallelism with error handling:
//! - tryJoin: Execute N error-returning tasks in parallel with error safety
//!
//! These variants ensure that all tasks complete even if some return errors.
//! This is critical for safety because tasks may reference data in the caller's
//! stack frame (via closures). If we propagate an error without waiting
//! for all tasks, the stack frame could be invalidated while tasks are still running.
//!
//! No matter what happens, all tasks will always be executed.
//!
//! Note on Zig panics: Unlike Rust, Zig panics are terminal and cannot be
//! caught. This error safety only applies to recoverable errors (error unions).
//! If a function calls @panic, the program will terminate regardless.

const std = @import("std");
const runtime = @import("runtime.zig");
const Task = runtime.Task;
const Future = runtime.Future;
const join_mod = @import("join.zig");

// ============================================================================
// Type Helpers for Error-Safe Join
// ============================================================================

/// Get the error set from a task's return type (must be error union).
pub fn getTaskErrorType(comptime TasksType: type, comptime field_name: [:0]const u8) type {
    const ReturnType = join_mod.getTaskReturnType(TasksType, field_name);
    const ret_info = @typeInfo(ReturnType);
    if (ret_info != .error_union) {
        @compileError("tryJoin tasks must return error unions. Use join() for non-error functions.");
    }
    return ret_info.error_union.error_set;
}

/// Get the payload type from an error union return type.
pub fn getTaskPayloadType(comptime TasksType: type, comptime field_name: [:0]const u8) type {
    const ReturnType = join_mod.getTaskReturnType(TasksType, field_name);
    const ret_info = @typeInfo(ReturnType);
    if (ret_info != .error_union) {
        @compileError("tryJoin tasks must return error unions. Use join() for non-error functions.");
    }
    return ret_info.error_union.payload;
}

/// Compute the result type for a tryJoin operation (payload types only).
pub fn TryJoinResultType(comptime TasksType: type) type {
    const fields = @typeInfo(TasksType).@"struct".fields;
    var result_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, 0..) |field, i| {
        const PayloadType = getTaskPayloadType(TasksType, field.name);
        result_fields[i] = .{
            .name = field.name,
            .type = PayloadType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(PayloadType),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &result_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Merge error sets from all tasks.
pub fn TryJoinErrorSet(comptime TasksType: type) type {
    const fields = @typeInfo(TasksType).@"struct".fields;
    var error_set = getTaskErrorType(TasksType, fields[0].name);

    inline for (fields[1..]) |field| {
        error_set = error_set || getTaskErrorType(TasksType, field.name);
    }

    return error_set;
}

// ============================================================================
// tryJoin() - Error-Safe Fork-Join API
// ============================================================================

/// Execute a single task that returns an error union.
fn executeTaskTry(
    comptime tasks: anytype,
    comptime field_name: [:0]const u8,
) TryJoinErrorSet(@TypeOf(tasks))!getTaskPayloadType(@TypeOf(tasks), field_name) {
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
            @compileError("tryJoin supports up to 6 arguments per task");
        }
    } else {
        // Bare function pointer (no args)
        return task_val();
    }
}

/// Execute N error-returning tasks in parallel with error safety.
///
/// All tasks are guaranteed to complete even if some return errors.
/// This is critical for safety - tasks may reference the caller's stack frame.
///
/// Usage:
/// ```zig
/// const result = try blitz.tryJoin(.{
///     .user = fetchUser,           // returns !User
///     .posts = fetchPosts,         // returns ![]Post
/// });
/// // result.user: User, result.posts: []Post
///
/// // With arguments:
/// const result = try blitz.tryJoin(.{
///     .user = .{ fetchUserById, user_id },
///     .posts = .{ fetchPostsByUser, user_id },
/// });
/// ```
pub fn tryJoin(comptime tasks: anytype) TryJoinErrorSet(@TypeOf(tasks))!TryJoinResultType(@TypeOf(tasks)) {
    const TasksType = @TypeOf(tasks);
    const fields = @typeInfo(TasksType).@"struct".fields;
    const E = TryJoinErrorSet(TasksType);
    const ResultType = TryJoinResultType(TasksType);

    if (fields.len == 0) {
        return .{};
    }

    if (fields.len == 1) {
        const result = try executeTaskTry(tasks, fields[0].name);
        var ret: ResultType = undefined;
        @field(ret, fields[0].name) = result;
        return ret;
    }

    // For 2+ tasks, use binary tree with error safety
    return tryJoinImpl(TasksType, E, tasks, 0, fields.len);
}

/// Binary tree implementation of tryJoin for work-stealing with error safety.
fn tryJoinImpl(
    comptime TasksType: type,
    comptime E: type,
    comptime tasks: TasksType,
    comptime start: usize,
    comptime end: usize,
) E!TryJoinResultType(TasksType) {
    const fields = @typeInfo(TasksType).@"struct".fields;
    const len = end - start;
    const ResultType = TryJoinResultType(TasksType);

    if (len == 1) {
        const result = try executeTaskTry(tasks, fields[start].name);
        var ret: ResultType = undefined;
        @field(ret, fields[start].name) = result;
        return ret;
    }

    if (len == 2) {
        const left_name = fields[start].name;
        const right_name = fields[start + 1].name;

        const LeftPayload = getTaskPayloadType(TasksType, left_name);
        const RightPayload = getTaskPayloadType(TasksType, right_name);

        const pair = try tryJoinBinary(
            LeftPayload,
            RightPayload,
            E,
            TasksType,
            tasks,
            left_name,
            right_name,
        );

        var ret: ResultType = undefined;
        @field(ret, left_name) = pair[0];
        @field(ret, right_name) = pair[1];
        return ret;
    }

    // Recursive case: split into halves
    const mid = start + len / 2;

    const LeftResult = TryJoinResultSlice(TasksType, start, mid);
    const RightResult = TryJoinResultSlice(TasksType, mid, end);

    const pair = try tryJoinBinaryGeneric(
        LeftResult,
        RightResult,
        E,
        struct {
            fn left() E!LeftResult {
                return tryJoinImplSlice(TasksType, E, tasks, start, mid);
            }
        }.left,
        struct {
            fn right() E!RightResult {
                return tryJoinImplSlice(TasksType, E, tasks, mid, end);
            }
        }.right,
    );

    var ret: ResultType = undefined;
    inline for (fields[start..mid]) |field| {
        @field(ret, field.name) = @field(pair[0], field.name);
    }
    inline for (fields[mid..end]) |field| {
        @field(ret, field.name) = @field(pair[1], field.name);
    }
    return ret;
}

/// Result type for a slice of tryJoin fields.
fn TryJoinResultSlice(comptime TasksType: type, comptime start: usize, comptime end: usize) type {
    const all_fields = @typeInfo(TasksType).@"struct".fields;
    const slice_fields = all_fields[start..end];
    var result_fields: [slice_fields.len]std.builtin.Type.StructField = undefined;

    for (slice_fields, 0..) |field, i| {
        const PayloadType = getTaskPayloadType(TasksType, field.name);
        result_fields[i] = .{
            .name = field.name,
            .type = PayloadType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(PayloadType),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &result_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Implementation for a slice of tryJoin tasks.
fn tryJoinImplSlice(
    comptime TasksType: type,
    comptime E: type,
    comptime tasks: TasksType,
    comptime start: usize,
    comptime end: usize,
) E!TryJoinResultSlice(TasksType, start, end) {
    const all_fields = @typeInfo(TasksType).@"struct".fields;
    const len = end - start;
    const ResultType = TryJoinResultSlice(TasksType, start, end);

    if (len == 1) {
        const result = try executeTaskTry(tasks, all_fields[start].name);
        var ret: ResultType = undefined;
        @field(ret, all_fields[start].name) = result;
        return ret;
    }

    if (len == 2) {
        const left_name = all_fields[start].name;
        const right_name = all_fields[start + 1].name;

        const LeftPayload = getTaskPayloadType(TasksType, left_name);
        const RightPayload = getTaskPayloadType(TasksType, right_name);

        const pair = try tryJoinBinary(LeftPayload, RightPayload, E, TasksType, tasks, left_name, right_name);

        var ret: ResultType = undefined;
        @field(ret, left_name) = pair[0];
        @field(ret, right_name) = pair[1];
        return ret;
    }

    // Recursive split
    const mid = start + len / 2;

    const LeftResult = TryJoinResultSlice(TasksType, start, mid);
    const RightResult = TryJoinResultSlice(TasksType, mid, end);

    const pair = try tryJoinBinaryGeneric(
        LeftResult,
        RightResult,
        E,
        struct {
            fn left() E!LeftResult {
                return tryJoinImplSlice(TasksType, E, tasks, start, mid);
            }
        }.left,
        struct {
            fn right() E!RightResult {
                return tryJoinImplSlice(TasksType, E, tasks, mid, end);
            }
        }.right,
    );

    var ret: ResultType = undefined;
    inline for (all_fields[start..mid]) |field| {
        @field(ret, field.name) = @field(pair[0], field.name);
    }
    inline for (all_fields[mid..end]) |field| {
        @field(ret, field.name) = @field(pair[1], field.name);
    }
    return ret;
}

/// Binary tryJoin for two named tasks.
fn tryJoinBinary(
    comptime RA: type,
    comptime RB: type,
    comptime E: type,
    comptime TasksType: type,
    comptime tasks: TasksType,
    comptime left_name: [:0]const u8,
    comptime right_name: [:0]const u8,
) E!struct { RA, RB } {
    return tryJoinBinaryGeneric(
        RA,
        RB,
        E,
        struct {
            fn left() E!RA {
                return executeTaskTry(tasks, left_name);
            }
        }.left,
        struct {
            fn right() E!RB {
                return executeTaskTry(tasks, right_name);
            }
        }.right,
    );
}

/// Core binary tryJoin implementation with error safety.
fn tryJoinBinaryGeneric(
    comptime RA: type,
    comptime RB: type,
    comptime E: type,
    comptime fn_a: fn () E!RA,
    comptime fn_b: fn () E!RB,
) E!struct { RA, RB } {
    const wrapper_a = struct {
        fn call(task: *Task, _: void) E!RA {
            _ = task;
            return fn_a();
        }
    }.call;

    const wrapper_b = struct {
        fn call(task: *Task, _: void) E!RB {
            _ = task;
            return fn_b();
        }
    }.call;

    // Fast path: if we're already inside a pool context
    if (runtime.current_task) |task| {
        return tryJoinBinaryImpl(RA, RB, E, wrapper_a, wrapper_b, task);
    }

    // Get pool or fallback to sequential (still error-safe: both tasks always run)
    const pool = runtime.getPool() orelse {
        var error_a: ?E = null;
        var result_a: RA = undefined;
        if (fn_a()) |ra| {
            result_a = ra;
        } else |err| {
            error_a = err;
        }
        var error_b: ?E = null;
        var result_b: RB = undefined;
        if (fn_b()) |rb| {
            result_b = rb;
        } else |err| {
            error_b = err;
        }
        // A's error takes priority (matches parallel implementation)
        if (error_a) |err| return err;
        if (error_b) |err| return err;
        return .{ result_a, result_b };
    };

    return pool.call(E!struct { RA, RB }, struct {
        fn compute(task: *Task, _: void) E!struct { RA, RB } {
            const prev_task = runtime.current_task;
            runtime.current_task = task;
            defer runtime.current_task = prev_task;

            return tryJoinBinaryImpl(RA, RB, E, wrapper_a, wrapper_b, task);
        }
    }.compute, {});
}

/// Implementation of binary tryJoin with error safety.
fn tryJoinBinaryImpl(
    comptime RA: type,
    comptime RB: type,
    comptime E: type,
    comptime wrapper_a: fn (*Task, void) E!RA,
    comptime wrapper_b: fn (*Task, void) E!RB,
    task: *Task,
) E!struct { RA, RB } {
    var future_b = Future(void, E!RB).init();
    future_b.fork(task, wrapper_b, {});

    // Execute A - capture any error
    var error_a: ?E = null;
    var result_a: RA = undefined;

    if (task.call(E!RA, wrapper_a, {})) |ra| {
        result_a = ra;
    } else |err| {
        error_a = err;
    }

    // CRITICAL: Always wait for B to complete, even if A errored
    const result_b_or_null = future_b.join(task);
    const result_b_union: E!RB = result_b_or_null orelse wrapper_b(task, {});

    // Propagate errors - A's error takes priority
    if (error_a) |err| {
        return err;
    }

    const result_b = try result_b_union;
    return .{ result_a, result_b };
}

// ============================================================================
// Tests
// ============================================================================

test "tryJoin - both succeed" {
    const TestError = error{TestFailed};

    const result = tryJoin(.{
        .a = struct {
            fn call() TestError!i32 {
                return 5 * 2;
            }
        }.call,
        .b = struct {
            fn call() TestError!i32 {
                return 7 * 3;
            }
        }.call,
    });
    const values = try result;

    try std.testing.expectEqual(@as(i32, 10), values.a);
    try std.testing.expectEqual(@as(i32, 21), values.b);
}

// Module-level state for error-safety test
var tryJoin_b_completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

test "tryJoin - A fails, B still completes" {
    const TestError = error{AFailed};
    tryJoin_b_completed.store(false, .release);

    const result = tryJoin(.{
        .a = struct {
            fn call() TestError!i32 {
                return TestError.AFailed;
            }
        }.call,
        .b = struct {
            fn call() TestError!i32 {
                // Simulate some work
                for (0..100) |_| {
                    std.atomic.spinLoopHint();
                }
                tryJoin_b_completed.store(true, .release);
                return 42;
            }
        }.call,
    });

    // Should return A's error
    try std.testing.expectError(TestError.AFailed, result);

    // B should have completed before error was propagated
    try std.testing.expect(tryJoin_b_completed.load(.acquire));
}

test "tryJoin - B fails" {
    const TestError = error{BFailed};

    const result = tryJoin(.{
        .a = struct {
            fn call() TestError!i32 {
                return 5 * 2;
            }
        }.call,
        .b = struct {
            fn call() TestError!i32 {
                return TestError.BFailed;
            }
        }.call,
    });

    try std.testing.expectError(TestError.BFailed, result);
}

test "tryJoin - both fail, A's error takes priority" {
    const TestError = error{ AFailed, BFailed };

    const result = tryJoin(.{
        .a = struct {
            fn call() TestError!i32 {
                return TestError.AFailed;
            }
        }.call,
        .b = struct {
            fn call() TestError!i32 {
                return TestError.BFailed;
            }
        }.call,
    });

    // A's error takes priority
    try std.testing.expectError(TestError.AFailed, result);
}

// Module-level state for void functions test
var tryJoin_void_a_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var tryJoin_void_b_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

test "tryJoin - void functions both succeed" {
    const TestError = error{TestFailed};
    tryJoin_void_a_called.store(false, .release);
    tryJoin_void_b_called.store(false, .release);

    const result = tryJoin(.{
        .a = struct {
            fn call() TestError!void {
                tryJoin_void_a_called.store(true, .release);
            }
        }.call,
        .b = struct {
            fn call() TestError!void {
                tryJoin_void_b_called.store(true, .release);
            }
        }.call,
    });

    _ = try result;

    try std.testing.expect(tryJoin_void_a_called.load(.acquire));
    try std.testing.expect(tryJoin_void_b_called.load(.acquire));
}
