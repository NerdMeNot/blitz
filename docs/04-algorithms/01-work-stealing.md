# Work Stealing Algorithm

The core scheduling algorithm that makes Blitz efficient.

## Overview

Work stealing is a dynamic load-balancing technique where idle workers "steal" tasks from busy workers. This approach is used by Rayon, Intel TBB, Go's goroutine scheduler, and other high-performance parallel runtimes.

## Why Work Stealing?

### Problem: Load Imbalance

```
Static partitioning with uneven work:

Worker 0: [=========] 100ms  (done early, sits idle)
Worker 1: [=========] 100ms  (done early, sits idle)
Worker 2: [====================] 200ms  (still working)
Worker 3: [===================================] 350ms

Total time: 350ms (limited by slowest)
Utilization: (100+100+200+350)/(4*350) = 53%
```

### Solution: Dynamic Rebalancing

```
Work stealing with same work:

Worker 0: [=========][steal][steal] 116ms
Worker 1: [=========][steal][steal] 116ms
Worker 2: [==========][steal] 116ms
Worker 3: [===========] 116ms

Total time: 116ms
Utilization: ~98%
```

## The Algorithm

### Data Structure: Per-Worker Deques

Each worker maintains a **Chase-Lev deque** (double-ended queue):

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Worker 0   │     │  Worker 1   │     │  Worker 2   │
│ ┌─────────┐ │     │ ┌─────────┐ │     │ ┌─────────┐ │
│ │ bottom  │ │     │ │ bottom  │ │     │ │ bottom  │ │
│ │ ┌─────┐ │ │     │ │         │ │     │ │         │ │
│ │ │Job 3│ │ │     │ │         │ │     │ │ ┌─────┐ │ │
│ │ ├─────┤ │ │     │ │         │ │     │ │ │Job 1│ │ │
│ │ │Job 2│ │ │     │ │         │ │     │ │ └─────┘ │ │
│ │ ├─────┤ │ │     │ │         │ │     │ │   top   │ │
│ │ │Job 1│ │ │     │ │         │ │     │ └─────────┘ │
│ │ └──▲──┘ │ │     │ │         │ │     │             │
│ │   top   │ │     │ │         │ │     │             │
│ └─────────┘ │     │ └─────────┘ │     │             │
└─────────────┘     └─────────────┘     └─────────────┘
```

### Operations

| Operation | Who | Direction | Lock-Free? |
|-----------|-----|-----------|------------|
| **Push** | Owner | Bottom | Yes (wait-free) |
| **Pop** | Owner | Bottom | Yes (wait-free) |
| **Steal** | Thieves | Top | Yes (CAS loop) |

### The Stealing Loop

When a worker runs out of work:

```
while (true) {
    1. Try to pop from own deque
       → If success: execute job
       → If empty: continue to step 2

    2. Try to steal from random victim
       → Select victim randomly (avoid thundering herd)
       → Try CAS steal from victim's deque
       → If success: execute stolen job
       → If fail: try another victim

    3. If no work found after K attempts:
       → Enter progressive sleep (spin → yield → sleep)
       → Wake on futex when work arrives
}
```

## Why This Design is Fast

### 1. LIFO for Owner (Cache Locality)

```
Owner pushes: A → B → C → D
Owner pops:   D → C → B → A (most recent first)

D is still hot in cache when executed!
```

### 2. FIFO for Thieves (Coarse-Grained Stealing)

```
Thief steals: A (oldest, likely largest subtree)

Stealing old work means:
- Larger chunks (less stealing overhead)
- Better locality for thief (fresh cache)
```

### 3. Randomized Victim Selection

```
// Bad: always steal from Worker 0
for (victim in 0..n) steal(victim)  // Contention on Worker 0!

// Good: random victim selection
victim = rng.bounded(n)  // Spreads load evenly
```

### 4. No Central Queue

```
Central queue:           Work stealing:
    ┌───────┐            ┌───┐ ┌───┐ ┌───┐
    │ Queue │            │ D │ │ D │ │ D │
    └───┬───┘            └─┬─┘ └─┬─┘ └─┬─┘
   ┌──┬─┴─┬──┐             │     │     │
   │  │   │  │             W0    W1    W2
   W0 W1 W2 W3
                         No central bottleneck!
(contention!)
```

## Implementation Details

### Chase-Lev Deque (from `deque.zig`)

```zig
pub fn Deque(comptime T: type) type {
    return struct {
        buffer: []T,
        bottom: std.atomic.Value(isize),  // Owner's end
        top: std.atomic.Value(isize),     // Thieves' end

        // Owner: push to bottom (always succeeds)
        pub fn push(self: *@This(), item: T) void {
            const b = self.bottom.load(.monotonic);
            self.buffer[@intCast(b)] = item;
            self.bottom.store(b + 1, .release);  // Make visible
        }

        // Owner: pop from bottom (may race with steal)
        pub fn pop(self: *@This()) ?T {
            var b = self.bottom.load(.monotonic) - 1;
            self.bottom.store(b, .seq_cst);  // Prevent reorder

            var t = self.top.load(.seq_cst);
            if (t <= b) {
                // Non-empty
                const item = self.buffer[@intCast(b)];
                if (t == b) {
                    // Race with steal on last item
                    if (!self.top.cmpxchgStrong(t, t + 1, .seq_cst, .relaxed)) {
                        self.bottom.store(b + 1, .monotonic);
                        return null;  // Thief got it
                    }
                }
                return item;
            }
            self.bottom.store(b + 1, .monotonic);
            return null;  // Empty
        }

        // Thief: steal from top (may fail)
        // Returns struct with result enum and optional item
        pub fn steal(self: *@This()) struct { result: StealResult, item: ?T } {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);

            if (t >= b) return .{ .result = .empty, .item = null };

            const item = self.buffer[@intCast(t)];

            // CAS to claim the item
            if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .monotonic)) |_| {
                return .{ .result = .retry, .item = null };  // Lost race
            }
            return .{ .result = .success, .item = item };
        }
    };
}

// StealResult enum for steal operations
pub const StealResult = enum { empty, success, retry };
```

### Progressive Sleep (from `pool.zig`)

```zig
const SPIN_LIMIT: u32 = 64;
const YIELD_LIMIT: u32 = 128;

fn waitForWork(self: *Worker) void {
    var attempts: u32 = 0;

    while (true) {
        // Try to find work
        if (self.trySteal()) |job| {
            job.execute();
            attempts = 0;
            continue;
        }

        attempts += 1;

        if (attempts < SPIN_LIMIT) {
            // Spin (lowest latency)
            std.atomic.spinLoopHint();
        } else if (attempts < YIELD_LIMIT) {
            // Yield (medium latency, saves CPU)
            std.Thread.yield();
        } else {
            // Sleep on futex (highest latency, lowest CPU)
            self.pool.sleepUntilWork();
        }
    }
}
```

## Comparison with Other Approaches

| Approach | Pros | Cons |
|----------|------|------|
| **Work Stealing** | Dynamic balance, scalable | Complex implementation |
| Central Queue | Simple | Contention bottleneck |
| Static Partition | Zero overhead | Load imbalance |
| Work Sharing | Simple distribution | Push overhead |

## Performance Characteristics

```
Blitz Work Stealing Performance (10 workers):

Fork overhead:     ~1 ns (push to deque)
Join overhead:     ~1-10 ns (pop or wait)
Steal overhead:    ~5-50 ns (CAS + memory)
Wake overhead:     ~5-10 ns (futex_wake)

Scaling: Near-linear for compute-bound work
```
