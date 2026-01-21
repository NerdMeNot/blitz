# Initialization

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
// Get current grain size
const current = blitz.getGrainSize();

// Set custom grain size
blitz.setGrainSize(2048);

// Reset to default (automatic)
blitz.setGrainSize(blitz.defaultGrainSize);
```

## Auto-Initialization

Many Blitz operations auto-initialize if needed:

```zig
// This will auto-init if not already initialized
const sum = blitz.iter(i64, data).sum();

// Explicit init is still recommended for:
// 1. Error handling
// 2. Custom configuration
// 3. Predictable startup time
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
