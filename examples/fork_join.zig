//! Fork-Join Example
//!
//! Demonstrates parallel recursive computation using Blitz's fork-join.

const std = @import("std");
const blitz = @import("blitz");

/// Parallel Fibonacci using fork-join with unified join API
fn fib(n: u64) u64 {
    // Base case: sequential for small n
    if (n <= 20) return fibSeq(n);

    // Fork: compute fib(n-1) and fib(n-2) in parallel
    // The unified join API now supports runtime arguments!
    const r = blitz.join(.{
        .a = .{ fib, n - 1 },
        .b = .{ fib, n - 2 },
    });

    return r.a + r.b;
}

/// Sequential Fibonacci
fn fibSeq(n: u64) u64 {
    if (n <= 1) return n;
    var a: u64 = 0;
    var b: u64 = 1;
    for (0..n - 1) |_| {
        const tmp = a + b;
        a = b;
        b = tmp;
    }
    return b;
}

/// Parallel merge sort using fork-join with unified join API
fn mergeSort(data: []i32, temp: []i32) void {
    if (data.len <= 32) {
        // Base case: insertion sort
        insertionSort(data);
        return;
    }

    const mid = data.len / 2;

    // Fork: sort left and right halves in parallel
    // The unified join API supports runtime arguments and void returns!
    _ = blitz.join(.{
        .left = .{ mergeSort, data[0..mid], temp[0..mid] },
        .right = .{ mergeSort, data[mid..], temp[mid..] },
    });

    // Merge the sorted halves
    merge(data, temp, mid);
}

fn insertionSort(data: []i32) void {
    for (1..data.len) |i| {
        const key = data[i];
        var j: usize = i;
        while (j > 0 and data[j - 1] > key) : (j -= 1) {
            data[j] = data[j - 1];
        }
        data[j] = key;
    }
}

fn merge(data: []i32, temp: []i32, mid: usize) void {
    @memcpy(temp[0..data.len], data);

    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;

    while (i < mid and j < data.len) : (k += 1) {
        if (temp[i] <= temp[j]) {
            data[k] = temp[i];
            i += 1;
        } else {
            data[k] = temp[j];
            j += 1;
        }
    }

    while (i < mid) : ({
        i += 1;
        k += 1;
    }) {
        data[k] = temp[i];
    }
}

pub fn main() !void {
    // Initialize Blitz
    try blitz.init();
    defer blitz.deinit();

    const allocator = std.heap.c_allocator;

    // Example 1: Parallel Fibonacci
    std.debug.print("=== Parallel Fibonacci ===\n", .{});

    for ([_]u64{ 35, 40, 45 }) |n| {
        const start = std.time.nanoTimestamp();
        const result = fib(n);
        const elapsed = std.time.nanoTimestamp() - start;

        std.debug.print("fib({d}) = {d} in {d:.1} ms\n", .{
            n,
            result,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    }

    // Example 2: Parallel Merge Sort
    std.debug.print("\n=== Parallel Merge Sort ===\n", .{});

    const n = 1_000_000;
    const data = try allocator.alloc(i32, n);
    defer allocator.free(data);
    const temp = try allocator.alloc(i32, n);
    defer allocator.free(temp);

    // Initialize with random data
    var rng = std.Random.DefaultPrng.init(12345);
    for (data) |*v| {
        v.* = @bitCast(rng.random().int(u32));
    }

    const start = std.time.nanoTimestamp();
    mergeSort(data, temp);
    const elapsed = std.time.nanoTimestamp() - start;

    std.debug.print("Sorted {d} elements in {d:.1} ms\n", .{
        n,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    // Verify sorted
    for (0..data.len - 1) |i| {
        if (data[i] > data[i + 1]) {
            std.debug.print("ERROR: Not sorted at index {d}\n", .{i});
            return error.NotSorted;
        }
    }
    std.debug.print("Verification passed!\n", .{});
}
