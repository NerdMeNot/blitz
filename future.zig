//! Future for Blitz - Rayon-style Fork-Join
//!
//! Future(Input, Output) enables fork-join parallelism with return values.
//! The future is stack-allocated and uses comptime specialization to
//! eliminate vtable overhead.
//!
//! Design (following Rayon's StackJob):
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
const Job = @import("job.zig").Job;
const Task = @import("worker.zig").Task;
const Worker = @import("worker.zig").Worker;
const OnceLatch = @import("latch.zig").OnceLatch;

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
        /// After calling fork(), you MUST call join().
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
                    const api = @import("api.zig");
                    const prev_task = api.current_task;
                    api.current_task = t;
                    defer api.current_task = prev_task;

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

            // Push to deque and wake an idle worker to steal this job
            task.worker.pushAndWake(&self.job);
        }

        /// Schedule work with Rayon-style smart wake.
        ///
        /// This implements Rayon's wake strategy:
        /// - Check if deque was empty before push
        /// - Only wake sleeping workers if needed
        /// - Awake-but-idle workers will find work naturally
        pub inline fn forkSmartWake(
            self: *Self,
            task: *Task,
            comptime func: fn (*Task, Input) Output,
            input: Input,
        ) void {
            const Handler = struct {
                fn handle(t: *Task, job: *Job) void {
                    const fut: *Self = @fieldParentPtr("job", job);

                    const api = @import("api.zig");
                    const prev_task = api.current_task;
                    api.current_task = t;
                    defer api.current_task = prev_task;

                    fut.result = @call(.always_inline, func, .{ t, fut.input });
                    fut.latch.setDone();
                }
            };

            self.input = input;
            self.job = Job.init();
            self.job.handler = Handler.handle;
            self.latch = OnceLatch.init();

            // Check if queue was empty before push (Rayon does this)
            const queue_was_empty = task.worker.deque != null and task.worker.deque.?.isEmpty();

            // Push to deque
            task.worker.push(&self.job);

            // Notify pool with Rayon-style logic
            task.worker.pool.notifyNewJobs(1, queue_was_empty);
        }

        /// Wait for the result of fork().
        ///
        /// Returns the computed value if the job was stolen and executed,
        /// or null if the job was not stolen (caller should execute locally).
        ///
        /// Hybrid approach for best performance at all depths:
        /// - Quick latch check first (catches fast stolen completions - good at shallow depth)
        /// - Then try pop (catches local jobs - good at deep depth)
        /// - Only enter steal loop when both fail
        pub inline fn join(self: *Self, task: *Task) ?Output {
            const worker = task.worker;

            // Fast path: job was stolen and already completed (common at shallow depth)
            if (self.latch.probe()) {
                return self.result;
            }

            // Try to pop our job (common at deep depth - job is usually local)
            if (worker.pop()) |popped_job| {
                if (popped_job == &self.job) {
                    return null; // Execute locally
                }
                // Got a different job - execute it
                if (popped_job.handler) |handler| {
                    handler(task, popped_job);
                }
            }

            // Work-stealing loop for when job was stolen but not yet complete
            var spin_backoff: u32 = 0;
            const SPIN_LIMIT: u32 = 6; // Max ~64 spins before yield

            while (!self.latch.probe()) {
                // Try our deque
                if (worker.pop()) |popped_job| {
                    if (popped_job == &self.job) {
                        return null;
                    }
                    if (popped_job.handler) |handler| {
                        handler(task, popped_job);
                    }
                    spin_backoff = 0; // Reset backoff on successful work
                    continue;
                }

                // Try stealing from others
                if (tryStealFromOthers(worker)) |stolen_job| {
                    if (stolen_job.handler) |handler| {
                        handler(task, stolen_job);
                    }
                    spin_backoff = 0; // Reset backoff on successful work
                    continue;
                }

                // Exponential backoff spin (1, 2, 4, 8, 16, 32, 64 spins)
                // NOTE: We check latch AFTER spinning, not during each spin.
                // This reduces atomic operations from O(spins) to O(1) per backoff level.
                // The while loop condition already checks the latch each iteration.
                if (spin_backoff < SPIN_LIMIT) {
                    const spins = @as(u32, 1) << @intCast(spin_backoff);
                    for (0..spins) |_| {
                        std.atomic.spinLoopHint();
                    }
                    spin_backoff += 1;
                } else {
                    // Heavy wait - yield to OS
                    std.Thread.yield() catch {};
                }
            }

            return self.result;
        }

        /// Try to steal work from other workers in the pool.
        fn tryStealFromOthers(self_worker: *Worker) ?*Job {
            const pool = self_worker.pool;
            const num_workers = pool.num_workers;
            if (num_workers <= 1) return null;

            const start = self_worker.rng.nextBounded(num_workers);

            for (0..num_workers) |offset| {
                const victim_idx = (start + offset) % num_workers;
                if (victim_idx == self_worker.id) continue;

                const victim = pool.workers[victim_idx] orelse continue;
                if (victim.steal()) |job| {
                    return job;
                }
            }

            return null;
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
