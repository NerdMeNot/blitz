//! Blitz vs Rayon Comparison Benchmarks
//!
//! Outputs JSON for easy comparison with Rayon benchmarks.
//!
//! Build: zig build-exe -O ReleaseFast benchmarks/rayon_compare.zig --dep blitz -Mblitz=api.zig -lc
//! Run:   ./rayon_compare

const std = @import("std");
const blitz = @import("blitz");
const posix = std.posix;

// ============================================================================
// Configuration
// ============================================================================

const NUM_WORKERS = 10;
const WARMUP_ITERATIONS = 5;
const BENCHMARK_ITERATIONS = 10;

// ============================================================================
// JSON Output
// ============================================================================

const JsonWriter = struct {
    first: bool = true,

    fn begin(self: *JsonWriter) void {
        _ = self;
        std.debug.print("{{\n", .{});
    }

    fn end(self: *JsonWriter) void {
        _ = self;
        std.debug.print("\n}}\n", .{});
    }

    fn key(self: *JsonWriter, name: []const u8) void {
        if (!self.first) {
            std.debug.print(",\n", .{});
        }
        self.first = false;
        std.debug.print("  \"{s}\": ", .{name});
    }

    fn value(self: *JsonWriter, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(fmt, args);
    }
};

// ============================================================================
// Resource Usage
// ============================================================================

const ResourceUsage = struct {
    peak_memory_kb: i64,
    voluntary_ctx_switches: i64,
    involuntary_ctx_switches: i64,
};

fn getResourceUsage() ResourceUsage {
    const RUSAGE_SELF: i32 = 0;
    const ru = posix.getrusage(RUSAGE_SELF);
    return .{
        .peak_memory_kb = @divTrunc(ru.maxrss, 1024), // Convert to KB (macOS reports bytes)
        .voluntary_ctx_switches = ru.nvcsw,
        .involuntary_ctx_switches = ru.nivcsw,
    };
}

// ============================================================================
// Benchmark Utilities
// ============================================================================

fn benchmark(comptime func: anytype, args: anytype) u64 {
    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        const r = @call(.never_inline, func, args);
        std.mem.doNotOptimizeAway(r);
    }

    // Measure
    var total: u64 = 0;
    for (0..BENCHMARK_ITERATIONS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        const r = @call(.never_inline, func, args);
        total += timer.read();
        std.mem.doNotOptimizeAway(r);
    }

    return total / BENCHMARK_ITERATIONS;
}

// ============================================================================
// Benchmark 1: Fork-Join Overhead
// ============================================================================

fn recursiveJoin(depth: usize) usize {
    if (depth == 0) return 1;

    // Unified join API supports runtime arguments
    const r = blitz.join(.{
        .a = .{ recursiveJoin, depth - 1 },
        .b = .{ recursiveJoin, depth - 1 },
    });

    return r.a + r.b;
}

// ============================================================================
// Benchmark 2: Parallel Fibonacci
// ============================================================================

fn fibSeqInner(n: u64) u64 {
    if (n <= 1) return n;
    return fibSeqInner(n - 1) + fibSeqInner(n - 2);
}

var fib_volatile: u64 = 0;

fn fibSeq(n: u64) u64 {
    const result = fibSeqInner(n);
    @as(*volatile u64, @ptrCast(&fib_volatile)).* = result;
    return result;
}

fn fibPar(n: u64) u64 {
    if (n <= 20) return fibSeq(n);

    // Unified join API supports runtime arguments
    const r = blitz.join(.{
        .a = .{ fibPar, n - 2 },
        .b = .{ fibPar, n - 1 },
    });

    return r.a + r.b;
}

// ============================================================================
// Benchmark 3: Parallel Sum
// ============================================================================

var sum_data: []f64 = undefined;

// Use iter-based sum (parallel reduction, like Rayon's par_iter().sum())
fn sumParallel() f64 {
    return blitz.iter_mod.iter(f64, sum_data).sum();
}

fn sumSequential() f64 {
    var s: f64 = 0;
    for (sum_data) |v| s += v;
    return s;
}

// ============================================================================
// Benchmark 4: PDQSort
// ============================================================================

var sort_data: []f64 = undefined;
var sort_original: []f64 = undefined;

fn sortBench() void {
    @memcpy(sort_data, sort_original);
    blitz.sortAsc(f64, sort_data);
}

// ============================================================================
// Benchmark 5: Find Operations
// ============================================================================

var find_data: []i64 = undefined;

fn findEarly() bool {
    return blitz.iter_mod.iter(i64, find_data).findAny(struct {
        fn pred(x: i64) bool {
            return x == 100;
        }
    }.pred) != null;
}

fn findLate() bool {
    const target: i64 = @intCast(find_data.len - 100);
    // Can't capture runtime value in comptime pred, use position instead
    for (find_data) |x| {
        if (x == target) return true;
    }
    return false;
}

// ============================================================================
// Benchmark 6: Any/All
// ============================================================================

fn anyEarly() bool {
    return blitz.iter_mod.iter(i64, find_data).any(struct {
        fn pred(x: i64) bool {
            return x > 100;
        }
    }.pred);
}

fn anyFullScan() bool {
    return blitz.iter_mod.iter(i64, find_data).any(struct {
        fn pred(x: i64) bool {
            return x > 99999999;
        }
    }.pred);
}

fn allPass() bool {
    return blitz.iter_mod.iter(i64, find_data).all(struct {
        fn pred(x: i64) bool {
            return x < 99999999;
        }
    }.pred);
}

// ============================================================================
// Benchmark 7: Chunks
// ============================================================================

fn chunksSum1000() i64 {
    return blitz.iter_mod.iter(i64, find_data).chunks_iter(1000).reduce(i64, 0, struct {
        fn sumChunk(chunk: []const i64) i64 {
            var s: i64 = 0;
            for (chunk) |v| s += v;
            return s;
        }
    }.sumChunk, struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;
        }
    }.combine);
}

// ============================================================================
// Benchmark 8: Min/Max by Key
// ============================================================================

fn minByKey() ?i64 {
    return blitz.iter_mod.iter(i64, find_data).minByKey(i64, struct {
        fn key(x: i64) i64 {
            // Key that makes values near middle smaller
            const mid: i64 = 5_000_000;
            const diff = x - mid;
            return if (diff < 0) -diff else diff;
        }
    }.key);
}

fn maxByKey() ?i64 {
    return blitz.iter_mod.iter(i64, find_data).maxByKey(i64, struct {
        fn key(x: i64) i64 {
            return x;
        }
    }.key);
}

// ============================================================================
// Benchmark 9: Position (using positionAny for fair comparison with Rayon)
// ============================================================================

fn positionAnyEarly() ?usize {
    return blitz.iter_mod.iter(i64, find_data).positionAny(struct {
        fn pred(x: i64) bool {
            return x == 100;
        }
    }.pred);
}

fn positionAnyMid() ?usize {
    return blitz.iter_mod.iter(i64, find_data).positionAny(struct {
        fn pred(x: i64) bool {
            return x == 5_000_000;
        }
    }.pred);
}

// ============================================================================
// Benchmark 10: Enumerate
// ============================================================================

var enumerate_sum: i64 = 0;

fn enumerateSum() void {
    enumerate_sum = 0;
    blitz.iter_mod.iter(i64, find_data).enumerate_iter().forEach(struct {
        fn body(idx: usize, val: i64) void {
            _ = idx;
            _ = val;
            // Just iterate - measuring overhead
        }
    }.body);
}

// ============================================================================
// Benchmark 11: Chain
// ============================================================================

var chain_data1: []i64 = undefined;
var chain_data2: []i64 = undefined;

fn chainSum() i64 {
    return blitz.iter_mod.chain(i64, chain_data1, chain_data2).reduce(0, struct {
        fn add(a: i64, b: i64) i64 {
            return a + b;
        }
    }.add);
}

// ============================================================================
// Benchmark 12: Zip
// ============================================================================

fn zipDotProduct() i64 {
    return blitz.iter_mod.zip(i64, i64, chain_data1, chain_data2).mapReduce(
        i64,
        0,
        struct {
            fn mul(a: i64, b: i64) i64 {
                return a * b;
            }
        }.mul,
        struct {
            fn add(a: i64, b: i64) i64 {
                return a + b;
            }
        }.add,
    );
}

// ============================================================================
// Benchmark 13: Flatten + Sum (like Rayon's flatten().sum())
// ============================================================================

var flatten_chunks: [][]const i64 = undefined;

fn flattenSumBench() i64 {
    // Use FlattenIter to iterate over nested slices and sum
    return blitz.iter_mod.flatten(i64, flatten_chunks).sum();
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    // Use c_allocator for better performance (matches Rust's allocator)
    const allocator = std.heap.c_allocator;

    // Initialize Blitz
    try blitz.initWithConfig(.{ .background_worker_count = NUM_WORKERS });
    defer blitz.deinit();

    // System warmup - exercise thread pool before benchmarks
    // This ensures all worker threads are spawned and caches are hot
    {
        // Warmup with fork-join to spawn all threads
        for (0..10) |_| {
            _ = recursiveJoin(15);
        }
        // Warmup with parallel sum
        const warmup_data = try allocator.alloc(f64, 1_000_000);
        defer allocator.free(warmup_data);
        for (warmup_data, 0..) |*v, i| v.* = @floatFromInt(i);
        for (0..5) |_| {
            const sum = blitz.simd_mod.parallelSum(f64, warmup_data);
            std.mem.doNotOptimizeAway(sum);
        }
    }

    var json = JsonWriter{};
    json.begin();

    // Fork-Join Overhead
    {
        json.key("fork_join_depth_10");
        const ns = benchmark(recursiveJoin, .{@as(usize, 10)});
        const num_forks: u64 = (1 << 11) - 1;
        json.value("{d:.2}", .{@as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(num_forks))});

        json.key("fork_join_depth_15");
        const ns15 = benchmark(recursiveJoin, .{@as(usize, 15)});
        const num_forks15: u64 = (1 << 16) - 1;
        json.value("{d:.2}", .{@as(f64, @floatFromInt(ns15)) / @as(f64, @floatFromInt(num_forks15))});

        json.key("fork_join_depth_20");
        const ns20 = benchmark(recursiveJoin, .{@as(usize, 20)});
        const num_forks20: u64 = (1 << 21) - 1;
        json.value("{d:.2}", .{@as(f64, @floatFromInt(ns20)) / @as(f64, @floatFromInt(num_forks20))});
    }

    // Fibonacci
    {
        json.key("fib_35_par_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(fibPar, .{@as(u64, 35)}))) / 1_000_000.0});

        json.key("fib_35_seq_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(fibSeq, .{@as(u64, 35)}))) / 1_000_000.0});

        json.key("fib_40_par_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(fibPar, .{@as(u64, 40)}))) / 1_000_000.0});

        json.key("fib_40_seq_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(fibSeq, .{@as(u64, 40)}))) / 1_000_000.0});
    }

    // Parallel Sum
    {
        sum_data = try allocator.alloc(f64, 10_000_000);
        defer allocator.free(sum_data);
        for (sum_data, 0..) |*v, i| v.* = @floatFromInt(i % 1000);

        json.key("sum_10m_par_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(sumParallel, .{}))) / 1_000_000.0});

        json.key("sum_10m_seq_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(sumSequential, .{}))) / 1_000_000.0});
    }

    // PDQSort
    {
        sort_original = try allocator.alloc(f64, 1_000_000);
        defer allocator.free(sort_original);
        sort_data = try allocator.alloc(f64, 1_000_000);
        defer allocator.free(sort_data);

        var rng = std.Random.DefaultPrng.init(12345);
        for (sort_original) |*v| v.* = rng.random().float(f64);

        json.key("sort_1m_random_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(sortBench, .{}))) / 1_000_000.0});

        // Sorted
        for (sort_original, 0..) |*v, i| v.* = @floatFromInt(i);
        json.key("sort_1m_sorted_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(sortBench, .{}))) / 1_000_000.0});

        // Reverse
        for (sort_original, 0..) |*v, i| v.* = @floatFromInt(1_000_000 - i);
        json.key("sort_1m_reverse_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(sortBench, .{}))) / 1_000_000.0});

        // Equal
        for (sort_original) |*v| v.* = 42.0;
        json.key("sort_1m_equal_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(sortBench, .{}))) / 1_000_000.0});
    }

    // Find/Any/All
    {
        find_data = try allocator.alloc(i64, 10_000_000);
        defer allocator.free(find_data);
        for (find_data, 0..) |*v, i| v.* = @intCast(i);

        json.key("find_10m_early_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(findEarly, .{}))) / 1000.0});

        json.key("any_10m_early_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(anyEarly, .{}))) / 1000.0});

        json.key("any_10m_full_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(anyFullScan, .{}))) / 1000.0});

        json.key("all_10m_pass_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(allPass, .{}))) / 1000.0});

        json.key("chunks_10m_1000_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(chunksSum1000, .{}))) / 1_000_000.0});

        // Min/Max by Key
        json.key("min_by_key_10m_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(minByKey, .{}))) / 1000.0});

        json.key("max_by_key_10m_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(maxByKey, .{}))) / 1000.0});

        // Position (using positionAny for fair comparison with Rayon's position_any)
        json.key("position_10m_early_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(positionAnyEarly, .{}))) / 1000.0});

        json.key("position_10m_mid_us");
        json.value("{d:.1}", .{@as(f64, @floatFromInt(benchmark(positionAnyMid, .{}))) / 1000.0});

        // Enumerate
        json.key("enumerate_10m_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(enumerateSum, .{}))) / 1_000_000.0});
    }

    // Chain/Zip/Flatten
    {
        chain_data1 = try allocator.alloc(i64, 5_000_000);
        defer allocator.free(chain_data1);
        chain_data2 = try allocator.alloc(i64, 5_000_000);
        defer allocator.free(chain_data2);

        for (chain_data1, 0..) |*v, i| v.* = @intCast(i);
        for (chain_data2, 0..) |*v, i| v.* = @intCast(i);

        json.key("chain_2x5m_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(chainSum, .{}))) / 1_000_000.0});

        json.key("zip_10m_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(zipDotProduct, .{}))) / 1_000_000.0});

        // Flatten + Sum: 1000 chunks of 10000 elements each
        const num_chunks: usize = 1000;
        const chunk_size: usize = 10_000;
        const chunks_storage = try allocator.alloc([]const i64, num_chunks);
        defer allocator.free(chunks_storage);

        const flat_data = try allocator.alloc(i64, num_chunks * chunk_size);
        defer allocator.free(flat_data);
        for (flat_data, 0..) |*v, i| v.* = @intCast(i);

        for (chunks_storage, 0..) |*chunk, i| {
            chunk.* = flat_data[i * chunk_size .. (i + 1) * chunk_size];
        }
        flatten_chunks = chunks_storage;

        json.key("flatten_1000x10k_ms");
        json.value("{d:.2}", .{@as(f64, @floatFromInt(benchmark(flattenSumBench, .{}))) / 1_000_000.0});
    }

    // Resource usage
    {
        const ru = getResourceUsage();
        json.key("peak_memory_kb");
        json.value("{d}", .{ru.peak_memory_kb});
        json.key("voluntary_ctx_switches");
        json.value("{d}", .{ru.voluntary_ctx_switches});
        json.key("involuntary_ctx_switches");
        json.value("{d}", .{ru.involuntary_ctx_switches});
    }

    json.end();
}
