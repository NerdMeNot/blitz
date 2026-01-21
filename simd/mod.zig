//! SIMD-Optimized Operations for Blitz
//!
//! High-performance vectorized implementations of common operations.
//! Uses multiple accumulators for instruction-level parallelism (ILP).

const std = @import("std");

// Re-export sub-modules
pub const aggregations = @import("aggregations.zig");
pub const argminmax = @import("argminmax.zig");
pub const search = @import("search.zig");
pub const parallel = @import("parallel.zig");

// Re-export constants
pub const VECTOR_WIDTH = aggregations.VECTOR_WIDTH;
pub const UNROLL_FACTOR = aggregations.UNROLL_FACTOR;
pub const CHUNK_SIZE = aggregations.CHUNK_SIZE;

// Re-export core aggregation functions
pub const sum = aggregations.sum;
pub const min = aggregations.min;
pub const max = aggregations.max;

// Re-export argmin/argmax functions
pub const ArgResult = argminmax.ArgResult;
pub const argmin = argminmax.argmin;
pub const argmax = argminmax.argmax;

// Re-export search functions
pub const findValue = search.findValue;
pub const anyGreaterThan = search.anyGreaterThan;
pub const allLessThan = search.allLessThan;
pub const isSimdCompatible = search.isSimdCompatible;

// Re-export parallel functions
pub const parallelSum = parallel.parallelSum;
pub const parallelMin = parallel.parallelMin;
pub const parallelMax = parallel.parallelMax;
pub const parallelArgmin = parallel.parallelArgmin;
pub const parallelArgmax = parallel.parallelArgmax;
pub const parallelArgminByKey = parallel.parallelArgminByKey;
pub const parallelArgmaxByKey = parallel.parallelArgmaxByKey;
pub const shouldParallelizeSimd = parallel.shouldParallelizeSimd;
pub const calculateParallelThreshold = parallel.calculateParallelThreshold;
pub const getParallelThreshold = parallel.getParallelThreshold;

// Tests
test {
    _ = @import("tests.zig");
}
