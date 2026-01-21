# Quick Start

Get parallel execution working in under 5 minutes.

## Hello Parallel World

```zig
const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    // Initialize the thread pool (auto-detects CPU count)
    try blitz.init();
    defer blitz.deinit();

    std.debug.print("Running with {} workers\n", .{blitz.numWorkers()});

    // Parallel for: process 1 million elements
    var data: [1_000_000]f64 = undefined;

    const Context = struct { data: []f64 };
    blitz.parallelFor(data.len, Context, .{ .data = &data }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.data[start..end], start..) |*v, i| {
                v.* = @sqrt(@as(f64, @floatFromInt(i)));
            }
        }
    }.body);

    std.debug.print("Computed {} square roots in parallel!\n", .{data.len});
}
```

## Core Patterns

### 1. Parallel For Loop

Process a range `[0, n)` in parallel:

```zig
blitz.parallelFor(n, Context, ctx, bodyFn);
```

### 2. Parallel Reduce

Map elements and combine results:

```zig
const sum = blitz.parallelReduce(
    i64,           // Result type
    data.len,      // Count
    0,             // Identity element
    []const i64,   // Context type
    data,          // Context value
    mapFn,         // fn(ctx, index) -> T
    combineFn,     // fn(T, T) -> T
);
```

### 3. Fork-Join

Execute two tasks potentially in parallel:

```zig
const results = blitz.join(
    ResultA, ResultB,  // Return types
    taskA, taskB,      // Functions
    argA, argB,        // Arguments
);
// results[0] = taskA(argA)
// results[1] = taskB(argB)
```

### 4. Parallel Iterators

Rayon-style composable iterators:

```zig
const sum = blitz.iter(i64, data).sum();
const min = blitz.iter(i64, data).min();
const found = blitz.iter(i64, data).findAny(isNegative);
```

## Example: Parallel Sum

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

// Using iterator
const sum1 = blitz.iter(i64, &data).sum();

// Using parallelReduce
const sum2 = blitz.parallelReduce(
    i64, data.len, 0,
    []const i64, &data,
    struct { fn map(d: []const i64, i: usize) i64 { return d[i]; } }.map,
    struct { fn add(a: i64, b: i64) i64 { return a + b; } }.add,
);

// Both return 55
```

## Example: Parallel Sort

```zig
var numbers = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

// In-place parallel PDQSort
blitz.sort(i64, &numbers, struct {
    fn lessThan(a: i64, b: i64) bool {
        return a < b;
    }
}.lessThan);

// numbers is now [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

## Next Steps

- [Basic Concepts](03-basic-concepts.md) - Understand the execution model
- [Usage Guide](../02-usage/) - Detailed API usage
- [Examples](../../examples/) - Runnable code examples
