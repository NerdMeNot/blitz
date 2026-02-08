const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Blitz Module (for downstream users)
    // ========================================================================
    const blitz_mod = b.addModule("blitz", .{
        .root_source_file = b.path("api.zig"),
        .target = target,
        .optimize = optimize,
    });
    blitz_mod.link_libc = true;

    // ========================================================================
    // Unit Tests
    // ========================================================================
    const test_mod = b.createModule(.{
        .root_source_file = b.path("blitz.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.link_libc = true;

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ========================================================================
    // Stress Tests (ReleaseFast for realistic performance)
    // ========================================================================
    const blitz_test_mod = b.createModule(.{
        .root_source_file = b.path("blitz.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    blitz_test_mod.link_libc = true;

    const stress_mod = b.createModule(.{
        .root_source_file = b.path("tests/stress.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    stress_mod.addImport("blitz", blitz_test_mod);
    stress_mod.link_libc = true;

    const stress_tests = b.addTest(.{ .root_module = stress_mod });
    const run_stress = b.addRunArtifact(stress_tests);
    const stress_step = b.step("test-stress", "Run stress tests (ReleaseFast)");
    stress_step.dependOn(&run_stress.step);

    // ========================================================================
    // All Tests
    // ========================================================================
    const test_all_step = b.step("test-all", "Run all tests (unit + stress)");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(stress_step);

    // ========================================================================
    // Benchmarks
    // ========================================================================
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/rayon_compare.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("blitz", blitz_mod);
    bench_mod.link_libc = true;

    const bench = b.addExecutable(.{
        .name = "blitz_bench",
        .root_module = bench_mod,
    });

    // Install to zig-out/benchmarks/ (so compare.zig can find it)
    const install_bench = b.addInstallArtifact(bench, .{
        .dest_dir = .{ .override = .{ .custom = "benchmarks" } },
    });

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ========================================================================
    // Comparative Benchmark (Blitz vs Rayon)
    // ========================================================================
    const compare_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/compare.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const compare_exe = b.addExecutable(.{
        .name = "compare",
        .root_module = compare_mod,
    });

    // Ensure blitz_bench is built first
    compare_exe.step.dependOn(&install_bench.step);

    const run_compare = b.addRunArtifact(compare_exe);

    const compare_step = b.step("compare", "Run comparative benchmark (Blitz vs Rayon)");
    compare_step.dependOn(&run_compare.step);

    // ========================================================================
    // Examples
    // ========================================================================
    const example_step = b.step("examples", "Build all examples");

    const examples = [_]struct { name: []const u8, desc: []const u8, path: []const u8 }{
        .{ .name = "parallel-sum", .desc = "Parallel sum reduction", .path = "examples/parallel_sum.zig" },
        .{ .name = "parallel-sort", .desc = "Parallel sorting", .path = "examples/parallel_sort.zig" },
        .{ .name = "fork-join", .desc = "Fork-join parallelism", .path = "examples/fork_join.zig" },
    };

    // ========================================================================
    // API Documentation (Zig Autodocs)
    // ========================================================================
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("api.zig"),
        .target = target,
        .optimize = .Debug,
    });
    docs_mod.link_libc = true;

    const docs_obj = b.addObject(.{
        .name = "blitz",
        .root_module = docs_mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .{ .custom = "docs/api-reference" },
        .install_subdir = "",
    });

    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);

    for (examples) |example| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("blitz", blitz_mod);
        exe_mod.link_libc = true;

        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = exe_mod,
        });

        const install = b.addInstallArtifact(exe, .{});
        example_step.dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        const run_step = b.step(example.name, example.desc);
        run_step.dependOn(&run.step);
    }
}
