# Fork-Join

Execute two tasks potentially in parallel and collect results.

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

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    const results = blitz.join(
        u64,        // Return type A
        u64,        // Return type B
        computeA,   // Function A
        computeB,   // Function B
        1_000_000,  // Argument for A
        1_000_000,  // Argument for B
    );

    // results[0] = computeA(1_000_000)
    // results[1] = computeB(1_000_000)
    const total = results[0] + results[1];
}
```

## How It Works

```
┌─────────────────────────────────────────────────┐
│                  join(A, B)                     │
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
│  4. Return [resultA, resultB]                   │
│                                                 │
└─────────────────────────────────────────────────┘
```

## Void Functions

For functions that don't return values:

```zig
blitz.joinVoid(
    processChunkA,  // fn(ArgA) void
    processChunkB,  // fn(ArgB) void
    chunkA,
    chunkB,
);
// Both complete before returning
```

## Different Argument Types

```zig
fn processStrings(strings: []const []const u8) usize {
    return strings.len;
}

fn processNumbers(numbers: []const i64) i64 {
    var sum: i64 = 0;
    for (numbers) |n| sum += n;
    return sum;
}

const results = blitz.join(
    usize,          // Return type A
    i64,            // Return type B
    processStrings,
    processNumbers,
    strings,        // []const []const u8
    numbers,        // []const i64
);
```

## Recursive Fork-Join (Divide and Conquer)

Classic parallel fibonacci:

```zig
fn fibPar(n: u64) u64 {
    // Base case: don't parallelize small subproblems
    if (n <= 20) return fibSeq(n);

    // Fork fib(n-1), execute fib(n-2) locally
    const results = blitz.join(u64, u64, fibPar, fibPar, n - 1, n - 2);
    return results[0] + results[1];
}

fn fibSeq(n: u64) u64 {
    if (n <= 1) return n;
    return fibSeq(n - 1) + fibSeq(n - 2);
}
```

**Performance (fib(40) on 10 cores):**
- Sequential: 635 ms
- Parallel: 93 ms
- Speedup: 6.9x

## Parallel Merge Sort

```zig
fn parallelMergeSort(data: []i64, temp: []i64) void {
    if (data.len <= 1024) {
        // Sequential for small arrays
        std.mem.sort(i64, data, {}, std.sort.asc(i64));
        return;
    }

    const mid = data.len / 2;

    // Sort halves in parallel
    blitz.joinVoid(
        struct {
            fn sortLeft(args: struct { d: []i64, t: []i64 }) void {
                parallelMergeSort(args.d, args.t);
            }
        }.sortLeft,
        struct {
            fn sortRight(args: struct { d: []i64, t: []i64 }) void {
                parallelMergeSort(args.d, args.t);
            }
        }.sortRight,
        .{ .d = data[0..mid], .t = temp[0..mid] },
        .{ .d = data[mid..], .t = temp[mid..] },
    );

    // Merge (could also parallelize this)
    merge(data[0..mid], data[mid..], temp);
    @memcpy(data, temp);
}
```

## Multiple Tasks (join2, join3, joinN)

```zig
// Two tasks (same as join)
const r2 = blitz.join2(T1, T2, fn1, fn2);

// Three tasks
const r3 = blitz.join3(T1, T2, T3, fn1, fn2, fn3);

// N tasks (all same return type)
const funcs = [_]fn() i64{ task1, task2, task3, task4 };
const results = blitz.joinN(i64, 4, &funcs);
```

## When to Use Fork-Join

**Good for:**
- Recursive divide-and-conquer (sort, fibonacci, tree traversal)
- Two independent computations
- When result of one doesn't depend on other

**Not ideal for:**
- Many small tasks (use parallelFor instead)
- Sequential dependencies
- Very unbalanced workloads

## Fork-Join vs ParallelFor

| Use Case | Best Choice |
|----------|-------------|
| Process array elements | parallelFor |
| Two independent tasks | join |
| Recursive tree structure | join |
| N homogeneous chunks | parallelFor |
| N heterogeneous tasks | joinN |

## Performance Characteristics

- **Fork overhead**: ~1-10 ns (lock-free)
- **Join overhead**: ~1-10 ns if not stolen, ~50 ns if stolen
- **Scaling**: Near-linear for compute-bound work

```
Fork-Join Performance (10 workers):
┌────────────────────────────────────┐
│ Depth 20, 2M forks: 0.54 ns/fork   │
│ Parallel fib(45): 6.9x speedup     │
│ Recursive sort 10M: 8x speedup     │
└────────────────────────────────────┘
```
