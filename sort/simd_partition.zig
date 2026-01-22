//! SIMD-optimized Block Tracing for Partition
//!
//! Uses SIMD to compare multiple elements to pivot at once,
//! building offset arrays faster than scalar code for numeric types.
//!
//! Designed to integrate with BlockQuicksort partitioning.

const std = @import("std");

/// SIMD vector width for different element sizes
fn vectorLen(comptime T: type) usize {
    return switch (@sizeOf(T)) {
        1 => 32,
        2 => 16,
        4 => 8,
        8 => 4,
        else => 4,
    };
}

/// Check if type supports SIMD partitioning
pub fn canSimdPartition(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        .int => @sizeOf(T) <= 8,
        else => false,
    };
}

/// Trace left block using SIMD - find elements >= pivot (i.e., !is_less(elem, pivot))
/// Works on a block starting at data[0..block_len]
/// Returns number of offsets written (elements that need to move right)
///
/// For ascending sort: finds elements >= pivot
pub fn traceBlockLeftSimd(
    comptime T: type,
    data: []const T,
    block_len: usize,
    pivot: T,
    offsets: *[128]u8,
) usize {
    const vec_len = comptime vectorLen(T);
    const Vec = @Vector(vec_len, T);

    var end: usize = 0;
    var i: usize = 0;

    // Broadcast pivot to vector
    const pivot_vec: Vec = @splat(pivot);

    // SIMD loop - process vec_len elements at a time
    while (i + vec_len <= block_len) : (i += vec_len) {
        // Load vec_len elements
        const vals: Vec = data[i..][0..vec_len].*;

        // Compare: find elements >= pivot (NOT less than pivot)
        // For ascending sort with is_less = (a < b), we want !(elem < pivot) i.e., elem >= pivot
        const lt_mask = vals < pivot_vec;

        // Invert mask to get elements >= pivot
        const ge_mask = ~@as(std.meta.Int(.unsigned, vec_len), @bitCast(lt_mask));

        // For each bit set, store the offset
        var mask = ge_mask;
        while (mask != 0) {
            const bit_pos: u8 = @intCast(@ctz(mask));
            offsets[end] = @as(u8, @intCast(i)) + bit_pos;
            end += 1;
            mask &= mask - 1; // Clear lowest set bit
        }
    }

    // Scalar tail
    while (i < block_len) : (i += 1) {
        if (!(data[i] < pivot)) { // elem >= pivot
            offsets[end] = @intCast(i);
            end += 1;
        }
    }

    return end;
}

/// Trace right block using SIMD - find elements < pivot
/// Works on a block ending at data[data.len - block_len .. data.len]
/// Offsets are relative to the END: offset 0 = last element, offset 1 = second-to-last, etc.
/// Returns number of offsets written (elements that need to move left)
pub fn traceBlockRightSimd(
    comptime T: type,
    data: []const T,
    block_len: usize,
    pivot: T,
    offsets: *[128]u8,
) usize {
    const vec_len = comptime vectorLen(T);
    const Vec = @Vector(vec_len, T);

    const len = data.len;
    var end: usize = 0;
    var i: usize = 0;

    // Broadcast pivot to vector
    const pivot_vec: Vec = @splat(pivot);

    // Process from the end, comparing elements at data[len-1-i]
    // SIMD processes vec_len elements at a time
    while (i + vec_len <= block_len) : (i += vec_len) {
        // Load vec_len elements ending at position (len - 1 - i)
        // We want elements at indices: len-1-i, len-2-i, ..., len-vec_len-i
        // Load forward starting at len-vec_len-i
        const start_idx = len - vec_len - i;
        const vals: Vec = data[start_idx..][0..vec_len].*;

        // Compare: find elements < pivot
        const lt_mask = vals < pivot_vec;
        const mask_bits = @as(std.meta.Int(.unsigned, vec_len), @bitCast(lt_mask));

        // For each matching element, compute its reverse offset
        var mask = mask_bits;
        while (mask != 0) {
            const bit_pos: usize = @ctz(mask);
            // Element at data[start_idx + bit_pos] is < pivot
            // Its reverse offset (from end) is: (len - 1) - (start_idx + bit_pos)
            const rev_offset = (len - 1) - (start_idx + bit_pos);
            offsets[end] = @intCast(rev_offset);
            end += 1;
            mask &= mask - 1;
        }
    }

    // Scalar tail - process remaining elements from the end
    while (i < block_len) : (i += 1) {
        if (data[len - 1 - i] < pivot) {
            offsets[end] = @intCast(i);
            end += 1;
        }
    }

    return end;
}

// ============================================================================
// Tests
// ============================================================================

test "traceBlockLeftSimd - basic f64" {
    const data = [_]f64{ 1.0, 5.0, 2.0, 7.0, 3.0, 8.0, 4.0, 9.0 };
    var offsets: [128]u8 = undefined;

    const count = traceBlockLeftSimd(f64, &data, 8, 5.0, &offsets);

    // Elements >= 5.0: 5.0(1), 7.0(3), 8.0(5), 9.0(7) = 4 elements
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u8, 1), offsets[0]);
    try std.testing.expectEqual(@as(u8, 3), offsets[1]);
    try std.testing.expectEqual(@as(u8, 5), offsets[2]);
    try std.testing.expectEqual(@as(u8, 7), offsets[3]);
}

test "traceBlockLeftSimd - all less" {
    const data = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    var offsets: [128]u8 = undefined;

    const count = traceBlockLeftSimd(f64, &data, 4, 10.0, &offsets);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "traceBlockLeftSimd - all greater or equal" {
    const data = [_]f64{ 10.0, 20.0, 30.0, 40.0 };
    var offsets: [128]u8 = undefined;

    const count = traceBlockLeftSimd(f64, &data, 4, 5.0, &offsets);
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "traceBlockRightSimd - basic f64" {
    const data = [_]f64{ 1.0, 5.0, 2.0, 7.0, 3.0, 8.0, 4.0, 9.0 };
    var offsets: [128]u8 = undefined;

    const count = traceBlockRightSimd(f64, &data, 8, 5.0, &offsets);

    // Elements < 5.0: 1.0(0), 2.0(2), 3.0(4), 4.0(6) = 4 elements
    // From right: indices 0,2,4,6 -> reverse offsets 7,5,3,1
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "traceBlockLeftSimd - i32" {
    const data = [_]i32{ 1, 5, 2, 7, 3, 8, 4, 9 };
    var offsets: [128]u8 = undefined;

    const count = traceBlockLeftSimd(i32, &data, 8, 5, &offsets);

    // Elements >= 5: 5(1), 7(3), 8(5), 9(7) = 4 elements
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "traceBlockLeftSimd - partial block" {
    const data = [_]f64{ 1.0, 5.0, 2.0, 7.0, 3.0 };
    var offsets: [128]u8 = undefined;

    // Only trace first 3 elements
    const count = traceBlockLeftSimd(f64, &data, 3, 4.0, &offsets);

    // Elements >= 4.0 in first 3: 5.0(1) = 1 element
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u8, 1), offsets[0]);
}
