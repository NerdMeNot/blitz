//! Internal Utilities Module
//!
//! Contains shared utilities used by other Blitz modules.
//! Not intended for public use.

pub const threshold = @import("threshold.zig");
pub const splitter = @import("Splitter.zig");
pub const rng = @import("Rng.zig");

// Re-export commonly used types
pub const OpType = threshold.OpType;
pub const Splitter = splitter.Splitter;
pub const LengthSplitter = splitter.LengthSplitter;
pub const XorShift64Star = rng.XorShift64Star;

// Re-export commonly used functions
pub const shouldParallelize = threshold.shouldParallelize;
pub const getThreshold = threshold.getThreshold;
pub const isMemoryBound = threshold.isMemoryBound;
pub const costPerElement = threshold.costPerElement;

test {
    _ = threshold;
    _ = splitter;
    _ = rng;
}
