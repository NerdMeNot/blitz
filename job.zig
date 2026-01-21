//! Job for Blitz - Rayon-style Work Stealing
//!
//! A Job represents a unit of work that can be stolen by another thread.
//! Jobs are stack-allocated in the caller's frame and pushed to a deque.
//!
//! Design principles (following Rayon):
//! - Jobs live on the stack (zero heap allocation for local execution)
//! - Chase-Lev deque provides instant visibility and mutual exclusion
//! - Owner pops from bottom, thieves steal from top
//! - Latch is embedded in the containing Future (no allocation needed)
//!
//! Size: 8 bytes (handler pointer only)

const std = @import("std");

// Forward declare Task to avoid circular import
pub const Task = @import("worker.zig").Task;

/// Job represents a unit of work pushed to the deque.
///
/// The job is stack-allocated in the owner's frame. When forked:
/// 1. Owner pushes job pointer to their deque
/// 2. Owner continues with other work
/// 3. On join: owner pops from deque (if still there) or waits on latch
///
/// Coordination uses Chase-Lev deque semantics:
/// - Owner: push to bottom, pop from bottom
/// - Thief: steal from top
/// - Only one thread gets the job (deque provides mutual exclusion)
///
/// The latch for completion signaling is embedded in the containing Future,
/// not in the Job itself. This allows zero-allocation for the common case
/// where the job is not stolen.
pub const Job = struct {
    /// Function to execute this job.
    /// Signature: fn(*Task, *Job) void
    /// The handler reads input from the containing struct and writes result.
    /// When called by a thief (stolen job), the handler is responsible for
    /// signaling the embedded latch in the containing Future.
    handler: ?*const fn (*Task, *Job) void = null,

    /// Create a new pending job.
    pub inline fn init() Job {
        return .{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Job - init creates empty job" {
    const job = Job.init();
    try std.testing.expect(job.handler == null);
}

test "Job - size is minimal" {
    // Job should be just a function pointer (8 bytes on 64-bit)
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Job));
}
