# Adaptive Splitting

Intelligent work division for optimal parallelism.

## The Problem

How do we divide work among parallel tasks?

### Too Few Splits

```
4 workers, 2 splits:

[==========Task A==========][==========Task B==========]
     Worker 0                      Worker 1
     Workers 2,3 idle!

Poor utilization: 50%
```

### Too Many Splits

```
4 workers, 1000 splits:

[T1][T2][T3][T4]...[T1000]

Each task: fork overhead + execution
Fork overhead dominates for small tasks!
```

### Just Right

```
4 workers, ~16 splits (4x oversubscription):

[T1][T2][T3][T4][T5][T6][T7][T8][T9]...

- Enough splits for load balancing
- Each task large enough to amortize overhead
- Work stealing handles stragglers
```

## Blitz's Approach

### Splitter Structure

```zig
pub const Splitter = struct {
    splits: u32,  // Remaining allowed splits

    pub fn init(num_workers: u32) Splitter {
        // Allow 4x oversubscription
        return .{ .splits = num_workers * 4 };
    }

    pub fn trySplit(self: *Splitter) bool {
        if (self.splits == 0) return false;
        self.splits -= 1;
        return true;
    }

    pub fn clone(self: *Splitter) Splitter {
        // Give half the splits to child
        const child_splits = self.splits / 2;
        self.splits -= child_splits;
        return .{ .splits = child_splits };
    }
};
```

### Usage in Recursive Algorithms

```zig
fn parallelMergeSort(data: []i64, splitter: *Splitter) void {
    if (data.len <= SEQUENTIAL_THRESHOLD) {
        sequentialSort(data);
        return;
    }

    if (!splitter.trySplit()) {
        // No more splits allowed - go sequential
        sequentialSort(data);
        return;
    }

    const mid = data.len / 2;
    var child_splitter = splitter.clone();

    // Fork with split tracking
    blitz.joinVoid(
        struct {
            fn left(args: anytype) void {
                parallelMergeSort(args.data, args.splitter);
            }
        }.left,
        struct {
            fn right(args: anytype) void {
                parallelMergeSort(args.data, args.splitter);
            }
        }.right,
        .{ .data = data[0..mid], .splitter = splitter },
        .{ .data = data[mid..], .splitter = &child_splitter },
    );

    merge(data[0..mid], data[mid..]);
}
```

## Length-Aware Splitting

Consider data size when splitting:

```zig
pub const LengthSplitter = struct {
    inner: Splitter,
    min_length: usize,  // Don't split below this

    pub fn init(num_workers: u32, min_len: usize) LengthSplitter {
        return .{
            .inner = Splitter.init(num_workers),
            .min_length = min_len,
        };
    }

    pub fn trySplit(self: *LengthSplitter, current_len: usize) bool {
        // Don't split if chunk is too small
        if (current_len < self.min_length * 2) return false;
        return self.inner.trySplit();
    }
};
```

### Why Minimum Length?

```
Without minimum length:
- Splits: 1M → 500K → 250K → 125K → 62K → 31K → 15K → 8K → 4K → 2K → 1K...
- Many tiny tasks with fork overhead

With minimum length (e.g., 8192):
- Splits: 1M → 500K → 250K → 125K → 62K → 31K → 15K → 8K → STOP
- Reasonable task sizes
```

## Threshold Heuristics

Different operations have different optimal thresholds:

```zig
pub fn getThreshold(op: OpType) usize {
    return switch (op) {
        // Compute-bound: lower threshold (parallelize earlier)
        .transform => 4096,
        .sort => 8192,

        // Memory-bound: higher threshold (need more data)
        .sum => 32768,
        .min, .max => 32768,

        // Mixed
        .filter => 8192,
        .scan => 16384,
    };
}
```

### Operation Cost Model

```zig
pub fn costPerElement(op: OpType) usize {
    return switch (op) {
        .sum, .min, .max => 1,      // Simple arithmetic
        .transform => 10,           // User function call
        .filter => 5,               // Predicate + branch
        .sort => 20,                // Comparisons + swaps
        .scan => 3,                 // Arithmetic + dependency
    };
}
```

## Dynamic Threshold Calculation

Adjust based on runtime conditions:

```zig
pub fn calculateThreshold(
    comptime T: type,
    op: OpType,
    num_workers: u32,
) usize {
    const base = getThreshold(op);
    const element_size = @sizeOf(T);

    // Memory-bound operations scale with bandwidth
    if (isMemoryBound(op)) {
        // Need more data to saturate memory bandwidth
        return base * @max(1, 8 / element_size);
    }

    // Compute-bound scales with worker count
    return base * num_workers / 4;
}
```

## Work Distribution Strategies

### Static Partitioning

```
Simple but inflexible:

Data: [0........25%........50%........75%........100%]
       |  W0  |   |  W1  |   |  W2  |   |  W3  |

Problem: If W2's chunk is harder, others wait idle.
```

### Dynamic Chunking

```
Better balance with smaller chunks:

Data: [chunk1][chunk2][chunk3][chunk4][chunk5][chunk6]...
       W0      W1      W2      W3      W0      W1

Workers grab chunks as they finish.
```

### Work Stealing (Blitz)

```
Best of both worlds:

1. Start with coarse partition
2. Workers steal when idle
3. Stolen work is further split if needed

[====W0====][====W1====][====W2====][====W3====]
                 ↑ steal ↑
         W1 finishes, steals from W2
```

## Parallel For Implementation

```zig
pub fn parallelFor(
    n: usize,
    comptime Context: type,
    ctx: Context,
    comptime body: fn(Context, usize, usize) void,
) void {
    if (n == 0) return;

    const num_workers = numWorkers();
    const threshold = @max(n / (num_workers * 4), 1024);

    if (n <= threshold) {
        // Sequential - not worth parallelizing
        body(ctx, 0, n);
        return;
    }

    // Recursive parallel split
    parallelForImpl(0, n, ctx, body, Splitter.init(num_workers));
}

fn parallelForImpl(
    start: usize,
    end: usize,
    ctx: Context,
    comptime body: fn(Context, usize, usize) void,
    splitter: *Splitter,
) void {
    const len = end - start;

    if (len <= MIN_CHUNK or !splitter.trySplit()) {
        // Execute sequentially
        body(ctx, start, end);
        return;
    }

    const mid = start + len / 2;
    var child = splitter.clone();

    // Fork
    joinVoid(
        parallelForImpl, parallelForImpl,
        .{ start, mid, ctx, body, splitter },
        .{ mid, end, ctx, body, &child },
    );
}
```

## Tuning Guidelines

### When to Increase Threshold

- Memory-bound operations
- High fork/join overhead
- Small element size
- Simple operations (low compute per element)

### When to Decrease Threshold

- Compute-bound operations
- Large element size
- Complex operations (high compute per element)
- Many cores available

### Profiling Approach

```zig
// Benchmark different thresholds
for ([_]usize{ 1024, 2048, 4096, 8192, 16384, 32768 }) |threshold| {
    const start = std.time.nanoTimestamp();

    parallelForWithGrain(data.len, ctx, body, threshold);

    const elapsed = std.time.nanoTimestamp() - start;
    std.debug.print("Threshold {}: {} ms\n", .{ threshold, elapsed / 1_000_000 });
}
```
