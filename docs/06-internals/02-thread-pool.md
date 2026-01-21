# Thread Pool

Internal thread pool implementation details.

## Overview

The thread pool manages a fixed set of worker threads that execute parallel work through work stealing.

## Structure

```zig
pub const ThreadPool = struct {
    /// Worker threads
    workers: [MAX_WORKERS]Worker,
    worker_count: u32,

    /// OS threads
    threads: []std.Thread,

    /// Coordination
    idle_count: std.atomic.Value(u32),
    shutdown: std.atomic.Value(bool),

    /// Global work injection
    injector: Deque(Job),
};
```

## Initialization

```zig
pub fn init(config: Config) !*ThreadPool {
    const pool = &global_pool;

    // Determine worker count
    const cpu_count = std.Thread.getCpuCount() catch 4;
    pool.worker_count = config.background_worker_count orelse cpu_count;

    // Initialize workers
    for (pool.workers[0..pool.worker_count], 0..) |*worker, i| {
        worker.* = Worker.init(pool, i);
    }

    // Spawn background threads (main thread is worker 0)
    pool.threads = try allocator.alloc(std.Thread, pool.worker_count - 1);
    for (pool.threads, 1..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&pool.workers[i]});
    }

    return pool;
}
```

## Work Injection

External threads inject work via the injector deque:

```zig
pub fn inject(pool: *ThreadPool, job: Job) void {
    pool.injector.push(job);
    pool.wakeOne();  // Wake an idle worker
}
```

Workers check the injector when their local deques are empty:

```zig
fn findWork(self: *Worker) ?Job {
    // 1. Try local deque first (fastest)
    if (self.deque.pop()) |job| return job;

    // 2. Try stealing from random victim
    if (self.tryStealFromVictim()) |job| return job;

    // 3. Try global injector (last resort)
    if (self.pool.injector.steal()) |job| return job;

    return null;
}
```

## Sleep/Wake Mechanism

### Going to Sleep

```zig
fn waitForWork(self: *Worker) void {
    var spin_count: u32 = 0;

    while (true) {
        // Try to find work
        if (self.findWork()) |job| {
            job.execute();
            spin_count = 0;
            continue;
        }

        // Progressive backoff
        spin_count += 1;

        if (spin_count < SPIN_LIMIT) {
            // Spin (CPU hint to reduce power)
            std.atomic.spinLoopHint();
        } else if (spin_count < YIELD_LIMIT) {
            // Yield to OS scheduler
            std.Thread.yield();
        } else {
            // Sleep on futex
            self.sleep();
            spin_count = 0;
        }
    }
}

fn sleep(self: *Worker) void {
    // Increment idle count
    const prev = self.pool.idle_count.fetchAdd(1, .release);

    // Check for new work one more time
    if (self.findWork()) |job| {
        _ = self.pool.idle_count.fetchSub(1, .acquire);
        job.execute();
        return;
    }

    // Actually sleep
    std.os.futex_wait(
        @ptrCast(&self.pool.idle_count),
        prev + 1,
        null,  // No timeout
    );

    _ = self.pool.idle_count.fetchSub(1, .acquire);
}
```

### Waking Workers

```zig
fn wakeOne(pool: *ThreadPool) void {
    // Only wake if there are sleeping workers
    if (pool.idle_count.load(.acquire) > 0) {
        std.os.futex_wake(
            @ptrCast(&pool.idle_count),
            1,  // Wake one worker
        );
    }
}

fn wakeAll(pool: *ThreadPool) void {
    const idle = pool.idle_count.load(.acquire);
    if (idle > 0) {
        std.os.futex_wake(
            @ptrCast(&pool.idle_count),
            idle,  // Wake all idle workers
        );
    }
}
```

## Shutdown

```zig
pub fn deinit(pool: *ThreadPool) void {
    // Signal shutdown
    pool.shutdown.store(true, .release);

    // Wake all sleeping workers
    pool.wakeAll();

    // Join all threads
    for (pool.threads) |thread| {
        thread.join();
    }

    // Cleanup
    for (pool.workers[0..pool.worker_count]) |*worker| {
        worker.deinit();
    }
}
```

Workers check shutdown flag:

```zig
fn run(self: *Worker) void {
    while (!self.pool.shutdown.load(.acquire)) {
        self.waitForWork();
    }
}
```

## Call Interface

External code uses `call` to enter the pool context:

```zig
pub fn call(
    pool: *ThreadPool,
    comptime T: type,
    comptime func: fn(*Task, anytype) T,
    arg: anytype,
) T {
    // Create task for this call
    var task = Task.init(&pool.workers[0]);

    // Execute with task context
    return func(&task, arg);
}
```

Inside `func`, the task can be used for nested parallelism:

```zig
fn computeParallel(task: *Task, data: []i64) i64 {
    if (data.len <= threshold) {
        return sequentialSum(data);
    }

    // Fork subtask
    var future: Future([]i64, i64) = .{};
    future.fork(task, computeParallel, data[data.len/2..]);

    // Compute local half
    const local = computeParallel(task, data[0..data.len/2]);

    // Join
    const remote = future.join(task) orelse computeParallel(task, data[data.len/2..]);

    return local + remote;
}
```

## Thread-Local Optimization

To avoid repeatedly looking up the current worker:

```zig
threadlocal var current_task: ?*Task = null;

pub fn getCurrentTask() ?*Task {
    return current_task;
}

fn run(self: *Worker) void {
    var task = Task.init(self);
    current_task = &task;
    defer current_task = null;

    while (!self.pool.shutdown.load(.acquire)) {
        self.waitForWork();
    }
}
```

This allows nested `join()` calls to use the fast path:

```zig
pub fn join(...) [2]T {
    if (getCurrentTask()) |task| {
        // Already in pool context - use fast path
        return joinWithTask(task, ...);
    } else {
        // External call - enter pool context
        return pool.call(joinWithTask, ...);
    }
}
```

## Configuration

```zig
pub const ThreadPoolConfig = struct {
    /// Number of background worker threads.
    /// null = auto-detect (CPU count - 1)
    background_worker_count: ?u32 = null,

    /// Stack size for worker threads.
    /// null = OS default
    stack_size: ?usize = null,
};
```

## Constants

```zig
/// Maximum supported workers (compile-time array size)
pub const MAX_WORKERS: u32 = 128;

/// Spin iterations before yielding
const SPIN_LIMIT: u32 = 64;

/// Yield iterations before sleeping
const YIELD_LIMIT: u32 = 128;
```
