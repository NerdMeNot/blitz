//! Sleep module for Blitz - Rayon-style with Aggressive External Wake
//!
//! Based on Rayon's proven sleep design with one key change:
//! When external work is injected, wake ALL sleeping workers immediately.
//! This eliminates cold start variance at the cost of brief thundering herd.
//!
//! For internal work (task spawning), use conservative cascading wake.

const std = @import("std");

/// Cache line size for preventing false sharing.
const CACHE_LINE = std.atomic.cache_line;

/// Number of rounds before becoming sleepy.
const ROUNDS_UNTIL_SLEEPY: u32 = 32;

/// Number of rounds until actually sleeping.
const ROUNDS_UNTIL_SLEEPING: u32 = ROUNDS_UNTIL_SLEEPY + 1;

/// Bits used for thread counters.
const THREADS_BITS: u6 = 16;

/// Maximum number of threads supported.
pub const THREADS_MAX: usize = (@as(usize, 1) << THREADS_BITS) - 1;

/// Bit shifts for packed counter fields.
const SLEEPING_SHIFT: u6 = 0;
const INACTIVE_SHIFT: u6 = THREADS_BITS;
const JEC_SHIFT: u6 = 2 * THREADS_BITS;

/// Constants for atomic operations.
const ONE_SLEEPING: usize = 1;
const ONE_INACTIVE: usize = @as(usize, 1) << INACTIVE_SHIFT;
const ONE_JEC: usize = @as(usize, 1) << JEC_SHIFT;
const THREADS_MASK: usize = (@as(usize, 1) << THREADS_BITS) - 1;

/// Packed counters for efficient atomic operations.
pub const Counters = struct {
    word: usize,

    pub fn init() Counters {
        return .{ .word = 0 };
    }

    pub fn sleepingThreads(self: Counters) usize {
        return (self.word >> SLEEPING_SHIFT) & THREADS_MASK;
    }

    pub fn inactiveThreads(self: Counters) usize {
        return (self.word >> INACTIVE_SHIFT) & THREADS_MASK;
    }

    pub fn awakeButIdleThreads(self: Counters) usize {
        const sleeping = self.sleepingThreads();
        const inactive = self.inactiveThreads();
        return if (inactive >= sleeping) inactive - sleeping else 0;
    }

    pub fn jobsEventCounter(self: Counters) usize {
        return self.word >> JEC_SHIFT;
    }

    pub fn jecIsSleepy(self: Counters) bool {
        return (self.jobsEventCounter() & 1) == 0;
    }

    pub fn jecIsActive(self: Counters) bool {
        return !self.jecIsSleepy();
    }

    pub fn withIncrementedJec(self: Counters) Counters {
        return .{ .word = self.word +% ONE_JEC };
    }

    pub fn withAddedSleeping(self: Counters) Counters {
        return .{ .word = self.word + ONE_SLEEPING };
    }
};

/// Atomic counters wrapper.
pub const AtomicCounters = struct {
    value: std.atomic.Value(usize) align(CACHE_LINE) = std.atomic.Value(usize).init(0),

    pub fn load(self: *const AtomicCounters, comptime order: std.builtin.AtomicOrder) Counters {
        return .{ .word = self.value.load(order) };
    }

    pub fn seqCstFence(self: *AtomicCounters) void {
        _ = self.value.fetchAdd(0, .seq_cst);
    }

    pub fn addInactiveThread(self: *AtomicCounters) void {
        _ = self.value.fetchAdd(ONE_INACTIVE, .seq_cst);
    }

    pub fn subInactiveThread(self: *AtomicCounters) usize {
        const old = Counters{ .word = self.value.fetchSub(ONE_INACTIVE, .seq_cst) };
        return @min(old.sleepingThreads(), 2);
    }

    pub fn tryAddSleepingThread(self: *AtomicCounters, expected: Counters) bool {
        const new = expected.withAddedSleeping();
        return self.value.cmpxchgStrong(expected.word, new.word, .seq_cst, .monotonic) == null;
    }

    pub fn subSleepingThread(self: *AtomicCounters) void {
        _ = self.value.fetchSub(ONE_SLEEPING, .seq_cst);
    }

    pub fn incrementJecIf(self: *AtomicCounters, comptime condition: fn (Counters) bool) Counters {
        while (true) {
            const old = self.load(.seq_cst);
            if (condition(old)) {
                const new = old.withIncrementedJec();
                if (self.value.cmpxchgWeak(old.word, new.word, .seq_cst, .monotonic) == null) {
                    return new;
                }
            } else {
                return old;
            }
        }
    }
};

/// Per-worker sleep state.
pub const WorkerSleepState = struct {
    is_blocked: bool = false,
    mutex: std.Thread.Mutex = .{},
    condvar: std.Thread.Condition = .{},
};

/// Idle state for a worker thread.
pub const IdleState = struct {
    worker_index: usize,
    rounds: u32 = 0,
    jec_when_sleepy: usize = std.math.maxInt(usize),

    pub fn wakeFully(self: *IdleState) void {
        self.rounds = 0;
        self.jec_when_sleepy = std.math.maxInt(usize);
    }

    pub fn wakePartly(self: *IdleState) void {
        self.rounds = ROUNDS_UNTIL_SLEEPY;
        self.jec_when_sleepy = std.math.maxInt(usize);
    }

    pub fn isSleepy(self: *const IdleState) bool {
        return self.jec_when_sleepy != std.math.maxInt(usize);
    }
};

/// Sleep manager.
pub const Sleep = struct {
    worker_states: []WorkerSleepState,
    counters: AtomicCounters = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n_threads: usize) Sleep {
        if (n_threads == 0) {
            return Sleep{
                .worker_states = &[_]WorkerSleepState{},
                .allocator = allocator,
            };
        }
        const states = allocator.alloc(WorkerSleepState, n_threads) catch @panic("OOM");
        for (states) |*state| {
            state.* = .{};
        }
        return Sleep{
            .worker_states = states,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Sleep) void {
        if (self.worker_states.len > 0) {
            self.allocator.free(self.worker_states);
        }
    }

    pub fn startLooking(self: *Sleep, worker_index: usize) IdleState {
        self.counters.addInactiveThread();
        return IdleState{ .worker_index = worker_index };
    }

    pub fn workFound(self: *Sleep) void {
        const threads_to_wake = self.counters.subInactiveThread();
        self.wakeAnyThreads(@intCast(threads_to_wake));
    }

    pub fn noWorkFound(
        self: *Sleep,
        idle_state: *IdleState,
        is_terminating: *const std.atomic.Value(bool),
        comptime Context: type,
        ctx: Context,
        comptime has_injected_jobs: fn (Context) bool,
    ) void {
        if (idle_state.rounds < ROUNDS_UNTIL_SLEEPY) {
            std.Thread.yield() catch {};
            idle_state.rounds += 1;
        } else if (idle_state.rounds == ROUNDS_UNTIL_SLEEPY) {
            idle_state.jec_when_sleepy = self.announceSleepy();
            idle_state.rounds += 1;
            std.Thread.yield() catch {};
        } else if (idle_state.rounds < ROUNDS_UNTIL_SLEEPING) {
            idle_state.rounds += 1;
            std.Thread.yield() catch {};
        } else {
            self.sleepImpl(idle_state, is_terminating, Context, ctx, has_injected_jobs);
        }
    }

    fn announceSleepy(self: *Sleep) usize {
        const counters = self.counters.incrementJecIf(Counters.jecIsActive);
        return counters.jobsEventCounter();
    }

    fn sleepImpl(
        self: *Sleep,
        idle_state: *IdleState,
        is_terminating: *const std.atomic.Value(bool),
        comptime Context: type,
        ctx: Context,
        comptime has_injected_jobs: fn (Context) bool,
    ) void {
        const worker_index = idle_state.worker_index;
        const sleep_state = &self.worker_states[worker_index];

        sleep_state.mutex.lock();

        while (true) {
            if (is_terminating.load(.acquire)) {
                sleep_state.mutex.unlock();
                idle_state.wakeFully();
                return;
            }

            const counters = self.counters.load(.seq_cst);

            if (counters.jobsEventCounter() != idle_state.jec_when_sleepy) {
                sleep_state.mutex.unlock();
                idle_state.wakePartly();
                return;
            }

            if (self.counters.tryAddSleepingThread(counters)) {
                break;
            }
        }

        self.counters.seqCstFence();

        if (has_injected_jobs(ctx)) {
            self.counters.subSleepingThread();
            sleep_state.mutex.unlock();
            idle_state.wakeFully();
            return;
        }

        sleep_state.is_blocked = true;
        while (sleep_state.is_blocked and !is_terminating.load(.acquire)) {
            sleep_state.condvar.wait(&sleep_state.mutex);
        }
        sleep_state.mutex.unlock();

        idle_state.wakeFully();
    }

    /// External work injection - wake ALL sleeping workers.
    /// This is aggressive but eliminates cold start variance.
    pub fn newInjectedJobs(self: *Sleep, num_jobs: u32, queue_was_empty: bool) void {
        _ = num_jobs;
        _ = queue_was_empty;
        self.counters.seqCstFence();
        _ = self.counters.incrementJecIf(Counters.jecIsSleepy);
        // Wake ALL sleeping workers for external work
        self.wakeAll();
    }

    /// Internal work - conservative cascading wake.
    pub fn newInternalJobs(self: *Sleep, num_jobs: u32, queue_was_empty: bool) void {
        const counters = self.counters.incrementJecIf(Counters.jecIsSleepy);

        const num_sleepers = counters.sleepingThreads();
        if (num_sleepers == 0) return;

        const num_awake_idle = counters.awakeButIdleThreads();

        if (!queue_was_empty) {
            self.wakeAnyThreads(@intCast(@min(num_jobs, num_sleepers)));
        } else if (num_awake_idle < num_jobs) {
            const needed = num_jobs - @as(u32, @intCast(num_awake_idle));
            self.wakeAnyThreads(@intCast(@min(needed, num_sleepers)));
        }
    }

    pub fn notifyWorkerLatchIsSet(self: *Sleep, target_worker_index: usize) void {
        _ = self.wakeSpecificThread(target_worker_index);
    }

    fn wakeAnyThreads(self: *Sleep, num_to_wake: u32) void {
        var remaining = num_to_wake;
        for (0..self.worker_states.len) |i| {
            if (remaining == 0) break;
            if (self.wakeSpecificThread(i)) {
                remaining -= 1;
            }
        }
    }

    pub fn wakeAll(self: *Sleep) void {
        for (0..self.worker_states.len) |i| {
            _ = self.wakeSpecificThread(i);
        }
    }

    fn wakeSpecificThread(self: *Sleep, index: usize) bool {
        const sleep_state = &self.worker_states[index];

        sleep_state.mutex.lock();
        defer sleep_state.mutex.unlock();

        if (sleep_state.is_blocked) {
            sleep_state.is_blocked = false;
            sleep_state.condvar.signal();
            self.counters.subSleepingThread();
            return true;
        }
        return false;
    }
};
