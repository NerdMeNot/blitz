//! Future for Blitz - Fork-Join Parallelism
//!
//! Future(Input, Output) enables fork-join parallelism with return values.
//! The future is stack-allocated and uses comptime specialization to
//! eliminate vtable overhead.
//!
//! Design:
//! - Future owns a Job that gets pushed to the deque
//! - Future embeds a latch for completion signaling (no allocation!)
//! - Fork: push job to deque, job is instantly visible to thieves
//! - Join: try to pop (if at bottom of deque), else wait on embedded latch
//!
//! The latch is embedded in the Future, not allocated separately.
//! This eliminates the race condition where owner waits before thief allocates.
//!
//! Usage:
//! ```zig
//! var future = Future(i32, i64).init();
//! future.fork(&task, compute, input_value);
//! // ... do other work ...
//! const result = future.join(&task) orelse compute(&task, input_value);
//! ```

const std = @import("std");
const pool_mod = @import("Pool.zig");
const Job = pool_mod.Job;
const Task = pool_mod.Task;
const Worker = pool_mod.Worker;
const OnceLatch = @import("Latch.zig").OnceLatch;

/// A future represents a computation that may run on another thread.
///
/// The latch is embedded to avoid allocation and eliminate races.
/// Size: Job (8) + OnceLatch (4) + Input + Output
pub fn Future(comptime Input: type, comptime Output: type) type {
    return struct {
        const Self = @This();

        /// The underlying job (pushed to deque).
        job: Job,

        /// Embedded latch for completion signaling.
        /// When the job is stolen and executed by a thief, the thief signals this.
        /// The owner waits on this if they can't pop their job back.
        latch: OnceLatch,

        /// Input value to pass to the function.
        input: Input,

        /// Result storage (written by thief if stolen).
        result: Output,

        /// Create a new pending future.
        pub inline fn init() Self {
            return Self{
                .job = Job.init(),
                .latch = OnceLatch.init(),
                .input = undefined,
                .result = undefined,
            };
        }

        /// Schedule work to potentially run on another thread.
        ///
        /// After calling fork(), you MUST call join() before the Future goes
        /// out of scope. The Future is typically stack-allocated, and a stolen
        /// job writes its result into the Future's memory. If the Future is
        /// dropped (e.g. by returning early) before join() completes, the
        /// stolen job will write to freed stack memory (use-after-free).
        ///
        /// Safe pattern:
        /// ```zig
        /// var future = Future(i32, i64).init();
        /// future.fork(&task, compute, input);
        /// // ... do other work ...
        /// const result = future.join(&task) orelse compute(&task, input);
        /// ```
        ///
        /// The function signature must be: fn(*Task, Input) Output
        ///
        /// The job is pushed to the worker's deque and becomes
        /// instantly visible to idle workers for stealing.
        pub inline fn fork(
            self: *Self,
            task: *Task,
            comptime func: fn (*Task, Input) Output,
            input: Input,
        ) void {
            // Set up the handler that will execute the function
            // This handler is ONLY called when the job is stolen.
            // When executed locally, the caller invokes func directly.
            const Handler = struct {
                fn handle(t: *Task, job: *Job) void {
                    const fut: *Self = @fieldParentPtr("job", job);

                    // CRITICAL: Set thread-local task context for nested calls.
                    // Without this, nested blitz.join() would take the slow path
                    // (pool.call) instead of the fast path, causing deadlock.
                    const runtime = @import("ops/runtime.zig");
                    const prev_task = runtime.current_task;
                    runtime.current_task = t;
                    defer runtime.current_task = prev_task;

                    // Execute the function and store result in the Future
                    // (The Future lives on the owner's stack, valid until join() returns)
                    fut.result = @call(.always_inline, func, .{ t, fut.input });

                    // Signal completion LAST - owner may be waiting in join()
                    // WARNING: After this call, fut may be deallocated by owner!
                    // Do not access fut after signaling.
                    fut.latch.setDone();
                }
            };

            self.input = input;
            self.job = Job.init();
            self.job.handler = Handler.handle;
            // Reset latch for this fork (may be reused)
            self.latch = OnceLatch.init();

            // Push to deque AND notify sleep manager
            task.worker.pushAndWake(&self.job);
        }

        /// Wait for the result of fork().
        ///
        /// Returns the computed value if the job was stolen and executed,
        /// or null if the job was not stolen (caller should execute locally).
        ///
        /// Fast path optimized: try pop first without latch check.
        /// At deep depths, job is almost always local, so we avoid atomic latch probe.
        pub inline fn join(self: *Self, task: *Task) ?Output {
            const worker = task.worker;

            // Fast path: try to pop without checking latch first
            // At deep depths, our job is almost always at the bottom of our deque
            while (true) {
                if (worker.pop()) |popped_job| {
                    if (popped_job == &self.job) {
                        // Found our job! Caller will run it inline.
                        return null;
                    }
                    // Not our job - execute it and keep looking
                    if (popped_job.handler) |handler| {
                        handler(task, popped_job);
                    }
                    continue;
                }

                // Deque is empty. Either job was stolen, or we just executed everything.
                // Check if job was stolen and completed.
                if (self.latch.probe()) {
                    return self.result;
                }

                // Job was stolen but not yet complete. Enter work-stealing wait.
                break;
            }

            // Work-stealing wait loop with adaptive backoff
            // Balance between CPU burn and latency for fast stolen jobs
            const SPIN_LIMIT: u32 = 5; // 2^5 = 32 spins before yielding
            var backoff: u32 = 0;
            var spins_since_latch_check: u32 = 0;

            while (!self.latch.probe()) {
                // Try our deque first (in case work was pushed)
                if (worker.pop()) |popped_job| {
                    if (popped_job.handler) |handler| {
                        handler(task, popped_job);
                    }
                    backoff = 0; // Reset backoff on successful work
                    spins_since_latch_check = 0;
                    continue;
                }

                // Try stealing from others
                if (tryStealFromOthers(worker)) |stolen_job| {
                    if (stolen_job.handler) |handler| {
                        handler(task, stolen_job);
                    }
                    backoff = 0; // Reset backoff on successful work
                    spins_since_latch_check = 0;
                    continue;
                }

                // No work found - adaptive backoff
                // Check latch frequently at low backoff (fast jobs complete quickly)
                if (backoff < SPIN_LIMIT) {
                    const spins = @as(u32, 1) << @intCast(backoff);
                    for (0..spins) |_| {
                        std.atomic.spinLoopHint();
                        spins_since_latch_check += 1;
                        // Check latch every 8 spins to catch fast completions
                        if (spins_since_latch_check >= 8) {
                            if (self.latch.probe()) break;
                            spins_since_latch_check = 0;
                        }
                    }
                    backoff += 1;
                } else {
                    // Heavy wait - yield to OS scheduler
                    std.Thread.yield() catch {};
                }
            }

            return self.result;
        }

        /// Try to steal work from other workers in the pool.
        fn tryStealFromOthers(self_worker: *Worker) ?*Job {
            return self_worker.pool.tryStealFromOthers(self_worker);
        }
    };
}

/// Void future for when you don't need a return value.
pub const VoidFuture = Future(void, void);

// ============================================================================
// Tests
// ============================================================================

test "Future - basic init" {
    const future = Future(i32, i64).init();
    try std.testing.expect(future.job.handler == null);
    try std.testing.expect(!future.latch.isDone());
}

test "Future - input storage" {
    var future = Future(struct { x: i32, y: i32 }, i64).init();
    future.input = .{ .x = 10, .y = 20 };
    try std.testing.expectEqual(@as(i32, 10), future.input.x);
    try std.testing.expectEqual(@as(i32, 20), future.input.y);
}

test "Future - size is reasonable" {
    // Future should be small enough to stack-allocate
    const FutureType = Future(i32, i64);
    // Job (8) + OnceLatch (4) + padding + i32 (4) + i64 (8) = ~32 bytes
    try std.testing.expect(@sizeOf(FutureType) <= 48);
}

test "Future - latch integration" {
    // Test that Future's embedded latch works correctly for signaling
    var future = Future(i32, i64).init();

    // Initially not done
    try std.testing.expect(!future.latch.isDone());

    // Simulate completion (as thief would do)
    future.result = 42;
    future.latch.setDone();

    // Now should be done
    try std.testing.expect(future.latch.isDone());
    try std.testing.expectEqual(@as(i64, 42), future.result);
}
