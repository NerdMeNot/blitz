---
title: Initialization
description: How to initialize and configure the Blitz thread pool
---

How to initialize and configure the Blitz thread pool.

## Basic Initialization

```zig
const blitz = @import("blitz");

pub fn main() !void {
    // Initialize with automatic thread detection
    try blitz.init();
    defer blitz.deinit();

    // Now use parallel operations...
}
```

## Custom Configuration

```zig
try blitz.initWithConfig(.{
    // Number of background worker threads
    // Default: CPU count - 1 (main thread also participates)
    .background_worker_count = 8,
});
defer blitz.deinit();
```

## Query Runtime Status

```zig
// Check if initialized
if (blitz.isInitialized()) {
    std.debug.print("Pool is ready\n", .{});
}

// Get worker count (including main thread)
const workers = blitz.numWorkers();
std.debug.print("Running with {} workers\n", .{workers});
```

## Grain Size Configuration

Control minimum chunk size for parallel operations:

```zig
// Get current grain size (default: 65536)
const current = blitz.getGrainSize();

// Set custom grain size
blitz.setGrainSize(2048);

// Reset to default
blitz.setGrainSize(blitz.DEFAULT_GRAIN_SIZE); // 65536
```

The default grain size (`DEFAULT_GRAIN_SIZE = 65536`) works well for most workloads. Reduce it for expensive per-element operations; increase it for trivial operations.

## Initialization is Required

Blitz does **not** auto-initialize. You must call `init()` before using parallel operations:

```zig
// Correct usage
try blitz.init();
defer blitz.deinit();
const sum = blitz.iter(i64, data).sum();
```

Calling `initWithConfig()` on an already-initialized pool returns `error.AlreadyInitialized`.

## Pool Statistics

```zig
// Get execution stats
const stats = blitz.getStats();
std.debug.print("Executed: {}, Stolen: {}\n", .{ stats.executed, stats.stolen });

// Reset stats
blitz.resetStats();
```

## Thread Count Guidelines

| Workload Type | Recommended Threads |
|---------------|---------------------|
| CPU-bound (compute) | CPU count |
| Memory-bound (copy, scan) | CPU count / 2 |
| Mixed | CPU count - 1 |
| I/O-bound | Not ideal for Blitz |

## Example: Production Setup

```zig
pub fn initBlitz() !void {
    const cpu_count = std.Thread.getCpuCount() catch 4;

    try blitz.initWithConfig(.{
        // Leave 1 core for OS and other tasks
        .background_worker_count = @max(1, cpu_count - 2),
    });
}

pub fn main() !void {
    try initBlitz();
    defer blitz.deinit();

    // Application code...
}
```
