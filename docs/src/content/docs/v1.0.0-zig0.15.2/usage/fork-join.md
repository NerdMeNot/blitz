---
title: Fork-Join
description: Execute multiple tasks potentially in parallel and collect results
slug: v1.0.0-zig0.15.2/usage/fork-join
---

Execute multiple tasks potentially in parallel and collect results. This is the foundation of divide-and-conquer parallelism.

## Basic Usage

```zig
const blitz = @import("blitz");

fn computeA(n: u32) u64 {
    var sum: u64 = 0;
    for (0..n) |i| sum += i * 2;
    return sum;
}

fn computeB(n: u32) u64 {
    var sum: u64 = 0;
    for (0..n) |i| sum += i * 3;
    return sum;
}

pub fn main() void {
    // Join two tasks - B may run in parallel with A
    const result = blitz.join(.{
        .a = .{ computeA, @as(u32, 1_000_000) },
        .b = .{ computeB, @as(u32, 1_000_000) },
    });

    // Access results by field name
    const total = result.a + result.b;
}
```

No explicit initialization required - Blitz auto-initializes on first use.

## How It Works

```
┌─────────────────────────────────────────────────┐
│                  join(.{.a, .b})                 │
├─────────────────────────────────────────────────┤
│                                                 │
│  1. Fork: Push B to deque (may be stolen)       │
│     ┌─────┐                                     │
│     │  B  │ ◄── visible to other workers        │
│     └─────┘                                     │
│                                                 │
│  2. Execute A locally                           │
│     ┌─────┐                                     │
│     │  A  │ ◄── runs on calling thread          │
│     └─────┘                                     │
│                                                 │
│  3. Join: Get B's result                        │
│     - If B not stolen: pop and run locally      │
│     - If B stolen: wait for thief to finish     │
│                                                 │
│  4. Return .{ .a = resultA, .b = resultB }      │
│                                                 │
└─────────────────────────────────────────────────┘
```

## Multiple Tasks

### Two Tasks

```zig
const result = blitz.join(.{
    .left = .{ computeLeft, left_data },
    .right = .{ computeRight, right_data },
});
// Access: result.left, result.right
```

### Three Tasks

```zig
const result = blitz.join(.{
    .first = .{ task1, arg1 },
    .second = .{ task2, arg2 },
    .third = .{ task3, arg3 },
});
// Access: result.first, result.second, result.third
```

### Many Tasks (Up to 8)

```zig
const result = blitz.join(.{
    .a = .{ taskA, argA },
    .b = .{ taskB, argB },
    .c = .{ taskC, argC },
    .d = .{ taskD, argD },
    // ... up to 8 tasks
});
```

## Different Return Types

Functions can return different types:

```zig
fn processStrings(strings: []const []const u8) usize {
    return strings.len;
}

fn processNumbers(numbers: []const i64) i64 {
    var sum: i64 = 0;
    for (numbers) |n| sum += n;
    return sum;
}

const result = blitz.join(.{
    .count = .{ processStrings, strings },  // Returns usize
    .sum = .{ processNumbers, numbers },     // Returns i64
});

// result.count: usize
// result.sum: i64
```

## Void Functions

For functions that don't return values, the result fields are `void`:

```zig
fn processChunkA(chunk: []u8) void {
    for (chunk) |*c| c.* *= 2;
}

fn processChunkB(chunk: []u8) void {
    for (chunk) |*c| c.* += 1;
}

_ = blitz.join(.{
    .a = .{ processChunkA, chunk_a },
    .b = .{ processChunkB, chunk_b },
});
// Both complete before returning
```

## Recursive Fork-Join (Divide and Conquer)

### Parallel Fibonacci

```zig
fn parallelFib(n: u64) u64 {
    // CRITICAL: Sequential threshold prevents overhead explosion
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

**Performance (fib(45) on 10 cores):**

| Method | Time | Speedup |
|--------|------|---------|
| Sequential | 635 ms | 1.0x |
| Parallel (threshold=20) | 93 ms | 6.9x |

### Parallel Merge Sort

```zig
fn parallelMergeSort(data: []i64, temp: []i64) void {
    // Sequential for small arrays
    if (data.len <= 1024) {
        std.mem.sort(i64, data, {}, std.sort.asc(i64));
        return;
    }

    const mid = data.len / 2;

    // Sort halves in parallel
    _ = blitz.join(.{
        .left = .{ struct {
            fn sort(args: struct { d: []i64, t: []i64 }) void {
                parallelMergeSort(args.d, args.t);
            }
        }.sort, .{ .d = data[0..mid], .t = temp[0..mid] } },
        .right = .{ struct {
            fn sort(args: struct { d: []i64, t: []i64 }) void {
                parallelMergeSort(args.d, args.t);
            }
        }.sort, .{ .d = data[mid..], .t = temp[mid..] } },
    });

    // Merge sorted halves
    merge(data[0..mid], data[mid..], temp);
    @memcpy(data, temp);
}
```

### Parallel Tree Reduction

```zig
fn parallelSum(data: []const i64) i64 {
    if (data.len < 1000) {
        var sum: i64 = 0;
        for (data) |v| sum += v;
        return sum;
    }

    const mid = data.len / 2;
    const r = blitz.join(.{
        .left = .{ parallelSum, data[0..mid] },
        .right = .{ parallelSum, data[mid..] },
    });
    return r.left + r.right;
}
```

## Sequential Threshold

**Always set a sequential threshold** in recursive fork-join:

```zig
// GOOD: Has threshold
fn goodFib(n: u64) u64 {
    if (n < 20) return fibSeq(n);  // ← Threshold!
    const r = blitz.join(.{...});
    return r.a + r.b;
}

// BAD: No threshold - exponential overhead
fn badFib(n: u64) u64 {
    if (n <= 1) return n;
    const r = blitz.join(.{...});  // ← Spawns task even for n=2!
    return r.a + r.b;
}
```

Threshold guidelines:

| Algorithm | Recommended Threshold |
|-----------|----------------------|
| Fibonacci | n \< 20 |
| Merge sort | len \< 1024 |
| Tree operations | nodes \< 100-1000 |
| General | Switch when overhead > work |

## When to Use Fork-Join

### Good For

* **Recursive divide-and-conquer**: sort, fibonacci, tree traversal
* **Two independent computations**: results don't depend on each other
* **Heterogeneous tasks**: different operations, different types
* **Nested parallelism**: recursive algorithms that spawn subtasks

### Not Ideal For

* **Many small independent tasks**: use `parallelFor` instead
* **Sequential dependencies**: one task needs another's result
* **Very unbalanced workloads**: one task much larger than others
* **Single elements**: overhead exceeds benefit

## Fork-Join vs Other APIs

| Use Case | Best Choice | Why |
|----------|-------------|-----|
| Process array elements | `iter().forEach()` | Optimized for data parallelism |
| Sum/min/max array | `iter().sum()` | Parallel reduction |
| Two independent tasks | `join(.{...})` | Named results |
| Recursive tree structure | `join(.{...})` | Natural recursion |
| Transform elements | `iterMut().mapInPlace()` | In-place, parallel |
| Search for element | `iter().findAny()` | Early exit |

## Performance Characteristics

| Operation | Typical Time | Notes |
|-----------|-------------|-------|
| Fork (push to deque) | ~3 ns | Wait-free |
| Join (local, not stolen) | ~5 ns | Pop from deque |
| Join (stolen, complete) | ~3 ns | Latch check only |
| Join (stolen, waiting) | ~10-50 ns | Work-stealing while waiting |
| Full fork-join cycle | ~10-20 ns | Amortized |

```
Fork-Join Scaling (10 workers, fib(n)):
┌──────────────────────────────────────────┐
│ Depth 10:  10.54 ms (1M forks)           │
│ Depth 15:   1.29 ms                      │
│ Depth 20:   0.54 ms (1M forks)           │
│ Scaling:    2.4x per 5 depth levels      │
└──────────────────────────────────────────┘
```

## Common Patterns

### Pattern 1: Binary Split

```zig
fn process(data: []T) Result {
    if (data.len < threshold) return processSeq(data);
    const mid = data.len / 2;
    const r = blitz.join(.{
        .left = .{ process, data[0..mid] },
        .right = .{ process, data[mid..] },
    });
    return combine(r.left, r.right);
}
```

### Pattern 2: Multiple Operations on Same Data

```zig
const stats = blitz.join(.{
    .sum = .{ computeSum, data },
    .variance = .{ computeVariance, data },
    .histogram = .{ computeHistogram, data },
});
```

### Pattern 3: Pipeline Stages

```zig
// Stage 1: Load in parallel
const r1 = blitz.join(.{
    .a = .{ loadFile, "data1.bin" },
    .b = .{ loadFile, "data2.bin" },
});

// Stage 2: Process in parallel
const r2 = blitz.join(.{
    .a = .{ process, r1.a },
    .b = .{ process, r1.b },
});

// Stage 3: Combine
const final = merge(r2.a, r2.b);
```

## Limitations

1. **Stack-allocated futures**: Deep recursion can overflow stack
2. **No cancellation**: Once forked, tasks run to completion
3. **No priority**: All tasks have equal priority
4. **Fixed parallelism**: Can't dynamically adjust task count

## Related APIs

* **[Error Handling](/v1.0.0-zig0.15.2/usage/error-handling/)** — Use `tryJoin()` when your tasks return error unions. All tasks complete before errors propagate.
* **[Scope & Broadcast](/v1.0.0-zig0.15.2/usage/scope-broadcast/)** — Use `scope()` for dynamic task spawning (up to 64 tasks) and `broadcast()` to run on all workers.
* **[Choosing the Right API](/v1.0.0-zig0.15.2/guides/choosing-api/)** — Decision guide for when to use `join()` vs `parallelFor` vs iterators.

## Best Practices

1. **Always set sequential thresholds** in recursive code
2. **Name fields meaningfully**: `.left`/`.right`, `.sum`/`.count`, etc.
3. **Keep tasks balanced**: Similar work in each branch
4. **Measure before optimizing**: Profile to find the right threshold
5. **Use iterators for data parallelism**: Fork-join is for task parallelism
