# Installation

Blitz is a pure Zig library with no external dependencies.

## Requirements

- Zig 0.15.0 or later
- POSIX-compatible OS (Linux, macOS) or Windows

## Adding Blitz to Your Project

### Option 1: Zig Package Manager (Recommended)

**Step 1**: Add blitz to your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",

    .dependencies = .{
        .blitz = .{
            .url = "https://github.com/NerdMeNot/blitz/archive/refs/tags/v1.0.0-zig0.15.2.tar.gz",
            .hash = "blitz-1.0.0-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            // Run `zig build` to get the correct hash
        },
    },

    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

**Step 2**: Add the dependency to your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get blitz dependency
    const blitz_dep = b.dependency("blitz", .{
        .target = target,
        .optimize = optimize,
    });

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add blitz module
    exe.root_module.addImport("blitz", blitz_dep.module("blitz"));

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
```

**Step 3**: Use blitz in your code:

```zig
// src/main.zig
const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    var data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const sum = blitz.iter(i64, &data).sum();
    std.debug.print("Sum: {}\n", .{sum});
}
```

### Option 2: Git Submodule

```bash
git submodule add https://github.com/NerdMeNot/blitz.git deps/blitz
```

Then in your `build.zig`:

```zig
const blitz_mod = b.addModule("blitz", .{
    .root_source_file = b.path("deps/blitz/mod.zig"),
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("blitz", blitz_mod);
```

### Option 3: Direct Import (Development)

For quick prototyping, copy the blitz source and import directly:

```zig
const blitz = @import("path/to/blitz/mod.zig");
```

## Verifying Installation

Run the test suite to verify everything works:

```bash
cd blitz
zig build test
```

Expected output:
```
All tests passed.
```

## Running Benchmarks

```bash
cd blitz
zig build bench
./benchmarks/compare_bench.sh  # Compare with Rayon
```

## Platform Notes

### macOS (Apple Silicon)
- Full support with ARM64 SIMD (NEON)
- Optimal performance on M1/M2/M3 chips

### Linux (x86_64)
- Full support with AVX2/AVX-512 SIMD
- Works on any modern x86_64 processor

### Windows
- Supported via Zig's cross-platform std library
- Uses Windows synchronization primitives internally

## Optimization Tips

For best performance, build with release mode:

```bash
zig build -Doptimize=ReleaseFast
```

Or in your build.zig, ensure users can select optimization:

```zig
const optimize = b.standardOptimizeOption(.{});
```
