---
title: Futures and Jobs
description: Internal implementation of fork-join primitives.
---

## Job Structure

A job is the minimal unit of work in the system, defined in `Pool.zig`:

```zig
pub const Job = struct {
    handler: ?*const fn (*Task, *Job) void = null,

    pub inline fn init() Job {
        return .{};
    }
};
```

**Size**: 8 bytes (single nullable function pointer)

The handler signature takes both a `Task` (providing thread-local context) and a pointer back to the `Job` itself, allowing the handler to navigate to the containing `Future` via `@fieldParentPtr`.

## Future Structure

A future represents a parallel computation, defined in `Future.zig`:

```zig
pub fn Future(comptime Input: type, comptime Output: type) type {
    return struct {
        const Self = @This();

        job: Job,
        latch: OnceLatch,
        input: Input,
        result: Output,

        pub inline fn init() Self { ... }
        pub inline fn fork(self: *Self, task: *Task, comptime func: fn (*Task, Input) Output, input: Input) void { ... }
        pub inline fn join(self: *Self, task: *Task) ?Output { ... }
    };
}
```

**Key design**: The `Job`, `OnceLatch`, `Input`, and `Output` are all embedded directly in the struct — no indirection, no heap allocation. The future lives on the caller's stack frame.

## Fork Operation

Fork pushes a job to the deque:

```zig
pub inline fn fork(
    self: *Self,
    task: *Task,
    comptime func: fn (*Task, Input) Output,
    input: Input,
) void {
    self.input = input;

    // Comptime-specialized handler
    const Handler = struct {
        fn handle(t: *Task, job: *Job) void {
            const future = @fieldParentPtr(Self, "job", job);
            future.result = func(t, future.input);
            future.latch.setDone();
        }
    };

    self.job.handler = Handler.handle;
    task.worker.pushAndWake(&self.job);
}
```

`pushAndWake` pushes the job to the worker's Chase-Lev deque and wakes a sleeping worker if needed.

## Join Operation

Join retrieves the result, doing useful work while waiting:

```zig
pub inline fn join(self: *Self, task: *Task) ?Output {
    // Fast path: already completed by a thief
    if (self.latch.probe()) {
        return self.result;
    }

    // Try to pop our job (maybe it wasn't stolen)
    if (task.worker.pop()) |job| {
        if (job == &self.job) {
            // Got our own job back - execute locally
            return null;  // Caller executes locally instead
        }
        // Got a different job - execute it, keep waiting
        job.handler.?(task, job);
    }

    // Our job was stolen - wait while doing useful work
    while (!self.latch.probe()) {
        if (task.worker.pop()) |job| {
            job.handler.?(task, job);
        } else if (task.worker.stealFromOther()) |job| {
            job.handler.?(task, job);
        } else {
            std.atomic.spinLoopHint();
        }
    }

    return self.result;
}
```

The return type is `?Output`:
- `null` means "your job was still on the deque — execute it locally"
- A value means "a thief executed it — here's the result"

## The Join Pattern

```
Timeline of fork-join:

Time    Owner Thread              Thief Thread
--------------------------------------------
t0      fork(B)
        | push B to deque
        | wake thief
        v
t1      execute A locally         wake up
                                  |
t2      (working on A)            steal B from owner
                                  |
t3      (working on A)            execute B
                                  |
t4      finish A                  finish B
        |                         latch.setDone()
        v
t5      join()
        | latch.probe() == true
        | read result
        v
t6      return [resultA, resultB]
```

## Stack Allocation Pattern

Futures are designed to be stack-allocated:

```zig
fn parallelCompute(task: *Task, data: []i64) i64 {
    if (data.len <= threshold) {
        return sequentialCompute(data);
    }

    // Future on stack - no heap allocation!
    var future: Future([]i64, i64) = .{};

    // Fork right half
    future.fork(task, parallelCompute, data[data.len/2..]);

    // Compute left half locally
    const left_result = parallelCompute(task, data[0..data.len/2]);

    // Join (wait for right half)
    const right_result = future.join(task) orelse
        parallelCompute(task, data[data.len/2..]);

    return left_result + right_result;
}
```

**Key insight**: The future lives in the caller's stack frame, which remains valid until `join()` returns.

## Latch Implementation

The `OnceLatch` provides one-shot synchronization with a 4-state machine (defined in `Latch.zig`):

```zig
pub const OnceLatch = struct {
    const UNSET: u32 = 0;
    const SLEEPY: u32 = 1;
    const SLEEPING: u32 = 2;
    const SET: u32 = 3;

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(UNSET),

    pub fn init() OnceLatch { return .{}; }

    /// Non-blocking check if done
    pub inline fn probe(self: *const OnceLatch) bool {
        return self.state.load(.acquire) == SET;
    }

    /// Alias for probe()
    pub inline fn isDone(self: *const OnceLatch) bool {
        return self.probe();
    }

    /// Mark as done and wake any sleepers
    pub fn setDone(self: *OnceLatch) void {
        const prev = self.state.swap(SET, .release);
        if (prev == SLEEPING) {
            // Wake the waiter
            std.Thread.Futex.wake(@ptrCast(&self.state), 1);
        }
    }

    /// Block until done
    pub fn wait(self: *OnceLatch) void {
        while (self.state.load(.acquire) != SET) {
            if (self.getSleepy()) {
                if (self.fallAsleep()) {
                    std.Thread.Futex.wait(@ptrCast(&self.state), SLEEPING, null);
                }
            }
        }
    }
};
```

The 4-state protocol prevents missed wakes:
1. **UNSET** — initial state
2. **SLEEPY** — announced intent to sleep (can still be cancelled)
3. **SLEEPING** — actually blocking on futex
4. **SET** — done, result available

## VoidFuture

For functions that don't return values, `Future.zig` provides:

```zig
pub const VoidFuture = Future(void, void);
```

## Performance Characteristics

| Operation | Typical Time | Notes |
|-----------|-------------|-------|
| Future init | ~1 ns | Stack allocation |
| fork() | ~3-5 ns | Deque push + conditional wake |
| join() (not stolen) | ~3 ns | Deque pop |
| join() (stolen, done) | ~1 ns | Single probe() |
| join() (stolen, waiting) | ~10-100 ns | Steal loop |
| latch.setDone() | ~5 ns | Atomic swap + conditional futex wake |
| latch.probe() | ~1 ns | Atomic load |

## Memory Ordering

Critical orderings in the fork-join protocol:

```zig
// Fork: ensure data is visible before job
self.input = input;                          // Store input
self.job.handler = Handler.handle;           // Store handler
task.worker.pushAndWake(&self.job);          // Release via deque push

// Join: ensure we see the result after latch
while (!self.latch.probe()) { ... }          // Acquire via probe()
return self.result;                          // Read result
```
