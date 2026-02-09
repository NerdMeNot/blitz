---
title: Synchronization Primitives
description: Lock-free synchronization building blocks used in Blitz.
---

## Overview

Blitz uses several synchronization primitives defined in `Latch.zig` and `Sync.zig`, all designed to be lock-free for the hot path.

## OnceLatch

Single-fire synchronization point with a 4-state machine to prevent missed wakes.

### Use Case
Signal completion of a single task (e.g., a Future result is ready).

### Implementation

```zig
pub const OnceLatch = struct {
    const UNSET: u32 = 0;
    const SLEEPY: u32 = 1;
    const SLEEPING: u32 = 2;
    const SET: u32 = 3;

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(UNSET),

    pub fn init() OnceLatch {
        return .{};
    }

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
            // Waiter is blocked on futex — wake them
            std.Thread.Futex.wake(@ptrCast(&self.state), 1);
        }
    }

    /// Block until done (uses "tickle-then-get-sleepy" pattern)
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

### 4-State Protocol

The 4-state machine prevents a race where a waker sets the latch while the waiter is transitioning to sleep:

```
UNSET (0) ──────────────────────────────── SET (3)
    │                                         ▲
    │ getSleepy() [CAS UNSET→SLEEPY]         │ setDone() [swap→SET]
    ▼                                         │
SLEEPY (1) ────────────────────────────── SET (3)
    │                                         ▲
    │ fallAsleep() [CAS SLEEPY→SLEEPING]     │ setDone() [swap→SET, futex_wake]
    ▼                                         │
SLEEPING (2) ─────────────────────────── SET (3)
    │
    │ wakeUp() [spurious]
    ▼
UNSET (0)
```

**Why 4 states?** Without the SLEEPY intermediate state:

```
Thread A (waiter):          Thread B (setter):
  if (!done) {               setDone();
                              futex_wake();  // A not sleeping yet!
    futex_wait();             // MISSED WAKE — A sleeps forever
```

With SLEEPY state, `setDone()` sees `prev == SLEEPING` and knows to issue a futex wake.

### Usage

```zig
var latch = OnceLatch.init();

// Thread 1: Wait for completion
latch.wait();
// ... proceed after signal

// Thread 2: Signal completion
latch.setDone();
```

Or for non-blocking polling:

```zig
if (latch.probe()) {
    // Result is ready
}
```

## CountLatch

Countdown synchronization point.

### Use Case
Wait for N tasks to complete.

### Implementation

```zig
pub const CountLatch = struct {
    count: std.atomic.Value(u32),

    pub fn init(count: u32) CountLatch {
        return .{ .count = std.atomic.Value(u32).init(count) };
    }

    /// Decrement count, signal if reaching zero
    pub fn decrement(self: *CountLatch) void {
        const prev = self.count.fetchSub(1, .acq_rel);
        if (prev == 1) {
            // Last one - wake waiters
            std.Thread.Futex.wake(@ptrCast(&self.count), std.math.maxInt(u32));
        }
    }

    /// Check if count reached zero
    pub fn isDone(self: *CountLatch) bool {
        return self.count.load(.acquire) == 0;
    }

    /// Block until count reaches zero
    pub fn wait(self: *CountLatch) void {
        while (true) {
            const count = self.count.load(.acquire);
            if (count == 0) return;
            std.Thread.Futex.wait(@ptrCast(&self.count), count, null);
        }
    }
};
```

### Usage

```zig
var latch = CountLatch.init(4);  // Wait for 4 tasks

// Spawn 4 tasks, each calls latch.decrement() on completion
// ...

// Wait for all to complete
latch.wait();
```

## SpinWait

Adaptive spinning with exponential backoff.

### Use Case
Efficient short-term waiting without syscalls.

### Implementation

```zig
pub const SpinWait = struct {
    iteration: u32 = 0,

    const SPIN_LIMIT: u32 = 10;
    const YIELD_LIMIT: u32 = 20;

    pub fn spin(self: *SpinWait) void {
        self.iteration += 1;

        if (self.iteration <= SPIN_LIMIT) {
            // Pure spin with CPU hint (exponential backoff)
            var i: u32 = 0;
            while (i < 1 << @min(self.iteration, 6)) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        } else if (self.iteration <= YIELD_LIMIT) {
            // Yield to other threads
            std.Thread.yield() catch {};
        } else {
            // Sleep briefly
            std.time.sleep(1000);  // 1 microsecond
        }
    }

    pub fn reset(self: *SpinWait) void {
        self.iteration = 0;
    }

    pub fn wouldYield(self: *SpinWait) bool {
        return self.iteration > SPIN_LIMIT;
    }
};
```

### Phases

| Phase | Iterations | Strategy | Latency |
|-------|-----------|----------|---------|
| Spin | 1-10 | `spinLoopHint()` with exponential backoff | ~10-100 ns |
| Yield | 11-20 | `Thread.yield()` | ~1-5 us |
| Sleep | 21+ | `time.sleep(1us)` | ~1 us |

### Usage

```zig
var wait = SpinWait{};

while (!condition()) {
    wait.spin();
}
wait.reset();
```

## SyncPtr

Lock-free pointer for parallel writes to disjoint array regions (defined in `Sync.zig`).

### Use Case
Multiple threads writing to non-overlapping array regions without data races.

### Implementation

```zig
pub fn SyncPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: [*]T,

        pub fn init(slice: []T) Self {
            return .{ .ptr = slice.ptr };
        }

        pub fn fromPtr(ptr: [*]T) Self {
            return .{ .ptr = ptr };
        }

        /// Write to specific offset (thread-safe if offsets are disjoint)
        pub fn writeAt(self: Self, offset: usize, value: T) void {
            self.ptr[offset] = value;
        }

        /// Read from specific offset
        pub fn readAt(self: Self, offset: usize) T {
            return self.ptr[offset];
        }

        /// Get a slice view starting at offset
        pub fn sliceFrom(self: Self, offset: usize, len: usize) []T {
            return (self.ptr + offset)[0..len];
        }

        /// Copy a slice to a specific offset
        pub fn copyAt(self: Self, offset: usize, src: []const T) void {
            @memcpy((self.ptr + offset)[0..src.len], src);
        }
    };
}
```

:::note
SyncPtr does **not** use memory fences internally. Safety is guaranteed by the caller ensuring disjoint access — each thread must write to non-overlapping offsets. This is typically achieved by pre-computing offsets with `computeOffsetsInto()`.
:::

### Usage

```zig
var buffer: [1000]i64 = undefined;
const ptr = SyncPtr(i64).init(&buffer);

// Parallel writes to disjoint regions
blitz.parallelFor(1000, struct {
    ptr: SyncPtr(i64),
}, .{ .ptr = ptr }, struct {
    fn body(ctx: @This(), start: usize, end: usize) void {
        for (start..end) |i| {
            ctx.ptr.writeAt(i, computeValue(i));
        }
    }
}.body);
```

## Memory Ordering Reference

| Ordering | Use Case |
|----------|----------|
| `.relaxed` | Statistics counters |
| `.acquire` | Read side of synchronization |
| `.release` | Write side of synchronization |
| `.acq_rel` | Read-modify-write sync point |
| `.seq_cst` | Total ordering required |

### Common Patterns

```zig
// Producer-consumer
producer:
    data = value;
    @fence(.release);
    flag.store(1, .release);

consumer:
    while (flag.load(.acquire) != 1) {}
    @fence(.acquire);
    use(data);

// Lock-free stack push
new_node.next.store(head.load(.acquire), .relaxed);
while (head.cmpxchgWeak(new_node.next.load(.relaxed), new_node, .release, .relaxed)) |old| {
    new_node.next.store(old, .relaxed);
}
```

## Performance Comparison

| Primitive | Operation | Time |
|-----------|-----------|------|
| OnceLatch | setDone (uncontended) | ~5 ns |
| OnceLatch | probe | ~1 ns |
| OnceLatch | wait (already set) | ~1 ns |
| CountLatch | decrement | ~5 ns |
| SpinWait | spin (first few) | ~10 ns |
| Futex wake | wake one | ~500 ns |
| Futex wait | blocked | ~1 us |
| Mutex lock | uncontended | ~20 ns |
| Mutex lock | contended | ~1-10 us |
