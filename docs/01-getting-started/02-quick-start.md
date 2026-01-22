# Quick Start

Get parallel execution working in under 2 minutes.

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

## Core Patterns

### 1. Parallel Aggregations

```zig
const data: []i64 = getNumbers();

const sum = blitz.iter(i64, data).sum();
const min = blitz.iter(i64, data).min();  // -> ?i64
const max = blitz.iter(i64, data).max();  // -> ?i64
```

### 2. Parallel Search (with early exit)

```zig
// Find any match (fastest)
const found = blitz.iter(i64, data).findAny(isNegative);

// Check predicates
const has_negative = blitz.iter(i64, data).any(isNegative);
const all_positive = blitz.iter(i64, data).all(isPositive);

fn isNegative(x: i64) bool { return x < 0; }
fn isPositive(x: i64) bool { return x > 0; }
```

### 3. Parallel Transform

```zig
var data: []i64 = getNumbers();

// Transform in-place
blitz.iterMut(i64, data).mapInPlace(double);

// Fill with value
blitz.iterMut(i64, data).fill(0);

fn double(x: i64) i64 { return x * 2; }
```

### 4. Parallel Sort

```zig
var numbers = [_]i64{ 5, 2, 8, 1, 9, 3, 7, 4, 6 };

try blitz.parallelSort(i64, &numbers, allocator);
// numbers is now [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

### 5. Fork-Join (Divide and Conquer)

```zig
// Execute two computations in parallel
const result = blitz.join(u64, u64, computeLeft, computeRight, left_arg, right_arg);
// result[0] = computeLeft(left_arg)
// result[1] = computeRight(right_arg)

// Classic example: parallel fibonacci
fn fib(n: u64) u64 {
    if (n < 20) return fibSequential(n);
    const r = blitz.join(u64, u64, fib, fib, n - 1, n - 2);
    return r[0] + r[1];
}
```

### 6. Range Iteration

```zig
// Process indices 0..999 in parallel
blitz.range(0, 1000).forEach(processIndex);

fn processIndex(i: usize) void {
    // Process index i
}
```

## Complete Example

```zig
const std = @import("std");
const blitz = @import("blitz");

pub fn main() !void {
    // Generate some data
    var data: [1_000_000]i64 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    // Parallel operations
    const sum = blitz.iter(i64, &data).sum();
    const min = blitz.iter(i64, &data).min();
    const max = blitz.iter(i64, &data).max();

    std.debug.print("Sum: {}, Min: {}, Max: {}\n", .{ sum, min, max });

    // Transform in parallel
    blitz.iterMut(i64, &data).mapInPlace(square);

    // Check result
    const all_positive = blitz.iter(i64, &data).all(isPositive);
    std.debug.print("All positive after squaring: {}\n", .{all_positive});
}

fn square(x: i64) i64 { return x * x; }
fn isPositive(x: i64) bool { return x >= 0; }
```

## Next Steps

- [Basic Concepts](03-basic-concepts.md) - Understand the execution model
- [Iterator API](../02-usage/05-iterators.md) - Full iterator reference
- [Fork-Join](../02-usage/04-fork-join.md) - Divide and conquer patterns
