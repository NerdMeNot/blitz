# Thread Pool

Blitz implements a Rayon-style work-stealing thread pool with sophisticated sleep/wake coordination to minimize both latency and CPU usage.

## Overview

The thread pool is the heart of Blitz's parallelism. Key characteristics:

- **Lock-free work stealing**: Chase-Lev deques with wait-free push/pop
- **Rayon-style sleep protocol**: Progressive sleep with JEC (Jobs Event Counter)
- **4-state CoreLatch**: Prevents missed wake signals
- **Packed AtomicCounters**: Single u64 holds sleeping/inactive/JEC counters

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         ThreadPool                               │
├─────────────────────────────────────────────────────────────────┤
│  workers: []Worker          // Background worker threads         │
│  main_worker: Worker        // For external call() invocations   │
│  sleep: Sleep               // Sleep manager with JEC protocol   │
│  injected_jobs_head: *Node  // Treiber stack for external jobs   │
│  stopping: Atomic(bool)     // Shutdown flag                     │
└─────────────────────────────────────────────────────────────────┘
                                │
                ┌───────────────┴───────────────┐
                ▼                               ▼
┌───────────────────────────┐   ┌───────────────────────────┐
│      Worker (per thread)   │   │         Sleep Manager      │
├───────────────────────────┤   ├───────────────────────────┤
│  id: u32                   │   │  counters: AtomicCounters  │
│  deque: Deque(*Job)        │   │  worker_sleep_states: []   │
│  rng: XorShift64Star       │   │    WorkerSleepState        │
│  latch: CoreLatch          │   └───────────────────────────┘
│  pool: *ThreadPool         │
└───────────────────────────┘
```

## AtomicCounters: Packed u64 State

All sleep coordination state is packed into a single 64-bit atomic value for efficient multi-field updates:

```
┌────────────────────────────────────────────────────────────────┐
│                        AtomicCounters (u64)                     │
├──────────────────┬──────────────────┬──────────────────────────┤
│ Bits 0-15        │ Bits 16-31       │ Bits 32-63               │
│ sleeping_threads │ inactive_threads │ JEC (Jobs Event Counter) │
├──────────────────┼──────────────────┼──────────────────────────┤
│ Workers blocked  │ Workers not      │ Even = sleepy mode       │
│ on condvar       │ executing work   │ Odd = active mode        │
└──────────────────┴──────────────────┴──────────────────────────┘
```

**Key relationships**:
- `awake_but_idle = inactive_threads - sleeping_threads`
- These workers are polling and will find new work naturally
- Only sleeping workers need explicit wake signals

```zig
const AtomicCounters = struct {
    value: std.atomic.Value(u64),

    // Extract individual counters
    fn extractSleeping(counters: u64) u16;    // Bits 0-15
    fn extractInactive(counters: u64) u16;    // Bits 16-31
    fn extractJec(counters: u64) u32;         // Bits 32-63

    // Atomic operations (all SeqCst for correctness)
    fn tryAddSleepingThread(self: *AtomicCounters, expected: u64) bool;
    fn subSleepingThread(self: *AtomicCounters) void;
    fn addInactiveThread(self: *AtomicCounters) void;
    fn subInactiveThread(self: *AtomicCounters) u16;  // Returns threads to wake
    fn incrementJecIfSleepy(self: *AtomicCounters) u64;
};
```

## JEC Protocol: Jobs Event Counter

The JEC protocol prevents a critical race condition where a worker misses newly posted work while transitioning to sleep.

**JEC States**:
- **Even (LSB = 0)**: "Sleepy" mode - no new work since last sleepy announcement
- **Odd (LSB = 1)**: "Active" mode - new work has been posted

**Protocol flow**:

```
Worker going to sleep:                Job poster:
─────────────────────                ───────────
1. Round 32: Announce sleepy
   - Save JEC snapshot
   - Increment JEC if even→odd

2. Round 33: One more yield          Work arrives here:
                                     - Increment JEC if even→odd

3. Round 34+: Try to sleep
   - Check: JEC changed since
     snapshot?
   - YES: New work! Go back to
     round 32, re-announce
   - NO: Safe to sleep
```

This ensures:
- If work arrives while worker is "sleepy but awake", worker sees JEC change
- If work arrives after worker sleeps, poster will wake them explicitly

```zig
fn incrementJecIfSleepy(self: *AtomicCounters) u64 {
    while (true) {
        const old = self.loadSeqCst();
        const jec_val = extractJec(old);

        if ((jec_val & 1) != 0) {
            return old;  // Already active (odd) - no change needed
        }

        // Try to toggle from even to odd
        const new = old +% ONE_JEC;
        if (self.value.cmpxchgWeak(old, new, .seq_cst, .monotonic) == null) {
            return old;
        }
        // CAS failed, retry
    }
}
```

## CoreLatch: 4-State Sleep Protocol

Each worker has a CoreLatch to coordinate sleep/wake without races:

```
State Machine:

    UNSET (0) ──────────────────────────► SET (3)
        │                                    ▲
        │ getSleepy()                        │ set()
        ▼                                    │
    SLEEPY (1) ─────────────────────────► SET (3)
        │                                    ▲
        │ fallAsleep()                       │ set()
        ▼                                    │
    SLEEPING (2) ───────────────────────► SET (3)
        │
        │ wakeUp() [spurious]
        ▼
    UNSET (0)
```

**State meanings**:
- **UNSET (0)**: Worker is active, not trying to sleep
- **SLEEPY (1)**: Worker announced intent to sleep, one more check pending
- **SLEEPING (2)**: Worker is blocked on condvar
- **SET (3)**: Work has been assigned, worker should wake

**Why 4 states?** Prevents the "tickle-then-get-sleepy" race:

```
Without SLEEPY state (RACE!):
  Worker A: if (!hasWork) {      Poster B: postWork();
  Worker A:                      Poster B: wake();  // A not sleeping yet!
  Worker A:   sleep();           // MISSED WAKE - A sleeps forever

With SLEEPY state (SAFE):
  Worker A: latch = SLEEPY;
  Worker A: if (!hasWork) {      Poster B: postWork();
  Worker A:   CAS SLEEPY→SLEEPING
  Worker A:   sleep();           Poster B: if (swap(SET) == SLEEPING) wake();
                                 // B sees SLEEPING, will wake A
```

## Progressive Sleep: 32 + 1 + Sleep

Workers progress through idle states to balance latency vs CPU usage:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Progressive Sleep Protocol                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Rounds 0-31: YIELD PHASE                                       │
│  ─────────────────────────                                      │
│  - Call std.Thread.yield() each round                           │
│  - Check for work between yields                                │
│  - Low latency: ~1-5µs to find new work                         │
│  - Moderate CPU: yields allow other threads to run              │
│                                                                  │
│  Round 32: ANNOUNCE SLEEPY                                      │
│  ─────────────────────────                                      │
│  - Increment JEC if even (toggle to odd)                        │
│  - Save JEC snapshot for later comparison                       │
│  - One more yield                                               │
│                                                                  │
│  Round 33: PRE-SLEEP YIELD                                      │
│  ─────────────────────────                                      │
│  - Final yield before committing to sleep                       │
│  - Gives job posters one more chance                            │
│                                                                  │
│  Round 34+: ACTUAL SLEEP                                        │
│  ─────────────────────────                                      │
│  1. CAS latch UNSET → SLEEPY                                    │
│  2. Lock worker's mutex                                         │
│  3. CAS latch SLEEPY → SLEEPING                                 │
│  4. Check if JEC changed since snapshot                         │
│     - YES: Unlock, wakeUp(), go to round 32                     │
│  5. CAS to add self to sleeping_threads count                   │
│  6. SeqCst fence                                                │
│  7. Check for injected jobs (double-check pattern)              │
│     - If found: undo sleep registration, return                 │
│  8. Block on condvar                                            │
│  9. On wake: wakeUp() latch, reset rounds to 0                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Key constants**:
```zig
const ROUNDS_UNTIL_SLEEPY: u32 = 32;   // Yield 32 times before announcing
const ROUNDS_UNTIL_SLEEPING: u32 = 33; // One more yield after announcing
```

## Wake Protocol: Smart Thread Wake

When new work arrives, the poster must decide how many workers to wake:

```zig
fn newJobs(self: *Sleep, num_jobs: u32, queue_was_empty: bool) void {
    // 1. Toggle JEC to odd if even (signals "new work available")
    const old = self.counters.incrementJecIfSleepy();
    const sleeping = extractSleeping(old);

    if (sleeping == 0) return;  // No sleeping workers to wake

    const inactive = extractInactive(old);
    const awake_but_idle = inactive -| sleeping;  // Saturating subtract

    // 2. Decide how many to wake
    const num_to_wake: u32 = if (queue_was_empty) blk: {
        // Queue was empty - wake if not enough idle workers to grab the work
        if (awake_but_idle < num_jobs) {
            break :blk @min(num_jobs - awake_but_idle, sleeping);
        }
        break :blk 0;  // Enough idle workers already polling
    } else blk: {
        // Queue had work - always wake some to help clear backlog
        break :blk @min(num_jobs, sleeping);
    };

    self.wakeThreads(num_to_wake);
}
```

**Critical invariant**: The waker decrements `sleeping_threads`, not the sleeper. This ensures:
1. Sleeper registers before blocking → count is accurate
2. Waker sees sleeper in count → knows to signal condvar
3. Waker decrements count → prevents double-wake

## SeqCst Fences: When They're Required

Blitz uses two SeqCst fences to handle the race between job injection and sleep:

```
┌─────────────────────────────────────────────────────────────────┐
│                  Fence #1: Job Injection                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  fn newInjectedJobs(self: *Sleep, ...) void {                   │
│      seqCstFence();  // ◄── FENCE HERE                          │
│      self.newJobs(...);                                         │
│  }                                                               │
│                                                                  │
│  Purpose: Ensure injected job is visible before we read         │
│  sleeping count. Without this, a sleeping worker might          │
│  not see the job, and we might not see them sleeping.           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                  Fence #2: Sleep Entry                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  fn sleep(...) void {                                           │
│      // ... register as sleeping ...                            │
│      seqCstFence();  // ◄── FENCE HERE                          │
│      if (pool.hasInjectedJobs()) {                              │
│          // Undo sleep registration, return                     │
│      }                                                           │
│      // Actually block                                          │
│  }                                                               │
│                                                                  │
│  Purpose: After registering as sleeping, check for injected     │
│  jobs one more time. The fence ensures we see any jobs that     │
│  were injected before we registered.                            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Important**: Internal jobs (pushed to deques) do NOT need a fence because:
- Deque operations use acquire/release semantics
- Thieves naturally synchronize via CAS on deque.top
- Only cross-thread Treiber stack access needs the fence

## Worker Main Loop

```zig
fn workerLoop(pool: *ThreadPool, worker_id: u32) void {
    const worker = &pool.workers[worker_id];
    worker.initDeque(pool.allocator, worker_id);
    pool.workers_ready.post();  // Signal ready

    while (!pool.stopping.load(.acquire)) {
        // Fast path: find and execute work
        if (pool.findWork(worker)) |job| {
            executeJob(worker, job);
            continue;
        }

        // Slow path: enter idle state
        var idle_state = pool.sleep.startLooking(worker_id);
        var found_work = false;

        while (!pool.stopping.load(.acquire)) {
            if (pool.findWork(worker)) |job| {
                found_work = true;
                const to_wake = pool.sleep.workFound();
                executeJob(worker, job);
                pool.sleep.wakeThreads(to_wake);  // Cascade wake
                break;
            }

            pool.sleep.noWorkFound(&idle_state, &worker.latch, pool);
        }

        if (!found_work) {
            _ = pool.sleep.workFound();  // Clean up inactive count
        }
    }
}
```

## Work Finding Priority

Work is discovered in this priority order:

```
1. Own deque (LIFO pop)
   ├── Fastest access (no contention)
   ├── Best cache locality (recently pushed work)
   └── Owner has exclusive pop access

2. Steal from others (FIFO steal)
   ├── Try main_worker first (most likely to have external work)
   ├── Then all background workers from random start index
   └── FIFO order balances load (oldest work distributed first)

3. Injected job queue (Treiber stack)
   └── External submissions from non-pool threads
```

## Configuration

```zig
pub const ThreadPoolConfig = struct {
    /// Number of background worker threads.
    /// null = auto-detect (CPU count)
    background_worker_count: ?usize = null,
};
```

## Key Design Decisions

### 1. Yield Every Round (Rayon-style)

During the idle phase, workers yield on every round instead of spinning:

```zig
if (idle.rounds < ROUNDS_UNTIL_SLEEPY) {
    std.Thread.yield() catch {};  // Yield every round
    return;
}
```

**Why**: Spinning with `spinLoopHint()` caused benchmark variance because:
- CPU cores weren't being shared fairly
- Other threads couldn't make progress
- Yielding gives OS scheduler control, reducing variance

### 2. Packed Counters in Single Atomic

All sleep state in one u64 enables atomic multi-field operations:

```zig
// Single atomic read gets all state
const counters = self.counters.loadSeqCst();
const sleeping = extractSleeping(counters);
const inactive = extractInactive(counters);
const jec = extractJec(counters);
```

### 3. Waker Decrements Counter

The thread that wakes a sleeping worker also decrements `sleeping_threads`:

```zig
fn wakeSpecificThread(self: *Sleep, ...) bool {
    if (state.is_blocked) {
        state.is_blocked = false;
        state.condvar.signal();
        self.counters.subSleepingThread();  // Waker decrements
        return true;
    }
    return false;
}
```

This prevents races where the sleeper might decrement before actually waking.

### 4. Cache-Line Aligned Sleep State

Each `WorkerSleepState` is padded to prevent false sharing:

```zig
const WorkerSleepState = struct {
    mutex: std.Thread.Mutex,
    condvar: std.Thread.Condition,
    is_blocked: bool,
    _padding: [cache_line - size]u8,  // Isolate each worker's state
};
```

## Performance Characteristics

| Operation | Typical Time | Notes |
|-----------|-------------|-------|
| Push to deque | ~3 ns | Wait-free |
| Pop from deque | ~3 ns | Wait-free (no contention) |
| Steal from deque | ~10-50 ns | CAS contention possible |
| Yield (idle round) | ~1-5 µs | OS scheduler involved |
| Wake sleeping worker | ~10-100 µs | Condvar + context switch |
| Full sleep cycle | ~100-500 µs | Progressive sleep saves CPU |

## Thread Safety Summary

| Component | Safety Model |
|-----------|--------------|
| AtomicCounters | Thread-safe (SeqCst atomics) |
| CoreLatch | Thread-safe (CAS transitions) |
| WorkerSleepState | Protected by per-worker mutex |
| Deque push/pop | Single-owner (owning thread only) |
| Deque steal | Multi-reader (lock-free CAS) |
| Treiber stack | Lock-free (CAS-based) |
