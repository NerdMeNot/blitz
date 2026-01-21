//! Scope-based parallelism for Blitz
//!
//! Provides scope-based parallel execution for spawning arbitrary tasks
//! that must all complete before the scope exits.
//!
//! Usage:
//! ```zig
//! const blitz = @import("blitz");
//!
//! // Execute multiple tasks in parallel
//! const results = blitz.join2(i64, i64,
//!     fn() i64 { return compute1(); },
//!     fn() i64 { return compute2(); },
//! );
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
    /// Maximum MAX_SCOPE_TASKS tasks can be spawned per scope.
    pub fn spawn(self: *Scope, comptime func: fn () void) void {
        if (self.count >= MAX_SCOPE_TASKS) {
            @panic("Too many tasks spawned in scope (max 64)");
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
// Convenience Functions for Common Patterns
// ============================================================================

/// Execute two functions in parallel and return their results.
pub fn join2(
    comptime A: type,
    comptime B: type,
    comptime func_a: fn () A,
    comptime func_b: fn () B,
) struct { A, B } {
    return api.join(
        A,
        B,
        struct {
            fn wrapA(_: void) A {
                return func_a();
            }
        }.wrapA,
        struct {
            fn wrapB(_: void) B {
                return func_b();
            }
        }.wrapB,
        {},
        {},
    );
}

/// Execute three functions in parallel and return their results.
pub fn join3(
    comptime A: type,
    comptime B: type,
    comptime C: type,
    comptime func_a: fn () A,
    comptime func_b: fn () B,
    comptime func_c: fn () C,
) struct { A, B, C } {
    // Execute A in parallel with (B || C)
    const ab = api.join(
        A,
        struct { B, C },
        struct {
            fn wrapA(_: void) A {
                return func_a();
            }
        }.wrapA,
        struct {
            fn wrapBC(_: void) struct { B, C } {
                return api.join(
                    B,
                    C,
                    struct {
                        fn wrapB(_: void) B {
                            return func_b();
                        }
                    }.wrapB,
                    struct {
                        fn wrapC(_: void) C {
                            return func_c();
                        }
                    }.wrapC,
                    {},
                    {},
                );
            }
        }.wrapBC,
        {},
        {},
    );

    return .{ ab[0], ab[1][0], ab[1][1] };
}

/// Execute N functions in parallel using an array of function pointers.
/// Note: Limited to functions returning the same type.
pub fn joinN(comptime T: type, comptime N: usize, funcs: *const [N]fn () T) [N]T {
    var results: [N]T = undefined;

    if (N == 0) return results;
    if (N == 1) {
        results[0] = funcs[0]();
        return results;
    }

    // Use parallelFor pattern for N tasks
    const Context = struct {
        funcs: *const [N]fn () T,
        results: *[N]T,
    };
    const ctx = Context{ .funcs = funcs, .results = &results };

    api.parallelFor(N, Context, ctx, struct {
        fn body(c: Context, start: usize, end: usize) void {
            for (start..end) |i| {
                c.results[i] = c.funcs[i]();
            }
        }
    }.body);

    return results;
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
// Tests
// ============================================================================

test "join2 - basic" {
    const result = join2(
        i32,
        i64,
        struct {
            fn a() i32 {
                return 42;
            }
        }.a,
        struct {
            fn b() i64 {
                return 100;
            }
        }.b,
    );

    try std.testing.expectEqual(@as(i32, 42), result[0]);
    try std.testing.expectEqual(@as(i64, 100), result[1]);
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
