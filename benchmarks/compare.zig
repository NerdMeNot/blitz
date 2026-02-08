//! Blitz vs Rayon Comparative Benchmark
//!
//! Builds and runs both Blitz (Zig) and Rayon (Rust) benchmarks,
//! then displays a formatted comparison table.
//!
//! Usage: zig build compare

const std = @import("std");

// ============================================================================
// ANSI Colors
// ============================================================================

const Color = struct {
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const cyan = "\x1b[0;36m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";
};

// ============================================================================
// JSON Parsing
// ============================================================================

const BenchmarkResults = struct {
    // Fork-join overhead (ns/fork)
    fork_join_depth_10: f64 = 0,
    fork_join_depth_15: f64 = 0,
    fork_join_depth_20: f64 = 0,
    // Fibonacci (ms)
    fib_35_par_ms: f64 = 0,
    fib_35_seq_ms: f64 = 0,
    fib_40_par_ms: f64 = 0,
    fib_40_seq_ms: f64 = 0,
    // Parallel sum (ms)
    sum_10m_par_ms: f64 = 0,
    sum_10m_seq_ms: f64 = 0,
    // PDQSort (ms)
    sort_1m_random_ms: f64 = 0,
    sort_1m_sorted_ms: f64 = 0,
    sort_1m_reverse_ms: f64 = 0,
    sort_1m_equal_ms: f64 = 0,
    // Find (us)
    find_10m_early_us: f64 = 0,
    // Any/All (us)
    any_10m_early_us: f64 = 0,
    any_10m_full_us: f64 = 0,
    all_10m_pass_us: f64 = 0,
    // Chunks (ms)
    chunks_10m_1000_ms: f64 = 0,
    // Min/Max by key (us)
    min_by_key_10m_us: f64 = 0,
    max_by_key_10m_us: f64 = 0,
    // Position (us)
    position_10m_early_us: f64 = 0,
    position_10m_mid_us: f64 = 0,
    // Enumerate (ms)
    enumerate_10m_ms: f64 = 0,
    // Chain/Zip/Flatten (ms)
    chain_2x5m_ms: f64 = 0,
    zip_10m_ms: f64 = 0,
    flatten_1000x10k_ms: f64 = 0,
    // Resource usage
    peak_memory_kb: f64 = 0,
    voluntary_ctx_switches: f64 = 0,
    involuntary_ctx_switches: f64 = 0,
};

fn parseJsonResults(json_str: []const u8) BenchmarkResults {
    var results = BenchmarkResults{};

    var lines = std.mem.splitScalar(u8, json_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '{' or trimmed[0] == '}') continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
            const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t\"");
            const value_str = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t,");

            if (std.mem.eql(u8, key, "fork_join_depth_10")) {
                results.fork_join_depth_10 = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "fork_join_depth_15")) {
                results.fork_join_depth_15 = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "fork_join_depth_20")) {
                results.fork_join_depth_20 = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "fib_35_par_ms")) {
                results.fib_35_par_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "fib_35_seq_ms")) {
                results.fib_35_seq_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "fib_40_par_ms")) {
                results.fib_40_par_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "fib_40_seq_ms")) {
                results.fib_40_seq_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "sum_10m_par_ms")) {
                results.sum_10m_par_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "sum_10m_seq_ms")) {
                results.sum_10m_seq_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "sort_1m_random_ms")) {
                results.sort_1m_random_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "sort_1m_sorted_ms")) {
                results.sort_1m_sorted_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "sort_1m_reverse_ms")) {
                results.sort_1m_reverse_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "sort_1m_equal_ms")) {
                results.sort_1m_equal_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "find_10m_early_us")) {
                results.find_10m_early_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "any_10m_early_us")) {
                results.any_10m_early_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "any_10m_full_us")) {
                results.any_10m_full_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "all_10m_pass_us")) {
                results.all_10m_pass_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "chunks_10m_1000_ms")) {
                results.chunks_10m_1000_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "min_by_key_10m_us")) {
                results.min_by_key_10m_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "max_by_key_10m_us")) {
                results.max_by_key_10m_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "position_10m_early_us")) {
                results.position_10m_early_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "position_10m_mid_us")) {
                results.position_10m_mid_us = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "enumerate_10m_ms")) {
                results.enumerate_10m_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "chain_2x5m_ms")) {
                results.chain_2x5m_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "zip_10m_ms")) {
                results.zip_10m_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "flatten_1000x10k_ms")) {
                results.flatten_1000x10k_ms = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "peak_memory_kb")) {
                results.peak_memory_kb = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "voluntary_ctx_switches")) {
                results.voluntary_ctx_switches = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "involuntary_ctx_switches")) {
                results.involuntary_ctx_switches = std.fmt.parseFloat(f64, value_str) catch 0;
            }
        }
    }

    return results;
}

// ============================================================================
// Table Drawing
// ============================================================================

const TableWriter = struct {
    const w1 = 24; // Benchmark name
    const w2 = 14; // Blitz
    const w3 = 14; // Rayon
    const w4 = 16; // Difference

    fn printHeader(title: []const u8) void {
        std.debug.print("\n{s}{s}{s}\n", .{ Color.bold, title, Color.reset });
    }

    fn printTopBorder() void {
        std.debug.print("{s}", .{"\u{250C}"});
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w4 + 2);
        std.debug.print("{s}\n", .{"\u{2510}"});
    }

    fn printMidBorder() void {
        std.debug.print("{s}", .{"\u{251C}"});
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w4 + 2);
        std.debug.print("{s}\n", .{"\u{2524}"});
    }

    fn printBottomBorder() void {
        std.debug.print("{s}", .{"\u{2514}"});
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w4 + 2);
        std.debug.print("{s}\n", .{"\u{2518}"});
    }

    fn printDash(count: usize) void {
        for (0..count) |_| {
            std.debug.print("{s}", .{"\u{2500}"});
        }
    }

    fn printTableHeader(col1: []const u8) void {
        printRow4(col1, "Blitz", "Rayon", "Difference");
    }

    fn printRow4(name: []const u8, c1: []const u8, c2: []const u8, c3: []const u8) void {
        std.debug.print("\u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w1}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w2}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w3}) ++
            "} \u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w4}) ++
            "} \u{2502}\n", .{ name, c1, c2, c3 });
    }

    fn printValueRow(name: []const u8, blitz_val: f64, rayon_val: f64, unit: []const u8, bufs: *Bufs) void {
        const blitz_str = fmtVal(blitz_val, unit, &bufs.b1);
        const rayon_str = fmtVal(rayon_val, unit, &bufs.b2);
        const diff_str = calcDiff(blitz_val, rayon_val, &bufs.b3);
        printRow4(name, blitz_str, rayon_str, diff_str);
    }

    fn printIntRow(name: []const u8, blitz_val: f64, rayon_val: f64, bufs: *Bufs) void {
        const blitz_str = if (blitz_val > 0)
            std.fmt.bufPrint(&bufs.b1, "{d:.0}", .{blitz_val}) catch "N/A"
        else
            "N/A";
        const rayon_str = if (rayon_val > 0)
            std.fmt.bufPrint(&bufs.b2, "{d:.0}", .{rayon_val}) catch "N/A"
        else
            "N/A";
        const diff_str = calcDiff(blitz_val, rayon_val, &bufs.b3);
        printRow4(name, blitz_str, rayon_str, diff_str);
    }

    fn fmtVal(val: f64, unit: []const u8, buf: *[32]u8) []const u8 {
        if (val == 0) return "N/A";
        return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ val, unit }) catch "N/A";
    }

    fn calcDiff(blitz_val: f64, rayon_val: f64, buf: *[48]u8) []const u8 {
        if (blitz_val == 0 or rayon_val == 0) return "N/A";

        const ratio = blitz_val / rayon_val;

        if (ratio < 1.0) {
            const pct = (1.0 - ratio) * 100.0;
            return std.fmt.bufPrint(buf, "{s}+{d:.1}% faster{s}", .{ Color.green, pct, Color.reset }) catch "N/A";
        } else {
            const pct = (ratio - 1.0) * 100.0;
            return std.fmt.bufPrint(buf, "{s}-{d:.1}% slower{s}", .{ Color.red, pct, Color.reset }) catch "N/A";
        }
    }

    const Bufs = struct {
        b1: [32]u8 = undefined,
        b2: [32]u8 = undefined,
        b3: [48]u8 = undefined,
    };
};

// ============================================================================
// Subprocess Execution
// ============================================================================

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !struct { stdout: []u8, stderr: []u8, success: bool } {
    var child = std.process.Child.init(argv, allocator);
    if (cwd) |dir| {
        child.cwd = dir;
    }
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: [4 * 1024 * 1024]u8 = undefined;
    var stderr_buf: [4 * 1024 * 1024]u8 = undefined;

    const stdout_len = child.stdout.?.readAll(&stdout_buf) catch 0;
    const stderr_len = child.stderr.?.readAll(&stderr_buf) catch 0;

    const term = try child.wait();
    const success = term.Exited == 0;

    const stdout = try allocator.dupe(u8, stdout_buf[0..stdout_len]);
    const stderr = try allocator.dupe(u8, stderr_buf[0..stderr_len]);

    return .{ .stdout = stdout, .stderr = stderr, .success = success };
}

fn getProjectDir(allocator: std.mem.Allocator) ![]const u8 {
    const exe_path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_path);

    if (std.mem.indexOf(u8, exe_path, ".zig-cache")) |_| {
        return try std.fs.path.resolve(allocator, &.{ exe_path, "..", "..", ".." });
    } else {
        return try std.fs.path.resolve(allocator, &.{ exe_path, "..", ".." });
    }
}

// ============================================================================
// Summary Stats
// ============================================================================

const CompareResult = struct {
    blitz_wins: u32 = 0,
    rayon_wins: u32 = 0,
    ties: u32 = 0,

    fn compare(self: *CompareResult, blitz_val: f64, rayon_val: f64) void {
        if (blitz_val > 0 and rayon_val > 0) {
            const ratio = blitz_val / rayon_val;
            if (@abs(ratio - 1.0) < 0.01) {
                self.ties += 1;
            } else if (blitz_val < rayon_val) {
                self.blitz_wins += 1;
            } else {
                self.rayon_wins += 1;
            }
        }
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const project_dir = try getProjectDir(allocator);
    defer allocator.free(project_dir);

    const benchmarks_dir = try std.fs.path.join(allocator, &.{ project_dir, "benchmarks" });
    defer allocator.free(benchmarks_dir);

    const rust_dir = try std.fs.path.join(allocator, &.{ benchmarks_dir, "rayon" });
    defer allocator.free(rust_dir);

    // Print header
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                    BLITZ vs RAYON COMPARATIVE BENCHMARK{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });

    // Build Rust/Rayon benchmark
    std.debug.print("{s}Building Rayon benchmark...{s}\n", .{ Color.blue, Color.reset });
    const cargo_result = try runCommand(allocator, &.{ "cargo", "build", "--release" }, rust_dir);
    defer allocator.free(cargo_result.stdout);
    defer allocator.free(cargo_result.stderr);

    if (!cargo_result.success) {
        std.debug.print("{s}Failed to build Rayon benchmark{s}\n", .{ Color.red, Color.reset });
        std.debug.print("{s}\n", .{cargo_result.stderr});
        return;
    }
    std.debug.print("{s}✓ Rayon build complete{s}\n", .{ Color.green, Color.reset });

    // Run Blitz benchmark
    std.debug.print("{s}Running Blitz benchmark...{s}\n", .{ Color.blue, Color.reset });

    const zig_out_bench = try std.fs.path.join(allocator, &.{ project_dir, "zig-out", "benchmarks" });
    defer allocator.free(zig_out_bench);
    const blitz_bench_path = try std.fs.path.join(allocator, &.{ zig_out_bench, "blitz_bench" });
    defer allocator.free(blitz_bench_path);

    const blitz_result = try runCommand(allocator, &.{blitz_bench_path}, benchmarks_dir);
    defer allocator.free(blitz_result.stdout);
    defer allocator.free(blitz_result.stderr);

    if (!blitz_result.success) {
        std.debug.print("{s}Failed to run Blitz benchmark{s}\n", .{ Color.red, Color.reset });
        std.debug.print("stdout: {s}\n", .{blitz_result.stdout});
        std.debug.print("stderr: {s}\n", .{blitz_result.stderr});
        return;
    }
    std.debug.print("{s}✓ Blitz benchmark complete{s}\n", .{ Color.green, Color.reset });

    // Run Rayon benchmark
    std.debug.print("{s}Running Rayon benchmark...{s}\n", .{ Color.blue, Color.reset });

    const rayon_bench_path = try std.fs.path.join(allocator, &.{ rust_dir, "target", "release", "rayon_compare" });
    defer allocator.free(rayon_bench_path);

    const rayon_result = try runCommand(allocator, &.{rayon_bench_path}, rust_dir);
    defer allocator.free(rayon_result.stdout);
    defer allocator.free(rayon_result.stderr);

    if (!rayon_result.success) {
        std.debug.print("{s}Failed to run Rayon benchmark{s}\n", .{ Color.red, Color.reset });
        std.debug.print("{s}\n", .{rayon_result.stderr});
        return;
    }
    std.debug.print("{s}✓ Rayon benchmark complete{s}\n\n", .{ Color.green, Color.reset });

    // Parse results (blitz outputs to stderr via std.debug.print, rayon to stdout)
    const blitz = parseJsonResults(blitz_result.stderr);
    const rayon = parseJsonResults(rayon_result.stdout);

    var bufs = TableWriter.Bufs{};
    var cmp = CompareResult{};

    // Display comparison
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                              COMPARISON RESULTS{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });

    // 1. Fork-Join Overhead
    TableWriter.printHeader("1. FORK-JOIN OVERHEAD (ns/fork, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Benchmark");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("Depth 10", blitz.fork_join_depth_10, rayon.fork_join_depth_10, "ns", &bufs);
    cmp.compare(blitz.fork_join_depth_10, rayon.fork_join_depth_10);
    TableWriter.printValueRow("Depth 15", blitz.fork_join_depth_15, rayon.fork_join_depth_15, "ns", &bufs);
    cmp.compare(blitz.fork_join_depth_15, rayon.fork_join_depth_15);
    TableWriter.printValueRow("Depth 20", blitz.fork_join_depth_20, rayon.fork_join_depth_20, "ns", &bufs);
    cmp.compare(blitz.fork_join_depth_20, rayon.fork_join_depth_20);
    TableWriter.printBottomBorder();

    // 2. Parallel Fibonacci
    TableWriter.printHeader("2. PARALLEL FIBONACCI (ms, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Benchmark");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("fib(35) parallel", blitz.fib_35_par_ms, rayon.fib_35_par_ms, "ms", &bufs);
    cmp.compare(blitz.fib_35_par_ms, rayon.fib_35_par_ms);
    TableWriter.printValueRow("fib(35) sequential", blitz.fib_35_seq_ms, rayon.fib_35_seq_ms, "ms", &bufs);
    cmp.compare(blitz.fib_35_seq_ms, rayon.fib_35_seq_ms);
    TableWriter.printValueRow("fib(40) parallel", blitz.fib_40_par_ms, rayon.fib_40_par_ms, "ms", &bufs);
    cmp.compare(blitz.fib_40_par_ms, rayon.fib_40_par_ms);
    TableWriter.printValueRow("fib(40) sequential", blitz.fib_40_seq_ms, rayon.fib_40_seq_ms, "ms", &bufs);
    cmp.compare(blitz.fib_40_seq_ms, rayon.fib_40_seq_ms);
    TableWriter.printBottomBorder();

    // 3. Parallel Sum
    TableWriter.printHeader("3. PARALLEL SUM - 10M elements (ms, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Benchmark");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("Parallel sum", blitz.sum_10m_par_ms, rayon.sum_10m_par_ms, "ms", &bufs);
    cmp.compare(blitz.sum_10m_par_ms, rayon.sum_10m_par_ms);
    TableWriter.printValueRow("Sequential sum", blitz.sum_10m_seq_ms, rayon.sum_10m_seq_ms, "ms", &bufs);
    cmp.compare(blitz.sum_10m_seq_ms, rayon.sum_10m_seq_ms);
    TableWriter.printBottomBorder();

    // 4. PDQSort
    TableWriter.printHeader("4. PARALLEL PDQSORT - 1M elements (ms, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Pattern");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("Random", blitz.sort_1m_random_ms, rayon.sort_1m_random_ms, "ms", &bufs);
    cmp.compare(blitz.sort_1m_random_ms, rayon.sort_1m_random_ms);
    TableWriter.printValueRow("Sorted", blitz.sort_1m_sorted_ms, rayon.sort_1m_sorted_ms, "ms", &bufs);
    cmp.compare(blitz.sort_1m_sorted_ms, rayon.sort_1m_sorted_ms);
    TableWriter.printValueRow("Reverse", blitz.sort_1m_reverse_ms, rayon.sort_1m_reverse_ms, "ms", &bufs);
    cmp.compare(blitz.sort_1m_reverse_ms, rayon.sort_1m_reverse_ms);
    TableWriter.printValueRow("Equal", blitz.sort_1m_equal_ms, rayon.sort_1m_equal_ms, "ms", &bufs);
    cmp.compare(blitz.sort_1m_equal_ms, rayon.sort_1m_equal_ms);
    TableWriter.printBottomBorder();

    // 5. Find Operations
    TableWriter.printHeader("5. FIND OPERATIONS - 10M elements (\xc2\xb5s, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Operation");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("find (early exit)", blitz.find_10m_early_us, rayon.find_10m_early_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.find_10m_early_us, rayon.find_10m_early_us);
    TableWriter.printValueRow("position (early)", blitz.position_10m_early_us, rayon.position_10m_early_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.position_10m_early_us, rayon.position_10m_early_us);
    TableWriter.printValueRow("position (middle)", blitz.position_10m_mid_us, rayon.position_10m_mid_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.position_10m_mid_us, rayon.position_10m_mid_us);
    TableWriter.printBottomBorder();

    // 6. Any/All Predicates
    TableWriter.printHeader("6. ANY/ALL PREDICATES - 10M elements (\xc2\xb5s, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Operation");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("any (early exit)", blitz.any_10m_early_us, rayon.any_10m_early_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.any_10m_early_us, rayon.any_10m_early_us);
    TableWriter.printValueRow("any (full scan)", blitz.any_10m_full_us, rayon.any_10m_full_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.any_10m_full_us, rayon.any_10m_full_us);
    TableWriter.printValueRow("all (pass)", blitz.all_10m_pass_us, rayon.all_10m_pass_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.all_10m_pass_us, rayon.all_10m_pass_us);
    TableWriter.printBottomBorder();

    // 7. Min/Max by Key
    TableWriter.printHeader("7. MIN/MAX BY KEY - 10M elements (\xc2\xb5s, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Operation");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("minByKey", blitz.min_by_key_10m_us, rayon.min_by_key_10m_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.min_by_key_10m_us, rayon.min_by_key_10m_us);
    TableWriter.printValueRow("maxByKey", blitz.max_by_key_10m_us, rayon.max_by_key_10m_us, "\xc2\xb5s", &bufs);
    cmp.compare(blitz.max_by_key_10m_us, rayon.max_by_key_10m_us);
    TableWriter.printBottomBorder();

    // 8. Iterator Combinators
    TableWriter.printHeader("8. ITERATOR COMBINATORS (ms, lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Operation");
    TableWriter.printMidBorder();
    TableWriter.printValueRow("chunks(1000) + sum", blitz.chunks_10m_1000_ms, rayon.chunks_10m_1000_ms, "ms", &bufs);
    cmp.compare(blitz.chunks_10m_1000_ms, rayon.chunks_10m_1000_ms);
    TableWriter.printValueRow("enumerate + forEach", blitz.enumerate_10m_ms, rayon.enumerate_10m_ms, "ms", &bufs);
    cmp.compare(blitz.enumerate_10m_ms, rayon.enumerate_10m_ms);
    TableWriter.printValueRow("chain(2x5M) + sum", blitz.chain_2x5m_ms, rayon.chain_2x5m_ms, "ms", &bufs);
    cmp.compare(blitz.chain_2x5m_ms, rayon.chain_2x5m_ms);
    TableWriter.printValueRow("zip + dot product", blitz.zip_10m_ms, rayon.zip_10m_ms, "ms", &bufs);
    cmp.compare(blitz.zip_10m_ms, rayon.zip_10m_ms);
    TableWriter.printValueRow("flatten(1000x10k) + sum", blitz.flatten_1000x10k_ms, rayon.flatten_1000x10k_ms, "ms", &bufs);
    cmp.compare(blitz.flatten_1000x10k_ms, rayon.flatten_1000x10k_ms);
    TableWriter.printBottomBorder();

    // 9. Resource Usage
    TableWriter.printHeader("9. RESOURCE USAGE (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader("Metric");
    TableWriter.printMidBorder();
    {
        // Format as MB for readability
        const blitz_mb = blitz.peak_memory_kb / 1024.0;
        const rayon_mb = rayon.peak_memory_kb / 1024.0;
        const blitz_str = std.fmt.bufPrint(&bufs.b1, "{d:.1} MB", .{blitz_mb}) catch "N/A";
        const rayon_str = std.fmt.bufPrint(&bufs.b2, "{d:.1} MB", .{rayon_mb}) catch "N/A";
        const diff_str = TableWriter.calcDiff(blitz.peak_memory_kb, rayon.peak_memory_kb, &bufs.b3);
        TableWriter.printRow4("Peak Memory", blitz_str, rayon_str, diff_str);
        cmp.compare(blitz.peak_memory_kb, rayon.peak_memory_kb);
    }
    TableWriter.printIntRow("Voluntary Ctx Sw", blitz.voluntary_ctx_switches, rayon.voluntary_ctx_switches, &bufs);
    cmp.compare(blitz.voluntary_ctx_switches, rayon.voluntary_ctx_switches);
    TableWriter.printIntRow("Involuntary Ctx Sw", blitz.involuntary_ctx_switches, rayon.involuntary_ctx_switches, &bufs);
    cmp.compare(blitz.involuntary_ctx_switches, rayon.involuntary_ctx_switches);
    TableWriter.printBottomBorder();

    // Legend
    std.debug.print("\n{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                                   LEGEND{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });
    std.debug.print("  {s}+X% faster{s}  = Blitz is X% faster than Rayon (lower time)\n", .{ Color.green, Color.reset });
    std.debug.print("  {s}-X% slower{s}  = Blitz is X% slower than Rayon (higher time)\n\n", .{ Color.red, Color.reset });
    std.debug.print("  Note: Results may vary based on system load and hardware.\n", .{});
    std.debug.print("  Both frameworks configured with 10 worker threads.\n", .{});

    // Summary
    std.debug.print("\n{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                                  SUMMARY{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });

    const total = cmp.blitz_wins + cmp.rayon_wins + cmp.ties;
    std.debug.print("  Benchmarks compared: {d}\n", .{total});
    std.debug.print("  {s}Blitz wins:{s}          {d}\n", .{ Color.green, Color.reset, cmp.blitz_wins });
    std.debug.print("  {s}Rayon wins:{s}          {d}\n", .{ Color.red, Color.reset, cmp.rayon_wins });
    std.debug.print("  Ties:                {d}\n\n", .{cmp.ties});

    if (cmp.blitz_wins > cmp.rayon_wins) {
        std.debug.print("  {s}{s}Blitz leads overall!{s}\n\n", .{ Color.green, Color.bold, Color.reset });
    } else if (cmp.rayon_wins > cmp.blitz_wins) {
        std.debug.print("  {s}{s}Rayon leads overall{s}\n\n", .{ Color.yellow, Color.bold, Color.reset });
    } else {
        std.debug.print("  {s}{s}It's a tie!{s}\n\n", .{ Color.cyan, Color.bold, Color.reset });
    }
}
