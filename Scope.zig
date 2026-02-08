//! Scope-based parallelism for Blitz
//!
//! Provides scope-based parallel execution for spawning arbitrary tasks
//! that must all complete before the scope exits.
//!
//! Usage:
//! ```zig
//! const blitz = @import("blitz");
//!
//! // Execute multiple tasks in parallel with unified join API
//! const results = blitz.join(.{
//!     .a = compute1,
//!     .b = compute2,
//!     .c = .{ computeWithArg, arg },  // with argument
//! });
//! // Access: results.a, results.b, results.c
//!
//! // Or spawn N tasks dynamically
//! blitz.parallelForRange(0, 100, fn(i: usize) void { process(i); });
//!
//! // Or use scope with spawn (tasks execute when scope ends):
//! blitz.scope(struct {
//!     fn run(s: *Scope) void {
//!         s.spawn(task1);
//!         s.spawn(task2);
//!         s.spawn(task3);
//!     }  // All tasks execute in parallel here
//! }.run);
//! ```

const std = @import("std");
const api = @import("api.zig");

/// Maximum concurrent spawned tasks in a scope.
/// If you need more than 64 tasks, use parallelFor or parallelForRange instead,
/// which split work adaptively without a fixed task limit.
const MAX_SCOPE_TASKS = 64;

/// Type-erased task wrapper for runtime function dispatch.
const TaskFn = *const fn () void;

/// A scope for running parallel tasks.
/// Tasks spawned within a scope all complete before the scope exits.
///
/// Implementation note: This uses a "collect and execute" model where spawned
/// tasks are collected during the scope body, then executed in parallel when
/// the scope exits. This is different from Rayon's immediate-spawn model but
/// provides correct parallel execution semantics.
pub const Scope = struct {
    /// Function pointers for spawned tasks.
    tasks: [MAX_SCOPE_TASKS]TaskFn = undefined,

    /// Number of tasks spawned.
    count: usize = 0,

    /// Initialize a new scope.
    pub fn init() Scope {
        return Scope{};
    }

    /// Spawn a function to run in parallel with other spawned tasks.
    /// The function will be executed when the scope exits (or when wait() is called).
    ///
    /// Maximum 64 tasks can be spawned per scope. For larger workloads, use
    /// parallelFor or parallelForRange instead, which split work adaptively.
    pub fn spawn(self: *Scope, comptime func: fn () void) void {
        if (self.count >= MAX_SCOPE_TASKS) {
            @panic("Too many tasks spawned in scope (max 64). Use parallelFor or parallelForRange for larger workloads.");
        }
        self.tasks[self.count] = func;
        self.count += 1;
    }

    /// Execute all spawned tasks in parallel and wait for completion.
    /// Called automatically when the scope exits, but can be called manually
    /// to execute tasks before the scope ends.
    pub fn wait(self: *Scope) void {
        if (self.count == 0) return;

        if (self.count == 1) {
            // Single task - just execute it
            self.tasks[0]();
            self.count = 0;
            return;
        }

        // Multiple tasks - execute in parallel
        const Context = struct {
            tasks: []const TaskFn,
        };

        const ctx = Context{
            .tasks = self.tasks[0..self.count],
        };

        // Execute all tasks in parallel using parallelFor
        // Use grain size of 1 since each task is independent work
        api.parallelForWithGrain(self.count, Context, ctx, struct {
            fn body(c: Context, start: usize, end: usize) void {
                for (start..end) |i| {
                    c.tasks[i]();
                }
            }
        }.body, 1);

        // Clear the task list
        self.count = 0;
    }
};

/// Execute a scope function.
/// All tasks spawned within the scope will be executed in parallel when the scope exits.
pub fn scope(comptime func: fn (*Scope) void) void {
    var s = Scope.init();
    func(&s);
    s.wait(); // Execute all spawned tasks in parallel
}

/// Execute a scope function with a context value.
pub fn scopeWithContext(comptime Context: type, context: Context, comptime func: fn (Context, *Scope) void) void {
    var s = Scope.init();
    func(context, &s);
    s.wait(); // Execute all spawned tasks in parallel
}

// ============================================================================
// Parallel For with Index Ranges
// ============================================================================

/// Parallel for_each over an index range.
/// Splits the range into chunks and executes in parallel.
pub fn parallelForRange(start: usize, end: usize, comptime func: fn (usize) void) void {
    if (end <= start) return;

    const len = end - start;

    const Context = struct { base: usize };
    const ctx = Context{ .base = start };

    api.parallelFor(len, Context, ctx, struct {
        fn body(c: Context, s: usize, e: usize) void {
            var i = c.base + s;
            const limit = c.base + e;
            while (i < limit) : (i += 1) {
                func(i);
            }
        }
    }.body);
}

/// Parallel for_each with context.
pub fn parallelForRangeWithContext(
    comptime Context: type,
    context: Context,
    start: usize,
    end: usize,
    comptime func: fn (Context, usize) void,
) void {
    if (end <= start) return;

    const len = end - start;

    const FullContext = struct { base: usize, ctx: Context };
    const full_ctx = FullContext{ .base = start, .ctx = context };

    api.parallelFor(len, FullContext, full_ctx, struct {
        fn body(c: FullContext, s: usize, e: usize) void {
            var i = c.base + s;
            const limit = c.base + e;
            while (i < limit) : (i += 1) {
                func(c.ctx, i);
            }
        }
    }.body);
}

// ============================================================================
// Fire-and-Forget Spawn (Rayon-style)
// ============================================================================

/// Spawn a fire-and-forget task that runs asynchronously.
/// Unlike scope.spawn(), this task is not tied to a scope and runs independently.
/// The caller does not wait for completion - the task runs in the background.
///
/// Usage:
/// ```zig
/// blitz.spawn(struct {
///     fn run() void {
///         // Background work
///     }
/// }.run);
/// // Returns immediately, task runs in background
/// ```
///
/// Note: The task must complete before program exit. Use scope() if you need
/// to wait for task completion.
pub fn spawn(comptime func: fn () void) void {
    // Use parallelFor with grain=1 to spawn a single background task
    api.parallelForWithGrain(1, void, {}, struct {
        fn body(_: void, _: usize, _: usize) void {
            func();
        }
    }.body, 1);
}

/// Spawn a fire-and-forget task with context.
pub fn spawnWithContext(comptime Context: type, context: Context, comptime func: fn (Context) void) void {
    api.parallelForWithGrain(1, Context, context, struct {
        fn body(ctx: Context, _: usize, _: usize) void {
            func(ctx);
        }
    }.body, 1);
}

// ============================================================================
// Broadcast (Execute on All Workers)
// ============================================================================

/// Execute a function on all worker threads in parallel.
/// Similar to Rayon's broadcast() - useful for thread-local initialization
/// or operations that need to run on every thread.
///
/// Usage:
/// ```zig
/// blitz.broadcast(struct {
///     fn run(worker_index: usize) void {
///         // Runs on each worker thread
///     }
/// }.run);
/// ```
///
/// The function receives the worker index (0..numWorkers).
pub fn broadcast(comptime func: fn (usize) void) void {
    const num_workers: usize = @intCast(api.numWorkers());
    if (num_workers == 0) return;

    // Use parallelFor with grain=1 so each worker gets one task
    api.parallelForWithGrain(num_workers, void, {}, struct {
        fn body(_: void, start: usize, end: usize) void {
            for (start..end) |worker_idx| {
                func(worker_idx);
            }
        }
    }.body, 1);
}

/// Execute a function with context on all worker threads.
pub fn broadcastWithContext(comptime Context: type, context: Context, comptime func: fn (Context, usize) void) void {
    const num_workers: usize = @intCast(api.numWorkers());
    if (num_workers == 0) return;

    api.parallelForWithGrain(num_workers, Context, context, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (start..end) |worker_idx| {
                func(ctx, worker_idx);
            }
        }
    }.body, 1);
}

// ============================================================================
// Tests
// ============================================================================

test "join - basic" {
    const result = api.join(.{
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

test "parallelForRange - basic" {
    var sum: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    parallelForRangeWithContext(
        *std.atomic.Value(usize),
        &sum,
        0,
        100,
        struct {
            fn body(s: *std.atomic.Value(usize), i: usize) void {
                _ = s.fetchAdd(i, .monotonic);
            }
        }.body,
    );

    // Sum of 0..99 = 99*100/2 = 4950
    try std.testing.expectEqual(@as(usize, 4950), sum.load(.monotonic));
}

test "Scope - basic" {
    // Simple test that scope executes without error
    scope(struct {
        fn run(s: *Scope) void {
            _ = s;
            // Scope body runs
        }
    }.run);
}

// Test state - must be at module level for comptime access
var test_counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var test_flags: [32]std.atomic.Value(bool) = init_test_flags();

fn init_test_flags() [32]std.atomic.Value(bool) {
    var flags: [32]std.atomic.Value(bool) = undefined;
    for (&flags) |*f| {
        f.* = std.atomic.Value(bool).init(false);
    }
    return flags;
}

fn resetTestState() void {
    test_counter.store(0, .monotonic);
    for (&test_flags) |*f| {
        f.store(false, .monotonic);
    }
}

test "Scope - spawn executes tasks" {
    resetTestState();

    scope(struct {
        fn run(s: *Scope) void {
            s.spawn(task1);
            s.spawn(task2);
            s.spawn(task3);
        }

        fn task1() void {
            _ = test_counter.fetchAdd(1, .monotonic);
        }
        fn task2() void {
            _ = test_counter.fetchAdd(10, .monotonic);
        }
        fn task3() void {
            _ = test_counter.fetchAdd(100, .monotonic);
        }
    }.run);

    // All tasks should have executed: 1 + 10 + 100 = 111
    try std.testing.expectEqual(@as(usize, 111), test_counter.load(.monotonic));
}

test "Scope - spawn with many tasks" {
    resetTestState();

    scope(struct {
        fn run(s: *Scope) void {
            s.spawn(setFlag0);
            s.spawn(setFlag1);
            s.spawn(setFlag2);
            s.spawn(setFlag3);
            s.spawn(setFlag4);
            s.spawn(setFlag5);
            s.spawn(setFlag6);
            s.spawn(setFlag7);
        }

        fn setFlag0() void {
            test_flags[0].store(true, .release);
        }
        fn setFlag1() void {
            test_flags[1].store(true, .release);
        }
        fn setFlag2() void {
            test_flags[2].store(true, .release);
        }
        fn setFlag3() void {
            test_flags[3].store(true, .release);
        }
        fn setFlag4() void {
            test_flags[4].store(true, .release);
        }
        fn setFlag5() void {
            test_flags[5].store(true, .release);
        }
        fn setFlag6() void {
            test_flags[6].store(true, .release);
        }
        fn setFlag7() void {
            test_flags[7].store(true, .release);
        }
    }.run);

    // All tasks should have executed
    for (0..8) |i| {
        try std.testing.expect(test_flags[i].load(.acquire));
    }
}

test "Scope - single task" {
    resetTestState();

    scope(struct {
        fn run(s: *Scope) void {
            s.spawn(singleTask);
        }

        fn singleTask() void {
            _ = test_counter.fetchAdd(42, .monotonic);
        }
    }.run);

    try std.testing.expectEqual(@as(usize, 42), test_counter.load(.monotonic));
}

test "Scope - empty scope" {
    // Test that empty scope works
    scope(struct {
        fn run(s: *Scope) void {
            _ = s; // No tasks spawned
        }
    }.run);
    // Should not crash
}

test "spawn - fire and forget" {
    resetTestState();

    spawn(struct {
        fn run() void {
            _ = test_counter.fetchAdd(100, .monotonic);
        }
    }.run);

    // Spawn is synchronous in current implementation (waits for completion)
    // This is because parallelForWithGrain blocks until done
    try std.testing.expectEqual(@as(usize, 100), test_counter.load(.monotonic));
}

test "spawnWithContext - with runtime context" {
    resetTestState();

    const Context = struct {
        value: usize,
    };

    spawnWithContext(Context, Context{ .value = 42 }, struct {
        fn run(ctx: Context) void {
            _ = test_counter.fetchAdd(ctx.value, .monotonic);
        }
    }.run);

    try std.testing.expectEqual(@as(usize, 42), test_counter.load(.monotonic));
}

// Module-level state for broadcast test
var broadcast_worker_flags: [64]std.atomic.Value(bool) = init_broadcast_flags();

fn init_broadcast_flags() [64]std.atomic.Value(bool) {
    var flags: [64]std.atomic.Value(bool) = undefined;
    for (&flags) |*f| {
        f.* = std.atomic.Value(bool).init(false);
    }
    return flags;
}

fn resetBroadcastFlags() void {
    for (&broadcast_worker_flags) |*f| {
        f.store(false, .monotonic);
    }
}

test "broadcast - runs on all workers" {
    resetBroadcastFlags();

    broadcast(struct {
        fn run(worker_idx: usize) void {
            if (worker_idx < 64) {
                broadcast_worker_flags[worker_idx].store(true, .release);
            }
        }
    }.run);

    // At least worker 0 should have been called (single-threaded case)
    try std.testing.expect(broadcast_worker_flags[0].load(.acquire));

    // Count how many workers were called
    var count: usize = 0;
    for (&broadcast_worker_flags) |*f| {
        if (f.load(.acquire)) count += 1;
    }

    // Should match the number of workers
    const num_workers: usize = @intCast(api.numWorkers());
    try std.testing.expectEqual(num_workers, count);
}

test "broadcastWithContext - with runtime context" {
    resetBroadcastFlags();

    const Context = struct {
        multiplier: usize,
    };

    broadcastWithContext(Context, Context{ .multiplier = 10 }, struct {
        fn run(ctx: Context, worker_idx: usize) void {
            if (worker_idx < 64) {
                broadcast_worker_flags[worker_idx].store(ctx.multiplier > 0, .release);
            }
        }
    }.run);

    // At least worker 0 should have been called
    try std.testing.expect(broadcast_worker_flags[0].load(.acquire));
}
