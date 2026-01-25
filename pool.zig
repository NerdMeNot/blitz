//! Pool - Lock-Free Work-Stealing Thread Pool
//!
//! Implements a complete work-stealing architecture:
//! - Chase-Lev lock-free deques per worker
//! - AtomicCounters with packed sleeping/inactive/JEC counters
//! - Progressive sleep: 32 rounds yield -> announce sleepy -> 1 more yield -> sleep
//! - CoreLatch 4-state protocol for robust wake guarantees
//! - JEC (Jobs Event Counter) protocol to prevent missed wakes

const std = @import("std");
const Deque = @import("deque.zig").Deque;
const XorShift64Star = @import("internal/rng.zig").XorShift64Star;
const OnceLatch = @import("latch.zig").OnceLatch;
const SpinWait = @import("latch.zig").SpinWait;

// ============================================================================
// Job and Task
// ============================================================================

pub const Job = struct {
    handler: ?*const fn (*Task, *Job) void = null,

    pub inline fn init() Job {
        return .{};
    }
};

pub const Task = struct {
    worker: *Worker,

    pub inline fn call(self: *Task, comptime T: type, func: anytype, arg: anytype) T {
        return @call(.always_inline, func, .{ self, arg });
    }
};

// ============================================================================
// Thread Pool Configuration
// ============================================================================

pub const ThreadPoolConfig = struct {
    background_worker_count: ?usize = null,
};

// ============================================================================
// Fence Emulation (Zig 0.15 lacks @fence builtin)
// ============================================================================

/// Global sentinel for SeqCst fence emulation.
/// A fetchAdd(0) with SeqCst ordering acts as a full memory barrier.
var fence_sentinel: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

inline fn seqCstFence() void {
    _ = fence_sentinel.fetchAdd(0, .seq_cst);
}

// ============================================================================
// AtomicCounters - Packed u64 with sleeping/inactive/JEC
// ============================================================================

const SLEEPING_SHIFT: u6 = 0;
const INACTIVE_SHIFT: u6 = 16;
const JEC_SHIFT: u6 = 32;

const ONE_SLEEPING: u64 = 1;
const ONE_INACTIVE: u64 = 1 << INACTIVE_SHIFT;
const ONE_JEC: u64 = 1 << JEC_SHIFT;

const AtomicCounters = struct {
    value: std.atomic.Value(u64),

    fn init() AtomicCounters {
        return .{ .value = std.atomic.Value(u64).init(0) };
    }

    /// Load with acquire ordering (sufficient for reads).
    inline fn load(self: *const AtomicCounters) u64 {
        return self.value.load(.acquire);
    }

    /// Load with SeqCst (only when needed for JEC protocol).
    inline fn loadSeqCst(self: *const AtomicCounters) u64 {
        return self.value.load(.seq_cst);
    }

    /// Extract sleeping count from packed value.
    inline fn extractSleeping(counters: u64) u16 {
        return @truncate(counters);
    }

    /// Extract inactive count from packed value.
    inline fn extractInactive(counters: u64) u16 {
        return @truncate(counters >> INACTIVE_SHIFT);
    }

    /// Extract JEC from packed value.
    inline fn extractJec(counters: u64) u32 {
        return @truncate(counters >> JEC_SHIFT);
    }

    /// SeqCst for all counter operations ensures the sleep protocol
    /// works correctly (tickle-then-get-sleepy race prevention).
    fn tryAddSleepingThread(self: *AtomicCounters, expected: u64) bool {
        const new = expected +% ONE_SLEEPING;
        return self.value.cmpxchgWeak(expected, new, .seq_cst, .monotonic) == null;
    }

    fn subSleepingThread(self: *AtomicCounters) void {
        _ = self.value.fetchSub(ONE_SLEEPING, .seq_cst);
    }

    fn addInactiveThread(self: *AtomicCounters) void {
        _ = self.value.fetchAdd(ONE_INACTIVE, .seq_cst);
    }

    fn subInactiveThread(self: *AtomicCounters) u16 {
        const old = self.value.fetchSub(ONE_INACTIVE, .seq_cst);
        const sleeping = extractSleeping(old);
        return @min(sleeping, 2); // Heuristic: wake at most 2
    }

    /// Increment JEC if currently sleepy (even). Returns old counters.
    /// Used by work posters to signal "new work available".
    /// SeqCst for the CAS ensures visibility across threads.
    fn incrementJecIfSleepy(self: *AtomicCounters) u64 {
        while (true) {
            const old = self.loadSeqCst();
            const jec_val = extractJec(old);

            if ((jec_val & 1) != 0) {
                return old; // Already active (odd)
            }

            // Try to increment JEC (toggle to odd)
            const new = old +% ONE_JEC;
            if (self.value.cmpxchgWeak(old, new, .seq_cst, .monotonic) == null) {
                return old;
            }
            // Retry on CAS failure
        }
    }
};

// ============================================================================
// Sleep Manager
// ============================================================================

const ROUNDS_UNTIL_SLEEPY: u32 = 32;
const ROUNDS_UNTIL_SLEEPING: u32 = 33;

/// Per-idle-session state.
const IdleState = struct {
    worker_index: usize,
    rounds: u32,
    jobs_counter: u32, // JEC snapshot when sleepy announced
};

/// Per-worker sleep state (condvar-based blocking).
/// Cache-line aligned to prevent false sharing between workers.
const WorkerSleepState = struct {
    mutex: std.Thread.Mutex,
    condvar: std.Thread.Condition,
    is_blocked: bool,
    // Padding to ensure each WorkerSleepState is on its own cache line
    _padding: [std.atomic.cache_line - (@sizeOf(std.Thread.Mutex) + @sizeOf(std.Thread.Condition) + 1) % std.atomic.cache_line]u8 = undefined,

    fn init() WorkerSleepState {
        return .{
            .mutex = .{},
            .condvar = .{},
            .is_blocked = false,
            ._padding = undefined,
        };
    }
};

/// CoreLatch for worker sleep/wake (4-state protocol).
/// This is separate from OnceLatch - used for idle workers.
const CoreLatch = struct {
    state: std.atomic.Value(u32),

    const UNSET: u32 = 0;
    const SLEEPY: u32 = 1;
    const SLEEPING: u32 = 2;
    const SET: u32 = 3;

    fn init() CoreLatch {
        return .{ .state = std.atomic.Value(u32).init(UNSET) };
    }

    fn reset(self: *CoreLatch) void {
        self.state.store(UNSET, .release);
    }

    /// Check if latch is set (fast path).
    fn probe(self: *const CoreLatch) bool {
        return self.state.load(.acquire) == SET;
    }

    /// Try to transition UNSET -> SLEEPY. Returns true if successful.
    fn getSleepy(self: *CoreLatch) bool {
        return self.state.cmpxchgWeak(UNSET, SLEEPY, .seq_cst, .monotonic) == null;
    }

    /// Try to transition SLEEPY -> SLEEPING. Returns true if successful.
    fn fallAsleep(self: *CoreLatch) bool {
        return self.state.cmpxchgWeak(SLEEPY, SLEEPING, .seq_cst, .monotonic) == null;
    }

    /// Wake up from SLEEPING state (if not already SET).
    /// Check probe() first to avoid unnecessary CAS.
    fn wakeUp(self: *CoreLatch) void {
        if (!self.probe()) {
            _ = self.state.cmpxchgWeak(SLEEPING, UNSET, .seq_cst, .monotonic);
        }
    }

    /// Set the latch. Returns true if thread was SLEEPING (needs wake).
    fn set(self: *CoreLatch) bool {
        return self.state.swap(SET, .acq_rel) == SLEEPING;
    }
};

/// Sleep manager - handles progressive sleep for idle workers.
pub const Sleep = struct {
    counters: AtomicCounters,
    worker_sleep_states: []WorkerSleepState,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) Sleep {
        if (num_workers == 0) {
            return .{
                .counters = AtomicCounters.init(),
                .worker_sleep_states = &.{},
                .allocator = allocator,
            };
        }
        const states = allocator.alloc(WorkerSleepState, num_workers) catch @panic("OOM");
        for (states) |*s| s.* = WorkerSleepState.init();
        return .{
            .counters = AtomicCounters.init(),
            .worker_sleep_states = states,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Sleep) void {
        if (self.worker_sleep_states.len > 0) {
            self.allocator.free(self.worker_sleep_states);
            self.worker_sleep_states = &.{};
        }
    }

    /// Called when worker starts looking for work.
    pub fn startLooking(self: *Sleep, worker_index: usize) IdleState {
        self.counters.addInactiveThread();
        return .{
            .worker_index = worker_index,
            .rounds = 0,
            .jobs_counter = 0,
        };
    }

    /// Called when worker finds work.
    pub fn workFound(self: *Sleep) u16 {
        return self.counters.subInactiveThread(); // Returns threads to wake
    }

    /// Called when no work found during idle search.
    /// Uses spin-then-yield progression to reduce syscall overhead and variance.
    /// Returns true if work might be available (caller should check immediately).
    pub fn noWorkFound(
        self: *Sleep,
        idle: *IdleState,
        latch: *CoreLatch,
        pool: *ThreadPool,
    ) void {
        idle.rounds += 1;

        if (idle.rounds < ROUNDS_UNTIL_SLEEPY) {
            // Yield on every round like Rayon does.
            // This gives the OS scheduler a chance to run other threads
            // and prevents the variance seen with pure spin loops.
            std.Thread.yield() catch {};
            return;
        }

        if (idle.rounds == ROUNDS_UNTIL_SLEEPY) {
            // Announce sleepy: try to toggle JEC even→odd.
            // IMPORTANT: Save the CURRENT JEC value after any toggle, not the old value.
            // If we saved the old value, the worker that toggled would see
            // "JEC changed" (due to its own action) and partial wake immediately.
            _ = self.counters.incrementJecIfSleepy();
            idle.jobs_counter = AtomicCounters.extractJec(self.counters.loadSeqCst());
            std.Thread.yield() catch {};
            return;
        }

        if (idle.rounds == ROUNDS_UNTIL_SLEEPING) {
            // One more yield before sleeping
            std.Thread.yield() catch {};
            return;
        }

        // Actually sleep
        self.sleep(idle, latch, pool);
    }

    fn sleep(
        self: *Sleep,
        idle: *IdleState,
        latch: *CoreLatch,
        pool: *ThreadPool,
    ) void {

        // Step 1: Try to transition latch UNSET -> SLEEPY
        if (!latch.getSleepy()) {
            idle.rounds = 0; // Latch was set, wake fully
            return;
        }

        const state = &self.worker_sleep_states[idle.worker_index];
        state.mutex.lock();

        // Step 2: Try to transition latch SLEEPY -> SLEEPING
        if (!latch.fallAsleep()) {
            state.mutex.unlock();
            idle.rounds = 0; // Latch was set during transition
            return;
        }

        // Step 3: Try to add ourselves to sleeping count
        while (true) {
            const counters = self.counters.loadSeqCst();
            const jec_now = AtomicCounters.extractJec(counters);

            // Check if JEC changed since we announced sleepy
            if (jec_now != idle.jobs_counter) {
                // New work arrived! Go back to sleepy state
                state.mutex.unlock();
                latch.wakeUp();
                idle.rounds = ROUNDS_UNTIL_SLEEPY; // Wake partly
                return;
            }

            if (self.counters.tryAddSleepingThread(counters)) {
                break; // Successfully registered as sleeping
            }
        }

        // Step 4: CRITICAL - SeqCst fence then check injected jobs
        seqCstFence();

        if (pool.hasInjectedJobs()) {
            // Work was injected while we were registering
            self.counters.subSleepingThread();
            state.mutex.unlock();
            latch.wakeUp();
            idle.rounds = 0;
            return;
        }

        // Step 5: Actually block on condvar
        state.is_blocked = true;
        while (state.is_blocked and !pool.stopping.load(.acquire)) {
            state.condvar.wait(&state.mutex);
        }
        state.mutex.unlock();

        // Woken up
        latch.wakeUp();
        idle.rounds = 0;
    }

    /// Called when new jobs are injected from external thread.
    pub fn newInjectedJobs(self: *Sleep, num_jobs: u32, queue_was_empty: bool) void {
        // CRITICAL: SeqCst fence before reading counters
        seqCstFence();
        self.newJobs(num_jobs, queue_was_empty);
    }

    /// Called when new jobs are pushed from worker thread.
    pub fn newInternalJobs(self: *Sleep, num_jobs: u32, queue_was_empty: bool) void {
        // No fence needed for internal jobs - deque has acquire/release semantics
        self.newJobs(num_jobs, queue_was_empty);
    }

    fn newJobs(self: *Sleep, num_jobs: u32, queue_was_empty: bool) void {
        // Toggle JEC to odd if even (signal new work)
        const old = self.counters.incrementJecIfSleepy();
        const sleeping = AtomicCounters.extractSleeping(old);

        if (sleeping == 0) return; // Nobody to wake

        const inactive = AtomicCounters.extractInactive(old);
        const awake_but_idle = inactive -| sleeping;

        // Decide how many to wake
        const num_to_wake: u32 = if (queue_was_empty) blk: {
            // Queue was empty - wake if not enough idle workers
            if (awake_but_idle < num_jobs) {
                break :blk @min(num_jobs - awake_but_idle, sleeping);
            }
            break :blk 0;
        } else blk: {
            // Queue not empty - always wake some
            break :blk @min(num_jobs, sleeping);
        };

        self.wakeThreads(num_to_wake);
    }

    pub fn wakeThreads(self: *Sleep, count: u32) void {
        var woken: u32 = 0;
        for (self.worker_sleep_states, 0..) |*state, i| {
            if (woken >= count) break;
            if (self.wakeSpecificThread(i, state)) {
                woken += 1;
            }
        }
    }

    fn wakeSpecificThread(self: *Sleep, index: usize, state: *WorkerSleepState) bool {
        _ = index;
        state.mutex.lock();
        defer state.mutex.unlock();

        if (state.is_blocked) {
            state.is_blocked = false;
            state.condvar.signal();
            // CRITICAL: Waker decrements counter, not sleeper
            self.counters.subSleepingThread();
            return true;
        }
        return false;
    }

    pub fn wakeAll(self: *Sleep) void {
        for (self.worker_sleep_states, 0..) |*state, i| {
            _ = self.wakeSpecificThread(i, state);
        }
    }
};

// ============================================================================
// Worker
// ============================================================================

/// Default deque capacity (must be power of 2).
const DEFAULT_DEQUE_CAPACITY: usize = 256;

/// Worker statistics for debugging/monitoring.
pub const WorkerStats = struct {
    jobs_executed: u64 = 0,
    jobs_stolen: u64 = 0,
};

pub const Worker = struct {
    pool: *ThreadPool,
    id: u32 = 0,
    deque: ?Deque(*Job) = null,
    rng: XorShift64Star = XorShift64Star.init(0),
    latch: CoreLatch = CoreLatch.init(),
    stats: WorkerStats = .{},

    pub fn initDeque(self: *Worker, allocator: std.mem.Allocator, worker_id: u32) !void {
        self.id = worker_id;
        self.deque = try Deque(*Job).init(allocator, DEFAULT_DEQUE_CAPACITY);
        self.rng = XorShift64Star.initFromIndex(worker_id);
        self.latch = CoreLatch.init();
    }

    pub fn deinitDeque(self: *Worker) void {
        if (self.deque) |*d| {
            d.deinit();
            self.deque = null;
        }
    }

    pub inline fn begin(self: *Worker) Task {
        return Task{ .worker = self };
    }

    pub inline fn push(self: *Worker, job: *Job) void {
        if (self.deque) |*d| {
            d.push(job);
        }
    }

    pub inline fn pushAndWake(self: *Worker, job: *Job) void {
        if (self.deque) |*d| {
            const was_empty = d.isEmpty();
            d.push(job);
            self.pool.sleep.newInternalJobs(1, was_empty);
        }
    }

    pub inline fn pop(self: *Worker) ?*Job {
        if (self.deque) |*d| {
            return d.pop();
        }
        return null;
    }

    pub inline fn steal(self: *Worker) ?*Job {
        if (self.deque) |*d| {
            return d.stealLoop();
        }
        return null;
    }

    pub inline fn hasWork(self: *Worker) bool {
        if (self.deque) |*d| {
            return !d.isEmpty();
        }
        return false;
    }

    pub inline fn localDequeIsEmpty(self: *Worker) bool {
        if (self.deque) |*d| {
            return d.isEmpty();
        }
        return true;
    }
};

// ============================================================================
// Injected Job Node (for Treiber stack)
// ============================================================================

const InjectedJob = struct {
    job: *Job,
    next: ?*InjectedJob,
};

// ============================================================================
// Thread Pool
// ============================================================================

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    num_workers: usize,
    threads: std.ArrayListUnmanaged(std.Thread),
    sleep: Sleep,
    stopping: std.atomic.Value(bool),
    workers_ready: std.Thread.Semaphore,
    main_worker: Worker,

    // Treiber stack for injected jobs (lock-free)
    injected_jobs_head: std.atomic.Value(?*InjectedJob),

    pub fn init(allocator: std.mem.Allocator) ThreadPool {
        var pool = ThreadPool{
            .allocator = allocator,
            .workers = &.{},
            .num_workers = 0,
            .threads = .{},
            .sleep = Sleep.init(allocator, 0),
            .stopping = std.atomic.Value(bool).init(false),
            .workers_ready = .{},
            .main_worker = undefined,
            .injected_jobs_head = std.atomic.Value(?*InjectedJob).init(null),
        };
        pool.main_worker = Worker{ .pool = &pool };
        return pool;
    }

    /// Initialize with no workers (for testing).
    pub fn initEmpty(allocator: std.mem.Allocator) ThreadPool {
        return init(allocator);
    }

    pub fn start(self: *ThreadPool, config: ThreadPoolConfig) !void {
        const count = config.background_worker_count orelse (std.Thread.getCpuCount() catch 1);

        if (count == 0) {
            self.num_workers = 0;
            return;
        }

        // Reinitialize sleep manager with correct count
        self.sleep.deinit();
        self.sleep = Sleep.init(self.allocator, count);

        self.num_workers = count;
        self.workers = try self.allocator.alloc(Worker, count);
        for (self.workers) |*w| {
            w.* = Worker{ .pool = self };
        }

        // Initialize main worker with deque
        self.main_worker = Worker{ .pool = self };
        try self.main_worker.initDeque(self.allocator, 0xFFFF); // Special ID for main worker

        // Spawn worker threads
        for (0..count) |i| {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{ self, @as(u32, @intCast(i)) });
            try self.threads.append(self.allocator, thread);
        }

        // Wait for all workers to be ready
        for (0..count) |_| {
            self.workers_ready.wait();
        }
    }

    pub fn deinit(self: *ThreadPool) void {
        // Signal shutdown
        self.stopping.store(true, .release);
        self.sleep.wakeAll();

        // Wait for all threads
        for (self.threads.items) |thread| {
            thread.join();
        }

        // Clean up workers
        for (self.workers) |*w| {
            w.deinitDeque();
        }
        self.main_worker.deinitDeque();

        if (self.workers.len > 0) self.allocator.free(self.workers);
        self.threads.deinit(self.allocator);
        self.sleep.deinit();

        // Clean up any remaining injected jobs
        while (self.popInjectedJob()) |_| {}

        self.* = undefined;
    }

    pub fn numWorkers(self: *const ThreadPool) usize {
        return self.num_workers;
    }

    /// Execute a function on the pool (blocking).
    pub fn call(self: *ThreadPool, comptime T: type, func: anytype, arg: anytype) T {
        var task = self.main_worker.begin();
        return @call(.always_inline, func, .{ &task, arg });
    }

    // ========================================================================
    // Job Injection (for external submissions)
    // ========================================================================

    /// Check if there are injected jobs (lock-free).
    pub fn hasInjectedJobs(self: *const ThreadPool) bool {
        return self.injected_jobs_head.load(.acquire) != null;
    }

    /// Pop an injected job from the Treiber stack.
    pub fn popInjectedJob(self: *ThreadPool) ?*Job {
        while (true) {
            const head = self.injected_jobs_head.load(.acquire) orelse return null;
            if (self.injected_jobs_head.cmpxchgWeak(head, head.next, .acq_rel, .acquire) == null) {
                const job = head.job;
                self.allocator.destroy(head);
                return job;
            }
        }
    }

    /// Inject a job from an external thread (allocates InjectedJob node).
    pub fn injectJob(self: *ThreadPool, job: *Job) !void {
        const node = try self.allocator.create(InjectedJob);
        node.* = .{ .job = job, .next = null };

        var was_empty = false;
        while (true) {
            const head = self.injected_jobs_head.load(.acquire);
            was_empty = head == null;
            node.next = head;
            if (self.injected_jobs_head.cmpxchgWeak(head, node, .acq_rel, .acquire) == null) {
                break;
            }
        }

        self.sleep.newInjectedJobs(1, was_empty);
    }

    /// Notify that new jobs are available.
    pub inline fn notifyNewJobs(self: *ThreadPool, num_jobs: u32, queue_was_empty: bool) void {
        self.sleep.newInternalJobs(num_jobs, queue_was_empty);
    }

    pub inline fn notifyWorkAvailable(self: *ThreadPool) void {
        self.sleep.newInternalJobs(1, true);
    }

    // ========================================================================
    // Work Stealing
    // ========================================================================

    /// Try to steal work from other workers (including main_worker).
    /// Tries ALL workers to ensure work is found if available (reduces variance).
    pub fn tryStealFromOthers(self: *ThreadPool, self_worker: *Worker) ?*Job {
        const n = self.num_workers;

        // Try to steal from main_worker first (most likely to have work from join())
        if (self_worker != &self.main_worker) {
            if (self.main_worker.steal()) |job| {
                return job;
            }
        }

        if (n == 0) return null;

        // Try ALL background workers starting from random index.
        // This ensures we find work if it exists, reducing variance.
        const start_idx = self_worker.rng.nextBounded(n);

        for (0..n) |i| {
            const victim_idx = (start_idx + i) % n;
            if (victim_idx == self_worker.id) continue;

            if (self.workers[victim_idx].steal()) |job| {
                return job;
            }
        }

        return null;
    }

    /// Find work from any source.
    /// Priority: own deque (LIFO) > steal from others (FIFO) > injected queue.
    inline fn findWork(self: *ThreadPool, worker: *Worker) ?*Job {
        // 1. Own deque (LIFO pop) - fastest, best cache locality
        if (worker.pop()) |job| return job;

        // 2. Steal from random victim (FIFO steal)
        if (self.tryStealFromOthers(worker)) |job| return job;

        // 3. Global injected queue
        return self.popInjectedJob();
    }
};

/// Execute a job. Minimal overhead - no stats in hot path.
inline fn executeJob(worker: *Worker, job: *Job) void {
    var task = worker.begin();
    if (job.handler) |handler| {
        handler(&task, job);
    }
}

// ============================================================================
// Worker Main Loop
// ============================================================================

fn workerLoop(pool: *ThreadPool, worker_id: u32) void {
    const worker = &pool.workers[worker_id];
    worker.initDeque(pool.allocator, worker_id) catch @panic("Failed to init worker deque");

    // Signal ready
    pool.workers_ready.post();

    // Main loop
    while (!pool.stopping.load(.acquire)) {
        // Fast path: find and execute work
        if (pool.findWork(worker)) |job| {
            executeJob(worker, job);
            continue;
        }

        // Slow path: enter idle state
        var idle_state = pool.sleep.startLooking(worker_id);
        var found_work = false;

        while (!pool.stopping.load(.acquire)) {
            if (pool.findWork(worker)) |job| {
                found_work = true;
                const to_wake = pool.sleep.workFound();
                executeJob(worker, job);
                pool.sleep.wakeThreads(to_wake);
                break;
            }

            pool.sleep.noWorkFound(
                &idle_state,
                &worker.latch,
                pool,
            );
        }

        // If we exited idle loop without finding work, decrement inactive count
        if (!found_work) {
            _ = pool.sleep.workFound();
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Pool - init and call" {
    var pool = ThreadPool.init(std.testing.allocator);
    try pool.start(.{ .background_worker_count = 4 });
    defer pool.deinit();

    const result = pool.call(i32, struct {
        fn compute(task: *Task, x: i32) i32 {
            _ = task;
            return x * 2;
        }
    }.compute, @as(i32, 21));

    try std.testing.expectEqual(@as(i32, 42), result);
}

test "Pool - single threaded works" {
    var pool = ThreadPool.init(std.testing.allocator);
    try pool.start(.{ .background_worker_count = 0 });
    defer pool.deinit();

    const result = pool.call(i32, struct {
        fn compute(task: *Task, x: i32) i32 {
            _ = task;
            return x + 1;
        }
    }.compute, @as(i32, 10));

    try std.testing.expectEqual(@as(i32, 11), result);
}

test "AtomicCounters - bit packing" {
    var counters = AtomicCounters.init();

    var val = counters.load();
    try std.testing.expectEqual(@as(u16, 0), AtomicCounters.extractSleeping(val));
    try std.testing.expectEqual(@as(u16, 0), AtomicCounters.extractInactive(val));
    try std.testing.expectEqual(@as(u32, 0), AtomicCounters.extractJec(val));

    counters.addInactiveThread();
    val = counters.load();
    try std.testing.expectEqual(@as(u16, 1), AtomicCounters.extractInactive(val));

    _ = counters.tryAddSleepingThread(val);
    val = counters.load();
    try std.testing.expectEqual(@as(u16, 1), AtomicCounters.extractSleeping(val));

    _ = counters.incrementJecIfSleepy();
    val = counters.load();
    try std.testing.expectEqual(@as(u32, 1), AtomicCounters.extractJec(val));
}

test "CoreLatch - state transitions" {
    var latch = CoreLatch.init();

    try std.testing.expectEqual(CoreLatch.UNSET, latch.state.load(.seq_cst));
    try std.testing.expect(!latch.probe());

    // UNSET -> SLEEPY
    try std.testing.expect(latch.getSleepy());
    try std.testing.expectEqual(CoreLatch.SLEEPY, latch.state.load(.seq_cst));

    // SLEEPY -> SLEEPING
    try std.testing.expect(latch.fallAsleep());
    try std.testing.expectEqual(CoreLatch.SLEEPING, latch.state.load(.seq_cst));

    // SLEEPING -> UNSET via wakeUp
    latch.wakeUp();
    try std.testing.expectEqual(CoreLatch.UNSET, latch.state.load(.seq_cst));

    // Test set()
    _ = latch.set();
    try std.testing.expect(latch.probe());
}

test "Sleep - basic operations" {
    var sleep = Sleep.init(std.testing.allocator, 4);
    defer sleep.deinit();

    var val = sleep.counters.load();
    try std.testing.expectEqual(@as(u16, 0), AtomicCounters.extractInactive(val));

    const idle = sleep.startLooking(0);
    try std.testing.expectEqual(@as(u32, 0), idle.rounds);
    val = sleep.counters.load();
    try std.testing.expectEqual(@as(u16, 1), AtomicCounters.extractInactive(val));

    _ = sleep.workFound();
    val = sleep.counters.load();
    try std.testing.expectEqual(@as(u16, 0), AtomicCounters.extractInactive(val));
}
