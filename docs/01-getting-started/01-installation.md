# Installation

Blitz is a pure Zig library with no external dependencies.

## Requirements

- Zig 0.13.0 or later
- POSIX-compatible OS (Linux, macOS) or Windows

## Adding Blitz to Your Project

### Option 1: As a Module Dependency

Add to your `build.zig`:

```zig
const blitz_mod = b.addModule("blitz", .{
    .root_source_file = .{ .path = "path/to/blitz/api.zig" },
});

exe.root_module.addImport("blitz", blitz_mod);
```

### Option 2: Direct Import

Simply import the API file:

```zig
const blitz = @import("path/to/blitz/api.zig");
```

### Option 3: Build as Static Library

```bash
cd blitz
zig build -Doptimize=ReleaseFast
```

This produces `libblitz.a` which can be linked into your project.

## Verifying Installation

Run the test suite to verify everything works:

```bash
cd blitz
zig test api.zig
```

Expected output:
```
All 117 tests passed.
```

## Running Examples

```bash
cd blitz
zig build-exe --dep blitz -Mroot=examples/examples.zig -Mblitz=api.zig -lc -O ReleaseFast
./root
```

## Platform Notes

### macOS (Apple Silicon)
- Full support with ARM64 SIMD (NEON)
- 10+ cores recommended for best performance

### Linux (x86_64)
- Full support with AVX2/AVX-512 SIMD
- Works on any modern x86_64 processor

### Windows
- Supported via Zig's cross-platform std library
- Uses Windows synchronization primitives internally
