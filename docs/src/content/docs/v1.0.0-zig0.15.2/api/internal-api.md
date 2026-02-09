---
title: Internal API Reference
description: Low-level utilities and internal modules
sidebar:
  order: 4
---

Low-level utilities and internal modules. These are not part of the public API (`api.zig`) and may change between versions.

## Threshold Module

`internal/threshold.zig` — Parallelism decision heuristics.

### `OpType` enum

Operation types for threshold calculation:

```zig
pub const OpType = enum {
    // Aggregations
    sum, min, max, product, mean,
    // Arithmetic
    add, sub, mul, div,
    // Transformations
    transform, filter, map,
    // Misc
    compare, hash,
    // Complex
    sort, scan, reduce, find,
};
```

### `shouldParallelize(op, len) bool`

Determine if parallelization is beneficial for the given operation and data size.

```zig
const threshold = @import("internal/threshold.zig");

if (threshold.shouldParallelize(.sum, data.len)) {
    // Use parallel path
}
```

:::note
This function is not exported via the public `api.zig` module. It's available internally via `blitz.zig` for testing and benchmarking. For application code, use `data.len >= blitz.DEFAULT_GRAIN_SIZE` as a simpler threshold check.
:::

### `isMemoryBound(op) bool`

Check if operation is memory-bandwidth limited.

### `getThreshold(op) usize`

Get minimum data size for parallelization.

### `costPerElement(op) usize`

Approximate cycles per element for operation.

---

## Splitter Module

`internal/Splitter.zig` — Adaptive work splitting.

### `Splitter`

Adaptive splitter using Rayon-style thief-splitting heuristics.

```zig
pub const Splitter = struct {
    splits: usize,
    initial_splits: usize,

    pub fn init() Splitter;                              // Auto-detects worker count
    pub fn initWithSplits(splits: usize) Splitter;       // Custom split count
    pub fn trySplit(self: *Splitter) bool;                // Halves remaining splits
    pub fn trySplitWithHint(self: *Splitter, migrated: bool) bool;  // Thief-aware
    pub fn shouldSplit(self: *const Splitter) bool;       // Lookahead (non-consuming)
    pub fn remaining(self: *const Splitter) usize;
    pub fn clone(self: *const Splitter) Splitter;
};
```

**Usage:**
```zig
var splitter = Splitter.init();  // Starts with num_workers splits

// In recursive algorithm:
if (splitter.trySplit()) {
    // Worth splitting - fork subtask
    var child = splitter.clone();
    // ... fork with child splitter
} else {
    // Don't split - process sequentially
}
```

### `LengthSplitter`

Length-aware splitter that considers both parallelism and data size.

```zig
pub const LengthSplitter = struct {
    inner: Splitter,
    min_len: usize,

    pub const DEFAULT_MIN_LEN: usize = 1;
    pub const DEFAULT_MAX_LEN: usize = 8192;

    pub fn init(len: usize, min_len: usize, max_len: usize) LengthSplitter;
    pub fn initDefault(len: usize) LengthSplitter;        // Uses DEFAULT_MIN/MAX_LEN
    pub fn initWithMin(len: usize, min_len: usize) LengthSplitter;
    pub fn trySplit(self: *LengthSplitter, len: usize) bool;
    pub fn trySplitWithHint(self: *LengthSplitter, len: usize, migrated: bool) bool;
};
```

---

## RNG Module

`internal/Rng.zig` — Fast random number generation.

### `XorShift64Star`

XorShift64* PRNG with Lemire's fast bounded.

```zig
pub const XorShift64Star = struct {
    state: u64,

    pub fn init(seed: u64) XorShift64Star;
    pub fn initFromThread() XorShift64Star;          // Per-thread unique seed
    pub fn initFromIndex(idx: usize) XorShift64Star; // Deterministic per-worker seed
    pub fn next(self: *XorShift64Star) u64;
    pub fn nextBounded(self: *XorShift64Star, n: usize) usize;  // [0, n) via Lemire's method
    pub fn nextExcluding(self: *XorShift64Star, n: usize, exclude: usize) usize;
};
```

**Used for:**
- Work stealing victim selection
- PDQSort pivot randomization
- Pattern breaking in sort

---

## Job (Pool.zig)

Minimal job struct — the unit of work in the deque.

```zig
pub const Job = struct {
    handler: ?*const fn (*Task, *Job) void = null,

    pub inline fn init() Job {
        return .{};
    }
};
```

**Size**: 8 bytes (single nullable function pointer).

The handler takes `*Task` (thread-local context) and `*Job` (self pointer, used with `@fieldParentPtr` to navigate to the containing `Future`).

---

## Latch Module

`Latch.zig` — Synchronization primitives.

### `OnceLatch`

4-state single-fire latch for one-time synchronization.

```zig
pub const OnceLatch = struct {
    // States: UNSET(0) → SLEEPY(1) → SLEEPING(2) → SET(3)
    pub fn init() OnceLatch;
    pub fn probe(self: *const OnceLatch) bool;    // Non-blocking check
    pub fn isDone(self: *const OnceLatch) bool;    // Alias for probe()
    pub fn setDone(self: *OnceLatch) void;         // Signal completion
    pub fn wait(self: *OnceLatch) void;            // Block until done
};
```

### `CountLatch`

Countdown latch for waiting on N completions.

```zig
pub const CountLatch = struct {
    pub fn init(count: u32) CountLatch;
    pub fn decrement(self: *CountLatch) void;
    pub fn isDone(self: *CountLatch) bool;
    pub fn wait(self: *CountLatch) void;
};
```

### `SpinWait`

Adaptive spinning with exponential backoff.

```zig
pub const SpinWait = struct {
    iteration: u32 = 0,

    const SPIN_LIMIT: u32 = 10;
    const YIELD_LIMIT: u32 = 20;

    pub fn spin(self: *SpinWait) void;
    pub fn reset(self: *SpinWait) void;
    pub fn wouldYield(self: *SpinWait) bool;
};
```

---

## Deque Module

`Deque.zig` — Chase-Lev work-stealing deque.

### `Deque(T)`

Lock-free double-ended queue with cache-line aligned fields.

```zig
pub fn Deque(comptime T: type) type {
    return struct {
        pub fn init(alloc: Allocator, capacity: usize) !@This();
        pub fn deinit(self: *@This()) void;

        // Owner operations (single-thread only)
        pub fn push(self: *@This(), item: T) void;
        pub fn pop(self: *@This()) ?T;

        // Thief operations (multi-thread safe)
        pub fn steal(self: *@This()) struct { result: StealResult, item: ?T };
        pub fn stealLoop(self: *@This()) ?T;  // steal with retry + backoff

        pub fn len(self: *const @This()) usize;
        pub fn isEmpty(self: *const @This()) bool;
    };
}

pub const StealResult = enum { empty, success, retry };
```

**Guarantees:**
- `push`/`pop`: Wait-free (owner only)
- `steal`: Lock-free (returns `retry` on contention)
- `stealLoop`: Lock-free with exponential backoff
- No ABA problem (uses circular array + monotonic indices)

---

## Future Module

`Future.zig` — Stack-allocated fork-join with return values.

### `Future(Input, Output)`

Typed future for parallel computation.

```zig
pub fn Future(comptime Input: type, comptime Output: type) type {
    return struct {
        job: Job,
        latch: OnceLatch,
        input: Input,
        result: Output,

        pub fn init() @This();
        pub fn fork(self: *@This(), task: *Task, comptime func: fn (*Task, Input) Output, input: Input) void;
        pub fn join(self: *@This(), task: *Task) ?Output;
    };
}

pub const VoidFuture = Future(void, void);
```

**Usage:**
```zig
var future = Future(u64, u64).init();
future.fork(task, computeFn, input);

// ... do other work ...

const result = future.join(task) orelse computeFn(task, input);
```

---

## Worker & Task (Pool.zig)

### `Worker`

Individual worker with deque and RNG.

```zig
pub const Worker = struct {
    pool: *ThreadPool,
    id: u32,
    deque: ?Deque(*Job),
    rng: XorShift64Star,
    latch: CoreLatch,
    stats: WorkerStats,
};

pub const WorkerStats = struct {
    jobs_executed: u64 = 0,
    jobs_stolen: u64 = 0,
};
```

### `Task`

Context passed to job handlers — provides access to the worker and pool.

```zig
pub const Task = struct {
    worker: *Worker,
};
```
