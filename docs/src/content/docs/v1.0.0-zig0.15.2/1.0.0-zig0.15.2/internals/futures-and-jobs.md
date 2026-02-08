---
title: Futures and Jobs
description: Internal implementation of fork-join primitives.
slug: v1.0.0-zig0.15.2/1.0.0-zig0.15.2/internals/futures-and-jobs
---

## Job Structure

A job is the minimal unit of work in the system:

```zig
pub const Job = struct {
    /// Function to execute
    func: *const fn(*anyopaque) void,

    /// Context/argument pointer
    context: *anyopaque,

    pub fn execute(self: Job) void {
        self.func(self.context);
    }
};
```

**Size**: 16 bytes (two pointers)

### Job Creation

Jobs are created from typed functions:

```zig
pub fn createJob(
    comptime func: fn(Arg) Ret,
    arg: Arg,
    result_ptr: *Ret,
    latch: *OnceLatch,
) Job {
    const Context = struct {
        arg: Arg,
        result: *Ret,
        latch: *OnceLatch,

        fn wrapper(ctx: *@This()) void {
            ctx.result.* = func(ctx.arg);
            ctx.latch.set();
        }
    };

    return Job{
        .func = @ptrCast(&Context.wrapper),
        .context = @ptrCast(&context_storage),
    };
}
```

## Future Structure

A future represents an asynchronous computation:

```zig
pub fn Future(comptime Input: type, comptime Output: type) type {
    return struct {
        const Self = @This();

        /// Storage for the result
        result: Output = undefined,

        /// Synchronization latch
        latch: OnceLatch = OnceLatch.init(),

        /// The job (if forked)
        job: Job = undefined,

        /// Was this future forked?
        forked: bool = false,
    };
}
```

## Fork Operation

Fork pushes a job to the deque:

```zig
pub fn fork(
    self: *Self,
    task: *Task,
    comptime func: fn(Input) Output,
    input: Input,
) void {
    // Store input for later execution
    self.input = input;
    self.forked = true;

    // Create job
    self.job = Job{
        .func = @ptrCast(&executeWrapper),
        .context = @ptrCast(self),
    };

    // Push to worker's deque
    task.worker.deque.push(self.job);

    // Wake an idle worker (if any)
    task.worker.pool.wakeOne();
}

fn executeWrapper(self: *Self) void {
    self.result = func(self.input);
    self.latch.set();
}
```

## Join Operation

Join retrieves the result, doing useful work while waiting:

```zig
pub fn join(self: *Self, task: *Task) ?Output {
    if (!self.forked) {
        // Never forked - no result
        return null;
    }

    // Check if already complete
    if (self.latch.isSet()) {
        return self.result;
    }

    // Try to pop our job (maybe it wasn't stolen)
    if (task.worker.deque.pop()) |job| {
        if (@ptrCast(job.context) == @ptrCast(self)) {
            // Got our own job back - execute locally
            job.execute();
            return self.result;
        } else {
            // Got a different job - execute it, keep waiting
            job.execute();
        }
    }

    // Our job was stolen - wait while doing useful work
    while (!self.latch.isSet()) {
        // Try to steal and execute other work
        if (task.worker.trySteal()) |stolen_job| {
            stolen_job.execute();
        } else {
            // No work available - spin/yield
            std.atomic.spinLoopHint();
        }
    }

    return self.result;
}
```

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
        |                         set latch
        v
t5      join()
        | latch is set!
        | read result
        v
t6      return [resultA, resultB]
```

## Stack Allocation Pattern

Futures are designed to be stack-allocated:

```zig
fn parallelCompute(data: []i64) i64 {
    if (data.len <= threshold) {
        return sequentialCompute(data);
    }

    // Future on stack - no heap allocation!
    var future: Future([]i64, i64) = .{};

    // Fork right half
    future.fork(task, parallelCompute, data[data.len/2..]);

    // Compute left half locally
    const left_result = parallelCompute(data[0..data.len/2]);

    // Join (wait for right half)
    const right_result = future.join(task) orelse
        parallelCompute(data[data.len/2..]);

    return left_result + right_result;
}
```

**Key insight**: The future lives in the caller's stack frame, which remains valid until `join()` returns.

## Latch Implementation

The `OnceLatch` provides one-shot synchronization:

```zig
pub const OnceLatch = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const UNSET: u32 = 0;
    const SET: u32 = 1;

    pub fn init() OnceLatch {
        return .{};
    }

    pub fn set(self: *OnceLatch) void {
        const prev = self.state.swap(SET, .release);
        if (prev == UNSET) {
            // Wake any waiters
            std.os.futex_wake(@ptrCast(&self.state), std.math.maxInt(u32));
        }
    }

    pub fn isSet(self: *OnceLatch) bool {
        return self.state.load(.acquire) == SET;
    }

    pub fn wait(self: *OnceLatch) void {
        while (self.state.load(.acquire) != SET) {
            std.os.futex_wait(@ptrCast(&self.state), UNSET, null);
        }
    }
};
```

## Join with Void Return

For functions that don't return values:

```zig
pub fn joinVoid(
    comptime fnA: fn(ArgA) void,
    comptime fnB: fn(ArgB) void,
    argA: ArgA,
    argB: ArgB,
) void {
    var latch = CountLatch.init(2);

    // Fork B
    var job_b = Job.create(fnB, argB, &latch);
    task.worker.deque.push(job_b);
    task.worker.pool.wakeOne();

    // Execute A
    fnA(argA);
    latch.decrement();

    // Wait for B (while doing useful work)
    while (!latch.isDone()) {
        if (task.worker.trySteal()) |job| {
            job.execute();
        }
    }
}
```

## Performance Characteristics

| Operation | Typical Time | Notes |
|-----------|-------------|-------|
| Future init | ~1 ns | Stack allocation |
| fork() | ~3-5 ns | Deque push + wake |
| join() (not stolen) | ~3 ns | Deque pop |
| join() (stolen) | ~10-100 ns | Wait + steal loop |
| Latch set | ~5 ns | Atomic + futex wake |
| Latch check | ~1 ns | Atomic load |

## Memory Ordering

Critical orderings in the fork-join protocol:

```zig
// Fork: ensure data is visible before job
self.input = input;                          // Store input
@fence(.release);                            // Ensure visibility
task.worker.deque.push(self.job);            // Make job available

// Join: ensure we see the result after latch
while (!self.latch.isSet()) { ... }          // Acquire via latch
@fence(.acquire);                            // Ensure visibility
return self.result;                          // Read result
```
