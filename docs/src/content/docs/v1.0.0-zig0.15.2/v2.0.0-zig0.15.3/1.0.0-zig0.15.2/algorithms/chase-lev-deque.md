---
title: Chase-Lev Deque
description: The lock-free double-ended queue at the heart of work stealing.
slug: v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/1.0.0-zig0.15.2/algorithms/chase-lev-deque
---

## Overview

The Chase-Lev deque is a concurrent data structure designed specifically for work stealing. It was introduced in "Dynamic Circular Work-Stealing Deque" by David Chase and Yossi Lev (2005).

## Properties

| Property | Value |
|----------|-------|
| Push (owner) | Wait-free O(1) |
| Pop (owner) | Wait-free O(1) |
| Steal (thieves) | Lock-free O(1) |
| Memory | O(n) where n is max concurrent items |

## Design

### Structure

```
         ┌─────────────────────────────────────┐
         │          Circular Buffer            │
         │  ┌───┬───┬───┬───┬───┬───┬───┬───┐ │
         │  │ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ │
         │  └───┴───┴───┴───┴───┴───┴───┴───┘ │
         │        ▲               ▲            │
         │       top            bottom         │
         │    (thieves)        (owner)         │
         └─────────────────────────────────────┘

Elements stored: indices [top, bottom)
Owner operates at bottom
Thieves operate at top
```

### Key Insight: Asymmetric Access

```
Owner (single thread):
- Push: Write to bottom, increment bottom
- Pop: Decrement bottom, read from bottom

Thieves (multiple threads):
- Steal: Read from top, CAS increment top

The asymmetry allows owner operations to be wait-free!
```

## Implementation

### Data Structure

```zig
pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Circular buffer (power of 2 size for fast modulo)
        buffer: []T,
        mask: usize,  // buffer.len - 1

        /// Atomic indices
        bottom: std.atomic.Value(isize),  // Owner's end
        top: std.atomic.Value(isize),     // Thieves' end

        pub fn init(allocator: Allocator, capacity: usize) !Self {
            // Round up to power of 2
            const size = std.math.ceilPowerOfTwo(usize, capacity);
            return Self{
                .buffer = try allocator.alloc(T, size),
                .mask = size - 1,
                .bottom = std.atomic.Value(isize).init(0),
                .top = std.atomic.Value(isize).init(0),
            };
        }
    };
}
```

### Push (Owner Only)

Wait-free: always succeeds in constant time.

```zig
pub fn push(self: *Self, item: T) void {
    const b = self.bottom.load(.monotonic);

    // Write item to buffer
    self.buffer[@intCast(b) & self.mask] = item;

    // Memory fence: ensure item is visible before bottom update
    @fence(.release);

    // Make item available to stealers
    self.bottom.store(b + 1, .monotonic);
}
```

**Why it's wait-free:**

* No loops
* No CAS operations
* Just a write and atomic store

### Pop (Owner Only)

Wait-free in common case, one CAS in edge case.

```zig
pub fn pop(self: *Self) ?T {
    // Decrement bottom first (tentatively claim item)
    var b = self.bottom.load(.monotonic) - 1;
    self.bottom.store(b, .seq_cst);

    // Load top (may race with stealers)
    var t = self.top.load(.seq_cst);

    if (t <= b) {
        // Deque is non-empty
        const item = self.buffer[@intCast(b) & self.mask];

        if (t == b) {
            // This is the LAST item - race with stealers
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .relaxed) != null) {
                // A stealer got it first
                self.bottom.store(b + 1, .monotonic);
                return null;
            }
            self.bottom.store(b + 1, .monotonic);
        }
        return item;
    } else {
        // Deque was empty
        self.bottom.store(b + 1, .monotonic);
        return null;
    }
}
```

**The tricky case:**

```
Before:  top=5, bottom=6  (one item at index 5)

Owner pop:  bottom=5
Stealer:    Reads top=5, bottom=5 (sees one item)

Race! Both want item at index 5.
Solution: CAS on top to break tie.
```

### Steal (Thieves)

Lock-free: may fail but makes progress system-wide.

Returns a struct with result enum (success/empty/retry) and optional item:

```zig
pub const StealResult = enum { empty, success, retry };

pub fn steal(self: *Self) struct { result: StealResult, item: ?T } {
    // Load top first with acquire
    const t = self.top.load(.acquire);

    // Load bottom with acquire to see owner's operations
    const b = self.bottom.load(.acquire);

    if (t >= b) {
        // Deque is empty
        return .{ .result = .empty, .item = null };
    }

    // Speculatively read the item
    const idx = @as(usize, @intCast(t)) & self.mask;
    const item = self.buffer[idx];

    // Try to claim by incrementing top with CAS
    if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .monotonic)) |_| {
        // Lost the race - another thief got it or owner popped
        return .{ .result = .retry, .item = null };
    }

    // Success!
    return .{ .result = .success, .item = item };
}
```

**Why CAS?**

```
Multiple thieves trying to steal:

Thief A: Read top=3, item=X
Thief B: Read top=3, item=X

Without CAS, both would take item X!

With CAS:
Thief A: CAS(3→4) succeeds, gets X
Thief B: CAS(3→4) fails (top is now 4), retries
```

## Memory Ordering

### Why seq\_cst on Critical Operations?

```zig
// Pop
self.bottom.store(b, .seq_cst);  // Must order before top read
var t = self.top.load(.seq_cst);

// Steal
var t = self.top.load(.acquire);
@fence(.seq_cst);  // Must order before bottom read
const b = self.bottom.load(.acquire);
```

The seq\_cst ensures:

1. Pop's bottom decrement is visible before checking top
2. Steal's top read is ordered with bottom read

Without this, we could have:

* Pop thinks deque has 2 items (stale top)
* Steal thinks deque has 2 items (stale bottom)
* Both try to take "different" items that are actually the same!

## Comparison with Alternatives

| Deque Type | Push | Pop | Steal | Notes |
|------------|------|-----|-------|-------|
| **Chase-Lev** | Wait-free | Wait-free\* | Lock-free | Best for work stealing |
| Mutex-based | O(1) + lock | O(1) + lock | O(1) + lock | Simple but slow |
| Michael-Scott | Lock-free | Lock-free | Lock-free | For queues, not deques |

\*Wait-free except for single-item case requiring CAS

## Optimization: No ABA Problem

Unlike many lock-free structures, Chase-Lev doesn't suffer from ABA:

```
ABA Problem (in other structures):
1. Thread A reads value A at location X
2. Thread B changes X: A → B → A
3. Thread A's CAS succeeds (sees A) but data is wrong!

Chase-Lev avoids this:
- Indices only increase monotonically
- No value reuse in the same position
- Circular buffer means index wraps, not value
```

## Performance

```
Benchmark (single producer, 4 stealers):

Push:  ~3 ns (wait-free)
Pop:   ~3 ns (wait-free common case)
Steal: ~10-50 ns (CAS contention varies)

Throughput: ~100M ops/sec per deque
```

## References

1. Chase, D., & Lev, Y. (2005). "Dynamic Circular Work-Stealing Deque"
2. Le, N. M., et al. (2013). "Correct and Efficient Work-Stealing for Weak Memory Models"
3. Rayon source: `rayon-core/src/deque`
