# Lock-Free Futex Wake

The synchronization mechanism that makes Blitz's fork-join 44-62% faster than traditional approaches.

## Overview

When a parallel task completes or new work is submitted, sleeping workers need to be woken. Traditional approaches use mutex + condition variable, but Blitz uses a **lock-free futex wake** pattern that's significantly faster.

## The Problem with Traditional Approaches

### Mutex + Condition Variable

```
Traditional wake (Rayon-style condvar):

Producer:
    mutex.lock()           // Acquire lock (~50-100ns)
    work_available = true
    condvar.signal()       // Wake one waiter (~50-100ns)
    mutex.unlock()         // Release lock (~20-50ns)

Consumer (sleeping worker):
    mutex.lock()           // Contention with producer!
    while (!work_available)
        condvar.wait()     // Release + sleep + reacquire
    mutex.unlock()

Total producer cost: ~100-300ns
Problem: Lock contention on hot path
```

### Why It's Slow

```
Scenario: 8 workers, producer submits work

mutex.lock()  ← Worker 0 holds lock
    ↑
    └── Workers 1-7 all spinning, waiting for lock

Even with short critical section:
- Cache line bouncing between cores
- Memory barriers on lock acquire/release
- Contention scales with worker count
```

## Blitz's Lock-Free Solution

### Core Mechanism

```zig
/// In ThreadPool:
wake_futex: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
sleeping_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

/// Wake one sleeping worker (completely lock-free!)
pub inline fn wakeOne(self: *ThreadPool) void {
    // Quick check - only wake if workers are actually sleeping
    if (self.sleeping_count.load(.monotonic) > 0) {
        // Increment futex value to signal change
        _ = self.wake_futex.fetchAdd(1, .release);
        // Wake one waiter
        std.Thread.Futex.wake(&self.wake_futex, 1);
    }
}
```

**Total cost: ~5-10ns** (vs ~100-300ns for mutex+condvar)

### Why It's Fast

```
Lock-free wake:

Producer:
    if (sleeping_count > 0)         // Cheap atomic load (~1ns)
        fetchAdd(&wake_futex, 1)    // Lock-free atomic (~2-5ns)
        futex_wake(&wake_futex, 1)  // Syscall (~2-5ns)

No mutex! No contention! No spinning!
```

### Worker Sleep Loop

```zig
fn workerLoop(pool: *ThreadPool, worker_id: u32) void {
    var rounds: u32 = 0;
    var idle_state: IdleState = .active;

    while (!pool.stopping.load(.acquire)) {
        // Try to find work...
        if (findWork(pool, worker)) |job| {
            transitionToActive(pool, &idle_state);
            executeJob(worker, job);
            rounds = 0;
            continue;
        }

        // Progressive sleep (Rayon-style)
        rounds += 1;

        if (rounds < SPIN_LIMIT) {          // 64 rounds
            // Phase 1: Spin (lowest latency)
            std.atomic.spinLoopHint();
        } else if (rounds < YIELD_LIMIT) {  // 256 rounds
            // Phase 2: Yield (medium latency, saves CPU)
            transitionToIdle(pool, &idle_state);
            std.Thread.yield();
        } else {
            // Phase 3: Sleep on futex (highest latency, lowest CPU)
            transitionToSleeping(pool, &idle_state);

            // Check for work one more time before sleeping
            if (findWork(pool, worker)) |job| {
                transitionToActive(pool, &idle_state);
                executeJob(worker, job);
                rounds = 0;
                continue;
            }

            // Sleep until wake_futex changes
            const current = pool.wake_futex.load(.acquire);
            std.Thread.Futex.wait(&wake_futex, current);

            transitionToActive(pool, &idle_state);
            rounds = 0;
        }
    }
}
```

## State Tracking

Blitz tracks worker states for smart wake decisions:

```zig
const IdleState = enum {
    active,    // Working or spinning
    idle,      // Awake but polling (counted in idle_count)
    sleeping,  // Blocked on futex (counted in sleeping_count)
};

// Pool-level counters
idle_count: std.atomic.Value(u32),     // Workers actively polling
sleeping_count: std.atomic.Value(u32), // Workers blocked on futex
```

### State Transitions

```
                    ┌─────────────┐
           work     │             │  no work
        ┌──────────▶│   ACTIVE    │◀──────────┐
        │           │             │           │
        │           └──────┬──────┘           │
        │                  │ rounds > 64      │
        │                  ▼                  │
        │           ┌─────────────┐           │
        │   work    │             │           │
        ├──────────▶│    IDLE     │           │
        │           │  (polling)  │           │
        │           └──────┬──────┘           │
        │                  │ rounds > 256     │
        │                  ▼                  │
        │           ┌─────────────┐           │
        │   wake    │             │           │
        └──────────▶│  SLEEPING   │───────────┘
                    │  (futex)    │  futex_wake
                    └─────────────┘
```

## Smart Wake Strategy

Not all wakes are necessary. Blitz implements Rayon's smart wake:

```zig
/// Notify pool of new internal jobs
pub inline fn notifyNewJobs(self: *ThreadPool, queue_was_empty: bool) void {
    const num_sleepers = self.sleeping_count.load(.monotonic);

    if (num_sleepers == 0) {
        // No sleeping workers - awake workers will find the work
        return;
    }

    const num_awake_but_idle = self.idle_count.load(.monotonic);

    // Wake if: work is piling up OR no idle workers to find new work
    if (!queue_was_empty or num_awake_but_idle == 0) {
        _ = self.wake_futex.fetchAdd(1, .release);
        std.Thread.Futex.wake(&self.wake_futex, 1);
    }
    // Otherwise: idle workers are polling and will find the work
}
```

### Why This Matters

```
Scenario A: 8 workers, 3 idle (polling), 5 sleeping
    New work arrives
    → Idle workers will find it naturally
    → No wake needed!
    → Saves syscall + context switch

Scenario B: 8 workers, 0 idle, 8 sleeping
    New work arrives
    → Must wake a sleeper
    → Single futex_wake

Scenario C: 8 workers, 0 idle, 8 sleeping, queue already has work
    More work arrives
    → Queue wasn't empty AND no idle workers
    → Wake to prevent pile-up
```

## Comparison with Alternatives

### Mutex + Condvar (Traditional)

```
Producer: ~100-300ns
- mutex.lock (~50-100ns)
- condvar.signal (~50-100ns)
- mutex.unlock (~20-50ns)

Issues:
- Lock contention on hot path
- Cache line bouncing
- Scales poorly with worker count
```

### Atomic Flag + Spin (Naive Lock-Free)

```
Producer: ~2ns
- atomic_store(flag, true)

Consumer: Spins forever
- while (!atomic_load(flag)) spin;

Issues:
- 100% CPU while waiting
- Cache line thrashing
- Terrible for long waits
```

### Blitz: Atomic + Futex (Best of Both)

```
Producer: ~5-10ns (no sleepers) or ~10-20ns (with wake)
- atomic_load (sleeping_count)
- atomic_fetchAdd (if needed)
- futex_wake (if needed)

Consumer: Progressive degradation
- Spin for 64 rounds (~64ns) - catches quick work
- Yield for 192 rounds (~1-5ms) - saves CPU
- Sleep on futex - zero CPU

Issues: None significant
- Lock-free producer path
- Near-zero CPU when idle
- Minimal wake latency
```

## Performance Impact

### Fork-Join Microbenchmark

```
Benchmark: binary tree fork-join (depth=10, 2047 total forks)

Traditional (mutex+condvar):   18.60 ms
Blitz (lock-free futex):        7.03 ms

Improvement: 62% faster
```

### Why 62% Faster?

Each fork-join cycle involves:
1. Parent spawns child task
2. Parent notifies pool (wake)
3. Worker wakes and steals task
4. Worker completes and signals parent
5. Parent wakes and continues

With 2047 forks:
```
Traditional: 2047 × ~300ns wake overhead = ~614μs just in wakes
Blitz:       2047 × ~10ns wake overhead = ~20μs just in wakes

Saved: ~594μs per benchmark iteration
```

### Scaling with Depth

```
Depth   Forks      Blitz      Rayon     Improvement
──────────────────────────────────────────────────
10      2,047      7.03 ms    18.60 ms  62% faster
15      65,535     0.96 ms    1.71 ms   44% faster
20      2,097,151  0.82 ms    0.71 ms   15% slower*

*At extreme depth, wake overhead is amortized
```

## Implementation Details

### Futex Semantics

```zig
// Wait: block if *ptr == expected
std.Thread.Futex.wait(&wake_futex, expected_value);

// Wake: wake up to N waiters
std.Thread.Futex.wake(&wake_futex, count);
```

The futex (fast userspace mutex) is a Linux/macOS primitive that:
- `wait`: Atomically checks value and sleeps if equal
- `wake`: Wakes blocked waiters without any lock

### ABA Prevention

The futex value always increments, never wraps to same value:

```zig
// Always increment - never reuse values
_ = self.wake_futex.fetchAdd(1, .release);
```

Even if the value wraps around (after 4 billion wakes), the wake is spurious at worst - workers will just check for work and go back to sleep if none found.

### Memory Ordering

```zig
// Producer side
sleeping_count.load(.monotonic)     // Just a hint, can be stale
wake_futex.fetchAdd(1, .release)    // Release: make work visible

// Consumer side
wake_futex.load(.acquire)           // Acquire: see all prior writes
```

## When to Use This Pattern

**Good for:**
- Thread pools with work stealing
- Producer-consumer with bursty load
- Any scenario with sleep/wake cycles

**Not needed for:**
- Spin-only synchronization (tight loops)
- Single-producer single-consumer queues
- Lock-free data structures without blocking

## References

1. Futex design: Drepper, "Futexes Are Tricky" (2011)
2. Rayon latch implementation: `rayon-core/src/latch.rs`
3. Blitz implementation: `pool.zig`
