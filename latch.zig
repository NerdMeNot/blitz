//! Synchronization Primitives for Blitz
//!
//! Lightweight synchronization using futex for blocking.
//! Implements Rayon's 4-state latch protocol for robust wake guarantees.
//!
//! ## Memory Ordering
//!
//! Latches need to guarantee two things:
//! 1. Once `probe()` returns true, all memory effects from `setDone()` are visible
//!    (the set should synchronize-with the probe).
//! 2. Once `setDone()` occurs, the next `probe()` *will* observe it.
//!    This requires SeqCst ordering for state transitions.
//!
//! ## The "Tickle-Then-Get-Sleepy" Pattern
//!
//! The 4-state machine prevents a subtle race:
//! - Thread A checks latch (not set)
//! - Thread B sets latch
//! - Thread A sleeps -> MISSED WAKE!
//!
//! With the SLEEPY state:
//! - Thread A marks SLEEPY (announces intent to sleep)
//! - Thread A checks latch again (sees SET if B set it)
//! - Only if still not set, Thread A transitions to SLEEPING
//!
//! Reference: Rayon's latch.rs and sleep/README.md

const std = @import("std");
const Futex = std.Thread.Futex;

// ============================================================================
// SpinWait - Adaptive Spinning
// ============================================================================

/// Adaptive spinning utility for short waits.
/// Spins with increasing backoff before yielding/sleeping.
pub const SpinWait = struct {
    iteration: u32 = 0,

    const SPIN_LIMIT: u32 = 10;
    const YIELD_LIMIT: u32 = 20;

    pub fn reset(self: *SpinWait) void {
        self.iteration = 0;
    }

    /// Spin once, potentially yielding based on iteration count.
    pub fn spin(self: *SpinWait) void {
        if (self.iteration < SPIN_LIMIT) {
            // Exponential backoff with pause instruction
            const shift: u5 = @intCast(@min(self.iteration, 31));
            var spin_count: u32 = @as(u32, 1) << shift;
            while (spin_count > 0) : (spin_count -= 1) {
                std.atomic.spinLoopHint();
            }
        } else if (self.iteration < YIELD_LIMIT) {
            std.Thread.yield() catch {};
        } else {
            std.Thread.sleep(1_000); // 1 microsecond
        }
        self.iteration +|= 1;
    }

    /// Returns true if the next spin would yield.
    pub fn wouldYield(self: *const SpinWait) bool {
        return self.iteration >= SPIN_LIMIT;
    }
};

// ============================================================================
// OnceLatch - Single-Shot Completion Signal (4-State Protocol)
// ============================================================================

/// A single-shot latch that signals completion.
/// Once set, all waiters are released and future waits return immediately.
///
/// ## State Machine
///
/// ```
///     UNSET -----> SET (via setDone)
///       |           ^
///       v           |
///     SLEEPY -----> SET (via setDone)
///       |           ^
///       v           |
///    SLEEPING ----> SET (via setDone, triggers wake)
///       |
///       v
///     UNSET (via wakeUp, if woken spuriously)
/// ```
///
/// ## States
/// - UNSET (0): Latch not set, owning thread is awake
/// - SLEEPY (1): Latch not set, owning thread is preparing to sleep
/// - SLEEPING (2): Latch not set, owning thread is asleep and must be woken
/// - SET (3): Latch is set, all operations complete immediately
///
pub const OnceLatch = struct {
    /// Latch not set, owning thread is awake
    const UNSET: u32 = 0;
    /// Latch not set, owning thread is preparing to sleep (announced intent)
    const SLEEPY: u32 = 1;
    /// Latch not set, owning thread is asleep and needs wakeup
    const SLEEPING: u32 = 2;
    /// Latch is set - terminal state
    const SET: u32 = 3;

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(UNSET),

    pub fn init() OnceLatch {
        return .{};
    }

    /// Check if done (non-blocking). Use this in hot loops before wait().
    /// This is the equivalent of Rayon's latch.probe().
    ///
    /// Memory ordering: Acquire ensures we see all writes that happened before setDone().
    pub inline fn probe(self: *const OnceLatch) bool {
        return self.state.load(.acquire) == SET;
    }

    /// Alias for probe() for backwards compatibility.
    pub inline fn isDone(self: *const OnceLatch) bool {
        return self.probe();
    }

    /// Announce intent to sleep. Called by waiter before checking condition.
    /// Returns true if we successfully transitioned UNSET -> SLEEPY.
    /// Returns false if latch was already set (or in another state).
    ///
    /// Memory ordering: SeqCst to ensure the setter sees our intent before we check.
    fn getSleepy(self: *OnceLatch) bool {
        return self.state.cmpxchgStrong(UNSET, SLEEPY, .seq_cst, .seq_cst) == null;
    }

    /// Commit to sleeping. Called after getSleepy() and final condition check.
    /// Returns true if we successfully transitioned SLEEPY -> SLEEPING.
    /// Returns false if latch was set between getSleepy() and fallAsleep().
    ///
    /// Memory ordering: SeqCst to ensure happens-before with setDone().
    fn fallAsleep(self: *OnceLatch) bool {
        return self.state.cmpxchgStrong(SLEEPY, SLEEPING, .seq_cst, .seq_cst) == null;
    }

    /// Reset state after being woken (if not set).
    /// Called when woken from futex but latch might not be set (spurious wake).
    ///
    /// Memory ordering: SeqCst for consistency with other transitions.
    fn wakeUp(self: *OnceLatch) void {
        if (!self.probe()) {
            // Try to reset to UNSET. If latch was set between probe and CAS, that's fine.
            _ = self.state.cmpxchgStrong(SLEEPING, UNSET, .seq_cst, .seq_cst);
        }
    }

    /// Set to done and wake all waiters.
    /// Returns true if a waiter was sleeping and needs to be woken.
    ///
    /// Memory ordering: AcqRel for the swap ensures:
    /// - Acquire: we see all writes before any waiter's sleep
    /// - Release: waiters see all our writes when they observe SET
    pub fn setDone(self: *OnceLatch) void {
        const prev = self.state.swap(SET, .acq_rel);
        if (prev == SLEEPING) {
            // Waiter is actually sleeping on futex, must wake them
            Futex.wake(&self.state, std.math.maxInt(u32));
        }
        // If prev == SLEEPY, the waiter will see SET when they try fallAsleep()
        // If prev == UNSET, no waiter was waiting
    }

    /// Wait until done.
    ///
    /// Implements the "tickle-then-get-sleepy" pattern:
    /// 1. Spin for a bit (fast path for short waits)
    /// 2. Announce intent to sleep (getSleepy)
    /// 3. Check condition one more time
    /// 4. Commit to sleep (fallAsleep)
    /// 5. Actually sleep on futex
    /// 6. On wake, reset state if needed (wakeUp)
    pub fn wait(self: *OnceLatch) void {
        var spinner = SpinWait{};

        while (true) {
            // Fast path: already done
            if (self.probe()) return;

            // Spin phase: try spinning before going to sleep
            if (!spinner.wouldYield()) {
                spinner.spin();
                continue;
            }

            // Announce intent to sleep (UNSET -> SLEEPY)
            if (!self.getSleepy()) {
                // Failed to transition - either SET or already SLEEPY/SLEEPING
                // Check if set
                if (self.probe()) return;
                // Someone else is manipulating state, spin and retry
                spinner.spin();
                continue;
            }

            // CRITICAL: Check condition again after announcing intent
            // This is the key to preventing missed wakes
            if (self.probe()) {
                // Latch was set between our last check and getSleepy()
                // Reset state and return
                _ = self.state.cmpxchgStrong(SLEEPY, UNSET, .seq_cst, .seq_cst);
                return;
            }

            // Commit to sleeping (SLEEPY -> SLEEPING)
            if (!self.fallAsleep()) {
                // Failed - latch was set between getSleepy() and fallAsleep()
                // State is now SET, so we're done
                if (self.probe()) return;
                // Unexpected state, reset and retry
                self.wakeUp();
                continue;
            }

            // Actually sleep on futex
            // We pass SLEEPING as expected value - if state changed, we wake immediately
            Futex.wait(&self.state, SLEEPING);

            // Woken up - reset state if this was a spurious wake
            self.wakeUp();

            // Check if actually done
            if (self.probe()) return;

            // Spurious wake or race - reset spinner and continue
            spinner.reset();
        }
    }
};

// ============================================================================
// CountLatch - Countdown Latch
// ============================================================================

/// A countdown latch that blocks until count reaches zero.
/// Used for fork-join where we wait for N tasks.
pub const CountLatch = struct {
    const WAITER_BIT: u32 = 1 << 31;
    const COUNT_MASK: u32 = ~WAITER_BIT;

    state: std.atomic.Value(u32),

    pub fn init(count: u32) CountLatch {
        std.debug.assert(count <= COUNT_MASK);
        return .{
            .state = std.atomic.Value(u32).init(count),
        };
    }

    /// Get current count.
    pub fn getCount(self: *const CountLatch) u32 {
        return self.state.load(.acquire) & COUNT_MASK;
    }

    /// Check if count is zero.
    pub inline fn isDone(self: *const CountLatch) bool {
        return self.getCount() == 0;
    }

    /// Decrement count. Wakes waiters when reaching zero.
    pub fn countDown(self: *CountLatch) void {
        const prev = self.state.fetchSub(1, .acq_rel);
        const prev_count = prev & COUNT_MASK;
        const had_waiters = (prev & WAITER_BIT) != 0;

        std.debug.assert(prev_count > 0);

        if (prev_count == 1 and had_waiters) {
            Futex.wake(&self.state, std.math.maxInt(u32));
        }
    }

    /// Increment count.
    pub fn countUp(self: *CountLatch) void {
        const prev = self.state.fetchAdd(1, .acq_rel);
        std.debug.assert((prev & COUNT_MASK) < COUNT_MASK);
    }

    /// Wait until count reaches zero.
    pub fn wait(self: *CountLatch) void {
        var spinner = SpinWait{};

        while (true) {
            var state = self.state.load(.acquire);
            var count = state & COUNT_MASK;

            if (count == 0) return;

            if (!spinner.wouldYield()) {
                spinner.spin();
                continue;
            }

            // Set waiter bit and get current state in one operation
            if ((state & WAITER_BIT) == 0) {
                if (self.state.cmpxchgWeak(state, state | WAITER_BIT, .acq_rel, .acquire)) |failed_state| {
                    // CAS failed - use the current state we observed
                    state = failed_state;
                    count = state & COUNT_MASK;
                    if (count == 0) return;
                } else {
                    // CAS succeeded - state now has waiter bit set
                    state = state | WAITER_BIT;
                }
            }

            // Check count one more time before sleeping
            count = state & COUNT_MASK;
            if (count == 0) return;

            Futex.wait(&self.state, state);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SpinWait - basic" {
    var sw = SpinWait{};
    try std.testing.expect(!sw.wouldYield());

    for (0..10) |_| {
        sw.spin();
    }
    try std.testing.expect(sw.wouldYield());

    sw.reset();
    try std.testing.expect(!sw.wouldYield());
}

test "OnceLatch - basic" {
    var latch = OnceLatch.init();
    try std.testing.expect(!latch.isDone());
    try std.testing.expect(!latch.probe());

    latch.setDone();
    try std.testing.expect(latch.isDone());
    try std.testing.expect(latch.probe());

    // Wait returns immediately when already set
    latch.wait();
}

test "OnceLatch - state transitions" {
    // Test the 4-state protocol manually
    var latch = OnceLatch.init();

    // Initial state is UNSET
    try std.testing.expectEqual(OnceLatch.UNSET, latch.state.load(.seq_cst));

    // getSleepy: UNSET -> SLEEPY
    try std.testing.expect(latch.getSleepy());
    try std.testing.expectEqual(OnceLatch.SLEEPY, latch.state.load(.seq_cst));

    // Can't getSleepy again (already SLEEPY)
    try std.testing.expect(!latch.getSleepy());

    // fallAsleep: SLEEPY -> SLEEPING
    try std.testing.expect(latch.fallAsleep());
    try std.testing.expectEqual(OnceLatch.SLEEPING, latch.state.load(.seq_cst));

    // wakeUp: SLEEPING -> UNSET (when not set)
    latch.wakeUp();
    try std.testing.expectEqual(OnceLatch.UNSET, latch.state.load(.seq_cst));

    // setDone: * -> SET
    latch.setDone();
    try std.testing.expectEqual(OnceLatch.SET, latch.state.load(.seq_cst));
    try std.testing.expect(latch.probe());
}

test "OnceLatch - setDone while SLEEPING wakes waiter" {
    var latch = OnceLatch.init();

    // Simulate waiter going to sleep
    try std.testing.expect(latch.getSleepy());
    try std.testing.expect(latch.fallAsleep());
    try std.testing.expectEqual(OnceLatch.SLEEPING, latch.state.load(.seq_cst));

    // Setter sets the latch - this should trigger wake
    latch.setDone();
    try std.testing.expectEqual(OnceLatch.SET, latch.state.load(.seq_cst));
}

test "OnceLatch - setDone while SLEEPY prevents sleep" {
    var latch = OnceLatch.init();

    // Waiter announces intent to sleep
    try std.testing.expect(latch.getSleepy());
    try std.testing.expectEqual(OnceLatch.SLEEPY, latch.state.load(.seq_cst));

    // Setter sets before waiter commits to sleeping
    latch.setDone();
    try std.testing.expectEqual(OnceLatch.SET, latch.state.load(.seq_cst));

    // Waiter tries to commit but fails (state is SET, not SLEEPY)
    try std.testing.expect(!latch.fallAsleep());
    try std.testing.expect(latch.probe());
}

test "OnceLatch - concurrent wait and set" {
    // Stress test the 4-state protocol with multiple threads
    const num_iterations = 1000;

    for (0..num_iterations) |_| {
        var latch = OnceLatch.init();
        var waiter_done = std.atomic.Value(bool).init(false);

        // Waiter thread
        const waiter = std.Thread.spawn(.{}, struct {
            fn run(l: *OnceLatch, done: *std.atomic.Value(bool)) void {
                l.wait();
                done.store(true, .release);
            }
        }.run, .{ &latch, &waiter_done }) catch unreachable;

        // Small random delay to vary timing
        std.Thread.yield() catch {};

        // Setter thread (main)
        latch.setDone();

        // Wait for waiter to complete
        waiter.join();

        // Verify waiter saw the set
        try std.testing.expect(waiter_done.load(.acquire));
        try std.testing.expect(latch.probe());
    }
}

test "CountLatch - countdown" {
    var latch = CountLatch.init(3);

    try std.testing.expectEqual(@as(u32, 3), latch.getCount());
    try std.testing.expect(!latch.isDone());

    latch.countDown();
    latch.countDown();
    latch.countDown();

    try std.testing.expect(latch.isDone());
}
