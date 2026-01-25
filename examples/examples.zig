//! Blitz Examples - Core API
//!
//! Comprehensive examples demonstrating Blitz's parallel runtime capabilities.
//!
//! Run with: zig build-exe --dep blitz -Mroot=examples/examples.zig -Mblitz=api.zig -lc -O ReleaseFast
//!           ./examples
//!
//! Examples in this file:
//! 1. Basic initialization and parallel for
//! 2. Parallel reduction (sum, min, max)
//! 3. Fork-join with join()
//! 4. Recursive divide-and-conquer (parallel fibonacci)
//! 5. Parallel collect (map)
//! 6. Scope-based parallelism
//! 7. Real-world: Matrix multiplication
//!
//! See also:
//! - examples/iterators.zig  - Parallel iterator API (find, any/all, minBy, chunks)
//! - examples/sorting.zig    - Parallel PDQSort (sortByKey, sortByCachedKey)

const std = @import("std");
const blitz = @import("blitz");

const print = std.debug.print;

pub fn main() !void {
    print(
        \\
        \\======================================================================
        \\              BLITZ PARALLEL RUNTIME EXAMPLES
        \\======================================================================
        \\
        \\
    , .{});

    // Initialize Blitz (auto-detects CPU count)
    try blitz.init();
    defer blitz.deinit();

    print("Initialized with {} workers\n\n", .{blitz.numWorkers()});

    // Run all examples
    try example1_parallel_for();
    try example2_parallel_reduce();
    try example3_fork_join();
    try example4_parallel_fibonacci();
    try example5_parallel_collect();
    try example6_scope_parallelism();
    try example7_matrix_multiply();

    print(
        \\
        \\======================================================================
        \\                    ALL EXAMPLES COMPLETE
        \\======================================================================
        \\
    , .{});
}

// ============================================================================
// Example 1: Basic Parallel For
// ============================================================================

fn example1_parallel_for() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 1: Parallel For
        \\ Process array elements in parallel with automatic chunking
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 1_000_000;

    const data = try allocator.alloc(f64, n);
    defer allocator.free(data);

    // Initialize sequentially
    for (data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    // Transform in parallel: each element becomes its square root
    const Context = struct { data: []f64 };
    const start = std.time.nanoTimestamp();

    blitz.parallelFor(n, Context, .{ .data = data }, struct {
        fn body(ctx: Context, chunk_start: usize, chunk_end: usize) void {
            for (ctx.data[chunk_start..chunk_end]) |*v| {
                v.* = @sqrt(v.*);
            }
        }
    }.body);

    const elapsed_ns = std.time.nanoTimestamp() - start;

    print("  Computed sqrt of {} elements in {d:.2} ms\n", .{
        n,
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
    });
    print("  Sample: sqrt(999999) = {d:.4}\n\n", .{data[999999]});
}

// ============================================================================
// Example 2: Parallel Reduction
// ============================================================================

fn example2_parallel_reduce() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 2: Parallel Reduction
        \\ Sum with parallel map-reduce pattern
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 10_000_000;

    const data = try allocator.alloc(i64, n);
    defer allocator.free(data);

    // Initialize with values 0..n-1
    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    // Parallel sum using reduce
    const Context = struct { data: []const i64 };
    const start_sum = std.time.nanoTimestamp();

    const sum = blitz.parallelReduce(
        i64,
        n,
        0, // identity
        Context,
        .{ .data = data },
        struct {
            fn map(ctx: Context, i: usize) i64 {
                return ctx.data[i];
            }
        }.map,
        struct {
            fn combine(a: i64, b: i64) i64 {
                return a + b;
            }
        }.combine,
    );

    const elapsed_sum = std.time.nanoTimestamp() - start_sum;

    // Expected: n*(n-1)/2
    const expected: i64 = @intCast(n * (n - 1) / 2);

    print("  Sum of 0..{}: {} (expected: {})\n", .{ n - 1, sum, expected });
    print("  Time: {d:.2} ms\n", .{
        @as(f64, @floatFromInt(elapsed_sum)) / 1_000_000.0,
    });

    // Parallel max
    const start_max = std.time.nanoTimestamp();
    const max = blitz.parallelReduce(
        i64,
        n,
        std.math.minInt(i64),
        Context,
        .{ .data = data },
        struct {
            fn map(ctx: Context, i: usize) i64 {
                return ctx.data[i];
            }
        }.map,
        struct {
            fn combine(a: i64, b: i64) i64 {
                return @max(a, b);
            }
        }.combine,
    );
    const elapsed_max = std.time.nanoTimestamp() - start_max;

    print("  Max: {} (expected: {})\n", .{ max, n - 1 });
    print("  Time: {d:.2} ms\n\n", .{
        @as(f64, @floatFromInt(elapsed_max)) / 1_000_000.0,
    });
}

// ============================================================================
// Example 3: Fork-Join with join()
// ============================================================================

fn example3_fork_join() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 3: Fork-Join
        \\ Execute two tasks in parallel and collect both results
        \\----------------------------------------------------------------------
        \\
    , .{});

    const start = std.time.nanoTimestamp();

    // Fork two compute tasks using unified join API
    const results = blitz.join(.{
        .a = .{struct {
            fn compute(n: u32) u64 {
                var sum: u64 = 0;
                for (0..n) |i| {
                    sum += i * 2;
                }
                return sum;
            }
        }.compute, @as(u32, 1_000_000)},
        .b = .{struct {
            fn compute(n: u32) u64 {
                var sum: u64 = 0;
                for (0..n) |i| {
                    sum += i * 3;
                }
                return sum;
            }
        }.compute, @as(u32, 1_000_000)},
    });

    const elapsed_ns = std.time.nanoTimestamp() - start;

    print("  Task A result: {}\n", .{results.a});
    print("  Task B result: {}\n", .{results.b});
    print("  Total time: {d:.2} ms (ran in parallel!)\n\n", .{
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
    });
}

// ============================================================================
// Example 4: Recursive Parallel Fibonacci
// ============================================================================

fn example4_parallel_fibonacci() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 4: Parallel Fibonacci
        \\ Classic divide-and-conquer with work-stealing
        \\----------------------------------------------------------------------
        \\
    , .{});

    const n: u64 = 40;

    // Sequential for comparison
    const start_seq = std.time.nanoTimestamp();
    const seq_result = fibSeq(n);
    const elapsed_seq = std.time.nanoTimestamp() - start_seq;

    // Parallel
    const start_par = std.time.nanoTimestamp();
    const par_result = fibPar(n);
    const elapsed_par = std.time.nanoTimestamp() - start_par;

    const speedup = @as(f64, @floatFromInt(elapsed_seq)) / @as(f64, @floatFromInt(elapsed_par));

    print("  fib({}) = {}\n", .{ n, seq_result });
    print("  Sequential: {d:.1} ms\n", .{
        @as(f64, @floatFromInt(elapsed_seq)) / 1_000_000.0,
    });
    print("  Parallel:   {d:.1} ms\n", .{
        @as(f64, @floatFromInt(elapsed_par)) / 1_000_000.0,
    });
    print("  Speedup:    {d:.1}x\n", .{speedup});
    print("  Correct:    {}\n\n", .{seq_result == par_result});
}

fn fibSeq(n: u64) u64 {
    if (n <= 1) return n;
    return fibSeq(n - 1) + fibSeq(n - 2);
}

fn fibPar(n: u64) u64 {
    // Sequential threshold - don't parallelize small subproblems
    if (n <= 20) return fibSeq(n);

    // Fork fib(n-1) and fib(n-2) in parallel with unified join API
    const r = blitz.join(.{
        .a = .{ fibPar, n - 1 },
        .b = .{ fibPar, n - 2 },
    });

    return r.a + r.b;
}

// ============================================================================
// Example 5: Parallel Collect (Map)
// ============================================================================

fn example5_parallel_collect() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 5: Parallel Collect (Map)
        \\ Transform elements in parallel into new array
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const n: usize = 1_000_000;

    const input = try allocator.alloc(i32, n);
    defer allocator.free(input);
    const output = try allocator.alloc(i64, n);
    defer allocator.free(output);

    for (input, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    const start = std.time.nanoTimestamp();

    // Square each element
    blitz.parallelCollect(i32, i64, input, output, void, {}, struct {
        fn map(_: void, x: i32) i64 {
            return @as(i64, x) * @as(i64, x);
        }
    }.map);

    const elapsed = std.time.nanoTimestamp() - start;

    print("  Squared {} elements\n", .{n});
    print("  Sample: {}^2 = {}\n", .{ input[1000], output[1000] });
    print("  Time: {d:.2} ms\n\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
}

// ============================================================================
// Example 6: Scope-Based Parallelism (using parallelForWithGrain)
// ============================================================================

fn example6_scope_parallelism() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 6: Scope-Based Parallelism
        \\ Execute multiple independent tasks in parallel
        \\----------------------------------------------------------------------
        \\
    , .{});

    var result_a: u64 = 0;
    var result_b: u64 = 0;

    const Context = struct {
        result_a: *u64,
        result_b: *u64,
    };

    const start = std.time.nanoTimestamp();

    // Fork two independent tasks using parallelForWithGrain
    blitz.parallelForWithGrain(2, Context, Context{
        .result_a = &result_a,
        .result_b = &result_b,
    }, struct {
        fn body(ctx: Context, start_idx: usize, end_idx: usize) void {
            for (start_idx..end_idx) |i| {
                if (i == 0) {
                    // Task A: compute sum 0..1M
                    var sum: u64 = 0;
                    for (0..1_000_000) |j| sum += j;
                    ctx.result_a.* = sum;
                } else {
                    // Task B: compute 20!
                    var prod: u64 = 1;
                    for (1..21) |j| prod *= j;
                    ctx.result_b.* = prod;
                }
            }
        }
    }.body, 1);

    const elapsed = std.time.nanoTimestamp() - start;

    print("  Task A (sum 0..1M): {}\n", .{result_a});
    print("  Task B (20!): {}\n", .{result_b});
    print("  Time: {d:.2} ms\n\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
}

// ============================================================================
// Example 7: Real-World - Matrix Multiplication
// ============================================================================

fn example7_matrix_multiply() !void {
    print(
        \\----------------------------------------------------------------------
        \\ Example 7: Parallel Matrix Multiplication
        \\ Real-world compute-bound workload
        \\----------------------------------------------------------------------
        \\
    , .{});

    const allocator = std.heap.page_allocator;
    const N: usize = 512; // 512x512 matrices

    // Allocate matrices
    const A = try allocator.alloc(f64, N * N);
    defer allocator.free(A);
    const B = try allocator.alloc(f64, N * N);
    defer allocator.free(B);
    const C = try allocator.alloc(f64, N * N);
    defer allocator.free(C);

    // Initialize A and B
    for (0..N * N) |i| {
        A[i] = @floatFromInt(i % 100);
        B[i] = @floatFromInt((i * 7) % 100);
    }

    // Sequential matrix multiply for comparison
    @memset(C, 0);
    const start_seq = std.time.nanoTimestamp();
    matmulSeq(N, A, B, C);
    const elapsed_seq = std.time.nanoTimestamp() - start_seq;

    var checksum_seq: f64 = 0;
    for (C) |v| checksum_seq += v;

    // Parallel matrix multiply
    @memset(C, 0);
    const start_par = std.time.nanoTimestamp();
    matmulPar(N, A, B, C);
    const elapsed_par = std.time.nanoTimestamp() - start_par;

    var checksum_par: f64 = 0;
    for (C) |v| checksum_par += v;

    const speedup = @as(f64, @floatFromInt(elapsed_seq)) / @as(f64, @floatFromInt(elapsed_par));

    print("  Matrix size: {}x{}\n", .{ N, N });
    print("  Sequential: {d:.1} ms\n", .{
        @as(f64, @floatFromInt(elapsed_seq)) / 1_000_000.0,
    });
    print("  Parallel:   {d:.1} ms\n", .{
        @as(f64, @floatFromInt(elapsed_par)) / 1_000_000.0,
    });
    print("  Speedup:    {d:.1}x\n", .{speedup});
    print("  Checksums match: {}\n\n", .{@abs(checksum_seq - checksum_par) < 0.001});
}

fn matmulSeq(N: usize, A: []const f64, B: []const f64, C: []f64) void {
    for (0..N) |i| {
        for (0..N) |j| {
            var sum: f64 = 0;
            for (0..N) |k| {
                sum += A[i * N + k] * B[k * N + j];
            }
            C[i * N + j] = sum;
        }
    }
}

fn matmulPar(N: usize, A: []const f64, B: []const f64, C: []f64) void {
    const Context = struct {
        N: usize,
        A: []const f64,
        B: []const f64,
        C: []f64,
    };

    // Parallelize over rows
    blitz.parallelFor(N, Context, .{ .N = N, .A = A, .B = B, .C = C }, struct {
        fn body(ctx: Context, row_start: usize, row_end: usize) void {
            for (row_start..row_end) |i| {
                for (0..ctx.N) |j| {
                    var sum: f64 = 0;
                    for (0..ctx.N) |k| {
                        sum += ctx.A[i * ctx.N + k] * ctx.B[k * ctx.N + j];
                    }
                    ctx.C[i * ctx.N + j] = sum;
                }
            }
        }
    }.body);
}
