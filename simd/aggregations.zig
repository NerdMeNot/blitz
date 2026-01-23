//! SIMD Aggregation Operations
//!
//! Core SIMD implementations for sum, min, max operations.

const std = @import("std");

/// Vector width for SIMD operations (8 elements for AVX2/NEON)
pub const VECTOR_WIDTH: usize = 8;

/// Unroll factor for hiding latency
pub const UNROLL_FACTOR: usize = 4;

/// Chunk size for unrolled loops
pub const CHUNK_SIZE: usize = VECTOR_WIDTH * UNROLL_FACTOR;

// ============================================================================
// Sum
// ============================================================================

/// SIMD-optimized sum for integer types.
/// Uses 4 vector accumulators for instruction-level parallelism.
pub fn sum(comptime T: type, data: []const T) T {
    if (data.len == 0) return 0;

    // For small arrays, use scalar
    if (data.len < CHUNK_SIZE) {
        return sumScalar(T, data);
    }

    const Vec = @Vector(VECTOR_WIDTH, T);

    // Use multiple accumulators to hide latency and enable ILP
    var acc0: Vec = @splat(0);
    var acc1: Vec = @splat(0);
    var acc2: Vec = @splat(0);
    var acc3: Vec = @splat(0);

    // Process CHUNK_SIZE elements at a time (unrolled)
    const unrolled_len = data.len - (data.len % CHUNK_SIZE);
    var i: usize = 0;

    while (i < unrolled_len) : (i += CHUNK_SIZE) {
        const chunk0: Vec = data[i..][0..VECTOR_WIDTH].*;
        const chunk1: Vec = data[i + VECTOR_WIDTH ..][0..VECTOR_WIDTH].*;
        const chunk2: Vec = data[i + VECTOR_WIDTH * 2 ..][0..VECTOR_WIDTH].*;
        const chunk3: Vec = data[i + VECTOR_WIDTH * 3 ..][0..VECTOR_WIDTH].*;

        acc0 += chunk0;
        acc1 += chunk1;
        acc2 += chunk2;
        acc3 += chunk3;
    }

    // Combine accumulators
    const combined = acc0 + acc1 + acc2 + acc3;

    // Horizontal sum of vector
    var result: T = @reduce(.Add, combined);

    // Handle remainder
    for (data[unrolled_len..]) |v| {
        result += v;
    }

    return result;
}

/// Scalar sum for small arrays or remainder.
pub fn sumScalar(comptime T: type, data: []const T) T {
    var result: T = 0;
    for (data) |v| {
        result += v;
    }
    return result;
}

// ============================================================================
// Min
// ============================================================================

/// SIMD-optimized minimum for integer types.
pub fn min(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;

    if (data.len < CHUNK_SIZE) {
        return minScalar(T, data);
    }

    const Vec = @Vector(VECTOR_WIDTH, T);
    const max_val: T = if (@typeInfo(T) == .float) std.math.inf(T) else std.math.maxInt(T);

    var acc0: Vec = @splat(max_val);
    var acc1: Vec = @splat(max_val);
    var acc2: Vec = @splat(max_val);
    var acc3: Vec = @splat(max_val);

    const unrolled_len = data.len - (data.len % CHUNK_SIZE);
    var i: usize = 0;

    while (i < unrolled_len) : (i += CHUNK_SIZE) {
        const chunk0: Vec = data[i..][0..VECTOR_WIDTH].*;
        const chunk1: Vec = data[i + VECTOR_WIDTH ..][0..VECTOR_WIDTH].*;
        const chunk2: Vec = data[i + VECTOR_WIDTH * 2 ..][0..VECTOR_WIDTH].*;
        const chunk3: Vec = data[i + VECTOR_WIDTH * 3 ..][0..VECTOR_WIDTH].*;

        acc0 = @min(acc0, chunk0);
        acc1 = @min(acc1, chunk1);
        acc2 = @min(acc2, chunk2);
        acc3 = @min(acc3, chunk3);
    }

    // Combine accumulators
    const combined = @min(@min(acc0, acc1), @min(acc2, acc3));
    var result: T = @reduce(.Min, combined);

    // Handle remainder
    for (data[unrolled_len..]) |v| {
        if (v < result) result = v;
    }

    return result;
}

/// Scalar min for small arrays.
pub fn minScalar(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;
    var result: T = data[0];
    for (data[1..]) |v| {
        if (v < result) result = v;
    }
    return result;
}

// ============================================================================
// Max
// ============================================================================

/// SIMD-optimized maximum for integer types.
pub fn max(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;

    if (data.len < CHUNK_SIZE) {
        return maxScalar(T, data);
    }

    const Vec = @Vector(VECTOR_WIDTH, T);
    const min_val: T = if (@typeInfo(T) == .float) -std.math.inf(T) else std.math.minInt(T);

    var acc0: Vec = @splat(min_val);
    var acc1: Vec = @splat(min_val);
    var acc2: Vec = @splat(min_val);
    var acc3: Vec = @splat(min_val);

    const unrolled_len = data.len - (data.len % CHUNK_SIZE);
    var i: usize = 0;

    while (i < unrolled_len) : (i += CHUNK_SIZE) {
        const chunk0: Vec = data[i..][0..VECTOR_WIDTH].*;
        const chunk1: Vec = data[i + VECTOR_WIDTH ..][0..VECTOR_WIDTH].*;
        const chunk2: Vec = data[i + VECTOR_WIDTH * 2 ..][0..VECTOR_WIDTH].*;
        const chunk3: Vec = data[i + VECTOR_WIDTH * 3 ..][0..VECTOR_WIDTH].*;

        acc0 = @max(acc0, chunk0);
        acc1 = @max(acc1, chunk1);
        acc2 = @max(acc2, chunk2);
        acc3 = @max(acc3, chunk3);
    }

    // Combine accumulators
    const combined = @max(@max(acc0, acc1), @max(acc2, acc3));
    var result: T = @reduce(.Max, combined);

    // Handle remainder
    for (data[unrolled_len..]) |v| {
        if (v > result) result = v;
    }

    return result;
}

/// Scalar max for small arrays.
pub fn maxScalar(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;
    var result: T = data[0];
    for (data[1..]) |v| {
        if (v > result) result = v;
    }
    return result;
}
