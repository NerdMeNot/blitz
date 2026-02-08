---
title: Internal API Reference
description: Low-level utilities and internal modules
sidebar:
  order: 4
slug: 1.0.0-zig0.15.2/api/internal-api
---

Low-level utilities and internal modules.

## Threshold Module

`internal/threshold.zig` - Parallelism decision heuristics.

### `OpType` enum

Operation types for threshold calculation:

```zig
pub const OpType = enum {
    // Aggregations
    sum,
    min,
    max,
    product,
    mean,

    // Arithmetic
    add,
    sub,
    mul,
    div,

    // Transformations
    transform,
    filter,
    map,

    // Complex
    sort,
    scan,
    reduce,
    find,
};
```

### `shouldParallelize(op, len) bool`

Determine if parallelization is beneficial.

```zig
const internal = blitz.internal;

if (internal.shouldParallelize(.sum, data.len)) {
    // Use parallel path
}
```

### `isMemoryBound(op) bool`

Check if operation is memory-bandwidth limited.

```zig
if (internal.isMemoryBound(.add)) {
    // May not scale linearly with cores
}
```

### `getThreshold(op) usize`

Get minimum data size for parallelization.

```zig
const min_size = internal.getThreshold(.sum);
```

### `costPerElement(op) usize`

Approximate cycles per element for operation.

***

## Splitter Module

`internal/splitter.zig` - Adaptive work splitting.

### `Splitter`

Tracks remaining work splits.

```zig
pub const Splitter = struct {
    splits: u32,

    pub fn init(num_workers: u32) Splitter;
    pub fn trySplit(self: *Splitter) bool;
    pub fn clone(self: *Splitter) Splitter;
};
```

**Usage:**

```zig
var splitter = Splitter.init(blitz.numWorkers());

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

Length-aware splitter for better balance.

```zig
pub const LengthSplitter = struct {
    inner: Splitter,
    min_length: usize,

    pub fn init(num_workers: u32, min_len: usize) LengthSplitter;
    pub fn trySplit(self: *LengthSplitter, current_len: usize) bool;
};
```

***

## RNG Module

`internal/rng.zig` - Fast random number generation.

### `XorShift64Star`

XorShift64\* PRNG with Lemire's fast bounded.

```zig
pub const XorShift64Star = struct {
    state: u64,

    pub fn init(seed: u64) XorShift64Star;
    pub fn next(self: *XorShift64Star) u64;
    pub fn bounded(self: *XorShift64Star, bound: u64) u64;
};
```

**Used for:**

* Work stealing victim selection
* PDQSort pivot randomization
* Pattern breaking in sort

**Example:**

```zig
var rng = XorShift64Star.init(12345);
const victim = rng.bounded(num_workers);  // 0 <= victim < num_workers
```

***

## Job Module

`job.zig` - Minimal job representation.

### `Job`

8-byte job structure stored in deque.

```zig
pub const Job = struct {
    data: u64,  // Encodes function pointer + state

    pub fn init(comptime func: anytype, arg: anytype) Job;
    pub fn execute(self: Job) void;
};
```

***

## Latch Module

`latch.zig` - Synchronization primitives.

### `OnceLatch`

Single-fire latch for one-time synchronization.

```zig
pub const OnceLatch = struct {
    pub fn init() OnceLatch;
    pub fn set(self: *OnceLatch) void;
    pub fn wait(self: *OnceLatch) void;
    pub fn isSet(self: *OnceLatch) bool;
};
```

### `CountLatch`

Countdown latch for waiting on N completions.

```zig
pub const CountLatch = struct {
    pub fn init(count: u32) CountLatch;
    pub fn decrement(self: *CountLatch) void;
    pub fn wait(self: *CountLatch) void;
};
```

### `SpinWait`

Adaptive spinning with backoff.

```zig
pub const SpinWait = struct {
    pub fn init() SpinWait;
    pub fn spin(self: *SpinWait) void;
    pub fn reset(self: *SpinWait) void;
    pub fn shouldYield(self: *SpinWait) bool;
};
```

***

## Deque Module

`deque.zig` - Chase-Lev work-stealing deque.

### `Deque(T)`

Lock-free double-ended queue.

```zig
pub fn Deque(comptime T: type) type {
    return struct {
        pub fn init(allocator: Allocator) !@This();
        pub fn deinit(self: *@This()) void;

        // Owner operations (thread-safe with self only)
        pub fn push(self: *@This(), item: T) void;
        pub fn pop(self: *@This()) ?T;

        // Thief operations (thread-safe with multiple thieves)
        pub fn steal(self: *@This()) ?T;

        pub fn len(self: *@This()) usize;
        pub fn isEmpty(self: *@This()) bool;
    };
}
```

**Guarantees:**

* `push`/`pop`: Wait-free (owner only)
* `steal`: Lock-free (may fail under contention)
* No ABA problem (uses array + indices)

***

## Future Module

`future.zig` - Fork-join with return values.

### `Future(Input, Output)`

Typed future for async computation.

```zig
pub fn Future(comptime Input: type, comptime Output: type) type {
    return struct {
        pub fn init() @This();
        pub fn fork(self: *@This(), task: *Task, func: anytype, input: Input) void;
        pub fn join(self: *@This(), task: *Task) ?Output;
    };
}
```

**Usage:**

```zig
var future = Future(u64, u64).init();
future.fork(task, computeFn, input);

// ... do other work ...

const result = future.join(task) orelse computeFn(task, input);
```

***

## Worker Module

`worker.zig` - Worker thread implementation.

### `Worker`

Individual worker with deque and RNG.

```zig
pub const Worker = struct {
    deque: Deque(Job),
    rng: XorShift64Star,
    pool: *ThreadPool,

    pub fn run(self: *Worker) void;
    pub fn steal(self: *Worker) ?Job;
};
```

### `Task`

Context passed to parallel bodies.

```zig
pub const Task = struct {
    worker: *Worker,

    pub fn tick(self: *Task) void;
    pub fn call(self: *Task, comptime T: type, func: anytype, arg: anytype) T;
};
```
