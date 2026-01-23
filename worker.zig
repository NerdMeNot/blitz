//! Worker and Task for Blitz - Rayon-style Work Stealing
//!
//! Each worker has:
//! - A lock-free Chase-Lev deque for work-stealing
//! - An RNG for randomized victim selection
//!
//! Design principles (following Rayon):
//! - Push/pop from bottom (owner), steal from top (thieves)
//! - Lock-free deque operations for instant work visibility
//! - Randomized victim selection to avoid thundering herd
//! - No heartbeat - thieves actively poll for work

const std = @import("std");
const Job = @import("job.zig").Job;
const Deque = @import("deque.zig").Deque;
const XorShift64Star = @import("internal/rng.zig").XorShift64Star;

// Forward declaration for ThreadPool
pub const ThreadPool = @import("pool.zig").ThreadPool;

/// Default deque capacity (must be power of 2).
/// 256 should be enough for most recursive algorithms.
const DEFAULT_DEQUE_CAPACITY: usize = 256;

/// Worker statistics for debugging/monitoring.
pub const WorkerStats = struct {
    jobs_executed: u64 = 0,
    jobs_stolen: u64 = 0,
};

/// Per-worker state.
///
/// Each worker has:
/// - A lock-free deque for work-stealing (owner pushes/pops bottom, thieves steal top)
/// - An RNG for randomized victim selection
///
/// The deque provides instant visibility of forked work to idle workers.
/// No heartbeat needed - thieves actively look for work.
pub const Worker = struct {
    /// Reference to the thread pool.
    pool: *ThreadPool,

    /// Worker ID (index in pool's worker array).
    id: u32 = 0,

    /// Lock-free Chase-Lev deque for work-stealing.
    /// Owner pushes/pops from bottom (LIFO for locality).
    /// Thieves steal from top (FIFO for fairness).
    deque: ?Deque(*Job) = null,

    /// Per-worker RNG for randomized victim selection.
    rng: XorShift64Star = XorShift64Star.init(0),

    /// Statistics.
    stats: WorkerStats = .{},

    /// Initialize the worker's deque and RNG.
    /// Called by the pool when creating workers.
    pub fn initDeque(self: *Worker, allocator: std.mem.Allocator, worker_id: u32) !void {
        self.id = worker_id;
        self.deque = try Deque(*Job).init(allocator, DEFAULT_DEQUE_CAPACITY);
        self.rng = XorShift64Star.initFromIndex(worker_id);
    }

    /// Deinitialize the worker's deque.
    pub fn deinitDeque(self: *Worker, allocator: std.mem.Allocator) void {
        if (self.deque) |*d| {
            d.deinit(allocator);
            self.deque = null;
        }
    }

    /// Start executing work on this worker.
    /// Returns a Task that can be used for spawning sub-tasks.
    pub inline fn begin(self: *Worker) Task {
        return Task{ .worker = self };
    }

    /// Push a job to the deque (owner operation).
    /// The job becomes immediately visible to thieves.
    pub inline fn push(self: *Worker, job: *Job) void {
        if (self.deque) |*d| {
            d.push(job);
        }
    }

    /// Push a job and notify the pool (Rayon-style smart wake).
    ///
    /// Only wakes sleeping workers when needed:
    /// - If idle workers exist, they'll find the work naturally
    /// - Only wake if work is piling up or no idle workers
    ///
    /// This reduces unnecessary wakes for bursty workloads.
    pub inline fn pushAndWake(self: *Worker, job: *Job) void {
        if (self.deque) |*d| {
            const was_empty = d.isEmpty();
            d.push(job);
            self.pool.notifyNewJobs(1, was_empty);
        }
    }

    /// Pop a job from the deque (owner operation).
    /// Returns null if deque is empty or was stolen.
    pub inline fn pop(self: *Worker) ?*Job {
        if (self.deque) |*d| {
            return d.pop();
        }
        return null;
    }

    /// Steal a job from this worker's deque (thief operation).
    /// Returns null if deque is empty.
    pub inline fn steal(self: *Worker) ?*Job {
        if (self.deque) |*d| {
            return d.stealLoop();
        }
        return null;
    }
};

/// Task is the handle passed to user functions.
///
/// Size: 8 bytes (1 pointer) - minimal overhead.
///
/// The task provides access to the worker for:
/// - Pushing/popping jobs from the deque
/// - Recursive parallel computation via Future
pub const Task = struct {
    /// The worker we're running on.
    worker: *Worker,

    /// Execute a function, returning its result.
    /// This is a simple passthrough - no tick/heartbeat check needed.
    pub inline fn call(self: *Task, comptime T: type, func: anytype, arg: anytype) T {
        return @call(.always_inline, func, .{ self, arg });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Worker - begin creates valid task" {
    const pool = @import("pool.zig");
    var tp = pool.ThreadPool.initEmpty(std.testing.allocator);
    defer tp.deinit();

    var worker = Worker{ .pool = &tp };
    const task = worker.begin();

    try std.testing.expect(task.worker == &worker);
}

test "Worker - deque operations" {
    const pool = @import("pool.zig");
    var tp = pool.ThreadPool.initEmpty(std.testing.allocator);
    defer tp.deinit();

    var worker = Worker{ .pool = &tp };
    try worker.initDeque(std.testing.allocator, 0);
    defer worker.deinitDeque(std.testing.allocator);

    // Empty deque returns null
    try std.testing.expect(worker.pop() == null);
    try std.testing.expect(worker.steal() == null);

    // Push and pop
    var job = Job.init();
    worker.push(&job);
    try std.testing.expect(worker.pop() == &job);
    try std.testing.expect(worker.pop() == null);
}

test "Task - size is minimal" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Task));
}
