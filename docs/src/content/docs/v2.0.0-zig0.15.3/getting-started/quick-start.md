---
title: Quick Start
description: Get parallel execution working in under 5 minutes
slug: v2.0.0-zig0.15.3/getting-started/quick-start
---

Get parallel execution working in under 5 minutes.

## Installation

Add Blitz to your `build.zig.zon`:

```zig
.dependencies = .{
    .blitz = .{
        .url = "https://github.com/NerdMeNot/blitz/archive/refs/tags/v1.0.0-zig0.15.2.tar.gz",
        .hash = "...", // Get from error message on first build
    },
},
```

In `build.zig`:

```zig
const blitz = b.dependency("blitz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("blitz", blitz.module("blitz"));
```

## Hello Parallel World

```zig
const blitz = @import("blitz");

pub fn main() !void {
    var numbers = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    // Parallel sum - that's it!
    const sum = blitz.iter(i64, &numbers).sum();
    // sum = 55
}
```

No initialization required. Blitz auto-initializes on first use.

## The Two APIs

Blitz provides two levels of abstraction:

| API | Best For | Example |
|-----|----------|---------|
| **Iterators** (recommended) | Data processing, aggregations, transforms | `blitz.iter(T, data).sum()` |
| **Fork-Join** | Divide-and-conquer, recursive algorithms | `blitz.join(.{...})` |

## Iterator API (Recommended)

### Aggregations

```zig
const data: []const i64 = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

const sum = blitz.iter(i64, data).sum();      // 55
const min = blitz.iter(i64, data).min();      // ?i64 = 1
const max = blitz.iter(i64, data).max();      // ?i64 = 10
const count = blitz.iter(i64, data).count();  // 10
```

### Search (with early exit)

```zig
// Find any match (fastest - non-deterministic order)
const found = blitz.iter(i64, data).findAny(isNegative);

// Find first match (deterministic)
const first = blitz.iter(i64, data).findFirst(isNegative);

// Check predicates (short-circuit on match)
const has_negative = blitz.iter(i64, data).any(isNegative);
const all_positive = blitz.iter(i64, data).all(isPositive);

fn isNegative(x: i64) bool { return x < 0; }
fn isPositive(x: i64) bool { return x > 0; }
```

### Transform

```zig
var data: [100]i64 = undefined;
for (&data, 0..) |*v, i| v.* = @intCast(i);

// Transform in-place
blitz.iterMut(i64, &data).mapInPlace(double);

// Fill with value
blitz.iterMut(i64, &data).fill(0);

fn double(x: i64) i64 { return x * 2; }
```

### Custom Reduce

```zig
const product = blitz.iter(i64, data).reduce(1, multiply);

fn multiply(a: i64, b: i64) i64 { return a * b; }
```

## Fork-Join API

### Two Tasks

```zig
const result = blitz.join(.{
    .left = .{ computeLeft, left_data },
    .right = .{ computeRight, right_data },
});
// Access: result.left, result.right
```

### Three or More Tasks

```zig
const result = blitz.join(.{
    .a = .{ taskA, arg_a },
    .b = .{ taskB, arg_b },
    .c = .{ taskC, arg_c },
});
// Access: result.a, result.b, result.c
```

### Classic Fibonacci Example

```zig
fn parallelFib(n: u64) u64 {
    // Switch to sequential below threshold
    if (n < 20) return fibSequential(n);

    const r = blitz.join(.{
        .a = .{ parallelFib, n - 1 },
        .b = .{ parallelFib, n - 2 },
    });
    return r.a + r.b;
}

fn fibSequential(n: u64) u64 {
    if (n <= 1) return n;
    return fibSequential(n - 1) + fibSequential(n - 2);
}
```

## Parallel Sort

```zig
var numbers = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

// Sort ascending (in-place, no allocation needed)
blitz.sortAsc(i64, &numbers);
// numbers is now [1, 2, 3, 4, 5, 6, 7, 8, 9]

// Sort descending
blitz.sortDesc(i64, &numbers);

// Custom comparator
blitz.sort(i64, &numbers, lessThan);

fn lessThan(a: i64, b: i64) bool {
    return a < b;
}

// Sort by key
blitz.sortByKey(Person, u32, &people, getAge);

fn getAge(p: Person) u32 { return p.age; }
```

## Range Iteration

```zig
// Process indices 0..999 in parallel
blitz.range(0, 1000).forEach(processIndex);

fn processIndex(i: usize) void {
    // Process index i
}

// Sum a range
const sum = blitz.range(0, 1000).sum(i64, identity);

fn identity(i: usize) i64 { return @intCast(i); }
```

## Low-Level API

For full control, use the low-level parallel primitives:

```zig
// Parallel for with context
const Context = struct {
    input: []const f64,
    output: []f64,
    scale: f64,
};

blitz.parallelFor(data.len, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) void {
        for (c.input[start..end], c.output[start..end]) |in, *out| {
            out.* = in * c.scale;
        }
    }
}.body);

// Parallel reduce
const sum = blitz.parallelReduce(
    i64,          // Result type
    data.len,     // Element count
    0,            // Identity value
    []const i64,  // Context type
    data,         // Context value
    struct {
        fn map(d: []const i64, i: usize) i64 { return d[i]; }
    }.map,
    struct {
        fn combine(a: i64, b: i64) i64 { return a + b; }
    }.combine,
);
```

## Complete Example

```zig
const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate data
    var data: [1_000_000]i64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    // Parallel aggregations
    const sum = blitz.iter(i64, &data).sum();
    const min = blitz.iter(i64, &data).min();
    const max = blitz.iter(i64, &data).max();
    std.debug.print("Sum: {}, Min: {?}, Max: {?}\n", .{ sum, min, max });

    // Parallel transform
    blitz.iterMut(i64, &data).mapInPlace(square);

    // Parallel search
    const found = blitz.iter(i64, &data).findAny(isLarge);
    std.debug.print("Found large value: {?}\n", .{found});

    // Parallel sort
    var to_sort = [_]i64{ 5, 2, 8, 1, 9 };
    blitz.sortAsc(i64, &to_sort);
    std.debug.print("Sorted: {any}\n", .{to_sort});

    // Fork-join
    const result = blitz.join(.{
        .a = .{ computeA, @as(u64, 10) },
        .b = .{ computeB, @as(u64, 20) },
    });
    std.debug.print("Join result: a={}, b={}\n", .{ result.a, result.b });
}

fn square(x: i64) i64 { return x * x; }
fn isLarge(x: i64) bool { return x > 500_000_000; }
fn computeA(n: u64) u64 { return n * n; }
fn computeB(n: u64) u64 { return n + 100; }
```

## Real-World Taste

Here's what Blitz looks like on a realistic 10-million-element workload:

```zig
const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 10 million elements
    const n = 10_000_000;
    const data = try allocator.alloc(f64, n);
    defer allocator.free(data);

    for (data, 0..) |*v, i| {
        v.* = @as(f64, @floatFromInt(i)) * 0.001;
    }

    // Parallel stats: compute sum and max simultaneously
    const stats = blitz.join(.{
        .sum = .{ struct {
            fn compute(d: []const f64) f64 {
                return blitz.iter(f64, d).sum();
            }
        }.compute, @as([]const f64, data) },
        .max = .{ struct {
            fn compute(d: []const f64) ?f64 {
                return blitz.iter(f64, d).max();
            }
        }.compute, @as([]const f64, data) },
    });

    std.debug.print("Sum: {d:.2}, Max: {?d:.2}\n", .{ stats.sum, stats.max });

    // Transform in-place: normalize all values by the max
    if (stats.max) |max_val| {
        var mut_data = data;
        const scale = 1.0 / max_val;
        blitz.parallelFor(mut_data.len, struct { d: []f64, s: f64 }, .{
            .d = mut_data,
            .s = scale,
        }, struct {
            fn body(ctx: @This(), start: usize, end: usize) void {
                for (ctx.d[start..end]) |*v| {
                    v.* *= ctx.s;
                }
            }
        }.body);
    }
}
```

:::caution[Common Mistakes]
1. **Forgetting `defer blitz.deinit()`** — leaks worker threads
2. **Parallelizing tiny data** — overhead exceeds benefit below ~1000 elements
3. **Shared mutable state** — each chunk must write to disjoint memory regions
4. **Missing sequential threshold** in recursive `join()` — causes exponential overhead
:::

## Common Patterns

### Pattern 1: Process and Aggregate

```zig
// Process data, then aggregate results
blitz.iterMut(f64, &data).mapInPlace(normalize);
const total = blitz.iter(f64, &data).sum();
```

### Pattern 2: Search and Early Exit

```zig
// Find first invalid entry (stops early if found)
const invalid = blitz.iter(Record, &records).findAny(isInvalid);
if (invalid) |record| {
    std.debug.print("Invalid record found: {}\n", .{record});
}
```

### Pattern 3: Divide and Conquer

```zig
fn mergeSort(data: []i32) void {
    if (data.len <= 1024) {
        std.sort.insertion(i32, data, {}, std.sort.asc(i32));
        return;
    }
    const mid = data.len / 2;
    _ = blitz.join(.{
        .left = .{ mergeSort, data[0..mid] },
        .right = .{ mergeSort, data[mid..] },
    });
    merge(data, mid); // Combine sorted halves
}
```

## Performance Tips

1. **Use iterators for data processing** - Optimized parallel aggregations
2. **Use fork-join for recursive algorithms** - Optimal work distribution
3. **Set appropriate thresholds** - Switch to sequential below ~1000 elements
4. **Avoid false sharing** - Don't write to adjacent memory from different threads
5. **Trust the defaults** - Auto grain size works well for most cases

## What's Next

* [Basic Concepts](/v2.0.0-zig0.15.3/getting-started/basic-concepts/) - Understand work stealing and fork-join
* [Iterator API](/v2.0.0-zig0.15.3/usage/iterators/) - Complete iterator reference
* [Fork-Join](/v2.0.0-zig0.15.3/usage/fork-join/) - Divide and conquer patterns
* [API Reference](/v2.0.0-zig0.15.3/api/core-api/) - Full API documentation
