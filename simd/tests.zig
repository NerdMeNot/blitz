//! Tests for SIMD operations.

const std = @import("std");
const mod = @import("mod.zig");

test "simd sum" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const result = mod.sum(i64, &data);
    try std.testing.expectEqual(@as(i64, 55), result);
}

test "simd sum large" {
    var data: [1000]i64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i + 1);
    }
    const result = mod.sum(i64, &data);
    try std.testing.expectEqual(@as(i64, 500500), result);
}

test "simd min" {
    const data = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    const result = mod.min(i64, &data);
    try std.testing.expectEqual(@as(i64, 1), result.?);
}

test "simd max" {
    const data = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    const result = mod.max(i64, &data);
    try std.testing.expectEqual(@as(i64, 9), result.?);
}

test "simd empty" {
    const empty: []const i64 = &.{};
    try std.testing.expectEqual(@as(i64, 0), mod.sum(i64, empty));
    try std.testing.expectEqual(@as(?i64, null), mod.min(i64, empty));
    try std.testing.expectEqual(@as(?i64, null), mod.max(i64, empty));
}

test "simd argmin" {
    const data = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    const result = mod.argmin(i64, &data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 1), result.?.value);
    try std.testing.expectEqual(@as(usize, 3), result.?.index);
}

test "simd argmax" {
    const data = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    const result = mod.argmax(i64, &data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 9), result.?.value);
    try std.testing.expectEqual(@as(usize, 4), result.?.index);
}

test "simd argmin first occurrence" {
    const data = [_]i64{ 5, 1, 8, 1, 9, 1, 7, 4, 6 };
    const result = mod.argmin(i64, &data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 1), result.?.value);
    try std.testing.expectEqual(@as(usize, 1), result.?.index);
}

test "simd argmin large" {
    var data: [1000]i64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }
    data[500] = -1;

    const result = mod.argmin(i64, &data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, -1), result.?.value);
    try std.testing.expectEqual(@as(usize, 500), result.?.index);
}

test "simd findValue" {
    const data = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };
    try std.testing.expectEqual(@as(?usize, 3), mod.findValue(i64, &data, 1));
    try std.testing.expectEqual(@as(?usize, 4), mod.findValue(i64, &data, 9));
    try std.testing.expectEqual(@as(?usize, null), mod.findValue(i64, &data, 100));
}

test "simd anyGreaterThan" {
    const data = [_]i64{ 1, 2, 3, 4, 5 };
    try std.testing.expect(mod.anyGreaterThan(i64, &data, 4));
    try std.testing.expect(!mod.anyGreaterThan(i64, &data, 5));
}

test "simd allLessThan" {
    const data = [_]i64{ 1, 2, 3, 4, 5 };
    try std.testing.expect(mod.allLessThan(i64, &data, 6));
    try std.testing.expect(!mod.allLessThan(i64, &data, 5));
}

// ============================================================================
// Float tests
// ============================================================================

test "simd sum f64" {
    const data = [_]f64{ 1.5, 2.5, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };
    const result = mod.sum(f64, &data);
    try std.testing.expectApproxEqAbs(@as(f64, 56.0), result, 0.0001);
}

test "simd sum f64 large" {
    var data: [1000]f64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @floatFromInt(i + 1);
    }
    const result = mod.sum(f64, &data);
    try std.testing.expectApproxEqAbs(@as(f64, 500500.0), result, 0.0001);
}

test "simd min f64" {
    const data = [_]f64{ 5.5, 2.2, 8.8, 1.1, 9.9, 3.3, 7.7, 4.4, 6.6 };
    const result = mod.min(f64, &data);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), result.?, 0.0001);
}

test "simd min f64 large" {
    var data: [1000]f64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @floatFromInt(i + 100);
    }
    data[500] = -42.5;
    const result = mod.min(f64, &data);
    try std.testing.expectApproxEqAbs(@as(f64, -42.5), result.?, 0.0001);
}

test "simd max f64" {
    const data = [_]f64{ 5.5, 2.2, 8.8, 1.1, 9.9, 3.3, 7.7, 4.4, 6.6 };
    const result = mod.max(f64, &data);
    try std.testing.expectApproxEqAbs(@as(f64, 9.9), result.?, 0.0001);
}

test "simd max f64 large" {
    var data: [1000]f64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }
    data[500] = 99999.5;
    const result = mod.max(f64, &data);
    try std.testing.expectApproxEqAbs(@as(f64, 99999.5), result.?, 0.0001);
}

test "simd empty f64" {
    const empty: []const f64 = &.{};
    try std.testing.expectApproxEqAbs(@as(f64, 0), mod.sum(f64, empty), 0.0001);
    try std.testing.expectEqual(@as(?f64, null), mod.min(f64, empty));
    try std.testing.expectEqual(@as(?f64, null), mod.max(f64, empty));
}

test "simd argmin f64" {
    const data = [_]f64{ 5.5, 2.2, 8.8, 1.1, 9.9, 3.3, 7.7, 4.4, 6.6 };
    const result = mod.argmin(f64, &data);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), result.?.value, 0.0001);
    try std.testing.expectEqual(@as(usize, 3), result.?.index);
}

test "simd argmax f64" {
    const data = [_]f64{ 5.5, 2.2, 8.8, 1.1, 9.9, 3.3, 7.7, 4.4, 6.6 };
    const result = mod.argmax(f64, &data);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 9.9), result.?.value, 0.0001);
    try std.testing.expectEqual(@as(usize, 4), result.?.index);
}

test "simd f32 min max" {
    const data = [_]f32{ 5.5, 2.2, 8.8, 1.1, 9.9, 3.3, 7.7, 4.4, 6.6 };
    const min_result = mod.min(f32, &data);
    const max_result = mod.max(f32, &data);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), min_result.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.9), max_result.?, 0.0001);
}
