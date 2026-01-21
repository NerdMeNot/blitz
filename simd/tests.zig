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
