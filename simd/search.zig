//! SIMD Search Operations
//!
//! Fast vectorized search and predicate operations.

const std = @import("std");
const aggregations = @import("aggregations.zig");

const VECTOR_WIDTH = aggregations.VECTOR_WIDTH;

/// Check if type is compatible with SIMD operations
pub fn isSimdCompatible(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        .float => true,
        else => false,
    };
}

/// SIMD-accelerated find - finds first element matching a value.
/// Uses vector comparisons for faster searching.
pub fn findValue(comptime T: type, data: []const T, needle: T) ?usize {
    if (data.len == 0) return null;

    // For small arrays, use scalar
    if (data.len < VECTOR_WIDTH * 2 or !isSimdCompatible(T)) {
        for (data, 0..) |v, i| {
            if (v == needle) return i;
        }
        return null;
    }

    const Vec = @Vector(VECTOR_WIDTH, T);
    const needle_vec: Vec = @splat(needle);

    // Process in vector chunks
    const vec_len = data.len - (data.len % VECTOR_WIDTH);
    var i: usize = 0;

    while (i < vec_len) : (i += VECTOR_WIDTH) {
        const chunk: Vec = data[i..][0..VECTOR_WIDTH].*;
        const matches = chunk == needle_vec;

        // Check if any match (horizontal OR)
        if (@reduce(.Or, matches)) {
            // Find the exact index
            for (0..VECTOR_WIDTH) |lane| {
                if (matches[lane]) return i + lane;
            }
        }
    }

    // Handle remainder
    for (data[vec_len..], vec_len..) |v, idx| {
        if (v == needle) return idx;
    }

    return null;
}

/// SIMD-accelerated any - checks if any element satisfies condition.
/// Uses vector comparisons for threshold-based predicates.
pub fn anyGreaterThan(comptime T: type, data: []const T, threshold: T) bool {
    if (data.len == 0) return false;

    if (data.len < VECTOR_WIDTH * 2 or !isSimdCompatible(T)) {
        for (data) |v| {
            if (v > threshold) return true;
        }
        return false;
    }

    const Vec = @Vector(VECTOR_WIDTH, T);
    const threshold_vec: Vec = @splat(threshold);

    const vec_len = data.len - (data.len % VECTOR_WIDTH);
    var i: usize = 0;

    while (i < vec_len) : (i += VECTOR_WIDTH) {
        const chunk: Vec = data[i..][0..VECTOR_WIDTH].*;
        const matches = chunk > threshold_vec;

        if (@reduce(.Or, matches)) return true;
    }

    for (data[vec_len..]) |v| {
        if (v > threshold) return true;
    }

    return false;
}

/// SIMD-accelerated all - checks if all elements satisfy condition.
pub fn allLessThan(comptime T: type, data: []const T, threshold: T) bool {
    if (data.len == 0) return true;

    if (data.len < VECTOR_WIDTH * 2 or !isSimdCompatible(T)) {
        for (data) |v| {
            if (v >= threshold) return false;
        }
        return true;
    }

    const Vec = @Vector(VECTOR_WIDTH, T);
    const threshold_vec: Vec = @splat(threshold);

    const vec_len = data.len - (data.len % VECTOR_WIDTH);
    var i: usize = 0;

    while (i < vec_len) : (i += VECTOR_WIDTH) {
        const chunk: Vec = data[i..][0..VECTOR_WIDTH].*;
        const fails = chunk >= threshold_vec;

        if (@reduce(.Or, fails)) return false;
    }

    for (data[vec_len..]) |v| {
        if (v >= threshold) return false;
    }

    return true;
}
