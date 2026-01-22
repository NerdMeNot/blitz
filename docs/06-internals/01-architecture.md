# Architecture Overview

This document describes the internal architecture of Blitz, including component interactions, data structures, and key design decisions.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              USER CODE                                       │
│  blitz.iter(data).sum() | blitz.join(.{...}) | blitz.sortAsc()              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           API LAYER (api.zig)                                │
│  • High-level parallel primitives                                            │
│  • Automatic grain size calculation                                          │
│  • Sequential/parallel threshold decisions                                   │
│  • Iterator combinators and transformations                                  │
│  • Thread-local task context management                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        FORK-JOIN LAYER (future.zig)                          │
│  • Stack-allocated Future(Input, Output) for fork-join                       │
│  • Embedded OnceLatch for completion signaling                               │
│  • Hybrid join: latch-first for stolen, pop-first for local                  │
│  • Active work-stealing during join wait                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      SCHEDULER (pool.zig + worker.zig)                       │
│  • ThreadPool with lock-free job injection                                   │
│  • Rayon-style idle/sleeping state tracking                                  │
│  • Smart wake: notifyNewJobs() only wakes when needed                        │
│  • Progressive sleep: spin → yield → futex wait                              │
│  • Background workers with Chase-Lev deques                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        LOCK-FREE PRIMITIVES                                  │
│  deque.zig   - Chase-Lev work-stealing deque (wait-free push/pop)           │
│  latch.zig   - 4-state OnceLatch, CountLatch, SpinWait                      │
│  job.zig     - Minimal Job struct (8 bytes: handler pointer)                │
│  sync.zig    - SyncPtr for lock-free parallel writes                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Component Details

### ThreadPool (pool.zig)

The thread pool manages worker threads and coordinates work distribution.

```
ThreadPool
├── allocator: Allocator           // For worker/deque allocation
├── workers: []?*Worker            // Fixed array of workers
├── num_workers: usize             // Worker count
├── threads: []Thread              // OS thread handles
│
├── wake_futex: Atomic(u32)        // Futex for sleep/wake
├── idle_count: Atomic(u32)        // Workers awake but polling
├── sleeping_count: Atomic(u32)    // Workers blocked on futex
├── stopping: Atomic(bool)         // Shutdown flag
│
├── injected_jobs: Atomic(u64)     // Treiber stack for external jobs
└── workers_ready: Semaphore       // Startup synchronization
```

**Key Operations**:

1. **Job Injection** (external threads calling `pool.call()`):
   ```
   External thread                    Worker thread
        │                                  │
        ├─► Push to Treiber stack ─────────┤
        ├─► wakeOne() ─────────────────────┤
        └─► Wait on done event             │
                                           ├─► Pop from Treiber stack
                                           ├─► Execute job
                                           └─► Signal done event
   ```

2. **Work Stealing**:
   ```
   Worker A (owner)                  Worker B (thief)
        │                                  │
        ├─► push(job) to deque             │
        │   (bottom++)                     │
        │                                  ├─► steal() from A's deque
        │                                  │   (top++, CAS)
        ├─► pop() from deque               │
        │   (bottom--, CAS if last)        │
   ```

### Worker (worker.zig)

Each worker thread maintains local state for efficient work distribution.

```
Worker (per thread)
├── pool: *ThreadPool              // Back-reference to pool
├── id: u32                        // Worker index
├── deque: ?Deque(*Job)            // Chase-Lev deque (256 slots)
├── rng: XorShift64Star            // For randomized victim selection
└── stats: WorkerStats             // jobs_executed, jobs_stolen
```

**Worker Loop State Machine**:

```
                    ┌──────────────────┐
                    │      ACTIVE      │
                    │  (spinning)      │
                    │  rounds < 64     │
                    └────────┬─────────┘
                             │ no work found
                             ▼
                    ┌──────────────────┐
                    │      IDLE        │
                    │  (yielding)      │
                    │  64 ≤ rounds     │
                    │      < 256       │
                    │  idle_count++    │
                    └────────┬─────────┘
                             │ still no work
                             ▼
                    ┌──────────────────┐
                    │    SLEEPING      │
                    │  (futex wait)    │
                    │  idle_count--    │
                    │  sleeping_count++│
                    └────────┬─────────┘
                             │ wake signal
                             ▼
                    ┌──────────────────┐
                    │      ACTIVE      │
                    │  sleeping_count--│
                    └──────────────────┘
```

### Future (future.zig)

Stack-allocated futures enable zero-allocation fork-join parallelism.

```
Future(Input, Output)
├── job: Job                       // Handler pointer (8 bytes)
├── latch: OnceLatch               // Completion signal (4 bytes)
├── input: Input                   // Captured input value
└── result: Output                 // Storage for result

Total size: ~32-64 bytes (on stack)
```

**Fork-Join Flow**:

```
1. fork(task, func, input):
   ┌─────────────────────────────────────────────────────────────┐
   │  self.input = input                                         │
   │  self.job.handler = Handler.handle  // comptime specialized │
   │  self.latch = OnceLatch.init()                              │
   │  task.worker.pushAndWake(&self.job) // visible to thieves   │
   └─────────────────────────────────────────────────────────────┘

2. join(task) - Hybrid Strategy:
   ┌─────────────────────────────────────────────────────────────┐
   │  // Fast path: check if stolen job already completed        │
   │  if (latch.probe()) return self.result;                     │
   │                                                             │
   │  // Try pop first: catches local jobs at deep recursion     │
   │  if (worker.pop()) |job| {                                  │
   │      if (job == &self.job) return null; // execute locally  │
   │      job.execute();                                         │
   │  }                                                          │
   │                                                             │
   │  // Work-stealing loop while waiting                        │
   │  while (!latch.probe()) {                                   │
   │      pop() or steal() and execute                           │
   │      spin, then yield                                       │
   │  }                                                          │
   │  return self.result;                                        │
   └─────────────────────────────────────────────────────────────┘
```

### Chase-Lev Deque (deque.zig)

Lock-free double-ended queue optimized for work-stealing.

```
Deque(T)
├── top: Atomic(isize)     // Thieves' end (cache-line aligned)
├── _padding: [56]u8       // Prevent false sharing
├── bottom: Atomic(isize)  // Owner's end (cache-line aligned)
├── _padding2: [56]u8
├── buffer: []T            // Circular array (power of 2)
└── mask: usize            // buffer.len - 1 for fast modulo
```

**Memory Ordering**:

| Operation | Ordering | Rationale |
|-----------|----------|-----------|
| push (write bottom) | release | Make item visible before index |
| pop (read/write bottom) | seq_cst | Synchronize with steal |
| pop (CAS top) | seq_cst | Race with thieves |
| steal (read top) | acquire | See owner's pushes |
| steal (read bottom) | acquire | See owner's pops |
| steal (CAS top) | seq_cst | Race with owner and other thieves |

**Steal with Backoff**:

```zig
pub fn stealLoop(self: *Self) ?T {
    var backoff: u32 = 0;
    while (true) {
        switch (self.steal().result) {
            .success => return item,
            .empty => return null,
            .retry => {
                // Exponential backoff: 1, 2, 4, 8, 16, 32 spins
                // Then yield to OS
                backoff = @min(backoff + 1, 6);
                spin(1 << backoff);
            }
        }
    }
}
```

### OnceLatch (latch.zig)

4-state latch that prevents missed wakes.

```
States:
  UNSET (0)    ──────────► SET (3)
     │                       ▲
     ▼                       │
  SLEEPY (1)  ──────────► SET (3)
     │                       ▲
     ▼                       │
  SLEEPING (2) ─────────► SET (3)
     │
     ▼
  UNSET (0)  [spurious wake]
```

**The "Tickle-Then-Get-Sleepy" Pattern**:

This pattern prevents a race where Thread A misses a wake:

```
Without SLEEPY state (race condition):
  Thread A: if (!done) {     Thread B: done = true;
  Thread A:                  Thread B: wake();  // A not sleeping yet!
  Thread A:   sleep();       // MISSED WAKE!

With SLEEPY state (safe):
  Thread A: state = SLEEPY;
  Thread A: if (!done) {     Thread B: done = true;
  Thread A:   if (CAS SLEEPY→SLEEPING) {
  Thread A:     sleep();     Thread B: if (prev == SLEEPING) wake();
  Thread A:   }              // B sees A is SLEEPING, will wake
            }
```

## Data Flow Examples

### parallelFor

```
1. User calls blitz.parallelFor(1000000, ctx, body)
         │
         ▼
2. Calculate grain size: max(1000000 / (workers * 4), MIN_GRAIN)
         │
         ▼
3. If n < threshold: execute sequentially
   Else: recursive parallel split
         │
         ▼
4. Split in half: [0..500000) and [500000..1000000)
   Fork right half, recurse left
         │
         ├──► Worker 0: process [0..500000)
         │    └── Further splits as needed
         │
         └──► Worker 1 steals: [500000..1000000)
              └── Further splits as needed
         │
         ▼
5. Join waits, actively stealing other work
         │
         ▼
6. All ranges processed, return
```

### parallelReduce

```
1. Divide into chunks based on grain size
         │
         ▼
2. Parallel map phase:
   ┌─────────┬─────────┬─────────┬─────────┐
   │ Chunk 0 │ Chunk 1 │ Chunk 2 │ Chunk 3 │
   │  map()  │  map()  │  map()  │  map()  │
   │ reduce  │ reduce  │ reduce  │ reduce  │
   └────┬────┴────┬────┴────┬────┴────┬────┘
        │         │         │         │
        ▼         ▼         ▼         ▼
      part0     part1     part2     part3
         │
         ▼
3. Tree reduction (parallel):
        part0 ─────┐
        part1 ────►├──► combined01 ────┐
        part2 ─────┤                   │
        part3 ────►└──► combined23 ────┼──► final
                                       │
4. Return final result
```

### join (2-task)

```
1. blitz.join(.{ .a = taskA, .b = taskB })
         │
         ▼
2. Fork task B (push to deque, wake if sleepers)
         │
         ├──► Task B visible to thieves
         │
         ▼
3. Execute task A inline (no fork needed)
         │
         ├──► If A does nested join, repeat recursively
         │
         ▼
4. Join task B:
   - If B was stolen and done: return result
   - If B in deque: pop and execute locally
   - If B stolen but not done: steal other work while waiting
         │
         ▼
5. Return .{ .a = resultA, .b = resultB }
```

## Key Design Decisions

### 1. Lock-Free Wake via Futex

Traditional pools use mutex + condition variable:
```c
// Slow: ~100-300ns
mutex_lock(&mtx);
cond_signal(&cv);
mutex_unlock(&mtx);
```

Blitz uses futex directly:
```zig
// Fast: ~5-10ns
if (sleeping_count.load(.monotonic) > 0) {
    _ = wake_futex.fetchAdd(1, .release);
    Futex.wake(&wake_futex, 1);
}
```

### 2. Stack-Allocated Futures

Jobs are embedded in the caller's stack frame:

```zig
fn parallelRecurse(...) void {
    var future: Future(Input, Output) = undefined;  // On stack!
    future.fork(&task, func, input);
    // ... local work ...
    const result = future.join(&task);
}
```

**Benefits**:
- Zero heap allocation for fork-join
- Cache-friendly (future near call site)
- Automatic cleanup on function return

### 3. Hybrid Join Strategy

Optimized for both shallow and deep recursion:

1. **Shallow recursion** (high steal rate): Check latch first, stolen jobs often complete quickly
2. **Deep recursion** (low steal rate): Try pop first, jobs usually still local

```zig
// Fast path for stolen
if (latch.probe()) return result;

// Fast path for local
if (worker.pop()) |job| {
    if (job == &self.job) return null;
    execute(job);
}

// Full work-stealing loop
while (!latch.probe()) { ... }
```

### 4. Rayon-Style Idle Tracking

Two separate counters for efficient wake decisions:

- `idle_count`: Workers awake but polling (will find work naturally)
- `sleeping_count`: Workers blocked on futex (need explicit wake)

```zig
pub fn notifyNewJobs(self: *ThreadPool, num_jobs: u32, queue_was_empty: bool) void {
    const num_sleepers = self.sleeping_count.load(.monotonic);
    if (num_sleepers == 0) return;  // Awake workers will find work

    const num_idle = self.idle_count.load(.monotonic);
    // Only wake if work is piling up OR no idle workers
    if (!queue_was_empty or num_idle == 0) {
        wake(1);
    }
}
```

### 5. Comptime Specialization

All function pointers resolved at compile time:

```zig
pub fn parallelFor(
    n: usize,
    comptime Context: type,      // Compile-time
    ctx: Context,
    comptime body: fn(...) void, // Compile-time
) void
```

**Benefits**:
- No virtual dispatch
- Full inlining possible
- Type-specific optimizations

## Performance Characteristics

| Operation | Time | Notes |
|-----------|------|-------|
| Fork (push) | ~3 ns | Wait-free |
| Join (pop, local) | ~5 ns | Wait-free, no latch check needed |
| Join (stolen, done) | ~3 ns | Single latch.probe() |
| Steal | ~10-50 ns | Lock-free, CAS contention |
| Wake | ~5-10 ns | Futex |
| Full fork-join cycle | ~10-20 ns | Amortized over work |

## Thread Safety Summary

| Component | Safety | Notes |
|-----------|--------|-------|
| ThreadPool | Thread-safe | Singleton, all operations atomic |
| Worker | Single-owner | Only owning thread accesses |
| Deque.push/pop | Single-owner | Called by owner thread only |
| Deque.steal | Multi-reader | Multiple thieves can race (CAS) |
| Future | Single-owner | Lives on owner's stack |
| OnceLatch | Thread-safe | Multiple threads can wait/set |
| Job handler | User responsibility | User ensures data safety |

## Memory Layout Optimizations

### Cache-Line Alignment

```
Deque memory layout (prevents false sharing):
┌────────────────────────────────────────────────────────────┐
│ Cache Line 0: top (8 bytes) + padding (56 bytes)           │
├────────────────────────────────────────────────────────────┤
│ Cache Line 1: bottom (8 bytes) + padding (56 bytes)        │
├────────────────────────────────────────────────────────────┤
│ Cache Line 2+: buffer pointer, mask, allocator             │
└────────────────────────────────────────────────────────────┘
```

This ensures:
- Owner (bottom) and thieves (top) don't cause cache invalidation
- Buffer metadata rarely changes after initialization

### Future Size Optimization

```
Future(i32, i64) layout:
├── job: Job           (8 bytes: handler pointer)
├── latch: OnceLatch   (4 bytes: state atomic)
├── padding            (4 bytes: alignment)
├── input: i32         (4 bytes)
├── padding            (4 bytes: alignment)
└── result: i64        (8 bytes)
Total: 32 bytes (fits in half a cache line)
```
