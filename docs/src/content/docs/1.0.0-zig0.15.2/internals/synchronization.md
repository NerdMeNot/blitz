---
title: Synchronization Primitives
description: Lock-free synchronization building blocks.
slug: 1.0.0-zig0.15.2/internals/synchronization
---

## Overview

Blitz uses several synchronization primitives, all designed to be lock-free for the hot path.

## OnceLatch

Single-fire synchronization point.

### Use Case

Signal completion of a single task.

### Implementation

```zig
pub const OnceLatch = struct {
    state: std.atomic.Value(u32),

    const UNSET: u32 = 0;
    const SET: u32 = 1;

    pub fn init() OnceLatch {
        return .{ .state = std.atomic.Value(u32).init(UNSET) };
    }

    /// Signal completion (one-time only)
    pub fn set(self: *OnceLatch) void {
        const prev = self.state.swap(SET, .release);
        if (prev == UNSET) {
            // First to set - wake waiters
            std.os.futex_wake(@ptrCast(&self.state), std.math.maxInt(u32));
        }
    }

    /// Check without blocking
    pub fn isSet(self: *OnceLatch) bool {
        return self.state.load(.acquire) == SET;
    }

    /// Block until set
    pub fn wait(self: *OnceLatch) void {
        while (!self.isSet()) {
            std.os.futex_wait(@ptrCast(&self.state), UNSET, null);
        }
    }
};
```

### Usage

```zig
var latch = OnceLatch.init();

// Thread 1: Wait for completion
latch.wait();
// ... proceed after signal

// Thread 2: Signal completion
latch.set();
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
            std.os.futex_wake(@ptrCast(&self.count), std.math.maxInt(u32));
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
            std.os.futex_wait(@ptrCast(&self.count), count, null);
        }
    }
};
```

### Usage

```zig
var latch = CountLatch.init(4);  // Wait for 4 tasks

// Spawn 4 tasks
for (0..4) |_| {
    spawn(struct {
        fn task(l: *CountLatch) void {
            defer l.decrement();
            doWork();
        }
    }.task, &latch);
}

// Wait for all to complete
latch.wait();
```

## SpinWait

Adaptive spinning with backoff.

### Use Case

Efficient short-term waiting without syscalls.

### Implementation

```zig
pub const SpinWait = struct {
    count: u32 = 0,

    const SPIN_LIMIT: u32 = 10;
    const YIELD_LIMIT: u32 = 20;

    pub fn spin(self: *SpinWait) void {
        self.count += 1;

        if (self.count <= SPIN_LIMIT) {
            // Pure spin with CPU hint
            var i: u32 = 0;
            while (i < 1 << @min(self.count, 6)) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        } else if (self.count <= YIELD_LIMIT) {
            // Yield to other threads
            std.Thread.yield();
        } else {
            // Sleep briefly
            std.time.sleep(1000);  // 1 microsecond
        }
    }

    pub fn reset(self: *SpinWait) void {
        self.count = 0;
    }

    pub fn shouldYield(self: *SpinWait) bool {
        return self.count > SPIN_LIMIT;
    }
};
```

### Usage

```zig
var wait = SpinWait{};

while (!condition()) {
    wait.spin();
}
wait.reset();
```

## SyncPtr

Lock-free pointer for parallel writes to disjoint regions.

### Use Case

Multiple threads writing to non-overlapping array regions.

### Implementation

```zig
pub fn SyncPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: [*]T,

        pub fn init(slice: []T) Self {
            return .{ .ptr = slice.ptr };
        }

        /// Write to specific index (thread-safe if indices are disjoint)
        pub fn writeAt(self: Self, index: usize, value: T) void {
            @fence(.release);
            self.ptr[index] = value;
        }

        /// Read from specific index
        pub fn readAt(self: Self, index: usize) T {
            const value = self.ptr[index];
            @fence(.acquire);
            return value;
        }
    };
}
```

### Usage

```zig
var buffer: [1000]i64 = undefined;
const ptr = SyncPtr(i64).init(&buffer);

// Parallel writes to disjoint regions
blitz.parallelFor(10, struct {
    ptr: SyncPtr(i64),
}, .{ .ptr = ptr }, struct {
    fn body(ctx: @This(), start: usize, end: usize) void {
        for (start..end) |i| {
            ctx.ptr.writeAt(i * 100, computeValue(i));
        }
    }
}.body);
```

## Futex Operations

Low-level futex wrapper for Linux/macOS:

```zig
pub fn futex_wait(ptr: *const u32, expected: u32, timeout: ?u64) void {
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.futex(
            @ptrCast(ptr),
            std.os.linux.FUTEX.WAIT | std.os.linux.FUTEX.PRIVATE_FLAG,
            expected,
            @ptrCast(timeout),
            null,
            0,
        );
    } else if (@import("builtin").os.tag == .macos) {
        // macOS uses __ulock_wait
        darwin.__ulock_wait(
            darwin.UL_COMPARE_AND_WAIT,
            @ptrCast(ptr),
            expected,
            timeout orelse 0,
        );
    }
}

pub fn futex_wake(ptr: *const u32, count: u32) void {
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.futex(
            @ptrCast(ptr),
            std.os.linux.FUTEX.WAKE | std.os.linux.FUTEX.PRIVATE_FLAG,
            count,
            null,
            null,
            0,
        );
    } else if (@import("builtin").os.tag == .macos) {
        darwin.__ulock_wake(
            darwin.UL_COMPARE_AND_WAIT,
            @ptrCast(ptr),
            0,
        );
    }
}
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
| OnceLatch | set (uncontended) | ~5 ns |
| OnceLatch | isSet | ~1 ns |
| OnceLatch | wait (already set) | ~1 ns |
| CountLatch | decrement | ~5 ns |
| SpinWait | spin (first few) | ~10 ns |
| Futex wake | wake one | ~500 ns |
| Futex wait | blocked | ~1 us |
| Mutex lock | uncontended | ~20 ns |
| Mutex lock | contended | ~1-10 us |
