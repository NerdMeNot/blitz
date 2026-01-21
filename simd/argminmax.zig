//! SIMD Argmin/Argmax Operations
//!
//! Returns both the value and index of min/max elements.

const std = @import("std");
const aggregations = @import("aggregations.zig");
const search = @import("search.zig");

const VECTOR_WIDTH = aggregations.VECTOR_WIDTH;
const CHUNK_SIZE = aggregations.CHUNK_SIZE;

/// Result of argmin/argmax operation
pub fn ArgResult(comptime T: type) type {
    return struct {
        value: T,
        index: usize,
    };
}

/// SIMD-optimized argmin - returns minimum value and its index.
/// Uses vector comparisons to track both value and index efficiently.
/// For ties, returns the first (leftmost) occurrence.
pub fn argmin(comptime T: type, data: []const T) ?ArgResult(T) {
    if (data.len == 0) return null;

    // For small arrays or non-integer types, use scalar
    if (data.len < CHUNK_SIZE or !search.isSimdCompatible(T)) {
        return argminScalar(T, data);
    }

    const Vec = @Vector(VECTOR_WIDTH, T);
    const IdxVec = @Vector(VECTOR_WIDTH, usize);

    // Initialize with maximum values
    const max_val: T = if (@typeInfo(T) == .int) std.math.maxInt(T) else std.math.floatMax(T);
    var min_vec: Vec = @splat(max_val);
    var min_idx: IdxVec = @splat(0);

    // Create initial index vector [0, 1, 2, ..., VECTOR_WIDTH-1]
    var base_idx: IdxVec = undefined;
    for (0..VECTOR_WIDTH) |i| {
        base_idx[i] = i;
    }
    const stride: IdxVec = @splat(VECTOR_WIDTH);

    // Process in vector chunks
    const vec_len = data.len - (data.len % VECTOR_WIDTH);
    var i: usize = 0;
    var current_idx = base_idx;

    while (i < vec_len) : (i += VECTOR_WIDTH) {
        const chunk: Vec = data[i..][0..VECTOR_WIDTH].*;

        // Compare: which elements are smaller?
        const is_smaller = chunk < min_vec;

        // Update minimum values and indices using select
        min_vec = @select(T, is_smaller, chunk, min_vec);
        min_idx = @select(usize, is_smaller, current_idx, min_idx);

        current_idx += stride;
    }

    // Horizontal reduction: find the minimum across vector lanes
    var best_val = min_vec[0];
    var best_idx = min_idx[0];

    for (1..VECTOR_WIDTH) |lane| {
        if (min_vec[lane] < best_val) {
            best_val = min_vec[lane];
            best_idx = min_idx[lane];
        } else if (min_vec[lane] == best_val and min_idx[lane] < best_idx) {
            // For ties, prefer the earlier index
            best_idx = min_idx[lane];
        }
    }

    // Handle remainder
    for (data[vec_len..], vec_len..) |v, idx| {
        if (v < best_val) {
            best_val = v;
            best_idx = idx;
        }
    }

    return .{ .value = best_val, .index = best_idx };
}

/// SIMD-optimized argmax - returns maximum value and its index.
pub fn argmax(comptime T: type, data: []const T) ?ArgResult(T) {
    if (data.len == 0) return null;

    // For small arrays or non-integer types, use scalar
    if (data.len < CHUNK_SIZE or !search.isSimdCompatible(T)) {
        return argmaxScalar(T, data);
    }

    const Vec = @Vector(VECTOR_WIDTH, T);
    const IdxVec = @Vector(VECTOR_WIDTH, usize);

    // Initialize with minimum values
    const min_val: T = if (@typeInfo(T) == .int) std.math.minInt(T) else -std.math.floatMax(T);
    var max_vec: Vec = @splat(min_val);
    var max_idx: IdxVec = @splat(0);

    // Create initial index vector
    var base_idx: IdxVec = undefined;
    for (0..VECTOR_WIDTH) |i| {
        base_idx[i] = i;
    }
    const stride: IdxVec = @splat(VECTOR_WIDTH);

    // Process in vector chunks
    const vec_len = data.len - (data.len % VECTOR_WIDTH);
    var i: usize = 0;
    var current_idx = base_idx;

    while (i < vec_len) : (i += VECTOR_WIDTH) {
        const chunk: Vec = data[i..][0..VECTOR_WIDTH].*;

        // Compare: which elements are larger?
        const is_larger = chunk > max_vec;

        // Update maximum values and indices
        max_vec = @select(T, is_larger, chunk, max_vec);
        max_idx = @select(usize, is_larger, current_idx, max_idx);

        current_idx += stride;
    }

    // Horizontal reduction
    var best_val = max_vec[0];
    var best_idx = max_idx[0];

    for (1..VECTOR_WIDTH) |lane| {
        if (max_vec[lane] > best_val) {
            best_val = max_vec[lane];
            best_idx = max_idx[lane];
        } else if (max_vec[lane] == best_val and max_idx[lane] < best_idx) {
            best_idx = max_idx[lane];
        }
    }

    // Handle remainder
    for (data[vec_len..], vec_len..) |v, idx| {
        if (v > best_val) {
            best_val = v;
            best_idx = idx;
        }
    }

    return .{ .value = best_val, .index = best_idx };
}

/// Scalar argmin for small arrays or unsupported types
pub fn argminScalar(comptime T: type, data: []const T) ?ArgResult(T) {
    if (data.len == 0) return null;
    var best_val = data[0];
    var best_idx: usize = 0;
    for (data[1..], 1..) |v, i| {
        if (v < best_val) {
            best_val = v;
            best_idx = i;
        }
    }
    return .{ .value = best_val, .index = best_idx };
}

/// Scalar argmax for small arrays or unsupported types
pub fn argmaxScalar(comptime T: type, data: []const T) ?ArgResult(T) {
    if (data.len == 0) return null;
    var best_val = data[0];
    var best_idx: usize = 0;
    for (data[1..], 1..) |v, i| {
        if (v > best_val) {
            best_val = v;
            best_idx = i;
        }
    }
    return .{ .value = best_val, .index = best_idx };
}
