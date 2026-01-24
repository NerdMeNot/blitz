//! SIMD Aggregation Operations
//!
//! Core SIMD implementations for sum, min, max operations.
//! Uses adaptive vector widths based on target CPU capabilities.

const std = @import("std");

/// Unroll factor for hiding latency
pub const UNROLL_FACTOR: usize = 4;

/// Legacy constant for compatibility (8-wide for AVX2/NEON with 32-bit types)
pub const VECTOR_WIDTH: usize = 8;

/// Legacy constant for compatibility
pub const CHUNK_SIZE: usize = VECTOR_WIDTH * UNROLL_FACTOR;

/// Get the optimal vector width for a type based on target CPU.
/// Falls back to scalar (width=1) if SIMD is not available.
///
/// Examples:
/// - AVX2 (256-bit): i32 -> 8, i64 -> 4, f64 -> 4
/// - SSE2/NEON (128-bit): i32 -> 4, i64 -> 2, f64 -> 2
/// - No SIMD: returns 1 (scalar)
pub fn vectorWidth(comptime T: type) comptime_int {
    return std.simd.suggestVectorLength(T) orelse 1;
}

/// Get the chunk size for a type (vector width * unroll factor)
pub fn chunkSize(comptime T: type) comptime_int {
    return vectorWidth(T) * UNROLL_FACTOR;
}

// ============================================================================
// Sum
// ============================================================================

/// SIMD-optimized sum for integer and float types.
/// Uses 4 vector accumulators for instruction-level parallelism.
/// Vector width adapts to target CPU (AVX2: 8 x i32, SSE2/NEON: 4 x i32, etc.)
pub fn sum(comptime T: type, data: []const T) T {
    if (data.len == 0) return 0;

    const VEC_WIDTH = comptime vectorWidth(T);
    const CHUNK = comptime chunkSize(T);

    // Fall back to scalar if no SIMD or small array
    if (VEC_WIDTH == 1 or data.len < CHUNK) {
        return sumScalar(T, data);
    }

    const Vec = @Vector(VEC_WIDTH, T);

    // Use multiple accumulators to hide latency and enable ILP
    var acc0: Vec = @splat(0);
    var acc1: Vec = @splat(0);
    var acc2: Vec = @splat(0);
    var acc3: Vec = @splat(0);

    // Process CHUNK elements at a time (unrolled)
    const unrolled_len = data.len - (data.len % CHUNK);
    var i: usize = 0;

    while (i < unrolled_len) : (i += CHUNK) {
        const chunk0: Vec = data[i..][0..VEC_WIDTH].*;
        const chunk1: Vec = data[i + VEC_WIDTH ..][0..VEC_WIDTH].*;
        const chunk2: Vec = data[i + VEC_WIDTH * 2 ..][0..VEC_WIDTH].*;
        const chunk3: Vec = data[i + VEC_WIDTH * 3 ..][0..VEC_WIDTH].*;

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

/// SIMD-optimized minimum for integer and float types.
/// Vector width adapts to target CPU capabilities.
pub fn min(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;

    const VEC_WIDTH = comptime vectorWidth(T);
    const CHUNK = comptime chunkSize(T);

    // Fall back to scalar if no SIMD or small array
    if (VEC_WIDTH == 1 or data.len < CHUNK) {
        return minScalar(T, data);
    }

    const Vec = @Vector(VEC_WIDTH, T);
    const max_val: T = if (@typeInfo(T) == .float) std.math.inf(T) else std.math.maxInt(T);

    var acc0: Vec = @splat(max_val);
    var acc1: Vec = @splat(max_val);
    var acc2: Vec = @splat(max_val);
    var acc3: Vec = @splat(max_val);

    const unrolled_len = data.len - (data.len % CHUNK);
    var i: usize = 0;

    while (i < unrolled_len) : (i += CHUNK) {
        const chunk0: Vec = data[i..][0..VEC_WIDTH].*;
        const chunk1: Vec = data[i + VEC_WIDTH ..][0..VEC_WIDTH].*;
        const chunk2: Vec = data[i + VEC_WIDTH * 2 ..][0..VEC_WIDTH].*;
        const chunk3: Vec = data[i + VEC_WIDTH * 3 ..][0..VEC_WIDTH].*;

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

/// SIMD-optimized maximum for integer and float types.
/// Vector width adapts to target CPU capabilities.
pub fn max(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;

    const VEC_WIDTH = comptime vectorWidth(T);
    const CHUNK = comptime chunkSize(T);

    // Fall back to scalar if no SIMD or small array
    if (VEC_WIDTH == 1 or data.len < CHUNK) {
        return maxScalar(T, data);
    }

    const Vec = @Vector(VEC_WIDTH, T);
    const min_val: T = if (@typeInfo(T) == .float) -std.math.inf(T) else std.math.minInt(T);

    var acc0: Vec = @splat(min_val);
    var acc1: Vec = @splat(min_val);
    var acc2: Vec = @splat(min_val);
    var acc3: Vec = @splat(min_val);

    const unrolled_len = data.len - (data.len % CHUNK);
    var i: usize = 0;

    while (i < unrolled_len) : (i += CHUNK) {
        const chunk0: Vec = data[i..][0..VEC_WIDTH].*;
        const chunk1: Vec = data[i + VEC_WIDTH ..][0..VEC_WIDTH].*;
        const chunk2: Vec = data[i + VEC_WIDTH * 2 ..][0..VEC_WIDTH].*;
        const chunk3: Vec = data[i + VEC_WIDTH * 3 ..][0..VEC_WIDTH].*;

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

// ============================================================================
// Dot Product
// ============================================================================

/// SIMD-optimized dot product of two arrays.
/// Computes sum(a[i] * b[i]) for all i.
/// Vector width adapts to target CPU capabilities.
pub fn dotProduct(comptime T: type, a: []const T, b: []const T) T {
    const n = @min(a.len, b.len);
    if (n == 0) return 0;

    const VEC_WIDTH = comptime vectorWidth(T);
    const CHUNK = comptime chunkSize(T);

    // Fall back to scalar if no SIMD or small array
    if (VEC_WIDTH == 1 or n < CHUNK) {
        return dotProductScalar(T, a[0..n], b[0..n]);
    }

    const Vec = @Vector(VEC_WIDTH, T);

    // Use multiple accumulators for ILP
    var acc0: Vec = @splat(0);
    var acc1: Vec = @splat(0);
    var acc2: Vec = @splat(0);
    var acc3: Vec = @splat(0);

    const unrolled_len = n - (n % CHUNK);
    var i: usize = 0;

    while (i < unrolled_len) : (i += CHUNK) {
        const a0: Vec = a[i..][0..VEC_WIDTH].*;
        const a1: Vec = a[i + VEC_WIDTH ..][0..VEC_WIDTH].*;
        const a2: Vec = a[i + VEC_WIDTH * 2 ..][0..VEC_WIDTH].*;
        const a3: Vec = a[i + VEC_WIDTH * 3 ..][0..VEC_WIDTH].*;

        const b0: Vec = b[i..][0..VEC_WIDTH].*;
        const b1: Vec = b[i + VEC_WIDTH ..][0..VEC_WIDTH].*;
        const b2: Vec = b[i + VEC_WIDTH * 2 ..][0..VEC_WIDTH].*;
        const b3: Vec = b[i + VEC_WIDTH * 3 ..][0..VEC_WIDTH].*;

        acc0 += a0 * b0;
        acc1 += a1 * b1;
        acc2 += a2 * b2;
        acc3 += a3 * b3;
    }

    // Combine accumulators
    const combined = acc0 + acc1 + acc2 + acc3;
    var result: T = @reduce(.Add, combined);

    // Handle remainder
    for (i..n) |j| {
        result += a[j] * b[j];
    }

    return result;
}

/// Scalar dot product for small arrays.
pub fn dotProductScalar(comptime T: type, a: []const T, b: []const T) T {
    const n = @min(a.len, b.len);
    var result: T = 0;
    for (0..n) |i| {
        result += a[i] * b[i];
    }
    return result;
}
