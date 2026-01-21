//! ThreadPool for Blitz - Rayon-style Work Stealing
//!
//! A thread pool with lock-free work stealing following Rayon's proven design:
//!
//! - Each worker has a Chase-Lev deque (push/pop bottom, steal top)
//! - Idle workers steal from random victims (randomized to avoid thundering herd)
//! - External threads inject work via lock-free Treiber stack
//! - Progressive sleep: spin → yield → sleep to balance latency and CPU usage
//!
//! No heartbeat thread - work visibility is instant through the deques.

const std = @import("std");
const Job = @import("job.zig").Job;
const Worker = @import("worker.zig").Worker;
const Task = @import("worker.zig").Task;
const XorShift64Star = @import("internal/rng.zig").XorShift64Star;

/// Progressive sleep constants (from Rayon).
/// Workers spin first (low latency), then yield (medium), then sleep (low CPU).
const SPIN_LIMIT: u32 = 64;
const YIELD_LIMIT: u32 = 256;

/// Configuration for the thread pool.
pub const ThreadPoolConfig = struct {
    /// Number of background workers. null = auto-detect (CPU count - 1).
    background_worker_count: ?usize = null,
};

/// An injected job from an external thread.
/// External threads block until a worker executes the job.
pub const InjectedJob = struct {
    /// Handler to execute the job.
    handler: *const fn (*InjectedJob, *Worker) void,
    /// Completion signal.
    done: std.Thread.ResetEvent = .{},
    /// Next pointer for Treiber stack.
    next: ?*InjectedJob = null,
};

/// Tagged pointer for ABA prevention in lock-free stack.
const TaggedPtr = packed struct {
    ptr: u48,
    tag: u16,

    fn init(p: ?*InjectedJob, t: u16) TaggedPtr {
        return .{
            .ptr = if (p) |pp| @truncate(@intFromPtr(pp)) else 0,
            .tag = t,
        };
    }

    fn getPtr(self: TaggedPtr) ?*InjectedJob {
        return if (self.ptr == 0) null else @ptrFromInt(@as(usize, self.ptr));
    }

    fn toU64(self: TaggedPtr) u64 {
        return @bitCast(self);
    }

    fn fromU64(v: u64) TaggedPtr {
        return @bitCast(v);
    }
};

/// Thread pool with Rayon-style work stealing.
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,

    /// Background workers (fixed array for efficient random access).
    workers: []?*Worker = &[_]?*Worker{},

    /// Number of workers.
    num_workers: usize = 0,

    /// Background worker threads.
    threads: std.ArrayListUnmanaged(std.Thread) = .{},

    /// Futex for lock-free sleep/wake. Workers wait on this when idle.
    /// Incremented by wakeOne/wakeAll to wake sleeping workers.
    wake_futex: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Semaphore: workers signal when they're ready.
    workers_ready: std.Thread.Semaphore = .{},

    /// Atomic stop flag for shutdown.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Number of idle workers (for wake optimization).
    idle_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Head of injected jobs stack (lock-free Treiber stack).
    injected_jobs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Create an empty thread pool (for testing).
    pub fn initEmpty(allocator: std.mem.Allocator) ThreadPool {
        return ThreadPool{ .allocator = allocator };
    }

    /// Initialize the thread pool.
    pub fn init(allocator: std.mem.Allocator) ThreadPool {
        return ThreadPool{ .allocator = allocator };
    }

    /// Start the thread pool with the given configuration.
    pub fn start(self: *ThreadPool, config: ThreadPoolConfig) void {
        const count = config.background_worker_count orelse blk: {
            const cpus = std.Thread.getCpuCount() catch 1;
            break :blk if (cpus > 1) cpus - 1 else 1;
        };

        self.num_workers = count;
        self.threads.ensureUnusedCapacity(self.allocator, count) catch @panic("OOM");
        self.workers = self.allocator.alloc(?*Worker, count) catch @panic("OOM");
        @memset(self.workers, null);

        // Spawn background workers
        for (0..count) |i| {
            const thread = std.Thread.spawn(.{}, workerLoop, .{ self, @as(u32, @intCast(i)) }) catch @panic("spawn error");
            self.threads.append(self.allocator, thread) catch @panic("OOM");
        }

        // Wait for all workers to be ready
        for (0..count) |_| {
            self.workers_ready.wait();
        }
    }

    /// Shut down the thread pool.
    pub fn deinit(self: *ThreadPool) void {
        // Signal stop
        self.stopping.store(true, .release);

        // Wake all sleeping workers (lock-free!)
        _ = self.wake_futex.fetchAdd(1, .release);
        std.Thread.Futex.wake(&self.wake_futex, std.math.maxInt(u32));

        // Join threads
        for (self.threads.items) |thread| {
            thread.join();
        }

        // Clean up workers
        for (self.workers) |maybe_worker| {
            if (maybe_worker) |worker| {
                worker.deinitDeque(self.allocator);
                self.allocator.destroy(worker);
            }
        }

        if (self.workers.len > 0) {
            self.allocator.free(self.workers);
        }
        self.threads.deinit(self.allocator);
        self.* = undefined;
    }

    /// Execute a function on the thread pool (for external threads).
    /// Injects the job and blocks until a worker executes it.
    pub fn call(self: *ThreadPool, comptime T: type, func: anytype, arg: anytype) T {
        const Arg = @TypeOf(arg);

        const CallJob = struct {
            base: InjectedJob,
            arg: Arg,
            result: T,

            fn execute(base: *InjectedJob, worker: *Worker) void {
                const this: *@This() = @fieldParentPtr("base", base);
                var task = worker.begin();
                this.result = task.call(T, func, this.arg);
                base.done.set();
            }
        };

        var call_job = CallJob{
            .base = InjectedJob{ .handler = CallJob.execute },
            .arg = arg,
            .result = undefined,
        };

        // Push to injected jobs stack (lock-free)
        while (true) {
            const head_raw = self.injected_jobs.load(.acquire);
            const head = TaggedPtr.fromU64(head_raw);
            call_job.base.next = head.getPtr();
            const new_head = TaggedPtr.init(&call_job.base, head.tag +% 1);
            if (self.injected_jobs.cmpxchgWeak(head_raw, new_head.toU64(), .release, .acquire) == null) {
                break;
            }
        }

        // Wake a sleeping worker if any (lock-free!)
        if (self.idle_count.load(.monotonic) > 0) {
            _ = self.wake_futex.fetchAdd(1, .release);
            std.Thread.Futex.wake(&self.wake_futex, 1);
        }

        // Wait for completion
        call_job.base.done.wait();
        return call_job.result;
    }

    /// Get the number of workers.
    pub fn numWorkers(self: *const ThreadPool) usize {
        return self.num_workers;
    }

    /// Wake one sleeping worker (if any) to steal work.
    /// This is completely lock-free - just atomic increment + futex wake.
    pub inline fn wakeOne(self: *ThreadPool) void {
        // Quick check - only wake if workers are actually sleeping
        if (self.idle_count.load(.monotonic) > 0) {
            // Increment futex value to signal change, then wake one waiter
            _ = self.wake_futex.fetchAdd(1, .release);
            std.Thread.Futex.wake(&self.wake_futex, 1);
        }
    }

    /// Get total jobs executed and stolen across all workers (for debugging).
    pub fn getStats(self: *const ThreadPool) struct { executed: u64, stolen: u64 } {
        var executed: u64 = 0;
        var stolen: u64 = 0;
        for (self.workers) |maybe_worker| {
            if (maybe_worker) |w| {
                executed += w.stats.jobs_executed;
                stolen += w.stats.jobs_stolen;
            }
        }
        return .{ .executed = executed, .stolen = stolen };
    }

    /// Reset stats for all workers.
    pub fn resetStats(self: *ThreadPool) void {
        for (self.workers) |maybe_worker| {
            if (maybe_worker) |w| {
                w.stats = .{};
            }
        }
    }

    /// Pop an injected job (called by workers).
    fn popInjectedJob(self: *ThreadPool) ?*InjectedJob {
        while (true) {
            const head_raw = self.injected_jobs.load(.acquire);
            const head = TaggedPtr.fromU64(head_raw);
            const head_ptr = head.getPtr() orelse return null;
            const new_head = TaggedPtr.init(head_ptr.next, head.tag +% 1);
            if (self.injected_jobs.cmpxchgWeak(head_raw, new_head.toU64(), .release, .acquire) == null) {
                return head_ptr;
            }
        }
    }
};

/// Background worker loop.
fn workerLoop(pool: *ThreadPool, worker_id: u32) void {
    // Create and initialize worker
    const worker = pool.allocator.create(Worker) catch @panic("OOM");
    worker.* = Worker{ .pool = pool };
    worker.initDeque(pool.allocator, worker_id) catch @panic("OOM");
    pool.workers[worker_id] = worker;

    // Signal ready
    pool.workers_ready.post();

    var rounds: u32 = 0;

    while (!pool.stopping.load(.acquire)) {
        // 1. Try our own deque (fast path)
        if (worker.pop()) |job| {
            executeJob(worker, job);
            rounds = 0;
            continue;
        }

        // 2. Try stealing from others
        if (trySteal(pool, worker)) |job| {
            worker.stats.jobs_stolen += 1;
            executeJob(worker, job);
            rounds = 0;
            continue;
        }

        // 3. Try injected jobs
        if (pool.popInjectedJob()) |injected| {
            injected.handler(injected, worker);
            rounds = 0;
            continue;
        }

        // 4. Progressive sleep
        rounds += 1;

        if (rounds < SPIN_LIMIT) {
            std.atomic.spinLoopHint();
        } else if (rounds < YIELD_LIMIT) {
            std.Thread.yield() catch {};
        } else {
            // Sleep using futex (lock-free!)
            _ = pool.idle_count.fetchAdd(1, .monotonic);

            // Check for work one more time before sleeping
            if (pool.popInjectedJob()) |injected| {
                _ = pool.idle_count.fetchSub(1, .monotonic);
                injected.handler(injected, worker);
                rounds = 0;
                continue;
            }

            // Also check deques one more time
            if (trySteal(pool, worker)) |job| {
                _ = pool.idle_count.fetchSub(1, .monotonic);
                worker.stats.jobs_stolen += 1;
                executeJob(worker, job);
                rounds = 0;
                continue;
            }

            // Now sleep on futex - will wake when wake_futex changes
            const current = pool.wake_futex.load(.acquire);
            if (!pool.stopping.load(.acquire)) {
                std.Thread.Futex.wait(&pool.wake_futex, current);
            }

            _ = pool.idle_count.fetchSub(1, .monotonic);
            rounds = 0;
        }
    }
}

/// Execute a job that was obtained from a deque (either pop or steal).
///
/// The job was obtained exclusively through Chase-Lev deque operations,
/// so no additional claiming is needed. The job's handler is responsible
/// for signaling the embedded latch in the containing Future.
fn executeJob(worker: *Worker, job: *Job) void {
    // Execute the job's handler
    // The handler writes the result to the Future and signals the embedded latch
    var task = worker.begin();
    if (job.handler) |handler| {
        handler(&task, job);
    }
    worker.stats.jobs_executed += 1;
}

/// Try to steal from other workers using randomized victim selection.
fn trySteal(pool: *ThreadPool, self_worker: *Worker) ?*Job {
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

// ============================================================================
// Tests
// ============================================================================

test "ThreadPool - initEmpty" {
    var pool = ThreadPool.initEmpty(std.testing.allocator);
    defer pool.deinit();
    try std.testing.expect(!pool.stopping.load(.acquire));
}

test "ThreadPool - init and deinit" {
    var pool = ThreadPool.init(std.testing.allocator);
    pool.start(.{ .background_worker_count = 2 });
    defer pool.deinit();
    try std.testing.expect(pool.num_workers == 2);
}

test "ThreadPool - call" {
    var pool = ThreadPool.init(std.testing.allocator);
    pool.start(.{ .background_worker_count = 2 });
    defer pool.deinit();

    const arg: i32 = 21;
    const result = pool.call(i32, struct {
        fn compute(task: *Task, x: i32) i32 {
            _ = task;
            return x * 2;
        }
    }.compute, arg);

    try std.testing.expectEqual(@as(i32, 42), result);
}
