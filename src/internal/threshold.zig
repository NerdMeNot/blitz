//! Intelligent Parallelism Threshold System for Blitz2
//!
//! Decides when to parallelize based on operation type, data size, and core count.
//! Like Polars - parallelism just works. Users never think about thresholds.
//!
//! Key principles:
//! 1. Operation-aware cost model (sort is 25x more expensive than sum per element)
//! 2. Scales with core count (more cores = lower threshold)
//! 3. Memory-bound operations skip parallelism (cache contention makes it slower)
//! 4. 10x overhead rule (only parallelize when benefit > 10x sync cost)
//!
//! Blitz2 uses heartbeat scheduling which has much lower overhead (~50ns per join
//! vs ~500ns in traditional work-stealing), so thresholds are lower.

const std = @import("std");
const api = @import("../api.zig");

/// Operation types with different computational costs.
pub const OpType = enum {
    // Reductions - compute-bound, parallelize for large data
    sum,
    min,
    max,
    mean,
    count,

    // Element-wise - memory-bound, SKIP parallelism (cache contention)
    add,
    sub,
    mul,
    div,
    compare,

    // Compute-intensive - low threshold, big wins
    sort,
    hash,
    join_probe,

    // Medium complexity
    filter,
    gather,
    groupby_agg,
};

/// Approximate cost per element in nanoseconds.
/// These are empirically-tuned values for modern CPUs with SIMD.
pub fn costPerElement(op: OpType) u32 {
    return switch (op) {
        // Fast SIMD reductions (~2ns/element with 8-wide vectors)
        .sum, .min, .max, .mean, .count => 2,

        // Memory-bound operations (~1ns/element, limited by bandwidth)
        .add, .sub, .mul, .div => 1,
        .compare => 2,

        // Moderate complexity
        .filter => 3, // Mask creation + branch
        .gather => 5, // Random access pattern

        // Compute-intensive operations
        .hash => 10, // Hash computation per element
        .groupby_agg => 15, // Scatter-accumulate pattern
        .join_probe => 30, // Hash lookup + comparison

        // O(n log n) amortized - very expensive
        .sort => 50,
    };
}

/// Returns true if the operation is memory-bound.
/// Memory-bound operations should NOT be parallelized because:
/// - Memory bandwidth is the bottleneck, not CPU
/// - Multiple threads compete for cache, making it slower
/// - Benchmarks showed parallel Add was slower than sequential Sub
pub fn isMemoryBound(op: OpType) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .compare => true,
        else => false,
    };
}

/// Decides whether an operation should use parallel execution.
///
/// Decision formula:
/// - work_ns = len x cost_per_element
/// - overhead_ns = num_workers x 500 (Blitz2 sync overhead ~500ns per worker)
/// - parallelize when: work_ns > overhead_ns x 10
///
/// Note: Blitz2 has 10x lower overhead than traditional work-stealing
/// thanks to heartbeat scheduling. This allows parallelizing smaller workloads.
pub fn shouldParallelize(op: OpType, len: usize) bool {
    // Memory-bound operations never benefit from parallelism
    if (isMemoryBound(op)) {
        return false;
    }

    // Get number of workers
    const num_workers = getNumWorkers();
    if (num_workers <= 1) {
        return false;
    }

    // Synchronization overhead: ~500ns per worker for heartbeat scheduling
    // This is 10x lower than Chase-Lev work-stealing (~5000ns)
    const overhead_ns: u64 = @as(u64, num_workers) * 500;

    // Work estimate: elements x cost per element
    const work_ns: u64 = @as(u64, len) * @as(u64, costPerElement(op));

    // 10x rule: only parallelize when work >> overhead
    return work_ns > overhead_ns * 10;
}

/// Get the effective number of workers.
fn getNumWorkers() u32 {
    return api.numWorkers();
}

/// Calculate the minimum threshold for an operation to be worth parallelizing.
/// Useful for debugging and tuning.
pub fn getThreshold(op: OpType) usize {
    if (isMemoryBound(op)) {
        return std.math.maxInt(usize); // Never parallelize
    }

    const num_workers = getNumWorkers();
    if (num_workers <= 1) {
        return std.math.maxInt(usize);
    }

    // threshold = (overhead x 10) / cost_per_element
    const overhead_ns: u64 = @as(u64, num_workers) * 500;
    const cost = costPerElement(op);

    return @intCast((overhead_ns * 10) / cost);
}

// ============================================================================
// Tests
// ============================================================================

test "memory-bound operations never parallelize" {
    // These should never return true regardless of size
    try std.testing.expect(!shouldParallelize(.add, 10_000_000));
    try std.testing.expect(!shouldParallelize(.sub, 10_000_000));
    try std.testing.expect(!shouldParallelize(.mul, 10_000_000));
    try std.testing.expect(!shouldParallelize(.div, 10_000_000));
    try std.testing.expect(!shouldParallelize(.compare, 10_000_000));
}

test "small data never parallelizes" {
    // Small data (100 elements) - never worth parallelizing
    try std.testing.expect(!shouldParallelize(.sum, 100));
    try std.testing.expect(!shouldParallelize(.sort, 100));
    try std.testing.expect(!shouldParallelize(.hash, 100));
}

test "threshold scales with operation cost" {
    // Sort is more expensive than sum, so it should have lower threshold
    const sort_threshold = getThreshold(.sort);
    const sum_threshold = getThreshold(.sum);

    // When pool isn't initialized, both return maxInt - skip comparison
    if (sort_threshold == std.math.maxInt(usize) and sum_threshold == std.math.maxInt(usize)) {
        return;
    }

    // Sort threshold should be much lower (sort is 25x more expensive per element)
    try std.testing.expect(sort_threshold < sum_threshold);
}

test "cost model values" {
    // Verify cost model makes sense (sort > hash > gather > filter > sum)
    try std.testing.expect(costPerElement(.sort) > costPerElement(.hash));
    try std.testing.expect(costPerElement(.hash) > costPerElement(.gather));
    try std.testing.expect(costPerElement(.gather) > costPerElement(.filter));
    try std.testing.expect(costPerElement(.filter) > costPerElement(.sum));
}
