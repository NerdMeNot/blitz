# Architecture Overview

Internal design and component interactions.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           BLITZ ARCHITECTURE                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                         USER CODE                                │    │
│  │  join() | parallelFor() | parallelReduce() | iter().sum()        │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                         API LAYER                                │    │
│  │  api.zig - High-level parallel primitives                        │    │
│  │  • Grain size calculation                                        │    │
│  │  • Threshold decisions                                           │    │
│  │  • Context management                                            │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      FORK-JOIN LAYER                             │    │
│  │  future.zig - Future.fork() / Future.join()                      │    │
│  │  • Job creation and scheduling                                   │    │
│  │  • Work stealing during join                                     │    │
│  │  • Result collection                                             │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      SCHEDULER LAYER                             │    │
│  │  pool.zig + worker.zig                                           │    │
│  │  • Thread pool management                                        │    │
│  │  • Work stealing coordination                                    │    │
│  │  • Sleep/wake management                                         │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                     LOCK-FREE PRIMITIVES                         │    │
│  │  deque.zig - Chase-Lev work-stealing deque                       │    │
│  │  latch.zig - OnceLatch, CountLatch, SpinWait                     │    │
│  │  sync.zig  - SyncPtr for parallel writes                         │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Diagram

```
                    ┌──────────────┐
                    │   api.zig    │
                    │  (entry pt)  │
                    └──────┬───────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
  │  iter/mod   │  │  simd/mod   │  │  sort/mod   │
  │ (iterators) │  │   (SIMD)    │  │  (sorting)  │
  └─────────────┘  └─────────────┘  └─────────────┘
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
                    ┌──────▼───────┐
                    │  future.zig  │
                    │ (fork-join)  │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
       ┌──────────┐ ┌──────────┐ ┌──────────┐
       │ pool.zig │ │worker.zig│ │ job.zig  │
       │ (thread  │ │ (worker  │ │  (job    │
       │  pool)   │ │  logic)  │ │  repr)   │
       └────┬─────┘ └────┬─────┘ └──────────┘
            │            │
            ▼            ▼
       ┌──────────┐ ┌──────────┐
       │deque.zig │ │latch.zig │
       │(deque)   │ │ (sync)   │
       └──────────┘ └──────────┘
```

## Data Flow: parallelFor

```
1. User calls parallelFor(n, ctx, body)
         │
         ▼
2. API calculates grain size and checks threshold
         │
         ▼
3. If sequential: call body(ctx, 0, n) directly
   If parallel: continue to step 4
         │
         ▼
4. Create recursive split:
   - Split range in half
   - Fork right half (push to deque)
   - Recurse on left half
         │
         ▼
5. Workers steal from deques:
   - Idle worker steals job
   - Executes the forked half
   - May split further
         │
         ▼
6. Join waits for completion:
   - Owner pops own work first
   - While waiting, steals and executes other work
         │
         ▼
7. All ranges processed, return to user
```

## Data Flow: parallelReduce

```
1. User calls parallelReduce(T, n, identity, ctx, map, combine)
         │
         ▼
2. Divide into chunks (based on grain size)
         │
         ▼
3. Parallel phase:
   ┌─────────┬─────────┬─────────┬─────────┐
   │ Chunk 0 │ Chunk 1 │ Chunk 2 │ Chunk 3 │
   │  map()  │  map()  │  map()  │  map()  │
   │ combine │ combine │ combine │ combine │
   └────┬────┴────┬────┴────┬────┴────┬────┘
        │         │         │         │
        ▼         ▼         ▼         ▼
      partial0  partial1  partial2  partial3
         │
         ▼
4. Sequential combine phase:
   result = combine(partial0, combine(partial1, ...))
         │
         ▼
5. Return final result
```

## Memory Layout

### Thread Pool

```
ThreadPool
├── workers: [MAX_WORKERS]Worker
│   ├── Worker 0
│   │   ├── deque: Deque(Job)
│   │   ├── rng: XorShift64Star
│   │   └── pool: *ThreadPool
│   ├── Worker 1
│   │   └── ...
│   └── ...
├── idle_count: Atomic(u32)
├── shutdown: Atomic(bool)
└── threads: []Thread
```

### Chase-Lev Deque

```
Deque(Job)
├── buffer: []Job          (circular array)
├── mask: usize            (buffer.len - 1 for fast modulo)
├── bottom: Atomic(isize)  (owner's end)
└── top: Atomic(isize)     (thieves' end)

Memory layout (cache-line aligned):
┌────────────────────────────────────────────────┐
│ bottom (64 bytes, own cache line)              │
├────────────────────────────────────────────────┤
│ top (64 bytes, own cache line)                 │
├────────────────────────────────────────────────┤
│ buffer pointer + mask (same cache line OK)     │
└────────────────────────────────────────────────┘
```

### Job Representation

```
Job (8 bytes)
├── function_ptr: u48  (compressed pointer)
└── state: u16         (task state)

Or for larger contexts:
Job
├── function_ptr: *const fn
└── context_ptr: *anyopaque
```

## Key Design Decisions

### 1. Lock-Free Wake

Traditional thread pools use mutex + condition variable:
```
// Slow path
mutex.lock();
cond.signal();
mutex.unlock();
```

Blitz uses futex directly:
```zig
// Fast path
_ = @atomicRmw(&idle_count, .Add, 1, .release);
std.os.futex_wake(&idle_count, 1);
```

**Benefit**: ~5-10ns vs ~100-300ns wake overhead

### 2. Stack-Allocated Jobs

Jobs are embedded in the caller's stack frame:

```zig
fn parallelRecurse(...) void {
    var future: Future(Input, Output) = undefined;  // On stack!
    future.fork(&task, func, input);
    // ... local work ...
    const result = future.join(&task);
}
```

**Benefit**: Zero heap allocation for fork-join

### 3. Active Work-Stealing in Join

While waiting for stolen work:

```zig
fn join(self: *Future, task: *Task) ?Output {
    while (!self.latch.isSet()) {
        // Don't just wait - do useful work!
        if (task.worker.trySteal()) |job| {
            job.execute();
        }
    }
    return self.result;
}
```

**Benefit**: No idle cores while waiting

### 4. Comptime Specialization

All generics resolved at compile time:

```zig
pub fn parallelFor(
    n: usize,
    comptime Context: type,     // Compile-time
    ctx: Context,
    comptime body: fn(...),     // Compile-time
) void
```

**Benefit**: No virtual dispatch, full inlining

## Thread Safety Guarantees

| Component | Thread Safety |
|-----------|---------------|
| ThreadPool | Thread-safe (singleton) |
| Worker | Single-owner (owner thread) |
| Deque.push/pop | Single-owner |
| Deque.steal | Thread-safe (multiple thieves) |
| Future | Single-owner |
| Latch | Thread-safe |

## Performance Characteristics

| Operation | Time | Notes |
|-----------|------|-------|
| Fork (push) | ~3 ns | Wait-free |
| Join (pop) | ~3 ns | Wait-free (common case) |
| Steal | ~10-50 ns | Lock-free, CAS contention |
| Wake | ~5-10 ns | Futex |
| Full fork-join | ~10-100 ns | Including work execution |
