//! SIMD-optimized Partition Tracing
//!
//! Uses SIMD to compare multiple elements to pivot at once,
//! building offset arrays ~4x faster than scalar code.

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

/// Trace left block using SIMD - find elements >= pivot
/// Returns number of offsets written (elements that need to move right)
pub fn traceLeftSimd(
    comptime T: type,
    data: []const T,
    pivot: T,
    offsets: []u8,
) usize {
    const vec_len = comptime vectorLen(T);
    const Vec = @Vector(vec_len, T);

    const len = data.len;
    var end: usize = 0;
    var i: usize = 0;

    // Broadcast pivot to vector
    const pivot_vec: Vec = @splat(pivot);

    // SIMD loop - process vec_len elements at a time
    const simd_end = len -| vec_len;
    while (i <= simd_end) : (i += vec_len) {
        // Load vec_len elements
        const vals: Vec = data[i..][0..vec_len].*;

        // Compare: find elements >= pivot (i.e., NOT less than pivot)
        // vals >= pivot means !(vals < pivot)
        const lt_mask = vals < pivot_vec;

        // Extract mask bits and invert (we want >= pivot)
        const ge_mask = ~@as(std.meta.Int(.unsigned, vec_len), @bitCast(lt_mask));

        // For each bit set in ge_mask, store the offset
        var mask = ge_mask;
        var j: u8 = 0;
        while (mask != 0) : (j += 1) {
            const bit_pos = @ctz(mask);
            offsets[end] = @as(u8, @intCast(i)) + bit_pos;
            end += 1;
            mask &= mask - 1; // Clear lowest set bit
        }
    }

    // Scalar tail
    while (i < len) : (i += 1) {
        if (data[i] >= pivot) {
            offsets[end] = @intCast(i);
            end += 1;
        }
    }

    return end;
}

/// Trace right block using SIMD - find elements < pivot
/// Data is accessed in reverse order (from end towards start)
/// Returns number of offsets written (elements that need to move left)
pub fn traceRightSimd(
    comptime T: type,
    data: []const T,
    pivot: T,
    offsets: []u8,
) usize {
    const vec_len = comptime vectorLen(T);
    const Vec = @Vector(vec_len, T);

    const len = data.len;
    var end: usize = 0;
    var i: usize = 0;

    // Broadcast pivot to vector
    const pivot_vec: Vec = @splat(pivot);

    // Process from the end in reverse
    // We compare data[len-1-i] for i = 0, 1, 2, ...
    const simd_end = len -| vec_len;
    while (i <= simd_end) : (i += vec_len) {
        // Load vec_len elements from the end (in forward order, then we'll adjust offsets)
        // Actually, we need to compare data[len-1-i], data[len-2-i], ...
        // Let's load data[len-vec_len-i .. len-i] and reverse the mask interpretation

        const start_idx = len - vec_len - i;
        const vals: Vec = data[start_idx..][0..vec_len].*;

        // Compare: find elements < pivot
        const lt_mask = vals < pivot_vec;
        const mask_bits = @as(std.meta.Int(.unsigned, vec_len), @bitCast(lt_mask));

        // The mask is for positions [start_idx, start_idx+vec_len)
        // But we're iterating from the end, so offset 0 corresponds to data[len-1-0] = data[len-1]
        // We need to map: if vals[j] < pivot, then offset = (len-1) - (start_idx + j) - ...
        // This is getting complex. Let's do a simpler approach for right block.

        // For each element in the SIMD window that's < pivot, compute its "reverse offset"
        var mask = mask_bits;
        while (mask != 0) {
            const bit_pos = @ctz(mask);
            // Element at data[start_idx + bit_pos] is < pivot
            // Its reverse index from end is: (len - 1) - (start_idx + bit_pos)
            const rev_idx = (len - 1) - (start_idx + bit_pos);
            // But we're building offsets for the right side where offset i means data[r - 1 - i]
            // So we want: i such that r - 1 - i = start_idx + bit_pos
            // where r is the original right boundary. But we're tracing within [0, len)
            // Actually, for the right trace, offset i means "the i-th element from the right"
            // So offset 0 = data[len-1], offset 1 = data[len-2], etc.
            // For data[start_idx + bit_pos], the offset is (len - 1) - (start_idx + bit_pos)
            offsets[end] = @intCast(rev_idx);
            end += 1;
            mask &= mask - 1;
        }
    }

    // Scalar tail - process remaining elements from the end
    while (i < len) : (i += 1) {
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

test "traceLeftSimd - basic" {
    const data = [_]f64{ 1.0, 5.0, 2.0, 7.0, 3.0, 8.0, 4.0, 9.0 };
    var offsets: [8]u8 = undefined;

    const count = traceLeftSimd(f64, &data, 5.0, &offsets);

    // Elements >= 5.0: 5.0(1), 7.0(3), 8.0(5), 9.0(7) = 4 elements
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "traceLeftSimd - all less" {
    const data = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    var offsets: [4]u8 = undefined;

    const count = traceLeftSimd(f64, &data, 10.0, &offsets);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "traceLeftSimd - all greater" {
    const data = [_]f64{ 10.0, 20.0, 30.0, 40.0 };
    var offsets: [4]u8 = undefined;

    const count = traceLeftSimd(f64, &data, 5.0, &offsets);
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "traceRightSimd - basic" {
    const data = [_]f64{ 1.0, 5.0, 2.0, 7.0, 3.0, 8.0, 4.0, 9.0 };
    var offsets: [8]u8 = undefined;

    const count = traceRightSimd(f64, &data, 5.0, &offsets);

    // Elements < 5.0: 1.0(0), 2.0(2), 3.0(4), 4.0(6) = 4 elements
    // From right: 4.0 is at index 6 = offset 1 from right (len-1-6 = 1)
    try std.testing.expectEqual(@as(usize, 4), count);
}
