//! Adaptive Splitter for Blitz
//!
//! Implements Rayon-style thief-splitting heuristics that automatically
//! decide when to split work vs execute sequentially.
//!
//! The key insight from Rayon:
//! - Start with num_threads worth of desired parallelism
//! - When work is stolen, reset the split counter (thief will keep dividing)
//! - When not stolen, halve the counter until we run sequentially
//!
//! This creates a binary tree of tasks that naturally maps to thread count,
//! adapting to actual parallelism available without manual tuning.

const std = @import("std");

/// Get the number of worker threads from the pool.
/// Imported here to avoid circular dependencies.
fn getNumWorkers() usize {
    // Import at runtime to avoid circular dependency
    const api = @import("../api.zig");
    return @intCast(api.numWorkers());
}

/// Adaptive splitter that decides when to split work.
///
/// Creates a binary tree of tasks that naturally maps to thread count.
/// Each split halves the remaining count until we reach 0, at which point
/// we execute sequentially.
///
/// Usage:
/// ```zig
/// var splitter = Splitter.init();
///
/// fn processRange(splitter: *Splitter, start: usize, end: usize) void {
///     if (!splitter.trySplit()) {
///         // Base case: execute sequentially
///         for (start..end) |i| process(i);
///         return;
///     }
///     // Recursive case: split and potentially parallelize
///     const mid = start + (end - start) / 2;
///     fork(processRange, splitter, mid, end);
///     processRange(splitter, start, mid);
///     join();
/// }
/// ```
pub const Splitter = struct {
    /// Remaining splits before we go sequential.
    /// Starts at num_workers, halves on each split.
    splits: usize,

    /// Initialize a splitter with parallelism matching thread count.
    /// Creates log2(num_workers) levels of parallelism.
    pub fn init() Splitter {
        return .{ .splits = getNumWorkers() };
    }

    /// Initialize with a specific split count.
    /// Use this for testing or custom parallelism levels.
    pub fn initWithSplits(splits: usize) Splitter {
        return .{ .splits = splits };
    }

    /// Decide whether to split work.
    ///
    /// Returns true if we should split (fork), false if we should run sequentially.
    /// Each call halves the remaining splits.
    pub fn trySplit(self: *Splitter) bool {
        if (self.splits > 0) {
            self.splits /= 2;
            return true;
        }
        return false;
    }

    /// Version with migration hint for future optimization.
    /// Currently ignores the hint, but API allows future thief-splitting.
    pub fn trySplitWithHint(self: *Splitter, _: bool) bool {
        // TODO: Implement thief-splitting when migration detection is added
        // For now, use simple halving
        return self.trySplit();
    }

    /// Check if we should split without consuming a split.
    /// Useful for lookahead decisions.
    pub fn shouldSplit(self: *const Splitter) bool {
        return self.splits > 0;
    }

    /// Get remaining splits (for debugging/testing).
    pub fn remaining(self: *const Splitter) usize {
        return self.splits;
    }

    /// Clone the splitter for passing to forked tasks.
    /// Each branch gets its own split counter.
    pub fn clone(self: *const Splitter) Splitter {
        return .{ .splits = self.splits };
    }
};

/// Length-aware splitter that considers both parallelism and data size.
///
/// Extends Splitter with minimum and maximum length constraints:
/// - min_len: Never split below this size (avoids overhead on tiny chunks)
/// - max_len: Ensure at least len/max_len splits (for large data)
///
/// This prevents:
/// 1. Creating too many tiny tasks (overhead kills speedup)
/// 2. Creating too few tasks for large data (underutilized cores)
pub const LengthSplitter = struct {
    inner: Splitter,
    min_len: usize,

    /// Default minimum chunk size (elements per task).
    /// Below this, parallelism overhead exceeds benefit.
    pub const DEFAULT_MIN_LEN: usize = 1;

    /// Default maximum chunk size.
    /// Above this, we want to split even if splitter says no.
    pub const DEFAULT_MAX_LEN: usize = 8192;

    /// Create a length-aware splitter.
    ///
    /// Parameters:
    /// - len: Total number of elements to process
    /// - min_len: Minimum elements per chunk (never split below this)
    /// - max_len: Maximum elements per chunk (ensure enough splits for large data)
    pub fn init(len: usize, min_len: usize, max_len: usize) LengthSplitter {
        var splitter = Splitter.init();

        // Ensure we create enough splits for large data.
        // If len=1M and max_len=1024, we want at least 1000 splits.
        if (max_len > 0) {
            const min_splits = len / max_len;
            if (min_splits > splitter.splits) {
                // Round up to next power of 2 for balanced tree
                splitter.splits = std.math.ceilPowerOfTwo(usize, min_splits) catch min_splits;
            }
        }

        return .{
            .inner = splitter,
            .min_len = min_len,
        };
    }

    /// Create with default min/max lengths.
    pub fn initDefault(len: usize) LengthSplitter {
        return init(len, DEFAULT_MIN_LEN, DEFAULT_MAX_LEN);
    }

    /// Create with custom minimum length only.
    pub fn initWithMin(len: usize, min_len: usize) LengthSplitter {
        return init(len, min_len, DEFAULT_MAX_LEN);
    }

    /// Decide whether to split, considering both parallelism and data size.
    ///
    /// Returns false if:
    /// - len < min_len (chunk too small, overhead would dominate)
    /// - No more splits remaining
    ///
    /// Returns true if:
    /// - Splitter says split AND len >= min_len
    pub fn trySplit(self: *LengthSplitter, len: usize) bool {
        if (len < self.min_len) {
            return false;
        }
        return self.inner.trySplit();
    }

    /// Version with migration hint for future optimization.
    pub fn trySplitWithHint(self: *LengthSplitter, len: usize, hint: bool) bool {
        if (len < self.min_len) {
            return false;
        }
        return self.inner.trySplitWithHint(hint);
    }

    /// Check if we should split without consuming.
    pub fn shouldSplit(self: *const LengthSplitter, len: usize) bool {
        if (len < self.min_len) {
            return false;
        }
        return self.inner.shouldSplit();
    }

    /// Get remaining splits.
    pub fn remaining(self: *const LengthSplitter) usize {
        return self.inner.remaining();
    }

    /// Clone the splitter for passing to forked tasks.
    pub fn clone(self: *const LengthSplitter) LengthSplitter {
        return .{
            .inner = self.inner.clone(),
            .min_len = self.min_len,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Splitter - basic split behavior" {
    var splitter = Splitter.initWithSplits(8);

    // Should split while splits > 0
    try std.testing.expect(splitter.trySplit()); // splits: 8 -> 4
    try std.testing.expectEqual(@as(usize, 4), splitter.remaining());

    try std.testing.expect(splitter.trySplit()); // splits: 4 -> 2
    try std.testing.expectEqual(@as(usize, 2), splitter.remaining());

    try std.testing.expect(splitter.trySplit()); // splits: 2 -> 1
    try std.testing.expectEqual(@as(usize, 1), splitter.remaining());

    try std.testing.expect(splitter.trySplit()); // splits: 1 -> 0
    try std.testing.expectEqual(@as(usize, 0), splitter.remaining());

    // Should not split when splits == 0
    try std.testing.expect(!splitter.trySplit());
}

test "Splitter - clone preserves state" {
    var splitter = Splitter.initWithSplits(8);

    _ = splitter.trySplit(); // 8 -> 4
    _ = splitter.trySplit(); // 4 -> 2
    try std.testing.expectEqual(@as(usize, 2), splitter.remaining());

    // Clone should have same state
    const cloned = splitter.clone();
    try std.testing.expectEqual(@as(usize, 2), cloned.remaining());
}

test "LengthSplitter - respects min_len" {
    var splitter = LengthSplitter.init(1000, 100, 500);

    // Should split when len >= min_len
    try std.testing.expect(splitter.trySplit(100));

    // Should NOT split when len < min_len
    try std.testing.expect(!splitter.trySplit(50));
}

test "LengthSplitter - ensures enough splits for large data" {
    // 1M elements with max_len=1024 should have at least 1000 splits
    const splitter = LengthSplitter.init(1_000_000, 1, 1024);

    // Should have at least 1000 splits (rounded to power of 2 = 1024)
    try std.testing.expect(splitter.remaining() >= 1000);
}

test "LengthSplitter - default initialization" {
    const splitter = LengthSplitter.initDefault(10000);

    // Should be properly initialized
    try std.testing.expect(splitter.min_len == LengthSplitter.DEFAULT_MIN_LEN);
    try std.testing.expect(splitter.remaining() > 0);
}

test "Splitter - shouldSplit lookahead" {
    var splitter = Splitter.initWithSplits(2);

    // shouldSplit doesn't consume
    try std.testing.expect(splitter.shouldSplit());
    try std.testing.expect(splitter.shouldSplit());
    try std.testing.expectEqual(@as(usize, 2), splitter.remaining());

    // trySplit does consume
    _ = splitter.trySplit();
    try std.testing.expectEqual(@as(usize, 1), splitter.remaining());
}

test "LengthSplitter - clone preserves state" {
    var splitter = LengthSplitter.init(10000, 100, 1000);

    _ = splitter.trySplit(500); // Should split
    const remaining_before = splitter.remaining();

    const cloned = splitter.clone();
    try std.testing.expectEqual(remaining_before, cloned.remaining());
    try std.testing.expectEqual(splitter.min_len, cloned.min_len);
}
