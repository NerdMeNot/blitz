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
    if (!isInitialized()) {
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

    parallelForWithGrain(fields.len, Context, Context{
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
    if (current_task) |task| {
        var results: ResultType = undefined;

        // Fork task B WITHOUT waking (idle workers actively steal)
        // This matches Rayon's behavior and avoids overhead at scale
        var future_b = Future(FutureInput, ReturnB).init();
        future_b.forkSmartWake(task, struct {
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
    const pool = getPool() orelse {
        // No pool - sequential
        var results: ResultType = undefined;
        executeTaskByIndex(TasksType, tasks, &results, 0);
        executeTaskByIndex(TasksType, tasks, &results, 1);
        return results;
    };

    return pool.call(ResultType, struct {
        fn compute(task: *Task, tasks_ptr: *const TasksType) ResultType {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            var results: ResultType = undefined;

            // Fork task B (no wake - we'll work-steal while waiting)
            var future_b = Future(FutureInput, ReturnB).init();
            future_b.forkSmartWake(task, struct {
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

/// Execute task at comptime index and store result.
/// Works with both comptime and runtime task values.
fn executeTaskByIndex(
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
fn executeTaskValue(task_val: anytype) TaskReturnType(@TypeOf(task_val)) {
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

/// Get return type from a task value type (function or tuple).
fn TaskReturnType(comptime FieldType: type) type {
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
fn JoinResultType(comptime TasksType: type) type {
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
fn getTaskReturnType(comptime TasksType: type, comptime field_name: [:0]const u8) type {
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

/// Execute a single task from the tasks struct (comptime).
/// Supports: bare function, (function, arg), or (function, arg1, arg2, ...)
fn executeTask(
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
fn joinImpl(
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
fn JoinResultSlice(comptime TasksType: type, comptime start: usize, comptime end: usize) type {
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
fn joinImplSlice(
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
fn joinBinary(
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
fn joinBinaryGeneric(
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
    if (current_task) |task| {
        var future_b = Future(void, RB).init();
        future_b.fork(task, wrapper_b, {});

        const result_a = task.call(RA, wrapper_a, {});
        const result_b = future_b.join(task) orelse wrapper_b(task, {});

        return .{ result_a, result_b };
    }

    // Get pool or fallback to sequential
    const pool = getPool() orelse {
        return .{ fn_a(), fn_b() };
    };

    // Slow path: create a new worker context
    return pool.call(struct { RA, RB }, struct {
        fn compute(task: *Task, _: void) struct { RA, RB } {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

            var future_b = Future(void, RB).init();
            future_b.fork(task, wrapper_b, {});

            const result_a = task.call(RA, wrapper_a, {});
            const result_b = future_b.join(task) orelse wrapper_b(task, {});

            return .{ result_a, result_b };
        }
    }.compute, {});
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

/// Get the error set from a task's return type (must be error union).
fn getTaskErrorType(comptime TasksType: type, comptime field_name: [:0]const u8) type {
    const ReturnType = getTaskReturnType(TasksType, field_name);
    const ret_info = @typeInfo(ReturnType);
    if (ret_info != .error_union) {
        @compileError("tryJoin tasks must return error unions. Use join() for non-error functions.");
    }
    return ret_info.error_union.error_set;
}

/// Get the payload type from an error union return type.
fn getTaskPayloadType(comptime TasksType: type, comptime field_name: [:0]const u8) type {
    const ReturnType = getTaskReturnType(TasksType, field_name);
    const ret_info = @typeInfo(ReturnType);
    if (ret_info != .error_union) {
        @compileError("tryJoin tasks must return error unions. Use join() for non-error functions.");
    }
    return ret_info.error_union.payload;
}

/// Compute the result type for a tryJoin operation (payload types only).
fn TryJoinResultType(comptime TasksType: type) type {
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
fn TryJoinErrorSet(comptime TasksType: type) type {
    const fields = @typeInfo(TasksType).@"struct".fields;
    var error_set = getTaskErrorType(TasksType, fields[0].name);

    inline for (fields[1..]) |field| {
        error_set = error_set || getTaskErrorType(TasksType, field.name);
    }

    return error_set;
}

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
    if (current_task) |task| {
        return tryJoinBinaryImpl(RA, RB, E, wrapper_a, wrapper_b, task);
    }

    // Get pool or fallback to sequential
    const pool = getPool() orelse {
        const result_a = try fn_a();
        const result_b = try fn_b();
        return .{ result_a, result_b };
    };

    return pool.call(E!struct { RA, RB }, struct {
        fn compute(task: *Task, _: void) E!struct { RA, RB } {
            const prev_task = current_task;
            current_task = task;
            defer current_task = prev_task;

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
    const slice2 = [_]u32{3};

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

    // A's error takes priority (Rayon behavior)
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
// Unified Join API Tests
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
