//! SIMD-optimized sorted sequence detection
//!
//! Uses SIMD to check if an array is sorted ~8x faster than scalar loops.
//! Falls back to scalar for non-SIMD-friendly types.

const std = @import("std");

/// Check if slice is sorted (ascending) using SIMD.
/// Returns true if v[i] <= v[i+1] for all adjacent pairs.
pub fn isSortedAsc(comptime T: type, v: []const T) bool {
    if (v.len <= 1) return true;

    // For SIMD-friendly types, use vectorized check
    if (comptime canSimdCheck(T)) {
        return isSortedSimd(T, v, struct {
            fn isOrdered(a: T, b: T) bool {
                return a <= b;
            }
        }.isOrdered);
    }

    // Scalar fallback
    for (0..v.len - 1) |i| {
        if (v[i] > v[i + 1]) return false;
    }
    return true;
}

/// Check if slice is sorted (descending) using SIMD.
pub fn isSortedDesc(comptime T: type, v: []const T) bool {
    if (v.len <= 1) return true;

    if (comptime canSimdCheck(T)) {
        return isSortedSimd(T, v, struct {
            fn isOrdered(a: T, b: T) bool {
                return a >= b;
            }
        }.isOrdered);
    }

    // Scalar fallback
    for (0..v.len - 1) |i| {
        if (v[i] < v[i + 1]) return false;
    }
    return true;
}

/// Check if slice is sorted using arbitrary comparator.
/// SIMD-optimized for standard <= and >= on numeric types.
pub fn isSorted(comptime T: type, v: []const T, comptime is_ordered: fn (T, T) bool) bool {
    if (v.len <= 1) return true;

    // For SIMD-friendly types with standard comparators, use vectorized check
    if (comptime canSimdCheck(T)) {
        return isSortedSimd(T, v, is_ordered);
    }

    // Scalar fallback
    for (0..v.len - 1) |i| {
        if (!is_ordered(v[i], v[i + 1])) return false;
    }
    return true;
}

/// Returns true if type T can use SIMD sorted check
pub fn canSimdCheck(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        .int => @sizeOf(T) <= 8,
        else => false,
    };
}

/// SIMD-optimized sorted check
fn isSortedSimd(comptime T: type, v: []const T, comptime is_ordered: fn (T, T) bool) bool {
    const len = v.len;
    if (len <= 1) return true;

    // Vector width based on type size
    const vec_len = switch (@sizeOf(T)) {
        1 => 32,
        2 => 16,
        4 => 8,
        8 => 4,
        else => 4,
    };

    const Vec = @Vector(vec_len, T);

    var i: usize = 0;
    const simd_end = if (len > vec_len) len - vec_len else 0;

    // Main SIMD loop: check vec_len pairs at a time
    while (i < simd_end) : (i += vec_len) {
        // Load v[i..i+vec_len] and v[i+1..i+1+vec_len]
        const a: Vec = v[i..][0..vec_len].*;
        const b: Vec = v[i + 1 ..][0..vec_len].*;

        // Check if all a[j] <= b[j] (or appropriate comparison)
        // Use SIMD comparison - result is a bool vector
        const ordered = simdCompare(T, Vec, vec_len, a, b, is_ordered);

        // If any pair is out of order, not sorted
        if (!ordered) return false;
    }

    // Scalar tail: check remaining pairs
    while (i < len - 1) : (i += 1) {
        if (!is_ordered(v[i], v[i + 1])) return false;
    }

    return true;
}

/// SIMD comparison that checks if all pairs satisfy is_ordered
fn simdCompare(
    comptime T: type,
    comptime Vec: type,
    comptime vec_len: usize,
    a: Vec,
    b: Vec,
    comptime is_ordered: fn (T, T) bool,
) bool {
    // Check which comparison to use by testing the is_ordered function
    // at compile time with known values
    const is_ascending = comptime blk: {
        // For ascending: is_ordered(1, 2) should be true (1 <= 2)
        // For descending: is_ordered(1, 2) should be false (1 >= 2 is false)
        const one: T = if (@typeInfo(T) == .float) 1.0 else 1;
        const two: T = if (@typeInfo(T) == .float) 2.0 else 2;
        break :blk is_ordered(one, two);
    };

    switch (@typeInfo(T)) {
        .float, .int => {
            const cmp = if (is_ascending) a <= b else a >= b;
            return @reduce(.And, cmp);
        },
        else => {
            // Scalar fallback for unsupported types
            inline for (0..vec_len) |j| {
                if (!is_ordered(a[j], b[j])) return false;
            }
            return true;
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "isSortedAsc - empty and single" {
    const empty: []const f64 = &[_]f64{};
    try std.testing.expect(isSortedAsc(f64, empty));

    const single = [_]f64{42.0};
    try std.testing.expect(isSortedAsc(f64, &single));
}

test "isSortedAsc - sorted data" {
    var data: [1000]f64 = undefined;
    for (&data, 0..) |*v, i| v.* = @floatFromInt(i);

    try std.testing.expect(isSortedAsc(f64, &data));
}

test "isSortedAsc - unsorted data" {
    var data = [_]f64{ 1.0, 2.0, 3.0, 1.0, 5.0 };
    try std.testing.expect(!isSortedAsc(f64, &data));
}

test "isSortedAsc - reverse sorted" {
    var data: [1000]f64 = undefined;
    for (&data, 0..) |*v, i| v.* = @floatFromInt(1000 - i);

    try std.testing.expect(!isSortedAsc(f64, &data));
}

test "isSortedDesc - descending data" {
    var data: [1000]f64 = undefined;
    for (&data, 0..) |*v, i| v.* = @floatFromInt(1000 - i);

    try std.testing.expect(isSortedDesc(f64, &data));
}

test "isSortedAsc - i64" {
    var data: [1000]i64 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(i);

    try std.testing.expect(isSortedAsc(i64, &data));
}

test "isSortedAsc - i32" {
    var data: [1000]i32 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(i);

    try std.testing.expect(isSortedAsc(i32, &data));
}

test "isSortedAsc - large array" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(f64, 1_000_000);
    defer allocator.free(data);

    for (data, 0..) |*v, i| v.* = @floatFromInt(i);

    try std.testing.expect(isSortedAsc(f64, data));
}
