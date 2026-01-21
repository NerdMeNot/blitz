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
        .root_source_file = b.path("mod.zig"),
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
        .name = "blitz-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ========================================================================
    // Examples
    // ========================================================================
    const example_step = b.step("examples", "Build all examples");

    const examples = [_]struct { name: []const u8, desc: []const u8, path: []const u8 }{
        .{ .name = "parallel-sum", .desc = "Parallel sum reduction", .path = "examples/parallel_sum.zig" },
        .{ .name = "parallel-sort", .desc = "Parallel sorting", .path = "examples/parallel_sort.zig" },
        .{ .name = "fork-join", .desc = "Fork-join parallelism", .path = "examples/fork_join.zig" },
    };

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
