//! Parallel Sum Example
//!
//! Demonstrates parallel reduction using Blitz iterators.

const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    // Initialize Blitz with default thread count
    try blitz.init();
    defer blitz.deinit();

    const allocator = std.heap.c_allocator;

    // Create test data
    const n = 10_000_000;
    const data = try allocator.alloc(f64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @floatFromInt(i + 1);
    }

    // Sequential sum for verification
    var seq_sum: f64 = 0;
    const seq_start = std.time.nanoTimestamp();
    for (data) |v| {
        seq_sum += v;
    }
    const seq_time = std.time.nanoTimestamp() - seq_start;

    // Parallel sum using Blitz iterator
    const par_start = std.time.nanoTimestamp();
    const par_sum = blitz.iter_mod.iter(f64, data).sum();
    const par_time = std.time.nanoTimestamp() - par_start;

    // Results
    std.debug.print("Sum of 1 to {d}:\n", .{n});
    std.debug.print("  Sequential: {d:.0} in {d:.2} ms\n", .{
        seq_sum,
        @as(f64, @floatFromInt(seq_time)) / 1_000_000.0,
    });
    std.debug.print("  Parallel:   {d:.0} in {d:.2} ms\n", .{
        par_sum,
        @as(f64, @floatFromInt(par_time)) / 1_000_000.0,
    });
    std.debug.print("  Speedup:    {d:.1}x\n", .{
        @as(f64, @floatFromInt(seq_time)) / @as(f64, @floatFromInt(par_time)),
    });

    // Verify correctness
    const expected = @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(n + 1)) / 2.0;
    if (@abs(par_sum - expected) > 1.0) {
        std.debug.print("ERROR: Expected {d}, got {d}\n", .{ expected, par_sum });
        return error.IncorrectResult;
    }
}
