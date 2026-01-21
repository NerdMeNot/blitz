//! Parallel Sort Example
//!
//! Demonstrates parallel sorting using Blitz's PDQSort implementation.

const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    // Initialize Blitz
    try blitz.init();
    defer blitz.deinit();

    const allocator = std.heap.c_allocator;

    // Create random test data
    const n = 1_000_000;
    const data = try allocator.alloc(f64, n);
    defer allocator.free(data);

    const original = try allocator.alloc(f64, n);
    defer allocator.free(original);

    var rng = std.Random.DefaultPrng.init(12345);
    for (original) |*v| {
        v.* = rng.random().float(f64);
    }

    // Benchmark random data
    std.debug.print("Sorting {d} random elements:\n", .{n});

    @memcpy(data, original);
    var timer = std.time.Timer.start() catch unreachable;
    blitz.sortAsc(f64, data);
    const random_time = timer.read();

    std.debug.print("  Random:  {d:.2} ms\n", .{@as(f64, @floatFromInt(random_time)) / 1_000_000.0});

    // Verify sorted
    for (0..data.len - 1) |i| {
        if (data[i] > data[i + 1]) {
            std.debug.print("ERROR: Not sorted at index {d}\n", .{i});
            return error.NotSorted;
        }
    }

    // Benchmark already sorted data (pattern detection)
    timer = std.time.Timer.start() catch unreachable;
    blitz.sortAsc(f64, data); // data is already sorted
    const sorted_time = timer.read();

    std.debug.print("  Sorted:  {d:.2} ms (pattern detection)\n", .{@as(f64, @floatFromInt(sorted_time)) / 1_000_000.0});

    // Benchmark reverse sorted
    for (data, 0..) |*v, i| {
        v.* = @floatFromInt(n - i);
    }
    timer = std.time.Timer.start() catch unreachable;
    blitz.sortAsc(f64, data);
    const reverse_time = timer.read();

    std.debug.print("  Reverse: {d:.2} ms (pattern detection)\n", .{@as(f64, @floatFromInt(reverse_time)) / 1_000_000.0});

    // Custom comparator (descending)
    @memcpy(data, original);
    timer = std.time.Timer.start() catch unreachable;
    blitz.sortDesc(f64, data);
    const desc_time = timer.read();

    std.debug.print("  Desc:    {d:.2} ms\n", .{@as(f64, @floatFromInt(desc_time)) / 1_000_000.0});

    // Verify descending
    for (0..data.len - 1) |i| {
        if (data[i] < data[i + 1]) {
            std.debug.print("ERROR: Not sorted descending at index {d}\n", .{i});
            return error.NotSorted;
        }
    }

    std.debug.print("\nAll sorts completed successfully!\n", .{});
}
